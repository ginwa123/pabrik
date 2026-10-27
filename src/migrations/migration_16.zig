const std = @import("std");
const common = @import("common.zig");

const Backend = common.Backend;
const addColumnIfMissing = common.addColumnIfMissing;
const dropColumnIfExists = common.dropColumnIfExists;
const renameColumnIfExists = common.renameColumnIfExists;
const helpers = @import("helpers");

pub const Migration016AddInputOutputColumns = struct {
    pub const version: u32 = 16;
    pub const name = "add_input_output_columns";

    pub fn up(db: *Backend, allocator: std.mem.Allocator) anyerror!void {
        try db.exec(allocator, "ALTER TABLE llm_history ADD COLUMN is_input INTEGER DEFAULT 0", &[_][]const u8{});
        try db.exec(allocator, "ALTER TABLE llm_history ADD COLUMN is_output INTEGER DEFAULT 0", &[_][]const u8{});
        try db.exec(allocator, "ALTER TABLE llm_history ADD COLUMN tool_name TEXT", &[_][]const u8{});
    }
};
