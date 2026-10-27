const std = @import("std");
const schemas = @import("schemas.zig");
const AgentTool = schemas.AgentTool;
const pabrikcore = @import("pabrikcore");
const sqlite = pabrikcore.sqlite;
const database = pabrikcore.database;
const workspace_scope = pabrikcore.workspace_scope;
const ask_user_pending = pabrikcore.ask_user_pending;
const helpers = @import("helpers");
const sanitize = helpers.sanitize_control_chars;
const is_worker_running = @import("../../../agentic_loop/is_worker_running.zig");

/// Input for run_session. This tool ATTACHES to a session — it never creates
/// one — so `session_id` is the load-bearing field.
pub const RunSessionInput = struct {
    /// The session whose agent loop to start. Required.
    session_id: []const u8 = "",
    /// Queue this message onto the session before starting the loop. Omitted,
    /// the loop resumes with the conversation the session already has.
    message: []const u8 = "",
};

/// Which of the two behaviors the plan implements.
pub const RunMode = enum { sent, resumed };

/// Every way a call can be refused. Each one is a state the caller can act
/// on; none of them starts a half-configured run.
pub const RunSessionError = error{
    /// No `session_id`. This tool attaches to a session; it has nothing to
    /// attach to otherwise, and it does not create one.
    SessionIdRequired,
    SessionNotFound,
    /// A run is already executing on that session.
    WorkerAlreadyRunning,
    /// The session lives outside the caller's workspace.
    CrossWorkspaceForbidden,
};

/// A validated, ready-to-emit run. `queue_message` borrows the caller's
/// input; everything else is the SESSION's own row, copied.
pub const RunPlan = struct {
    mode: RunMode,
    session_id: []u8,
    session_name: []u8,
    cwd: []u8,
    profile: []u8,
    is_auto_retry_until_stop: []u8,
    user_id: []u8,
    workspace_id: []u8,
    queue_message: []const u8,
    skip_initial_queue_message: bool,

    pub fn deinit(self: *const RunPlan, allocator: std.mem.Allocator) void {
        allocator.free(self.session_id);
        allocator.free(self.session_name);
        allocator.free(self.cwd);
        allocator.free(self.profile);
        allocator.free(self.is_auto_retry_until_stop);
        allocator.free(self.user_id);
        allocator.free(self.workspace_id);
    }
};

pub const run_session_tool_system_prompt =
    \\## Run Session Tool — Behavior
    \\Use `run_session` to start the agent loop on an EXISTING session in YOUR OWN WORKSPACE.
    \\It never creates a session, so `session_id` is required.
    \\- `session_id` alone → start (or resume) that session's agent, continuing its conversation.
    \\- `session_id` + `message` → queue the message onto it first, then start.
    \\- The session keeps its OWN cwd, git worktree, profile and tools.
    \\- A `session_id` from another workspace is REFUSED, never run.
    \\- ASYNCHRONOUS: the call returns when the run is scheduled, not when it ends.
    \\
;

pub const run_session_tool = AgentTool{
    .type = "function",
    .function = .{
        .name = "run_session",
        .description =
        \\Start the agent loop on an EXISTING session in YOUR OWN WORKSPACE. It never creates a session: `session_id` is required.
        \\
        \\- `session_id` alone: start (or resume) that session's agent, continuing the conversation it already has.
        \\- `session_id` + `message`: queue the message onto it first, then start.
        \\
        \\The session keeps its OWN cwd, git worktree, profile and tools — nothing about it is overridden here.
        \\
        \\A `session_id` from another workspace is REFUSED, never run.
        \\
        \\ASYNCHRONOUS: the run is scheduled, not awaited. Use `view_session` to follow it.
        \\
        \\REFUSED (`success:false`, nothing started): no `session_id`; an unknown one; one outside your workspace; one whose worker is already running (NOT silently queued).
        \\
        \\MAIN-AGENT-ONLY: never available to a sub-agent.
        ,
        .parameters = .{
            .type = "object",
            .properties = &.{
                .{ .name = "session_id", .type = "string", .description = "REQUIRED. The session whose agent loop to start; must be in YOUR workspace. This tool never creates a session." },
                .{ .name = "message", .type = "string", .description = "Queue this message onto the session before starting. Omitted, the loop resumes the conversation the session already has." },
            },
            .required = &.{"session_id"},
        },
        .system_prompt = run_session_tool_system_prompt,
    },
};

fn sessionExists(allocator: std.mem.Allocator, db: *database.Db, session_id: []const u8) !bool {
    var rows = try db.query(allocator, "SELECT 1 FROM sessions WHERE id = ? LIMIT 1", &.{session_id});
    defer rows.deinit();
    if (try rows.next()) |row| {
        defer row.deinit(allocator);
        return true;
    }
    return false;
}

fn workspaceName(allocator: std.mem.Allocator, db: *database.Db, workspace_id: []const u8) ![]u8 {
    if (workspace_id.len == 0) return allocator.dupe(u8, "");
    var rows = try db.query(allocator, "SELECT COALESCE(name, '') FROM workspaces WHERE id = ? LIMIT 1", &.{workspace_id});
    defer rows.deinit();
    if (try rows.next()) |row| {
        defer row.deinit(allocator);
        return try allocator.dupe(u8, row.values[0]);
    }
    return allocator.dupe(u8, "");
}

/// Validate the call and resolve everything `App.emit_run_agent` needs. Reads
/// only: nothing here writes a row, so a refusal cannot leave state behind.
pub fn planRunSession(
    allocator: std.mem.Allocator,
    db: *database.Db,
    caller_session_id: []const u8,
    input: RunSessionInput,
) !RunPlan {
    if (input.session_id.len == 0) return error.SessionIdRequired;
    if (!try sessionExists(allocator, db, input.session_id)) return error.SessionNotFound;
    if (is_worker_running.isWorkerRunning(allocator, db, input.session_id)) return error.WorkerAlreadyRunning;
    // The same gate `read_workspace_session` uses. Fail CLOSED — an
    // unresolvable pair (a caller with no workspace) is not "same".
    if (!try workspace_scope.isSameWorkspace(allocator, db, caller_session_id, input.session_id)) {
        return error.CrossWorkspaceForbidden;
    }

    const fields = try ask_user_pending.loadSessionRunFields(allocator, db, input.session_id);
    defer fields.deinit(allocator);
    const resolved = try workspace_scope.resolveWorkspaceId(allocator, db, input.session_id);

    const session_id = try allocator.dupe(u8, input.session_id);
    errdefer allocator.free(session_id);
    const session_name = try allocator.dupe(u8, fields.name);
    errdefer allocator.free(session_name);
    const cwd = try allocator.dupe(u8, fields.cwd);
    errdefer allocator.free(cwd);
    const profile = try allocator.dupe(u8, fields.selected_profile_model);
    errdefer allocator.free(profile);
    const auto_retry = try allocator.dupe(u8, fields.is_auto_retry_until_stop);
    errdefer allocator.free(auto_retry);
    const user_id = try allocator.dupe(u8, fields.user_id);
    errdefer allocator.free(user_id);

    const has_message = input.message.len > 0;
    return .{
        .mode = if (has_message) .sent else .resumed,
        .session_id = session_id,
        .session_name = session_name,
        .cwd = cwd,
        .profile = profile,
        .is_auto_retry_until_stop = auto_retry,
        .user_id = user_id,
        .workspace_id = resolved orelse try allocator.dupe(u8, ""),
        .queue_message = input.message,
        // RESUME must not fabricate a user turn; SEND already carries one.
        .skip_initial_queue_message = !has_message,
    };
}

/// The refusal code the LLM reads, plus one actionable sentence.
fn refusalMessage(code: []const u8) []const u8 {
    if (std.mem.eql(u8, code, "session_id_required")) return "Pass the `session_id` of the session to start. `run_session` attaches to an existing session — it never creates one.";
    if (std.mem.eql(u8, code, "session_not_found")) return "No session with that `session_id`.";
    if (std.mem.eql(u8, code, "cross_workspace_forbidden")) return "That session is outside YOUR workspace. `run_session` only reaches the workspace you are in.";
    if (std.mem.eql(u8, code, "worker_already_running")) return "That session is already running. Do not retry in a loop — wait for it with `view_session`, or start a different session.";
    if (std.mem.eql(u8, code, "server_not_initialized")) return "The server singleton is unavailable, so no run can be scheduled right now.";
    return "Invalid run_session input.";
}

/// snake_case code for one refusal.
pub fn refusalCode(err: anyerror) []const u8 {
    return switch (err) {
        error.SessionIdRequired => "session_id_required",
        error.SessionNotFound => "session_not_found",
        error.CrossWorkspaceForbidden => "cross_workspace_forbidden",
        error.WorkerAlreadyRunning => "worker_already_running",
        else => "run_session_failed",
    };
}

// Exec adapter — the tool definition and its executor live in ONE file.

const exec_pabrikcore = @import("pabrikcore");
const tools = @import("../../../agentic_loop/tools.zig");
const ToolExecContext = tools.ToolExecContext;
const ToolExecResult = tools.ToolExecResult;
const agent = exec_pabrikcore.agent;
const wrapToolOutput = tools.wrapToolOutput;
const error_explain = @import("tools_error_explain.zig");
const run_session_mod = exec_pabrikcore.run_session;

/// JSON body of a refusal, as the tool-result text.
fn refusalJSON(allocator: std.mem.Allocator, code: []const u8, detail: []const u8) ![]u8 {
    const clean_detail = try sanitize(allocator, detail);
    defer allocator.free(clean_detail);
    return std.json.Stringify.valueAlloc(allocator, .{
        .success = false,
        .@"error" = code,
        .message = clean_detail,
    }, .{});
}

fn refused(ctx: ToolExecContext, tc: agent.ToolCall, code: []const u8) !ToolExecResult {
    const detail = try refusalJSON(ctx.allocator, code, refusalMessage(code));
    defer ctx.allocator.free(detail);
    const output = try wrapToolOutput(ctx.allocator, "run_session", tc.function.arguments, false, detail, "");
    return ToolExecResult{ .output = output, .output_allocated = true };
}

pub fn execRunSession(ctx: ToolExecContext, tc: agent.ToolCall) !ToolExecResult {
    const parsed = std.json.parseFromSlice(
        RunSessionInput,
        ctx.allocator,
        tc.function.arguments,
        .{ .allocate = .alloc_always, .ignore_unknown_fields = true },
    ) catch |err| {
        const err_msg = try error_explain.explain(ctx.allocator, err, null);
        defer ctx.allocator.free(err_msg);
        const output = try wrapToolOutput(ctx.allocator, "run_session", tc.function.arguments, false, err_msg, "");
        return ToolExecResult{ .output = output, .output_allocated = true };
    };
    defer parsed.deinit();

    var plan = run_session_mod.planRunSession(ctx.allocator, ctx.db, ctx.session_id, parsed.value) catch |err| {
        ctx.logger.infoFmt("run_session: refused ({s})", .{@errorName(err)});
        return refused(ctx, tc, run_session_mod.refusalCode(err));
    };
    defer plan.deinit(ctx.allocator);

    const di = exec_pabrikcore.getSingleton() catch {
        return refused(ctx, tc, "server_not_initialized");
    };

    // Attaching to an existing session: the row already exists, so
    // `insert_worker`'s INSERT OR IGNORE is a no-op and every column —
    // workspace included — stays exactly as the session had it.
    di.emit_run_agent(.{
        .session_id = plan.session_id,
        .session_name = plan.session_name,
        .queue_message = plan.queue_message,
        .cwd = plan.cwd,
        .body_message = "",
        .allowed_tools = "",
        .image_urls = "",
        .video_urls = "",
        .selected_profile_model = plan.profile,
        .is_auto_retry_until_stop = plan.is_auto_retry_until_stop,
        .skip_initial_queue_message = plan.skip_initial_queue_message,
        .user_id = plan.user_id,
    }) catch |err| {
        ctx.logger.errFmt("run_session: emit_run_agent failed: {s}", .{@errorName(err)});
        return refused(ctx, tc, "run_session_failed");
    };

    const workspace_label = try workspaceName(ctx.allocator, ctx.db, plan.workspace_id);
    defer ctx.allocator.free(workspace_label);

    const clean_session_id = try sanitize(ctx.allocator, plan.session_id);
    defer ctx.allocator.free(clean_session_id);
    const clean_name = try sanitize(ctx.allocator, plan.session_name);
    defer ctx.allocator.free(clean_name);
    const clean_workspace = try sanitize(ctx.allocator, workspace_label);
    defer ctx.allocator.free(clean_workspace);
    const clean_cwd = try sanitize(ctx.allocator, plan.cwd);
    defer ctx.allocator.free(clean_cwd);

    const inner = try std.json.Stringify.valueAlloc(ctx.allocator, .{
        .success = true,
        .mode = @tagName(plan.mode),
        .session_id = clean_session_id,
        .session_name = clean_name,
        .workspace_id = plan.workspace_id,
        .workspace_name = clean_workspace,
        .cwd = clean_cwd,
        .note = "The run was scheduled, not awaited — this call returns before the agent finishes. Read the session with `view_session` to follow it.",
    }, .{});
    defer ctx.allocator.free(inner);

    const output = try wrapToolOutput(ctx.allocator, "run_session", tc.function.arguments, true, null, inner);
    return ToolExecResult{ .output = output, .output_allocated = true };
}

const testing = std.testing;

fn parseTestJson(alloc: std.mem.Allocator, out: []const u8) !std.json.Parsed(std.json.Value) {
    return std.json.parseFromSlice(std.json.Value, alloc, out, .{});
}

const TestCtx = struct {
    db: database.Db,
    threaded: std.Io.Threaded,
};

fn setupDb() !TestCtx {
    const alloc = testing.allocator;
    var threaded = std.Io.Threaded.init(alloc, .{});
    errdefer threaded.deinit();
    var db: database.Db = .{};
    errdefer db.deinit();
    try db.init(threaded.io(), ":memory:");

    try db.exec(alloc,
        \\CREATE TABLE sessions (
        \\  id TEXT PRIMARY KEY,
        \\  name TEXT NOT NULL,
        \\  status TEXT DEFAULT 'active',
        \\  cwd TEXT,
        \\  selected_profile_model TEXT,
        \\  is_auto_retry_until_stop INTEGER DEFAULT 0,
        \\  user_id TEXT,
        \\  workspace_id TEXT
        \\)
    , &.{});
    try db.exec(alloc, "CREATE TABLE workspaces (id TEXT PRIMARY KEY, name TEXT NOT NULL DEFAULT '')", &.{});
    try db.exec(alloc,
        \\CREATE TABLE workspace_items (
        \\  id TEXT PRIMARY KEY,
        \\  workspace_id TEXT NOT NULL,
        \\  item_type TEXT NOT NULL,
        \\  name TEXT,
        \\  path TEXT,
        \\  position INTEGER NOT NULL DEFAULT 0,
        \\  is_default INTEGER NOT NULL DEFAULT 0
        \\)
    , &.{});
    try db.exec(alloc,
        \\CREATE TABLE workspace_item_tasks (
        \\  id TEXT PRIMARY KEY,
        \\  name TEXT NOT NULL,
        \\  workspace_item_id TEXT NOT NULL
        \\)
    , &.{});
    try db.exec(alloc, "CREATE TABLE worker (id TEXT PRIMARY KEY, session_id TEXT)", &.{});

    try db.exec(alloc,
        \\INSERT INTO workspaces (id, name) VALUES ('ws_a', 'Alpha'), ('ws_b', 'KabelWeb')
    , &.{});
    try db.exec(alloc,
        \\INSERT INTO workspace_items (id, workspace_id, item_type, name, path, position, is_default)
        \\VALUES ('item_a', 'ws_a', 'agent', 'Project Default', '/repos/alpha', 1, 1),
        \\       ('item_b', 'ws_b', 'agent', 'Project Default', '/repos/kabelweb', 1, 1)
    , &.{});
    // `caller` is a task chat in ws_a (its session id IS the task id);
    // `mate` and `peer` are sessions in the caller's workspace and another one.
    try db.exec(alloc,
        \\INSERT INTO workspace_item_tasks (id, name, workspace_item_id) VALUES ('caller', 'Fix the login bug', 'item_a')
    , &.{});
    try db.exec(alloc,
        \\INSERT INTO sessions (id, name, status, cwd, selected_profile_model, is_auto_retry_until_stop, user_id, workspace_id)
        \\VALUES ('caller', 'Fix the login bug', 'active', '/repos/alpha', 'alpha-profile', 0, 'u_1', NULL),
        \\       ('mate', 'Sibling chat', 'active', '/repos/alpha/sub', 'alpha-profile', 0, 'u_1', 'ws_a'),
        \\       ('peer', 'Other workspace', 'active', '/repos/kabelweb/sub', 'kabel-profile', 1, 'u_1', 'ws_b')
    , &.{});
    return .{ .db = db, .threaded = threaded };
}

fn teardown(ctx: *TestCtx) void {
    ctx.db.deinit();
    ctx.threaded.deinit();
}

test "run_session: a session_id alone resumes without fabricating a user turn" {
    var s = try setupDb();
    defer teardown(&s);
    const alloc = testing.allocator;

    var plan = try planRunSession(alloc, &s.db, "caller", .{ .session_id = "mate" });
    defer plan.deinit(alloc);

    try testing.expectEqual(RunMode.resumed, plan.mode);
    try testing.expect(plan.skip_initial_queue_message);
    try testing.expectEqualStrings("", plan.queue_message);
    // The run inherits the SESSION's own row — nothing is overridden.
    try testing.expectEqualStrings("mate", plan.session_id);
    try testing.expectEqualStrings("Sibling chat", plan.session_name);
    try testing.expectEqualStrings("/repos/alpha/sub", plan.cwd);
    try testing.expectEqualStrings("alpha-profile", plan.profile);
    try testing.expectEqualStrings("0", plan.is_auto_retry_until_stop);
    try testing.expectEqualStrings("u_1", plan.user_id);
    try testing.expectEqualStrings("ws_a", plan.workspace_id);
}

test "run_session: a session_id plus a message queues that message onto it" {
    var s = try setupDb();
    defer teardown(&s);
    const alloc = testing.allocator;

    var plan = try planRunSession(alloc, &s.db, "caller", .{
        .session_id = "mate",
        .message = "also update the docs",
    });
    defer plan.deinit(alloc);

    try testing.expectEqual(RunMode.sent, plan.mode);
    try testing.expect(!plan.skip_initial_queue_message);
    try testing.expectEqualStrings("also update the docs", plan.queue_message);
}

test "run_session: no session_id is refused, because it never creates a session" {
    var s = try setupDb();
    defer teardown(&s);
    const alloc = testing.allocator;

    try testing.expectError(error.SessionIdRequired, planRunSession(alloc, &s.db, "caller", .{}));
    // A message alone is NOT a start-a-new-session request.
    try testing.expectError(error.SessionIdRequired, planRunSession(alloc, &s.db, "caller", .{
        .message = "run the test suite",
    }));
    try testing.expect(std.mem.indexOf(u8, refusalMessage("session_id_required"), "never creates one") != null);
}

test "run_session: an unknown session_id is refused" {
    var s = try setupDb();
    defer teardown(&s);
    const alloc = testing.allocator;

    try testing.expectError(error.SessionNotFound, planRunSession(alloc, &s.db, "caller", .{
        .session_id = "sess_ghost",
    }));
}

test "run_session: a busy worker is refused instead of silently queueing" {
    var s = try setupDb();
    defer teardown(&s);
    const alloc = testing.allocator;

    try s.db.exec(alloc, "INSERT INTO worker (id, session_id) VALUES ('mate', 'mate')", &.{});

    try testing.expectError(error.WorkerAlreadyRunning, planRunSession(alloc, &s.db, "caller", .{
        .session_id = "mate",
    }));
    // SENDING to a busy session is refused too — the loop would swallow the
    // message into `session_queue_messages` and report nothing.
    try testing.expectError(error.WorkerAlreadyRunning, planRunSession(alloc, &s.db, "caller", .{
        .session_id = "mate",
        .message = "x",
    }));
}

test "run_session: another workspace's session is refused" {
    var s = try setupDb();
    defer teardown(&s);
    const alloc = testing.allocator;

    // `peer` lives in ws_b: not resumable, not sendable.
    try testing.expectError(error.CrossWorkspaceForbidden, planRunSession(alloc, &s.db, "caller", .{
        .session_id = "peer",
    }));
    try testing.expectError(error.CrossWorkspaceForbidden, planRunSession(alloc, &s.db, "caller", .{
        .session_id = "peer",
        .message = "hello",
    }));
}

test "run_session: an unresolvable caller cannot reach a peer (fail closed)" {
    var s = try setupDb();
    defer teardown(&s);
    const alloc = testing.allocator;

    try s.db.exec(alloc,
        \\INSERT INTO sessions (id, name, status, cwd, user_id) VALUES ('orphan', 'Orphan', 'active', '/nowhere', 'u_1')
    , &.{});

    try testing.expectError(error.CrossWorkspaceForbidden, planRunSession(alloc, &s.db, "orphan", .{
        .session_id = "mate",
    }));
    try testing.expectError(error.CrossWorkspaceForbidden, planRunSession(alloc, &s.db, "orphan", .{
        .session_id = "caller",
    }));
}

test "run_session: a session may start its OWN loop" {
    var s = try setupDb();
    defer teardown(&s);
    const alloc = testing.allocator;

    // Self-targeting is the one case that needs no workspace to compare: a
    // session is always in its own workspace.
    var plan = try planRunSession(alloc, &s.db, "caller", .{ .session_id = "caller" });
    defer plan.deinit(alloc);
    try testing.expectEqual(RunMode.resumed, plan.mode);

    var orphan = try setupDb();
    defer teardown(&orphan);
    try orphan.db.exec(alloc,
        \\INSERT INTO sessions (id, name, status, cwd, user_id) VALUES ('orphan', 'Orphan', 'active', '/nowhere', 'u_1')
    , &.{});
    var self = try planRunSession(alloc, &orphan.db, "orphan", .{ .session_id = "orphan" });
    defer self.deinit(alloc);
    try testing.expectEqual(RunMode.resumed, self.mode);
    try testing.expectEqualStrings("", self.workspace_id);
}

test "run_session: the schema requires a session_id and takes nothing else" {
    const tool = run_session_tool.function;
    try testing.expectEqualStrings("run_session", tool.name);
    try testing.expect(std.mem.indexOf(u8, tool.description, "It never creates a session") != null);
    try testing.expect(std.mem.indexOf(u8, tool.description, "EXISTING session") != null);
    try testing.expect(std.mem.indexOf(u8, tool.description, "ASYNCHRONOUS") != null);
    try testing.expect(std.mem.indexOf(u8, tool.description, "MAIN-AGENT-ONLY") != null);
    try testing.expect(std.mem.indexOf(u8, run_session_tool_system_prompt, "It never creates a session") != null);

    // Exactly two parameters, and no workspace selector: the workspace comes
    // from the session.
    const expected = [_][]const u8{ "session_id", "message" };
    try testing.expectEqual(expected.len, tool.parameters.properties.len);
    for (tool.parameters.properties, 0..) |p, i| {
        try testing.expectEqualStrings(expected[i], p.name);
        try testing.expect(p.description.len > 0);
        try testing.expect(!std.mem.eql(u8, p.name, "workspace_id"));
    }
    // `session_id` is REQUIRED — the tool has nothing to do without it.
    try testing.expectEqual(@as(usize, 1), tool.parameters.required.len);
    try testing.expectEqualStrings("session_id", tool.parameters.required[0]);

    // A budget on the tool-level text, which the model pays for on EVERY
    // request: it was rewritten once already for being too long.
    try testing.expect(tool.description.len <= 900);
}
