const std = @import("std");
const common = @import("common.zig");

const Backend = common.Backend;
const addColumnIfMissing = common.addColumnIfMissing;
const dropColumnIfExists = common.dropColumnIfExists;
const renameColumnIfExists = common.renameColumnIfExists;
const helpers = @import("helpers");

pub const Migration039AddToolCallIdToLlmHistory = struct {
    pub const version: u32 = 39;
    pub const name = "add_tool_call_id";

    pub fn up(db: *Backend, allocator: std.mem.Allocator) anyerror!void {
        try db.exec(allocator, "ALTER TABLE llm_history ADD COLUMN tool_call_id TEXT", &[_][]const u8{});
    }
};
