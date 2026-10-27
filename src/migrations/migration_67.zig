const std = @import("std");
const common = @import("common.zig");

const Backend = common.Backend;
const addColumnIfMissing = common.addColumnIfMissing;
const dropColumnIfExists = common.dropColumnIfExists;
const renameColumnIfExists = common.renameColumnIfExists;
const helpers = @import("helpers");

/// Migration 067 — Add `workspace_item_tasks.tags` column to support the
/// kanban task tags feature (free-form string list). ## Why this migration
/// exists The kanban task tags feature adds user-defined labels per task
pub const Migration067AddTaskTags = struct {
    pub const version: u32 = 67;
    pub const name = "add_task_tags";

    pub fn up(db: *Backend, allocator: std.mem.Allocator) anyerror!void {
        try addColumnIfMissing(
            .{ .db = db },
            allocator,
            "workspace_item_tasks",
            "tags",
            // `addColumnIfMissing` builds `ALTER TABLE {table} ADD COLUMN
            // {definition}`, so the definition must include BOTH the column
            // name AND the type.
            "tags TEXT NOT NULL DEFAULT ''",
        );
    }
};
