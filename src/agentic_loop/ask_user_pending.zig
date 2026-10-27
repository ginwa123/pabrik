//! `ask_user` state + the answer round-trip. The `ask_user` tool does NOT
//! block the agentic loop.

const std = @import("std");
const pabrikcore = @import("pabrikcore");
const test_db = pabrikcore.test_db;

const sqlite = pabrikcore.sqlite;
const database = pabrikcore.database;
const llm_history = pabrikcore.llm_history;
const ask_user_mod = pabrikcore.ask_user;
const wrapToolOutput = @import("../modules/agent/tools/tools_wrap_output.zig").wrapToolOutput;
const on_event_sent = @import("on_event_sent.zig");
const is_worker_running = @import("is_worker_running.zig");
const testing = std.testing;

const Status = ask_user_mod.Status;

/// One row of `session_pending_question`. Owned strings; `deinit` frees.
pub const PendingQuestion = struct {
    id: []const u8,
    session_id: []const u8,
    tool_call_id: []const u8,
    llm_history_id: []const u8,
    question: []const u8,
    multi_select: bool,
    status: []const u8,
    /// COALESCEd to "" on read — an empty answer is never stored (validation
    /// rejects it), so "" here means "not answered yet".
    answer: []const u8,

    pub fn deinit(self: *const PendingQuestion, allocator: std.mem.Allocator) void {
        allocator.free(self.id);
        allocator.free(self.session_id);
        allocator.free(self.tool_call_id);
        allocator.free(self.llm_history_id);
        allocator.free(self.question);
        allocator.free(self.status);
        allocator.free(self.answer);
    }
};

/// `q_<nanoseconds>` — same shape as the other row ids in this codebase
/// (`at_<nanos>`, `sess_<nanos>`).
pub fn newQuestionId(allocator: std.mem.Allocator, io: std.Io) ![]u8 {
    return std.fmt.allocPrint(allocator, "q_{d}", .{std.Io.Timestamp.now(io, .real).nanoseconds});
}

/// `Backend.exec` binds every argument as a string; SQLite's column
/// affinity converts it for INTEGER columns. Keeping this in one place means
/// no call site has to remember the cast.
fn intArg(allocator: std.mem.Allocator, v: i64) ![]u8 {
    return std.fmt.allocPrint(allocator, "{d}", .{v});
}

pub const InsertQuestionInput = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    db: *database.Db,
    session_id: []const u8,
    tool_call_id: []const u8,
    llm_history_id: []const u8,
    question: []const u8,
    /// Whether the human may pick several options (Migration 088's
    /// `multi_select` column) — the answer endpoint validates the wire shape
    /// against it.
    multi_select: bool = false,
    /// Optional pre-generated id (tests pass a fixed one). Generated when null.
    id: ?[]const u8 = null,
};

/// Insert the pending row and return its id (caller-owned).
pub fn insertPendingQuestion(input: InsertQuestionInput) ![]u8 {
    const allocator = input.allocator;
    const id_owned: ?[]u8 = if (input.id) |given| try allocator.dupe(u8, given) else null;
    defer if (id_owned) |s| allocator.free(s);
    const id = id_owned orelse try newQuestionId(allocator, input.io);
    defer if (id_owned == null) allocator.free(id);

    const created_at = try intArg(allocator, @intCast(std.Io.Timestamp.now(input.io, .real).nanoseconds));
    defer allocator.free(created_at);

    try input.db.exec(
        allocator,
        \\INSERT OR IGNORE INTO session_pending_question
        \\    (id, session_id, tool_call_id, llm_history_id, question, multi_select, status, answer, created_at, resolved_at)
        \\VALUES (?, ?, ?, ?, ?, ?, ?, NULL, ?, NULL)
    ,
        &.{
            id,
            input.session_id,
            input.tool_call_id,
            input.llm_history_id,
            input.question,
            if (input.multi_select) "1" else "0",
            Status.pending.to_str(),
            created_at,
        },
    );

    // Whether we inserted or the OR IGNORE skipped an existing row, the
    // authoritative id is whatever the tool_call_id now resolves to.
    if (try getPendingQuestionByToolCall(allocator, input.db, input.session_id, input.tool_call_id)) |existing| {
        defer existing.deinit(allocator);
        return allocator.dupe(u8, existing.id);
    }
    return allocator.dupe(u8, id);
}

const SELECT_COLUMNS =
    \\SELECT id, session_id, tool_call_id, llm_history_id, question, COALESCE(multi_select, 0), status, COALESCE(answer, '')
    \\FROM session_pending_question
;

fn rowToQuestion(row: anytype, allocator: std.mem.Allocator) !PendingQuestion {
    return .{
        .id = try allocator.dupe(u8, row.values[0]),
        .session_id = try allocator.dupe(u8, row.values[1]),
        .tool_call_id = try allocator.dupe(u8, row.values[2]),
        .llm_history_id = try allocator.dupe(u8, row.values[3]),
        .question = try allocator.dupe(u8, row.values[4]),
        .multi_select = !std.mem.eql(u8, row.values[5], "0"),
        .status = try allocator.dupe(u8, row.values[6]),
        .answer = try allocator.dupe(u8, row.values[7]),
    };
}

/// Look up by question id. Caller frees via `deinit`.
pub fn getPendingQuestion(
    allocator: std.mem.Allocator,
    db: *database.Db,
    question_id: []const u8,
) !?PendingQuestion {
    const sql = SELECT_COLUMNS ++ " WHERE id = ? LIMIT 1";
    var rows = try db.query(allocator, sql, &.{question_id});
    defer rows.deinit();
    if (try rows.next()) |row| {
        defer row.deinit(allocator);
        return try rowToQuestion(row, allocator);
    }
    return null;
}

/// Look up by (session, tool call). The fallback key for a client that only
/// has the tool row in hand (the card's `tool_call_id`).
pub fn getPendingQuestionByToolCall(
    allocator: std.mem.Allocator,
    db: *database.Db,
    session_id: []const u8,
    tool_call_id: []const u8,
) !?PendingQuestion {
    const sql = SELECT_COLUMNS ++ " WHERE session_id = ? AND tool_call_id = ? LIMIT 1";
    var rows = try db.query(allocator, sql, &.{ session_id, tool_call_id });
    defer rows.deinit();
    if (try rows.next()) |row| {
        defer row.deinit(allocator);
        return try rowToQuestion(row, allocator);
    }
    return null;
}

/// Move a question to a terminal (or back to pending) status. `answer` is
/// stored only when non-null and non-empty.
pub fn markQuestionStatus(
    allocator: std.mem.Allocator,
    io: std.Io,
    db: *database.Db,
    question_id: []const u8,
    status: Status,
    answer: ?[]const u8,
) !void {
    const resolved_at = try intArg(allocator, @intCast(std.Io.Timestamp.now(io, .real).nanoseconds));
    defer allocator.free(resolved_at);

    if (status == .pending) {
        try db.exec(
            allocator,
            "UPDATE session_pending_question SET status = ?, answer = NULL, resolved_at = NULL WHERE id = ?",
            &.{ status.to_str(), question_id },
        );
        return;
    }

    try db.exec(
        allocator,
        "UPDATE session_pending_question SET status = ?, answer = ?, resolved_at = ? WHERE id = ?",
        &.{
            status.to_str(),
            answer orelse "",
            resolved_at,
            question_id,
        },
    );
}

/// Resolve every still-pending question for a session as `abandoned`.
pub fn markAbandonedForSession(
    allocator: std.mem.Allocator,
    io: std.Io,
    db: *database.Db,
    session_id: []const u8,
) !usize {
    const pending = Status.pending.to_str();
    const abandoned = Status.abandoned.to_str();
    const resolved_at = try intArg(allocator, @intCast(std.Io.Timestamp.now(io, .real).nanoseconds));
    defer allocator.free(resolved_at);

    // Count first — after the UPDATE the rows are indistinguishable from
    // questions abandoned earlier in the session's life.
    var changed: usize = 0;
    {
        var rows = try db.query(
            allocator,
            "SELECT COUNT(*) FROM session_pending_question WHERE session_id = ? AND status = ?",
            &.{ session_id, pending },
        );
        defer rows.deinit();
        if (try rows.next()) |row| {
            defer row.deinit(allocator);
            changed = std.fmt.parseInt(usize, row.values[0], 10) catch 0;
        }
    }
    if (changed == 0) return 0;

    try db.exec(
        allocator,
        "UPDATE session_pending_question SET status = ?, resolved_at = ? WHERE session_id = ? AND status = ?",
        &.{
            abandoned,
            resolved_at,
            session_id,
            pending,
        },
    );
    return changed;
}

/// The hot-path predicate: is this session waiting on the human? Called at
/// the top of every agentic-loop iteration and before every user-initiated
/// run.
pub fn hasPendingQuestion(
    allocator: std.mem.Allocator,
    db: *database.Db,
    session_id: []const u8,
) bool {
    const sql = "SELECT 1 FROM session_pending_question WHERE session_id = ? AND status = 'pending' LIMIT 1";
    var rows = db.query(allocator, sql, &.{session_id}) catch return false;
    defer rows.deinit();
    if (rows.next() catch return false) |row| {
        defer row.deinit(allocator);
        return true;
    }
    return false;
}

/// Settle every pending question for a session as `abandoned`, rewriting each
/// question's tool-result row so the model reads "the human moved on" instead
/// of `<status>pending</status>`.
pub fn abandonPendingQuestions(
    allocator: std.mem.Allocator,
    io: std.Io,
    db: *database.Db,
    session_id: []const u8,
) !usize {
    // `listRecentQuestions` returns pending rows (always) plus rows resolved
    // in the last minute; we only settle the pending ones.
    const all = try listRecentQuestions(allocator, io, db, session_id);
    defer {
        for (all) |q| q.deinit(allocator);
        allocator.free(all);
    }

    var settled: usize = 0;
    for (all) |q| {
        if (!std.mem.eql(u8, q.status, Status.pending.to_str())) continue;

        try markQuestionStatus(allocator, io, db, q.id, .abandoned, null);

        const inner = try ask_user_mod.buildAskUserJson(allocator, .{
            .status = .abandoned,
            .question_id = q.id,
            .question = q.question,
        });
        defer allocator.free(inner);

        try rewriteToolResultRow(.{
            .allocator = allocator,
            .io = io,
            .db = db,
            .session_id = session_id,
            .llm_history_id = q.llm_history_id,
            .inner = inner,
        });
        settled += 1;
    }
    return settled;
}

/// All questions the frontend still needs for a session: everything pending
/// (answered whenever), plus rows resolved in the last minute so a card that
/// was just answered rehydrates in its resolved state after a reload.
pub fn listRecentQuestions(
    allocator: std.mem.Allocator,
    io: std.Io,
    db: *database.Db,
    session_id: []const u8,
) ![]PendingQuestion {
    const cutoff = try intArg(allocator, @intCast(std.Io.Timestamp.now(io, .real).nanoseconds - std.time.ns_per_min));
    defer allocator.free(cutoff);
    // `Backend` binds every argument as TEXT, so a bare `?` next to an
    // INTEGER expression has no column affinity on either side — and SQLite
    // orders INTEGER before TEXT, making `resolved_at >= '1789…'` always
    const sql = SELECT_COLUMNS ++
        " WHERE session_id = ? AND (status = 'pending' OR COALESCE(resolved_at, 0) >= CAST(? AS INTEGER)) ORDER BY created_at ASC";
    var rows = try db.query(allocator, sql, &.{ session_id, cutoff });
    defer rows.deinit();

    var out: std.ArrayList(PendingQuestion) = .empty;
    errdefer {
        for (out.items) |q| q.deinit(allocator);
        out.deinit(allocator);
    }
    while (try rows.next()) |row| {
        defer row.deinit(allocator);
        try out.append(allocator, try rowToQuestion(row, allocator));
    }
    return out.toOwnedSlice(allocator);
}

// ============================================================================
// The answer round-trip
// ============================================================================

pub const RewriteToolResultInput = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    db: *database.Db,
    session_id: []const u8,
    /// The `llm_history` row to overwrite (the `ask_user` tool result).
    llm_history_id: []const u8,
    /// The JSON `data` payload for the resolved status. The outer JSON
    /// envelope is built here via the shared `wrapToolOutput` so callers
    /// cannot get the envelope shape wrong.
    inner: []const u8,
};

/// Read a row's `response_content` (owned). Null when the row is gone.
fn readRowContent(
    allocator: std.mem.Allocator,
    db: *database.Db,
    row_id: []const u8,
) !?[]u8 {
    var rows = try db.query(
        allocator,
        "SELECT COALESCE(response_content, '') FROM llm_history WHERE id = ? LIMIT 1",
        &.{row_id},
    );
    defer rows.deinit();
    if (try rows.next()) |row| {
        defer row.deinit(allocator);
        return try allocator.dupe(u8, row.values[0]);
    }
    return null;
}

/// Lift the `parameters` object out of an existing JSON tool envelope and
/// return it as a JSON string so a rewrite can re-emit it. Missing, null,
/// or non-JSON input means empty args (`{}`).
fn extractParametersJson(allocator: std.mem.Allocator, content: []const u8) ![]u8 {
    const trimmed = std.mem.trim(u8, content, " \t\r\n");
    const parsed = std.json.parseFromSlice(std.json.Value, allocator, trimmed, .{}) catch {
        return allocator.dupe(u8, "{}");
    };
    defer parsed.deinit();
    if (parsed.value != .object) return allocator.dupe(u8, "{}");
    const params = parsed.value.object.get("parameters") orelse return allocator.dupe(u8, "{}");
    if (params == .null) return allocator.dupe(u8, "{}");
    return std.json.Stringify.valueAlloc(allocator, params, .{});
}

/// Step 2 of the answer round-trip: overwrite the tool-result row in place
/// with the resolved envelope and push the row's SSE update so an open
/// `ChatView` flips the card without a reload.
pub fn rewriteToolResultRow(input: RewriteToolResultInput) !void {
    const allocator = input.allocator;

    const previous = try readRowContent(allocator, input.db, input.llm_history_id);
    defer if (previous) |p| allocator.free(p);

    const params = try extractParametersJson(allocator, previous orelse "");
    defer allocator.free(params);

    const envelope = try wrapToolOutput(allocator, ask_user_mod.ASK_USER_TOOL_NAME, params, true, null, input.inner);
    defer allocator.free(envelope);

    try llm_history.updateToolResultById(allocator, input.io, input.db, input.llm_history_id, .{
        .content = envelope,
        .diffview_before = null,
        .diffview_after = null,
    });

    emitRowById(allocator, input.db, input.session_id, input.llm_history_id);
}

/// Emit the `llm_full` frame for one `llm_history` row.
fn emitRowById(
    allocator: std.mem.Allocator,
    db: *database.Db,
    session_id: []const u8,
    id: []const u8,
) void {
    // Owned by `getMessageById`; freed below.
    const msg = llm_history.getMessageById(allocator, db, session_id, id) catch return;
    if (msg == null) return;
    const m = msg.?;
    defer {
        allocator.free(m.id);
        allocator.free(m.session_id);
        allocator.free(m.model);
        allocator.free(m.created_at);
        allocator.free(m.response_content);
        allocator.free(m.finish_reason);
        allocator.free(m.role);
        allocator.free(m.tools);
        if (m.reasoning_content) |r| allocator.free(r);
        allocator.free(m.agent);
        allocator.free(m.session_name);
        allocator.free(m.tool_name);
        if (m.parent_session_id) |p| allocator.free(p);
        if (m.diffview_before) |d| allocator.free(d);
        if (m.diffview_after) |d| allocator.free(d);
        if (m.image_urls) |urls| {
            for (urls) |u| allocator.free(u);
            allocator.free(urls);
        }
        if (m.tool_call_id) |t| allocator.free(t);
    }

    on_event_sent.onEventSendLLMHistory(allocator, .{
        .id = m.id,
        .session_id = m.session_id,
        .model = m.model,
        .cwd = "",
        .content = m.response_content,
        .reasoning_content = m.reasoning_content,
        .role = m.role,
        .finish_reason = m.finish_reason,
        .tool_calls_json = null,
        .tool_call_id = m.tool_call_id orelse m.id,
        .tool_name = m.tool_name,
        .agent_name = m.agent,
        .loop_index = m.loop_index,
        .temperature = m.temperature,
        .is_thinking = m.is_thinking,
        .is_input = false,
        .is_output = true,
        .parent_session_id = m.parent_session_id,
        .parent_id = session_id,
        .diffview_before = m.diffview_before,
        .diffview_after = m.diffview_after,
        .total_tokens = m.total_tokens,
        .image_url = null,
        .session_skills = null,
    }) catch |err| {
        std.log.warn("ask_user: SSE emit for row {s} failed: {s}", .{ m.id, @errorName(err) });
    };
}

pub const SessionRunFields = struct {
    name: []const u8,
    cwd: []const u8,
    selected_profile_model: []const u8,
    is_auto_retry_until_stop: []const u8,
    /// Owning user id (`COALESCE(user_id, '')`).
    user_id: []const u8,

    pub fn deinit(self: *const SessionRunFields, allocator: std.mem.Allocator) void {
        allocator.free(self.name);
        allocator.free(self.cwd);
        allocator.free(self.selected_profile_model);
        allocator.free(self.is_auto_retry_until_stop);
        allocator.free(self.user_id);
    }
};

/// Read the `sessions` columns `emit_run_agent` needs. Missing row → safe
/// empty defaults (`insert_worker` upserts the session anyway), matching
/// `start_agent.zig` step 3 / `wakeSessionForCompletion`.
pub fn loadSessionRunFields(
    allocator: std.mem.Allocator,
    db: *database.Db,
    session_id: []const u8,
) !SessionRunFields {
    var rows = try db.query(
        allocator,
        "SELECT COALESCE(name, ''), COALESCE(cwd, ''), COALESCE(selected_profile_model, ''), COALESCE(is_auto_retry_until_stop, '0'), COALESCE(user_id, '') FROM sessions WHERE id = ?",
        &.{session_id},
    );
    defer rows.deinit();
    if (try rows.next()) |row| {
        defer row.deinit(allocator);
        return .{
            .name = try allocator.dupe(u8, row.values[0]),
            .cwd = try allocator.dupe(u8, row.values[1]),
            .selected_profile_model = try allocator.dupe(u8, row.values[2]),
            .is_auto_retry_until_stop = try allocator.dupe(u8, row.values[3]),
            .user_id = try allocator.dupe(u8, row.values[4]),
        };
    }
    return .{
        .name = try allocator.dupe(u8, ""),
        .cwd = try allocator.dupe(u8, ""),
        .selected_profile_model = try allocator.dupe(u8, ""),
        .is_auto_retry_until_stop = try allocator.dupe(u8, "0"),
        .user_id = try allocator.dupe(u8, ""),
    };
}

/// Step 3 of the answer round-trip: resume the conversation.
pub fn resumeSession(
    di: *pabrikcore.App,
    allocator: std.mem.Allocator,
    session_id: []const u8,
) !bool {
    if (is_worker_running.isWorkerRunning(allocator, di.db, session_id)) return false;

    const fields = try loadSessionRunFields(allocator, di.db, session_id);
    defer fields.deinit(allocator);

    try di.emit_run_agent(.{
        .session_id = session_id,
        .session_name = fields.name,
        .queue_message = "",
        .cwd = fields.cwd,
        .body_message = "",
        .allowed_tools = "",
        .image_urls = "",
        .selected_profile_model = fields.selected_profile_model,
        .is_auto_retry_until_stop = fields.is_auto_retry_until_stop,
        .skip_initial_queue_message = true,
        // Preserve the session's owner so the worker's upsert keeps the
        // row owned under `--auth` (plan 2026-09-25).
        .user_id = fields.user_id,
    });
    return true;
}

// ============================================================================
// Tests
// ============================================================================

fn setupDb() !struct { db: database.Db, threaded: std.Io.Threaded } {
    const alloc = testing.allocator;
    var threaded = std.Io.Threaded.init(alloc, .{});
    errdefer threaded.deinit();
    const io = threaded.io();
    var db: database.Db = .{};
    errdefer db.deinit();
    try test_db.openMemory(&db, io);
    // The Migration 088 shape: `answer` / `resolved_at` NULL-able on purpose.
    try db.exec(alloc,
        \\CREATE TABLE session_pending_question (
        \\    id TEXT PRIMARY KEY,
        \\    session_id TEXT NOT NULL,
        \\    tool_call_id TEXT NOT NULL,
        \\    llm_history_id TEXT NOT NULL,
        \\    question TEXT NOT NULL,
        \\    multi_select INTEGER NOT NULL DEFAULT 0,
        \\    status TEXT NOT NULL DEFAULT 'pending',
        \\    answer TEXT,
        \\    created_at INTEGER NOT NULL,
        \\    resolved_at INTEGER
        \\)
    , &.{});
    try db.exec(
        alloc,
        "CREATE UNIQUE INDEX idx_spq_tool_call ON session_pending_question(tool_call_id)",
        &.{},
    );
    try db.exec(
        alloc,
        "CREATE INDEX idx_spq_session_status ON session_pending_question(session_id, status)",
        &.{},
    );
    return .{ .db = db, .threaded = threaded };
}

fn insertOne(s: anytype, id: []const u8, session: []const u8, tool_call: []const u8) ![]u8 {
    return insertPendingQuestion(.{
        .allocator = testing.allocator,
        .io = s.threaded.io(),
        .db = &s.db,
        .session_id = session,
        .tool_call_id = tool_call,
        .llm_history_id = "row_1",
        .question = "Which environment?",
        .id = id,
    });
}

test "ask_user_pending: insert + read back, with a NULL answer coalesced to empty" {
    var s = try setupDb();
    defer s.db.deinit();
    defer s.threaded.deinit();

    const id = try insertOne(&s, "q_1", "s1", "call_1");
    defer testing.allocator.free(id);
    try testing.expectEqualStrings("q_1", id);

    const q = (try getPendingQuestion(testing.allocator, &s.db, "q_1")).?;
    defer q.deinit(testing.allocator);
    try testing.expectEqualStrings("s1", q.session_id);
    try testing.expectEqualStrings("call_1", q.tool_call_id);
    try testing.expectEqualStrings("row_1", q.llm_history_id);
    try testing.expectEqualStrings("Which environment?", q.question);
    try testing.expectEqualStrings("pending", q.status);
    // The empty-slice-binds-as-NULL guard: NULL round-trips as "", not a crash.
    try testing.expectEqualStrings("", q.answer);
}

test "ask_user_pending: hasPendingQuestion tracks the status" {
    var s = try setupDb();
    defer s.db.deinit();
    defer s.threaded.deinit();
    const a = testing.allocator;

    try testing.expect(!hasPendingQuestion(a, &s.db, "s1"));

    const id = try insertOne(&s, "q_1", "s1", "call_1");
    defer a.free(id);
    try testing.expect(hasPendingQuestion(a, &s.db, "s1"));
    // Session scoping.
    try testing.expect(!hasPendingQuestion(a, &s.db, "s2"));

    try markQuestionStatus(a, s.threaded.io(), &s.db, "q_1", .answered, "staging");
    try testing.expect(!hasPendingQuestion(a, &s.db, "s1"));
}

test "ask_user_pending: answering stores the value and clears pending" {
    var s = try setupDb();
    defer s.db.deinit();
    defer s.threaded.deinit();
    const a = testing.allocator;

    const id = try insertOne(&s, "q_1", "s1", "call_1");
    defer a.free(id);
    try markQuestionStatus(a, s.threaded.io(), &s.db, "q_1", .answered, "staging");

    const q = (try getPendingQuestion(a, &s.db, "q_1")).?;
    defer q.deinit(a);
    try testing.expectEqualStrings("answered", q.status);
    try testing.expectEqualStrings("staging", q.answer);
    try testing.expect(!hasPendingQuestion(a, &s.db, "s1"));
}

test "ask_user_pending: skipped and abandoned are distinct statuses" {
    var s = try setupDb();
    defer s.db.deinit();
    defer s.threaded.deinit();
    const a = testing.allocator;

    const id1 = try insertOne(&s, "q_1", "s1", "call_1");
    defer a.free(id1);
    try markQuestionStatus(a, s.threaded.io(), &s.db, "q_1", .skipped, null);
    const q1 = (try getPendingQuestion(a, &s.db, "q_1")).?;
    defer q1.deinit(a);
    try testing.expectEqualStrings("skipped", q1.status);

    const id2 = try insertOne(&s, "q_2", "s1", "call_2");
    defer a.free(id2);
    try markQuestionStatus(a, s.threaded.io(), &s.db, "q_2", .abandoned, null);
    const q2 = (try getPendingQuestion(a, &s.db, "q_2")).?;
    defer q2.deinit(a);
    try testing.expectEqualStrings("abandoned", q2.status);
}

test "ask_user_pending: UNIQUE(tool_call_id) makes a re-exec idempotent" {
    var s = try setupDb();
    defer s.db.deinit();
    defer s.threaded.deinit();
    const a = testing.allocator;

    const first = try insertOne(&s, "q_1", "s1", "call_1");
    defer a.free(first);
    // A retry of the same tool call, even with a different proposed id,
    // must resolve to the row that already exists.
    const second = try insertOne(&s, "q_2", "s1", "call_1");
    defer a.free(second);
    try testing.expectEqualStrings("q_1", second);

    try testing.expectEqual(@as(usize, 1), try countRows(&s));
}

fn countRows(s: anytype) !usize {
    var rows = try s.db.query(testing.allocator, "SELECT COUNT(*) FROM session_pending_question", &.{});
    defer rows.deinit();
    if (try rows.next()) |row| {
        defer row.deinit(testing.allocator);
        return std.fmt.parseInt(usize, row.values[0], 10);
    }
    return 0;
}

test "ask_user_pending: markAbandonedForSession resolves only that session's pending rows" {
    var s = try setupDb();
    defer s.db.deinit();
    defer s.threaded.deinit();
    const a = testing.allocator;

    const id1 = try insertOne(&s, "q_1", "s1", "call_1");
    defer a.free(id1);
    const id2 = try insertOne(&s, "q_2", "s1", "call_2");
    defer a.free(id2);
    const id3 = try insertOne(&s, "q_3", "s2", "call_3");
    defer a.free(id3);
    // An already-answered row must not be resurrected as abandoned.
    try markQuestionStatus(a, s.threaded.io(), &s.db, "q_2", .answered, "staging");

    _ = try markAbandonedForSession(a, s.threaded.io(), &s.db, "s1");

    try testing.expect(!hasPendingQuestion(a, &s.db, "s1"));
    const q1 = (try getPendingQuestion(a, &s.db, "q_1")).?;
    defer q1.deinit(a);
    try testing.expectEqualStrings("abandoned", q1.status);
    const q2 = (try getPendingQuestion(a, &s.db, "q_2")).?;
    defer q2.deinit(a);
    try testing.expectEqualStrings("answered", q2.status);
    try testing.expectEqualStrings("staging", q2.answer);
    // Untouched session.
    try testing.expect(hasPendingQuestion(a, &s.db, "s2"));
    const q3 = (try getPendingQuestion(a, &s.db, "q_3")).?;
    defer q3.deinit(a);
    try testing.expectEqualStrings("pending", q3.status);
}

test "ask_user_pending: getPendingQuestionByToolCall finds the row the card names" {
    var s = try setupDb();
    defer s.db.deinit();
    defer s.threaded.deinit();
    const a = testing.allocator;

    const id = try insertOne(&s, "q_1", "s1", "call_abc");
    defer a.free(id);

    const q = (try getPendingQuestionByToolCall(a, &s.db, "s1", "call_abc")).?;
    defer q.deinit(a);
    try testing.expectEqualStrings("q_1", q.id);

    // Wrong session / unknown call → not found, never a wrong row.
    try testing.expect((try getPendingQuestionByToolCall(a, &s.db, "s2", "call_abc")) == null);
    try testing.expect((try getPendingQuestionByToolCall(a, &s.db, "s1", "nope")) == null);
}

test "ask_user_pending: listRecentQuestions returns pending + just-resolved rows" {
    var s = try setupDb();
    defer s.db.deinit();
    defer s.threaded.deinit();
    const a = testing.allocator;
    const io = s.threaded.io();

    const id1 = try insertOne(&s, "q_1", "s1", "call_1");
    defer a.free(id1);
    const id2 = try insertOne(&s, "q_2", "s1", "call_2");
    defer a.free(id2);
    try markQuestionStatus(a, io, &s.db, "q_2", .answered, "staging");

    // A row resolved long ago (outside the 60s window) must not come back.
    try s.db.exec(a, "INSERT INTO session_pending_question (id, session_id, tool_call_id, llm_history_id, question, multi_select, status, answer, created_at, resolved_at) VALUES ('q_old','s1','call_old','row_1','old',0,'answered','x',1,1)", &.{});

    const list = try listRecentQuestions(a, io, &s.db, "s1");
    defer {
        for (list) |q| q.deinit(a);
        a.free(list);
    }
    try testing.expectEqual(@as(usize, 2), list.len);
    try testing.expectEqualStrings("q_1", list[0].id); // pending first (created_at ASC)
    try testing.expectEqualStrings("q_2", list[1].id); // just-resolved
}

test "ask_user_pending: newQuestionId is prefixed and unique" {
    var threaded = std.Io.Threaded.init(testing.allocator, .{});
    defer threaded.deinit();
    const a = testing.allocator;
    const id = try newQuestionId(a, threaded.io());
    defer a.free(id);
    try testing.expect(std.mem.startsWith(u8, id, "q_"));
    try testing.expect(id.len > 3);
}

test "ask_user_pending: extractParametersJson returns a JSON string" {
    const a = testing.allocator;

    // A row carrying a JSON object passes through verbatim.
    {
        const body = try extractParametersJson(
            a,
            "{\"tool\":\"ask_user\",\"parameters\":{\"question\":\"Q?\"},\"success\":true,\"data\":{},\"error\":null,\"v\":1}",
        );
        defer a.free(body);
        try testing.expectEqualStrings("{\"question\":\"Q?\"}", body);
    }

    // A rewrite whose row has no `parameters` must still work.
    {
        const body = try extractParametersJson(a, "{\"tool\":\"x\",\"success\":true,\"data\":{},\"error\":null,\"v\":1}");
        defer a.free(body);
        try testing.expectEqualStrings("{}", body);
    }

    // Null parameters mean empty args.
    {
        const body = try extractParametersJson(a, "{\"tool\":\"x\",\"parameters\":null,\"success\":true,\"data\":{},\"error\":null,\"v\":1}");
        defer a.free(body);
        try testing.expectEqualStrings("{}", body);
    }

    // A legacy pre-migration row degrades to empty args (old rows render
    // as raw text downstream anyway).
    {
        const body = try extractParametersJson(a, "<tool><name>x</name><data>y</data></tool>");
        defer a.free(body);
        try testing.expectEqualStrings("{}", body);
    }

    // Empty input means empty args.
    {
        const body = try extractParametersJson(a, "");
        defer a.free(body);
        try testing.expectEqualStrings("{}", body);
    }
}

test "ask_user_pending: a rewrite preserves parameters so the card can parse it" {
    const a = testing.allocator;
    var s = try setupDb();
    defer s.db.deinit();
    defer s.threaded.deinit();

    // Only the columns this test touches; the real table comes from Migration
    // 001+. `diffview_*` + `is_loading` are needed because
    // `updateToolResultById` names them in its UPDATE.
    try s.db.exec(a,
        \\CREATE TABLE llm_history (
        \\    id TEXT PRIMARY KEY,
        \\    session_id TEXT NOT NULL,
        \\    model TEXT NOT NULL,
        \\    response_content TEXT,
        \\    role TEXT,
        \\    tool_name TEXT,
        \\    diffview_before TEXT,
        \\    diffview_after TEXT,
        \\    is_loading INTEGER NOT NULL DEFAULT 0
        \\)
    , &.{});

    // The row handle_tool would have written, then the rewrite the answer
    // endpoint performs.
    const placeholder =
        "{\"tool\":\"ask_user\",\"parameters\":{\"header\":\"Deploy target\"}," ++
        "\"success\":true,\"data\":{\"status\":\"pending\"},\"error\":null,\"v\":1}";
    try s.db.exec(a,
        \\INSERT INTO llm_history (id, session_id, model, response_content, role, tool_name)
        \\VALUES ('row_1', 'sess_1', 'm', ?, 'tool', 'ask_user')
    , &.{placeholder});

    const inner = try ask_user_mod.buildAskUserJson(a, .{
        .status = .skipped,
        .question_id = "q_1",
        .question = "Which environment?",
    });
    defer a.free(inner);

    try rewriteToolResultRow(.{
        .allocator = a,
        .io = s.threaded.io(),
        .db = &s.db,
        .session_id = "sess_1",
        .llm_history_id = "row_1",
        .inner = inner,
    });

    const after = (try readRowContent(a, &s.db, "row_1")).?;
    defer a.free(after);
    try testing.expect(std.mem.indexOf(u8, after, "\"status\":\"skipped\"") != null);
    try testing.expect(std.mem.indexOf(u8, after, "\"question\":\"Which environment?\"") != null);
    // The contract the frontend's unwrapToolOutput enforces. Without this the
    // card falls back to an empty pending render and never shows the outcome.
    // Parameters survive as a JSON object.
    try testing.expect(std.mem.indexOf(u8, after, "\"parameters\":{\"header\":\"Deploy target\"}") != null);
    try testing.expect(std.mem.indexOf(u8, after, "\"tool\":\"ask_user\"") != null);
    try testing.expect(std.mem.indexOf(u8, after, "\"success\":true") != null);
}
