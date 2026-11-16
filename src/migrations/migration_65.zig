const std = @import("std");
const common = @import("common.zig");

const Backend = common.Backend;
const addColumnIfMissing = common.addColumnIfMissing;
const dropColumnIfExists = common.dropColumnIfExists;
const renameColumnIfExists = common.renameColumnIfExists;
const helpers = @import("helpers");
const dialect = common.dialect;

/// Migration 065 — Add `workspace_item_tasks.last_human_touched_at`.
pub const Migration065AddTaskHumanTouchedAt = struct {
    pub const version: u32 = 65;
    pub const name = "add_task_human_touched_at";

    pub fn up(db: *Backend, allocator: std.mem.Allocator) anyerror!void {
        try addColumnIfMissing(
            .{ .db = db },
            allocator,
            "workspace_item_tasks",
            "last_human_touched_at",
            // name + type — `addColumnIfMissing` uses this verbatim as `ALTER TABLE {table} ADD COLUMN {definition}`, so omitting the column name would create a column …
            "last_human_touched_at " ++ dialect.epoch_type,
        );
    }
};
