const std = @import("std");
const common = @import("common.zig");

const Backend = common.Backend;
const addColumnIfMissing = common.addColumnIfMissing;
const dropColumnIfExists = common.dropColumnIfExists;
const renameColumnIfExists = common.renameColumnIfExists;
const helpers = @import("helpers");

pub const Migration042AddWorkspaceItemTasksUpdatedAtIndex = struct {
    pub const version: u32 = 42;
    pub const name = "add_workspace_item_tasks_updated_at_index";

    pub fn up(db: *Backend, allocator: std.mem.Allocator) anyerror!void {
        // Hot read path for the workspace-item tasks endpoint when
        // sort_by=updated_at (the new default). Mirrors
        // idx_workspace_item_tasks_item_created (Migration 041).
        try db.exec(allocator, "CREATE INDEX IF NOT EXISTS idx_workspace_item_tasks_item_updated ON workspace_item_tasks(workspace_item_id, updated_at DESC)", &[_][]const u8{});

        // ANALYZE so the query planner sees the new index on existing
        // databases (without this, the planner may still pick a full
        // scan on pre-existing data).
        try db.exec(allocator, "ANALYZE", &[_][]const u8{});
    }
};
