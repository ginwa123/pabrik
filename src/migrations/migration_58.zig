const std = @import("std");
const common = @import("common.zig");

const Backend = common.Backend;
const addColumnIfMissing = common.addColumnIfMissing;
const dropColumnIfExists = common.dropColumnIfExists;
const renameColumnIfExists = common.renameColumnIfExists;
const helpers = @import("helpers");
const dialect = common.dialect;

pub const Migration058AddLlmHistoryFts = struct {
    pub const version: u32 = 58;
    pub const name = "add_llm_history_fts";

    pub fn up(db: *Backend, allocator: std.mem.Allocator) anyerror!void {
        if (dialect.is_postgres) {
            try db.exec(allocator,
                \\CREATE INDEX IF NOT EXISTS idx_llm_history_fts
                \\ON llm_history USING gin (to_tsvector('simple'::regconfig, COALESCE(response_content, '')))
            , &[_][]const u8{});
            return;
        }

        // FTS5 virtual table.
        try db.exec(allocator,
            \\CREATE VIRTUAL TABLE IF NOT EXISTS messages_fts USING fts5(
            \\    content,
            \\    tokenize='porter unicode61 remove_diacritics 2'
            \\)
        , &[_][]const u8{});

        // Sync triggers: keep `messages_fts` in sync with `llm_history` rows.
        // The rowid linkage allows searchMessagesFts to JOIN back to
        // llm_history for id/session_id/role/timestamps.
        try db.exec(allocator,
            \\CREATE TRIGGER IF NOT EXISTS llm_history_ai AFTER INSERT ON llm_history BEGIN
            \\  INSERT INTO messages_fts(rowid, content) VALUES (new.rowid, COALESCE(new.response_content, ''));
            \\END
        , &[_][]const u8{});

        try db.exec(allocator,
            \\CREATE TRIGGER IF NOT EXISTS llm_history_ad AFTER DELETE ON llm_history BEGIN
            \\  DELETE FROM messages_fts WHERE rowid = old.rowid;
            \\END
        , &[_][]const u8{});

        try db.exec(allocator,
            \\CREATE TRIGGER IF NOT EXISTS llm_history_au AFTER UPDATE ON llm_history BEGIN
            \\  DELETE FROM messages_fts WHERE rowid = old.rowid;
            \\  INSERT INTO messages_fts(rowid, content) VALUES (new.rowid, COALESCE(new.response_content, ''));
            \\END
        , &[_][]const u8{});

        // Backfill: walk existing llm_history rows and INSERT into the
        // FTS table. For zero rows this is a no-op; for ~10K rows it's
        // ~10ms.
        try db.exec(allocator,
            \\INSERT INTO messages_fts(rowid, content)
            \\SELECT rowid, COALESCE(response_content, '')
            \\FROM llm_history
        , &[_][]const u8{});
    }
};
