//! CLI configuration: server URL + optional session/profile defaults.
//! Resolution order (highest priority first): 1. CLI flags (`--server`,
//! `--session`, `--profile`) 2.

const std = @import("std");

/// Default server URL used when neither flag nor env is set.
pub const default_server = "http://localhost:8081";

/// Runtime configuration for one CLI invocation.
pub const Config = struct {
    server: []const u8,
    /// Borrowed slices: either the cli flag or the env map. Both
    /// are required to outlive the Config (env: the `Init.environ_map`;
    /// flags: the caller's flag storage).
    session_id: ?[]const u8 = null,
    profile: ?[]const u8 = null,
};

pub const env_server = "PABRIKCLI_SERVER";
pub const env_session = "PABRIKCLI_SESSION_ID";
pub const env_profile = "PABRIKCLI_PROFILE";

/// Look up an env var. Returns null if unset or empty.
fn getEnvOrNull(environment: *const std.process.Environ.Map, key: []const u8) ?[]const u8 {
    const v = environment.get(key) orelse return null;
    if (v.len == 0) return null;
    return v;
}

/// Load config from CLI flags + env. The returned `server` slice is
/// heap-allocated (caller frees with `allocator.free`); the
/// `session_id` and `profile` slices are borrowed (see Config docs).
pub fn load(
    allocator: std.mem.Allocator,
    environment: *const std.process.Environ.Map,
    flag_server: ?[]const u8,
    flag_session: ?[]const u8,
    flag_profile: ?[]const u8,
) !Config {
    const server_src = flag_server orelse getEnvOrNull(environment, env_server) orelse default_server;
    const cfg = Config{
        .server = try allocator.dupe(u8, server_src),
        .session_id = flag_session orelse getEnvOrNull(environment, env_session),
        .profile = flag_profile orelse getEnvOrNull(environment, env_profile),
    };
    return cfg;
}

/// Free the heap-allocated `server` slice. Safe to call on a config
/// returned by `load` (the borrowed fields are not freed).
pub fn deinit(cfg: *Config, allocator: std.mem.Allocator) void {
    allocator.free(cfg.server);
    cfg.server = &[_]u8{};
}

// ===== Tests merged from config_test.zig (2026-09-29 flatten) =====
// Tests for src/config.zig.

const testing = std.testing;

test "load: all defaults when no flags and no env" {
    var env = std.process.Environ.Map.init(testing.allocator);
    defer env.deinit();

    var cfg = try load(testing.allocator, &env, null, null, null);
    defer deinit(&cfg, testing.allocator);

    try testing.expectEqualStrings("http://localhost:8081", cfg.server);
    try testing.expect(cfg.session_id == null);
    try testing.expect(cfg.profile == null);
}

test "load: flag overrides env and default" {
    var env = std.process.Environ.Map.init(testing.allocator);
    defer env.deinit();
    try env.put("PABRIKCLI_SERVER", "http://env:1234");

    var cfg = try load(
        testing.allocator,
        &env,
        "http://flag:5678",
        null,
        null,
    );
    defer deinit(&cfg, testing.allocator);

    try testing.expectEqualStrings("http://flag:5678", cfg.server);
}

test "load: env overrides default when no flag" {
    var env = std.process.Environ.Map.init(testing.allocator);
    defer env.deinit();
    try env.put("PABRIKCLI_SERVER", "http://env:9090");

    var cfg = try load(
        testing.allocator,
        &env,
        null,
        null,
        null,
    );
    defer deinit(&cfg, testing.allocator);

    try testing.expectEqualStrings("http://env:9090", cfg.server);
}

test "load: session + profile fall through to env" {
    var env = std.process.Environ.Map.init(testing.allocator);
    defer env.deinit();
    try env.put("PABRIKCLI_SESSION_ID", "session-env");
    try env.put("PABRIKCLI_PROFILE", "profile-env");

    var cfg = try load(
        testing.allocator,
        &env,
        null,
        null,
        null,
    );
    defer deinit(&cfg, testing.allocator);

    try testing.expectEqualStrings("session-env", cfg.session_id.?);
    try testing.expectEqualStrings("profile-env", cfg.profile.?);
}

test "load: flag session/profile override env" {
    var env = std.process.Environ.Map.init(testing.allocator);
    defer env.deinit();
    try env.put("PABRIKCLI_SESSION_ID", "session-env");
    try env.put("PABRIKCLI_PROFILE", "profile-env");

    var cfg = try load(
        testing.allocator,
        &env,
        null,
        "session-flag",
        "profile-flag",
    );
    defer deinit(&cfg, testing.allocator);

    try testing.expectEqualStrings("session-flag", cfg.session_id.?);
    try testing.expectEqualStrings("profile-flag", cfg.profile.?);
}

test "load: empty env value is treated as missing" {
    var env = std.process.Environ.Map.init(testing.allocator);
    defer env.deinit();
    try env.put("PABRIKCLI_SESSION_ID", "");

    var cfg = try load(
        testing.allocator,
        &env,
        null,
        null,
        null,
    );
    defer deinit(&cfg, testing.allocator);

    try testing.expect(cfg.session_id == null);
}

test "deinit: frees server slice only" {
    var env = std.process.Environ.Map.init(testing.allocator);
    defer env.deinit();

    var cfg = try load(
        testing.allocator,
        &env,
        "http://example:1234",
        null,
        null,
    );
    const slice = cfg.server;

    deinit(&cfg, testing.allocator);

    // The helper resets the slice pointer to a static empty string
    // (safe to inspect after deinit; we just verify the value).
    try testing.expectEqualStrings("", cfg.server);
    // The original slice is still the heap-allocated copy — we just
    // can't safely access it after deinit without a use-after-free.
    _ = slice;
}
