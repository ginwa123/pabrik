const std = @import("std");
const common = @import("common.zig");

const Backend = common.Backend;
const addColumnIfMissing = common.addColumnIfMissing;
const dropColumnIfExists = common.dropColumnIfExists;
const renameColumnIfExists = common.renameColumnIfExists;
const helpers = @import("helpers");

pub const Migration100AddWorkspaceMembers = struct {
    pub const version: u32 = 100;
    pub const name = "add_workspace_members";

    pub fn up(db: *Backend, allocator: std.mem.Allocator) anyerror!void {
        // One tx: the table, its index and the backfill must land together.
        // Same shape as Migration 077.
        var tx = try db.begin();
        defer tx.commitOrRollback() catch {};
        errdefer tx.rollback() catch {};

        try tx.exec(allocator,
            \\CREATE TABLE IF NOT EXISTS workspace_members (
            \\    workspace_id TEXT NOT NULL,
            \\    user_id TEXT NOT NULL,
            \\    role TEXT NOT NULL DEFAULT 'viewer' CHECK (role IN ('owner', 'admin', 'editor', 'viewer')),
            \\    joined_at DATETIME DEFAULT CURRENT_TIMESTAMP,
            \\    invited_by TEXT,
            \\    PRIMARY KEY (workspace_id, user_id)
            \\)
        , &[_][]const u8{});

        // The PK already covers workspace_id -> members (the direction the
        // visibility EXISTS subquery walks). This covers the other direction:
        // "which workspaces is this user in".
        try tx.exec(allocator, "CREATE INDEX IF NOT EXISTS idx_workspace_members_user ON workspace_members(user_id, workspace_id)", &[_][]const u8{});

        // Backfill.
        try tx.exec(allocator,
            \\INSERT OR IGNORE INTO workspace_members (workspace_id, user_id, role, joined_at)
            \\SELECT id, COALESCE(NULLIF(user_id, ''), 'user_system'), 'owner', datetime('now')
            \\FROM workspaces
        , &[_][]const u8{});

        try tx.commit();

        // Refresh planner stats so the new index is picked up on pre-existing
        // databases (mirrors Migrations 041-052 / 070 / 072 / 077).
        try db.exec(allocator, "ANALYZE", &[_][]const u8{});
    }
};
