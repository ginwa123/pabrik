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
        // `zig build test` relays stderr from a PASSING test as a `run test w`
        // block, and the guard's own test trips this on purpose: gate on is_test.
        if (!builtin.is_test) std.debug.print("\n!! refusing fixture git: {s} is set !!\n", .{name});
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

// `setenv`/`unsetenv` exist on POSIX only. Windows spells the same thing
// with the CRT's `_putenv_s`, which is the setter behind the `getenv` this
// module reads — an empty value REMOVES the variable there.
extern "c" fn setenv(name: [*:0]const u8, value: [*:0]const u8, overwrite: c_int) c_int;
extern "c" fn unsetenv(name: [*:0]const u8) c_int;
extern "c" fn _putenv_s(name: [*:0]const u8, value: [*:0]const u8) c_int;

/// Set `name` in the environment `ambientGitEnvOverride` reads it from:
/// libc's `setenv` on POSIX, the CRT's `_putenv_s` on Windows.
fn setAmbientVar(name: [*:0]const u8, value: [*:0]const u8) c_int {
    return switch (builtin.os.tag) {
        .windows => _putenv_s(name, value),
        else => setenv(name, value, 1),
    };
}

/// Remove `name` from that same environment — an empty value is how
/// `_putenv_s` spells `unsetenv`.
fn unsetAmbientVar(name: [*:0]const u8) c_int {
    return switch (builtin.os.tag) {
        .windows => _putenv_s(name, ""),
        else => unsetenv(name),
    };
}

test "ambientGitEnvOverride trips on a set redirect var and clears after unset" {
    try std.testing.expectEqual(@as(c_int, 0), setAmbientVar("GIT_DIR", "/tmp/probe-guard-test"));
    try std.testing.expectEqualStrings("GIT_DIR", ambientGitEnvOverride().?);
    try std.testing.expectError(error.AmbientGitEnvRedirect, requireCleanGitEnv());
    try std.testing.expectEqual(@as(c_int, 0), unsetAmbientVar("GIT_DIR"));
    try std.testing.expect(ambientGitEnvOverride() == null);
    try requireCleanGitEnv();
}
