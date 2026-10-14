//! `GET /api/llm/session/:session_id` — single-session detail.

const std = @import("std");
const http_response = @import("http_response.zig");
const pabrikcore = @import("pabrikcore");
const gserverz = pabrikcore.gserverz;
const llm_history = pabrikcore.llm_history;

pub const SessionGetError = error{
    QueryFailed,
    /// `std.json.Stringify.valueAlloc` can fail with `OutOfMemory`.
    /// Unreachable on the per-request arena, but the type system
    /// requires the variant.
    OutOfMemory,
};

/// Wire shape of the detail response. Field names mirror the session list
/// (`session_id`, not `id`) so clients read both endpoints the same way; the
/// full row is included so a detail fetch never needs a second round-trip.
pub const SessionDetailJson = struct {
    session_id: []const u8,
    name: []const u8,
    status: []const u8,
    cwd: []const u8,
    created_at: []const u8,
    updated_at: []const u8,
    selected_profile_model: []const u8,
    git_worktree_cwd: []const u8,
    is_auto_retry_until_stop: []const u8,
    last_finish_reason: []const u8,
    pr_url: []const u8,
    pr_provider: []const u8,
    sub_agent_name: []const u8,
    parent_session_id: []const u8,
    /// Owning workspace id, or null when the session is outside
    /// every workspace (or the session itself is unknown — the
    /// useCase returns null and the handler answers 404).
    workspace_id: ?[]const u8 = null,
};

// =====================================================================
// Use case
// =====================================================================

/// Read the session row and resolve its workspace.
/// Returns null for an unknown session id (handler → 404).
fn useCase(
    allocator: std.mem.Allocator,
    db: *pabrikcore.sqlite.SqliteBackend,
    session_id: []const u8,
) SessionGetError!?[]const u8 {
    // Empty id: fail closed without touching the resolver (it also guards
    // this, but there is no row to find either). getSession binds the id in a
    // SELECT — a probe for "" simply matches nothing; it is never written
    if (session_id.len == 0) return null;

    const session = (llm_history.getSession(allocator, db, session_id) catch return error.QueryFailed) orelse return null;
    defer session.deinit(allocator);

    // Workspace resolution is auxiliary data: a resolver failure
    // degrades to workspace_id=null instead of failing the whole
    // detail read.
    const workspace_id = pabrikcore.workspace_scope.resolveWorkspaceId(allocator, db, session_id) catch |err| blk: {
        std.log.warn(
            "session_get: workspace resolution failed (non-fatal, workspace_id=null): {s}",
            .{@errorName(err)},
        );
        break :blk @as(?[]u8, null);
    };
    defer if (workspace_id) |w| allocator.free(w);

    return try std.json.Stringify.valueAlloc(allocator, SessionDetailJson{
        .session_id = session.id,
        .name = session.name,
        .status = session.status,
        .cwd = session.cwd,
        .created_at = session.created_at,
        .updated_at = session.updated_at,
        // Already-corrupted rows (0xAA poison) are invalid UTF-8, which
        // std.json would emit as a byte array ([170, ...]). Fall back to
        // empty (Default chip) so the wire never carries garbage.
        .selected_profile_model = if (std.unicode.utf8ValidateSlice(session.selected_profile_model))
            session.selected_profile_model
        else
            "",
        .git_worktree_cwd = session.git_worktree_cwd,
        .is_auto_retry_until_stop = session.is_auto_retry_until_stop,
        .last_finish_reason = session.last_finish_reason,
        .pr_url = session.pr_url,
        .pr_provider = session.pr_provider,
        .sub_agent_name = session.sub_agent_name,
        .parent_session_id = session.parent_session_id,
        .workspace_id = workspace_id,
    }, .{});
}

// =====================================================================
// Handler
// =====================================================================

/// GET /api/llm/session/:session_id
pub fn sessionGetHandler(
    ctx: gserverz.HttpContext,
    req: gserverz.HttpRequest,
    res: gserverz.HttpResponse,
) !gserverz.HttpResponse {
    const allocator = ctx.allocator;

    const session_id = req.params.get("session_id") orelse {
        return res.jsonResponse(.{
            .status_code = 400,
            .data = try http_response.makeErrorResponse(allocator, .{ .@"error" = "Missing session_id" }),
        });
    };
    if (session_id.len == 0) {
        return res.jsonResponse(.{
            .status_code = 400,
            .data = try http_response.makeErrorResponse(allocator, .{ .@"error" = "Missing session_id" }),
        });
    }

    const di = try pabrikcore.getSingleton();
    const sqlite_db = di.db;

    const response = useCase(allocator, sqlite_db, session_id) catch |err| {
        const status: u16 = switch (err) {
            error.QueryFailed => 500,
            error.OutOfMemory => 500,
        };
        const message: []const u8 = switch (err) {
            error.QueryFailed => "Database query failed",
            error.OutOfMemory => "Out of memory",
        };
        return res.jsonResponse(.{
            .status_code = status,
            .data = try http_response.makeErrorResponse(allocator, .{ .@"error" = message }),
        });
    };

    const json = response orelse {
        return res.jsonResponse(.{
            .status_code = 404,
            .data = try http_response.makeErrorResponse(allocator, .{ .@"error" = "session not found" }),
        });
    };

    return res.jsonResponse(.{ .status_code = 200, .data = json });
}

// =====================================================================
// Tests — workspace_id resolution through the useCase (in-memory DB)
// =====================================================================

const testing = std.testing;

const TestCtx = struct {
    db: pabrikcore.sqlite.SqliteBackend,
    threaded: std.Io.Threaded,
};

fn setupDb() !TestCtx {
    const alloc = testing.allocator;
    var threaded = std.Io.Threaded.init(alloc, .{});
    errdefer threaded.deinit();
    const io = threaded.io();
    var db: pabrikcore.sqlite.SqliteBackend = .{};
    errdefer db.deinit();
    try db.init(io, ":memory:");

    // Full column set so llm_history.getSession's primary SELECT
    // succeeds (no legacy fallback).
    try db.exec(alloc,
        \\CREATE TABLE sessions (
        \\  id TEXT PRIMARY KEY,
        \\  name TEXT NOT NULL,
        \\  status TEXT NOT NULL DEFAULT 'active',
        \\  cwd TEXT NOT NULL DEFAULT '',
        \\  created_at DATETIME DEFAULT CURRENT_TIMESTAMP,
        \\  updated_at DATETIME DEFAULT CURRENT_TIMESTAMP,
        \\  selected_profile_model TEXT,
        \\  git_worktree_cwd TEXT NOT NULL DEFAULT '',
        \\  is_auto_retry_until_stop INTEGER NOT NULL DEFAULT 0,
        \\  last_finish_reason TEXT NOT NULL DEFAULT '',
        \\  pr_url TEXT NOT NULL DEFAULT '',
        \\  pr_provider TEXT NOT NULL DEFAULT '',
        \\  sub_agent_name TEXT NOT NULL DEFAULT '',
        \\  parent_session_id TEXT NOT NULL DEFAULT '',
        \\  last_human_touched_at_nano INTEGER
        \\)
    , &.{});
    try db.exec(alloc,
        \\CREATE TABLE workspace_items (
        \\  id TEXT PRIMARY KEY,
        \\  workspace_id TEXT,
        \\  item_type TEXT,
        \\  name TEXT,
        \\  path TEXT,
        \\  position INTEGER
        \\)
    , &.{});
    try db.exec(alloc,
        \\CREATE TABLE workspace_item_tasks (
        \\  id TEXT PRIMARY KEY,
        \\  name TEXT NOT NULL,
        \\  workspace_item_id TEXT NOT NULL
        \\)
    , &.{});

    try db.exec(alloc,
        \\INSERT INTO workspace_items (id, workspace_id, item_type, name, path, position)
        \\VALUES ('i_a', 'A', 'kanban', 'Kanban A', '/proj/a', 1)
    , &.{});
    try db.exec(alloc,
        \\INSERT INTO workspace_item_tasks (id, name, workspace_item_id)
        \\VALUES ('task_a1', 'Task A1', 'i_a')
    , &.{});
    try db.exec(alloc,
        \\INSERT INTO sessions (id, name, cwd) VALUES
        \\  ('task_a1', 'Task A1', '/proj/a'),
        \\  ('plain_a', 'Plain chat under A', '/proj/a/sub'),
        \\  ('outside', 'No workspace', '/elsewhere')
    , &.{});

    return .{ .db = db, .threaded = threaded };
}

fn teardown(ctx: *TestCtx) void {
    ctx.db.deinit();
    ctx.threaded.deinit();
}

test "useCase: task-linked, cwd-matched, and outside sessions resolve workspace_id correctly" {
    var ctx = try setupDb();
    defer teardown(&ctx);
    const alloc = testing.allocator;

    // Task link wins: session id == task id → workspace A.
    {
        const json = (try useCase(alloc, &ctx.db, "task_a1")) orelse return error.TestExpectedSessionFound;
        defer alloc.free(json);
        try testing.expect(std.mem.indexOf(u8, json, "\"session_id\":\"task_a1\"") != null);
        try testing.expect(std.mem.indexOf(u8, json, "\"workspace_id\":\"A\"") != null);
    }

    // Cwd heuristic: /proj/a/sub falls under A's /proj/a item path.
    {
        const json = (try useCase(alloc, &ctx.db, "plain_a")) orelse return error.TestExpectedSessionFound;
        defer alloc.free(json);
        try testing.expect(std.mem.indexOf(u8, json, "\"session_id\":\"plain_a\"") != null);
        try testing.expect(std.mem.indexOf(u8, json, "\"workspace_id\":\"A\"") != null);
    }

    // Outside every workspace → workspace_id null (JSON `null`).
    {
        const json = (useCase(alloc, &ctx.db, "outside") catch null) orelse return error.TestExpectedSessionFound;
        defer alloc.free(json);
        try testing.expect(std.mem.indexOf(u8, json, "\"session_id\":\"outside\"") != null);
        try testing.expect(std.mem.indexOf(u8, json, "\"workspace_id\":null") != null);
    }

    // Unknown session → null (handler maps to 404).
    try testing.expect((try useCase(alloc, &ctx.db, "nope")) == null);
    // Empty session id → null without touching the resolver.
    try testing.expect((try useCase(alloc, &ctx.db, "")) == null);
}
