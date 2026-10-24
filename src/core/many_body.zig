//! forceManyBody, exact mode (TRD, Zig core design: "manyBody, exact mode").
//! d3-force's manyBody.js with node objects replaced by indices and the
//! `visit` callback inlined into a loop over an explicit stack. Statement
//! order is d3's, so every f64 sum sees the same operands in the same order.
//!
//! On the thread pool (TRD 3, Kernels: "Exact mode") accumulate runs one job
//! per subtree, then the top cells on the main thread; the traversal runs in
//! chunks of nodes in Morton order. A node that meets a zero delta, where d3
//! would draw from `random`, is abandoned unwritten and flagged; afterwards
//! the main thread reruns the flagged nodes in ascending index order with the
//! real `random`, which draws what d3 draws, in d3's order, because nodes that
//! never jiggle never draw.

const std = @import("std");
const Allocator = std.mem.Allocator;
const Sim = @import("sim.zig").Sim;
const Force = @import("force.zig").Force;
const tree_mod = @import("tree.zig");
const Tree = tree_mod.Tree;
const Cell = tree_mod.Cell;
const NONE = tree_mod.NONE;
const rng = @import("rng.zig");
const pool = @import("pool.zig");

/// Nodes per traversal chunk: about 33 µs on the phone's fastest core.
const CHUNK: u32 = 32;

/// Nodes flagged per thread in the last traversal, a line apart.
var flagged: [pool.MAX_WORKERS + 1][16]u32 = .{.{0} ** 16} ** (pool.MAX_WORKERS + 1);

pub fn run(s: *Sim, a: Allocator, f: *const Force, alpha: f64, random: rng.Source) !void {
    try s.buildTree(a, false);
    const t = &s.tree;
    if (t.root == NONE) return;

    // accumulate, via visitAfter. Cells are numbered in preorder, so every
    // child has a larger index than its parent and a reverse sweep is a valid
    // post-order; only the 0..3 order within a cell affects the sums. A job's
    // subtree is one contiguous range; the top cells come after every job.
    const acc = Acc{ .t = t, .xs = s.x, .ys = s.y, .strengths = f.f0 };
    try pool.parallelFor(&acc, t.n_jobs, Acc.job);
    var k = t.n_tops;
    while (k > 0) {
        k -= 1;
        acc.cell(t.tops[k]);
    }

    if (s.flags.len < s.n) {
        s.flags = try a.realloc(s.flags, s.cap);
        @memset(s.flags, 0);
    }
    const size = pool.chunkSize(CHUNK);
    const tr = Trav{
        .cells = t.cells[0..t.len],
        .root = t.root,
        .perm = t.perm,
        .rest = t.rest,
        .t = t,
        .xs = s.x,
        .ys = s.y,
        .vxs = s.vx,
        .vys = s.vy,
        .strengths = f.f0,
        .theta2 = f.scalar(.theta2),
        .distance_min2 = f.scalar(.distance_min2),
        .distance_max2 = f.scalar(.distance_max2),
        .alpha = alpha,
        .m = t.m,
        .n = s.n,
        .size = size,
        .flags = s.flags,
    };
    for (&flagged) |*row| row[0] = 0;
    try pool.parallelFor(&tr, pool.chunks(s.n, size), Trav.chunk);
    var total: u32 = 0;
    for (flagged) |row| total += row[0];
    if (total == 0) return;
    const stack = t.walkStack(0);
    for (0..s.n) |i| {
        if (s.flags[i] == 0) continue;
        s.flags[i] = 0;
        _ = tr.node(false, @intCast(i), stack, random);
    }
}

const Acc = struct {
    t: *Tree,
    xs: []const f64,
    ys: []const f64,
    strengths: []const f64,

    fn job(p: *const Acc, j: u32, _: u32) void {
        const job_ = p.t.jobs[j];
        var c = job_.base + job_.cells;
        while (c > job_.base) {
            c -= 1;
            p.cell(c);
        }
    }

    fn cell(p: *const Acc, c: u32) void {
        @setFloatMode(.strict);
        const cells = p.t.cells;
        const perm = p.t.perm;
        const quad = &cells[c];
        var strength: f64 = 0;
        if (!quad.isLeaf()) {
            var weight: f64 = 0;
            var x: f64 = 0;
            var y: f64 = 0;
            for (quad.child) |ch| if (ch != NONE) {
                const q = &cells[ch];
                const w = @abs(q.value);
                if (w > 0) { // `c = Math.abs(q.value)` is truthy: not 0, not NaN
                    strength += q.value;
                    weight += w;
                    x += w * q.x;
                    y += w * q.y;
                }
            };
            quad.x = x / weight;
            quad.y = y / weight;
        } else {
            // The leaf chain runs head first, in descending index order.
            const head = perm[quad.first + quad.count - 1];
            quad.x = p.xs[head];
            quad.y = p.ys[head];
            var k = quad.first + quad.count;
            while (k > quad.first) {
                k -= 1;
                strength += p.strengths[perm[k]];
            }
        }
        quad.value = strength;
    }
};

const Trav = struct {
    cells: []const Cell,
    root: u32,
    perm: []const u32,
    rest: []const u32,
    t: *const Tree,
    xs: []const f64,
    ys: []const f64,
    vxs: []f64,
    vys: []f64,
    strengths: []const f64,
    theta2: f64,
    distance_min2: f64,
    distance_max2: f64,
    alpha: f64,
    m: u32,
    n: u32,
    size: u32,
    flags: []u8,

    /// Positions [lo, hi) of the node order: perm (Morton order), then the
    /// nodes with a NaN coordinate.
    fn chunk(p: *const Trav, c: u32, tid: u32) void {
        const r = pool.range(p.n, p.size, c);
        const stack = p.t.walkStack(tid);
        var count: u32 = 0;
        for (r.lo..r.hi) |pos| {
            const i = if (pos < p.m) p.perm[pos] else p.rest[pos - p.m];
            if (!p.node(true, i, stack, undefined)) {
                p.flags[i] = 1;
                count += 1;
            }
        }
        if (count != 0) flagged[tid][0] += count;
    }

    /// d3's traversal for node i. With `record`, it returns false without
    /// writing anything at the first point where d3 would call `random`.
    fn node(p: *const Trav, record: bool, i: u32, stack: []u32, random: rng.Source) bool {
        @setFloatMode(.strict);
        const cells = p.cells;
        const perm = p.perm;
        const theta2 = p.theta2;
        const distance_min2 = p.distance_min2;
        const distance_max2 = p.distance_max2;
        const alpha = p.alpha;
        const nx = p.xs[i];
        const ny = p.ys[i];
        var vx = p.vxs[i];
        var vy = p.vys[i];
        var sp: usize = 1;
        stack[0] = p.root;
        while (sp > 0) {
            sp -= 1;
            const quad = &cells[stack[sp]];
            const value = quad.value;
            if (!(value != 0 and value == value)) continue; // `!quad.value`

            var x = quad.x - nx;
            var y = quad.y - ny;
            const w = quad.x1 - quad.x0;
            var l = x * x + y * y;

            // Barnes-Hut approximation.
            if (w * w / theta2 < l) {
                if (l < distance_max2) {
                    if (record and (x == 0 or y == 0)) return false;
                    if (x == 0) {
                        x = rng.jiggle(random);
                        l += x * x;
                    }
                    if (y == 0) {
                        y = rng.jiggle(random);
                        l += y * y;
                    }
                    if (l < distance_min2) l = @sqrt(distance_min2 * l);
                    vx += x * value * alpha / l;
                    vy += y * value * alpha / l;
                }
                continue;
            }

            if (!quad.isLeaf()) {
                // `return` (undefined): descend, pushing children 3..0.
                var q: usize = 4;
                while (q > 0) {
                    q -= 1;
                    const ch = quad.child[q];
                    if (ch != NONE) {
                        stack[sp] = ch;
                        sp += 1;
                    }
                }
                continue;
            }
            if (l >= distance_max2) continue;

            // Leaf: process points directly.
            const head = perm[quad.first + quad.count - 1];
            if (head != i or quad.count > 1) {
                if (record and (x == 0 or y == 0)) return false;
                if (x == 0) {
                    x = rng.jiggle(random);
                    l += x * x;
                }
                if (y == 0) {
                    y = rng.jiggle(random);
                    l += y * y;
                }
                if (l < distance_min2) l = @sqrt(distance_min2 * l);
            }
            var k = quad.first + quad.count;
            while (k > quad.first) {
                k -= 1;
                const j = perm[k];
                if (j != i) {
                    const wj = p.strengths[j] * alpha / l;
                    vx += x * wj;
                    vy += y * wj;
                }
            }
        }
        p.vxs[i] = vx;
        p.vys[i] = vy;
        return true;
    }
};
