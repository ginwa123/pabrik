const std = @import("std");
const common = @import("common.zig");

const Backend = common.Backend;
const addColumnIfMissing = common.addColumnIfMissing;
const dropColumnIfExists = common.dropColumnIfExists;
const renameColumnIfExists = common.renameColumnIfExists;
const helpers = @import("helpers");

pub const Migration088AddSessionPendingQuestion = struct {
    pub const version: u32 = 88;
    pub const name = "add_session_pending_question";

    pub fn up(db: *Backend, allocator: std.mem.Allocator) anyerror!void {
        // One row per `ask_user` tool call.
        try db.exec(allocator,
            \\CREATE TABLE IF NOT EXISTS session_pending_question (
            \\    id TEXT PRIMARY KEY,
            \\    session_id TEXT NOT NULL,
            \\    tool_call_id TEXT NOT NULL,
            \\    llm_history_id TEXT NOT NULL,
            \\    question TEXT NOT NULL,
            \\    multi_select INTEGER NOT NULL DEFAULT 0,
            \\    status TEXT NOT NULL DEFAULT 'pending',
            \\    answer TEXT,
            \\    created_at INTEGER NOT NULL,
            \\    resolved_at INTEGER
            \\)
        , &[_][]const u8{});

        // One question per tool call — makes a re-exec (retry after a
        // transient failure) idempotent instead of inserting a second row.
        try db.exec(allocator,
            "CREATE UNIQUE INDEX IF NOT EXISTS idx_spq_tool_call ON session_pending_question(tool_call_id)",
            &[_][]const u8{},
        );

        // The hot path: hasPendingQuestion() on every loop iteration and on
        // every user-sent message.
        try db.exec(allocator,
            "CREATE INDEX IF NOT EXISTS idx_spq_session_status ON session_pending_question(session_id, status)",
            &[_][]const u8{},
        );
    }
};
