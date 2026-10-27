const std = @import("std");
const common = @import("common.zig");

const Backend = common.Backend;
const addColumnIfMissing = common.addColumnIfMissing;
const dropColumnIfExists = common.dropColumnIfExists;
const renameColumnIfExists = common.renameColumnIfExists;
const helpers = @import("helpers");

pub const Migration050AddPinnedToWorkspaceItemTasks = struct {
    pub const version: u32 = 50;
    pub const name = "add_pinned_to_workspace_item_tasks";

    pub fn up(db: *Backend, allocator: std.mem.Allocator) anyerror!void {
        try db.exec(allocator,
            "ALTER TABLE workspace_item_tasks ADD COLUMN is_pinned INTEGER NOT NULL DEFAULT 0",
            &[_][]const u8{});
        try db.exec(allocator,
            "ALTER TABLE workspace_item_tasks ADD COLUMN pinned_position INTEGER NOT NULL DEFAULT 0",
            &[_][]const u8{});
        try db.exec(allocator,
            "CREATE INDEX IF NOT EXISTS idx_workspace_item_tasks_pinned " ++
            "ON workspace_item_tasks(workspace_item_id, is_pinned DESC, pinned_position DESC)",
            &[_][]const u8{});
        try db.exec(allocator, "ANALYZE", &[_][]const u8{});
    }
};
