//! Per-session resolution of the `skill_evals` block. Why this exists: under
//! `--auth` every user owns a `users.config_json` row, and both config
//! handlers read and write that row and nothing else.

const std = @import("std");
const pabrikcore = @import("pabrikcore");
const config_mod = @import("../modules/config/Config.zig");
const session_llm_config = @import("session_llm_config.zig");

/// The `skill_evals` block in force for `session_id`, or null when
/// `ctx.config.skill_evals` is already authoritative and should be read
/// directly.
pub fn resolve(
    allocator: std.mem.Allocator,
    db: *pabrikcore.sqlite.SqliteBackend,
    session_id: []const u8,
) ?config_mod.SkillEvalsConfig {
    const di = pabrikcore.getSingleton() catch return null;
    // File mode: the PUT swaps the singleton synchronously, so it already
    // tracks the user's settings. Reading the database here would add a
    // second source that can only ever disagree with it.
    if (!di.auth_enabled) return null;
    if (session_id.len == 0) return null;

    const owner = session_llm_config.sessionOwner(allocator, db, session_id) catch return null;
    defer allocator.free(owner);
    return resolveForOwner(allocator, db, owner);
}

/// The `skill_evals` block stored for one user, or null when they have no
/// saved config at all.
pub fn resolveForOwner(
    allocator: std.mem.Allocator,
    db: *pabrikcore.sqlite.SqliteBackend,
    owner: []const u8,
) ?config_mod.SkillEvalsConfig {
    const cfg = session_llm_config.forOwner(allocator, db, owner) orelse return null;
    defer {
        var tmp = cfg;
        tmp.deinit();
        allocator.destroy(tmp);
    }
    return cfg.skill_evals;
}

// ─── tests ───────────────────────────────────────────────────────────────

const testing = std.testing;
const sqlite = pabrikcore.sqlite;
const migration = @import("../migrations/migration.zig");

const TestCtx = struct {
    db: sqlite.SqliteBackend,
    threaded: std.Io.Threaded,
};

fn setupDb() !TestCtx {
    const alloc = testing.allocator;
    var threaded = std.Io.Threaded.init(alloc, .{});
    errdefer threaded.deinit();
    var db: sqlite.SqliteBackend = .{};
    errdefer db.deinit();
    try db.init(threaded.io(), ":memory:");
    var manager = migration.MigrationManager.init(alloc, &db);
    defer manager.deinit();
    try migration.registerAllMigrations(&manager);
    try manager.runMigrations();
    return .{ .db = db, .threaded = threaded };
}

fn insertUser(db: *sqlite.SqliteBackend, id: []const u8, config_json: ?[]const u8) !void {
    try db.exec(testing.allocator,
        \\INSERT INTO users (id, email, password_hash, config_json)
        \\VALUES (?, ?, 'x', ?)
    , &[_][]const u8{ id, id, config_json orelse "" });
}

test "resolveForOwner returns the block the user saved (the auth-mode trap)" {
    var ctx = try setupDb();
    defer ctx.threaded.deinit();
    defer ctx.db.deinit();

    try insertUser(&ctx.db, "u1", "{\"notify_on_complete\":true,\"skill_evals\":{\"enabled\":true,\"max_skills_per_run\":3,\"fact_lease_seconds\":42}}");

    const got = resolveForOwner(testing.allocator, &ctx.db, "u1");
    try testing.expect(got != null);
    try testing.expect(got.?.enabled);
    try testing.expectEqual(@as(u32, 3), got.?.max_skills_per_run);
    try testing.expectEqual(@as(u32, 42), got.?.fact_lease_seconds);
}

test "resolveForOwner returns null for a user who never saved settings" {
    // The fallback must be the singleton, not "off": an absent row is not a
    // request to disable the feature.
    var ctx = try setupDb();
    defer ctx.threaded.deinit();
    defer ctx.db.deinit();

    try testing.expect(resolveForOwner(testing.allocator, &ctx.db, "nobody") == null);
}

test "a saved config with no skill_evals key reads as OFF, not as an error" {
    var ctx = try setupDb();
    defer ctx.threaded.deinit();
    defer ctx.db.deinit();

    try insertUser(&ctx.db, "u2", "{\"notify_on_complete\":true,\"mcp_servers\":[]}");

    const got = resolveForOwner(testing.allocator, &ctx.db, "u2");
    try testing.expect(got != null);
    try testing.expect(!got.?.enabled);
}

test "unrelated keys and nested objects do not break the parse" {
    var ctx = try setupDb();
    defer ctx.threaded.deinit();
    defer ctx.db.deinit();

    try insertUser(&ctx.db, "u3", "{\"profiles_models\":[{\"name\":\"p\",\"models\":{\"x\":\"y\"}}],\"skill_evals\":{\"enabled\":true,\"apply_mode\":\"off\"}}");

    const got = resolveForOwner(testing.allocator, &ctx.db, "u3");
    try testing.expect(got != null);
    try testing.expect(got.?.enabled);
    try testing.expectEqual(config_mod.SkillEvalsConfig.ApplyMode.off, got.?.apply_mode);
}

test "resolve degrades to the singleton when no singleton is installed" {
    // File mode and unit-test dispatch both land here: without a live
    // singleton the caller must keep reading `ctx.config` rather than
    // silently switching the feature off.
    var ctx = try setupDb();
    defer ctx.threaded.deinit();
    defer ctx.db.deinit();

    try insertUser(&ctx.db, "u4", "{\"skill_evals\":{\"enabled\":true}}");
    try testing.expect(resolve(testing.allocator, &ctx.db, "any_session") == null);
}
