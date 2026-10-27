const std = @import("std");
const common = @import("common.zig");

const Backend = common.Backend;
const addColumnIfMissing = common.addColumnIfMissing;
const dropColumnIfExists = common.dropColumnIfExists;
const renameColumnIfExists = common.renameColumnIfExists;
const helpers = @import("helpers");

pub const Migration093AddOwnerColumns = struct {
    pub const version: u32 = 93;
    pub const name = "add_owner_columns";

    pub fn up(db: *Backend, allocator: std.mem.Allocator) anyerror!void {
        try addColumnIfMissing(.{ .db = db }, allocator, "worker", "user_id", "user_id TEXT");
        try db.exec(allocator,
            "CREATE INDEX IF NOT EXISTS idx_worker_user_id ON worker(user_id)",
            &[_][]const u8{},
        );

        // Idempotent: only rows that still have no owner are touched, so a
        // re-run is a no-op and post-isolation rows keep their real owner.
        try db.exec(allocator, "UPDATE workspaces SET user_id = 'user_system' WHERE user_id IS NULL", &[_][]const u8{});
        try db.exec(allocator, "UPDATE sessions SET user_id = 'user_system' WHERE user_id IS NULL", &[_][]const u8{});
        try db.exec(allocator, "UPDATE worker SET user_id = 'user_system' WHERE user_id IS NULL", &[_][]const u8{});
    }
};
