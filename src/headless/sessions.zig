//! `pabrik headless sessions` and `pabrik headless messages`.

const std = @import("std");
const pabrikcore = @import("pabrikcore");

const args = @import("args.zig");
const boot_mod = @import("boot.zig");

const llm_history = pabrikcore.llm_history;

/// One row of `headless sessions`.
pub const SessionRow = struct {
    id: []const u8,
    name: []const u8,
    cwd: []const u8,
    created_at: []const u8,
};

/// One row of `headless messages`.
pub const MessageRow = struct {
    id: []const u8,
    role: []const u8,
    content: []const u8,
    tool_name: []const u8,
    finish_reason: []const u8,
    created_at: []const u8,
};

pub const SessionsResult = struct {
    sessions: []SessionRow,
    total: u32,
};

pub const MessagesResult = struct {
    session_id: []const u8,
    messages: []MessageRow,
    has_more: bool,
};

/// List recent sessions, newest first.
pub fn listSessions(
    allocator: std.mem.Allocator,
    backend: *boot_mod.Backend,
    a: args.SessionsArgs,
) !SessionsResult {
    const db = backend.ctx.db;
    const res = try llm_history.getSessionListWithCursor(
        allocator,
        db,
        null, // status
        null, // agent_type
        null, // cwd filter
        null, // workspace scope
        "", // owner (auth is off in headless mode)
        a.limit,
        null, // cursor — first page only
        .updated_at,
        .desc,
    );

    var rows = try allocator.alloc(SessionRow, res.sessions.len);
    for (res.sessions, 0..) |s, i| {
        rows[i] = .{
            .id = s.session_id,
            .name = s.session_name,
            .cwd = s.cwd,
            .created_at = s.created_at,
        };
    }
    // The `SessionInfo` slices are owned by the caller (getSessionList
    // dupes them), so they are handed to the rows rather than copied.
    allocator.free(res.sessions);

    return .{ .sessions = rows, .total = res.total };
}

pub fn freeSessions(allocator: std.mem.Allocator, r: *SessionsResult) void {
    for (r.sessions) |s| {
        allocator.free(s.id);
        allocator.free(s.name);
        allocator.free(s.cwd);
        allocator.free(s.created_at);
    }
    allocator.free(r.sessions);
    r.sessions = &.{};
}

/// Print one session's messages, oldest first.
pub fn listMessages(
    allocator: std.mem.Allocator,
    backend: *boot_mod.Backend,
    a: args.MessagesArgs,
) !MessagesResult {
    const db = backend.ctx.db;
    const res = try llm_history.getSessionMessagesSorted(
        allocator,
        db,
        a.session_id,
        a.limit,
        null,
        .created_at_asc,
        null,
    );

    var rows = try allocator.alloc(MessageRow, res.messages.len);
    for (res.messages, 0..) |m, i| {
        rows[i] = .{
            .id = m.id,
            .role = m.role,
            .content = m.content,
            .tool_name = m.tool_name,
            .finish_reason = m.finish_reason,
            .created_at = m.timestamp,
        };
    }
    allocator.free(res.messages);

    return .{
        .session_id = a.session_id,
        .messages = rows,
        .has_more = res.has_more,
    };
}

pub fn freeMessages(allocator: std.mem.Allocator, r: *MessagesResult) void {
    for (r.messages) |m| {
        allocator.free(m.id);
        allocator.free(m.role);
        allocator.free(m.content);
        allocator.free(m.tool_name);
        allocator.free(m.finish_reason);
        allocator.free(m.created_at);
    }
    allocator.free(r.messages);
    r.messages = &.{};
}
