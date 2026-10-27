const std = @import("std");
const common = @import("common.zig");

const Backend = common.Backend;
const addColumnIfMissing = common.addColumnIfMissing;
const dropColumnIfExists = common.dropColumnIfExists;
const renameColumnIfExists = common.renameColumnIfExists;
const helpers = @import("helpers");

pub const Migration031AddTimestampsToWorkspaceItems = struct {
    pub const version: u32 = 31;
    pub const name = "add_timestamps_to_workspace_items";

    pub fn up(db: *Backend, allocator: std.mem.Allocator) anyerror!void {
        try db.exec(allocator, "ALTER TABLE workspace_items ADD COLUMN created_at DATETIME DEFAULT NULL", &[_][]const u8{});
        try db.exec(allocator, "ALTER TABLE workspace_items ADD COLUMN updated_at DATETIME DEFAULT NULL", &[_][]const u8{});
        try db.exec(allocator, "UPDATE workspace_items SET created_at = CURRENT_TIMESTAMP, updated_at = CURRENT_TIMESTAMP WHERE created_at IS NULL", &[_][]const u8{});
    }
};
