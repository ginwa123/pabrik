const std = @import("std");
const schemas = @import("schemas.zig");
const AgentTool = schemas.AgentTool;
const pabrikcore = @import("pabrikcore");
const sqlite = pabrikcore.sqlite;
const workspace_scope = pabrikcore.workspace_scope;
const helpers = @import("helpers");
const sanitize = helpers.sanitize_control_chars;
const is_worker_running = @import("../../../agentic_loop/is_worker_running.zig");

/// Input for view_session. Omitting `session_id` reports the CALLER's own
/// session — the common "where am I working?" question.
pub const ViewSessionInput = struct {
    /// A session in your workspace to inspect. Omit for your own session.
    session_id: []const u8 = "",
};

pub const view_session_tool_system_prompt =
    \\## View Session Tool — Behavior
    \\Use `view_session` to see ONE session's detail: where it runs and what it is doing.
    \\- Called with no arguments it reports YOUR OWN session — working directory, git worktree,
    \\  task, workspace, profile and whether a run is in flight.
    \\- `session_id` inspects another session in YOUR workspace. Another workspace's session is
    \\  DENIED (`denied: true`) and never described.
    \\- It returns METADATA only. Use `read_workspace_session` for messages and transcripts.
    \\
;

pub const view_session_tool = AgentTool{
    .type = "function",
    .function = .{
        .name = "view_session",
        .description =
        \\Show ONE session's detail — where it runs and what it is doing — as read-only metadata. It does NOT return messages or transcripts (use `read_workspace_session` for those).
        \\
        \\DEFAULT IS YOUR OWN SESSION: call it with no arguments to answer "what working directory am I in, is there a git worktree, which task/workspace is this, which profile, is a run in flight right now".
        \\
        \\WHAT YOU GET (JSON): `session_id`, `name`, `status`; `workspace` (`id`, `name`); `task` (`id`, `name`, `cwd`, `item_id`, `item_type`, `item_name`) or null when the session is a plain chat rather than a task chat; `cwd`; `git_worktree_cwd` (empty when none is bound); `selected_profile_model`; `is_auto_retry_until_stop`; `last_finish_reason`; `pr` (`url`, `provider`) or null; `parent_session_id`; `sub_agent_name`; `is_pinned`; `user_id`; `created_at`; `updated_at`; `last_human_touched_at_nano`; `is_running` (a worker row exists, i.e. a turn is executing NOW); `worker` (`working_directory`, `last_activity`, `last_activity_description`) or null; `queued_messages` (messages waiting behind the running turn); `has_pending_question` (an unanswered `ask_user` is blocking the session); `message_count`; `last_message_at`; `is_current_session`.
        \\
        \\SCOPE: your own session always. A `session_id` must belong to YOUR workspace — another workspace's session answers `denied: true` with no fields, exactly like `read_workspace_session`. An unknown id returns `session_not_found`.
        \\
        \\WHY THE RUNNING FIELDS MATTER: `run_session` schedules a run and returns immediately, so `is_running`, `last_finish_reason` and `queued_messages` are how you tell whether it is still going, finished, or waiting behind another turn.
        \\
        \\Examples: {} my own session · {"session_id": "sess_42"} a peer in my workspace.
        ,
        .parameters = .{
            .type = "object",
            .properties = &.{
                .{ .name = "session_id", .type = "string", .description = "A session in YOUR workspace to inspect. Omit to report your own session." },
            },
            .required = &.{},
        },
        .system_prompt = view_session_tool_system_prompt,
    },
};

/// True for the strings SQLite hands back for a `1`/`0` flag column.
fn truthy(v: []const u8) bool {
    if (v.len == 0) return false;
    return !std.mem.eql(u8, v, "0");
}

fn parseI64(v: []const u8) i64 {
    return std.fmt.parseInt(i64, v, 10) catch 0;
}

fn countScalar(allocator: std.mem.Allocator, db: *sqlite.SqliteBackend, sql: []const u8, binds: []const []const u8) !u32 {
    var rows = try db.query(allocator, sql, binds);
    defer rows.deinit();
    if (try rows.next()) |row| {
        defer row.deinit(allocator);
        return std.fmt.parseInt(u32, row.values[0], 10) catch 0;
    }
    return 0;
}

/// One owned string from a single-row scalar query, or "" when there is no
/// row.
fn scalar(allocator: std.mem.Allocator, db: *sqlite.SqliteBackend, sql: []const u8, binds: []const []const u8) ![]u8 {
    var rows = try db.query(allocator, sql, binds);
    defer rows.deinit();
    if (try rows.next()) |row| {
        defer row.deinit(allocator);
        return try allocator.dupe(u8, row.values[0]);
    }
    return allocator.dupe(u8, "");
}

const TaskDetail = struct {
    task_id: []u8,
    task_name: []u8,
    task_cwd: []u8,
    item_id: []u8,
    item_type: []u8,
    item_name: []u8,

    fn deinit(self: *const TaskDetail, allocator: std.mem.Allocator) void {
        allocator.free(self.task_id);
        allocator.free(self.task_name);
        allocator.free(self.task_cwd);
        allocator.free(self.item_id);
        allocator.free(self.item_type);
        allocator.free(self.item_name);
    }
};

/// The kanban/agent task this session IS, when it is a task chat. A session
/// id doubles as the task id (Migration 052), so the join is by id.
fn taskDetail(allocator: std.mem.Allocator, db: *sqlite.SqliteBackend, session_id: []const u8) !?TaskDetail {
    var rows = try db.query(allocator,
        \\SELECT t.id, COALESCE(t.name, ''), COALESCE(t.cwd, ''), wi.id,
        \\       COALESCE(wi.item_type, ''), COALESCE(wi.name, '')
        \\FROM workspace_item_tasks t
        \\JOIN workspace_items wi ON wi.id = t.workspace_item_id
        \\WHERE t.id = ?
    , &.{session_id});
    defer rows.deinit();
    if (try rows.next()) |row| {
        defer row.deinit(allocator);
        return .{
            .task_id = try allocator.dupe(u8, row.values[0]),
            .task_name = try allocator.dupe(u8, row.values[1]),
            .task_cwd = try allocator.dupe(u8, row.values[2]),
            .item_id = try allocator.dupe(u8, row.values[3]),
            .item_type = try allocator.dupe(u8, row.values[4]),
            .item_name = try allocator.dupe(u8, row.values[5]),
        };
    }
    return null;
}

const WorkerDetail = struct {
    working_directory: []u8,
    last_activity: []u8,
    last_activity_description: []u8,

    fn deinit(self: *const WorkerDetail, allocator: std.mem.Allocator) void {
        allocator.free(self.working_directory);
        allocator.free(self.last_activity);
        allocator.free(self.last_activity_description);
    }
};

/// The live `worker` row, when a turn is executing. `is_running` is derived
/// from the same row, so the two can never disagree.
fn workerDetail(allocator: std.mem.Allocator, db: *sqlite.SqliteBackend, session_id: []const u8) !?WorkerDetail {
    var rows = try db.query(allocator,
        \\SELECT COALESCE(working_directory, ''), COALESCE(last_activity_nano, 0),
        \\       COALESCE(last_activity_description, '')
        \\FROM worker WHERE id = ? LIMIT 1
    , &.{session_id});
    defer rows.deinit();
    if (try rows.next()) |row| {
        defer row.deinit(allocator);
        return .{
            .working_directory = try allocator.dupe(u8, row.values[0]),
            .last_activity = try allocator.dupe(u8, row.values[1]),
            .last_activity_description = try allocator.dupe(u8, row.values[2]),
        };
    }
    return null;
}

const SessionDetail = struct {
    id: []u8,
    name: []u8,
    status: []u8,
    cwd: []u8,
    git_worktree_cwd: []u8,
    profile: []u8,
    auto_retry: []u8,
    last_finish_reason: []u8,
    pr_url: []u8,
    pr_provider: []u8,
    parent_session_id: []u8,
    sub_agent_name: []u8,
    is_pinned: []u8,
    user_id: []u8,
    created_at: []u8,
    updated_at: []u8,
    last_human_touched_at_nano: []u8,
    message_count: u32,
    last_message_at: []u8,
    queued_messages: u32,
    has_pending_question: bool,
    worker: ?WorkerDetail,
    task: ?TaskDetail,

    fn deinit(self: *const SessionDetail, allocator: std.mem.Allocator) void {
        allocator.free(self.id);
        allocator.free(self.name);
        allocator.free(self.status);
        allocator.free(self.cwd);
        allocator.free(self.git_worktree_cwd);
        allocator.free(self.profile);
        allocator.free(self.auto_retry);
        allocator.free(self.last_finish_reason);
        allocator.free(self.pr_url);
        allocator.free(self.pr_provider);
        allocator.free(self.parent_session_id);
        allocator.free(self.sub_agent_name);
        allocator.free(self.is_pinned);
        allocator.free(self.user_id);
        allocator.free(self.created_at);
        allocator.free(self.updated_at);
        allocator.free(self.last_human_touched_at_nano);
        allocator.free(self.last_message_at);
        if (self.worker) |w| w.deinit(allocator);
        if (self.task) |t| t.deinit(allocator);
    }
};

/// Read every column view_session reports for one session, or null when the
/// row is gone. Reads only; the caller owns the result.
fn loadSessionDetail(allocator: std.mem.Allocator, db: *sqlite.SqliteBackend, session_id: []const u8) !?SessionDetail {
    var rows = try db.query(allocator,
        \\SELECT id, COALESCE(name, ''), COALESCE(status, ''), COALESCE(cwd, ''),
        \\       COALESCE(git_worktree_cwd, ''), COALESCE(selected_profile_model, ''),
        \\       COALESCE(is_auto_retry_until_stop, 0), COALESCE(last_finish_reason, ''),
        \\       COALESCE(pr_url, ''), COALESCE(pr_provider, ''),
        \\       COALESCE(parent_session_id, ''), COALESCE(sub_agent_name, ''),
        \\       COALESCE(is_pinned, 0), COALESCE(user_id, ''),
        \\       COALESCE(created_at, ''), COALESCE(updated_at, ''),
        \\       COALESCE(last_human_touched_at_nano, 0)
        \\FROM sessions WHERE id = ?
    , &.{session_id});
    defer rows.deinit();

    const row = (try rows.next()) orelse return null;
    defer row.deinit(allocator);

    var detail = SessionDetail{
        .id = try allocator.dupe(u8, row.values[0]),
        .name = try allocator.dupe(u8, row.values[1]),
        .status = try allocator.dupe(u8, row.values[2]),
        .cwd = try allocator.dupe(u8, row.values[3]),
        .git_worktree_cwd = try allocator.dupe(u8, row.values[4]),
        .profile = try allocator.dupe(u8, row.values[5]),
        .auto_retry = try allocator.dupe(u8, row.values[6]),
        .last_finish_reason = try allocator.dupe(u8, row.values[7]),
        .pr_url = try allocator.dupe(u8, row.values[8]),
        .pr_provider = try allocator.dupe(u8, row.values[9]),
        .parent_session_id = try allocator.dupe(u8, row.values[10]),
        .sub_agent_name = try allocator.dupe(u8, row.values[11]),
        .is_pinned = try allocator.dupe(u8, row.values[12]),
        .user_id = try allocator.dupe(u8, row.values[13]),
        .created_at = try allocator.dupe(u8, row.values[14]),
        .updated_at = try allocator.dupe(u8, row.values[15]),
        .last_human_touched_at_nano = try allocator.dupe(u8, row.values[16]),
        .message_count = 0,
        .last_message_at = try allocator.dupe(u8, ""),
        .queued_messages = 0,
        .has_pending_question = false,
        .worker = null,
        .task = null,
    };
    errdefer detail.deinit(allocator);

    // Parsed and duped INSIDE the row scope: a `break` that returned these
    // slices would hand back memory the row's `defer` is about to free.
    detail.message_count = blk: {
        var r = try db.query(allocator,
            \\SELECT COUNT(*), COALESCE(MAX(created_at_nano), '') FROM llm_history WHERE session_id = ?
        , &.{session_id});
        defer r.deinit();
        if (try r.next()) |cr| {
            defer cr.deinit(allocator);
            const n = std.fmt.parseInt(u32, cr.values[0], 10) catch 0;
            const last = try allocator.dupe(u8, cr.values[1]);
            allocator.free(detail.last_message_at);
            detail.last_message_at = last;
            break :blk n;
        }
        break :blk 0;
    };

    detail.queued_messages = try countScalar(
        allocator,
        db,
        "SELECT COUNT(*) FROM session_queue_messages WHERE session_id = ?",
        &.{session_id},
    );
    detail.has_pending_question = (try countScalar(
        allocator,
        db,
        "SELECT COUNT(*) FROM session_pending_question WHERE session_id = ? AND status = 'pending'",
        &.{session_id},
    )) > 0;
    detail.worker = try workerDetail(allocator, db, session_id);
    detail.task = try taskDetail(allocator, db, session_id);

    return detail;
}

fn jsonError(allocator: std.mem.Allocator, msg: []const u8) ![]u8 {
    const clean = try sanitize(allocator, msg);
    defer allocator.free(clean);
    return std.json.Stringify.valueAlloc(allocator, .{ .@"error" = clean }, .{});
}

/// The read gate, shared with `read_workspace_session`: your own session is
/// always visible, a peer only inside your workspace. Never leaks fields on a
/// denial.
fn deniedJSON(allocator: std.mem.Allocator, session_id: []const u8) ![]u8 {
    const clean = try sanitize(allocator, session_id);
    defer allocator.free(clean);
    return std.json.Stringify.valueAlloc(allocator, .{
        .denied = true,
        .session_id = clean,
        .message = "Session is not in your workspace.",
    }, .{});
}

/// Execute view_session. Returns a JSON string for the LLM.
pub fn execute_view_session(
    allocator: std.mem.Allocator,
    db: *sqlite.SqliteBackend,
    caller_session_id: []const u8,
    input: ViewSessionInput,
) ![]const u8 {
    if (caller_session_id.len == 0) {
        return jsonError(allocator, "Missing caller session — cannot resolve which session to describe.");
    }
    const target = if (input.session_id.len > 0) input.session_id else caller_session_id;
    const is_self = std.mem.eql(u8, target, caller_session_id);

    const detail = (try loadSessionDetail(allocator, db, target)) orelse
        return jsonError(allocator, "No session with that session_id.");
    defer detail.deinit(allocator);

    // Your own session is always visible; a peer must share the workspace.
    // Fail closed: an unresolvable pair is not "same".
    if (!is_self and !try workspace_scope.isSameWorkspace(allocator, db, caller_session_id, target)) {
        return deniedJSON(allocator, target);
    }

    // The RESOLVED workspace, not the raw column: a task-linked session (the
    // common case) has no stamped value and resolves through its task row.
    const resolved_workspace = try workspace_scope.resolveWorkspaceId(allocator, db, target);
    defer if (resolved_workspace) |w| allocator.free(w);
    const workspace_id: []const u8 = resolved_workspace orelse "";

    const workspace_name = try scalar(
        allocator,
        db,
        "SELECT COALESCE(name, '') FROM workspaces WHERE id = ? LIMIT 1",
        &.{workspace_id},
    );
    defer allocator.free(workspace_name);

    var owned: std.ArrayList([]u8) = .empty;
    defer {
        for (owned.items) |s| allocator.free(s);
        owned.deinit(allocator);
    }

    const id = try sanitize(allocator, detail.id);
    try owned.append(allocator, id);
    const name = try sanitize(allocator, detail.name);
    try owned.append(allocator, name);
    const status = try sanitize(allocator, detail.status);
    try owned.append(allocator, status);
    const cwd = try sanitize(allocator, detail.cwd);
    try owned.append(allocator, cwd);
    const worktree = try sanitize(allocator, detail.git_worktree_cwd);
    try owned.append(allocator, worktree);
    const profile = try sanitize(allocator, detail.profile);
    try owned.append(allocator, profile);
    const finish = try sanitize(allocator, detail.last_finish_reason);
    try owned.append(allocator, finish);
    const parent = try sanitize(allocator, detail.parent_session_id);
    try owned.append(allocator, parent);
    const sub_agent = try sanitize(allocator, detail.sub_agent_name);
    try owned.append(allocator, sub_agent);
    const user_id = try sanitize(allocator, detail.user_id);
    try owned.append(allocator, user_id);
    const created = try sanitize(allocator, detail.created_at);
    try owned.append(allocator, created);
    const updated = try sanitize(allocator, detail.updated_at);
    try owned.append(allocator, updated);
    const last_msg = try sanitize(allocator, detail.last_message_at);
    try owned.append(allocator, last_msg);
    const ws_name = try sanitize(allocator, workspace_name);
    try owned.append(allocator, ws_name);

    const JsonPr = struct { url: []const u8, provider: []const u8 };
    var pr: ?JsonPr = null;
    if (detail.pr_url.len > 0) {
        const url = try sanitize(allocator, detail.pr_url);
        try owned.append(allocator, url);
        const provider = try sanitize(allocator, detail.pr_provider);
        try owned.append(allocator, provider);
        pr = .{ .url = url, .provider = provider };
    }

    const JsonWorker = struct {
        working_directory: []const u8,
        last_activity: i64,
        last_activity_description: []const u8,
    };
    var worker: ?JsonWorker = null;
    if (detail.worker) |w| {
        const wd = try sanitize(allocator, w.working_directory);
        try owned.append(allocator, wd);
        const desc = try sanitize(allocator, w.last_activity_description);
        try owned.append(allocator, desc);
        worker = .{
            .working_directory = wd,
            .last_activity = parseI64(w.last_activity),
            .last_activity_description = desc,
        };
    }

    const JsonTask = struct {
        id: []const u8,
        name: []const u8,
        cwd: []const u8,
        item_id: []const u8,
        item_type: []const u8,
        item_name: []const u8,
    };
    var task: ?JsonTask = null;
    if (detail.task) |t| {
        const tid = try sanitize(allocator, t.task_id);
        try owned.append(allocator, tid);
        const tname = try sanitize(allocator, t.task_name);
        try owned.append(allocator, tname);
        const tcwd = try sanitize(allocator, t.task_cwd);
        try owned.append(allocator, tcwd);
        const iid = try sanitize(allocator, t.item_id);
        try owned.append(allocator, iid);
        const itype = try sanitize(allocator, t.item_type);
        try owned.append(allocator, itype);
        const iname = try sanitize(allocator, t.item_name);
        try owned.append(allocator, iname);
        task = .{
            .id = tid,
            .name = tname,
            .cwd = tcwd,
            .item_id = iid,
            .item_type = itype,
            .item_name = iname,
        };
    }

    return std.json.Stringify.valueAlloc(allocator, .{
        .success = true,
        .is_current_session = is_self,
        .session_id = id,
        .name = name,
        .status = status,
        .workspace = .{ .id = workspace_id, .name = ws_name },
        .task = task,
        .cwd = cwd,
        .git_worktree_cwd = worktree,
        .selected_profile_model = profile,
        .is_auto_retry_until_stop = truthy(detail.auto_retry),
        .last_finish_reason = finish,
        .pr = pr,
        .parent_session_id = parent,
        .sub_agent_name = sub_agent,
        .is_pinned = truthy(detail.is_pinned),
        .user_id = user_id,
        .created_at = created,
        .updated_at = updated,
        .last_human_touched_at_nano = parseI64(detail.last_human_touched_at_nano),
        .is_running = detail.worker != null,
        .worker = worker,
        .queued_messages = detail.queued_messages,
        .has_pending_question = detail.has_pending_question,
        .message_count = detail.message_count,
        .last_message_at = last_msg,
    }, .{});
}

const testing = std.testing;

fn parseTestJson(alloc: std.mem.Allocator, out: []const u8) !std.json.Parsed(std.json.Value) {
    return std.json.parseFromSlice(std.json.Value, alloc, out, .{});
}

const TestCtx = struct {
    db: sqlite.SqliteBackend,
    threaded: std.Io.Threaded,
};

fn setupDb() !TestCtx {
    const alloc = testing.allocator;
    var threaded = std.Io.Threaded.init(alloc, .{});
    errdefer threaded.deinit();
    var db: sqlite.SqliteBackend = .{};
    errdefer db.deinit();
    try db.init(threaded.io(), ":memory:");

    try db.exec(alloc,
        \\CREATE TABLE sessions (
        \\  id TEXT PRIMARY KEY,
        \\  name TEXT NOT NULL,
        \\  status TEXT NOT NULL DEFAULT 'active',
        \\  cwd TEXT,
        \\  workspace_id TEXT,
        \\  created_at DATETIME DEFAULT NULL,
        \\  updated_at DATETIME DEFAULT NULL,
        \\  selected_profile_model TEXT,
        \\  git_worktree_cwd TEXT,
        \\  is_auto_retry_until_stop INTEGER NOT NULL DEFAULT 0,
        \\  last_finish_reason TEXT,
        \\  user_id TEXT,
        \\  last_human_touched_at_nano INTEGER,
        \\  pr_url TEXT,
        \\  pr_provider TEXT,
        \\  sub_agent_name TEXT,
        \\  parent_session_id TEXT,
        \\  is_pinned INTEGER NOT NULL DEFAULT 0,
        \\  pinned_position INTEGER NOT NULL DEFAULT 0
        \\)
    , &.{});
    try db.exec(alloc, "CREATE TABLE workspaces (id TEXT PRIMARY KEY, name TEXT NOT NULL DEFAULT '')", &.{});
    try db.exec(alloc,
        \\CREATE TABLE workspace_items (
        \\  id TEXT PRIMARY KEY,
        \\  workspace_id TEXT NOT NULL,
        \\  item_type TEXT NOT NULL,
        \\  name TEXT,
        \\  path TEXT
        \\)
    , &.{});
    try db.exec(alloc,
        \\CREATE TABLE workspace_item_tasks (
        \\  id TEXT PRIMARY KEY,
        \\  name TEXT NOT NULL,
        \\  workspace_item_id TEXT NOT NULL,
        \\  cwd TEXT NOT NULL DEFAULT ''
        \\)
    , &.{});
    try db.exec(alloc,
        \\CREATE TABLE worker (
        \\  id TEXT PRIMARY KEY,
        \\  session_id TEXT NOT NULL,
        \\  working_directory TEXT,
        \\  last_activity_nano INTEGER DEFAULT 0,
        \\  last_activity_description TEXT
        \\)
    , &.{});
    try db.exec(alloc,
        \\CREATE TABLE session_queue_messages (
        \\  id TEXT NOT NULL, session_id TEXT NOT NULL, message TEXT
        \\)
    , &.{});
    try db.exec(alloc,
        \\CREATE TABLE session_pending_question (
        \\  id TEXT PRIMARY KEY, session_id TEXT NOT NULL, tool_call_id TEXT NOT NULL,
        \\  llm_history_id TEXT NOT NULL, question TEXT NOT NULL, status TEXT NOT NULL DEFAULT 'pending'
        \\)
    , &.{});
    try db.exec(alloc,
        \\CREATE TABLE llm_history (
        \\  id TEXT PRIMARY KEY, session_id TEXT NOT NULL, role TEXT,
        \\  response_content TEXT, created_at_nano TEXT
        \\)
    , &.{});

    try db.exec(alloc, "INSERT INTO workspaces (id, name) VALUES ('ws_a', 'Alpha'), ('ws_b', 'KabelWeb')", &.{});
    try db.exec(alloc,
        \\INSERT INTO workspace_items (id, workspace_id, item_type, name, path)
        \\VALUES ('item_a', 'ws_a', 'kanban', 'Sprint board', '/repos/alpha'),
        \\       ('item_b', 'ws_b', 'agent', 'Project Default', '/repos/kabelweb')
    , &.{});
    // `caller` is a task chat in ws_a — its session id IS the task id.
    try db.exec(alloc,
        \\INSERT INTO workspace_item_tasks (id, name, workspace_item_id, cwd)
        \\VALUES ('caller', 'Fix the login bug', 'item_a', '/repos/alpha')
    , &.{});
    try db.exec(alloc,
        \\INSERT INTO sessions (id, name, status, cwd, workspace_id, created_at, updated_at,
        \\  selected_profile_model, git_worktree_cwd, is_auto_retry_until_stop, last_finish_reason,
        \\  user_id, last_human_touched_at_nano, pr_url, pr_provider, is_pinned)
        \\VALUES ('caller', 'Fix the login bug', 'active', '/repos/alpha', NULL,
        \\  '2026-01-01 00:00:00', '2026-01-01 00:10:00', 'alpha-profile',
        \\  '/home/u/.config/pabrik/.worktrees/fix-login', 1, 'stop', 'u_1', 1700000000000000000,
        \\  'https://github.com/o/r/pull/7', 'github', 1),
        \\  ('mate', 'Sibling chat', 'active', '/repos/alpha/sub', 'ws_a',
        \\  '2026-01-01 00:00:00', '2026-01-01 00:20:00', 'alpha-profile', '', 0, '', 'u_1',
        \\  0, '', '', 0),
        \\  ('peer', 'Other workspace', 'active', '/repos/kabelweb', 'ws_b',
        \\  '2026-01-01 00:00:00', '2026-01-01 00:00:00', 'kabel-profile', '', 0, '', 'u_1',
        \\  0, '', '', 0),
        \\  ('orphan', 'No workspace', 'active', '/nowhere', NULL,
        \\  '2026-01-01 00:00:00', '2026-01-01 00:00:00', '', '', 0, '', 'u_1', 0, '', '', 0)
    , &.{});
    try db.exec(alloc,
        \\INSERT INTO llm_history (id, session_id, role, response_content, created_at_nano)
        \\VALUES ('h1', 'caller', 'user', 'fix it', 'n1'), ('h2', 'caller', 'assistant', 'done', 'n2')
    , &.{});
    return .{ .db = db, .threaded = threaded };
}

fn teardown(ctx: *TestCtx) void {
    ctx.db.deinit();
    ctx.threaded.deinit();
}

fn str(obj: std.json.ObjectMap, key: []const u8) []const u8 {
    return obj.get(key).?.string;
}

test "view_session: no session_id reports the caller's own session with its task and worktree" {
    var s = try setupDb();
    defer teardown(&s);
    const alloc = testing.allocator;

    const out = try execute_view_session(alloc, &s.db, "caller", .{});
    defer alloc.free(out);
    const parsed = try parseTestJson(alloc, out);
    defer parsed.deinit();
    const obj = parsed.value.object;

    try testing.expect(obj.get("success").?.bool);
    try testing.expect(obj.get("is_current_session").?.bool);
    try testing.expectEqualStrings("caller", str(obj, "session_id"));
    try testing.expectEqualStrings("Fix the login bug", str(obj, "name"));
    try testing.expectEqualStrings("/repos/alpha", str(obj, "cwd"));
    try testing.expectEqualStrings("/home/u/.config/pabrik/.worktrees/fix-login", str(obj, "git_worktree_cwd"));
    try testing.expectEqualStrings("ws_a", str(obj.get("workspace").?.object, "id"));
    try testing.expectEqualStrings("Alpha", str(obj.get("workspace").?.object, "name"));
    try testing.expectEqualStrings("alpha-profile", str(obj, "selected_profile_model"));
    try testing.expectEqualStrings("stop", str(obj, "last_finish_reason"));
    try testing.expect(obj.get("is_auto_retry_until_stop").?.bool);
    try testing.expect(obj.get("is_pinned").?.bool);
    try testing.expectEqualStrings("github", str(obj.get("pr").?.object, "provider"));
    try testing.expectEqual(@as(i64, 2), obj.get("message_count").?.integer);
    try testing.expectEqualStrings("n2", str(obj, "last_message_at"));
    // Task chat: the session id doubles as the task id.
    const task = obj.get("task").?.object;
    try testing.expectEqualStrings("Fix the login bug", str(task, "name"));
    try testing.expectEqualStrings("item_a", str(task, "item_id"));
    try testing.expectEqualStrings("kanban", str(task, "item_type"));
    try testing.expectEqualStrings("Sprint board", str(task, "item_name"));
    // Nothing is running and nothing is queued.
    try testing.expect(!obj.get("is_running").?.bool);
    try testing.expect(obj.get("worker").? == .null);
    try testing.expectEqual(@as(i64, 0), obj.get("queued_messages").?.integer);
    try testing.expect(!obj.get("has_pending_question").?.bool);
}

test "view_session: a peer in the caller's workspace is described, marked as not current" {
    var s = try setupDb();
    defer teardown(&s);
    const alloc = testing.allocator;

    const out = try execute_view_session(alloc, &s.db, "caller", .{ .session_id = "mate" });
    defer alloc.free(out);
    const parsed = try parseTestJson(alloc, out);
    defer parsed.deinit();
    const obj = parsed.value.object;

    try testing.expectEqualStrings("mate", str(obj, "session_id"));
    try testing.expectEqualStrings("Sibling chat", str(obj, "name"));
    // A plain chat: no task row, so `task` is null rather than an empty object.
    try testing.expect(obj.get("task").? == .null);
    try testing.expect(obj.get("pr").? == .null);
    try testing.expect(!obj.get("is_current_session").?.bool);
}

test "view_session: another workspace's session is denied without leaking a field" {
    var s = try setupDb();
    defer teardown(&s);
    const alloc = testing.allocator;

    const out = try execute_view_session(alloc, &s.db, "caller", .{ .session_id = "peer" });
    defer alloc.free(out);
    const parsed = try parseTestJson(alloc, out);
    defer parsed.deinit();
    const obj = parsed.value.object;

    try testing.expect(obj.get("denied").?.bool);
    try testing.expectEqualStrings("peer", str(obj, "session_id"));
    // The denial must not describe the session it refused.
    try testing.expect(std.mem.indexOf(u8, out, "kabel-profile") == null);
    try testing.expect(std.mem.indexOf(u8, out, "/repos/kabelweb") == null);
    try testing.expect(obj.get("cwd") == null);
    try testing.expect(obj.get("success") == null);
}

test "view_session: an unresolvable caller cannot describe a peer (fail closed)" {
    var s = try setupDb();
    defer teardown(&s);
    const alloc = testing.allocator;

    const out = try execute_view_session(alloc, &s.db, "orphan", .{ .session_id = "mate" });
    defer alloc.free(out);
    const parsed = try parseTestJson(alloc, out);
    defer parsed.deinit();
    try testing.expect(parsed.value.object.get("denied").?.bool);
}

test "view_session: a session with no workspace still describes itself" {
    var s = try setupDb();
    defer teardown(&s);
    const alloc = testing.allocator;

    // The most common sandbox case: your OWN session, no workspace at all.
    const out = try execute_view_session(alloc, &s.db, "orphan", .{});
    defer alloc.free(out);
    const parsed = try parseTestJson(alloc, out);
    defer parsed.deinit();
    const obj = parsed.value.object;
    try testing.expect(obj.get("success").?.bool);
    try testing.expectEqualStrings("", str(obj.get("workspace").?.object, "id"));
    try testing.expectEqualStrings("/nowhere", str(obj, "cwd"));
}

test "view_session: an unknown session_id is an error, not a denial" {
    var s = try setupDb();
    defer teardown(&s);
    const alloc = testing.allocator;

    const out = try execute_view_session(alloc, &s.db, "caller", .{ .session_id = "sess_ghost" });
    defer alloc.free(out);
    const parsed = try parseTestJson(alloc, out);
    defer parsed.deinit();
    const obj = parsed.value.object;
    try testing.expect(obj.get("denied") == null);
    try testing.expect(std.mem.indexOf(u8, str(obj, "error"), "No session") != null);
}

test "view_session: a running worker is reported with what it is doing and the queue behind it" {
    var s = try setupDb();
    defer teardown(&s);
    const alloc = testing.allocator;

    try s.db.exec(alloc,
        \\INSERT INTO worker (id, session_id, working_directory, last_activity_nano, last_activity_description)
        \\VALUES ('mate', 'mate', '/repos/alpha/sub', 1700000000000000123, 'running the test suite')
    , &.{});
    try s.db.exec(alloc,
        \\INSERT INTO session_queue_messages (id, session_id, message)
        \\VALUES ('q1', 'mate', 'next'), ('q2', 'mate', 'after that')
    , &.{});
    try s.db.exec(alloc,
        \\INSERT INTO session_pending_question (id, session_id, tool_call_id, llm_history_id, question, status)
        \\VALUES ('p1', 'mate', 'tc1', 'h9', 'which one?', 'pending')
    , &.{});

    const out = try execute_view_session(alloc, &s.db, "caller", .{ .session_id = "mate" });
    defer alloc.free(out);
    const parsed = try parseTestJson(alloc, out);
    defer parsed.deinit();
    const obj = parsed.value.object;

    try testing.expect(obj.get("is_running").?.bool);
    const worker = obj.get("worker").?.object;
    try testing.expectEqualStrings("/repos/alpha/sub", str(worker, "working_directory"));
    try testing.expectEqualStrings("running the test suite", str(worker, "last_activity_description"));
    try testing.expectEqual(@as(i64, 1700000000000000123), worker.get("last_activity").?.integer);
    try testing.expectEqual(@as(i64, 2), obj.get("queued_messages").?.integer);
    try testing.expect(obj.get("has_pending_question").?.bool);
}

test "view_session: is_running comes from the same worker row as the detail" {
    var s = try setupDb();
    defer teardown(&s);
    const alloc = testing.allocator;

    try testing.expect(!is_worker_running.isWorkerRunning(alloc, &s.db, "mate"));
    const before = try execute_view_session(alloc, &s.db, "caller", .{ .session_id = "mate" });
    defer alloc.free(before);
    const before_parsed = try parseTestJson(alloc, before);
    defer before_parsed.deinit();
    try testing.expect(!before_parsed.value.object.get("is_running").?.bool);

    // Positive control: with a worker row present it flips, so the assertion
    // above is not a field that is hard-coded false.
    try s.db.exec(alloc, "INSERT INTO worker (id, session_id) VALUES ('mate', 'mate')", &.{});
    try testing.expect(is_worker_running.isWorkerRunning(alloc, &s.db, "mate"));
    const after = try execute_view_session(alloc, &s.db, "caller", .{ .session_id = "mate" });
    defer alloc.free(after);
    const after_parsed = try parseTestJson(alloc, after);
    defer after_parsed.deinit();
    try testing.expect(after_parsed.value.object.get("is_running").?.bool);
}

test "view_session: the schema and prompt teach own-session default and the denial" {
    const tool = view_session_tool.function;
    try testing.expectEqualStrings("view_session", tool.name);
    try testing.expect(std.mem.indexOf(u8, tool.description, "DEFAULT IS YOUR OWN SESSION") != null);
    try testing.expect(std.mem.indexOf(u8, tool.description, "denied") != null);
    try testing.expect(std.mem.indexOf(u8, tool.description, "read_workspace_session") != null);
    try testing.expect(std.mem.indexOf(u8, view_session_tool_system_prompt, "DENIED") != null);
    try testing.expectEqual(@as(usize, 1), tool.parameters.properties.len);
    try testing.expectEqualStrings("session_id", tool.parameters.properties[0].name);
    // Optional, and the description must say what omitting it means.
    try testing.expectEqual(@as(usize, 0), tool.parameters.required.len);
    try testing.expect(std.mem.indexOf(u8, tool.parameters.properties[0].description, "your own session") != null);
}

// Exec adapter — the tool definition and its executor live in ONE file.

const exec_pabrikcore = @import("pabrikcore");
const tools = @import("../../../agentic_loop/tools.zig");
const ToolExecContext = tools.ToolExecContext;
const ToolExecResult = tools.ToolExecResult;
const agent = exec_pabrikcore.agent;
const wrapToolOutput = tools.wrapToolOutput;
const error_explain = @import("../../../agentic_loop/tools_error_explain.zig");
const view_session_mod = exec_pabrikcore.view_session;

pub fn execViewSession(ctx: ToolExecContext, tc: agent.ToolCall) !ToolExecResult {
    const parsed = std.json.parseFromSlice(
        view_session_mod.ViewSessionInput,
        ctx.allocator,
        tc.function.arguments,
        .{ .allocate = .alloc_always, .ignore_unknown_fields = true },
    ) catch |err| {
        const err_msg = try error_explain.explain(ctx.allocator, err, null);
        defer ctx.allocator.free(err_msg);
        const output = try wrapToolOutput(ctx.allocator, "view_session", tc.function.arguments, false, err_msg, "");
        return ToolExecResult{ .output = output, .output_allocated = true };
    };
    defer parsed.deinit();

    const inner = view_session_mod.execute_view_session(
        ctx.allocator,
        ctx.db,
        ctx.session_id,
        parsed.value,
    ) catch |err| {
        const err_msg = try error_explain.explain(ctx.allocator, err, null);
        defer ctx.allocator.free(err_msg);
        const output = try wrapToolOutput(ctx.allocator, "view_session", tc.function.arguments, false, err_msg, "");
        return ToolExecResult{ .output = output, .output_allocated = true };
    };

    const output = try wrapToolOutput(ctx.allocator, "view_session", tc.function.arguments, true, null, inner);
    return ToolExecResult{ .output = output, .output_allocated = true };
}
