const std = @import("std");
const test_db = @import("../testing/test_db.zig");
const common = @import("common.zig");

const Backend = common.Backend;
const dialect = common.dialect;

/// Migration 149 — a database created before Migration 072's DDL was corrected
/// keeps `ON DELETE SET NULL` on the `NOT NULL` `kanban.kanban_column_id`, so
/// deleting a kanban project rolls back with a NOT NULL constraint error.
pub const Migration149RepairKanbanColumnCascade = struct {
    pub const version: u32 = 149;
    pub const name = "repair_kanban_column_cascade";

    const table = "kanban";
    const column = "kanban_column_id";
    const parent = "kanban_columns";
    const index_name = "idx_kanban_column_position";

    pub fn up(db: *Backend, allocator: std.mem.Allocator) anyerror!void {
        if (!try dialect.tableExists(.{ .db = db }, allocator, table)) return;
        if (try cascadesOnColumnDelete(db, allocator)) return;

        if (dialect.is_postgres) {
            try db.exec(allocator, "ALTER TABLE kanban DROP CONSTRAINT IF EXISTS kanban_kanban_column_id_fkey", &.{});
            try db.exec(
                allocator,
                "ALTER TABLE kanban ADD CONSTRAINT kanban_kanban_column_id_fkey FOREIGN KEY (kanban_column_id) REFERENCES kanban_columns(id) ON DELETE CASCADE",
                &.{},
            );
            return;
        }

        var tx = try db.begin();
        defer tx.commitOrRollback() catch {};
        errdefer tx.rollback() catch {};

        try tx.exec(allocator,
            \\CREATE TABLE kanban_repaired (
            \\    workspace_item_task_id TEXT PRIMARY KEY,
            \\    kanban_column_id       TEXT NOT NULL,
            \\    kanban_position        INTEGER NOT NULL DEFAULT 0,
            \\    FOREIGN KEY (workspace_item_task_id)
            \\        REFERENCES workspace_item_tasks(id) ON DELETE CASCADE,
            \\    FOREIGN KEY (kanban_column_id)
            \\        REFERENCES kanban_columns(id) ON DELETE CASCADE
            \\)
        , &.{});
        try tx.exec(
            allocator,
            "INSERT INTO kanban_repaired (workspace_item_task_id, kanban_column_id, kanban_position) " ++
                "SELECT workspace_item_task_id, kanban_column_id, kanban_position FROM kanban",
            &.{},
        );
        try tx.exec(allocator, "DROP TABLE kanban", &.{});
        try tx.exec(allocator, "ALTER TABLE kanban_repaired RENAME TO kanban", &.{});
        try tx.exec(
            allocator,
            "CREATE INDEX IF NOT EXISTS " ++ index_name ++ " ON kanban(kanban_column_id, kanban_position)",
            &.{},
        );

        try tx.commit();
    }

    /// True when the placement already dies with its column — the shape a
    /// database created after Migration 072 was corrected has.
    fn cascadesOnColumnDelete(db: *Backend, allocator: std.mem.Allocator) !bool {
        if (dialect.is_postgres) {
            var row = try db.queryRow(
                allocator,
                "SELECT confdeltype FROM pg_constraint WHERE conrelid = 'kanban'::regclass AND contype = 'f' " ++
                    "AND pg_get_constraintdef(oid) LIKE '%kanban_column_id%'",
                &.{},
            );
            defer row.deinit(allocator);
            if (row.values.len == 0) return false;
            return std.mem.eql(u8, row.values[0], "c");
        }

        var rows = try db.query(
            allocator,
            "SELECT \"on_delete\" FROM pragma_foreign_key_list('kanban') WHERE \"from\" = ?",
            &.{column},
        );
        defer rows.deinit();

        var found = false;
        while (try rows.next()) |row| {
            defer row.deinit(allocator);
            if (!std.mem.eql(u8, row.values[0], "CASCADE")) return false;
            found = true;
        }
        return found;
    }
};

const testing = std.testing;

fn openLegacyDb(alloc: std.mem.Allocator, comptime placement_on_delete: []const u8) !struct { db: Backend, threaded: std.Io.Threaded } {
    var threaded = std.Io.Threaded.init(alloc, .{});
    errdefer threaded.deinit();
    var db: Backend = .{};
    errdefer db.deinit();
    try test_db.openMemory(&db, threaded.io());

    try db.exec(alloc, "CREATE TABLE workspace_items (id TEXT PRIMARY KEY, workspace_id TEXT NOT NULL, item_type TEXT NOT NULL)", &.{});
    try db.exec(alloc, "CREATE TABLE workspace_item_tasks (id TEXT PRIMARY KEY, name TEXT NOT NULL, workspace_item_id TEXT NOT NULL)", &.{});
    try db.exec(alloc,
        \\CREATE TABLE kanban_columns (
        \\    id TEXT PRIMARY KEY,
        \\    workspace_item_id TEXT NOT NULL,
        \\    name TEXT NOT NULL,
        \\    position INTEGER NOT NULL,
        \\    FOREIGN KEY (workspace_item_id) REFERENCES workspace_items(id) ON DELETE CASCADE
        \\)
    , &.{});
    try db.exec(alloc,
        \\CREATE TABLE kanban (
        \\    workspace_item_task_id TEXT PRIMARY KEY,
        \\    kanban_column_id TEXT NOT NULL,
        \\    kanban_position INTEGER NOT NULL DEFAULT 0,
        \\    FOREIGN KEY (workspace_item_task_id) REFERENCES workspace_item_tasks(id) ON DELETE CASCADE,
        \\    FOREIGN KEY (kanban_column_id) REFERENCES kanban_columns(id) ON DELETE 
    ++ placement_on_delete ++
        \\)
    , &.{});
    try db.exec(alloc, "CREATE INDEX idx_kanban_column_position ON kanban(kanban_column_id, kanban_position)", &.{});
    return .{ .db = db, .threaded = threaded };
}

fn seedProject(db: *Backend, alloc: std.mem.Allocator) !void {
    try db.exec(alloc, "INSERT INTO workspace_items (id, workspace_id, item_type) VALUES ('item_1', 'ws_1', 'kanban')", &.{});
    try db.exec(alloc, "INSERT INTO kanban_columns (id, workspace_item_id, name, position) VALUES ('col_1', 'item_1', 'todo', 0)", &.{});
    try db.exec(alloc, "INSERT INTO workspace_item_tasks (id, name, workspace_item_id) VALUES ('task_1', 'a task', 'item_1')", &.{});
    try db.exec(alloc, "INSERT INTO kanban (workspace_item_task_id, kanban_column_id, kanban_position) VALUES ('task_1', 'col_1', 0)", &.{});
}

fn placementColumnCount(db: *Backend, alloc: std.mem.Allocator) !usize {
    var row = try db.queryRow(alloc, "SELECT COUNT(*) FROM kanban", &.{});
    defer row.deinit(alloc);
    return std.fmt.parseInt(usize, row.values[0], 10) catch 0;
}

fn onDeleteOfPlacement(db: *Backend, alloc: std.mem.Allocator) ![]const u8 {
    var row = try db.queryRow(
        alloc,
        "SELECT \"on_delete\" FROM pragma_foreign_key_list('kanban') WHERE \"from\" = 'kanban_column_id'",
        &.{},
    );
    defer row.deinit(alloc);
    return try alloc.dupe(u8, row.values[0]);
}

test "Migration149 lets a project delete drop its columns instead of nulling a NOT NULL placement" {
    if (dialect.is_postgres) return;
    const alloc = testing.allocator;
    var ctx = try openLegacyDb(alloc, "SET NULL");
    defer ctx.threaded.deinit();
    defer ctx.db.deinit();

    try seedProject(&ctx.db, alloc);

    try test_db.enableForeignKeys(alloc, &ctx.db);
    try testing.expectError(
        error.ExecuteFailed,
        ctx.db.exec(alloc, "DELETE FROM workspace_items WHERE id = 'item_1'", &.{}),
    );
    try ctx.db.exec(alloc, "PRAGMA foreign_keys = OFF", &.{});

    try Migration149RepairKanbanColumnCascade.up(&ctx.db, alloc);

    const action = try onDeleteOfPlacement(&ctx.db, alloc);
    defer alloc.free(action);
    try testing.expectEqualStrings("CASCADE", action);

    try testing.expectEqual(@as(usize, 1), try placementColumnCount(&ctx.db, alloc));

    try test_db.enableForeignKeys(alloc, &ctx.db);
    try ctx.db.exec(alloc, "DELETE FROM workspace_items WHERE id = 'item_1'", &.{});

    try testing.expectEqual(@as(usize, 0), try placementColumnCount(&ctx.db, alloc));
}

test "Migration149 leaves a placement table that already cascades alone, rows and index intact" {
    if (dialect.is_postgres) return;
    const alloc = testing.allocator;
    var ctx = try openLegacyDb(alloc, "CASCADE");
    defer ctx.threaded.deinit();
    defer ctx.db.deinit();

    try seedProject(&ctx.db, alloc);
    try Migration149RepairKanbanColumnCascade.up(&ctx.db, alloc);
    try Migration149RepairKanbanColumnCascade.up(&ctx.db, alloc);

    const action = try onDeleteOfPlacement(&ctx.db, alloc);
    defer alloc.free(action);
    try testing.expectEqualStrings("CASCADE", action);
    try testing.expectEqual(@as(usize, 1), try placementColumnCount(&ctx.db, alloc));

    var row = try ctx.db.queryRow(
        alloc,
        "SELECT COUNT(*) FROM sqlite_master WHERE type = 'index' AND name = 'idx_kanban_column_position'",
        &.{},
    );
    defer row.deinit(alloc);
    try testing.expectEqualStrings("1", row.values[0]);
}

test "Migration149 keeps the placement index a repaired database had" {
    if (dialect.is_postgres) return;
    const alloc = testing.allocator;
    var ctx = try openLegacyDb(alloc, "SET NULL");
    defer ctx.threaded.deinit();
    defer ctx.db.deinit();

    try Migration149RepairKanbanColumnCascade.up(&ctx.db, alloc);

    var row = try ctx.db.queryRow(
        alloc,
        "SELECT COUNT(*) FROM sqlite_master WHERE type = 'index' AND name = 'idx_kanban_column_position'",
        &.{},
    );
    defer row.deinit(alloc);
    try testing.expectEqualStrings("1", row.values[0]);
}

test "Migration149 is a no-op on a database with no placement table" {
    const alloc = testing.allocator;
    var threaded = std.Io.Threaded.init(alloc, .{});
    defer threaded.deinit();
    var db: Backend = .{};
    defer db.deinit();
    try test_db.openMemory(&db, threaded.io());
    try Migration149RepairKanbanColumnCascade.up(&db, alloc);
}
// ════════════════════════════════════════════════════════════════════════════
// Migration149 — postgres path (the sqlite tests above cannot reach it)
// ════════════════════════════════════════════════════════════════════════════

fn openPgLegacyDb(alloc: std.mem.Allocator) !struct { db: Backend, threaded: std.Io.Threaded } {
    var threaded = std.Io.Threaded.init(alloc, .{});
    errdefer threaded.deinit();
    var db: Backend = .{};
    errdefer db.deinit();
    try test_db.openMemory(&db, threaded.io());

    try db.exec(alloc, "CREATE TABLE workspace_items (id TEXT PRIMARY KEY, workspace_id TEXT NOT NULL, item_type TEXT NOT NULL)", &.{});
    try db.exec(alloc, "CREATE TABLE workspace_item_tasks (id TEXT PRIMARY KEY, name TEXT NOT NULL, workspace_item_id TEXT NOT NULL)", &.{});
    try db.exec(alloc,
        \\CREATE TABLE kanban_columns (
        \\    id TEXT PRIMARY KEY,
        \\    workspace_item_id TEXT NOT NULL,
        \\    name TEXT NOT NULL,
        \\    position INTEGER NOT NULL,
        \\    FOREIGN KEY (workspace_item_id) REFERENCES workspace_items(id) ON DELETE CASCADE
        \\)
    , &.{});
    try db.exec(alloc,
        \\CREATE TABLE kanban (
        \\    workspace_item_task_id TEXT PRIMARY KEY,
        \\    kanban_column_id TEXT NOT NULL,
        \\    kanban_position INTEGER NOT NULL DEFAULT 0,
        \\    FOREIGN KEY (workspace_item_task_id) REFERENCES workspace_item_tasks(id) ON DELETE CASCADE,
        \\    CONSTRAINT kanban_kanban_column_id_fkey
        \\        FOREIGN KEY (kanban_column_id) REFERENCES kanban_columns(id) ON DELETE SET NULL
        \\)
    , &.{});
    return .{ .db = db, .threaded = threaded };
}

fn constraintDeleteAction(db: *Backend, alloc: std.mem.Allocator) ![]const u8 {
    var row = try db.queryRow(
        alloc,
        "SELECT confdeltype FROM pg_constraint WHERE conrelid = 'kanban'::regclass AND contype = 'f' " ++
            "AND pg_get_constraintdef(oid) LIKE '%kanban_column_id%'",
        &.{},
    );
    defer row.deinit(alloc);
    return try alloc.dupe(u8, row.values[0]);
}

test "Migration149 repairs a postgres placement constraint that nulls a NOT NULL column" {
    if (!dialect.is_postgres) return;
    const alloc = testing.allocator;
    var ctx = try openPgLegacyDb(alloc);
    defer ctx.threaded.deinit();
    defer ctx.db.deinit();

    try ctx.db.exec(alloc, "INSERT INTO workspace_items (id, workspace_id, item_type) VALUES ('item_1', 'ws_1', 'kanban')", &.{});
    try ctx.db.exec(alloc, "INSERT INTO kanban_columns (id, workspace_item_id, name, position) VALUES ('col_1', 'item_1', 'todo', 0)", &.{});
    try ctx.db.exec(alloc, "INSERT INTO workspace_item_tasks (id, name, workspace_item_id) VALUES ('task_1', 'a task', 'item_1')", &.{});
    try ctx.db.exec(alloc, "INSERT INTO kanban (workspace_item_task_id, kanban_column_id, kanban_position) VALUES ('task_1', 'col_1', 0)", &.{});

    try Migration149RepairKanbanColumnCascade.up(&ctx.db, alloc);

    const action = try constraintDeleteAction(&ctx.db, alloc);
    defer alloc.free(action);
    try testing.expectEqualStrings("c", action);

    try testing.expectEqual(@as(usize, 1), try placementColumnCount(&ctx.db, alloc));

    try ctx.db.exec(alloc, "DELETE FROM workspace_items WHERE id = 'item_1'", &.{});

    try testing.expectEqual(@as(usize, 0), try placementColumnCount(&ctx.db, alloc));
}
