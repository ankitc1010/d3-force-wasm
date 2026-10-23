//! forceLink, fast mode (TRD 2, "Fast link"): a Jacobi sweep over adjacency
//! lists. Each node walks its incident edges, evaluates d3's per-edge
//! arithmetic on a snapshot of x + vx, y + vy taken before the pass, and
//! applies only its own side of the spring (bias as target, 1 − bias as
//! source). Every edge is evaluated twice and no node writes another's
//! velocity, so the result does not depend on processing order or threads.
//! Jiggle on a zero-length edge is a hash of the edge index and the tick seed,
//! so both ends agree on it.

const std = @import("std");
const Allocator = std.mem.Allocator;
const Sim = @import("sim.zig").Sim;
const Force = @import("force.zig").Force;
const hash = @import("hash.zig");

const TARGET_BIT: u32 = 0x8000_0000;

pub fn run(s: *Sim, a: Allocator, f: *Force, alpha: f64) !void {
    @setFloatMode(.strict);
    const n = s.n;
    const m = f.count;
    for (f.source[0..m], f.target[0..m]) |src, tgt| {
        if (src >= n or tgt >= n) return error.BadArgument;
    }
    try buildCsr(f, a, n);
    const row = f.csr_ptr[0 .. n + 1];
    const adj = f.csr_adj[0 .. 2 * m];
    const seed = hash.seedFrom(f.scalar(.seed));
    const iterations = f.scalar(.iterations);
    var k: f64 = 0;
    while (k < iterations) : (k += 1) {
        // Snapshot, so every edge sees the velocities from before this pass.
        for (0..n) |i| {
            s.px[i] = s.x[i] + s.vx[i];
            s.py[i] = s.y[i] + s.vy[i];
        }
        for (0..n) |i| {
            var vx = s.vx[i];
            var vy = s.vy[i];
            const pxi = s.px[i];
            const pyi = s.py[i];
            for (adj[row[i]..row[i + 1]]) |entry| {
                const e = entry & ~TARGET_BIT;
                const is_target = entry & TARGET_BIT != 0;
                const j = if (is_target) f.source[e] else f.target[e];
                // d3: x = target − source, from this end's point of view.
                var x = if (is_target) pxi - s.px[j] else s.px[j] - pxi;
                var y = if (is_target) pyi - s.py[j] else s.py[j] - pyi;
                if (x == 0 or x != x) x = hash.jiggle(seed, e, 0, 0);
                if (y == 0 or y != y) y = hash.jiggle(seed, e, 0, 1);
                var l = @sqrt(x * x + y * y);
                l = (l - f.f1[e]) / l * alpha * f.f0[e];
                x *= l;
                y *= l;
                const b = f.f2[e];
                if (is_target) {
                    vx -= x * b;
                    vy -= y * b;
                } else {
                    vx += x * (1 - b);
                    vy += y * (1 - b);
                }
            }
            s.vx[i] = vx;
            s.vy[i] = vy;
        }
    }
}

/// Adjacency in CSR form: row_ptr[n + 1], adj[2m] of edge index with the
/// TARGET_BIT set on the entry stored under the edge's target. Rebuilt per
/// run; O(m), a small fraction of the sweep.
fn buildCsr(f: *Force, a: Allocator, n: u32) !void {
    const m = f.count;
    if (f.csr_ptr.len < n + 1) f.csr_ptr = try a.realloc(f.csr_ptr, n + 1);
    if (f.csr_adj.len < 2 * m) f.csr_adj = try a.realloc(f.csr_adj, 2 * m);
    const row = f.csr_ptr[0 .. n + 1];
    @memset(row, 0);
    for (f.source[0..m], f.target[0..m]) |src, tgt| {
        row[src + 1] += 1;
        row[tgt + 1] += 1;
    }
    for (1..n + 1) |i| row[i] += row[i - 1];
    // Fill from the back of each row so row[] ends as the start offsets.
    var fill = f.csr_adj[0 .. 2 * m];
    for (f.source[0..m], f.target[0..m], 0..) |src, tgt, e| {
        const ei: u32 = @intCast(e);
        fill[row[src + 1] - 1] = ei;
        row[src + 1] -= 1;
        fill[row[tgt + 1] - 1] = ei | TARGET_BIT;
        row[tgt + 1] -= 1;
    }
    // After the fill, row[i + 1] holds the start of row i's entries: shift
    // left so row[i]..row[i + 1] is row i.
    for (0..n) |i| row[i] = row[i + 1];
    row[n] = 2 * m;
    _ = &fill;
}
