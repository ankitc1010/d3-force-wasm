//! forceCollide, exact mode (TRD, Zig core design: "collide, exact mode").
//! d3-force's collide.js over indices. Pushes write the other node's
//! velocity and later nodes read it, so the pass is sequential; only the tree
//! build and the radius sweep run on the thread pool, and from the second
//! iteration on not even those, so no parallel phase follows a random draw
//! (TRD 3, Facade: "Failure").

const std = @import("std");
const Allocator = std.mem.Allocator;
const Sim = @import("sim.zig").Sim;
const Force = @import("force.zig").Force;
const NONE = @import("tree.zig").NONE;
const rng = @import("rng.zig");
const pool = @import("pool.zig");
const Tree = @import("tree.zig").Tree;

pub fn run(s: *Sim, a: Allocator, f: *const Force, random: rng.Source) !void {
    @setFloatMode(.strict);
    const radii = f.f0;
    const strength = f.scalar(.strength);
    const iterations = f.scalar(.iterations);
    const xs = s.x;
    const ys = s.y;
    const vxs = s.vx;
    const vys = s.vy;

    defer pool.setInline(false);
    var k: f64 = 0;
    while (k < iterations) : (k += 1) {
        if (k > 0) pool.setInline(true);
        // Tree on (x + vx, y + vy), then prepare via visitAfter: by subtree,
        // then the top cells, as in many_body.zig.
        try s.buildTree(a, true);
        const t = &s.tree;
        if (t.root == NONE) continue;
        const perm = t.perm;
        const cells = t.cells[0..t.len];
        const prep = Prep{ .t = t, .radii = radii };
        try pool.parallelFor(&prep, t.n_jobs, Prep.job);
        var top = t.n_tops;
        while (top > 0) {
            top -= 1;
            prep.cell(t.tops[top]);
        }

        const stack = t.walkStack(0);
        for (0..s.n) |i| {
            const ri = radii[i];
            const ri2 = ri * ri;
            const xi = xs[i] + vxs[i];
            const yi = ys[i] + vys[i];
            var sp: usize = 1;
            stack[0] = t.root;
            while (sp > 0) {
                sp -= 1;
                const quad = &cells[stack[sp]];
                var rj = quad.r;
                var r = ri + rj;
                if (quad.isLeaf()) {
                    const j = perm[quad.first + quad.count - 1];
                    if (j > i) {
                        var x = xi - xs[j] - vxs[j];
                        var y = yi - ys[j] - vys[j];
                        var l = x * x + y * y;
                        if (l < r * r) {
                            if (x == 0) {
                                x = rng.jiggle(random);
                                l += x * x;
                            }
                            if (y == 0) {
                                y = rng.jiggle(random);
                                l += y * y;
                            }
                            l = @sqrt(l);
                            l = (r - l) / l * strength;
                            x *= l;
                            y *= l;
                            rj *= rj;
                            r = rj / (ri2 + rj);
                            vxs[i] += x * r;
                            vys[i] += y * r;
                            r = 1 - r;
                            vxs[j] -= x * r;
                            vys[j] -= y * r;
                        }
                    }
                    continue;
                }
                if (quad.x0 > xi + r or quad.x1 < xi - r or quad.y0 > yi + r or quad.y1 < yi - r) continue;
                var q: usize = 4;
                while (q > 0) {
                    q -= 1;
                    const ch = quad.child[q];
                    if (ch != NONE) {
                        stack[sp] = ch;
                        sp += 1;
                    }
                }
            }
        }
    }
}

const Prep = struct {
    t: *Tree,
    radii: []const f64,

    fn job(p: *const Prep, j: u32, _: u32) void {
        const job_ = p.t.jobs[j];
        var c = job_.base + job_.cells;
        while (c > job_.base) {
            c -= 1;
            p.cell(c);
        }
    }

    fn cell(p: *const Prep, c: u32) void {
        const cells = p.t.cells;
        const quad = &cells[c];
        if (quad.isLeaf()) {
            // `quad.data` is the chain head; the rest of the chain is never read.
            quad.r = p.radii[p.t.perm[quad.first + quad.count - 1]];
        } else {
            quad.r = 0;
            for (quad.child) |ch| if (ch != NONE and cells[ch].r > quad.r) {
                quad.r = cells[ch].r;
            };
        }
    }
};
