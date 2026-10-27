const std = @import("std");
const common = @import("common.zig");

const Backend = common.Backend;
const addColumnIfMissing = common.addColumnIfMissing;
const dropColumnIfExists = common.dropColumnIfExists;
const renameColumnIfExists = common.renameColumnIfExists;
const helpers = @import("helpers");

pub const Migration034CreateWorkspaceItemTasks = struct {
    pub const version: u32 = 34;
    pub const name = "create_workspace_item_tasks";

    pub fn up(db: *Backend, allocator: std.mem.Allocator) anyerror!void {
        // Note: this migration historically included a `session_id` column.
        try db.exec(allocator,
            \\CREATE TABLE IF NOT EXISTS workspace_item_tasks (
            \\    id TEXT PRIMARY KEY,
            \\    name TEXT NOT NULL,
            \\    workspace_item_id TEXT NOT NULL,
            \\    created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
            \\    updated_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP
            \\)
        , &[_][]const u8{});
        try db.exec(allocator, "CREATE INDEX IF NOT EXISTS idx_workspace_item_tasks_item ON workspace_item_tasks(workspace_item_id)", &[_][]const u8{});
    }
};
