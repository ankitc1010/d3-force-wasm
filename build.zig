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

    // core-mt.wasm: the same source with threads (TRD 3, Design: "Build"). It
    // imports a shared memory, which may declare a smaller maximum than 1 GiB.
    const wasm_mt = b.resolveTargetQuery(.{
        .cpu_arch = .wasm32,
        .os_tag = .freestanding,
        .cpu_features_add = std.Target.wasm.featureSet(&.{ .simd128, .atomics, .bulk_memory }),
    });
    const core_mt = b.addExecutable(.{
        .name = "core-mt",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/core/root.zig"),
            .target = wasm_mt,
            .optimize = optimize,
            .strip = optimize != .Debug,
            .single_threaded = false,
        }),
    });
    core_mt.entry = .disabled;
    core_mt.rdynamic = true;
    core_mt.import_memory = true;
    core_mt.shared_memory = true;
    // wasm-ld needs room above the 1 MiB default stack.
    core_mt.initial_memory = 2 << 20;
    core_mt.max_memory = 1 << 30;
    b.installArtifact(core_mt);

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
