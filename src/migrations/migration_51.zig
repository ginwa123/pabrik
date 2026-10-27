const std = @import("std");
const common = @import("common.zig");

const Backend = common.Backend;
const addColumnIfMissing = common.addColumnIfMissing;
const dropColumnIfExists = common.dropColumnIfExists;
const renameColumnIfExists = common.renameColumnIfExists;
const helpers = @import("helpers");

pub const Migration051AddKanban = struct {
    pub const version: u32 = 51;
    pub const name = "add_kanban";

    pub fn up(db: *Backend, allocator: std.mem.Allocator) anyerror!void {
        // Workspace Item Kanban feature — Chunk 1 (Migration 051). Adds the
        // kanban_columns table and the two column-reference columns on
        // workspace_item_tasks.
        try db.exec(allocator,
            \\CREATE TABLE IF NOT EXISTS kanban_columns (
            \\    id TEXT PRIMARY KEY,
            \\    workspace_item_id TEXT NOT NULL,
            \\    name TEXT NOT NULL,
            \\    position INTEGER NOT NULL,
            \\    created_at DATETIME DEFAULT CURRENT_TIMESTAMP,
            \\    FOREIGN KEY (workspace_item_id) REFERENCES workspace_items(id) ON DELETE CASCADE
            \\)
        , &[_][]const u8{});
        try db.exec(allocator,
            "CREATE INDEX IF NOT EXISTS idx_kanban_columns_item_position " ++
            "ON kanban_columns(workspace_item_id, position)",
            &[_][]const u8{},
        );
        // Nullable: NULL for tasks in non-kanban items
        // (folder / chat / memory) — they have no flow.
        try db.exec(allocator,
            "ALTER TABLE workspace_item_tasks ADD COLUMN kanban_column_id TEXT",
            &[_][]const u8{},
        );
        // Per-column ordering (independent of the global
        // workspace_item_tasks.position which the folder list view's
        // drag-and-drop uses).
        try db.exec(allocator,
            "ALTER TABLE workspace_item_tasks ADD COLUMN kanban_position INTEGER NOT NULL DEFAULT 0",
            &[_][]const u8{},
        );
        try db.exec(allocator,
            "CREATE INDEX IF NOT EXISTS idx_tasks_column_position " ++
            "ON workspace_item_tasks(kanban_column_id, kanban_position)",
            &[_][]const u8{},
        );
        // ANALYZE so the query planner sees the new indexes on
        // pre-existing databases (mirrors the ANALYZE-after-CREATE-INDEX
        // pattern used by Migrations 041/042/043/048/049/050).
        try db.exec(allocator, "ANALYZE", &[_][]const u8{});
    }
};
