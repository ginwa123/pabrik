//! Build for the PRIBRIK functional test package (`tests/functional/`). WHY
//! THIS IS A SEPARATE PACKAGE (and not a `b.addTest` on the root `pabrikcore`
//! module): The functional suite is a BLACK-BOX suite.

const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const test_mod = b.createModule(.{
        .root_source_file = b.path("root.zig"),
        .target = target,
        .optimize = optimize,
    });

    // The suite boots the `pabrik` binary, which lives at the REPO root's
    // `zig-out/bin/`.
    const unit_tests = b.addTest(.{ .root_module = test_mod });
    const run_unit_tests = b.addRunArtifact(unit_tests);
    run_unit_tests.setCwd(b.path("../.."));

    const test_step = b.step("test", "Run the PRIBRIK functional test suite");
    test_step.dependOn(&run_unit_tests.step);
}
