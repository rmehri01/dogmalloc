//! By convention, root.zig is the root source file when making a library.

const std = @import("std");
const log = std.log;
const Thread = std.Thread;
const assert = std.debug.assert;
const SinglyLinkedList = std.SinglyLinkedList;
const DoublyLinkedList = std.DoublyLinkedList;

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
    tid: Thread.Id,
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
    const BIN_FULL = 48;

    /// We never allocate more than PTRDIFF_MAX (see also <https://sourceware.org/ml/libc-announce/2019/msg00001.html>).
    const MAX_ALLOC_SIZE = std.math.maxInt(isize);

    fn init() Heap {
        @compileLog(binIndex(Page.SIZE));
        return .{
            .tid = std.Thread.getCurrentId(),
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
    fn alloc(self: *Heap, len: usize) ?[*]u8 {
        assert(len > 0);

        // fast path for small objects
        if (len <= SMALL_SIZE_MAX) {
            // TODO: how much do these branch hints impact perf
            @branchHint(.likely);
            return self.allocSmall(len);
        }

        // huge allocation?
        if (len > Page.SIZE) {
            @branchHint(.unlikely);
            // TODO: proper alignment
            return std.heap.PageAllocator.map(len, .fromByteUnits(len));
        }

        // regular allocation
        assert(self.tid == Thread.getCurrentId()); // heaps are thread local
        return self.allocGeneric(len);
    }

    fn allocSmall(self: *Heap, len: usize) ?[*]u8 {
        assert(len <= SMALL_SIZE_MAX);
        assert(self.tid == Thread.getCurrentId()); // heaps are thread local

        // get page in constant time, and allocate from it
        const page = self.getFreeSmallPage(len);
        return self.allocPage(page, len);
    }

    fn getFreeSmallPage(self: *Heap, len: usize) *Page {
        assert(len <= SMALL_SIZE_MAX);
        return self.pages_free_direct[wsizeOf(len) - 1];
    }

    /// Generic allocation routine if the fast path (`allocPage`) does not succeed.
    fn allocGeneric(self: *Heap, len: usize) ?[*]u8 {
        // TODO: initialize if necessary
        // TODO: do administrative tasks every N generic mallocs

        // find (or allocate) a page of the right size
        const page = self.findPage(len) orelse page: {
            // first time out of memory, try to collect and retry the allocation once more
            @branchHint(.unlikely);
            self.collectFree(true);
            const p = self.findPage(len) orelse {
                // out of memory
                @branchHint(.unlikely);
                return null;
            };
            break :page p;
        };

        assert(page.immediateAvailable());
        assert(len <= page.block_size);
        assert(Page.fromPtr(page) == page);

        // and try again, this time succeeding! (i.e. this should never recurse)
        const res = self.allocPage(page, len);
        assert(res != null);

        // TODO: move full pages to full queue

        return res;
    }

    /// Fast allocation in a page: just pop from the free list.
    /// Fall back to generic allocation only if the list is empty.
    fn allocPage(self: *Heap, page: *Page, len: usize) ?[*]u8 {
        // TODO: assertions

        // pop from the free list
        const node = page.free.popFirst() orelse {
            @branchHint(.unlikely);
            return self.allocGeneric(len);
        };
        const block: [*]u8 = @ptrCast(node);
        page.used += 1;

        // TODO: assertions

        return block;
    }

    /// Allocate a page.
    fn findPage(self: *Heap, len: usize) ?*Page {
        if (len > MAX_ALLOC_SIZE) {
            @branchHint(.unlikely);
            log.err("allocation request is too large ({d} bytes)", .{len});
            return null;
        }

        const pq = self.pageQueue(len);
        return self.findFreePage(pq);
    }

    fn pageQueue(self: *Heap, len: usize) *PageQueue {
        const pq = &self.pages[binIndex(len)];
        assert(@intFromEnum(pq.block_size) <= Page.SIZE);
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
        const idx = wsizeOf(size) - 1;
        if (self.pages_free_direct[idx] == page) return; // already set

        // find start slot
        const bin = binIndex(size);
        // TODO: indexing is sus, same with / vs divCeil
        const start = if (bin == 0) 0 else start: {
            // find previous size
            const prev_size = self.pages[bin - 1].block_size;
            break :start wsizeOf(@intFromEnum(prev_size));
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
    // TODO: aligning here is wrong since its not block size
    data: [DATA_LEN]u8 align(8),

    const SIZE = 1 << 16;
    const DATA_LEN = SIZE - (8 + 2 + 8 + 16 + 2);
    /// Heuristic, one OS page seems to work well.
    const MAX_EXTEND = 4 * 1024;
    comptime {
        assert(@sizeOf(Page) == SIZE);
        assert(@alignOf(Page) == SIZE);
        assert(SIZE % MAX_EXTEND == 0);
        assert(binBlockSize(Heap.BIN_FULL - 1) == Page.SIZE);
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
        const block_total = self.data.len / block_size;
        for (0..block_total - 1) |block_num| {
            const block: *SinglyLinkedList.Node = @ptrCast(@alignCast(&self.data[block_num * block_size]));
            const next: *SinglyLinkedList.Node = @ptrCast(@alignCast(&self.data[block_num * block_size + block_size]));
            block.next = next;
        }

        const first: *SinglyLinkedList.Node = @ptrCast(@alignCast(&self.data[0]));
        const last: *SinglyLinkedList.Node = @ptrCast(@alignCast(&self.data[(block_total - 1) * block_size]));
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
        full = Page.SIZE + 1,
        _,
    };
};

/// Return the bin for a given size allocation.
// TODO: the returned index can be smaller
fn binIndex(len: usize) usize {
    assert(len <= Page.SIZE);

    var wsize = wsizeOf(len);
    if (wsize <= Heap.EXACT_BINS) {
        @branchHint(.likely);
        return wsize - 1;
    }

    wsize -= 1;
    // find the highest bit
    const b: u6 = @intCast(@bitSizeOf(usize) - 1 - @clz(wsize)); // note: wsize != 0
    // and use the top 3 bits to determine the bin (~12.5% worst internal fragmentation).
    // - adjust with 3 because we use do not round the first `EXACT_BINS` sizes
    //   which each get an exact bin
    // - adjust with 1 because there is no size 0 bin
    const binIdx = ((@as(usize, b) << 2) + ((wsize >> (b - 2)) & 0x03)) - std.math.log2(Heap.EXACT_BINS) - 1;
    assert(0 < binIdx and binIdx < Heap.BIN_FULL);
    assert(len / @sizeOf(usize) <= binBlockSize(binIdx));
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
fn wsizeOf(len: usize) usize {
    return std.math.divCeil(usize, len, @sizeOf(usize)) catch unreachable;
}

// TODO: actual tests
test {
    for (1..100) |i| {
        std.debug.print("{d} bytes: bin {d}\n", .{ i, binIndex(i * 8) });
    }

    var heap = Heap.init();
    for (heap.pages) |p| {
        std.debug.print("{d}\n", .{p.block_size});
    }

    const x = heap.alloc(9 * 128);
    const y = heap.alloc(9 * 128);
    const z = heap.alloc(9 * 128);
    std.debug.print("{any} {any} {any}\n", .{ x, y, z });
}
