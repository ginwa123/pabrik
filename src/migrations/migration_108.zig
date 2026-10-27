const std = @import("std");
const common = @import("common.zig");

const Backend = common.Backend;

/// Migration 108 — remember how much of a process's log the agent has been
/// shown.
pub const Migration108AddBackgroundProcessReadOffset = struct {
    pub const version: u32 = 108;
    pub const name = "add_background_process_read_offset";

    pub fn up(db: *Backend, allocator: std.mem.Allocator) anyerror!void {
        try db.exec(allocator,
            \\ALTER TABLE session_background_process
            \\    ADD COLUMN last_read_offset INTEGER NOT NULL DEFAULT 0
        , &[_][]const u8{});
    }
};
