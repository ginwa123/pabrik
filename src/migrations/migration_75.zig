const std = @import("std");
const common = @import("common.zig");

const SqliteBackend = common.SqliteBackend;
const addColumnIfMissing = common.addColumnIfMissing;
const dropColumnIfExists = common.dropColumnIfExists;
const renameColumnIfExists = common.renameColumnIfExists;
const helpers = @import("helpers");

/// Migration 075 — Rename 5 timestamp columns to use the `_nano` suffix,
/// making the column name self-document the stored unit (integer since Unix
/// epoch).
pub const Migration075RenameTimestampColumnsToNanoSuffix = struct {
    pub const version: u32 = 75;
    pub const name = "rename_timestamp_columns_to_nano_suffix";

    pub fn up(db: *SqliteBackend, allocator: std.mem.Allocator) anyerror!void {
        // Wrap in a tx (db.begin/tx.exec/tx.commit) so the 5 renames + 2
        // index swaps are atomic.
        var tx = try db.begin();
        defer tx.commitOrRollback() catch {};
        errdefer tx.rollback() catch {};

        // 5 column renames — order doesn't matter logically, but
        // keep the order alphabetical by table for diff readability.
        try renameColumnIfExists(.{ .tx = &tx }, allocator, "llm_history", "created_at", "created_at_nano");
        try renameColumnIfExists(.{ .tx = &tx }, allocator, "logs", "created_at", "created_at_nano");
        try renameColumnIfExists(.{ .tx = &tx }, allocator, "session_skills", "loaded_at", "loaded_at_nano");
        try renameColumnIfExists(.{ .tx = &tx }, allocator, "worker", "last_activity", "last_activity_nano");
        try renameColumnIfExists(.{ .tx = &tx }, allocator, "workspace_item_tasks", "last_human_touched_at", "last_human_touched_at_nano");

        // 2 index renames — SQLite doesn't have `ALTER INDEX … RENAME TO …`,
        // and the index's auto-generated name doesn't auto- update on the
        // column rename.
        try tx.exec(allocator, "DROP INDEX IF EXISTS idx_logs_created_at", &.{});
        try tx.exec(allocator,
            "CREATE INDEX IF NOT EXISTS idx_logs_created_at_nano ON logs(created_at_nano DESC)",
            &.{});

        try tx.exec(allocator, "DROP INDEX IF EXISTS idx_worker_last_activity", &.{});
        try tx.exec(allocator,
            "CREATE INDEX IF NOT EXISTS idx_worker_last_activity_nano ON worker(last_activity_nano DESC)",
            &.{});

        // Commit the transaction. After this, Migration 075 is
        // "done" and the new schema is durable.
        try tx.commit();

        // ANALYZE so the query planner sees the renamed indexes
        // (mirrors Migration 041/042/043/051 pattern).
        try db.exec(allocator, "ANALYZE", &[_][]const u8{});
    }
};
