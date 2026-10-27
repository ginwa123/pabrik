const std = @import("std");
const common = @import("common.zig");

const Backend = common.Backend;
const addColumnIfMissing = common.addColumnIfMissing;
const dropColumnIfExists = common.dropColumnIfExists;
const renameColumnIfExists = common.renameColumnIfExists;
const helpers = @import("helpers");

pub const Migration045AddPositionToWorkspaceItems = struct {
    pub const version: u32 = 45;
    pub const name = "add_position_to_workspace_items";

    pub fn up(db: *Backend, allocator: std.mem.Allocator) anyerror!void {
        // Mirror of Migration043AddPositionToWorkspaces but scoped to a
        // single workspace's items.
        try db.exec(allocator, "ALTER TABLE workspace_items ADD COLUMN position INTEGER NOT NULL DEFAULT 0", &[_][]const u8{});

        // Backfill.
        try db.exec(allocator,
            \\UPDATE workspace_items
            \\SET position = (
            \\    SELECT COUNT(*)
            \\    FROM workspace_items wi
            \\    WHERE wi.workspace_id = workspace_items.workspace_id
            \\        AND (wi.created_at > workspace_items.created_at
            \\            OR (wi.created_at = workspace_items.created_at AND wi.id > workspace_items.id))
            \\)
        , &[_][]const u8{});

        // Index on (workspace_id, position DESC) so the per-workspace
        // item list query uses an index even with hundreds of items
        // per workspace.
        try db.exec(allocator, "CREATE INDEX IF NOT EXISTS idx_workspace_items_workspace_position ON workspace_items(workspace_id, position DESC)", &[_][]const u8{});

        // Refresh query-planner stats (mirrors Migration043/044
        // pattern) so the new index is picked on pre-existing DBs.
        try db.exec(allocator, "ANALYZE", &[_][]const u8{});
    }
};
