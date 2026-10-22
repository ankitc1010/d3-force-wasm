//! Per-simulation node table in structure-of-arrays form (TRD, Memory model).
//! Arrays are indexed by `node.index`; capacity grows by doubling.

const std = @import("std");
const Allocator = std.mem.Allocator;
const Tree = @import("tree.zig").Tree;

/// Indices for `sim_ptr`.
pub const Ptr = enum(u32) { x, y, vx, vy, fx, fy, fixed, perm, rng_buf };

pub const Sim = struct {
    n: u32 = 0,
    cap: u32 = 0,
    x: []f64 = &.{},
    y: []f64 = &.{},
    vx: []f64 = &.{},
    vy: []f64 = &.{},
    fx: []f64 = &.{},
    fy: []f64 = &.{},
    /// bit 0 = fx set, bit 1 = fy set
    fixed: []u8 = &.{},
    /// Scratch for trees built on shifted positions (collide uses x + vx).
    px: []f64 = &.{},
    py: []f64 = &.{},
    tree: Tree = .{},

    pub fn deinit(s: *Sim, a: Allocator) void {
        inline for (.{ "x", "y", "vx", "vy", "fx", "fy", "fixed", "px", "py" }) |f| a.free(@field(s, f));
        s.tree.deinit(a);
        s.* = .{};
    }

    /// Returns true when arrays were reallocated, so views must be refreshed.
    pub fn setNodeCount(s: *Sim, a: Allocator, n: u32) !bool {
        s.n = n;
        if (n <= s.cap) return false;
        const cap = @max(n, s.cap * 2, 16);
        inline for (.{ "x", "y", "vx", "vy", "fx", "fy", "fixed", "px", "py" }) |f| {
            @field(s, f) = try a.realloc(@field(s, f), cap);
        }
        s.cap = cap;
        return true;
    }

    pub fn ptr(s: *Sim, which: Ptr) usize {
        return switch (which) {
            .x => @intFromPtr(s.x.ptr),
            .y => @intFromPtr(s.y.ptr),
            .vx => @intFromPtr(s.vx.ptr),
            .vy => @intFromPtr(s.vy.ptr),
            .fx => @intFromPtr(s.fx.ptr),
            .fy => @intFromPtr(s.fy.ptr),
            .fixed => @intFromPtr(s.fixed.ptr),
            .perm => @intFromPtr(s.tree.perm.ptr),
            .rng_buf => 0,
        };
    }

    /// Builds the shared tree on (x, y), or on (x + vx, y + vy) when `shifted`.
    pub fn buildTree(s: *Sim, a: Allocator, shifted: bool) !void {
        const n = s.n;
        if (shifted) {
            for (0..n) |i| {
                s.px[i] = s.x[i] + s.vx[i];
                s.py[i] = s.y[i] + s.vy[i];
            }
            try s.tree.build(a, s.px[0..n], s.py[0..n]);
        } else {
            try s.tree.build(a, s.x[0..n], s.y[0..n]);
        }
    }
};
