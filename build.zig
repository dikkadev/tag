const std = @import("std");

// Although this function looks imperative, note that its job is to
// declaratively construct a build graph that will be executed by an external
// runner.
pub fn build(b: *std.Build) void {
    // Standard target options allows the person running `zig build` to choose
    // what target to build for. Here we do not override the defaults, which
    // means any target is allowed, and the default is native. Other options
    // for restricting supported target set are available.
    const target = b.standardTargetOptions(.{});

    // Standard optimization options allow the person running `zig build` to select
    // between Debug, ReleaseSafe, ReleaseFast, and ReleaseSmall. Here we do not
    // set a preferred release mode, allowing the user to decide how to optimize.
    const optimize = b.standardOptimizeOption(.{});

    // Add sokol dependency
    const sokol_dep = b.dependency("sokol", .{
        .target = target,
        .optimize = optimize,
    });

    // Add Zeys dependency
    const zeys_dep = b.dependency("Zeys", .{
        .target = target,
        .optimize = optimize,
    });

    // Create executable
    const exe = b.addExecutable(.{
        .name = "tag",
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
        .win32_manifest = null,
    });
    
    // Set Windows subsystem - use Console for debug builds to see logs
    if (target.result.os.tag == .windows) {
        if (optimize == .Debug) {
            exe.subsystem = .Console; // Show console for debug builds so we can see logs
        } else {
            exe.subsystem = .Windows; // GUI mode for release builds
        }
    }

    // Add sokol module
    exe.root_module.addImport("sokol", sokol_dep.module("sokol"));
    
    // Add Zeys module
    exe.root_module.addImport("zeys", zeys_dep.module("zeys"));

    // Add C wrapper for SUI library
    exe.addCSourceFile(.{
        .file = b.path("src/sui_wrapper.c"),
        .flags = &.{"-std=c99"},
    });
    exe.linkLibC();

    b.installArtifact(exe);

    // Run step
    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());

    if (b.args) |args| {
        run_cmd.addArgs(args);
    }

    const run_step = b.step("run", "Run the app");
    run_step.dependOn(&run_cmd.step);

    // Creates a step for unit testing. This only builds the test executable
    // but does not run it.
    const exe_unit_tests = b.addTest(.{
        .root_module = exe.root_module,
    });

    const run_exe_unit_tests = b.addRunArtifact(exe_unit_tests);

    // Similar to creating the run step earlier, this exposes a `test` step to
    // the `zig build --help` menu, providing a way for the user to request
    // running the unit tests.
    const test_step = b.step("test", "Run unit tests");
    test_step.dependOn(&run_exe_unit_tests.step);
}
