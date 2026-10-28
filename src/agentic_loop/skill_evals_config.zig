//! Per-session resolution of the `skill_evals` block. Why this exists: under
//! `--auth` every user owns a `users.config_json` row, and both config
//! handlers read and write that row and nothing else.

const std = @import("std");
const pabrikcore = @import("pabrikcore");
const test_db = pabrikcore.test_db;
const config_mod = @import("../modules/config/Config.zig");
const session_llm_config = @import("session_llm_config.zig");
const workspace_settings_store = @import("workspace_settings_store.zig");

/// The `skill_evals` block in force for `session_id`, or null when
/// `ctx.config.skill_evals` is already authoritative and should be read
/// directly.
pub fn resolve(
    allocator: std.mem.Allocator,
    db: *pabrikcore.database.Db,
    session_id: []const u8,
) ?config_mod.SkillEvalsConfig {
    const di = pabrikcore.getSingleton() catch return null;
    if (!di.auth_enabled) return null;
    if (session_id.len == 0) return null;

    const owner = session_llm_config.sessionOwner(allocator, db, session_id) catch return null;
    defer allocator.free(owner);
    return resolveForSessionWorkspace(allocator, db, owner, session_id);
}

fn resolveForSessionWorkspace(
    allocator: std.mem.Allocator,
    db: *pabrikcore.database.Db,
    owner: []const u8,
    session_id: []const u8,
) ?config_mod.SkillEvalsConfig {
    const workspace_id = session_llm_config.sessionWorkspace(allocator, db, session_id) catch
        return resolveForOwner(allocator, db, owner);
    defer allocator.free(workspace_id);
    if (workspace_id.len == 0) return resolveForOwner(allocator, db, owner);
    return resolveFromWorkspaceRow(allocator, db, owner, workspace_id);
}

/// The block stored in `(owner, workspace_id)`'s row, or null when that row
/// carries none.
pub fn resolveFromWorkspaceRow(
    allocator: std.mem.Allocator,
    db: *pabrikcore.database.Db,
    owner: []const u8,
    workspace_id: []const u8,
) ?config_mod.SkillEvalsConfig {
    const overlay = workspace_settings_store.loadRaw(allocator, db, owner, workspace_id) catch return null;
    const content = overlay orelse return null;
    defer allocator.free(content);
    return skillEvalsFrom(allocator, content);
}

/// The block in one stored document, or null when it carries none.
pub fn skillEvalsFrom(allocator: std.mem.Allocator, content: []const u8) ?config_mod.SkillEvalsConfig {
    const cfg = session_llm_config.fromJsonText(allocator, content) orelse return null;
    defer {
        var tmp = cfg;
        tmp.deinit();
        allocator.destroy(tmp);
    }
    return cfg.skill_evals;
}

/// The block stored for one user. Only a session with no workspace still
/// resolves here — everywhere else the workspace row is the source.
pub fn resolveForOwner(
    allocator: std.mem.Allocator,
    db: *pabrikcore.database.Db,
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
const database = pabrikcore.database;
const migration = @import("../migrations/migration.zig");

const TestCtx = struct {
    db: database.Db,
    threaded: std.Io.Threaded,
};

fn setupDb() !TestCtx {
    const alloc = testing.allocator;
    var threaded = std.Io.Threaded.init(alloc, .{});
    errdefer threaded.deinit();
    var db: database.Db = .{};
    errdefer db.deinit();
    try test_db.openMemory(&db, threaded.io());
    var manager = migration.MigrationManager.init(alloc, &db);
    defer manager.deinit();
    try migration.registerAllMigrations(&manager);
    try manager.runMigrations();
    return .{ .db = db, .threaded = threaded };
}

fn insertUser(db: *database.Db, id: []const u8, config_json: ?[]const u8) !void {
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
