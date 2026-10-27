const std = @import("std");
const common = @import("common.zig");

const Backend = common.Backend;
const addColumnIfMissing = common.addColumnIfMissing;
const dropColumnIfExists = common.dropColumnIfExists;
const renameColumnIfExists = common.renameColumnIfExists;
const helpers = @import("helpers");

pub const Migration033AddCancelledToWorker = struct {
    pub const version: u32 = 33;
    pub const name = "add_cancelled_to_worker";

    pub fn up(db: *Backend, allocator: std.mem.Allocator) anyerror!void {
        try db.exec(allocator, "ALTER TABLE worker ADD COLUMN cancelled INTEGER DEFAULT 0", &[_][]const u8{});
    }
};
