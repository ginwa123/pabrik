const std = @import("std");
const common = @import("common.zig");

const Backend = common.Backend;
const addColumnIfMissing = common.addColumnIfMissing;
const dropColumnIfExists = common.dropColumnIfExists;
const renameColumnIfExists = common.renameColumnIfExists;
const helpers = @import("helpers");

pub const Migration028CreateWorkspaceItems = struct {
    pub const version: u32 = 28;
    pub const name = "create_workspace_items";

    pub fn up(db: *Backend, allocator: std.mem.Allocator) anyerror!void {
        try db.exec(allocator,
            \\CREATE TABLE IF NOT EXISTS workspace_items (
            \\    id TEXT PRIMARY KEY,
            \\    workspace_id TEXT NOT NULL,
            \\    item_type TEXT NOT NULL
            \\)
        , &[_][]const u8{});
        try db.exec(allocator, "CREATE INDEX IF NOT EXISTS idx_workspace_items_workspace ON workspace_items(workspace_id)", &[_][]const u8{});
    }
};
