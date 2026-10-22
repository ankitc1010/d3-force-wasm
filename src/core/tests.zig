//! Zig unit tests for the core, run with `zig build test` in ReleaseSafe.
//! Structural parity against d3-quadtree traces lives in test/tree-test.js.

const std = @import("std");
const tree_mod = @import("tree.zig");
const Tree = tree_mod.Tree;
const NONE = tree_mod.NONE;
const a = std.testing.allocator;

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
