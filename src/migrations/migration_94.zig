const std = @import("std");
const common = @import("common.zig");

const SqliteBackend = common.SqliteBackend;
const addColumnIfMissing = common.addColumnIfMissing;
const dropColumnIfExists = common.dropColumnIfExists;
const renameColumnIfExists = common.renameColumnIfExists;
const helpers = @import("helpers");

pub const Migration094AddDefaultProjectToWorkspaceItems = struct {
    pub const version: u32 = 94;
    pub const name = "add_default_project_to_workspace_items";

    pub fn up(db: *SqliteBackend, allocator: std.mem.Allocator) anyerror!void {
        // NOT NULL DEFAULT 0 is the only shape SQLite accepts when adding a
        // column to an existing table, and it has the property we want for
        // free: every pre-existing row reads back as 0 (an ordinary project)
        try addColumnIfMissing(.{ .db = db }, allocator, "workspace_items", "is_default", "is_default INTEGER NOT NULL DEFAULT 0");

        // At most one default per workspace, enforced by the DATABASE rather
        // than by a convention.
        try db.exec(allocator,
            \\CREATE UNIQUE INDEX IF NOT EXISTS idx_workspace_items_default_per_workspace
            \\ON workspace_items(workspace_id) WHERE is_default = 1
        , &[_][]const u8{});

        // Lookup index: ensureDefaultProject's fast path filters on both
        // columns, and this list runs on every sidebar load.
        try db.exec(allocator,
            \\CREATE INDEX IF NOT EXISTS idx_workspace_items_default_lookup
            \\ON workspace_items(workspace_id, is_default)
        , &[_][]const u8{});
    }
};
