//! Storage layer for workspace document folders (Migration 140). The depth,
//! cycle and "delete reparents" invariants live here because the agent tools
//! write through these functions too, not only the HTTP handlers.

const std = @import("std");
const database = @import("pabrikcore").database;
const helpers = @import("helpers");

/// Five levels. The sidebar rail is 240px and each level spends the 16px
/// `--sb-mark` slot, so a sixth level leaves 120px for a title.
pub const MAX_FOLDER_DEPTH: u8 = 5;

var folder_id_counter: std.atomic.Value(u64) = .init(0);

fn folderIdSeq() u64 {
    return folder_id_counter.fetchAdd(1, .monotonic);
}

pub const FolderRow = struct {
    id: []const u8,
    workspace_id: []const u8,
    /// `null` at the root. Allocator-owned when present.
    parent_id: ?[]const u8,
    name: []const u8,
    position: i64,
    created_at: []const u8,
    updated_at: []const u8,
};

pub const CreateFolderArgs = struct {
    workspace_id: []const u8,
    name: []const u8,
    /// `null` creates the folder at the root.
    parent_id: ?[]const u8 = null,
};

pub const UpdateFolderArgs = struct {
    name: ?[]const u8 = null,
    /// Set `move_parent` to move, so `parent_id = null` means "to the root"
    /// rather than "keep the current parent".
    parent_id: ?[]const u8 = null,
    move_parent: bool = false,
};

pub const CreateFolderError = error{
    WorkspaceIdRequired,
    NameRequired,
    ParentNotFound,
    TooDeep,
    InsertFailed,
    RowNotFoundAfterInsert,
    QueryFailed,
    OutOfMemory,
};

pub const UpdateFolderError = error{
    IdsRequired,
    NotFound,
    NotFoundOrEmptyName,
    NameRequired,
    ParentNotFound,
    CycleRefused,
    TooDeep,
    UpdateFailed,
    QueryFailed,
    OutOfMemory,
};

pub const DeleteFolderError = error{
    IdsRequired,
    NotFound,
    DeleteFailed,
    QueryFailed,
    TransactionFailed,
    OutOfMemory,
};

pub const ListFoldersError = error{
    WorkspaceIdRequired,
    QueryFailed,
    OutOfMemory,
};

const SELECT_COLUMNS =
    "SELECT id, workspace_id, COALESCE(parent_id, ''), name, " ++
    "COALESCE(CAST(position AS TEXT), '0'), " ++
    "COALESCE(CAST(created_at AS TEXT), ''), COALESCE(CAST(updated_at AS TEXT), '') " ++
    "FROM document_folders";

fn rowFromValues(allocator: std.mem.Allocator, values: []const []const u8) !FolderRow {
    const parent: ?[]const u8 = if (values[2].len == 0) null else try allocator.dupe(u8, values[2]);
    return .{
        .id = try allocator.dupe(u8, values[0]),
        .workspace_id = try allocator.dupe(u8, values[1]),
        .parent_id = parent,
        .name = try allocator.dupe(u8, values[3]),
        .position = std.fmt.parseInt(i64, values[4], 10) catch 0,
        .created_at = try allocator.dupe(u8, values[5]),
        .updated_at = try allocator.dupe(u8, values[6]),
    };
}

pub fn freeFolderRow(allocator: std.mem.Allocator, row: FolderRow) void {
    allocator.free(row.id);
    allocator.free(row.workspace_id);
    if (row.parent_id) |p| allocator.free(p);
    allocator.free(row.name);
    allocator.free(row.created_at);
    allocator.free(row.updated_at);
}

pub fn freeFolderRows(allocator: std.mem.Allocator, rows: []FolderRow) void {
    for (rows) |row| freeFolderRow(allocator, row);
    allocator.free(rows);
}

/// Every folder in one workspace, in saved order. The client assembles the
/// tree from `parent_id`; a per-level read would be an N+1 on the sidebar's
/// first paint.
pub fn listFolders(
    allocator: std.mem.Allocator,
    db: *database.Db,
    workspace_id: []const u8,
) ListFoldersError![]FolderRow {
    if (workspace_id.len == 0) return error.WorkspaceIdRequired;

    var q = db.query(
        allocator,
        SELECT_COLUMNS ++ " WHERE workspace_id = ? ORDER BY position ASC, created_at ASC, id ASC",
        &[_][]const u8{workspace_id},
    ) catch return error.QueryFailed;
    defer q.deinit();

    var list: std.ArrayList(FolderRow) = .empty;
    errdefer freeFolderRows(allocator, list.items);

    while (q.next() catch return error.QueryFailed) |r| {
        defer r.deinit(allocator);
        list.append(allocator, try rowFromValues(allocator, r.values)) catch return error.OutOfMemory;
    }
    return list.toOwnedSlice(allocator) catch return error.OutOfMemory;
}

pub fn getFolder(
    allocator: std.mem.Allocator,
    db: *database.Db,
    workspace_id: []const u8,
    folder_id: []const u8,
) UpdateFolderError!FolderRow {
    if (workspace_id.len == 0 or folder_id.len == 0) return error.IdsRequired;

    var q = db.query(
        allocator,
        SELECT_COLUMNS ++ " WHERE id = ? AND workspace_id = ?",
        &[_][]const u8{ folder_id, workspace_id },
    ) catch return error.QueryFailed;
    defer q.deinit();

    const r = (q.next() catch return error.QueryFailed) orelse return error.NotFound;
    defer r.deinit(allocator);
    return rowFromValues(allocator, r.values) catch return error.OutOfMemory;
}

/// `folder_id` exists in this workspace AND belongs to `parent_id` (which may
/// be null for the root). Used by the document write path so a document can
/// never point at a folder from another workspace.
pub fn folderExists(
    allocator: std.mem.Allocator,
    db: *database.Db,
    workspace_id: []const u8,
    folder_id: []const u8,
) bool {
    if (workspace_id.len == 0 or folder_id.len == 0) return false;
    var q = db.query(
        allocator,
        "SELECT id FROM document_folders WHERE id = ? AND workspace_id = ?",
        &[_][]const u8{ folder_id, workspace_id },
    ) catch return false;
    defer q.deinit();
    const r = (q.next() catch return false) orelse return false;
    r.deinit(allocator);
    return true;
}

/// The folder's parent, `null` at the root. `error.NotFound` when the folder
/// does not exist in this workspace.
fn parentOf(
    allocator: std.mem.Allocator,
    db: *database.Db,
    workspace_id: []const u8,
    folder_id: []const u8,
) (QueryOrDepthError)!?[]u8 {
    var q = db.query(
        allocator,
        "SELECT COALESCE(parent_id, '') FROM document_folders WHERE id = ? AND workspace_id = ?",
        &[_][]const u8{ folder_id, workspace_id },
    ) catch return error.QueryFailed;
    defer q.deinit();

    const r = (q.next() catch return error.QueryFailed) orelse return error.NotFound;
    defer r.deinit(allocator);
    if (r.values[0].len == 0) return null;
    return allocator.dupe(u8, r.values[0]) catch return error.OutOfMemory;
}

const QueryOrDepthError = error{ NotFound, QueryFailed, TooDeep, OutOfMemory };

/// Levels from the root: a root folder is 1, its child 2. Walks up rather than
/// trusting a stored number, so a corrupt row cannot report depth 1 forever.
fn depthOf(
    allocator: std.mem.Allocator,
    db: *database.Db,
    workspace_id: []const u8,
    folder_id: []const u8,
) QueryOrDepthError!u8 {
    var current = allocator.dupe(u8, folder_id) catch return error.OutOfMemory;
    defer allocator.free(current);

    var depth: u8 = 0;
    while (true) {
        depth += 1;
        if (depth > MAX_FOLDER_DEPTH) return error.TooDeep;
        const next = try parentOf(allocator, db, workspace_id, current);
        if (next) |p| {
            allocator.free(current);
            current = p;
        } else return depth;
    }
}

/// How many levels of children hang below this folder. 0 for a leaf.
fn deepestBelow(
    allocator: std.mem.Allocator,
    db: *database.Db,
    workspace_id: []const u8,
    folder_id: []const u8,
    guard: u8,
) (QueryOrDepthError)!u8 {
    if (guard == 0) return error.TooDeep;

    var q = db.query(
        allocator,
        "SELECT id FROM document_folders WHERE workspace_id = ? AND parent_id = ?",
        &[_][]const u8{ workspace_id, folder_id },
    ) catch return error.QueryFailed;
    defer q.deinit();

    var best: u8 = 0;
    while (q.next() catch return error.QueryFailed) |r| {
        const child = allocator.dupe(u8, r.values[0]) catch {
            r.deinit(allocator);
            return error.OutOfMemory;
        };
        defer allocator.free(child);
        r.deinit(allocator);

        const below = try deepestBelow(allocator, db, workspace_id, child, guard - 1);
        if (below + 1 > best) best = below + 1;
    }
    return best;
}

/// True when `candidate` sits at or below `ancestor` in the tree.
fn isAtOrBelow(
    allocator: std.mem.Allocator,
    db: *database.Db,
    workspace_id: []const u8,
    ancestor_id: []const u8,
    candidate_id: []const u8,
) (QueryOrDepthError)!bool {
    var current = allocator.dupe(u8, candidate_id) catch return error.OutOfMemory;
    defer allocator.free(current);

    var steps: u8 = 0;
    while (steps <= MAX_FOLDER_DEPTH) : (steps += 1) {
        if (std.mem.eql(u8, current, ancestor_id)) return true;
        const next = try parentOf(allocator, db, workspace_id, current);
        if (next) |p| {
            allocator.free(current);
            current = p;
        } else return false;
    }
    return error.TooDeep;
}

pub fn createFolder(
    allocator: std.mem.Allocator,
    db: *database.Db,
    args: CreateFolderArgs,
) CreateFolderError!FolderRow {
    if (args.workspace_id.len == 0) return error.WorkspaceIdRequired;

    const name = std.mem.trim(u8, args.name, " \t\n\r");
    if (name.len == 0) return error.NameRequired;

    if (args.parent_id) |parent_id| {
        if (parent_id.len > 0) {
            const parent_depth = depthOf(allocator, db, args.workspace_id, parent_id) catch |err| switch (err) {
                error.NotFound => return error.ParentNotFound,
                error.TooDeep => return error.TooDeep,
                error.QueryFailed => return error.QueryFailed,
                error.OutOfMemory => return error.OutOfMemory,
            };
            if (parent_depth + 1 > MAX_FOLDER_DEPTH) return error.TooDeep;
        }
    }

    const folder_id = std.fmt.allocPrint(
        allocator,
        "fld_{d}_{d}_{d}",
        .{ helpers.unixTimestampNanos(), helpers.process.getCurrentProcessId(), folderIdSeq() },
    ) catch return error.OutOfMemory;
    defer allocator.free(folder_id);

    const parent = args.parent_id orelse "";
    // `#` cannot appear in a folder id; "" binds as SQL NULL, so comparing
    // `COALESCE(parent_id, '')` against it would never match.
    const level = if (parent.len == 0) "#root" else parent;
    db.exec(allocator,
        \\INSERT INTO document_folders (id, workspace_id, parent_id, name, position, created_at, updated_at)
        \\VALUES (?, ?, NULLIF(?, ''), COALESCE(NULLIF(?, ''), 'Folder'), COALESCE((SELECT MIN(position) FROM document_folders WHERE workspace_id = ? AND COALESCE(parent_id, '#root') = ?), 0) - 1, CURRENT_TIMESTAMP, CURRENT_TIMESTAMP)
    , &[_][]const u8{ folder_id, args.workspace_id, parent, name, args.workspace_id, level }) catch
        return error.InsertFailed;

    return getFolder(allocator, db, args.workspace_id, folder_id) catch |err| switch (err) {
        error.NotFound, error.IdsRequired, error.QueryFailed => error.RowNotFoundAfterInsert,
        error.OutOfMemory => error.InsertFailed,
        else => error.InsertFailed,
    };
}

/// Rename and/or move a folder. A move is refused when it would create a cycle
/// or exceed `MAX_FOLDER_DEPTH`; both refusals leave the stored row untouched.
pub fn updateFolder(
    allocator: std.mem.Allocator,
    db: *database.Db,
    workspace_id: []const u8,
    folder_id: []const u8,
    patch: UpdateFolderArgs,
) UpdateFolderError!FolderRow {
    if (workspace_id.len == 0 or folder_id.len == 0) return error.IdsRequired;

    const existing = getFolder(allocator, db, workspace_id, folder_id) catch |err| switch (err) {
        error.NotFound => return error.NotFound,
        else => return err,
    };
    defer freeFolderRow(allocator, existing);

    const name: []const u8 = if (patch.name) |raw| blk: {
        const trimmed = std.mem.trim(u8, raw, " \t\n\r");
        if (trimmed.len == 0) return error.NameRequired;
        break :blk trimmed;
    } else existing.name;

    var parent: ?[]const u8 = existing.parent_id;
    if (patch.move_parent) {
        const target: ?[]const u8 = if (patch.parent_id) |p| (if (p.len == 0) null else p) else null;
        if (target) |target_id| {
            if (std.mem.eql(u8, target_id, folder_id)) return error.CycleRefused;

            const inside = isAtOrBelow(allocator, db, workspace_id, folder_id, target_id) catch |err| switch (err) {
                error.NotFound => return error.ParentNotFound,
                error.TooDeep => return error.CycleRefused,
                error.QueryFailed => return error.QueryFailed,
                error.OutOfMemory => return error.OutOfMemory,
            };
            if (inside) return error.CycleRefused;

            const target_depth = depthOf(allocator, db, workspace_id, target_id) catch |err| switch (err) {
                error.NotFound => return error.ParentNotFound,
                error.TooDeep => return error.TooDeep,
                error.QueryFailed => return error.QueryFailed,
                error.OutOfMemory => return error.OutOfMemory,
            };
            const below = deepestBelow(allocator, db, workspace_id, folder_id, MAX_FOLDER_DEPTH) catch |err| switch (err) {
                error.NotFound => 0,
                error.TooDeep => return error.TooDeep,
                error.QueryFailed => return error.QueryFailed,
                error.OutOfMemory => return error.OutOfMemory,
            };
            if (target_depth + 1 + below > MAX_FOLDER_DEPTH) return error.TooDeep;
        }
        parent = target;
    }

    db.exec(allocator,
        \\UPDATE document_folders
        \\SET name = ?, parent_id = NULLIF(?, ''), updated_at = CURRENT_TIMESTAMP
        \\WHERE id = ? AND workspace_id = ?
    , &[_][]const u8{ name, parent orelse "", folder_id, workspace_id }) catch
        return error.UpdateFailed;

    return getFolder(allocator, db, workspace_id, folder_id) catch return error.UpdateFailed;
}

/// Delete a folder and move its contents one level up. Returns how many
/// documents were reparented, so the caller can tell the user none were lost.
pub fn deleteFolder(
    allocator: std.mem.Allocator,
    db: *database.Db,
    workspace_id: []const u8,
    folder_id: []const u8,
) DeleteFolderError!usize {
    if (workspace_id.len == 0 or folder_id.len == 0) return error.IdsRequired;

    const existing = getFolder(allocator, db, workspace_id, folder_id) catch |err| switch (err) {
        error.NotFound => return error.NotFound,
        error.QueryFailed => return error.QueryFailed,
        error.OutOfMemory => return error.OutOfMemory,
        else => return error.DeleteFailed,
    };
    defer freeFolderRow(allocator, existing);

    const grandparent = existing.parent_id orelse "";

    var count_q = db.query(
        allocator,
        "SELECT COUNT(*) FROM documents WHERE workspace_id = ? AND folder_id = ?",
        &[_][]const u8{ workspace_id, folder_id },
    ) catch return error.QueryFailed;
    const count_row = (count_q.next() catch return error.QueryFailed) orelse {
        count_q.deinit();
        return error.QueryFailed;
    };
    const documents_kept = std.fmt.parseInt(usize, count_row.values[0], 10) catch 0;
    count_row.deinit(allocator);
    count_q.deinit();

    var tx = db.begin() catch return error.TransactionFailed;
    defer tx.commitOrRollback() catch {};
    errdefer tx.rollback() catch {};

    tx.exec(
        allocator,
        "UPDATE document_folders SET parent_id = NULLIF(?, ''), updated_at = CURRENT_TIMESTAMP " ++
            "WHERE workspace_id = ? AND parent_id = ?",
        &[_][]const u8{ grandparent, workspace_id, folder_id },
    ) catch return error.DeleteFailed;

    tx.exec(
        allocator,
        "UPDATE documents SET folder_id = NULLIF(?, '') WHERE workspace_id = ? AND folder_id = ?",
        &[_][]const u8{ grandparent, workspace_id, folder_id },
    ) catch return error.DeleteFailed;

    tx.exec(
        allocator,
        "DELETE FROM document_folders WHERE id = ? AND workspace_id = ?",
        &[_][]const u8{ folder_id, workspace_id },
    ) catch return error.DeleteFailed;

    tx.commit() catch return error.DeleteFailed;
    return documents_kept;
}

// ─── Tests ──────────────────────────────────────────────────────────────

const testing = std.testing;
const test_db = @import("pabrikcore").test_db;
const migration = @import("../../../migrations/migration.zig");

const TestCtx = struct {
    db: database.Db,
    threaded: std.Io.Threaded,
};

fn setupDb() !TestCtx {
    var threaded = std.Io.Threaded.init(testing.allocator, .{});
    errdefer threaded.deinit();
    var db: database.Db = .{};
    errdefer db.deinit();
    try test_db.openMemory(&db, threaded.io());
    try migration.Migration098CreateDocuments.up(&db, testing.allocator);
    try migration.Migration122AddDocumentPosition.up(&db, testing.allocator);
    try migration.Migration140AddDocumentFolders.up(&db, testing.allocator);
    try migration.Migration143AddDocumentContentKey.up(&db, testing.allocator);
    try migration.Migration144DropDocumentContent.up(&db, testing.allocator);
    return .{ .db = db, .threaded = threaded };
}

fn seedDocument(alloc: std.mem.Allocator, db: *database.Db, id: []const u8, folder_id: ?[]const u8) !void {
    try db.exec(alloc,
        \\INSERT INTO documents (id, workspace_id, title, folder_id)
        \\VALUES (?, 'ws_1', ?, NULLIF(?, ''))
    , &[_][]const u8{ id, id, folder_id orelse "" });
}

fn folderIdOf(alloc: std.mem.Allocator, db: *database.Db, name: []const u8) ![]u8 {
    var q = try db.query(
        alloc,
        "SELECT id FROM document_folders WHERE name = ? LIMIT 1",
        &[_][]const u8{name},
    );
    defer q.deinit();
    const r = (try q.next()) orelse return error.NotFound;
    defer r.deinit(alloc);
    return alloc.dupe(u8, r.values[0]);
}

test "createFolder: a root folder reports its parent as null and a name" {
    const alloc = testing.allocator;
    var ctx = try setupDb();
    defer ctx.threaded.deinit();
    defer ctx.db.deinit();

    const folder = try createFolder(alloc, &ctx.db, .{ .workspace_id = "ws_1", .name = "  Split bill  " });
    defer freeFolderRow(alloc, folder);

    try testing.expectEqualStrings("ws_1", folder.workspace_id);
    try testing.expectEqualStrings("Split bill", folder.name);
    try testing.expectEqual(@as(?[]const u8, null), folder.parent_id);
}

test "createFolder: a child of a five-deep chain is refused, not stored" {
    const alloc = testing.allocator;
    var ctx = try setupDb();
    defer ctx.threaded.deinit();
    defer ctx.db.deinit();

    var parent: ?[]const u8 = null;
    var keep: std.ArrayList([]u8) = .empty;
    defer {
        for (keep.items) |id| alloc.free(id);
        keep.deinit(alloc);
    }
    for (0..MAX_FOLDER_DEPTH) |level| {
        const folder = try createFolder(alloc, &ctx.db, .{
            .workspace_id = "ws_1",
            .name = "level",
            .parent_id = parent,
        });
        const copy = try alloc.dupe(u8, folder.id);
        keep.append(alloc, copy) catch @panic("keep list append");
        parent = copy;
        freeFolderRow(alloc, folder);
        _ = level;
    }

    try testing.expectError(
        error.TooDeep,
        createFolder(alloc, &ctx.db, .{ .workspace_id = "ws_1", .name = "sixth", .parent_id = parent }),
    );

    const all = try listFolders(alloc, &ctx.db, "ws_1");
    defer freeFolderRows(alloc, all);
    try testing.expectEqual(@as(usize, MAX_FOLDER_DEPTH), all.len);
}

test "createFolder: a parent from another workspace is refused" {
    const alloc = testing.allocator;
    var ctx = try setupDb();
    defer ctx.threaded.deinit();
    defer ctx.db.deinit();

    const theirs = try createFolder(alloc, &ctx.db, .{ .workspace_id = "ws_2", .name = "Theirs" });
    defer freeFolderRow(alloc, theirs);

    try testing.expectError(
        error.ParentNotFound,
        createFolder(alloc, &ctx.db, .{ .workspace_id = "ws_1", .name = "Mine", .parent_id = theirs.id }),
    );
}

test "updateFolder: moving a folder into its own descendant is refused" {
    const alloc = testing.allocator;
    var ctx = try setupDb();
    defer ctx.threaded.deinit();
    defer ctx.db.deinit();

    const root = try createFolder(alloc, &ctx.db, .{ .workspace_id = "ws_1", .name = "Root" });
    defer freeFolderRow(alloc, root);
    const child = try createFolder(alloc, &ctx.db, .{ .workspace_id = "ws_1", .name = "Child", .parent_id = root.id });
    defer freeFolderRow(alloc, child);

    try testing.expectError(
        error.CycleRefused,
        updateFolder(alloc, &ctx.db, "ws_1", root.id, .{ .parent_id = child.id, .move_parent = true }),
    );

    const after = try getFolder(alloc, &ctx.db, "ws_1", root.id);
    defer freeFolderRow(alloc, after);
    try testing.expectEqual(@as(?[]const u8, null), after.parent_id);
}

test "updateFolder: a move that would push a subtree past the cap is refused" {
    const alloc = testing.allocator;
    var ctx = try setupDb();
    defer ctx.threaded.deinit();
    defer ctx.db.deinit();

    var root = try createFolder(alloc, &ctx.db, .{ .workspace_id = "ws_1", .name = "Chain 1" });
    var root_parent: ?[]const u8 = null;
    var chain: std.ArrayList([]u8) = .empty;
    defer {
        for (chain.items) |id| alloc.free(id);
        chain.deinit(alloc);
    }
    for (0..MAX_FOLDER_DEPTH - 1) |_| {
        const copy = try alloc.dupe(u8, root.id);
        chain.append(alloc, copy) catch @panic("chain list append");
        root_parent = copy;
        const next = try createFolder(alloc, &ctx.db, .{ .workspace_id = "ws_1", .name = "Chain", .parent_id = root_parent });
        freeFolderRow(alloc, root);
        root = next;
    }
    defer freeFolderRow(alloc, root);

    const loner = try createFolder(alloc, &ctx.db, .{ .workspace_id = "ws_1", .name = "Loner" });
    defer freeFolderRow(alloc, loner);
    const loner_child = try createFolder(alloc, &ctx.db, .{ .workspace_id = "ws_1", .name = "Loner child", .parent_id = loner.id });
    defer freeFolderRow(alloc, loner_child);

    try testing.expectError(
        error.TooDeep,
        updateFolder(alloc, &ctx.db, "ws_1", loner.id, .{ .parent_id = root.id, .move_parent = true }),
    );
}

test "updateFolder: renaming keeps the parent and the trimmed name" {
    const alloc = testing.allocator;
    var ctx = try setupDb();
    defer ctx.threaded.deinit();
    defer ctx.db.deinit();

    const parent = try createFolder(alloc, &ctx.db, .{ .workspace_id = "ws_1", .name = "Parent" });
    defer freeFolderRow(alloc, parent);
    const child = try createFolder(alloc, &ctx.db, .{ .workspace_id = "ws_1", .name = "Child", .parent_id = parent.id });
    defer freeFolderRow(alloc, child);

    const renamed = try updateFolder(alloc, &ctx.db, "ws_1", child.id, .{ .name = "  Renamed  " });
    defer freeFolderRow(alloc, renamed);

    try testing.expectEqualStrings("Renamed", renamed.name);
    try testing.expect(renamed.parent_id != null);
    try testing.expectEqualStrings(parent.id, renamed.parent_id.?);
}

test "deleteFolder: documents and child folders move up, nothing is deleted" {
    const alloc = testing.allocator;
    var ctx = try setupDb();
    defer ctx.threaded.deinit();
    defer ctx.db.deinit();

    const parent = try createFolder(alloc, &ctx.db, .{ .workspace_id = "ws_1", .name = "Parent" });
    defer freeFolderRow(alloc, parent);
    const doomed = try createFolder(alloc, &ctx.db, .{ .workspace_id = "ws_1", .name = "Doomed", .parent_id = parent.id });
    defer freeFolderRow(alloc, doomed);
    const nested = try createFolder(alloc, &ctx.db, .{ .workspace_id = "ws_1", .name = "Nested", .parent_id = doomed.id });
    defer freeFolderRow(alloc, nested);

    try seedDocument(alloc, &ctx.db, "doc_a", doomed.id);
    try seedDocument(alloc, &ctx.db, "doc_b", doomed.id);
    try seedDocument(alloc, &ctx.db, "doc_root", null);

    const kept = try deleteFolder(alloc, &ctx.db, "ws_1", doomed.id);
    try testing.expectEqual(@as(usize, 2), kept);

    const folders = try listFolders(alloc, &ctx.db, "ws_1");
    defer freeFolderRows(alloc, folders);
    try testing.expectEqual(@as(usize, 2), folders.len);
    for (folders) |f| {
        if (std.mem.eql(u8, f.name, "Nested")) {
            try testing.expect(f.parent_id != null);
            try testing.expectEqualStrings(parent.id, f.parent_id.?);
        }
    }

    // The two documents moved into the removed folder now sit in its parent,
    // one level up, not at the root of the section.
    var q = try ctx.db.query(alloc,
        \\SELECT COUNT(*) FROM documents WHERE workspace_id = 'ws_1' AND folder_id = ?
    , &[_][]const u8{parent.id});
    defer q.deinit();
    const r = (try q.next()) orelse return error.NoRow;
    defer r.deinit(alloc);
    try testing.expectEqualStrings("2", r.values[0]);

    var root_q = try ctx.db.query(alloc,
        \\SELECT COUNT(*) FROM documents WHERE workspace_id = 'ws_1' AND folder_id IS NULL
    , &[_][]const u8{});
    defer root_q.deinit();
    const root_row = (try root_q.next()) orelse return error.NoRow;
    defer root_row.deinit(alloc);
    try testing.expectEqualStrings("1", root_row.values[0]);
}

test "deleteFolder: a folder from another workspace is refused and survives" {
    const alloc = testing.allocator;
    var ctx = try setupDb();
    defer ctx.threaded.deinit();
    defer ctx.db.deinit();

    const theirs = try createFolder(alloc, &ctx.db, .{ .workspace_id = "ws_2", .name = "Theirs" });
    defer freeFolderRow(alloc, theirs);

    try testing.expectError(error.NotFound, deleteFolder(alloc, &ctx.db, "ws_1", theirs.id));

    const still = try listFolders(alloc, &ctx.db, "ws_2");
    defer freeFolderRows(alloc, still);
    try testing.expectEqual(@as(usize, 1), still.len);
}

test "listFolders: one workspace's tree never leaks into another" {
    const alloc = testing.allocator;
    var ctx = try setupDb();
    defer ctx.threaded.deinit();
    defer ctx.db.deinit();

    const mine = try createFolder(alloc, &ctx.db, .{ .workspace_id = "ws_1", .name = "Mine" });
    defer freeFolderRow(alloc, mine);
    const theirs = try createFolder(alloc, &ctx.db, .{ .workspace_id = "ws_2", .name = "Theirs" });
    defer freeFolderRow(alloc, theirs);

    const rows = try listFolders(alloc, &ctx.db, "ws_1");
    defer freeFolderRows(alloc, rows);
    try testing.expectEqual(@as(usize, 1), rows.len);
    try testing.expectEqualStrings("Mine", rows[0].name);
}

test "createFolder: a new folder lands at the top of its level" {
    const alloc = testing.allocator;
    var ctx = try setupDb();
    defer ctx.threaded.deinit();
    defer ctx.db.deinit();

    const first = try createFolder(alloc, &ctx.db, .{ .workspace_id = "ws_1", .name = "First" });
    defer freeFolderRow(alloc, first);
    const second = try createFolder(alloc, &ctx.db, .{ .workspace_id = "ws_1", .name = "Second" });
    defer freeFolderRow(alloc, second);

    const rows = try listFolders(alloc, &ctx.db, "ws_1");
    defer freeFolderRows(alloc, rows);
    try testing.expectEqualStrings("Second", rows[0].name);
    try testing.expectEqualStrings("First", rows[1].name);
}

// Keeps `folderIdOf` referenced where a test needs it without a second helper.
test "folderIdOf: lookup by name is scoped to the fixture" {
    const alloc = testing.allocator;
    var ctx = try setupDb();
    defer ctx.threaded.deinit();
    defer ctx.db.deinit();

    const folder = try createFolder(alloc, &ctx.db, .{ .workspace_id = "ws_1", .name = "Findable" });
    defer freeFolderRow(alloc, folder);
    const found = try folderIdOf(alloc, &ctx.db, "Findable");
    defer alloc.free(found);
    try testing.expectEqualStrings(folder.id, found);
}
