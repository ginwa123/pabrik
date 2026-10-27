const std = @import("std");
const common = @import("common.zig");

const Backend = common.Backend;
const addColumnIfMissing = common.addColumnIfMissing;
const dropColumnIfExists = common.dropColumnIfExists;
const renameColumnIfExists = common.renameColumnIfExists;
const helpers = @import("helpers");

pub const Migration040AddSelectedProfileModelToSessions = struct {
    pub const version: u32 = 40;
    pub const name = "add_selected_profile_model_to_sessions";

    pub fn up(db: *Backend, allocator: std.mem.Allocator) anyerror!void {
        try db.exec(allocator, "ALTER TABLE sessions ADD COLUMN selected_profile_model TEXT", &[_][]const u8{});
    }
};
