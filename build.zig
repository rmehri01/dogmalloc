const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // The check step makes sure everything compiles and gives us nicer
    // diagnostics from zls.
    const check = b.step("check", "Check if dogmalloc compiles");

    const mod = b.addModule("dogmalloc", .{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
    });

    const mod_tests = b.addTest(.{
        .root_module = mod,
    });
    const run_mod_tests = b.addRunArtifact(mod_tests);
    check.dependOn(&run_mod_tests.step);

    const test_step = b.step("test", "Run tests");
    test_step.dependOn(&run_mod_tests.step);

    const build_libs = b.option(bool, "libs", "Build static/dynamic libs") orelse false;
    if (build_libs) {
        const lib_mod = b.createModule(.{
            .root_source_file = b.path("src/libdogmalloc.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{.{ .name = "dogmalloc", .module = mod }},
            .link_libc = true,
        });

        const static_lib = b.addLibrary(.{
            .name = "dogmalloc",
            .linkage = .static,
            .root_module = lib_mod,
        });
        b.installArtifact(static_lib);
        check.dependOn(&static_lib.step);

        const dynamic_lib = b.addLibrary(.{
            .name = "dogmalloc",
            .linkage = .dynamic,
            .root_module = lib_mod,
        });
        b.installArtifact(dynamic_lib);
        check.dependOn(&dynamic_lib.step);
    }
}
