const std = @import("std");
const common = @import("common.zig");

const Backend = common.Backend;
const addColumnIfMissing = common.addColumnIfMissing;
const dropColumnIfExists = common.dropColumnIfExists;
const renameColumnIfExists = common.renameColumnIfExists;
const helpers = @import("helpers");

/// Migration 071 — `workspace_item_tasks.cwd` (per-task cwd_session). Adds a
/// `cwd TEXT NOT NULL DEFAULT ''` column so each kanban task can carry its
/// own cwd override.
pub const Migration071AddTaskCwd = struct {
    pub const version: u32 = 71;
    pub const name = "add_task_cwd";

    pub fn up(db: *Backend, allocator: std.mem.Allocator) anyerror!void {
        // `cwd TEXT NOT NULL DEFAULT ''` — the empty string is the canonical
        // "no per-task cwd" sentinel (matches the description / tags /
        // image_urls patterns from Migrations 062 / 067 / 069).
        try addColumnIfMissing(
            .{ .db = db },
            allocator,
            "workspace_item_tasks",
            "cwd",
            "cwd TEXT NOT NULL DEFAULT ''",
        );
    }
};
