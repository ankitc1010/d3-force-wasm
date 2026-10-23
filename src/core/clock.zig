//! Monotonic nanoseconds for native benchmarks; zero in the wasm build.
const std = @import("std");
const builtin = @import("builtin");

pub fn now() u64 {
    if (builtin.os.tag != .linux) return 0;
    var ts: std.os.linux.timespec = undefined;
    _ = std.os.linux.clock_gettime(.MONOTONIC, &ts);
    return @as(u64, @intCast(ts.sec)) * 1_000_000_000 + @as(u64, @intCast(ts.nsec));
}
