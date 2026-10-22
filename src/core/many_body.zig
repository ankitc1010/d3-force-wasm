//! forceManyBody, exact mode (TRD, Zig core design: "manyBody, exact mode").
//! d3-force's manyBody.js with node objects replaced by indices and the
//! `visit` callback inlined into a loop over an explicit stack. Statement
//! order is d3's, so every f64 sum sees the same operands in the same order.

const std = @import("std");
const Allocator = std.mem.Allocator;
const Sim = @import("sim.zig").Sim;
const Force = @import("force.zig").Force;
const NONE = @import("tree.zig").NONE;
const rng = @import("rng.zig");

pub fn run(s: *Sim, a: Allocator, f: *const Force, alpha: f64, random: rng.Source) !void {
    @setFloatMode(.strict);
    try s.buildTree(a, false);
    const t = &s.tree;
    if (t.root == NONE) return;
    const strengths = f.f0;
    const xs = s.x;
    const ys = s.y;
    const perm = t.perm;
    const cells = t.cells[0..t.len];

    // accumulate, via visitAfter. Cells are numbered in preorder, so every
    // child has a larger index than its parent and a reverse sweep is a valid
    // post-order; only the 0..3 order within a cell affects the sums.
    var c = cells.len;
    while (c > 0) {
        c -= 1;
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
            quad.x = xs[head];
            quad.y = ys[head];
            var k = quad.first + quad.count;
            while (k > quad.first) {
                k -= 1;
                strength += strengths[perm[k]];
            }
        }
        quad.value = strength;
    }

    const theta2 = f.scalar(.theta2);
    const distance_min2 = f.scalar(.distance_min2);
    const distance_max2 = f.scalar(.distance_max2);
    const stack = t.vstack;

    for (0..s.n) |i| {
        const nx = xs[i];
        const ny = ys[i];
        var vx = s.vx[i];
        var vy = s.vy[i];
        var sp: usize = 1;
        stack[0] = t.root;
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
                    const wj = strengths[j] * alpha / l;
                    vx += x * wj;
                    vy += y * wj;
                }
            }
        }
        s.vx[i] = vx;
        s.vy[i] = vy;
    }
}
