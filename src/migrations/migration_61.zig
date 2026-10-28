const std = @import("std");
const common = @import("common.zig");

const Backend = common.Backend;
const addColumnIfMissing = common.addColumnIfMissing;
const dropColumnIfExists = common.dropColumnIfExists;
const renameColumnIfExists = common.renameColumnIfExists;
const helpers = @import("helpers");
const dialect = common.dialect;

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
            \\   OR (created_iso NOT LIKE '19__-%'
            \\       AND created_iso NOT LIKE '20__-%')
        , .{ dialect.now_text, from_epoch });
        defer allocator.free(backfill);
        try db.exec(allocator, backfill, &[_][]const u8{});
    }
};
