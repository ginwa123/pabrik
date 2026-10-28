const std = @import("std");
const pabrikcore = @import("pabrikcore");

const sqlite = pabrikcore.sqlite;
const database = pabrikcore.database;
const event_bus_mod = pabrikcore.event_bus;

const onEventSendSessions = @import("sse_on_event_send_session.zig").onEventSendSessions;

/// Update session name
pub fn updateSessionName(
    allocator: std.mem.Allocator,
    db: *database.Db,
    id: []const u8,
    new_name: []const u8,
    event_bus: ?*event_bus_mod.EventBus,
) !void {
    const sql = "UPDATE sessions SET name = ? WHERE id = ?";
    try db.exec(allocator, sql, &.{ new_name, id });

    if (event_bus) |eb| {
        const session = getSession(allocator, db, id) catch null;
        if (session) |s| {
            defer s.deinit(allocator);
            onEventSendSessions(allocator, eb, .{
                .action = "updated",
                .id = s.id,
                .name = s.name,
                .status = s.status,
                .cwd = s.cwd,
                .created_at = s.created_at,
                .updated_at = s.updated_at,
                .selected_profile_model = s.selected_profile_model,
                .git_worktree_cwd = s.git_worktree_cwd,
            }) catch {};
        }
    }
}

fn getSession(
    allocator: std.mem.Allocator,
    db: *database.Db,
    id: []const u8,
) !?SessionTableInfo {
    const sql = "SELECT s.id, s.name, s.status, COALESCE(s.cwd, ''), COALESCE(CAST(s.created_at AS TEXT), ''), COALESCE(CAST(s.updated_at AS TEXT), ''), COALESCE(s.selected_profile_model, ''), COALESCE(s.git_worktree_cwd, '') FROM sessions s WHERE s.id = ?";

    var rows = try db.query(allocator, sql, &.{id});
    defer rows.deinit();

    if (try rows.next()) |row| {
        const session = SessionTableInfo{
            .id = try allocator.dupe(u8, row.values[0]),
            .name = try allocator.dupe(u8, row.values[1]),
            .status = try allocator.dupe(u8, row.values[2]),
            .cwd = try allocator.dupe(u8, row.values[3]),
            .created_at = try allocator.dupe(u8, row.values[4]),
            .updated_at = try allocator.dupe(u8, row.values[5]),
            .selected_profile_model = try allocator.dupe(u8, row.values[6]),
            .git_worktree_cwd = try allocator.dupe(u8, row.values[7]),
        };
        row.deinit(allocator);
        return session;
    }

    return null;
}

pub const SessionTableInfo = struct {
    id: []u8,
    name: []u8,
    status: []u8,
    cwd: []u8,
    created_at: []u8,
    updated_at: []u8,
    selected_profile_model: []u8,
    git_worktree_cwd: []u8,

    pub fn deinit(self: SessionTableInfo, allocator: std.mem.Allocator) void {
        allocator.free(self.id);
        allocator.free(self.name);
        allocator.free(self.status);
        allocator.free(self.cwd);
        allocator.free(self.created_at);
        allocator.free(self.updated_at);
        allocator.free(self.selected_profile_model);
        allocator.free(self.git_worktree_cwd);
    }
};
