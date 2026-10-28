const std = @import("std");
const common = @import("common.zig");

const Backend = common.Backend;
const addColumnIfMissing = common.addColumnIfMissing;
const dropColumnIfExists = common.dropColumnIfExists;
const renameColumnIfExists = common.renameColumnIfExists;
const helpers = @import("helpers");

pub const Migration089AuthSessions = struct {
    pub const version: u32 = 89;
    pub const name = "auth_sessions";

    pub fn up(db: *Backend, allocator: std.mem.Allocator) anyerror!void {
        try db.exec(allocator,
            \\CREATE TABLE IF NOT EXISTS auth_sessions (
            \\    token_hash TEXT PRIMARY KEY,
            \\    user_id TEXT NOT NULL,
            \\    created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
            \\    expires_at TIMESTAMP NOT NULL,
            \\    last_seen_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
            \\    FOREIGN KEY (user_id) REFERENCES users(id) ON DELETE CASCADE
            \\)
        , &[_][]const u8{});
        try db.exec(allocator,
            "CREATE INDEX IF NOT EXISTS idx_auth_sessions_user ON auth_sessions(user_id)",
            &[_][]const u8{},
        );
        try db.exec(allocator,
            "CREATE INDEX IF NOT EXISTS idx_auth_sessions_expires ON auth_sessions(expires_at)",
            &[_][]const u8{},
        );
    }
};
