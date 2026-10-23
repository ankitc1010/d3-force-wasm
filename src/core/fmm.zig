//! forceManyBody, fast mode (TRD 2, "Fast many-body kernel: O(n) by fast
//! multipole"). A dual-tree fast multipole method over complex expansions of
//!     Φ'(z) = Σ_j s_j / (z − z_j),
//! for which d3's update is Δv_i = −α · conj(Φ'(z_i)). The tree is cut from a
//! quantised Morton sort (tree.prepareFast); cells are stored in level order
//! with children contiguous, one 48-byte record per cell so a traversal visit
//! touches one cache line per cell. Positions are scaled to the root cell so
//! every coefficient is O(Σ|s|) whatever the coordinate magnitude; Φ' scales
//! back by 1 / width. Near-field pairs use d3's own pair formula, including
//! distanceMin, distanceMax and jiggle, with jiggle drawn from hash.zig.
//!
//! The hot loops are vectorised by hand (two f64 lanes) rather than with a
//! relaxed float mode, which would also let the compiler assume away the NaN
//! and Infinity cases d3's semantics depend on. No @mulAdd: wasm has no fused
//! multiply-add and would call a software routine.

const std = @import("std");
const Allocator = std.mem.Allocator;
const Sim = @import("sim.zig").Sim;
const Force = @import("force.zig").Force;
const tree_mod = @import("tree.zig");
const hash = @import("hash.zig");
const clock = @import("clock.zig");

pub const MAX_ORDER: u32 = 24;
pub const DEFAULT_ORDER: u32 = 8;
pub const DEFAULT_OPENING: f64 = 1.4;
/// Below this node count fast mode runs the exact kernel (TRD 2, crossover).
pub const MIN_N: u32 = 2000;
/// Leaf capacity `s`. A variable so the native benchmark can sweep it; the
/// facade never changes it.
pub var LEAF: u32 = 32;
/// Key resolution of prepareFast: 16 levels.
const LEVELS: u32 = 16;
/// Two cells closer than this (in root-cell units) are never expanded; the
/// inverse powers would overflow.
const MIN_SEP2: f64 = 1e-28;

const V = @Vector(2, f64);

/// Interaction counters and phase timers for the native benchmark
/// (src/core/bench.zig); a few increments per cell pair.
pub const Stats = struct { m2l: u64 = 0, p2p_calls: u64 = 0, p2p_pairs: u64 = 0, visits: u64 = 0 };
pub var stats: Stats = .{};
/// Nanoseconds per phase of the last run: cells, geometry, upward, traversal,
/// downward, prepare (Morton keys + sort), coefficient reset.
pub var phase_ns: [8]u64 = .{0} ** 8;
/// Benchmark-only switches to isolate the two traversal costs.
pub var skip_m2l = false;
pub var skip_p2p = false;

pub const Cell = extern struct {
    cx: f64,
    cy: f64,
    r: f64,
    first: u32,
    count: u32,
    child0: u32,
    nchild: u32,
    depth: u32,
    _pad: u32 = 0,
};

pub const Fmm = struct {
    len: u32 = 0,
    cap: u32 = 0,
    cells: []Cell = &.{},
    /// Points in Morton order: scaled positions, raw positions and strength,
    /// so the near field and the leaf operators stream through memory.
    ux: []f64 = &.{},
    uy: []f64 = &.{},
    px: []f64 = &.{},
    py: []f64 = &.{},
    ps: []f64 = &.{},
    pts_cap: u32 = 0,
    /// Bounding box scratch (scaled), only used while computing geometry.
    bx0: []f64 = &.{},
    by0: []f64 = &.{},
    bx1: []f64 = &.{},
    by1: []f64 = &.{},
    /// Expansions: (p + 1) complex numbers per cell in planar layout
    /// ([re_0..re_p][im_0..im_p]), 16-byte aligned, so the inner loops of
    /// M2L vectorise over k without lane swizzles.
    m: []align(16) f64 = &.{},
    l: []align(16) f64 = &.{},
    coef_cap: usize = 0,
    /// Binomial table C(n, k) for n, k ≤ 2p + 1, row stride `bstride`, and
    /// factorials 0! .. (2p + 1)! for the M2L scaling.
    binom: []f64 = &.{},
    bstride: usize = 0,
    binom_p: u32 = 0,
    fact: [2 * MAX_ORDER + 2]f64 = undefined,

    pub fn deinit(f: *Fmm, a: Allocator) void {
        inline for (.{ "cells", "ux", "uy", "px", "py", "ps", "bx0", "by0", "bx1", "by1", "m", "l", "binom" }) |name| a.free(@field(f, name));
        f.* = .{};
    }

    fn reserveCells(f: *Fmm, a: Allocator, cap: u32) !void {
        if (cap <= f.cap) return;
        inline for (.{ "cells", "bx0", "by0", "bx1", "by1" }) |name| {
            @field(f, name) = try a.realloc(@field(f, name), cap);
        }
        f.cap = cap;
    }

    fn reservePoints(f: *Fmm, a: Allocator, m: u32) !void {
        if (m <= f.pts_cap) return;
        inline for (.{ "ux", "uy", "px", "py", "ps" }) |name| {
            @field(f, name) = try a.realloc(@field(f, name), m);
        }
        f.pts_cap = m;
    }

    fn reserveCoefs(f: *Fmm, a: Allocator, need: usize) !void {
        if (need <= f.coef_cap) return;
        a.free(f.m);
        a.free(f.l);
        f.m = &.{};
        f.l = &.{};
        f.coef_cap = 0;
        f.m = try a.alignedAlloc(f64, .@"16", need);
        f.l = try a.alignedAlloc(f64, .@"16", need);
        f.coef_cap = need;
    }

    fn binomials(f: *Fmm, a: Allocator, p: u32) !void {
        if (f.binom_p == p and f.binom.len > 0) return;
        const nmax: usize = 2 * p + 2;
        f.bstride = nmax;
        f.binom = try a.realloc(f.binom, nmax * nmax);
        @memset(f.binom, 0);
        for (0..nmax) |n| {
            f.binom[n * nmax] = 1;
            for (1..n + 1) |k| {
                f.binom[n * nmax + k] = f.binom[(n - 1) * nmax + k - 1] + (if (k < n) f.binom[(n - 1) * nmax + k] else 0);
            }
        }
        f.fact[0] = 1;
        for (1..nmax) |k| f.fact[k] = f.fact[k - 1] * @as(f64, @floatFromInt(k));
        f.binom_p = p;
    }

    inline fn bin(f: *const Fmm, n: usize, k: usize) f64 {
        return f.binom[n * f.bstride + k];
    }
};

/// Runs the fast kernel. Returns false when the input is not suited to it (a
/// non-finite extent), in which case the caller runs the exact kernel instead.
pub fn run(s: *Sim, a: Allocator, f: *const Force, alpha: f64) !bool {
    const t = &s.tree;
    const n = s.n;
    const t_run = clock.now();
    defer phase_ns[7] = clock.now() - t_run;
    var tick = clock.now();
    if (!try t.prepareFast(a, s.x[0..n], s.y[0..n])) return true;
    phase_ns[5] = clock.now() - tick;
    const e = t.extent;
    const w = e[2] - e[0];
    if (!(w > 0 and w < std.math.inf(f64))) return false;

    var p: u32 = DEFAULT_ORDER;
    const po = f.scalar(.order);
    if (po >= 1 and po <= @as(f64, @floatFromInt(MAX_ORDER))) p = @intFromFloat(po);
    var kappa = f.scalar(.opening);
    if (!(kappa > 1)) kappa = DEFAULT_OPENING;

    var fm = &s.fmm;
    try fm.binomials(a, p);
    tick = clock.now();
    try buildCells(fm, a, t);
    phase_ns[0] = clock.now() - tick;
    const nc: usize = fm.len;
    const stride: usize = 2 * (p + 1);
    tick = clock.now();
    try fm.reserveCoefs(a, nc * stride);
    @memset(fm.m[0 .. nc * stride], 0);
    @memset(fm.l[0 .. nc * stride], 0);
    phase_ns[6] = clock.now() - tick;

    var dmax_scaled: f64 = std.math.inf(f64);
    const dmax2 = f.scalar(.distance_max2);
    if (dmax2 < std.math.inf(f64)) dmax_scaled = @sqrt(dmax2) / w;
    const dmin2 = f.scalar(.distance_min2);
    const dmin_scaled: f64 = if (dmin2 > 0) @sqrt(dmin2) / w else 0;

    // Gather the points into Morton order once (TRD 2: a thread's nodes are
    // spatially close and stream through memory).
    try fm.reservePoints(a, t.m);
    const ox = (e[0] + e[2]) / 2;
    const oy = (e[1] + e[3]) / 2;
    const inv_w = 1 / w;
    for (t.perm[0..t.m], 0..) |i, k| {
        const x = s.x[i];
        const y = s.y[i];
        fm.px[k] = x;
        fm.py[k] = y;
        // Strength times alpha, with NaN strengths contributing nothing (d3's
        // `!quad.value` in effect), so the kernels need neither per pair.
        const st = f.f0[i] * alpha;
        fm.ps[k] = if (st != st) 0 else st;
        fm.ux[k] = (x - ox) * inv_w;
        fm.uy[k] = (y - oy) * inv_w;
    }

    var ctx = Ctx{
        .fm = fm,
        .cells = fm.cells.ptr,
        .perm = t.perm[0..t.m],
        .ux = fm.ux,
        .uy = fm.uy,
        .px = fm.px,
        .py = fm.py,
        .ps = fm.ps,
        .vx = s.vx,
        .vy = s.vy,
        .alpha = alpha,
        .p = p,
        .stride = stride,
        .inv_w = inv_w,
        .mac_far = 2 * kappa - 1,
        .ring = dmin_scaled > 0 or dmax_scaled < std.math.inf(f64),
        .has_dmax = dmax_scaled < std.math.inf(f64),
        .dmax_scaled = dmax_scaled,
        .dmin_scaled = dmin_scaled,
        .dmin2 = dmin2,
        .dmax2 = dmax2,
        .seed = hash.seedFrom(f.scalar(.seed)),
        .dpow = undefined,
    };

    tick = clock.now();
    geometry(&ctx);
    var t1 = clock.now();
    phase_ns[1] = t1 - tick;
    tick = t1;
    upward(&ctx);
    scaleForM2l(&ctx);
    t1 = clock.now();
    phase_ns[2] = t1 - tick;
    tick = t1;
    ctx.interact(0, 0);
    t1 = clock.now();
    phase_ns[3] = t1 - tick;
    tick = t1;
    unscaleAfterM2l(&ctx);
    downward(&ctx);
    phase_ns[4] = clock.now() - tick;
    return true;
}

const Ctx = struct {
    fm: *Fmm,
    cells: [*]Cell,
    perm: []const u32,
    /// Morton-ordered points: scaled, raw, strength (see Fmm).
    ux: []const f64,
    uy: []const f64,
    px: []const f64,
    py: []const f64,
    ps: []const f64,
    vx: []f64,
    vy: []f64,
    alpha: f64,
    p: u32,
    stride: usize,
    inv_w: f64,
    /// MAC: d ≥ mac_far · max(rA, rB) + min(rA, rB), mac_far = 2κ − 1.
    mac_far: f64,
    /// Whether distanceMin or distanceMax need the exact gap of a pair.
    ring: bool,
    has_dmax: bool,
    dmax_scaled: f64,
    /// Pairs that may come closer than distanceMin are always direct, so the
    /// clamp is applied exactly (TRD 2, "d3 semantics kept").
    dmin_scaled: f64,
    dmin2: f64,
    dmax2: f64,
    seed: u64,
    /// Scratch: shift powers for M2M and L2L, planar (see shiftPowers).
    dpow: [2 * (MAX_ORDER + 1)]f64,

    /// Dual-tree traversal (TRD 2, "Traversal"): target A receives from source B.
    fn interact(c: *Ctx, A: u32, B: u32) void {
        stats.visits += 1;
        const ca = &c.cells[A];
        if (A == B) {
            if (ca.nchild == 0) {
                if (!skip_p2p) c.p2pSelf(ca);
            } else {
                const c0 = ca.child0;
                const k = ca.nchild;
                for (0..k) |i| for (0..k) |j| c.interact(c0 + @as(u32, @intCast(i)), c0 + @as(u32, @intCast(j)));
            }
            return;
        }
        const cb = &c.cells[B];
        const ra = ca.r;
        const rb = cb.r;
        const dx = ca.cx - cb.cx;
        const dy = ca.cy - cb.cy;
        const d2 = dx * dx + dy * dy;
        const rmax = @max(ra, rb);
        const rmin = @min(ra, rb);
        const thr = c.mac_far * rmax + rmin;
        if (d2 > MIN_SEP2 and d2 >= thr * thr) {
            // Well separated. A finite distanceMax drops pairs wholly beyond it
            // and opens pairs that straddle the ring; pairs that may come
            // closer than distanceMin are opened too.
            var separated = true;
            if (c.ring) {
                const gap = @sqrt(d2) - ra - rb;
                if (gap >= c.dmax_scaled) return;
                if (gap + 2 * (ra + rb) > c.dmax_scaled or gap < c.dmin_scaled) separated = false;
            }
            if (separated) {
                stats.m2l += 1;
                if (!skip_m2l) c.m2l(A, B, dx, dy);
                return;
            }
        }
        const la = ca.nchild == 0;
        const lb = cb.nchild == 0;
        if (la and lb) {
            if (!skip_p2p) c.p2p(ca, cb);
        } else if (la or (!lb and rb > ra)) {
            const c0 = cb.child0;
            for (0..cb.nchild) |j| c.interact(A, c0 + @as(u32, @intCast(j)));
        } else {
            const c0 = ca.child0;
            for (0..ca.nchild) |i| c.interact(c0 + @as(u32, @intCast(i)), B);
        }
    }

    /// Near field, d3's formula, B's points onto A's points, two sources per
    /// step on f64x2 lanes; zero deltas and NaN strengths take the scalar path.
    fn p2p(c: *Ctx, ca: *const Cell, cb: *const Cell) void {
        stats.p2p_calls += 1;
        stats.p2p_pairs += @as(u64, ca.count) * cb.count;
        if (c.has_dmax) {
            for (ca.first..ca.first + ca.count) |ti| c.target(true, @intCast(ti), cb.first, cb.first + cb.count);
        } else {
            for (ca.first..ca.first + ca.count) |ti| c.target(false, @intCast(ti), cb.first, cb.first + cb.count);
        }
    }

    fn p2pSelf(c: *Ctx, ca: *const Cell) void {
        stats.p2p_calls += 1;
        stats.p2p_pairs += @as(u64, ca.count) * ca.count;
        if (c.has_dmax) {
            for (ca.first..ca.first + ca.count) |ti| c.target(true, @intCast(ti), ca.first, ca.first + ca.count);
        } else {
            for (ca.first..ca.first + ca.count) |ti| c.target(false, @intCast(ti), ca.first, ca.first + ca.count);
        }
    }

    /// One target (at Morton position ti) against the sources at positions
    /// [b0, b1).
    fn target(c: *Ctx, comptime has_dmax: bool, ti: u32, b0: u32, b1: u32) void {
        const i = c.perm[ti];
        const xi = c.px[ti];
        const yi = c.py[ti];
        var vx = c.vx[i];
        var vy = c.vy[i];
        var ax: V = @splat(0);
        var ay: V = @splat(0);
        const zero: V = @splat(0);
        const dmax2: V = @splat(c.dmax2);
        // Four pairs per step with one division: 1 / (l0 l1 l2 l3) times the
        // other three products gives each 1 / l_i. Zero deltas, NaN strengths,
        // the node itself and pairs inside distanceMin take the scalar path.
        var k: u32 = b0;
        while (k + 4 <= b1) : (k += 4) {
            const sa: V = c.ps[k..][0..2].*;
            const sb: V = c.ps[k + 2 ..][0..2].*;
            const xa = @as(V, c.px[k..][0..2].*) - @as(V, @splat(xi));
            const ya = @as(V, c.py[k..][0..2].*) - @as(V, @splat(yi));
            const xb = @as(V, c.px[k + 2 ..][0..2].*) - @as(V, @splat(xi));
            const yb = @as(V, c.py[k + 2 ..][0..2].*) - @as(V, @splat(yi));
            const la = xa * xa + ya * ya;
            const lb = xb * xb + yb * yb;
            // Rare cases take the scalar path: a zero delta component (the
            // product of all four is then 0), a pair inside distanceMin, or
            // the node itself.
            if (@reduce(.Or, xa * ya * xb * yb == zero) or !(@reduce(.Min, @min(la, lb)) >= c.dmin2) or (ti >= k and ti < k + 4)) {
                inline for (0..4) |q| c.pair(ti, k + @as(u32, q), xi, yi, &vx, &vy);
                continue;
            }
            const la_sw = V{ la[1], la[0] };
            const lb_sw = V{ lb[1], lb[0] };
            const pa = la * la_sw; // {l0 l1, l0 l1}
            const pb = lb * lb_sw; // {l2 l3, l2 l3}
            const inv = @as(V, @splat(1)) / (pa * pb);
            var wa = sa * la_sw * pb * inv;
            var wb = sb * lb_sw * pa * inv;
            if (has_dmax) {
                wa = @select(f64, la < dmax2, wa, zero);
                wb = @select(f64, lb < dmax2, wb, zero);
            }
            ax += xa * wa + xb * wb;
            ay += ya * wa + yb * wb;
        }
        while (k < b1) : (k += 1) c.pair(ti, k, xi, yi, &vx, &vy);
        c.vx[i] = vx + @reduce(.Add, ax);
        c.vy[i] = vy + @reduce(.Add, ay);
    }

    /// d3's pair formula for the target at position ti and source at tj.
    fn pair(c: *Ctx, ti: u32, tj: u32, xi: f64, yi: f64, vx: *f64, vy: *f64) void {
        if (tj == ti) return;
        const sj = c.ps[tj];
        var x = c.px[tj] - xi;
        var y = c.py[tj] - yi;
        var l = x * x + y * y;
        if (l >= c.dmax2) return;
        if (x == 0 or y == 0) {
            // Jiggle is a hash of the node ids, so it is order-independent.
            const i = c.perm[ti];
            const j = c.perm[tj];
            if (x == 0) {
                x = hash.jiggle(c.seed, i, j, 0);
                l += x * x;
            }
            if (y == 0) {
                y = hash.jiggle(c.seed, i, j, 1);
                l += y * y;
            }
        }
        if (l < c.dmin2) l = @sqrt(c.dmin2 * l);
        const wj = sj / l; // alpha is folded into ps
        vx.* += x * wj;
        vy.* += y * wj;
    }

    /// Multipole of B to local of A. z0 = cA − cB (dx, dy):
    ///   L_l = (−1)^l Σ_k M_k C(k + l, l) / z0^(k + l + 1)
    ///       = ((−1)^l / l!) Σ_k (M_k / k!) · ((k + l)! / z0^(k + l + 1)).
    /// Between scaleForM2l and unscaleAfterM2l the arrays hold M_k / k! and
    /// Σ_k (M_k / k!) T_(k+l), so this is a contiguous complex correlation with
    /// T_m = m! / z0^(m + 1), no table lookups, on f64x2 lanes.
    fn m2l(c: *Ctx, A: u32, B: u32, dx: f64, dy: f64) void {
        const fm = c.fm;
        const p = c.p;
        const q = p + 1;
        const d2 = dx * dx + dy * dy;
        const ire = dx / d2;
        const iim = -dy / d2;
        var tre: [2 * MAX_ORDER + 1]f64 = undefined;
        var tim: [2 * MAX_ORDER + 1]f64 = undefined;
        var are = ire;
        var aim = iim;
        tre[0] = are;
        tim[0] = aim;
        for (1..2 * p + 1) |m| {
            const nre = are * ire - aim * iim;
            const nim = are * iim + aim * ire;
            are = nre;
            aim = nim;
            tre[m] = are * fm.fact[m];
            tim[m] = aim * fm.fact[m];
        }
        const mre = fm.m[B * c.stride ..][0..q];
        const mim = fm.m[B * c.stride + q ..][0..q];
        const lre = fm.l[A * c.stride ..][0..q];
        const lim = fm.l[A * c.stride + q ..][0..q];
        for (0..q) |l| {
            // Σ_k (M_k / k!) T_(k+l) as a two-lane reduction with FMAs.
            var vre: V = @splat(0);
            var vim: V = @splat(0);
            var k: usize = 0;
            while (k + 2 <= q) : (k += 2) {
                const a: V = mre[k..][0..2].*;
                const b: V = mim[k..][0..2].*;
                const tr: V = tre[l + k ..][0..2].*;
                const ti: V = tim[l + k ..][0..2].*;
                // Plain multiply-add: wasm has no fused form and @mulAdd would
                // become a software routine there.
                vre += a * tr - b * ti;
                vim += a * ti + b * tr;
            }
            var sre = @reduce(.Add, vre);
            var sim = @reduce(.Add, vim);
            if (k < q) {
                sre += mre[k] * tre[l + k] - mim[k] * tim[l + k];
                sim += mre[k] * tim[l + k] + mim[k] * tre[l + k];
            }
            lre[l] += sre;
            lim[l] += sim;
        }
    }

    /// Powers d^0..d^p of a shift: real parts in dpow[0..p], imaginary in
    /// dpow[MAX_ORDER + 1 ..].
    inline fn shiftPowers(c: *Ctx, dre: f64, dim: f64) void {
        const pre = c.dpow[0 .. MAX_ORDER + 1];
        const pim = c.dpow[MAX_ORDER + 1 ..];
        pre[0] = 1;
        pim[0] = 0;
        for (1..c.p + 1) |k| {
            pre[k] = pre[k - 1] * dre - pim[k - 1] * dim;
            pim[k] = pre[k - 1] * dim + pim[k - 1] * dre;
        }
    }
};

/// M_k ← M_k / k! for every cell, so M2L needs no binomials. The multipoles
/// are not read again after the traversal, so nothing restores them.
fn scaleForM2l(c: *Ctx) void {
    const fm = c.fm;
    for (0..fm.len) |i| {
        const q = c.p + 1;
        const mre = fm.m[i * c.stride ..][0..q];
        const mim = fm.m[i * c.stride + q ..][0..q];
        for (2..q) |k| {
            const inv = 1 / fm.fact[k];
            mre[k] *= inv;
            mim[k] *= inv;
        }
    }
}

/// L_l ← (−1)^l L_l / l!, completing the M2L identity.
fn unscaleAfterM2l(c: *Ctx) void {
    const fm = c.fm;
    for (0..fm.len) |i| {
        const q = c.p + 1;
        const lre = fm.l[i * c.stride ..][0..q];
        const lim = fm.l[i * c.stride + q ..][0..q];
        var sign: f64 = 1;
        for (0..q) |k| {
            const inv = sign / fm.fact[k];
            lre[k] *= inv;
            lim[k] *= inv;
            sign = -sign;
        }
    }
}

/// Cells from the sorted keys: level order, children contiguous.
fn buildCells(fm: *Fmm, a: Allocator, t: *const tree_mod.Tree) !void {
    const m = t.m;
    try fm.reserveCells(a, @max(64, 2 * (m / LEAF + 1)));
    fm.len = 0;
    try appendCell(fm, a, 0, m, 0);
    var c: u32 = 0;
    while (c < fm.len) : (c += 1) {
        const d = fm.cells[c].depth;
        const lo = fm.cells[c].first;
        const hi = lo + fm.cells[c].count;
        if (fm.cells[c].count <= LEAF or d >= LEVELS) continue;
        const shift: u6 = @intCast(2 * (LEVELS - 1 - d));
        var k = lo;
        const c0 = fm.len;
        var nc: u32 = 0;
        for (0..4) |q| {
            const start = k;
            while (k < hi and (t.keys[k] >> shift) & 3 == q) k += 1;
            if (k > start) {
                try appendCell(fm, a, start, k, d + 1);
                nc += 1;
            }
        }
        fm.cells[c].child0 = c0;
        fm.cells[c].nchild = nc;
    }
}

fn appendCell(fm: *Fmm, a: Allocator, lo: u32, hi: u32, depth: u32) !void {
    if (fm.len == fm.cap) try fm.reserveCells(a, fm.cap * 2);
    fm.cells[fm.len] = .{ .cx = 0, .cy = 0, .r = 0, .first = lo, .count = hi - lo, .child0 = 0, .nchild = 0, .depth = depth };
    fm.len += 1;
}

/// Centres and radii from point bounding boxes, leaves first then unions.
fn geometry(c: *Ctx) void {
    const fm = c.fm;
    var i = fm.len;
    while (i > 0) {
        i -= 1;
        const cell = &fm.cells[i];
        var x0: f64 = std.math.inf(f64);
        var y0: f64 = std.math.inf(f64);
        var x1: f64 = -std.math.inf(f64);
        var y1: f64 = -std.math.inf(f64);
        if (cell.nchild == 0) {
            for (cell.first..cell.first + cell.count) |k| {
                const x = c.ux[k];
                const y = c.uy[k];
                x0 = @min(x0, x);
                x1 = @max(x1, x);
                y0 = @min(y0, y);
                y1 = @max(y1, y);
            }
        } else {
            for (cell.child0..cell.child0 + cell.nchild) |ch| {
                x0 = @min(x0, fm.bx0[ch]);
                x1 = @max(x1, fm.bx1[ch]);
                y0 = @min(y0, fm.by0[ch]);
                y1 = @max(y1, fm.by1[ch]);
            }
        }
        fm.bx0[i] = x0;
        fm.by0[i] = y0;
        fm.bx1[i] = x1;
        fm.by1[i] = y1;
        cell.cx = (x0 + x1) / 2;
        cell.cy = (y0 + y1) / 2;
        const dx = x1 - x0;
        const dy = y1 - y0;
        cell.r = 0.5 * @sqrt(dx * dx + dy * dy);
    }
}

/// P2M at leaves, M2M into parents (children have larger indices, so a
/// reverse sweep finishes every child before its parent).
fn upward(c: *Ctx) void {
    const fm = c.fm;
    const p = c.p;
    var i = fm.len;
    while (i > 0) {
        i -= 1;
        const cell = &fm.cells[i];
        const q = p + 1;
        const mre = fm.m[i * c.stride ..][0..q];
        const mim = fm.m[i * c.stride + q ..][0..q];
        if (cell.nchild == 0) {
            for (cell.first..cell.first + cell.count) |k| {
                const s = c.ps[k];
                if (s != s) continue;
                const zre = c.ux[k] - cell.cx;
                const zim = c.uy[k] - cell.cy;
                var pre: f64 = 1;
                var pim: f64 = 0;
                mre[0] += s;
                for (1..q) |o| {
                    const nre = pre * zre - pim * zim;
                    const nim = pre * zim + pim * zre;
                    pre = nre;
                    pim = nim;
                    mre[o] += s * pre;
                    mim[o] += s * pim;
                }
            }
        } else {
            const dre = c.dpow[0 .. MAX_ORDER + 1];
            const dim = c.dpow[MAX_ORDER + 1 ..];
            for (cell.child0..cell.child0 + cell.nchild) |ch| {
                // M^p_n += Σ_{k ≤ n} M^c_k C(n, k) d^(n − k), d = c_child − c_parent
                const child = &fm.cells[ch];
                c.shiftPowers(child.cx - cell.cx, child.cy - cell.cy);
                const cre = fm.m[ch * c.stride ..][0..q];
                const cim = fm.m[ch * c.stride + q ..][0..q];
                for (0..q) |nn| {
                    var sre: f64 = 0;
                    var sim: f64 = 0;
                    for (0..nn + 1) |k| {
                        const b = fm.bin(nn, k);
                        const xre = cre[k] * b;
                        const xim = cim[k] * b;
                        sre += xre * dre[nn - k] - xim * dim[nn - k];
                        sim += xre * dim[nn - k] + xim * dre[nn - k];
                    }
                    mre[nn] += sre;
                    mim[nn] += sim;
                }
            }
        }
    }
}

/// L2L from parents (smaller indices) into children, then L2P at leaves.
fn downward(c: *Ctx) void {
    const fm = c.fm;
    const p = c.p;
    for (0..fm.len) |i| {
        const cell = &fm.cells[i];
        const q = p + 1;
        const lre = fm.l[i * c.stride ..][0..q];
        const lim = fm.l[i * c.stride + q ..][0..q];
        if (cell.nchild == 0) {
            for (cell.first..cell.first + cell.count) |k| {
                // Horner: Φ' = Σ_l L_l w^l, w = u_k − c
                const j = c.perm[k];
                const wre = c.ux[k] - cell.cx;
                const wim = c.uy[k] - cell.cy;
                var are = lre[p];
                var aim = lim[p];
                var l = p;
                while (l > 0) {
                    l -= 1;
                    const nre = are * wre - aim * wim + lre[l];
                    const nim = are * wim + aim * wre + lim[l];
                    are = nre;
                    aim = nim;
                }
                // Δv = −α conj(Φ'_z), Φ'_z = Φ'_u / width; α is already in ps.
                c.vx[j] -= are * c.inv_w;
                c.vy[j] += aim * c.inv_w;
            }
        } else {
            const dre = c.dpow[0 .. MAX_ORDER + 1];
            const dim = c.dpow[MAX_ORDER + 1 ..];
            for (cell.child0..cell.child0 + cell.nchild) |ch| {
                // L^c_m += Σ_{l ≥ m} L^p_l C(l, m) d^(l − m), d = c_child − c_parent
                const child = &fm.cells[ch];
                c.shiftPowers(child.cx - cell.cx, child.cy - cell.cy);
                const cre = fm.l[ch * c.stride ..][0..q];
                const cim = fm.l[ch * c.stride + q ..][0..q];
                for (0..q) |mm| {
                    var sre: f64 = 0;
                    var sim: f64 = 0;
                    for (mm..q) |l| {
                        const b = fm.bin(l, mm);
                        const xre = lre[l] * b;
                        const xim = lim[l] * b;
                        sre += xre * dre[l - mm] - xim * dim[l - mm];
                        sim += xre * dim[l - mm] + xim * dre[l - mm];
                    }
                    cre[mm] += sre;
                    cim[mm] += sim;
                }
            }
        }
    }
}

test "fast many-body matches the direct sum to the stated bound" {
    const a = std.testing.allocator;
    var s: Sim = .{};
    defer s.deinit(a);
    const n: u32 = 2000;
    _ = try s.setNodeCount(a, n);
    var lcg = @import("rng.zig").Lcg{};
    // Two clusters plus a spread, so the tree is adaptive; a few exact
    // duplicates and a NaN strength exercise the scalar path.
    for (0..n) |i| {
        const u = lcg.next();
        const v = lcg.next();
        if (i % 3 == 0) {
            s.x[i] = 300 + 20 * u;
            s.y[i] = -100 + 20 * v;
        } else {
            s.x[i] = 1000 * (u - 0.5);
            s.y[i] = 1000 * (v - 0.5);
        }
        if (i % 97 == 1) s.x[i] = s.x[i - 1];
        s.vx[i] = 0;
        s.vy[i] = 0;
    }
    var f: Force = .{ .kind = .many_body };
    defer f.deinit(a);
    try f.setCount(a, n);
    for (f.f0) |*st| st.* = -30;
    f.f0[5] = std.math.nan(f64);
    const Scalar = @import("force.zig").Scalar;
    f.scalars[@intFromEnum(Scalar.distance_min2)] = 1;
    f.scalars[@intFromEnum(Scalar.distance_max2)] = std.math.inf(f64);
    f.scalars[@intFromEnum(Scalar.seed)] = 0.5;

    // Direct O(n²) sum with d3's pair formula (jiggle-free: exact zero
    // deltas only happen in x here, and y then carries the pair).
    const ref_vx = try a.alloc(f64, n);
    defer a.free(ref_vx);
    const ref_vy = try a.alloc(f64, n);
    defer a.free(ref_vy);
    for (0..n) |i| {
        var vx: f64 = 0;
        var vy: f64 = 0;
        for (0..n) |j| {
            if (i == j or j == 5) continue;
            var x = s.x[j] - s.x[i];
            const y = s.y[j] - s.y[i];
            var l = x * x + y * y;
            if (x == 0) {
                x = hash.jiggle(hash.seedFrom(0.5), @intCast(i), @intCast(j), 0);
                l += x * x;
            }
            if (l < 1) l = @sqrt(l);
            const wj = -30 * 0.3 / l;
            vx += x * wj;
            vy += y * wj;
        }
        ref_vx[i] = vx;
        ref_vy[i] = vy;
    }
    // Defaults, a tighter opening, and all-direct (every pair through P2P).
    const orders = [_]f64{ 8, 12, 8 };
    const openings = [_]f64{ 1.5, 2, 1e9 };
    const bounds = [_]f64{ 1e-4, 1e-6, 1e-12 };
    for (openings, orders, bounds) |op, ord, bound| {
        f.scalars[@intFromEnum(Scalar.order)] = ord;
        f.scalars[@intFromEnum(Scalar.opening)] = op;
        @memset(s.vx[0..n], 0);
        @memset(s.vy[0..n], 0);
        try std.testing.expect(try run(&s, a, &f, 0.3));
        var err2: f64 = 0;
        var ref2: f64 = 0;
        var worst: f64 = 0;
        for (0..n) |i| {
            const ex = s.vx[i] - ref_vx[i];
            const ey = s.vy[i] - ref_vy[i];
            const e2 = ex * ex + ey * ey;
            const r2 = ref_vx[i] * ref_vx[i] + ref_vy[i] * ref_vy[i];
            err2 += e2;
            ref2 += r2;
            worst = @max(worst, @sqrt(e2 / r2));
        }
        const rms = @sqrt(err2 / ref2);
        // Measured 2026-10-23: p = 8 / 1.5 gives rms 5.7e-6 and worst 3.5e-4;
        // p = 12 / 2 gives 2.2e-9; all-direct is float-order noise, 2e-15.
        try std.testing.expect(rms < bound);
        try std.testing.expect(worst < 100 * bound);
    }
}
