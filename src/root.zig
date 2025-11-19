//! By convention, root.zig is the root source file when making a library.

const std = @import("std");
const testing = std.testing;
const Thread = std.Thread;
const Allocator = std.mem.Allocator;
const Alignment = std.mem.Alignment;
const assert = std.debug.assert;
const SinglyLinkedList = std.SinglyLinkedList;
const DoublyLinkedList = std.DoublyLinkedList;
const page_allocator = std.heap.page_allocator;

const log = std.log.scoped(.dogmalloc);

pub const allocator: Allocator = .{
    .ptr = undefined,
    .vtable = &.{
        .alloc = alloc,
        .resize = resize,
        .remap = remap,
        .free = free,
    },
};

const Error = error{OutOfMemory};

var init_heaps = std.once(struct {
    fn init() void {
        cpu_count = @intCast(Thread.getCpuCount() catch 128);
        heaps = page_allocator.alloc(Heap, cpu_count * 4) catch @panic("failed to initialize heaps");
        for (heaps) |*heap| heap.* = .init();
    }
}.init);
var cpu_count: u32 = undefined;
var heaps: []Heap = undefined;
var next_idx: std.atomic.Value(u32) = .init(0);

threadlocal var heap_idx: ?u32 = null;

fn getThreadHeap() *Heap {
    init_heaps.call();
    const idx = heap_idx orelse idx: {
        const next = next_idx.fetchAdd(1, .acq_rel) % cpu_count;
        heap_idx = next;
        break :idx next;
    };
    return &heaps[idx];
}

fn alloc(ctx: *anyopaque, len: usize, alignment: Alignment, ra: usize) ?[*]u8 {
    _ = ctx;

    if (isHuge(len, alignment)) return page_allocator.rawAlloc(
        len,
        alignment,
        ra,
    );

    const heap = getThreadHeap();
    return heap.alloc(len, alignment) catch null;
}

fn resize(ctx: *anyopaque, memory: []u8, alignment: Alignment, new_len: usize, ra: usize) bool {
    _ = ctx;

    const old_huge = isHuge(memory.len, alignment);
    const new_huge = isHuge(new_len, alignment);
    if (old_huge and new_huge) return page_allocator.rawResize(
        memory,
        alignment,
        new_len,
        ra,
    );
    if (old_huge or new_huge) return false;

    const old_bin = binIndex(wsizeOf(memory.len, alignment));
    const new_bin = binIndex(wsizeOf(new_len, alignment));
    return old_bin == new_bin;
}

fn remap(ctx: *anyopaque, memory: []u8, alignment: Alignment, new_len: usize, ra: usize) ?[*]u8 {
    _ = ctx;

    const old_huge = isHuge(memory.len, alignment);
    const new_huge = isHuge(new_len, alignment);
    if (old_huge and new_huge) return page_allocator.rawRemap(
        memory,
        alignment,
        new_len,
        ra,
    );
    if (old_huge or new_huge) return null;

    const old_bin = binIndex(wsizeOf(memory.len, alignment));
    const new_bin = binIndex(wsizeOf(new_len, alignment));
    return if (old_bin == new_bin) memory.ptr else null;
}

fn free(ctx: *anyopaque, memory: []u8, alignment: Alignment, ra: usize) void {
    _ = ctx;

    if (isHuge(memory.len, alignment)) return page_allocator.rawFree(
        memory,
        alignment,
        ra,
    );

    const heap = getThreadHeap();
    return heap.free(memory.ptr);
}

/// A heap owns a set of pages.
const Heap = struct {
    /// Avoid false sharing.
    _: void align(std.atomic.cache_line) = {},

    /// Protects the state in this struct.
    mutex: std.Thread.Mutex = .{},
    /// Queue of pages for each size class (or "bin").
    pages: [BIN_COUNT]PageQueue,
    /// Optimization: array where every entry points to a page with possibly
    /// free blocks in the corresponding queue for that size.
    pages_free_direct: [SMALL_WSIZE_MAX]?*Page.Meta,
    /// Optimization: prevents full pages from being repeatedly searched in
    /// `pageQueueFindFree`.
    pages_full: DoublyLinkedList,

    const SMALL_WSIZE_MAX = 128;
    const SMALL_SIZE_MAX = SMALL_WSIZE_MAX * @sizeOf(usize);

    const EXACT_BINS = 8;
    const BIN_COUNT = binIndex(Page.MAX_OBJ_WSIZE) + 1;

    fn init() Heap {
        return .{
            .pages_free_direct = @splat(null),
            .pages = comptime pages: {
                var pages: [BIN_COUNT]PageQueue = undefined;
                for (0..BIN_COUNT) |bin| {
                    pages[bin] = .{
                        .items = .{},
                        .block_size = binBlockSize(bin),
                    };
                }
                break :pages pages;
            },
            .pages_full = .{},
        };
    }

    /// The main allocation function.
    fn alloc(self: *Heap, len: usize, alignment: Alignment) ![*]u8 {
        assert(len > 0);
        self.mutex.lock();
        defer self.mutex.unlock();

        // fast path for small objects
        const wsize = wsizeOf(len, alignment);
        if (wsize <= SMALL_WSIZE_MAX) return self.allocSmall(wsize);

        // regular allocation
        return self.allocGeneric(wsize);
    }

    /// Free a block.
    fn free(self: *Heap, ptr: *anyopaque) void {
        const page = &Page.fromPtr(ptr).meta;
        const block: *SinglyLinkedList.Node = @ptrCast(@alignCast(ptr));
        if (page.heap_id == heap_idx) {
            // thread-local free
            self.mutex.lock();
            defer self.mutex.unlock();

            page.free.prepend(block);
            page.used -= 1;
            if (page.used == 0) {
                const pq = self.pageQueue(page.block_size / @sizeOf(usize));
                self.retirePage(pq, page);
            }
            // TODO: unfull
        } else {
            // non-local free
            // push atomically on the page thread free list
            var old = page.thread_free.load(.monotonic);
            while (true) {
                block.next = old;
                if (page.thread_free.cmpxchgWeak(
                    old,
                    block,
                    .acq_rel,
                    .acquire,
                )) |current| {
                    old = current;
                } else break;
            }
        }
    }

    fn allocSmall(self: *Heap, wsize: usize) ![*]u8 {
        assert(wsize <= SMALL_WSIZE_MAX);

        // get page in constant time, and allocate from it
        const page = self.getFreeSmallPage(wsize) orelse return self.allocGeneric(wsize);
        return self.allocPage(page, wsize);
    }

    fn getFreeSmallPage(self: *Heap, wsize: usize) ?*Page.Meta {
        assert(wsize <= SMALL_WSIZE_MAX);
        return self.pages_free_direct[wsize - 1];
    }

    /// Generic allocation routine if the fast path (`allocPage`) does not succeed.
    fn allocGeneric(self: *Heap, wsize: usize) ![*]u8 {
        // TODO: do administrative tasks every N generic mallocs

        // find (or allocate) a page of the right size
        const page = self.findPage(wsize) catch page: {
            // first time out of memory, try to collect and retry the allocation once more
            self.collectFree(true);
            const p = try self.findPage(wsize);
            break :page p;
        };

        assert(page.immediateAvailable());
        assert(wsize * @sizeOf(usize) <= page.block_size);
        assert(&Page.fromPtr(page).meta == page);

        // and try again, this time succeeding! (i.e. this should never recurse)
        return self.allocPage(page, wsize) catch unreachable;
    }

    /// Fast allocation in a page: just pop from the free list.
    /// Fall back to generic allocation only if the list is empty.
    fn allocPage(self: *Heap, page: *Page.Meta, wsize: usize) Error![*]u8 {
        assert(wsize * @sizeOf(usize) <= page.block_size);

        // pop from the free list
        const node = page.free.popFirst() orelse return self.allocGeneric(wsize);
        const block: [*]u8 = @ptrCast(node);
        page.used += 1;

        assert(&Page.fromPtr(block).meta == page);
        return block;
    }

    /// Allocate a page.
    fn findPage(self: *Heap, wsize: usize) !*Page.Meta {
        const pq = self.pageQueue(wsize);
        return self.findFreePage(pq);
    }

    fn pageQueue(self: *Heap, wsize: usize) *PageQueue {
        return &self.pages[binIndex(wsize)];
    }

    /// Find a page with free blocks within the given `PageQueue`.
    fn findFreePage(self: *Heap, pq: *PageQueue) !*Page.Meta {
        // check the first page: we even do this with candidate search or otherwise
        // we re-search every time
        if (pq.items.first) |page_node| {
            const page: *Page.Meta = @fieldParentPtr("node", page_node);
            if (page.immediateAvailable()) return page; // fast path
        }

        return self.pageQueueFindFree(pq);
    }

    /// Find a page with free blocks of `pq.block_size`.
    fn pageQueueFindFree(self: *Heap, pq: *PageQueue) !*Page.Meta {
        // search up to `MAX_CANDIDATES` pages for a best candidate
        const MAX_CANDIDATES = 4;

        // search through the pages in "next fit" order
        var candidate: ?*Page.Meta = null;
        var node = pq.items.first;
        var next: ?*DoublyLinkedList.Node = null;
        var candidate_limit: ?std.math.IntFittingRange(0, MAX_CANDIDATES) = null;

        while (node) |n| : ({
            node = next;
            if (candidate_limit) |*c| c.* -|= 1;
        }) {
            const page: *Page.Meta = @fieldParentPtr("node", n);
            next = n.next; // remember next (as this page can move to another queue)

            // is the local free list non-empty?
            if (!page.immediateAvailable()) {
                // collect freed blocks by us and other threads so we get a proper used count
                page.collectFree();
            }

            // if the page is completely full, move it to `pages_full`
            // queue so we don't visit long-lived pages too often.
            if (page.isFull()) {
                self.moveToFull(pq, page);
                continue;
            }

            // the page has free space, make it a candidate
            // we prefer non-expandable pages with high usage as candidates (to reduce commit, and
            // increase chances of free-ing up pages)
            if (candidate) |c| {
                if (c.used == 0) {
                    self.retirePage(pq, c);
                    candidate = page;
                } else if (page.used >= c.used and !page.isMostlyUsed()) {
                    // prefer to reuse fuller pages (in the hope the less used page gets freed)
                    candidate = page;
                }
            } else {
                candidate_limit = MAX_CANDIDATES;
                candidate = page;
            }

            // if we find a non-expandable candidate, or searched for N pages, return
            // with the best candidate
            if (page.immediateAvailable() or candidate_limit == 0) {
                assert(candidate != null);
                break;
            }
        }

        if (candidate) |page| {
            if (!page.immediateAvailable()) {
                assert(page.expandable());
                page.extendFree();
            }
            assert(page.immediateAvailable());

            // move the page to the front of the queue
            self.pageQueueRemove(pq, page);
            self.pageQueuePush(pq, page);

            return page;
        } else {
            return self.pageFresh(pq);
        }
    }

    /// Get a fresh page to use.
    fn pageFresh(self: *Heap, pq: *PageQueue) !*Page.Meta {
        const page = try self.pageFreshAlloc(pq, pq.block_size);
        assert(pq.block_size == page.block_size);
        return page;
    }

    /// Allocate a fresh page.
    fn pageFreshAlloc(self: *Heap, pq: *PageQueue, block_size: usize) !*Page.Meta {
        assert(block_size == pq.block_size);

        const page = try Page.init(pq.block_size);
        self.pageQueuePush(pq, page);

        assert(page.immediateAvailable());
        assert(page.block_size >= block_size);
        return page;
    }

    fn moveToFull(self: *Heap, pq: *PageQueue, page: *Page.Meta) void {
        self.pageQueueRemove(pq, page);
        self.pages_full.append(&page.node);
    }

    /// Retire a page with no more used blocks.
    /// TODO: Important to not retire too quickly though as new allocations might coming.
    fn retirePage(self: *Heap, pq: *PageQueue, meta: *Page.Meta) void {
        _ = self; // autofix
        _ = pq; // autofix
        _ = meta; // autofix

        // assert(pq.block_size == meta.block_size);
        // self.pageQueueRemove(pq, meta);

        // const page: *Page = @alignCast(@fieldParentPtr("meta", meta));
        // TODO: slow
        // page_allocator.destroy(page);
    }

    fn pageQueuePush(self: *Heap, pq: *PageQueue, page: *Page.Meta) void {
        pq.items.prepend(&page.node);
        self.updateDirect(pq);
    }

    fn pageQueueRemove(self: *Heap, pq: *PageQueue, page: *Page.Meta) void {
        const was_first = pq.items.first == &page.node;
        pq.items.remove(&page.node);
        if (was_first) self.updateDirect(pq);
    }

    /// The current small page array is for efficiency and for each
    /// small size (up to `SMALL_WSIZE_MAX`) it points directly to the page for that
    /// size without having to compute the bin. This means when the
    /// current free page queue is updated for a small bin, we need to update a
    /// range of entries in `pages_free_direct`.
    fn updateDirect(self: *Heap, pq: *PageQueue) void {
        const size = pq.block_size;
        if (size > SMALL_SIZE_MAX) return;

        const page: ?*Page.Meta = if (pq.items.first) |node|
            @fieldParentPtr("node", node)
        else
            null;

        // find index in the right direct page array
        const idx = wsizeOf(size, .@"1") - 1;
        if (self.pages_free_direct[idx] == page) return; // already set

        // find start slot
        const bin = binIndex(wsizeOf(size, .@"1"));
        const start = if (bin == 0) 0 else start: {
            // find previous size
            const prev_size = self.pages[bin - 1].block_size;
            break :start wsizeOf(prev_size, .@"1");
        };

        // set size range to the right page
        assert(start <= idx);
        for (start..idx + 1) |sz| self.pages_free_direct[sz] = page;
    }

    fn collectFree(self: *Heap, force: bool) void {
        _ = self; // autofix
        _ = force; // autofix
        @panic("todo");
    }
};

/// A page contains blocks of one specific size (`block_size`).
///
/// Each page has three list of free blocks:
/// `free` for blocks that can be allocated,
/// `local_free` for freed blocks that are not yet available
/// `thread_free` for freed blocks by other threads
///
/// The `local_free` and `thread_free` lists are migrated to the `free` list
/// when it is exhausted. The separate `local_free` list is necessary to
/// implement a monotonic heartbeat. The `thread_free` list is needed for
/// avoiding atomic operations when allocating from the owning thread.
///
/// `used - |thread_free|` == actual blocks that are in use (alive)
/// `used - |thread_free| + |free| + |local_free| == capacity`
///
/// We don't count "freed" (as |free|) but use only the `used` field to reduce
/// the number of memory accesses in the `Page.allFree` function.
/// Use `Page.collectFree` to collect the thread_free list and update the `used` count.
///
/// TODO: update docs
/// Notes:
/// - Non-atomic fields can only be accessed if having _ownership_ (low bit of `xthread_free` is 1).
///   Combining the `thread_free` list with an ownership bit allows a concurrent `free` to atomically
///   free an object and (re)claim ownership if the page was abandoned.
/// - If a page is not part of a heap it is called "abandoned"  (`heap==NULL`) -- in
///   that case the `xthreadid` is 0 or 4 (4 is for abandoned pages that
///   are in the `pages_abandoned` lists of an arena, these are called "mapped" abandoned pages).
/// - page flags are in the bottom 3 bits of `xthread_id` for the fast path in `mi_free`.
/// - The layout is optimized for `free.c:mi_free` and `alloc.c:mi_page_alloc`
const Page = struct {
    _: void align(SIZE) = {},

    /// Header metadata.
    meta: Meta,
    /// The actual data that `free` points to.
    data: [DATA_SIZE]u8,

    const SIZE = 1 << 19;
    const DATA_SIZE = SIZE - @sizeOf(Meta);
    const MAX_OBJ_SIZE = DATA_SIZE / 8;
    const MAX_OBJ_WSIZE = MAX_OBJ_SIZE / @sizeOf(usize);

    comptime {
        assert(@sizeOf(Page) == SIZE);
        assert(@alignOf(Page) == SIZE);
        assert(MAX_OBJ_SIZE < binBlockSize(Heap.BIN_COUNT - 1));
    }

    fn init(block_size: usize) !*Page.Meta {
        // TODO: better allocation strategy
        const page = try page_allocator.create(Page);
        assert(std.mem.isAligned(@intFromPtr(page), Page.SIZE));

        const meta = &page.meta;
        meta.* = .{
            .heap_id = heap_idx.?,
            .free = .{},
            .thread_free = .init(null),
            .used = 0,
            .block_size = block_size,
            .node = .{},
            .next_idx = 0,
        };
        meta.next_idx = @intCast(std.mem.alignPointerOffset(
            @as([*]u8, &page.data),
            meta.blockAlignment().toByteUnits(),
        ).?);

        // initialize an initial free list
        meta.extendFree();
        return meta;
    }

    fn fromPtr(ptr: *anyopaque) *Page {
        return @ptrFromInt(std.mem.alignBackward(usize, @intFromPtr(ptr), SIZE));
    }

    const Meta = struct {
        /// Heap this page belongs to.
        heap_id: u32,
        /// List of available free blocks (`malloc` allocates from this list).
        /// Blocks will be aligned to the greatest power of 2 divisor of `block_size`.
        free: SinglyLinkedList,
        /// List of deferred free blocks freed by other threads.
        thread_free: std.atomic.Value(?*SinglyLinkedList.Node),
        /// Number of blocks in use (including blocks in `thread_free`).
        used: u16,
        /// Size available in each block (always `>0`).
        block_size: usize,
        /// Intrusive doubly linked list, see `PageQueue`.
        node: DoublyLinkedList.Node,
        /// Next index to use when extending the `free` pointers to `data`.
        next_idx: u32,

        /// Are there immediately available blocks, i.e. blocks available on the free list.
        fn immediateAvailable(self: *const Meta) bool {
            return self.free.first != null;
        }

        // Has the page not yet used up to its reserved space?
        fn expandable(self: *const Meta) bool {
            return self.next_idx + self.block_size <= DATA_SIZE;
        }

        fn isFull(self: *const Meta) bool {
            return !self.immediateAvailable() and !self.expandable();
        }

        // Is more than 7/8th of the page in use?
        fn isMostlyUsed(self: *const Meta) bool {
            const block_total = DATA_SIZE / self.block_size;
            const frac = block_total / 8;
            return (block_total - self.used) <= frac;
        }

        /// Extend the capacity (up to reserved) by initializing a free list.
        /// We usually do at most `std.heap.pageSize()` to avoid touching too much memory.
        fn extendFree(self: *Meta) void {
            assert(self.free.first == null);
            assert(self.expandable());

            const block_size = self.block_size;
            const page: *Page = @alignCast(@fieldParentPtr("meta", self));
            const remaining = page.data[self.next_idx..];
            assert(self.blockAlignment().check(@intFromPtr(remaining.ptr)));

            // Heuristic, one OS page seems to work well.
            const page_size = std.heap.pageSize();
            const max_extend = if (block_size >= page_size) 1 else page_size / block_size;
            const extend = @min(remaining.len / block_size, max_extend);

            const data = remaining[0 .. extend * block_size];
            for (0..extend - 1) |block_num| {
                const block: *SinglyLinkedList.Node = @ptrCast(@alignCast(&data[block_num * block_size]));
                const next: *SinglyLinkedList.Node = @ptrCast(@alignCast(&data[(block_num + 1) * block_size]));
                assert(self.blockAlignment().check(@intFromPtr(block)));
                assert(self.blockAlignment().check(@intFromPtr(next)));
                block.next = next;
            }

            const first: *SinglyLinkedList.Node = @ptrCast(@alignCast(&data[0]));
            const last: *SinglyLinkedList.Node = @ptrCast(@alignCast(&data[(extend - 1) * block_size]));
            last.next = self.free.first;
            self.free.first = first;

            self.next_idx += @intCast(extend * block_size);
        }

        fn collectFree(self: *Meta) void {
            // atomically capture the thread free list
            var head = self.thread_free.load(.monotonic) orelse return;
            while (true) {
                if (self.thread_free.cmpxchgWeak(
                    head,
                    null,
                    .acq_rel,
                    .acquire,
                )) |current| {
                    head = current orelse return;
                } else break;
            }

            // and move it to the local list
            const count: u16 = @intCast(head.countChildren() + 1);
            self.free.prepend(head);
            self.used = self.used - count;
        }

        fn blockAlignment(self: *const Meta) Alignment {
            return @enumFromInt(@ctz(self.block_size));
        }
    };
};

/// Pages of a certain block size are held in a queue.
const PageQueue = struct {
    items: DoublyLinkedList,
    block_size: usize,
};

fn isHuge(len: usize, alignment: Alignment) bool {
    return wsizeOf(len, alignment) > Page.MAX_OBJ_WSIZE;
}

/// Return the bin for a given size allocation.
fn binIndex(req_wsize: usize) usize {
    if (req_wsize <= Heap.EXACT_BINS) return req_wsize - 1;

    const wsize = req_wsize - 1;
    // find the highest bit
    const b: u6 = @intCast(@bitSizeOf(usize) - 1 - @clz(wsize)); // note: wsize != 0
    // and use the top 3 bits to determine the bin (~12.5% worst internal fragmentation).
    // - adjust with 3 because we use do not round the first `EXACT_BINS` sizes
    //   which each get an exact bin
    // - adjust with 1 because there is no size 0 bin
    const binIdx = ((@as(usize, b) << 2) + ((wsize >> (b - 2)) & 0x03)) - std.math.log2(Heap.EXACT_BINS) - 1;
    assert(req_wsize * @sizeOf(usize) <= binBlockSize(binIdx));
    return binIdx;
}

/// Return the block size in bytes for a given bin.
fn binBlockSize(binIdx: usize) usize {
    const bin = binIdx + 1;
    if (bin < Heap.EXACT_BINS) return bin * @sizeOf(usize);

    const adj = bin + 1 + std.math.log2(Heap.EXACT_BINS);
    const b: u6 = @intCast(adj >> 2);
    const m = adj & 0x03;
    return ((@as(usize, 1) << b) | (m << (b - 2))) * @sizeOf(usize);
}

/// Align a byte size to a size in _machine words_,
/// i.e. byte size == `wsize * @sizeOf(usize)`.
fn wsizeOf(len: usize, alignment: Alignment) usize {
    const size = alignment.forward(len);
    return std.math.divCeil(usize, size, @sizeOf(usize)) catch unreachable;
}

test "standard allocator tests" {
    try std.heap.testAllocator(allocator);
    try std.heap.testAllocatorAligned(allocator);
    try std.heap.testAllocatorLargeAlignment(allocator);
    try std.heap.testAllocatorAlignedShrink(allocator);
}
