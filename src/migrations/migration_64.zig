const std = @import("std");
const common = @import("common.zig");

const Backend = common.Backend;
const addColumnIfMissing = common.addColumnIfMissing;
const dropColumnIfExists = common.dropColumnIfExists;
const renameColumnIfExists = common.renameColumnIfExists;
const helpers = @import("helpers");

/// Migration 064 — Add the `logs` table for the frontend_log_post endpoint
/// (POST /api/log).
pub const Migration064AddFrontendLogs = struct {
    pub const version: u32 = 64;
    pub const name = "add_frontend_logs";

    pub fn up(db: *Backend, allocator: std.mem.Allocator) anyerror!void {
        try db.exec(
            allocator,
            \\CREATE TABLE IF NOT EXISTS logs (
            \\  id TEXT PRIMARY KEY,
            \\  created_at INTEGER NOT NULL,
            \\  level TEXT NOT NULL,
            \\  kind TEXT NOT NULL,
            \\  message TEXT NOT NULL,
            \\  stack TEXT,
            \\  source TEXT,
            \\  line INTEGER,
            \\  route_path TEXT,
            \\  session_id TEXT,
            \\  count INTEGER NOT NULL DEFAULT 1
            \\)
        , &[_][]const u8{});
        try db.exec(
            allocator,
            "CREATE INDEX IF NOT EXISTS idx_logs_created_at ON logs(created_at DESC)",
            &[_][]const u8{},
        );
        try db.exec(
            allocator,
            "CREATE INDEX IF NOT EXISTS idx_logs_level ON logs(level)",
            &[_][]const u8{},
        );
    }
};
