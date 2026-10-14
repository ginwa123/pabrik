const std = @import("std");
const tree1_mod = @import("pabrikcore");
const sqlite = tree1_mod.sqlite;
const logger_mod = tree1_mod.loggermod;

/// Check if an agent is already loaded in the database
pub fn isLoaded(
    allocator: std.mem.Allocator,
    db: *sqlite.SqliteBackend,
    session_id: []const u8,
    agent_name: []const u8,
) !bool {
    if (session_id.len == 0) return false;

    const sql = "SELECT 1 FROM session_agents WHERE session_id = ? AND agent_name = ? LIMIT 1";
    var rows = try db.query(allocator, sql, &.{ session_id, agent_name });
    defer rows.deinit();

    if (try rows.next()) |row| {
        row.deinit(allocator);
        return true;
    }
    return false;
}

/// Save a loaded agent to the database for persistence
pub fn SaveAgent(
    allocator: std.mem.Allocator,
    db: *sqlite.SqliteBackend,
    logger: *logger_mod.Logger,
    session_id: []const u8,
    agent_name: []const u8,
) !void {
    // Skip if session_id is empty
    if (session_id.len == 0) return;

    const sql = "INSERT OR REPLACE INTO session_agents (session_id, agent_name, updated_at) VALUES (?, ?, strftime('%s', 'now'))";
    try db.exec(allocator, sql, &.{ session_id, agent_name });
    logger.debugFmt("Agent '{s}' saved to database for session {s}", .{ agent_name, session_id });
}


test "save_agent module imports" {
    // Smoke test that the module compiles and exports the public API expected
    // by callers (isLoaded, SaveAgent). This replaces the standalone
    // save_agent_test.zig inlined here per the `agentic_loop/` convention.
    _ = isLoaded;
    _ = SaveAgent;
    try std.testing.expect(true);
}
