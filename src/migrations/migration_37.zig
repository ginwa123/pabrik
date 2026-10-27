const std = @import("std");
const common = @import("common.zig");

const Backend = common.Backend;
const addColumnIfMissing = common.addColumnIfMissing;
const dropColumnIfExists = common.dropColumnIfExists;
const renameColumnIfExists = common.renameColumnIfExists;
const helpers = @import("helpers");

pub const Migration037AddImageUrlToSessionQueueMessages = struct {
    pub const version: u32 = 37;
    pub const name = "add_image_url_to_session_queue_messages";

    pub fn up(db: *Backend, allocator: std.mem.Allocator) anyerror!void {
        try db.exec(allocator, "ALTER TABLE session_queue_messages ADD COLUMN image_url TEXT", &[_][]const u8{});
    }
};
