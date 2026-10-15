const std = @import("std");
const common = @import("common.zig");

const SqliteBackend = common.SqliteBackend;
const addColumnIfMissing = common.addColumnIfMissing;
const dropColumnIfExists = common.dropColumnIfExists;
const renameColumnIfExists = common.renameColumnIfExists;
const helpers = @import("helpers");

/// Migration 090 — `workspace_item_tasks.video_urls` +
/// `llm_history.video_url` + `session_queue_messages.video_url` for full
/// video upload to LLM.
pub const Migration090AddVideoUrls = struct {
    pub const version: u32 = 90;
    pub const name = "add_video_urls";

    pub fn up(db: *SqliteBackend, allocator: std.mem.Allocator) anyerror!void {
        try addColumnIfMissing(
            .{ .db = db },
            allocator,
            "workspace_item_tasks",
            "video_urls",
            "video_urls TEXT NOT NULL DEFAULT ''",
        );
        try addColumnIfMissing(
            .{ .db = db },
            allocator,
            "llm_history",
            "video_url",
            "video_url TEXT",
        );
        try addColumnIfMissing(
            .{ .db = db },
            allocator,
            "session_queue_messages",
            "video_url",
            "video_url TEXT",
        );
    }
};
