const std = @import("std");
const common = @import("common.zig");

const Backend = common.Backend;

/// Migration 107 — tag each background process with its KIND.
/// `session_background_process` (migration 014) recorded one thing: a
/// detached command, its log, and whether it was still alive.
pub const Migration107AddBackgroundProcessKind = struct {
    pub const version: u32 = 107;
    pub const name = "add_background_process_kind";

    pub fn up(db: *Backend, allocator: std.mem.Allocator) anyerror!void {
        try db.exec(allocator,
            \\ALTER TABLE session_background_process
            \\    ADD COLUMN kind TEXT NOT NULL DEFAULT 'job'
        , &[_][]const u8{});
    }
};
