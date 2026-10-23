//! Per-simulation node table in structure-of-arrays form (TRD, Memory model).
//! Arrays are indexed by `node.index`; capacity grows by doubling.

const std = @import("std");
const Allocator = std.mem.Allocator;
const Tree = @import("tree.zig").Tree;
const Fmm = @import("fmm.zig").Fmm;
const Grid = @import("grid.zig").Grid;
const Force = @import("force.zig").Force;
const addr = @import("force.zig").addr;

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
    /// Fast many-body tree and expansions (fmm.zig).
    fmm: Fmm = .{},
    /// Fast collide grid (grid.zig).
    grid: Grid = .{},
    /// Force handle fh refers to forces[fh - 1]; 0 is never a valid handle.
    forces: []?*Force = &.{},

    pub fn deinit(s: *Sim, a: Allocator) void {
        inline for (.{ "x", "y", "vx", "vy", "fx", "fy", "fixed", "px", "py" }) |f| a.free(@field(s, f));
        s.tree.deinit(a);
        s.fmm.deinit(a);
        s.grid.deinit(a);
        for (s.forces) |slot| if (slot) |f| {
            f.deinit(a);
            a.destroy(f);
        };
        a.free(s.forces);
        s.* = .{};
    }

    /// Returns true when arrays were reallocated, so views must be refreshed.
    /// Node-sized force arrays follow the node count, padded with NaN.
    pub fn setNodeCount(s: *Sim, a: Allocator, n: u32) !bool {
        s.n = n;
        var grown = false;
        for (s.forces) |slot| if (slot) |f| if (f.nodeSized() and f.count < n) {
            try f.setCount(a, n);
            grown = true;
        };
        if (n <= s.cap) return grown;
        const cap = @max(n, s.cap * 2, 16);
        inline for (.{ "x", "y", "vx", "vy", "fx", "fy", "fixed", "px", "py" }) |f| {
            @field(s, f) = try a.realloc(@field(s, f), cap);
        }
        s.cap = cap;
        return true;
    }

    pub fn ptr(s: *Sim, which: Ptr) usize {
        return switch (which) {
            .x => addr(s.x),
            .y => addr(s.y),
            .vx => addr(s.vx),
            .vy => addr(s.vy),
            .fx => addr(s.fx),
            .fy => addr(s.fy),
            .fixed => addr(s.fixed),
            .perm => addr(s.tree.perm),
            .rng_buf => 0,
        };
    }

    pub fn getForce(s: *Sim, fh: u32) ?*Force {
        if (fh == 0 or fh > s.forces.len) return null;
        return s.forces[fh - 1];
    }

    pub fn addForce(s: *Sim, a: Allocator, f: *Force) !u32 {
        for (s.forces, 0..) |slot, i| if (slot == null) {
            s.forces[i] = f;
            return @intCast(i + 1);
        };
        s.forces = try a.realloc(s.forces, s.forces.len + 1);
        s.forces[s.forces.len - 1] = f;
        return @intCast(s.forces.len);
    }

    /// Builds the shared tree on (x, y), or on (x + vx, y + vy) when `shifted`.
    pub fn buildTree(s: *Sim, a: Allocator, shifted: bool) !void {
        @setFloatMode(.strict);
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
