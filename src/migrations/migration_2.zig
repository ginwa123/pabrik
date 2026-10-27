const std = @import("std");
const common = @import("common.zig");

const Backend = common.Backend;
const addColumnIfMissing = common.addColumnIfMissing;
const dropColumnIfExists = common.dropColumnIfExists;
const renameColumnIfExists = common.renameColumnIfExists;
const helpers = @import("helpers");

pub const Migration002AddRoleToLLMHistory = struct {
    pub const version: u32 = 2;
    pub const name = "add_role_to_llm_history";

    pub fn up(db: *Backend, allocator: std.mem.Allocator) anyerror!void {
        try db.exec(allocator, "ALTER TABLE llm_history ADD COLUMN role TEXT DEFAULT 'assistant'", &[_][]const u8{});
    }
};
