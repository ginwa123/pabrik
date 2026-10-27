const std = @import("std");
const common = @import("common.zig");

const Backend = common.Backend;
const addColumnIfMissing = common.addColumnIfMissing;
const dropColumnIfExists = common.dropColumnIfExists;
const renameColumnIfExists = common.renameColumnIfExists;
const helpers = @import("helpers");

pub const Migration019CreateWorkerTable = struct {
    pub const version: u32 = 19;
    pub const name = "create_worker_table";

    pub fn up(db: *Backend, allocator: std.mem.Allocator) anyerror!void {
        try db.exec(allocator,
            \\CREATE TABLE IF NOT EXISTS worker (
            \\    id TEXT PRIMARY KEY,
            \\    session_id TEXT NOT NULL,
            \\    working_directory TEXT,
            \\    last_activity INTEGER DEFAULT (strftime('%s', 'now')),
            \\    last_activity_description TEXT,
            \\    created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP
            \\)
        , &[_][]const u8{});

        try db.exec(allocator, "CREATE INDEX IF NOT EXISTS idx_worker_session ON worker(session_id)", &[_][]const u8{});
    }
};
