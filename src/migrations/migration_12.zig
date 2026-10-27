const std = @import("std");
const common = @import("common.zig");

const Backend = common.Backend;
const addColumnIfMissing = common.addColumnIfMissing;
const dropColumnIfExists = common.dropColumnIfExists;
const renameColumnIfExists = common.renameColumnIfExists;
const helpers = @import("helpers");

pub const Migration012AddParentTracking = struct {
    pub const version: u32 = 12;
    pub const name = "add_parent_tracking";

    pub fn up(db: *Backend, allocator: std.mem.Allocator) anyerror!void {
        try db.exec(allocator, "ALTER TABLE llm_history ADD COLUMN parent_session_id TEXT", &[_][]const u8{});
        try db.exec(allocator, "ALTER TABLE llm_history ADD COLUMN parent_id TEXT", &[_][]const u8{});
        try db.exec(allocator, "CREATE INDEX IF NOT EXISTS idx_llm_history_parent_session ON llm_history(parent_session_id)", &[_][]const u8{});
    }
};
