const std = @import("std");
const common = @import("common.zig");

const Backend = common.Backend;
const addColumnIfMissing = common.addColumnIfMissing;
const dropColumnIfExists = common.dropColumnIfExists;
const renameColumnIfExists = common.renameColumnIfExists;
const helpers = @import("helpers");

/// Migration 069 — Add `workspace_item_tasks.image_urls` column (kanban-image-urls-column plan, 2026-08-06).
pub const Migration069AddTaskImageUrls = struct {
    pub const version: u32 = 69;
    pub const name = "add_task_image_urls";

    pub fn up(db: *Backend, allocator: std.mem.Allocator) anyerror!void {
        // `image_urls TEXT NOT NULL DEFAULT ''` — the empty string is the canonical "no images" sentinel (matches `description` / `tags` patterns from Migrations 062 / …
        try addColumnIfMissing(
            .{ .db = db },
            allocator,
            "workspace_item_tasks",
            "image_urls",
            "image_urls TEXT NOT NULL DEFAULT ''",
        );
    }
};
