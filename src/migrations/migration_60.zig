const std = @import("std");
const common = @import("common.zig");

const Backend = common.Backend;
const addColumnIfMissing = common.addColumnIfMissing;
const dropColumnIfExists = common.dropColumnIfExists;
const renameColumnIfExists = common.renameColumnIfExists;
const helpers = @import("helpers");
const dialect = common.dialect;

/// Migration 060 — Re-run the `created_iso` backfill for rows that were NULL
/// when Migration 059 first ran. ## Why this migration exists V1 of Migration
/// 059 (now reverted) used SQLite INSERT/UPDATE triggers to populate
pub const Migration060RebackfillCreatedIso = struct {
    pub const version: u32 = 60;
    pub const name = "rebackfill_llm_history_created_iso";

    pub fn up(db: *Backend, allocator: std.mem.Allocator) anyerror!void {
        // Re-run the backfill from Migration 059 (v2).
        const from_epoch = try dialect.epochToText(allocator, "substr(CAST(created_at AS TEXT), 1, 10)");
        defer allocator.free(from_epoch);
        const backfill = try std.fmt.allocPrint(
            allocator,
            \\UPDATE llm_history
            \\SET created_iso = CASE
            \\    WHEN COALESCE(CAST(created_at AS TEXT), '') = ''
            \\        THEN {s}
            \\    ELSE {s}
            \\END
            \\WHERE created_iso IS NULL
            \\   OR created_iso = ''
        , .{ dialect.now_text, from_epoch });
        defer allocator.free(backfill);
        try db.exec(allocator, backfill, &[_][]const u8{});
    }
};
