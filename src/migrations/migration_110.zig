const std = @import("std");
const common = @import("common.zig");

const SqliteBackend = common.SqliteBackend;
const addColumnIfMissing = common.addColumnIfMissing;

/// skill_name is a NAME, not an id (name is the row identity; ids break on re-import).
/// No FK to skills — task rows must survive skill deletion. Empty = no skill.
pub const Migration110AddTaskSkillName = struct {
    pub const version: u32 = 110;
    pub const name = "add_task_skill_name";

    pub fn up(db: *SqliteBackend, allocator: std.mem.Allocator) anyerror!void {
        try addColumnIfMissing(
            .{ .db = db },
            allocator,
            "workspace_item_tasks",
            "skill_name",
            "skill_name TEXT NOT NULL DEFAULT ''",
        );
    }
};
