const std = @import("std");
const common = @import("common.zig");

const Backend = common.Backend;
const addColumnIfMissing = common.addColumnIfMissing;
const dropColumnIfExists = common.dropColumnIfExists;
const renameColumnIfExists = common.renameColumnIfExists;
const helpers = @import("helpers");

/// Migration 059 — Add a `created_iso` column to `llm_history` (populated by
/// application code — NOT SQLite triggers). ## Why this exists
/// `llm_history.created_at` is a TEXT column storing **Unix microseconds**
pub const Migration059AddCreatedIso = struct {
    pub const version: u32 = 59;
    pub const name = "add_llm_history_created_iso";

    pub fn up(db: *Backend, allocator: std.mem.Allocator) anyerror!void {
        // 1. Add the column (regular TEXT, nullable).
        try addColumnIfMissing(
            .{ .db = db },
            allocator,
            "llm_history",
            "created_iso",
            "created_iso TEXT",
        );

        // 2. Backfill existing rows.
        try db.exec(
            allocator,
            \\UPDATE llm_history
            \\SET created_iso = CASE
            \\    WHEN created_at IS NULL OR created_at = ''
            \\        THEN datetime('now')
            \\    ELSE datetime(
            \\        CAST(substr(created_at, 1, 10) AS INTEGER),
            \\        'unixepoch'
            \\    )
            \\END
            \\WHERE created_iso IS NULL
            \\   OR created_iso = ''
        , &[_][]const u8{});

        // 3. Index for queries filtering by created_iso.
        try db.exec(
            allocator,
            "CREATE INDEX IF NOT EXISTS idx_llm_history_created_iso ON llm_history(created_iso)",
            &[_][]const u8{},
        );
    }
};
