//! forceLink, exact mode (TRD, Zig core design: "link, exact mode").
//! Gauss-Seidel over the edge list in user order, as d3-force's link.js.

const Sim = @import("sim.zig").Sim;
const Force = @import("force.zig").Force;
const rng = @import("rng.zig");

pub fn run(s: *Sim, f: *const Force, alpha: f64, random: rng.Source) error{BadArgument}!void {
    @setFloatMode(.strict);
    for (f.source[0..f.count], f.target[0..f.count]) |src, tgt| {
        if (src >= s.n or tgt >= s.n) return error.BadArgument;
    }
    const iterations = f.scalar(.iterations);
    const xs = s.x;
    const ys = s.y;
    const vxs = s.vx;
    const vys = s.vy;
    var k: f64 = 0;
    while (k < iterations) : (k += 1) {
        for (0..f.count) |i| {
            const src = f.source[i];
            const tgt = f.target[i];
            // `a || jiggle(random)` falls through on 0, -0 and NaN.
            var x = xs[tgt] + vxs[tgt] - xs[src] - vxs[src];
            if (x == 0 or x != x) x = rng.jiggle(random);
            var y = ys[tgt] + vys[tgt] - ys[src] - vys[src];
            if (y == 0 or y != y) y = rng.jiggle(random);
            var l = @sqrt(x * x + y * y);
            l = (l - f.f1[i]) / l * alpha * f.f0[i];
            x *= l;
            y *= l;
            var b = f.f2[i];
            vxs[tgt] -= x * b;
            vys[tgt] -= y * b;
            b = 1 - b;
            vxs[src] += x * b;
            vys[src] += y * b;
        }
    }
}
