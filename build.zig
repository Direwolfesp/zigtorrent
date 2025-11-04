const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const exe_mod = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
    });

    const spsc = b.dependency("spsc_queue", .{
        .target = target,
        .optimize = optimize,
    });
    exe_mod.addImport("spsc_queue", spsc.module("spsc_queue"));

    const exe = b.addExecutable(.{
        .name = "zigtorrent_testing",
        .root_module = exe_mod,
    });

    b.installArtifact(exe);
    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());

    if (b.args) |args| {
        run_cmd.addArgs(args);
    }

    const run_step = b.step("run", "Run the app");
    run_step.dependOn(&run_cmd.step);

    const test_runner = b.addTest(.{
        .root_module = exe_mod,
        .test_runner = .{ .path = b.path("src/tests/test_runner.zig"), .mode = .simple },
    });

    const run_exe_unit_tests = b.addRunArtifact(test_runner);
    const test_step = b.step("test", "Run unit tests");
    test_step.dependOn(&run_exe_unit_tests.step);
}
