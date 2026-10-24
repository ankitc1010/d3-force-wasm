//! The core's allocator: Zig 0.16's `std.heap.BrkAllocator`, wasm path only,
//! without its `single_threaded` check (TRD 3, Design: "Allocator"). In a
//! build with threads `std.heap.wasm_allocator` is a compile error; this copy
//! is just as unsafe across threads, which is fine because only the main
//! thread allocates, between phases. Both builds use it.
//!
//! Size classes are powers of two: small slots live in 64 KiB big pages, and
//! a block of a big page or more takes a power-of-two run of them.

const std = @import("std");
const Allocator = std.mem.Allocator;
const Alignment = std.mem.Alignment;
const math = std.math;

pub const allocator: Allocator = .{ .ptr = undefined, .vtable = &vtable };

const vtable: Allocator.VTable = .{
    .alloc = alloc,
    .resize = resize,
    .remap = remap,
    .free = free,
};

const State = struct {
    next_addrs: [size_class_count]usize = @splat(0),
    /// For each size class, points to the freed pointer.
    frees: [size_class_count]usize = @splat(0),
    /// For each big size class, points to the freed pointer.
    big_frees: [big_size_class_count]usize = @splat(0),
};

var global: State = .{};

const max_usize = math.maxInt(usize);
const bigpage_size: comptime_int = 64 * 1024;
const bigpage_count = max_usize / bigpage_size;
const wasm_page_size: comptime_int = 64 * 1024;

/// Because of storing free list pointers, the minimum size class is 3.
const min_class = math.log2(math.ceilPowerOfTwoAssert(usize, 1 + @sizeOf(usize)));
const size_class_count = math.log2(bigpage_size) - min_class;
/// 0 - 1 bigpage, 1 - 2 bigpages, 2 - 4 bigpages, etc.
const big_size_class_count = math.log2(bigpage_count);

// The four entry points stay out of line: the vtable is comptime-known, so
// every call site would otherwise inline a copy.
noinline fn alloc(ctx: *anyopaque, len: usize, alignment: Alignment, return_address: usize) ?[*]u8 {
    _ = ctx;
    _ = return_address;
    // Make room for the freelist next pointer.
    const actual_len = @max(len +| @sizeOf(usize), alignment.toByteUnits());
    const slot_size = math.ceilPowerOfTwo(usize, actual_len) catch return null;
    const class = math.log2(slot_size) - min_class;
    if (class < size_class_count) {
        const addr = a: {
            const top_free_ptr = global.frees[class];
            if (top_free_ptr != 0) {
                const node: *usize = @ptrFromInt(top_free_ptr + (slot_size - @sizeOf(usize)));
                global.frees[class] = node.*;
                break :a top_free_ptr;
            }
            const next_addr = global.next_addrs[class];
            if (next_addr % bigpage_size == 0) {
                const addr = allocBigPages(1);
                if (addr == 0) return null;
                global.next_addrs[class] = addr + slot_size;
                break :a addr;
            } else {
                global.next_addrs[class] = next_addr + slot_size;
                break :a next_addr;
            }
        };
        return @ptrFromInt(addr);
    }
    const bigpages_needed = bigPagesNeeded(actual_len);
    return @ptrFromInt(allocBigPages(bigpages_needed));
}

noinline fn resize(ctx: *anyopaque, buf: []u8, alignment: Alignment, new_len: usize, return_address: usize) bool {
    _ = ctx;
    _ = return_address;
    // Nothing moves between size classes, but bytes between powers of two
    // can be recovered.
    const buf_align = alignment.toByteUnits();
    const old_actual_len = @max(buf.len + @sizeOf(usize), buf_align);
    const new_actual_len = @max(new_len +| @sizeOf(usize), buf_align);
    const old_small_slot_size = math.ceilPowerOfTwoAssert(usize, old_actual_len);
    const old_small_class = math.log2(old_small_slot_size) - min_class;
    if (old_small_class < size_class_count) {
        const new_small_slot_size = math.ceilPowerOfTwo(usize, new_actual_len) catch return false;
        return old_small_slot_size == new_small_slot_size;
    } else {
        const old_bigpages_needed = bigPagesNeeded(old_actual_len);
        const old_big_slot_pages = math.ceilPowerOfTwoAssert(usize, old_bigpages_needed);
        const new_bigpages_needed = bigPagesNeeded(new_actual_len);
        const new_big_slot_pages = math.ceilPowerOfTwo(usize, new_bigpages_needed) catch return false;
        return old_big_slot_pages == new_big_slot_pages;
    }
}

noinline fn remap(context: *anyopaque, memory: []u8, alignment: Alignment, new_len: usize, return_address: usize) ?[*]u8 {
    return if (resize(context, memory, alignment, new_len, return_address)) memory.ptr else null;
}

noinline fn free(ctx: *anyopaque, buf: []u8, alignment: Alignment, return_address: usize) void {
    _ = ctx;
    _ = return_address;
    const buf_align = alignment.toByteUnits();
    const actual_len = @max(buf.len + @sizeOf(usize), buf_align);
    const slot_size = math.ceilPowerOfTwoAssert(usize, actual_len);
    const class = math.log2(slot_size) - min_class;
    const addr = @intFromPtr(buf.ptr);
    if (class < size_class_count) {
        const node: *usize = @ptrFromInt(addr + (slot_size - @sizeOf(usize)));
        node.* = global.frees[class];
        global.frees[class] = addr;
    } else {
        const bigpages_needed = bigPagesNeeded(actual_len);
        const pow2_pages = math.ceilPowerOfTwoAssert(usize, bigpages_needed);
        const big_slot_size_bytes = pow2_pages * bigpage_size;
        const node: *usize = @ptrFromInt(addr + (big_slot_size_bytes - @sizeOf(usize)));
        const big_class = math.log2(pow2_pages);
        node.* = global.big_frees[big_class];
        global.big_frees[big_class] = addr;
    }
}

inline fn bigPagesNeeded(byte_count: usize) usize {
    return (byte_count + (bigpage_size + (@sizeOf(usize) - 1))) / bigpage_size;
}

fn allocBigPages(n: usize) usize {
    const pow2_pages = math.ceilPowerOfTwoAssert(usize, n);
    const slot_size_bytes = pow2_pages * bigpage_size;
    const class = math.log2(pow2_pages);

    const top_free_ptr = global.big_frees[class];
    if (top_free_ptr != 0) {
        const node: *usize = @ptrFromInt(top_free_ptr + (slot_size_bytes - @sizeOf(usize)));
        global.big_frees[class] = node.*;
        return top_free_ptr;
    }

    const pages_per_bigpage = bigpage_size / wasm_page_size;
    const page_index = @wasmMemoryGrow(0, pow2_pages * pages_per_bigpage);
    if (page_index == -1) return 0;
    return @as(usize, @intCast(page_index)) * wasm_page_size;
}
