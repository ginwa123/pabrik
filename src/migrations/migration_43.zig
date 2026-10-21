const std = @import("std");
const common = @import("common.zig");

const SqliteBackend = common.SqliteBackend;
const addColumnIfMissing = common.addColumnIfMissing;
const dropColumnIfExists = common.dropColumnIfExists;
const renameColumnIfExists = common.renameColumnIfExists;
const helpers = @import("helpers");

pub const Migration043AddPositionToWorkspaces = struct {
    pub const version: u32 = 43;
    pub const name = "add_position_to_workspaces";

    pub fn up(db: *SqliteBackend, allocator: std.mem.Allocator) anyerror!void {
        // Adds the `position` column to the workspaces table. The column is
        // the sort key for the sidebar's workspace list
        try db.exec(allocator, "ALTER TABLE workspaces ADD COLUMN position INTEGER NOT NULL DEFAULT 0", &[_][]const u8{});

        // Backfill. Assign position N-1 to the newest workspace, 0 to the
        // oldest.
        try db.exec(allocator,
            \\UPDATE workspaces
            \\SET position = (
            \\    SELECT COUNT(*)
            \\    FROM workspaces w2
            \\    WHERE w2.created_at < workspaces.created_at
            \\        OR (w2.created_at = workspaces.created_at AND w2.id > workspaces.id)
            \\)
        , &[_][]const u8{});

        // Index on position for the list endpoint's ORDER BY.
        try db.exec(allocator, "CREATE INDEX IF NOT EXISTS idx_workspaces_position ON workspaces(position DESC)", &[_][]const u8{});

        // ANALYZE so the query planner picks up the new index on
        // existing databases (without this, the planner may still
        // pick a full scan on pre-existing data).
        try db.exec(allocator, "ANALYZE", &[_][]const u8{});
    }
};
