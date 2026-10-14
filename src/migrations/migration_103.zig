const std = @import("std");
const common = @import("common.zig");

const SqliteBackend = common.SqliteBackend;
const addColumnIfMissing = common.addColumnIfMissing;
const dropColumnIfExists = common.dropColumnIfExists;
const renameColumnIfExists = common.renameColumnIfExists;
const helpers = @import("helpers");

pub const Migration103CreateWorkspaceSecrets = struct {
    pub const version: u32 = 103;
    pub const name = "create_workspace_secrets";

    pub fn up(db: *SqliteBackend, allocator: std.mem.Allocator) anyerror!void {
        try db.exec(allocator,
            \\CREATE TABLE IF NOT EXISTS workspace_secrets (
            \\    id TEXT PRIMARY KEY,
            \\    workspace_id TEXT NOT NULL,
            \\    name TEXT NOT NULL,
            \\    value TEXT NOT NULL,
            \\    created_at DATETIME DEFAULT CURRENT_TIMESTAMP,
            \\    updated_at DATETIME DEFAULT CURRENT_TIMESTAMP,
            \\    FOREIGN KEY (workspace_id) REFERENCES workspaces(id) ON DELETE CASCADE
            \\)
        , &[_][]const u8{});

        // Only ONE index, on purpose.
        try db.exec(allocator,
            \\CREATE UNIQUE INDEX IF NOT EXISTS uq_workspace_secrets_name
            \\ON workspace_secrets(workspace_id, name)
        , &[_][]const u8{});
    }
};
