//! center, x, y, radial and integrate (TRD, Zig core design: "center, x, y,
//! radial, integrate"). Direct transcriptions of d3-force over SoA. Every one
//! but center is per node, so it runs in static chunks on any thread (TRD 3);
//! center keeps d3's sequential summation order.

const Sim = @import("sim.zig").Sim;
const Force = @import("force.zig").Force;
const pool = @import("pool.zig");

/// Nodes per chunk for these streaming passes: below this many nodes a pass
/// runs inline rather than pay for a barrier.
const CHUNK: u32 = 16384;

pub fn center(s: *Sim, f: *const Force) void {
    @setFloatMode(.strict);
    const n = s.n;
    var sx: f64 = 0;
    var sy: f64 = 0;
    for (0..n) |i| {
        sx += s.x[i];
        sy += s.y[i];
    }
    const nf: f64 = @floatFromInt(n);
    const strength = f.scalar(.strength);
    sx = (sx / nf - f.scalar(.x)) * strength;
    sy = (sy / nf - f.scalar(.y)) * strength;
    for (0..n) |i| {
        s.x[i] -= sx;
        s.y[i] -= sy;
    }
}

const Pass = struct {
    s: *Sim,
    f: *const Force,
    alpha: f64,
    size: u32,

    fn run(s: *Sim, f: *const Force, alpha: f64, comptime func: fn (*const Pass, u32, u32) void) pool.Error!void {
        const size = pool.chunkSize(CHUNK);
        const p = Pass{ .s = s, .f = f, .alpha = alpha, .size = size };
        try pool.parallelFor(&p, pool.chunks(s.n, size), func);
    }

    fn nodes(p: *const Pass, c: u32) pool.Range {
        return pool.range(p.s.n, p.size, c);
    }
};

/// forceX (`axis` = 0) and forceY (1): `v += (target - p) * strength * alpha`.
pub fn axis(s: *Sim, f: *const Force, alpha: f64, comptime dim: u1) pool.Error!void {
    const K = struct {
        fn chunk(p: *const Pass, c: u32, _: u32) void {
            @setFloatMode(.strict);
            const r = p.nodes(c);
            const pos = if (dim == 0) p.s.x else p.s.y;
            const v = if (dim == 0) p.s.vx else p.s.vy;
            for (r.lo..r.hi) |i| v[i] += (p.f.f1[i] - pos[i]) * p.f.f0[i] * p.alpha;
        }
    };
    try Pass.run(s, f, alpha, K.chunk);
}

pub fn radial(s: *Sim, f: *const Force, alpha: f64) pool.Error!void {
    const K = struct {
        fn chunk(p: *const Pass, c: u32, _: u32) void {
            @setFloatMode(.strict);
            const r = p.nodes(c);
            const sim = p.s;
            const cx = p.f.scalar(.x);
            const cy = p.f.scalar(.y);
            for (r.lo..r.hi) |i| {
                // `a || 1e-6`, never jiggle.
                var dx = sim.x[i] - cx;
                if (dx == 0 or dx != dx) dx = 1e-6;
                var dy = sim.y[i] - cy;
                if (dy == 0 or dy != dy) dy = 1e-6;
                const l = @sqrt(dx * dx + dy * dy);
                const k = (p.f.f1[i] - l) * p.f.f0[i] * p.alpha / l;
                sim.vx[i] += dx * k;
                sim.vy[i] += dy * k;
            }
        }
    };
    try Pass.run(s, f, alpha, K.chunk);
}

/// The end of d3's tick: `x += vx *= velocityDecay`, or `x = fx, vx = 0`
/// when fixed.
pub fn integrate(s: *Sim, velocity_decay: f64) pool.Error!void {
    const K = struct {
        s: *Sim,
        decay: f64,
        size: u32,

        fn chunk(p: *const @This(), c: u32, _: u32) void {
            @setFloatMode(.strict);
            const r = pool.range(p.s.n, p.size, c);
            const sim = p.s;
            const decay = p.decay;
            for (r.lo..r.hi) |i| {
                const fixed = sim.fixed[i];
                if (fixed & 1 == 0) {
                    sim.vx[i] *= decay;
                    sim.x[i] += sim.vx[i];
                } else {
                    sim.x[i] = sim.fx[i];
                    sim.vx[i] = 0;
                }
                if (fixed & 2 == 0) {
                    sim.vy[i] *= decay;
                    sim.y[i] += sim.vy[i];
                } else {
                    sim.y[i] = sim.fy[i];
                    sim.vy[i] = 0;
                }
            }
        }
    };
    const size = pool.chunkSize(CHUNK);
    const k = K{ .s = s, .decay = velocity_decay, .size = size };
    try pool.parallelFor(&k, pool.chunks(s.n, size), K.chunk);
}
