const std = @import("std");
const common = @import("common.zig");

const Backend = common.Backend;
const addColumnIfMissing = common.addColumnIfMissing;
const dropColumnIfExists = common.dropColumnIfExists;
const renameColumnIfExists = common.renameColumnIfExists;
const helpers = @import("helpers");

pub const Migration013AddTokenUsageColumns = struct {
    pub const version: u32 = 13;
    pub const name = "add_token_usage_columns";

    pub fn up(db: *Backend, allocator: std.mem.Allocator) anyerror!void {
        try db.exec(allocator, "ALTER TABLE llm_history ADD COLUMN prompt_tokens INTEGER DEFAULT 0", &[_][]const u8{});
        try db.exec(allocator, "ALTER TABLE llm_history ADD COLUMN completion_tokens INTEGER DEFAULT 0", &[_][]const u8{});
        try db.exec(allocator, "ALTER TABLE llm_history ADD COLUMN total_tokens INTEGER DEFAULT 0", &[_][]const u8{});
    }
};
