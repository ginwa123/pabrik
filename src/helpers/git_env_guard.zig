//! Refuses fixture git when GIT_DIR/GIT_WORK_TREE-style vars are set. `git -C
//! <fixture>` obeys those over `-C`, so under a git hook every fixture commit
//! would land in the real repo.

const std = @import("std");
const builtin = @import("builtin");

/// Vars that redirect git away from the `-C` path. Any one set is enough to misroute a fixture spawn.
pub const AMBIENT_GIT_ENV_VARS = [_][]const u8{
    "GIT_DIR",
    "GIT_WORK_TREE",
    "GIT_INDEX_FILE",
    "GIT_OBJECT_DIRECTORY",
    "GIT_COMMON_DIR",
};

/// First set-and-non-empty redirect var, or null when the env is clean.
pub fn ambientGitEnvOverride() ?[]const u8 {
    for (AMBIENT_GIT_ENV_VARS) |name| {
        var buf: [64]u8 = undefined;
        if (name.len + 1 > buf.len) continue;
        @memcpy(buf[0..name.len], name);
        buf[name.len] = 0;
        const zname: [*:0]const u8 = buf[0..name.len :0];
        if (std.c.getenv(zname)) |val| {
            if (val[0] != 0) return name;
        }
    }
    return null;
}

/// Call before the first git spawn in a fixture: fails the test instead of committing into a real repo.
pub fn requireCleanGitEnv() error{AmbientGitEnvRedirect}!void {
    if (ambientGitEnvOverride()) |name| {
        std.debug.print("\n!! refusing fixture git: {s} is set !!\n", .{name});
        return error.AmbientGitEnvRedirect;
    }
}

// ─── Tests ───────────────────────────────────────────────────────────────

test "AMBIENT_GIT_ENV_VARS names every git redirect variable" {
    // Dropping one re-opens the hole this guard closes.
    const want = [_][]const u8{
        "GIT_DIR",
        "GIT_WORK_TREE",
        "GIT_INDEX_FILE",
        "GIT_OBJECT_DIRECTORY",
        "GIT_COMMON_DIR",
    };
    try std.testing.expectEqual(want.len, AMBIENT_GIT_ENV_VARS.len);
    for (want) |name| {
        var found = false;
        for (AMBIENT_GIT_ENV_VARS) |have| {
            if (std.mem.eql(u8, have, name)) {
                found = true;
                break;
            }
        }
        try std.testing.expect(found);
    }
}

test "ambientGitEnvOverride is null in a clean environment" {
    try std.testing.expect(ambientGitEnvOverride() == null);
}

// setenv/unsetenv exist on POSIX only; the guard itself (getenv) is portable.
extern "c" fn setenv(name: [*:0]const u8, value: [*:0]const u8, overwrite: c_int) c_int;
extern "c" fn unsetenv(name: [*:0]const u8) c_int;

test "ambientGitEnvOverride trips on a set redirect var and clears after unset" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;
    try std.testing.expect(setenv("GIT_DIR", "/tmp/probe-guard-test", 1) == 0);
    try std.testing.expectEqualStrings("GIT_DIR", ambientGitEnvOverride().?);
    try std.testing.expectError(error.AmbientGitEnvRedirect, requireCleanGitEnv());
    try std.testing.expect(unsetenv("GIT_DIR") == 0);
    try std.testing.expect(ambientGitEnvOverride() == null);
    try requireCleanGitEnv();
}
