//! Storage layer for the per-workspace config OVERLAY (`workspace_settings`,
//! Migration 105).
//!
//! One row per `(owner, workspace_id)` holding a SPARSE JSON object. The row
//! is an overlay, not a replacement: `workspace_config.overlayJson` merges it
//! over the user-level config, so a workspace that only overrides `tools`
//! still inherits every profile, MCP server and eval flag from the user.
//!
//! "No overlay" has EXACTLY ONE representation here, on purpose: an ABSENT
//! row. `saveRaw` treats an empty string and `{}` as "clear" and deletes the
//! row, and `loadRaw` maps a NULL column to `null` too. Two spellings of
//! "inherit" that behave differently (absent row vs. stored `{}`) is how a
//! settings screen ends up showing an "Overridden" pill over values nobody
//! changed.
//!
//! HOW THE OWNER IS DERIVED - the one thing callers must get right:
//!   - `--auth` OFF  -> `FILE_MODE_OWNER` (`""`). One overlay per workspace.
//!   - `--auth` ON   -> the session's `users.id`. A workspace is shared
//!     between users, and the overlay holds API keys, so it is scoped per
//!     user exactly like `users.config_json` is.
//! Derive it from the same place the rest of the app does
//! (`session_llm_config.sessionOwner`) - do not invent a second rule.
//!
//! ## The empty-slice landmine, twice over
//!
//! `SqliteBackend.exec` binds an EMPTY slice as SQL NULL, and `''` IS the
//! `--auth`-off owner. So every statement here wraps the owner bind in
//! `COALESCE(?, '')`: without it the INSERT trips `owner NOT NULL` and every
//! `WHERE owner = ?` compares against NULL - which is never true, so a
//! file-mode overlay would be write-only and silently invisible. Both
//! directions are pinned by tests below.
//!
//! Ownership: every returned slice is allocator-owned; the caller frees it.

const std = @import("std");
const sqlite = @import("pabrikcore").sqlite;

/// The `owner` value used when `--auth` is OFF. Also the column DEFAULT.
pub const FILE_MODE_OWNER = "";

/// Is `json_text` an overlay that carries NO overrides?
///
/// `{}` and whitespace-only both count: they mean "change nothing", which is
/// the same thing as having no row at all, and storing them would give the
/// settings UI an override to display for a workspace the user never
/// configured. Public so the HTTP handler and the store agree on one spelling.
pub fn isEmptyOverlay(json_text: []const u8) bool {
    const trimmed = std.mem.trim(u8, json_text, " \t\r\n");
    return trimmed.len == 0 or std.mem.eql(u8, trimmed, "{}");
}

/// The raw overlay JSON for `(owner, workspace_id)`, or null when that
/// workspace inherits everything from the user-level config.
///
/// A NULL column and an empty column both read as null - see the module
/// header for why there is only one representation on the write path and why
/// the read path stays tolerant anyway.
pub fn loadRaw(
    allocator: std.mem.Allocator,
    db: *sqlite.SqliteBackend,
    owner: []const u8,
    workspace_id: []const u8,
) !?[]u8 {
    if (workspace_id.len == 0) return null;
    var q = try db.query(
        allocator,
        // `COALESCE(?, '')` on `owner`, NOT a bare `?`. This backend binds an
        // empty slice as SQL NULL, and `owner = NULL` is never true - so in
        // file mode (where the owner IS the empty string) a bare bind would
        // make every overlay invisible. Same idiom as the WHERE clauses in
        // `secrets_store.zig`.
        "SELECT COALESCE(config_json, '') FROM workspace_settings WHERE owner = COALESCE(?, '') AND workspace_id = ?",
        &[_][]const u8{ owner, workspace_id },
    );
    defer q.deinit();
    const row = (try q.next()) orelse return null;
    defer row.deinit(allocator);
    if (row.values.len < 1) return null;
    if (row.values[0].len == 0) return null;
    return try allocator.dupe(u8, row.values[0]);
}

/// Write the overlay for `(owner, workspace_id)`.
///
/// An overlay that carries no overrides CLEARS the row instead of storing
/// `{}` - see `isEmptyOverlay`. UPSERT (not INSERT-then-UPDATE) so concurrent
/// saves for the same workspace converge on one row rather than racing to a
/// constraint error.
pub fn saveRaw(
    allocator: std.mem.Allocator,
    db: *sqlite.SqliteBackend,
    owner: []const u8,
    workspace_id: []const u8,
    config_json: []const u8,
) !void {
    if (workspace_id.len == 0) return error.WorkspaceIdRequired;
    if (isEmptyOverlay(config_json)) return clear(allocator, db, owner, workspace_id);
    try db.exec(allocator,
        \\INSERT INTO workspace_settings (owner, workspace_id, config_json, updated_at)
        \\VALUES (COALESCE(?, ''), ?, ?, datetime('now'))
        \\ON CONFLICT (owner, workspace_id) DO UPDATE SET
        \\    config_json = excluded.config_json,
        \\    updated_at = datetime('now')
    , &[_][]const u8{ owner, workspace_id, config_json });
}

/// Drop the overlay so the workspace inherits the user-level config again.
/// Deleting an absent row is a no-op, so callers may call this blind.
pub fn clear(
    allocator: std.mem.Allocator,
    db: *sqlite.SqliteBackend,
    owner: []const u8,
    workspace_id: []const u8,
) !void {
    if (workspace_id.len == 0) return error.WorkspaceIdRequired;
    try db.exec(
        allocator,
        // `COALESCE(?, '')` for the same reason as `loadRaw` - see there.
        "DELETE FROM workspace_settings WHERE owner = COALESCE(?, '') AND workspace_id = ?",
        &[_][]const u8{ owner, workspace_id },
    );
}

/// Does this workspace carry any override at all?
///
/// Separate from `loadRaw` so a caller that only needs the yes/no (the
/// "Inherited" vs "Overridden" pill on the settings screen) does not pay for
/// reading and parsing the whole config.
///
/// "Any override" means a non-empty BODY, not merely a row: a row whose
/// `config_json` is NULL or `''` carries no overrides, so reporting it as
/// overridden would put an "Overridden" pill on a workspace that behaves
/// exactly like an untouched one. This is the same property `loadRaw`
/// enforces, and the two must not disagree.
pub fn hasOverlay(
    allocator: std.mem.Allocator,
    db: *sqlite.SqliteBackend,
    owner: []const u8,
    workspace_id: []const u8,
) !bool {
    if (workspace_id.len == 0) return false;
    var q = try db.query(
        allocator,
        // `COALESCE(?, '')` for the same reason as `loadRaw` - see there.
        \\SELECT 1 FROM workspace_settings
        \\WHERE owner = COALESCE(?, '') AND workspace_id = ?
        \\  AND COALESCE(config_json, '') <> ''
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

// =====================================================================
// Tests (in-memory SQLite, same pattern as secrets_store.zig)
// =====================================================================
//
// Five properties, each pinned because its failure mode is INVISIBLE until a
// user notices their workspace config bleed:
//
//   1. Round-trip is byte-exact - the overlay is opaque JSON to this layer.
//   2. `{}` / '' CLEARS, so "no override" has one representation.
//   3. A NULL column reads as "no overlay" (tolerance for a hand-edited DB).
//   4. Two WORKSPACES never see each other's overlay.
//   5. Two OWNERS in ONE workspace never see each other's overlay - the
//      `--auth` leak the composite key exists to prevent.

const testing = std.testing;

const TestCtx = struct {
    db: sqlite.SqliteBackend,
    threaded: std.Io.Threaded,
};

fn setupDb() !TestCtx {
    const alloc = testing.allocator;
    var threaded = std.Io.Threaded.init(alloc, .{});
    errdefer threaded.deinit();
    const io = threaded.io();
    var db: sqlite.SqliteBackend = .{};
    errdefer db.deinit();
    try db.init(io, ":memory:");

    try db.exec(alloc, "CREATE TABLE workspaces (id TEXT PRIMARY KEY)", &.{});
    try db.exec(alloc,
        \\CREATE TABLE workspace_settings (
        \\  owner TEXT NOT NULL DEFAULT '',
        \\  workspace_id TEXT NOT NULL,
        \\  config_json TEXT,
        \\  created_at DATETIME DEFAULT CURRENT_TIMESTAMP,
        \\  updated_at DATETIME DEFAULT CURRENT_TIMESTAMP,
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

test "an empty or `{}` overlay clears the row instead of storing an empty object" {
    const alloc = testing.allocator;
    var ctx = try setupDb();
    defer teardown(&ctx);

    // Positive control: there IS an overlay to clear. Without this the two
    // "cleared" assertions below would pass on a store that never wrote.
    try saveRaw(alloc, &ctx.db, FILE_MODE_OWNER, "ws_a", "{\"retry_delay_ms\":500}");
    try testing.expectEqual(@as(i64, 1), try rowCount(&ctx));

    try saveRaw(alloc, &ctx.db, FILE_MODE_OWNER, "ws_a", "{}");
    try testing.expectEqual(@as(i64, 0), try rowCount(&ctx));
    try testing.expect((try loadRaw(alloc, &ctx.db, FILE_MODE_OWNER, "ws_a")) == null);
    try testing.expect(!try hasOverlay(alloc, &ctx.db, FILE_MODE_OWNER, "ws_a"));

    // Whitespace-only is the same "change nothing" as `{}`.
    try saveRaw(alloc, &ctx.db, FILE_MODE_OWNER, "ws_a", "{\"retry_delay_ms\":500}");
    try saveRaw(alloc, &ctx.db, FILE_MODE_OWNER, "ws_a", "  \n\t ");
    try testing.expectEqual(@as(i64, 0), try rowCount(&ctx));
}

test "a NULL config_json column reads back as no overlay" {
    const alloc = testing.allocator;
    var ctx = try setupDb();
    defer teardown(&ctx);

    // Written straight to SQL: a row can exist with a NULL body (a manual
    // edit, or a future writer that clears the text but not the row).
    //
    // The owner is a SQL LITERAL `''` and not a bind on purpose - binding
    // `FILE_MODE_OWNER` here would be collapsed to SQL NULL by this backend
    // and trip `owner NOT NULL`, which is the store's own landmine rather
    // than the one this test is about.
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
