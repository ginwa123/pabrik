const std = @import("std");
const common = @import("common.zig");

const Backend = common.Backend;
const addColumnIfMissing = common.addColumnIfMissing;
const dropColumnIfExists = common.dropColumnIfExists;
const renameColumnIfExists = common.renameColumnIfExists;
const helpers = @import("helpers");
const dialect = common.dialect;

/// Migration 072 — Extract `kanban_column_id` + `kanban_position` from
/// `workspace_item_tasks` into a dedicated `kanban` join table.
pub const Migration072ExtractKanbanTable = struct {
    pub const version: u32 = 72;
    pub const name = "extract_kanban_table";

    pub fn up(db: *Backend, allocator: std.mem.Allocator) anyerror!void {
        // Wrap in a tx (db.begin/tx.exec/tx.commit) so the CREATE+INSERT+DROP
        // sequence is atomic.
        var tx = try db.begin();
        defer tx.commitOrRollback() catch {};
        errdefer tx.rollback() catch {};

        // Step 1: CREATE kanban (idempotent via IF NOT EXISTS)
        try tx.exec(allocator,
            \\CREATE TABLE IF NOT EXISTS kanban (
            \\    workspace_item_task_id TEXT PRIMARY KEY,
            \\    kanban_column_id       TEXT NOT NULL,
            \\    kanban_position        INTEGER NOT NULL DEFAULT 0,
            \\    FOREIGN KEY (workspace_item_task_id)
            \\        REFERENCES workspace_item_tasks(id) ON DELETE CASCADE,
            \\    FOREIGN KEY (kanban_column_id)
            \\        REFERENCES kanban_columns(id)       ON DELETE CASCADE
            \\)
        , &[_][]const u8{});

        // Step 2: per-column ordering index
        try tx.exec(allocator,
            "CREATE INDEX IF NOT EXISTS idx_kanban_column_position " ++
            "ON kanban(kanban_column_id, kanban_position)",
            &[_][]const u8{},
        );

        // Step 4: drop the per-column index on workspace_item_tasks BEFORE
        // the INSERT (which would otherwise create a pending read lock on the
        // same table via the kanban FK validation, blocking the DROP).
        try tx.exec(allocator,
            "DROP INDEX IF EXISTS idx_tasks_column_position",
            &[_][]const u8{},
        );

        // Step 3: backfill from existing data.
        if (try dialect.columnExists(
            .{ .tx = &tx },
            allocator,
            "workspace_item_tasks",
            "kanban_column_id",
        )) {
            // Source columns still exist — first run, do the backfill.
            const backfill = try std.fmt.allocPrint(
                allocator,
                \\{s} INTO kanban (workspace_item_task_id, kanban_column_id, kanban_position)
                \\SELECT t.id, t.kanban_column_id, COALESCE(t.kanban_position, 0)
                \\FROM workspace_item_tasks t
                \\WHERE t.kanban_column_id IS NOT NULL
                \\  AND t.kanban_column_id IN (SELECT id FROM kanban_columns){s}
            , .{ dialect.insert_ignore_prefix, dialect.conflict_ignore });
            defer allocator.free(backfill);
            try tx.exec(allocator, backfill, &[_][]const u8{});
        }
        // else: re-run — backfill already happened on the first run.

        // Step 5 + 6: drop the two columns. dropColumnIfExists is the safe
        // pattern (used in Migration 052) — fresh-DB users who walked the
        // canonical schema may not have these columns if we eventually move
        try dropColumnIfExists(.{ .tx = &tx }, allocator, "workspace_item_tasks", "kanban_column_id");
        try dropColumnIfExists(.{ .tx = &tx }, allocator, "workspace_item_tasks", "kanban_position");

        // Commit the transaction. After this, Migration 072 is "done"
        // and the new schema is durable.
        try tx.commit();

        // ANALYZE so the query planner sees the new index (mirrors
        // Migration 051 / 041 / 042 / 043 / 048 / 049 / 050).
        try db.exec(allocator, "ANALYZE", &[_][]const u8{});
    }
};
