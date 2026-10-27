const std = @import("std");
const common = @import("common.zig");

const Backend = common.Backend;
const addColumnIfMissing = common.addColumnIfMissing;
const dropColumnIfExists = common.dropColumnIfExists;
const renameColumnIfExists = common.renameColumnIfExists;
const helpers = @import("helpers");

/// Migration 084 — drop per-task routines, replace with workspace-level
/// routines (`workspace_routines`, 1:1 with routine `workspace_items`). ##
/// Why this migration exists Per-task routines (`routines` table from
pub const Migration084ReplaceRoutinesWithWorkspaceRoutines = struct {
    pub const version: u32 = 84;
    pub const name = "replace_routines_with_workspace_routines";

    pub fn up(db: *Backend, allocator: std.mem.Allocator) anyerror!void {
        // 1. Normalize leftovers so no task claims a deleted mode.
        try db.exec(allocator,
            "UPDATE workspace_item_tasks SET task_type = 'standard' WHERE task_type = 'routine'",
            &[_][]const u8{},
        );

        // 2. Drop the old per-task table + its indexes.
        try db.exec(allocator, "DROP TABLE IF EXISTS routines", &[_][]const u8{});
        try db.exec(allocator, "DROP INDEX IF EXISTS idx_routines_enabled_next_run", &[_][]const u8{});
        try db.exec(allocator, "DROP INDEX IF EXISTS idx_routines_last_status", &[_][]const u8{});

        // 3. Create the workspace-level replacement.
        try db.exec(allocator,
            \\CREATE TABLE IF NOT EXISTS workspace_routines (
            \\    id TEXT PRIMARY KEY,
            \\    workspace_item_id TEXT NOT NULL UNIQUE,
            \\    description TEXT NOT NULL DEFAULT '',
            \\    instruction TEXT NOT NULL DEFAULT '',
            \\    schedule TEXT NOT NULL DEFAULT '',
            \\    enabled INTEGER NOT NULL DEFAULT 1,
            \\    last_run_at TIMESTAMP,
            \\    next_run_at TIMESTAMP,
            \\    last_status TEXT NOT NULL DEFAULT 'idle',
            \\    last_error TEXT NOT NULL DEFAULT '',
            \\    created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
            \\    updated_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
            \\    FOREIGN KEY (workspace_item_id) REFERENCES workspace_items(id) ON DELETE CASCADE
            \\)
        , &[_][]const u8{});

        try db.exec(allocator,
            "CREATE INDEX IF NOT EXISTS idx_workspace_routines_workspace_item_id ON workspace_routines(workspace_item_id)",
            &[_][]const u8{},
        );
        // Hot-path index for the Scheduler's due-scan
        // (SELECT id FROM workspace_routines WHERE enabled=1 AND next_run_at<=now).
        try db.exec(allocator,
            "CREATE INDEX IF NOT EXISTS idx_workspace_routines_enabled_next_run ON workspace_routines(enabled, next_run_at)",
            &[_][]const u8{},
        );
        try db.exec(allocator, "ANALYZE", &[_][]const u8{});
    }
};
