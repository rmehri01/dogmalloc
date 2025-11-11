//! By convention, root.zig is the root source file when making a library.

const std = @import("std");
const log = std.log;
const testing = std.testing;
const Thread = std.Thread;
const Allocator = std.mem.Allocator;
const Alignment = std.mem.Alignment;
const assert = std.debug.assert;
const SinglyLinkedList = std.SinglyLinkedList;
const DoublyLinkedList = std.DoublyLinkedList;
const PageAllocator = std.heap.PageAllocator;

pub const allocator: Allocator = .{
    .ptr = undefined,
    .vtable = &.{
        .alloc = alloc,
        .resize = resize,
        .remap = remap,
        .free = free,
    },
};

// TODO: deal with threads dying and leaking memory
// TODO: can probably just make a global like SmpAllocator instead of trying to support separate heaps
threadlocal var global: Heap = .init();

fn alloc(ctx: *anyopaque, len: usize, alignment: Alignment, ra: usize) ?[*]u8 {
    _ = ctx;
    _ = ra;

    if (isHuge(len, alignment)) {
        @branchHint(.unlikely);
        return PageAllocator.map(len, alignment);
    }

    return global.alloc(len, alignment);
}

fn resize(ctx: *anyopaque, memory: []u8, alignment: Alignment, new_len: usize, ra: usize) bool {
    _ = ctx;
    _ = ra;

    if (isHuge(memory.len, alignment)) {
        @branchHint(.unlikely);
        if (!isHuge(new_len, alignment)) return false;
        return PageAllocator.realloc(memory, new_len, false) != null;
    }
    // TODO: this is messy
    if (isHuge(new_len, alignment)) return false;

    return binIndex(wsizeOf(memory.len, alignment)) == binIndex(wsizeOf(new_len, alignment));
}

fn remap(ctx: *anyopaque, memory: []u8, alignment: Alignment, new_len: usize, ra: usize) ?[*]u8 {
    _ = ctx;
    _ = ra;

    if (isHuge(memory.len, alignment)) {
        @branchHint(.unlikely);
        if (!isHuge(new_len, alignment)) return null;
        return PageAllocator.realloc(memory, new_len, true);
    }
    if (isHuge(new_len, alignment)) return null;

    return if (binIndex(wsizeOf(memory.len, alignment)) == binIndex(wsizeOf(new_len, alignment))) memory.ptr else null;
}

// TODO: implement free
fn free(ctx: *anyopaque, memory: []u8, alignment: Alignment, ra: usize) void {
    _ = memory; // autofix
    _ = alignment; // autofix
    _ = ctx;
    _ = ra;
}

// TODO: use null instead of empty page
var page_empty: Page = .{
    .free = .{},
    .used = 0,
    .block_size = 0,
    .node = .{},
    .next_idx = 0,
    .data = undefined,
};

/// A heap owns a set of pages.
const Heap = struct {
    // TODO: what fields actually need to be thread local
    /// Unique id of this thread.
    // TODO: add back
    // tid: ?Thread.Id,
    /// Optimization: array where every entry points to a page with possibly
    /// free blocks in the corresponding queue for that size.
    pages_free_direct: [SMALL_WSIZE_MAX]*Page,
    /// Queue of pages for each size class (or "bin").
    pages: [BIN_COUNT]PageQueue,
    /// Total number of pages in the `pages` queues.
    page_count: usize,

    const SMALL_WSIZE_MAX = 128;
    const SMALL_SIZE_MAX = SMALL_WSIZE_MAX * @sizeOf(usize);

    // TODO: naming, binhuge vs hugebin
    const EXACT_BINS = 8;
    const BIN_COUNT = BIN_FULL + 1;
    const BIN_FULL = 36;

    /// We never allocate more than PTRDIFF_MAX (see also <https://sourceware.org/ml/libc-announce/2019/msg00001.html>).
    const MAX_ALLOC_SIZE = std.math.maxInt(isize);

    fn init() Heap {
        return .{
            // .tid = std.Thread.getCurrentId(),
            .pages_free_direct = @splat(&page_empty),
            .pages = comptime pages: {
                var pages: [BIN_COUNT]PageQueue = undefined;
                for (0..BIN_COUNT) |bin| {
                    pages[bin] = .{
                        .items = .{},
                        .count = 0,
                        .block_size = switch (bin) {
                            BIN_FULL => .full,
                            else => @enumFromInt(binBlockSize(bin)),
                        },
                    };
                }
                break :pages pages;
            },
            .page_count = 0,
        };
    }

    /// The main allocation function.
    fn alloc(self: *Heap, len: usize, alignment: Alignment) ?[*]u8 {
        assert(len > 0);

        // fast path for small objects
        const wsize = wsizeOf(len, alignment);
        if (wsize <= SMALL_WSIZE_MAX) {
            // TODO: how much do these branch hints impact perf
            @branchHint(.likely);
            return self.allocSmall(wsize);
        }

        // regular allocation
        // assert(self.tid == Thread.getCurrentId()); // heaps are thread local
        return self.allocGeneric(wsize);
    }

    fn allocSmall(self: *Heap, wsize: usize) ?[*]u8 {
        assert(wsize <= SMALL_WSIZE_MAX);
        // assert(self.tid == Thread.getCurrentId()); // heaps are thread local

        // get page in constant time, and allocate from it
        const page = self.getFreeSmallPage(wsize);
        return self.allocPage(page, wsize);
    }

    fn getFreeSmallPage(self: *Heap, wsize: usize) *Page {
        assert(wsize <= SMALL_WSIZE_MAX);
        return self.pages_free_direct[wsize - 1];
    }

    /// Generic allocation routine if the fast path (`allocPage`) does not succeed.
    fn allocGeneric(self: *Heap, wsize: usize) ?[*]u8 {
        // TODO: initialize if necessary
        // TODO: do administrative tasks every N generic mallocs

        // find (or allocate) a page of the right size
        const page = self.findPage(wsize) orelse page: {
            // first time out of memory, try to collect and retry the allocation once more
            @branchHint(.unlikely);
            self.collectFree(true);
            const p = self.findPage(wsize) orelse {
                // out of memory
                @branchHint(.unlikely);
                return null;
            };
            break :page p;
        };

        assert(page.immediateAvailable());
        assert(wsize * @sizeOf(usize) <= page.block_size);
        assert(Page.fromPtr(page) == page);

        // and try again, this time succeeding! (i.e. this should never recurse)
        const res = self.allocPage(page, wsize);
        assert(res != null);

        // TODO: move full pages to full queue

        return res;
    }

    /// Fast allocation in a page: just pop from the free list.
    /// Fall back to generic allocation only if the list is empty.
    fn allocPage(self: *Heap, page: *Page, wsize: usize) ?[*]u8 {
        // TODO: assertions

        // pop from the free list
        const node = page.free.popFirst() orelse {
            @branchHint(.unlikely);
            return self.allocGeneric(wsize);
        };
        const block: [*]u8 = @ptrCast(node);
        page.used += 1;

        // TODO: assertions

        return block;
    }

    /// Allocate a page.
    fn findPage(self: *Heap, wsize: usize) ?*Page {
        if (wsize * @sizeOf(usize) > MAX_ALLOC_SIZE) {
            @branchHint(.unlikely);
            log.err("allocation request is too large ({d} bytes)", .{wsize * @sizeOf(usize)});
            return null;
        }

        const pq = self.pageQueue(wsize);
        return self.findFreePage(pq);
    }

    fn pageQueue(self: *Heap, wsize: usize) *PageQueue {
        const pq = &self.pages[binIndex(wsize)];
        // assert(@intFromEnum(pq.block_size) <= Page.MAX_OBJ_SIZE);
        return pq;
    }

    /// Find a page with free blocks within the given `PageQueue`.
    fn findFreePage(self: *Heap, pq: *PageQueue) ?*Page {
        // check the first page: we even do this with candidate search or otherwise we re-search every time
        if (pq.items.first) |page_node| {
            @branchHint(.likely);
            const page: *Page = @alignCast(@fieldParentPtr("node", page_node));
            if (page.immediateAvailable()) {
                @branchHint(.likely);
                // TODO: retire expire?
                return page; // fast path
            }
        }

        return self.pageQueueFindFree(pq, true);
    }

    /// Find a page with free blocks of `pq.block_size`.
    fn pageQueueFindFree(self: *Heap, pq: *PageQueue, first_try: bool) ?*Page {
        // search through the pages in "next fit" order
        var candidate: ?*Page = null;
        var node = pq.items.first;
        while (node) |n| {
            const page: *Page = @alignCast(@fieldParentPtr("node", n));
            const next = n.next;

            // search up to N pages for a best candidate

            // is the local free list non-empty?
            const available = page.immediateAvailable();
            if (!available) {
                // TODO: collect freed blocks by us and other threads to we get a proper use count
            }

            // if the page is completely full, move it to `pages_full`
            // queue so we don't visit long-lived pages too often.
            if (!available and !page.expandable()) {
                // TODO: handle
            } else {
                // the page has free space, make it a candidate
                // we prefer non-expandable pages with high usage as candidates (to reduce commit, and increase chances of free-ing up pages)
                if (candidate) |c| {
                    // TODO: if used 0, free
                    if (page.used >= c.used and !page.isMostlyUsed()) {
                        // prefer to reuse fuller pages (in the hope the less used page gets freed)
                        candidate = page;
                    }
                } else {
                    candidate = page;
                    // TODO: set limit?
                }
            }

            // TODO: if we find a non-expandable candidate, or searched for N pages, return with the best candidate
            if (available) {
                assert(candidate != null);
                break;
            }

            node = next;
        }

        // set the page to the best candidate
        // TODO: names and control flow need to be cleaned up
        var page = candidate;
        if (page) |p| {
            if (!p.immediateAvailable()) {
                assert(p.expandable());
                if (!p.extendFree()) page = null;
            }
            assert(p.immediateAvailable());
        }

        if (page) |p| {
            // move the page to the front of the queue
            assert(p.immediateAvailable());
            pq.items.remove(&p.node);
            pq.items.prepend(&p.node);
            // TODO retire expire
        } else {
            // TODO: collect retired
            page = self.pageFresh(pq);
            if (page) |p| assert(p.immediateAvailable());
            if (page == null and first_try) {
                // TODO: out-of-memory _or_ an abandoned page with free blocks was reclaimed, try once again
            }
        }

        return page;
    }

    /// Get a fresh page to use.
    fn pageFresh(self: *Heap, pq: *PageQueue) ?*Page {
        const page = self.pageFreshAlloc(pq, @intFromEnum(pq.block_size)) orelse return null;
        assert(@intFromEnum(pq.block_size) == page.block_size);
        // TODO: assertion
        return page;
    }

    /// Allocate a fresh page.
    // TODO: alignment
    fn pageFreshAlloc(self: *Heap, pq: *PageQueue, block_size: usize) ?*Page {
        // TODO: assertion
        assert(block_size == @intFromEnum(pq.block_size));

        // TODO: better allocation strategy, return proper oom error
        // TODO: probably move to page.init()
        const page = std.heap.page_allocator.create(Page) catch return null;
        page.* = .{
            .free = .{},
            .used = 0,
            .block_size = @intFromEnum(pq.block_size),
            .node = .{},
            .next_idx = 0,
            .data = undefined,
        };

        // initialize an initial free list
        if (!page.extendFree()) return null;

        self.pageQueuePush(pq, page);
        assert(page.block_size >= block_size);
        // TODO: assertion
        return page;
    }

    fn pageQueuePush(self: *Heap, pq: *PageQueue, page: *Page) void {
        pq.items.prepend(&page.node);
        pq.count += 1;
        self.updateDirect(pq);
        self.page_count += 1;
    }

    /// The current small page array is for efficiency and for each
    /// small size (up to `SMALL_WSIZE_MAX`) it points directly to the page for that
    /// size without having to compute the bin. This means when the
    /// current free page queue is updated for a small bin, we need to update a
    /// range of entries in `pages_free_direct`.
    fn updateDirect(self: *Heap, pq: *PageQueue) void {
        // TODO: assertion
        const size = @intFromEnum(pq.block_size);
        if (size > SMALL_SIZE_MAX) return;

        // TODO: is this okay to unwrap
        const page: *Page = @alignCast(@fieldParentPtr("node", pq.items.first.?));

        // find index in the right direct page array
        const idx = wsizeOf(size, .@"1") - 1;
        if (self.pages_free_direct[idx] == page) return; // already set

        // find start slot
        const bin = binIndex(wsizeOf(size, .@"1"));
        const start = if (bin == 0) 0 else start: {
            // find previous size
            const prev_size = self.pages[bin - 1].block_size;
            break :start wsizeOf(@intFromEnum(prev_size), .@"1");
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
// TODO: parameterize by block size and total size?
const Page = struct {
    _: void align(SIZE) = {},

    /// List of available free blocks (`malloc` allocates from this list).
    /// Blocks will be aligned to the greatest power of 2 divisor of `block_size`.
    free: SinglyLinkedList,
    /// Number of blocks in use (including blocks in `thread_free`).
    used: u16,
    /// Size available in each block (always `>0`).
    block_size: usize,
    /// Intrusive doubly linked list, see `PageQueue`.
    node: DoublyLinkedList.Node,
    /// Next index to use when extending the `free` pointers to `data`.
    next_idx: u16,
    /// The actual data that `free` points to.
    data: [DATA_LEN]u8,

    // TODO: these and the page constants need to be cleaned up
    const SIZE = 1 << 16;
    const DATA_LEN = SIZE - (8 + 2 + 8 + 16 + 2);
    const MAX_OBJ_SIZE = DATA_LEN / 8;
    // TODO: compute this with wsizeOf?
    const MAX_OBJ_WSIZE = MAX_OBJ_SIZE / @sizeOf(usize);

    /// Heuristic, one OS page seems to work well.
    const MAX_EXTEND = 4 * 1024;

    comptime {
        assert(@sizeOf(Page) == SIZE);
        assert(@alignOf(Page) == SIZE);
        assert(SIZE % MAX_EXTEND == 0);
        assert(MAX_OBJ_SIZE <= binBlockSize(Heap.BIN_FULL - 1));
    }

    fn fromPtr(ptr: *anyopaque) *Page {
        return @ptrFromInt(std.mem.alignBackward(usize, @intFromPtr(ptr), SIZE));
    }

    /// Are there immediately available blocks, i.e. blocks available on the free list.
    fn immediateAvailable(self: *const Page) bool {
        return self.free.first != null;
    }

    // Has the page not yet used up to its reserved space?
    fn expandable(self: *const Page) bool {
        // TODO: dont just initialize whole free list?
        return self.next_idx == 0;
    }

    // Is more than 7/8th of the page in use?
    fn isMostlyUsed(self: *const Page) bool {
        // TODO: duplicated
        const block_total = self.data.len / self.block_size;
        const frac = block_total / 8;
        return (block_total - self.used) <= frac;
    }

    /// Extend the capacity (up to reserved) by initializing a free list.
    /// TODO: We do at most `MAX_EXTEND` to avoid touching too much memory.
    fn extendFree(self: *Page) bool {
        // TODO: assertion
        if (!self.expandable()) return false;

        // TODO: dont just initialize whole free list?
        assert(self.next_idx == 0);

        const block_size = self.block_size;
        const off = std.mem.alignPointerOffset(
            @as([*]u8, &self.data),
            // TODO: this wastes space, should use next_idx instead
            std.math.ceilPowerOfTwoAssert(usize, block_size),
        ).?;
        const data = self.data[off..];
        const block_total = data.len / block_size;
        for (0..block_total - 1) |block_num| {
            const block: *SinglyLinkedList.Node = @ptrCast(@alignCast(&data[block_num * block_size]));
            const next: *SinglyLinkedList.Node = @ptrCast(@alignCast(&data[block_num * block_size + block_size]));
            block.next = next;
        }

        const first: *SinglyLinkedList.Node = @ptrCast(@alignCast(&data[0]));
        const last: *SinglyLinkedList.Node = @ptrCast(@alignCast(&data[(block_total - 1) * block_size]));
        last.next = self.free.first;
        self.free.first = first;

        // TODO: dont just initialize whole free list?
        self.next_idx = self.data.len;

        return true;
    }
};

/// Pages of a certain block size are held in a queue.
const PageQueue = struct {
    items: DoublyLinkedList,
    count: usize,
    block_size: BlockSize,

    // TODO: could store this more compactly like in std.mem.Alignment + std.math.IntFittingRange
    const BlockSize = enum(usize) {
        // TODO: should separate out full into separate field?
        full = Page.MAX_OBJ_SIZE + 1,
        _,
    };
};

fn isHuge(len: usize, alignment: Alignment) bool {
    return wsizeOf(len, alignment) > Page.MAX_OBJ_WSIZE;
}

/// Return the bin for a given size allocation.
// TODO: the returned index can be smaller
fn binIndex(req_wsize: usize) usize {
    assert(req_wsize <= Page.MAX_OBJ_WSIZE);

    if (req_wsize <= Heap.EXACT_BINS) {
        @branchHint(.likely);
        return req_wsize - 1;
    }

    const wsize = req_wsize - 1;
    // find the highest bit
    const b: u6 = @intCast(@bitSizeOf(usize) - 1 - @clz(wsize)); // note: wsize != 0
    // and use the top 3 bits to determine the bin (~12.5% worst internal fragmentation).
    // - adjust with 3 because we use do not round the first `EXACT_BINS` sizes
    //   which each get an exact bin
    // - adjust with 1 because there is no size 0 bin
    const binIdx = ((@as(usize, b) << 2) + ((wsize >> (b - 2)) & 0x03)) - std.math.log2(Heap.EXACT_BINS) - 1;
    assert(0 < binIdx and binIdx < Heap.BIN_FULL);
    assert(req_wsize * @sizeOf(usize) <= binBlockSize(binIdx));
    return binIdx;
}

/// Return the block size in bytes for a given bin.
fn binBlockSize(binIdx: usize) usize {
    assert(binIdx < Heap.BIN_FULL);

    const bin = binIdx + 1;
    if (bin < Heap.EXACT_BINS) {
        @branchHint(.likely);
        return bin * @sizeOf(usize);
    }

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

// TODO: actual tests
test {
    for (1..100) |i| {
        std.debug.print("{d} bytes: bin {d}\n", .{ i, binIndex(i) });
    }

    for (global.pages) |p| {
        std.debug.print("{d}\n", .{p.block_size});
    }

    const x = allocator.alloc(u8, Page.MAX_OBJ_SIZE) catch unreachable;
    const y = allocator.alloc(u8, 128 * 8) catch unreachable;
    const z = allocator.alloc(u8, 128 * 8) catch unreachable;
    std.debug.print("{*} {*} {*}\n", .{ x.ptr, y.ptr, z.ptr });
}

test "standard allocator tests" {
    try std.heap.testAllocator(allocator);
    try std.heap.testAllocatorAligned(allocator);
    try std.heap.testAllocatorLargeAlignment(allocator);
    try std.heap.testAllocatorAlignedShrink(allocator);
}
