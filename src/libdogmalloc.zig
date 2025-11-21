//! Library that can be used from C, mostly for testing and benchmarking purposes.

const std = @import("std");
const assert = std.debug.assert;

const dogmalloc = @import("dogmalloc");
var allocator = dogmalloc.allocator;

const log = std.log.scoped(.libdogmalloc);

// Mostly copied from https://github.com/dweiller/zimalloc/blob/main/src/libzimalloc.zig

/// Minimal alignment necessary. On most platforms 16 bytes are needed
/// due to SSE registers for example.
const MAX_ALIGN = @alignOf(std.c.max_align_t);

export fn malloc(len: usize) ?*anyopaque {
    log.debug("malloc {d}", .{len});
    return allocateBytes(len, MAX_ALIGN, @returnAddress(), false, false, true);
}

export fn realloc(ptr_opt: ?*anyopaque, len: usize) ?*anyopaque {
    log.debug("realloc {?*} {d}", .{ ptr_opt, len });
    if (ptr_opt) |ptr| {
        const old = SliceMeta.fromRaw(ptr);
        const old_slice = old.ptr[0..old.len];

        const new_len = len + (old.len - old.usableSize(ptr));
        if (allocator.resize(old_slice, new_len)) {
            old.len = new_len;
            return ptr;
        }

        const new_mem = allocateBytes(
            len,
            MAX_ALIGN,
            @returnAddress(),
            false,
            false,
            true,
        ) orelse return null;

        const copy_len = @min(len, old.usableSize(ptr));
        @memcpy(new_mem[0..copy_len], @as([*]u8, @ptrCast(ptr))[0..copy_len]);

        allocator.free(old_slice);
        return new_mem;
    }

    return allocateBytes(len, MAX_ALIGN, @returnAddress(), false, false, true);
}

export fn free(ptr_opt: ?*anyopaque) void {
    log.debug("free {?*}", .{ptr_opt});
    if (ptr_opt) |ptr| {
        const old = SliceMeta.fromRaw(ptr);
        allocator.free(old.ptr[0..old.len]);
    }
}

export fn calloc(size: usize, count: usize) ?*anyopaque {
    log.debug("calloc {d} {d}", .{ size, count });
    const bytes = size * count;
    return allocateBytes(bytes, MAX_ALIGN, @returnAddress(), true, false, true);
}

export fn aligned_alloc(alignment: usize, size: usize) ?*anyopaque {
    log.debug("aligned_alloc alignment={d}, size={d}", .{ alignment, size });
    return allocateBytes(size, alignment, @returnAddress(), false, true, true);
}

export fn posix_memalign(ptr: *?*anyopaque, alignment: usize, size: usize) c_int {
    log.debug("posix_memalign ptr={*}, alignment={d}, size={d}", .{ ptr, alignment, size });

    if (size == 0) {
        ptr.* = null;
        return 0;
    }

    if (@popCount(alignment) != 1 or alignment < @sizeOf(*anyopaque)) {
        return @intFromEnum(std.c.E.INVAL);
    }

    if (allocateBytes(size, alignment, @returnAddress(), false, false, false)) |p| {
        ptr.* = p;
        return 0;
    }

    return @intFromEnum(std.c.E.NOMEM);
}

export fn memalign(alignment: usize, size: usize) ?*anyopaque {
    log.debug("memalign alignment={d}, size={d}", .{ alignment, size });
    return allocateBytes(size, alignment, @returnAddress(), false, true, true);
}

export fn valloc(size: usize) ?*anyopaque {
    log.debug("valloc {d}", .{size});
    return allocateBytes(size, std.heap.pageSize(), @returnAddress(), false, false, true);
}

export fn pvalloc(size: usize) ?*anyopaque {
    log.debug("pvalloc {d}", .{size});
    const aligned_size = std.mem.alignForward(usize, size, std.heap.pageSize());
    return allocateBytes(aligned_size, std.heap.pageSize(), @returnAddress(), false, false, true);
}

export fn malloc_usable_size(ptr_opt: ?*anyopaque) usize {
    if (ptr_opt) |ptr| return SliceMeta.fromRaw(ptr).usableSize(ptr);
    return 0;
}

/// We store the size of the pointer in the allocation which adds a bit of
/// overhead when used from C but means that we don't have to add extra metadata
/// when the library is used from Zig since the Zig `Allocator` interface
/// requires a slice to be passed to `free`.
const SliceMeta = struct {
    ptr: [*]u8,
    len: usize,

    fn fromRaw(ptr: *anyopaque) *SliceMeta {
        return @alignCast(std.mem.bytesAsValue(
            SliceMeta,
            @as([*]u8, @ptrCast(ptr)) - @sizeOf(SliceMeta),
        ));
    }

    fn usableSize(self: *const SliceMeta, ptr: *const anyopaque) usize {
        const meta_size = @as([*]const u8, @ptrCast(ptr)) - self.ptr;
        return self.len - meta_size;
    }
};

fn allocateBytes(
    byte_count: usize,
    alignment: usize,
    ret_addr: usize,
    comptime zero: bool,
    comptime check_alignment: bool,
    comptime set_errno: bool,
) ?[*]u8 {
    if (byte_count == 0) return null;

    if (check_alignment) {
        if (!set_errno) @compileError("check_alignment requires set_errno to be true");
        if (!std.mem.isValidAlign(alignment)) @panic("invalid");
    }

    const padding = @max(@sizeOf(SliceMeta), alignment);
    const len = byte_count + padding;
    if (allocator.rawAlloc(len, .fromByteUnits(alignment), ret_addr)) |ptr| {
        const user_ptr = ptr + padding;
        @memset(user_ptr[0..byte_count], if (zero) 0 else undefined);
        const meta_ptr = user_ptr - @sizeOf(SliceMeta);
        const slice_meta = SliceMeta{ .ptr = ptr, .len = len };
        @memcpy(meta_ptr, std.mem.asBytes(&slice_meta));

        log.debug("allocated {*}", .{user_ptr});
        assert(SliceMeta.fromRaw(user_ptr).ptr == ptr);
        assert(SliceMeta.fromRaw(user_ptr).len == len);
        assert(SliceMeta.fromRaw(user_ptr).usableSize(user_ptr) == byte_count);
        return user_ptr;
    }

    log.debug("out of memory", .{});
    if (set_errno) setErrno(.NOMEM);
    return null;
}

fn setErrno(code: std.c.E) void {
    std.c._errno().* = @intFromEnum(code);
}
