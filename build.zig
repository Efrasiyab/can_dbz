const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const root_module = b.addModule("can_dbz", .{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .optimize = optimize,
    });
    const lib = b.addLibrary(.{
        .name = "can_dbz",
        .root_module = root_module,
    });
    b.installArtifact(lib);

    const lib_unit_tests = b.addTest(.{
        .root_module = root_module,
    });

    const run_lib_unit_tests = b.addRunArtifact(lib_unit_tests);
    const test_step = b.step("test", "Run unit tests");
    test_step.dependOn(&run_lib_unit_tests.step);

    const schema_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("schema_test.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    const run_schema_tests = b.addRunArtifact(schema_tests);
    test_step.dependOn(&run_schema_tests.step);

    const smoke_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("tests/smoke.zig"),
            .imports = &.{.{
                .name = "can_dbz",
                .module = root_module,
            }},
            .target = target,
            .optimize = optimize,
        }),
    });
    const run_smoke_tests = b.addRunArtifact(smoke_tests);
    const smoke_step = b.step("test-smoke", "Run fixture-backed smoke tests");
    smoke_step.dependOn(&run_smoke_tests.step);

    const benchmark = b.addExecutable(.{
        .name = "can_dbz_bench",
        .root_module = b.createModule(.{
            .root_source_file = b.path("bench.zig"),
            .target = target,
            .optimize = .ReleaseFast,
        }),
    });
    const run_benchmark = b.addRunArtifact(benchmark);
    const benchmark_step = b.step("bench", "Measure load-time and compiled decode throughput");
    benchmark_step.dependOn(&run_benchmark.step);
}
