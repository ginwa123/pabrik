const std = @import("std");
const common = @import("common.zig");

const Backend = common.Backend;
const addColumnIfMissing = common.addColumnIfMissing;
const dropColumnIfExists = common.dropColumnIfExists;
const renameColumnIfExists = common.renameColumnIfExists;
const helpers = @import("helpers");

pub const Migration026DropSessionIdFromWorkspaces = struct {
    pub const version: u32 = 26;
    pub const name = "drop_session_id_from_workspaces";

    pub fn up(db: *Backend, allocator: std.mem.Allocator) anyerror!void {
        // SQLite doesn't support DROP COLUMN directly, recreate table
        // Step 1: Create new table without session_id
        try db.exec(allocator, "CREATE TABLE IF NOT EXISTS workspaces_new (id TEXT PRIMARY KEY)", &[_][]const u8{});
        // Step 2: Copy data from old table
        try db.exec(allocator, "INSERT INTO workspaces_new SELECT id FROM workspaces", &[_][]const u8{});
        // Step 3: Drop old table
        try db.exec(allocator, "DROP TABLE workspaces", &[_][]const u8{});
        // Step 4: Rename new table
        try db.exec(allocator, "ALTER TABLE workspaces_new RENAME TO workspaces", &[_][]const u8{});
    }
};
