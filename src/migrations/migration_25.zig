const std = @import("std");
const common = @import("common.zig");

const Backend = common.Backend;
const addColumnIfMissing = common.addColumnIfMissing;
const dropColumnIfExists = common.dropColumnIfExists;
const renameColumnIfExists = common.renameColumnIfExists;
const helpers = @import("helpers");

pub const Migration025AddWorkspaceIdToSessions = struct {
    pub const version: u32 = 25;
    pub const name = "add_workspace_id_to_sessions";

    pub fn up(db: *Backend, allocator: std.mem.Allocator) anyerror!void {
        // Add workspace_id column to sessions table
        try db.exec(allocator, "ALTER TABLE sessions ADD COLUMN workspace_id TEXT", &[_][]const u8{});
        try db.exec(allocator, "CREATE INDEX IF NOT EXISTS idx_sessions_workspace ON sessions(workspace_id)", &[_][]const u8{});
    }
};
