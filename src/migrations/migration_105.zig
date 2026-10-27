const std = @import("std");
const common = @import("common.zig");

const Backend = common.Backend;

/// Migration 105 - create `workspace_settings`, the per-workspace config
/// overlay.
pub const Migration105CreateWorkspaceSettings = struct {
    pub const version: u32 = 105;
    pub const name = "create_workspace_settings";

    pub fn up(db: *Backend, allocator: std.mem.Allocator) anyerror!void {
        try db.exec(allocator,
            \\CREATE TABLE IF NOT EXISTS workspace_settings (
            \\    owner TEXT NOT NULL DEFAULT '',
            \\    workspace_id TEXT NOT NULL,
            \\    config_json TEXT,
            \\    created_at DATETIME DEFAULT CURRENT_TIMESTAMP,
            \\    updated_at DATETIME DEFAULT CURRENT_TIMESTAMP,
            \\    PRIMARY KEY (owner, workspace_id),
            \\    FOREIGN KEY (workspace_id) REFERENCES workspaces(id) ON DELETE CASCADE
            \\)
        , &[_][]const u8{});
    }
};
