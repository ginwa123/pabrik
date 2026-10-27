const std = @import("std");
const common = @import("common.zig");

const Backend = common.Backend;
const addColumnIfMissing = common.addColumnIfMissing;
const dropColumnIfExists = common.dropColumnIfExists;
const renameColumnIfExists = common.renameColumnIfExists;
const helpers = @import("helpers");

pub const Migration091AddSubAgentNameToSessions = struct {
    pub const version: u32 = 91;
    pub const name = "add_sub_agent_name_to_sessions";

    pub fn up(db: *Backend, allocator: std.mem.Allocator) anyerror!void {
        try addColumnIfMissing(
            .{ .db = db },
            allocator,
            "sessions",
            "sub_agent_name",
            "sub_agent_name TEXT",
        );
        try addColumnIfMissing(
            .{ .db = db },
            allocator,
            "sessions",
            "parent_session_id",
            "parent_session_id TEXT",
        );
    }
};
