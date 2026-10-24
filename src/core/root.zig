//! Exported ABI of the core (TRD, Zig core design: "Exported ABI"). Flat and
//! C-style: every export takes a simulation handle and integers or f64 and
//! returns an i32 status or an index. core.wasm imports only `env.random`;
//! core-mt.wasm also imports its shared memory and `env.now` and exports the
//! pool (TRD 3, Design).

const std = @import("std");
const builtin = @import("builtin");
const sim_mod = @import("sim.zig");
const tree_mod = @import("tree.zig");
const force_mod = @import("force.zig");
const pool = @import("pool.zig");
const Sim = sim_mod.Sim;
const Force = force_mod.Force;

pub const Status = enum(i32) {
    ok = 0,
    grown = 1,
    arena_full = 2,
    rng_exhausted = 3,
    bad_handle = -1,
    out_of_memory = -2,
    bad_argument = -3,
    worker_failed = -4,
};

const gpa: std.mem.Allocator = if (builtin.target.cpu.arch.isWasm()) @import("alloc.zig").allocator else std.heap.page_allocator;

/// Handle h refers to sims[h - 1]; 0 is never a valid handle.
var sims: []?*Sim = &.{};

fn get(h: u32) ?*Sim {
    if (h == 0 or h > sims.len) return null;
    return sims[h - 1];
}

fn status(s: Status) i32 {
    return @intFromEnum(s);
}

/// The status for a kernel error.
fn failure(e: anyerror) i32 {
    return status(switch (e) {
        error.BadArgument => .bad_argument,
        error.WorkerFailed => .worker_failed,
        else => .out_of_memory,
    });
}

// Test-only exports (alloc, free, tree_build, tree_info, tree_order) are in
// core-mt.wasm alone, which keeps them out of the install budget; the tree
// tests load that core without workers, where every phase runs inline.

fn alloc(bytes: u32) callconv(.c) u32 {
    const mem = gpa.alignedAlloc(u8, .@"16", bytes) catch return 0;
    return @intCast(@intFromPtr(mem.ptr));
}

fn free(p: u32, bytes: u32) callconv(.c) void {
    if (p == 0) return;
    const mem: [*]align(16) u8 = @ptrFromInt(p);
    gpa.free(mem[0..bytes]);
}

export fn sim_create() u32 {
    const s = gpa.create(Sim) catch return 0;
    s.* = .{};
    for (sims, 0..) |slot, i| if (slot == null) {
        sims[i] = s;
        return @intCast(i + 1);
    };
    sims = gpa.realloc(sims, sims.len + 1) catch {
        gpa.destroy(s);
        return 0;
    };
    sims[sims.len - 1] = s;
    return @intCast(sims.len);
}

export fn sim_destroy(h: u32) i32 {
    const s = get(h) orelse return status(.bad_handle);
    s.deinit(gpa);
    gpa.destroy(s);
    sims[h - 1] = null;
    return status(.ok);
}

export fn sim_set_node_count(h: u32, n: u32) i32 {
    const s = get(h) orelse return status(.bad_handle);
    const grown = s.setNodeCount(gpa, n) catch return status(.out_of_memory);
    return status(if (grown) .grown else .ok);
}

export fn sim_ptr(h: u32, which: u32) u32 {
    const s = get(h) orelse return 0;
    const w = std.enums.fromInt(sim_mod.Ptr, which) orelse return 0;
    return @intCast(s.ptr(w));
}

/// Builds the tree on positions (`shifted` = 0) or on x + vx, y + vy (1).
/// Returns GROWN when the build reallocated, so views must be refreshed.
fn tree_build(h: u32, shifted: u32) callconv(.c) i32 {
    const s = get(h) orelse return status(.bad_handle);
    const cells_before = s.tree.cells.ptr;
    const perm_before = s.tree.perm.ptr;
    s.buildTree(gpa, shifted != 0) catch |e| return failure(e);
    return status(if (s.tree.cells.ptr != cells_before or s.tree.perm.ptr != perm_before) .grown else .ok);
}

/// Tree introspection for the facade and the trace tests.
/// 0 cell count, 1 root, 2 cells ptr, 3 extent ptr (4 × f64), 4 perm ptr,
/// 5 sizeof(Cell), 6 points in tree.
fn tree_info(h: u32, which: u32) callconv(.c) u32 {
    const s = get(h) orelse return 0;
    const t = &s.tree;
    return switch (which) {
        0 => t.len,
        1 => t.root,
        2 => @intCast(@intFromPtr(t.cells.ptr)),
        3 => @intCast(@intFromPtr(&t.extent)),
        4 => @intCast(@intFromPtr(t.perm.ptr)),
        5 => @sizeOf(tree_mod.Cell),
        6 => t.m,
        else => 0,
    };
}

/// Writes cell indices in d3-quadtree callback order to `out` (cell count × u32):
/// `after` = 0 for `visit`, 1 for `visitAfter`.
fn tree_order(h: u32, after: u32, out: u32) callconv(.c) i32 {
    const s = get(h) orelse return status(.bad_handle);
    const t = &s.tree;
    if (out == 0) return status(.bad_argument);
    const dst: [*]u32 = @ptrFromInt(out);
    t.order(gpa, after != 0, dst[0..t.len]) catch return status(.out_of_memory);
    return status(.ok);
}

/// The force's JS random source (`env.random`); the facade points it at the
/// running force's `random` before each `force_run`.
extern "env" fn random() f64;

fn jsRandom() f64 {
    return random();
}

export fn force_create(h: u32, kind: u32) u32 {
    const s = get(h) orelse return 0;
    const k = std.enums.fromInt(force_mod.Kind, kind) orelse return 0;
    const f = gpa.create(Force) catch return 0;
    f.* = .{ .kind = k };
    if (f.nodeSized()) f.setCount(gpa, s.n) catch {
        gpa.destroy(f);
        return 0;
    };
    return s.addForce(gpa, f) catch {
        f.deinit(gpa);
        gpa.destroy(f);
        return 0;
    };
}

export fn force_destroy(h: u32, fh: u32) i32 {
    const s = get(h) orelse return status(.bad_handle);
    const f = s.getForce(fh) orelse return status(.bad_handle);
    f.deinit(gpa);
    gpa.destroy(f);
    s.forces[fh - 1] = null;
    return status(.ok);
}

/// Resizes the force's arrays to `count` entries (nodes, or links for link).
/// Existing entries are kept; new float entries are NaN.
export fn force_set_count(h: u32, fh: u32, count: u32) i32 {
    const s = get(h) orelse return status(.bad_handle);
    const f = s.getForce(fh) orelse return status(.bad_handle);
    f.setCount(gpa, count) catch return status(.out_of_memory);
    return status(.grown);
}

export fn force_ptr(h: u32, fh: u32, which: u32) u32 {
    const s = get(h) orelse return 0;
    const f = s.getForce(fh) orelse return 0;
    const w = std.enums.fromInt(force_mod.Array, which) orelse return 0;
    return @intCast(f.ptr(w));
}

export fn force_set_scalar(h: u32, fh: u32, which: u32, v: f64) i32 {
    const s = get(h) orelse return status(.bad_handle);
    const f = s.getForce(fh) orelse return status(.bad_handle);
    if (which >= f.scalars.len) return status(.bad_argument);
    f.scalars[which] = v;
    return status(.ok);
}

export fn force_get_scalar(h: u32, fh: u32, which: u32) f64 {
    const s = get(h) orelse return 0;
    const f = s.getForce(fh) orelse return 0;
    return if (which < f.scalars.len) f.scalars[which] else 0;
}

/// Saves vx, vy (and x, y when `positions` is 1) before a threaded step;
/// `sim_ptr(h, 9)` points at them: vx, vy, x, y, n entries each. In
/// core-mt.wasm only, the one core whose steps can fail.
fn sim_snapshot(h: u32, positions: u32) callconv(.c) i32 {
    const s = get(h) orelse return status(.bad_handle);
    s.snapshot(gpa, positions != 0) catch return status(.out_of_memory);
    return status(.ok);
}

export fn force_run(h: u32, fh: u32, alpha: f64) i32 {
    const s = get(h) orelse return status(.bad_handle);
    const f = s.getForce(fh) orelse return status(.bad_handle);
    if (f.nodeSized() and f.count < s.n) return status(.bad_argument);
    runForce(s, f, alpha) catch |e| return failure(e);
    return status(.ok);
}

fn runForce(s: *Sim, f: *Force, alpha: f64) !void {
    switch (f.kind) {
        .center => @import("simple.zig").center(s, f),
        .x => try @import("simple.zig").axis(s, f, alpha, 0),
        .y => try @import("simple.zig").axis(s, f, alpha, 1),
        .radial => try @import("simple.zig").radial(s, f, alpha),
        .link => {
            if (fastMode(s, f)) {
                try @import("link_fast.zig").run(s, gpa, f, alpha);
            } else try @import("link.zig").run(s, f, alpha, &jsRandom);
        },
        .many_body => {
            // Fast mode: FMM at or above the crossover; the exact kernel otherwise,
            // or when the FMM declines a degenerate extent (TRD 2).
            if (fastMode(s, f) and try @import("fmm.zig").run(s, gpa, f, alpha)) return;
            try @import("many_body.zig").run(s, gpa, f, alpha, &jsRandom);
        },
        .collide => {
            if (fastMode(s, f)) {
                try @import("grid.zig").run(s, gpa, f, alpha);
            } else try @import("collide.zig").run(s, gpa, f, &jsRandom);
        },
    }
}

/// Fast mode applies at or above the crossover node count (TRD 2); below it
/// every kernel is the exact one, so small simulations stay bit-exact.
fn fastMode(s: *const Sim, f: *const Force) bool {
    return f.scalar(.precision) == 1 and s.n >= @import("fmm.zig").MIN_N;
}

export fn sim_integrate(h: u32, velocity_decay: f64) i32 {
    const s = get(h) orelse return status(.bad_handle);
    @import("simple.zig").integrate(s, velocity_decay) catch |e| return failure(e);
    return status(.ok);
}

/// Test and benchmark knobs (pool.tune), in core-mt.wasm only: chunk sizes
/// never change results, and without the export the inlined core folds the
/// test overrides away.
fn pool_tune(which: u32, v: f64) callconv(.c) void {
    pool.tune(which, v);
}

// The pool's exports, in core-mt.wasm only (TRD 3, Design).
const pool_exports = if (pool.threaded) struct {
    /// Allocates the regions of k workers; returns the first region, or 0.
    fn pool_init(k: u32) callconv(.c) u32 {
        return pool.mt.init(gpa, k);
    }
    fn pool_hold(delta: i32) callconv(.c) void {
        pool.mt.hold(delta);
    }
    /// Sets the workers taking part in later phases; returns the previous value.
    fn pool_set_active(a: u32) callconv(.c) u32 {
        return pool.mt.setActive(a);
    }
    fn pool_retire() callconv(.c) void {
        pool.mt.retire();
    }
    /// 0 workers, 1 failed tid (64 = timeout), 2 address of the failed flag,
    /// 3 region size, 4 active workers.
    fn pool_info(which: u32) callconv(.c) u32 {
        return switch (which) {
            0 => pool.mt.workers,
            1 => @atomicLoad(u32, &pool.mt.slot.failed, .seq_cst),
            2 => @intCast(@intFromPtr(&pool.mt.slot.failed)),
            3 => pool.REGION,
            4 => pool.mt.slot.active,
            else => 0,
        };
    }
    /// 0 phases dispatched, 1 ms the main thread waited for check-ins.
    fn pool_stat(which: u32) callconv(.c) f64 {
        return switch (which) {
            0 => pool.mt.phases,
            1 => pool.mt.wait_ms,
            else => 0,
        };
    }
} else struct {};

comptime {
    if (pool.threaded) {
        @export(&alloc, .{ .name = "alloc" });
        @export(&pool_tune, .{ .name = "pool_tune" });
        @export(&sim_snapshot, .{ .name = "sim_snapshot" });
        @export(&free, .{ .name = "free" });
        @export(&tree_build, .{ .name = "tree_build" });
        @export(&tree_info, .{ .name = "tree_info" });
        @export(&tree_order, .{ .name = "tree_order" });
        @export(&pool.mt.workerStart, .{ .name = "worker_start" });
        for (.{ "pool_init", "pool_hold", "pool_set_active", "pool_retire", "pool_info", "pool_stat" }) |name| {
            @export(&@field(pool_exports, name), .{ .name = name });
        }
    }
}

test {
    _ = @import("tests.zig");
}
