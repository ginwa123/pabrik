//! Storage layer for the per-workspace config OVERLAY (`workspace_settings`,
//! Migration 105). One row per `(owner, workspace_id)` holding a SPARSE JSON
//! object.

const std = @import("std");
const test_db = @import("pabrikcore").test_db;
const sqlite = @import("pabrikcore").sqlite;
const database = @import("pabrikcore").database;
const secrets_at_rest = @import("secrets_at_rest.zig");

/// The `owner` value used when `--auth` is OFF. Also the column DEFAULT.
pub const FILE_MODE_OWNER = "";

/// The AAD binding for one row's envelope: table name plus the row's primary
/// key, `owner` length-prefixed so `("a","b:c")` and `("a:b","c")` cannot
/// share one scope. A copied envelope fails to open instead of decrypting.
fn scopeId(allocator: std.mem.Allocator, owner: []const u8, workspace_id: []const u8) ![]u8 {
    return std.fmt.allocPrint(allocator, "workspace_settings:{d}:{s}{s}", .{ owner.len, owner, workspace_id });
}

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

    // A legacy plaintext row reads through unchanged; a sealed one is opened.
    // `error.KeyUnavailable` is deliberately NOT "no overlay": a host that lost
    // the key must not look like a workspace that never configured anything.
    const scope = try scopeId(allocator, owner, workspace_id);
    defer allocator.free(scope);
    return try secrets_at_rest.openValue(allocator, scope, row.values[0]);
}

/// Write the overlay for `(owner, workspace_id)`, sealed. An empty overlay
/// writes the EMPTY-BODY marker instead (see `isEmptyOverlay`), and a host with
/// no master key REFUSES the write rather than storing one more plaintext row.
pub fn saveRaw(
    allocator: std.mem.Allocator,
    db: *database.Db,
    owner: []const u8,
    workspace_id: []const u8,
    config_json: []const u8,
) !void {
    if (workspace_id.len == 0) return error.WorkspaceIdRequired;
    if (isEmptyOverlay(config_json)) return clear(allocator, db, owner, workspace_id);

    const scope = try scopeId(allocator, owner, workspace_id);
    defer allocator.free(scope);
    const sealed = try secrets_at_rest.sealValue(allocator, scope, config_json);
    defer allocator.free(sealed);

    try db.exec(allocator,
        \\INSERT INTO workspace_settings (owner, workspace_id, config_json, updated_at)
        \\VALUES (COALESCE(CAST(? AS TEXT), ''), ?, ?, datetime('now'))
        \\ON CONFLICT (owner, workspace_id) DO UPDATE SET
        \\    config_json = excluded.config_json,
        \\    updated_at = datetime('now')
    , &[_][]const u8{ owner, workspace_id, sealed });
}

/// Seal every row written before this feature existed; returns how many. Runs
/// at boot, not in a migration, because the chain must run with no key. Sealed
/// rows and unknown envelopes are left alone, so a second pass is a no-op.
pub fn sealLegacySettingsRows(allocator: std.mem.Allocator, db: *database.Db) !usize {
    if (!secrets_at_rest.sealingAvailable()) return 0;

    // Collect first, update second: rewriting rows while the SELECT's cursor is
    // still open is how a "seal everything" loop seals a moving target.
    const Row = struct { owner: []u8, workspace_id: []u8, body: []u8 };
    var rows: std.ArrayList(Row) = .empty;
    defer {
        for (rows.items) |r| {
            allocator.free(r.owner);
            allocator.free(r.workspace_id);
            allocator.free(r.body);
        }
        rows.deinit(allocator);
    }

    var q = try db.query(
        allocator,
        \\SELECT COALESCE(CAST(owner AS TEXT), ''), workspace_id, COALESCE(CAST(config_json AS TEXT), '')
        \\FROM workspace_settings
        \\WHERE COALESCE(CAST(config_json AS TEXT), '') <> ''
    ,
        &[_][]const u8{},
    );
    defer q.deinit();
    while (try q.next()) |r| {
        defer r.deinit(allocator);
        if (r.values.len < 3) continue;
        if (secrets_at_rest.classify(r.values[2]) != .legacy_plaintext) continue;
        try rows.append(allocator, .{
            .owner = try allocator.dupe(u8, r.values[0]),
            .workspace_id = try allocator.dupe(u8, r.values[1]),
            .body = try allocator.dupe(u8, r.values[2]),
        });
    }
    if (rows.items.len == 0) return 0;

    // One UPDATE per row, each atomic on its own; a crash midway is finished by
    // the next boot. No wrapping transaction: `BEGIN IMMEDIATE` is sqlite-only.
    var sealed_count: usize = 0;
    for (rows.items) |row| {
        const scope = scopeId(allocator, row.owner, row.workspace_id) catch continue;
        defer allocator.free(scope);
        const envelope = secrets_at_rest.sealValue(allocator, scope, row.body) catch |err| {
            std.log.warn("workspace config: could not seal {s}/{s}: {s}", .{ row.owner, row.workspace_id, @errorName(err) });
            continue;
        };
        defer allocator.free(envelope);
        db.exec(
            allocator,
            "UPDATE workspace_settings SET config_json = ? WHERE owner = COALESCE(CAST(? AS TEXT), '') AND workspace_id = ?",
            &[_][]const u8{ envelope, row.owner, row.workspace_id },
        ) catch |err| {
            std.log.warn("workspace config: could not seal {s}/{s}: {s}", .{ row.owner, row.workspace_id, @errorName(err) });
            continue;
        };
        sealed_count += 1;
    }
    return sealed_count;
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

const test_key: [secrets_at_rest.KEY_LEN]u8 = blk: {
    var k: [secrets_at_rest.KEY_LEN]u8 = undefined;
    for (&k, 0..) |*b, i| b.* = @intCast(i);
    break :blk k;
};

/// Install the suite's fixed key. Shared with the other suites that save
/// through this store (`workspace_config`, `session_llm_config`, the HTTP
/// config handler) so none of them reads the host's real key file.
pub fn installTestKey() void {
    secrets_at_rest.setKey(test_key);
}

const TestCtx = struct {
    db: database.Db,
    threaded: std.Io.Threaded,
};

fn setupDb() !TestCtx {
    const alloc = testing.allocator;
    installTestKey();
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

/// The column exactly as SQL returns it, so an assertion about "the file does
/// not hold the config" cannot be satisfied by the reader under test.
fn rawColumn(ctx: *TestCtx, owner: []const u8, workspace_id: []const u8) ![]u8 {
    const alloc = testing.allocator;
    var q = try ctx.db.query(
        alloc,
        "SELECT COALESCE(CAST(config_json AS TEXT), '') FROM workspace_settings WHERE owner = ? AND workspace_id = ?",
        &[_][]const u8{ owner, workspace_id },
    );
    defer q.deinit();
    const row = (try q.next()) orelse return error.RowMissing;
    defer row.deinit(alloc);
    return alloc.dupe(u8, row.values[0]);
}

test "a saved overlay is sealed in the column and still reads back as JSON" {
    const alloc = testing.allocator;
    var ctx = try setupDb();
    defer teardown(&ctx);

    const overlay = "{\"active_profile\":\"claude\",\"tools\":[\"read_file\"]}";
    try saveRaw(alloc, &ctx.db, FILE_MODE_OWNER, "ws_a", overlay);

    const stored = try rawColumn(&ctx, FILE_MODE_OWNER, "ws_a");
    defer alloc.free(stored);
    // THE point of the feature: what a database file (or a DB GUI) shows is an
    // envelope, not the config.
    try testing.expect(secrets_at_rest.isSealed(stored));
    try testing.expect(std.mem.indexOf(u8, stored, "claude") == null);
    try testing.expect(std.mem.indexOf(u8, stored, "read_file") == null);

    const loaded = (try loadRaw(alloc, &ctx.db, FILE_MODE_OWNER, "ws_a")) orelse
        return error.OverlayMissing;
    defer alloc.free(loaded);
    try testing.expectEqualStrings(overlay, loaded);
    try testing.expect(try hasOverlay(alloc, &ctx.db, FILE_MODE_OWNER, "ws_a"));
}

test "two writes of the same overlay seal differently, so a no-op save is not observable" {
    const alloc = testing.allocator;
    var ctx = try setupDb();
    defer teardown(&ctx);

    const overlay = "{\"tools\":[\"read_file\"]}";
    try saveRaw(alloc, &ctx.db, FILE_MODE_OWNER, "ws_a", overlay);
    const first = try rawColumn(&ctx, FILE_MODE_OWNER, "ws_a");
    defer alloc.free(first);

    try saveRaw(alloc, &ctx.db, FILE_MODE_OWNER, "ws_a", overlay);
    const second = try rawColumn(&ctx, FILE_MODE_OWNER, "ws_a");
    defer alloc.free(second);

    try testing.expect(!std.mem.eql(u8, first, second));
}

test "an envelope moved to another workspace's row fails instead of decrypting" {
    const alloc = testing.allocator;
    var ctx = try setupDb();
    defer teardown(&ctx);

    try saveRaw(alloc, &ctx.db, FILE_MODE_OWNER, "ws_a", "{\"active_profile\":\"a\"}");
    const stolen = try rawColumn(&ctx, FILE_MODE_OWNER, "ws_a");
    defer alloc.free(stolen);

    // A copy-paste by someone with write access to the file: the ciphertext is
    // intact, the row it belongs to is not.
    try ctx.db.exec(
        alloc,
        "INSERT INTO workspace_settings (owner, workspace_id, config_json) VALUES ('', 'ws_b', ?)",
        &[_][]const u8{stolen},
    );

    try testing.expectError(error.Corrupt, loadRaw(alloc, &ctx.db, FILE_MODE_OWNER, "ws_b"));
}

test "with no key set, a write is refused and the column gains no plaintext row" {
    const alloc = testing.allocator;
    var ctx = try setupDb();
    defer teardown(&ctx);
    defer installTestKey();

    // FAIL CLOSED. Storing the config as-is is what makes "encrypted at rest" a
    // claim nobody can check.
    secrets_at_rest.setKey(null);
    try testing.expectError(
        error.SealingUnavailable,
        saveRaw(alloc, &ctx.db, FILE_MODE_OWNER, "ws_a", "{\"active_profile\":\"a\"}"),
    );
    try testing.expectEqual(@as(i64, 0), try rowCount(&ctx));
}

test "a sealed row on a host with no key is an error, not an empty overlay" {
    const alloc = testing.allocator;
    var ctx = try setupDb();
    defer teardown(&ctx);
    defer installTestKey();

    try saveRaw(alloc, &ctx.db, FILE_MODE_OWNER, "ws_a", "{\"active_profile\":\"a\"}");
    const seeded = try rawColumn(&ctx, FILE_MODE_OWNER, "ws_a");
    defer alloc.free(seeded);

    secrets_at_rest.setKey(null);
    // A workspace whose config cannot be unsealed must not look like one that
    // was never configured: the two states need different remedies.
    try testing.expectError(error.KeyUnavailable, loadRaw(alloc, &ctx.db, FILE_MODE_OWNER, "ws_a"));

    installTestKey();
    const loaded = (try loadRaw(alloc, &ctx.db, FILE_MODE_OWNER, "ws_a")) orelse
        return error.OverlayMissing;
    defer alloc.free(loaded);
    try testing.expectEqualStrings("{\"active_profile\":\"a\"}", loaded);
}

test "the backfill seals legacy plaintext rows once and leaves sealed ones alone" {
    const alloc = testing.allocator;
    var ctx = try setupDb();
    defer teardown(&ctx);

    // Straight to SQL: a row written before this feature existed.
    try ctx.db.exec(
        alloc,
        "INSERT INTO workspace_settings (owner, workspace_id, config_json) VALUES ('', 'ws_legacy', '{\"tools\":[\"glob\"]}')",
        &[_][]const u8{},
    );
    try saveRaw(alloc, &ctx.db, FILE_MODE_OWNER, "ws_sealed", "{\"tools\":[\"glob\"]}");

    try testing.expectEqual(@as(usize, 1), try sealLegacySettingsRows(alloc, &ctx.db));

    const legacy = try rawColumn(&ctx, FILE_MODE_OWNER, "ws_legacy");
    defer alloc.free(legacy);
    try testing.expect(secrets_at_rest.isSealed(legacy));
    try testing.expect(std.mem.indexOf(u8, legacy, "glob") == null);

    // The value survived the reseal.
    const loaded = (try loadRaw(alloc, &ctx.db, FILE_MODE_OWNER, "ws_legacy")) orelse
        return error.OverlayMissing;
    defer alloc.free(loaded);
    try testing.expectEqualStrings("{\"tools\":[\"glob\"]}", loaded);

    // Idempotent: a second pass has nothing to do.
    try testing.expectEqual(@as(usize, 0), try sealLegacySettingsRows(alloc, &ctx.db));
}

test "the backfill is a no-op with no key, and the rows stay readable" {
    const alloc = testing.allocator;
    var ctx = try setupDb();
    defer teardown(&ctx);
    defer installTestKey();

    try ctx.db.exec(
        alloc,
        "INSERT INTO workspace_settings (owner, workspace_id, config_json) VALUES ('', 'ws_legacy', '{\"tools\":[\"glob\"]}')",
        &[_][]const u8{},
    );

    secrets_at_rest.setKey(null);
    try testing.expectEqual(@as(usize, 0), try sealLegacySettingsRows(alloc, &ctx.db));

    const stored = try rawColumn(&ctx, FILE_MODE_OWNER, "ws_legacy");
    defer alloc.free(stored);
    try testing.expectEqualStrings("{\"tools\":[\"glob\"]}", stored);

    installTestKey();
    try testing.expectEqual(@as(usize, 1), try sealLegacySettingsRows(alloc, &ctx.db));
}

test "the envelope binds the (owner, workspace) pair, not a joined spelling of it" {
    const alloc = testing.allocator;
    var ctx = try setupDb();
    defer teardown(&ctx);

    // Two DIFFERENT rows whose joined strings would be identical
    // ("a" + ":" + "b:c" vs "a:b" + ":" + "c"). Without the length prefix in
    // the AAD, one owner's ciphertext would open as the other's config.
    try saveRaw(alloc, &ctx.db, "a", "b:c", "{\"active_profile\":\"mine\"}");
    const stolen = try rawColumn(&ctx, "a", "b:c");
    defer alloc.free(stolen);

    try ctx.db.exec(
        alloc,
        "INSERT INTO workspace_settings (owner, workspace_id, config_json) VALUES (?, ?, ?)",
        &[_][]const u8{ "a:b", "c", stolen },
    );
    try testing.expectError(error.Corrupt, loadRaw(alloc, &ctx.db, "a:b", "c"));

    // Positive control: the row it belongs to still opens.
    const own = (try loadRaw(alloc, &ctx.db, "a", "b:c")) orelse return error.OverlayMissing;
    defer alloc.free(own);
    try testing.expectEqualStrings("{\"active_profile\":\"mine\"}", own);
}
