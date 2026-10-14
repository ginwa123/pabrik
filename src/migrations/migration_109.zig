const std = @import("std");
const common = @import("common.zig");

const SqliteBackend = common.SqliteBackend;
const addColumnIfMissing = common.addColumnIfMissing;

pub const Migration109AddSkillCanAutoImprove = struct {
    pub const version: u32 = 109;
    pub const name = "add_skill_can_auto_improve";

    pub fn up(db: *SqliteBackend, allocator: std.mem.Allocator) anyerror!void {
        try addColumnIfMissing(
            .{ .db = db },
            allocator,
            "skills",
            "is_can_auto_improve",
            "is_can_auto_improve INTEGER NOT NULL DEFAULT 1",
        );
    }
};
