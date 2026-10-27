const std = @import("std");
const common = @import("common.zig");

const Backend = common.Backend;
const addColumnIfMissing = common.addColumnIfMissing;
const dropColumnIfExists = common.dropColumnIfExists;
const renameColumnIfExists = common.renameColumnIfExists;
const helpers = @import("helpers");

/// Migration 082 - Add `sessions.last_human_touched_at_nano`. Sibling of
/// Migration 065 (which added the same column shape to
/// `workspace_item_tasks`).
pub const Migration082AddSessionHumanTouchedAt = struct {
    pub const version: u32 = 82;
    pub const name = "add_session_human_touched_at";

    pub fn up(db: *Backend, allocator: std.mem.Allocator) anyerror!void {
        try addColumnIfMissing(
            .{ .db = db },
            allocator,
            "sessions",
            // The SQL column name and the `column` probe arg must match
            // exactly - `addColumnIfMissing` issues `SELECT 1 FROM
            // pragma_table_info('sessions') WHERE name = '<column>'` first to
            "last_human_touched_at_nano",
            // name + type - `addColumnIfMissing` uses this verbatim as `ALTER
            // TABLE {table} ADD COLUMN {definition}`, so omitting the column
            // name would create a column literally named "INTEGER".
            "last_human_touched_at_nano INTEGER",
        );
    }
};
