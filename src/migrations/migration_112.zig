const std = @import("std");
const common = @import("common.zig");

const Backend = common.Backend;
const renameColumnIfExists = common.renameColumnIfExists;

/// One task may ask for several skills, so Migration 110's column is renamed
/// to its plural. It keeps holding names, now `||`-joined: a single name IS a
/// one-element list, so no row needs a backfill and no column moves.
pub const Migration112RenameTaskSkillNames = struct {
    pub const version: u32 = 112;
    pub const name = "rename_task_skill_names";

    pub fn up(db: *Backend, allocator: std.mem.Allocator) anyerror!void {
        try renameColumnIfExists(
            .{ .db = db },
            allocator,
            "workspace_item_tasks",
            "skill_name",
            "skill_names",
        );
    }
};
