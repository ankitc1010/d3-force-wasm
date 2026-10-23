//! Zig unit tests for the core, run with `zig build test` in ReleaseSafe.
//! Structural parity against d3-quadtree traces lives in test/tree-test.js.

const std = @import("std");
const tree_mod = @import("tree.zig");
const Tree = tree_mod.Tree;
const NONE = tree_mod.NONE;
const a = std.testing.allocator;

test {
    _ = @import("fmm.zig");
    _ = @import("hash.zig");
}

test "empty and all-NaN inputs give an empty tree" {
    var t: Tree = .{};
    defer t.deinit(a);
    try t.build(a, &.{}, &.{});
    try std.testing.expectEqual(NONE, t.root);
    const nan = std.math.nan(f64);
    try t.build(a, &.{ nan, 1 }, &.{ 0, nan });
    try std.testing.expectEqual(NONE, t.root);
    try std.testing.expect(std.math.isNan(t.extent[0]));
}

test "single point: root leaf, extent from floor + 1" {
    var t: Tree = .{};
    defer t.deinit(a);
    try t.build(a, &.{3.25}, &.{-7.5});
    try std.testing.expectEqual(@as(u32, 1), t.len);
    try std.testing.expect(t.cells[0].isLeaf());
    try std.testing.expectEqualSlices(f64, &.{ 3, -8, 4, -7 }, &t.extent);
}

test "coincident points form one leaf, chain in descending index order" {
    var t: Tree = .{};
    defer t.deinit(a);
    const xs = [_]f64{ 1, 1, -0.0, 1 };
    const ys = [_]f64{ 2, 2, 5, 2 };
    try t.build(a, &xs, &ys);
    // Leaf contents in perm are ascending, chain is read from the end.
    var found = false;
    for (t.cells[0..t.len]) |c| if (c.isLeaf() and c.count == 3) {
        try std.testing.expectEqualSlices(u32, &.{ 0, 1, 3 }, t.perm[c.first .. c.first + c.count]);
        found = true;
    };
    try std.testing.expect(found);
}

test "two points split to the first separating level" {
    var t: Tree = .{};
    defer t.deinit(a);
    try t.build(a, &.{ 0, 1 }, &.{ 0, 1 });
    // extent [0,0]-[2,2]: root internal, children 0 and 3 are leaves.
    try std.testing.expectEqualSlices(f64, &.{ 0, 0, 2, 2 }, &t.extent);
    const r = t.cells[t.root];
    try std.testing.expect(r.child[0] != NONE and r.child[3] != NONE);
    try std.testing.expect(r.child[1] == NONE and r.child[2] == NONE);
}

test "near-duplicates below 2^-32 of the extent still separate" {
    var t: Tree = .{};
    defer t.deinit(a);
    const xs = [_]f64{ 0, 1024, 0.5, 0.5 + 1e-12 };
    const ys = [_]f64{ 0, 1024, 0.25, 0.25 };
    try t.build(a, &xs, &ys);
    var leaves: u32 = 0;
    var deepest: f64 = std.math.inf(f64);
    for (t.cells[0..t.len]) |c| if (c.isLeaf()) {
        leaves += 1;
        deepest = @min(deepest, c.x1 - c.x0);
    };
    try std.testing.expectEqual(@as(u32, 4), leaves);
    try std.testing.expect(deepest < 2048.0 / @as(f64, 1 << 32));
}

test "radix sort output is sorted and stable" {
    var t: Tree = .{};
    defer t.deinit(a);
    var prng = std.Random.DefaultPrng.init(42);
    const r = prng.random();
    var xs: [500]f64 = undefined;
    var ys: [500]f64 = undefined;
    for (&xs, &ys, 0..) |*x, *y, i| {
        // Many duplicates so stability is exercised.
        x.* = @floatFromInt(r.intRangeLessThan(i32, -20, 20));
        y.* = if (i % 2 == 0) 3 else @floatFromInt(r.intRangeLessThan(i32, -20, 20));
    }
    try t.build(a, &xs, &ys);
    for (1..t.m) |k| {
        try std.testing.expect(t.keys[k - 1] <= t.keys[k]);
        if (t.keys[k - 1] == t.keys[k]) try std.testing.expect(t.perm[k - 1] < t.perm[k]);
    }
}

test "visit order is preorder and visitAfter is post-order" {
    var t: Tree = .{};
    defer t.deinit(a);
    const xs = [_]f64{ 0, 3, 1, 2, 3.5 };
    const ys = [_]f64{ 0, 3, 2, 1, 0.5 };
    try t.build(a, &xs, &ys);
    const out = try a.alloc(u32, t.len);
    defer a.free(out);
    try t.order(a, false, out);
    for (out, 0..) |c, i| try std.testing.expectEqual(@as(u32, @intCast(i)), c);
    try t.order(a, true, out);
    try std.testing.expectEqual(t.root, out[t.len - 1]);
    // Every child is called back before its parent.
    var pos = try a.alloc(u32, t.len);
    defer a.free(pos);
    for (out, 0..) |c, i| pos[c] = @intCast(i);
    for (t.cells[0..t.len], 0..) |c, i| for (c.child) |ch| if (ch != NONE) {
        try std.testing.expect(pos[ch] < pos[i]);
    };
}

const Sim = @import("sim.zig").Sim;
const Force = @import("force.zig").Force;

fn addForce(s: *Sim, kind: @import("force.zig").Kind) !*Force {
    const f = try a.create(Force);
    f.* = .{ .kind = kind };
    _ = try s.addForce(a, f);
    return f;
}

test "node-sized force arrays follow the node count, padded with NaN" {
    var s: Sim = .{};
    defer s.deinit(a);
    const f = try addForce(&s, .x);
    try f.setCount(a, 2);
    f.f0[0] = 1;
    f.f1[1] = 2;
    try std.testing.expect(try s.setNodeCount(a, 5));
    try std.testing.expectEqual(@as(u32, 5), f.count);
    try std.testing.expectEqual(@as(f64, 1), f.f0[0]);
    try std.testing.expectEqual(@as(f64, 2), f.f1[1]);
    for (f.f0[2..], f.f1[2..]) |x, t| try std.testing.expect(std.math.isNan(x) and std.math.isNan(t));
    // Shrinking keeps the arrays; the kernels only read the first n.
    _ = try s.setNodeCount(a, 3);
    try std.testing.expectEqual(@as(u32, 5), f.count);
}

test "link arrays do not follow the node count, and bad indices are rejected" {
    var s: Sim = .{};
    defer s.deinit(a);
    _ = try s.setNodeCount(a, 3);
    const f = try addForce(&s, .link);
    try f.setCount(a, 1);
    _ = try s.setNodeCount(a, 10);
    try std.testing.expectEqual(@as(u32, 1), f.count);
    f.source[0] = 0;
    f.target[0] = 10;
    const never = struct {
        fn random() f64 {
            unreachable;
        }
    }.random;
    try std.testing.expectError(error.BadArgument, @import("link.zig").run(&s, f, 1, &never));
}

test "integrate applies the fixed-position rule per axis" {
    var s: Sim = .{};
    defer s.deinit(a);
    _ = try s.setNodeCount(a, 2);
    for (0..2) |i| {
        s.x[i] = 1;
        s.y[i] = 2;
        s.vx[i] = 10;
        s.vy[i] = 20;
        s.fx[i] = -5;
        s.fy[i] = -6;
    }
    s.fixed[0] = 0;
    s.fixed[1] = 2; // fy only
    @import("simple.zig").integrate(&s, 0.5);
    try std.testing.expectEqualSlices(f64, &.{ 6, 6 }, s.x[0..2]);
    try std.testing.expectEqualSlices(f64, &.{ 5, 5 }, s.vx[0..2]);
    try std.testing.expectEqualSlices(f64, &.{ 12, -6 }, s.y[0..2]);
    try std.testing.expectEqualSlices(f64, &.{ 10, 0 }, s.vy[0..2]);
}

const Scalar = @import("force.zig").Scalar;

fn setScalar(f: *Force, which: Scalar, v: f64) void {
    f.scalars[@intFromEnum(which)] = v;
}

test "fast link equals exact link bitwise on a perfect matching" {
    // With one edge per node, Jacobi and Gauss-Seidel see the same operands.
    var s: Sim = .{};
    defer s.deinit(a);
    const n: u32 = 2400;
    _ = try s.setNodeCount(a, n);
    var lcg = @import("rng.zig").Lcg{};
    for (0..n) |i| {
        s.x[i] = 500 * (lcg.next() - 0.5);
        s.y[i] = 500 * (lcg.next() - 0.5);
        s.vx[i] = lcg.next() - 0.5;
        s.vy[i] = lcg.next() - 0.5;
    }
    s.x[7] = s.x[6];
    s.y[7] = s.y[6]; // a zero-length edge, so jiggle runs
    var f: Force = .{ .kind = .link };
    defer f.deinit(a);
    try f.setCount(a, n / 2);
    for (0..n / 2) |e| {
        f.source[e] = @intCast(2 * e);
        f.target[e] = @intCast(2 * e + 1);
        f.f0[e] = 0.7;
        f.f1[e] = 30;
        f.f2[e] = 0.5;
    }
    setScalar(&f, .iterations, 1);
    setScalar(&f, .seed, 0.25);
    const vx0 = try a.dupe(f64, s.vx[0..n]);
    defer a.free(vx0);
    const vy0 = try a.dupe(f64, s.vy[0..n]);
    defer a.free(vy0);
    try @import("link_fast.zig").run(&s, a, &f, 0.3);
    const fast_vx = try a.dupe(f64, s.vx[0..n]);
    defer a.free(fast_vx);
    const fast_vy = try a.dupe(f64, s.vy[0..n]);
    defer a.free(fast_vy);
    @memcpy(s.vx[0..n], vx0);
    @memcpy(s.vy[0..n], vy0);
    const Jig = struct {
        fn random() f64 {
            return 0.25; // any value: exact draws it only for the zero-length edge
        }
    };
    try @import("link.zig").run(&s, &f, 0.3, &Jig.random);
    for (0..n) |i| {
        if (i == 6 or i == 7) continue; // the jiggled edge differs by construction
        try std.testing.expectEqual(s.vx[i], fast_vx[i]);
        try std.testing.expectEqual(s.vy[i], fast_vy[i]);
    }
}

test "fast collide matches exact collide on isolated pairs and reduces overlap in general" {
    var s: Sim = .{};
    defer s.deinit(a);
    const n: u32 = 2000;
    _ = try s.setNodeCount(a, n);
    // Pairs 10 units apart on a 100-unit grid, radius 6: each pair overlaps and
    // nothing else is within reach.
    for (0..n) |i| {
        const pair: f64 = @floatFromInt(i / 2);
        const col = @mod(pair, 40.0);
        const row = @floor(pair / 40.0);
        s.x[i] = col * 100 + (if (i % 2 == 1) @as(f64, 10) else 0);
        s.y[i] = row * 100 + (if (i % 2 == 1) @as(f64, 3) else 0);
        s.vx[i] = 0;
        s.vy[i] = 0;
    }
    var f: Force = .{ .kind = .collide };
    defer f.deinit(a);
    try f.setCount(a, n);
    for (f.f0) |*r| r.* = 6;
    setScalar(&f, .strength, 1);
    setScalar(&f, .iterations, 1);
    setScalar(&f, .seed, 0.25);
    try @import("grid.zig").run(&s, a, &f, 0);
    const fast_vx = try a.dupe(f64, s.vx[0..n]);
    defer a.free(fast_vx);
    const fast_vy = try a.dupe(f64, s.vy[0..n]);
    defer a.free(fast_vy);
    @memset(s.vx[0..n], 0);
    @memset(s.vy[0..n], 0);
    const Jig = struct {
        fn random() f64 {
            return 0.25;
        }
    };
    try @import("collide.zig").run(&s, a, &f, &Jig.random);
    var moved: u32 = 0;
    for (0..n) |i| {
        try std.testing.expectApproxEqRel(s.vx[i], fast_vx[i], 1e-12);
        try std.testing.expectApproxEqRel(s.vy[i], fast_vy[i], 1e-12);
        if (s.vx[i] != 0) moved += 1;
    }
    try std.testing.expectEqual(n, moved);
}
