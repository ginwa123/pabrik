const std = @import("std");
const common = @import("common.zig");

const Backend = common.Backend;
const addColumnIfMissing = common.addColumnIfMissing;
const dropColumnIfExists = common.dropColumnIfExists;
const renameColumnIfExists = common.renameColumnIfExists;
const helpers = @import("helpers");

/// Migration 104 - Add `sessions.is_pinned` + `sessions.pinned_position`.
/// Powers the PINNED section above RECENT in the sidebar.
pub const Migration104AddSessionPinned = struct {
    pub const version: u32 = 104;
    pub const name = "add_session_pinned";

    pub fn up(db: *Backend, allocator: std.mem.Allocator) anyerror!void {
        try addColumnIfMissing(
            .{ .db = db },
            allocator,
            "sessions",
            "is_pinned",
            "is_pinned INTEGER NOT NULL DEFAULT 0",
        );
        try addColumnIfMissing(
            .{ .db = db },
            allocator,
            "sessions",
            "pinned_position",
            "pinned_position INTEGER NOT NULL DEFAULT 0",
        );
        try db.exec(allocator,
            "CREATE INDEX IF NOT EXISTS idx_sessions_pinned " ++
            "ON sessions(is_pinned DESC, pinned_position DESC)",
            &[_][]const u8{});
    }
};
