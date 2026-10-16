const std = @import("std");
const common = @import("common.zig");

const SqliteBackend = common.SqliteBackend;
const renameColumnIfExists = common.renameColumnIfExists;

/// One task may ask for several skills, so the column Migration 110 added is
/// renamed to its plural. It keeps holding names, now `||`-joined: a single
/// name IS a one-element list, so no row needs a backfill, and a RENAME leaves
/// the column in place for the listers' `row.values[N]` mapping.
pub const Migration112RenameTaskSkillNames = struct {
    pub const version: u32 = 112;
    pub const name = "rename_task_skill_names";

    pub fn up(db: *SqliteBackend, allocator: std.mem.Allocator) anyerror!void {
        try renameColumnIfExists(
            .{ .db = db },
            allocator,
            "workspace_item_tasks",
            "skill_name",
            "skill_names",
        );
    }
};
