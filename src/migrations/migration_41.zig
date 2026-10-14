const std = @import("std");
const common = @import("common.zig");

const SqliteBackend = common.SqliteBackend;
const addColumnIfMissing = common.addColumnIfMissing;
const dropColumnIfExists = common.dropColumnIfExists;
const renameColumnIfExists = common.renameColumnIfExists;
const helpers = @import("helpers");

pub const Migration041AddPerformanceIndexes = struct {
    pub const version: u32 = 41;
    pub const name = "add_performance_indexes";

    pub fn up(db: *SqliteBackend, allocator: std.mem.Allocator) anyerror!void {
        // Hot read paths in llm_history.zig +
        // http_handlers/queue_messages_get.zig +
        // http_handlers/worker_list.zig + http_handlers/workspaces_list.zig.
        try db.exec(allocator, "CREATE INDEX IF NOT EXISTS idx_llm_history_session_created ON llm_history(session_id, created_at DESC)", &[_][]const u8{});
        try db.exec(allocator, "CREATE INDEX IF NOT EXISTS idx_sessions_cwd_created ON sessions(cwd, created_at DESC)", &[_][]const u8{});
        try db.exec(allocator, "CREATE INDEX IF NOT EXISTS idx_sessions_updated_at ON sessions(updated_at DESC)", &[_][]const u8{});
        try db.exec(allocator, "CREATE INDEX IF NOT EXISTS idx_session_queue_messages_session_created ON session_queue_messages(session_id, created_at ASC)", &[_][]const u8{});
        try db.exec(allocator, "CREATE INDEX IF NOT EXISTS idx_worker_last_activity ON worker(last_activity DESC)", &[_][]const u8{});
        try db.exec(allocator, "CREATE INDEX IF NOT EXISTS idx_workspace_items_workspace_created ON workspace_items(workspace_id, created_at DESC)", &[_][]const u8{});
        try db.exec(allocator, "CREATE INDEX IF NOT EXISTS idx_workspace_items_created_at ON workspace_items(created_at DESC)", &[_][]const u8{});
        try db.exec(allocator, "CREATE INDEX IF NOT EXISTS idx_workspace_item_tasks_item_created ON workspace_item_tasks(workspace_item_id, created_at DESC)", &[_][]const u8{});
        try db.exec(allocator, "CREATE INDEX IF NOT EXISTS idx_workspaces_created_at ON workspaces(created_at DESC)", &[_][]const u8{});

        // ANALYZE updates sqlite_stat1 so the query planner knows the new indexes
        // exist and how selective they are. Without this, the planner may still pick
        // a full scan on existing databases that pre-date the new indexes.
        try db.exec(allocator, "ANALYZE", &[_][]const u8{});
    }
};
