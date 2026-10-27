const std = @import("std");
const common = @import("common.zig");

const Backend = common.Backend;
const addColumnIfMissing = common.addColumnIfMissing;
const dropColumnIfExists = common.dropColumnIfExists;
const renameColumnIfExists = common.renameColumnIfExists;
const helpers = @import("helpers");

pub const Migration011AddTemperatureAndThinking = struct {
    pub const version: u32 = 11;
    pub const name = "add_temperature_and_thinking";

    pub fn up(db: *Backend, allocator: std.mem.Allocator) anyerror!void {
        try db.exec(allocator, "ALTER TABLE llm_history ADD COLUMN temperature REAL DEFAULT 0.2", &[_][]const u8{});
        try db.exec(allocator, "ALTER TABLE llm_history ADD COLUMN is_thinking INTEGER DEFAULT 0", &[_][]const u8{});
    }
};
