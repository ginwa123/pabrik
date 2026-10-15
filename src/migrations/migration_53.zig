const std = @import("std");
const common = @import("common.zig");

const SqliteBackend = common.SqliteBackend;
const addColumnIfMissing = common.addColumnIfMissing;
const dropColumnIfExists = common.dropColumnIfExists;
const renameColumnIfExists = common.renameColumnIfExists;
const helpers = @import("helpers");

pub const Migration053AddKanbanColumnDescription = struct {
    pub const version: u32 = 53;
    pub const name = "add_kanban_column_description";

    pub fn up(db: *SqliteBackend, allocator: std.mem.Allocator) anyerror!void {
        // Kanban column description — Chunk 1 of the
        // kanban-column-description-settings plan.
        try db.exec(allocator,
            "ALTER TABLE kanban_columns ADD COLUMN description TEXT NOT NULL DEFAULT ''",
            &[_][]const u8{},
        );
    }
};
