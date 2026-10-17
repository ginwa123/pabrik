const std = @import("std");
const schemas = @import("schemas.zig");
const AgentTool = schemas.AgentTool;
const pabrikcore = @import("pabrikcore");
const sqlite = pabrikcore.sqlite;
const workspace_scope = pabrikcore.workspace_scope;
const ask_user_pending = pabrikcore.ask_user_pending;
const helpers = @import("helpers");
const sanitize = helpers.sanitize_control_chars;
const is_worker_running = @import("../../../agentic_loop/is_worker_running.zig");

/// Input for run_session. `message` alone starts a NEW session; `session_id`
/// runs an EXISTING one (with `message` it is queued onto it instead).
pub const RunSessionInput = struct {
    /// Prompt for a NEW session, or a message to queue onto `session_id`.
    message: []const u8 = "",
    /// An existing session to run. Alone it resumes the agent with no new
    /// user turn.
    session_id: []const u8 = "",
    /// Your OWN workspace, for a NEW session. Accepted only as a restatement
    /// of it — naming any other workspace is a refusal.
    workspace_id: []const u8 = "",
    /// Case-insensitive alternative to `workspace_id`.
    workspace_name: []const u8 = "",
    /// Name of a NEW session. Default: derived from `message`.
    name: []const u8 = "",
    /// Absolute working directory for a NEW session. Default: the caller's
    /// workspace project path.
    cwd: []const u8 = "",
    /// LLM profile for a NEW session. Default: the target workspace's active
    /// profile — the loop resolves it from the session's own config scope.
    profile: []const u8 = "",
    /// CSV allowlist for a NEW session. Empty = every equipped tool.
    allowed_tools: []const u8 = "",
};

/// Which of the three behaviors the plan implements.
pub const RunMode = enum { started, sent, resumed };

/// Every way a call can be refused. Each one is a state the caller can act
/// on; none of them leaves a half-written session behind.
pub const RunSessionError = error{
    /// Neither `message` nor `session_id`.
    NothingToRun,
    /// Both `workspace_id` and `workspace_name`.
    AmbiguousWorkspace,
    /// A workspace target paired with an existing `session_id` — the session
    /// already has a workspace, so the target is a contradiction.
    WorkspaceTargetWithExistingSession,
    /// The target is outside the caller's own workspace: either another
    /// workspace named in a workspace selector, or a `session_id` that
    /// resolves to one.
    CrossWorkspaceForbidden,
    SessionNotFound,
    WorkerAlreadyRunning,
    WorkspaceNotFound,
    WorkspaceHasNoPath,
    NoWorkspace,
    CwdNotAbsolute,
};

/// A validated, ready-to-emit run. Owns `session_id`, `session_name`, `cwd`,
/// `profile`, `is_auto_retry_until_stop`, `user_id` and `workspace_id`;
/// `queue_message` and `allowed_tools` borrow the caller's input.
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
    allowed_tools: []const u8,
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
    \\Use `run_session` to start or resume an agent session IN YOUR OWN WORKSPACE.
    \\- `message` alone → START a new session in your workspace and run it on that prompt.
    \\- `session_id` alone → RESUME that session's agent with no new user turn.
    \\- `session_id` + `message` → send the message to that existing session and run it.
    \\- Your workspace is the only reachable one: a `session_id` that belongs to another workspace,
    \\  or a `workspace_id`/`workspace_name` that is not your own, is REFUSED.
    \\- The run is ASYNCHRONOUS: the call returns as soon as the run is scheduled, not when it ends.
    \\- A session that already has a worker running is REFUSED — never retried in a loop.
    \\
;

pub const run_session_tool = AgentTool{
    .type = "function",
    .function = .{
        .name = "run_session",
        .description =
        \\Start or resume an agent session, and return immediately.
        \\
        \\THREE BEHAVIORS (pick by params):
        \\- START (`message`, no `session_id`): create a NEW session in the target workspace and run it with `message` as the first user turn.
        \\- SEND (`session_id` + `message`): queue `message` onto that existing session and run it.
        \\- RESUME (`session_id` alone): run that existing session's agent with NO new user message.
        \\
        \\SAME WORKSPACE ONLY: the target is always YOUR workspace. A NEW session is created in it and runs in that workspace's project directory with its config, skills and secrets. `workspace_id`/`workspace_name` are accepted only as a restatement of your own workspace — naming another one is refused, and so is a `session_id` that lives in another workspace. Another workspace's session can never be reached or run from here. A workspace target is also refused alongside `session_id`: an existing session already has a workspace.
        \\
        \\ASYNCHRONOUS: the run is scheduled, not awaited. This call returns as soon as the run is queued — it does NOT wait for the agent to finish, and it does not report the result. Follow the run by reading the session later.
        \\
        \\REFUSALS (`success:false`, nothing started): a `session_id` or workspace target OUTSIDE your workspace; a session whose worker is already running (started, and NOT silently queued); an unknown `session_id`, `workspace_id` or `workspace_name`; a relative `cwd`; a workspace that owns no directory; a caller with no resolvable workspace; and both `workspace_id` and `workspace_name` at once.
        \\
        \\MAIN-AGENT-ONLY: never available to a sub-agent.
        \\
        \\Examples: {"message": "run the test suite and report failures"} · {"message": "fix the failing spec", "cwd": "/abs/path"} · {"session_id": "sess_42"} resume · {"session_id": "sess_42", "message": "also update the docs"} send.
        ,
        .parameters = .{
            .type = "object",
            .properties = &.{
                .{ .name = "message", .type = "string", .description = "Prompt for a NEW session (START), or a message to queue onto `session_id` (SEND)." },
                .{ .name = "session_id", .type = "string", .description = "Existing session to run. Must be in YOUR workspace or the call is refused. Alone it resumes with no new user turn." },
                .{ .name = "workspace_id", .type = "string", .description = "Your OWN workspace, for a NEW session. Naming any OTHER workspace is refused. Mutually exclusive with workspace_name and with session_id." },
                .{ .name = "workspace_name", .type = "string", .description = "Case-insensitive alternative to workspace_id; must also be your own workspace. Mutually exclusive with workspace_id and with session_id." },
                .{ .name = "name", .type = "string", .description = "Name for a NEW session. Default: derived from the first line of `message`." },
                .{ .name = "cwd", .type = "string", .description = "ABSOLUTE working directory for a NEW session. Default: your workspace's project path." },
                .{ .name = "profile", .type = "string", .description = "LLM profile name for a NEW session. Default: your workspace's active profile." },
                .{ .name = "allowed_tools", .type = "string", .description = "CSV allowlist for a NEW session. Omit or leave empty for every equipped tool." },
            },
            .required = &.{},
        },
        .system_prompt = run_session_tool_system_prompt,
    },
};

/// Starts of two sessions in the same nanosecond would collide otherwise.
var session_id_seq: std.atomic.Value(u64) = .init(0);

/// Distinct per call, unlike the second-resolution
/// `helpers.random.generateSessionId` (two starts inside one second would
/// return the same id and the second run would adopt the first session).
fn allocateSessionId(allocator: std.mem.Allocator) ![]u8 {
    const stamp = helpers.unixTimestampNanos();
    const seq = session_id_seq.fetchAdd(1, .monotonic);
    return std.fmt.allocPrint(allocator, "sess_{d}_{d}", .{ stamp, seq });
}

fn sessionExists(allocator: std.mem.Allocator, db: *sqlite.SqliteBackend, session_id: []const u8) !bool {
    var rows = try db.query(allocator, "SELECT 1 FROM sessions WHERE id = ? LIMIT 1", &.{session_id});
    defer rows.deinit();
    if (try rows.next()) |row| {
        defer row.deinit(allocator);
        return true;
    }
    return false;
}

fn workspaceExists(allocator: std.mem.Allocator, db: *sqlite.SqliteBackend, workspace_id: []const u8) !bool {
    var rows = try db.query(allocator, "SELECT 1 FROM workspaces WHERE id = ? LIMIT 1", &.{workspace_id});
    defer rows.deinit();
    if (try rows.next()) |row| {
        defer row.deinit(allocator);
        return true;
    }
    return false;
}

fn workspaceIdByName(allocator: std.mem.Allocator, db: *sqlite.SqliteBackend, name: []const u8) !?[]u8 {
    const trimmed = std.mem.trim(u8, name, " \t");
    if (trimmed.len == 0) return null;
    var rows = try db.query(
        allocator,
        "SELECT id FROM workspaces WHERE name = ? COLLATE NOCASE ORDER BY id ASC LIMIT 1",
        &.{trimmed},
    );
    defer rows.deinit();
    if (try rows.next()) |row| {
        defer row.deinit(allocator);
        if (row.values[0].len > 0) return try allocator.dupe(u8, row.values[0]);
    }
    return null;
}

fn workspaceName(allocator: std.mem.Allocator, db: *sqlite.SqliteBackend, workspace_id: []const u8) ![]u8 {
    if (workspace_id.len == 0) return allocator.dupe(u8, "");
    var rows = try db.query(allocator, "SELECT COALESCE(name, '') FROM workspaces WHERE id = ? LIMIT 1", &.{workspace_id});
    defer rows.deinit();
    if (try rows.next()) |row| {
        defer row.deinit(allocator);
        return try allocator.dupe(u8, row.values[0]);
    }
    return allocator.dupe(u8, "");
}

fn callerOwner(allocator: std.mem.Allocator, db: *sqlite.SqliteBackend, caller_session_id: []const u8) ![]u8 {
    if (caller_session_id.len == 0) return allocator.dupe(u8, "");
    var rows = try db.query(allocator, "SELECT COALESCE(user_id, '') FROM sessions WHERE id = ? LIMIT 1", &.{caller_session_id});
    defer rows.deinit();
    if (try rows.next()) |row| {
        defer row.deinit(allocator);
        return try allocator.dupe(u8, row.values[0]);
    }
    return allocator.dupe(u8, "");
}

/// The directory a NEW session in `workspace_id` runs in: the item flagged
/// `is_default`, else the item with the highest position that has a path.
fn workspaceProjectPath(allocator: std.mem.Allocator, db: *sqlite.SqliteBackend, workspace_id: []const u8) !?[]u8 {
    if (workspace_id.len == 0) return null;
    {
        var rows = try db.query(allocator,
            \\SELECT COALESCE(path, '') FROM workspace_items
            \\WHERE workspace_id = ? AND is_default = 1 AND COALESCE(path, '') != ''
            \\LIMIT 1
        , &.{workspace_id});
        defer rows.deinit();
        if (try rows.next()) |row| {
            defer row.deinit(allocator);
            if (row.values[0].len > 0) return try allocator.dupe(u8, row.values[0]);
        }
    }
    var rows = try db.query(allocator,
        \\SELECT COALESCE(path, '') FROM workspace_items
        \\WHERE workspace_id = ? AND COALESCE(path, '') != ''
        \\ORDER BY position DESC, id ASC LIMIT 1
    , &.{workspace_id});
    defer rows.deinit();
    if (try rows.next()) |row| {
        defer row.deinit(allocator);
        if (row.values[0].len > 0) return try allocator.dupe(u8, row.values[0]);
    }
    return null;
}

/// An absolute directory for the NEW session, or a refusal. `caller_cwd`
/// wins over `workspace_id`'s project path because it is where the caller
/// is already working.
fn resolveCwd(
    allocator: std.mem.Allocator,
    db: *sqlite.SqliteBackend,
    explicit: []const u8,
    caller_cwd: []const u8,
    workspace_id: []const u8,
) ![]u8 {
    if (explicit.len > 0) {
        if (!std.fs.path.isAbsolute(explicit)) return error.CwdNotAbsolute;
        return allocator.dupe(u8, explicit);
    }
    if (caller_cwd.len > 0 and std.fs.path.isAbsolute(caller_cwd)) {
        return allocator.dupe(u8, caller_cwd);
    }
    const from_workspace = try workspaceProjectPath(allocator, db, workspace_id);
    if (from_workspace) |p| {
        if (std.fs.path.isAbsolute(p)) return p;
        allocator.free(p);
    }
    return error.WorkspaceHasNoPath;
}

/// A display name for the NEW session: the explicit one, else the first line
/// of the message capped at 60 characters.
fn resolveSessionName(allocator: std.mem.Allocator, explicit: []const u8, message: []const u8) ![]u8 {
    if (explicit.len > 0) return allocator.dupe(u8, explicit);
    const trimmed = std.mem.trim(u8, message, " \t\r\n");
    const line_end = std.mem.indexOfAny(u8, trimmed, "\r\n") orelse trimmed.len;
    const line = std.mem.trim(u8, trimmed[0..line_end], " \t");
    if (line.len == 0) return allocator.dupe(u8, "New session");
    return allocator.dupe(u8, line[0..@min(line.len, 60)]);
}

/// Validate the call and resolve everything `App.emit_run_agent` needs. Pure
/// with respect to process state: it reads the database and writes nothing.
pub fn planRunSession(
    allocator: std.mem.Allocator,
    db: *sqlite.SqliteBackend,
    caller_session_id: []const u8,
    caller_cwd: []const u8,
    input: RunSessionInput,
) !RunPlan {
    if (input.workspace_id.len > 0 and input.workspace_name.len > 0) return error.AmbiguousWorkspace;

    const has_message = input.message.len > 0;
    const has_session = input.session_id.len > 0;
    if (!has_message and !has_session) return error.NothingToRun;

    if (has_session) return planExistingSession(allocator, db, caller_session_id, input, has_message);
    return planNewSession(allocator, db, caller_session_id, caller_cwd, input);
}

fn planExistingSession(
    allocator: std.mem.Allocator,
    db: *sqlite.SqliteBackend,
    caller_session_id: []const u8,
    input: RunSessionInput,
    has_message: bool,
) !RunPlan {
    if (input.workspace_id.len > 0 or input.workspace_name.len > 0) {
        return error.WorkspaceTargetWithExistingSession;
    }
    if (!try sessionExists(allocator, db, input.session_id)) return error.SessionNotFound;
    if (is_worker_running.isWorkerRunning(allocator, db, input.session_id)) return error.WorkerAlreadyRunning;
    // The same gate `read_workspace_session` uses: a session outside the
    // caller's workspace is never run. Fail CLOSED — an unresolvable pair
    // (a caller with no workspace) is not "same".
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
    const workspace_id = resolved orelse try allocator.dupe(u8, "");

    return .{
        .mode = if (has_message) .sent else .resumed,
        .session_id = session_id,
        .session_name = session_name,
        .cwd = cwd,
        .profile = profile,
        .is_auto_retry_until_stop = auto_retry,
        .user_id = user_id,
        .workspace_id = workspace_id,
        .queue_message = input.message,
        .allowed_tools = "",
        // RESUME must not fabricate a user turn; SEND already carries one.
        .skip_initial_queue_message = !has_message,
    };
}

fn planNewSession(
    allocator: std.mem.Allocator,
    db: *sqlite.SqliteBackend,
    caller_session_id: []const u8,
    caller_cwd: []const u8,
    input: RunSessionInput,
) !RunPlan {
    const caller_workspace = try workspace_scope.resolveWorkspaceId(allocator, db, caller_session_id);
    defer if (caller_workspace) |w| allocator.free(w);
    const own = caller_workspace orelse return error.NoWorkspace;

    // A workspace selector is a restatement of the caller's own workspace.
    // Naming a DIFFERENT one is the cross-workspace refusal.
    if (input.workspace_id.len > 0) {
        if (!try workspaceExists(allocator, db, input.workspace_id)) return error.WorkspaceNotFound;
        if (!std.mem.eql(u8, input.workspace_id, own)) return error.CrossWorkspaceForbidden;
    } else if (input.workspace_name.len > 0) {
        const named = (try workspaceIdByName(allocator, db, input.workspace_name)) orelse
            return error.WorkspaceNotFound;
        defer allocator.free(named);
        if (!std.mem.eql(u8, named, own)) return error.CrossWorkspaceForbidden;
    }

    const target_workspace_id = try allocator.dupe(u8, own);
    errdefer allocator.free(target_workspace_id);

    const cwd = try resolveCwd(allocator, db, input.cwd, caller_cwd, target_workspace_id);
    errdefer allocator.free(cwd);

    const session_id = try allocateSessionId(allocator);
    errdefer allocator.free(session_id);
    const session_name = try resolveSessionName(allocator, input.name, input.message);
    errdefer allocator.free(session_name);
    const profile = try allocator.dupe(u8, input.profile);
    errdefer allocator.free(profile);
    const user_id = try callerOwner(allocator, db, caller_session_id);
    errdefer allocator.free(user_id);

    return .{
        .mode = .started,
        .session_id = session_id,
        .session_name = session_name,
        .cwd = cwd,
        .profile = profile,
        // A run nobody asked to babysit must not retry forever by default.
        .is_auto_retry_until_stop = try allocator.dupe(u8, "0"),
        .user_id = user_id,
        .workspace_id = target_workspace_id,
        .queue_message = input.message,
        .allowed_tools = input.allowed_tools,
        .skip_initial_queue_message = false,
    };
}

/// The refusal code the LLM reads, plus one actionable sentence.
fn refusalMessage(code: []const u8) []const u8 {
    if (std.mem.eql(u8, code, "nothing_to_run")) return "Provide `message` to start a new session, or `session_id` to run an existing one.";    if (std.mem.eql(u8, code, "ambiguous_workspace")) return "Pass `workspace_id` OR `workspace_name`, not both.";
    if (std.mem.eql(u8, code, "cross_workspace_forbidden")) return "That target is outside YOUR workspace. `run_session` only reaches your own workspace — start or resume sessions in the workspace you are in.";
    if (std.mem.eql(u8, code, "workspace_target_with_existing_session")) return "`workspace_id`/`workspace_name` only restate your own workspace for a NEW session — drop them when you pass `session_id`.";
    if (std.mem.eql(u8, code, "session_not_found")) return "No session with that `session_id`.";
    if (std.mem.eql(u8, code, "worker_already_running")) return "That session is already running. Do not retry in a loop — wait for it, or start a different session.";
    if (std.mem.eql(u8, code, "workspace_not_found")) return "No workspace matches that id or name.";
    if (std.mem.eql(u8, code, "workspace_has_no_path")) return "That workspace owns no project directory, so there is no directory to run in. Pass an absolute `cwd`.";
    if (std.mem.eql(u8, code, "no_workspace")) return "Your session is not linked to any workspace — pass an explicit `workspace_id` or `cwd`.";
    if (std.mem.eql(u8, code, "cwd_not_absolute")) return "`cwd` must be an absolute path.";
    if (std.mem.eql(u8, code, "server_not_initialized")) return "The server singleton is unavailable, so no run can be scheduled right now.";
    return "Invalid run_session input.";
}

/// snake_case code for one refusal.
pub fn refusalCode(err: anyerror) []const u8 {
    return switch (err) {
        error.NothingToRun => "nothing_to_run",
        error.AmbiguousWorkspace => "ambiguous_workspace",
        error.WorkspaceTargetWithExistingSession => "workspace_target_with_existing_session",
        error.CrossWorkspaceForbidden => "cross_workspace_forbidden",
        error.SessionNotFound => "session_not_found",
        error.WorkerAlreadyRunning => "worker_already_running",
        error.WorkspaceNotFound => "workspace_not_found",
        error.WorkspaceHasNoPath => "workspace_has_no_path",
        error.NoWorkspace => "no_workspace",
        error.CwdNotAbsolute => "cwd_not_absolute",
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
const error_explain = @import("../../../agentic_loop/tools_error_explain.zig");
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

    var plan = planRunSession(ctx.allocator, ctx.db, ctx.session_id, ctx.cwd, parsed.value) catch |err| {
        ctx.logger.infoFmt("run_session: refused ({s})", .{@errorName(err)});
        return refused(ctx, tc, refusalCode(err));
    };
    defer plan.deinit(ctx.allocator);

    const di = exec_pabrikcore.getSingleton() catch {
        return refused(ctx, tc, "server_not_initialized");
    };

    // `workspace_id` is only sent for a NEW session: an existing row already
    // carries its workspace, and insert_worker must not rewrite it.
    const pin_workspace: []const u8 = if (plan.mode == .started) plan.workspace_id else "";

    di.emit_run_agent(.{
        .session_id = plan.session_id,
        .session_name = plan.session_name,
        .queue_message = plan.queue_message,
        .cwd = plan.cwd,
        .body_message = "",
        .allowed_tools = plan.allowed_tools,
        .image_urls = "",
        .video_urls = "",
        .selected_profile_model = plan.profile,
        .is_auto_retry_until_stop = plan.is_auto_retry_until_stop,
        .skip_initial_queue_message = plan.skip_initial_queue_message,
        .user_id = plan.user_id,
        .workspace_id = pin_workspace,
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
        .note = "The run was scheduled, not awaited — this call returns before the agent finishes. Read the session later for the outcome.",
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
    // `mate` is a sibling session inside the caller's own workspace (ws_a);
    // `peer` belongs to another workspace (ws_b) and must be unreachable.
    try db.exec(alloc,
        \\INSERT INTO sessions (id, name, status, cwd, selected_profile_model, is_auto_retry_until_stop, user_id, workspace_id)
        \\VALUES ('caller', 'Caller', 'active', '/repos/alpha', 'alpha-profile', 0, 'u_1', NULL),
        \\       ('mate', 'Mate', 'active', '/repos/alpha/sub', 'alpha-profile', 0, 'u_1', 'ws_a'),
        \\       ('peer', 'Peer', 'active', '/repos/kabelweb/sub', 'kabel-profile', 1, 'u_1', 'ws_b')
    , &.{});
    return .{ .db = db, .threaded = threaded };
}

fn teardown(ctx: *TestCtx) void {
    ctx.db.deinit();
    ctx.threaded.deinit();
}

test "run_session: a bare message starts a new session in the caller's own workspace" {
    var s = try setupDb();
    defer teardown(&s);
    const alloc = testing.allocator;

    var plan = try planRunSession(alloc, &s.db, "caller", "/repos/alpha", .{ .message = "fix the login bug" });
    defer plan.deinit(alloc);

    try testing.expectEqual(RunMode.started, plan.mode);
    try testing.expectEqualStrings("ws_a", plan.workspace_id);
    try testing.expectEqualStrings("/repos/alpha", plan.cwd);
    try testing.expectEqualStrings("fix the login bug", plan.queue_message);
    try testing.expectEqualStrings("fix the login bug", plan.session_name);
    try testing.expectEqualStrings("u_1", plan.user_id);
    try testing.expectEqualStrings("0", plan.is_auto_retry_until_stop);
    try testing.expect(plan.session_id.len > 0);
    try testing.expect(!plan.skip_initial_queue_message);
}

test "run_session: naming your OWN workspace explicitly is accepted" {
    var s = try setupDb();
    defer teardown(&s);
    const alloc = testing.allocator;

    var plan = try planRunSession(alloc, &s.db, "caller", "/repos/alpha", .{
        .message = "run the suite",
        .workspace_id = "ws_a",
    });
    defer plan.deinit(alloc);

    try testing.expectEqual(RunMode.started, plan.mode);
    try testing.expectEqualStrings("ws_a", plan.workspace_id);
    try testing.expectEqualStrings("/repos/alpha", plan.cwd);
}

test "run_session: another workspace's id or name is refused" {
    var s = try setupDb();
    defer teardown(&s);
    const alloc = testing.allocator;

    try testing.expectError(error.CrossWorkspaceForbidden, planRunSession(alloc, &s.db, "caller", "/repos/alpha", .{
        .message = "x",
        .workspace_id = "ws_b",
    }));
    try testing.expectError(error.CrossWorkspaceForbidden, planRunSession(alloc, &s.db, "caller", "/repos/alpha", .{
        .message = "x",
        .workspace_name = "kabelweb",
    }));
}

test "run_session: workspace_name resolves your own workspace case-insensitively" {
    var s = try setupDb();
    defer teardown(&s);
    const alloc = testing.allocator;

    // Stored as "Alpha"; the caller may write it any way it likes.
    var plan = try planRunSession(alloc, &s.db, "caller", "/repos/alpha", .{
        .message = "bump the pin",
        .workspace_name = "alpha",
    });
    defer plan.deinit(alloc);

    try testing.expectEqualStrings("ws_a", plan.workspace_id);
    try testing.expectEqualStrings("/repos/alpha", plan.cwd);
}

test "run_session: an unknown workspace is refused rather than retargeted" {
    var s = try setupDb();
    defer teardown(&s);
    const alloc = testing.allocator;

    try testing.expectError(error.WorkspaceNotFound, planRunSession(alloc, &s.db, "caller", "/repos/alpha", .{
        .message = "x",
        .workspace_name = "nope",
    }));
    try testing.expectError(error.WorkspaceNotFound, planRunSession(alloc, &s.db, "caller", "/repos/alpha", .{
        .message = "x",
        .workspace_id = "ws_ghost",
    }));
}

test "run_session: both workspace selectors at once is refused" {
    var s = try setupDb();
    defer teardown(&s);
    const alloc = testing.allocator;

    try testing.expectError(error.AmbiguousWorkspace, planRunSession(alloc, &s.db, "caller", "/repos/alpha", .{
        .message = "x",
        .workspace_id = "ws_a",
        .workspace_name = "Alpha",
    }));
}

test "run_session: neither message nor session_id is refused" {
    var s = try setupDb();
    defer teardown(&s);
    const alloc = testing.allocator;

    try testing.expectError(error.NothingToRun, planRunSession(alloc, &s.db, "caller", "/repos/alpha", .{}));
}

test "run_session: a session_id alone resumes without fabricating a user turn" {
    var s = try setupDb();
    defer teardown(&s);
    const alloc = testing.allocator;

    var plan = try planRunSession(alloc, &s.db, "caller", "/repos/alpha", .{ .session_id = "mate" });
    defer plan.deinit(alloc);

    try testing.expectEqual(RunMode.resumed, plan.mode);
    try testing.expect(plan.skip_initial_queue_message);
    try testing.expectEqualStrings("", plan.queue_message);
    // The run inherits the SESSION's own row, not the caller's.
    try testing.expectEqualStrings("Mate", plan.session_name);
    try testing.expectEqualStrings("/repos/alpha/sub", plan.cwd);
    try testing.expectEqualStrings("alpha-profile", plan.profile);
    try testing.expectEqualStrings("0", plan.is_auto_retry_until_stop);
    try testing.expectEqualStrings("ws_a", plan.workspace_id);
}

test "run_session: a session_id plus a message queues that message onto it" {
    var s = try setupDb();
    defer teardown(&s);
    const alloc = testing.allocator;

    var plan = try planRunSession(alloc, &s.db, "caller", "/repos/alpha", .{
        .session_id = "mate",
        .message = "also update the docs",
    });
    defer plan.deinit(alloc);

    try testing.expectEqual(RunMode.sent, plan.mode);
    try testing.expect(!plan.skip_initial_queue_message);
    try testing.expectEqualStrings("also update the docs", plan.queue_message);
}

test "run_session: another workspace's session_id is refused" {
    var s = try setupDb();
    defer teardown(&s);
    const alloc = testing.allocator;

    // `peer` lives in ws_b. Naming it must not run it, resume it, or accept
    // a message for it.
    try testing.expectError(error.CrossWorkspaceForbidden, planRunSession(alloc, &s.db, "caller", "/repos/alpha", .{
        .session_id = "peer",
    }));
    try testing.expectError(error.CrossWorkspaceForbidden, planRunSession(alloc, &s.db, "caller", "/repos/alpha", .{
        .session_id = "peer",
        .message = "hello",
    }));
}

test "run_session: a session with no resolvable workspace is refused for a peer too" {
    var s = try setupDb();
    defer teardown(&s);
    const alloc = testing.allocator;

    // `orphan` resolves to nothing, so a caller cannot prove it is the same
    // workspace — the gate fails closed, in both directions.
    try s.db.exec(alloc,
        \\INSERT INTO sessions (id, name, status, cwd, user_id) VALUES ('orphan', 'Orphan', 'active', '/nowhere', 'u_1')
    , &.{});

    try testing.expectError(error.CrossWorkspaceForbidden, planRunSession(alloc, &s.db, "caller", "/repos/alpha", .{
        .session_id = "orphan",
    }));
    try testing.expectError(error.CrossWorkspaceForbidden, planRunSession(alloc, &s.db, "orphan", "/nowhere", .{
        .session_id = "caller",
    }));
}

test "run_session: an unknown session_id is refused" {
    var s = try setupDb();
    defer teardown(&s);
    const alloc = testing.allocator;

    try testing.expectError(error.SessionNotFound, planRunSession(alloc, &s.db, "caller", "/repos/alpha", .{
        .session_id = "sess_ghost",
        .message = "x",
    }));
}

test "run_session: a busy worker is refused instead of silently queueing" {
    var s = try setupDb();
    defer teardown(&s);
    const alloc = testing.allocator;

    try s.db.exec(alloc, "INSERT INTO worker (id, session_id) VALUES ('mate', 'mate')", &.{});

    try testing.expectError(error.WorkerAlreadyRunning, planRunSession(alloc, &s.db, "caller", "/repos/alpha", .{
        .session_id = "mate",
    }));
    try testing.expectError(error.WorkerAlreadyRunning, planRunSession(alloc, &s.db, "caller", "/repos/alpha", .{
        .session_id = "mate",
        .message = "x",
    }));
}

test "run_session: a workspace target alongside a session_id is refused" {
    var s = try setupDb();
    defer teardown(&s);
    const alloc = testing.allocator;

    try testing.expectError(error.WorkspaceTargetWithExistingSession, planRunSession(alloc, &s.db, "caller", "/repos/alpha", .{
        .session_id = "mate",
        .workspace_id = "ws_a",
    }));
    try testing.expectError(error.WorkspaceTargetWithExistingSession, planRunSession(alloc, &s.db, "caller", "/repos/alpha", .{
        .session_id = "mate",
        .workspace_name = "Alpha",
    }));
}

test "run_session: a relative cwd is refused, an absolute one wins over the workspace default" {
    var s = try setupDb();
    defer teardown(&s);
    const alloc = testing.allocator;

    try testing.expectError(error.CwdNotAbsolute, planRunSession(alloc, &s.db, "caller", "/repos/alpha", .{
        .message = "x",
        .cwd = "relative/dir",
    }));

    var plan = try planRunSession(alloc, &s.db, "caller", "/repos/alpha", .{
        .message = "x",
        .workspace_id = "ws_a",
        .cwd = "/tmp/elsewhere",
    });
    defer plan.deinit(alloc);
    try testing.expectEqualStrings("/tmp/elsewhere", plan.cwd);
}

test "run_session: two starts in the same instant get distinct session ids" {
    var s = try setupDb();
    defer teardown(&s);
    const alloc = testing.allocator;

    var first = try planRunSession(alloc, &s.db, "caller", "/repos/alpha", .{ .message = "one" });
    defer first.deinit(alloc);
    var second = try planRunSession(alloc, &s.db, "caller", "/repos/alpha", .{ .message = "two" });
    defer second.deinit(alloc);

    try testing.expect(!std.mem.eql(u8, first.session_id, second.session_id));
}

test "run_session: an explicit name, profile and allowlist are used for the new session" {
    var s = try setupDb();
    defer teardown(&s);
    const alloc = testing.allocator;

    var plan = try planRunSession(alloc, &s.db, "caller", "/repos/alpha", .{
        .message = "long message\nsecond line",
        .name = "Pin bump",
        .profile = "muse auto",
        .allowed_tools = "read_file,search",
    });
    defer plan.deinit(alloc);

    try testing.expectEqualStrings("Pin bump", plan.session_name);
    try testing.expectEqualStrings("muse auto", plan.profile);
    try testing.expectEqualStrings("read_file,search", plan.allowed_tools);
}

test "run_session: the derived session name is the first line of the message, capped" {
    var s = try setupDb();
    defer teardown(&s);
    const alloc = testing.allocator;

    var multi = try planRunSession(alloc, &s.db, "caller", "/repos/alpha", .{
        .message = "first line\nsecond line",
    });
    defer multi.deinit(alloc);
    try testing.expectEqualStrings("first line", multi.session_name);

    var long = try planRunSession(alloc, &s.db, "caller", "/repos/alpha", .{
        .message = "0123456789012345678901234567890123456789012345678901234567890123456789",
    });
    defer long.deinit(alloc);
    try testing.expectEqual(@as(usize, 60), long.session_name.len);
}

test "run_session: a caller with no resolvable workspace is refused" {
    var s = try setupDb();
    defer teardown(&s);
    const alloc = testing.allocator;

    try s.db.exec(alloc,
        \\INSERT INTO sessions (id, name, status, cwd, user_id) VALUES ('orphan', 'Orphan', 'active', '/nowhere', 'u_1')
    , &.{});

    try testing.expectError(error.NoWorkspace, planRunSession(alloc, &s.db, "orphan", "/nowhere", .{ .message = "x" }));
}

test "run_session: a workspace with no project directory is refused" {
    var s = try setupDb();
    defer teardown(&s);
    const alloc = testing.allocator;

    // The CALLER's own workspace, task-linked, whose only item has no path:
    // there is no directory to run a new session in.
    try s.db.exec(alloc, "INSERT INTO workspaces (id, name) VALUES ('ws_bare', 'Bare')", &.{});
    try s.db.exec(alloc,
        \\INSERT INTO workspace_items (id, workspace_id, item_type, name, path, position, is_default)
        \\VALUES ('item_bare', 'ws_bare', 'folder', 'Code', '', 1, 1)
    , &.{});
    try s.db.exec(alloc, "INSERT INTO workspace_item_tasks (id, name, workspace_item_id) VALUES ('bare_task', 'T', 'item_bare')", &.{});
    try s.db.exec(alloc, "INSERT INTO sessions (id, name, status, cwd, user_id) VALUES ('bare_task', 'Bare caller', 'active', '', 'u_1')", &.{});

    try testing.expectError(error.WorkspaceHasNoPath, planRunSession(alloc, &s.db, "bare_task", "", .{
        .message = "x",
    }));
}

test "run_session: a workspace with only a non-default item still resolves its path" {
    var s = try setupDb();
    defer teardown(&s);
    const alloc = testing.allocator;

    try s.db.exec(alloc, "INSERT INTO workspaces (id, name) VALUES ('ws_plain', 'Plain')", &.{});
    try s.db.exec(alloc,
        \\INSERT INTO workspace_items (id, workspace_id, item_type, name, path, position, is_default)
        \\VALUES ('item_p', 'ws_plain', 'folder', 'Code', '/repos/plain', 2, 0)
    , &.{});
    try s.db.exec(alloc, "INSERT INTO workspace_item_tasks (id, name, workspace_item_id) VALUES ('plain_task', 'T', 'item_p')", &.{});
    try s.db.exec(alloc, "INSERT INTO sessions (id, name, status, cwd, user_id) VALUES ('plain_task', 'Plain caller', 'active', '', 'u_1')", &.{});

    var plan = try planRunSession(alloc, &s.db, "plain_task", "", .{ .message = "x" });
    defer plan.deinit(alloc);
    try testing.expectEqualStrings("ws_plain", plan.workspace_id);
    try testing.expectEqualStrings("/repos/plain", plan.cwd);
}

test "run_session: a refusal renders the code and an actionable sentence" {
    const alloc = testing.allocator;
    try testing.expectEqualStrings("worker_already_running", refusalCode(error.WorkerAlreadyRunning));
    try testing.expectEqualStrings("nothing_to_run", refusalCode(error.NothingToRun));
    try testing.expectEqualStrings("cwd_not_absolute", refusalCode(error.CwdNotAbsolute));
    try testing.expectEqualStrings("cross_workspace_forbidden", refusalCode(error.CrossWorkspaceForbidden));
    try testing.expectEqualStrings("run_session_failed", refusalCode(error.Unexpected));

    const out = try refusalJSON(alloc, "worker_already_running", refusalMessage("worker_already_running"));
    defer alloc.free(out);
    const parsed = try parseTestJson(alloc, out);
    defer parsed.deinit();
    try testing.expect(!parsed.value.object.get("success").?.bool);
    try testing.expectEqualStrings("worker_already_running", parsed.value.object.get("error").?.string);
    try testing.expect(std.mem.indexOf(u8, parsed.value.object.get("message").?.string, "already running") != null);
}

test "run_session: the schema and prompt teach the same-workspace rule" {
    const tool = run_session_tool.function;
    try testing.expectEqualStrings("run_session", tool.name);
    try testing.expect(std.mem.indexOf(u8, tool.description, "SAME WORKSPACE ONLY") != null);
    try testing.expect(std.mem.indexOf(u8, tool.description, "ASYNCHRONOUS") != null);
    try testing.expect(std.mem.indexOf(u8, run_session_tool_system_prompt, "IN YOUR OWN WORKSPACE") != null);

    var saw_id = false;
    var saw_name = false;
    for (tool.parameters.properties) |p| {
        if (std.mem.eql(u8, p.name, "workspace_id")) {
            saw_id = true;
            // The refusal is only discoverable if the parameter says so.
            try testing.expect(std.mem.indexOf(u8, p.description, "refused") != null);
        }
        if (std.mem.eql(u8, p.name, "workspace_name")) saw_name = true;
        if (std.mem.eql(u8, p.name, "session_id")) {
            try testing.expect(std.mem.indexOf(u8, p.description, "YOUR workspace") != null);
        }
    }
    try testing.expect(saw_id);
    try testing.expect(saw_name);
    // Optional on purpose: a session_id-only call must still be a legal body.
    try testing.expectEqual(@as(usize, 0), tool.parameters.required.len);
}
