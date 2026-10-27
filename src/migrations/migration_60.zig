const std = @import("std");
const common = @import("common.zig");

const Backend = common.Backend;
const addColumnIfMissing = common.addColumnIfMissing;
const dropColumnIfExists = common.dropColumnIfExists;
const renameColumnIfExists = common.renameColumnIfExists;
const helpers = @import("helpers");

/// Migration 060 — Re-run the `created_iso` backfill for rows that were NULL
/// when Migration 059 first ran. ## Why this migration exists V1 of Migration
/// 059 (now reverted) used SQLite INSERT/UPDATE triggers to populate
pub const Migration060RebackfillCreatedIso = struct {
    pub const version: u32 = 60;
    pub const name = "rebackfill_llm_history_created_iso";

    pub fn up(db: *Backend, allocator: std.mem.Allocator) anyerror!void {
        // Re-run the backfill from Migration 059 (v2).
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
    }
};
