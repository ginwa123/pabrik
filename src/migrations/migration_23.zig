const std = @import("std");
const common = @import("common.zig");

const Backend = common.Backend;
const addColumnIfMissing = common.addColumnIfMissing;
const dropColumnIfExists = common.dropColumnIfExists;
const renameColumnIfExists = common.renameColumnIfExists;
const helpers = @import("helpers");

pub const Migration023DropSessionDirFromLlmHistory = struct {
    pub const version: u32 = 23;
    pub const name = "drop_session_dir_from_llm_history";

    pub fn up(db: *Backend, allocator: std.mem.Allocator) anyerror!void {
        // SQLite doesn't support DROP COLUMN directly, so we need to recreate the table
        // Step 1: Rename old table
        try db.exec(allocator, "ALTER TABLE llm_history RENAME TO llm_history_old", &[_][]const u8{});

        // Step 2: Create new table without session_dir column
        try db.exec(allocator,
            \\CREATE TABLE IF NOT EXISTS llm_history (
            \\    id TEXT PRIMARY KEY,
            \\    session_id TEXT NOT NULL,
            \\    model TEXT NOT NULL,
            \\    response_content TEXT,
            \\    tool_calls_json TEXT,
            \\    tool_results_json TEXT,
            \\    finish_reason TEXT,
            \\    usage_json TEXT,
            \\    created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
            \\    role TEXT DEFAULT 'assistant',
            \\    reasoning_content TEXT,
            \\    is_feed_to_llm INTEGER DEFAULT 1,
            \\    agent TEXT DEFAULT 'Agent',
            \\    loop_index INTEGER DEFAULT 0,
            \\    temperature REAL DEFAULT 0.2,
            \\    is_thinking INTEGER DEFAULT 0,
            \\    parent_session_id TEXT,
            \\    parent_id TEXT,
            \\    prompt_tokens INTEGER DEFAULT 0,
            \\    completion_tokens INTEGER DEFAULT 0,
            \\    total_tokens INTEGER DEFAULT 0,
            \\    is_input INTEGER DEFAULT 0,
            \\    is_output INTEGER DEFAULT 0,
            \\    tool_name TEXT
            \\)
        , &[_][]const u8{});

        // Step 3: Copy data from old table (excluding session_dir column)
        try db.exec(allocator,
            \\INSERT INTO llm_history (id, session_id, model, response_content, tool_calls_json,
            \\    tool_results_json, finish_reason, usage_json, created_at, role,
            \\    reasoning_content, is_feed_to_llm, agent, loop_index, temperature, is_thinking,
            \\    parent_session_id, parent_id, prompt_tokens, completion_tokens, total_tokens,
            \\    is_input, is_output, tool_name)
            \\SELECT id, session_id, model, response_content, tool_calls_json,
            \\    tool_results_json, finish_reason, usage_json, created_at, role,
            \\    reasoning_content, is_feed_to_llm, agent, loop_index, COALESCE(temperature, 0.2), COALESCE(is_thinking, 0),
            \\    parent_session_id, parent_id, COALESCE(prompt_tokens, 0), COALESCE(completion_tokens, 0), COALESCE(total_tokens, 0),
            \\    COALESCE(is_input, 0), COALESCE(is_output, 0), tool_name
            \\FROM llm_history_old
        , &[_][]const u8{});

        // Step 4: Recreate index
        try db.exec(allocator, "CREATE INDEX IF NOT EXISTS idx_llm_history_session ON llm_history(session_id)", &[_][]const u8{});
        try db.exec(allocator, "CREATE INDEX IF NOT EXISTS idx_llm_history_parent_session ON llm_history(parent_session_id)", &[_][]const u8{});

        // Step 5: Drop old table
        try db.exec(allocator, "DROP TABLE llm_history_old", &[_][]const u8{});
    }
};
