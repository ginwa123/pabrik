const std = @import("std");
const common = @import("common.zig");

const Backend = common.Backend;
const dialect = common.dialect;
const addColumnIfMissing = common.addColumnIfMissing;

/// Migration 111: the `kanban_task_dependencies` edge table, plus `kanban_columns.is_done` (a card that lands there has finished), with a name-based backfill so …
pub const Migration111AddKanbanTaskDependencies = struct {
    pub const version: u32 = 111;
    pub const name = "add_kanban_task_dependencies";

    /// Column names that mean "this column finishes a task" (English + Indonesian — the two languages this product's boards use).
    const done_column_names =
        \\UPDATE kanban_columns SET is_done = 1
        \\WHERE lower(trim(name)) IN (
        \\    'done', 'complete', 'completed', 'finish', 'finished', 'closed',
        \\    'merged', 'shipped', 'released', 'deployed', 'archived', 'archive',
        \\    'drop', 'dropped', 'cancelled', 'canceled',
        \\    'selesai', 'beres', 'batal', 'arsip'
        \\)
    ;

    /// Boards where NO column matched: without this, every dependency there would block forever.
    const done_last_column =
        \\UPDATE kanban_columns SET is_done = 1
        \\WHERE position = (
        \\        SELECT MAX(kc2.position) FROM kanban_columns kc2
        \\        WHERE kc2.workspace_item_id = kanban_columns.workspace_item_id)
        \\  AND workspace_item_id IN (
        \\        SELECT kc3.workspace_item_id FROM kanban_columns kc3
        \\        GROUP BY kc3.workspace_item_id HAVING SUM(kc3.is_done) = 0)
    ;

    pub fn up(db: *Backend, allocator: std.mem.Allocator) anyerror!void {
        try db.exec(allocator,
            \\CREATE TABLE IF NOT EXISTS kanban_task_dependencies (
            \\    task_id TEXT NOT NULL,
            \\    depends_on_task_id TEXT NOT NULL,
            \\    created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
            \\    PRIMARY KEY (task_id, depends_on_task_id)
            \\)
        , &[_][]const u8{});

        // Both directions are read: "what blocks this card" by `task_id`, and "what is waiting on this card" by `depends_on_task_id` (the move gate asks the second …
        try db.exec(allocator,
            \\CREATE INDEX IF NOT EXISTS idx_kanban_task_dependencies_task
            \\ON kanban_task_dependencies(task_id)
        , &[_][]const u8{});
        try db.exec(allocator,
            \\CREATE INDEX IF NOT EXISTS idx_kanban_task_dependencies_dependency
            \\ON kanban_task_dependencies(depends_on_task_id)
        , &[_][]const u8{});

        const had_column = try columnExists(db, allocator, "kanban_columns", "is_done");
        try addColumnIfMissing(
            .{ .db = db },
            allocator,
            "kanban_columns",
            "is_done",
            "is_done INTEGER NOT NULL DEFAULT 0",
        );

        // Only a FIRST run backfills.
        if (had_column) return;

        try db.exec(allocator, done_column_names, &[_][]const u8{});
        try db.exec(allocator, done_last_column, &[_][]const u8{});
    }
};

/// True when the column is already there.
fn columnExists(
    db: *Backend,
    allocator: std.mem.Allocator,
    table: []const u8,
    column: []const u8,
) !bool {
    return dialect.columnExists(.{ .db = db }, allocator, table, column);
}
