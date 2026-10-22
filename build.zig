const std = @import("std");

pub fn build(b: *std.Build) void {
    const optimize = b.option(std.builtin.OptimizeMode, "optimize", "Core optimize mode (default ReleaseFast)") orelse .ReleaseFast;

    // core.wasm: single-threaded, simd128, no libc, explicit exports only.
    const wasm = b.resolveTargetQuery(.{
        .cpu_arch = .wasm32,
        .os_tag = .freestanding,
        .cpu_features_add = std.Target.wasm.featureSet(&.{.simd128}),
    });
    const core = b.addExecutable(.{
        .name = "core",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/core/root.zig"),
            .target = wasm,
            .optimize = optimize,
            .strip = optimize != .Debug,
        }),
    });
    core.entry = .disabled;
    core.rdynamic = true;
    b.installArtifact(core);

    // Unit tests run natively in ReleaseSafe so bad indices trap.
    const tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/core/tests.zig"),
            .target = b.graph.host,
            .optimize = .ReleaseSafe,
        }),
    });
    const run_tests = b.addRunArtifact(tests);
    b.step("test", "Run the Zig unit tests").dependOn(&run_tests.step);
}
