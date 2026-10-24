//! Per-force parameter storage (TRD, Memory model: "Per-force arrays").
//! Arrays are filled by the facade on `initialize`, exactly when d3-force
//! re-evaluates its accessors; scalars are pushed before every run.

const std = @import("std");
const Allocator = std.mem.Allocator;

pub const Kind = enum(u32) { center, collide, link, many_body, radial, x, y };

/// Indices for `force_set_scalar`. `precision` is 0 (exact) or 1 (fast);
/// `order` and `opening` are the fast many-body FMM parameters; `seed` is
/// the one `random()` draw fast mode makes per force per tick (TRD 2).
pub const Scalar = enum(u32) { strength, x, y, theta2, distance_min2, distance_max2, iterations, precision, order, opening, seed };

/// Indices for `force_ptr`. Meaning per kind:
///   many_body  f0 strength
///   collide    f0 radius
///   x, y       f0 strength, f1 target
///   radial     f0 strength, f1 radius
///   link       f0 strength, f1 distance, f2 bias, source, target
pub const Array = enum(u32) { f0, f1, f2, source, target };

/// Byte offset of an array for the facade, or 0 when it is empty.
pub fn addr(slice: anytype) usize {
    return if (slice.len == 0) 0 else @intFromPtr(slice.ptr);
}

pub const Force = struct {
    kind: Kind,
    scalars: [11]f64 = .{0} ** 11,
    /// Length of every array: node count, or link count for `link`.
    count: u32 = 0,
    f0: []f64 = &.{},
    f1: []f64 = &.{},
    f2: []f64 = &.{},
    source: []u32 = &.{},
    target: []u32 = &.{},
    /// Fast link's adjacency (link_fast.zig); empty until first used.
    csr_ptr: []u32 = &.{},
    csr_adj: []u32 = &.{},
    /// The node count the adjacency was built for; 0 once the links change.
    csr_n: u32 = 0,

    pub fn deinit(f: *Force, a: Allocator) void {
        inline for (.{ "f0", "f1", "f2", "source", "target", "csr_ptr", "csr_adj" }) |name| a.free(@field(f, name));
        f.* = .{ .kind = f.kind };
    }

    /// True when the arrays are indexed by node, so they follow the node count.
    pub fn nodeSized(f: *const Force) bool {
        return f.kind != .link and f.kind != .center;
    }

    fn floatArrays(kind: Kind) u32 {
        return switch (kind) {
            .center => 0,
            .collide, .many_body => 1,
            .radial, .x, .y => 2,
            .link => 3,
        };
    }

    /// Resizes every array to `count`. New float slots are NaN, which is what
    /// d3 reads from an accessor array indexed past its end (`+undefined`).
    pub fn setCount(f: *Force, a: Allocator, count: u32) !void {
        const old = f.count;
        const k = floatArrays(f.kind);
        inline for (.{ "f0", "f1", "f2" }, 0..) |name, i| if (i < k) {
            @field(f, name) = try a.realloc(@field(f, name), count);
            if (count > old) @memset(@field(f, name)[old..], std.math.nan(f64));
        };
        if (f.kind == .link) {
            f.source = try a.realloc(f.source, count);
            f.target = try a.realloc(f.target, count);
            if (count > old) {
                @memset(f.source[old..], 0);
                @memset(f.target[old..], 0);
            }
        }
        f.count = count;
        f.csr_n = 0;
    }

    /// An empty slice's pointer is only an alignment dummy, so it reads as 0.
    pub fn ptr(f: *Force, which: Array) usize {
        return switch (which) {
            inline else => |w| addr(@field(f, @tagName(w))),
        };
    }

    pub fn scalar(f: *const Force, which: Scalar) f64 {
        return f.scalars[@intFromEnum(which)];
    }
};
