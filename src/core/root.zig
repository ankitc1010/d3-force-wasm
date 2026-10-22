//! Exported ABI of the core (TRD, Zig core design: "Exported ABI"). Flat and
//! C-style: every export takes a simulation handle and integers or f64 and
//! returns an i32 status or an index. Nothing is imported but memory.

const std = @import("std");
const builtin = @import("builtin");
const sim_mod = @import("sim.zig");
const tree_mod = @import("tree.zig");
const force_mod = @import("force.zig");
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
};

const gpa: std.mem.Allocator = if (builtin.target.cpu.arch.isWasm()) std.heap.wasm_allocator else std.heap.page_allocator;

/// Handle h refers to sims[h - 1]; 0 is never a valid handle.
var sims: []?*Sim = &.{};

fn get(h: u32) ?*Sim {
    if (h == 0 or h > sims.len) return null;
    return sims[h - 1];
}

fn status(s: Status) i32 {
    return @intFromEnum(s);
}

export fn alloc(bytes: u32) u32 {
    const mem = gpa.alignedAlloc(u8, .@"16", bytes) catch return 0;
    return @intCast(@intFromPtr(mem.ptr));
}

export fn free(p: u32, bytes: u32) void {
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
export fn tree_build(h: u32, shifted: u32) i32 {
    const s = get(h) orelse return status(.bad_handle);
    const cells_before = s.tree.cells.ptr;
    const perm_before = s.tree.perm.ptr;
    s.buildTree(gpa, shifted != 0) catch return status(.out_of_memory);
    return status(if (s.tree.cells.ptr != cells_before or s.tree.perm.ptr != perm_before) .grown else .ok);
}

/// Tree introspection for the facade and the trace tests.
/// 0 cell count, 1 root, 2 cells ptr, 3 extent ptr (4 × f64), 4 perm ptr,
/// 5 sizeof(Cell), 6 points in tree.
export fn tree_info(h: u32, which: u32) u32 {
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
export fn tree_order(h: u32, after: u32, out: u32) i32 {
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

export fn force_run(h: u32, fh: u32, alpha: f64) i32 {
    const s = get(h) orelse return status(.bad_handle);
    const f = s.getForce(fh) orelse return status(.bad_handle);
    if (f.nodeSized() and f.count < s.n) return status(.bad_argument);
    switch (f.kind) {
        .center => @import("simple.zig").center(s, f),
        .x => @import("simple.zig").axis(s, f, alpha, 0),
        .y => @import("simple.zig").axis(s, f, alpha, 1),
        .radial => @import("simple.zig").radial(s, f, alpha),
        .link => @import("link.zig").run(s, f, alpha, &jsRandom) catch return status(.bad_argument),
        .many_body => @import("many_body.zig").run(s, gpa, f, alpha, &jsRandom) catch return status(.out_of_memory),
        .collide => @import("collide.zig").run(s, gpa, f, &jsRandom) catch return status(.out_of_memory),
    }
    return status(.ok);
}

export fn sim_integrate(h: u32, velocity_decay: f64) i32 {
    const s = get(h) orelse return status(.bad_handle);
    @import("simple.zig").integrate(s, velocity_decay);
    return status(.ok);
}

test {
    _ = @import("tests.zig");
}
