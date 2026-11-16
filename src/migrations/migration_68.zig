const std = @import("std");
const common = @import("common.zig");

const Backend = common.Backend;
const addColumnIfMissing = common.addColumnIfMissing;
const dropColumnIfExists = common.dropColumnIfExists;
const renameColumnIfExists = common.renameColumnIfExists;
const helpers = @import("helpers");

/// Migration 068 — Add `llm_history.is_loading` column + partial UNIQUE INDEX on `tool_call_id` (tool-call-loading-placeholder plan).
pub const Migration068AddToolCallLoading = struct {
    pub const version: u32 = 68;
    pub const name = "add_tool_call_loading";

    pub fn up(db: *Backend, allocator: std.mem.Allocator) anyerror!void {
        // 1.
        try addColumnIfMissing(
            .{ .db = db },
            allocator,
            "llm_history",
            "is_loading",
            // name + type — `addColumnIfMissing` builds `ALTER TABLE {table} ADD COLUMN {definition}`, so the definition must include BOTH the column name AND the type.
            "is_loading INTEGER NOT NULL DEFAULT 0",
        );

        // 2. Backfill every existing row to `is_loading = 0`.
        try db.exec(
            allocator,
            "UPDATE llm_history SET is_loading = 0 WHERE is_loading IS NULL OR is_loading != 0",
            &[_][]const u8{},
        );

        // 3. Partial UNIQUE INDEX on `tool_call_id`.
        try db.exec(
            allocator,
            "CREATE UNIQUE INDEX IF NOT EXISTS idx_llm_history_tool_call_id_loading " ++
                "ON llm_history(tool_call_id) " ++
                "WHERE tool_call_id IS NOT NULL AND tool_call_id != ''",
            &[_][]const u8{},
        );
    }
};
