//! Native benchmark of the many-body kernels. Parameters come from the
//! generated bench_config.zig (see scripts/bench-native.sh):
//!   scripts/bench-native.sh 100000 8 1.5
const std = @import("std");
const Sim = @import("sim.zig").Sim;
const Force = @import("force.zig").Force;
const Scalar = @import("force.zig").Scalar;
const fmm = @import("fmm.zig");
const many_body = @import("many_body.zig");
const rng = @import("rng.zig");
const clock = @import("clock.zig");

var lcg = rng.Lcg{};
fn random() f64 {
    return lcg.next();
}

fn ms(ns: u64) f64 {
    return @as(f64, @floatFromInt(ns)) / 1e6;
}

pub fn main() !void {
    const a = std.heap.page_allocator;
    const cfg = @import("bench_config.zig");
    const n: u32 = cfg.n;
    const order: f64 = cfg.order;
    const opening: f64 = cfg.opening;
    fmm.LEAF = cfg.leaf;
    var s: Sim = .{};
    defer s.deinit(a);
    _ = try s.setNodeCount(a, n);
    // d3's phyllotaxis start, jittered so no two deltas are exactly zero.
    for (0..n) |i| {
        const fi: f64 = @floatFromInt(i);
        const radius = 10 * @sqrt(0.5 + fi);
        const angle = fi * std.math.pi * (3 - @sqrt(5.0));
        s.x[i] = radius * @cos(angle) + lcg.next();
        s.y[i] = radius * @sin(angle) + lcg.next();
        s.vx[i] = 0;
        s.vy[i] = 0;
        s.fixed[i] = 0;
    }
    var f: Force = .{ .kind = .many_body };
    defer f.deinit(a);
    try f.setCount(a, n);
    for (f.f0) |*st| st.* = -30;
    f.scalars[@intFromEnum(Scalar.theta2)] = 0.81;
    f.scalars[@intFromEnum(Scalar.distance_min2)] = 1;
    f.scalars[@intFromEnum(Scalar.distance_max2)] = std.math.inf(f64);
    f.scalars[@intFromEnum(Scalar.seed)] = 0.5;
    f.scalars[@intFromEnum(Scalar.order)] = order;
    f.scalars[@intFromEnum(Scalar.opening)] = opening;

    // Min of `reps` runs: the phone's clock speed drifts, so means mislead.
    // Interleaved exact/fast repetitions, min of each: the phone's clock
    // speed drifts under load, so means and separate loops mislead.
    const reps: usize = 4;
    var exact_ns: u64 = std.math.maxInt(u64);
    var fast_ns: u64 = std.math.maxInt(u64);
    var best_phases: [8]u64 = undefined;
    var st: fmm.Stats = .{};
    for (0..reps) |_| {
        var t = clock.now();
        try many_body.run(&s, a, &f, 0.3, &random);
        exact_ns = @min(exact_ns, clock.now() - t);
        @memset(s.vx[0..n], 0);
        @memset(s.vy[0..n], 0);
        fmm.stats = .{};
        t = clock.now();
        _ = try fmm.run(&s, a, &f, 0.3);
        const dt = clock.now() - t;
        if (dt < fast_ns) {
            fast_ns = dt;
            best_phases = fmm.phase_ns;
            st = fmm.stats;
        }
    }
    fmm.phase_ns = best_phases;

    // Accuracy: RMS relative error against the direct O(n²) sum on a sample
    // of 400 target nodes (the last run's velocities are the FMM result).
    var err2: f64 = 0;
    var ref2: f64 = 0;
    var k: u32 = 0;
    while (k < 400) : (k += 1) {
        const i: u32 = @intCast((@as(u64, k) * 2654435761) % n);
        var vx: f64 = 0;
        var vy: f64 = 0;
        for (0..n) |j| {
            if (i == j) continue;
            const x = s.x[j] - s.x[i];
            const y = s.y[j] - s.y[i];
            var l = x * x + y * y;
            if (l < 1) l = @sqrt(l);
            const wj = -30 * 0.3 / l;
            vx += x * wj;
            vy += y * wj;
        }
        const ex = s.vx[i] - vx;
        const ey = s.vy[i] - vy;
        err2 += ex * ex + ey * ey;
        ref2 += vx * vx + vy * vy;
    }
    const rms = @sqrt(err2 / ref2);
    const nf: f64 = @floatFromInt(n);
    const cells: f64 = @floatFromInt(s.fmm.len);
    std.debug.print("n = {d}, p = {d:.0}, opening = {d:.2}, leaf {d}: exact {d:.1} ms, fast {d:.1} ms, {d} cells, rms error {e:.2}\n", .{ n, order, opening, fmm.LEAF, ms(exact_ns), ms(fast_ns), s.fmm.len, rms });
    std.debug.print("  phases ms: prepare {d:.1}, cells {d:.1}, geometry {d:.1}, reset {d:.1}, upward {d:.1}, traversal {d:.1}, downward {d:.1}; run total inside {d:.1}\n", .{ ms(fmm.phase_ns[5]), ms(fmm.phase_ns[0]), ms(fmm.phase_ns[1]), ms(fmm.phase_ns[6]), ms(fmm.phase_ns[2]), ms(fmm.phase_ns[3]), ms(fmm.phase_ns[4]), ms(fmm.phase_ns[7]) });
    std.debug.print("  per run: {d} pair visits, {d} M2L ({d:.1} per cell), {d} P2P calls, {d} P2P pairs ({d:.0} per node)\n", .{
        st.visits, st.m2l, @as(f64, @floatFromInt(st.m2l)) / cells, st.p2p_calls, st.p2p_pairs, @as(f64, @floatFromInt(st.p2p_pairs)) / nf,
    });

    if (!cfg.isolate) return;

    // Isolate the traversal's two costs (min of reps each).
    const Variant = struct { name: []const u8, m2l: bool, p2p: bool };
    const variants = [_]Variant{ .{ .name = "without P2P", .m2l = false, .p2p = true }, .{ .name = "without M2L", .m2l = true, .p2p = false }, .{ .name = "without both", .m2l = true, .p2p = true } };
    for (variants) |v| {
        fmm.skip_m2l = v.m2l;
        fmm.skip_p2p = v.p2p;
        var best: u64 = std.math.maxInt(u64);
        for (0..reps) |_| {
            const t = clock.now();
            _ = try fmm.run(&s, a, &f, 0.3);
            best = @min(best, clock.now() - t);
        }
        std.debug.print("  {s}: {d:.1} ms\n", .{ v.name, ms(best) });
    }
    fmm.skip_m2l = false;
    fmm.skip_p2p = false;
}
