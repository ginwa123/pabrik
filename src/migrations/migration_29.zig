const std = @import("std");
const common = @import("common.zig");

const Backend = common.Backend;
const addColumnIfMissing = common.addColumnIfMissing;
const dropColumnIfExists = common.dropColumnIfExists;
const renameColumnIfExists = common.renameColumnIfExists;
const helpers = @import("helpers");

pub const Migration029AddTimestampsToSessions = struct {
    pub const version: u32 = 29;
    pub const name = "add_timestamps_to_sessions";

    pub fn up(db: *Backend, allocator: std.mem.Allocator) anyerror!void {
        // Use NULL default — CURRENT_TIMESTAMP is non-constant in older SQLite
        try db.exec(allocator, "ALTER TABLE sessions ADD COLUMN created_at DATETIME DEFAULT NULL", &[_][]const u8{});
        try db.exec(allocator, "ALTER TABLE sessions ADD COLUMN updated_at DATETIME DEFAULT NULL", &[_][]const u8{});

        // Backfill existing rows with the current time
        try db.exec(allocator, "UPDATE sessions SET created_at = CURRENT_TIMESTAMP, updated_at = CURRENT_TIMESTAMP WHERE created_at IS NULL", &[_][]const u8{});
    }
};
