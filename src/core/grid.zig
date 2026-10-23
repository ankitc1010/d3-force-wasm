//! forceCollide, fast mode (TRD 2, "Fast collide"): a uniform grid with cell
//! size 2 · r_max over the shifted positions x + vx, built by counting sort,
//! then a Jacobi sweep in which each node scans its 3 × 3 neighbourhood and
//! adds only its own share of each push, r_j² / (r_i² + r_j²). Node j adds the
//! complementary share on its own turn, so every pair is evaluated twice and
//! no node writes another's velocity. Jiggle for a coincident pair is a hash of
//! the unordered pair and the tick seed, negated on the higher-indexed side.

const std = @import("std");
const Allocator = std.mem.Allocator;
const Sim = @import("sim.zig").Sim;
const Force = @import("force.zig").Force;
const hash = @import("hash.zig");

pub const Grid = struct {
    start: []u32 = &.{},
    items: []u32 = &.{},
    cell_of: []u32 = &.{},

    pub fn deinit(g: *Grid, a: Allocator) void {
        a.free(g.start);
        a.free(g.items);
        a.free(g.cell_of);
        g.* = .{};
    }
};

pub fn run(s: *Sim, a: Allocator, f: *const Force, alpha: f64) !void {
    @setFloatMode(.strict);
    _ = alpha; // collide ignores alpha, as in d3
    const n = s.n;
    const radii = f.f0;
    const strength = f.scalar(.strength);
    const iterations = f.scalar(.iterations);
    const seed = hash.seedFrom(f.scalar(.seed));
    const g = &s.grid;
    if (g.items.len < n) {
        g.items = try a.realloc(g.items, n);
        g.cell_of = try a.realloc(g.cell_of, n);
    }

    var k: f64 = 0;
    while (k < iterations) : (k += 1) {
        // Shifted positions, bounds and the largest radius.
        var x0 = std.math.inf(f64);
        var y0 = std.math.inf(f64);
        var x1 = -std.math.inf(f64);
        var y1 = -std.math.inf(f64);
        var rmax: f64 = 0;
        var m: u32 = 0;
        for (0..n) |i| {
            const x = s.x[i] + s.vx[i];
            const y = s.y[i] + s.vy[i];
            s.px[i] = x;
            s.py[i] = y;
            if (x != x or y != y) continue;
            m += 1;
            if (x < x0) x0 = x;
            if (x > x1) x1 = x;
            if (y < y0) y0 = y;
            if (y > y1) y1 = y;
            const r = radii[i];
            if (r > rmax) rmax = r;
        }
        if (m < 2 or !(rmax > 0)) continue;
        var h = 2 * rmax;
        var gx: u32 = @intFromFloat(@floor((x1 - x0) / h) + 1);
        var gy: u32 = @intFromFloat(@floor((y1 - y0) / h) + 1);
        // At most 4n cells: coarsen when radii are tiny next to the extent.
        while (@as(u64, gx) * gy > 4 * @as(u64, n) + 16) {
            h *= 2;
            gx = @intFromFloat(@floor((x1 - x0) / h) + 1);
            gy = @intFromFloat(@floor((y1 - y0) / h) + 1);
        }
        const cells: usize = @as(usize, gx) * gy;
        if (g.start.len < cells + 1) g.start = try a.realloc(g.start, cells + 1);
        const start = g.start[0 .. cells + 1];
        @memset(start, 0);
        const inv_h = 1 / h;
        for (0..n) |i| {
            if (s.px[i] != s.px[i] or s.py[i] != s.py[i]) {
                g.cell_of[i] = std.math.maxInt(u32);
                continue;
            }
            const cx: u32 = @intFromFloat(@floor((s.px[i] - x0) * inv_h));
            const cy: u32 = @intFromFloat(@floor((s.py[i] - y0) * inv_h));
            const c = cy * gx + cx;
            g.cell_of[i] = c;
            start[c + 1] += 1;
        }
        for (1..cells + 1) |c| start[c] += start[c - 1];
        for (0..n) |i| {
            const c = g.cell_of[i];
            if (c == std.math.maxInt(u32)) continue;
            g.items[start[c + 1] - 1] = @intCast(i);
            start[c + 1] -= 1;
        }
        // start[c + 1] is now the first item of cell c: shift left so
        // start[c]..start[c + 1] is cell c.
        for (0..cells) |c| start[c] = start[c + 1];
        start[cells] = m;

        for (0..n) |i| {
            const ci = g.cell_of[i];
            if (ci == std.math.maxInt(u32)) continue;
            const ri = radii[i];
            const ri2 = ri * ri;
            const xi = s.px[i];
            const yi = s.py[i];
            var vx = s.vx[i];
            var vy = s.vy[i];
            const cxi = ci % gx;
            const cyi = ci / gx;
            const xa = if (cxi > 0) cxi - 1 else 0;
            const xb = @min(cxi + 1, gx - 1);
            const ya = if (cyi > 0) cyi - 1 else 0;
            const yb = @min(cyi + 1, gy - 1);
            var cy = ya;
            while (cy <= yb) : (cy += 1) {
                var cx = xa;
                while (cx <= xb) : (cx += 1) {
                    const c = cy * gx + cx;
                    for (g.items[start[c]..start[c + 1]]) |j| {
                        if (j == i) continue;
                        const rj = radii[j];
                        var r = ri + rj;
                        var x = xi - s.px[j];
                        var y = yi - s.py[j];
                        var l = x * x + y * y;
                        if (l < r * r) {
                            if (x == 0 or y == 0) {
                                // Same displacement for both ends: hash the
                                // unordered pair, flip the sign on the higher.
                                const lo = @min(i, j);
                                const hi = @max(i, j);
                                const sign: f64 = if (i == lo) 1 else -1;
                                if (x == 0) {
                                    x = sign * hash.jiggle(seed, @intCast(lo), @intCast(hi), 0);
                                    l += x * x;
                                }
                                if (y == 0) {
                                    y = sign * hash.jiggle(seed, @intCast(lo), @intCast(hi), 1);
                                    l += y * y;
                                }
                            }
                            l = @sqrt(l);
                            l = (r - l) / l * strength;
                            x *= l;
                            y *= l;
                            r = rj * rj / (ri2 + rj * rj);
                            vx += x * r;
                            vy += y * r;
                        }
                    }
                }
            }
            s.vx[i] = vx;
            s.vy[i] = vy;
        }
    }
}
