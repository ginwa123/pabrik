const std = @import("std");
const common = @import("common.zig");

const SqliteBackend = common.SqliteBackend;
const addColumnIfMissing = common.addColumnIfMissing;
const dropColumnIfExists = common.dropColumnIfExists;
const renameColumnIfExists = common.renameColumnIfExists;
const helpers = @import("helpers");

/// Migration 069 — Add `workspace_item_tasks.image_urls` column
/// (kanban-image-urls-column plan, 2026-08-06). ## Why this migration exists
/// Until now, the only way to attach an image to a kanban task was the
pub const Migration069AddTaskImageUrls = struct {
    pub const version: u32 = 69;
    pub const name = "add_task_image_urls";

    pub fn up(db: *SqliteBackend, allocator: std.mem.Allocator) anyerror!void {
        // `image_urls TEXT NOT NULL DEFAULT ''` — the empty string is the
        // canonical "no images" sentinel (matches `description` / `tags`
        // patterns from Migrations 062 / 067).
        try addColumnIfMissing(
            .{ .db = db },
            allocator,
            "workspace_item_tasks",
            "image_urls",
            "image_urls TEXT NOT NULL DEFAULT ''",
        );
    }
};
