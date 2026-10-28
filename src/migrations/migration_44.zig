const std = @import("std");
const common = @import("common.zig");

const Backend = common.Backend;
const addColumnIfMissing = common.addColumnIfMissing;
const dropColumnIfExists = common.dropColumnIfExists;
const renameColumnIfExists = common.renameColumnIfExists;
const helpers = @import("helpers");
const dialect = common.dialect;

pub const Migration044AddRoutines = struct {
    pub const version: u32 = 44;
    pub const name = "add_routines";

    pub fn up(db: *Backend, allocator: std.mem.Allocator) anyerror!void {
        // Adds the `task_type` column to the existing workspace_item_tasks
        // table (defaulting to 'standard' for backwards compatibility — every
        // pre-existing task row is a standard chat) and the new `routines`
        try db.exec(allocator,
            "ALTER TABLE workspace_item_tasks ADD COLUMN task_type TEXT NOT NULL DEFAULT 'standard'",
            &[_][]const u8{},
        );

        try db.exec(allocator,
            \\CREATE TABLE IF NOT EXISTS routines (
            \\    id TEXT PRIMARY KEY,
            \\    task_id TEXT NOT NULL UNIQUE,
            \\    schedule TEXT NOT NULL,
            \\    initial_prompt TEXT NOT NULL,
            \\    enabled INTEGER NOT NULL DEFAULT 1,
            \\    last_run_at TIMESTAMP,
            \\    next_run_at TIMESTAMP NOT NULL,
            \\    last_status TEXT,
            \\    last_error TEXT,
            \\    created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
            \\    updated_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
            ++ comptime dialect.foreignKey("FOREIGN KEY (task_id) REFERENCES workspace_item_tasks(id) ON DELETE CASCADE") ++
            \\)
        , &[_][]const u8{});

        // Polling index for the Scheduler's hot read path
        // (SELECT id FROM routines WHERE enabled=1 AND next_run_at<=now).
        try db.exec(allocator,
            "CREATE INDEX IF NOT EXISTS idx_routines_enabled_next_run ON routines(enabled, next_run_at)",
            &[_][]const u8{},
        );
        // Refresh query-planner stats so the new index is picked on
        // pre-existing databases (mirrors the ANALYZE-after-CREATE-INDEX
        // pattern used by Migrations 041/042/043).
        try db.exec(allocator, "ANALYZE", &[_][]const u8{});
    }
};
