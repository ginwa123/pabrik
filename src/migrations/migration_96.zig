const std = @import("std");
const common = @import("common.zig");

const SqliteBackend = common.SqliteBackend;
const addColumnIfMissing = common.addColumnIfMissing;
const dropColumnIfExists = common.dropColumnIfExists;
const renameColumnIfExists = common.renameColumnIfExists;
const helpers = @import("helpers");

pub const Migration096CreateSessionSkillEvents = struct {
    pub const version: u32 = 96;
    pub const name = "create_session_skill_events";

    pub fn up(db: *SqliteBackend, allocator: std.mem.Allocator) anyerror!void {
        // `event` is 'loaded' | 'listed' | 'created' | 'edited' | 'removed';
        // `source` is the tool name that produced the row.
        try db.exec(allocator,
            \\CREATE TABLE IF NOT EXISTS session_skill_events (
            \\    id TEXT PRIMARY KEY,
            \\    session_id TEXT NOT NULL,
            \\    skill_name TEXT NOT NULL,
            \\    event TEXT NOT NULL DEFAULT 'loaded',
            \\    source TEXT NOT NULL DEFAULT '',
            \\    content_hash TEXT NOT NULL DEFAULT '',
            \\    loop_index INTEGER NOT NULL DEFAULT 0,
            \\    llm_history_id TEXT NOT NULL DEFAULT '',
            \\    created_at DATETIME DEFAULT CURRENT_TIMESTAMP
            \\)
        , &[_][]const u8{});

        // The eval reads one session's events; the per-skill timeline reads by
        // name across sessions.
        try db.exec(allocator,
            "CREATE INDEX IF NOT EXISTS idx_session_skill_events_session ON session_skill_events(session_id, created_at)",
            &[_][]const u8{});
        try db.exec(allocator,
            "CREATE INDEX IF NOT EXISTS idx_session_skill_events_skill ON session_skill_events(skill_name, created_at)",
            &[_][]const u8{});
    }
};
