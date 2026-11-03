const std = @import("std");
const test_db = @import("../testing/test_db.zig");
const common = @import("common.zig");

const Backend = common.Backend;
const dialect = common.dialect;
const addColumnIfMissing = common.addColumnIfMissing;

pub const Migration137ExpandKanbanOntoTasks = struct {
    pub const version: u32 = 137;
    pub const name = "expand_kanban_onto_workspace_item_tasks";

    pub const column_column = "kanban_column_id";
    pub const position_column = "kanban_position";

    pub fn up(db: *Backend, allocator: std.mem.Allocator) anyerror!void {
        try addColumnIfMissing(
            .{ .db = db },
            allocator,
            "workspace_item_tasks",
            column_column,
            "kanban_column_id TEXT",
        );
        try addColumnIfMissing(
            .{ .db = db },
            allocator,
            "workspace_item_tasks",
            position_column,
            "kanban_position INTEGER NOT NULL DEFAULT 0",
        );

        try db.exec(allocator,
            \\UPDATE workspace_item_tasks SET
            \\  kanban_column_id = COALESCE(kanban_column_id, (SELECT k.kanban_column_id FROM kanban k WHERE k.workspace_item_task_id = workspace_item_tasks.id)),
            \\  kanban_position = (SELECT k.kanban_position FROM kanban k WHERE k.workspace_item_task_id = workspace_item_tasks.id)
            \\WHERE kanban_column_id IS NULL
            \\  AND id IN (SELECT workspace_item_task_id FROM kanban)
        , &[_][]const u8{});

        try db.exec(allocator,
            \\CREATE INDEX IF NOT EXISTS idx_workspace_item_tasks_kanban
            \\ON workspace_item_tasks(kanban_column_id, kanban_position)
        , &[_][]const u8{});
    }
};

const testing = std.testing;

fn openDb(alloc: std.mem.Allocator) !struct { db: Backend, threaded: std.Io.Threaded } {
    var threaded = std.Io.Threaded.init(alloc, .{});
    errdefer threaded.deinit();
    var db: Backend = .{};
    errdefer db.deinit();
    try test_db.openMemory(&db, threaded.io());
    try db.exec(alloc,
        \\CREATE TABLE workspace_item_tasks (
        \\    id TEXT PRIMARY KEY,
        \\    workspace_item_id TEXT NOT NULL,
        \\    name TEXT NOT NULL DEFAULT ''
        \\)
    , &[_][]const u8{});
    try db.exec(alloc,
        \\CREATE TABLE kanban (
        \\    workspace_item_task_id TEXT PRIMARY KEY,
        \\    kanban_column_id TEXT NOT NULL,
        \\    kanban_position INTEGER NOT NULL DEFAULT 0
        \\)
    , &[_][]const u8{});
    return .{ .db = db, .threaded = threaded };
}

fn valueOf(alloc: std.mem.Allocator, db: *Backend, id: []const u8, column: []const u8) ![]u8 {
    var buf: [160]u8 = undefined;
    const sql = std.fmt.bufPrint(&buf, "SELECT COALESCE(CAST({s} AS TEXT), '') FROM workspace_item_tasks WHERE id = ?", .{column}) catch
        return error.BufferTooSmall;
    var row = try db.queryRow(alloc, sql, &[_][]const u8{id});
    defer row.deinit(alloc);
    return try alloc.dupe(u8, row.values[0]);
}

test "Migration137 copies every board placement onto its task" {
    const alloc = testing.allocator;
    var ctx = try openDb(alloc);
    defer ctx.db.deinit();
    defer ctx.threaded.deinit();
    const db = &ctx.db;

    try db.exec(alloc,
        \\INSERT INTO workspace_item_tasks (id, workspace_item_id) VALUES ('t1', 'i1'), ('t2', 'i1'), ('t3', 'i1')
    , &[_][]const u8{});
    try db.exec(alloc,
        \\INSERT INTO kanban (workspace_item_task_id, kanban_column_id, kanban_position) VALUES
        \\  ('t1', 'col_a', 0), ('t2', 'col_a', 1), ('t3', 'col_b', 0)
    , &[_][]const u8{});

    try Migration137ExpandKanbanOntoTasks.up(db, alloc);

    const t1_col = try valueOf(alloc, db, "t1", "kanban_column_id");
    defer alloc.free(t1_col);
    try testing.expectEqualStrings("col_a", t1_col);

    const t2_pos = try valueOf(alloc, db, "t2", "kanban_position");
    defer alloc.free(t2_pos);
    try testing.expectEqualStrings("1", t2_pos);

    const t3_col = try valueOf(alloc, db, "t3", "kanban_column_id");
    defer alloc.free(t3_col);
    try testing.expectEqualStrings("col_b", t3_col);
}

test "Migration137 leaves a task that is on no board without a column" {
    const alloc = testing.allocator;
    var ctx = try openDb(alloc);
    defer ctx.db.deinit();
    defer ctx.threaded.deinit();
    const db = &ctx.db;

    try db.exec(alloc, "INSERT INTO workspace_item_tasks (id, workspace_item_id) VALUES ('loose', 'i1')", &[_][]const u8{});

    try Migration137ExpandKanbanOntoTasks.up(db, alloc);

    const col = try valueOf(alloc, db, "loose", "kanban_column_id");
    defer alloc.free(col);
    try testing.expectEqualStrings("", col);
}

test "Migration137 never overwrites a placement the task already carries" {
    const alloc = testing.allocator;
    var ctx = try openDb(alloc);
    defer ctx.db.deinit();
    defer ctx.threaded.deinit();
    const db = &ctx.db;

    try db.exec(alloc, "INSERT INTO workspace_item_tasks (id, workspace_item_id) VALUES ('t1', 'i1')", &[_][]const u8{});
    try db.exec(alloc, "INSERT INTO kanban (workspace_item_task_id, kanban_column_id, kanban_position) VALUES ('t1', 'legacy_col', 0)", &[_][]const u8{});

    try Migration137ExpandKanbanOntoTasks.up(db, alloc);
    try db.exec(alloc, "UPDATE workspace_item_tasks SET kanban_column_id = 'newer_col' WHERE id = 't1'", &[_][]const u8{});
    try Migration137ExpandKanbanOntoTasks.up(db, alloc);

    const col = try valueOf(alloc, db, "t1", "kanban_column_id");
    defer alloc.free(col);
    try testing.expectEqualStrings("newer_col", col);
}

test "Migration137 replaying is a no-op" {
    const alloc = testing.allocator;
    var ctx = try openDb(alloc);
    defer ctx.db.deinit();
    defer ctx.threaded.deinit();
    const db = &ctx.db;

    try Migration137ExpandKanbanOntoTasks.up(db, alloc);
    try Migration137ExpandKanbanOntoTasks.up(db, alloc);

    var row = try db.queryRow(alloc, "SELECT COUNT(*) FROM " ++
        comptime dialect.tableColumns("workspace_item_tasks") ++
        " WHERE name IN ('kanban_column_id', 'kanban_position')", &[_][]const u8{});
    defer row.deinit(alloc);
    try testing.expectEqualStrings("2", row.values[0]);
}

test "Migration137 is registered in allMigrations" {
    for (@import("migration.zig").allMigrations) |m| {
        if (m.version == Migration137ExpandKanbanOntoTasks.version) return;
    }
    return error.Migration137NotRegistered;
}
