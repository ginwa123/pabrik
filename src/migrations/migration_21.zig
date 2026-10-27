const std = @import("std");
const common = @import("common.zig");

const Backend = common.Backend;
const addColumnIfMissing = common.addColumnIfMissing;
const dropColumnIfExists = common.dropColumnIfExists;
const renameColumnIfExists = common.renameColumnIfExists;
const helpers = @import("helpers");

pub const Migration021RemoveSessionNameFromLlmHistory = struct {
    pub const version: u32 = 21;
    pub const name = "remove_session_name_from_llm_history";

    pub fn up(db: *Backend, allocator: std.mem.Allocator) anyerror!void {
        try db.exec(allocator, "ALTER TABLE llm_history DROP COLUMN session_name", &[_][]const u8{});
    }
};
