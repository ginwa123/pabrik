//! Data layer for the kanban workspace item (item_type='kanban'). Each kanban
//! workspace item has N user-defined columns (the default seed is `todo / in
//! progress / done`).

const std = @import("std");
/// The tail of the upsert of a task's `kanban` row: sqlite's `INSERT OR
/// REPLACE` replaces the row, postgres assigns the two columns instead.
const UPSERT_KANBAN_TAIL: []const u8 = if (dialect.is_postgres)
    " ON CONFLICT (workspace_item_task_id) DO UPDATE SET " ++
        "kanban_column_id = excluded.kanban_column_id, kanban_position = excluded.kanban_position"
else
    "";

const pabrikcore = @import("pabrikcore");
const dialect = pabrikcore.dialect;
const test_db = pabrikcore.test_db;
const sqlite = pabrikcore.sqlite;
const database = pabrikcore.database;
/// Re-exported so a caller holding a slice returned by `incompleteDependencies`
/// frees it through the SAME module copy it was built with.
pub const deps = @import("kanban_deps.zig");

/// One kanban column row, fully duplicated into heap memory.
/// Free with `freeColumns(allocator, slice)`.
pub const KanbanColumn = struct {
    id: []u8,
    workspace_item_id: []u8,
    name: []u8,
    description: []u8,
    position: i64,
    created_at: []u8,
    /// Migration 111 — true when a card that lands in this column has finished
    /// the work it describes, so it stops blocking its dependents.
    is_done: bool = false,
};

/// Free the per-column strings and the backing slice in one call.
pub fn freeColumns(allocator: std.mem.Allocator, cols: []KanbanColumn) void {
    for (cols) |c| {
        allocator.free(c.id);
        allocator.free(c.workspace_item_id);
        allocator.free(c.name);
        allocator.free(c.description);
        allocator.free(c.created_at);
    }
    allocator.free(cols);
}

/// List the columns of a kanban workspace item in `position` order. Returns
/// an owned slice; the caller must release it with `freeColumns(allocator,
/// slice)`.
pub fn listColumns(
    allocator: std.mem.Allocator,
    db: *database.Db,
    workspace_item_id: []const u8,
) ![]KanbanColumn {
    var q = try db.query(allocator,
        \\SELECT kc.id, kc.workspace_item_id, kc.name, kc.description, kc.position,
        \\       COALESCE(CAST(kc.created_at AS TEXT), ''), COALESCE(kc.is_done, 0)
        \\FROM kanban_columns kc
        \\WHERE kc.workspace_item_id = ?
        \\ORDER BY kc.position ASC
    , &.{workspace_item_id});
    defer q.deinit();

    var rows = std.ArrayList(KanbanColumn).empty;
    errdefer {
        for (rows.items) |c| {
            allocator.free(c.id);
            allocator.free(c.workspace_item_id);
            allocator.free(c.name);
            allocator.free(c.description);
            allocator.free(c.created_at);
        }
        rows.deinit(allocator);
    }

    while (try q.next()) |row| {
        defer row.deinit(allocator);
        try rows.append(allocator, .{
            .id = try allocator.dupe(u8, row.values[0]),
            .workspace_item_id = try allocator.dupe(u8, row.values[1]),
            .name = try allocator.dupe(u8, row.values[2]),
            .description = try allocator.dupe(u8, row.values[3]),
            .position = std.fmt.parseInt(i64, row.values[4], 10) catch 0,
            .created_at = try allocator.dupe(u8, row.values[5]),
            // A row written before Migration 111 comes back NULL and is
            // COALESCEd to "0"; anything else is "not zero" = true.
            .is_done = !std.mem.eql(u8, row.values[6], "0"),
        });
    }
    return rows.toOwnedSlice(allocator);
}

/// Generate a unique column id of the form `col_<unix_nanoseconds>`.
fn generateColumnId(allocator: std.mem.Allocator) ![]u8 {
    const counter = nextColumnIdCounter();
    var entropy: [8]u8 = undefined;
    const stack_addr: u64 = @intCast(@intFromPtr(&entropy));
    const mixed: u64 = counter ^ stack_addr;
    std.mem.writeInt(u64, &entropy, mixed, .little);
    var hex: [16]u8 = undefined;
    const hex_chars = "0123456789abcdef";
    for (entropy, 0..) |b, i| {
        hex[i * 2] = hex_chars[b >> 4];
        hex[i * 2 + 1] = hex_chars[b & 0x0F];
    }
    return std.fmt.allocPrint(allocator, "col_{s}", .{&hex});
}

/// Process-global monotonic counter for `generateColumnId`. Every call to
/// `generateColumnId` advances the counter by one, guaranteeing a unique ID
/// per call regardless of how fast the caller invokes it.
var column_id_counter: std.atomic.Value(u64) = .init(0);

fn nextColumnIdCounter() u64 {
    return column_id_counter.fetchAdd(1, .seq_cst);
}

/// Append a new column to the end of the kanban's column sequence.
pub fn addColumn(
    allocator: std.mem.Allocator,
    db: pabrikcore.database.DbOrTx,
    workspace_item_id: []const u8,
    name: []const u8,
    description: []const u8,
    position: ?i64,
) ![]u8 {
    const id = try generateColumnId(allocator);
    defer allocator.free(id);

    const pos = position orelse blk: {
        var q = try db.query(allocator,
            \\SELECT COALESCE(MAX(kc.position), -1) + 1
            \\FROM kanban_columns kc
            \\WHERE kc.workspace_item_id = ?
        , &.{workspace_item_id});
        defer q.deinit();
        const row = (try q.next()) orelse return error.NoMaxPosition;
        defer row.deinit(allocator);
        break :blk try std.fmt.parseInt(i64, row.values[0], 10);
    };

    const pos_str = try std.fmt.allocPrint(allocator, "{d}", .{pos});
    defer allocator.free(pos_str);

    // SQLiteBackend.exec binds `arg.len == 0` as SQL NULL (see `ruangsql
    // src/sqlite/Sqlite.zig (github.com/ginwa123/ruangsql):73-74`).
    if (description.len == 0) {
        try db.exec(allocator,
            "INSERT INTO kanban_columns (id, workspace_item_id, name, position) " ++
            "VALUES (?, ?, ?, ?)",
            &.{ id, workspace_item_id, name, pos_str });
    } else {
        try db.exec(allocator,
            "INSERT INTO kanban_columns (id, workspace_item_id, name, description, position) " ++
            "VALUES (?, ?, ?, ?, ?)",
            &.{ id, workspace_item_id, name, description, pos_str });
    }
    return allocator.dupe(u8, id);
}

/// Seed the canonical 3-column default flow `todo / in progress / done` for a
/// freshly-created kanban item.
pub fn seedDefaultColumns(
    allocator: std.mem.Allocator,
    db: pabrikcore.database.DbOrTx,
    workspace_item_id: []const u8,
) !void {
    // Each `addColumn` returns an owned id slice that the caller MUST
    // free. `seedDefaultColumns` doesn't surface the ids (the caller
    // doesn't need them), so we free each one immediately after.
    {
        const id = try addColumn(allocator, db, workspace_item_id, "todo", "", 0);
        defer allocator.free(id);
    }
    {
        const id = try addColumn(allocator, db, workspace_item_id, "in progress", "", 1);
        defer allocator.free(id);
    }
    {
        const id = try addColumn(allocator, db, workspace_item_id, "done", "", 2);
        defer allocator.free(id);
    }
}

/// Update an existing column. `name` and `description` are both optional; at
/// least one must be non-null (validated at the HTTP handler layer).
pub fn updateColumn(
    allocator: std.mem.Allocator,
    db: *database.Db,
    workspace_item_id: []const u8,
    column_id: []const u8,
    name: ?[]const u8,
    description: ?[]const u8,
) !void {
    _ = workspace_item_id;
    if (name) |n| {
        try db.exec(allocator,
            "UPDATE kanban_columns SET name = ? WHERE id = ?",
            &.{ n, column_id });
    }
    // Three distinct states for `description`: null → don't change (field
    // absent from PATCH body) "" → clear (user explicitly sent empty string)
    // non-empty → overwrite with the new value The "clear" branch binds the
    if (description) |d| {
        if (d.len > 0) {
            try db.exec(allocator,
                "UPDATE kanban_columns SET description = ? WHERE id = ?",
                &.{ d, column_id });
        } else {
            try db.exec(allocator,
                "UPDATE kanban_columns SET description = '' WHERE id = ?",
                &.{column_id});
        }
    }
}

/// Migration 111 — flip the "a card that lands here is finished" flag. Kept
/// separate from `updateColumn` so the rename path's signature (and its six
/// fixtures) stay untouched.
pub fn setColumnIsDone(
    allocator: std.mem.Allocator,
    db: *database.Db,
    column_id: []const u8,
    is_done: bool,
) !void {
    try db.exec(allocator,
        "UPDATE kanban_columns SET is_done = ? WHERE id = ?",
        // Bind the literal "1"/"0" string, never "" — the backend binds an
        // empty slice as SQL NULL.
        &.{ if (is_done) "1" else "0", column_id });
}

/// Delete a column.
pub fn deleteColumn(
    allocator: std.mem.Allocator,
    db: *database.Db,
    workspace_item_id: []const u8,
    column_id: []const u8,
) !void {
    _ = workspace_item_id;
    // Tasks that were assigned to this column have their `kanban` card row
    // DELETED (so the LEFT JOIN in list queries surfaces them as "task exists
    // but is unassigned" — the same observable wire format as before).
    try db.exec(allocator,
        "DELETE FROM kanban WHERE kanban_column_id = ?",
        &.{column_id});
    try db.exec(allocator,
        "DELETE FROM kanban_columns WHERE id = ?",
        &.{column_id});
}

/// Replace the target kanban's columns with copies of the source kanban's
/// columns.
pub fn replaceColumnsWith(
    allocator: std.mem.Allocator,
    db: *database.Db,
    source_item_id: []const u8,
    target_item_id: []const u8,
) !void {
    // Step 1: Fetch the source's columns (ordered by position ASC).
    const source_cols = try listColumns(allocator, db, source_item_id);
    defer freeColumns(allocator, source_cols);

    // Step 2: Delete every existing column on the target.
    {
        var existing = try db.query(allocator,
            \\SELECT kc.id FROM kanban_columns kc WHERE kc.workspace_item_id = ?
        , &.{target_item_id});
        defer existing.deinit();
        var target_column_ids = std.ArrayList([]u8).empty;
        errdefer {
            for (target_column_ids.items) |id| allocator.free(id);
            target_column_ids.deinit(allocator);
        }
        while (try existing.next()) |row| {
            defer row.deinit(allocator);
            try target_column_ids.append(allocator, try allocator.dupe(u8, row.values[0]));
        }
        const owned_ids = try target_column_ids.toOwnedSlice(allocator);
        defer {
            for (owned_ids) |id| allocator.free(id);
            allocator.free(owned_ids);
        }
        for (owned_ids) |col_id| {
            try deleteColumn(allocator, db, target_item_id, col_id);
        }
    }

    // Step 3: Copy each source column to the target with position 0..N-1.
    for (source_cols, 0..) |col, idx| {
        // addColumn returns a heap-owned id that the caller MUST
        // free. We don't surface the id (the caller doesn't need
        // it) so we free it immediately — mirrors `seedDefaultColumns`.
        const new_id = try addColumn(
            allocator,
            .{ .db = db },
            target_item_id,
            col.name,
            col.description,
            @intCast(idx),
        );
        defer allocator.free(new_id);
    }
}

/// Append copies of the source kanban's columns to the end of the target
/// kanban's column sequence.
pub fn appendColumnsFrom(
    allocator: std.mem.Allocator,
    db: *database.Db,
    source_item_id: []const u8,
    target_item_id: []const u8,
) !void {
    const source_cols = try listColumns(allocator, db, source_item_id);
    defer freeColumns(allocator, source_cols);

    // Compute MAX(position) + 1 across the target's columns. The
    // COALESCE handles the empty-target case (no rows → MAX is
    // NULL → -1 → start_pos 0).
    var start_pos: i64 = 0;
    {
        var q = try db.query(allocator,
            \\
            \\SELECT COALESCE(MAX(kc.position), -1) + 1
            \\FROM kanban_columns kc
            \\WHERE kc.workspace_item_id = ?
        , &.{target_item_id});
        defer q.deinit();
        if (try q.next()) |row| {
            defer row.deinit(allocator);
            start_pos = std.fmt.parseInt(i64, row.values[0], 10) catch 0;
        }
    }

    for (source_cols, 0..) |col, offset| {
        // addColumn returns a heap-owned id that the caller MUST
        // free (mirrors seedDefaultColumns + replaceColumnsWith).
        const new_id = try addColumn(
            allocator,
            .{ .db = db },
            target_item_id,
            col.name,
            col.description,
            start_pos + @as(i64, @intCast(offset)),
        );
        defer allocator.free(new_id);
    }
}

/// Count how many tasks currently reference `column_id` as their
/// `kanban_column_id`.
pub fn countTasksInColumn(
    allocator: std.mem.Allocator,
    db: *database.Db,
    column_id: []const u8,
) !u32 {
    // After Migration 072, "tasks in this column" is read from `kanban` (the
    // 1:1 join table where a row exists iff a task is assigned to a kanban
    // column).
    var q = try db.query(allocator,
        \\SELECT COUNT(*) FROM kanban k WHERE k.kanban_column_id = ?
    , &.{column_id});
    defer q.deinit();
    const row = (try q.next()) orelse return 0;
    defer row.deinit(allocator);
    return try std.fmt.parseInt(u32, row.values[0], 10);
}

/// Reorder a column to a new position with list-insertion semantics: the
/// column is removed from its current slot and re-inserted at `new_position`,
/// shifting the OTHER columns around it.
pub fn reorderColumn(
    allocator: std.mem.Allocator,
    db: *database.Db,
    workspace_item_id: []const u8,
    column_id: []const u8,
    new_position: i64,
) !void {
    // Sentinel: large enough to park the moved column past every
    // realistic position without overflow concerns (SQLite stores
    // INTEGER as i64).
    const SENTINEL: i64 = 1_000_000;
    const sentinel_str = try std.fmt.allocPrint(allocator, "{d}", .{SENTINEL});
    defer allocator.free(sentinel_str);
    const new_pos_str = try std.fmt.allocPrint(allocator, "{d}", .{new_position});
    defer allocator.free(new_pos_str);

    // Step 1: park the moved column at the sentinel.
    try db.exec(allocator,
        "UPDATE kanban_columns SET position = ? WHERE id = ?",
        &.{ sentinel_str, column_id });

    // Step 2: compact the OTHER columns (everyone except the parked one) into
    // 0..N-2 by current position order.
    try db.exec(allocator,
        \\UPDATE kanban_columns
        \\SET position = (
        \\    SELECT COUNT(*) FROM kanban_columns kc2
        \\    WHERE kc2.workspace_item_id = kanban_columns.workspace_item_id
        \\      AND kc2.id != ?
        \\      AND (kc2.position < kanban_columns.position
        \\          OR (kc2.position = kanban_columns.position AND kc2.id < kanban_columns.id))
        \\)
        \\WHERE workspace_item_id = ? AND id != ?
    , &.{ column_id, workspace_item_id, column_id });

    // Step 3: shift every OTHER column at position >= new_position
    // up by 1, opening a slot for the moved column.
    try db.exec(allocator,
        \\UPDATE kanban_columns
        \\SET position = position + 1
        \\WHERE workspace_item_id = ? AND id != ? AND position >= ?
    , &.{ workspace_item_id, column_id, new_pos_str });

    // Step 4: place the moved column at new_position.
    try db.exec(allocator,
        "UPDATE kanban_columns SET position = ? WHERE id = ?",
        &.{ new_pos_str, column_id });
}

/// Move a task from its current column to `target_column_id` at
/// `target_position`.
pub fn moveTask(
    allocator: std.mem.Allocator,
    db: *database.Db,
    workspace_item_id: []const u8,
    task_id: []const u8,
    target_column_id: []const u8,
    target_position: i64,
) !void {
    _ = workspace_item_id;

    // Step 1: read the current column for the task (needed to renumber the
    // source column after the move).
    const current_col_id = blk: {
        var q = try db.query(allocator,
            "SELECT COALESCE(k.kanban_column_id, '') FROM kanban k WHERE k.workspace_item_task_id = ?",
            &.{task_id});
        defer q.deinit();
        const row = (try q.next()) orelse return error.TaskNotFound;
        defer row.deinit(allocator);
        break :blk try allocator.dupe(u8, row.values[0]);
    };
    defer allocator.free(current_col_id);

    const pos_str = try std.fmt.allocPrint(allocator, "{d}", .{target_position});
    defer allocator.free(pos_str);

    // Step 2: move the task to the target column at the target position.
    try db.exec(allocator,
        dialect.upsert_verb ++ " INTO kanban (workspace_item_task_id, kanban_column_id, kanban_position) VALUES (?, ?, ?)" ++ UPSERT_KANBAN_TAIL,
        &.{ task_id, target_column_id, pos_str });

    // Step 3: shift other tasks in the target column that are at >= target_position.
    try db.exec(allocator,
        \\UPDATE kanban
        \\SET kanban_position = kanban_position + 1
        \\WHERE kanban_column_id = ? AND workspace_item_task_id != ? AND kanban_position >= ?
    , &.{ target_column_id, task_id, pos_str });

    // Step 4: if the column changed, compact the source column.
    if (!std.mem.eql(u8, current_col_id, target_column_id)) {
        try db.exec(allocator,
            \\UPDATE kanban
            \\SET kanban_position = (
            \\    SELECT COUNT(*) FROM kanban k2
            \\    WHERE k2.kanban_column_id = kanban.kanban_column_id
            \\        AND (k2.kanban_position < kanban.kanban_position
            \\            OR (k2.kanban_position = kanban.kanban_position AND k2.workspace_item_task_id <= kanban.workspace_item_task_id))
            \\) - 1
            \\WHERE kanban_column_id = ?
        , &.{current_col_id});
    }
}


// ─── Dependency gate (Migration 111) ─────────────────────────────────────
// Enforced HERE, not in the UI: the drag-and-drop handler and the
// `kanban_move_task` agent tool both funnel through `moveTaskChecked`.

/// The column the task is currently in ('' when it is unassigned).
fn currentColumnId(
    allocator: std.mem.Allocator,
    db: *database.Db,
    task_id: []const u8,
) ![]u8 {
    var q = try db.query(allocator,
        "SELECT COALESCE(kanban_column_id, '') FROM kanban WHERE workspace_item_task_id = ?",
        &.{task_id});
    defer q.deinit();

    const row = (try q.next()) orelse return allocator.dupe(u8, "");
    defer row.deinit(allocator);
    return allocator.dupe(u8, row.values[0]);
}

/// The task's dependencies that have NOT completed — the blockers a 409 body
/// reports. Caller frees with `kanban_deps.freeEdges`.
pub fn incompleteDependencies(
    allocator: std.mem.Allocator,
    db: *database.Db,
    task_id: []const u8,
) ![]deps.Edge {
    const all = try deps.listEdgesForTask(allocator, db, task_id);
    var blocked: std.ArrayList(deps.Edge) = .empty;
    errdefer blocked.deinit(allocator);

    for (all) |edge| {
        if (edge.is_done) {
            // A resolved dependency owns its strings just as much as a
            // blocking one — free it here or it leaks.
            allocator.free(edge.task_id);
            allocator.free(edge.depends_on_task_id);
            allocator.free(edge.name);
            allocator.free(edge.column_id);
            allocator.free(edge.column_name);
            continue;
        }
        try blocked.append(allocator, edge);
    }
    allocator.free(all);
    return blocked.toOwnedSlice(allocator);
}

pub const MoveGateError = error{BlockedByDependencies};

/// Refuse a column CHANGE while a dependency is unfinished. Reordering inside
/// the current column and assigning an unassigned card are not column changes,
/// so both stay allowed.
pub fn assertMoveAllowed(
    allocator: std.mem.Allocator,
    db: *database.Db,
    task_id: []const u8,
    target_column_id: []const u8,
) !void {
    const current = try currentColumnId(allocator, db, task_id);
    defer allocator.free(current);
    if (current.len == 0 or std.mem.eql(u8, current, target_column_id)) return;

    const blocked = try incompleteDependencies(allocator, db, task_id);
    defer deps.freeEdges(allocator, blocked);
    if (blocked.len > 0) return error.BlockedByDependencies;
}

/// The move every real caller uses: the gate, then the move. `force` is the
/// explicit human escape hatch ("Move anyway") — it skips the gate but never
/// the move itself.
pub fn moveTaskChecked(
    allocator: std.mem.Allocator,
    db: *database.Db,
    workspace_item_id: []const u8,
    task_id: []const u8,
    target_column_id: []const u8,
    target_position: i64,
    force: bool,
) !void {
    if (!force) try assertMoveAllowed(allocator, db, task_id, target_column_id);
    try moveTask(allocator, db, workspace_item_id, task_id, target_column_id, target_position);
}


// ─── Inline tests (formerly kanban_model_test.zig) ───────────────────────
// Unit tests for the kanban column CRUD data layer. Inlined here per
// the agentic_loop/ convention.

const testing = std.testing;


/// Open a fresh in-memory sqlite DB with the bare minimum tables the
/// kanban_model functions need: `workspace_items` (for the FK reference) and
/// `kanban_columns` (the table being queried).
fn setupDb() !struct { db: database.Db, threaded: std.Io.Threaded } {
    const alloc = testing.allocator;
    var threaded = std.Io.Threaded.init(alloc, .{});
    errdefer threaded.deinit();
    const io = threaded.io();

    var db: database.Db = .{};
    errdefer db.deinit();
    try test_db.openMemory(&db, io);

    return .{ .db = db, .threaded = threaded };
}

// ─── Test: listColumns orders by position ────────────────────────────────

test "listColumns returns columns ordered by position" {
    const alloc = testing.allocator;
    var s = try setupDb();
    defer s.threaded.deinit();
    defer s.db.deinit();

    try s.db.exec(alloc,
        "CREATE TABLE workspace_items (id TEXT PRIMARY KEY, workspace_id TEXT, item_type TEXT)", &.{});
    try s.db.exec(alloc,
        \\CREATE TABLE kanban_columns (
        \\    id TEXT PRIMARY KEY, workspace_item_id TEXT, name TEXT, description TEXT NOT NULL DEFAULT '',
        \\    position INTEGER, is_done INTEGER NOT NULL DEFAULT 0, created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP)
    , &.{});
    try s.db.exec(alloc,
        "INSERT INTO workspace_items (id, workspace_id, item_type) VALUES ('item_1', 'ws_1', 'kanban')", &.{});
    try s.db.exec(alloc,
        "INSERT INTO kanban_columns (id, workspace_item_id, name, position) VALUES ('c1', 'item_1', 'todo', 0)", &.{});
    try s.db.exec(alloc,
        "INSERT INTO kanban_columns (id, workspace_item_id, name, position) VALUES ('c2', 'item_1', 'in progress', 1)", &.{});
    try s.db.exec(alloc,
        "INSERT INTO kanban_columns (id, workspace_item_id, name, position) VALUES ('c3', 'item_1', 'done', 2)", &.{});

    const cols = try listColumns(alloc, &s.db, "item_1");
    defer freeColumns(alloc, cols);

    try testing.expectEqual(@as(usize, 3), cols.len);
    try testing.expectEqualStrings("c1", cols[0].id);
    try testing.expectEqualStrings("todo", cols[0].name);
    try testing.expectEqualStrings("c2", cols[1].id);
    try testing.expectEqualStrings("c3", cols[2].id);
}

// ─── Test: addColumn appends at MAX(position) + 1 when position=null ─────

test "addColumn inserts at end of position sequence" {
    const alloc = testing.allocator;
    var s = try setupDb();
    defer s.threaded.deinit();
    defer s.db.deinit();

    try s.db.exec(alloc,
        "CREATE TABLE workspace_items (id TEXT PRIMARY KEY, workspace_id TEXT, item_type TEXT)", &.{});
    try s.db.exec(alloc,
        \\CREATE TABLE kanban_columns (
        \\    id TEXT PRIMARY KEY, workspace_item_id TEXT, name TEXT, description TEXT NOT NULL DEFAULT '',
        \\    position INTEGER, is_done INTEGER NOT NULL DEFAULT 0, created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP)
    , &.{});
    try s.db.exec(alloc,
        "INSERT INTO workspace_items (id, workspace_id, item_type) VALUES ('item_1', 'ws_1', 'kanban')", &.{});
    try s.db.exec(alloc,
        "INSERT INTO kanban_columns (id, workspace_item_id, name, position) VALUES ('c1', 'item_1', 'todo', 0)", &.{});

    const new_id = try addColumn(alloc, .{ .db = &s.db }, "item_1", "review", "", null);
    defer alloc.free(new_id);
    // Generated id is `col_<unix_nanoseconds>` — just sanity-check the prefix.
    try testing.expect(std.mem.startsWith(u8, new_id, "col_"));

    const cols = try listColumns(alloc, &s.db, "item_1");
    defer freeColumns(alloc, cols);

    try testing.expectEqual(@as(usize, 2), cols.len);
    try testing.expectEqualStrings("review", cols[1].name);
    try testing.expectEqual(@as(i64, 1), cols[1].position);
}

// ─── Test: seedDefaultColumns produces the 3-column canonical flow ───────

test "seedDefaultColumns creates todo, in progress, done" {
    const alloc = testing.allocator;
    var s = try setupDb();
    defer s.threaded.deinit();
    defer s.db.deinit();

    try s.db.exec(alloc,
        "CREATE TABLE workspace_items (id TEXT PRIMARY KEY, workspace_id TEXT, item_type TEXT)", &.{});
    try s.db.exec(alloc,
        \\CREATE TABLE kanban_columns (
        \\    id TEXT PRIMARY KEY, workspace_item_id TEXT, name TEXT, description TEXT NOT NULL DEFAULT '',
        \\    position INTEGER, is_done INTEGER NOT NULL DEFAULT 0, created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP)
    , &.{});
    try s.db.exec(alloc,
        "INSERT INTO workspace_items (id, workspace_id, item_type) VALUES ('item_1', 'ws_1', 'kanban')", &.{});

    try seedDefaultColumns(alloc, .{ .db = &s.db }, "item_1");

    const cols = try listColumns(alloc, &s.db, "item_1");
    defer freeColumns(alloc, cols);

    try testing.expectEqual(@as(usize, 3), cols.len);
    try testing.expectEqualStrings("todo", cols[0].name);
    try testing.expectEqualStrings("in progress", cols[1].name);
    try testing.expectEqualStrings("done", cols[2].name);
}

// ─── Test: renameColumn updates the column's name ────────────────────────

test "renameColumn updates name" {
    const alloc = testing.allocator;
    var s = try setupDb();
    defer s.threaded.deinit();
    defer s.db.deinit();

    try s.db.exec(alloc,
        "CREATE TABLE workspace_items (id TEXT PRIMARY KEY, workspace_id TEXT, item_type TEXT)", &.{});
    try s.db.exec(alloc,
        \\CREATE TABLE kanban_columns (
        \\    id TEXT PRIMARY KEY, workspace_item_id TEXT, name TEXT, description TEXT NOT NULL DEFAULT '',
        \\    position INTEGER, is_done INTEGER NOT NULL DEFAULT 0, created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP)
    , &.{});
    try s.db.exec(alloc,
        "INSERT INTO workspace_items (id, workspace_id, item_type) VALUES ('item_1', 'ws_1', 'kanban')", &.{});
    try s.db.exec(alloc,
        "INSERT INTO kanban_columns (id, workspace_item_id, name, position) VALUES ('c1', 'item_1', 'todo', 0)", &.{});

    try updateColumn(alloc, &s.db, "item_1", "c1", "backlog", null);

    const cols = try listColumns(alloc, &s.db, "item_1");
    defer freeColumns(alloc, cols);
    try testing.expectEqual(@as(usize, 1), cols.len);
    try testing.expectEqualStrings("backlog", cols[0].name);
}

// ─── Test: deleteColumn nulls out the kanban row's kanban_column_id ──────

test "deleteColumn nulls out the kanban row's kanban_column_id" {
    const alloc = testing.allocator;
    var s = try setupDb();
    defer s.threaded.deinit();
    defer s.db.deinit();

    try s.db.exec(alloc,
        "CREATE TABLE workspace_items (id TEXT PRIMARY KEY, workspace_id TEXT, item_type TEXT)", &.{});
    try s.db.exec(alloc,
        \\CREATE TABLE kanban_columns (
        \\    id TEXT PRIMARY KEY, workspace_item_id TEXT, name TEXT, description TEXT NOT NULL DEFAULT '',
        \\    position INTEGER, is_done INTEGER NOT NULL DEFAULT 0, created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP)
    , &.{});
    // Mirror the post-Migration-072 schema: workspace_item_tasks has
    // no kanban_column_id/kanban_position columns; the kanban table
    // holds the 1:1 task-to-board placement with FKs.
    try s.db.exec(alloc,
        \\CREATE TABLE workspace_item_tasks (
        \\    id TEXT PRIMARY KEY, name TEXT, workspace_item_id TEXT)
    , &.{});
    try s.db.exec(alloc,
        \\CREATE TABLE kanban (
        \\    workspace_item_task_id TEXT PRIMARY KEY, kanban_column_id TEXT NOT NULL,
        \\    kanban_position INTEGER NOT NULL DEFAULT 0,
        \\    FOREIGN KEY (workspace_item_task_id) REFERENCES workspace_item_tasks(id) ON DELETE CASCADE,
        \\    FOREIGN KEY (kanban_column_id) REFERENCES kanban_columns(id) ON DELETE SET NULL)
    , &.{});
    try s.db.exec(alloc,
        "INSERT INTO workspace_items (id, workspace_id, item_type) VALUES ('item_1', 'ws_1', 'kanban')", &.{});
    try s.db.exec(alloc,
        "INSERT INTO kanban_columns (id, workspace_item_id, name, position) VALUES ('c1', 'item_1', 'todo', 0)", &.{});
    try s.db.exec(alloc,
        "INSERT INTO workspace_item_tasks (id, name, workspace_item_id) VALUES ('t1', 'A', 'item_1')", &.{});
    try s.db.exec(alloc,
        "INSERT INTO kanban (workspace_item_task_id, kanban_column_id, kanban_position) VALUES ('t1', 'c1', 0)", &.{});

    try deleteColumn(alloc, &s.db, "item_1", "c1");

    // Column row is gone
    const cols = try listColumns(alloc, &s.db, "item_1");
    defer freeColumns(alloc, cols);
    try testing.expectEqual(@as(usize, 0), cols.len);

    // The task itself still exists (kanban FK CASCADE doesn't drop the task)
    {
        var q = try s.db.query(alloc,
            "SELECT t.id FROM workspace_item_tasks t WHERE t.id = 't1'", &.{});
        defer q.deinit();
        const row = (try q.next()) orelse return error.NoTask;
        defer row.deinit(alloc);
        try testing.expectEqualStrings("t1", row.values[0]);
    }

    // The kanban card row is DELETED (no kanban row = "task exists but
    // is unassigned" — the list-query LEFT JOIN surfaces this as
    // kanban_column_id = NULL in the wire format).
    {
        var q = try s.db.query(alloc,
            "SELECT COUNT(*) FROM kanban k WHERE k.workspace_item_task_id = 't1'", &.{});
        defer q.deinit();
        const row = (try q.next()) orelse return error.NoCount;
        defer row.deinit(alloc);
        try testing.expectEqualStrings("0", row.values[0]);
    }
}

// ─── Test: countTasksInColumn counts only tasks in that column ───────────

test "countTasksInColumn returns the number of tasks assigned to the column" {
    const alloc = testing.allocator;
    var s = try setupDb();
    defer s.threaded.deinit();
    defer s.db.deinit();

    // Post-Migration-072 schema: workspace_item_tasks has no
    // kanban_column_id/kanban_position; the kanban join table holds
    // the 1:1 task-to-board placement.
    try s.db.exec(alloc,
        \\CREATE TABLE workspace_item_tasks (
        \\    id TEXT PRIMARY KEY, name TEXT, workspace_item_id TEXT)
    , &.{});
    try s.db.exec(alloc,
        \\CREATE TABLE kanban (
        \\    workspace_item_task_id TEXT PRIMARY KEY, kanban_column_id TEXT NOT NULL,
        \\    kanban_position INTEGER NOT NULL DEFAULT 0)
    , &.{});
    // Three tasks in c1, one in c2, one unassigned (no kanban row).
    try s.db.exec(alloc,
        "INSERT INTO workspace_item_tasks (id, name, workspace_item_id) VALUES " ++
            "('t1', 'A', 'item_1'), ('t2', 'B', 'item_1'), ('t3', 'C', 'item_1'), " ++
            "('t4', 'D', 'item_1'), ('t5', 'E', 'item_1')",
        &.{});
    try s.db.exec(alloc,
        "INSERT INTO kanban (workspace_item_task_id, kanban_column_id, kanban_position) VALUES " ++
            "('t1', 'c1', 0), ('t2', 'c1', 1), ('t3', 'c1', 2), ('t4', 'c2', 0)",
        &.{});

    try testing.expectEqual(@as(u32, 3), try countTasksInColumn(alloc, &s.db, "c1"));
    try testing.expectEqual(@as(u32, 1), try countTasksInColumn(alloc, &s.db, "c2"));
}

test "countTasksInColumn returns 0 when no tasks reference the column" {
    const alloc = testing.allocator;
    var s = try setupDb();
    defer s.threaded.deinit();
    defer s.db.deinit();

    try s.db.exec(alloc,
        \\CREATE TABLE workspace_item_tasks (
        \\    id TEXT PRIMARY KEY, name TEXT, workspace_item_id TEXT)
    , &.{});
    try s.db.exec(alloc,
        \\CREATE TABLE kanban (
        \\    workspace_item_task_id TEXT PRIMARY KEY, kanban_column_id TEXT NOT NULL,
        \\    kanban_position INTEGER NOT NULL DEFAULT 0)
    , &.{});
    try s.db.exec(alloc,
        "INSERT INTO workspace_item_tasks (id, name, workspace_item_id) VALUES ('t1', 'A', 'item_1')", &.{});
    try s.db.exec(alloc,
        "INSERT INTO kanban (workspace_item_task_id, kanban_column_id, kanban_position) VALUES ('t1', 'c1', 0)", &.{});

    // c2 exists in kanban_columns but has no tasks — count is 0, not
    // an error. (The delete-handler treats 0 as "safe to delete".)
    try testing.expectEqual(@as(u32, 0), try countTasksInColumn(alloc, &s.db, "c2"));
    // Non-existent column id also returns 0 (no rows match the FK).
    try testing.expectEqual(@as(u32, 0), try countTasksInColumn(alloc, &s.db, "col_does_not_exist"));
}

test "countTasksInColumn returns 0 when the kanban table is empty" {
    const alloc = testing.allocator;
    var s = try setupDb();
    defer s.threaded.deinit();
    defer s.db.deinit();

    try s.db.exec(alloc,
        \\CREATE TABLE kanban (
        \\    workspace_item_task_id TEXT PRIMARY KEY, kanban_column_id TEXT NOT NULL,
        \\    kanban_position INTEGER NOT NULL DEFAULT 0)
    , &.{});

    try testing.expectEqual(@as(u32, 0), try countTasksInColumn(alloc, &s.db, "any_column"));
}

// ─── Test: moveTask changes column and renumbers positions ──────────────

test "moveTask changes column and renumbers positions" {
    const alloc = testing.allocator;
    var s = try setupDb();
    defer s.threaded.deinit();
    defer s.db.deinit();

    try s.db.exec(alloc,
        "CREATE TABLE workspace_items (id TEXT PRIMARY KEY, workspace_id TEXT, item_type TEXT)", &.{});
    try s.db.exec(alloc,
        \\CREATE TABLE kanban_columns (
        \\    id TEXT PRIMARY KEY, workspace_item_id TEXT, name TEXT, description TEXT NOT NULL DEFAULT '',
        \\    position INTEGER, is_done INTEGER NOT NULL DEFAULT 0, created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP)
    , &.{});
    // Post-Migration-072 schema
    try s.db.exec(alloc,
        \\CREATE TABLE workspace_item_tasks (
        \\    id TEXT PRIMARY KEY, name TEXT, workspace_item_id TEXT)
    , &.{});
    try s.db.exec(alloc,
        \\CREATE TABLE kanban (
        \\    workspace_item_task_id TEXT PRIMARY KEY, kanban_column_id TEXT NOT NULL,
        \\    kanban_position INTEGER NOT NULL DEFAULT 0)
    , &.{});
    try s.db.exec(alloc,
        "INSERT INTO workspace_items (id, workspace_id, item_type) VALUES ('item_1', 'ws_1', 'kanban')", &.{});
    try s.db.exec(alloc,
        "INSERT INTO kanban_columns (id, workspace_item_id, name, position) VALUES ('c1', 'item_1', 'todo', 0)", &.{});
    try s.db.exec(alloc,
        "INSERT INTO kanban_columns (id, workspace_item_id, name, position) VALUES ('c2', 'item_1', 'done', 1)", &.{});
    try s.db.exec(alloc,
        "INSERT INTO workspace_item_tasks (id, name, workspace_item_id) VALUES ('t1', 'A', 'item_1')", &.{});
    try s.db.exec(alloc,
        "INSERT INTO workspace_item_tasks (id, name, workspace_item_id) VALUES ('t2', 'B', 'item_1')", &.{});
    try s.db.exec(alloc,
        "INSERT INTO workspace_item_tasks (id, name, workspace_item_id) VALUES ('t3', 'C', 'item_1')", &.{});
    try s.db.exec(alloc,
        "INSERT INTO kanban (workspace_item_task_id, kanban_column_id, kanban_position) VALUES ('t1', 'c1', 0)", &.{});
    try s.db.exec(alloc,
        "INSERT INTO kanban (workspace_item_task_id, kanban_column_id, kanban_position) VALUES ('t2', 'c1', 1)", &.{});
    try s.db.exec(alloc,
        "INSERT INTO kanban (workspace_item_task_id, kanban_column_id, kanban_position) VALUES ('t3', 'c2', 0)", &.{});

    // Move t1 (was c1 pos 0) to c2 pos 0
    try moveTask(alloc, &s.db, "item_1", "t1", "c2", 0);

    var q = try s.db.query(alloc,
        "SELECT k.workspace_item_task_id, k.kanban_column_id, k.kanban_position " ++
        "FROM kanban k " ++
        "WHERE k.workspace_item_task_id IN ('t1', 't2', 't3') ORDER BY k.workspace_item_task_id", &.{});
    defer q.deinit();
    // t1 → c2, pos 0
    const r1 = (try q.next()) orelse return error.NoTask;
    defer r1.deinit(alloc);
    try testing.expectEqualStrings("t1", r1.values[0]);
    try testing.expectEqualStrings("c2", r1.values[1]);
    try testing.expectEqualStrings("0", r1.values[2]);
    // t2 → c1, pos 0 (compacted up after t1 left)
    const r2 = (try q.next()) orelse return error.NoTask;
    defer r2.deinit(alloc);
    try testing.expectEqualStrings("t2", r2.values[0]);
    try testing.expectEqualStrings("c1", r2.values[1]);
    try testing.expectEqualStrings("0", r2.values[2]);
    // t3 → c2, pos 1 (shifted down after t1 arrived)
    const r3 = (try q.next()) orelse return error.NoTask;
    defer r3.deinit(alloc);
    try testing.expectEqualStrings("t3", r3.values[0]);
    try testing.expectEqualStrings("c2", r3.values[1]);
    try testing.expectEqualStrings("1", r3.values[2]);
}

// ─── Test: reorderColumn shifts siblings to keep positions dense ─────────
// Mirrors the two-step drag scenario from the plan: - move "done" from slot 3
// to slot 0 → [done, todo, ip, rev] - move "todo" from slot 1 to slot 2 →
test "reorderColumn shifts siblings to a dense sequence matching the user's intent" {
    const alloc = testing.allocator;
    var s = try setupDb();
    defer s.threaded.deinit();
    defer s.db.deinit();

    try s.db.exec(alloc,
        "CREATE TABLE workspace_items (id TEXT PRIMARY KEY, workspace_id TEXT, item_type TEXT)", &.{});
    try s.db.exec(alloc,
        \\CREATE TABLE kanban_columns (
        \\    id TEXT PRIMARY KEY, workspace_item_id TEXT, name TEXT, description TEXT NOT NULL DEFAULT '',
        \\    position INTEGER, is_done INTEGER NOT NULL DEFAULT 0, created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP)
    , &.{});
    try s.db.exec(alloc,
        "INSERT INTO workspace_items (id, workspace_id, item_type) VALUES ('item_1', 'ws_1', 'kanban')", &.{});
    // Seed 4 columns at dense positions 0..3. The names (todo, ip, rev, done)
    // and ids (c1..c4) don't match — the renumber uses CURRENT position
    // order, not lex-id, so the id labels are arbitrary.
    try s.db.exec(alloc,
        "INSERT INTO kanban_columns (id, workspace_item_id, name, position) VALUES ('c1', 'item_1', 'todo', 0)", &.{});
    try s.db.exec(alloc,
        "INSERT INTO kanban_columns (id, workspace_item_id, name, position) VALUES ('c2', 'item_1', 'in_progress', 1)", &.{});
    try s.db.exec(alloc,
        "INSERT INTO kanban_columns (id, workspace_item_id, name, position) VALUES ('c3', 'item_1', 'review', 2)", &.{});
    try s.db.exec(alloc,
        "INSERT INTO kanban_columns (id, workspace_item_id, name, position) VALUES ('c4', 'item_1', 'done', 3)", &.{});

    // Helper: read columns in current position order, returning
    // their (id, position) pairs.
    const ColRow = struct {
        id: []const u8,
        position: i64,
    };
    const readByPos = struct {
        fn run(a: std.mem.Allocator, db: *database.Db, item_id: []const u8) ![]ColRow {
            var q = try db.query(a,
                \\SELECT kc.id, kc.position
                \\FROM kanban_columns kc
                \\WHERE kc.workspace_item_id = ?
                \\ORDER BY kc.position ASC
            , &.{item_id});
            defer q.deinit();
            var rows = std.ArrayList(ColRow).empty;
            errdefer rows.deinit(a);
            while (try q.next()) |row| {
                defer row.deinit(a);
                try rows.append(a, .{
                    .id = try a.dupe(u8, row.values[0]),
                    .position = try std.fmt.parseInt(i64, row.values[1], 10),
                });
            }
            return rows.toOwnedSlice(a);
        }
    }.run;

    // Step 1: drag "done" (c4) from slot 3 to slot 0.
    try reorderColumn(alloc, &s.db, "item_1", "c4", 0);

    const after1 = try readByPos(alloc, &s.db, "item_1");
    defer {
        for (after1) |r| alloc.free(r.id);
        alloc.free(after1);
    }
    try testing.expectEqual(@as(usize, 4), after1.len);
    // Expected: done (c4) at 0, then todo (c1) at 1, ip (c2) at 2,
    // rev (c3) at 3 — the OTHERS shifted right by 1.
    try testing.expectEqualStrings("c4", after1[0].id);
    try testing.expectEqual(@as(i64, 0), after1[0].position);
    try testing.expectEqualStrings("c1", after1[1].id);
    try testing.expectEqual(@as(i64, 1), after1[1].position);
    try testing.expectEqualStrings("c2", after1[2].id);
    try testing.expectEqual(@as(i64, 2), after1[2].position);
    try testing.expectEqualStrings("c3", after1[3].id);
    try testing.expectEqual(@as(i64, 3), after1[3].position);

    // Step 2: drag "todo" (c1) from slot 1 to slot 2.
    try reorderColumn(alloc, &s.db, "item_1", "c1", 2);

    const after2 = try readByPos(alloc, &s.db, "item_1");
    defer {
        for (after2) |r| alloc.free(r.id);
        alloc.free(after2);
    }
    try testing.expectEqual(@as(usize, 4), after2.len);
    // Expected: done (c4) at 0, ip (c2) at 1, todo (c1) at 2,
    // rev (c3) at 3.
    try testing.expectEqualStrings("c4", after2[0].id);
    try testing.expectEqual(@as(i64, 0), after2[0].position);
    try testing.expectEqualStrings("c2", after2[1].id);
    try testing.expectEqual(@as(i64, 1), after2[1].position);
    try testing.expectEqualStrings("c1", after2[2].id);
    try testing.expectEqual(@as(i64, 2), after2[2].position);
    try testing.expectEqualStrings("c3", after2[3].id);
    try testing.expectEqual(@as(i64, 3), after2[3].position);
}


// ─── Inline tests (formerly kanban_model_test_description.zig) ──────────
// Unit tests for kanban column description. Inlined here.

fn setupDbDescription() !struct { db: database.Db, threaded: std.Io.Threaded } {
    const alloc = testing.allocator;
    var threaded = std.Io.Threaded.init(alloc, .{});
    errdefer threaded.deinit();
    const io = threaded.io();
    var db: database.Db = .{};
    errdefer db.deinit();
    try test_db.openMemory(&db, io);
    // Migration 051 needs `workspace_items` (FK target) and
    // `workspace_item_tasks` (ALTER TABLE target).
    try db.exec(alloc,
        "CREATE TABLE workspace_items (id TEXT PRIMARY KEY, workspace_id TEXT, item_type TEXT)",
        &.{});
    try db.exec(alloc,
        "CREATE TABLE workspace_item_tasks (id TEXT PRIMARY KEY, name TEXT, workspace_item_id TEXT)",
        &.{});
    const migration = pabrikcore.migrations_mod.migration;
    try migration.Migration051AddKanban.up(&db, alloc);
    try migration.Migration053AddKanbanColumnDescription.up(&db, alloc);
    // Migration 111 — `listColumns` reads `is_done`, which 110 adds.
    try migration.Migration111AddKanbanTaskDependencies.up(&db, alloc);
    return .{ .db = db, .threaded = threaded };
}

test "addColumn writes description to the new row" {
    const alloc = testing.allocator;
    var ctx = try setupDbDescription();
    defer ctx.threaded.deinit();
    defer ctx.db.deinit();

    const id = try addColumn(alloc, .{ .db = &ctx.db }, "wi_1", "in_review", "Awaiting code review", 0,
    );
    defer alloc.free(id);

    const cols = try listColumns(alloc, &ctx.db, "wi_1");
    defer freeColumns(alloc, cols);

    try testing.expectEqual(@as(usize, 1), cols.len);
    try testing.expectEqualStrings("in_review", cols[0].name);
    try testing.expectEqualStrings("Awaiting code review", cols[0].description);
}

test "updateColumn with only description leaves name unchanged" {
    const alloc = testing.allocator;
    var ctx = try setupDbDescription();
    defer ctx.threaded.deinit();
    defer ctx.db.deinit();

    const id = try addColumn(alloc, .{ .db = &ctx.db }, "wi_1", "todo", "Not started", 0,
    );
    defer alloc.free(id);

    try updateColumn(
        alloc, &ctx.db, "wi_1", id, null, "Not started yet — work in queue",
    );

    const cols = try listColumns(alloc, &ctx.db, "wi_1");
    defer freeColumns(alloc, cols);

    try testing.expectEqualStrings("todo", cols[0].name);
    try testing.expectEqualStrings("Not started yet — work in queue", cols[0].description);
}

test "updateColumn with only name leaves description unchanged" {
    const alloc = testing.allocator;
    var ctx = try setupDbDescription();
    defer ctx.threaded.deinit();
    defer ctx.db.deinit();

    const id = try addColumn(alloc, .{ .db = &ctx.db }, "wi_1", "todo", "Not started", 0,
    );
    defer alloc.free(id);

    try updateColumn(alloc, &ctx.db, "wi_1", id, "backlog", null);

    const cols = try listColumns(alloc, &ctx.db, "wi_1");
    defer freeColumns(alloc, cols);

    try testing.expectEqualStrings("backlog", cols[0].name);
    try testing.expectEqualStrings("Not started", cols[0].description);
}

test "updateColumn with both name and description writes both" {
    const alloc = testing.allocator;
    var ctx = try setupDbDescription();
    defer ctx.threaded.deinit();
    defer ctx.db.deinit();

    const id = try addColumn(alloc, .{ .db = &ctx.db }, "wi_1", "todo", "old", 0,
    );
    defer alloc.free(id);

    try updateColumn(
        alloc, &ctx.db, "wi_1", id, "backlog", "Newly triaged items",
    );

    const cols = try listColumns(alloc, &ctx.db, "wi_1");
    defer freeColumns(alloc, cols);

    try testing.expectEqualStrings("backlog", cols[0].name);
    try testing.expectEqualStrings("Newly triaged items", cols[0].description);
}

test "seedDefaultColumns writes empty descriptions" {
    const alloc = testing.allocator;
    var ctx = try setupDbDescription();
    defer ctx.threaded.deinit();
    defer ctx.db.deinit();

    try seedDefaultColumns(alloc, .{ .db = &ctx.db }, "wi_1");

    const cols = try listColumns(alloc, &ctx.db, "wi_1");
    defer freeColumns(alloc, cols);

    try testing.expectEqual(@as(usize, 3), cols.len);
    for (cols) |c| {
        try testing.expectEqualStrings("", c.description);
    }
}

test "updateColumn with empty-string description clears existing description" {
    // Regression test for the 2026-06-30 PATCH bug: curl -X PATCH
    // .../kanban/columns/col_X \ --data-raw
    // '{"name":"in_review_planning","description":""}' The old code treated
    const alloc = testing.allocator;
    var ctx = try setupDbDescription();
    defer ctx.threaded.deinit();
    defer ctx.db.deinit();

    const id = try addColumn(alloc, .{ .db = &ctx.db }, "wi_1", "in_review", "Awaiting code review", 0,
    );
    defer alloc.free(id);

    // Sanity check: description was set on creation.
    {
        const cols = try listColumns(alloc, &ctx.db, "wi_1");
        defer freeColumns(alloc, cols);
        try testing.expectEqualStrings("Awaiting code review", cols[0].description);
    }

    // PATCH with description="" — must CLEAR the description (not
    // skip the UPDATE). The name stays unchanged.
    try updateColumn(
        alloc, &ctx.db, "wi_1", id, null, "",
    );

    const cols = try listColumns(alloc, &ctx.db, "wi_1");
    defer freeColumns(alloc, cols);

    try testing.expectEqualStrings("in_review", cols[0].name);
    try testing.expectEqualStrings("", cols[0].description);
}

test "updateColumn with null description leaves existing description unchanged" {
    // Companion to the empty-clear test above. Verifies that `null` still
    // means "leave unchanged" (field absent from PATCH body), distinct from
    // `""` (clear).
    const alloc = testing.allocator;
    var ctx = try setupDbDescription();
    defer ctx.threaded.deinit();
    defer ctx.db.deinit();

    const id = try addColumn(alloc, .{ .db = &ctx.db }, "wi_1", "todo", "Not started", 0,
    );
    defer alloc.free(id);

    // PATCH with name only — description must NOT be cleared.
    try updateColumn(alloc, &ctx.db, "wi_1", id, "backlog", null);

    const cols = try listColumns(alloc, &ctx.db, "wi_1");
    defer freeColumns(alloc, cols);

    try testing.expectEqualStrings("backlog", cols[0].name);
    try testing.expectEqualStrings("Not started", cols[0].description);
}

test "updateColumn with both empty description and new name writes both" {
    // Mixed PATCH: rename the column AND clear its description in the same
    // call.
    const alloc = testing.allocator;
    var ctx = try setupDbDescription();
    defer ctx.threaded.deinit();
    defer ctx.db.deinit();

    const id = try addColumn(alloc, .{ .db = &ctx.db }, "wi_1", "in_review", "Awaiting code review", 0,
    );
    defer alloc.free(id);

    try updateColumn(
        alloc, &ctx.db, "wi_1", id, "in_review_planning", "",
    );

    const cols = try listColumns(alloc, &ctx.db, "wi_1");
    defer freeColumns(alloc, cols);

    try testing.expectEqualStrings("in_review_planning", cols[0].name);
    try testing.expectEqualStrings("", cols[0].description);
}


// ─── Inline tests (formerly kanban_copy_spec_test.zig) ───────────────────
// In-memory round-trip tests for replaceColumnsWith + appendColumnsFrom.
// Inlined here.

fn setupDbCopy() !struct { db: database.Db, threaded: std.Io.Threaded } {
    const alloc = testing.allocator;
    var threaded = std.Io.Threaded.init(alloc, .{});
    errdefer threaded.deinit();
    const io = threaded.io();
    var db: database.Db = .{};
    errdefer db.deinit();
    try test_db.openMemory(&db, io);
    // Migration 051 needs `workspace_items` (FK target) and
    // `workspace_item_tasks` (ALTER TABLE target).
    try db.exec(alloc,
        "CREATE TABLE workspace_items (id TEXT PRIMARY KEY, workspace_id TEXT, item_type TEXT)",
        &.{});
    try db.exec(alloc,
        "CREATE TABLE workspace_item_tasks (id TEXT PRIMARY KEY, name TEXT, workspace_item_id TEXT)",
        &.{});
    const migration = @import("pabrikcore").migrations_mod.migration;
    try migration.Migration051AddKanban.up(&db, alloc);
    try migration.Migration053AddKanbanColumnDescription.up(&db, alloc);
    try migration.Migration072ExtractKanbanTable.up(&db, alloc);
    // Migration 111 — `listColumns` reads `is_done`, which 110 adds.
    try migration.Migration111AddKanbanTaskDependencies.up(&db, alloc);
    return .{ .db = db, .threaded = threaded };
}

/// Seed a column and immediately free the returned id.
fn seedColumn(
    alloc: std.mem.Allocator,
    db: *database.Db,
    workspace_item_id: []const u8,
    name: []const u8,
    description: []const u8,
    position: i64,
) !void {
    const id = try addColumn(
        alloc,
        .{ .db = db },
        workspace_item_id,
        name,
        description,
        position,
    );
    defer alloc.free(id);
}

test "replaceColumnsWith deletes target columns and copies source columns" {
    const alloc = testing.allocator;
    var ctx = try setupDbCopy();
    defer ctx.threaded.deinit();
    defer ctx.db.deinit();

    // Seed source kanban with 3 columns.
    try seedColumn(alloc, &ctx.db, "wi_src", "todo", "", 0);
    try seedColumn(alloc, &ctx.db, "wi_src", "in progress", "", 1);
    try seedColumn(alloc, &ctx.db, "wi_src", "done", "", 2);

    // Seed target kanban with 1 column (different from source).
    try seedColumn(alloc, &ctx.db, "wi_tgt", "legacy", "", 0);

    try replaceColumnsWith(alloc, &ctx.db, "wi_src", "wi_tgt");

    const cols = try listColumns(alloc, &ctx.db, "wi_tgt");
    defer freeColumns(alloc, cols);

    try testing.expectEqual(@as(usize, 3), cols.len);
    try testing.expectEqualStrings("todo", cols[0].name);
    try testing.expectEqualStrings("in progress", cols[1].name);
    try testing.expectEqualStrings("done", cols[2].name);
    // Positions are 0, 1, 2 (dense).
    try testing.expectEqual(@as(i64, 0), cols[0].position);
    try testing.expectEqual(@as(i64, 1), cols[1].position);
    try testing.expectEqual(@as(i64, 2), cols[2].position);
}

test "replaceColumnsWith preserves description field" {
    const alloc = testing.allocator;
    var ctx = try setupDbCopy();
    defer ctx.threaded.deinit();
    defer ctx.db.deinit();

    try seedColumn(alloc, &ctx.db, "wi_src", "in_review", "Awaiting code review", 0);
    try seedColumn(alloc, &ctx.db, "wi_tgt", "old", "Old desc", 0);

    try replaceColumnsWith(alloc, &ctx.db, "wi_src", "wi_tgt");

    const cols = try listColumns(alloc, &ctx.db, "wi_tgt");
    defer freeColumns(alloc, cols);
    try testing.expectEqualStrings("Awaiting code review", cols[0].description);
}

test "appendColumnsFrom adds source columns to target without deleting" {
    const alloc = testing.allocator;
    var ctx = try setupDbCopy();
    defer ctx.threaded.deinit();
    defer ctx.db.deinit();

    try seedColumn(alloc, &ctx.db, "wi_src", "review", "", 0);
    try seedColumn(alloc, &ctx.db, "wi_src", "merged", "", 1);

    try seedColumn(alloc, &ctx.db, "wi_tgt", "todo", "", 0);
    try seedColumn(alloc, &ctx.db, "wi_tgt", "in progress", "", 1);
    try seedColumn(alloc, &ctx.db, "wi_tgt", "done", "", 2);

    try appendColumnsFrom(alloc, &ctx.db, "wi_src", "wi_tgt");

    const cols = try listColumns(alloc, &ctx.db, "wi_tgt");
    defer freeColumns(alloc, cols);
    try testing.expectEqual(@as(usize, 5), cols.len);
    // Original target columns kept their positions 0,1,2.
    try testing.expectEqualStrings("todo", cols[0].name);
    try testing.expectEqualStrings("in progress", cols[1].name);
    try testing.expectEqualStrings("done", cols[2].name);
    // Source columns appended at MAX+1, MAX+2 (positions 3, 4).
    try testing.expectEqualStrings("review", cols[3].name);
    try testing.expectEqualStrings("merged", cols[4].name);
    try testing.expectEqual(@as(i64, 3), cols[3].position);
    try testing.expectEqual(@as(i64, 4), cols[4].position);
}

test "replaceColumnsWith unassigns tasks on the deleted target columns" {
    const alloc = testing.allocator;
    var ctx = try setupDbCopy();
    defer ctx.threaded.deinit();
    defer ctx.db.deinit();

    try seedColumn(alloc, &ctx.db, "wi_src", "todo", "", 0);
    // Capture the legacy column id before the replace — we'll verify the task
    // referencing it was unassigned. addColumn returns a heap-allocated id
    // that we must free (see seedColumn's doc on why an explicit `defer
    const legacy_id = try addColumn(alloc, .{ .db = &ctx.db }, "wi_tgt", "legacy", "", 0);
    defer alloc.free(legacy_id);

    // Create a task assigned to the target's "legacy" column. After Migration
    // 072, the task→column mapping lives in the `kanban` join table (1:1 row
    // per assigned task), not on workspace_item_tasks directly.
    try ctx.db.exec(alloc,
        "INSERT INTO workspace_item_tasks (id, workspace_item_id) VALUES ('task_1', 'wi_tgt')",
        &.{});
    try ctx.db.exec(alloc,
        "INSERT INTO kanban (workspace_item_task_id, kanban_column_id, kanban_position) VALUES ('task_1', ?, 0)",
        &.{legacy_id});

    try replaceColumnsWith(alloc, &ctx.db, "wi_src", "wi_tgt");

    // Verify the kanban card row was DELETED when the column was replaced (FK
    // CASCADE simulation — PRAGMA foreign_keys is off in this codebase, so we
    // explicitly DELETE the kanban rows in deleteColumn).
    {
        var q = try ctx.db.query(alloc,
            "SELECT COUNT(*) FROM kanban k WHERE k.workspace_item_task_id = 'task_1'",
            &.{});
        defer q.deinit();
        const row = (try q.next()) orelse return error.RowMissing;
        defer row.deinit(alloc);
        try testing.expectEqualStrings("0", row.values[0]);
    }

    // Sanity: the task row still exists.
    {
        var q2 = try ctx.db.query(alloc,
            "SELECT t.id FROM workspace_item_tasks t WHERE t.id = 'task_1'",
            &.{});
        defer q2.deinit();
        const r2 = (try q2.next()) orelse return error.RowMissing;
        defer r2.deinit(alloc);
        try testing.expectEqualStrings("task_1", r2.values[0]);
    }
}

test "replaceColumnsWith with empty source empties the target" {
    const alloc = testing.allocator;
    var ctx = try setupDbCopy();
    defer ctx.threaded.deinit();
    defer ctx.db.deinit();

    try seedColumn(alloc, &ctx.db, "wi_src", "todo", "", 0);
    try seedColumn(alloc, &ctx.db, "wi_tgt", "x", "", 0);
    try seedColumn(alloc, &ctx.db, "wi_tgt", "y", "", 1);

    // Manually empty the source.
    try ctx.db.exec(alloc, "DELETE FROM kanban_columns WHERE workspace_item_id = 'wi_src'", &.{});

    try replaceColumnsWith(alloc, &ctx.db, "wi_src", "wi_tgt");

    const cols = try listColumns(alloc, &ctx.db, "wi_tgt");
    defer freeColumns(alloc, cols);
    try testing.expectEqual(@as(usize, 0), cols.len);
}

// ─── Dependency gate tests (Migration 111) ──────────────────────────────
// A task waiting on an unfinished dependency must not change column. The board
// is `c1 todo / c2 in progress` (not completing) and `c3 done` (completing).

const GateDb = struct {
    db: database.Db,
    threaded: std.Io.Threaded,

    fn deinit(self: *GateDb) void {
        self.db.deinit();
        self.threaded.deinit();
    }
};

fn setupGateDb() !GateDb {
    const alloc = testing.allocator;
    var threaded = std.Io.Threaded.init(alloc, .{});
    errdefer threaded.deinit();

    var db: database.Db = .{};
    errdefer db.deinit();
    try test_db.openMemory(&db, threaded.io());

    try db.exec(alloc,
        \\CREATE TABLE kanban_columns (
        \\    id TEXT PRIMARY KEY, workspace_item_id TEXT, name TEXT,
        \\    description TEXT NOT NULL DEFAULT '', position INTEGER,
        \\    is_done INTEGER NOT NULL DEFAULT 0,
        \\    created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP)
    , &.{});
    try db.exec(alloc,
        \\CREATE TABLE workspace_item_tasks (
        \\    id TEXT PRIMARY KEY, name TEXT, workspace_item_id TEXT)
    , &.{});
    try db.exec(alloc,
        \\CREATE TABLE kanban (
        \\    workspace_item_task_id TEXT PRIMARY KEY, kanban_column_id TEXT NOT NULL,
        \\    kanban_position INTEGER NOT NULL DEFAULT 0)
    , &.{});
    try db.exec(alloc,
        \\CREATE TABLE kanban_task_dependencies (
        \\    task_id TEXT NOT NULL, depends_on_task_id TEXT NOT NULL,
        \\    created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
        \\    PRIMARY KEY (task_id, depends_on_task_id))
    , &.{});

    try db.exec(alloc,
        "INSERT INTO kanban_columns (id, workspace_item_id, name, position, is_done) VALUES ('c1', 'item_1', 'todo', 0, 0)", &.{});
    try db.exec(alloc,
        "INSERT INTO kanban_columns (id, workspace_item_id, name, position, is_done) VALUES ('c2', 'item_1', 'in progress', 1, 0)", &.{});
    try db.exec(alloc,
        "INSERT INTO kanban_columns (id, workspace_item_id, name, position, is_done) VALUES ('c3', 'item_1', 'done', 2, 1)", &.{});
    try db.exec(alloc,
        "INSERT INTO workspace_item_tasks (id, name, workspace_item_id) VALUES ('t1', 'Ship it', 'item_1')", &.{});
    try db.exec(alloc,
        "INSERT INTO workspace_item_tasks (id, name, workspace_item_id) VALUES ('t2', 'Fix login', 'item_1')", &.{});
    try db.exec(alloc,
        "INSERT INTO kanban (workspace_item_task_id, kanban_column_id, kanban_position) VALUES ('t1', 'c2', 0)", &.{});
    try db.exec(alloc,
        "INSERT INTO kanban (workspace_item_task_id, kanban_column_id, kanban_position) VALUES ('t2', 'c1', 0)", &.{});
    try db.exec(alloc,
        "INSERT INTO kanban_task_dependencies (task_id, depends_on_task_id) VALUES ('t1', 't2')", &.{});

    return .{ .db = db, .threaded = threaded };
}

fn columnOfTask(db: *database.Db, task_id: []const u8) ![]u8 {
    const alloc = testing.allocator;
    var q = try db.query(alloc,
        "SELECT kanban_column_id FROM kanban WHERE workspace_item_task_id = ?", &.{task_id});
    defer q.deinit();
    const row = (try q.next()) orelse return error.NoAssignment;
    defer row.deinit(alloc);
    return alloc.dupe(u8, row.values[0]);
}

test "kanban move gate: reordering inside the current column is always allowed" {
    const alloc = testing.allocator;
    var s = try setupGateDb();
    defer s.deinit();

    // t1 is blocked by t2, but staying in `c2` is not a move.
    try assertMoveAllowed(alloc, &s.db, "t1", "c2");
}

test "kanban move gate: a blocked task cannot change column" {
    const alloc = testing.allocator;
    var s = try setupGateDb();
    defer s.deinit();

    try testing.expectError(
        error.BlockedByDependencies,
        assertMoveAllowed(alloc, &s.db, "t1", "c1"),
    );
    try testing.expectError(
        error.BlockedByDependencies,
        assertMoveAllowed(alloc, &s.db, "t1", "c3"),
    );
}

test "kanban move gate: an unassigned task can still be placed on a column" {
    const alloc = testing.allocator;
    var s = try setupGateDb();
    defer s.deinit();

    // No `kanban` row: there is no column to leave, so assigning it is not a
    // move away from anything.
    try s.db.exec(alloc, "DELETE FROM kanban WHERE workspace_item_task_id = 't1'", &.{});
    try assertMoveAllowed(alloc, &s.db, "t1", "c1");
}

test "kanban move gate: the dependency completing unblocks the blocked task" {
    const alloc = testing.allocator;
    var s = try setupGateDb();
    defer s.deinit();

    try testing.expectError(
        error.BlockedByDependencies,
        assertMoveAllowed(alloc, &s.db, "t1", "c3"),
    );

    // t2 reaches the column flagged `is_done`.
    try moveTask(alloc, &s.db, "item_1", "t2", "c3", 0);

    try assertMoveAllowed(alloc, &s.db, "t1", "c3");
}

test "kanban move gate: an is_done column that is NOT last still completes a task" {
    const alloc = testing.allocator;
    var s = try setupGateDb();
    defer s.deinit();

    // `c3` is flagged done and `c1`/`c2` are not — the gate must read the FLAG,
    // not the position (on the real board the last column is `drop`).
    try moveTask(alloc, &s.db, "item_1", "t2", "c3", 0);
    try assertMoveAllowed(alloc, &s.db, "t1", "c1");
}

test "kanban move gate: moveTaskChecked enforces the gate and force bypasses it" {
    const alloc = testing.allocator;
    var s = try setupGateDb();
    defer s.deinit();

    try testing.expectError(
        error.BlockedByDependencies,
        moveTaskChecked(alloc, &s.db, "item_1", "t1", "c3", 0, false),
    );
    {
        const col = try columnOfTask(&s.db, "t1");
        defer alloc.free(col);
        try testing.expectEqualStrings("c2", col);
    }

    // The human's "Move anyway".
    try moveTaskChecked(alloc, &s.db, "item_1", "t1", "c3", 0, true);
    {
        const col = try columnOfTask(&s.db, "t1");
        defer alloc.free(col);
        try testing.expectEqualStrings("c3", col);
    }
}

test "kanban move gate: incompleteDependencies reports the blockers and their columns" {
    const alloc = testing.allocator;
    var s = try setupGateDb();
    defer s.deinit();

    {
        const blocked = try incompleteDependencies(alloc, &s.db, "t1");
        defer deps.freeEdges(alloc, blocked);
        try testing.expectEqual(@as(usize, 1), blocked.len);
        try testing.expectEqualStrings("t2", blocked[0].depends_on_task_id);
        try testing.expectEqualStrings("Fix login", blocked[0].name);
        try testing.expectEqualStrings("c1", blocked[0].column_id);
        try testing.expectEqualStrings("todo", blocked[0].column_name);
    }

    // Resolved -> no blockers.
    try moveTask(alloc, &s.db, "item_1", "t2", "c3", 0);
    const blocked = try incompleteDependencies(alloc, &s.db, "t1");
    defer deps.freeEdges(alloc, blocked);
    try testing.expectEqual(@as(usize, 0), blocked.len);
}

test "kanban move gate: listColumns reports the is_done flag" {
    const alloc = testing.allocator;
    var s = try setupGateDb();
    defer s.deinit();

    const cols = try listColumns(alloc, &s.db, "item_1");
    defer freeColumns(alloc, cols);

    try testing.expectEqual(@as(usize, 3), cols.len);
    try testing.expect(!cols[0].is_done);
    try testing.expect(!cols[1].is_done);
    try testing.expect(cols[2].is_done);

    // And the flag round-trips through setColumnIsDone.
    try setColumnIsDone(alloc, &s.db, "c1", true);
    const after = try listColumns(alloc, &s.db, "item_1");
    defer freeColumns(alloc, after);
    try testing.expect(after[0].is_done);
}
