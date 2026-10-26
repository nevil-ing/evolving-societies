const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const raylib_dep = b.dependency("raylib", .{
        .target = target,
        .optimize = optimize,
        .raudio = false,
        .rmodels = false,
    });
    // raylib's own exported module isn't visible to dependents on 0.17.0,
    // so translate the header here and link the compiled library.
    const raylib_lib = raylib_dep.artifact("raylib");
    const raylib_h = b.addTranslateC(.{
        .root_source_file = raylib_dep.path("src/raylib.h"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    const raylib_mod = raylib_h.createModule();
    raylib_mod.linkLibrary(raylib_lib);

    const exe = b.addExecutable(.{
        .name = "evolving-societies",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "raylib", .module = raylib_mod },
            },
        }),
    });
    // Fly sub-circuit produced by tools/extract_circuit.py
    exe.root_module.addAnonymousImport("flybrain", .{ .root_source_file = b.path("assets/flybrain.bin") });
    b.installArtifact(exe);

    const run_step = b.step("run", "Run the simulation");
    const run_cmd = b.addRunArtifact(exe);
    run_step.dependOn(&run_cmd.step);
    run_cmd.step.dependOn(b.getInstallStep());
    run_cmd.addPassthruArgs();

    const tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/tests.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    tests.root_module.addAnonymousImport("flybrain", .{ .root_source_file = b.path("assets/flybrain.bin") });
    const opts = b.addOptions();
    opts.addOption(bool, "slow", b.option(bool, "slow", "Also run the slow chemotaxis and balance experiments") orelse false);
    tests.root_module.addOptions("build_options", opts);
    const test_step = b.step("test", "Run tests");
    test_step.dependOn(&b.addRunArtifact(tests).step);
}
