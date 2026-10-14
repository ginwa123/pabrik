const std = @import("std");
const common = @import("common.zig");

const SqliteBackend = common.SqliteBackend;
const addColumnIfMissing = common.addColumnIfMissing;
const dropColumnIfExists = common.dropColumnIfExists;
const renameColumnIfExists = common.renameColumnIfExists;
const helpers = @import("helpers");

pub const Migration073AddSessionActivity = struct {
    pub const version: u32 = 73;
    pub const name = "add_session_activity";

    pub fn up(db: *SqliteBackend, allocator: std.mem.Allocator) anyerror!void {
        // 1. Source table — append-only log, no UNIQUE constraint.
        // `description` is NOT NULL (callers must supply) but has no DEFAULT
        // — an empty description would defeat the purpose of the log.
        try db.exec(allocator,
            \\CREATE TABLE IF NOT EXISTS session_activity (
            \\    id TEXT PRIMARY KEY,
            \\    session_id TEXT NOT NULL,
            \\    description TEXT NOT NULL,
            \\    created_at DATETIME DEFAULT CURRENT_TIMESTAMP
            \\)
        , &[_][]const u8{});

        // 2. Per-session newest-first index. Matches the index name
        //    pattern used elsewhere (`idx_llm_history_session`,
        //    `idx_session_skills_session`, `idx_agent_memories_updated`).
        try db.exec(allocator,
            "CREATE INDEX IF NOT EXISTS idx_session_activity_session_created " ++
                "ON session_activity(session_id, created_at DESC)",
            &[_][]const u8{},
        );
    }
};
