const std = @import("std");
const common = @import("common.zig");

const Backend = common.Backend;
const addColumnIfMissing = common.addColumnIfMissing;
const dropColumnIfExists = common.dropColumnIfExists;
const renameColumnIfExists = common.renameColumnIfExists;
const helpers = @import("helpers");

/// Migration 062 — Add a `description` column to `workspace_item_tasks` so
/// every task (chat / routine / kanban) can carry a free-form text note
/// alongside its display name.
pub const Migration062AddTaskDescription = struct {
    pub const version: u32 = 62;
    pub const name = "add_task_description";

    pub fn up(db: *Backend, allocator: std.mem.Allocator) anyerror!void {
        try addColumnIfMissing(
            .{ .db = db },
            allocator,
            "workspace_item_tasks",
            "description",
            "description TEXT NOT NULL DEFAULT ''",
        );
    }
};
