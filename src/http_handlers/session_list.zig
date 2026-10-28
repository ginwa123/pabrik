//! `GET /api/sessions` — list sessions with cursor pagination.

const std = @import("std");
const http_response = @import("http_response.zig");
const pabrikcore = @import("pabrikcore");
const test_db = pabrikcore.test_db;
const gserverz = pabrikcore.gserverz;
const llm_history = pabrikcore.llm_history;

pub const SessionListError = error{
    QueryFailed,
    /// `buildSessionListJson` returns `![]u8` (its body uses
    /// `std.json.Stringify.valueAlloc` which can fail with `OutOfMemory`).
    OutOfMemory,
};

const auth_common = @import("auth_common.zig");

pub const SessionListInput = struct {
    limit: u32,
    cursor: ?[]const u8,
    cwd: ?[]const u8,
    /// Raw `workspace_id` query param. null = param absent (global
    /// list); present (including empty "") = scope to that workspace.
    workspace_id: ?[]const u8,
    sort_field: llm_history.SessionSortField,
    sort_direction: llm_history.SessionSortDirection,
    /// Server-derived owner id. Defaults to the system user so same-file
    /// tests (and any caller without a request) keep the pre-isolation
    /// behaviour; the handler always sets the real owner.
    owner: []const u8 = auth_common.system_user_id,
};

pub const SessionListResult = []const u8; // pre-serialized JSON

// =====================================================================
// Use case
// =====================================================================

/// Parse query params into the typed input.
fn parseInput(query: anytype) !SessionListInput {
    const limit_str = query.get("limit") orelse "50";
    const limit = std.fmt.parseInt(u32, limit_str, 10) catch 50;

    const sort_by_str = query.get("sort_by") orelse "created_at";
    const sort_field = llm_history.enumFromString(llm_history.SessionSortField, sort_by_str) catch .created_at;

    const direction_str = query.get("direction") orelse "desc";
    const sort_direction = llm_history.enumFromString(llm_history.SessionSortDirection, direction_str) catch .desc;

    return .{
        .limit = limit,
        .cursor = query.get("cursor"),
        .cwd = query.get("cwd"),
        .workspace_id = query.get("workspace_id"),
        .sort_field = sort_field,
        .sort_direction = sort_direction,
    };
}

fn useCase(
    allocator: std.mem.Allocator,
    db: *pabrikcore.database.Db,
    io: std.Io,
    input: SessionListInput,
) SessionListError!SessionListResult {
    // Workspace scope: resolve `workspace_id` into the concrete session-id
    // set (task-linked ∪ cwd-matched).
    var scoped_ids: ?[][]u8 = null;
    defer if (scoped_ids) |ids| pabrikcore.workspace_scope.freeSessionIds(allocator, ids);

    // Const view of the same ids ([][]u8 does not coerce to
    // []const []const u8 element-wise); pointer-shares the id
    // buffers owned by scoped_ids — no extra string copies.
    var scope_view = std.ArrayList([]const u8).empty;
    defer scope_view.deinit(allocator);

    if (input.workspace_id) |wid| {
        scoped_ids = pabrikcore.workspace_scope.workspaceSessionIds(allocator, db, wid) catch return error.QueryFailed;
        if (scoped_ids) |ids| {
            for (ids) |id| scope_view.append(allocator, id) catch return error.OutOfMemory;
        }
    }
    const workspace_ids: ?[]const []const u8 = if (input.workspace_id != null) scope_view.items else null;

    const result = llm_history.getSessionListWithCursor(
        allocator,
        db,
        null,
        null,
        input.cwd,
        workspace_ids,
        input.owner,
        input.limit,
        input.cursor,
        input.sort_field,
        input.sort_direction,
    ) catch return error.QueryFailed;
    defer {
        for (result.sessions) |s| s.deinit(allocator);
        allocator.free(result.sessions);
    }

    // Sidebar git badge (mirrors the kanban tasks_list.zig badge). Resolve
    // the current branch per session via `git -C <cwd>` where cwd prefers the
    // bound worktree path and falls back to the session cwd.
    for (result.sessions) |*s| {
        const effective_cwd = if (s.git_worktree_cwd.len > 0) s.git_worktree_cwd else s.cwd;
        const branch = if (effective_cwd.len == 0) "" else resolveGitBranch(allocator, io, effective_cwd);
        defer if (branch.len > 0) allocator.free(branch);
        allocator.free(s.git_branch);
        s.git_branch = try allocator.dupe(u8, branch);
    }

    // has_more is true iff we got the full page back.
    const has_more = result.sessions.len == @as(usize, input.limit);

    // The cursor value is the last item's sort-field value
    // (created_at or updated_at depending on sort_field).
    const cursor_value: ?[]const u8 = if (result.sessions.len > 0)
        switch (input.sort_field) {
            .updated_at => result.sessions[result.sessions.len - 1].updated_at,
            else => result.sessions[result.sessions.len - 1].created_at,
        }
    else
        null;

    return try llm_history.buildSessionListJson(
        allocator,
        result.sessions,
        result.total,
        has_more,
        cursor_value,
    );
}

// =====================================================================
// Handler
// =====================================================================

pub fn sessionListHandler(
    ctx: gserverz.HttpContext,
    req: gserverz.HttpRequest,
    res: gserverz.HttpResponse,
) !gserverz.HttpResponse {
    const allocator = ctx.allocator;
    const io = ctx.io;

    const di = try pabrikcore.getSingleton();
    const sqlite_db = di.db;

    // Server-derived owner (cookie only, never a query param). Scopes the
    // list so B never sees A's chats; with --auth off the system user sees
    // everything, by decision 2026-09-25.
    const owner = auth_common.resolveRequestUserId(allocator, sqlite_db, di.auth_enabled, req.headers) catch {
        return res.jsonResponse(.{
            .status_code = 500,
            .data = try http_response.makeErrorResponse(allocator, .{ .@"error" = "Out of memory" }),
        });
    };
    defer allocator.free(owner);

    var input = parseInput(req.query) catch |err| {
        // Today `parseInput` never returns an error (parseInt with catch
        // defaults; enumFromString with catch defaults).
        return res.jsonResponse(.{
            .status_code = 400,
            .data = try http_response.makeErrorResponse(allocator, .{ .@"error" = @errorName(err) }),
        });
    };

    input.owner = owner;

    const response = useCase(allocator, sqlite_db, io, input) catch |err| {
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

    return res.jsonResponse(.{ .status_code = 200, .data = response });
}

// ===================================================================== Tests
// — workspace-scoped list end-to-end through the useCase
// ===================================================================== The

const testing = std.testing;

const TestCtx = struct {
    db: pabrikcore.database.Db,
    threaded: std.Io.Threaded,
};

fn setupDb() !TestCtx {
    const alloc = testing.allocator;
    var threaded = std.Io.Threaded.init(alloc, .{});
    errdefer threaded.deinit();
    const io = threaded.io();
    var db: pabrikcore.database.Db = .{};
    errdefer db.deinit();
    try test_db.openMemory(&db, io);

    // Minimal schema: the columns the session-list SELECT reads plus
    // the workspace tables the scope resolver joins on.
    try db.exec(alloc,
        \\CREATE TABLE sessions (
        \\  id TEXT PRIMARY KEY,
        \\  name TEXT NOT NULL,
        \\  status TEXT NOT NULL DEFAULT 'active',
        \\  cwd TEXT NOT NULL DEFAULT '',
        \\  created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
        \\  updated_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
        \\  selected_profile_model TEXT,
        \\  is_auto_retry_until_stop INTEGER NOT NULL DEFAULT 0,
        \\  last_finish_reason TEXT,
        \\  last_human_touched_at_nano INTEGER,
        \\  git_worktree_cwd TEXT,
        \\  is_pinned INTEGER NOT NULL DEFAULT 0,
        \\  pinned_position INTEGER NOT NULL DEFAULT 0
        \\)
    , &.{});
    try db.exec(alloc,
        \\CREATE TABLE llm_history (id TEXT PRIMARY KEY, session_id TEXT, agent TEXT)
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

    // Workspace A: item i_a (/proj/a) with task-linked sessions
    // task_a1 + task_a2, plus a plain chat cwd-matched under the
    // item path. Workspace B: item i_b (/proj/b) with task_b1.
    try db.exec(alloc,
        \\INSERT INTO workspace_items (id, workspace_id, item_type, name, path, position)
        \\VALUES ('i_a', 'A', 'kanban', 'Kanban A', '/proj/a', 1),
        \\       ('i_b', 'B', 'kanban', 'Kanban B', '/proj/b', 1)
    , &.{});
    try db.exec(alloc,
        \\INSERT INTO workspace_item_tasks (id, name, workspace_item_id)
        \\VALUES ('task_a1', 'Task A1', 'i_a'),
        \\       ('task_a2', 'Task A2', 'i_a'),
        \\       ('task_b1', 'Task B1', 'i_b')
    , &.{});
    try db.exec(alloc,
        \\INSERT INTO sessions (id, name, cwd) VALUES
        \\  ('task_a1', 'Task A1', '/proj/a'),
        \\  ('task_a2', 'Task A2', '/proj/a'),
        \\  ('plain_a', 'Plain chat under A', '/proj/a/sub'),
        \\  ('task_b1', 'Task B1', '/proj/b')
    , &.{});

    return .{ .db = db, .threaded = threaded };
}

fn teardown(ctx: *TestCtx) void {
    ctx.db.deinit();
    ctx.threaded.deinit();
}

fn runUseCase(ctx: *TestCtx, workspace_id: ?[]const u8) !SessionListResult {
    return useCase(testing.allocator, &ctx.db, ctx.threaded.io(), .{
        .limit = 50,
        .cursor = null,
        .cwd = null,
        .workspace_id = workspace_id,
        .sort_field = .created_at,
        .sort_direction = .desc,
    });
}

test "useCase: workspace_id=A returns exactly task-linked + cwd-matched sessions (total 3)" {
    var ctx = try setupDb();
    defer teardown(&ctx);

    const json = try runUseCase(&ctx, "A");
    defer testing.allocator.free(json);

    try testing.expect(std.mem.indexOf(u8, json, "\"session_id\":\"task_a1\"") != null);
    try testing.expect(std.mem.indexOf(u8, json, "\"session_id\":\"task_a2\"") != null);
    try testing.expect(std.mem.indexOf(u8, json, "\"session_id\":\"plain_a\"") != null);
    // Workspace B's session must not leak into A's scope.
    try testing.expect(std.mem.indexOf(u8, json, "task_b1") == null);
    // The count query must carry the same filter: 3, not the global 4.
    try testing.expect(std.mem.indexOf(u8, json, "\"total\":3") != null);
    try testing.expect(std.mem.indexOf(u8, json, "\"total\":4") == null);
}

test "useCase: each row carries the project it belongs to, and is empty when it belongs to none" {
    // Why this exists: `workspace_id` is resolved down to a set of *task ids*
    // and the project is then thrown away, so a client holding this list
    // cannot tell which project a session came from.
    var ctx = try setupDb();
    defer teardown(&ctx);

    const json = try runUseCase(&ctx, "A");
    defer testing.allocator.free(json);

    const parsed = try std.json.parseFromSlice(std.json.Value, testing.allocator, json, .{});
    defer parsed.deinit();

    const rows = parsed.value.object.get("sessions").?.array;
    var saw_task_a1 = false;
    var saw_plain_a = false;
    for (rows.items) |row| {
        const obj = row.object;
        const id = obj.get("session_id").?.string;
        const project = obj.get("workspace_item_id").?.string;

        if (std.mem.eql(u8, id, "task_a1") or std.mem.eql(u8, id, "task_a2")) {
            // Both belong to workspace item `i_a` (see setupDb).
            try testing.expectEqualStrings("i_a", project);
            saw_task_a1 = true;
        } else if (std.mem.eql(u8, id, "plain_a")) {
            // A plain chat under the same cwd, in no project at all. It must be
            // "" and not "i_a": a client that lights a spinner on the wrong
            // project is worse than one that lights none.
            try testing.expectEqualStrings("", project);
            saw_plain_a = true;
        }
    }
    try testing.expect(saw_task_a1);
    try testing.expect(saw_plain_a);

    // Workspace B's session reports B's project — the field tracks the row's
    // own project, not the scope it was listed under.
    const json_b = try runUseCase(&ctx, "B");
    defer testing.allocator.free(json_b);
    try testing.expect(std.mem.indexOf(u8, json_b, "\"workspace_item_id\":\"i_b\"") != null);
}

test "useCase: workspace scoping is fail-closed and param-absent stays global" {
    var ctx = try setupDb();
    defer teardown(&ctx);

    // B → only its own task session, total 1.
    {
        const json = try runUseCase(&ctx, "B");
        defer testing.allocator.free(json);
        try testing.expect(std.mem.indexOf(u8, json, "task_b1") != null);
        try testing.expect(std.mem.indexOf(u8, json, "task_a1") == null);
        try testing.expect(std.mem.indexOf(u8, json, "plain_a") == null);
        try testing.expect(std.mem.indexOf(u8, json, "\"total\":1") != null);
    }

    // Unknown workspace → empty list + total 0 (fail closed).
    {
        const json = try runUseCase(&ctx, "nope");
        defer testing.allocator.free(json);
        try testing.expect(std.mem.indexOf(u8, json, "\"sessions\":[]") != null);
        try testing.expect(std.mem.indexOf(u8, json, "\"total\":0") != null);
    }

    // Empty workspace_id (param present but "") → fail closed too.
    // Guards the `IN ()` / empty-bind bug classes: the resolver
    // returns an empty set, the SQL must stay valid with 0 rows.
    {
        const json = try runUseCase(&ctx, "");
        defer testing.allocator.free(json);
        try testing.expect(std.mem.indexOf(u8, json, "\"sessions\":[]") != null);
        try testing.expect(std.mem.indexOf(u8, json, "\"total\":0") != null);
    }

    // Param absent (null) → global list unchanged (back-compat).
    {
        const json = try runUseCase(&ctx, null);
        defer testing.allocator.free(json);
        try testing.expect(std.mem.indexOf(u8, json, "\"session_id\":\"task_a1\"") != null);
        try testing.expect(std.mem.indexOf(u8, json, "\"session_id\":\"task_a2\"") != null);
        try testing.expect(std.mem.indexOf(u8, json, "\"session_id\":\"plain_a\"") != null);
        try testing.expect(std.mem.indexOf(u8, json, "\"session_id\":\"task_b1\"") != null);
        try testing.expect(std.mem.indexOf(u8, json, "\"total\":4") != null);
    }
}

// =====================================================================
// Git branch resolution (sidebar git badge, mirrors tasks_list.zig)
// =====================================================================

/// Run `git -C <path> symbolic-ref --short HEAD` and fall back to `git -C
/// <path> rev-parse --abbrev-ref HEAD` for detached HEAD.
fn resolveGitBranch(
    allocator: std.mem.Allocator,
    io: std.Io,
    path: []const u8,
) []const u8 {
    const sym_argv = [_][]const u8{ "git", "-C", path, "symbolic-ref", "--short", "HEAD" };
    if (std.process.run(allocator, io, .{ .argv = &sym_argv })) |sym_result| {
        defer allocator.free(sym_result.stdout);
        defer allocator.free(sym_result.stderr);
        if (sym_result.term.exited == 0) {
            const branch = std.mem.trim(u8, sym_result.stdout, " \n\r\t");
            if (branch.len == 0) return "";
            return allocator.dupe(u8, branch) catch return "";
        }
    } else |_| {
        return "";
    }
    const rev_argv = [_][]const u8{ "git", "-C", path, "rev-parse", "--abbrev-ref", "HEAD" };
    const rev_result = std.process.run(allocator, io, .{ .argv = &rev_argv }) catch return "";
    defer allocator.free(rev_result.stdout);
    defer allocator.free(rev_result.stderr);
    if (rev_result.term.exited != 0) return "";
    const branch = std.mem.trim(u8, rev_result.stdout, " \n\r\t");
    if (branch.len == 0) return "";
    if (std.mem.eql(u8, branch, "HEAD")) return "";
    return allocator.dupe(u8, branch) catch return "";
}

test "useCase: session list wire carries git_worktree_cwd + git_branch (sidebar badge)" {
    var ctx = try setupDb();
    defer teardown(&ctx);

    // Bind a worktree path to one session; the wire must carry it
    // through even though /proj/a is not a git repo (branch "").
    try ctx.db.exec(testing.allocator, "UPDATE sessions SET git_worktree_cwd = '/tmp/wt-1' WHERE id = 'task_a1'", &.{});

    const json = try runUseCase(&ctx, "A");
    defer testing.allocator.free(json);

    try testing.expect(std.mem.indexOf(u8, json, "\"git_worktree_cwd\":\"/tmp/wt-1\"") != null);
    // Non-git cwd resolves to empty branch; key must still be present.
    try testing.expect(std.mem.indexOf(u8, json, "\"git_branch\":\"\"") != null);
}
