const std = @import("std");
const common = @import("common.zig");

const SqliteBackend = common.SqliteBackend;
const addColumnIfMissing = common.addColumnIfMissing;
const dropColumnIfExists = common.dropColumnIfExists;
const renameColumnIfExists = common.renameColumnIfExists;
const helpers = @import("helpers");

pub const Migration052DropSessionIdFromWorkspaceItemTasks = struct {
    pub const version: u32 = 52;
    pub const name = "drop_session_id_from_workspace_item_tasks";

    pub fn up(db: *SqliteBackend, allocator: std.mem.Allocator) anyerror!void {
        // Drop the redundant `session_id` column on `workspace_item_tasks`.
        try dropColumnIfExists(.{ .db = db }, allocator, "workspace_item_tasks", "session_id");
        // The session_id index (created in Migration 034) is now
        // unused and would just slow writes down. Drop it.
        try db.exec(allocator,
            "DROP INDEX IF EXISTS idx_workspace_item_tasks_session_id",
            &[_][]const u8{},
        );
        // ANALYZE so the query planner drops the dropped index from
        // its stats. Mirrors the ANALYZE-after-DDL pattern used by
        // Migrations 041/042/043/048/049/050/051.
        try db.exec(allocator, "ANALYZE", &[_][]const u8{});
    }
};
