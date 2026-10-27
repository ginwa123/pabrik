//! Per-user LLM config store for opt-in `--auth` mode.

const std = @import("std");
const pabrikcore = @import("pabrikcore");

/// Load the raw `config_json` for a user. Returns null when the user
/// has no row, the column is NULL, or it is empty (all mean
/// "defaults"). Caller owns the returned slice.
pub fn loadRaw(
    allocator: std.mem.Allocator,
    db: *pabrikcore.database.Db,
    user_id: []const u8,
) !?[]u8 {
    if (user_id.len == 0) return null;
    var q = try db.query(
        allocator,
        "SELECT COALESCE(config_json, '') FROM users WHERE id = ?",
        &[_][]const u8{user_id},
    );
    defer q.deinit();
    const row = try q.next();
    const r = row orelse return null;
    defer r.deinit(allocator);
    if (r.values.len < 1) return null;
    if (r.values[0].len == 0) return null;
    return try allocator.dupe(u8, r.values[0]);
}

/// Save the raw `config_json` for a user. Empty input stores NULL (defaults)
/// — never binds `""` directly since Backend collapses empty slices to
/// NULL mid-execution anyway; the literal keeps the intent explicit.
pub fn saveRaw(
    allocator: std.mem.Allocator,
    db: *pabrikcore.database.Db,
    user_id: []const u8,
    json_text: []const u8,
) !void {
    if (json_text.len == 0) {
        try db.exec(
            allocator,
            "UPDATE users SET config_json = NULL, updated_at = datetime('now') WHERE id = ?",
            &[_][]const u8{user_id},
        );
    } else {
        try db.exec(
            allocator,
            "UPDATE users SET config_json = ?, updated_at = datetime('now') WHERE id = ?",
            &[_][]const u8{ json_text, user_id },
        );
    }
}

// =====================================================================
// Tests (in-memory SQLite, same pattern as agent_kanban handlers)
// =====================================================================

const testing = std.testing;
const sqlite = pabrikcore.sqlite;
const database = pabrikcore.database;
const Migration077 = @import("../../migrations/migration.zig").Migration077AddUsersAndRbacSchema;
const Migration092 = @import("../../migrations/migration.zig").Migration092AddUserConfigJson;

const TestCtx = struct {
    db: database.Db,
    threaded: std.Io.Threaded,
};

fn setupDb() !TestCtx {
    var threaded = std.Io.Threaded.init(testing.allocator, .{});
    errdefer threaded.deinit();
    const io = threaded.io();
    var db: database.Db = .{};
    errdefer db.deinit();
    try db.init(io, ":memory:");
    // Migration077 adds user_id to pre-existing workspaces/sessions
    // tables — stub them so the ALTER has a target.
    try db.exec(
        testing.allocator,
        "CREATE TABLE workspaces (id TEXT PRIMARY KEY)",
        &[_][]const u8{},
    );
    try db.exec(
        testing.allocator,
        "CREATE TABLE sessions (id TEXT PRIMARY KEY)",
        &[_][]const u8{},
    );
    try Migration077.up(&db, testing.allocator);
    try Migration092.up(&db, testing.allocator);
    try db.exec(
        testing.allocator,
        "INSERT INTO users (id, email, name, password_hash, role, is_active) VALUES ('u1', 'a@x.y', 'A', 'h', 'user', 1)",
        &[_][]const u8{},
    );
    return .{ .db = db, .threaded = threaded };
}

test "user config: fresh user loads null (defaults)" {
    var ctx = try setupDb();
    defer ctx.threaded.deinit();
    defer ctx.db.deinit();
    const got = try loadRaw(testing.allocator, &ctx.db, "u1");
    try testing.expect(got == null);
}

test "user config: save then load round-trips" {
    var ctx = try setupDb();
    defer ctx.threaded.deinit();
    defer ctx.db.deinit();
    const body = "{\"active_profile\":null,\"profiles_models\":{\"p\":{\"model\":\"m\"}}}";
    try saveRaw(testing.allocator, &ctx.db, "u1", body);
    const got = try loadRaw(testing.allocator, &ctx.db, "u1");
    defer if (got) |g| testing.allocator.free(g);
    try testing.expect(got != null);
    try testing.expectEqualStrings(body, got.?);
}

test "user config: empty save stores defaults (loads null)" {
    var ctx = try setupDb();
    defer ctx.threaded.deinit();
    defer ctx.db.deinit();
    try saveRaw(testing.allocator, &ctx.db, "u1", "{\"a\":1}");
    try saveRaw(testing.allocator, &ctx.db, "u1", "");
    const got = try loadRaw(testing.allocator, &ctx.db, "u1");
    try testing.expect(got == null);
}

test "user config: unknown user loads null" {
    var ctx = try setupDb();
    defer ctx.threaded.deinit();
    defer ctx.db.deinit();
    const got = try loadRaw(testing.allocator, &ctx.db, "nope");
    try testing.expect(got == null);
}

test "user config: per-user isolation" {
    var ctx = try setupDb();
    defer ctx.threaded.deinit();
    defer ctx.db.deinit();
    try ctx.db.exec(
        testing.allocator,
        "INSERT INTO users (id, email, name, password_hash, role, is_active) VALUES ('u2', 'b@x.y', 'B', 'h', 'user', 1)",
        &[_][]const u8{},
    );
    try saveRaw(testing.allocator, &ctx.db, "u1", "{\"who\":\"u1\"}");
    try saveRaw(testing.allocator, &ctx.db, "u2", "{\"who\":\"u2\"}");
    const g1 = try loadRaw(testing.allocator, &ctx.db, "u1");
    defer if (g1) |g| testing.allocator.free(g);
    const g2 = try loadRaw(testing.allocator, &ctx.db, "u2");
    defer if (g2) |g| testing.allocator.free(g);
    try testing.expectEqualStrings("{\"who\":\"u1\"}", g1.?);
    try testing.expectEqualStrings("{\"who\":\"u2\"}", g2.?);
}
