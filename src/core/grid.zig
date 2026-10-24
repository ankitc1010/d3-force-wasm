//! forceCollide, fast mode (TRD 2, "Fast collide"): a uniform grid with cell
//! size 2 · r_max over the shifted positions x + vx, then a Jacobi sweep in
//! which each node scans its 3 × 3 neighbourhood and adds only its own share
//! of each push, r_j² / (r_i² + r_j²). Node j adds the complementary share on
//! its own turn, so every pair is evaluated twice and no node writes another's
//! velocity. Jiggle for a coincident pair is a hash of the unordered pair and
//! the tick seed, negated on the higher-indexed side.
//!
//! On the thread pool (TRD 3, Kernels: "Fast mode") the bounds pass runs in
//! static chunks, binning is the shared radix sort on cell ids, and the sweep
//! runs in dynamic chunks. The sort's input runs in descending node order, so
//! each cell lists its nodes high index first, exactly as the counting sort of
//! 0.2.0 filled them, and the sweep adds pushes in the same order.

const std = @import("std");
const Allocator = std.mem.Allocator;
const Sim = @import("sim.zig").Sim;
const Force = @import("force.zig").Force;
const hash = @import("hash.zig");
const pool = @import("pool.zig");
const sort = @import("sort.zig");

/// Nodes per chunk of the streaming passes and of the sweep.
const CHUNK: u32 = 16384;
const SWEEP_CHUNK: u32 = 256;

pub const Grid = struct {
    start: []u32 = &.{},
    /// Nodes by cell, and the sort's keys (cell ids) and scratch. The keys
    /// are u64 so the grid shares the tree's sort instantiation.
    items: []u32 = &.{},
    items_tmp: []u32 = &.{},
    keys: []u64 = &.{},
    keys_tmp: []u64 = &.{},
    hist: []u32 = &.{},
    cell_of: []u32 = &.{},
    rows: []Row = &.{},

    pub fn deinit(g: *Grid, a: Allocator) void {
        inline for (.{ "start", "items", "items_tmp", "keys", "keys_tmp", "hist", "cell_of", "rows" }) |name| a.free(@field(g, name));
        g.* = .{};
    }
};

/// One chunk's bounds of the shifted positions, largest radius, point count.
const Row = struct { x0: f64, y0: f64, x1: f64, y1: f64, rmax: f64, m: u32 };

const NO_CELL = std.math.maxInt(u32);

const Pass = struct {
    s: *Sim,
    g: *Grid,
    radii: []const f64,
    strength: f64,
    seed: u64,
    size: u32,
    x0: f64 = 0,
    y0: f64 = 0,
    inv_h: f64 = 0,
    gx: u32 = 0,
    gy: u32 = 0,
    cells: u32 = 0,
    m: u32 = 0,

    /// Shifted positions, bounds and the largest radius.
    fn bounds(p: *const Pass, c: u32, _: u32) void {
        @setFloatMode(.strict);
        const s = p.s;
        const r = pool.range(s.n, p.size, c);
        var x0 = std.math.inf(f64);
        var y0 = std.math.inf(f64);
        var x1 = -std.math.inf(f64);
        var y1 = -std.math.inf(f64);
        var rmax: f64 = 0;
        var m: u32 = 0;
        for (r.lo..r.hi) |i| {
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
            const rad = p.radii[i];
            if (rad > rmax) rmax = rad;
        }
        p.g.rows[c] = .{ .x0 = x0, .y0 = y0, .x1 = x1, .y1 = y1, .rmax = rmax, .m = m };
    }

    /// Sort input in descending node order: position k holds node n − 1 − k,
    /// keyed by its cell, or by `cells` (sorting last) without one.
    fn bin(p: *const Pass, c: u32, _: u32) void {
        const s = p.s;
        const g = p.g;
        const r = pool.range(s.n, p.size, c);
        for (r.lo..r.hi) |k| {
            const i = s.n - 1 - @as(u32, @intCast(k));
            var cell: u32 = p.cells;
            if (s.px[i] == s.px[i] and s.py[i] == s.py[i]) {
                const cx: u32 = @intFromFloat(@floor((s.px[i] - p.x0) * p.inv_h));
                const cy: u32 = @intFromFloat(@floor((s.py[i] - p.y0) * p.inv_h));
                cell = cy * p.gx + cx;
            }
            g.cell_of[i] = if (cell == p.cells) NO_CELL else cell;
            g.keys[k] = cell;
            g.items[k] = i;
        }
    }

    /// start[c] = the first position of cell c: every boundary between two
    /// keys in sorted order sets the starts of the cells in between.
    fn starts(p: *const Pass, c: u32, _: u32) void {
        const g = p.g;
        const n = p.s.n;
        const r = pool.range(n, p.size, c);
        for (r.lo..r.hi) |k| {
            const lo: u32 = if (k == 0) 0 else @intCast(g.keys[k - 1] + 1);
            const hi: u32 = @intCast(@min(g.keys[k], p.cells));
            if (k == 0 or g.keys[k] != g.keys[k - 1]) {
                var cell = lo;
                while (cell <= hi) : (cell += 1) g.start[cell] = @intCast(k);
            }
        }
    }

    fn sweep(p: *const Pass, c: u32, _: u32) void {
        @setFloatMode(.strict);
        const s = p.s;
        const g = p.g;
        const radii = p.radii;
        const gx = p.gx;
        const gy = p.gy;
        const start = g.start;
        const r = pool.range(s.n, p.size, c);
        for (r.lo..r.hi) |i| {
            const ci = g.cell_of[i];
            if (ci == NO_CELL) continue;
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
                    const cell = cy * gx + cx;
                    for (g.items[start[cell]..start[cell + 1]]) |j| {
                        if (j == i) continue;
                        const rj = radii[j];
                        var rr = ri + rj;
                        var x = xi - s.px[j];
                        var y = yi - s.py[j];
                        var l = x * x + y * y;
                        if (l < rr * rr) {
                            if (x == 0 or y == 0) {
                                // Same displacement for both ends: hash the
                                // unordered pair, flip the sign on the higher.
                                const lo = @min(i, j);
                                const hi = @max(i, j);
                                const sign: f64 = if (i == lo) 1 else -1;
                                if (x == 0) {
                                    x = sign * hash.jiggle(p.seed, @intCast(lo), @intCast(hi), 0);
                                    l += x * x;
                                }
                                if (y == 0) {
                                    y = sign * hash.jiggle(p.seed, @intCast(lo), @intCast(hi), 1);
                                    l += y * y;
                                }
                            }
                            l = @sqrt(l);
                            l = (rr - l) / l * p.strength;
                            x *= l;
                            y *= l;
                            rr = rj * rj / (ri2 + rj * rj);
                            vx += x * rr;
                            vy += y * rr;
                        }
                    }
                }
            }
            s.vx[i] = vx;
            s.vy[i] = vy;
        }
    }
};

pub fn run(s: *Sim, a: Allocator, f: *const Force, alpha: f64) !void {
    @setFloatMode(.strict);
    _ = alpha; // collide ignores alpha, as in d3
    const n = s.n;
    const g = &s.grid;
    if (g.items.len < n) {
        inline for (.{ "items", "items_tmp", "keys", "keys_tmp", "cell_of" }) |name| {
            @field(g, name) = try a.realloc(@field(g, name), s.cap);
        }
    }
    const size = pool.chunkSize(CHUNK);
    const n_chunks = pool.chunks(n, size);
    if (g.rows.len < n_chunks) g.rows = try a.realloc(g.rows, n_chunks);
    var p = Pass{
        .s = s,
        .g = g,
        .radii = f.f0,
        .strength = f.scalar(.strength),
        .seed = hash.seedFrom(f.scalar(.seed)),
        .size = size,
    };

    const iterations = f.scalar(.iterations);
    var k: f64 = 0;
    while (k < iterations) : (k += 1) {
        // Rows combined in chunk order with the serial scan's comparisons.
        try pool.parallelFor(&p, n_chunks, Pass.bounds);
        var x0 = std.math.inf(f64);
        var y0 = std.math.inf(f64);
        var x1 = -std.math.inf(f64);
        var y1 = -std.math.inf(f64);
        var rmax: f64 = 0;
        var m: u32 = 0;
        for (g.rows[0..n_chunks]) |row| {
            if (row.m == 0) continue;
            m += row.m;
            if (row.x0 < x0) x0 = row.x0;
            if (row.x1 > x1) x1 = row.x1;
            if (row.y0 < y0) y0 = row.y0;
            if (row.y1 > y1) y1 = row.y1;
            if (row.rmax > rmax) rmax = row.rmax;
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
        const cells = gx * gy;
        if (g.start.len < cells + 1) g.start = try a.realloc(g.start, cells + 1);
        p.x0 = x0;
        p.y0 = y0;
        p.inv_h = 1 / h;
        p.gx = gx;
        p.gy = gy;
        p.cells = cells;
        p.m = m;

        try pool.parallelFor(&p, n_chunks, Pass.bin);
        const bytes: u32 = if (cells < 1 << 8) 1 else if (cells < 1 << 16) 2 else if (cells < 1 << 24) 3 else 4;
        try sort.sort(u64, a, &g.keys, &g.items, &g.keys_tmp, &g.items_tmp, &g.hist, n, bytes);
        try pool.parallelFor(&p, n_chunks, Pass.starts);
        // Cells after the last key start at m, the end of the binned nodes.
        var cell: u32 = if (g.keys[n - 1] == cells) cells + 1 else @intCast(g.keys[n - 1] + 1);
        while (cell <= cells) : (cell += 1) g.start[cell] = m;
        g.start[cells] = m;

        const sweep = Pass{
            .s = p.s,
            .g = p.g,
            .radii = p.radii,
            .strength = p.strength,
            .seed = p.seed,
            .size = pool.chunkSize(SWEEP_CHUNK),
            .x0 = p.x0,
            .y0 = p.y0,
            .inv_h = p.inv_h,
            .gx = gx,
            .gy = gy,
            .cells = cells,
            .m = m,
        };
        try pool.parallelFor(&sweep, pool.chunks(n, sweep.size), Pass.sweep);
    }
}
