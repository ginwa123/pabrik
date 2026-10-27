const std = @import("std");
const pabrikcore = @import("pabrikcore");

const sqlite = pabrikcore.sqlite;
const database = pabrikcore.database;

pub fn markHistoryNotForLLMRun(
    allocator: std.mem.Allocator,
    db: *database.Db,
    session_id: []const u8,
) !void {
    const sql = "UPDATE llm_history SET is_feed_to_llm = 0 WHERE session_id = ?";
    try db.exec(allocator, sql, &.{session_id});
}
