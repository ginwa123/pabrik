const std = @import("std");
const common = @import("common.zig");

const Backend = common.Backend;
const addColumnIfMissing = common.addColumnIfMissing;
const dropColumnIfExists = common.dropColumnIfExists;
const renameColumnIfExists = common.renameColumnIfExists;
const helpers = @import("helpers");
const dialect = common.dialect;

pub const Migration070AddAgentMemories = struct {
    pub const version: u32 = 70;
    pub const name = "add_agent_memories";

    pub fn up(db: *Backend, allocator: std.mem.Allocator) anyerror!void {
        // 1. Source table. `tags` is the canonical "no tags" sentinel
        //    ('') — matches `description` / `tags` / `image_urls`
        //    conventions from Migrations 062 / 067 / 069.
        try db.exec(allocator,
            \\CREATE TABLE IF NOT EXISTS agent_memories (
            \\    id TEXT PRIMARY KEY,
            \\    content TEXT NOT NULL,
            \\    tags TEXT NOT NULL DEFAULT '',
            \\    created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
            \\    updated_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP
            \\)
        , &[_][]const u8{});

        // 2. updated_at index for future "recent memories" surfaces.
        try db.exec(allocator,
            "CREATE INDEX IF NOT EXISTS idx_agent_memories_updated " ++
                "ON agent_memories(updated_at DESC)",
            &[_][]const u8{});

        // 3. The search index. Postgres keeps it in a GIN over `tsvector`,
        //    sqlite in an FTS5 virtual table.
        if (dialect.is_postgres) {
            const fts_index = try std.fmt.allocPrint(allocator,
                "CREATE INDEX IF NOT EXISTS idx_agent_memories_fts ON agent_memories USING gin ({s})",
                .{dialect.tsVectorText("COALESCE(content, '') || ' ' || COALESCE(tags, '')")},
            );
            defer allocator.free(fts_index);
            try db.exec(allocator, fts_index, &[_][]const u8{});
            return;
        }

        try db.exec(allocator,
            \\CREATE VIRTUAL TABLE IF NOT EXISTS agent_memories_fts USING fts5(
            \\    content,
            \\    tags,
            \\    tokenize='porter unicode61 remove_diacritics 2'
            \\)
        , &[_][]const u8{});

        // 4. Sync triggers — same pattern as Migration 058.
        try db.exec(allocator,
            \\CREATE TRIGGER IF NOT EXISTS agent_memories_ai AFTER INSERT ON agent_memories BEGIN
            \\  INSERT INTO agent_memories_fts(rowid, content, tags)
            \\  VALUES (new.rowid, new.content, new.tags);
            \\END
        , &[_][]const u8{});

        try db.exec(allocator,
            \\CREATE TRIGGER IF NOT EXISTS agent_memories_ad AFTER DELETE ON agent_memories BEGIN
            \\  DELETE FROM agent_memories_fts WHERE rowid = old.rowid;
            \\END
        , &[_][]const u8{});

        try db.exec(allocator,
            \\CREATE TRIGGER IF NOT EXISTS agent_memories_au AFTER UPDATE ON agent_memories BEGIN
            \\  DELETE FROM agent_memories_fts WHERE rowid = old.rowid;
            \\  INSERT INTO agent_memories_fts(rowid, content, tags)
            \\  VALUES (new.rowid, new.content, new.tags);
            \\END
        , &[_][]const u8{});

        // 5. Backfill. On a fresh DB this is a no-op (zero rows). On an
        //    existing DB that somehow has rows without FTS5 coverage
        //    (shouldn't happen, but defensive), this catches them up.
        try db.exec(allocator,
            \\INSERT INTO agent_memories_fts(rowid, content, tags)
            \\SELECT rowid, content, tags FROM agent_memories
        , &[_][]const u8{});
    }
};
