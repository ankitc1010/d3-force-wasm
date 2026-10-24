//! Stable LSD radix sort of keys carrying u32 values, 8-bit digits, on any
//! number of threads (TRD 3, Kernels: "Radix sort"). Each pass counts digits
//! per chunk, turns the counts into per-chunk offsets that keep equal digits
//! in input order, and scatters each chunk at its offsets. A stable sort of
//! the same keys has one result, so the output does not depend on chunking.

const std = @import("std");
const Allocator = std.mem.Allocator;
const pool = @import("pool.zig");

/// Keys per chunk: a pass costs a few ns per key, so below this many keys
/// it runs inline on the main thread rather than pay for a barrier.
const CHUNK: u32 = 16384;

fn Pass(comptime K: type) type {
    return struct {
        src_k: []const K,
        src_v: []const u32,
        dst_k: []K,
        dst_v: []u32,
        hist: []u32,
        shift: std.math.Log2Int(K),
        m: u32,
        size: u32,

        const Self = @This();

        inline fn digit(p: *const Self, k: K) u8 {
            return @truncate(k >> p.shift);
        }

        fn count(p: *const Self, c: u32, _: u32) void {
            const h = p.hist[c * 256 ..][0..256];
            @memset(h, 0);
            const r = pool.range(p.m, p.size, c);
            for (p.src_k[r.lo..r.hi]) |k| h[p.digit(k)] += 1;
        }

        fn scatter(p: *const Self, c: u32, _: u32) void {
            const h = p.hist[c * 256 ..][0..256];
            const r = pool.range(p.m, p.size, c);
            for (p.src_k[r.lo..r.hi], p.src_v[r.lo..r.hi]) |k, v| {
                const d = p.digit(k);
                p.dst_k[h[d]] = k;
                p.dst_v[h[d]] = v;
                h[d] += 1;
            }
        }
    };
}

/// Sorts keys[0..m] by their low `bytes` bytes, carrying vals; passes whose
/// digit is the same in every key are skipped. On return keys and vals hold
/// the result, possibly swapped with keys_tmp and vals_tmp.
pub fn sort(comptime K: type, a: Allocator, keys: *[]K, vals: *[]u32, keys_tmp: *[]K, vals_tmp: *[]u32, hist: *[]u32, m: u32, bytes: u32) !void {
    if (m == 0) return;
    const size = pool.chunkSize(CHUNK);
    const n_chunks = pool.chunks(m, size);
    if (hist.len < 256 * @as(usize, n_chunks)) hist.* = try a.realloc(hist.*, 256 * @as(usize, n_chunks));
    var b: u32 = 0;
    while (b < bytes) : (b += 1) {
        const P = Pass(K);
        const p = P{
            .src_k = keys.*[0..m],
            .src_v = vals.*[0..m],
            .dst_k = keys_tmp.*[0..m],
            .dst_v = vals_tmp.*[0..m],
            .hist = hist.*,
            .shift = @intCast(8 * b),
            .m = m,
            .size = size,
        };
        try pool.parallelFor(&p, n_chunks, P.count);
        const first = p.digit(p.src_k[0]);
        var same: u32 = 0;
        for (0..n_chunks) |c| same += p.hist[c * 256 + first];
        if (same == m) continue;
        var run: u32 = 0;
        for (0..256) |d| {
            for (0..n_chunks) |c| {
                const h = &p.hist[c * 256 + d];
                const cnt = h.*;
                h.* = run;
                run += cnt;
            }
        }
        try pool.parallelFor(&p, n_chunks, P.scatter);
        std.mem.swap([]K, keys, keys_tmp);
        std.mem.swap([]u32, vals, vals_tmp);
    }
}

test "matches a stable serial sort on any chunking" {
    const a = std.testing.allocator;
    const n = 5000;
    var keys = try a.alloc(u64, n);
    var vals = try a.alloc(u32, n);
    var kt = try a.alloc(u64, n);
    var vt = try a.alloc(u32, n);
    var hist: []u32 = &.{};
    defer {
        a.free(keys);
        a.free(vals);
        a.free(kt);
        a.free(vt);
        a.free(hist);
    }
    var lcg = @import("rng.zig").Lcg{};
    for (0..n) |i| {
        // Few distinct keys, so stability matters; constant top bytes.
        keys[i] = @as(u64, @intFromFloat(lcg.next() * 300)) << 8 | 7;
        vals[i] = @intCast(i);
    }
    const ref_k = try a.dupe(u64, keys);
    defer a.free(ref_k);
    const ref_v = try a.dupe(u32, vals);
    defer a.free(ref_v);
    const Pair = struct { k: u64, v: u32 };
    const pairs = try a.alloc(Pair, n);
    defer a.free(pairs);
    for (pairs, ref_k, ref_v) |*p, k, v| p.* = .{ .k = k, .v = v };
    std.mem.sort(Pair, pairs, {}, struct {
        fn lt(_: void, x: Pair, y: Pair) bool {
            return x.k < y.k or (x.k == y.k and x.v < y.v);
        }
    }.lt);
    for ([_]u32{ 0, 7, 1000 }) |chunk| {
        pool.test_chunk = chunk;
        defer pool.test_chunk = 0;
        @memcpy(keys, ref_k);
        @memcpy(vals, ref_v);
        try sort(u64, a, &keys, &vals, &kt, &vt, &hist, n, 8);
        for (pairs, keys, vals) |p, k, v| {
            try std.testing.expectEqual(p.k, k);
            try std.testing.expectEqual(p.v, v);
        }
    }
}
