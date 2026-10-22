//! center, x, y, radial and integrate (TRD, Zig core design: "center, x, y,
//! radial, integrate"). Direct transcriptions of d3-force over SoA.

const Sim = @import("sim.zig").Sim;
const Force = @import("force.zig").Force;

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

/// forceX (`axis` = 0) and forceY (1): `v += (target - p) * strength * alpha`.
pub fn axis(s: *Sim, f: *const Force, alpha: f64, comptime dim: u1) void {
    @setFloatMode(.strict);
    const p = if (dim == 0) s.x else s.y;
    const v = if (dim == 0) s.vx else s.vy;
    for (0..s.n) |i| v[i] += (f.f1[i] - p[i]) * f.f0[i] * alpha;
}

pub fn radial(s: *Sim, f: *const Force, alpha: f64) void {
    @setFloatMode(.strict);
    const cx = f.scalar(.x);
    const cy = f.scalar(.y);
    for (0..s.n) |i| {
        // `a || 1e-6`, never jiggle.
        var dx = s.x[i] - cx;
        if (dx == 0 or dx != dx) dx = 1e-6;
        var dy = s.y[i] - cy;
        if (dy == 0 or dy != dy) dy = 1e-6;
        const r = @sqrt(dx * dx + dy * dy);
        const k = (f.f1[i] - r) * f.f0[i] * alpha / r;
        s.vx[i] += dx * k;
        s.vy[i] += dy * k;
    }
}

/// The end of d3's tick: `x += vx *= velocityDecay`, or `x = fx, vx = 0`
/// when fixed.
pub fn integrate(s: *Sim, velocity_decay: f64) void {
    @setFloatMode(.strict);
    for (0..s.n) |i| {
        const fixed = s.fixed[i];
        if (fixed & 1 == 0) {
            s.vx[i] *= velocity_decay;
            s.x[i] += s.vx[i];
        } else {
            s.x[i] = s.fx[i];
            s.vx[i] = 0;
        }
        if (fixed & 2 == 0) {
            s.vy[i] *= velocity_decay;
            s.y[i] += s.vy[i];
        } else {
            s.y[i] = s.fy[i];
            s.vy[i] = 0;
        }
    }
}
