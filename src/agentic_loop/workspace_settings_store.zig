//! Storage layer for the per-workspace config OVERLAY (`workspace_settings`,
//! Migration 105). One row per `(owner, workspace_id)` holding a SPARSE JSON
//! object.

const std = @import("std");
const test_db = @import("pabrikcore").test_db;
const sqlite = @import("pabrikcore").sqlite;
const database = @import("pabrikcore").database;

/// The `owner` value used when `--auth` is OFF. Also the column DEFAULT.
pub const FILE_MODE_OWNER = "";

/// The `owner` a `workspace_settings` row uses for a request. ONE definition
/// for every reader and writer: `--auth` OFF is a single-user instance whose
/// rows live under `FILE_MODE_OWNER`, whatever identity the request resolved.
pub fn ownerKey(auth_enabled: bool, resolved_user_id: []const u8) []const u8 {
    return if (auth_enabled) resolved_user_id else FILE_MODE_OWNER;
}

/// Is `json_text` an overlay that carries NO overrides?
pub fn isEmptyOverlay(json_text: []const u8) bool {
    const trimmed = std.mem.trim(u8, json_text, " \t\r\n");
    return trimmed.len == 0 or std.mem.eql(u8, trimmed, "{}");
}

/// The raw overlay JSON for `(owner, workspace_id)`, or null when that
/// workspace has no scoped settings of its own.
pub fn loadRaw(
    allocator: std.mem.Allocator,
    db: *database.Db,
    owner: []const u8,
    workspace_id: []const u8,
) !?[]u8 {
    if (workspace_id.len == 0) return null;
    var q = try db.query(
        allocator,
        // `COALESCE(CAST(? AS TEXT), '')` on `owner`, NOT a bare `?`.
        "SELECT COALESCE(CAST(config_json AS TEXT), '') FROM workspace_settings WHERE owner = COALESCE(CAST(? AS TEXT), '') AND workspace_id = ?",
        &[_][]const u8{ owner, workspace_id },
    );
    defer q.deinit();
    const row = (try q.next()) orelse return null;
    defer row.deinit(allocator);
    if (row.values.len < 1) return null;
    if (row.values[0].len == 0) return null;
    return try allocator.dupe(u8, row.values[0]);
}

/// Write the overlay for `(owner, workspace_id)`. An overlay that carries no
/// overrides writes the EMPTY-BODY marker instead of storing `{}` - see
/// `isEmptyOverlay` and the module header.
pub fn saveRaw(
    allocator: std.mem.Allocator,
    db: *database.Db,
    owner: []const u8,
    workspace_id: []const u8,
    config_json: []const u8,
) !void {
    if (workspace_id.len == 0) return error.WorkspaceIdRequired;
    if (isEmptyOverlay(config_json)) return clear(allocator, db, owner, workspace_id);
    try db.exec(allocator,
        \\INSERT INTO workspace_settings (owner, workspace_id, config_json, updated_at)
        \\VALUES (COALESCE(CAST(? AS TEXT), ''), ?, ?, datetime('now'))
        \\ON CONFLICT (owner, workspace_id) DO UPDATE SET
        \\    config_json = excluded.config_json,
        \\    updated_at = datetime('now')
    , &[_][]const u8{ owner, workspace_id, config_json });
}

/// Record "this workspace has NO scoped settings": the row is kept with a NULL
/// body, which every reader treats as empty - and which no later pass refills.
pub fn clear(
    allocator: std.mem.Allocator,
    db: *database.Db,
    owner: []const u8,
    workspace_id: []const u8,
) !void {
    if (workspace_id.len == 0) return error.WorkspaceIdRequired;
    try db.exec(allocator,
        \\INSERT INTO workspace_settings (owner, workspace_id, config_json, updated_at)
        \\VALUES (COALESCE(CAST(? AS TEXT), ''), ?, NULL, datetime('now'))
        \\ON CONFLICT (owner, workspace_id) DO UPDATE SET
        \\    config_json = NULL,
        \\    updated_at = datetime('now')
    , &[_][]const u8{ owner, workspace_id });
}

/// Has this `(owner, workspace_id)` been DECIDED yet - either overridden or
/// explicitly left inherited?
pub fn hasRow(
    allocator: std.mem.Allocator,
    db: *database.Db,
    owner: []const u8,
    workspace_id: []const u8,
) !bool {
    if (workspace_id.len == 0) return false;
    var q = try db.query(
        allocator,
        // `COALESCE(CAST(? AS TEXT), '')` for the same reason as `loadRaw` - see there.
        "SELECT 1 FROM workspace_settings WHERE owner = COALESCE(CAST(? AS TEXT), '') AND workspace_id = ?",
        &[_][]const u8{ owner, workspace_id },
    );
    defer q.deinit();
    if ((try q.next())) |row| {
        row.deinit(allocator);
        return true;
    }
    return false;
}

/// Does this workspace carry any override at all?
pub fn hasOverlay(
    allocator: std.mem.Allocator,
    db: *database.Db,
    owner: []const u8,
    workspace_id: []const u8,
) !bool {
    if (workspace_id.len == 0) return false;
    var q = try db.query(
        allocator,
        // `COALESCE(CAST(? AS TEXT), '')` for the same reason as `loadRaw` - see there.
        \\SELECT 1 FROM workspace_settings
        \\WHERE owner = COALESCE(CAST(? AS TEXT), '') AND workspace_id = ?
        \\  AND COALESCE(CAST(config_json AS TEXT), '') <> ''
    ,
        &[_][]const u8{ owner, workspace_id },
    );
    defer q.deinit();
    if ((try q.next())) |row| {
        row.deinit(allocator);
        return true;
    }
    return false;
}

// ===================================================================== Tests
// (in-memory SQLite, same pattern as secrets_store.zig)
// ===================================================================== Five

const testing = std.testing;

const TestCtx = struct {
    db: database.Db,
    threaded: std.Io.Threaded,
};

fn setupDb() !TestCtx {
    const alloc = testing.allocator;
    var threaded = std.Io.Threaded.init(alloc, .{});
    errdefer threaded.deinit();
    const io = threaded.io();
    var db: database.Db = .{};
    errdefer db.deinit();
    try test_db.openMemory(&db, io);

    try db.exec(alloc, "CREATE TABLE workspaces (id TEXT PRIMARY KEY)", &.{});
    try db.exec(alloc,
        \\CREATE TABLE workspace_settings (
        \\  owner TEXT NOT NULL DEFAULT '',
        \\  workspace_id TEXT NOT NULL,
        \\  config_json TEXT,
        \\  created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
        \\  updated_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
        \\  PRIMARY KEY (owner, workspace_id)
        \\)
    , &.{});
    return .{ .db = db, .threaded = threaded };
}

fn teardown(ctx: *TestCtx) void {
    ctx.db.deinit();
    ctx.threaded.deinit();
}

/// Row count straight from SQL, so a "cleared" assertion cannot be satisfied
/// by the same code path it is testing.
fn rowCount(ctx: *TestCtx) !i64 {
    const alloc = testing.allocator;
    var q = try ctx.db.query(alloc, "SELECT COUNT(*) FROM workspace_settings", &.{});
    defer q.deinit();
    const row = (try q.next()) orelse return error.RowMissing;
    defer row.deinit(alloc);
    return std.fmt.parseInt(i64, row.values[0], 10);
}

test "overlay round-trips through saveRaw/loadRaw byte-for-byte" {
    const alloc = testing.allocator;
    var ctx = try setupDb();
    defer teardown(&ctx);

    const overlay =
        "{\"active_profile\":\"claude\",\"tools\":[\"read_file\"]}";
    try saveRaw(alloc, &ctx.db, FILE_MODE_OWNER, "ws_a", overlay);

    const loaded = (try loadRaw(alloc, &ctx.db, FILE_MODE_OWNER, "ws_a")) orelse
        return error.OverlayMissing;
    defer alloc.free(loaded);
    try testing.expectEqualStrings(overlay, loaded);
    try testing.expect(try hasOverlay(alloc, &ctx.db, FILE_MODE_OWNER, "ws_a"));
}

test "an empty or `{}` overlay records an explicit inherit, not an empty object" {
    const alloc = testing.allocator;
    var ctx = try setupDb();
    defer teardown(&ctx);

    // Positive control: there IS an overlay to clear. Without this the
    // "inherits" assertions below would pass on a store that never wrote.
    try saveRaw(alloc, &ctx.db, FILE_MODE_OWNER, "ws_a", "{\"retry_delay_ms\":500}");
    try testing.expect(try hasOverlay(alloc, &ctx.db, FILE_MODE_OWNER, "ws_a"));

    try saveRaw(alloc, &ctx.db, FILE_MODE_OWNER, "ws_a", "{}");
    // Inherits: no body, so nothing to override and no "Overridden" pill.
    try testing.expect((try loadRaw(alloc, &ctx.db, FILE_MODE_OWNER, "ws_a")) == null);
    try testing.expect(!try hasOverlay(alloc, &ctx.db, FILE_MODE_OWNER, "ws_a"));
    // ...but DECIDED: the row is still there, which is what stops the boot
    // backfill from re-copying the config the user just cleared.
    try testing.expect(try hasRow(alloc, &ctx.db, FILE_MODE_OWNER, "ws_a"));
    try testing.expectEqual(@as(i64, 1), try rowCount(&ctx));

    // Whitespace-only is the same "change nothing" as `{}`.
    try saveRaw(alloc, &ctx.db, FILE_MODE_OWNER, "ws_a", "{\"retry_delay_ms\":500}");
    try saveRaw(alloc, &ctx.db, FILE_MODE_OWNER, "ws_a", "  \n\t ");
    try testing.expect(!try hasOverlay(alloc, &ctx.db, FILE_MODE_OWNER, "ws_a"));
    try testing.expect(try hasRow(alloc, &ctx.db, FILE_MODE_OWNER, "ws_a"));
    try testing.expectEqual(@as(i64, 1), try rowCount(&ctx));
}

test "an untouched workspace and a cleared one both read as empty" {
    const alloc = testing.allocator;
    var ctx = try setupDb();
    defer teardown(&ctx);

    // `hasRow` still separates "nobody configured this" from "someone
    // cleared it", but both answers to `loadRaw` are the same: no scoped
    // settings at all.
    try testing.expect(!try hasRow(alloc, &ctx.db, FILE_MODE_OWNER, "ws_new"));
    try testing.expect(!try hasOverlay(alloc, &ctx.db, FILE_MODE_OWNER, "ws_new"));

    try clear(alloc, &ctx.db, FILE_MODE_OWNER, "ws_new");
    try testing.expect(try hasRow(alloc, &ctx.db, FILE_MODE_OWNER, "ws_new"));
    try testing.expect(!try hasOverlay(alloc, &ctx.db, FILE_MODE_OWNER, "ws_new"));
}

test "a NULL config_json column reads back as no overlay" {
    const alloc = testing.allocator;
    var ctx = try setupDb();
    defer teardown(&ctx);

    // Written straight to SQL: a row can exist with a NULL body (a manual
    // edit, or a future writer that clears the text but not the row).
    try ctx.db.exec(
        alloc,
        "INSERT INTO workspace_settings (owner, workspace_id, config_json) VALUES ('', ?, NULL)",
        &[_][]const u8{"ws_a"},
    );

    try testing.expect((try loadRaw(alloc, &ctx.db, FILE_MODE_OWNER, "ws_a")) == null);
    try testing.expect(!try hasOverlay(alloc, &ctx.db, FILE_MODE_OWNER, "ws_a"));
}

test "two workspaces never share an overlay" {
    const alloc = testing.allocator;
    var ctx = try setupDb();
    defer teardown(&ctx);

    try saveRaw(alloc, &ctx.db, FILE_MODE_OWNER, "ws_a", "{\"active_profile\":\"claude\"}");

    // ws_b was never configured: it must inherit, not borrow ws_a's profile.
    try testing.expect((try loadRaw(alloc, &ctx.db, FILE_MODE_OWNER, "ws_b")) == null);
    try testing.expect(!try hasOverlay(alloc, &ctx.db, FILE_MODE_OWNER, "ws_b"));

    try clear(alloc, &ctx.db, FILE_MODE_OWNER, "ws_a");
    try testing.expect((try loadRaw(alloc, &ctx.db, FILE_MODE_OWNER, "ws_a")) == null);
    // ws_b is still untouched: clearing ws_a must not decide ws_b for it.
    try testing.expect(!try hasRow(alloc, &ctx.db, FILE_MODE_OWNER, "ws_b"));
}

test "two owners in one workspace never share an overlay (the --auth leak)" {
    const alloc = testing.allocator;
    var ctx = try setupDb();
    defer teardown(&ctx);

    try saveRaw(alloc, &ctx.db, "user_1", "ws_shared", "{\"active_profile\":\"mine\"}");

    // The whole point of keying on (owner, workspace_id): user_2 opening the
    // SAME workspace must not see user_1's profile - and profiles carry API
    // keys, so this is a credential leak, not a cosmetic one.
    try testing.expect((try loadRaw(alloc, &ctx.db, "user_2", "ws_shared")) == null);
    try testing.expect(!try hasOverlay(alloc, &ctx.db, "user_2", "ws_shared"));

    // Two owners, two rows - the PK must not collapse them.
    try saveRaw(alloc, &ctx.db, "user_2", "ws_shared", "{\"active_profile\":\"theirs\"}");
    try testing.expectEqual(@as(i64, 2), try rowCount(&ctx));
    const mine = (try loadRaw(alloc, &ctx.db, "user_1", "ws_shared")) orelse
        return error.OverlayMissing;
    defer alloc.free(mine);
    try testing.expectEqualStrings("{\"active_profile\":\"mine\"}", mine);
}

test "saving twice overwrites in place instead of adding a second row" {
    const alloc = testing.allocator;
    var ctx = try setupDb();
    defer teardown(&ctx);

    try saveRaw(alloc, &ctx.db, FILE_MODE_OWNER, "ws_a", "{\"retry_delay_ms\":500}");
    try saveRaw(alloc, &ctx.db, FILE_MODE_OWNER, "ws_a", "{\"retry_delay_ms\":900}");

    try testing.expectEqual(@as(i64, 1), try rowCount(&ctx));
    const loaded = (try loadRaw(alloc, &ctx.db, FILE_MODE_OWNER, "ws_a")) orelse
        return error.OverlayMissing;
    defer alloc.free(loaded);
    try testing.expectEqualStrings("{\"retry_delay_ms\":900}", loaded);
}

test "an empty workspace_id is refused rather than written as a global default" {
    const alloc = testing.allocator;
    var ctx = try setupDb();
    defer teardown(&ctx);

    // A row with workspace_id '' would poison every workspace's lookup.
    try testing.expectError(
        error.WorkspaceIdRequired,
        saveRaw(alloc, &ctx.db, FILE_MODE_OWNER, "", "{\"retry_delay_ms\":500}"),
    );
    try testing.expectEqual(@as(i64, 0), try rowCount(&ctx));
    try testing.expect((try loadRaw(alloc, &ctx.db, FILE_MODE_OWNER, "")) == null);
}

test "a row written for a request identity is the row a reader finds in file mode" {
    const alloc = testing.allocator;
    var ctx = try setupDb();
    defer teardown(&ctx);

    // `user_system` is what request identity resolves to with `--auth` off;
    // every reader asks this store with `FILE_MODE_OWNER`.
    try saveRaw(alloc, &ctx.db, ownerKey(false, "user_system"), "ws_a", "{\"tools\":[\"read_file\"]}");

    const loaded = (try loadRaw(alloc, &ctx.db, ownerKey(false, ""), "ws_a")) orelse
        return error.OverlayMissing;
    defer alloc.free(loaded);
    try testing.expectEqualStrings("{\"tools\":[\"read_file\"]}", loaded);
}

test "auth mode keys a workspace's row by the user, not by the sentinel" {
    const alloc = testing.allocator;
    var ctx = try setupDb();
    defer teardown(&ctx);

    try saveRaw(alloc, &ctx.db, ownerKey(true, "user_1"), "ws_a", "{\"tools\":[\"read_file\"]}");

    try testing.expect((try loadRaw(alloc, &ctx.db, ownerKey(true, "user_2"), "ws_a")) == null);
    try testing.expect((try loadRaw(alloc, &ctx.db, ownerKey(true, "user_system"), "ws_a")) == null);
    const loaded = (try loadRaw(alloc, &ctx.db, ownerKey(true, "user_1"), "ws_a")) orelse
        return error.OverlayMissing;
    defer alloc.free(loaded);
    try testing.expectEqualStrings("{\"tools\":[\"read_file\"]}", loaded);
}
