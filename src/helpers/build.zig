const std = @import("std");

/// `helpers` package — the project-wide portable sleep / time /
/// file-existence helpers (`PosixTimespec`, `sleepMillis`, `unixTimestamp`,
/// `nanosleep`, `clock_gettime`, etc.).
pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    _ = b.addModule("helpers", .{
        .root_source_file = b.path("mod.zig"),
        .target = target,
        .optimize = optimize,
    });
}
