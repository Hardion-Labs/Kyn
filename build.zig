const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const exe = b.addExecutable(.{
        .name = "kync",
        .root_module = b.createModule(.{
            .root_source_file = b.path("compiler/main.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    b.installArtifact(exe);

    const builder = b.addExecutable(.{
        .name = "kyn-build",
        .root_module = b.createModule(.{
            .root_source_file = b.path("build-system/main.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    b.installArtifact(builder);

    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());
    run_cmd.addPassthruArgs();
    const run_step = b.step("run", "Run the Kyn compiler");
    run_step.dependOn(&run_cmd.step);

    const tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("compiler/tests.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    const run_tests = b.addRunArtifact(tests);
    const test_step = b.step("test", "Run compiler unit and regression tests");
    test_step.dependOn(&run_tests.step);

    const integration = b.addSystemCommand(&.{ "bash", "tests/integration/run.sh", "--no-build" });
    integration.step.dependOn(b.getInstallStep());
    const integration_step = b.step("integration", "Run end-to-end integration tests");
    integration_step.dependOn(&integration.step);
}
