//! Random source for jiggle. In the wasm build it calls the force's JS
//! `random` function through the `env.random` import, so the stream and the
//! moment each value is drawn are exactly d3's for any `randomSource`.

pub const Source = *const fn () f64;

/// d3-force's jiggle.js: `(random() - 0.5) * 1e-6`.
pub inline fn jiggle(random: Source) f64 {
    @setFloatMode(.strict);
    return (random() - 0.5) * 1e-6;
}

/// d3-force's lcg.js, for native tests: `s = (a * s + c) % 2^32; s / 2^32`.
/// The product stays below 2^53, so u64 arithmetic gives d3's doubles.
pub const Lcg = struct {
    s: u64 = 1,

    pub fn next(l: *Lcg) f64 {
        l.s = (1664525 * l.s + 1013904223) % 4294967296;
        return @as(f64, @floatFromInt(l.s)) / 4294967296;
    }
};
