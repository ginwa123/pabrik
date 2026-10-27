const std = @import("std");
const common = @import("common.zig");

const Backend = common.Backend;
const addColumnIfMissing = common.addColumnIfMissing;
const dropColumnIfExists = common.dropColumnIfExists;
const renameColumnIfExists = common.renameColumnIfExists;
const helpers = @import("helpers");

/// Migration 061 — Re-backfill `created_iso` for rows that are NULL, empty,
/// OR have the wrong year (e.g. year 58,507 from the nanosecond/microsecond
/// mismatch). ## Why this migration exists Migration 060's backfill only
pub const Migration061FixCreatedIsoYear = struct {
    pub const version: u32 = 61;
    pub const name = "fix_llm_history_created_iso_year";

    pub fn up(db: *Backend, allocator: std.mem.Allocator) anyerror!void {
        // UPDATE WHERE clause matches three categories: 1. created_iso IS
        // NULL 2. created_iso = '' 3. created_iso has a year that doesn't
        // match any plausible Unix‑timestamp year — i.e.
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
            \\   OR (created_iso NOT LIKE '19__-%'
            \\       AND created_iso NOT LIKE '20__-%')
        , &[_][]const u8{});
    }
};
