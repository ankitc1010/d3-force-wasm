//! Counter-based random values for fast mode (TRD 2, "Fast many-body kernel":
//! jiggle uses a hash of the pair and the tick seed). Fast mode draws the
//! force's `random` once per tick for `seed`; every jiggle is then a pure
//! function of (seed, i, j, salt), so the result does not depend on the order
//! in which pairs are visited or on which thread visits them.

const std = @import("std");

/// splitmix64 finaliser over the pair and a salt.
pub fn mix(seed: u64, i: u32, j: u32, salt: u32) u64 {
    var h = seed ^ (@as(u64, i) << 32 | j) ^ (@as(u64, salt) *% 0x9E3779B97F4A7C15);
    h = (h ^ (h >> 30)) *% 0xBF58476D1CE4E5B9;
    h = (h ^ (h >> 27)) *% 0x94D049BB133111EB;
    return h ^ (h >> 31);
}

/// Uniform in [0, 1) with 53 random bits.
pub fn uniform(seed: u64, i: u32, j: u32, salt: u32) f64 {
    return @as(f64, @floatFromInt(mix(seed, i, j, salt) >> 11)) * 0x1.0p-53;
}

/// d3's jiggle magnitude: `(random() - 0.5) * 1e-6`.
pub fn jiggle(seed: u64, i: u32, j: u32, salt: u32) f64 {
    return (uniform(seed, i, j, salt) - 0.5) * 1e-6;
}

/// The seed as the facade passes it: the f64 from `random()` reinterpreted.
pub fn seedFrom(v: f64) u64 {
    return @bitCast(v);
}

test "jiggle is deterministic, symmetric under salt, and small" {
    const s = seedFrom(0.123456789);
    try std.testing.expectEqual(jiggle(s, 3, 7, 0), jiggle(s, 3, 7, 0));
    try std.testing.expect(jiggle(s, 3, 7, 0) != jiggle(s, 3, 7, 1));
    try std.testing.expect(jiggle(s, 3, 7, 0) != jiggle(s, 7, 3, 0));
    try std.testing.expect(@abs(jiggle(s, 3, 7, 0)) <= 0.5e-6);
}
