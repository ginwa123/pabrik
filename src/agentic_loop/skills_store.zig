//! Workspace-scoped skill storage (Migrations 101 + 119), and ONE rule:
//! `workspace_id` is a parameter in every `WHERE`, so isolation is SQL-side.
//! `skill_metadata` projects the fence in `content`; it is never authored.

const std = @import("std");
const sqlite = @import("pabrikcore").sqlite;
const database = @import("pabrikcore").database;
const helpers = @import("helpers");
const frontmatter = @import("skill_frontmatter.zig");
/// Migration 101, imported (never re-typed) so the tests below run
/// against the real schema. A store/DDL mismatch fails here rather
/// than in production.
const migration = @import("../migrations/migration.zig");

/// Hard cap on a single skill body. 2 MiB is far beyond any hand-written
/// SKILL.MD and stops a runaway agent from filling the disk. The agent tool
/// surfaces it as a tool error; the HTTP handler as 413.
pub const MAX_CONTENT_BYTES: usize = 2 << 20; // 2 MiB

/// Hard cap on ONE companion file of a bundled skill. The two bundles
/// installed today top out around 30 KiB; 2 MiB leaves three orders of
/// magnitude of headroom while still bounding a single INSERT.
pub const MAX_ASSET_BYTES: usize = 2 << 20; // 2 MiB

/// Max bytes of a skill name, which is a directory-safe token: letters,
/// digits, dot, dash, underscore, no leading or trailing dot. `use_skill`
/// joins the name onto a materialisation dir, so `..` must not escape it.
pub const MAX_NAME_BYTES: usize = 128;

/// One row in `skills`. All string fields are allocator-owned.
pub const SkillRow = struct {
    id: []const u8,
    workspace_id: []const u8,
    name: []const u8,
    description: []const u8,
    content: []const u8,
    created_at: []const u8,
    updated_at: []const u8,
    is_can_auto_improve: bool,
};

/// One row in `skill_assets`: a companion file of a bundled skill, stored
/// at the same relative path the body refers to (`scripts/run_eval.py`).
pub const SkillAssetRow = struct {
    id: []const u8,
    skill_id: []const u8,
    rel_path: []const u8,
    content: []const u8,
    created_at: []const u8,
};

/// One row in `skill_metadata`: a SKILL.md frontmatter key that has no
/// column of its own. All string fields are allocator-owned.
pub const SkillMetadataRow = struct {
    id: []const u8,
    skill_id: []const u8,
    key: []const u8,
    value: []const u8,
    created_at: []const u8,
    updated_at: []const u8,
};

/// A companion file to write. Borrows every string; `replaceAssets` copies
/// the bytes into SQL before the caller drops them.
pub const SkillAssetInput = struct {
    rel_path: []const u8,
    content: []const u8,
};

/// Create-or-replace. `name` is the natural key within a workspace, so an
/// import of the same skill twice updates in place rather than failing on
/// the UNIQUE constraint.
pub const UpsertSkillArgs = struct {
    workspace_id: []const u8,
    name: []const u8,
    description: []const u8 = "",
    content: []const u8 = "",
    is_can_auto_improve: ?bool = null,
};

/// Patch shape. Every field optional; an absent field keeps its current
/// value (the `effective_*` pattern).
pub const UpdateSkillArgs = struct {
    description: ?[]const u8 = null,
    content: ?[]const u8 = null,
    is_can_auto_improve: ?bool = null,
};

pub const ListSkillsError = error{
    WorkspaceIdRequired,
    QueryFailed,
    OutOfMemory,
};

pub const GetSkillError = error{
    WorkspaceIdNameRequired,
    NotFound,
    QueryFailed,
    OutOfMemory,
};

pub const UpsertSkillError = error{
    WorkspaceIdNameRequired,
    NameTooLong,
    ContentTooLarge,
    WriteFailed,
    RowNotFoundAfterWrite,
    OutOfMemory,
};

pub const UpdateSkillError = error{
    WorkspaceIdNameRequired,
    NotFound,
    ContentTooLarge,
    NothingToChange,
    UpdateFailed,
    OutOfMemory,
};

pub const DeleteSkillError = error{
    WorkspaceIdNameRequired,
    NotFound,
    DeleteFailed,
};

pub const ListMetadataError = error{
    WorkspaceIdNameRequired,
    QueryFailed,
    OutOfMemory,
};

pub const ListAssetsError = error{
    WorkspaceIdNameRequired,
    QueryFailed,
    OutOfMemory,
};

pub const ReplaceAssetsError = error{
    WorkspaceIdNameRequired,
    SkillNotFound,
    AssetPathRequired,
    AssetTooLarge,
    WriteFailed,
    OutOfMemory,
};

/// The SELECT list, shared by every read so no call site can return a
/// different shape. `COALESCE` flattens SQL NULL and guards a row written
/// before a column existed, so the JS side never sees a null string.
const SELECT_COLUMNS =
    "SELECT id, workspace_id, name, COALESCE(description, ''), COALESCE(content, ''), " ++
    "COALESCE(created_at, ''), COALESCE(updated_at, ''), COALESCE(is_can_auto_improve, 1) " ++
    "FROM skills";

const SELECT_METADATA_COLUMNS =
    "SELECT id, skill_id, key, COALESCE(value, ''), COALESCE(created_at, ''), " ++
    "COALESCE(updated_at, '') FROM skill_metadata";

const SELECT_ASSET_COLUMNS =
    "SELECT id, skill_id, rel_path, COALESCE(content, ''), COALESCE(created_at, '') " ++
    "FROM skill_assets";

/// Positional dupe, so a column reorder becomes a compile error in exactly
/// one place.
fn rowFromValues(allocator: std.mem.Allocator, values: []const []const u8) !SkillRow {
    return .{
        .id = try allocator.dupe(u8, values[0]),
        .workspace_id = try allocator.dupe(u8, values[1]),
        .name = try allocator.dupe(u8, values[2]),
        .description = try allocator.dupe(u8, values[3]),
        .content = try allocator.dupe(u8, values[4]),
        .created_at = try allocator.dupe(u8, values[5]),
        .updated_at = try allocator.dupe(u8, values[6]),
        .is_can_auto_improve = !std.mem.eql(u8, values[7], "0"),
    };
}

fn metadataFromValues(allocator: std.mem.Allocator, values: []const []const u8) !SkillMetadataRow {
    return .{
        .id = try allocator.dupe(u8, values[0]),
        .skill_id = try allocator.dupe(u8, values[1]),
        .key = try allocator.dupe(u8, values[2]),
        .value = try allocator.dupe(u8, values[3]),
        .created_at = try allocator.dupe(u8, values[4]),
        .updated_at = try allocator.dupe(u8, values[5]),
    };
}

fn assetFromValues(allocator: std.mem.Allocator, values: []const []const u8) !SkillAssetRow {
    return .{
        .id = try allocator.dupe(u8, values[0]),
        .skill_id = try allocator.dupe(u8, values[1]),
        .rel_path = try allocator.dupe(u8, values[2]),
        .content = try allocator.dupe(u8, values[3]),
        .created_at = try allocator.dupe(u8, values[4]),
    };
}

/// True when `name` is a legal skill name: 1..MAX_NAME_BYTES of
/// `[A-Za-z0-9._-]`, with no leading or trailing dot — the dot rule is the
/// load-bearing one, because `name` is joined onto a materialisation dir.
pub fn isValidSkillName(name: []const u8) bool {
    if (name.len == 0 or name.len > MAX_NAME_BYTES) return false;
    if (name[0] == '.' or name[name.len - 1] == '.') return false;
    for (name) |c| {
        if (!(std.ascii.isAlphanumeric(c) or c == '.' or c == '_' or c == '-')) return false;
    }
    return true;
}

/// Every skill in one workspace, ordered by name — which rides the
/// `UNIQUE (workspace_id, name)` index, so the listing needs no second index.
pub fn listSkills(
    allocator: std.mem.Allocator,
    db: *database.Db,
    workspace_id: []const u8,
) ListSkillsError![]SkillRow {
    if (workspace_id.len == 0) return error.WorkspaceIdRequired;

    var q = db.query(
        allocator,
        SELECT_COLUMNS ++ " WHERE workspace_id = ? ORDER BY name",
        &[_][]const u8{workspace_id},
    ) catch return error.QueryFailed;
    defer q.deinit();

    var list: std.ArrayList(SkillRow) = .empty;
    // On a mid-iteration OOM the already-built rows would leak; unwind them
    // here rather than at each `try`.
    errdefer freeSkillRows(allocator, list.items);

    while (q.next() catch return error.QueryFailed) |r| {
        defer r.deinit(allocator);
        try list.append(allocator, try rowFromValues(allocator, r.values));
    }
    return list.toOwnedSlice(allocator);
}

/// One skill by name, scoped to `workspace_id`. A name that belongs to
/// another workspace reports `error.NotFound`, not a distinct "wrong
/// workspace" error: saying it exists would leak a foreign row.
pub fn getSkillByName(
    allocator: std.mem.Allocator,
    db: *database.Db,
    workspace_id: []const u8,
    name: []const u8,
) GetSkillError!SkillRow {
    if (workspace_id.len == 0 or name.len == 0) return error.WorkspaceIdNameRequired;

    var q = db.query(
        allocator,
        SELECT_COLUMNS ++ " WHERE workspace_id = ? AND name = ?",
        &[_][]const u8{ workspace_id, name },
    ) catch return error.QueryFailed;
    defer q.deinit();

    const r = (q.next() catch return error.QueryFailed) orelse return error.NotFound;
    defer r.deinit(allocator);
    return rowFromValues(allocator, r.values) catch return error.OutOfMemory;
}

/// Insert a skill, or replace the one already holding that name here.
/// Returns the stored row so the caller learns the canonical id its assets
/// hang off; `ON CONFLICT` leaves `id` alone, or they would orphan.
pub fn upsertSkill(
    allocator: std.mem.Allocator,
    db: *database.Db,
    args: UpsertSkillArgs,
) UpsertSkillError!SkillRow {
    if (args.workspace_id.len == 0 or args.name.len == 0) return error.WorkspaceIdNameRequired;
    if (args.name.len > MAX_NAME_BYTES) return error.NameTooLong;
    if (args.content.len > MAX_CONTENT_BYTES) return error.ContentTooLarge;

    const skill_id = try std.fmt.allocPrint(allocator, "sk_{d}", .{helpers.unixTimestampNanos()});
    defer allocator.free(skill_id);

    // No opinion means auto-improvable; only an explicit `false` locks it.
    // The importer re-runs on every start-up, so the ON CONFLICT clause
    // below leaves this column alone — a reset would drop the human's lock.
    const is_can_auto_improve: []const u8 = if (args.is_can_auto_improve orelse true) "1" else "0";

    // One transaction: the row and the metadata projected out of its body
    // must land together, or a crash between them leaves metadata pointing at
    // a body that no longer says it.
    var tx = db.begin() catch return error.WriteFailed;
    defer tx.commitOrRollback() catch {};
    errdefer tx.rollback() catch {};

    // COALESCE(NULLIF(?, ''), '') on every NOT NULL text column: `exec`
    // binds a zero-length slice as SQL NULL, and an empty description is a
    // legitimate state that has to round-trip as "" rather than fail.
    tx.exec(allocator,
        \\INSERT INTO skills (id, workspace_id, name, description, content, is_can_auto_improve, created_at, updated_at)
        \\VALUES (?, ?, COALESCE(NULLIF(?, ''), ''), COALESCE(NULLIF(?, ''), ''), COALESCE(NULLIF(?, ''), ''), ?, CURRENT_TIMESTAMP, CURRENT_TIMESTAMP)
        \\ON CONFLICT (workspace_id, name) DO UPDATE SET
        \\    description = COALESCE(NULLIF(excluded.description, ''), ''),
        \\    content = COALESCE(NULLIF(excluded.content, ''), ''),
        \\    updated_at = CURRENT_TIMESTAMP
    , &[_][]const u8{ skill_id, args.workspace_id, args.name, args.description, args.content, is_can_auto_improve }) catch
        return error.WriteFailed;

    // The stored id, not the freshly minted one: `ON CONFLICT` keeps the
    // existing row's id so its assets and metadata stay attached to it.
    const stored_id = try storedSkillId(allocator, &tx, args.workspace_id, args.name);
    defer allocator.free(stored_id);
    projectMetadata(allocator, &tx, stored_id, args.content) catch return error.WriteFailed;

    tx.commit() catch return error.WriteFailed;

    return getSkillByName(allocator, db, args.workspace_id, args.name) catch |err| switch (err) {
        error.NotFound,
        error.WorkspaceIdNameRequired,
        error.QueryFailed,
        => error.RowNotFoundAfterWrite,
        error.OutOfMemory => error.WriteFailed,
    };
}

/// Patch a skill by name. Absent fields keep their current value;
/// `updated_at` always advances so a re-import is visible as a change.
pub fn updateSkill(
    allocator: std.mem.Allocator,
    db: *database.Db,
    workspace_id: []const u8,
    name: []const u8,
    patch: UpdateSkillArgs,
) UpdateSkillError!SkillRow {
    if (workspace_id.len == 0 or name.len == 0) return error.WorkspaceIdNameRequired;
    if (patch.content) |c| {
        if (c.len > MAX_CONTENT_BYTES) return error.ContentTooLarge;
    }

    // Load the current values so an absent field is a true no-op rather than
    // a wipe. Without this, "update only the description" would blank the
    // body — which for a skill IS the whole instruction set.
    const existing = getSkillByName(allocator, db, workspace_id, name) catch
        return error.NotFound;
    defer freeSkillRow(allocator, existing);

    const description = patch.description orelse existing.description;
    const content = patch.content orelse existing.content;
    const is_can_auto_improve = patch.is_can_auto_improve orelse existing.is_can_auto_improve;
    if (std.mem.eql(u8, description, existing.description) and
        std.mem.eql(u8, content, existing.content) and
        is_can_auto_improve == existing.is_can_auto_improve) return error.NothingToChange;

    var tx = db.begin() catch return error.UpdateFailed;
    defer tx.commitOrRollback() catch {};
    errdefer tx.rollback() catch {};

    tx.exec(allocator,
        \\UPDATE skills
        \\SET description = COALESCE(NULLIF(?, ''), ''), content = COALESCE(NULLIF(?, ''), ''), is_can_auto_improve = ?, updated_at = CURRENT_TIMESTAMP
        \\WHERE workspace_id = ? AND name = ?
    , &[_][]const u8{ description, content, if (is_can_auto_improve) "1" else "0", workspace_id, name }) catch
        return error.UpdateFailed;

    // The body may have carried metadata in or out of it, so the projection
    // is re-derived rather than patched: a key deleted from the frontmatter
    // has to lose its row.
    projectMetadata(allocator, &tx, existing.id, content) catch return error.UpdateFailed;

    tx.commit() catch return error.UpdateFailed;

    return getSkillByName(allocator, db, workspace_id, name) catch
        return error.UpdateFailed;
}

/// Delete a skill AND its companion assets. Scoped like every other read: a
/// foreign name reports `error.NotFound` and deletes nothing. The asset
/// DELETE is explicit because `PRAGMA foreign_keys` is off project-wide.
pub fn deleteSkill(
    allocator: std.mem.Allocator,
    db: *database.Db,
    workspace_id: []const u8,
    name: []const u8,
) DeleteSkillError!void {
    if (workspace_id.len == 0 or name.len == 0) return error.WorkspaceIdNameRequired;

    // Resolve the id FIRST so the asset delete is scoped to THIS skill: a
    // subquery on an unqualified name would clear another workspace's
    // companions.
    const row = getSkillByName(allocator, db, workspace_id, name) catch |err| switch (err) {
        error.NotFound, error.WorkspaceIdNameRequired => return error.NotFound,
        error.QueryFailed, error.OutOfMemory => return error.DeleteFailed,
    };
    defer freeSkillRow(allocator, row);

    var tx = db.begin() catch return error.DeleteFailed;
    defer tx.commitOrRollback() catch {};
    errdefer tx.rollback() catch {};

    // Both children explicitly: `PRAGMA foreign_keys` is off project-wide, so
    // the declared CASCADE never fires.
    tx.exec(allocator, "DELETE FROM skill_metadata WHERE skill_id = ?", &[_][]const u8{row.id}) catch
        return error.DeleteFailed;
    tx.exec(allocator, "DELETE FROM skill_assets WHERE skill_id = ?", &[_][]const u8{row.id}) catch
        return error.DeleteFailed;
    tx.exec(
        allocator,
        "DELETE FROM skills WHERE workspace_id = ? AND name = ?",
        &[_][]const u8{ workspace_id, name },
    ) catch return error.DeleteFailed;

    tx.commit() catch return error.DeleteFailed;
}

/// One skill's metadata, ordered by key so a rendered list is stable.
pub fn listMetadata(
    allocator: std.mem.Allocator,
    db: *database.Db,
    workspace_id: []const u8,
    name: []const u8,
) ListMetadataError![]SkillMetadataRow {
    if (workspace_id.len == 0 or name.len == 0) return error.WorkspaceIdNameRequired;

    var q = db.query(
        allocator,
        SELECT_METADATA_COLUMNS ++
            " WHERE skill_id = (SELECT id FROM skills WHERE workspace_id = ? AND name = ?)" ++
            " ORDER BY key",
        &[_][]const u8{ workspace_id, name },
    ) catch return error.QueryFailed;
    defer q.deinit();

    var list: std.ArrayList(SkillMetadataRow) = .empty;
    errdefer freeSkillMetadataRows(allocator, list.items);

    while (q.next() catch return error.QueryFailed) |r| {
        defer r.deinit(allocator);
        try list.append(allocator, try metadataFromValues(allocator, r.values));
    }
    return list.toOwnedSlice(allocator);
}

/// The id `(workspace_id, name)` resolves to, for a caller that has just
/// written the row and must not guess.
fn storedSkillId(
    allocator: std.mem.Allocator,
    tx: *database.Db.Transaction,
    workspace_id: []const u8,
    name: []const u8,
) UpsertSkillError![]u8 {
    var q = tx.query(
        allocator,
        "SELECT id FROM skills WHERE workspace_id = ? AND name = ?",
        &[_][]const u8{ workspace_id, name },
    ) catch return error.WriteFailed;
    defer q.deinit();
    const r = (q.next() catch return error.WriteFailed) orelse return error.WriteFailed;
    defer r.deinit(allocator);
    return allocator.dupe(u8, r.values[0]) catch return error.OutOfMemory;
}

/// Replace `skill_id`'s metadata with the frontmatter projection of
/// `content`. Replace, never merge: a key the body no longer carries must
/// lose its row, or the table would outlive the file it claims to describe.
fn projectMetadata(
    allocator: std.mem.Allocator,
    tx: *database.Db.Transaction,
    skill_id: []const u8,
    content: []const u8,
) !void {
    tx.exec(allocator, "DELETE FROM skill_metadata WHERE skill_id = ?", &[_][]const u8{skill_id}) catch
        return error.WriteFailed;

    var parsed = try frontmatter.parse(allocator, content);
    defer parsed.deinit(allocator);

    for (parsed.pairs, 0..) |pair, i| {
        const id = try std.fmt.allocPrint(allocator, "sm_{d}_{d}", .{ helpers.unixTimestampNanos(), i });
        defer allocator.free(id);

        tx.exec(allocator,
            \\INSERT OR REPLACE INTO skill_metadata (id, skill_id, key, value, created_at, updated_at)
            \\VALUES (?, ?, ?, ?, CURRENT_TIMESTAMP, CURRENT_TIMESTAMP)
        , &[_][]const u8{ id, skill_id, pair.key, pair.value }) catch
            return error.WriteFailed;
    }
}

/// Every companion file of one skill, ordered by `rel_path` so the
/// materialised directory is written in a stable order.
pub fn listAssets(
    allocator: std.mem.Allocator,
    db: *database.Db,
    workspace_id: []const u8,
    name: []const u8,
) ListAssetsError![]SkillAssetRow {
    if (workspace_id.len == 0 or name.len == 0) return error.WorkspaceIdNameRequired;

    var q = db.query(
        allocator,
        SELECT_ASSET_COLUMNS ++
            " WHERE skill_id = (SELECT id FROM skills WHERE workspace_id = ? AND name = ?)" ++
            " ORDER BY rel_path",
        &[_][]const u8{ workspace_id, name },
    ) catch return error.QueryFailed;
    defer q.deinit();

    var list: std.ArrayList(SkillAssetRow) = .empty;
    errdefer freeSkillAssetRows(allocator, list.items);

    while (q.next() catch return error.QueryFailed) |r| {
        defer r.deinit(allocator);
        try list.append(allocator, try assetFromValues(allocator, r.values));
    }
    return list.toOwnedSlice(allocator);
}

/// Replace a skill's whole companion set in one transaction. Replace, not
/// merge: the caller hands over the directory as it is now, so a companion
/// whose file is gone must lose its row rather than linger half-written.
pub fn replaceAssets(
    allocator: std.mem.Allocator,
    db: *database.Db,
    workspace_id: []const u8,
    name: []const u8,
    assets: []const SkillAssetInput,
) ReplaceAssetsError!void {
    if (workspace_id.len == 0 or name.len == 0) return error.WorkspaceIdNameRequired;

    const row = getSkillByName(allocator, db, workspace_id, name) catch |err| switch (err) {
        error.NotFound, error.WorkspaceIdNameRequired => return error.SkillNotFound,
        error.QueryFailed, error.OutOfMemory => return error.WriteFailed,
    };
    defer freeSkillRow(allocator, row);

    // Validate the whole batch BEFORE opening the transaction, so a bad
    // path in the last file cannot leave half a bundle written.
    for (assets) |a| {
        if (a.rel_path.len == 0) return error.AssetPathRequired;
        if (a.content.len > MAX_ASSET_BYTES) return error.AssetTooLarge;
    }

    var tx = db.begin() catch return error.WriteFailed;
    defer tx.commitOrRollback() catch {};
    errdefer tx.rollback() catch {};

    tx.exec(allocator, "DELETE FROM skill_assets WHERE skill_id = ?", &[_][]const u8{row.id}) catch
        return error.WriteFailed;

    for (assets, 0..) |a, i| {
        const asset_id = try std.fmt.allocPrint(
            allocator,
            "sa_{d}_{d}",
            .{ helpers.unixTimestampNanos(), i },
        );
        defer allocator.free(asset_id);

        // OR REPLACE, not OR IGNORE: every row for this skill was just
        // deleted, so a collision can only be a duplicate `rel_path` inside
        // ONE batch, where the last writer is the right answer.
        tx.exec(allocator,
            \\INSERT OR REPLACE INTO skill_assets (id, skill_id, rel_path, content, created_at)
            \\VALUES (?, ?, COALESCE(NULLIF(?, ''), ''), COALESCE(NULLIF(?, ''), ''), CURRENT_TIMESTAMP)
        , &[_][]const u8{ asset_id, row.id, a.rel_path, a.content }) catch
            return error.WriteFailed;
    }

    tx.commit() catch return error.WriteFailed;
}

/// Free a single row's owned strings.
pub fn freeSkillRow(allocator: std.mem.Allocator, row: SkillRow) void {
    allocator.free(row.id);
    allocator.free(row.workspace_id);
    allocator.free(row.name);
    allocator.free(row.description);
    allocator.free(row.content);
    allocator.free(row.created_at);
    allocator.free(row.updated_at);
}

/// Free a slice of rows. The slice header is freed last.
pub fn freeSkillRows(allocator: std.mem.Allocator, rows: []SkillRow) void {
    for (rows) |row| freeSkillRow(allocator, row);
    allocator.free(rows);
}

pub fn freeSkillMetadataRow(allocator: std.mem.Allocator, row: SkillMetadataRow) void {
    allocator.free(row.id);
    allocator.free(row.skill_id);
    allocator.free(row.key);
    allocator.free(row.value);
    allocator.free(row.created_at);
    allocator.free(row.updated_at);
}

pub fn freeSkillMetadataRows(allocator: std.mem.Allocator, rows: []SkillMetadataRow) void {
    for (rows) |row| freeSkillMetadataRow(allocator, row);
    allocator.free(rows);
}

pub fn freeSkillAssetRow(allocator: std.mem.Allocator, row: SkillAssetRow) void {
    allocator.free(row.id);
    allocator.free(row.skill_id);
    allocator.free(row.rel_path);
    allocator.free(row.content);
    allocator.free(row.created_at);
}

pub fn freeSkillAssetRows(allocator: std.mem.Allocator, rows: []SkillAssetRow) void {
    for (rows) |row| freeSkillAssetRow(allocator, row);
    allocator.free(rows);
}
// ============================================================================
// skills_store — inline tests
// ============================================================================

// The migration's own tests pin the SCHEMA; these pin the BEHAVIOUR the
// tools and handlers depend on, against the real Migration 101 tables — an
// empty description, both isolation directions, re-import, patch, delete.

const testing = std.testing;

const StoreTestCtx = struct {
    db: database.Db,
    threaded: std.Io.Threaded,
};

/// Real Migration 101 tables on an in-memory database.
fn setupStoreDb() !StoreTestCtx {
    const alloc = testing.allocator;
    var threaded = std.Io.Threaded.init(alloc, .{});
    errdefer threaded.deinit();
    const io = threaded.io();
    var db: database.Db = .{};
    errdefer db.deinit();
    try db.init(io, ":memory:");
    errdefer db.deinit();
    try migration.Migration102CreateSkills.up(&db, alloc);
    try migration.Migration119CreateSkillMetadata.up(&db, alloc);
    return .{ .db = db, .threaded = threaded };
}

fn expectRowCount(ctx: *StoreTestCtx, sql: []const u8, expected: []const u8) !void {
    const alloc = testing.allocator;
    var q = try ctx.db.query(alloc, sql, &.{});
    defer q.deinit();
    const row = (try q.next()) orelse return error.NoRows;
    defer row.deinit(alloc);
    try testing.expectEqualStrings(expected, row.values[0]);
}

test "skills_store round-trips a skill body, including an empty description" {
    const alloc = testing.allocator;
    var ctx = try setupStoreDb();
    defer ctx.threaded.deinit();
    defer ctx.db.deinit();

    const row = try upsertSkill(alloc, &ctx.db, .{
        .workspace_id = "ws_a",
        .name = "zig-trap",
        .description = "",
        .content = "---\nname: zig-trap\n---\nbody",
    });
    defer freeSkillRow(alloc, row);

    // The description is empty because the model did not write one yet.
    // It must come back as "" and NOT as a failed write / null.
    try testing.expectEqualStrings("", row.description);
    try testing.expectEqualStrings("---\nname: zig-trap\n---\nbody", row.content);
    try testing.expectEqualStrings("ws_a", row.workspace_id);

    const fetched = try getSkillByName(alloc, &ctx.db, "ws_a", "zig-trap");
    defer freeSkillRow(alloc, fetched);
    try testing.expectEqualStrings(row.id, fetched.id);
    try testing.expectEqualStrings("", fetched.description);
}

test "skills_store isolates one workspace from another in both directions" {
    const alloc = testing.allocator;
    var ctx = try setupStoreDb();
    defer ctx.threaded.deinit();
    defer ctx.db.deinit();

    const created_1 = try upsertSkill(alloc, &ctx.db, .{
        .workspace_id = "ws_a",
        .name = "pdf",
        .content = "A's copy",
    });
    defer freeSkillRow(alloc, created_1);

    // Read: ws_b cannot see ws_a's row even by exact name.
    try testing.expectError(
        error.NotFound,
        getSkillByName(alloc, &ctx.db, "ws_b", "pdf"),
    );

    // Write: ws_b is free to hold its OWN `pdf`. Same name, different
    // workspace, two rows — the whole point of dropping the global tier.
    const b = try upsertSkill(alloc, &ctx.db, .{
        .workspace_id = "ws_b",
        .name = "pdf",
        .content = "B's copy",
    });
    defer freeSkillRow(alloc, b);
    try testing.expectEqualStrings("B's copy", b.content);

    const a = try getSkillByName(alloc, &ctx.db, "ws_a", "pdf");
    defer freeSkillRow(alloc, a);
    try testing.expectEqualStrings("A's copy", a.content);
}

test "skills_store delete on a foreign name deletes nothing" {
    const alloc = testing.allocator;
    var ctx = try setupStoreDb();
    defer ctx.threaded.deinit();
    defer ctx.db.deinit();

    const created_2 = try upsertSkill(alloc, &ctx.db, .{
        .workspace_id = "ws_a",
        .name = "pdf",
        .content = "A's copy",
    });
    defer freeSkillRow(alloc, created_2);

    try testing.expectError(
        error.NotFound,
        deleteSkill(alloc, &ctx.db, "ws_b", "pdf"),
    );
    try expectRowCount(&ctx, "SELECT COUNT(*) FROM skills", "1");
}

test "skills_store re-upsert updates in place and keeps the id" {
    const alloc = testing.allocator;
    var ctx = try setupStoreDb();
    defer ctx.threaded.deinit();
    defer ctx.db.deinit();

    const first = try upsertSkill(alloc, &ctx.db, .{
        .workspace_id = "ws_a",
        .name = "pdf",
        .content = "old body",
    });
    defer freeSkillRow(alloc, first);

    // The importer runs again on every start-up; a second run must UPDATE,
    // not collide on UNIQUE, and must not re-issue the id that every
    // skill_assets row points at.
    const second = try upsertSkill(alloc, &ctx.db, .{
        .workspace_id = "ws_a",
        .name = "pdf",
        .description = "Work with PDFs",
        .content = "new body",
    });
    defer freeSkillRow(alloc, second);

    try testing.expectEqualStrings(first.id, second.id);
    try testing.expectEqualStrings("new body", second.content);
    try expectRowCount(&ctx, "SELECT COUNT(*) FROM skills", "1");
}

test "skills_store patch keeps the field it does not mention" {
    const alloc = testing.allocator;
    var ctx = try setupStoreDb();
    defer ctx.threaded.deinit();
    defer ctx.db.deinit();

    const created_3 = try upsertSkill(alloc, &ctx.db, .{
        .workspace_id = "ws_a",
        .name = "pdf",
        .description = "old description",
        .content = "the body that must survive",
    });
    defer freeSkillRow(alloc, created_3);

    const patched = try updateSkill(alloc, &ctx.db, "ws_a", "pdf", .{
        .description = "new description",
    });
    defer freeSkillRow(alloc, patched);

    // Without the load-current-first step, `edit_skill`'s description-only
    // patch would blank the instruction set — which IS the whole skill.
    try testing.expectEqualStrings("new description", patched.description);
    try testing.expectEqualStrings("the body that must survive", patched.content);
}

test "skills_store reports NothingToChange instead of bumping updated_at" {
    const alloc = testing.allocator;
    var ctx = try setupStoreDb();
    defer ctx.threaded.deinit();
    defer ctx.db.deinit();

    const created_4 = try upsertSkill(alloc, &ctx.db, .{
        .workspace_id = "ws_a",
        .name = "pdf",
        .description = "same",
        .content = "same body",
    });
    defer freeSkillRow(alloc, created_4);

    try testing.expectError(
        error.NothingToChange,
        updateSkill(alloc, &ctx.db, "ws_a", "pdf", .{
            .description = "same",
            .content = "same body",
        }),
    );
}

test "skills_store stores companion assets and scopes them to the workspace" {
    const alloc = testing.allocator;
    var ctx = try setupStoreDb();
    defer ctx.threaded.deinit();
    defer ctx.db.deinit();

    const created_5 = try upsertSkill(alloc, &ctx.db, .{
        .workspace_id = "ws_a",
        .name = "pdf",
        .content = "body",
    });
    defer freeSkillRow(alloc, created_5);

    try replaceAssets(alloc, &ctx.db, "ws_a", "pdf", &.{
        .{ .rel_path = "scripts/convert.py", .content = "print('hi')" },
        .{ .rel_path = "reference.md", .content = "# ref" },
    });

    const assets = try listAssets(alloc, &ctx.db, "ws_a", "pdf");
    defer freeSkillAssetRows(alloc, assets);
    try testing.expectEqual(@as(usize, 2), assets.len);

    // A different workspace's `pdf` sees none of them — the asset lookup
    // goes through the workspace-scoped subquery, not a bare name match.
    const foreign = try listAssets(alloc, &ctx.db, "ws_b", "pdf");
    defer freeSkillAssetRows(alloc, foreign);
    try testing.expectEqual(@as(usize, 0), foreign.len);
}

test "skills_store replaceAssets drops a companion that is gone from disk" {
    const alloc = testing.allocator;
    var ctx = try setupStoreDb();
    defer ctx.threaded.deinit();
    defer ctx.db.deinit();

    const created_6 = try upsertSkill(alloc, &ctx.db, .{
        .workspace_id = "ws_a",
        .name = "pdf",
        .content = "body",
    });
    defer freeSkillRow(alloc, created_6);
    try replaceAssets(alloc, &ctx.db, "ws_a", "pdf", &.{
        .{ .rel_path = "a.py", .content = "1" },
        .{ .rel_path = "b.py", .content = "2" },
    });

    // The file `b.py` was deleted from the bundle. A merge would leave it
    // alive in the DB and the body would still reference a script that can
    // no longer be materialised.
    try replaceAssets(alloc, &ctx.db, "ws_a", "pdf", &.{
        .{ .rel_path = "a.py", .content = "1" },
    });

    const assets = try listAssets(alloc, &ctx.db, "ws_a", "pdf");
    defer freeSkillAssetRows(alloc, assets);
    try testing.expectEqual(@as(usize, 1), assets.len);
    try testing.expectEqualStrings("a.py", assets[0].rel_path);
}

test "skills_store deleteSkill takes the skill's companions with it" {
    const alloc = testing.allocator;
    var ctx = try setupStoreDb();
    defer ctx.threaded.deinit();
    defer ctx.db.deinit();

    const created_7 = try upsertSkill(alloc, &ctx.db, .{
        .workspace_id = "ws_a",
        .name = "pdf",
        .content = "body",
    });
    defer freeSkillRow(alloc, created_7);
    try replaceAssets(alloc, &ctx.db, "ws_a", "pdf", &.{
        .{ .rel_path = "scripts/convert.py", .content = "print('hi')" },
    });

    try deleteSkill(alloc, &ctx.db, "ws_a", "pdf");

    // `PRAGMA foreign_keys` is off project-wide, so the declared CASCADE
    // does nothing. If the explicit asset DELETE regressed, these rows
    // would survive and a re-import of the name would collide on UNIQUE.
    try expectRowCount(&ctx, "SELECT COUNT(*) FROM skills", "0");
    try expectRowCount(&ctx, "SELECT COUNT(*) FROM skill_assets", "0");
}

test "skills_store lists one workspace in name order" {
    const alloc = testing.allocator;
    var ctx = try setupStoreDb();
    defer ctx.threaded.deinit();
    defer ctx.db.deinit();

    for ([_][]const u8{ "zebra", "alpha", "mango" }) |n| {
        const created = try upsertSkill(alloc, &ctx.db, .{
            .workspace_id = "ws_a",
            .name = n,
            .content = "x",
        });
        defer freeSkillRow(alloc, created);
    }
    const other = try upsertSkill(alloc, &ctx.db, .{
        .workspace_id = "ws_b",
        .name = "not-mine",
        .content = "x",
    });
    defer freeSkillRow(alloc, other);

    const rows = try listSkills(alloc, &ctx.db, "ws_a");
    defer freeSkillRows(alloc, rows);

    try testing.expectEqual(@as(usize, 3), rows.len);
    try testing.expectEqualStrings("alpha", rows[0].name);
    try testing.expectEqualStrings("mango", rows[1].name);
    try testing.expectEqualStrings("zebra", rows[2].name);
}

test "skills_store rejects a missing workspace id before touching SQL" {
    const alloc = testing.allocator;
    var ctx = try setupStoreDb();
    defer ctx.threaded.deinit();
    defer ctx.db.deinit();

    // An empty workspace_id must NOT reach the query: `Backend.exec`
    // binds "" as SQL NULL, and `workspace_id` is NOT NULL.
    try testing.expectError(
        error.WorkspaceIdNameRequired,
        upsertSkill(alloc, &ctx.db, .{ .workspace_id = "", .name = "x" }),
    );
    try testing.expectError(
        error.WorkspaceIdRequired,
        listSkills(alloc, &ctx.db, ""),
    );
}

test "skills_store isValidSkillName rejects anything that could escape a directory" {
    try testing.expect(isValidSkillName("pdf"));
    try testing.expect(isValidSkillName("zig-0.16-trap"));
    try testing.expect(isValidSkillName("a.b_c-d1"));

    // `name` is joined onto the materialisation directory by `use_skill`.
    try testing.expect(!isValidSkillName(".."));
    try testing.expect(!isValidSkillName("../../etc"));
    try testing.expect(!isValidSkillName("a/b"));
    try testing.expect(!isValidSkillName(""));
    try testing.expect(!isValidSkillName(".hidden"));
    try testing.expect(!isValidSkillName("trailing."));
    try testing.expect(!isValidSkillName("has space"));
}

test "skills_store defaults a new skill to auto-improvable and stores an explicit lock" {
    const alloc = testing.allocator;
    var ctx = try setupStoreDb();
    defer ctx.threaded.deinit();
    defer ctx.db.deinit();

    // No opinion from the caller means "the agent may evolve this", which is
    // the state every skill already installed had before the column existed.
    const open = try upsertSkill(alloc, &ctx.db, .{
        .workspace_id = "ws_a",
        .name = "open",
        .content = "body",
    });
    defer freeSkillRow(alloc, open);
    try testing.expect(open.is_can_auto_improve);

    const locked = try upsertSkill(alloc, &ctx.db, .{
        .workspace_id = "ws_a",
        .name = "locked",
        .content = "body",
        .is_can_auto_improve = false,
    });
    defer freeSkillRow(alloc, locked);
    try testing.expect(!locked.is_can_auto_improve);

    const read_back = try getSkillByName(alloc, &ctx.db, "ws_a", "locked");
    defer freeSkillRow(alloc, read_back);
    try testing.expect(!read_back.is_can_auto_improve);
}

test "skills_store re-upsert never resets a skill's auto-improve lock" {
    const alloc = testing.allocator;
    var ctx = try setupStoreDb();
    defer ctx.threaded.deinit();
    defer ctx.db.deinit();

    const created = try upsertSkill(alloc, &ctx.db, .{
        .workspace_id = "ws_a",
        .name = "pdf",
        .content = "old body",
    });
    defer freeSkillRow(alloc, created);

    const locked = try updateSkill(alloc, &ctx.db, "ws_a", "pdf", .{ .is_can_auto_improve = false });
    defer freeSkillRow(alloc, locked);
    try testing.expect(!locked.is_can_auto_improve);

    // The boot-time importer re-runs on every start-up through exactly this
    // call. If the ON CONFLICT clause wrote the flag, a human's lock would
    // be silently thrown away on the next restart.
    const reimported = try upsertSkill(alloc, &ctx.db, .{
        .workspace_id = "ws_a",
        .name = "pdf",
        .description = "re-imported",
        .content = "new body",
    });
    defer freeSkillRow(alloc, reimported);
    try testing.expect(!reimported.is_can_auto_improve);
    try testing.expectEqualStrings("new body", reimported.content);
    try testing.expectEqualStrings("re-imported", reimported.description);
}

test "skills_store updateSkill toggles the lock without touching the body" {
    const alloc = testing.allocator;
    var ctx = try setupStoreDb();
    defer ctx.threaded.deinit();
    defer ctx.db.deinit();

    const created = try upsertSkill(alloc, &ctx.db, .{
        .workspace_id = "ws_a",
        .name = "pdf",
        .description = "the description that must survive",
        .content = "the body that must survive",
    });
    defer freeSkillRow(alloc, created);
    try testing.expect(created.is_can_auto_improve);

    const locked = try updateSkill(alloc, &ctx.db, "ws_a", "pdf", .{ .is_can_auto_improve = false });
    defer freeSkillRow(alloc, locked);
    try testing.expect(!locked.is_can_auto_improve);
    try testing.expectEqualStrings("the description that must survive", locked.description);
    try testing.expectEqualStrings("the body that must survive", locked.content);

    const unlocked = try updateSkill(alloc, &ctx.db, "ws_a", "pdf", .{ .is_can_auto_improve = true });
    defer freeSkillRow(alloc, unlocked);
    try testing.expect(unlocked.is_can_auto_improve);
    try testing.expectEqualStrings("the body that must survive", unlocked.content);
}

test "skills_store treats a flag-only patch as a change, not as NothingToChange" {
    const alloc = testing.allocator;
    var ctx = try setupStoreDb();
    defer ctx.threaded.deinit();
    defer ctx.db.deinit();

    const created = try upsertSkill(alloc, &ctx.db, .{
        .workspace_id = "ws_a",
        .name = "pdf",
        .description = "same",
        .content = "same body",
    });
    defer freeSkillRow(alloc, created);

    // Without the flag in the comparison this is the same row and the patch
    // is refused as a no-op — the toggle in the UI would be a button whose
    // only outcome is a 409.
    const locked = try updateSkill(alloc, &ctx.db, "ws_a", "pdf", .{ .is_can_auto_improve = false });
    defer freeSkillRow(alloc, locked);
    try testing.expect(!locked.is_can_auto_improve);
    try testing.expectEqualStrings("same", locked.description);
    try testing.expectEqualStrings("same body", locked.content);
}

test "skills_store lists the lock state per row, not per workspace" {
    const alloc = testing.allocator;
    var ctx = try setupStoreDb();
    defer ctx.threaded.deinit();
    defer ctx.db.deinit();

    const open = try upsertSkill(alloc, &ctx.db, .{
        .workspace_id = "ws_a",
        .name = "alpha",
        .content = "a",
    });
    defer freeSkillRow(alloc, open);
    const to_lock = try upsertSkill(alloc, &ctx.db, .{
        .workspace_id = "ws_a",
        .name = "beta",
        .content = "b",
    });
    defer freeSkillRow(alloc, to_lock);
    const locked = try updateSkill(alloc, &ctx.db, "ws_a", "beta", .{ .is_can_auto_improve = false });
    defer freeSkillRow(alloc, locked);

    const rows = try listSkills(alloc, &ctx.db, "ws_a");
    defer freeSkillRows(alloc, rows);

    try testing.expectEqual(@as(usize, 2), rows.len);
    try testing.expectEqualStrings("alpha", rows[0].name);
    try testing.expect(rows[0].is_can_auto_improve);
    try testing.expectEqualStrings("beta", rows[1].name);
    try testing.expect(!rows[1].is_can_auto_improve);
}

test "a skill's frontmatter keys land in skill_metadata, minus the promoted three" {
    const alloc = testing.allocator;
    var ctx = try setupStoreDb();
    defer ctx.threaded.deinit();
    defer ctx.db.deinit();

    const created = try upsertSkill(alloc, &ctx.db, .{
        .workspace_id = "ws_a",
        .name = "pdf",
        .description = "Work with PDFs",
        .content =
        \\---
        \\name: pdf
        \\description: Work with PDFs
        \\origin: ECC
        \\tags: [workflow, documents]
        \\---
        \\Run scripts/convert.py.
        ,
    });
    defer freeSkillRow(alloc, created);

    const rows = try listMetadata(alloc, &ctx.db, "ws_a", "pdf");
    defer freeSkillMetadataRows(alloc, rows);

    // Key-ordered, and only the keys with no column: `name` and
    // `description` are already on `skills`, and duplicating them here would
    // give one fact two homes.
    try testing.expectEqual(@as(usize, 2), rows.len);
    try testing.expectEqualStrings("origin", rows[0].key);
    try testing.expectEqualStrings("ECC", rows[0].value);
    try testing.expectEqualStrings("tags", rows[1].key);
    try testing.expectEqualStrings("[workflow, documents]", rows[1].value);
    try testing.expectEqualStrings(created.id, rows[0].skill_id);
}

test "a body with no frontmatter has no metadata rows" {
    const alloc = testing.allocator;
    var ctx = try setupStoreDb();
    defer ctx.threaded.deinit();
    defer ctx.db.deinit();

    const created = try upsertSkill(alloc, &ctx.db, .{
        .workspace_id = "ws_a",
        .name = "bare",
        .content = "## When to Use\n\nNo fence at all.\n",
    });
    defer freeSkillRow(alloc, created);

    const rows = try listMetadata(alloc, &ctx.db, "ws_a", "bare");
    defer freeSkillMetadataRows(alloc, rows);
    try testing.expectEqual(@as(usize, 0), rows.len);
}

test "rewriting the body REPLACES its metadata instead of merging it" {
    const alloc = testing.allocator;
    var ctx = try setupStoreDb();
    defer ctx.threaded.deinit();
    defer ctx.db.deinit();

    const created = try upsertSkill(alloc, &ctx.db, .{
        .workspace_id = "ws_a",
        .name = "pdf",
        .content = "---\nname: pdf\norigin: ECC\ntags: [a]\n---\nbody\n",
    });
    defer freeSkillRow(alloc, created);

    // The new body drops `origin` and adds `license`. A merge would leave
    // `origin` alive and the table would describe a file that no longer says
    // it, which is exactly the drift the table exists to prevent.
    const patched = try updateSkill(alloc, &ctx.db, "ws_a", "pdf", .{
        .content = "---\nname: pdf\ntags: [a]\nlicense: MIT\n---\nnew body\n",
    });
    defer freeSkillRow(alloc, patched);

    const rows = try listMetadata(alloc, &ctx.db, "ws_a", "pdf");
    defer freeSkillMetadataRows(alloc, rows);
    try testing.expectEqual(@as(usize, 2), rows.len);
    try testing.expectEqualStrings("license", rows[0].key);
    try testing.expectEqualStrings("tags", rows[1].key);
}

test "one workspace's skill name never exposes another workspace's metadata" {
    const alloc = testing.allocator;
    var ctx = try setupStoreDb();
    defer ctx.threaded.deinit();
    defer ctx.db.deinit();

    const created = try upsertSkill(alloc, &ctx.db, .{
        .workspace_id = "ws_a",
        .name = "pdf",
        .content = "---\nname: pdf\norigin: ECC\n---\nbody\n",
    });
    defer freeSkillRow(alloc, created);

    const foreign = try listMetadata(alloc, &ctx.db, "ws_b", "pdf");
    defer freeSkillMetadataRows(alloc, foreign);
    try testing.expectEqual(@as(usize, 0), foreign.len);
}

test "repairing a row through upsert keeps its metadata attached to the same skill id" {
    const alloc = testing.allocator;
    var ctx = try setupStoreDb();
    defer ctx.threaded.deinit();
    defer ctx.db.deinit();

    const first = try upsertSkill(alloc, &ctx.db, .{
        .workspace_id = "ws_a",
        .name = "pdf",
        .content = "---\nname: pdf\norigin: ECC\n---\nbody\n",
    });
    defer freeSkillRow(alloc, first);

    // The boot-time importer re-runs this on every start-up. `ON CONFLICT`
    // keeps the original id, so the re-projection has to hang off THAT id —
    // a second id would orphan every row the first one wrote.
    const again = try upsertSkill(alloc, &ctx.db, .{
        .workspace_id = "ws_a",
        .name = "pdf",
        .content = "---\nname: pdf\norigin: ECC\ntags: [x]\n---\nbody v2\n",
    });
    defer freeSkillRow(alloc, again);

    const rows = try listMetadata(alloc, &ctx.db, "ws_a", "pdf");
    defer freeSkillMetadataRows(alloc, rows);
    try testing.expectEqual(@as(usize, 2), rows.len);
    for (rows) |row| try testing.expectEqualStrings(first.id, row.skill_id);
}

test "deleting a skill takes its metadata with it" {
    const alloc = testing.allocator;
    var ctx = try setupStoreDb();
    defer ctx.threaded.deinit();
    defer ctx.db.deinit();

    const created = try upsertSkill(alloc, &ctx.db, .{
        .workspace_id = "ws_a",
        .name = "pdf",
        .content = "---\nname: pdf\norigin: ECC\n---\nbody\n",
    });
    defer freeSkillRow(alloc, created);

    try deleteSkill(alloc, &ctx.db, "ws_a", "pdf");

    // `PRAGMA foreign_keys` is off project-wide, so the declared CASCADE does
    // nothing: an explicit DELETE is the only thing that stops a re-import of
    // the same name from inheriting the old rows.
    try expectRowCount(&ctx, "SELECT COUNT(*) FROM skill_metadata", "0");
}
