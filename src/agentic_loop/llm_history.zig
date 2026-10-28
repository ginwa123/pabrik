const model_catalog = @import("model_catalog.zig");
const std = @import("std");
/// The tail of the upsert of a session skill row (see `dialect.upsert_verb`).
const UPSERT_SESSION_SKILL_TAIL: []const u8 = if (dialect.is_postgres)
    " ON CONFLICT (session_id, skill_name) DO UPDATE SET " ++
        "content = excluded.content, loaded_at_nano = excluded.loaded_at_nano"
else
    "";

const testing = std.testing;
const pabrikcore = @import("pabrikcore");
const test_db = pabrikcore.test_db;
const sqlite = pabrikcore.sqlite;
const database = pabrikcore.database;
const dialect = pabrikcore.dialect;
const agent = pabrikcore.agent;
const logger_mod = pabrikcore.loggermod;
const helpers = @import("helpers");
const session_llm_config = @import("session_llm_config.zig");
const auth_common = @import("../http_handlers/auth_common.zig");
const config_mod = pabrikcore.config;
const TUIHistory = @import("models.zig").TUIHistory;
const llm_models = @import("pabrikcore").llm_models;
const on_event_sent = @import("on_event_sent.zig");
const model_guard = @import("llm_history_model_guard.zig");
const parsing = @import("parsing.zig");
// NOTE: routines_model import deleted with the per-task `routines`
// table (Migration 084, plan 2026-09-10-workspace-items-routines).

/// Session info for list view
pub const SessionInfo = struct {
    session_id: []const u8,
    session_name: []const u8,
    status: []const u8,
    cwd: []const u8,
    created_at: []const u8,
    updated_at: []const u8,
    agent: []const u8,
    selected_profile_model: []const u8,
    /// Migration 063 — "0" / "1" opt-in flag for unattended mode. Matches
    /// the SQL `is_auto_retry_until_stop` column convention. COALESCE'd to
    /// "0" at the SELECT boundary so callers always see a defined value.
    is_auto_retry_until_stop: []const u8,
    /// Migration 063 — denormalized cache of the most recent finish_reason
    /// the workflow observed for this session. Empty string until the
    /// first successful turn; never NULL at the API edge.
    last_finish_reason: []const u8,
    /// Migration 082 - unix-ms of the last time a HUMAN (not the AI agent)
    /// interacted with this session.
    last_human_touched_at: []const u8,
    /// Bound git worktree path ("" = none). Mirrors
    /// `sessions.git_worktree_cwd`; COALESCE'd to "" at the SELECT boundary.
    git_worktree_cwd: []const u8,
    /// Current git branch for the session's effective cwd (worktree cwd when
    /// bound, else the session cwd).
    git_branch: []const u8,
    /// The project this session belongs to
    /// (`workspace_item_tasks.workspace_item_id`, "" when it belongs to
    /// none).
    workspace_item_id: []const u8 = "",
    /// Migration 104 - pinned sessions (PINNED section above RECENT).
    /// True when the user pinned this session via right-click menu.
    is_pinned: bool = false,
    /// Migration 104 - position inside the pinned region. MAX+1 on pin,
    /// 0 when unpinned.
    pinned_position: i64 = 0,
    /// 1 when the AI finished a turn and no human has touched the session
    /// since. Same CASE predicate as the kanban card's index 13.
    needs_human_review: bool = false,

    pub fn deinit(self: *const SessionInfo, allocator: std.mem.Allocator) void {
        allocator.free(self.session_id);
        allocator.free(self.session_name);
        allocator.free(self.status);
        allocator.free(self.cwd);
        allocator.free(self.created_at);
        allocator.free(self.updated_at);
        allocator.free(self.agent);
        allocator.free(self.selected_profile_model);
        allocator.free(self.is_auto_retry_until_stop);
        allocator.free(self.last_finish_reason);
        allocator.free(self.last_human_touched_at);
        allocator.free(self.git_worktree_cwd);
        allocator.free(self.git_branch);
        // Zero-length when the field was left at its default, and
        // `Allocator.free` short-circuits on len 0 — so a literal that never
        // set it is not freeing a string constant.
        allocator.free(self.workspace_item_id);
    }
};

/// Sort specification for session list
pub const SessionSortField = enum { created_at, session_name, agent, updated_at };
pub fn enumFromString(comptime T: type, s: []const u8) !T {
    inline for (@typeInfo(T).@"enum".fields) |field| {
        if (std.mem.eql(u8, s, field.name)) {
            return @enumFromInt(field.value);
        }
    }
    return error.UnknownValue;
}
pub const SessionSortDirection = enum { asc, desc };

/// Sort field for the paginated workspace-item tasks endpoint (`GET
/// /api/workspaces/:wid/items/:iid/tasks`). Mirrors `SessionSortField`
/// (above) so the API surface is consistent.
pub const TaskSortField = enum { created_at, updated_at, name };

/// Sort direction for workspace-item tasks. Asc/desc. Mirrors
/// `SessionSortDirection` (above).
pub const TaskSortDirection = enum { asc, desc };

/// Detailed session info
pub const SessionDetail = struct {
    session_id: []const u8,
    cwd: []const u8,
    created_at: []const u8,
    agent: []const u8,
    session_name: []const u8,
    model: []const u8,
    temperature: f32,
    updated_at: []const u8,

    pub fn deinit(self: *const SessionDetail, allocator: std.mem.Allocator) void {
        allocator.free(self.session_id);
        allocator.free(self.cwd);
        allocator.free(self.created_at);
        allocator.free(self.agent);
        allocator.free(self.session_name);
        allocator.free(self.model);
        allocator.free(self.updated_at);
    }
};

/// Session info for SSE broadcast (lightweight)
pub const SessionBroadcastInfo = struct {
    session_id: []const u8,
    session_name: []const u8,
    status: []const u8,
    cwd: []const u8,
    created_at: []const u8,
    updated_at: []const u8,
    agent: []const u8,
    selected_profile_model: []const u8,
    git_worktree_cwd: []const u8,
    /// Migration 086 — attached PR URL ("" = none). Defaults keep older
    /// literal sites compiling; populated by getSessionsForBroadcast.
    pr_url: []const u8 = "",
    /// Migration 086 — effective PR provider. Same defaulting rationale.
    pr_provider: []const u8 = "",
    /// Migration 063 — opt-in flag for unattended mode.
    is_auto_retry_until_stop: []const u8,
    /// Migration 063 — most recent finish_reason the workflow observed.
    last_finish_reason: []const u8,
    /// Migration 091 — resolved sub-agent name ("" = main session).
    sub_agent_name: []const u8 = "",
    /// Migration 091 — parent session id for sub-agents.
    parent_session_id: []const u8 = "",
};

/// Get a list of sessions from the database
pub fn getSessionList(
    allocator: std.mem.Allocator,
    db: *database.Db,
    status: ?[]const u8,
    agent_type: ?[]const u8,
    limit: u32,
    offset: u32,
) !struct { sessions: []SessionInfo, total: u32 } {
    _ = status;
    _ = agent_type;

    // Rewritten to use idx_llm_history_created_session(created_at DESC,
    // session_id) — see Migration 048.
    const sql =
        \\SELECT sub.session_id,
        \\       sub.created_at,
        \\       COALESCE(s.cwd, '') AS cwd,
        \\       COALESCE(s.name, '') AS session_name,
        \\       COALESCE(
        \\         (SELECT h2.agent
        \\            FROM llm_history h2
        \\           WHERE h2.session_id = sub.session_id
        \\           ORDER BY h2.created_at_nano DESC
        \\           LIMIT 1),
        \\         'Agent'
        \\       ) AS agent,
        \\       COALESCE(s.is_auto_retry_until_stop, '0') AS is_auto_retry_until_stop,
        \\       COALESCE(s.last_finish_reason, '') AS last_finish_reason,
        \\       COALESCE(
        \\         (SELECT t.workspace_item_id
        \\            FROM workspace_item_tasks t
        \\           WHERE t.id = sub.session_id
        \\           LIMIT 1),
        \\         ''
        \\       ) AS workspace_item_id
        \\FROM (
        \\  SELECT h.session_id, MAX(h.created_at_nano) AS created_at
        \\    FROM llm_history h
        \\   GROUP BY h.session_id
        \\   ORDER BY created_at DESC
        \\   LIMIT ? OFFSET ?
        \\) sub
        \\LEFT JOIN sessions s ON s.id = sub.session_id
        \\ORDER BY sub.created_at DESC
    ;

    const limit_str = try std.fmt.allocPrint(allocator, "{d}", .{limit});
    const offset_str = try std.fmt.allocPrint(allocator, "{d}", .{offset});
    defer {
        allocator.free(limit_str);
        allocator.free(offset_str);
    }

    var rows = try db.query(allocator, sql, &.{ limit_str, offset_str });
    defer rows.deinit();

    var sessions = std.ArrayList(SessionInfo).empty;
    errdefer {
        for (sessions.items) |s| s.deinit(allocator);
        sessions.deinit(allocator);
    }

    while (try rows.next()) |row| {
        const session = SessionInfo{
            .session_id = try allocator.dupe(u8, row.values[0]),
            .cwd = try allocator.dupe(u8, row.values[1]),
            .created_at = try allocator.dupe(u8, row.values[2]),
            .agent = try allocator.dupe(u8, row.values[3]),
            .session_name = try allocator.dupe(u8, row.values[4]),
            .status = try allocator.dupe(u8, ""),
            .selected_profile_model = try allocator.dupe(u8, ""),
            .is_auto_retry_until_stop = try allocator.dupe(u8, "0"),
            .last_finish_reason = try allocator.dupe(u8, ""),
            .last_human_touched_at = try allocator.dupe(u8, ""),
            .git_worktree_cwd = try allocator.dupe(u8, ""),
            .git_branch = try allocator.dupe(u8, ""),
            // row.values[7] = workspace_item_id. COALESCE'd to "" by the
            // SELECT, so a session outside any project is "" and never NULL.
            .workspace_item_id = try allocator.dupe(u8, row.values[7]),
        };
        try sessions.append(allocator, session);
        row.deinit(allocator);
    }

    // Get total count
    const count_sql = "SELECT COUNT(DISTINCT session_id) FROM llm_history";
    var count_rows = try db.query(allocator, count_sql, &.{});
    defer count_rows.deinit();

    var total: u32 = 0;
    if (try count_rows.next()) |row| {
        total = std.fmt.parseInt(u32, row.values[0], 10) catch 0;
        row.deinit(allocator);
    }

    return .{
        .sessions = try sessions.toOwnedSlice(allocator),
        .total = total,
    };
}

/// Get a list of sessions with cursor-based pagination Queries from sessions
/// table with LEFT JOIN to llm_history `workspace_ids` scopes the list to a
/// workspace's sessions (as resolved by
pub fn getSessionListWithCursor(
    allocator: std.mem.Allocator,
    db: *database.Db,
    status: ?[]const u8,
    agent_type: ?[]const u8,
    cwd: ?[]const u8,
    workspace_ids: ?[]const []const u8,
    owner: []const u8,
    limit: u32,
    cursor: ?[]const u8,
    sort_field: SessionSortField,
    sort_direction: SessionSortDirection,
) !struct { sessions: []SessionInfo, total: u32 } {
    _ = status;
    _ = agent_type;

    // Build dynamic WHERE clause from optional filters
    var where_parts = std.ArrayList([]const u8).empty;
    defer where_parts.deinit(allocator);

    // Fragments this function heap-allocates (freed on the way out).
    // Tracked separately from where_parts so static literals are not
    // freed; keeps the tests' testing.allocator leak-clean.
    var owned_where_fragments = std.ArrayList([]u8).empty;
    defer {
        for (owned_where_fragments.items) |f| allocator.free(f);
        owned_where_fragments.deinit(allocator);
    }

    // Bound ids for the `s.id IN (...)` predicate — passed to BOTH
    // the main query and the count query (they share where_clause).
    var id_binds = std.ArrayList([]const u8).empty;
    defer id_binds.deinit(allocator);

    try where_parts.append(allocator, "s.id NOT LIKE '%subagent%'");

    if (cwd) |dir| {
        // A bind, not a literal: an injected `OR` here re-scopes the whole
        // WHERE past the owner clause appended below.
        try where_parts.append(allocator, "s.cwd = ?");
        try id_binds.append(allocator, dir);
    }

    if (workspace_ids) |ids| {
        if (ids.len == 0) {
            // Empty scope fails closed. `1 = 0` keeps the SQL valid
            // without emitting `IN ()` or binding an empty string.
            try where_parts.append(allocator, "1 = 0");
        } else {
            var frag_list = std.ArrayList(u8).empty;
            defer frag_list.deinit(allocator);
            try frag_list.appendSlice(allocator, "s.id IN (");
            for (ids, 0..) |_, i| {
                if (i > 0) try frag_list.append(allocator, ',');
                try frag_list.append(allocator, '?');
            }
            try frag_list.append(allocator, ')');
            const frag = try frag_list.toOwnedSlice(allocator);
            try owned_where_fragments.append(allocator, frag);
            try where_parts.append(allocator, frag);
            for (ids) |id| try id_binds.append(allocator, id);
        }
    }

    if (cursor) |c| {
        _ = c;
        // Cursor filtering is done via subquery below
    }

    // Per-user scope (plan 2026-09-25, W2.3).
    if (!auth_common.isSharedOwner(owner)) {
        try where_parts.append(allocator, auth_common.ownerVisibilityClause("s"));
        try id_binds.append(allocator, owner);
        try id_binds.append(allocator, owner);
    }

    const where_clause = try std.mem.join(allocator, " AND ", where_parts.items);
    defer allocator.free(where_clause);

    // Build ORDER BY clause based on sort field and direction
    const sort_order = switch (sort_direction) {
        .asc => "ASC",
        .desc => "DESC",
    };
    const order_by = switch (sort_field) {
        .created_at => try std.fmt.allocPrint(allocator, "s.created_at {s}", .{sort_order}),
        .session_name => try std.fmt.allocPrint(allocator, "COALESCE(s.name, '') {s}", .{sort_order}),
        .agent => try std.fmt.allocPrint(allocator, "COALESCE(h.agent, 'Agent') {s}", .{sort_order}),
        .updated_at => try std.fmt.allocPrint(allocator, "s.updated_at {s}", .{sort_order}),
    };
    defer allocator.free(order_by);

    // Build cursor filter.
    const cursor_column = switch (sort_field) {
        .created_at => "s.created_at",
        .session_name => "COALESCE(s.name, '')",
        .agent => "COALESCE(h.agent, 'Agent')",
        .updated_at => "s.updated_at",
    };
    const cursor_filter = if (cursor) |_|
        try std.fmt.allocPrint(allocator, " AND {s} {s} ?", .{ cursor_column, if (sort_direction == .asc) ">" else "<" })
    else
        try allocator.dupe(u8, "");
    defer allocator.free(cursor_filter);

    const where_with_cursor = try std.fmt.allocPrint(allocator, "{s}{s}", .{ where_clause, cursor_filter });
    defer allocator.free(where_with_cursor);

    const sql_final = try std.fmt.allocPrint(allocator,
        \\SELECT s.id, s.name, s.status, s.cwd, COALESCE(CAST(s.created_at AS TEXT), ''),
        \\COALESCE(CAST(s.updated_at AS TEXT), ''),
        \\COALESCE(h.agent, 'Agent'),
        \\COALESCE(s.selected_profile_model, ''),
        \\COALESCE(s.is_auto_retry_until_stop, '0'),
        \\COALESCE(s.last_finish_reason, ''),
        \\CASE WHEN s.last_human_touched_at_nano IS NULL OR s.last_human_touched_at_nano = '' THEN '' ELSE strftime('%Y-%m-%d %H:%M:%S', s.last_human_touched_at_nano / 1000, 'unixepoch') END,
        \\COALESCE(s.git_worktree_cwd, ''),
        \\COALESCE((SELECT t.workspace_item_id FROM workspace_item_tasks t WHERE t.id = s.id LIMIT 1), ''),
        \\COALESCE(s.is_pinned, 0),
        \\COALESCE(s.pinned_position, 0),
        \\CASE WHEN COALESCE(s.last_finish_reason, '') = 'stop' AND (s.last_human_touched_at_nano IS NULL OR s.last_human_touched_at_nano = '' OR s.last_human_touched_at_nano < CAST(strftime('%s', s.updated_at) AS INTEGER) * 1000) THEN 1 ELSE 0 END
        \\FROM sessions s
        \\LEFT JOIN llm_history h ON s.id = h.session_id
        \\WHERE {s}
        \\GROUP BY s.id ORDER BY {s} LIMIT {d}
    , .{ where_with_cursor, order_by, limit });
    defer allocator.free(sql_final);

    // The cursor is a bind for the MAIN query only: the count query below
    // shares `id_binds` but has no cursor predicate.
    var main_binds = std.ArrayList([]const u8).empty;
    defer main_binds.deinit(allocator);
    try main_binds.appendSlice(allocator, id_binds.items);
    if (cursor) |c| try main_binds.append(allocator, c);

    var rows = try db.query(allocator, sql_final, main_binds.items);
    defer rows.deinit();

    var sessions = std.ArrayList(SessionInfo).empty;
    errdefer {
        for (sessions.items) |s| s.deinit(allocator);
        sessions.deinit(allocator);
    }

    while (try rows.next()) |row| {
        const session = SessionInfo{
            .session_id = try allocator.dupe(u8, row.values[0]),
            .session_name = try allocator.dupe(u8, row.values[1]),
            .status = try allocator.dupe(u8, row.values[2]),
            .cwd = try allocator.dupe(u8, row.values[3]),
            .created_at = try allocator.dupe(u8, row.values[4]),
            .updated_at = try allocator.dupe(u8, row.values[5]),
            .agent = try allocator.dupe(u8, row.values[6]),
            .selected_profile_model = try allocator.dupe(u8, row.values[7]),
            // Migration 063 — the SELECT adds 2 trailing columns, so
            // the index shifts by 2. row.values[8] = is_auto_retry_until_stop,
            // row.values[9] = last_finish_reason.
            .is_auto_retry_until_stop = try allocator.dupe(u8, row.values[8]),
            .last_finish_reason = try allocator.dupe(u8, row.values[9]),
            // Migration 082 - row.values[10] = last_human_touched_at_nano.
            // Aliased to last_human_touched_at on the wire (D3 - SQL
            // column keeps the _nano suffix, the wire field is bare).
            .last_human_touched_at = try allocator.dupe(u8, row.values[10]),
            // Sidebar git badge - row.values[11] = git_worktree_cwd.
            // git_branch is resolved per request in session_list.zig
            // (git -C <effective-cwd>), so the DB layer leaves it empty.
            .git_worktree_cwd = try allocator.dupe(u8, row.values[11]),
            .git_branch = try allocator.dupe(u8, ""),
            // row.values[12] = workspace_item_id, appended after the git
            // columns so every existing index in this literal is unchanged.
            // "" for a session that is in no project.
            .workspace_item_id = try allocator.dupe(u8, row.values[12]),
            // Migration 104 - row.values[13] = is_pinned (0/1),
            // row.values[14] = pinned_position.
            .is_pinned = std.mem.eql(u8, row.values[13], "1"),
            .pinned_position = std.fmt.parseInt(i64, row.values[14], 10) catch 0,
            // row.values[15] = needs_human_review (CASE derived).
            .needs_human_review = std.mem.eql(u8, row.values[15], "1"),
        };
        try sessions.append(allocator, session);
        row.deinit(allocator);
    }

    // Count query: the SAME filter as the main query (shared where_clause),
    // aliased `s` so the `s.`-prefixed fragments apply verbatim, and WITHOUT
    // the cursor — `total` is the full filtered size that the cursor
    const count_sql: []u8 = try std.fmt.allocPrint(allocator, "SELECT COUNT(*) FROM sessions s WHERE {s}", .{where_clause});
    defer allocator.free(count_sql);

    var count_rows = try db.query(allocator, count_sql, id_binds.items);
    defer count_rows.deinit();

    var total: u32 = 0;
    if (try count_rows.next()) |row| {
        total = std.fmt.parseInt(u32, row.values[0], 10) catch 0;
        row.deinit(allocator);
    }

    return .{
        .sessions = try sessions.toOwnedSlice(allocator),
        .total = total,
    };
}

/// Session list JSON response structure
pub const SessionListJsonResponse = struct {
    sessions: []const SessionInfoJson,
    total: u32,
    has_more: bool,
    next_cursor: ?[]const u8 = null,
};

/// Session info for JSON serialization
pub const SessionInfoJson = struct {
    session_id: []const u8,
    cwd: []const u8,
    created_at: []const u8,
    updated_at: []const u8,
    agent: []const u8,
    session_name: []const u8,
    selected_profile_model: []const u8,
    /// Migration 063 — opt-in flag for unattended mode (Migration 063).
    is_auto_retry_until_stop: []const u8 = "",
    /// Migration 063 — most recent finish_reason (Migration 063).
    last_finish_reason: []const u8 = "",
    /// Migration 082 - unix-ms of the last human touch. Empty string for
    /// legacy rows (frontend falls back to updated_at).
    last_human_touched_at: []const u8 = "",
    /// Bound git worktree path ("" = none). The sidebar shows the
    /// kanban-style branch badge when `git_branch` is non-empty and
    /// uses this path as the tooltip + PR-status cwd.
    git_worktree_cwd: []const u8 = "",
    /// Current git branch for the effective cwd ("" = no badge).
    /// Computed per request in `session_list.zig` (same `git -C`
    /// helper as the kanban task badge).
    git_branch: []const u8 = "",
    /// The project this session belongs to ("" = not in one). Additive:
    /// a client that has never heard of it ignores the field, and the web
    /// (`api/index.ts`) does not read it today.
    workspace_item_id: []const u8 = "",
    /// Migration 104 - pinned sessions (PINNED section above RECENT). True
    /// when the user pinned this session via right-click menu. COALESCE'd to
    /// false at the SELECT boundary so legacy rows read as unpinned.
    is_pinned: bool = false,
    /// Migration 104 - position inside the pinned region. MAX+1 on pin
    /// (lands at bottom), 0 when unpinned. COALESCE'd to 0.
    pinned_position: i64 = 0,
    needs_human_review: bool = false,
};

/// Build JSON response for a list of sessions with cursor pagination
pub fn buildSessionListJson(
    allocator: std.mem.Allocator,
    sessions: []const SessionInfo,
    total: u32,
    has_more: bool,
    next_cursor: ?[]const u8,
) ![]u8 {
    // Convert SessionInfo to SessionInfoJson for serialization
    var json_sessions = std.ArrayList(SessionInfoJson).empty;
    defer json_sessions.deinit(allocator);

    for (sessions) |sess| {
        try json_sessions.append(allocator, .{
            .session_id = sess.session_id,
            .cwd = sess.cwd,
            .created_at = sess.created_at,
            .updated_at = sess.updated_at,
            .agent = sess.agent,
            .session_name = sess.session_name,
            .selected_profile_model = sess.selected_profile_model,
            // Migration 063 — pass through.
            .is_auto_retry_until_stop = sess.is_auto_retry_until_stop,
            .last_finish_reason = sess.last_finish_reason,
            // Migration 082 - forward the chat-side stamp value to the
            // wire. Empty string for legacy rows means the frontend
            // falls back to updated_at (per ChatsList.vue display logic).
            .last_human_touched_at = sess.last_human_touched_at,
            // Sidebar git badge - forward the worktree path and the
            // per-request resolved branch ("" = no badge).
            .git_worktree_cwd = sess.git_worktree_cwd,
            .git_branch = sess.git_branch,
            .workspace_item_id = sess.workspace_item_id,
            // Migration 104 - pinned sessions for PINNED section.
            .is_pinned = sess.is_pinned,
            .pinned_position = sess.pinned_position,
            .needs_human_review = sess.needs_human_review,
        });
    }

    const response = SessionListJsonResponse{
        .sessions = json_sessions.items,
        .total = total,
        .has_more = has_more,
        .next_cursor = next_cursor,
    };

    return try std.json.Stringify.valueAlloc(allocator, response, .{});
}

/// Append escaped JSON string (with quotes) to an ArrayList
fn jsonAppendEscaped(allocator: std.mem.Allocator, out: *std.ArrayList(u8), input: []const u8) !void {
    try out.append(allocator, '"');
    for (input) |c| {
        switch (c) {
            '"' => try out.appendSlice(allocator, "\\\""),
            '\\' => try out.appendSlice(allocator, "\\\\"),
            '\n' => try out.appendSlice(allocator, "\\n"),
            '\r' => try out.appendSlice(allocator, "\\r"),
            '\t' => try out.appendSlice(allocator, "\\t"),
            else => try out.append(allocator, c),
        }
    }
    try out.append(allocator, '"');
}

/// Get a single session by ID
pub fn get_session(
    allocator: std.mem.Allocator,
    db: *database.Db,
    session_id: []const u8,
) !?SessionDetail {
    const sql =
        \\SELECT DISTINCT
        \\    h.session_id,
        \\    COALESCE(s.cwd, ''),
        \\    s.created_at as created_at,
        \\    COALESCE(h.agent, 'Agent'),
        \\    COALESCE(s.name, ''),
        \\    COALESCE(h.model, 'gpt-4'),
        \\    COALESCE(h.temperature, 0.2),
        \\    s.updated_at as updated_at
        \\FROM llm_history h
        \\LEFT JOIN sessions s ON h.session_id = s.id
        \\WHERE h.session_id = ?
        \\GROUP BY h.session_id
    ;
    var rows = try db.query(allocator, sql, &.{session_id});
    defer rows.deinit();

    if (try rows.next()) |row| {
        const session = SessionDetail{
            .session_id = try allocator.dupe(u8, row.values[0]),
            .cwd = try allocator.dupe(u8, row.values[1]),
            .created_at = try allocator.dupe(u8, row.values[2]),
            .agent = try allocator.dupe(u8, row.values[3]),
            .session_name = try allocator.dupe(u8, row.values[4]),
            .model = try allocator.dupe(u8, row.values[5]),
            .temperature = std.fmt.parseFloat(f32, row.values[6]) catch 0.2,
            .updated_at = try allocator.dupe(u8, row.values[7]),
        };
        row.deinit(allocator);
        return session;
    }

    return null;
}

/// Get the latest finish_reason for a session from the database
/// Returns the most recent finish_reason value (e.g., "stop", "tool_calls", "length", etc.)
/// Returns null if no history exists for the session
pub fn getLatestFinishReason(
    allocator: std.mem.Allocator,
    db: *database.Db,
    session_id: []const u8,
) !?[]const u8 {
    const sql = "SELECT finish_reason FROM llm_history WHERE session_id = ? AND finish_reason IS NOT NULL AND finish_reason != '' ORDER BY created_at_nano DESC LIMIT 1";

    var rows = try db.query(allocator, sql, &.{session_id});
    defer rows.deinit();

    if (try rows.next()) |row| {
        const finish_reason = try allocator.dupe(u8, row.values[0]);
        row.deinit(allocator);
        return finish_reason;
    }

    return null;
}

/// Chat message for a session
pub const SessionMessage = struct {
    id: []const u8,
    session_id: []const u8,
    role: []const u8,
    content: []const u8,
    timestamp: []const u8,
    /// Wire-format boolean.
    is_input: bool,
    is_output: bool,
    tool_name: []const u8,
    finish_reason: []const u8,
    reasoning_content: []const u8,
    reasoning_id: ?[]const u8 = null,
    reasoning_encrypted_content: ?[]const u8 = null,
    diffview_before: ?[]const u8 = null,
    diffview_after: ?[]const u8 = null,
    image_urls: ?[][]const u8 = null,
    video_urls: ?[][]const u8 = null,
    /// The attached files as metadata only (name, mime, bytes) — the bytes
    /// never cross the read path.
    file_attachments_meta: ?[]const u8 = null,
    tool_call_id: ?[]const u8 = null,
    tool_calls_json: ?[]const u8 = null,

    pub fn deinit(self: *const SessionMessage, allocator: std.mem.Allocator) void {
        allocator.free(self.id);
        allocator.free(self.session_id);
        allocator.free(self.role);
        allocator.free(self.content);
        allocator.free(self.timestamp);
        // is_input / is_output are bool (not slices) — no free needed
        allocator.free(self.tool_name);
        allocator.free(self.finish_reason);
        allocator.free(self.reasoning_content);
        if (self.reasoning_id) |rid| allocator.free(rid);
        if (self.reasoning_encrypted_content) |rec| allocator.free(rec);
        if (self.diffview_before) |dv| allocator.free(dv);
        if (self.diffview_after) |da| allocator.free(da);
        if (self.image_urls) |iums| {
            for (iums) |img| allocator.free(img);
            allocator.free(iums);
        }
        if (self.video_urls) |vums| {
            for (vums) |vid| allocator.free(vid);
            allocator.free(vums);
        }
        if (self.file_attachments_meta) |fam| allocator.free(fam);
        if (self.tool_call_id) |tci| allocator.free(tci);
        if (self.tool_calls_json) |tcj| allocator.free(tcj);
    }
};

/// Response for session messages with cursor pagination
pub const SessionMessageResponse = struct {
    messages: []SessionMessage,
    has_more: bool,
    next_cursor: ?[]const u8,
    cwd: ?[]const u8 = null,
    /// Session's bound git worktree path (NULL/empty when no worktree is
    /// bound). Mirrors `sessions.git_worktree_cwd`.
    git_worktree_cwd: ?[]const u8 = null,
    /// Attached PR URL (NULL/empty when no PR is bound). Mirrors
    /// `sessions.pr_url`. Added for the set_pull_request tool so the
    /// ChatView right panel can switch to PR-changes mode.
    pr_url: ?[]const u8 = null,
    /// Effective PR provider (NULL/empty when no PR is bound). Mirrors
    /// `sessions.pr_provider`.
    pr_provider: ?[]const u8 = null,
    /// Session's selected profile name (NULL/empty when no profile is
    /// selected). Mirrors `sessions.selected_profile_model`.
    selected_profile_model: ?[]const u8 = null,
    /// Migration 091 — resolved sub-agent name (e.g. "implementator").
    sub_agent_name: ?[]const u8 = null,
    /// Migration 091 — parent session id for sub-agent sessions.
    parent_session_id: ?[]const u8 = null,
    max_total_tokens: u32 = 0,
    max_capacity_total_tokens: u32 = 0,
    total_count: ?u32 = null, // Total count of messages in session (for VirtualScroller)
    skills: ?[]const SkillInfo = null, // Skills loaded for this session
};

/// Sort direction
pub const SortDirection = enum { asc, desc };

/// Sort specification with field and direction combined
pub const SortSpec = union(enum) {
    created_at_asc: void,
    created_at_desc: void,
    id_asc: void,
    id_desc: void,
    role_asc: void,
    role_desc: void,
};

/// Parse a SQLite INTEGER column value (returned by the SQL binder as a
/// `[]const u8` slice) into a bool. Empty string is `false` (matches
/// `COALESCE(col, 0)` semantics).
fn parseRowBool(s: []const u8) bool {
    if (s.len == 0) return false;
    return s[0] == '1';
}

/// Get messages for a session with cursor-based pagination and sorting
/// `profile` — the session's selected profile, resolved by the caller (HTTP
/// handler) from `sessions.selected_profile_model` via
pub fn getSessionMessagesSorted(
    allocator: std.mem.Allocator,
    db: *database.Db,
    session_id: []const u8,
    limit: u32,
    cursor: ?[]const u8,
    sort_spec: SortSpec,
    profile: ?*const config_mod.LlmConfig.LlmAgent,
) !SessionMessageResponse {
    // Query limit + 1 to check if more results exist
    const query_limit = limit + 1;
    const limit_str = try std.fmt.allocPrint(allocator, "{d}", .{query_limit});
    defer allocator.free(limit_str);

    var sql: []u8 = undefined;
    var argv: []const []const u8 = undefined;

    if (cursor) |c| {
        const is_asc = switch (sort_spec) {
            .created_at_asc, .role_asc, .id_asc => true,
            else => false,
        };
        // Use h.created_at (message time) for cursor, not s.created_at (session time)
        const cursor_cmp = if (is_asc) " AND h.created_at_nano > ?" else " AND h.created_at_nano < ?";

        const order_part = switch (sort_spec) {
            .created_at_asc => " ORDER BY h.created_at_nano ASC, h.id ASC",
            .created_at_desc => " ORDER BY h.created_at_nano DESC, h.id DESC",
            .id_asc => " ORDER BY h.created_at_nano ASC, h.id ASC",
            .id_desc => " ORDER BY h.created_at_nano DESC, h.id DESC",
            .role_asc => " ORDER BY h.role ASC, h.created_at_nano ASC, h.id ASC",
            .role_desc => " ORDER BY h.role DESC, h.created_at_nano DESC, h.id DESC",
        };
        sql = try std.fmt.allocPrint(allocator,
            \\SELECT h.id, h.session_id, h.role, h.response_content, h.created_at_nano AS created_at,
            \\       COALESCE(h.is_input, 0), COALESCE(h.is_output, 0), COALESCE(h.tool_name, ''),
            \\       COALESCE(h.finish_reason, ''), COALESCE(s.cwd, ''), COALESCE(s.git_worktree_cwd, ''), COALESCE(h.reasoning_content, ''), COALESCE(h.reasoning_id, ''), COALESCE(h.reasoning_encrypted_content, ''),
            \\       COALESCE(h.diffview_before, ''), COALESCE(h.diffview_after, ''), COALESCE(h.image_url, ''), COALESCE(h.video_url, ''), COALESCE(h.tool_call_id, ''), COALESCE(h.tool_calls_json, ''),
            \\       COALESCE(s.selected_profile_model, ''), COALESCE(s.pr_url, ''), COALESCE(s.pr_provider, ''), COALESCE(s.sub_agent_name, ''), COALESCE(s.parent_session_id, ''),
            \\       COALESCE(h.file_attachments_meta, '')
            \\FROM llm_history h LEFT JOIN sessions s ON h.session_id = s.id
            \\WHERE h.session_id = ?{s}{s} LIMIT ?
        , .{ cursor_cmp, order_part });
        argv = &.{ session_id, c, limit_str };
    } else {
        // 2026-10-02-scrollback-order-key: the FIRST page (no cursor) must
        // order by the MESSAGE's own timestamp, not `s.created_at`.
        const order_part = switch (sort_spec) {
            .created_at_asc => " ORDER BY h.created_at_nano ASC, h.id ASC",
            .created_at_desc => " ORDER BY h.created_at_nano DESC, h.id DESC",
            .id_asc => " ORDER BY h.id ASC",
            .id_desc => " ORDER BY h.id DESC",
            .role_asc => " ORDER BY h.role ASC, h.created_at_nano ASC, h.id ASC",
            .role_desc => " ORDER BY h.role DESC, h.created_at_nano DESC, h.id DESC",
        };
        sql = try std.fmt.allocPrint(allocator,
            \\SELECT h.id, h.session_id, h.role, h.response_content, h.created_at_nano AS created_at,
            \\       COALESCE(h.is_input, 0), COALESCE(h.is_output, 0), COALESCE(h.tool_name, ''),
            \\       COALESCE(h.finish_reason, ''), COALESCE(s.cwd, ''), COALESCE(s.git_worktree_cwd, ''), COALESCE(h.reasoning_content, ''), COALESCE(h.reasoning_id, ''), COALESCE(h.reasoning_encrypted_content, ''),
            \\       COALESCE(h.diffview_before, ''), COALESCE(h.diffview_after, ''), COALESCE(h.image_url, ''), COALESCE(h.video_url, ''), COALESCE(h.tool_call_id, ''), COALESCE(h.tool_calls_json, ''),
            \\       COALESCE(s.selected_profile_model, ''), COALESCE(s.pr_url, ''), COALESCE(s.pr_provider, ''), COALESCE(s.sub_agent_name, ''), COALESCE(s.parent_session_id, ''),
            \\       COALESCE(h.file_attachments_meta, '')
            \\FROM llm_history h LEFT JOIN sessions s ON h.session_id = s.id
            \\WHERE h.session_id = ?{s} LIMIT ?
        , .{order_part});
        argv = &.{ session_id, limit_str };
    }
    defer allocator.free(sql);

    var rows = db.query(allocator, sql, argv) catch blk: {
        // Fallback for pre-Migration-091 tables: retry without the new
        // sessions columns. New identity fields stay null.
        allocator.free(sql);
        // Rebuild the legacy SELECT (same branch, without new cols).
        // We rebuild from scratch to keep column indices consistent.
        if (cursor) |c| {
            const is_asc = switch (sort_spec) {
                .created_at_asc, .role_asc, .id_asc => true,
                else => false,
            };
            const cursor_cmp = if (is_asc) " AND h.created_at_nano > ?" else " AND h.created_at_nano < ?";
            const order_part = switch (sort_spec) {
                .created_at_asc => " ORDER BY h.created_at_nano ASC, h.id ASC",
                .created_at_desc => " ORDER BY h.created_at_nano DESC, h.id DESC",
                .id_asc => " ORDER BY h.id ASC",
                .id_desc => " ORDER BY h.id DESC",
                .role_asc => " ORDER BY h.role ASC, h.created_at_nano ASC, h.id ASC",
                .role_desc => " ORDER BY h.role DESC, h.created_at_nano DESC, h.id DESC",
            };
            sql = try std.fmt.allocPrint(allocator,
                \\SELECT h.id, h.session_id, h.role, h.response_content, h.created_at_nano AS created_at,
                \\       COALESCE(h.is_input, 0), COALESCE(h.is_output, 0), COALESCE(h.tool_name, ''),
                \\       COALESCE(h.finish_reason, ''), COALESCE(s.cwd, ''), COALESCE(s.git_worktree_cwd, ''), COALESCE(h.reasoning_content, ''), COALESCE(h.reasoning_id, ''), COALESCE(h.reasoning_encrypted_content, ''),
                \\       COALESCE(h.diffview_before, ''), COALESCE(h.diffview_after, ''), COALESCE(h.image_url, ''), COALESCE(h.video_url, ''), COALESCE(h.tool_call_id, ''), COALESCE(h.tool_calls_json, ''),
                \\       COALESCE(s.selected_profile_model, ''), COALESCE(s.pr_url, ''), COALESCE(s.pr_provider, '')
                \\FROM llm_history h LEFT JOIN sessions s ON h.session_id = s.id
                \\WHERE h.session_id = ?{s}{s} LIMIT ?
            , .{ cursor_cmp, order_part });
            argv = &.{ session_id, c, limit_str };
        } else {
            // 2026-10-02-scrollback-order-key: the first page must order by
            // the Same 2026-10-02-scrollback-order-key fix as the primary
            // branch above: the no-cursor fallback must order by
            const order_part = switch (sort_spec) {
                .created_at_asc => " ORDER BY h.created_at_nano ASC, h.id ASC",
                .created_at_desc => " ORDER BY h.created_at_nano DESC, h.id DESC",
                .id_asc => " ORDER BY h.id ASC",
                .id_desc => " ORDER BY h.id DESC",
                .role_asc => " ORDER BY h.role ASC, h.created_at_nano ASC, h.id ASC",
                .role_desc => " ORDER BY h.role DESC, h.created_at_nano DESC, h.id DESC",
            };
            sql = try std.fmt.allocPrint(allocator,
                \\SELECT h.id, h.session_id, h.role, h.response_content, h.created_at_nano AS created_at,
                \\       COALESCE(h.is_input, 0), COALESCE(h.is_output, 0), COALESCE(h.tool_name, ''),
                \\       COALESCE(h.finish_reason, ''), COALESCE(s.cwd, ''), COALESCE(s.git_worktree_cwd, ''), COALESCE(h.reasoning_content, ''), COALESCE(h.reasoning_id, ''), COALESCE(h.reasoning_encrypted_content, ''),
                \\       COALESCE(h.diffview_before, ''), COALESCE(h.diffview_after, ''), COALESCE(h.image_url, ''), COALESCE(h.video_url, ''), COALESCE(h.tool_call_id, ''), COALESCE(h.tool_calls_json, ''),
                \\       COALESCE(s.selected_profile_model, ''), COALESCE(s.pr_url, ''), COALESCE(s.pr_provider, '')
                \\FROM llm_history h LEFT JOIN sessions s ON h.session_id = s.id
                \\WHERE h.session_id = ?{s} LIMIT ?
            , .{order_part});
            argv = &.{ session_id, limit_str };
        }
        break :blk try db.query(allocator, sql, argv);
    };
    defer rows.deinit();

    var messages = std.ArrayList(SessionMessage).empty;
    errdefer {
        for (messages.items) |m| m.deinit(allocator);
        messages.deinit(allocator);
    }

    // Get cwd from first row (same for all rows since we filter by session_id)
    var cwd: ?[]u8 = null;
    var git_worktree_cwd: ?[]u8 = null;
    var pr_url: ?[]u8 = null;
    var pr_provider: ?[]u8 = null;
    // 2026-08-07-profile-persist-read: also extract
    // `selected_profile_model` from the joined sessions row so the
    // frontend's profile chip survives a page refresh.
    var selected_profile_model: ?[]u8 = null;
    // Migration 091 — sub-agent identity, same first-row pattern.
    var sub_agent_name: ?[]u8 = null;
    var parent_session_id: ?[]u8 = null;

    while (try rows.next()) |row| {
        // Extract cwd + git_worktree_cwd + selected_profile_model from the
        // first row (same for all rows since we filter by session_id).
        if (cwd == null) {
            const cwd_val = row.values[9];
            if (cwd_val.len > 0) {
                cwd = try allocator.dupe(u8, cwd_val);
            }
        }
        if (git_worktree_cwd == null) {
            const wt_val = row.values[10];
            if (wt_val.len > 0) {
                git_worktree_cwd = try allocator.dupe(u8, wt_val);
            }
        }
        // Column indices 21/22 appended after selected_profile_model
        // at 20 (see SELECT above). Same first-row-only pattern.
        if (pr_url == null) {
            const pr_val = row.values[21];
            if (pr_val.len > 0) {
                pr_url = try allocator.dupe(u8, pr_val);
            }
        }
        if (pr_provider == null) {
            const prp_val = row.values[22];
            if (prp_val.len > 0) {
                pr_provider = try allocator.dupe(u8, prp_val);
            }
        }
        if (selected_profile_model == null) {
            const spm_val = row.values[20];
            if (spm_val.len > 0) {
                selected_profile_model = try allocator.dupe(u8, spm_val);
            }
        }
        if (sub_agent_name == null and row.values.len > 23) {
            const sa_val = row.values[23];
            if (sa_val.len > 0) {
                sub_agent_name = try allocator.dupe(u8, sa_val);
            }
        }
        if (parent_session_id == null and row.values.len > 24) {
            const ps_val = row.values[24];
            if (ps_val.len > 0) {
                parent_session_id = try allocator.dupe(u8, ps_val);
            }
        }

        const msg = SessionMessage{
            .id = try allocator.dupe(u8, row.values[0]),
            .session_id = try allocator.dupe(u8, row.values[1]),
            .role = try allocator.dupe(u8, row.values[2]),
            .content = try allocator.dupe(u8, row.values[3]),
            .timestamp = try allocator.dupe(u8, row.values[4]),
            .is_input = parseRowBool(row.values[5]),
            .is_output = parseRowBool(row.values[6]),
            .tool_name = try allocator.dupe(u8, row.values[7]),
            .finish_reason = try allocator.dupe(u8, row.values[8]),
            .reasoning_content = try allocator.dupe(u8, row.values[11]),
            .reasoning_id = if (row.values[12].len > 0) try allocator.dupe(u8, row.values[12]) else null,
            .reasoning_encrypted_content = if (row.values[13].len > 0) try allocator.dupe(u8, row.values[13]) else null,
            .diffview_before = if (row.values[14].len > 0) try allocator.dupe(u8, row.values[14]) else null,
            .diffview_after = if (row.values[15].len > 0) try allocator.dupe(u8, row.values[15]) else null,
            .image_urls = if (row.values[16].len > 0) blk: {
                var urls = std.ArrayList([]const u8).empty;
                errdefer {
                    for (urls.items) |u| allocator.free(u);
                    urls.deinit(allocator);
                }
                var iter = std.mem.splitScalar(u8, row.values[16], '|');
                while (iter.next()) |url| {
                    if (url.len > 0) {
                        try urls.append(allocator, try allocator.dupe(u8, url));
                    }
                }
                break :blk if (urls.items.len > 0) urls.items else null;
            } else null,
            .video_urls = if (row.values[17].len > 0) blk: {
                var urls = std.ArrayList([]const u8).empty;
                errdefer {
                    for (urls.items) |u| allocator.free(u);
                    urls.deinit(allocator);
                }
                var iter = std.mem.splitScalar(u8, row.values[17], '|');
                while (iter.next()) |url| {
                    if (url.len > 0) {
                        try urls.append(allocator, try allocator.dupe(u8, url));
                    }
                }
                break :blk if (urls.items.len > 0) urls.items else null;
            } else null,
            .file_attachments_meta = if (row.values.len > 25 and row.values[25].len > 0) try allocator.dupe(u8, row.values[25]) else null,
            .tool_call_id = if (row.values[18].len > 0) try allocator.dupe(u8, row.values[18]) else null,
            .tool_calls_json = if (row.values[19].len > 0) try allocator.dupe(u8, row.values[19]) else null,
        };
        try messages.append(allocator, msg);
        row.deinit(allocator);
    }

    // Check if there are more results
    const has_more = messages.items.len > @as(usize, limit);

    // Get next cursor from last message if has_more
    // Use created_at timestamp as cursor for proper pagination
    const next_cursor: ?[]const u8 = if (has_more and messages.items.len > 0)
        messages.items[@as(usize, limit) - 1].timestamp
    else
        null;

    // Return only limit messages if has_more.
    const result_messages = if (has_more) messages.items[0..limit] else messages.items;

    // Get total count of messages for this session
    const total_count = getTotalMessageCountForSession(allocator, db, session_id);

    // Get skills loaded for this session
    const session_skills = getSessionSkills(allocator, db, session_id) catch null;

    return SessionMessageResponse{
        .messages = result_messages,
        .has_more = has_more,
        .next_cursor = next_cursor,
        .cwd = cwd,
        .git_worktree_cwd = git_worktree_cwd,
        .pr_url = pr_url,
        .pr_provider = pr_provider,
        .selected_profile_model = selected_profile_model,
        .sub_agent_name = sub_agent_name,
        .parent_session_id = parent_session_id,
        .max_total_tokens = getMaxTotalTokensForSession(allocator, db, session_id) catch 0,
        .max_capacity_total_tokens = blk: {
            // Resolve the per-config override when the singleton is alive,
            // otherwise fall back to the built-in per-model default.
            const di_opt = pabrikcore.getSingleton() catch null;
            if (di_opt) |di| {
                // The window a session renders with belongs to the session's
                // owner under `--auth` (`session_llm_config.zig`).
                const cfg = session_llm_config.forSession(allocator, db, session_id) orelse
                    pabrikcore.getLlmConfig(di);
                break :blk resolveMaxCapacityTotalTokens(cfg, profile, cfg.model);
            }
            const empty_cfg = config_mod.LlmConfig{
                .allocator = allocator,
                .api_key = "",
                .model = "",
                .base_url = "",
                .model_compaction_size_kb = 100,
                .mcpServers_parsed = null,
                .mcp_servers = std.StringHashMap(config_mod.LlmConfig.McpServerConfig).init(allocator),
                .agents = std.StringHashMap(config_mod.LlmConfig.LlmAgent).init(allocator),
                .url_style = "openai",
            };
            break :blk resolveMaxCapacityTotalTokens(&empty_cfg, profile, empty_cfg.model);
        },
        .total_count = total_count,
        .skills = session_skills,
    };
}

/// Read `sessions.selected_profile_model` for one session.
pub fn getSessionProfileName(
    allocator: std.mem.Allocator,
    db: *database.Db,
    session_id: []const u8,
) ![]const u8 {
    var rows = try db.query(
        allocator,
        "SELECT COALESCE(selected_profile_model, '') FROM sessions WHERE id = ?",
        &.{session_id},
    );
    defer rows.deinit();

    const maybe_row = try rows.next();
    if (maybe_row) |row| {
        defer row.deinit(allocator);
        // CRITICAL: row.deinit() frees row.values[0]'s backing memory.
        // Dupe into `allocator` so the returned slice outlives the
        // deferred free (same pattern as re_read_selected_profile_model).
        return allocator.dupe(u8, row.values[0]);
    }
    return "";
}

/// Attached-PR binding for one session, read straight from the `sessions`
/// row.
pub const SessionPrFields = struct {
    pr_url: []const u8,
    pr_provider: []const u8,
};

pub fn getSessionPrFields(
    allocator: std.mem.Allocator,
    db: *database.Db,
    session_id: []const u8,
) !SessionPrFields {
    var rows = try db.query(
        allocator,
        "SELECT COALESCE(pr_url, ''), COALESCE(pr_provider, '') FROM sessions WHERE id = ?",
        &.{session_id},
    );
    defer rows.deinit();

    if (try rows.next()) |row| {
        defer row.deinit(allocator);
        return .{
            .pr_url = try allocator.dupe(u8, row.values[0]),
            .pr_provider = try allocator.dupe(u8, row.values[1]),
        };
    }
    return .{ .pr_url = "", .pr_provider = "" };
}

/// Resolve the effective context window for a session view. Pure function
/// over (config, profile, model) so tests can pin the cascade without the
/// process-global singleton.
pub fn resolveMaxCapacityTotalTokens(
    cfg: *const config_mod.LlmConfig,
    profile: ?*const config_mod.LlmConfig.LlmAgent,
    model: []const u8,
) u32 {
    // The live catalog is what makes a non-MiniMax model resolve to its real
    // window instead of the built-in 200k. `null` (no catalog yet) degrades to
    // exactly the previous behaviour.
    return cfg.maxCapacityForModelWith(profile, cfg, model, model_catalog.getSingleton());
}

/// Resolve the profile a session effectively runs under — the shared cascade
/// used by BOTH the workflow loop (workflow.zig `iter_profile`) and the HTTP
/// read paths (messages endpoint, manual compact).
pub fn resolveSessionProfile(
    cfg: *const config_mod.LlmConfig,
    selected_profile_model: []const u8,
) ?config_mod.LlmConfig.LlmAgent {
    return cfg.resolveSessionAgentCompat(selected_profile_model);
}

/// Get the total count of messages for a session
fn getTotalMessageCountForSession(
    allocator: std.mem.Allocator,
    db: *database.Db,
    session_id: []const u8,
) ?u32 {
    const sql = "SELECT COUNT(*) FROM llm_history WHERE session_id = ?";

    var rows = db.query(allocator, sql, &.{session_id}) catch return null;
    defer rows.deinit();

    const row = rows.next() catch return null;
    if (row) |r| {
        const count = std.fmt.parseInt(u32, r.values[0], 10) catch return null;
        return count;
    }
    return null;
}

/// Get the maximum total_tokens for a session (from messages with is_feed_to_llm = 1)
fn getMaxTotalTokensForSession(
    allocator: std.mem.Allocator,
    db: *database.Db,
    session_id: []const u8,
) !u32 {
    const sql =
        \\SELECT COALESCE(MAX(total_tokens), 0)
        \\FROM llm_history
        \\WHERE session_id = ? AND (is_feed_to_llm = 1 OR is_feed_to_llm IS NULL)
    ;

    var rows = try db.query(allocator, sql, &.{session_id});
    defer rows.deinit();

    if (try rows.next()) |row| {
        const max_tokens = std.fmt.parseInt(u32, row.values[0], 10) catch 0;
        row.deinit(allocator);
        return max_tokens;
    }
    return 0;
}

/// Escape JSON special characters for safe string output
fn jsonEscape(allocator: std.mem.Allocator, s: []const u8) ![]u8 {
    var result = std.ArrayList(u8).empty;
    errdefer result.deinit(allocator);

    for (s) |c| {
        switch (c) {
            '"' => try result.appendSlice(allocator, "\\\""),
            '\\' => try result.appendSlice(allocator, "\\\\"),
            '\n' => try result.appendSlice(allocator, "\\n"),
            '\r' => try result.appendSlice(allocator, "\\r"),
            '\t' => try result.appendSlice(allocator, "\\t"),
            '\x08' => try result.appendSlice(allocator, "\\b"), // backspace
            '\x0C' => try result.appendSlice(allocator, "\\f"), // form feed
            // Escape other control characters (0x00-0x1F except those above) as \u00XX
            0x00...0x07, 0x0E...0x1F => {
                var buf: [6]u8 = undefined;
                const hex_str = std.fmt.bufPrint(&buf, "\\u00{X}", .{c}) catch @panic("bufPrint failed formatting a \\u00XX escape in jsonEscape");
                try result.appendSlice(allocator, hex_str);
            },
            else => try result.append(allocator, c),
        }
    }

    return try result.toOwnedSlice(allocator);
}

/// Build JSON response for session messages with pagination info
pub fn buildSessionMessagesJson(
    allocator: std.mem.Allocator,
    response: *const SessionMessageResponse,
) ![]u8 {
    var json_messages = std.ArrayList(u8).empty;
    errdefer json_messages.deinit(allocator);

    try json_messages.appendSlice(allocator, "[");
    for (response.messages, 0..) |msg, i| {
        if (i > 0) try json_messages.append(allocator, ',');

        // Escape all string fields for JSON safety
        const escaped_id = try jsonEscape(allocator, msg.id);
        defer allocator.free(escaped_id);
        const escaped_session_id = try jsonEscape(allocator, msg.session_id);
        defer allocator.free(escaped_session_id);
        const escaped_role = try jsonEscape(allocator, msg.role);
        defer allocator.free(escaped_role);
        const escaped_content = try jsonEscape(allocator, msg.content);
        defer allocator.free(escaped_content);
        const escaped_timestamp = try jsonEscape(allocator, msg.timestamp);
        defer allocator.free(escaped_timestamp);
        const escaped_tool_name = try jsonEscape(allocator, msg.tool_name);
        defer allocator.free(escaped_tool_name);
        const escaped_finish_reason = try jsonEscape(allocator, msg.finish_reason);
        defer allocator.free(escaped_finish_reason);
        const escaped_reasoning_content = try jsonEscape(allocator, msg.reasoning_content);
        defer allocator.free(escaped_reasoning_content);

        // is_input / is_output are bool — emit as JSON booleans (not strings).
        // `"is_input":"1"` is the old wrong format; `"is_input":true` is correct.
        const is_input_str = if (msg.is_input) "true" else "false";
        const is_output_str = if (msg.is_output) "true" else "false";
        const msg_json = try std.fmt.allocPrint(allocator,
            \\{{"id":"{s}","session_id":"{s}","role":"{s}","content":"{s}","timestamp":"{s}",
            \\"is_input":{s},"is_output":{s},"tool_name":"{s}","finish_reason":"{s}","reasoning_content":"{s}"}}
        , .{ escaped_id, escaped_session_id, escaped_role, escaped_content, escaped_timestamp, is_input_str, is_output_str, escaped_tool_name, escaped_finish_reason, escaped_reasoning_content });
        defer allocator.free(msg_json);
        try json_messages.appendSlice(allocator, msg_json);
    }
    try json_messages.append(allocator, ']');

    // Build pagination fields
    const has_more_str = if (response.has_more) "true" else "false";
    const next_cursor_str = if (response.next_cursor) |c|
        try std.fmt.allocPrint(allocator, "\"{s}\"", .{c})
    else
        try std.fmt.allocPrint(allocator, "null", .{});
    defer allocator.free(next_cursor_str);

    // Build cwd field
    const cwd_str = if (response.cwd) |c|
        try std.fmt.allocPrint(allocator, "\"{s}\"", .{c})
    else
        try std.fmt.allocPrint(allocator, "null", .{});
    defer allocator.free(cwd_str);

    // Build max_total_tokens field
    const max_total_tokens_str = try std.fmt.allocPrint(allocator, "{d}", .{response.max_total_tokens});
    defer allocator.free(max_total_tokens_str);

    // Build max_capacity_total_tokens field
    const max_capacity_total_tokens_str = try std.fmt.allocPrint(allocator, "{d}", .{response.max_capacity_total_tokens});
    defer allocator.free(max_capacity_total_tokens_str);

    const result = try std.fmt.allocPrint(allocator, "{{\"messages\":{s},\"has_more\":{s},\"next_cursor\":{s},\"cwd\":{s},\"max_total_tokens\":{s},\"max_capacity_total_tokens\":{s}}}", .{ json_messages.items, has_more_str, next_cursor_str, cwd_str, max_total_tokens_str, max_capacity_total_tokens_str });
    json_messages.deinit(allocator);
    return result;
}

/// Escape XML special characters for safe output
pub fn xmlEscape(allocator: std.mem.Allocator, s: []const u8) ![]u8 {
    var result = std.ArrayList(u8).empty;
    errdefer result.deinit(allocator);

    for (s) |c| {
        switch (c) {
            '<' => try result.appendSlice(allocator, "&lt;"),
            '>' => try result.appendSlice(allocator, "&gt;"),
            '&' => try result.appendSlice(allocator, "&amp;"),
            '"' => try result.appendSlice(allocator, "&quot;"),
            '\'' => try result.appendSlice(allocator, "&apos;"),
            else => try result.append(allocator, c),
        }
    }

    return try result.toOwnedSlice(allocator);
}

/// Build XML response for session messages with pagination info
pub fn buildSessionMessagesXml(
    allocator: std.mem.Allocator,
    response: *const SessionMessageResponse,
) ![]u8 {
    var xml_messages = std.ArrayList(u8).empty;
    errdefer xml_messages.deinit(allocator);

    try xml_messages.appendSlice(allocator, "<messages>");
    for (response.messages) |msg| {
        const escaped_id = try xmlEscape(allocator, msg.id);
        defer allocator.free(escaped_id);
        const escaped_session_id = try xmlEscape(allocator, msg.session_id);
        defer allocator.free(escaped_session_id);
        const escaped_role = try xmlEscape(allocator, msg.role);
        defer allocator.free(escaped_role);
        const escaped_content = try xmlEscape(allocator, msg.content);
        defer allocator.free(escaped_content);
        const escaped_timestamp = try xmlEscape(allocator, msg.timestamp);
        defer allocator.free(escaped_timestamp);
        const escaped_tool_name = try xmlEscape(allocator, msg.tool_name);
        defer allocator.free(escaped_tool_name);
        const escaped_finish_reason = try xmlEscape(allocator, msg.finish_reason);
        defer allocator.free(escaped_finish_reason);
        const escaped_reasoning_content = try xmlEscape(allocator, msg.reasoning_content);
        defer allocator.free(escaped_reasoning_content);

        // is_input / is_output as XML text content.
        const is_input_str = if (msg.is_input) "true" else "false";
        const is_output_str = if (msg.is_output) "true" else "false";
        const msg_xml = try std.fmt.allocPrint(allocator,
            \\<message id="{s}">
            \\<session_id>{s}</session_id>
            \\<role>{s}</role>
            \\<content>{s}</content>
            \\<timestamp>{s}</timestamp>
            \\<is_input>{s}</is_input>
            \\<is_output>{s}</is_output>
            \\<tool_name>{s}</tool_name>
            \\<finish_reason>{s}</finish_reason>
            \\<reasoning_content>{s}</reasoning_content>
            \\</message>
        , .{ escaped_id, escaped_session_id, escaped_role, escaped_content, escaped_timestamp, is_input_str, is_output_str, escaped_tool_name, escaped_finish_reason, escaped_reasoning_content });
        defer allocator.free(msg_xml);
        try xml_messages.appendSlice(allocator, msg_xml);
    }

    // Add pagination info
    const has_more_str = if (response.has_more) "true" else "false";
    try xml_messages.appendSlice(allocator, "<has_more>");
    try xml_messages.appendSlice(allocator, has_more_str);
    try xml_messages.appendSlice(allocator, "</has_more>");
    try xml_messages.appendSlice(allocator, "<next_cursor>");
    if (response.next_cursor) |c| {
        try xml_messages.appendSlice(allocator, c);
    }
    try xml_messages.appendSlice(allocator, "</next_cursor>");
    try xml_messages.appendSlice(allocator, "<cwd>");
    if (response.cwd) |c| {
        try xml_messages.appendSlice(allocator, c);
    }
    try xml_messages.appendSlice(allocator, "</cwd>");
    try xml_messages.appendSlice(allocator, "<max_total_tokens>");
    const max_tokens_str = try std.fmt.allocPrint(allocator, "{d}", .{response.max_total_tokens});
    defer allocator.free(max_tokens_str);
    try xml_messages.appendSlice(allocator, max_tokens_str);
    try xml_messages.appendSlice(allocator, "</max_total_tokens>");
    try xml_messages.appendSlice(allocator, "<max_capacity_total_tokens>");
    const max_cap_tokens_str = try std.fmt.allocPrint(allocator, "{d}", .{response.max_capacity_total_tokens});
    defer allocator.free(max_cap_tokens_str);
    try xml_messages.appendSlice(allocator, max_cap_tokens_str);
    try xml_messages.appendSlice(allocator, "</max_capacity_total_tokens>");
    try xml_messages.appendSlice(allocator, "</messages>");

    return try xml_messages.toOwnedSlice(allocator);
}

// =============================================================================
// Session Creation
// =============================================================================

/// Create a new session in the database
pub fn createSession(
    allocator: std.mem.Allocator,
    db: *database.Db,
    agent_type: []const u8,
    model: []const u8,
    temperature: f32,
    session_name: []const u8,
) ![]const u8 {
    // Generate session ID
    var session_id_buf: [64]u8 = undefined;
    // `std.time.timestamp` was removed in Zig 0.16.
    const session_id = try std.fmt.bufPrint(&session_id_buf, "kerjabot_{}", .{helpers.unixTimestamp()});

    // Insert into sessions table first (for JOIN queries)
    const session_sql = "INSERT INTO sessions (id, name, status) VALUES (?, ?, 'active')";
    const copy_session_name = try allocator.dupe(u8, session_name);
    defer allocator.free(copy_session_name);
    try db.exec(allocator, session_sql, &.{ session_id, copy_session_name });

    // Insert session into llm_history table
    const insert_sql = "INSERT INTO llm_history (id, session_id, model, response_content, role, agent, temperature, created_at_nano, is_input, is_output, tool_name) VALUES (?, ?, ?, ?, ?, ?, ?, datetime('now'), ?, ?, ?)";

    const temp_str = try std.fmt.allocPrint(allocator, "{d}", .{temperature});
    defer allocator.free(temp_str);

    try db.exec(allocator, insert_sql, &.{ session_id, session_id, model, "", "system", agent_type, temp_str, "0", "0", "" });

    return session_id;
}

// =============================================================================
// Save Message Functions
// =============================================================================

/// Serialize tool_calls array to JSON string
pub fn serializeToolCalls(allocator: std.mem.Allocator, tool_calls: []agent.ToolCall) ![]u8 {
    var aw: std.Io.Writer.Allocating = .init(allocator);
    try aw.writer.print("{f}", .{std.json.fmt(tool_calls, .{})});
    return aw.toOwnedSlice();
}

pub const SaveMessageInput = struct {
    session_id: []const u8,
    model: []const u8,
    cwd: []const u8,
    content: ?[]const u8,
    reasoning_content: ?[]const u8,
    reasoning_id: ?[]const u8 = null,
    reasoning_encrypted_content: ?[]const u8 = null,
    role: ?[]const u8,
    finish_reason: ?[]const u8,
    tool_calls: ?[]agent.ToolCall,
    tool_call_id: ?[]const u8,
    tool_name: ?[]const u8 = null,
    agent_name: ?[]const u8,
    loop_index: u32,
    temperature: f32,
    is_thinking: bool,
    is_input: bool = false,
    is_output: bool = false,
    parent_session_id: ?[]const u8 = null,
    parent_id: ?[]const u8 = null,
    prompt_tokens: usize = 0,
    completion_tokens: usize = 0,
    total_tokens: usize = 0,
    /// Anthropic-only cache breakdown (billed at discounted rates; see
    /// `LLMHistory` in `agentic_loop/llm_history.zig`). 0 for OpenAI rows.
    cache_creation_input_tokens: usize = 0,
    cache_read_input_tokens: usize = 0,
    diffview_before: ?[]const u8 = null,
    diffview_after: ?[]const u8 = null,
    image_urls: ?[][]const u8 = null,
    video_urls: ?[][]const u8 = null,
    is_feed_to_llm: bool = true,
};

pub fn saveMessage(
    allocator: std.mem.Allocator,
    io: std.Io,
    db: *database.Db,
    input: SaveMessageInput,
) !void {
    // Get the current timestamp ONCE (two separate `Timestamp.now` calls can
    // return nanoseconds that differ by 1+, which would make `id` and
    // `created_at` disagree).
    const id = try std.fmt.allocPrint(allocator, "{}", .{std.Io.Timestamp.now(io, .real).nanoseconds});
    defer allocator.free(id);
    const created_at_nano = try std.fmt.allocPrint(allocator, "{}", .{std.Io.Timestamp.now(io, .real).nanoseconds});
    defer allocator.free(created_at_nano);

    // Compute `created_iso` (the UTC‑formatted ISO string for the
    // `since`/`until` filter columns) IN APPLICATION CODE rather than via
    // SQLite triggers.
    const created_iso = try helpers.currentTimeIsoLocal(allocator, io);
    defer allocator.free(created_iso);

    const contentStr = input.content orelse "";
    const finishReasonStr = input.finish_reason orelse "null";
    const roleStr = input.role orelse "assistant";
    const reasoningStr = input.reasoning_content orelse "";
    const agentStr = input.agent_name orelse "Agent";

    // Option A envelopes (mirrors insert_llm_histories): user rows carry
    // {user,name,msg}, non-empty assistant text carries {model,msg}.
    var enveloped_owned: ?[]u8 = null;
    defer if (enveloped_owned) |e| allocator.free(e);
    var effective_content: []const u8 = contentStr;
    if (contentStr.len > 0 and !parsing.isChatEnvelope(allocator, contentStr)) {
        if (std.mem.eql(u8, roleStr, "user")) {
            // Logged-in identity when the session has an owner; legacy
            // defaults otherwise (auth off). Lookup failures never block
            // the insert.
            var ident = parsing.resolveChatUser(allocator, db, input.session_id) catch null;
            defer if (ident) |*ci| ci.deinit(allocator);
            const uid: []const u8 = if (ident) |*ci| ci.user_id else "";
            const nm: []const u8 = if (ident) |*ci| (if (ci.name.len > 0) ci.name else agentStr) else agentStr;
            enveloped_owned = try parsing.encodeUserContent(allocator, uid, nm, contentStr);
            effective_content = enveloped_owned.?;
        } else if (std.mem.eql(u8, roleStr, "assistant")) {
            // Profile name the user picked (e.g. "900ribu"); raw model id
            // when Default / auth off / lookup fails.
            const profile_owned: ?[]u8 = parsing.resolveProfileName(allocator, db, input.session_id) catch null;
            defer if (profile_owned) |pr| allocator.free(pr);
            var label: []const u8 = model_guard.resolve(input.model);
            if (profile_owned) |pr| {
                if (pr.len > 0) label = pr;
            }
            enveloped_owned = try parsing.encodeAssistantContent(allocator, label, contentStr);
            effective_content = enveloped_owned.?;
        }
    }

    // tool_calls_json holds ONLY the serialized tool_calls array (assistant
    // message wire format).
    var toolCallsJson: []const u8 = "";
    var toolCallsOwned: ?[]u8 = null;
    if (input.tool_calls) |tc| {
        toolCallsOwned = try serializeToolCalls(allocator, tc);
        toolCallsJson = toolCallsOwned.?;
    }
    defer if (toolCallsOwned) |tcj| allocator.free(tcj);

    const sql =
        \\INSERT INTO llm_history (
        \\    id,
        \\    session_id,
        \\    model,
        \\    response_content,
        \\    finish_reason,
        \\    role,
        \\    tool_calls_json,
        \\    tool_call_id,
        \\    reasoning_content,
        \\    reasoning_id,
        \\    reasoning_encrypted_content,
        \\    is_feed_to_llm,
        \\    agent,
        \\    loop_index,
        \\    temperature,
        \\    is_thinking,
        \\    created_at_nano,
        \\    created_iso,
        \\    parent_session_id,
        \\    parent_id,
        \\    prompt_tokens,
        \\    completion_tokens,
        \\    total_tokens,
        \\    cache_creation_input_tokens,
        \\    cache_read_input_tokens,
        \\    is_input,
        \\    is_output,
        \\    tool_name,
        \\    diffview_before,
        \\    diffview_after,
        \\    image_url,
        \\    video_url
        \\) VALUES (
        \\    ?, ?, ?, ?, ?, ?, ?, ?, ?, ?,
        \\    ?, ?, ?, ?, ?, ?, ?, ?, ?, ?,
        \\    ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?
        \\)
    ;

    const copy_session_id = try allocator.dupe(u8, input.session_id);
    defer allocator.free(copy_session_id);
    // Never bind an empty model: `Backend.exec` binds a zero-length
    // slice as SQL NULL, which violates `model TEXT NOT NULL` and fails the
    // whole INSERT. See llm_history_model_guard.zig.
    const copy_model = try allocator.dupe(u8, model_guard.resolve(input.model));
    defer allocator.free(copy_model);
    const copy_content = try allocator.dupe(u8, effective_content);
    defer allocator.free(copy_content);
    const copy_finish_reason = try allocator.dupe(u8, finishReasonStr);
    defer allocator.free(copy_finish_reason);
    const copy_role = try allocator.dupe(u8, roleStr);
    defer allocator.free(copy_role);
    const copy_tool_calls = try allocator.dupe(u8, toolCallsJson);
    defer allocator.free(copy_tool_calls);
    const copy_reasoning = try allocator.dupe(u8, reasoningStr);
    defer allocator.free(copy_reasoning);
    const copy_reasoning_id = try allocator.dupe(u8, input.reasoning_id orelse "");
    defer allocator.free(copy_reasoning_id);
    const copy_reasoning_encrypted_content = try allocator.dupe(u8, input.reasoning_encrypted_content orelse "");
    defer allocator.free(copy_reasoning_encrypted_content);
    const copy_agent = try allocator.dupe(u8, agentStr);
    defer allocator.free(copy_agent);
    const loop_index_str = try std.fmt.allocPrint(allocator, "{}", .{input.loop_index});
    defer allocator.free(loop_index_str);
    const temperature_str = try std.fmt.allocPrint(allocator, "{d:.2}", .{input.temperature});
    defer allocator.free(temperature_str);
    const is_thinking_str = if (input.is_thinking) "1" else "0";
    const copy_parent_session_id = try allocator.dupe(u8, input.parent_session_id orelse "");
    defer allocator.free(copy_parent_session_id);
    const copy_parent_id = try allocator.dupe(u8, input.parent_id orelse "");
    defer allocator.free(copy_parent_id);
    const copy_tool_name = try allocator.dupe(u8, input.tool_name orelse "");
    defer allocator.free(copy_tool_name);
    const copy_tool_call_id = try allocator.dupe(u8, input.tool_call_id orelse "");
    defer allocator.free(copy_tool_call_id);
    const prompt_tokens_str = try std.fmt.allocPrint(allocator, "{}", .{input.prompt_tokens});
    defer allocator.free(prompt_tokens_str);
    const completion_tokens_str = try std.fmt.allocPrint(allocator, "{}", .{input.completion_tokens});
    defer allocator.free(completion_tokens_str);
    const total_tokens_str = try std.fmt.allocPrint(allocator, "{}", .{input.total_tokens});
    defer allocator.free(total_tokens_str);
    const cache_creation_input_tokens_str = try std.fmt.allocPrint(allocator, "{}", .{input.cache_creation_input_tokens});
    defer allocator.free(cache_creation_input_tokens_str);
    const cache_read_input_tokens_str = try std.fmt.allocPrint(allocator, "{}", .{input.cache_read_input_tokens});
    defer allocator.free(cache_read_input_tokens_str);
    const copy_diffview_before = try allocator.dupe(u8, input.diffview_before orelse "");
    defer allocator.free(copy_diffview_before);
    const copy_diffview_after = try allocator.dupe(u8, input.diffview_after orelse "");
    defer allocator.free(copy_diffview_after);

    const copy_is_feed_to_llm = try allocator.dupe(u8, if (input.is_feed_to_llm) "1" else "0");
    defer allocator.free(copy_is_feed_to_llm);

    // Join multiple image URLs with || delimiter
    var image_urls_str: []const u8 = "";
    var copy_image_urls: ?[]u8 = null;
    if (input.image_urls) |urls| {
        if (urls.len > 0) {
            var combined = std.ArrayList(u8).empty;
            defer combined.deinit(allocator);
            for (urls, 0..) |url, i| {
                if (i > 0) try combined.appendSlice(allocator, "||");
                try combined.appendSlice(allocator, url);
            }
            copy_image_urls = try allocator.dupe(u8, combined.items);
            image_urls_str = copy_image_urls.?;
        }
    }
    defer if (copy_image_urls) |c| allocator.free(c);

    // Join multiple video URLs with || delimiter (empty string binds as
    // '' literal downstream — never pass a zero-length slice as a bind
    // arg since Backend.exec binds "" as NULL).
    var video_urls_str: []const u8 = "";
    var copy_video_urls: ?[]u8 = null;
    if (input.video_urls) |urls| {
        if (urls.len > 0) {
            var combined = std.ArrayList(u8).empty;
            defer combined.deinit(allocator);
            for (urls, 0..) |url, i| {
                if (i > 0) try combined.appendSlice(allocator, "||");
                try combined.appendSlice(allocator, url);
            }
            copy_video_urls = try allocator.dupe(u8, combined.items);
            video_urls_str = copy_video_urls.?;
        }
    }
    defer if (copy_video_urls) |c| allocator.free(c);

    const sqlArgs = &.{ id, copy_session_id, copy_model, copy_content, copy_finish_reason, copy_role, copy_tool_calls, copy_tool_call_id, copy_reasoning, copy_reasoning_id, copy_reasoning_encrypted_content, copy_is_feed_to_llm, copy_agent, loop_index_str, temperature_str, is_thinking_str, created_at_nano, created_iso, copy_parent_session_id, copy_parent_id, prompt_tokens_str, completion_tokens_str, total_tokens_str, cache_creation_input_tokens_str, cache_read_input_tokens_str, if (input.is_input) "1" else "0", if (input.is_output) "1" else "0", copy_tool_name, copy_diffview_before, copy_diffview_after, image_urls_str, video_urls_str };

    try db.exec(allocator, sql, sqlArgs);

    // Update the session's cwd in the sessions table
    const copy_cwd = try allocator.dupe(u8, input.cwd);
    defer allocator.free(copy_cwd);
    try db.exec(allocator, "UPDATE sessions SET cwd = ?, updated_at = CURRENT_TIMESTAMP WHERE id = ?", &.{ copy_cwd, copy_session_id });
}
// =============================================================================
// Get Messages Functions
// =============================================================================

pub fn getMessages(
    allocator: std.mem.Allocator,
    db: *database.Db,
    session_id: []const u8,
) ![]TUIHistory {
    var results: std.ArrayList(TUIHistory) = .empty;

    const sql =
        \\SELECT
        \\    h.id, h.session_id, h.model, h.created_at_nano AS created_at,
        \\    h.response_content, h.finish_reason,
        \\    COALESCE(h.role, 'assistant'),
        \\    COALESCE(h.tool_calls_json, ''),
        \\    COALESCE(h.reasoning_content, ''),
        \\    COALESCE(h.reasoning_id, ''),
        \\    COALESCE(h.reasoning_encrypted_content, ''),
        \\    COALESCE(h.agent, 'Agent'),
        \\    COALESCE(s.name, ''),
        \\    COALESCE(h.loop_index, 0),
        \\    COALESCE(h.tool_name, ''),
        \\    COALESCE(h.parent_session_id, ''),
        \\    COALESCE(h.temperature, 0.2),
        \\    COALESCE(h.is_thinking, 0),
        \\    COALESCE(h.prompt_tokens, 0),
        \\    COALESCE(h.completion_tokens, 0),
        \\    COALESCE(h.total_tokens, 0),
        \\    COALESCE(h.is_input, 0),
        \\    COALESCE(h.is_output, 0),
        \\    COALESCE(h.diffview_before, ''),
        \\    COALESCE(h.diffview_after, ''),
        \\    COALESCE(h.image_url, ''),
        \\    COALESCE(h.video_url, ''),
        \\    COALESCE(h.tool_call_id, '')
        \\FROM llm_history h
        \\LEFT JOIN sessions s ON h.session_id = s.id
        \\WHERE h.session_id = ?
        \\AND (h.is_feed_to_llm = 1 OR h.is_feed_to_llm IS NULL)
        \\ORDER BY h.created_at_nano ASC
    ;

    var rows = try db.query(allocator, sql, &.{session_id});
    defer rows.deinit();

    while (try rows.next()) |row| {
        const parent_session_id_str = row.values[15];
        const diffview_before_str = row.values[23];
        const diffview_after_str = row.values[24];
        const image_url_str = row.values[25];
        const video_url_str = row.values[26];
        const history = TUIHistory{
            .id = try allocator.dupe(u8, row.values[0]),
            .session_id = try allocator.dupe(u8, row.values[1]),
            .model = try allocator.dupe(u8, row.values[2]),
            .created_at = try allocator.dupe(u8, row.values[3]),
            .response_content = try allocator.dupe(u8, row.values[4]),
            .finish_reason = try allocator.dupe(u8, row.values[5]),
            .role = try allocator.dupe(u8, row.values[6]),
            .tools = try allocator.dupe(u8, row.values[7]),
            .reasoning_content = if (row.values[8].len > 0) try allocator.dupe(u8, row.values[8]) else null,
            .reasoning_id = if (row.values[9].len > 0) try allocator.dupe(u8, row.values[9]) else null,
            .reasoning_encrypted_content = if (row.values[10].len > 0) try allocator.dupe(u8, row.values[10]) else null,
            .agent = try allocator.dupe(u8, row.values[11]),
            .session_name = try allocator.dupe(u8, row.values[12]),
            .loop_index = std.fmt.parseInt(u32, row.values[13], 10) catch 0,
            .tool_name = try allocator.dupe(u8, row.values[14]),
            .parent_session_id = if (parent_session_id_str.len > 0) try allocator.dupe(u8, parent_session_id_str) else null,
            .temperature = std.fmt.parseFloat(f32, row.values[16]) catch 0.2,
            .is_thinking = std.mem.eql(u8, row.values[17], "1"),
            .prompt_tokens = std.fmt.parseInt(u32, row.values[18], 10) catch 0,
            .completion_tokens = std.fmt.parseInt(u32, row.values[19], 10) catch 0,
            .total_tokens = std.fmt.parseInt(u32, row.values[20], 10) catch 0,
            .is_input = parseRowBool(row.values[21]),
            .is_output = parseRowBool(row.values[22]),
            .diffview_before = if (diffview_before_str.len > 0) try allocator.dupe(u8, diffview_before_str) else null,
            .diffview_after = if (diffview_after_str.len > 0) try allocator.dupe(u8, diffview_after_str) else null,
            .image_urls = if (image_url_str.len > 0) blk: {
                var urls = std.ArrayList([]const u8).empty;
                errdefer {
                    for (urls.items) |u| allocator.free(u);
                    urls.deinit(allocator);
                }
                var iter = std.mem.splitScalar(u8, image_url_str, '|');
                while (iter.next()) |url| {
                    if (url.len > 0) {
                        try urls.append(allocator, try allocator.dupe(u8, url));
                    }
                }
                break :blk if (urls.items.len > 0) urls.items else null;
            } else null,
            .video_urls = if (video_url_str.len > 0) blk: {
                var urls = std.ArrayList([]const u8).empty;
                errdefer {
                    for (urls.items) |u| allocator.free(u);
                    urls.deinit(allocator);
                }
                var iter = std.mem.splitScalar(u8, video_url_str, '|');
                while (iter.next()) |url| {
                    if (url.len > 0) {
                        try urls.append(allocator, try allocator.dupe(u8, url));
                    }
                }
                break :blk if (urls.items.len > 0) urls.items else null;
            } else null,
            .tool_call_id = if (row.values[27].len > 0) try allocator.dupe(u8, row.values[27]) else null,
        };
        try results.append(allocator, history);
        row.deinit(allocator);
    }

    return results.toOwnedSlice(allocator);
}

// =============================================================================
// Compacted Messages Query (is_feed_to_llm = 0)
// =============================================================================

/// Filter on the `is_feed_to_llm` column.
pub const FeedFilter = enum { all, live_only, compacted_only };

/// Options for filtering `getCompactedMessages`.
pub const CompactedMessagesOptions = struct {
    /// When non-null, only return messages whose id is in this list.
    /// Used by `read_workspace_session` (READ with message_ids=[...]).
    message_ids: ?[]const []const u8 = null,
    /// When non-null, only return messages with `role` matching this value
    /// (e.g. "user", "assistant", "tool").
    role: ?[]const u8 = null,
    /// When non-null, only return messages with `created_at >= since`.
    since: ?[]const u8 = null,
    /// When non-null, only return messages with `created_at <= until`.
    until: ?[]const u8 = null,
    /// When non-null, only return messages with `tool_name` matching
    /// this value exactly (e.g. "bash", "read_file", "read_workspace_session").
    /// Useful for "all `bash` invocations that ran `cargo test`".
    tool_name: ?[]const u8 = null,
    /// When non-null, only return messages with `parent_session_id` matching
    /// this value. Used for sub-agent debugging — find every message in
    /// any session whose parent is the given session id.
    parent_session_id: ?[]const u8 = null,
    /// When non-null, only return messages with `agent` matching this value
    /// exactly. Useful when one session has multiple agents (planning vs
    /// chat vs sub-agent).
    agent: ?[]const u8 = null,
    /// Max number of rows to return. Defaults to 100 for safety — the caller
    /// can request up to 1000 explicitly. The `read_workspace_session` tool
    /// wraps this in its own user-facing limit parameter.
    limit: ?u32 = 100,
    /// DEPRECATED alias for `feed_filter = .all`. When `true`, equivalent to
    /// `feed_filter = .all`; when `false` (default), equivalent to
    /// `feed_filter = .compacted_only`.
    include_all: bool = false,
    /// When non-null, restrict rows by their `is_feed_to_llm` value via this
    /// enum.
    feed_filter: ?FeedFilter = null,
    /// Sort direction for `created_at`. Default `.asc` (chronological
    /// forward).
    order: Order = .asc,

    /// Named enum so callers can reference it as
    /// `llm_history.CompactedMessagesOptions.Order` and use
    /// `@tagName(...)` to render it as a string for the wire format.
    pub const Order = enum { asc, desc };

    /// Resolve the effective feed filter, falling back to the legacy
    /// `include_all` boolean when `feed_filter` was not explicitly set.
    pub fn effectiveFeedFilter(self: CompactedMessagesOptions) FeedFilter {
        if (self.feed_filter) |ff| return ff;
        return if (self.include_all) .all else .compacted_only;
    }
};

/// Lighter-weight return struct than `TUIHistory` — only the fields the
/// `read_workspace_session` tool actually surfaces.
pub const CompactedMessage = struct {
    id: []const u8,
    session_id: []const u8,
    role: []const u8,
    content: []const u8,
    tool_call_id: ?[]const u8,
    tool_name: ?[]const u8,
    model: []const u8,
    agent: []const u8,
    created_at: []const u8,
    /// Total number of rows that matched the WHERE clause (before LIMIT).
    /// Surfaced via `COUNT(*) OVER ()` so it's computed in the same query.
    total_count: u32,

    pub fn deinit(self: *const CompactedMessage, allocator: std.mem.Allocator) void {
        allocator.free(self.id);
        allocator.free(self.session_id);
        allocator.free(self.role);
        allocator.free(self.content);
        allocator.free(self.model);
        allocator.free(self.agent);
        allocator.free(self.created_at);
        if (self.tool_call_id) |t| allocator.free(t);
        if (self.tool_name) |t| allocator.free(t);
    }
};

/// Options for `searchMessagesFts`. Mirrors the shape of
/// `CompactedMessagesOptions` so callers can build either kind of query
/// with a consistent input.
pub const SearchOptions = struct {
    /// When non-null, only return hits whose `llm_history.session_id` equals this.
    /// Useful for "search within this conversation only".
    session_id: ?[]const u8 = null,
    /// When non-null and non-empty, only return hits whose
    /// `llm_history.session_id` is in this list.
    session_ids: ?[]const []const u8 = null,
    /// When non-null, exact-match filter on `llm_history.role` ("user", "assistant", "tool").
    role: ?[]const u8 = null,
    /// When non-null, lower bound on `created_at` (inclusive, lex-sort = chrono-sort).
    since: ?[]const u8 = null,
    /// When non-null, upper bound on `created_at` (inclusive).
    until: ?[]const u8 = null,
    /// When non-null, restrict rows by their `is_feed_to_llm` value via
    /// the `FeedFilter` enum. See `getCompactedMessages` for the
    /// per-enum-value SQL mapping. Default = `.all` (no filter).
    feed_filter: FeedFilter = .all,
    /// When non-null, exact-match filter on `llm_history.tool_name`.
    /// e.g. `tool_name = "bash"` returns only `role=tool` rows where the
    /// tool that produced the result was `bash`.
    tool_name: ?[]const u8 = null,
    /// When non-null, exact-match filter on `llm_history.parent_session_id`.
    /// e.g. `parent_session_id = "s_parent"` returns only rows in any
    /// session whose parent is `s_parent` (typically sub-agent runs).
    parent_session_id: ?[]const u8 = null,
    /// When non-null, exact-match filter on `llm_history.agent`.
    agent: ?[]const u8 = null,
    /// Max rows to return. Defaults to 20 for safety; the caller can
    /// request up to 200 (the tool layer caps there). The FTS ranking
    /// does the rest of the filtering.
    limit: ?u32 = 20,
    /// Skip the first N results. Used by `read_workspace_session` search to
    /// walk forward through FTS results that exceed `limit`.
    offset: ?u32 = null,
};

/// One FTS hit. Mirrors `CompactedMessage` but adds `snippet` (the
/// FTS5-generated preview with `[match]` markers around matched tokens).
pub const SearchHit = struct {
    id: []const u8,
    session_id: []const u8,
    role: []const u8,
    snippet: []const u8,
    tool_call_id: ?[]const u8,
    tool_name: ?[]const u8,
    created_at: []const u8,
    /// Total number of rows that matched the WHERE clause (before LIMIT and
    /// OFFSET). Surfaced via `COUNT(*) OVER ()` so it's computed in the same
    /// query.
    total_count: u32,

    pub fn deinit(self: *const SearchHit, allocator: std.mem.Allocator) void {
        allocator.free(self.id);
        allocator.free(self.session_id);
        allocator.free(self.role);
        allocator.free(self.snippet);
        allocator.free(self.created_at);
        if (self.tool_call_id) |t| allocator.free(t);
        if (self.tool_name) |t| allocator.free(t);
    }
};

/// Return messages for the given session.
pub fn getCompactedMessages(
    allocator: std.mem.Allocator,
    db: *database.Db,
    session_id: []const u8,
    opts: CompactedMessagesOptions,
) ![]CompactedMessage {
    const effective_limit = opts.limit orelse 100;

    // Build the WHERE clause incrementally. Each filter appends AND <clause>
    // to the base `h.session_id = ?`.
    var sql: std.ArrayList(u8) = .empty;
    defer sql.deinit(allocator);
    try sql.appendSlice(allocator,
        \\SELECT
        \\    h.id, h.session_id, COALESCE(h.role, 'assistant'),
        \\    COALESCE(h.response_content, ''),
        \\    h.tool_call_id, h.tool_name,
        \\    COALESCE(h.model, ''), COALESCE(h.agent, ''),
        \\    COALESCE(CAST(h.created_at_nano AS TEXT), '') AS created_at,
        \\    COUNT(*) OVER () AS total
        \\FROM llm_history h
        \\WHERE h.session_id = ?
    );

    switch (opts.effectiveFeedFilter()) {
        .all => {},
        .live_only => try sql.appendSlice(allocator, " AND h.is_feed_to_llm = 1"),
        .compacted_only => try sql.appendSlice(allocator, " AND h.is_feed_to_llm = 0"),
    }

    var bind_values: std.ArrayList([]const u8) = .empty;
    defer bind_values.deinit(allocator);
    try bind_values.append(allocator, session_id);

    if (opts.message_ids) |ids| {
        if (ids.len > 0) {
            try sql.appendSlice(allocator, " AND h.id IN (");
            for (ids, 0..) |id, i| {
                if (i > 0) try sql.append(allocator, ',');
                try sql.append(allocator, '?');
                try bind_values.append(allocator, id);
            }
            try sql.append(allocator, ')');
        }
    }

    if (opts.role) |r| {
        try sql.appendSlice(allocator, " AND h.role = ?");
        try bind_values.append(allocator, r);
    }

    if (opts.tool_name) |tn| {
        try sql.appendSlice(allocator, " AND h.tool_name = ?");
        try bind_values.append(allocator, tn);
    }

    if (opts.parent_session_id) |psid| {
        try sql.appendSlice(allocator, " AND h.parent_session_id = ?");
        try bind_values.append(allocator, psid);
    }

    if (opts.agent) |a| {
        try sql.appendSlice(allocator, " AND h.agent = ?");
        try bind_values.append(allocator, a);
    }

    if (opts.since) |s| {
        try sql.appendSlice(allocator, " AND h.created_iso >= ?");
        try bind_values.append(allocator, s);
    }

    if (opts.until) |u| {
        try sql.appendSlice(allocator, " AND h.created_iso <= ?");
        try bind_values.append(allocator, u);
    }

    try sql.print(allocator, " ORDER BY h.created_at_nano {s}", .{@tagName(opts.order)});

    // Bind the limit at the end. Format inline since we know it's u32.
    try sql.print(allocator, " LIMIT {d}", .{effective_limit});

    var rows = try db.query(allocator, sql.items, bind_values.items);
    defer rows.deinit();

    var results: std.ArrayList(CompactedMessage) = .empty;
    errdefer {
        for (results.items) |m| {
            var copy = m;
            copy.deinit(allocator);
        }
        results.deinit(allocator);
    }

    while (try rows.next()) |row| {
        defer row.deinit(allocator);
        // `total` is column index 9 (COUNT(*) OVER ()) — computed before
        // LIMIT/OFFSET so it represents the total count of rows that
        // matched the WHERE clause, not the returned page size.
        const total_count: u32 = std.fmt.parseInt(u32, row.values[9], 10) catch 0;
        const msg = CompactedMessage{
            .id = try allocator.dupe(u8, row.values[0]),
            .session_id = try allocator.dupe(u8, row.values[1]),
            .role = try allocator.dupe(u8, row.values[2]),
            .content = try allocator.dupe(u8, row.values[3]),
            .tool_call_id = if (row.values[4].len > 0) try allocator.dupe(u8, row.values[4]) else null,
            .tool_name = if (row.values[5].len > 0) try allocator.dupe(u8, row.values[5]) else null,
            .model = try allocator.dupe(u8, row.values[6]),
            .agent = try allocator.dupe(u8, row.values[7]),
            .created_at = try allocator.dupe(u8, row.values[8]),
            .total_count = total_count,
        };
        try results.append(allocator, msg);
    }

    return try results.toOwnedSlice(allocator);
}

/// Look up messages by id alone, without a `session_id` filter.
pub fn getMessagesByIds(
    allocator: std.mem.Allocator,
    db: *database.Db,
    ids: []const []const u8,
) ![]CompactedMessage {
    if (ids.len == 0) return &.{};

    var sql: std.ArrayList(u8) = .empty;
    defer sql.deinit(allocator);
    try sql.appendSlice(allocator,
        \\SELECT
        \\    h.id, h.session_id, COALESCE(h.role, 'assistant'),
        \\    COALESCE(h.response_content, ''),
        \\    h.tool_call_id, h.tool_name,
        \\    COALESCE(h.model, ''), COALESCE(h.agent, ''),
        \\    COALESCE(CAST(h.created_at_nano AS TEXT), '') AS created_at,
        \\    COUNT(*) OVER () AS total
        \\FROM llm_history h
        \\WHERE h.id IN (
    );
    var bind_values: std.ArrayList([]const u8) = .empty;
    defer bind_values.deinit(allocator);
    for (ids, 0..) |id, i| {
        if (i > 0) try sql.append(allocator, ',');
        try sql.append(allocator, '?');
        try bind_values.append(allocator, id);
    }
    try sql.appendSlice(allocator, ")");

    var rows = try db.query(allocator, sql.items, bind_values.items);
    defer rows.deinit();

    var results: std.ArrayList(CompactedMessage) = .empty;
    errdefer {
        for (results.items) |m| {
            var copy = m;
            copy.deinit(allocator);
        }
        results.deinit(allocator);
    }

    while (try rows.next()) |row| {
        defer row.deinit(allocator);
        const total_count: u32 = std.fmt.parseInt(u32, row.values[9], 10) catch 0;
        const msg = CompactedMessage{
            .id = try allocator.dupe(u8, row.values[0]),
            .session_id = try allocator.dupe(u8, row.values[1]),
            .role = try allocator.dupe(u8, row.values[2]),
            .content = try allocator.dupe(u8, row.values[3]),
            .tool_call_id = if (row.values[4].len > 0) try allocator.dupe(u8, row.values[4]) else null,
            .tool_name = if (row.values[5].len > 0) try allocator.dupe(u8, row.values[5]) else null,
            .model = try allocator.dupe(u8, row.values[6]),
            .agent = try allocator.dupe(u8, row.values[7]),
            .created_at = try allocator.dupe(u8, row.values[8]),
            .total_count = total_count,
        };
        try results.append(allocator, msg);
    }

    return try results.toOwnedSlice(allocator);
}

/// Walks the tokens of a search query: alphanumerics and `_`, everything else
/// is a boundary. Shared by both engines' query builders.
const Tokenizer = struct {
    query: []const u8,
    at: usize = 0,

    fn next(self: *Tokenizer) ?[]const u8 {
        while (self.at < self.query.len and !isTokenChar(self.query[self.at])) self.at += 1;
        if (self.at >= self.query.len) return null;
        const start = self.at;
        while (self.at < self.query.len and isTokenChar(self.query[self.at])) self.at += 1;
        return self.query[start..self.at];
    }

    fn isTokenChar(c: u8) bool {
        return std.ascii.isAlphanumeric(c) or c == '_';
    }
};

/// The query text sqlite's FTS5 `MATCH` takes: every token a quoted phrase,
/// OR-ed together, so an operator in the user's text cannot break the parser.
pub fn escapeFtsQuery(allocator: std.mem.Allocator, query: []const u8) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);

    var it = Tokenizer{ .query = query };
    var first_token = true;
    while (it.next()) |token| {
        if (!first_token) try out.appendSlice(allocator, " OR ");
        try out.append(allocator, '"');
        try out.appendSlice(allocator, token);
        try out.append(allocator, '"');
        first_token = false;
    }
    return out.toOwnedSlice(allocator);
}

/// The query text postgres' `to_tsquery` takes: the same tokens, OR-ed.
/// `to_tsquery` rejects the phrase quotes FTS5 wants, so bare lexemes.
pub fn escapeTsQuery(allocator: std.mem.Allocator, query: []const u8) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);

    var it = Tokenizer{ .query = query };
    var first_token = true;
    while (it.next()) |token| {
        if (!first_token) try out.appendSlice(allocator, " | ");
        try out.appendSlice(allocator, token);
        first_token = false;
    }
    return out.toOwnedSlice(allocator);
}

/// The engine's query text for `query`: FTS5 phrases or a postgres tsquery.
pub fn searchQueryText(allocator: std.mem.Allocator, query: []const u8) ![]u8 {
    return if (dialect.is_postgres)
        escapeTsQuery(allocator, query)
    else
        escapeFtsQuery(allocator, query);
}

// ---------------------------------------------------------------------------
// escapeFtsQuery inline tests
// ---------------------------------------------------------------------------

test "escapeFtsQuery: single token is emitted in phrase quotes (no OR)" {
    const alloc = testing.allocator;
    const out = try escapeFtsQuery(alloc, "preferred");
    defer alloc.free(out);
    try testing.expectEqualStrings("\"preferred\"", out);
}

test "escapeFtsQuery: multi-token query is joined with OR for natural recall" {
    const alloc = testing.allocator;
    const out = try escapeFtsQuery(alloc, "preferred model");
    defer alloc.free(out);
    try testing.expectEqualStrings("\"preferred\" OR \"model\"", out);
}

test "escapeFtsQuery: three or more tokens also joined with OR" {
    const alloc = testing.allocator;
    const out = try escapeFtsQuery(alloc, "CI frontend bun");
    defer alloc.free(out);
    try testing.expectEqualStrings("\"CI\" OR \"frontend\" OR \"bun\"", out);
}

test "escapeFtsQuery: consecutive whitespace collapses to single token boundary" {
    const alloc = testing.allocator;
    const out = try escapeFtsQuery(alloc, "preferred   model");
    defer alloc.free(out);
    try testing.expectEqualStrings("\"preferred\" OR \"model\"", out);
}

test "escapeFtsQuery: FTS5 operators are replaced with token boundaries" {
    const alloc = testing.allocator;

    // Each operator becomes a token boundary — adjacent operators
    // don't collapse to a single boundary.
    {
        const out = try escapeFtsQuery(alloc, "2026-08-06");
        defer alloc.free(out);
        try testing.expectEqualStrings("\"2026\" OR \"08\" OR \"06\"", out);
    }

    // Colon-filter syntax (`tags: user`) becomes two tokens.
    {
        const out = try escapeFtsQuery(alloc, "tags: user");
        defer alloc.free(out);
        try testing.expectEqualStrings("\"tags\" OR \"user\"", out);
    }

    // Slash is also an FTS5 operator (not just `.`, `-`, `:`).
    {
        const out = try escapeFtsQuery(alloc, "agentic_loop/handle_tool.zig:18");
        defer alloc.free(out);
        try testing.expectEqualStrings(
            "\"agentic_loop\" OR \"handle_tool\" OR \"zig\" OR \"18\"",
            out,
        );
    }
}

test "escapeFtsQuery: underscore is part of a token (not a separator)" {
    const alloc = testing.allocator;
    const out = try escapeFtsQuery(alloc, "handle_tool");
    defer alloc.free(out);
    try testing.expectEqualStrings("\"handle_tool\"", out);
}

test "escapeFtsQuery: empty input returns empty string" {
    const alloc = testing.allocator;
    const out = try escapeFtsQuery(alloc, "");
    defer alloc.free(out);
    try testing.expectEqualStrings("", out);
}

test "escapeFtsQuery: all-special-chars input returns empty string (no usable tokens)" {
    const alloc = testing.allocator;
    const out = try escapeFtsQuery(alloc, "+++**::..//");
    defer alloc.free(out);
    try testing.expectEqualStrings("", out);
}

test "escapeFtsQuery: leading/trailing whitespace is harmless" {
    const alloc = testing.allocator;
    const out = try escapeFtsQuery(alloc, "  hello world  ");
    defer alloc.free(out);
    try testing.expectEqualStrings("\"hello\" OR \"world\"", out);
}

test "escapeFtsQuery: realistic multi-word recall query (regression for task_1787050039216_3)" {
    // The user's complaint: load_memory({query: "preferred model"}) returned
    // 0 hits because the query was wrapped in FTS5 phrase syntax.
    const alloc = testing.allocator;
    const out = try escapeFtsQuery(alloc, "preferred model");
    defer alloc.free(out);
    try testing.expectEqualStrings("\"preferred\" OR \"model\"", out);
}

pub fn searchMessagesFts(
    allocator: std.mem.Allocator,
    db: *database.Db,
    query: []const u8,
    opts: SearchOptions,
) ![]SearchHit {
    const effective_limit = opts.limit orelse 20;

    // Sanitize the user query so plain text with FTS5 operators (`.`, `-`,
    // `:`) doesn't blow up the MATCH parser. See `escapeFtsQuery` for the
    // full rationale and the exact transformation.
    const sanitized_query = try searchQueryText(allocator, query);
    defer allocator.free(sanitized_query);
    // Empty after sanitization (query was all FTS5 operators) — bail
    // before FTS5 sees `MATCH ''` and throws "empty query".
    if (sanitized_query.len == 0) return allocator.alloc(SearchHit, 0);

    var sql: std.ArrayList(u8) = .empty;
    defer sql.deinit(allocator);
    // The subquery is the only engine-specific part: sqlite reads the FTS5
    // index through `messages_fts`, postgres ranks `to_tsvector` directly.
    if (dialect.is_postgres) {
        try sql.appendSlice(allocator,
            \\SELECT
            \\    id, session_id, role, snippet, tool_call_id, tool_name, created_at,
            \\    COUNT(*) OVER () AS total
            \\FROM (
            \\    SELECT
            \\        h.id AS id, h.session_id AS session_id,
            \\        COALESCE(h.role, 'assistant') AS role,
            \\        ts_headline('simple'::regconfig, COALESCE(h.response_content, ''), q.tsq,
            \\                    'StartSel=[, StopSel=], MaxWords=10, MinWords=3') AS snippet,
            \\        h.tool_call_id AS tool_call_id,
            \\        h.tool_name AS tool_name,
            \\        COALESCE(NULLIF(h.created_iso, ''), CAST(h.created_at_nano AS TEXT), '') AS created_at,
            \\        -ts_rank(to_tsvector('simple'::regconfig, COALESCE(h.response_content, '')), q.tsq) AS fts_rank
            \\    FROM llm_history h, to_tsquery('simple'::regconfig, ?) AS q(tsq)
            \\    WHERE to_tsvector('simple'::regconfig, COALESCE(h.response_content, '')) @@ q.tsq
        );
    } else {
        // Wrap FTS5 access in a subquery so the COUNT(*) OVER () window
        // function runs over the regular subquery result, not directly over
        // the FTS5 virtual table.
        try sql.appendSlice(allocator,
            \\SELECT
            \\    id, session_id, role, snippet, tool_call_id, tool_name, created_at,
            \\    COUNT(*) OVER () AS total
            \\FROM (
            \\    SELECT
            \\        h.id AS id, h.session_id AS session_id,
            \\        COALESCE(h.role, 'assistant') AS role,
            \\        snippet(messages_fts, 0, '[', ']', '...', 10) AS snippet,
            \\        h.tool_call_id AS tool_call_id,
            \\        h.tool_name AS tool_name,
            \\        COALESCE(NULLIF(h.created_iso, ''), h.created_at_nano, '') AS created_at,
            \\        rank AS fts_rank
            \\    FROM messages_fts
            \\    JOIN llm_history h ON h.rowid = messages_fts.rowid
            \\    WHERE messages_fts MATCH ?
        );
    }

    var bind_values: std.ArrayList([]const u8) = .empty;
    defer bind_values.deinit(allocator);
    try bind_values.append(allocator, sanitized_query);

    if (opts.session_id) |sid| {
        try sql.appendSlice(allocator, " AND h.session_id = ?");
        try bind_values.append(allocator, sid);
    }

    if (opts.session_ids) |sids| {
        if (sids.len > 0) {
            try sql.appendSlice(allocator, " AND h.session_id IN (");
            for (sids, 0..) |sid, i| {
                if (i > 0) try sql.append(allocator, ',');
                try sql.append(allocator, '?');
                try bind_values.append(allocator, sid);
            }
            try sql.append(allocator, ')');
        }
    }

    if (opts.role) |r| {
        try sql.appendSlice(allocator, " AND h.role = ?");
        try bind_values.append(allocator, r);
    }

    switch (opts.feed_filter) {
        .all => {},
        .live_only => try sql.appendSlice(allocator, " AND h.is_feed_to_llm = 1"),
        .compacted_only => try sql.appendSlice(allocator, " AND h.is_feed_to_llm = 0"),
    }

    if (opts.tool_name) |tn| {
        try sql.appendSlice(allocator, " AND h.tool_name = ?");
        try bind_values.append(allocator, tn);
    }

    if (opts.parent_session_id) |psid| {
        try sql.appendSlice(allocator, " AND h.parent_session_id = ?");
        try bind_values.append(allocator, psid);
    }

    if (opts.agent) |a| {
        try sql.appendSlice(allocator, " AND h.agent = ?");
        try bind_values.append(allocator, a);
    }

    if (opts.since) |s| {
        try sql.appendSlice(allocator, " AND h.created_iso >= ?");
        try bind_values.append(allocator, s);
    }

    if (opts.until) |u| {
        try sql.appendSlice(allocator, " AND h.created_iso <= ?");
        try bind_values.append(allocator, u);
    }

    // Close the subquery, then ORDER BY the aliased rank column from inside it.
    try sql.appendSlice(allocator, ") AS hits ORDER BY fts_rank");
    try sql.print(allocator, " LIMIT {d}", .{effective_limit});
    if ((opts.offset orelse 0) > 0) {
        try sql.print(allocator, " OFFSET {d}", .{opts.offset.?});
    }

    var rows = try db.query(allocator, sql.items, bind_values.items);
    defer rows.deinit();

    var results: std.ArrayList(SearchHit) = .empty;
    errdefer {
        for (results.items) |h| {
            var copy = h;
            copy.deinit(allocator);
        }
        results.deinit(allocator);
    }

    while (try rows.next()) |row| {
        defer row.deinit(allocator);
        // `total` is column index 7 (COUNT(*) OVER ()) — computed
        // before LIMIT/OFFSET so it represents the total count of rows
        // that matched the WHERE clause, not the returned page size.
        const total_count: u32 = std.fmt.parseInt(u32, row.values[7], 10) catch 0;
        const hit = SearchHit{
            .id = try allocator.dupe(u8, row.values[0]),
            .session_id = try allocator.dupe(u8, row.values[1]),
            .role = try allocator.dupe(u8, row.values[2]),
            .snippet = try allocator.dupe(u8, row.values[3]),
            .tool_call_id = if (row.values[4].len > 0) try allocator.dupe(u8, row.values[4]) else null,
            .tool_name = if (row.values[5].len > 0) try allocator.dupe(u8, row.values[5]) else null,
            .created_at = try allocator.dupe(u8, row.values[6]),
            .total_count = total_count,
        };
        try results.append(allocator, hit);
    }

    return try results.toOwnedSlice(allocator);
}

pub fn getLatestMessage(
    allocator: std.mem.Allocator,
    db: *database.Db,
    session_id: []const u8,
) !?TUIHistory {
    const sql =
        \\SELECT
        \\    h.id, h.session_id, h.model, h.created_at_nano AS created_at,
        \\    h.response_content, h.finish_reason,
        \\    COALESCE(h.role, 'assistant'),
        \\    COALESCE(h.tool_calls_json, ''),
        \\    COALESCE(h.reasoning_content, ''),
        \\    COALESCE(h.reasoning_id, ''),
        \\    COALESCE(h.reasoning_encrypted_content, ''),
        \\    COALESCE(h.agent, 'Agent'),
        \\    COALESCE(s.name, ''),
        \\    COALESCE(h.loop_index, 0),
        \\    COALESCE(h.tool_name, ''),
        \\    COALESCE(h.parent_session_id, ''),
        \\    COALESCE(h.temperature, 0.2),
        \\    COALESCE(h.is_thinking, 0),
        \\    COALESCE(h.prompt_tokens, 0),
        \\    COALESCE(h.completion_tokens, 0),
        \\    COALESCE(h.total_tokens, 0),
        \\    COALESCE(h.is_input, 0),
        \\    COALESCE(h.is_output, 0),
        \\    COALESCE(h.diffview_before, ''),
        \\    COALESCE(h.diffview_after, ''),
        \\    COALESCE(h.image_url, ''),
        \\    COALESCE(h.video_url, ''),
        \\    COALESCE(h.tool_call_id, '')
        \\FROM llm_history h
        \\LEFT JOIN sessions s ON h.session_id = s.id
        \\WHERE h.session_id = ?
        \\AND (h.is_feed_to_llm = 1 OR h.is_feed_to_llm IS NULL)
        \\ORDER BY h.created_at_nano DESC
        \\LIMIT 1
    ;

    var rows = try db.query(allocator, sql, &.{session_id});
    defer rows.deinit();

    if (try rows.next()) |row| {
        const parent_session_id_str = row.values[15];
        const diffview_before_str = row.values[23];
        const diffview_after_str = row.values[24];
        const image_url_str = row.values[25];
        const video_url_str = row.values[26];
        const history = TUIHistory{
            .id = try allocator.dupe(u8, row.values[0]),
            .session_id = try allocator.dupe(u8, row.values[1]),
            .model = try allocator.dupe(u8, row.values[2]),
            .created_at = try allocator.dupe(u8, row.values[3]),
            .response_content = try allocator.dupe(u8, row.values[4]),
            .finish_reason = try allocator.dupe(u8, row.values[5]),
            .role = try allocator.dupe(u8, row.values[6]),
            .tools = try allocator.dupe(u8, row.values[7]),
            .reasoning_content = if (row.values[8].len > 0) try allocator.dupe(u8, row.values[8]) else null,
            .reasoning_id = if (row.values[9].len > 0) try allocator.dupe(u8, row.values[9]) else null,
            .reasoning_encrypted_content = if (row.values[10].len > 0) try allocator.dupe(u8, row.values[10]) else null,
            .agent = try allocator.dupe(u8, row.values[11]),
            .session_name = try allocator.dupe(u8, row.values[12]),
            .loop_index = std.fmt.parseInt(u32, row.values[13], 10) catch 0,
            .tool_name = try allocator.dupe(u8, row.values[14]),
            .parent_session_id = if (parent_session_id_str.len > 0) try allocator.dupe(u8, parent_session_id_str) else null,
            .temperature = std.fmt.parseFloat(f32, row.values[16]) catch 0.2,
            .is_thinking = std.mem.eql(u8, row.values[17], "1"),
            .prompt_tokens = std.fmt.parseInt(u32, row.values[18], 10) catch 0,
            .completion_tokens = std.fmt.parseInt(u32, row.values[19], 10) catch 0,
            .total_tokens = std.fmt.parseInt(u32, row.values[20], 10) catch 0,
            .is_input = parseRowBool(row.values[21]),
            .is_output = parseRowBool(row.values[22]),
            .diffview_before = if (diffview_before_str.len > 0) try allocator.dupe(u8, diffview_before_str) else null,
            .diffview_after = if (diffview_after_str.len > 0) try allocator.dupe(u8, diffview_after_str) else null,
            .image_urls = if (image_url_str.len > 0) blk: {
                var urls = std.ArrayList([]const u8).empty;
                errdefer {
                    for (urls.items) |u| allocator.free(u);
                    urls.deinit(allocator);
                }
                var iter = std.mem.splitScalar(u8, image_url_str, '|');
                while (iter.next()) |url| {
                    if (url.len > 0) {
                        try urls.append(allocator, try allocator.dupe(u8, url));
                    }
                }
                break :blk if (urls.items.len > 0) urls.items else null;
            } else null,
            .video_urls = if (video_url_str.len > 0) blk: {
                var urls = std.ArrayList([]const u8).empty;
                errdefer {
                    for (urls.items) |u| allocator.free(u);
                    urls.deinit(allocator);
                }
                var iter = std.mem.splitScalar(u8, video_url_str, '|');
                while (iter.next()) |url| {
                    if (url.len > 0) {
                        try urls.append(allocator, try allocator.dupe(u8, url));
                    }
                }
                break :blk if (urls.items.len > 0) urls.items else null;
            } else null,
            .tool_call_id = if (row.values[27].len > 0) try allocator.dupe(u8, row.values[27]) else null,
        };
        row.deinit(allocator);
        return history;
    }

    return null;
}

/// Fetch ONE llm_history row by its exact id (scoped to session_id).
/// 2026-08-23 B1 fix — handle_tool.zig used to emit tool-result SSE via
/// `getLatestMessage` (ORDER BY created_at_nano DESC LIMIT 1), which returns
pub fn getMessageById(
    allocator: std.mem.Allocator,
    db: *database.Db,
    session_id: []const u8,
    id: []const u8,
) !?TUIHistory {
    const sql =
        \\SELECT
        \\    h.id, h.session_id, h.model, h.created_at_nano AS created_at,
        \\    h.response_content, h.finish_reason,
        \\    COALESCE(h.role, 'assistant'),
        \\    COALESCE(h.tool_calls_json, ''),
        \\    COALESCE(h.reasoning_content, ''),
        \\    COALESCE(h.reasoning_id, ''),
        \\    COALESCE(h.reasoning_encrypted_content, ''),
        \\    COALESCE(h.agent, 'Agent'),
        \\    COALESCE(s.name, ''),
        \\    COALESCE(h.loop_index, 0),
        \\    COALESCE(h.tool_name, ''),
        \\    COALESCE(h.parent_session_id, ''),
        \\    COALESCE(h.temperature, 0.2),
        \\    COALESCE(h.is_thinking, 0),
        \\    COALESCE(h.prompt_tokens, 0),
        \\    COALESCE(h.completion_tokens, 0),
        \\    COALESCE(h.total_tokens, 0),
        \\    COALESCE(h.is_input, 0),
        \\    COALESCE(h.is_output, 0),
        \\    COALESCE(h.diffview_before, ''),
        \\    COALESCE(h.diffview_after, ''),
        \\    COALESCE(h.image_url, ''),
        \\    COALESCE(h.video_url, ''),
        \\    COALESCE(h.tool_call_id, '')
        \\FROM llm_history h
        \\LEFT JOIN sessions s ON h.session_id = s.id
        \\WHERE h.id = ? AND h.session_id = ?
        \\LIMIT 1
    ;

    var rows = try db.query(allocator, sql, &.{ id, session_id });
    defer rows.deinit();

    if (try rows.next()) |row| {
        const parent_session_id_str = row.values[15];
        const diffview_before_str = row.values[23];
        const diffview_after_str = row.values[24];
        const image_url_str = row.values[25];
        const video_url_str = row.values[26];
        const history = TUIHistory{
            .id = try allocator.dupe(u8, row.values[0]),
            .session_id = try allocator.dupe(u8, row.values[1]),
            .model = try allocator.dupe(u8, row.values[2]),
            .created_at = try allocator.dupe(u8, row.values[3]),
            .response_content = try allocator.dupe(u8, row.values[4]),
            .finish_reason = try allocator.dupe(u8, row.values[5]),
            .role = try allocator.dupe(u8, row.values[6]),
            .tools = try allocator.dupe(u8, row.values[7]),
            .reasoning_content = if (row.values[8].len > 0) try allocator.dupe(u8, row.values[8]) else null,
            .reasoning_id = if (row.values[9].len > 0) try allocator.dupe(u8, row.values[9]) else null,
            .reasoning_encrypted_content = if (row.values[10].len > 0) try allocator.dupe(u8, row.values[10]) else null,
            .agent = try allocator.dupe(u8, row.values[11]),
            .session_name = try allocator.dupe(u8, row.values[12]),
            .loop_index = std.fmt.parseInt(u32, row.values[13], 10) catch 0,
            .tool_name = try allocator.dupe(u8, row.values[14]),
            .parent_session_id = if (parent_session_id_str.len > 0) try allocator.dupe(u8, parent_session_id_str) else null,
            .temperature = std.fmt.parseFloat(f32, row.values[16]) catch 0.2,
            .is_thinking = std.mem.eql(u8, row.values[17], "1"),
            .prompt_tokens = std.fmt.parseInt(u32, row.values[18], 10) catch 0,
            .completion_tokens = std.fmt.parseInt(u32, row.values[19], 10) catch 0,
            .total_tokens = std.fmt.parseInt(u32, row.values[20], 10) catch 0,
            .is_input = parseRowBool(row.values[21]),
            .is_output = parseRowBool(row.values[22]),
            .diffview_before = if (diffview_before_str.len > 0) try allocator.dupe(u8, diffview_before_str) else null,
            .diffview_after = if (diffview_after_str.len > 0) try allocator.dupe(u8, diffview_after_str) else null,
            .image_urls = if (image_url_str.len > 0) blk: {
                var urls = std.ArrayList([]const u8).empty;
                errdefer {
                    for (urls.items) |u| allocator.free(u);
                    urls.deinit(allocator);
                }
                var iter = std.mem.splitScalar(u8, image_url_str, '|');
                while (iter.next()) |url| {
                    if (url.len > 0) {
                        try urls.append(allocator, try allocator.dupe(u8, url));
                    }
                }
                break :blk if (urls.items.len > 0) urls.items else null;
            } else null,
            .video_urls = if (video_url_str.len > 0) blk: {
                var urls = std.ArrayList([]const u8).empty;
                errdefer {
                    for (urls.items) |u| allocator.free(u);
                    urls.deinit(allocator);
                }
                var iter = std.mem.splitScalar(u8, video_url_str, '|');
                while (iter.next()) |url| {
                    if (url.len > 0) {
                        try urls.append(allocator, try allocator.dupe(u8, url));
                    }
                }
                break :blk if (urls.items.len > 0) urls.items else null;
            } else null,
            .tool_call_id = if (row.values[27].len > 0) try allocator.dupe(u8, row.values[27]) else null,
        };
        row.deinit(allocator);
        return history;
    }

    return null;
}

// =============================================================================
// Get Sessions By Directory Functions
// =============================================================================

pub fn get_sessions_by_dir(
    allocator: std.mem.Allocator,
    db: *database.Db,
    cwd: []const u8,
) ![]SessionInfo {
    var results: std.ArrayList(SessionInfo) = .empty;

    const sql = "SELECT h.session_id, COALESCE(s.cwd, ''), MAX(h.created_at_nano) AS created_at FROM llm_history h LEFT JOIN sessions s ON h.session_id = s.id WHERE s.cwd = ? GROUP BY h.session_id ORDER BY MAX(h.created_at_nano) DESC LIMIT 10";
    var rows = try db.query(allocator, sql, &[_][]const u8{cwd});
    defer rows.deinit();

    while (try rows.next()) |row| {
        const session = SessionInfo{
            .session_id = try allocator.dupe(u8, row.values[0]),
            .cwd = try allocator.dupe(u8, row.values[1]),
            .created_at = try allocator.dupe(u8, row.values[2]),
            .agent = try allocator.dupe(u8, ""),
            .session_name = try allocator.dupe(u8, ""),
            .status = try allocator.dupe(u8, ""),
            .selected_profile_model = try allocator.dupe(u8, ""),
            .is_auto_retry_until_stop = try allocator.dupe(u8, "0"),
            .last_finish_reason = try allocator.dupe(u8, ""),
            .last_human_touched_at = try allocator.dupe(u8, ""),
            .git_worktree_cwd = try allocator.dupe(u8, ""),
            .git_branch = try allocator.dupe(u8, ""),
        };
        try results.append(allocator, session);
        row.deinit(allocator);
    }

    return results.toOwnedSlice(allocator);
}

/// Get the latest session for a given directory
/// Returns null if no sessions exist for that directory
pub fn getLatestSessionByDir(
    allocator: std.mem.Allocator,
    db: *database.Db,
    cwd: []const u8,
) !?SessionInfo {
    const sql = "SELECT s.id, s.name, s.status, s.cwd, COALESCE(CAST(s.created_at AS TEXT), ''), COALESCE(CAST(s.updated_at AS TEXT), ''), COALESCE(h.agent, '') FROM sessions s LEFT JOIN llm_history h ON s.id = h.session_id WHERE s.cwd = ? GROUP BY s.id ORDER BY s.created_at DESC LIMIT 1";
    var rows = try db.query(allocator, sql, &[_][]const u8{cwd});
    defer rows.deinit();

    if (try rows.next()) |row| {
        const session = SessionInfo{
            .session_id = try allocator.dupe(u8, row.values[0]),
            .session_name = try allocator.dupe(u8, row.values[1]),
            .status = try allocator.dupe(u8, row.values[2]),
            .cwd = try allocator.dupe(u8, row.values[3]),
            .created_at = try allocator.dupe(u8, row.values[4]),
            .updated_at = try allocator.dupe(u8, row.values[5]),
            .agent = try allocator.dupe(u8, row.values[6]),
            .selected_profile_model = try allocator.dupe(u8, ""),
            .is_auto_retry_until_stop = try allocator.dupe(u8, "0"),
            .last_finish_reason = try allocator.dupe(u8, ""),
            .last_human_touched_at = try allocator.dupe(u8, ""),
            .git_worktree_cwd = try allocator.dupe(u8, ""),
            .git_branch = try allocator.dupe(u8, ""),
        };
        row.deinit(allocator);
        return session;
    }

    return null;
}

// =============================================================================
// Get Current Agent By Session ID Functions
// =============================================================================

pub const AgentState = struct {
    agent: []const u8,
    temperature: f32,
    is_thinking: bool,
};

pub fn get_current_agent_by_session_id(
    allocator: std.mem.Allocator,
    db: *database.Db,
    session_id: []const u8,
) !AgentState {
    const sql = "SELECT COALESCE(agent, 'Agent'), COALESCE(temperature, 0), COALESCE(is_thinking, 1) FROM llm_history WHERE session_id = ? ORDER BY created_at_nano DESC LIMIT 1";
    var rows = try db.query(allocator, sql, &.{session_id});
    defer rows.deinit();

    if (try rows.next()) |row| {
        defer row.deinit(allocator);
        const agent_name = try allocator.dupe(u8, row.values[0]);
        const temperature = try std.fmt.parseFloat(f32, row.values[1]);
        const is_thinking = std.mem.eql(u8, row.values[2], "1");
        return AgentState{
            .agent = agent_name,
            .temperature = temperature,
            .is_thinking = is_thinking,
        };
    } else {
        return AgentState{
            .agent = try allocator.dupe(u8, "Agent"),
            .temperature = 0,
            .is_thinking = true,
        };
    }
}

// =============================================================================
// WORKER INFO - For activity registry display
// =============================================================================

/// Worker info for displaying in agent prompts
pub const WorkerInfo = struct {
    session_id: []const u8,
    working_directory: []const u8,
    last_activity: i64,
    last_activity_description: []const u8,
    /// Bound git worktree path for this worker's session (empty when no
    /// worktree is bound). Mirrors `sessions.git_worktree_cwd`.
    git_worktree_cwd: []const u8,

    pub fn deinit(self: *const WorkerInfo, allocator: std.mem.Allocator) void {
        allocator.free(self.session_id);
        allocator.free(self.working_directory);
        allocator.free(self.last_activity_description);
        allocator.free(self.git_worktree_cwd);
    }

    /// Determine if this worker is a sub-agent by checking if session_id contains "subagent"
    pub fn isSubAgent(self: *const WorkerInfo) bool {
        return std.mem.indexOf(u8, self.session_id, "subagent") != null;
    }
};

/// Get all active workers with their info.
pub fn getActiveWorker(
    allocator: std.mem.Allocator,
    db: *database.Db,
) ![]WorkerInfo {
    const sql =
        \\SELECT
        \\    w.session_id,
        \\    COALESCE(w.working_directory, ''),
        \\    w.last_activity_nano AS last_activity,
        \\    COALESCE(w.last_activity_description, ''),
        \\    COALESCE(s.git_worktree_cwd, '')
        \\FROM worker w
        \\LEFT JOIN sessions s ON s.id = w.session_id
        \\ORDER BY w.last_activity_nano DESC
    ;

    var rows = try db.query(allocator, sql, &.{});
    defer rows.deinit();

    var workers = std.ArrayList(WorkerInfo).empty;
    errdefer {
        for (workers.items) |w| w.deinit(allocator);
        workers.deinit(allocator);
    }

    while (try rows.next()) |row| {
        const last_activity = std.fmt.parseInt(i64, row.values[2], 10) catch 0;
        const worker = WorkerInfo{
            .session_id = try allocator.dupe(u8, row.values[0]),
            .working_directory = try allocator.dupe(u8, row.values[1]),
            .last_activity = last_activity,
            .last_activity_description = try allocator.dupe(u8, row.values[3]),
            .git_worktree_cwd = try allocator.dupe(u8, row.values[4]),
        };
        try workers.append(allocator, worker);
        row.deinit(allocator);
    }

    return try workers.toOwnedSlice(allocator);
}

/// Update worker's last activity timestamp with description
pub fn updateWorkerActivityWithDescription(
    allocator: std.mem.Allocator,
    db: *database.Db,
    worker_id: []const u8,
    description: []const u8,
) !void {
    const sql = "UPDATE worker SET last_activity_nano = strftime('%s', 'now'), last_activity_description = ? WHERE id = ?";
    try db.exec(allocator, sql, &.{ description, worker_id });

    // Emit worker update event
    const now_timestamp: i64 = helpers.unixTimestamp();
    on_event_sent.onEventSendWorkers(allocator, .{
        .action = "updated",
        .id = worker_id,
        .session_id = "",
        .working_directory = "",
        .last_activity = now_timestamp,
        .last_activity_description = description,
        .created_at = "",
    }) catch {};
}

/// Append a single row to the `session_activity` per-session log (Migration
/// 073).
pub fn recordSessionActivity(
    allocator: std.mem.Allocator,
    io: std.Io,
    db: *database.Db,
    session_id: []const u8,
    description: []const u8,
) !void {
    const id = try std.fmt.allocPrint(allocator, "{}", .{std.Io.Timestamp.now(io, .real).nanoseconds});
    defer allocator.free(id);

    try db.exec(
        allocator,
        "INSERT INTO session_activity (id, session_id, description) VALUES (?, ?, ?)",
        &.{ id, session_id, description },
    );
}

/// Remove a worker
pub fn removeWorker(
    allocator: std.mem.Allocator,
    db: *database.Db,
    worker_id: []const u8,
) !void {
    const sql = "DELETE FROM worker WHERE id = ?";
    try db.exec(allocator, sql, &.{worker_id});

    // Emit worker deleted event
    on_event_sent.onEventSendWorkers(allocator, .{
        .action = "deleted",
        .id = worker_id,
        .session_id = "",
        .working_directory = "",
        .last_activity = 0,
        .last_activity_description = "",
        .created_at = "",
    }) catch {};
}

pub fn deleteAllWorkers(allocator: std.mem.Allocator, db: *database.Db) !void {
    const sql = "DELETE FROM worker";
    try db.exec(allocator, sql, &.{});
}

/// Delete a worker by session_id and emit SSE "deleted" event for each affected row
pub fn deleteWorkerBySessionId(
    allocator: std.mem.Allocator,
    db: *database.Db,
    session_id: []const u8,
) !void {
    // Capture affected worker IDs BEFORE deleting so we can emit one event per row
    const select_sql = "SELECT id FROM worker WHERE session_id = ?";
    var rows = try db.query(allocator, select_sql, &.{session_id});
    defer rows.deinit();

    var affected_ids: std.ArrayList([]const u8) = .empty;
    defer {
        for (affected_ids.items) |id| allocator.free(id);
        affected_ids.deinit(allocator);
    }

    while (try rows.next()) |row| {
        try affected_ids.append(allocator, try allocator.dupe(u8, row.values[0]));
    }

    const delete_sql = "DELETE FROM worker WHERE session_id = ?";
    try db.exec(allocator, delete_sql, &.{session_id});

    // Emit one worker deleted event per affected row
    for (affected_ids.items) |worker_id| {
        on_event_sent.onEventSendWorkers(allocator, .{
            .action = "deleted",
            .id = worker_id,
            .session_id = "",
            .working_directory = "",
            .last_activity = 0,
            .last_activity_description = "",
            .created_at = "",
        }) catch {};
    }
}

pub fn deleteAllQueuedMessages(allocator: std.mem.Allocator, db: *database.Db) !void {
    const sql = "DELETE FROM session_queue_messages";
    try db.exec(allocator, sql, &.{});
}

/// Delete all queued messages for a session
pub fn deleteQueuedMessagesBySessionId(
    allocator: std.mem.Allocator,
    db: *database.Db,
    session_id: []const u8,
) !void {
    const sql = "DELETE FROM session_queue_messages WHERE session_id = ?";
    try db.exec(allocator, sql, &.{session_id});
}

/// Get a worker by session_id Returns `null` when no worker row matches
/// `session_id` (e.g. when no LLM call has been issued yet for this session,
/// or when the session/worker has been cancelled).
pub fn getWorkerBySessionId(
    allocator: std.mem.Allocator,
    db: *database.Db,
    session_id: []const u8,
) !?WorkerInfo {
    const sql =
        \\SELECT
        \\    w.session_id,
        \\    COALESCE(w.working_directory, ''),
        \\    w.last_activity_nano AS last_activity,
        \\    COALESCE(w.last_activity_description, ''),
        \\    COALESCE(s.git_worktree_cwd, '')
        \\FROM worker w
        \\LEFT JOIN sessions s ON s.id = w.session_id
        \\WHERE w.session_id = ?
    ;

    var rows = try db.query(allocator, sql, &.{session_id});
    defer rows.deinit();

    if (try rows.next()) |row| {
        const last_activity = std.fmt.parseInt(i64, row.values[2], 10) catch 0;
        const worker = WorkerInfo{
            .session_id = try allocator.dupe(u8, row.values[0]),
            .working_directory = try allocator.dupe(u8, row.values[1]),
            .last_activity = last_activity,
            .last_activity_description = try allocator.dupe(u8, row.values[3]),
            .git_worktree_cwd = try allocator.dupe(u8, row.values[4]),
        };
        row.deinit(allocator);
        return worker;
    }
    return null;
}

/// Check if a task is currently running (a worker row exists for it). The
/// pabrik convention is `task.id == session.id`, so the worker table's
/// `session_id` column holds the task's id.
pub fn isTaskRunning(
    allocator: std.mem.Allocator,
    db: *database.Db,
    task_id: []const u8,
) bool {
    const sql = "SELECT 1 FROM worker WHERE session_id = ? LIMIT 1";
    var rows = db.query(allocator, sql, &.{task_id}) catch return false;
    defer rows.deinit();
    const row = (rows.next() catch return false) orelse return false;
    row.deinit(allocator);
    return true;
}

/// Cancel a session (set cancelled flag)
pub fn cancelSession(
    allocator: std.mem.Allocator,
    db: *database.Db,
    session_id: []const u8,
) !void {
    const sql = "UPDATE worker SET cancelled = 1 WHERE id = ?";
    try db.exec(allocator, sql, &.{session_id});
}

// =============================================================================
// Tool-call loading placeholder (Migration 068) The

/// Options for `saveToolResultPlaceholder`.
pub const SaveToolResultPlaceholderOptions = struct {
    session_id: []const u8,
    model: []const u8,
    tool_call_id: []const u8,
    tool_name: []const u8,
    loop_index: u32,
    /// Optional `parent_session_id` (matches `saveMessage`).
    parent_session_id: []const u8 = "",
};

/// Options for `updateToolResultById`. Only `content` is required;
/// `diffview_before` / `diffview_after` are optional (text_replace
/// uses them; most tools don't).
pub const UpdateToolResultOptions = struct {
    content: []const u8,
    diffview_before: ?[]const u8,
    diffview_after: ?[]const u8,
};

/// INSERT a `role=tool` placeholder row with `is_loading=1`. Returns the new
/// row's `id` (a nanosecond timestamp string, same shape as `saveMessage`).
pub fn saveToolResultPlaceholder(
    allocator: std.mem.Allocator,
    io: std.Io,
    db: *database.Db,
    opts: SaveToolResultPlaceholderOptions,
) ![]const u8 {
    const id = try std.fmt.allocPrint(allocator, "{}", .{std.Io.Timestamp.now(io, .real).nanoseconds});
    defer allocator.free(id);
    const created_at_nano = try std.fmt.allocPrint(allocator, "{}", .{std.Io.Timestamp.now(io, .real).nanoseconds});
    defer allocator.free(created_at_nano);
    const created_iso = try helpers.currentTimeIsoLocal(allocator, io);
    defer allocator.free(created_iso);

    const sql =
        \\INSERT INTO llm_history (
        \\    id, session_id, model, response_content, tool_call_id, tool_name,
        \\    role, finish_reason, is_loading, is_feed_to_llm,
        \\    agent, loop_index, temperature, is_thinking,
        \\    created_at_nano, created_iso, parent_session_id,
        \\    is_input, is_output, prompt_tokens, completion_tokens, total_tokens
        \\) VALUES (
        \\    ?, ?, ?, '', ?, ?, 'tool', 'tool', 1, 1,
        \\    'Agent', ?, 0.2, 0,
        \\    ?, ?, ?,
        \\    0, 1, 0, 0, 0
        \\)
    ;

    const loop_index_str = try std.fmt.allocPrint(allocator, "{}", .{opts.loop_index});
    defer allocator.free(loop_index_str);

    const sqlArgs = &.{
        id,
        opts.session_id,
        // Guarded for the same reason as `saveMessage`: an empty bind lands
        // as NULL and fails `model TEXT NOT NULL`. See
        // llm_history_model_guard.zig.
        model_guard.resolve(opts.model),
        opts.tool_call_id,
        opts.tool_name,
        loop_index_str,
        created_at_nano,
        created_iso,
        opts.parent_session_id,
    };
    try db.exec(allocator, sql, sqlArgs);

    // Return a copy the caller can own (the local `id` would be
    // freed by the deferred `allocator.free` above).
    return try allocator.dupe(u8, id);
}

/// UPDATE a placeholder row in place by `tool_call_id`.
pub fn updateToolResultById(
    allocator: std.mem.Allocator,
    io: std.Io,
    db: *database.Db,
    id: []const u8,
    opts: UpdateToolResultOptions,
) !void {
    _ = io;

    const sql =
        \\UPDATE llm_history SET
        \\    response_content = ?,
        \\    diffview_before = COALESCE(?, diffview_before),
        \\    diffview_after = COALESCE(?, diffview_after),
        \\    is_loading = 0
        \\WHERE id = ?
    ;

    // For diffview: an empty slice binds as NULL per project memory
    // `sqlite-backend-empty-slice-binds-as-null` — so passing '' is
    // indistinguishable from passing null.
    const sqlArgs = &.{
        opts.content,
        opts.diffview_before orelse "",
        opts.diffview_after orelse "",
        id,
    };
    try db.exec(allocator, sql, sqlArgs);
}

/// Replace every `is_loading=1` row in the session with a synthetic
/// "<interrupted>...</interrupted>" message so the next LLM call's
/// tool_call_id contract is satisfied after an agent crash.
pub fn resolveStaleLoadingToolResults(
    allocator: std.mem.Allocator,
    db: *database.Db,
    session_id: []const u8,
) !void {
    // The placeholder content is empty (Phase 1 inserts); replace it with the
    // synthetic interrupted message.
    const sql =
        \\UPDATE llm_history SET
        \\    response_content = '<interrupted>Tool execution was interrupted by server restart. Please retry this action.</interrupted>',
        \\    is_loading = 0
        \\WHERE session_id = ?
        \\AND is_loading = 1
        \\AND tool_call_id IS NOT NULL
        \\AND tool_call_id != ''
    ;
    try db.exec(allocator, sql, &.{session_id});
}

/// Struct to hold queued message data including image_url/video_url
pub const QueuedMessage = struct {
    message: []const u8,
    image_url: []const u8,
    video_url: []const u8 = "",
};

/// Returns null if no messages queued
/// Caller must free the returned slice
pub fn getQueueMessages(
    allocator: std.mem.Allocator,
    db: *database.Db,
    session_id: []const u8,
) !?std.ArrayList(QueuedMessage) {
    const select_sql = "SELECT message, image_url, COALESCE(video_url, '') FROM session_queue_messages WHERE session_id = ? ORDER BY created_at ASC";
    var rows = try db.query(allocator, select_sql, &.{session_id});
    defer rows.deinit();

    var messages = std.ArrayList(QueuedMessage).empty;
    errdefer {
        for (messages.items) |msg| {
            allocator.free(msg.message);
            allocator.free(msg.image_url);
            allocator.free(msg.video_url);
        }
        messages.deinit(allocator);
    }

    while (try rows.next()) |row| {
        const msg = try allocator.dupe(u8, row.values[0]);
        const image_url = try allocator.dupe(u8, row.values[1]);
        const video_url = try allocator.dupe(u8, row.values[2]);
        try messages.append(allocator, .{ .message = msg, .image_url = image_url, .video_url = video_url });
    }

    if (messages.items.len == 0) {
        messages.deinit(allocator);
        return null;
    }

    return messages;
}

// =============================================================================
// Session Table Functions (migrated from session_table.zig)
// =============================================================================

/// Session info for CRUD operations (from session_table.zig)
pub const SessionTableInfo = struct {
    id: []u8,
    name: []u8,
    status: []u8,
    cwd: []u8,
    created_at: []u8,
    updated_at: []u8,
    selected_profile_model: []u8,
    git_worktree_cwd: []u8,
    /// Migration 086 — attached PR URL + effective provider ("" = unset).
    pr_url: []u8,
    pr_provider: []u8,
    /// Migration 063 — opt-in flag for unattended mode. Stored as text
    /// ("0" / "1") to match `is_auto_retry_until_stop`'s INTEGER column
    /// convention used by the rest of the codebase.
    is_auto_retry_until_stop: []u8,
    /// Migration 063 — most recent `finish_reason` the workflow observed
    /// for this session. Empty string before the first successful turn.
    last_finish_reason: []u8,
    /// Migration 091 — resolved sub-agent name for sub-agent sessions (e.g.
    /// "implementator"). Empty for main-agent sessions.
    sub_agent_name: []u8,
    /// Migration 091 — parent session id for sub-agent sessions.
    parent_session_id: []u8,

    pub fn deinit(self: SessionTableInfo, allocator: std.mem.Allocator) void {
        allocator.free(self.id);
        allocator.free(self.name);
        allocator.free(self.status);
        allocator.free(self.cwd);
        allocator.free(self.created_at);
        allocator.free(self.updated_at);
        allocator.free(self.selected_profile_model);
        allocator.free(self.git_worktree_cwd);
        allocator.free(self.pr_url);
        allocator.free(self.pr_provider);
        allocator.free(self.is_auto_retry_until_stop);
        allocator.free(self.last_finish_reason);
        allocator.free(self.sub_agent_name);
        allocator.free(self.parent_session_id);
    }
};

/// Create a new session with status set to 'active'
/// `is_auto_retry_until_stop`: "1" enables unattended mode for this session
/// (workflow keeps retrying past the 10-attempt TooManyRetries bail).
pub fn create_session(
    allocator: std.mem.Allocator,
    db: *database.Db,
    id: []const u8,
    name: []const u8,
    is_auto_retry_until_stop: []const u8,
) !SessionTableInfo {
    const flag = if (std.mem.eql(u8, is_auto_retry_until_stop, "1")) "1" else "0";
    const sql =
        "INSERT INTO sessions (id, name, status, created_at, updated_at, is_auto_retry_until_stop) " ++
        "VALUES (?, ?, 'active', CURRENT_TIMESTAMP, CURRENT_TIMESTAMP, ?)";
    try db.exec(allocator, sql, &.{ id, name, flag });

    // Broadcast session created event — carry the new columns in the
    // SSE payload so ChatsList updates live without a refetch.
    on_event_sent.onEventSendSessions(allocator, .{
        .action = "created",
        .id = id,
        .name = name,
        .status = "active",
        .cwd = "",
        .created_at = "",
        .updated_at = "",
        .selected_profile_model = "",
        .git_worktree_cwd = "",
        .pr_url = "",
        .pr_provider = "",
        .is_auto_retry_until_stop = flag,
        .last_finish_reason = "",
    }) catch {};

    return SessionTableInfo{
        .id = try allocator.dupe(u8, id),
        .name = try allocator.dupe(u8, name),
        .status = try allocator.dupe(u8, "active"),
        // cwd is intentionally empty in create_session — the worker upserts
        // the cwd on the first llm_history insert (see
        // insert_llm_histories.zig:183).
        .cwd = try allocator.dupe(u8, ""),
        .created_at = try allocator.dupe(u8, ""),
        .updated_at = try allocator.dupe(u8, ""),
        .selected_profile_model = try allocator.dupe(u8, ""),
        .git_worktree_cwd = try allocator.dupe(u8, ""),
        .pr_url = try allocator.dupe(u8, ""),
        .pr_provider = try allocator.dupe(u8, ""),
        // Migration 063 — populated with the just-bound value for the
        // flag; last_finish_reason is empty until the workflow writes
        // the first value (Chunk 2 Task 2.1).
        .is_auto_retry_until_stop = try allocator.dupe(u8, flag),
        .last_finish_reason = try allocator.dupe(u8, ""),
        // Migration 091 — empty until workflow stamps sub-agent identity.
        .sub_agent_name = try allocator.dupe(u8, ""),
        .parent_session_id = try allocator.dupe(u8, ""),
    };
}

/// Ensure a session row exists for `session_id`. If no row matches, INSERT a
/// minimal row with sensible defaults (name='New Session',
/// is_auto_retry_until_stop='0', empty selected_profile_model).
pub fn ensureSessionExists(
    allocator: std.mem.Allocator,
    db: *database.Db,
    session_id: []const u8,
) !bool {
    const existing = (try getSession(allocator, db, session_id)) orelse {
        const created = try create_session(allocator, db, session_id, "New Session", "0");
        created.deinit(allocator);
        return true;
    };
    existing.deinit(allocator);
    return false;
}

/// Get a session by id
pub fn getSession(
    allocator: std.mem.Allocator,
    db: *database.Db,
    id: []const u8,
) !?SessionTableInfo {
    const sql =
        \\SELECT s.id, s.name, s.status, COALESCE(s.cwd, ''),
        \\       COALESCE(CAST(s.created_at AS TEXT), ''), COALESCE(CAST(s.updated_at AS TEXT), ''),
        \\       COALESCE(s.selected_profile_model, ''), COALESCE(s.git_worktree_cwd, ''),
        \\       COALESCE(s.is_auto_retry_until_stop, '0'), COALESCE(s.last_finish_reason, ''),
        \\       COALESCE(s.pr_url, ''), COALESCE(s.pr_provider, ''),
        \\       COALESCE(s.sub_agent_name, ''), COALESCE(s.parent_session_id, '')
        \\FROM sessions s WHERE s.id = ?
    ;

    var rows = db.query(allocator, sql, &.{id}) catch {
        // Fallback for pre-Migration-091 DBs and minimal test schemas
        // without the new columns: read the legacy column set and
        // return empty sub-agent identity.
        return getSessionLegacy(allocator, db, id);
    };
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
            .pr_url = try allocator.dupe(u8, row.values[10]),
            .pr_provider = try allocator.dupe(u8, row.values[11]),
            // Migration 063 — row.values[8] = is_auto_retry_until_stop
            // (COALESCE'd to '0'); row.values[9] = last_finish_reason
            // (COALESCE'd to '').
            .is_auto_retry_until_stop = try allocator.dupe(u8, row.values[8]),
            .last_finish_reason = try allocator.dupe(u8, row.values[9]),
            // Migration 091 — sub-agent identity (empty for main sessions).
            .sub_agent_name = try allocator.dupe(u8, row.values[12]),
            .parent_session_id = try allocator.dupe(u8, row.values[13]),
        };
        row.deinit(allocator);
        return session;
    }

    return null;
}

/// Legacy getSession without Migration-091 columns. Used as a fallback
/// when the sessions table predates the migration or a minimal test
/// schema omits the new columns. Returns empty sub-agent identity.
fn getSessionLegacy(
    allocator: std.mem.Allocator,
    db: *database.Db,
    id: []const u8,
) !?SessionTableInfo {
    const sql =
        \\SELECT s.id, s.name, s.status, COALESCE(s.cwd, ''),
        \\       COALESCE(CAST(s.created_at AS TEXT), ''), COALESCE(CAST(s.updated_at AS TEXT), ''),
        \\       COALESCE(s.selected_profile_model, ''), COALESCE(s.git_worktree_cwd, ''),
        \\       COALESCE(s.is_auto_retry_until_stop, '0'), COALESCE(s.last_finish_reason, ''),
        \\       COALESCE(s.pr_url, ''), COALESCE(s.pr_provider, '')
        \\FROM sessions s WHERE s.id = ?
    ;

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
            .pr_url = try allocator.dupe(u8, row.values[10]),
            .pr_provider = try allocator.dupe(u8, row.values[11]),
            .is_auto_retry_until_stop = try allocator.dupe(u8, row.values[8]),
            .last_finish_reason = try allocator.dupe(u8, row.values[9]),
            .sub_agent_name = try allocator.dupe(u8, ""),
            .parent_session_id = try allocator.dupe(u8, ""),
        };
        row.deinit(allocator);
        return session;
    }

    return null;
}

/// Update session status
pub fn update_session_status(
    allocator: std.mem.Allocator,
    db: *database.Db,
    id: []const u8,
    new_status: []const u8,
) !void {
    const sql = "UPDATE sessions SET status = ?, updated_at = CURRENT_TIMESTAMP WHERE id = ?";
    try db.exec(allocator, sql, &.{ new_status, id });

    // Get updated session data and broadcast
    const session = getSession(allocator, db, id) catch null;
    if (session) |s| {
        defer s.deinit(allocator);
        on_event_sent.onEventSendSessions(allocator, .{
            .action = "updated",
            .id = s.id,
            .name = s.name,
            .status = s.status,
            .cwd = s.cwd,
            .created_at = s.created_at,
            .updated_at = s.updated_at,
            .selected_profile_model = s.selected_profile_model,
            .git_worktree_cwd = s.git_worktree_cwd,
            .pr_url = s.pr_url,
            .pr_provider = s.pr_provider,
        }) catch {};
    }
}

/// Update session name
pub fn updateSessionName(
    allocator: std.mem.Allocator,
    db: *database.Db,
    id: []const u8,
    new_name: []const u8,
) !void {
    const sql = "UPDATE sessions SET name = ? WHERE id = ?";
    try db.exec(allocator, sql, &.{ new_name, id });

    // Get updated session data and broadcast
    const session = getSession(allocator, db, id) catch null;
    if (session) |s| {
        defer s.deinit(allocator);
        on_event_sent.onEventSendSessions(allocator, .{
            .action = "updated",
            .id = s.id,
            .name = s.name,
            .status = s.status,
            .cwd = s.cwd,
            .created_at = s.created_at,
            .updated_at = s.updated_at,
            .selected_profile_model = s.selected_profile_model,
            .git_worktree_cwd = s.git_worktree_cwd,
            .pr_url = s.pr_url,
            .pr_provider = s.pr_provider,
        }) catch {};
    }
}

/// Rename a workspace item task.
pub fn updateTaskName(
    allocator: std.mem.Allocator,
    db: *database.Db,
    id: []const u8,
    new_name: []const u8,
) !void {
    // 1) Update the task row.
    const task_sql = "UPDATE workspace_item_tasks SET name = ?, updated_at = datetime('now') WHERE id = ?";
    try db.exec(allocator, task_sql, &.{ new_name, id });

    // 2) Verify the task exists. If not (rare — e.g. the caller's
    // id is wrong) there's nothing to cascade. Return early; the
    // UPDATE above is a no-op in that case.
    const task = (getWorkspaceItemTask(allocator, db, id) catch null) orelse return;
    defer task.deinit(allocator);

    // 3) The task IS the session id. Always cascade.
    const session_id = id;

    // 4) Cascade the rename to the linked session.
    updateSessionName(allocator, db, session_id, new_name) catch {};
}

/// Update the unattended-mode flag for an existing session (Migration 063).
/// `value` must be "1" or "0" — handler layer validates the input shape.
pub fn updateSessionAutoRetryUntilStop(
    allocator: std.mem.Allocator,
    db: *database.Db,
    id: []const u8,
    value: []const u8,
) !void {
    const normalized: []const u8 = if (std.mem.eql(u8, value, "1")) "1" else "0";
    const sql =
        "UPDATE sessions SET is_auto_retry_until_stop = ?, updated_at = CURRENT_TIMESTAMP WHERE id = ?";
    try db.exec(allocator, sql, &.{ normalized, id });

    const session = getSession(allocator, db, id) catch null;
    if (session) |s| {
        defer s.deinit(allocator);
        on_event_sent.onEventSendSessions(allocator, .{
            .action = "updated",
            .id = s.id,
            .name = s.name,
            .status = s.status,
            .cwd = s.cwd,
            .created_at = s.created_at,
            .updated_at = s.updated_at,
            .selected_profile_model = s.selected_profile_model,
            .git_worktree_cwd = s.git_worktree_cwd,
            .pr_url = s.pr_url,
            .pr_provider = s.pr_provider,
            .is_auto_retry_until_stop = s.is_auto_retry_until_stop,
            .last_finish_reason = s.last_finish_reason,
        }) catch {};
    }
}

/// Update the most-recent `finish_reason` cache for an existing session
/// (Migration 063).
pub fn updateSessionLastFinishReason(
    allocator: std.mem.Allocator,
    db: *database.Db,
    id: []const u8,
    finish_reason: []const u8,
) !void {
    const sql =
        "UPDATE sessions SET last_finish_reason = ?, updated_at = CURRENT_TIMESTAMP WHERE id = ?";
    try db.exec(allocator, sql, &.{ finish_reason, id });
}

/// Stamp `last_human_touched_at = <unix_ms>` on a task.
pub fn updateTaskLastHumanTouchedAt(
    allocator: std.mem.Allocator,
    db: *database.Db,
    task_id: []const u8,
    now_unix_ms: ?i64,
) !void {
    const now_ms = now_unix_ms orelse unixMillisNow();
    const touched_at_str = try std.fmt.allocPrint(
        allocator,
        "{d}",
        .{now_ms},
    );
    defer allocator.free(touched_at_str);

    const sql =
        "UPDATE workspace_item_tasks SET last_human_touched_at_nano = ? WHERE id = ?";
    try db.exec(allocator, sql, &.{ touched_at_str, task_id });
}

/// Stamp `sessions.last_human_touched_at_nano = <unix_ms>`. Sibling of
/// `updateTaskLastHumanTouchedAt` (which targets `workspace_item_tasks`).
pub fn updateSessionLastHumanTouchedAt(
    allocator: std.mem.Allocator,
    db: *database.Db,
    session_id: []const u8,
    now_unix_ms: ?i64,
) !void {
    if (session_id.len == 0) return;
    const now_ms = now_unix_ms orelse unixMillisNow();
    const touched_at_str = try std.fmt.allocPrint(
        allocator,
        "{d}",
        .{now_ms},
    );
    defer allocator.free(touched_at_str);

    const sql =
        "UPDATE sessions SET last_human_touched_at_nano = CAST(? AS BIGINT) WHERE id = ?";
    try db.exec(allocator, sql, &.{ touched_at_str, session_id });
}

/// Current Unix epoch time in milliseconds. Used by
/// `updateTaskLastHumanTouchedAt` as the default timestamp; can also be
/// called directly by handlers that need a unix-ms stamp.
const builtin = @import("builtin");
const Clong = if (@bitSizeOf(usize) == 64 and builtin.os.tag != .windows)
    i64
else
    i32;

extern "c" fn gettimeofday(tv: ?*PosixTimeval, tz: ?*anyopaque) c_int;

/// `struct timeval { time_t tv_sec; suseconds_t tv_usec; }` (POSIX/UCRT).
const Usect = switch (builtin.os.tag) {
    .linux => i64,
    .macos, .windows => i32,
    else => @compileError("unixMillisNow: unsupported platform " ++ @tagName(builtin.os.tag)),
};

const PosixTimeval = extern struct {
    sec: Clong,
    usec: Usect,
};

pub fn unixMillisNow() i64 {
    var tv: PosixTimeval = undefined;
    _ = gettimeofday(&tv, null);
    return @as(i64, tv.sec) * 1000 + @divFloor(@as(i64, tv.usec), 1000);
}

test "unixMillisNow: returns positive value within sane range (catches macOS suseconds_t = i32 struct-layout fix)" {
    // On macOS ARM64, `suseconds_t` is `__int32_t` (4 bytes), not
    // `__int64_t`.
    const ts = unixMillisNow();
    try std.testing.expect(ts > 1_577_836_800_000);
    try std.testing.expect(ts < 4_102_444_800_000);
}

/// Update session selected_profile_model (the name of a profile in
/// LlmConfig.profiles_models). Pass empty string or null to clear.
pub fn updateSessionSelectedProfileModel(
    allocator: std.mem.Allocator,
    db: *database.Db,
    id: []const u8,
    selected_profile_model: ?[]const u8,
) !void {
    const effective: []const u8 = selected_profile_model orelse "";
    const sql = "UPDATE sessions SET selected_profile_model = ?, updated_at = CURRENT_TIMESTAMP WHERE id = ?";
    try db.exec(allocator, sql, &.{ effective, id });

    // Re-read and broadcast the updated session
    const session = getSession(allocator, db, id) catch null;
    if (session) |s| {
        defer s.deinit(allocator);
        on_event_sent.onEventSendSessions(allocator, .{
            .action = "updated",
            .id = s.id,
            .name = s.name,
            .status = s.status,
            .cwd = s.cwd,
            .created_at = s.created_at,
            .updated_at = s.updated_at,
            .selected_profile_model = s.selected_profile_model,
            .git_worktree_cwd = s.git_worktree_cwd,
            .pr_url = s.pr_url,
            .pr_provider = s.pr_provider,
        }) catch {};
    }
}

/// Migration 091 — stamp sub-agent identity onto a session row.
/// sub_agent_name is the resolved sub-agent name (e.g. "implementator"),
/// parent_session_id links back to the spawner.
pub fn updateSessionSubAgentInfo(
    allocator: std.mem.Allocator,
    db: *database.Db,
    id: []const u8,
    sub_agent_name: []const u8,
    parent_session_id: []const u8,
) !void {
    if (sub_agent_name.len > 0) {
        const sql = "UPDATE sessions SET sub_agent_name = ?, updated_at = CURRENT_TIMESTAMP WHERE id = ?";
        try db.exec(allocator, sql, &.{ sub_agent_name, id });
    }
    if (parent_session_id.len > 0) {
        const sql = "UPDATE sessions SET parent_session_id = ?, updated_at = CURRENT_TIMESTAMP WHERE id = ?";
        try db.exec(allocator, sql, &.{ parent_session_id, id });
    }
}

/// Read `sessions.git_worktree_cwd` for `session_id`. Empty string when the
/// session has no binding or no row — the caller then works in `cwd`.
pub fn getSessionGitWorktreeCwd(
    allocator: std.mem.Allocator,
    db: *database.Db,
    session_id: []const u8,
) ![]u8 {
    var rows = try db.query(
        allocator,
        "SELECT COALESCE(git_worktree_cwd, '') FROM sessions WHERE id = ?",
        &.{session_id},
    );
    defer rows.deinit();
    const row = (try rows.next()) orelse return allocator.dupe(u8, "");
    defer row.deinit(allocator);
    return allocator.dupe(u8, row.values[0]);
}

/// Update session git_worktree_cwd. Pass empty string or null to clear.
/// When the value changes, broadcast a session.updated SSE event so the
/// ChatsList sidebar updates its 🌳 badge in real time.
pub fn updateSessionGitWorktreeCwd(
    allocator: std.mem.Allocator,
    db: *database.Db,
    id: []const u8,
    git_worktree_cwd: ?[]const u8,
) !void {
    const effective: []const u8 = git_worktree_cwd orelse "";
    const sql = "UPDATE sessions SET git_worktree_cwd = ?, updated_at = CURRENT_TIMESTAMP WHERE id = ?";
    try db.exec(allocator, sql, &.{ effective, id });

    const session = getSession(allocator, db, id) catch null;
    if (session) |s| {
        defer s.deinit(allocator);
        on_event_sent.onEventSendSessions(allocator, .{
            .action = "updated",
            .id = s.id,
            .name = s.name,
            .status = s.status,
            .cwd = s.cwd,
            .created_at = s.created_at,
            .updated_at = s.updated_at,
            .selected_profile_model = s.selected_profile_model,
            .git_worktree_cwd = s.git_worktree_cwd,
            .pr_url = s.pr_url,
            .pr_provider = s.pr_provider,
        }) catch {};
    }
}

/// Update session attached-PR binding. Pass nulls (or empty strings) to
/// clear.
pub fn updateSessionPrUrl(
    allocator: std.mem.Allocator,
    db: *database.Db,
    id: []const u8,
    pr_url: ?[]const u8,
    pr_provider: ?[]const u8,
) !void {
    const effective_url: []const u8 = pr_url orelse "";
    const effective_provider: []const u8 = pr_provider orelse "";
    const sql = "UPDATE sessions SET pr_url = ?, pr_provider = ?, updated_at = CURRENT_TIMESTAMP WHERE id = ?";
    try db.exec(allocator, sql, &.{ effective_url, effective_provider, id });

    const session = getSession(allocator, db, id) catch null;
    if (session) |s| {
        defer s.deinit(allocator);
        on_event_sent.onEventSendSessions(allocator, .{
            .action = "updated",
            .id = s.id,
            .name = s.name,
            .status = s.status,
            .cwd = s.cwd,
            .created_at = s.created_at,
            .updated_at = s.updated_at,
            .selected_profile_model = s.selected_profile_model,
            .git_worktree_cwd = s.git_worktree_cwd,
            .pr_url = s.pr_url,
            .pr_provider = s.pr_provider,
        }) catch {};
    }
}

/// Delete a session by id
pub fn delete_session(
    allocator: std.mem.Allocator,
    db: *database.Db,
    id: []const u8,
) !void {
    const sql = "DELETE FROM sessions WHERE id = ?";
    try db.exec(allocator, sql, &.{id});

    // Broadcast session deleted event
    on_event_sent.onEventSendSessions(allocator, .{
        .action = "deleted",
        .id = id,
        .name = "",
        .status = "",
        .cwd = "",
        .created_at = "",
        .updated_at = "",
        .selected_profile_model = "",
        .git_worktree_cwd = "",
        .pr_url = "",
        .pr_provider = "",
    }) catch {};
}

/// List all sessions
pub fn list_sessions(
    allocator: std.mem.Allocator,
    db: *database.Db,
) ![]SessionTableInfo {
    const sql = "SELECT id, name, status, COALESCE(selected_profile_model, ''), COALESCE(cwd, ''), COALESCE(CAST(created_at AS TEXT), ''), COALESCE(CAST(updated_at AS TEXT), ''), COALESCE(git_worktree_cwd, ''), COALESCE(pr_url, ''), COALESCE(pr_provider, ''), COALESCE(is_auto_retry_until_stop, '0'), COALESCE(last_finish_reason, ''), COALESCE(sub_agent_name, ''), COALESCE(parent_session_id, '') FROM sessions ORDER BY id";

    var rows = try db.query(allocator, sql, &.{});
    defer rows.deinit();

    var sessions = std.ArrayList(SessionTableInfo).empty;
    errdefer {
        for (sessions.items) |s| s.deinit(allocator);
        sessions.deinit(allocator);
    }

    while (try rows.next()) |row| {
        const session = SessionTableInfo{
            .id = try allocator.dupe(u8, row.values[0]),
            .name = try allocator.dupe(u8, row.values[1]),
            .status = try allocator.dupe(u8, row.values[2]),
            .selected_profile_model = try allocator.dupe(u8, row.values[3]),
            .cwd = try allocator.dupe(u8, row.values[4]),
            .created_at = try allocator.dupe(u8, row.values[5]),
            .updated_at = try allocator.dupe(u8, row.values[6]),
            .git_worktree_cwd = try allocator.dupe(u8, row.values[7]),
            .pr_url = try allocator.dupe(u8, row.values[8]),
            .pr_provider = try allocator.dupe(u8, row.values[9]),
            .is_auto_retry_until_stop = try allocator.dupe(u8, row.values[10]),
            .last_finish_reason = try allocator.dupe(u8, row.values[11]),
            .sub_agent_name = try allocator.dupe(u8, row.values[12]),
            .parent_session_id = try allocator.dupe(u8, row.values[13]),
        };
        try sessions.append(allocator, session);
        row.deinit(allocator);
    }

    return try sessions.toOwnedSlice(allocator);
}

// =============================================================================
// Session Skills Functions (migrated from session_skills.zig)
// =============================================================================

/// Check if a skill is already loaded in the database
pub fn isSkillLoaded(
    allocator: std.mem.Allocator,
    db: *database.Db,
    session_id: []const u8,
    skill_name: []const u8,
) !bool {
    if (session_id.len == 0) return false;

    const sql = "SELECT 1 FROM session_skills WHERE session_id = ? AND skill_name = ? LIMIT 1";
    var rows = try db.query(allocator, sql, &.{ session_id, skill_name });
    defer rows.deinit();

    if (try rows.next()) |row| {
        row.deinit(allocator);
        return true;
    }
    return false;
}

/// Save a loaded skill to the database for persistence
pub fn saveSkill(
    allocator: std.mem.Allocator,
    db: *database.Db,
    logger: *logger_mod.Logger,
    session_id: []const u8,
    skill_name: []const u8,
    content: []const u8,
) !void {
    // Skip if session_id is empty
    if (session_id.len == 0) return;

    const sql = dialect.upsert_verb ++ " INTO session_skills (session_id, skill_name, content, loaded_at_nano) VALUES (?, ?, ?, strftime('%s', 'now'))" ++ UPSERT_SESSION_SKILL_TAIL;
    try db.exec(allocator, sql, &.{ session_id, skill_name, content });
    logger.debugFmt("Skill '{s}' saved to database for session {s}", .{ skill_name, session_id });
}

/// Skill info for session_skills table
pub const SkillInfo = struct {
    skill_name: []u8,
    content: []u8,
    loaded_at: ?i64 = null,

    pub fn deinit(self: SkillInfo, allocator: std.mem.Allocator) void {
        allocator.free(self.skill_name);
        allocator.free(self.content);
    }
};

/// Get all skills loaded for a session
pub fn getSessionSkills(
    allocator: std.mem.Allocator,
    db: *database.Db,
    session_id: []const u8,
) ![]SkillInfo {
    if (session_id.len == 0) return &.{};

    const sql = "SELECT skill_name, content, loaded_at_nano AS loaded_at FROM session_skills WHERE session_id = ?";
    var rows = try db.query(allocator, sql, &.{session_id});
    defer rows.deinit();

    var skills = std.ArrayList(SkillInfo).empty;
    errdefer {
        for (skills.items) |*s| s.deinit(allocator);
        skills.deinit(allocator);
    }

    while (try rows.next()) |row| {
        const skill_name = row.values[0];
        const content = row.values[1];
        const loaded_at = if (row.values[2].len > 0) std.fmt.parseInt(i64, row.values[2], 10) catch null else null;

        try skills.append(allocator, .{
            .skill_name = try allocator.dupe(u8, skill_name),
            .content = try allocator.dupe(u8, content),
            .loaded_at = loaded_at,
        });
        row.deinit(allocator);
    }

    return try skills.toOwnedSlice(allocator);
}

// =============================================================================
// Session Progressive Tool Functions (progressive tool search, Migration 085)
// The agent enables tools for itself with `use_tool`; the record lives here.

pub const ProgressiveToolInfo = struct {
    tool_name: []u8,
    server_name: []u8,
    loaded_at: ?i64 = null,

    pub fn deinit(self: ProgressiveToolInfo, allocator: std.mem.Allocator) void {
        allocator.free(self.tool_name);
        allocator.free(self.server_name);
    }
};

/// Check whether a tool is already enabled for this session. The caller
/// uses this for the "already equipped → do not insert" rule.
pub fn isProgressiveToolEquipped(
    allocator: std.mem.Allocator,
    db: *database.Db,
    session_id: []const u8,
    tool_name: []const u8,
) !bool {
    if (session_id.len == 0 or tool_name.len == 0) return false;

    const sql = "SELECT 1 FROM session_progressive_tool WHERE session_id = ? AND tool_name = ? LIMIT 1";
    var rows = try db.query(allocator, sql, &.{ session_id, tool_name });
    defer rows.deinit();

    if (try rows.next()) |row| {
        row.deinit(allocator);
        return true;
    }
    return false;
}

/// Enable `tool_name` for `session_id`. Returns `true` only when a row was
/// actually INSERTed.
pub fn saveProgressiveTool(
    allocator: std.mem.Allocator,
    db: *database.Db,
    logger: *logger_mod.Logger,
    session_id: []const u8,
    tool_name: []const u8,
    server_name: []const u8,
) !bool {
    if (session_id.len == 0 or tool_name.len == 0) return false;

    // COALESCE on server_name is REQUIRED, not cosmetic: Backend binds
    // an empty `[]const u8` as SQL NULL, and `server_name` is NOT NULL — so a
    // built-in (always passed with "") would violate the constraint and
    const sql = "INSERT INTO session_progressive_tool (session_id, tool_name, server_name, loaded_at_nano) VALUES (?, ?, COALESCE(?, ''), strftime('%s', 'now')) ON CONFLICT DO NOTHING";
    try db.exec(allocator, sql, &.{ session_id, tool_name, server_name });

    const inserted = db.changes() > 0;
    if (inserted) {
        logger.debugFmt(
            "Progressive tool '{s}' equipped for session {s}",
            .{ tool_name, session_id },
        );
    }
    return inserted;
}

/// All tools this session has enabled, oldest first (see
/// `saveProgressiveTool` for the ordering rule). Caller owns each entry and
/// the slice.
pub fn getProgressiveTools(
    allocator: std.mem.Allocator,
    db: *database.Db,
    session_id: []const u8,
) ![]ProgressiveToolInfo {
    if (session_id.len == 0) return &.{};

    const sql = "SELECT tool_name, server_name, loaded_at_nano FROM session_progressive_tool WHERE session_id = ? ORDER BY loaded_at_nano ASC, tool_name ASC";
    var rows = try db.query(allocator, sql, &.{session_id});
    defer rows.deinit();

    var out: std.ArrayList(ProgressiveToolInfo) = .empty;
    errdefer {
        for (out.items) |*t| t.deinit(allocator);
        out.deinit(allocator);
    }

    while (try rows.next()) |row| {
        const tool_name = row.values[0];
        const server_name = row.values[1];
        const loaded_at = if (row.values[2].len > 0) std.fmt.parseInt(i64, row.values[2], 10) catch null else null;

        try out.append(allocator, .{
            .tool_name = try allocator.dupe(u8, tool_name),
            .server_name = try allocator.dupe(u8, server_name),
            .loaded_at = loaded_at,
        });
        row.deinit(allocator);
    }

    return try out.toOwnedSlice(allocator);
}

/// Drop a tool from this session's progressive set. Used by tests and by a
/// future "unload" affordance; the normal path never removes a row.
pub fn deleteProgressiveTool(
    allocator: std.mem.Allocator,
    db: *database.Db,
    session_id: []const u8,
    tool_name: []const u8,
) !void {
    if (session_id.len == 0 or tool_name.len == 0) return;
    try db.exec(
        allocator,
        "DELETE FROM session_progressive_tool WHERE session_id = ? AND tool_name = ?",
        &.{ session_id, tool_name },
    );
}

// =============================================================================
// Workspace Items Functions (migrated from workspace_items_table.zig)
// =============================================================================

/// WorkspaceItem info for CRUD operations
pub const WorkspaceItemInfo = struct {
    id: []u8,
    workspace_id: []u8,
    item_type: []u8,
    name: ?[]u8 = null,
    path: ?[]u8 = null,
    created_at: ?[]u8 = null,
    updated_at: ?[]u8 = null,
    /// Migration 094 — 1 when this item is the workspace's default project.
    is_default: i64 = 0,

    pub fn deinit(self: WorkspaceItemInfo, allocator: std.mem.Allocator) void {
        allocator.free(self.id);
        allocator.free(self.workspace_id);
        allocator.free(self.item_type);
        if (self.name) |n| allocator.free(n);
        if (self.path) |p| allocator.free(p);
        if (self.created_at) |ca| allocator.free(ca);
        if (self.updated_at) |ua| allocator.free(ua);
    }
};

/// Create a new workspace item
pub fn createWorkspaceItem(
    allocator: std.mem.Allocator,
    db: *database.Db,
    id: []const u8,
    workspace_id: []const u8,
    item_type: []const u8,
) !WorkspaceItemInfo {
    const sql = "INSERT INTO workspace_items (id, workspace_id, item_type) VALUES (?, ?, ?)";
    try db.exec(allocator, sql, &.{ id, workspace_id, item_type });

    return WorkspaceItemInfo{
        .id = try allocator.dupe(u8, id),
        .workspace_id = try allocator.dupe(u8, workspace_id),
        .item_type = try allocator.dupe(u8, item_type),
    };
}

/// Get a workspace item by id
pub fn getWorkspaceItem(
    allocator: std.mem.Allocator,
    db: *database.Db,
    id: []const u8,
) !?WorkspaceItemInfo {
    const sql = "SELECT id, workspace_id, item_type, name, path, created_at, updated_at, is_default FROM workspace_items WHERE id = ?";

    var rows = try db.query(allocator, sql, &.{id});
    defer rows.deinit();

    if (try rows.next()) |row| {
        const item = WorkspaceItemInfo{
            .id = try allocator.dupe(u8, row.values[0]),
            .workspace_id = try allocator.dupe(u8, row.values[1]),
            .item_type = try allocator.dupe(u8, row.values[2]),
            .name = if (row.values[3].len > 0) try allocator.dupe(u8, row.values[3]) else null,
            .path = if (row.values[4].len > 0) try allocator.dupe(u8, row.values[4]) else null,
            .created_at = if (row.values[5].len > 0) try allocator.dupe(u8, row.values[5]) else null,
            .updated_at = if (row.values[6].len > 0) try allocator.dupe(u8, row.values[6]) else null,
            .is_default = std.fmt.parseInt(i64, row.values[7], 10) catch 0,
        };
        row.deinit(allocator);
        return item;
    }

    return null;
}

/// Update workspace item
pub fn updateWorkspaceItem(
    allocator: std.mem.Allocator,
    db: *database.Db,
    id: []const u8,
    workspace_id: []const u8,
    item_type: []const u8,
) !void {
    const sql = "UPDATE workspace_items SET workspace_id = ?, item_type = ?, updated_at = datetime('now') WHERE id = ?";
    try db.exec(allocator, sql, &.{ workspace_id, item_type, id });
}

/// Update only the `path` column of a workspace item.
pub fn updateWorkspaceItemPath(
    allocator: std.mem.Allocator,
    db: *database.Db,
    id: []const u8,
    path: ?[]const u8,
) !void {
    if (path) |p| {
        const sql = "UPDATE workspace_items SET path = ?, updated_at = datetime('now') WHERE id = ?";
        try db.exec(allocator, sql, &.{ p, id });
    } else {
        const sql = "UPDATE workspace_items SET path = NULL, updated_at = datetime('now') WHERE id = ?";
        try db.exec(allocator, sql, &.{id});
    }
}

/// Update only the `name` column of a workspace item.
pub fn updateWorkspaceItemName(
    allocator: std.mem.Allocator,
    db: *database.Db,
    id: []const u8,
    name: []const u8,
) !void {
    const sql = "UPDATE workspace_items SET name = ?, updated_at = datetime('now') WHERE id = ?";
    try db.exec(allocator, sql, &.{ name, id });
}

/// Delete a workspace item by id
pub fn deleteWorkspaceItem(
    allocator: std.mem.Allocator,
    db: *database.Db,
    id: []const u8,
) !void {
    const sql = "DELETE FROM workspace_items WHERE id = ?";
    try db.exec(allocator, sql, &.{id});
}

/// List all workspace items by workspace_id. Sorted by `wi.position DESC,
/// wi.id ASC`.
pub fn listWorkspaceItems(
    allocator: std.mem.Allocator,
    db: *database.Db,
    workspace_id: []const u8,
) ![]WorkspaceItemInfo {
    const sql = "SELECT wi.id, wi.workspace_id, wi.item_type, wi.name, wi.path, wi.created_at, wi.updated_at, wi.is_default FROM workspace_items wi WHERE wi.workspace_id = ? ORDER BY wi.position DESC, wi.id ASC";

    var rows = try db.query(allocator, sql, &.{workspace_id});
    defer rows.deinit();

    var items = std.ArrayList(WorkspaceItemInfo).empty;
    errdefer {
        for (items.items) |item| item.deinit(allocator);
        items.deinit(allocator);
    }

    while (try rows.next()) |row| {
        const item = WorkspaceItemInfo{
            .id = try allocator.dupe(u8, row.values[0]),
            .workspace_id = try allocator.dupe(u8, row.values[1]),
            .item_type = try allocator.dupe(u8, row.values[2]),
            .name = if (row.values[3].len > 0) try allocator.dupe(u8, row.values[3]) else null,
            .path = if (row.values[4].len > 0) try allocator.dupe(u8, row.values[4]) else null,
            .created_at = if (row.values[5].len > 0) try allocator.dupe(u8, row.values[5]) else null,
            .updated_at = if (row.values[6].len > 0) try allocator.dupe(u8, row.values[6]) else null,
            .is_default = std.fmt.parseInt(i64, row.values[7], 10) catch 0,
        };
        try items.append(allocator, item);
        row.deinit(allocator);
    }

    return try items.toOwnedSlice(allocator);
}

/// List ALL workspace items (for N+1 fix). Same sort as the per-workspace
/// list: `wi.position DESC, wi.id ASC`.
pub fn listAllWorkspaceItems(
    allocator: std.mem.Allocator,
    db: *database.Db,
) ![]WorkspaceItemInfo {
    const sql = "SELECT wi.id, wi.workspace_id, wi.item_type, wi.name, wi.path, wi.created_at, wi.updated_at FROM workspace_items wi ORDER BY wi.position DESC, wi.id ASC";

    var rows = try db.query(allocator, sql, &.{});
    defer rows.deinit();

    var items = std.ArrayList(WorkspaceItemInfo).empty;
    errdefer {
        for (items.items) |item| item.deinit(allocator);
        items.deinit(allocator);
    }

    while (try rows.next()) |row| {
        const item = WorkspaceItemInfo{
            .id = try allocator.dupe(u8, row.values[0]),
            .workspace_id = try allocator.dupe(u8, row.values[1]),
            .item_type = try allocator.dupe(u8, row.values[2]),
            .name = if (row.values[3].len > 0) try allocator.dupe(u8, row.values[3]) else null,
            .path = if (row.values[4].len > 0) try allocator.dupe(u8, row.values[4]) else null,
            .created_at = if (row.values[5].len > 0) try allocator.dupe(u8, row.values[5]) else null,
            .updated_at = if (row.values[6].len > 0) try allocator.dupe(u8, row.values[6]) else null,
        };
        try items.append(allocator, item);
        row.deinit(allocator);
    }

    return try items.toOwnedSlice(allocator);
}

// =============================================================================
// Workspace Context (used by prompts_build_messages_for_agent_prompt.zig to
// render the `## Workspace Context` section of the system prompt — see

/// Maximum number of sibling items returned per session.
pub const MAX_SIBLING_ITEMS: u32 = 20;

/// Maximum number of tasks listed under each sibling item.
pub const MAX_TASKS_PER_ITEM: u32 = 5;

/// Context for the "Workspace Context" dynamic prompt section. Returned by
/// `getWorkspaceContext`; the tui layer's `BuildWorkspaceContext` consumes
/// this struct and renders the markdown block.
pub const WorkspaceContext = struct {
    workspace_id: []u8,
    self_item_id: []u8, // task's own item id
    self_task_id: []u8, // task's own id
    self_item_type: []u8, // parent's workspace_items.item_type ('kanban', 'chat', 'folder', ...)
    self_path: ?[]u8, // task's own item path (cwd hint)
    siblings: []SiblingItem, // all items in the same workspace, self first
    truncated_items_count: u32, // > 0 when 20-item cap hit
    total_item_count: u32, // for diagnostic footer

    pub const SiblingItem = struct {
        id: []u8,
        item_type: []u8,
        name: ?[]u8,
        path: ?[]u8,
        is_self: bool,
        tasks: []SiblingTask, // ≤ MAX_TASKS_PER_ITEM
        truncated_tasks_count: u32, // > 0 when 5-task cap hit

        pub const SiblingTask = struct {
            id: []u8,
            name: []u8,
            task_type: []u8,
        };

        /// Free the per-item allocations.
        pub fn deinit(self: SiblingItem, allocator: std.mem.Allocator) void {
            allocator.free(self.id);
            allocator.free(self.item_type);
            if (self.name) |n| allocator.free(n);
            if (self.path) |p| allocator.free(p);
            for (self.tasks) |t| {
                allocator.free(t.id);
                allocator.free(t.name);
                allocator.free(t.task_type);
            }
            allocator.free(self.tasks);
        }
    };

    /// Free all heap-allocated fields of this `WorkspaceContext`.
    /// Callers MUST call `deinit` on a non-null value returned by
    /// `getWorkspaceContext` exactly once.
    pub fn deinit(self: WorkspaceContext, allocator: std.mem.Allocator) void {
        allocator.free(self.workspace_id);
        allocator.free(self.self_item_id);
        allocator.free(self.self_task_id);
        allocator.free(self.self_item_type);
        if (self.self_path) |p| allocator.free(p);
        for (self.siblings) |sib| sib.deinit(allocator);
        allocator.free(self.siblings);
    }
};

/// Look up the workspace context for a session.
pub fn getWorkspaceContext(
    allocator: std.mem.Allocator,
    db: *database.Db,
    session_id: []const u8,
) !?WorkspaceContext {
    if (session_id.len == 0) return null;

    // 1. Anchor: find the task bound to this session.
    const anchor_sql =
        \\SELECT t.id, t.workspace_item_id, wi.workspace_id, wi.path, wi.item_type
        \\FROM workspace_item_tasks t
        \\JOIN workspace_items wi ON wi.id = t.workspace_item_id
        \\WHERE t.id = ?
    ;
    var anchor_q = try db.query(allocator, anchor_sql, &.{session_id});
    defer anchor_q.deinit();
    const anchor_row = (try anchor_q.next()) orelse return null;
    const self_task_id = try allocator.dupe(u8, anchor_row.values[0]);
    const self_item_id = try allocator.dupe(u8, anchor_row.values[1]);
    const workspace_id = try allocator.dupe(u8, anchor_row.values[2]);
    const self_path: ?[]u8 = if (anchor_row.values[3].len > 0)
        try allocator.dupe(u8, anchor_row.values[3])
    else
        null;
    const self_item_type = try allocator.dupe(u8, anchor_row.values[4]);
    anchor_row.deinit(allocator); // Pitfall 1: pass allocator explicitly, NOT `anchor_row.allocator`

    // 2. Total item count for the "and N more" footer.
    var count_q = try db.query(
        allocator,
        "SELECT COUNT(*) FROM workspace_items wi WHERE wi.workspace_id = ?",
        &.{workspace_id},
    );
    defer count_q.deinit();
    const count_row = (try count_q.next()) orelse {
        // Defensive: COUNT(*) should always return a row. If not,
        // synthesize an empty siblings list so the caller still
        // gets a usable context.
        return WorkspaceContext{
            .workspace_id = workspace_id,
            .self_item_id = self_item_id,
            .self_task_id = self_task_id,
            .self_item_type = self_item_type,
            .self_path = self_path,
            .siblings = &.{},
            .truncated_items_count = 0,
            .total_item_count = 0,
        };
    };
    const total_item_count = try std.fmt.parseInt(u32, count_row.values[0], 10);
    count_row.deinit(allocator); // Pitfall 1 again

    // 3. Enumerate items (capped at MAX_SIBLING_ITEMS).
    const items_sql = try std.fmt.allocPrint(allocator,
        \\SELECT wi.id, wi.item_type, wi.name, wi.path,
        \\       (wi.id = ?) AS is_self
        \\FROM workspace_items wi
        \\WHERE wi.workspace_id = ?
        \\ORDER BY is_self DESC, wi.position DESC, wi.id ASC
        \\LIMIT {d}
    , .{MAX_SIBLING_ITEMS});
    defer allocator.free(items_sql);

    var items_q = try db.query(allocator, items_sql, &.{ self_item_id, workspace_id });
    defer items_q.deinit();

    var siblings: std.ArrayList(WorkspaceContext.SiblingItem) = .empty;
    errdefer {
        for (siblings.items) |s| s.deinit(allocator);
        siblings.deinit(allocator);
    }

    while (try items_q.next()) |row| {
        const item_id_owned = try allocator.dupe(u8, row.values[0]);
        errdefer allocator.free(item_id_owned);
        const item_type_owned = try allocator.dupe(u8, row.values[1]);
        const name_owned: ?[]u8 = if (row.values[2].len > 0) try allocator.dupe(u8, row.values[2]) else null;
        const path_owned: ?[]u8 = if (row.values[3].len > 0) try allocator.dupe(u8, row.values[3]) else null;
        const is_self_owned = std.mem.eql(u8, row.values[4], "1");
        row.deinit(allocator);

        // 4. Enumerate tasks under this item (capped at
        // MAX_TASKS_PER_ITEM). Same inlined-LIMIT pattern as above.
        const tasks_sql = try std.fmt.allocPrint(allocator,
            \\SELECT t.id, t.name, t.task_type
            \\FROM workspace_item_tasks t
            \\WHERE t.workspace_item_id = ?
            \\ORDER BY t.updated_at DESC, t.id ASC
            \\LIMIT {d}
        , .{MAX_TASKS_PER_ITEM});
        defer allocator.free(tasks_sql);

        var tasks_q = try db.query(allocator, tasks_sql, &.{item_id_owned});
        defer tasks_q.deinit();

        var tasks: std.ArrayList(WorkspaceContext.SiblingItem.SiblingTask) = .empty;
        errdefer {
            for (tasks.items) |t| {
                allocator.free(t.id);
                allocator.free(t.name);
                allocator.free(t.task_type);
            }
            tasks.deinit(allocator);
        }

        while (try tasks_q.next()) |trow| {
            const t_id = try allocator.dupe(u8, trow.values[0]);
            const t_name = try allocator.dupe(u8, trow.values[1]);
            const t_type = try allocator.dupe(u8, trow.values[2]);
            trow.deinit(allocator);
            try tasks.append(allocator, .{
                .id = t_id,
                .name = t_name,
                .task_type = t_type,
            });
        }

        // 4b. Truncation detection for tasks: see if there are
        // more tasks than we loaded.
        var task_count_q = try db.query(
            allocator,
            "SELECT COUNT(*) FROM workspace_item_tasks t WHERE t.workspace_item_id = ?",
            &.{item_id_owned},
        );
        defer task_count_q.deinit();
        const task_count_row = (try task_count_q.next()) orelse {
            // Defensive — COUNT(*) should always return a row.
            // Use the loaded count as the truth.
            try siblings.append(allocator, .{
                .id = item_id_owned,
                .item_type = item_type_owned,
                .name = name_owned,
                .path = path_owned,
                .is_self = is_self_owned,
                .tasks = try tasks.toOwnedSlice(allocator),
                .truncated_tasks_count = 0,
            });
            continue;
        };
        const total_tasks: u32 = try std.fmt.parseInt(u32, task_count_row.values[0], 10);
        task_count_row.deinit(allocator);
        const truncated_tasks_count: u32 = if (total_tasks > MAX_TASKS_PER_ITEM)
            total_tasks - MAX_TASKS_PER_ITEM
        else
            0;

        try siblings.append(allocator, .{
            .id = item_id_owned,
            .item_type = item_type_owned,
            .name = name_owned,
            .path = path_owned,
            .is_self = is_self_owned,
            .tasks = try tasks.toOwnedSlice(allocator),
            .truncated_tasks_count = truncated_tasks_count,
        });
    }

    const truncated_items_count: u32 = if (total_item_count > MAX_SIBLING_ITEMS)
        total_item_count - MAX_SIBLING_ITEMS
    else
        0;

    return WorkspaceContext{
        .workspace_id = workspace_id,
        .self_item_id = self_item_id,
        .self_task_id = self_task_id,
        .self_item_type = self_item_type,
        .self_path = self_path,
        .siblings = try siblings.toOwnedSlice(allocator),
        .truncated_items_count = truncated_items_count,
        .total_item_count = total_item_count,
    };
}

// =============================================================================
// Workspace Item Tasks Functions (migrated from workspace_item_tasks_table.zig)
// =============================================================================

// NOTE: RoutineMeta deleted with the per-task `routines` table
// (Migration 084, plan 2026-09-10-workspace-items-routines).
// Routines are now first-class workspace items (`workspace_routines`).

/// WorkspaceItemTask info for CRUD operations
pub const WorkspaceItemTaskInfo = struct {
    id: []u8,
    name: []u8,
    workspace_item_id: []u8,
    /// Task type. 'standard' for legacy rows; 'memory' for memory files.
    task_type: []u8 = &.{},
    /// Free-form description (Migration 062). Empty string is the
    /// canonical "no description" sentinel — the column is NOT NULL
    /// DEFAULT ''. Owned by the lister; freed by `deinit`.
    description: []u8 = &.{},
    created_at: ?[]u8 = null,
    updated_at: ?[]u8 = null,
    /// Pin flag. `true` when the user has pinned this task; the lister
    /// surfaces pinned tasks first (in `pinned_position` order, DESC),
    /// then unpinned tasks in the existing sort order.
    is_pinned: bool = false,
    /// Position within the pinned subset of a single workspace item. Higher =
    /// higher in the pinned region. Only meaningful when `is_pinned == true`.
    pinned_position: i64 = 0,
    /// Kanban column this task belongs to, when the parent workspace item is
    /// a kanban. `null` for standard tasks and for tasks whose parent is not
    /// a kanban.
    kanban_column_id: ?[]u8 = null,
    /// Position within the kanban column (lower = higher in the column).
    /// `0` for non-kanban tasks. Mirrors `workspace_item_tasks.kanban_position`
    /// (Migration 048).
    kanban_position: i64 = 0,
    /// Unattended-mode flag, joined from `sessions` for routine tasks (where
    /// `task.id == session.id` per the project convention). `'0'` for
    /// standard tasks that have no session row.
    is_auto_retry_until_stop: []u8 = &.{},

    /// Last `finish_reason` reported by the workflow (joined from
    /// `sessions`).
    last_finish_reason: []u8 = &.{},

    /// Computed boolean for the kanban card "AI finished — awaiting review"
    /// orange dot.
    needs_human_review: bool = false,

    /// JSON-encoded array of tag strings (Migration 067 — kanban task tags
    /// feature).
    tags: []u8 = &.{},

    /// `||`-delimited base64 data URLs (Migration 069 — kanban image urls
    /// column).
    image_urls: []u8 = &.{},

    /// `||`-delimited base64 data URLs (Migration 090 — kanban video urls
    /// column). Empty string is the canonical "no videos" sentinel, matching
    /// the `image_urls` pattern. Owned by the lister; freed by `deinit`.
    video_urls: []u8 = &.{},

    /// Lightweight media-presence flags, derived in SQL via `CASE WHEN <urls>
    /// != ''` (no stored columns, nothing to keep in sync).
    is_have_image: bool = false,
    is_have_video: bool = false,

    /// Per-task cwd override (Migration 070).
    cwd: []u8 = &.{},

    /// `||`-joined skill names for this task (Migration 112). Empty string is
    /// the canonical "no skill" sentinel.
    skill_names: []u8 = &.{},

    /// Joined from `sessions.git_worktree_cwd` (Migration 046). Empty string
    /// when no session row exists or no worktree is bound. Owned by the
    /// lister; freed by `deinit`.
    git_worktree_cwd: []u8 = &.{},

    /// Computed `git rev-parse --abbrev-ref HEAD` output for the task's cwd
    /// (`git_worktree_cwd` or the parent `workspace_items.path`).
    git_branch: ?[]u8 = null,

    pub fn deinit(self: WorkspaceItemTaskInfo, allocator: std.mem.Allocator) void {
        allocator.free(self.id);
        allocator.free(self.name);
        allocator.free(self.workspace_item_id);
        if (self.task_type.len > 0) allocator.free(self.task_type);
        if (self.description.len > 0) allocator.free(self.description);
        if (self.created_at) |ca| allocator.free(ca);
        if (self.updated_at) |ua| allocator.free(ua);
        if (self.kanban_column_id) |kc| allocator.free(kc);
        if (self.is_auto_retry_until_stop.len > 0) allocator.free(self.is_auto_retry_until_stop);
        if (self.last_finish_reason.len > 0) allocator.free(self.last_finish_reason);
        if (self.tags.len > 0) allocator.free(self.tags);
        if (self.image_urls.len > 0) allocator.free(self.image_urls);
        if (self.video_urls.len > 0) allocator.free(self.video_urls);
        if (self.cwd.len > 0) allocator.free(self.cwd);
        if (self.skill_names.len > 0) allocator.free(self.skill_names);
        if (self.git_worktree_cwd.len > 0) allocator.free(self.git_worktree_cwd);
        if (self.git_branch) |gb| allocator.free(gb);
    }
};

/// One distinct tag suggestion for a kanban's autocomplete dropdown.
pub const KanbanTagSuggestion = struct {
    /// The tag value as it appeared in some task's tags JSON array.
    /// First-occurrence casing wins (matches tags_validation.zig).
    name: []u8,
    /// Number of tasks on this kanban whose `tags` JSON array contains
    /// this value (after json_each expansion).
    count: u32,
    /// `updated_at` of the MOST RECENT task that uses this tag, in the same
    /// `YYYY-MM-DD HH:MM:SS` format the DB stores it in.
    last_used_at: ?[]u8,

    pub fn deinit(self: KanbanTagSuggestion, allocator: std.mem.Allocator) void {
        allocator.free(self.name);
        if (self.last_used_at) |s| allocator.free(s);
    }
};

/// Result of a single page of tag suggestions. The caller KNOWS the page size
/// (`limit` arg) so it can detect `has_more` by comparing `tags.len >=
/// limit`.
pub const KanbanTagSuggestionsPage = struct {
    tags: []KanbanTagSuggestion,
    has_more: bool,

    pub fn deinit(self: KanbanTagSuggestionsPage, allocator: std.mem.Allocator) void {
        for (self.tags) |t| t.deinit(allocator);
        allocator.free(self.tags);
    }
};

/// Create a new workspace item task
pub fn createWorkspaceItemTask(
    allocator: std.mem.Allocator,
    db: *database.Db,
    id: []const u8,
    name: []const u8,
    workspace_item_id: []const u8,
    task_type: []const u8,
    description: ?[]const u8,
    /// JSON-encoded array of tag strings (Migration 067 — kanban task tags
    /// feature).
    tags: ?[]const u8,
    image_urls: ?[]const u8,
    /// Per-task cwd override (Migration 070 — kanban-cwd-session- optional
    /// plan, 2026-08-06).
    cwd: ?[]const u8,
    /// `||`-delimited `data:video/...;base64,...` URLs (Migration 090).
    /// Same null/empty/literal contract as image_urls above.
    video_urls: ?[]const u8,
    /// `||`-joined skill names this task asks its agent to use (Migration
    /// 112, which widened Migration 110's single name). Empty = no skill.
    /// Names, not ids — `use_skill({ name })` takes the name.
    skill_names: ?[]const u8,
) !WorkspaceItemTaskInfo {
    if (!std.mem.eql(u8, task_type, "standard") and !std.mem.eql(u8, task_type, "routine")) {
        return error.InvalidTaskType;
    }

    // Note: this used to take a separate `session_id` parameter. The `task.id
    // == session_id` convention made the column redundant (Migration 052
    // dropped it).
    const returned_desc: []const u8 = description orelse "";
    const returned_tags: []const u8 = tags orelse "";
    const returned_image_urls: []const u8 = image_urls orelse "";
    const returned_video_urls: []const u8 = video_urls orelse "";
    const returned_cwd: []const u8 = cwd orelse "";
    const returned_skill_names: []const u8 = skill_names orelse "";
    {
        var cols_buf: std.ArrayList(u8) = .empty;
        defer cols_buf.deinit(allocator);
        var vals_buf: std.ArrayList(u8) = .empty;
        defer vals_buf.deinit(allocator);
        var bind_values: std.ArrayList([]const u8) = .empty;
        defer bind_values.deinit(allocator);

        try cols_buf.appendSlice(allocator, "id, name, workspace_item_id, task_type");
        try vals_buf.appendSlice(allocator, "?, ?, ?, ?");
        try bind_values.appendSlice(allocator, &[_][]const u8{
            id, name, workspace_item_id, task_type,
        });

        if (description) |d| {
            if (d.len == 0) {
                try cols_buf.appendSlice(allocator, ", description");
                try vals_buf.appendSlice(allocator, ", ''");
            } else {
                try cols_buf.appendSlice(allocator, ", description");
                try vals_buf.appendSlice(allocator, ", ?");
                try bind_values.append(allocator, d);
            }
        }

        // Migration 067 — same dynamic-SQL builder pattern for tags. Note:
        // empty string MUST be a SQL '' literal — see the Backend.exec
        // empty-slice-binds-as-NULL rule cited above.
        if (tags) |t| {
            if (t.len == 0) {
                try cols_buf.appendSlice(allocator, ", tags");
                try vals_buf.appendSlice(allocator, ", ''");
            } else {
                try cols_buf.appendSlice(allocator, ", tags");
                try vals_buf.appendSlice(allocator, ", ?");
                try bind_values.append(allocator, t);
            }
        }

        // Migration 069 — same dynamic-SQL builder pattern for image_urls.
        // The `||`-delimited string is opaque to the DB (TEXT), so we just
        // bind it as a single slice.
        if (image_urls) |u| {
            if (u.len == 0) {
                try cols_buf.appendSlice(allocator, ", image_urls");
                try vals_buf.appendSlice(allocator, ", ''");
            } else {
                try cols_buf.appendSlice(allocator, ", image_urls");
                try vals_buf.appendSlice(allocator, ", ?");
                try bind_values.append(allocator, u);
            }
        }

        // Migration 090 — same pattern for video_urls.
        if (video_urls) |u| {
            if (u.len == 0) {
                try cols_buf.appendSlice(allocator, ", video_urls");
                try vals_buf.appendSlice(allocator, ", ''");
            } else {
                try cols_buf.appendSlice(allocator, ", video_urls");
                try vals_buf.appendSlice(allocator, ", ?");
                try bind_values.append(allocator, u);
            }
        }

        // Migration 070 — same dynamic-SQL builder pattern for the per-task
        // cwd override.
        if (cwd) |c| {
            if (c.len == 0) {
                try cols_buf.appendSlice(allocator, ", cwd");
                try vals_buf.appendSlice(allocator, ", ''");
            } else {
                try cols_buf.appendSlice(allocator, ", cwd");
                try vals_buf.appendSlice(allocator, ", ?");
                try bind_values.append(allocator, c);
            }
        }

        // Migration 112 — same dynamic-SQL builder pattern for the skill
        // names. Empty string MUST be a SQL '' literal (see the
        // Backend.exec empty-slice-binds-as-NULL rule above).
        if (skill_names) |sk| {
            if (sk.len == 0) {
                try cols_buf.appendSlice(allocator, ", skill_names");
                try vals_buf.appendSlice(allocator, ", ''");
            } else {
                try cols_buf.appendSlice(allocator, ", skill_names");
                try vals_buf.appendSlice(allocator, ", ?");
                try bind_values.append(allocator, sk);
            }
        }

        var sql_buf: std.ArrayList(u8) = .empty;
        defer sql_buf.deinit(allocator);
        try sql_buf.print(
            allocator,
            "INSERT INTO workspace_item_tasks ({s}) VALUES ({s})",
            .{ cols_buf.items, vals_buf.items },
        );

        try db.exec(allocator, sql_buf.items, bind_values.items);
    }

    return WorkspaceItemTaskInfo{
        .id = try allocator.dupe(u8, id),
        .name = try allocator.dupe(u8, name),
        .workspace_item_id = try allocator.dupe(u8, workspace_item_id),
        .task_type = try allocator.dupe(u8, task_type),
        // Persist the description we just INSERTed (so the caller's
        // view of the new task matches what's in the DB without a
        // round-trip SELECT).
        .description = try allocator.dupe(u8, returned_desc),
        // Persist the tags we just INSERTed (Migration 067). dupe
        // unconditionally so `deinit` can free consistently.
        .tags = try allocator.dupe(u8, returned_tags),
        // Migration 069 — persist image_urls we just INSERTed. dupe
        // unconditionally so `deinit` can free consistently.
        .image_urls = try allocator.dupe(u8, returned_image_urls),
        // Migration 090 — persist video_urls we just INSERTed.
        .video_urls = try allocator.dupe(u8, returned_video_urls),
        // Media-flags change — flags mirror the TEXT columns above.
        .is_have_image = returned_image_urls.len > 0,
        .is_have_video = returned_video_urls.len > 0,
        // Migration 070 — persist the per-task cwd we just INSERTed. dupe
        // unconditionally so `deinit` can free consistently (the empty-string
        // path also gets duped — a 0-byte allocation, freed via `free('cwd')`
        .cwd = try allocator.dupe(u8, returned_cwd),
        // Migration 112 — persist the skill names we just INSERTed. Same
        // unconditional dupe so `deinit` frees consistently.
        .skill_names = try allocator.dupe(u8, returned_skill_names),
    };
}

/// Get a workspace item task by id
pub fn getWorkspaceItemTask(
    allocator: std.mem.Allocator,
    db: *database.Db,
    id: []const u8,
) !?WorkspaceItemTaskInfo {
    // Column index map for `row.values[N]`: 0: id 1: name 2:
    // workspace_item_id 3: description (Migration 062 — added right after
    // workspace_item_id) 4: created_at 5: updated_at 6: task_type (Migration
    const sql = "SELECT id, name, workspace_item_id, description, created_at, updated_at, task_type, tags FROM workspace_item_tasks t WHERE t.id = ?";

    var rows = try db.query(allocator, sql, &.{id});
    defer rows.deinit();

    if (try rows.next()) |row| {
        const task = WorkspaceItemTaskInfo{
            .id = try allocator.dupe(u8, row.values[0]),
            .name = try allocator.dupe(u8, row.values[1]),
            .workspace_item_id = try allocator.dupe(u8, row.values[2]),
            // description is NOT NULL DEFAULT '' (Migration 062) so the row
            // value is always present. dupe unconditionally (an empty slice
            // still gets a fresh allocation so deinit can free it
            .description = try allocator.dupe(u8, row.values[3]),
            .created_at = if (row.values[4].len > 0) try allocator.dupe(u8, row.values[4]) else null,
            .updated_at = if (row.values[5].len > 0) try allocator.dupe(u8, row.values[5]) else null,
            .task_type = if (row.values[6].len > 0) try allocator.dupe(u8, row.values[6]) else try allocator.dupe(u8, "standard"),
            // tags is NOT NULL DEFAULT '' (Migration 067). The frontend
            // decodes via JSON.parse. Stored value is a JSON-encode
            // array string ('' when no tags).
            .tags = try allocator.dupe(u8, row.values[7]),
        };
        row.deinit(allocator);
        return task;
    }

    return null;
}

/// Update workspace item task
pub fn updateWorkspaceItemTask(
    allocator: std.mem.Allocator,
    db: *database.Db,
    id: []const u8,
    name: ?[]const u8,
) !void {
    if (name == null) {
        // Nothing to update
        return;
    }

    var set_clauses = std.ArrayList([]const u8).empty;
    var values = std.ArrayList([]const u8).empty;

    if (name) |n| {
        try set_clauses.append(allocator, "name = ?");
        try values.append(allocator, n);
    }

    try values.append(allocator, id);

    var sql = std.ArrayList(u8).empty;
    try sql.appendSlice(allocator, "UPDATE workspace_item_tasks SET ");
    for (set_clauses.items, 0..) |clause, i| {
        if (i > 0) try sql.appendSlice(allocator, ", ");
        try sql.appendSlice(allocator, clause);
    }
    try sql.appendSlice(allocator, ", updated_at = datetime('now') WHERE id = ?");

    try db.exec(allocator, sql.items, values.items);
}

/// Delete a workspace item task by id
pub fn deleteWorkspaceItemTask(
    allocator: std.mem.Allocator,
    db: *database.Db,
    id: []const u8,
) !void {
    const sql = "DELETE FROM workspace_item_tasks WHERE id = ?";
    try db.exec(allocator, sql, &.{id});
}

/// Set or clear the `is_pinned` flag for a single task.
pub fn setTaskPinned(
    allocator: std.mem.Allocator,
    db: *database.Db,
    id: []const u8,
    is_pinned: bool,
) !i64 {
    if (is_pinned) {
        // Bump pinned_position to MAX+1 for the relevant workspace_item. The
        // MAX subquery is correlated on workspace_item_id (derived from the
        // row being pinned) so the position is scoped per item, not globally.
        var max_q = try db.query(
            allocator,
            "SELECT COALESCE(MAX(t.pinned_position), -1) FROM workspace_item_tasks t WHERE t.is_pinned = 1 AND t.workspace_item_id = (SELECT workspace_item_id FROM workspace_item_tasks WHERE id = ?)",
            &.{id},
        );
        defer max_q.deinit();
        const max_row = (try max_q.next()) orelse {
            return error.TaskNotFound;
        };
        defer max_row.deinit(allocator);
        const max_pos = std.fmt.parseInt(i64, max_row.values[0], 10) catch 0;
        const new_pos = max_pos + 1;
        const new_pos_str = try std.fmt.allocPrint(allocator, "{d}", .{new_pos});
        defer allocator.free(new_pos_str);
        try db.exec(
            allocator,
            "UPDATE workspace_item_tasks SET is_pinned = 1, pinned_position = ?, updated_at = datetime('now') WHERE id = ?",
            &.{ new_pos_str, id },
        );
        // Migration 104 - keep the linked session row in sync so the PINNED
        // section above RECENT reflects kanban pins (same id convention,
        // best-effort: a task with no session row only touches
        db.exec(
            allocator,
            "UPDATE sessions SET is_pinned = 1, pinned_position = ?, updated_at = datetime('now') WHERE id = ?",
            &.{ new_pos_str, id },
        ) catch {};
        return new_pos;
    } else {
        try db.exec(
            allocator,
            "UPDATE workspace_item_tasks SET is_pinned = 0, pinned_position = 0, updated_at = datetime('now') WHERE id = ?",
            &.{id},
        );
        db.exec(
            allocator,
            "UPDATE sessions SET is_pinned = 0, pinned_position = 0, updated_at = datetime('now') WHERE id = ?",
            &.{id},
        ) catch {};
        return 0;
    }
}

/// Set or clear the `is_pinned` flag for a single session (Migration 104).
pub fn setSessionPinned(
    allocator: std.mem.Allocator,
    db: *database.Db,
    id: []const u8,
    is_pinned: bool,
) !i64 {
    // Verify the session exists first so unknown ids 404 instead of
    // silently succeeding with zero rows touched.
    var exist_q = try db.query(
        allocator,
        "SELECT id FROM sessions WHERE id = ?",
        &.{id},
    );
    defer exist_q.deinit();
    const exist_row = (try exist_q.next()) orelse {
        return error.SessionNotFound;
    };
    exist_row.deinit(allocator);

    if (is_pinned) {
        var max_q = try db.query(
            allocator,
            "SELECT COALESCE(MAX(pinned_position), -1) FROM sessions WHERE is_pinned = 1",
            &.{},
        );
        defer max_q.deinit();
        const max_row = (try max_q.next()) orelse return error.SessionNotFound;
        defer max_row.deinit(allocator);
        const max_pos = std.fmt.parseInt(i64, max_row.values[0], 10) catch 0;
        const new_pos = max_pos + 1;
        const new_pos_str = try std.fmt.allocPrint(allocator, "{d}", .{new_pos});
        defer allocator.free(new_pos_str);
        try db.exec(
            allocator,
            "UPDATE sessions SET is_pinned = 1, pinned_position = ?, updated_at = datetime('now') WHERE id = ?",
            &.{ new_pos_str, id },
        );
        // Best-effort task sync (same id convention).
        db.exec(
            allocator,
            "UPDATE workspace_item_tasks SET is_pinned = 1, pinned_position = ?, updated_at = datetime('now') WHERE id = ?",
            &.{ new_pos_str, id },
        ) catch {};
        return new_pos;
    } else {
        try db.exec(
            allocator,
            "UPDATE sessions SET is_pinned = 0, pinned_position = 0, updated_at = datetime('now') WHERE id = ?",
            &.{id},
        );
        db.exec(
            allocator,
            "UPDATE workspace_item_tasks SET is_pinned = 0, pinned_position = 0, updated_at = datetime('now') WHERE id = ?",
            &.{id},
        ) catch {};
        return 0;
    }
}

/// Reorder the global pinned-sessions subset (Migration 104, drag-drop).
/// `ordered_ids` is the full top-to-bottom display order of pinned session
/// ids.
pub fn reorderPinnedSessions(
    allocator: std.mem.Allocator,
    db: *database.Db,
    ordered_ids: []const []const u8,
) !void {
    if (ordered_ids.len == 0) return;
    const count: i64 = @intCast(ordered_ids.len);
    var buf: [32]u8 = undefined;
    for (ordered_ids, 0..) |id_str, i| {
        const new_pos: i64 = count - 1 - @as(i64, @intCast(i));
        const pos_str = std.fmt.bufPrint(&buf, "{d}", .{new_pos}) catch {
            return error.IntegerTooLarge;
        };
        try db.exec(
            allocator,
            "UPDATE sessions SET pinned_position = ?, updated_at = datetime('now') " ++
                "WHERE id = ? AND is_pinned = 1",
            &.{ pos_str, id_str },
        );
    }
}

/// Reorder the pinned subset of a single workspace item.
pub fn reorderPinnedTasks(
    allocator: std.mem.Allocator,
    db: *database.Db,
    workspace_item_id: []const u8,
    ordered_ids: []const []const u8,
) !void {
    if (ordered_ids.len == 0) return;

    const count: i64 = @intCast(ordered_ids.len);
    var buf: [32]u8 = undefined;

    for (ordered_ids, 0..) |id_str, i| {
        const new_pos: i64 = count - 1 - @as(i64, @intCast(i));
        const pos_str = std.fmt.bufPrint(&buf, "{d}", .{new_pos}) catch {
            return error.IntegerTooLarge;
        };
        try db.exec(
            allocator,
            "UPDATE workspace_item_tasks SET pinned_position = ?, updated_at = datetime('now') " ++
                "WHERE id = ? AND workspace_item_id = ? AND is_pinned = 1",
            &.{ pos_str, id_str, workspace_item_id },
        );
    }
}

/// List all workspace item tasks by workspace_item_id
pub fn listWorkspaceItemTasks(
    allocator: std.mem.Allocator,
    db: *database.Db,
    workspace_item_id: []const u8,
) ![]WorkspaceItemTaskInfo {
    // Migration 062: added `t.description` to the SELECT column list,
    // positioned right after `t.workspace_item_id`. All subsequent
    // column indices shift by one.
    const sql =
        \\SELECT t.id, t.name, t.workspace_item_id, t.description, t.created_at, t.updated_at, t.task_type,
        \\       COALESCE(t.is_pinned, 0), COALESCE(t.pinned_position, 0),
        \\       k.kanban_column_id, COALESCE(k.kanban_position, 0)
        \\FROM workspace_item_tasks t
        \\LEFT JOIN kanban k ON k.workspace_item_task_id = t.id
        \\WHERE t.workspace_item_id = ?
        \\ORDER BY t.is_pinned DESC, t.pinned_position DESC, t.updated_at DESC, t.id DESC
    ;

    var rows = try db.query(allocator, sql, &.{workspace_item_id});
    defer rows.deinit();

    var tasks = std.ArrayList(WorkspaceItemTaskInfo).empty;
    errdefer {
        for (tasks.items) |task| task.deinit(allocator);
        tasks.deinit(allocator);
    }

    while (try rows.next()) |row| {
        // Row indices (post-Migration-061, post-Migration-084 which dropped
        // the routines JOIN): 0: id, 1: name, 2: workspace_item_id, 3:
        // description, 4: created_at, 5: updated_at, 6: task_type, 7:
        const task_type = if (row.values[6].len > 0)
            try allocator.dupe(u8, row.values[6])
        else
            try allocator.dupe(u8, "standard");
        const is_pinned_int = row.values[7];
        const pinned_position_str = row.values[8];

        const task = WorkspaceItemTaskInfo{
            .id = try allocator.dupe(u8, row.values[0]),
            .name = try allocator.dupe(u8, row.values[1]),
            .workspace_item_id = try allocator.dupe(u8, row.values[2]),
            .created_at = if (row.values[3].len > 0) try allocator.dupe(u8, row.values[3]) else null,
            .updated_at = if (row.values[4].len > 0) try allocator.dupe(u8, row.values[4]) else null,
            .task_type = task_type,
            .is_pinned = std.mem.eql(u8, is_pinned_int, "1"),
            .pinned_position = std.fmt.parseInt(i64, pinned_position_str, 10) catch 0,
            .kanban_column_id = if (row.values[8].len > 0) try allocator.dupe(u8, row.values[8]) else null,
            .kanban_position = std.fmt.parseInt(i64, row.values[9], 10) catch 0,
        };
        try tasks.append(allocator, task);
        row.deinit(allocator);
    }

    return try tasks.toOwnedSlice(allocator);
}

/// List workspace item tasks with cursor pagination. The `cursor` is the
/// value of the `sort_field` for the last task from the previous page; pass
/// null to fetch the first page.
fn escapeLikePattern(allocator: std.mem.Allocator, input: []const u8) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);
    for (input) |c| {
        if (c == '%' or c == '_' or c == '\\') {
            try out.append(allocator, '\\');
        }
        try out.append(allocator, c);
    }
    return try out.toOwnedSlice(allocator);
}

/// `q` is an optional case-insensitive substring filter applied at the SQL
/// level against `name`, `description`, and `tags` (Migration 067 JSON-encode
/// text).
pub fn getWorkspaceItemTaskById(
    allocator: std.mem.Allocator,
    db: *database.Db,
    workspace_item_id: []const u8,
    task_id: []const u8,
) !?WorkspaceItemTaskInfo {
    // SQL + row mapping mirror listWorkspaceItemTasksWithCursor (same
    // 18-column contract, indices 0-17) minus cursor/sort/pagination —
    // replaced by `WHERE t.id = ? ...
    const sql =
        \\SELECT t.id, t.name, t.workspace_item_id, t.description, t.created_at, t.updated_at, t.task_type, COALESCE(t.is_pinned, 0), COALESCE(t.pinned_position, 0), k.kanban_column_id, COALESCE(k.kanban_position, 0), COALESCE(s.is_auto_retry_until_stop, '0'), COALESCE(s.last_finish_reason, ''), CASE WHEN COALESCE(s.last_finish_reason, '') = 'stop' AND (t.last_human_touched_at_nano IS NULL OR t.last_human_touched_at_nano < CAST(strftime('%s', s.updated_at) AS INTEGER) * 1000) THEN 1 ELSE 0 END, t.tags, COALESCE(s.git_worktree_cwd, ''), t.cwd, CASE WHEN COALESCE(t.image_urls, '') != '' THEN 1 ELSE 0 END, CASE WHEN COALESCE(t.video_urls, '') != '' THEN 1 ELSE 0 END, COALESCE(t.skill_names, '') FROM workspace_item_tasks t LEFT JOIN kanban k ON k.workspace_item_task_id = t.id LEFT JOIN sessions s ON s.id = t.id WHERE t.workspace_item_id = ? AND t.id = ? LIMIT 1
    ;

    var rows = try db.query(allocator, sql, &.{ workspace_item_id, task_id });
    defer rows.deinit();

    if (try rows.next()) |row| {
        // Row indices are identical to the lister (see its mapping block):
        // 0-10 task/kanban fields, 11-12 session-joined fields, 13
        // needs_human_review, 14 tags, 15 worktree cwd, 16 per-task cwd, 17
        const task_type = if (row.values[6].len > 0)
            try allocator.dupe(u8, row.values[6])
        else
            try allocator.dupe(u8, "standard");
        const is_pinned_int = row.values[7];
        const pinned_position_str = row.values[8];

        const task = WorkspaceItemTaskInfo{
            .id = try allocator.dupe(u8, row.values[0]),
            .name = try allocator.dupe(u8, row.values[1]),
            .workspace_item_id = try allocator.dupe(u8, row.values[2]),
            .description = try allocator.dupe(u8, row.values[3]),
            .created_at = if (row.values[4].len > 0) try allocator.dupe(u8, row.values[4]) else null,
            .updated_at = if (row.values[5].len > 0) try allocator.dupe(u8, row.values[5]) else null,
            .task_type = task_type,
            .is_pinned = std.mem.eql(u8, is_pinned_int, "1"),
            .pinned_position = std.fmt.parseInt(i64, pinned_position_str, 10) catch 0,
            .kanban_column_id = if (row.values[9].len > 0) try allocator.dupe(u8, row.values[9]) else null,
            .kanban_position = std.fmt.parseInt(i64, row.values[10], 10) catch 0,
            .is_auto_retry_until_stop = try allocator.dupe(u8, row.values[11]),
            .last_finish_reason = try allocator.dupe(u8, row.values[12]),
            .needs_human_review = std.mem.eql(u8, row.values[13], "1"),
            .tags = try allocator.dupe(u8, row.values[14]),
            .git_worktree_cwd = try allocator.dupe(u8, row.values[15]),
            .cwd = try allocator.dupe(u8, row.values[16]),
            .is_have_image = std.mem.eql(u8, row.values[17], "1"),
            .is_have_video = std.mem.eql(u8, row.values[18], "1"),
            // '' = no skill.
            .skill_names = try allocator.dupe(u8, row.values[19]),
        };
        row.deinit(allocator);
        return task;
    }
    return null;
}

/// Lazy media fetch for a single task (media-flags change). Returns the raw
/// `||`-delimited `image_urls` / `video_urls` TEXT columns for one row,
/// scoped by both parent item id and task id.
pub const TaskMedia = struct {
    image_urls: []u8,
    video_urls: []u8,

    pub fn deinit(self: TaskMedia, alloc: std.mem.Allocator) void {
        alloc.free(self.image_urls);
        alloc.free(self.video_urls);
    }
};

pub fn getWorkspaceItemTaskMedia(
    allocator: std.mem.Allocator,
    db: *database.Db,
    workspace_item_id: []const u8,
    task_id: []const u8,
) !?TaskMedia {
    const sql = "SELECT COALESCE(t.image_urls, ''), COALESCE(t.video_urls, '') FROM workspace_item_tasks t WHERE t.workspace_item_id = ? AND t.id = ? LIMIT 1";
    var rows = try db.query(allocator, sql, &.{ workspace_item_id, task_id });
    defer rows.deinit();
    if (try rows.next()) |row| {
        const media = TaskMedia{
            .image_urls = try allocator.dupe(u8, row.values[0]),
            .video_urls = try allocator.dupe(u8, row.values[1]),
        };
        row.deinit(allocator);
        return media;
    }
    return null;
}

pub fn listWorkspaceItemTasksWithCursor(
    allocator: std.mem.Allocator,
    db: *database.Db,
    workspace_item_id: []const u8,
    limit: u32,
    cursor: ?[]const u8,
    sort_field: TaskSortField,
    sort_direction: TaskSortDirection,
    /// Per-column pagination filter (kanban-per-column-pagination,
    /// 2026-08-06).
    column_id: ?[]const u8,
    q: ?[]const u8,
) !struct {
    tasks: []WorkspaceItemTaskInfo,
    has_more: bool,
} {
    // Fetch `limit + 1` rows so we can detect "there are more pages"
    // without a separate COUNT query.
    const query_limit = limit + 1;
    const limit_str = try std.fmt.allocPrint(allocator, "{d}", .{query_limit});
    defer allocator.free(limit_str);

    // Build the ORDER BY column expression for the sort field. We hardcode
    // the column name (not the value) into the SQL string — only the values
    // are parameterized, so this is safe.
    const sort_col = switch (sort_field) {
        .created_at => "t.created_at",
        .updated_at => "t.updated_at",
        .name => "t.name",
    };
    const sort_dir_str = switch (sort_direction) {
        .asc => "ASC",
        .desc => "DESC",
    };
    const order_by = try std.fmt.allocPrint(
        allocator,
        "ORDER BY t.is_pinned DESC, t.pinned_position DESC, {s} {s}, t.id {s}",
        .{ sort_col, sort_dir_str, sort_dir_str },
    );
    defer allocator.free(order_by);

    // Cursor "<sort_value>|<id>": both halves are binds, or the value drops out
    // of the `workspace_item_id` scope below. sort_value binds twice — the
    // clause compares it twice — then id.
    var cursor_binds: [3][]const u8 = undefined;
    var cursor_bind_count: usize = 0;
    const cursor_clause: []u8 = blk: {
        const c = cursor orelse break :blk try allocator.dupe(u8, "");
        const pipe_idx = std.mem.indexOfScalar(u8, c, '|') orelse
            return error.MalformedCursor;
        const sort_value = c[0..pipe_idx];
        const id_value = c[pipe_idx + 1 ..];

        const cmp = switch (sort_direction) {
            .desc => "<",
            .asc => ">",
        };
        cursor_binds[0] = sort_value;
        cursor_binds[1] = sort_value;
        cursor_binds[2] = id_value;
        cursor_bind_count = 3;
        break :blk try std.fmt.allocPrint(
            allocator,
            " AND t.is_pinned = 0 AND ({s} {s} ? OR ({s} = ? AND t.id {s} ?))",
            .{ sort_col, cmp, sort_col, cmp },
        );
    };
    defer allocator.free(cursor_clause);

    // Optional q filter — case-insensitive substring match on name /
    // description / tags.
    var q_pattern: ?[]u8 = null;
    defer if (q_pattern) |p| allocator.free(p);
    var q_clause: []u8 = try allocator.dupe(u8, "");
    errdefer allocator.free(q_clause);
    if (q) |raw_q| {
        if (raw_q.len > 0) {
            const escaped = try escapeLikePattern(allocator, raw_q);
            defer allocator.free(escaped);
            q_pattern = try std.fmt.allocPrint(allocator, "%{s}%", .{escaped});
            q_clause = try std.fmt.allocPrint(
                allocator,
                " AND (LOWER(t.name) LIKE ? ESCAPE '\\' OR LOWER(COALESCE(t.description, '')) LIKE ? ESCAPE '\\' OR LOWER(COALESCE(t.tags, '')) LIKE ? ESCAPE '\\')",
                .{},
            );
        }
    }
    defer allocator.free(q_clause);

    // Optional column_id filter (per-column pagination, 2026-08-06). When
    // `column_id` is null OR empty, column_id_clause is "" (no WHERE addition
    // — matches the original behavior).
    var column_id_clause: []u8 = try allocator.dupe(u8, "");
    errdefer allocator.free(column_id_clause);
    if (column_id) |cid| {
        if (cid.len > 0) {
            column_id_clause = try std.fmt.allocPrint(
                allocator,
                " AND (k.kanban_column_id = ? OR k.kanban_column_id IS NULL)",
                .{},
            );
        }
    }
    defer allocator.free(column_id_clause);

    const sql = try std.fmt.allocPrint(
        allocator,
        // Auto-retry-until-stop: LEFT JOIN sessions on t.id = sessions.id
        // (per the project convention task.id == session.id; standard tasks
        // that have no matching session row get NULL → COALESCE to '0').
        "SELECT t.id, t.name, t.workspace_item_id, t.description, t.created_at, t.updated_at, t.task_type, COALESCE(t.is_pinned, 0), COALESCE(t.pinned_position, 0), k.kanban_column_id, COALESCE(k.kanban_position, 0), COALESCE(s.is_auto_retry_until_stop, '0'), COALESCE(s.last_finish_reason, ''), CASE WHEN COALESCE(s.last_finish_reason, '') = 'stop' AND (t.last_human_touched_at_nano IS NULL OR t.last_human_touched_at_nano < CAST(strftime('%s', s.updated_at) AS INTEGER) * 1000) THEN 1 ELSE 0 END, t.tags, COALESCE(s.git_worktree_cwd, ''), t.cwd, CASE WHEN COALESCE(t.image_urls, '') != '' THEN 1 ELSE 0 END, CASE WHEN COALESCE(t.video_urls, '') != '' THEN 1 ELSE 0 END, COALESCE(t.skill_names, '') FROM workspace_item_tasks t LEFT JOIN kanban k ON k.workspace_item_task_id = t.id LEFT JOIN sessions s ON s.id = t.id WHERE t.workspace_item_id = ?{s}{s}{s} {s} LIMIT {s}",
        .{ cursor_clause, column_id_clause, q_clause, order_by, limit_str },
    );
    defer allocator.free(sql);

    // Build binds: always workspace_item_id; when column_id is set, append it
    // once (one bind slot for the `?` in column_id_clause); when q is set,
    // append the q_pattern 3 times (one per OR'd LIKE clause).
    var binds = std.ArrayList([]const u8).empty;
    defer binds.deinit(allocator);
    try binds.append(allocator, workspace_item_id);
    // Cursor binds come immediately after the workspace scope: the clause is
    // emitted before column_id and q in the SQL above, so the bind order must
    // mirror it.
    for (cursor_binds[0..cursor_bind_count]) |v| try binds.append(allocator, v);
    if (column_id) |cid| {
        if (cid.len > 0) {
            try binds.append(allocator, cid);
        }
    }
    if (q_pattern) |p| {
        try binds.append(allocator, p);
        try binds.append(allocator, p);
        try binds.append(allocator, p);
    }

    var rows = try db.query(allocator, sql, binds.items);
    defer rows.deinit();

    var tasks = std.ArrayList(WorkspaceItemTaskInfo).empty;
    errdefer {
        for (tasks.items) |task| task.deinit(allocator);
        tasks.deinit(allocator);
    }

    while (try rows.next()) |row| {
        // Row indices (post-Migration-063-attended-toggle JOIN,
        // post-Migration-065-notification-icon JOIN, post-Migration-067-tags,
        // post-kanban-task-git-branch plan 2026-08-06,
        const task_type = if (row.values[6].len > 0)
            try allocator.dupe(u8, row.values[6])
        else
            try allocator.dupe(u8, "standard");
        const is_pinned_int = row.values[7];
        const pinned_position_str = row.values[8];

        const task = WorkspaceItemTaskInfo{
            .id = try allocator.dupe(u8, row.values[0]),
            .name = try allocator.dupe(u8, row.values[1]),
            .workspace_item_id = try allocator.dupe(u8, row.values[2]),
            // Migration 062: description at index 3.
            .description = try allocator.dupe(u8, row.values[3]),
            .created_at = if (row.values[4].len > 0) try allocator.dupe(u8, row.values[4]) else null,
            .updated_at = if (row.values[5].len > 0) try allocator.dupe(u8, row.values[5]) else null,
            .task_type = task_type,
            .is_pinned = std.mem.eql(u8, is_pinned_int, "1"),
            .pinned_position = std.fmt.parseInt(i64, pinned_position_str, 10) catch 0,
            .kanban_column_id = if (row.values[9].len > 0) try allocator.dupe(u8, row.values[9]) else null,
            .kanban_position = std.fmt.parseInt(i64, row.values[10], 10) catch 0,
            // Auto-retry-until-stop: index 11 (joined from sessions).
            // COALESCE'd to '0' in the SQL so this is always non-empty.
            .is_auto_retry_until_stop = try allocator.dupe(u8, row.values[11]),
            // Kanban notification icon (Migration 065): index 12.
            // COALESCE'd to '' in the SQL so this is always non-empty.
            .last_finish_reason = try allocator.dupe(u8, row.values[12]),
            // Kanban notification icon (Migration 065): index 13.
            // SQL CASE produces '1' or '0'; parse to bool.
            .needs_human_review = std.mem.eql(u8, row.values[13], "1"),
            // Kanban task tags (Migration 067): index 14. NOT NULL
            // DEFAULT '' so always present.
            .tags = try allocator.dupe(u8, row.values[14]),
            // Session worktree cwd (Migration 046): index 15. COALESCE'd
            // to '' in the SQL when no session row exists. Empty string
            // is the canonical "no worktree" sentinel.
            .git_worktree_cwd = try allocator.dupe(u8, row.values[15]),
            // Per-task cwd (Migration 070): index 16.
            .cwd = try allocator.dupe(u8, row.values[16]),
            // Image urls (Migration 069 read-path fix): index 17. NOT NULL
            // DEFAULT '' so always present; empty string is the "no images"
            // sentinel.
            .is_have_image = std.mem.eql(u8, row.values[17], "1"),
            // Video urls (Migration 090): index 18. Same contract.
            .is_have_video = std.mem.eql(u8, row.values[18], "1"),
            // '' = no skill.
            .skill_names = try allocator.dupe(u8, row.values[19]),
        };
        try tasks.append(allocator, task);
        row.deinit(allocator);
    }

    const has_more = tasks.items.len > limit;
    if (has_more) {
        // Drop the extra row we fetched to detect has_more.
        const extra = tasks.pop().?;
        extra.deinit(allocator);
    }

    return .{
        .tasks = try tasks.toOwnedSlice(allocator),
        .has_more = has_more,
    };
}

/// Returns one page of distinct tags on tasks belonging to the given
/// workspace item, ordered by frequency DESC then by most-recent usage DESC.
/// Used by the kanban task detail dialog autocomplete dropdown.
pub fn listKanbanDistinctTags(
    allocator: std.mem.Allocator,
    db: *pabrikcore.database.Db,
    workspace_item_id: []const u8,
    limit: u32,
    offset: u32,
) anyerror!KanbanTagSuggestionsPage {
    // Defensive: clamp limit to a sane max even if the caller passes
    // a huge value. The handler also clamps but defense-in-depth.
    const clamped_limit: u32 = if (limit == 0) 1 else if (limit > 50) 50 else limit;

    // LIMIT N+1 trick: fetch one extra row so we can detect has_more
    // in a single query. If the result has <= N rows, has_more=false.
    const fetch_limit: u32 = clamped_limit + 1;

    // Format the u32 LIMIT/OFFSET to strings for bind. db.query
    // only binds TEXT, so integers must be string-formatted. SQLite
    // coerces numeric-looking TEXT in numeric contexts.
    const limit_str = std.fmt.allocPrint(allocator, "{d}", .{fetch_limit}) catch "";
    const offset_str = std.fmt.allocPrint(allocator, "{d}", .{offset}) catch "";
    defer {
        if (limit_str.len > 0) allocator.free(limit_str);
        if (offset_str.len > 0) allocator.free(offset_str);
    }

    // `json_each` is sqlite's table-valued JSON expander, `jsonb_array_elements_text`
    // its postgres counterpart. The `LIKE '[%'` guard stands in for sqlite's
    // `json_valid`/`json_type`: a value that is not an array expands to nothing.
    const sql = if (dialect.is_postgres)
        \\SELECT je.value AS tag, COUNT(*) AS cnt, MAX(t.updated_at) AS last_used
        \\FROM workspace_item_tasks t
        \\CROSS JOIN LATERAL jsonb_array_elements_text(
        \\    CASE WHEN t.tags LIKE '[%' THEN t.tags::jsonb ELSE '[]'::jsonb END
        \\) AS je(value)
        \\WHERE t.workspace_item_id = ?
        \\GROUP BY je.value
        \\ORDER BY cnt DESC, last_used DESC
        \\LIMIT ?
        \\OFFSET ?
    else
        \\SELECT je.value AS tag, COUNT(*) AS cnt, MAX(t.updated_at) AS last_used
        \\FROM workspace_item_tasks t, json_each(t.tags) je
        \\WHERE t.workspace_item_id = ?
        \\  AND json_valid(t.tags) = 1
        \\  AND json_type(t.tags) = 'array'
        \\GROUP BY je.value
        \\ORDER BY cnt DESC, last_used DESC
        \\LIMIT ?
        \\OFFSET ?
    ;

    var q = try db.query(allocator, sql, &.{
        workspace_item_id,
        limit_str,
        offset_str,
    });
    defer q.deinit();

    var results: std.ArrayList(KanbanTagSuggestion) = .empty;
    errdefer {
        for (results.items) |r| r.deinit(allocator);
        results.deinit(allocator);
    }

    while (try q.next()) |row| {
        defer row.deinit(allocator);
        const suggestion: KanbanTagSuggestion = .{
            .name = try allocator.dupe(u8, row.values[0]),
            .count = std.fmt.parseInt(u32, row.values[1], 10) catch 0,
            .last_used_at = if (row.values[2].len > 0)
                try allocator.dupe(u8, row.values[2])
            else
                null,
        };
        try results.append(allocator, suggestion);
    }

    // Apply the LIMIT N+1 trick: if we got back more than the
    // requested limit, truncate and set has_more = true.
    const has_more = results.items.len > clamped_limit;
    if (has_more) {
        // Drop the last (extra) row; we don't want to return it.
        const last = results.pop().?;
        last.deinit(allocator);
    }

    return KanbanTagSuggestionsPage{
        .tags = try results.toOwnedSlice(allocator),
        .has_more = has_more,
    };
}

/// Get all active sessions for SSE broadcast
pub fn getSessionsForBroadcast(
    allocator: std.mem.Allocator,
    db: *database.Db,
) ![]SessionBroadcastInfo {
    const sql = "SELECT s.id, COALESCE(s.name, ''), COALESCE(s.status, 'active'), COALESCE(s.cwd, ''), COALESCE(CAST(s.created_at AS TEXT), ''), COALESCE(CAST(s.updated_at AS TEXT), ''), COALESCE(h.agent, 'Agent'), COALESCE(s.selected_profile_model, ''), COALESCE(s.git_worktree_cwd, ''), COALESCE(s.pr_url, ''), COALESCE(s.pr_provider, ''), COALESCE(s.sub_agent_name, ''), COALESCE(s.parent_session_id, '') FROM sessions s LEFT JOIN llm_history h ON s.id = h.session_id ORDER BY s.updated_at DESC";

    var rows = db.query(allocator, sql, &[_][]const u8{}) catch return &[_]SessionBroadcastInfo{};
    defer rows.deinit();

    var sessions = std.ArrayList(SessionBroadcastInfo).empty;
    errdefer sessions.deinit(allocator);

    while (rows.next() catch false) |row| {
        const session = SessionBroadcastInfo{
            .session_id = try allocator.dupe(u8, row.values[0]),
            .session_name = try allocator.dupe(u8, row.values[1]),
            .status = try allocator.dupe(u8, row.values[2]),
            .cwd = try allocator.dupe(u8, row.values[3]),
            .created_at = try allocator.dupe(u8, row.values[4]),
            .updated_at = try allocator.dupe(u8, row.values[5]),
            .agent = try allocator.dupe(u8, row.values[6]),
            .selected_profile_model = try allocator.dupe(u8, row.values[7]),
            .git_worktree_cwd = try allocator.dupe(u8, row.values[8]),
            .pr_url = try allocator.dupe(u8, row.values[9]),
            .pr_provider = try allocator.dupe(u8, row.values[10]),
            .sub_agent_name = try allocator.dupe(u8, row.values[11]),
            .parent_session_id = try allocator.dupe(u8, row.values[12]),
        };
        try sessions.append(allocator, session);
    }

    return try sessions.toOwnedSlice(allocator);
}

/// Free session broadcast info array
pub fn freeSessionsForBroadcast(allocator: std.mem.Allocator, sessions: []SessionBroadcastInfo) void {
    for (sessions) |*s| {
        allocator.free(s.session_id);
        allocator.free(s.session_name);
        allocator.free(s.status);
        allocator.free(s.cwd);
        allocator.free(s.created_at);
        allocator.free(s.updated_at);
        allocator.free(s.agent);
        allocator.free(s.git_worktree_cwd);
        allocator.free(s.pr_url);
        allocator.free(s.pr_provider);
        allocator.free(s.sub_agent_name);
        allocator.free(s.parent_session_id);
    }
    allocator.free(sessions);
}

pub fn updateSessionUpdatedAt(allocator: std.mem.Allocator, db: *database.Db, session_id: []const u8) !void {
    const sql = "UPDATE sessions SET updated_at = CURRENT_TIMESTAMP WHERE id = ?";
    try db.exec(allocator, sql, &.{session_id});
}

pub fn updateWorkspaceUpdatedAt(allocator: std.mem.Allocator, db: *database.Db, session_id: []const u8) !void {
    const sql = "UPDATE workspace_item_tasks SET updated_at = datetime('now') WHERE id = ?";
    try db.exec(allocator, sql, &.{session_id});
}

// ===================================================================== Tests
// for listKanbanDistinctTags

fn setupDbWithTagsForKanban() !struct { db: database.Db, threaded: std.Io.Threaded } {
    const alloc = testing.allocator;
    var threaded = std.Io.Threaded.init(alloc, .{});
    errdefer threaded.deinit();
    const io = threaded.io();
    var db: database.Db = .{};
    errdefer db.deinit();
    try test_db.openMemory(&db, io);

    // Minimal schema: workspace_items + workspace_item_tasks with the
    // tags column (Migration 067). We don't run all 66 prior migrations
    // — the model fn doesn't depend on them.
    try db.exec(alloc, "CREATE TABLE workspace_items (id TEXT PRIMARY KEY, workspace_id TEXT NOT NULL)", &.{});
    try db.exec(alloc,
        \\CREATE TABLE workspace_item_tasks (
        \\  id TEXT PRIMARY KEY,
        \\  workspace_item_id TEXT NOT NULL,
        \\  updated_at TEXT DEFAULT CURRENT_TIMESTAMP,
        \\  tags TEXT NOT NULL DEFAULT '',
        \\  cwd TEXT NOT NULL DEFAULT ''
        \\)
    , &.{});
    try db.exec(alloc, "INSERT INTO workspace_items (id, workspace_id) VALUES ('item_x', 'ws_x')", &.{});
    return .{ .db = db, .threaded = threaded };
}

fn insertKanbanTask(db: *database.Db, alloc: std.mem.Allocator, id: []const u8, item_id: []const u8, tags_json: []const u8) !void {
    // Backend.exec binds empty `[]const u8` as SQL NULL — which would
    // fail the NOT NULL constraint on `tags`.
    if (tags_json.len == 0) {
        try db.exec(alloc, "INSERT INTO workspace_item_tasks (id, workspace_item_id, tags) VALUES (?, ?, '')", &.{ id, item_id });
    } else {
        try db.exec(alloc, "INSERT INTO workspace_item_tasks (id, workspace_item_id, tags) VALUES (?, ?, ?)", &.{ id, item_id, tags_json });
    }
}

fn insertKanbanTaskWithUpdatedAt(
    db: *database.Db,
    alloc: std.mem.Allocator,
    id: []const u8,
    item_id: []const u8,
    tags_json: []const u8,
    updated_at: []const u8,
) !void {
    try db.exec(alloc, "INSERT INTO workspace_item_tasks (id, workspace_item_id, tags, updated_at) VALUES (?, ?, ?, ?)", &.{ id, item_id, tags_json, updated_at });
}

test "listKanbanDistinctTags returns empty page when kanban has no tasks" {
    var s = try setupDbWithTagsForKanban();
    defer s.threaded.deinit();
    defer s.db.deinit();
    const alloc = testing.allocator;
    const page = try listKanbanDistinctTags(alloc, &s.db, "item_x", 8, 0);
    defer page.deinit(alloc);
    try testing.expectEqual(@as(usize, 0), page.tags.len);
    try testing.expectEqual(false, page.has_more);
}

test "listKanbanDistinctTags returns empty page when tasks exist but none have tags" {
    var s = try setupDbWithTagsForKanban();
    defer s.threaded.deinit();
    defer s.db.deinit();
    const alloc = testing.allocator;
    try insertKanbanTask(&s.db, alloc, "t1", "item_x", "");
    try insertKanbanTask(&s.db, alloc, "t2", "item_x", "");
    const page = try listKanbanDistinctTags(alloc, &s.db, "item_x", 8, 0);
    defer page.deinit(alloc);
    try testing.expectEqual(@as(usize, 0), page.tags.len);
    try testing.expectEqual(false, page.has_more);
}

test "listKanbanDistinctTags returns single tag from one task" {
    var s = try setupDbWithTagsForKanban();
    defer s.threaded.deinit();
    defer s.db.deinit();
    const alloc = testing.allocator;
    try insertKanbanTask(&s.db, alloc, "t1", "item_x", "[\"bug\"]");
    const page = try listKanbanDistinctTags(alloc, &s.db, "item_x", 8, 0);
    defer page.deinit(alloc);
    try testing.expectEqual(@as(usize, 1), page.tags.len);
    try testing.expectEqualStrings("bug", page.tags[0].name);
    try testing.expectEqual(@as(u32, 1), page.tags[0].count);
    try testing.expectEqual(false, page.has_more);
}

test "listKanbanDistinctTags orders by frequency DESC (most-used first)" {
    var s = try setupDbWithTagsForKanban();
    defer s.threaded.deinit();
    defer s.db.deinit();
    const alloc = testing.allocator;
    // "bug" used by 3 tasks, "urgent" used by 2, "frontend" used by 1.
    try insertKanbanTask(&s.db, alloc, "t1", "item_x", "[\"bug\",\"urgent\"]");
    try insertKanbanTask(&s.db, alloc, "t2", "item_x", "[\"bug\",\"frontend\"]");
    try insertKanbanTask(&s.db, alloc, "t3", "item_x", "[\"bug\",\"urgent\"]");
    const page = try listKanbanDistinctTags(alloc, &s.db, "item_x", 8, 0);
    defer page.deinit(alloc);
    try testing.expectEqual(@as(usize, 3), page.tags.len);
    try testing.expectEqualStrings("bug", page.tags[0].name);
    try testing.expectEqual(@as(u32, 3), page.tags[0].count);
    try testing.expectEqualStrings("urgent", page.tags[1].name);
    try testing.expectEqual(@as(u32, 2), page.tags[1].count);
    try testing.expectEqualStrings("frontend", page.tags[2].name);
    try testing.expectEqual(@as(u32, 1), page.tags[2].count);
    try testing.expectEqual(false, page.has_more);
}

test "listKanbanDistinctTags breaks ties on recency (most-recently-used wins)" {
    var s = try setupDbWithTagsForKanban();
    defer s.threaded.deinit();
    defer s.db.deinit();
    const alloc = testing.allocator;
    try insertKanbanTaskWithUpdatedAt(&s.db, alloc, "t1", "item_x", "[\"old-tag\"]", "2025-01-01 00:00:00");
    try insertKanbanTaskWithUpdatedAt(&s.db, alloc, "t2", "item_x", "[\"new-tag\"]", "2026-12-31 23:59:59");
    const page = try listKanbanDistinctTags(alloc, &s.db, "item_x", 8, 0);
    defer page.deinit(alloc);
    try testing.expectEqual(@as(usize, 2), page.tags.len);
    try testing.expectEqualStrings("new-tag", page.tags[0].name);
    try testing.expectEqualStrings("old-tag", page.tags[1].name);
}

test "listKanbanDistinctTags respects the limit query" {
    var s = try setupDbWithTagsForKanban();
    defer s.threaded.deinit();
    defer s.db.deinit();
    const alloc = testing.allocator;
    // 5 distinct tags but ask for limit=2.
    try insertKanbanTask(&s.db, alloc, "t1", "item_x", "[\"a\",\"b\",\"c\",\"d\",\"e\"]");
    const page = try listKanbanDistinctTags(alloc, &s.db, "item_x", 2, 0);
    defer page.deinit(alloc);
    try testing.expectEqual(@as(usize, 2), page.tags.len);
    try testing.expectEqual(true, page.has_more); // 5 > 2, so more available
}

test "listKanbanDistinctTags has_more=false when result fits in limit" {
    var s = try setupDbWithTagsForKanban();
    defer s.threaded.deinit();
    defer s.db.deinit();
    const alloc = testing.allocator;
    try insertKanbanTask(&s.db, alloc, "t1", "item_x", "[\"a\",\"b\",\"c\"]");
    const page = try listKanbanDistinctTags(alloc, &s.db, "item_x", 8, 0);
    defer page.deinit(alloc);
    try testing.expectEqual(@as(usize, 3), page.tags.len);
    try testing.expectEqual(false, page.has_more); // 3 <= 8, no more
}

test "listKanbanDistinctTags paginates with offset (next page fetches distinct tags past the first page)" {
    var s = try setupDbWithTagsForKanban();
    defer s.threaded.deinit();
    defer s.db.deinit();
    const alloc = testing.allocator;
    // Seed 5 distinct tags, all used once. Fetch in pages of 2.
    try insertKanbanTask(&s.db, alloc, "t1", "item_x", "[\"a\",\"b\",\"c\",\"d\",\"e\"]");
    // Page 1 (offset=0, limit=2): expect first 2 of {a,b,c,d,e}.
    const page1 = try listKanbanDistinctTags(alloc, &s.db, "item_x", 2, 0);
    defer page1.deinit(alloc);
    try testing.expectEqual(@as(usize, 2), page1.tags.len);
    try testing.expectEqual(true, page1.has_more);
    // Page 2 (offset=2, limit=2): expect next 2.
    const page2 = try listKanbanDistinctTags(alloc, &s.db, "item_x", 2, 2);
    defer page2.deinit(alloc);
    try testing.expectEqual(@as(usize, 2), page2.tags.len);
    try testing.expectEqual(true, page2.has_more);
    // Page 3 (offset=4, limit=2): expect 1 tag, no more.
    const page3 = try listKanbanDistinctTags(alloc, &s.db, "item_x", 2, 4);
    defer page3.deinit(alloc);
    try testing.expectEqual(@as(usize, 1), page3.tags.len);
    try testing.expectEqual(false, page3.has_more);
}

test "listKanbanDistinctTags filters by workspace_item_id (no cross-kanban leakage)" {
    var s = try setupDbWithTagsForKanban();
    defer s.threaded.deinit();
    defer s.db.deinit();
    const alloc = testing.allocator;
    try s.db.exec(alloc, "INSERT INTO workspace_items (id, workspace_id) VALUES ('item_y', 'ws_x')", &.{});
    try insertKanbanTask(&s.db, alloc, "t1", "item_x", "[\"bug\"]");
    try insertKanbanTask(&s.db, alloc, "t2", "item_y", "[\"different\"]");
    const page = try listKanbanDistinctTags(alloc, &s.db, "item_x", 8, 0);
    defer page.deinit(alloc);
    try testing.expectEqual(@as(usize, 1), page.tags.len);
    try testing.expectEqualStrings("bug", page.tags[0].name);
}

test "listKanbanDistinctTags skips rows with malformed tags JSON (defensive)" {
    var s = try setupDbWithTagsForKanban();
    defer s.threaded.deinit();
    defer s.db.deinit();
    const alloc = testing.allocator;
    try insertKanbanTask(&s.db, alloc, "t1", "item_x", "[\"good\"]");
    try insertKanbanTask(&s.db, alloc, "t2", "item_x", "not-a-json-array");
    const page = try listKanbanDistinctTags(alloc, &s.db, "item_x", 8, 0);
    defer page.deinit(alloc);
    try testing.expectEqual(@as(usize, 1), page.tags.len);
    try testing.expectEqualStrings("good", page.tags[0].name);
}
// ════════════════════════════════════════════════════════════════════════════
// Inline behavioural tests for the kanban task search q-parameter Per project

const TestCtx = struct {
    db: database.Db,
    threaded: std.Io.Threaded,
    /// Allocator (the testing.allocator) — needed by the tool-call-loading
    /// test that has to allocate row data via `createSession` and
    /// `saveToolResultPlaceholder`. Other tests don't use this field.
    alloc: std.mem.Allocator,
};

/// Set up an in-memory SQLite DB with the minimum schema needed for
/// `listWorkspaceItemTasksWithCursor` to run.
fn setupDb() !TestCtx {
    const alloc = testing.allocator;
    var threaded = std.Io.Threaded.init(alloc, .{});
    errdefer threaded.deinit();
    const io = threaded.io();
    var db: database.Db = .{};
    errdefer db.deinit();
    try test_db.openMemory(&db, io);

    try db.exec(alloc, "CREATE TABLE workspace_items (id TEXT PRIMARY KEY, workspace_id TEXT, item_type TEXT)", &.{});
    try db.exec(alloc,
        \\CREATE TABLE workspace_item_tasks (
        \\    id TEXT PRIMARY KEY,
        \\    name TEXT,
        \\    workspace_item_id TEXT,
        \\    description TEXT,
        \\    created_at TEXT,
        \\    updated_at TEXT,
        \\    task_type TEXT NOT NULL DEFAULT 'standard',
        \\    is_pinned INTEGER DEFAULT 0,
        \\    pinned_position INTEGER DEFAULT 0,
        \\    -- kanban_column_id / kanban_position REMOVED post-Migration-072
        \\    -- (they now live in the `kanban` join table below)
        \\    last_human_touched_at_nano BIGINT,
        \\    tags TEXT NOT NULL DEFAULT '',
        \\    cwd TEXT NOT NULL DEFAULT '',
        \\    image_urls TEXT NOT NULL DEFAULT '',
        \\    video_urls TEXT NOT NULL DEFAULT '',
        \\    -- Migration 110 — the skill this task asks the agent to use.
        \\    skill_names TEXT NOT NULL DEFAULT ''
        \\)
    , &.{});
    try db.exec(alloc,
        \\CREATE TABLE kanban (
        \\    workspace_item_task_id TEXT PRIMARY KEY,
        \\    kanban_column_id TEXT NOT NULL,
        \\    kanban_position INTEGER NOT NULL DEFAULT 0
        \\)
    , &.{});
    try db.exec(alloc,
        \\CREATE TABLE sessions (
        \\    id TEXT PRIMARY KEY,
        \\    is_auto_retry_until_stop TEXT DEFAULT '0',
        \\    last_finish_reason TEXT,
        \\    updated_at TEXT,
        \\    git_worktree_cwd TEXT
        \\)
    , &.{});
    return .{ .db = db, .threaded = threaded, .alloc = alloc };
}

fn insertTask(
    ctx: *TestCtx,
    alloc: std.mem.Allocator,
    id: []const u8,
    name: []const u8,
    description: []const u8,
    tags: []const u8,
) !void {
    try ctx.db.exec(alloc, "INSERT INTO workspace_items (id, workspace_id, item_type) " ++
        "VALUES ('wi_1', 'ws_1', 'kanban') ON CONFLICT DO NOTHING", &.{});
    try ctx.db.exec(alloc,
        \\INSERT INTO workspace_item_tasks
        \\(id, name, workspace_item_id, description, updated_at, task_type, tags)
        \\VALUES (?, ?, 'wi_1', ?, datetime('now'), 'standard', ?)
    , &.{ id, name, description, tags });
}

/// Per-column pagination helper (plan 2026-08-06-kanban-per-column-
/// pagination.md, Task 3).
fn insertTaskInColumn(
    ctx: *TestCtx,
    alloc: std.mem.Allocator,
    id: []const u8,
    name: []const u8,
    description: []const u8,
    tags: []const u8,
    column_id: ?[]const u8,
    position: i64,
) !void {
    try ctx.db.exec(alloc, "INSERT INTO workspace_items (id, workspace_id, item_type) " ++
        "VALUES ('wi_1', 'ws_1', 'kanban') ON CONFLICT DO NOTHING", &.{});
    // SQLite exec binds only TEXT, so format position as a string.
    const pos_str = try std.fmt.allocPrint(alloc, "{d}", .{position});
    defer alloc.free(pos_str);
    // Post-Migration-072: the task→column mapping lives in `kanban`.
    // Insert the task row first (no kanban columns), then optionally
    // insert a kanban row when column_id is set.
    try ctx.db.exec(alloc,
        \\INSERT INTO workspace_item_tasks
        \\(id, name, workspace_item_id, description, updated_at, task_type, tags)
        \\VALUES (?, ?, 'wi_1', ?, datetime('now'), 'standard', ?)
    , &.{ id, name, description, tags });
    if (column_id) |cid| {
        try ctx.db.exec(alloc,
            \\INSERT INTO kanban (workspace_item_task_id, kanban_column_id, kanban_position)
            \\VALUES (?, ?, ?)
        , &.{ id, cid, pos_str });
    }
}

/// Free a returned tasks slice — mirrors the production deinit pattern
/// (each row's heap-allocated fields + the slice itself).
fn freeTasks(alloc: std.mem.Allocator, tasks: []WorkspaceItemTaskInfo) void {
    for (tasks) |*t| t.deinit(alloc);
    alloc.free(tasks);
}

// ─── Contract 1: q matches against name ───────────────────────────────────

test "listWorkspaceItemTasksWithCursor matches q against name (case-insensitive substring)" {
    const alloc = testing.allocator;
    var ctx = try setupDb();
    defer ctx.db.deinit();
    defer ctx.threaded.deinit();

    try insertTask(&ctx, alloc, "task_1", "fix login bug", "", "[]");
    try insertTask(&ctx, alloc, "task_2", "logout cleanup", "", "[]");
    try insertTask(&ctx, alloc, "task_3", "design page", "", "[]");

    const result = try listWorkspaceItemTasksWithCursor(
        alloc,
        &ctx.db,
        "wi_1",
        100,
        null,
        .updated_at,
        .desc,
        null,
        "login",
    );
    defer freeTasks(alloc, result.tasks);

    try testing.expectEqual(@as(usize, 1), result.tasks.len);
    try testing.expectEqualStrings("task_1", result.tasks[0].id);
    try testing.expect(!result.has_more);
}

// ─── Contract 2: q matches against description ────────────────────────────

test "listWorkspaceItemTasksWithCursor matches q against description" {
    const alloc = testing.allocator;
    var ctx = try setupDb();
    defer ctx.db.deinit();
    defer ctx.threaded.deinit();

    try insertTask(&ctx, alloc, "task_1", "feature one", "contains login flow", "[]");
    try insertTask(&ctx, alloc, "task_2", "feature two", "totally unrelated", "[]");
    try insertTask(&ctx, alloc, "task_3", "feature three", "another login ref", "[]");

    const result = try listWorkspaceItemTasksWithCursor(
        alloc,
        &ctx.db,
        "wi_1",
        100,
        null,
        .updated_at,
        .desc,
        null,
        "login",
    );
    defer freeTasks(alloc, result.tasks);

    try testing.expectEqual(@as(usize, 2), result.tasks.len);
    try testing.expectEqualStrings("task_3", result.tasks[0].id);
    try testing.expectEqualStrings("task_1", result.tasks[1].id);
}

// ─── Contract 3: q matches against tags (JSON-encode substring) ─────────

test "listWorkspaceItemTasksWithCursor matches q against tags JSON text" {
    const alloc = testing.allocator;
    var ctx = try setupDb();
    defer ctx.db.deinit();
    defer ctx.threaded.deinit();

    try insertTask(&ctx, alloc, "task_1", "feature one", "", "[]");
    try insertTask(&ctx, alloc, "task_2", "feature two", "", "[\"login\",\"urgent\"]");
    try insertTask(&ctx, alloc, "task_3", "feature three", "", "[\"design\",\"frontend\"]");

    const result = try listWorkspaceItemTasksWithCursor(
        alloc,
        &ctx.db,
        "wi_1",
        100,
        null,
        .updated_at,
        .desc,
        null,
        "login",
    );
    defer freeTasks(alloc, result.tasks);

    try testing.expectEqual(@as(usize, 1), result.tasks.len);
    try testing.expectEqualStrings("task_2", result.tasks[0].id);
}

// ─── Contract 4: q is case-insensitive across all 3 fields ──────────────

test "listWorkspaceItemTasksWithCursor q is case-insensitive" {
    const alloc = testing.allocator;
    var ctx = try setupDb();
    defer ctx.db.deinit();
    defer ctx.threaded.deinit();

    try insertTask(&ctx, alloc, "task_1", "Fix Login", "", "[]");
    try insertTask(&ctx, alloc, "task_2", "feature", "LOGIN FLOW", "[]");
    try insertTask(&ctx, alloc, "task_3", "feature", "", "[\"Login\",\"urgent\"]");

    const upper = try listWorkspaceItemTasksWithCursor(
        alloc,
        &ctx.db,
        "wi_1",
        100,
        null,
        .updated_at,
        .desc,
        null,
        "LOGIN",
    );
    defer freeTasks(alloc, upper.tasks);
    try testing.expectEqual(@as(usize, 3), upper.tasks.len);

    const mixed = try listWorkspaceItemTasksWithCursor(
        alloc,
        &ctx.db,
        "wi_1",
        100,
        null,
        .updated_at,
        .desc,
        null,
        "LoGiN",
    );
    defer freeTasks(alloc, mixed.tasks);
    try testing.expectEqual(@as(usize, 3), mixed.tasks.len);
}

// ─── Contract 5: empty q is equivalent to no filter ──────────────────────

test "listWorkspaceItemTasksWithCursor with empty q returns all tasks" {
    const alloc = testing.allocator;
    var ctx = try setupDb();
    defer ctx.db.deinit();
    defer ctx.threaded.deinit();

    try insertTask(&ctx, alloc, "task_1", "alpha", "", "[]");
    try insertTask(&ctx, alloc, "task_2", "beta", "", "[]");
    try insertTask(&ctx, alloc, "task_3", "gamma", "", "[]");

    const result = try listWorkspaceItemTasksWithCursor(
        alloc,
        &ctx.db,
        "wi_1",
        100,
        null,
        .updated_at,
        .desc,
        null,
        "",
    );
    defer freeTasks(alloc, result.tasks);

    try testing.expectEqual(@as(usize, 3), result.tasks.len);
}

// ─── Contract 6: null q is equivalent to no filter ───────────────────────

test "listWorkspaceItemTasksWithCursor with null q returns all tasks" {
    const alloc = testing.allocator;
    var ctx = try setupDb();
    defer ctx.db.deinit();
    defer ctx.threaded.deinit();

    try insertTask(&ctx, alloc, "task_1", "alpha", "", "[]");
    try insertTask(&ctx, alloc, "task_2", "beta", "", "[]");

    const result = try listWorkspaceItemTasksWithCursor(
        alloc,
        &ctx.db,
        "wi_1",
        100,
        null,
        .updated_at,
        .desc,
        null,
        null,
    );
    defer freeTasks(alloc, result.tasks);

    try testing.expectEqual(@as(usize, 2), result.tasks.len);
}

// ─── Contract 7: user-supplied % is escaped (matches nothing, not all) ──

test "listWorkspaceItemTasksWithCursor escapes % so literal % matches nothing" {
    const alloc = testing.allocator;
    var ctx = try setupDb();
    defer ctx.db.deinit();
    defer ctx.threaded.deinit();

    try insertTask(&ctx, alloc, "task_1", "alpha", "", "[]");
    try insertTask(&ctx, alloc, "task_2", "beta", "", "[]");

    const result = try listWorkspaceItemTasksWithCursor(
        alloc,
        &ctx.db,
        "wi_1",
        100,
        null,
        .updated_at,
        .desc,
        null,
        "%",
    );
    defer freeTasks(alloc, result.tasks);

    try testing.expectEqual(@as(usize, 0), result.tasks.len);
}

// ─── Contract 8: user-supplied _ is escaped (matches nothing, not all) ───

test "listWorkspaceItemTasksWithCursor escapes _ so literal _ matches nothing" {
    const alloc = testing.allocator;
    var ctx = try setupDb();
    defer ctx.db.deinit();
    defer ctx.threaded.deinit();

    try insertTask(&ctx, alloc, "task_1", "alpha", "", "[]");
    try insertTask(&ctx, alloc, "task_2", "beta", "", "[]");

    const result = try listWorkspaceItemTasksWithCursor(
        alloc,
        &ctx.db,
        "wi_1",
        100,
        null,
        .updated_at,
        .desc,
        null,
        "_",
    );
    defer freeTasks(alloc, result.tasks);

    try testing.expectEqual(@as(usize, 0), result.tasks.len);
}

// ─── Contract 9: SQL injection attempt is a no-op ───────────────────────

test "listWorkspaceItemTasksWithCursor SQL-injection attempt returns no rows (parameterized)" {
    const alloc = testing.allocator;
    var ctx = try setupDb();
    defer ctx.db.deinit();
    defer ctx.threaded.deinit();

    try insertTask(&ctx, alloc, "task_1", "alpha", "", "[]");
    try insertTask(&ctx, alloc, "task_2", "beta", "", "[]");

    const result = try listWorkspaceItemTasksWithCursor(
        alloc,
        &ctx.db,
        "wi_1",
        100,
        null,
        .updated_at,
        .desc,
        null,
        "' OR '1'='1",
    );
    defer freeTasks(alloc, result.tasks);

    try testing.expectEqual(@as(usize, 0), result.tasks.len);
}

// ─── Contract 10: q + cursor pagination advances through matches only ────

test "listWorkspaceItemTasksWithCursor q + cursor advances through matches only" {
    const alloc = testing.allocator;
    var ctx = try setupDb();
    defer ctx.db.deinit();
    defer ctx.threaded.deinit();

    try insertTask(&ctx, alloc, "task_m1", "match one", "", "[]");
    try insertTask(&ctx, alloc, "task_m2", "match two", "", "[]");
    try insertTask(&ctx, alloc, "task_m3", "match three", "", "[]");
    try insertTask(&ctx, alloc, "task_m4", "match four", "", "[]");
    try insertTask(&ctx, alloc, "task_m5", "match five", "", "[]");
    try insertTask(&ctx, alloc, "task_x1", "other one", "", "[]");
    try insertTask(&ctx, alloc, "task_x2", "other two", "", "[]");
    try insertTask(&ctx, alloc, "task_x3", "other three", "", "[]");
    try insertTask(&ctx, alloc, "task_x4", "other four", "", "[]");
    try insertTask(&ctx, alloc, "task_x5", "other five", "", "[]");

    const page1 = try listWorkspaceItemTasksWithCursor(
        alloc,
        &ctx.db,
        "wi_1",
        2,
        null,
        .updated_at,
        .desc,
        null,
        "match",
    );
    defer freeTasks(alloc, page1.tasks);

    try testing.expectEqual(@as(usize, 2), page1.tasks.len);
    try testing.expect(page1.has_more);
    try testing.expectEqualStrings("task_m5", page1.tasks[0].id);
    try testing.expectEqualStrings("task_m4", page1.tasks[1].id);

    // Cursor = "<updated_at>|<id>". production handler encodes this; the
    // DB fn just splits on the pipe. Use the first page's last row's
    // updated_at + id to construct the next cursor.
    const cursor_value = page1.tasks[1].updated_at orelse return error.UpdatedAtMissing;
    var cursor_buf: [256]u8 = undefined;
    const cursor_str = try std.fmt.bufPrint(
        &cursor_buf,
        "{s}|{s}",
        .{ cursor_value, page1.tasks[1].id },
    );
    const page2 = try listWorkspaceItemTasksWithCursor(
        alloc,
        &ctx.db,
        "wi_1",
        2,
        cursor_str,
        .updated_at,
        .desc,
        null,
        "match",
    );
    defer freeTasks(alloc, page2.tasks);

    try testing.expectEqual(@as(usize, 2), page2.tasks.len);
    try testing.expect(page2.has_more);
    try testing.expectEqualStrings("task_m3", page2.tasks[0].id);
    try testing.expectEqualStrings("task_m2", page2.tasks[1].id);

    const cursor_value2 = page2.tasks[1].updated_at orelse return error.UpdatedAtMissing;
    var cursor_buf2: [256]u8 = undefined;
    const cursor_str2 = try std.fmt.bufPrint(
        &cursor_buf2,
        "{s}|{s}",
        .{ cursor_value2, page2.tasks[1].id },
    );
    const page3 = try listWorkspaceItemTasksWithCursor(
        alloc,
        &ctx.db,
        "wi_1",
        2,
        cursor_str2,
        .updated_at,
        .desc,
        null,
        "match",
    );
    defer freeTasks(alloc, page3.tasks);

    try testing.expectEqual(@as(usize, 1), page3.tasks.len);
    try testing.expect(!page3.has_more);
    try testing.expectEqualStrings("task_m1", page3.tasks[0].id);
}

// ─── Contract 11: nonexistent q returns empty + has_more=false ───────────

test "listWorkspaceItemTasksWithCursor with nonexistent q returns empty + has_more=false" {
    const alloc = testing.allocator;
    var ctx = try setupDb();
    defer ctx.db.deinit();
    defer ctx.threaded.deinit();

    try insertTask(&ctx, alloc, "task_1", "alpha", "", "[]");
    try insertTask(&ctx, alloc, "task_2", "beta", "", "[]");

    const result = try listWorkspaceItemTasksWithCursor(
        alloc,
        &ctx.db,
        "wi_1",
        100,
        null,
        .updated_at,
        .desc,
        null,
        "nonexistent_token_xyz_12345",
    );
    defer freeTasks(alloc, result.tasks);

    try testing.expectEqual(@as(usize, 0), result.tasks.len);
    try testing.expect(!result.has_more);
}

// ─── Contract 12: sort by name returns A→Z (asc) and Z→A (desc) ─────────
// Locks in the kanban-sort-by plan (2026-08-06).

test "listWorkspaceItemTasksWithCursor sorts by name asc and desc" {
    const alloc = testing.allocator;
    var ctx = try setupDb();
    defer ctx.db.deinit();
    defer ctx.threaded.deinit();

    // Insert in non-alphabetical order so a correct sort proves
    // itself (insertion-order is not the natural return order).
    try insertTask(&ctx, alloc, "task_z", "Zeta", "", "[]");
    try insertTask(&ctx, alloc, "task_a", "Alpha", "", "[]");
    try insertTask(&ctx, alloc, "task_m", "Mike", "", "[]");

    const asc = try listWorkspaceItemTasksWithCursor(
        alloc,
        &ctx.db,
        "wi_1",
        100,
        null,
        .name,
        .asc,
        null,
        null,
    );
    defer freeTasks(alloc, asc.tasks);
    try testing.expectEqual(@as(usize, 3), asc.tasks.len);
    try testing.expectEqualStrings("Alpha", asc.tasks[0].name);
    try testing.expectEqualStrings("Mike", asc.tasks[1].name);
    try testing.expectEqualStrings("Zeta", asc.tasks[2].name);

    const desc = try listWorkspaceItemTasksWithCursor(
        alloc,
        &ctx.db,
        "wi_1",
        100,
        null,
        .name,
        .desc,
        null,
        null,
    );
    defer freeTasks(alloc, desc.tasks);
    try testing.expectEqual(@as(usize, 3), desc.tasks.len);
    try testing.expectEqualStrings("Zeta", desc.tasks[0].name);
    try testing.expectEqualStrings("Mike", desc.tasks[1].name);
    try testing.expectEqualStrings("Alpha", desc.tasks[2].name);
}

// ─── Contract 13: sort by created_at returns oldest/newest first ────────
// Locks in the kanban-sort-by plan (2026-08-06).

test "listWorkspaceItemTasksWithCursor sorts by created_at asc and desc" {
    const alloc = testing.allocator;
    var ctx = try setupDb();
    defer ctx.db.deinit();
    defer ctx.threaded.deinit();

    // Insert with the same updated_at so updated_at is not a
    // tiebreaker; the test exercises the created_at ORDER BY alone.
    try insertTask(&ctx, alloc, "task_old", "oldest", "", "[]");
    try insertTask(&ctx, alloc, "task_mid", "middle", "", "[]");
    try insertTask(&ctx, alloc, "task_new", "newest", "", "[]");

    // Set explicit created_at values (oldest < middle < newest) so the
    // sort is deterministic regardless of insertion order.
    try ctx.db.exec(alloc, "UPDATE workspace_item_tasks SET created_at = '2024-01-01 00:00:00' WHERE id = 'task_old'", &.{});
    try ctx.db.exec(alloc, "UPDATE workspace_item_tasks SET created_at = '2024-06-15 12:00:00' WHERE id = 'task_mid'", &.{});
    try ctx.db.exec(alloc, "UPDATE workspace_item_tasks SET created_at = '2024-12-31 23:59:59' WHERE id = 'task_new'", &.{});

    const asc = try listWorkspaceItemTasksWithCursor(
        alloc,
        &ctx.db,
        "wi_1",
        100,
        null,
        .created_at,
        .asc,
        null,
        null,
    );
    defer freeTasks(alloc, asc.tasks);
    try testing.expectEqual(@as(usize, 3), asc.tasks.len);
    try testing.expectEqualStrings("task_old", asc.tasks[0].id);
    try testing.expectEqualStrings("task_mid", asc.tasks[1].id);
    try testing.expectEqualStrings("task_new", asc.tasks[2].id);

    const desc = try listWorkspaceItemTasksWithCursor(
        alloc,
        &ctx.db,
        "wi_1",
        100,
        null,
        .created_at,
        .desc,
        null,
        null,
    );
    defer freeTasks(alloc, desc.tasks);
    try testing.expectEqual(@as(usize, 3), desc.tasks.len);
    try testing.expectEqualStrings("task_new", desc.tasks[0].id);
    try testing.expectEqualStrings("task_mid", desc.tasks[1].id);
    try testing.expectEqualStrings("task_old", desc.tasks[2].id);
}
// ════════════════════════════════════════════════════════════════════════════
// Inline behavioural tests for the kanban per-column pagination filter.

test "listWorkspaceItemTasksWithCursor column_id=col_a returns only col_a tasks" {
    const alloc = testing.allocator;
    var ctx = try setupDb();
    defer ctx.db.deinit();
    defer ctx.threaded.deinit();

    try insertTaskInColumn(&ctx, alloc, "task_a1", "alpha", "", "[]", "col_a", 0);
    try insertTaskInColumn(&ctx, alloc, "task_a2", "beta", "", "[]", "col_a", 1);
    try insertTaskInColumn(&ctx, alloc, "task_b1", "gamma", "", "[]", "col_b", 0);

    const result = try listWorkspaceItemTasksWithCursor(
        alloc,
        &ctx.db,
        "wi_1",
        100,
        null,
        .updated_at,
        .desc,
        "col_a",
        null,
    );
    defer freeTasks(alloc, result.tasks);

    try testing.expectEqual(@as(usize, 2), result.tasks.len);
    // ORDER BY is_pinned DESC, ..., updated_at DESC, id DESC. The tiebreaker
    // is `id DESC`, so the alphabetically-greater id comes first: task_a2
    // then task_a1. task_b1 is filtered out by the column_id WHERE clause.
    try testing.expectEqualStrings("task_a2", result.tasks[0].id);
    try testing.expectEqualStrings("task_a1", result.tasks[1].id);
    try testing.expect(!result.has_more);
}

test "listWorkspaceItemTasksWithCursor column_id=col_b returns only col_b tasks" {
    const alloc = testing.allocator;
    var ctx = try setupDb();
    defer ctx.db.deinit();
    defer ctx.threaded.deinit();

    try insertTaskInColumn(&ctx, alloc, "task_a1", "alpha", "", "[]", "col_a", 0);
    try insertTaskInColumn(&ctx, alloc, "task_a2", "beta", "", "[]", "col_a", 1);
    try insertTaskInColumn(&ctx, alloc, "task_b1", "gamma", "", "[]", "col_b", 0);
    try insertTaskInColumn(&ctx, alloc, "task_b2", "delta", "", "[]", "col_b", 1);

    const result = try listWorkspaceItemTasksWithCursor(
        alloc,
        &ctx.db,
        "wi_1",
        100,
        null,
        .updated_at,
        .desc,
        "col_b",
        null,
    );
    defer freeTasks(alloc, result.tasks);

    try testing.expectEqual(@as(usize, 2), result.tasks.len);
    // id DESC tiebreak → task_b2 first.
    try testing.expectEqualStrings("task_b2", result.tasks[0].id);
    try testing.expectEqualStrings("task_b1", result.tasks[1].id);
}

test "listWorkspaceItemTasksWithCursor column_id=col_a + cursor advances through col_a only" {
    const alloc = testing.allocator;
    var ctx = try setupDb();
    defer ctx.db.deinit();
    defer ctx.threaded.deinit();

    // 3 tasks in col_a, 2 in col_b. Page size 2 forces a cursor.
    try insertTaskInColumn(&ctx, alloc, "task_a1", "a1", "", "[]", "col_a", 0);
    try insertTaskInColumn(&ctx, alloc, "task_a2", "a2", "", "[]", "col_a", 1);
    try insertTaskInColumn(&ctx, alloc, "task_a3", "a3", "", "[]", "col_a", 2);
    try insertTaskInColumn(&ctx, alloc, "task_b1", "b1", "", "[]", "col_b", 0);
    try insertTaskInColumn(&ctx, alloc, "task_b2", "b2", "", "[]", "col_b", 1);

    // Page 1: limit 2 + col_a filter — should return task_a3 + task_a2
    // (id DESC tiebreak, both within the same updated_at bucket since
    // they're inserted in quick succession). task_a1 falls into page 2.
    const page1 = try listWorkspaceItemTasksWithCursor(
        alloc,
        &ctx.db,
        "wi_1",
        2,
        null,
        .updated_at,
        .desc,
        "col_a",
        null,
    );
    defer freeTasks(alloc, page1.tasks);
    try testing.expectEqual(@as(usize, 2), page1.tasks.len);
    try testing.expectEqualStrings("task_a3", page1.tasks[0].id);
    try testing.expectEqualStrings("task_a2", page1.tasks[1].id);
    try testing.expect(page1.has_more);

    // Construct the cursor from page1's last task id. The handler encodes the
    // cursor as "<sort_value>|<id>" — for updated_at DESC the sort_value is
    // the last task's updated_at.
    const cursor_str = try std.fmt.allocPrint(
        alloc,
        "{s}|{s}",
        .{ page1.tasks[1].updated_at.?, page1.tasks[1].id },
    );
    defer alloc.free(cursor_str);

    // Page 2: pass cursor + col_a filter — should return task_a1 only.
    const page2 = try listWorkspaceItemTasksWithCursor(
        alloc,
        &ctx.db,
        "wi_1",
        2,
        cursor_str,
        .updated_at,
        .desc,
        "col_a",
        null,
    );
    defer freeTasks(alloc, page2.tasks);
    try testing.expectEqual(@as(usize, 1), page2.tasks.len);
    try testing.expectEqualStrings("task_a1", page2.tasks[0].id);
    try testing.expect(!page2.has_more);
}

test "listWorkspaceItemTasksWithCursor column_id=col_a + q filters within the column" {
    const alloc = testing.allocator;
    var ctx = try setupDb();
    defer ctx.db.deinit();
    defer ctx.threaded.deinit();

    // col_a has 2 tasks (one matching 'login'); col_b has 2 tasks (one
    // matching 'login'). Filter by col_a + q=login → 1 task.
    try insertTaskInColumn(&ctx, alloc, "task_a1", "fix login bug", "", "[]", "col_a", 0);
    try insertTaskInColumn(&ctx, alloc, "task_a2", "unrelated", "", "[]", "col_a", 1);
    try insertTaskInColumn(&ctx, alloc, "task_b1", "login screen", "", "[]", "col_b", 0);
    try insertTaskInColumn(&ctx, alloc, "task_b2", "settings", "", "[]", "col_b", 1);

    const result = try listWorkspaceItemTasksWithCursor(
        alloc,
        &ctx.db,
        "wi_1",
        100,
        null,
        .updated_at,
        .desc,
        "col_a",
        "login",
    );
    defer freeTasks(alloc, result.tasks);

    try testing.expectEqual(@as(usize, 1), result.tasks.len);
    try testing.expectEqualStrings("task_a1", result.tasks[0].id);
}

test "listWorkspaceItemTasksWithCursor column_id='' (empty) returns all columns" {
    const alloc = testing.allocator;
    var ctx = try setupDb();
    defer ctx.db.deinit();
    defer ctx.threaded.deinit();

    try insertTaskInColumn(&ctx, alloc, "task_a1", "alpha", "", "[]", "col_a", 0);
    try insertTaskInColumn(&ctx, alloc, "task_b1", "beta", "", "[]", "col_b", 0);

    const result = try listWorkspaceItemTasksWithCursor(
        alloc,
        &ctx.db,
        "wi_1",
        100,
        null,
        .updated_at,
        .desc,
        "",
        null,
    );
    defer freeTasks(alloc, result.tasks);

    // Empty column_id is treated like null → returns all columns.
    try testing.expectEqual(@as(usize, 2), result.tasks.len);
}

test "listWorkspaceItemTasksWithCursor column_id=nonexistent returns 0 + has_more=false" {
    const alloc = testing.allocator;
    var ctx = try setupDb();
    defer ctx.db.deinit();
    defer ctx.threaded.deinit();

    try insertTaskInColumn(&ctx, alloc, "task_a1", "alpha", "", "[]", "col_a", 0);
    try insertTaskInColumn(&ctx, alloc, "task_b1", "beta", "", "[]", "col_b", 0);

    const result = try listWorkspaceItemTasksWithCursor(
        alloc,
        &ctx.db,
        "wi_1",
        100,
        null,
        .updated_at,
        .desc,
        "col_nonexistent",
        null,
    );
    defer freeTasks(alloc, result.tasks);

    try testing.expectEqual(@as(usize, 0), result.tasks.len);
    try testing.expect(!result.has_more);
}

test "listWorkspaceItemTasksWithCursor column_id includes NULL-column legacy tasks" {
    const alloc = testing.allocator;
    var ctx = try setupDb();
    defer ctx.db.deinit();
    defer ctx.threaded.deinit();

    // Insert 1 task in col_a, 1 task in col_b, 1 task with NULL
    // column (legacy). Filter by col_a → expect col_a task + NULL-
    // column task (per the defensive OR clause).
    try insertTaskInColumn(&ctx, alloc, "task_a", "in_a", "", "[]", "col_a", 0);
    try insertTaskInColumn(&ctx, alloc, "task_b", "in_b", "", "[]", "col_b", 0);
    try insertTaskInColumn(&ctx, alloc, "task_null", "null_col", "", "[]", null, 0);

    const result = try listWorkspaceItemTasksWithCursor(
        alloc,
        &ctx.db,
        "wi_1",
        100,
        null,
        .updated_at,
        .desc,
        "col_a",
        null,
    );
    defer freeTasks(alloc, result.tasks);

    // The OR clause matches both col_a AND NULL-column rows.
    try testing.expectEqual(@as(usize, 2), result.tasks.len);
    // Build a set of returned ids and verify task_b is NOT in it.
    const returned_ids: [2][]const u8 = .{ result.tasks[0].id, result.tasks[1].id };
    var found_task_b = false;
    for (returned_ids) |id| {
        if (std.mem.eql(u8, id, "task_b")) found_task_b = true;
    }
    try testing.expect(!found_task_b);
}

// ════════════════════════════════════════════════════════════════════════════
// getWorkspaceItemTaskById — single-task fetch for the kanban Task details
// dialog (plan:

test "getWorkspaceItemTaskById returns the matching task" {
    const alloc = testing.allocator;
    var ctx = try setupDb();
    defer ctx.db.deinit();
    defer ctx.threaded.deinit();

    try insertTask(&ctx, alloc, "task_1", "alpha", "first task", "[\"bug\"]");
    try insertTask(&ctx, alloc, "task_2", "beta", "second task", "[]");
    try insertTask(&ctx, alloc, "task_3", "gamma", "third task", "[]");

    const opt = try getWorkspaceItemTaskById(alloc, &ctx.db, "wi_1", "task_2");
    try testing.expect(opt != null);
    var task = opt.?;
    defer task.deinit(alloc);

    try testing.expectEqualStrings("task_2", task.id);
    try testing.expectEqualStrings("beta", task.name);
    try testing.expectEqualStrings("second task", task.description);
    try testing.expectEqualStrings("wi_1", task.workspace_item_id);
    try testing.expectEqualStrings("standard", task.task_type);
    try testing.expectEqualStrings("[]", task.tags);
}

test "getWorkspaceItemTaskById returns null for unknown task id" {
    const alloc = testing.allocator;
    var ctx = try setupDb();
    defer ctx.db.deinit();
    defer ctx.threaded.deinit();

    try insertTask(&ctx, alloc, "task_1", "alpha", "", "[]");

    const opt = try getWorkspaceItemTaskById(alloc, &ctx.db, "wi_1", "no_such_task");
    try testing.expect(opt == null);
}

test "getWorkspaceItemTaskById is scoped to the parent workspace item" {
    const alloc = testing.allocator;
    var ctx = try setupDb();
    defer ctx.db.deinit();
    defer ctx.threaded.deinit();

    // task_other lives under a DIFFERENT item (wi_2). Fetching it
    // through wi_1 must return null — the item scoping prevents
    // cross-item task reads.
    try ctx.db.exec(alloc, "INSERT INTO workspace_items (id, workspace_id, item_type) VALUES ('wi_2', 'ws_1', 'kanban') ON CONFLICT DO NOTHING", &.{});
    try ctx.db.exec(alloc, "INSERT INTO workspace_item_tasks (id, name, workspace_item_id, description, updated_at, task_type, tags) VALUES ('task_other', 'elsewhere', 'wi_2', '', datetime('now'), 'standard', '[]')", &.{});

    const opt = try getWorkspaceItemTaskById(alloc, &ctx.db, "wi_1", "task_other");
    try testing.expect(opt == null);

    // Sanity: fetching through the CORRECT item finds it.
    const opt2 = try getWorkspaceItemTaskById(alloc, &ctx.db, "wi_2", "task_other");
    try testing.expect(opt2 != null);
    var task = opt2.?;
    defer task.deinit(alloc);
    try testing.expectEqualStrings("elsewhere", task.name);
}

test "getWorkspaceItemTaskById joins sessions for unattended flag + worktree cwd" {
    const alloc = testing.allocator;
    var ctx = try setupDb();
    defer ctx.db.deinit();
    defer ctx.threaded.deinit();

    try insertTask(&ctx, alloc, "task_s", "with session", "", "[]");
    // Session row sharing the task id (project convention task.id ==
    // session.id): unattended ON, AI finished, worktree bound.
    try ctx.db.exec(alloc, "INSERT INTO sessions (id, is_auto_retry_until_stop, last_finish_reason, updated_at, git_worktree_cwd) " ++
        "VALUES ('task_s', '1', 'stop', datetime('now'), '/tmp/worktree-x')", &.{});

    const opt = try getWorkspaceItemTaskById(alloc, &ctx.db, "wi_1", "task_s");
    try testing.expect(opt != null);
    var task = opt.?;
    defer task.deinit(alloc);

    try testing.expectEqualStrings("1", task.is_auto_retry_until_stop);
    try testing.expectEqualStrings("stop", task.last_finish_reason);
    try testing.expectEqualStrings("/tmp/worktree-x", task.git_worktree_cwd);
    // AI finished ('stop') and no human touch → awaiting review.
    try testing.expect(task.needs_human_review);
}

test "getWorkspaceItemTaskById returns media flags and cwd passthrough" {
    const alloc = testing.allocator;
    var ctx = try setupDb();
    defer ctx.db.deinit();
    defer ctx.threaded.deinit();

    try insertTask(&ctx, alloc, "task_img", "with images", "", "[]");
    try ctx.db.exec(alloc, "UPDATE workspace_item_tasks SET image_urls = 'data:image/png;base64,AAA||data:image/png;base64,BBB', cwd = '/tmp/proj' " ++
        "WHERE id = 'task_img'", &.{});

    const opt = try getWorkspaceItemTaskById(alloc, &ctx.db, "wi_1", "task_img");
    try testing.expect(opt != null);
    var task = opt.?;
    defer task.deinit(alloc);

    try testing.expect(task.is_have_image);
    try testing.expect(!task.is_have_video);
    try testing.expectEqualStrings("/tmp/proj", task.cwd);
    const media = (try getWorkspaceItemTaskMedia(alloc, &ctx.db, "wi_1", "task_img")).?;
    defer media.deinit(alloc);
    try testing.expectEqualStrings("data:image/png;base64,AAA||data:image/png;base64,BBB", media.image_urls);
}

// ════════════════════════════════════════════════════════════════════════════
// Inlined from session_update_test.zig
// ════════════════════════════════════════════════════════════════════════════

fn sessionUpdateSetupDb() !TestCtx {
    const alloc = testing.allocator;
    var threaded = std.Io.Threaded.init(alloc, .{});
    errdefer threaded.deinit();
    const io = threaded.io();
    var db: database.Db = .{};
    errdefer db.deinit();
    try test_db.openMemory(&db, io);

    // Canonical post-Migration-063 schema (matches
    // migration_063_runtime_test.zig).
    try db.exec(alloc,
        \\CREATE TABLE sessions (
        \\    id TEXT PRIMARY KEY,
        \\    name TEXT NOT NULL,
        \\    status TEXT NOT NULL DEFAULT 'active',
        \\    cwd TEXT,
        \\    created_at TIMESTAMP,
        \\    updated_at TIMESTAMP,
        \\    selected_profile_model TEXT,
        \\    git_worktree_cwd TEXT,
        \\    is_auto_retry_until_stop INTEGER NOT NULL DEFAULT 0,
        \\    last_finish_reason TEXT,
        \\    pr_url TEXT,
        \\    pr_provider TEXT,
        \\    sub_agent_name TEXT,
        \\    parent_session_id TEXT
        \\)
    , &.{});
    return .{ .db = db, .threaded = threaded, .alloc = alloc };
}

/// Read a single TEXT column from `sessions` by id. Returns null when
/// the row is missing. Used to assert the post-fix state.
fn sessionUpdateReadColumn(
    ctx: *TestCtx,
    allocator: std.mem.Allocator,
    column: []const u8,
    row_id: []const u8,
) !?[]u8 {
    const sql = try std.fmt.allocPrint(allocator, "SELECT {s} FROM sessions WHERE id = ?", .{column});
    defer allocator.free(sql);
    var q = try ctx.db.query(allocator, sql, &.{row_id});
    defer q.deinit();
    const row_opt = try q.next();
    if (row_opt) |row| {
        defer row.deinit(allocator);
        return try allocator.dupe(u8, row.values[0]);
    }
    return null;
}

test "ensureSessionExists: returns false when row already exists" {
    const alloc = testing.allocator;
    var ctx = try sessionUpdateSetupDb();
    defer ctx.db.deinit();
    defer ctx.threaded.deinit();

    // Pre-create a session row.
    {
        const session = try create_session(alloc, &ctx.db, "s_existing", "Existing", "0");
        session.deinit(alloc);
    }

    const created = try ensureSessionExists(alloc, &ctx.db, "s_existing");
    try testing.expectEqual(false, created);

    // Name was NOT overwritten by the default.
    const name = (try sessionUpdateReadColumn(&ctx, alloc, "name", "s_existing")) orelse
        return error.NoRow;
    defer alloc.free(name);
    try testing.expectEqualStrings("Existing", name);
}

test "ensureSessionExists: creates a row when missing, returns true" {
    const alloc = testing.allocator;
    var ctx = try sessionUpdateSetupDb();
    defer ctx.db.deinit();
    defer ctx.threaded.deinit();

    // Sanity: no row exists yet.
    const before = (try sessionUpdateReadColumn(&ctx, alloc, "name", "s_brand_new")) orelse
        @as(?[]u8, null);
    if (before) |b| {
        defer alloc.free(b);
        return error.ExpectedNoRow;
    }

    const created = try ensureSessionExists(alloc, &ctx.db, "s_brand_new");
    try testing.expectEqual(true, created);

    // Row is now present with the default name.
    const name = (try sessionUpdateReadColumn(&ctx, alloc, "name", "s_brand_new")) orelse
        return error.NoRow;
    defer alloc.free(name);
    try testing.expectEqualStrings("New Session", name);

    // is_auto_retry_until_stop defaults to '0' (matches
    // create_session's coercion).
    const flag = (try sessionUpdateReadColumn(&ctx, alloc, "is_auto_retry_until_stop", "s_brand_new")) orelse
        return error.NoRow;
    defer alloc.free(flag);
    try testing.expectEqualStrings("0", flag);
}

test "ensureSessionExists: idempoent — calling twice on a missing row creates exactly once" {
    const alloc = testing.allocator;
    var ctx = try sessionUpdateSetupDb();
    defer ctx.db.deinit();
    defer ctx.threaded.deinit();

    _ = try ensureSessionExists(alloc, &ctx.db, "s_idemp");
    const second = try ensureSessionExists(alloc, &ctx.db, "s_idemp");
    try testing.expectEqual(false, second);

    // There is exactly one row.
    var q = try ctx.db.query(alloc, "SELECT id FROM sessions WHERE id = ?", &.{"s_idemp"});
    defer q.deinit();
    var row_count: usize = 0;
    while (try q.next()) |row| {
        row.deinit(alloc);
        row_count += 1;
    }
    try testing.expectEqual(@as(usize, 1), row_count);
}

test "ensureSessionExists + updateSessionSelectedProfileModel: preserves the profile when session is created on the fly" {
    // This is the exact bug: PUT /api/session/:id 404'd when the user picked
    // a profile on a brand-new chat.
    const alloc = testing.allocator;
    var ctx = try sessionUpdateSetupDb();
    defer ctx.db.deinit();
    defer ctx.threaded.deinit();

    // Brand-new session that doesn't exist yet.
    _ = try ensureSessionExists(alloc, &ctx.db, "s_fresh");
    try updateSessionSelectedProfileModel(alloc, &ctx.db, "s_fresh", "900ribu");

    const profile = (try sessionUpdateReadColumn(&ctx, alloc, "selected_profile_model", "s_fresh")) orelse
        return error.NoRow;
    defer alloc.free(profile);
    try testing.expectEqualStrings("900ribu", profile);
}

test "updateSessionSubAgentInfo: stamps sub-agent name and parent" {
    const alloc = testing.allocator;
    var ctx = try sessionUpdateSetupDb();
    defer ctx.db.deinit();
    defer ctx.threaded.deinit();

    _ = try ensureSessionExists(alloc, &ctx.db, "subagent_1_implementator");
    try updateSessionSelectedProfileModel(alloc, &ctx.db, "subagent_1_implementator", "muse spark auto");
    try updateSessionSubAgentInfo(alloc, &ctx.db, "subagent_1_implementator", "implementator", "parent_1");

    const sub = (try sessionUpdateReadColumn(&ctx, alloc, "sub_agent_name", "subagent_1_implementator")) orelse
        return error.NoRow;
    defer alloc.free(sub);
    try testing.expectEqualStrings("implementator", sub);

    const par = (try sessionUpdateReadColumn(&ctx, alloc, "parent_session_id", "subagent_1_implementator")) orelse
        return error.NoRow;
    defer alloc.free(par);
    try testing.expectEqualStrings("parent_1", par);

    // Parent profile is preserved alongside the sub-agent identity.
    const sess = (try getSession(alloc, &ctx.db, "subagent_1_implementator")) orelse return error.NoRow;
    defer sess.deinit(alloc);
    try testing.expectEqualStrings("muse spark auto", sess.selected_profile_model);
    try testing.expectEqualStrings("implementator", sess.sub_agent_name);
    try testing.expectEqualStrings("parent_1", sess.parent_session_id);
}

// ════════════════════════════════════════════════════════════════════════════
// Inlined from get_session_list_test.zig
// ════════════════════════════════════════════════════════════════════════════

// ─── Test helpers ─────────────────────────────────────────────────────────

/// Open a fresh in-memory sqlite DB with `llm_history` and `sessions` tables
/// present (matching the production schema columns that `getSessionList`
/// reads), plus the `idx_llm_history_created_session` index from Migration
fn getSessionListSetupDb() !struct {
    db: database.Db,
    threaded: std.Io.Threaded,
} {
    const alloc = testing.allocator;
    var threaded = std.Io.Threaded.init(alloc, .{});
    errdefer threaded.deinit();
    const io = threaded.io();

    var db: database.Db = .{};
    errdefer db.deinit();
    try test_db.openMemory(&db, io);

    // llm_history — only the columns the rewritten query reads.
    try db.exec(alloc,
        \\CREATE TABLE llm_history (
        \\    id TEXT PRIMARY KEY,
        \\    session_id TEXT NOT NULL,
        \\    model TEXT NOT NULL,
        \\    response_content TEXT,
        \\    tool_calls_json TEXT,
        \\    tool_results_json TEXT,
        \\    finish_reason TEXT,
        \\    usage_json TEXT,
        \\    created_at_nano TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
        \\    agent TEXT DEFAULT 'Agent'
        \\)
    , &.{});

    // sessions — only the columns the rewritten query reads (id, cwd,
    // name). SELECT coalesces NULLs to '' so empty strings are fine.
    try db.exec(alloc,
        \\CREATE TABLE sessions (
        \\    id TEXT PRIMARY KEY,
        \\    cwd TEXT,
        \\    name TEXT
        \\)
    , &.{});

    // The covering index added in Migration 048. We create it inline
    // (rather than running the migration) to keep this test focused on
    // the rewritten SQL, not on migration plumbing.
    try db.exec(alloc, "CREATE INDEX idx_llm_history_created_session " ++
        "ON llm_history(created_at_nano DESC, session_id)", &.{});

    return .{ .db = db, .threaded = threaded };
}

/// Run a query and assert it returns exactly `expected_len` rows.
/// Returns the rows' `values` slices so the caller can assert on
/// individual columns.
fn runAndCollect(
    alloc: std.mem.Allocator,
    db: *database.Db,
    sql: []const u8,
    args: []const []const u8,
    expected_len: usize,
) ![][]const u8 {
    var q = try db.query(alloc, sql, args);
    defer q.deinit();

    var collected = std.ArrayList([]const u8).empty;
    defer collected.deinit(alloc);

    while (try q.next()) |row| {
        defer row.deinit(alloc);
        // For these tests each row is a single column (session_id or agent).
        try collected.append(alloc, try alloc.dupe(u8, row.values[0]));
    }

    if (collected.items.len != expected_len) {
        std.debug.print(
            "!! expected {d} rows, got {d}\n",
            .{ expected_len, collected.items.len },
        );
        return error.RowCountMismatch;
    }
    return collected.toOwnedSlice(alloc);
}

// ─── Test 1: inner subquery order is created_at DESC ─────────────────────

test "getSessionList inner subquery returns sessions in created_at DESC order" {
    const alloc = testing.allocator;
    var ctx = try getSessionListSetupDb();
    defer ctx.db.deinit();
    defer ctx.threaded.deinit();

    // Three sessions, distinct created_at values. Newest first by
    // insert order means s_jan < s_feb < s_mar.
    try ctx.db.exec(alloc, "INSERT INTO llm_history (id, session_id, model, created_at_nano) " ++
        "VALUES ('h1', 's_jan', 'm1', '2024-01-01 00:00:00')", &.{});
    try ctx.db.exec(alloc, "INSERT INTO llm_history (id, session_id, model, created_at_nano) " ++
        "VALUES ('h2', 's_feb', 'm1', '2024-02-01 00:00:00')", &.{});
    try ctx.db.exec(alloc, "INSERT INTO llm_history (id, session_id, model, created_at_nano) " ++
        "VALUES ('h3', 's_mar', 'm1', '2024-03-01 00:00:00')", &.{});

    // Exact inner subquery the production rewrite uses (see
    // zig getSessionList). Asserts the order is the
    // contract the outer query depends on.
    const inner_sql =
        \\SELECT h.session_id
        \\  FROM llm_history h
        \\ GROUP BY h.session_id
        \\ ORDER BY MAX(h.created_at_nano) DESC
        \\ LIMIT 10 OFFSET 0
    ;

    const rows = try runAndCollect(alloc, &ctx.db, inner_sql, &.{}, 3);
    defer {
        for (rows) |r| alloc.free(r);
        alloc.free(rows);
    }

    try testing.expectEqualStrings("s_mar", rows[0]);
    try testing.expectEqualStrings("s_feb", rows[1]);
    try testing.expectEqualStrings("s_jan", rows[2]);
}

// ─── Test 2: inner subquery LIMIT and OFFSET are respected ───────────────

test "getSessionList inner subquery respects LIMIT and OFFSET" {
    const alloc = testing.allocator;
    var ctx = try getSessionListSetupDb();
    defer ctx.db.deinit();
    defer ctx.threaded.deinit();

    // Five sessions, distinct created_at values. The full ordering
    // (newest first) is: s5, s4, s3, s2, s1.
    const inserts = [_][]const u8{
        "INSERT INTO llm_history (id, session_id, model, created_at_nano) VALUES ('h1', 's1', 'm1', '2024-01-01 00:00:00')",
        "INSERT INTO llm_history (id, session_id, model, created_at_nano) VALUES ('h2', 's2', 'm1', '2024-02-01 00:00:00')",
        "INSERT INTO llm_history (id, session_id, model, created_at_nano) VALUES ('h3', 's3', 'm1', '2024-03-01 00:00:00')",
        "INSERT INTO llm_history (id, session_id, model, created_at_nano) VALUES ('h4', 's4', 'm1', '2024-04-01 00:00:00')",
        "INSERT INTO llm_history (id, session_id, model, created_at_nano) VALUES ('h5', 's5', 'm1', '2024-05-01 00:00:00')",
    };
    for (inserts) |sql| {
        try ctx.db.exec(alloc, sql, &.{});
    }

    // Page 1: limit=2, offset=0 → s5, s4
    const inner_sql =
        \\SELECT h.session_id
        \\  FROM llm_history h
        \\ GROUP BY h.session_id
        \\ ORDER BY MAX(h.created_at_nano) DESC
        \\ LIMIT 2 OFFSET 0
    ;
    const page1 = try runAndCollect(alloc, &ctx.db, inner_sql, &.{}, 2);
    defer {
        for (page1) |r| alloc.free(r);
        alloc.free(page1);
    }
    try testing.expectEqualStrings("s5", page1[0]);
    try testing.expectEqualStrings("s4", page1[1]);

    // Page 2: limit=2, offset=2 → s3, s2 (no overlap with page 1)
    const page2_sql =
        \\SELECT h.session_id
        \\  FROM llm_history h
        \\ GROUP BY h.session_id
        \\ ORDER BY MAX(h.created_at_nano) DESC
        \\ LIMIT 2 OFFSET 2
    ;
    const page2 = try runAndCollect(alloc, &ctx.db, page2_sql, &.{}, 2);
    defer {
        for (page2) |r| alloc.free(r);
        alloc.free(page2);
    }
    try testing.expectEqualStrings("s3", page2[0]);
    try testing.expectEqualStrings("s2", page2[1]);

    // Page 1 and Page 2 must not overlap (regression guard: if the
    // OFFSET clause were dropped, page 2 would be s4, s3).
    for (page1) |p1| {
        for (page2) |p2| {
            if (std.mem.eql(u8, p1, p2)) {
                std.debug.print(
                    "!! LIMIT/OFFSET overlap: page1 row '{s}' == page2 row '{s}'\n",
                    .{ p1, p2 },
                );
                return error.OffsetOverlap;
            }
        }
    }
}

// ─── Test 3: agent is the latest message's agent (bug-fix regression) ───

test "getSessionList agent field is from the latest message in the session" {
    const alloc = testing.allocator;
    var ctx = try getSessionListSetupDb();
    defer ctx.db.deinit();
    defer ctx.threaded.deinit();

    // Two messages for the same session. The OLDER one is agent='A', the
    // NEWER one is agent='B'.
    try ctx.db.exec(alloc, "INSERT INTO llm_history (id, session_id, model, agent, created_at_nano) " ++
        "VALUES ('h_old', 's1', 'm1', 'A', '2024-01-01 00:00:00')", &.{});
    try ctx.db.exec(alloc, "INSERT INTO llm_history (id, session_id, model, agent, created_at_nano) " ++
        "VALUES ('h_new', 's1', 'm1', 'B', '2024-02-01 00:00:00')", &.{});

    // Exact correlated subquery the production rewrite uses (see
    // zig getSessionList). Asserts the new "agent of the
    // LATEST message" semantics.
    const agent_sql =
        \\SELECT COALESCE(
        \\  (SELECT h2.agent
        \\     FROM llm_history h2
        \\    WHERE h2.session_id = 's1'
        \\    ORDER BY h2.created_at_nano DESC
        \\    LIMIT 1),
        \\  'Agent'
        \\) AS agent
    ;

    const rows = try runAndCollect(alloc, &ctx.db, agent_sql, &.{}, 1);
    defer {
        for (rows) |r| alloc.free(r);
        alloc.free(rows);
    }

    try testing.expectEqualStrings("B", rows[0]);
}

// ─── Test 4: planner uses idx_llm_history_created_session (EXPLAIN) ──────

test "getSessionList inner subquery uses idx_llm_history_created_session (EXPLAIN QUERY PLAN)" {
    const alloc = testing.allocator;
    var ctx = try getSessionListSetupDb();
    defer ctx.db.deinit();
    defer ctx.threaded.deinit();

    // Seed enough rows that the planner has a reason to use the index
    // (small tables often hit a SCAN regardless because the cost
    // estimate favors it). 100 rows is plenty.
    var i: usize = 0;
    while (i < 100) : (i += 1) {
        var buf: [256]u8 = undefined;
        const sql = try std.fmt.bufPrint(
            &buf,
            "INSERT INTO llm_history (id, session_id, model, created_at_nano) " ++
                "VALUES ('h{d}', 's{d}', 'm1', '2024-01-01 00:00:00')",
            .{ i, i },
        );
        try ctx.db.exec(alloc, sql, &.{});
    }

    // EXPLAIN QUERY PLAN is sqlite's plan text, and the assertion below reads a
    // sqlite index name out of it: postgres cannot answer this question.
    if (dialect.is_postgres) return error.SkipZigTest;

    var q = try ctx.db.query(alloc,
        \\EXPLAIN QUERY PLAN
        \\SELECT h.session_id, MAX(h.created_at_nano)
        \\  FROM llm_history h
        \\ GROUP BY h.session_id
        \\ ORDER BY MAX(h.created_at_nano) DESC
        \\ LIMIT 10 OFFSET 0
    , &.{});
    defer q.deinit();

    // Accumulate all plan rows into a single string so the
    // assertion can scan for the index name regardless of how
    // SQLite splits the plan across rows.
    var plan_text = std.ArrayList(u8).empty;
    defer plan_text.deinit(alloc);
    while (try q.next()) |row| {
        defer row.deinit(alloc);
        for (row.values, 0..) |col, j| {
            if (j > 0) try plan_text.append(alloc, ' ');
            try plan_text.appendSlice(alloc, col);
        }
        try plan_text.append(alloc, '\n');
    }

    const plan_str = plan_text.items;
    if (std.mem.indexOf(u8, plan_str, "idx_llm_history_created_session") == null) {
        std.debug.print(
            "!! getSessionList planner did NOT use idx_llm_history_created_session !!\n" ++
                "   EXPLAIN output:\n{s}\n",
            .{plan_str},
        );
        return error.ChatListIndexNotUsed;
    }
}

// ════════════════════════════════════════════════════════════════════════════
// Inlined from llm_history_is_input_output_test.zig
// ════════════════════════════════════════════════════════════════════════════

fn llmHistoryIsInputOutputMakeResponse(messages: []SessionMessage) SessionMessageResponse {
    return .{
        .messages = messages,
        .has_more = false,
        .next_cursor = null,
        .max_total_tokens = 0,
        .max_capacity_total_tokens = 0,
    };
}

test "buildSessionMessagesJson emits is_input/is_output as JSON booleans" {
    const allocator = testing.allocator;

    // Build a minimal SessionMessageResponse with known bool values:
    // is_input: true, is_output: false.
    const messages = [_]SessionMessage{
        .{
            .id = "m1",
            .session_id = "s1",
            .role = "user",
            .content = "hi",
            .timestamp = "1700000000",
            .is_input = true,
            .is_output = false,
            .tool_name = "",
            .finish_reason = "",
            .reasoning_content = "",
        },
    };
    const response = llmHistoryIsInputOutputMakeResponse(@constCast(&messages));

    const json = try buildSessionMessagesJson(allocator, &response);
    defer allocator.free(json);

    // Must contain boolean form (no quotes around true/false):
    try testing.expect(std.mem.indexOf(u8, json, "\"is_input\":true") != null);
    try testing.expect(std.mem.indexOf(u8, json, "\"is_output\":false") != null);
    // Must NOT contain string form (the old wrong format):
    try testing.expect(std.mem.indexOf(u8, json, "\"is_input\":\"1\"") == null);
    try testing.expect(std.mem.indexOf(u8, json, "\"is_output\":\"0\"") == null);
    // Must NOT contain string form with bare 'true'/'false' wrapped in quotes:
    try testing.expect(std.mem.indexOf(u8, json, "\"is_input\":\"true\"") == null);
    try testing.expect(std.mem.indexOf(u8, json, "\"is_output\":\"false\"") == null);
    // Must NOT contain number form (the alternative refactor that was rejected):
    try testing.expect(std.mem.indexOf(u8, json, "\"is_input\": 1") == null);
    try testing.expect(std.mem.indexOf(u8, json, "\"is_output\": 0") == null);
}

test "buildSessionMessagesXml emits is_input/is_output as text 'true'/'false'" {
    const allocator = testing.allocator;

    const messages = [_]SessionMessage{
        .{
            .id = "m1",
            .session_id = "s1",
            .role = "user",
            .content = "hi",
            .timestamp = "1700000000",
            .is_input = true,
            .is_output = false,
            .tool_name = "",
            .finish_reason = "",
            .reasoning_content = "",
        },
    };
    const response = llmHistoryIsInputOutputMakeResponse(@constCast(&messages));

    const xml = try buildSessionMessagesXml(allocator, &response);
    defer allocator.free(xml);

    // XML text content: <is_input>true</is_input> (bool rendered as text).
    try testing.expect(std.mem.indexOf(u8, xml, "<is_input>true</is_input>") != null);
    try testing.expect(std.mem.indexOf(u8, xml, "<is_output>false</is_output>") != null);
    // Must NOT contain the old "1"/"0" text form:
    try testing.expect(std.mem.indexOf(u8, xml, "<is_input>1</is_input>") == null);
    try testing.expect(std.mem.indexOf(u8, xml, "<is_output>0</is_output>") == null);
}

test "buildSessionMessagesJson emits true/false values in both directions" {
    // Defense-in-depth: confirm that BOTH true AND false round-trip through
    // the bool wire format. The single-message test above only exercises
    // (is_input=true, is_output=false); this one flips them.
    const allocator = testing.allocator;

    const messages = [_]SessionMessage{
        .{
            .id = "m2",
            .session_id = "s1",
            .role = "assistant",
            .content = "ok",
            .timestamp = "1700000001",
            .is_input = false,
            .is_output = true,
            .tool_name = "",
            .finish_reason = "stop",
            .reasoning_content = "",
        },
    };
    const response = llmHistoryIsInputOutputMakeResponse(@constCast(&messages));

    const json = try buildSessionMessagesJson(allocator, &response);
    defer allocator.free(json);

    try testing.expect(std.mem.indexOf(u8, json, "\"is_input\":false") != null);
    try testing.expect(std.mem.indexOf(u8, json, "\"is_output\":true") != null);
}

// ════════════════════════════════════════════════════════════════════════════
// Inlined from llm_history_notification_test.zig
// ════════════════════════════════════════════════════════════════════════════

// ───────────────────────────────────────────────────────────────────────
// 1. updateTaskLastHumanTouchedAt is callable + persists the value
// ───────────────────────────────────────────────────────────────────────

test "updateTaskLastHumanTouchedAt stamps the unix-ms value on the task" {
    const alloc = testing.allocator;
    var threaded = std.Io.Threaded.init(alloc, .{});
    defer threaded.deinit();
    const io = threaded.io();
    var db: database.Db = .{};
    defer db.deinit();
    try test_db.openMemory(&db, io);

    // Minimal tables Migration 065 needs (parent + task).
    try db.exec(alloc, "CREATE TABLE workspace_items (id TEXT PRIMARY KEY, workspace_id TEXT, item_type TEXT)", &.{});
    try db.exec(alloc, "CREATE TABLE workspace_item_tasks (id TEXT PRIMARY KEY, name TEXT, workspace_item_id TEXT)", &.{});
    try db.exec(alloc, "INSERT INTO workspace_items (id, workspace_id, item_type) " ++
        "VALUES ('wi_1', 'ws_1', 'chat')", &.{});
    try db.exec(alloc, "INSERT INTO workspace_item_tasks (id, name, workspace_item_id) " ++
        "VALUES ('task_1', 'T1', 'wi_1')", &.{});

    // Before stamp — column doesn't exist yet (Migration 065 not run).
    try db.exec(alloc, "ALTER TABLE workspace_item_tasks ADD COLUMN last_human_touched_at_nano BIGINT", &.{});

    const now_ms: i64 = 1_786_500_000_000;
    try updateTaskLastHumanTouchedAt(alloc, &db, "task_1", now_ms);

    var q = try db.query(alloc, "SELECT last_human_touched_at_nano FROM workspace_item_tasks WHERE id = 'task_1'", &.{});
    defer q.deinit();
    const row = (try q.next()) orelse return error.RowMissing;
    defer row.deinit(alloc);
    try testing.expectEqualStrings("1786500000000", row.values[0]);
}

test "updateTaskLastHumanTouchedAt overwrites on repeated calls" {
    const alloc = testing.allocator;
    var threaded = std.Io.Threaded.init(alloc, .{});
    defer threaded.deinit();
    const io = threaded.io();
    var db: database.Db = .{};
    defer db.deinit();
    try test_db.openMemory(&db, io);

    try db.exec(alloc, "CREATE TABLE workspace_items (id TEXT PRIMARY KEY, workspace_id TEXT, item_type TEXT)", &.{});
    try db.exec(alloc, "CREATE TABLE workspace_item_tasks (id TEXT PRIMARY KEY, name TEXT, workspace_item_id TEXT, last_human_touched_at_nano BIGINT)", &.{});
    try db.exec(alloc, "INSERT INTO workspace_items (id, workspace_id, item_type) " ++
        "VALUES ('wi_1', 'ws_1', 'chat')", &.{});
    try db.exec(alloc, "INSERT INTO workspace_item_tasks (id, name, workspace_item_id) " ++
        "VALUES ('task_1', 'T1', 'wi_1')", &.{});

    try updateTaskLastHumanTouchedAt(alloc, &db, "task_1", 100);
    try updateTaskLastHumanTouchedAt(alloc, &db, "task_1", 500);

    var q = try db.query(alloc, "SELECT last_human_touched_at_nano FROM workspace_item_tasks WHERE id = 'task_1'", &.{});
    defer q.deinit();
    const row = (try q.next()) orelse return error.RowMissing;
    defer row.deinit(alloc);
    try testing.expectEqualStrings("500", row.values[0]);
}

// ───────────────────────────────────────────────────────────────────────
// updateSessionLastHumanTouchedAt (Migration 082 / chat sidebar)
// ───────────────────────────────────────────────────────────────────────

test "updateSessionLastHumanTouchedAt stamps the unix-ms value on the session" {
    const alloc = testing.allocator;
    var threaded = std.Io.Threaded.init(alloc, .{});
    defer threaded.deinit();
    const io = threaded.io();
    var db: database.Db = .{};
    defer db.deinit();
    try test_db.openMemory(&db, io);

    // Minimal sessions table that already declares the Migration 082
    // column (so the writer doesn't have to run migrations in tests).
    try db.exec(alloc,
        \\CREATE TABLE sessions (
        \\    id TEXT PRIMARY KEY,
        \\    name TEXT NOT NULL,
        \\    last_human_touched_at_nano BIGINT
        \\)
    , &.{});
    try db.exec(alloc, "INSERT INTO sessions (id, name) VALUES ('sess_1', 'Hello')", &.{});

    const now_ms: i64 = 1_786_500_000_000;
    try updateSessionLastHumanTouchedAt(alloc, &db, "sess_1", now_ms);

    var q = try db.query(alloc, "SELECT last_human_touched_at_nano FROM sessions WHERE id = 'sess_1'", &.{});
    defer q.deinit();
    const row = (try q.next()) orelse return error.RowMissing;
    defer row.deinit(alloc);
    try testing.expectEqualStrings("1786500000000", row.values[0]);
}

test "updateSessionLastHumanTouchedAt with now_unix_ms=null reads the real clock" {
    const alloc = testing.allocator;
    var threaded = std.Io.Threaded.init(alloc, .{});
    defer threaded.deinit();
    const io = threaded.io();
    var db: database.Db = .{};
    defer db.deinit();
    try test_db.openMemory(&db, io);

    try db.exec(alloc,
        \\CREATE TABLE sessions (
        \\    id TEXT PRIMARY KEY,
        \\    name TEXT NOT NULL,
        \\    last_human_touched_at_nano BIGINT
        \\)
    , &.{});
    try db.exec(alloc, "INSERT INTO sessions (id, name) VALUES ('sess_real', 'Real')", &.{});

    // Stamp with null — should read real clock and produce a recent
    // unix-ms value (not 0, not NULL).
    const before_ms = unixMillisNow();
    try updateSessionLastHumanTouchedAt(alloc, &db, "sess_real", null);
    const after_ms = unixMillisNow();

    var q = try db.query(alloc, "SELECT last_human_touched_at_nano FROM sessions WHERE id = 'sess_real'", &.{});
    defer q.deinit();
    const row = (try q.next()) orelse return error.RowMissing;
    defer row.deinit(alloc);

    const stamped_ms = try std.fmt.parseInt(i64, row.values[0], 10);
    // Real-clock stamp must be within the [before, after] window
    // (allows for clock noise — both bounds are observed times).
    try testing.expect(stamped_ms >= before_ms);
    try testing.expect(stamped_ms <= after_ms);
    // And reasonably close to now — must not be 0 or null.
    try testing.expect(stamped_ms > 1_700_000_000_000); // year 2023+
}

test "updateSessionLastHumanTouchedAt is a no-op for unknown session_id" {
    const alloc = testing.allocator;
    var threaded = std.Io.Threaded.init(alloc, .{});
    defer threaded.deinit();
    const io = threaded.io();
    var db: database.Db = .{};
    defer db.deinit();
    try test_db.openMemory(&db, io);

    try db.exec(alloc,
        \\CREATE TABLE sessions (
        \\    id TEXT PRIMARY KEY,
        \\    name TEXT NOT NULL,
        \\    last_human_touched_at_nano BIGINT
        \\)
    , &.{});
    // No rows inserted.

    // Stamping an unknown id must NOT raise — the UPDATE affects 0 rows and
    // returns success.
    try updateSessionLastHumanTouchedAt(alloc, &db, "unknown_id", 12345);

    // Sanity: still zero rows.
    var q = try db.query(alloc, "SELECT COUNT(*) FROM sessions", &.{});
    defer q.deinit();
    const row = (try q.next()) orelse return error.RowMissing;
    defer row.deinit(alloc);
    try testing.expectEqualStrings("0", row.values[0]);
}

test "updateSessionLastHumanTouchedAt is idempotent on repeated calls with the same arg" {
    const alloc = testing.allocator;
    var threaded = std.Io.Threaded.init(alloc, .{});
    defer threaded.deinit();
    const io = threaded.io();
    var db: database.Db = .{};
    defer db.deinit();
    try test_db.openMemory(&db, io);

    try db.exec(alloc,
        \\CREATE TABLE sessions (
        \\    id TEXT PRIMARY KEY,
        \\    name TEXT NOT NULL,
        \\    last_human_touched_at_nano BIGINT
        \\)
    , &.{});
    try db.exec(alloc, "INSERT INTO sessions (id, name) VALUES ('sess_idem', 'Idem')", &.{});

    try updateSessionLastHumanTouchedAt(alloc, &db, "sess_idem", 999);
    try updateSessionLastHumanTouchedAt(alloc, &db, "sess_idem", 999);

    var q = try db.query(alloc, "SELECT last_human_touched_at_nano FROM sessions WHERE id = 'sess_idem'", &.{});
    defer q.deinit();
    const row = (try q.next()) orelse return error.RowMissing;
    defer row.deinit(alloc);
    try testing.expectEqualStrings("999", row.values[0]);
}

test "updateSessionLastHumanTouchedAt overwrites on repeated calls with a newer arg" {
    const alloc = testing.allocator;
    var threaded = std.Io.Threaded.init(alloc, .{});
    defer threaded.deinit();
    const io = threaded.io();
    var db: database.Db = .{};
    defer db.deinit();
    try test_db.openMemory(&db, io);

    try db.exec(alloc,
        \\CREATE TABLE sessions (
        \\    id TEXT PRIMARY KEY,
        \\    name TEXT NOT NULL,
        \\    last_human_touched_at_nano BIGINT
        \\)
    , &.{});
    try db.exec(alloc, "INSERT INTO sessions (id, name) VALUES ('sess_overwrite', 'Overwrite')", &.{});

    try updateSessionLastHumanTouchedAt(alloc, &db, "sess_overwrite", 100);
    try updateSessionLastHumanTouchedAt(alloc, &db, "sess_overwrite", 500);

    var q = try db.query(alloc, "SELECT last_human_touched_at_nano FROM sessions WHERE id = 'sess_overwrite'", &.{});
    defer q.deinit();
    const row = (try q.next()) orelse return error.RowMissing;
    defer row.deinit(alloc);
    try testing.expectEqualStrings("500", row.values[0]);
}

test "updateSessionLastHumanTouchedAt skips empty session_id (no SQL bind)" {
    const alloc = testing.allocator;
    var threaded = std.Io.Threaded.init(alloc, .{});
    defer threaded.deinit();
    const io = threaded.io();
    var db: database.Db = .{};
    defer db.deinit();
    try test_db.openMemory(&db, io);

    try db.exec(alloc,
        \\CREATE TABLE sessions (
        \\    id TEXT PRIMARY KEY,
        \\    name TEXT NOT NULL,
        \\    last_human_touched_at_nano BIGINT
        \\)
    , &.{});

    // Empty session_id must be a no-op (no DB write attempted).
    try updateSessionLastHumanTouchedAt(alloc, &db, "", 999);

    // No row was affected. The session table is empty.
    var q = try db.query(alloc, "SELECT COUNT(*) FROM sessions", &.{});
    defer q.deinit();
    const row = (try q.next()) orelse return error.RowMissing;
    defer row.deinit(alloc);
    try testing.expectEqualStrings("0", row.values[0]);
}

// Wire format - Migration 082: last_human_touched_at on the JSON wire.

test "buildSessionListJson emits last_human_touched_at when the row has a value (Migration 082 wire format)" {
    const alloc = testing.allocator;

    // Construct a SessionInfo with a known last_human_touched_at value.
    // All fields are heap-allocated so the deinit in buildSessionListJson's
    // caller doesn't trip the leak detector.
    const sess = SessionInfo{
        .session_id = try alloc.dupe(u8, "sess_1"),
        .session_name = try alloc.dupe(u8, "Test chat"),
        .status = try alloc.dupe(u8, "active"),
        .cwd = try alloc.dupe(u8, "/tmp"),
        .created_at = try alloc.dupe(u8, "2026-08-29 10:00:00"),
        .updated_at = try alloc.dupe(u8, "2026-08-29 10:00:00"),
        .agent = try alloc.dupe(u8, "Agent"),
        .selected_profile_model = try alloc.dupe(u8, ""),
        .is_auto_retry_until_stop = try alloc.dupe(u8, "0"),
        .last_finish_reason = try alloc.dupe(u8, ""),
        // The mapper test injects the wire shape directly (NOT
        // the raw unix-ms from the column).
        .last_human_touched_at = try alloc.dupe(u8, "2026-08-29 10:00:00"),
        .git_worktree_cwd = try alloc.dupe(u8, ""),
        .git_branch = try alloc.dupe(u8, ""),
    };
    defer sess.deinit(alloc);

    const json = try buildSessionListJson(alloc, &[_]SessionInfo{sess}, 1, false, null);
    defer alloc.free(json);

    // The wire field MUST be exactly `last_human_touched_at` (no `_nano`
    // suffix - per Migration 075 convention, SQL column keeps the suffix,
    // wire field is bare).
    try testing.expect(std.mem.indexOf(u8, json, "\"last_human_touched_at\":\"2026-08-29 10:00:00\"") != null);
}

test "buildSessionListJson emits last_human_touched_at as empty string for legacy NULL rows (Migration 082 fallback)" {
    const alloc = testing.allocator;

    // Legacy row: last_human_touched_at is the SQL default '' (NULL row).
    const sess = SessionInfo{
        .session_id = try alloc.dupe(u8, "sess_legacy"),
        .session_name = try alloc.dupe(u8, "Legacy chat"),
        .status = try alloc.dupe(u8, "active"),
        .cwd = try alloc.dupe(u8, "/tmp"),
        .created_at = try alloc.dupe(u8, "2026-08-01 10:00:00"),
        .updated_at = try alloc.dupe(u8, "2026-08-29 10:00:00"),
        .agent = try alloc.dupe(u8, "Agent"),
        .selected_profile_model = try alloc.dupe(u8, ""),
        .is_auto_retry_until_stop = try alloc.dupe(u8, "0"),
        .last_finish_reason = try alloc.dupe(u8, ""),
        .last_human_touched_at = try alloc.dupe(u8, ""),
        .git_worktree_cwd = try alloc.dupe(u8, ""),
        .git_branch = try alloc.dupe(u8, ""),
    };
    defer sess.deinit(alloc);

    const json = try buildSessionListJson(alloc, &[_]SessionInfo{sess}, 1, false, null);
    defer alloc.free(json);

    // Empty-string value (frontend treats empty as "fall back to updated_at").
    try testing.expect(std.mem.indexOf(u8, json, "\"last_human_touched_at\":\"\"") != null);
}
// Migration 082 - SELECT-layer unix-ms -> SQLite datetime conversion.
// The wire format is SQLite datetime UTC, NOT raw unix-ms. The
// SELECT layer is the sole conversion point (via strftime()).
test "getSessionListWithCursor converts unix-ms storage to SQLite datetime on the wire (Migration 082)" {
    const alloc = testing.allocator;
    var threaded = std.Io.Threaded.init(alloc, .{});
    defer threaded.deinit();
    const io = threaded.io();
    var db: database.Db = .{};
    defer db.deinit();
    try test_db.openMemory(&db, io);

    // Minimal schema with the Migration 082 column.
    try db.exec(alloc,
        \\CREATE TABLE sessions (
        \\    id TEXT PRIMARY KEY,
        \\    name TEXT NOT NULL,
        \\    status TEXT NOT NULL DEFAULT 'active',
        \\    cwd TEXT NOT NULL DEFAULT '',
        \\    created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
        \\    updated_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
        \\    selected_profile_model TEXT,
        \\    is_auto_retry_until_stop INTEGER NOT NULL DEFAULT 0,
        \\    last_finish_reason TEXT,
        \\    last_human_touched_at_nano BIGINT,
        \\    git_worktree_cwd TEXT,
        \\    is_pinned INTEGER NOT NULL DEFAULT 0,
        \\    pinned_position INTEGER NOT NULL DEFAULT 0
        \\)
    , &.{});
    // Minimal llm_history (the SELECT LEFT JOINs to it).
    try db.exec(alloc,
        \\CREATE TABLE llm_history (id TEXT PRIMARY KEY, session_id TEXT, agent TEXT)
    , &.{});
    // The session-list SELECT correlated-subqueries this table for
    // `workspace_item_id`, so a fixture that omits it fails at Prepare rather
    // than at the assertion.
    try db.exec(alloc,
        \\CREATE TABLE workspace_item_tasks (
        \\    id TEXT PRIMARY KEY,
        \\    name TEXT NOT NULL,
        \\    workspace_item_id TEXT NOT NULL
        \\)
    , &.{});

    // Insert a session with a known unix-ms stamp.
    // 2026-08-29 10:00:00 UTC = 1788008400 epoch seconds = 1788008400000 ms.
    try db.exec(alloc,
        \\INSERT INTO sessions (id, name, cwd, last_human_touched_at_nano)
        \\VALUES ('sess_conv', 'Test', '', '1788008400000')
    , &.{});

    // Run the SELECT.
    const result = getSessionListWithCursor(
        alloc,
        &db,
        null,
        null,
        null,
        null,
        auth_common.system_user_id,
        10,
        null,
        .created_at,
        .desc,
    ) catch return error.QueryFailed;
    defer {
        for (result.sessions) |s| s.deinit(alloc);
        alloc.free(result.sessions);
    }

    try testing.expectEqual(@as(usize, 1), result.sessions.len);
    const human_t = result.sessions[0].last_human_touched_at;
    // Must NOT be the raw unix-ms integer.
    try testing.expect(std.mem.indexOf(u8, human_t, "1788008400000") == null);
    // Must be the SQLite datetime format the frontend parses.
    try testing.expectEqualStrings("2026-08-29 13:00:00", human_t);
}

test "getSessionListWithCursor returns empty string for NULL last_human_touched_at_nano (Migration 082)" {
    const alloc = testing.allocator;
    var threaded = std.Io.Threaded.init(alloc, .{});
    defer threaded.deinit();
    const io = threaded.io();
    var db: database.Db = .{};
    defer db.deinit();
    try test_db.openMemory(&db, io);

    try db.exec(alloc,
        \\CREATE TABLE sessions (
        \\    id TEXT PRIMARY KEY,
        \\    name TEXT NOT NULL,
        \\    status TEXT NOT NULL DEFAULT 'active',
        \\    cwd TEXT NOT NULL DEFAULT '',
        \\    created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
        \\    updated_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
        \\    selected_profile_model TEXT,
        \\    is_auto_retry_until_stop INTEGER NOT NULL DEFAULT 0,
        \\    last_finish_reason TEXT,
        \\    last_human_touched_at_nano BIGINT,
        \\    git_worktree_cwd TEXT,
        \\    is_pinned INTEGER NOT NULL DEFAULT 0,
        \\    pinned_position INTEGER NOT NULL DEFAULT 0
        \\)
    , &.{});
    // Minimal llm_history (the SELECT LEFT JOINs to it).
    try db.exec(alloc,
        \\CREATE TABLE llm_history (id TEXT PRIMARY KEY, session_id TEXT, agent TEXT)
    , &.{});
    // The session-list SELECT correlated-subqueries this table for
    // `workspace_item_id`, so a fixture that omits it fails at Prepare rather
    // than at the assertion.
    try db.exec(alloc,
        \\CREATE TABLE workspace_item_tasks (
        \\    id TEXT PRIMARY KEY,
        \\    name TEXT NOT NULL,
        \\    workspace_item_id TEXT NOT NULL
        \\)
    , &.{});

    // Insert a session with NO stamp (NULL column).
    try db.exec(alloc,
        \\INSERT INTO sessions (id, name, cwd) VALUES ('sess_null', 'Legacy', '')
    , &.{});

    const result = getSessionListWithCursor(
        alloc,
        &db,
        null,
        null,
        null,
        null,
        auth_common.system_user_id,
        10,
        null,
        .created_at,
        .desc,
    ) catch return error.QueryFailed;
    defer {
        for (result.sessions) |s| s.deinit(alloc);
        alloc.free(result.sessions);
    }

    try testing.expectEqual(@as(usize, 1), result.sessions.len);
    try testing.expectEqualStrings("", result.sessions[0].last_human_touched_at);
}

test "getSessionListWithCursor derives needs_human_review for the sidebar status badge" {
    const alloc = testing.allocator;
    var threaded = std.Io.Threaded.init(alloc, .{});
    defer threaded.deinit();
    const io = threaded.io();
    var db: database.Db = .{};
    defer db.deinit();
    try test_db.openMemory(&db, io);

    try db.exec(alloc,
        \\CREATE TABLE sessions (
        \\    id TEXT PRIMARY KEY,
        \\    name TEXT NOT NULL,
        \\    status TEXT NOT NULL DEFAULT 'active',
        \\    cwd TEXT NOT NULL DEFAULT '',
        \\    created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
        \\    updated_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
        \\    selected_profile_model TEXT,
        \\    is_auto_retry_until_stop INTEGER NOT NULL DEFAULT 0,
        \\    last_finish_reason TEXT,
        \\    last_human_touched_at_nano BIGINT,
        \\    git_worktree_cwd TEXT,
        \\    is_pinned INTEGER NOT NULL DEFAULT 0,
        \\    pinned_position INTEGER NOT NULL DEFAULT 0
        \\)
    , &.{});
    try db.exec(alloc,
        \\CREATE TABLE llm_history (id TEXT PRIMARY KEY, session_id TEXT, agent TEXT)
    , &.{});
    try db.exec(alloc,
        \\CREATE TABLE workspace_item_tasks (
        \\    id TEXT PRIMARY KEY,
        \\    name TEXT NOT NULL,
        \\    workspace_item_id TEXT NOT NULL
        \\)
    , &.{});

    // Row 1: AI finished, human never touched -> awaiting review.
    // updated_at is pinned so the strftime comparison is deterministic.
    try db.exec(alloc,
        \\INSERT INTO sessions (id, name, cwd, updated_at, last_finish_reason)
        \\VALUES ('sess_await', 'Awaiting', '', '2026-08-29 10:00:00', 'stop')
    , &.{});
    // Row 2: AI finished, human touched AFTER -> reviewed.
    // 2026-08-29 12:00:00 UTC = 1788014400 epoch seconds.
    try db.exec(alloc,
        \\INSERT INTO sessions (id, name, cwd, updated_at, last_finish_reason, last_human_touched_at_nano)
        \\VALUES ('sess_reviewed', 'Reviewed', '', '2026-08-29 10:00:00', 'stop', '1788014400000')
    , &.{});
    // Row 3: mid-turn (tool_calls) -> no badge at all.
    try db.exec(alloc,
        \\INSERT INTO sessions (id, name, cwd, updated_at, last_finish_reason)
        \\VALUES ('sess_midturn', 'Mid turn', '', '2026-08-29 10:00:00', 'tool_calls')
    , &.{});

    const result = getSessionListWithCursor(
        alloc,
        &db,
        null,
        null,
        null,
        null,
        auth_common.system_user_id,
        10,
        null,
        .created_at,
        .desc,
    ) catch return error.QueryFailed;
    defer {
        for (result.sessions) |s| s.deinit(alloc);
        alloc.free(result.sessions);
    }

    try testing.expectEqual(@as(usize, 3), result.sessions.len);
    var awaiting = false;
    var reviewed = false;
    var midturn = false;
    for (result.sessions) |s| {
        if (std.mem.eql(u8, s.session_id, "sess_await")) {
            awaiting = s.needs_human_review;
        } else if (std.mem.eql(u8, s.session_id, "sess_reviewed")) {
            reviewed = s.needs_human_review;
        } else if (std.mem.eql(u8, s.session_id, "sess_midturn")) {
            midturn = s.needs_human_review;
        }
    }
    try testing.expect(awaiting);
    try testing.expect(!reviewed);
    try testing.expect(!midturn);
}

test "buildSessionListJson emits needs_human_review for the sidebar status badge" {
    const alloc = testing.allocator;

    const sess = SessionInfo{
        .session_id = try alloc.dupe(u8, "sess_badge"),
        .session_name = try alloc.dupe(u8, "Badge chat"),
        .status = try alloc.dupe(u8, "active"),
        .cwd = try alloc.dupe(u8, "/tmp"),
        .created_at = try alloc.dupe(u8, "2026-08-29 10:00:00"),
        .updated_at = try alloc.dupe(u8, "2026-08-29 10:00:00"),
        .agent = try alloc.dupe(u8, "Agent"),
        .selected_profile_model = try alloc.dupe(u8, ""),
        .is_auto_retry_until_stop = try alloc.dupe(u8, "0"),
        .last_finish_reason = try alloc.dupe(u8, "stop"),
        .last_human_touched_at = try alloc.dupe(u8, ""),
        .git_worktree_cwd = try alloc.dupe(u8, ""),
        .git_branch = try alloc.dupe(u8, ""),
        .needs_human_review = true,
    };
    defer sess.deinit(alloc);

    const json = try buildSessionListJson(alloc, &[_]SessionInfo{sess}, 1, false, null);
    defer alloc.free(json);

    try testing.expect(std.mem.indexOf(u8, json, "\"needs_human_review\":true") != null);
}

test "getSessionListWithCursor pages on the sort field's column, not created_at" {
    const alloc = testing.allocator;
    var threaded = std.Io.Threaded.init(alloc, .{});
    defer threaded.deinit();
    const io = threaded.io();
    var db: database.Db = .{};
    defer db.deinit();
    try test_db.openMemory(&db, io);

    try db.exec(alloc,
        \\CREATE TABLE sessions (
        \\    id TEXT PRIMARY KEY,
        \\    name TEXT NOT NULL,
        \\    status TEXT NOT NULL DEFAULT 'active',
        \\    cwd TEXT NOT NULL DEFAULT '',
        \\    created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
        \\    updated_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
        \\    selected_profile_model TEXT,
        \\    is_auto_retry_until_stop INTEGER NOT NULL DEFAULT 0,
        \\    last_finish_reason TEXT,
        \\    last_human_touched_at_nano BIGINT,
        \\    git_worktree_cwd TEXT,
        \\    is_pinned INTEGER NOT NULL DEFAULT 0,
        \\    pinned_position INTEGER NOT NULL DEFAULT 0
        \\)
    , &.{});
    try db.exec(alloc,
        \\CREATE TABLE llm_history (id TEXT PRIMARY KEY, session_id TEXT, agent TEXT)
    , &.{});
    // The session-list SELECT correlated-subqueries this table for
    // `workspace_item_id`, so a fixture that omits it fails at Prepare rather
    // than at the assertion.
    try db.exec(alloc,
        \\CREATE TABLE workspace_item_tasks (
        \\    id TEXT PRIMARY KEY,
        \\    name TEXT NOT NULL,
        \\    workspace_item_id TEXT NOT NULL
        \\)
    , &.{});

    // `created_at` and `updated_at` are deliberately INVERTED: every row was
    // created in early 2026 and touched later, so the two columns disagree
    // about ordering for every single row.
    try db.exec(alloc,
        \\INSERT INTO sessions (id, name, cwd, created_at, updated_at) VALUES
        \\  ('s_a', 'A', '', '2026-01-01 00:00:00', '2026-09-20 00:00:00'),
        \\  ('s_b', 'B', '', '2026-02-01 00:00:00', '2026-09-10 00:00:00'),
        \\  ('s_c', 'C', '', '2026-03-01 00:00:00', '2026-09-01 00:00:00')
    , &.{});

    // Page 1, newest two by updated_at.
    const page1 = getSessionListWithCursor(
        alloc,
        &db,
        null,
        null,
        null,
        null,
        auth_common.system_user_id,
        2,
        null,
        .updated_at,
        .desc,
    ) catch return error.QueryFailed;
    defer {
        for (page1.sessions) |s| s.deinit(alloc);
        alloc.free(page1.sessions);
    }

    try testing.expectEqual(@as(usize, 2), page1.sessions.len);
    try testing.expectEqualStrings("s_a", page1.sessions[0].session_id);
    try testing.expectEqualStrings("s_b", page1.sessions[1].session_id);
    // `total` is the full filtered size, not the remaining rows.
    try testing.expectEqual(@as(u32, 3), page1.total);

    // `next_cursor` is the last row's sort-field value — s_b's updated_at.
    const page2 = getSessionListWithCursor(
        alloc,
        &db,
        null,
        null,
        null,
        null,
        auth_common.system_user_id,
        2,
        "2026-09-10 00:00:00",
        .updated_at,
        .desc,
    ) catch return error.QueryFailed;
    defer {
        for (page2.sessions) |s| s.deinit(alloc);
        alloc.free(page2.sessions);
    }

    // Exactly the rows strictly older than the cursor — no replay of page 1.
    try testing.expectEqual(@as(usize, 1), page2.sessions.len);
    try testing.expectEqualStrings("s_c", page2.sessions[0].session_id);
    // Unchanged by the cursor: it counts the whole scoped set.
    try testing.expectEqual(@as(u32, 3), page2.total);
}

test "getSessionListWithCursor keeps the created_at filter when sorting by created_at" {
    const alloc = testing.allocator;
    var threaded = std.Io.Threaded.init(alloc, .{});
    defer threaded.deinit();
    const io = threaded.io();
    var db: database.Db = .{};
    defer db.deinit();
    try test_db.openMemory(&db, io);

    try db.exec(alloc,
        \\CREATE TABLE sessions (
        \\    id TEXT PRIMARY KEY,
        \\    name TEXT NOT NULL,
        \\    status TEXT NOT NULL DEFAULT 'active',
        \\    cwd TEXT NOT NULL DEFAULT '',
        \\    created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
        \\    updated_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
        \\    selected_profile_model TEXT,
        \\    is_auto_retry_until_stop INTEGER NOT NULL DEFAULT 0,
        \\    last_finish_reason TEXT,
        \\    last_human_touched_at_nano BIGINT,
        \\    git_worktree_cwd TEXT,
        \\    is_pinned INTEGER NOT NULL DEFAULT 0,
        \\    pinned_position INTEGER NOT NULL DEFAULT 0
        \\)
    , &.{});
    try db.exec(alloc,
        \\CREATE TABLE llm_history (id TEXT PRIMARY KEY, session_id TEXT, agent TEXT)
    , &.{});
    // The session-list SELECT correlated-subqueries this table for
    // `workspace_item_id`, so a fixture that omits it fails at Prepare rather
    // than at the assertion.
    try db.exec(alloc,
        \\CREATE TABLE workspace_item_tasks (
        \\    id TEXT PRIMARY KEY,
        \\    name TEXT NOT NULL,
        \\    workspace_item_id TEXT NOT NULL
        \\)
    , &.{});

    try db.exec(alloc,
        \\INSERT INTO sessions (id, name, cwd, created_at, updated_at) VALUES
        \\  ('s_new', 'New', '', '2026-09-20 00:00:00', '2026-01-01 00:00:00'),
        \\  ('s_old', 'Old', '', '2026-01-01 00:00:00', '2026-09-20 00:00:00')
    , &.{});

    // `created_at` desc puts s_new first; the cursor is its created_at, and
    // s_old is the only row created before it. Switching the filter column
    // must not have regressed the default sort.
    const result = getSessionListWithCursor(
        alloc,
        &db,
        null,
        null,
        null,
        null,
        auth_common.system_user_id,
        10,
        "2026-09-20 00:00:00",
        .created_at,
        .desc,
    ) catch return error.QueryFailed;
    defer {
        for (result.sessions) |s| s.deinit(alloc);
        alloc.free(result.sessions);
    }

    try testing.expectEqual(@as(usize, 1), result.sessions.len);
    try testing.expectEqualStrings("s_old", result.sessions[0].session_id);
}

// ───────────────────────────────────────────────────────────────────────
// Workspace-scoped list (plan: workspace-scoped chat sessions) — the count
// query must honor the same `s.id IN (...)` predicate as the main query,

test "getSessionListWithCursor: workspace_ids bounds sessions AND total (count honors the filter)" {
    const alloc = testing.allocator;
    var threaded = std.Io.Threaded.init(alloc, .{});
    defer threaded.deinit();
    const io = threaded.io();
    var db: database.Db = .{};
    defer db.deinit();
    try test_db.openMemory(&db, io);

    try db.exec(alloc,
        \\CREATE TABLE sessions (
        \\    id TEXT PRIMARY KEY,
        \\    name TEXT NOT NULL,
        \\    status TEXT NOT NULL DEFAULT 'active',
        \\    cwd TEXT NOT NULL DEFAULT '',
        \\    created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
        \\    updated_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
        \\    selected_profile_model TEXT,
        \\    is_auto_retry_until_stop INTEGER NOT NULL DEFAULT 0,
        \\    last_finish_reason TEXT,
        \\    last_human_touched_at_nano BIGINT,
        \\    git_worktree_cwd TEXT,
        \\    is_pinned INTEGER NOT NULL DEFAULT 0,
        \\    pinned_position INTEGER NOT NULL DEFAULT 0
        \\)
    , &.{});
    try db.exec(alloc,
        \\CREATE TABLE llm_history (id TEXT PRIMARY KEY, session_id TEXT, agent TEXT)
    , &.{});
    // The session-list SELECT correlated-subqueries this table for
    // `workspace_item_id`, so a fixture that omits it fails at Prepare rather
    // than at the assertion.
    try db.exec(alloc,
        \\CREATE TABLE workspace_item_tasks (
        \\    id TEXT PRIMARY KEY,
        \\    name TEXT NOT NULL,
        \\    workspace_item_id TEXT NOT NULL
        \\)
    , &.{});
    try db.exec(alloc,
        \\INSERT INTO sessions (id, name, cwd) VALUES
        \\  ('s_keep_a', 'Keep A', '/proj/a'),
        \\  ('s_keep_b', 'Keep B', '/proj/a'),
        \\  ('s_drop_1', 'Drop 1', '/proj/b'),
        \\  ('s_drop_2', 'Drop 2', '/proj/c')
    , &.{});

    // Non-null + non-empty: only the listed ids — sessions AND total
    // are both bounded (total must NOT stay at the global 4).
    const scoped = try alloc.alloc([]const u8, 2);
    defer alloc.free(scoped);
    scoped[0] = "s_keep_a";
    scoped[1] = "s_keep_b";
    const scoped_result = try getSessionListWithCursor(
        alloc,
        &db,
        null,
        null,
        null,
        scoped,
        auth_common.system_user_id,
        50,
        null,
        .created_at,
        .desc,
    );
    defer {
        for (scoped_result.sessions) |s| s.deinit(alloc);
        alloc.free(scoped_result.sessions);
    }
    try testing.expectEqual(@as(usize, 2), scoped_result.sessions.len);
    try testing.expectEqual(@as(u32, 2), scoped_result.total);

    // Non-null + EMPTY: fail closed with zero sessions and zero
    // total. Also proves we never emit `IN ()` (a syntax error that
    // would make this db.query throw instead of returning 0 rows).
    const empty_result = try getSessionListWithCursor(
        alloc,
        &db,
        null,
        null,
        null,
        &.{},
        auth_common.system_user_id,
        50,
        null,
        .created_at,
        .desc,
    );
    defer {
        for (empty_result.sessions) |s| s.deinit(alloc);
        alloc.free(empty_result.sessions);
    }
    try testing.expectEqual(@as(usize, 0), empty_result.sessions.len);
    try testing.expectEqual(@as(u32, 0), empty_result.total);

    // null: global list unchanged (back-compat with pre-scoping
    // callers — SQL and binds are identical to before the param).
    const global_result = try getSessionListWithCursor(
        alloc,
        &db,
        null,
        null,
        null,
        null,
        auth_common.system_user_id,
        50,
        null,
        .created_at,
        .desc,
    );
    defer {
        for (global_result.sessions) |s| s.deinit(alloc);
        alloc.free(global_result.sessions);
    }
    try testing.expectEqual(@as(usize, 4), global_result.sessions.len);
    try testing.expectEqual(@as(u32, 4), global_result.total);
}

// ───────────────────────────────────────────────────────────────────────
// Behavioural — the SQL predicate for needs_human_review works end-to-end on
// a real in-memory DB.

test "needs_human_review predicate returns 1 when finish_reason='stop' AND no human touch" {
    const alloc = testing.allocator;
    var threaded = std.Io.Threaded.init(alloc, .{});
    defer threaded.deinit();
    const io = threaded.io();
    var db: database.Db = .{};
    defer db.deinit();
    try test_db.openMemory(&db, io);

    // Parent table + task table with the Migration 065 column +
    // sessions table to JOIN against.
    try db.exec(alloc, "CREATE TABLE workspace_items (id TEXT PRIMARY KEY, workspace_id TEXT, item_type TEXT)", &.{});
    try db.exec(alloc,
        \\CREATE TABLE workspace_item_tasks (
        \\  id TEXT PRIMARY KEY,
        \\  name TEXT,
        \\  workspace_item_id TEXT,
        \\  last_human_touched_at_nano BIGINT
        \\)
    , &.{});
    // Post-Migration-072: kanban placement lives in the `kanban` join table.
    try db.exec(alloc,
        \\CREATE TABLE kanban (
        \\  task_id TEXT PRIMARY KEY,
        \\  kanban_column_id TEXT NOT NULL,
        \\  kanban_position INTEGER NOT NULL DEFAULT 0
        \\)
    , &.{});
    try db.exec(alloc,
        \\CREATE TABLE sessions (
        \\  id TEXT PRIMARY KEY,
        \\  name TEXT,
        \\  status TEXT,
        \\  last_finish_reason TEXT,
        \\  updated_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
        \\  git_worktree_cwd TEXT
        \\)
    , &.{});

    try db.exec(alloc, "INSERT INTO workspace_items (id, workspace_id, item_type) VALUES ('wi_1','ws_1','kanban')", &.{});
    try db.exec(alloc, "INSERT INTO workspace_item_tasks (id, name, workspace_item_id) " ++
        "VALUES ('task_awaiting', 'T1', 'wi_1')", &.{});
    // AI finished on this task 1 hour ago.
    try db.exec(alloc, "INSERT INTO sessions (id, name, status, last_finish_reason, updated_at) " ++
        "VALUES ('task_awaiting', 'T1', 'idle', 'stop', datetime('now', '-1 hour'))", &.{});

    // Replicate the production SQL CASE.
    var q = try db.query(alloc,
        \\SELECT CASE
        \\  WHEN COALESCE(s.last_finish_reason, '') = 'stop'
        \\       AND (
        \\         t.last_human_touched_at_nano IS NULL
        \\         OR t.last_human_touched_at_nano < CAST(strftime('%s', s.updated_at) AS INTEGER) * 1000
        \\       )
        \\  THEN 1 ELSE 0 END
        \\FROM workspace_item_tasks t
        \\LEFT JOIN sessions s ON s.id = t.id
        \\WHERE t.id = 'task_awaiting'
    , &.{});
    defer q.deinit();
    const row = (try q.next()) orelse return error.RowMissing;
    defer row.deinit(alloc);
    try testing.expectEqualStrings("1", row.values[0]);
}

test "needs_human_review predicate returns 0 when human touched AFTER the AI finished" {
    const alloc = testing.allocator;
    var threaded = std.Io.Threaded.init(alloc, .{});
    defer threaded.deinit();
    const io = threaded.io();
    var db: database.Db = .{};
    defer db.deinit();
    try test_db.openMemory(&db, io);

    try db.exec(alloc, "CREATE TABLE workspace_items (id TEXT PRIMARY KEY, workspace_id TEXT, item_type TEXT)", &.{});
    try db.exec(alloc,
        \\CREATE TABLE workspace_item_tasks (
        \\  id TEXT PRIMARY KEY, name TEXT, workspace_item_id TEXT,
        \\  last_human_touched_at_nano BIGINT
        \\)
    , &.{});
    try db.exec(alloc,
        \\CREATE TABLE sessions (
        \\  id TEXT PRIMARY KEY, name TEXT, status TEXT,
        \\  last_finish_reason TEXT,
        \\  updated_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
        \\  git_worktree_cwd TEXT
        \\)
    , &.{});
    try db.exec(alloc, "INSERT INTO workspace_items (id, workspace_id, item_type) VALUES ('wi_1','ws_1','kanban')", &.{});

    // AI finished 1 hour ago.
    try db.exec(alloc, "INSERT INTO sessions (id, name, status, last_finish_reason, updated_at) " ++
        "VALUES ('task_reviewed', 'T', 'idle', 'stop', datetime('now', '-1 hour'))", &.{});
    // Human touched 10 seconds ago (clearly after the AI's finish).
    const now_ms: i64 = 2_000_000_000_000; // year 2033 in unix-ms
    var t_buf: [32]u8 = undefined;
    const t_str = std.fmt.bufPrint(&t_buf, "{d}", .{now_ms}) catch @panic("bufPrint failed formatting the fixed fixture timestamp");
    try db.exec(alloc, "INSERT INTO workspace_item_tasks (id, name, workspace_item_id, last_human_touched_at_nano) " ++
        "VALUES ('task_reviewed', 'T', 'wi_1', ?)", &[_][]const u8{t_str});

    var q = try db.query(alloc,
        \\SELECT CASE
        \\  WHEN COALESCE(s.last_finish_reason, '') = 'stop'
        \\       AND (
        \\         t.last_human_touched_at_nano IS NULL
        \\         OR t.last_human_touched_at_nano < CAST(strftime('%s', s.updated_at) AS INTEGER) * 1000
        \\       )
        \\  THEN 1 ELSE 0 END
        \\FROM workspace_item_tasks t
        \\LEFT JOIN sessions s ON s.id = t.id
        \\WHERE t.id = 'task_reviewed'
    , &.{});
    defer q.deinit();
    const row = (try q.next()) orelse return error.RowMissing;
    defer row.deinit(alloc);
    try testing.expectEqualStrings("0", row.values[0]);
}

test "needs_human_review predicate returns 0 when finish_reason is 'tool_calls' (mid-tool, not yet stop)" {
    const alloc = testing.allocator;
    var threaded = std.Io.Threaded.init(alloc, .{});
    defer threaded.deinit();
    const io = threaded.io();
    var db: database.Db = .{};
    defer db.deinit();
    try test_db.openMemory(&db, io);

    try db.exec(alloc, "CREATE TABLE workspace_items (id TEXT PRIMARY KEY, workspace_id TEXT, item_type TEXT)", &.{});
    try db.exec(alloc,
        \\CREATE TABLE workspace_item_tasks (
        \\  id TEXT PRIMARY KEY, name TEXT, workspace_item_id TEXT,
        \\  last_human_touched_at_nano BIGINT
        \\)
    , &.{});
    try db.exec(alloc,
        \\CREATE TABLE sessions (
        \\  id TEXT PRIMARY KEY, name TEXT, status TEXT,
        \\  last_finish_reason TEXT,
        \\  updated_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
        \\  git_worktree_cwd TEXT
        \\)
    , &.{});
    try db.exec(alloc, "INSERT INTO workspace_items (id, workspace_id, item_type) VALUES ('wi_1','ws_1','kanban')", &.{});
    try db.exec(alloc, "INSERT INTO workspace_item_tasks (id, name, workspace_item_id) " ++
        "VALUES ('task_tools', 'T', 'wi_1')", &.{});
    // Agent is mid-tool-call, not finished yet.
    try db.exec(alloc, "INSERT INTO sessions (id, name, status, last_finish_reason, updated_at) " ++
        "VALUES ('task_tools', 'T', 'active', 'tool_calls', datetime('now'))", &.{});

    var q = try db.query(alloc,
        \\SELECT CASE
        \\  WHEN COALESCE(s.last_finish_reason, '') = 'stop'
        \\       AND (
        \\         t.last_human_touched_at_nano IS NULL
        \\         OR t.last_human_touched_at_nano < CAST(strftime('%s', s.updated_at) AS INTEGER) * 1000
        \\       )
        \\  THEN 1 ELSE 0 END
        \\FROM workspace_item_tasks t
        \\LEFT JOIN sessions s ON s.id = t.id
        \\WHERE t.id = 'task_tools'
    , &.{});
    defer q.deinit();
    const row = (try q.next()) orelse return error.RowMissing;
    defer row.deinit(alloc);
    try testing.expectEqualStrings("0", row.values[0]);
}

test "needs_human_review predicate returns 0 when no sessions row exists for the task" {
    // Tasks that never had any AI work (e.g. user created a card and
    // hasn't sent a chat message yet) should not show the dot.
    const alloc = testing.allocator;
    var threaded = std.Io.Threaded.init(alloc, .{});
    defer threaded.deinit();
    const io = threaded.io();
    var db: database.Db = .{};
    defer db.deinit();
    try test_db.openMemory(&db, io);

    try db.exec(alloc, "CREATE TABLE workspace_items (id TEXT PRIMARY KEY, workspace_id TEXT, item_type TEXT)", &.{});
    try db.exec(alloc,
        \\CREATE TABLE workspace_item_tasks (
        \\  id TEXT PRIMARY KEY, name TEXT, workspace_item_id TEXT,
        \\  last_human_touched_at_nano BIGINT
        \\)
    , &.{});
    try db.exec(alloc, "CREATE TABLE sessions (id TEXT PRIMARY KEY, name TEXT, status TEXT, last_finish_reason TEXT, updated_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP, git_worktree_cwd TEXT)", &.{});
    try db.exec(alloc, "INSERT INTO workspace_items (id, workspace_id, item_type) VALUES ('wi_1','ws_1','kanban')", &.{});
    try db.exec(alloc, "INSERT INTO workspace_item_tasks (id, name, workspace_item_id) VALUES ('task_empty','T','wi_1')", &.{});

    var q = try db.query(alloc,
        \\SELECT CASE
        \\  WHEN COALESCE(s.last_finish_reason, '') = 'stop'
        \\       AND (
        \\         t.last_human_touched_at_nano IS NULL
        \\         OR t.last_human_touched_at_nano < CAST(strftime('%s', s.updated_at) AS INTEGER) * 1000
        \\       )
        \\  THEN 1 ELSE 0 END
        \\FROM workspace_item_tasks t
        \\LEFT JOIN sessions s ON s.id = t.id
        \\WHERE t.id = 'task_empty'
    , &.{});
    defer q.deinit();
    const row = (try q.next()) orelse return error.RowMissing;
    defer row.deinit(alloc);
    try testing.expectEqualStrings("0", row.values[0]);
}

// ════════════════════════════════════════════════════════════════════════════
// Inlined from llm_history_search_fts_query_safety_test.zig
// ════════════════════════════════════════════════════════════════════════════

const migration = @import("../migrations/migration.zig");

fn llmHistorySearchFtsQuerySafetySetupDb() !TestCtx {
    const alloc = testing.allocator;
    var threaded = std.Io.Threaded.init(alloc, .{});
    errdefer threaded.deinit();
    const io = threaded.io();
    var db: database.Db = .{};
    errdefer db.deinit();
    try test_db.openMemory(&db, io);

    // Walk every production migration so the schema (including `messages_fts`
    // + its triggers) matches what production runs.
    var manager = migration.MigrationManager.init(alloc, &db);
    defer manager.deinit();
    try migration.registerAllMigrations(&manager);
    try manager.runMigrations();

    return .{ .db = db, .threaded = threaded, .alloc = alloc };
}

fn teardown(ctx: *TestCtx) void {
    ctx.db.deinit();
    ctx.threaded.deinit();
}

/// Insert a row whose `response_content` contains all of the "needle" words
/// in `needles` so we can prove the FTS5 query finds it.
fn insertRow(ctx: *TestCtx, id: []const u8, content: []const u8) !void {
    const alloc = testing.allocator;
    var sql_buf: [512]u8 = undefined;
    const stmt = try std.fmt.bufPrint(sql_buf[0..], "INSERT INTO llm_history (id, session_id, model, role, response_content) " ++
        "VALUES ('{s}','s_1','test-model','user','{s}')", .{ id, content });
    try ctx.db.exec(alloc, stmt, &.{});
}

fn freeHits(alloc: std.mem.Allocator, hits: []SearchHit) void {
    for (hits) |h| {
        var copy = h;
        copy.deinit(alloc);
    }
    alloc.free(hits);
}

// ─── Tests that prove the failing-queries bug ──────────────────────────
// Each test below reproduces a specific query the user ran that returned "FTS
// search failed: QueryFailed".

test "searchMessagesFts: dotted identifier handle_tool.zig returns the inserted row" {
    var ctx = try llmHistorySearchFtsQuerySafetySetupDb();
    defer teardown(&ctx);
    const alloc = testing.allocator;

    try insertRow(&ctx, "h1", "the agentic_loop/handle_tool.zig has broken imports that we need to fix");

    const hits = try searchMessagesFts(alloc, &ctx.db, "handle_tool.zig", .{});
    defer freeHits(alloc, hits);

    try testing.expectEqual(@as(usize, 1), hits.len);
    try testing.expectEqualStrings("h1", hits[0].id);
}

test "searchMessagesFts: hyphenated date 2026-08-06 returns the inserted row" {
    var ctx = try llmHistorySearchFtsQuerySafetySetupDb();
    defer teardown(&ctx);
    const alloc = testing.allocator;

    // Use a date-format string the user might search for verbatim
    try insertRow(&ctx, "h_date", "log entry on 2026-08-06 says the build is green");

    const hits = try searchMessagesFts(alloc, &ctx.db, "2026-08-06", .{});
    defer freeHits(alloc, hits);

    try testing.expectEqual(@as(usize, 1), hits.len);
    try testing.expectEqualStrings("h_date", hits[0].id);
}

test "searchMessagesFts: column-syntax colon agentic_loop/handle_tool.zig:18 returns the inserted row" {
    var ctx = try llmHistorySearchFtsQuerySafetySetupDb();
    defer teardown(&ctx);
    const alloc = testing.allocator;

    try insertRow(&ctx, "h_col", "the bug at agentic_loop/handle_tool.zig:18 references the broken import");

    // This is the exact query the user tried. Without the fix, FTS5
    // sees the trailing `:18` as a column-name filter on a column that
    // does not exist and returns SQLITE_ERROR.
    const hits = try searchMessagesFts(alloc, &ctx.db, "agentic_loop/handle_tool.zig:18", .{});
    defer freeHits(alloc, hits);

    try testing.expect(hits.len >= 1);
    try testing.expectEqualStrings("h_col", hits[0].id);
}

test "searchMessagesFts: dotted short word SPEC.md returns the inserted row" {
    var ctx = try llmHistorySearchFtsQuerySafetySetupDb();
    defer teardown(&ctx);
    const alloc = testing.allocator;

    try insertRow(&ctx, "h_spec", "see SPEC.md for the full design");

    const hits = try searchMessagesFts(alloc, &ctx.db, "SPEC.md", .{});
    defer freeHits(alloc, hits);

    try testing.expectEqual(@as(usize, 1), hits.len);
    try testing.expectEqualStrings("h_spec", hits[0].id);
}

// ─── Tests that already-passing queries still pass (regression guard) ──

test "searchMessagesFts: plain words still match (regression guard)" {
    var ctx = try llmHistorySearchFtsQuerySafetySetupDb();
    defer teardown(&ctx);
    const alloc = testing.allocator;

    try insertRow(&ctx, "h_plain", "the login bug needs fixing urgently");

    const hits = try searchMessagesFts(alloc, &ctx.db, "login bug", .{});
    defer freeHits(alloc, hits);

    try testing.expectEqual(@as(usize, 1), hits.len);
    try testing.expectEqualStrings("h_plain", hits[0].id);
}

// ════════════════════════════════════════════════════════════════════════════
// Inlined from llm_history_search_messages_fts_test.zig
// ════════════════════════════════════════════════════════════════════════════

fn llmHistorySearchMessagesFtsSetupDb() !TestCtx {
    const alloc = testing.allocator;
    var threaded = std.Io.Threaded.init(alloc, .{});
    errdefer threaded.deinit();
    const io = threaded.io();
    var db: database.Db = .{};
    errdefer db.deinit();
    try test_db.openMemory(&db, io);

    try db.exec(alloc,
        \\CREATE TABLE llm_history (
        \\  id TEXT PRIMARY KEY,
        \\  session_id TEXT NOT NULL,
        \\  model TEXT,
        \\  response_content TEXT,
        \\  role TEXT,
        \\  tool_call_id TEXT,
        \\  tool_name TEXT,
        \\  is_feed_to_llm INTEGER DEFAULT 1,
        \\  agent TEXT,
        \\  created_at_nano TEXT DEFAULT (datetime('now')),
        \\  -- Mirrors Migration 059 in production: a regular TEXT column.
        \\  -- No INSERT trigger — production populates it from application
        \\  -- code in `saveMessage`. For test convenience, default to
        \\  -- 'now localtime' (matching `created_at`'s default of 'now').
        \\  -- Tests that need specific timestamps pass `created_at` AND
        \\  -- `created_iso` explicitly via a sub-SELECT that mirrors the
        \\  -- production conversion.
        \\  created_iso TEXT DEFAULT CURRENT_TIMESTAMP
        \\)
    , &.{});
    if (dialect.has_fts5) {
        try db.exec(alloc,
            \\CREATE VIRTUAL TABLE messages_fts USING fts5(
            \\    content
            \\)
        , &.{});
    }

    // Sync triggers — same shape as Migration 058 in production (now
    // non-external-content so snippet() can read from messages_fts).
    if (dialect.has_fts5) try db.exec(alloc,
        \\CREATE TRIGGER llm_history_ai AFTER INSERT ON llm_history BEGIN
        \\  INSERT INTO messages_fts(rowid, content) VALUES (new.rowid, COALESCE(new.response_content, ''));
        \\END
    , &.{});
    if (dialect.has_fts5) try db.exec(alloc,
        \\CREATE TRIGGER llm_history_ad AFTER DELETE ON llm_history BEGIN
        \\  DELETE FROM messages_fts WHERE rowid = old.rowid;
        \\END
    , &.{});
    if (dialect.has_fts5) try db.exec(alloc,
        \\CREATE TRIGGER llm_history_au AFTER UPDATE ON llm_history BEGIN
        \\  DELETE FROM messages_fts WHERE rowid = old.rowid;
        \\  INSERT INTO messages_fts(rowid, content) VALUES (new.rowid, COALESCE(new.response_content, ''));
        \\END
    , &.{});

    return .{ .db = db, .threaded = threaded, .alloc = alloc };
}

test "searchMessagesFts: returns hits ranked by relevance" {
    var s = try llmHistorySearchMessagesFtsSetupDb();
    defer {
        s.db.deinit();
        s.threaded.deinit();
    }
    const alloc = testing.allocator;

    try s.db.exec(alloc, "INSERT INTO llm_history (id, session_id, role, response_content) " ++
        "VALUES ('h1','s_1','user','the login bug needs fixing urgently')", &.{});
    try s.db.exec(alloc, "INSERT INTO llm_history (id, session_id, role, response_content) " ++
        "VALUES ('h2','s_1','user','all tests pass')", &.{});

    const hits = try searchMessagesFts(alloc, &s.db, "login bug", .{});
    defer {
        for (hits) |h| {
            var copy = h;
            copy.deinit(alloc);
        }
        alloc.free(hits);
    }

    try testing.expectEqual(@as(usize, 1), hits.len);
    try testing.expectEqualStrings("h1", hits[0].id);
    // Snippet should contain [markers] around the matched tokens
    try testing.expect(std.mem.indexOf(u8, hits[0].snippet, "[") != null);
    try testing.expect(std.mem.indexOf(u8, hits[0].snippet, "login") != null);
}

test "searchMessagesFts: filters by session_id" {
    var s = try llmHistorySearchMessagesFtsSetupDb();
    defer {
        s.db.deinit();
        s.threaded.deinit();
    }
    const alloc = testing.allocator;

    try s.db.exec(alloc, "INSERT INTO llm_history (id, session_id, role, response_content) " ++
        "VALUES ('h1','s_a','user','the bug is fixed')", &.{});
    try s.db.exec(alloc, "INSERT INTO llm_history (id, session_id, role, response_content) " ++
        "VALUES ('h2','s_b','user','a different bug exists')", &.{});

    const hits = try searchMessagesFts(alloc, &s.db, "bug", .{
        .session_id = "s_a",
    });
    defer {
        for (hits) |h| {
            var copy = h;
            copy.deinit(alloc);
        }
        alloc.free(hits);
    }

    try testing.expectEqual(@as(usize, 1), hits.len);
    try testing.expectEqualStrings("h1", hits[0].id);
}

test "searchMessagesFts: filters by role" {
    var s = try llmHistorySearchMessagesFtsSetupDb();
    defer {
        s.db.deinit();
        s.threaded.deinit();
    }
    const alloc = testing.allocator;

    try s.db.exec(alloc, "INSERT INTO llm_history (id, session_id, role, response_content) " ++
        "VALUES ('h1','s_1','user','user asked about password reset')", &.{});
    try s.db.exec(alloc, "INSERT INTO llm_history (id, session_id, role, response_content) " ++
        "VALUES ('h2','s_1','assistant','the password reset feature')", &.{});

    const hits = try searchMessagesFts(alloc, &s.db, "password", .{
        .role = "user",
    });
    defer {
        for (hits) |h| {
            var copy = h;
            copy.deinit(alloc);
        }
        alloc.free(hits);
    }

    try testing.expectEqual(@as(usize, 1), hits.len);
    try testing.expectEqualStrings("h1", hits[0].id);
}

test "searchMessagesFts: respects limit" {
    var s = try llmHistorySearchMessagesFtsSetupDb();
    defer {
        s.db.deinit();
        s.threaded.deinit();
    }
    const alloc = testing.allocator;

    var i: usize = 0;
    while (i < 10) : (i += 1) {
        const id_buf = try std.fmt.allocPrint(alloc, "h_{d}", .{i});
        defer alloc.free(id_buf);
        try s.db.exec(alloc, "INSERT INTO llm_history (id, session_id, role, response_content) " ++
            "VALUES (?, 's_1', 'user', 'common keyword here')", &.{id_buf});
    }

    const hits = try searchMessagesFts(alloc, &s.db, "common", .{
        .limit = 3,
    });
    defer {
        for (hits) |h| {
            var copy = h;
            copy.deinit(alloc);
        }
        alloc.free(hits);
    }

    try testing.expectEqual(@as(usize, 3), hits.len);
}

test "searchMessagesFts: returns empty array when no matches" {
    var s = try llmHistorySearchMessagesFtsSetupDb();
    defer {
        s.db.deinit();
        s.threaded.deinit();
    }
    const alloc = testing.allocator;

    try s.db.exec(alloc, "INSERT INTO llm_history (id, session_id, role, response_content) " ++
        "VALUES ('h1','s_1','user','nothing relevant here')", &.{});

    const hits = try searchMessagesFts(alloc, &s.db, "monkeywrench", .{});
    defer alloc.free(hits);

    try testing.expectEqual(@as(usize, 0), hits.len);
}

test "searchMessagesFts: tool_call_id and tool_name surfaced for tool-role hits" {
    var s = try llmHistorySearchMessagesFtsSetupDb();
    defer {
        s.db.deinit();
        s.threaded.deinit();
    }
    const alloc = testing.allocator;

    try s.db.exec(alloc, "INSERT INTO llm_history (id, session_id, role, response_content, " ++
        "tool_call_id, tool_name) " ++
        "VALUES ('h1','s_1','tool','exit code 42','tc_1','bash')", &.{});

    const hits = try searchMessagesFts(alloc, &s.db, "exit code", .{});
    defer {
        for (hits) |h| {
            var copy = h;
            copy.deinit(alloc);
        }
        alloc.free(hits);
    }

    try testing.expectEqual(@as(usize, 1), hits.len);
    try testing.expectEqualStrings("tool", hits[0].role);
    try testing.expectEqualStrings("tc_1", hits[0].tool_call_id.?);
    try testing.expectEqualStrings("bash", hits[0].tool_name.?);
}

test "getCompactedMessages: include_all=true returns live AND compacted rows" {
    var s = try llmHistorySearchMessagesFtsSetupDb();
    defer {
        s.db.deinit();
        s.threaded.deinit();
    }
    const alloc = testing.allocator;

    // Seed: 1 live (is_feed_to_llm=1) + 1 compacted (is_feed_to_llm=0)
    try s.db.exec(alloc, "INSERT INTO llm_history (id, session_id, role, response_content, is_feed_to_llm) " ++
        "VALUES ('live_1','s_full','user','live message',1)", &.{});
    try s.db.exec(alloc, "INSERT INTO llm_history (id, session_id, role, response_content, is_feed_to_llm) " ++
        "VALUES ('compact_1','s_full','assistant','compacted message',0)", &.{});

    // Default behavior (include_all=false): only compacted.
    const compact_only = try getCompactedMessages(alloc, &s.db, "s_full", .{});
    defer {
        for (compact_only) |m| {
            var copy = m;
            copy.deinit(alloc);
        }
        alloc.free(compact_only);
    }
    try testing.expectEqual(@as(usize, 1), compact_only.len);
    try testing.expectEqualStrings("compact_1", compact_only[0].id);

    // include_all=true: both rows.
    const all_rows = try getCompactedMessages(alloc, &s.db, "s_full", .{
        .include_all = true,
    });
    defer {
        for (all_rows) |m| {
            var copy = m;
            copy.deinit(alloc);
        }
        alloc.free(all_rows);
    }
    try testing.expectEqual(@as(usize, 2), all_rows.len);
}

// ────────────────────────────────────────────────────────────────────────
// Regression tests for the since/until bug (historical note: fixed under the
// old global history search; the `created_iso` semantics are unchanged).

test "searchMessagesFts: filters by since using ISO date string (regression for since/until bug)" {
    var s = try llmHistorySearchMessagesFtsSetupDb();
    defer {
        s.db.deinit();
        s.threaded.deinit();
    }
    const alloc = testing.allocator;

    // Seed: two messages at known microsecond timestamps.
    const old_micros: []const u8 = "1780000000000000"; // ~2026-05-29 17:33 UTC
    const new_micros: []const u8 = "1785000000000000"; // ~2026-06-23 12:40 UTC

    // Production code in `saveMessage` computes `created_iso` from
    // `created_at` via libc `localtime_r` + `strftime`.
    try s.db.exec(alloc, "INSERT INTO llm_history (id, session_id, role, response_content, created_at_nano, created_iso) " ++
        "VALUES ('h_old','s1','user','old message',?,datetime(substr(?,1,10),'unixepoch'))", &.{ old_micros, old_micros });
    try s.db.exec(alloc, "INSERT INTO llm_history (id, session_id, role, response_content, created_at_nano, created_iso) " ++
        "VALUES ('h_new','s1','user','new message',?,datetime(substr(?,1,10),'unixepoch'))", &.{ new_micros, new_micros });

    // Compute the ISO date for `new_micros` using the SAME expression the
    // migration uses — that's what `created_iso` will contain.
    var iso_q = try s.db.queryRow(alloc, "SELECT datetime(? / 1000000, 'unixepoch')", &.{new_micros});
    defer iso_q.deinit(alloc);
    const new_iso = iso_q.values[0];

    // FTS match for "message" — both rows match. Filter on since=new_iso
    // should return only `h_new`.
    const hits = try searchMessagesFts(alloc, &s.db, "message", .{
        .since = new_iso,
    });
    defer {
        for (hits) |h| {
            var copy = h;
            copy.deinit(alloc);
        }
        alloc.free(hits);
    }
    try testing.expectEqual(@as(usize, 1), hits.len);
    try testing.expectEqualStrings("h_new", hits[0].id);
    try testing.expectEqual(@as(u32, 1), hits[0].total_count); // only 1 row after filter
}

test "searchMessagesFts: filters by until using ISO date string (regression for since/until bug)" {
    var s = try llmHistorySearchMessagesFtsSetupDb();
    defer {
        s.db.deinit();
        s.threaded.deinit();
    }
    const alloc = testing.allocator;

    const old_micros: []const u8 = "1780000000000000";
    const new_micros: []const u8 = "1785000000000000";

    try s.db.exec(alloc, "INSERT INTO llm_history (id, session_id, role, response_content, created_at_nano, created_iso) " ++
        "VALUES ('h_old','s1','user','old message',?,datetime(substr(?,1,10),'unixepoch'))", &.{ old_micros, old_micros });
    try s.db.exec(alloc, "INSERT INTO llm_history (id, session_id, role, response_content, created_at_nano, created_iso) " ++
        "VALUES ('h_new','s1','user','new message',?,datetime(substr(?,1,10),'unixepoch'))", &.{ new_micros, new_micros });

    // Compute the ISO for `old_micros` — `until=old_iso` should keep only h_old.
    // Use the same `substr(_,1,10)` expression as the inserted rows so
    // the lex comparison matches exactly.
    var iso_q = try s.db.queryRow(alloc, "SELECT datetime(substr(? ,1, 10), 'unixepoch')", &.{old_micros});
    defer iso_q.deinit(alloc);
    const old_iso = iso_q.values[0];

    const hits = try searchMessagesFts(alloc, &s.db, "message", .{
        .until = old_iso,
    });
    defer {
        for (hits) |h| {
            var copy = h;
            copy.deinit(alloc);
        }
        alloc.free(hits);
    }
    try testing.expectEqual(@as(usize, 1), hits.len);
    try testing.expectEqualStrings("h_old", hits[0].id);
}

test "searchMessagesFts: since AND until together produce a date range (regression)" {
    var s = try llmHistorySearchMessagesFtsSetupDb();
    defer {
        s.db.deinit();
        s.threaded.deinit();
    }
    const alloc = testing.allocator;

    const old_micros: []const u8 = "1780000000000000";
    const mid_micros: []const u8 = "1783000000000000";
    const new_micros: []const u8 = "1785000000000000";

    try s.db.exec(alloc, "INSERT INTO llm_history (id, session_id, role, response_content, created_at_nano, created_iso) " ++
        "VALUES ('h_old','s1','user','old message',?,datetime(substr(?,1,10),'unixepoch'))", &.{ old_micros, old_micros });
    try s.db.exec(alloc, "INSERT INTO llm_history (id, session_id, role, response_content, created_at_nano, created_iso) " ++
        "VALUES ('h_mid','s1','user','mid message',?,datetime(substr(?,1,10),'unixepoch'))", &.{ mid_micros, mid_micros });
    try s.db.exec(alloc, "INSERT INTO llm_history (id, session_id, role, response_content, created_at_nano, created_iso) " ++
        "VALUES ('h_new','s1','user','new message',?,datetime(substr(?,1,10),'unixepoch'))", &.{ new_micros, new_micros });

    // Use the same substr(_,1,10) expression as the inserted rows so the
    // lex comparison matches exactly.
    var iso_q = try s.db.queryRow(alloc,
        \\SELECT datetime(substr(? ,1,10), 'unixepoch') AS since_iso,
        \\       datetime(substr(? ,1,10), 'unixepoch') AS until_iso
    , &.{ mid_micros, new_micros });
    defer iso_q.deinit(alloc);
    const since_iso = iso_q.values[0];
    const until_iso = iso_q.values[1];

    const hits = try searchMessagesFts(alloc, &s.db, "message", .{
        .since = since_iso,
        .until = until_iso,
    });
    defer {
        for (hits) |h| {
            var copy = h;
            copy.deinit(alloc);
        }
        alloc.free(hits);
    }
    try testing.expectEqual(@as(usize, 2), hits.len);
    // Expectation: h_mid and h_new (the "since..until" inclusive window)
    // — but order is by rank, which is the same as no ORDER BY since
    // the MATCH score ties. Check that both are present.
    var ids: [2][]const u8 = undefined;
    for (hits, 0..) |h, i| ids[i] = h.id;
    // Both h_mid and h_new should be present (h_old should not).
    try testing.expect(std.mem.indexOf(u8, ids[0], "h_old") == null or
        std.mem.indexOf(u8, ids[1], "h_old") == null);
}

// ────────────────────────────────────────────────────────────────────────
// created_at shape The `since`/`until` filters above take an ISO date string,
// so the `created_at` we hand back has to be an ISO string too — returning

test "searchMessagesFts: created_at is a readable ISO timestamp, not a nanosecond epoch" {
    var s = try llmHistorySearchMessagesFtsSetupDb();
    defer {
        s.db.deinit();
        s.threaded.deinit();
    }
    const alloc = testing.allocator;

    // Seed both columns the way production writes them: `created_at_nano`
    // is a 19-digit nanosecond epoch, `created_iso` is the local-time
    // string `saveMessage` populates.
    const nano: []const u8 = "1790706338823948836";
    const iso: []const u8 = "2026-09-30 19:53:35";
    try s.db.exec(alloc, "INSERT INTO llm_history (id, session_id, role, response_content, created_at_nano, created_iso) " ++
        "VALUES ('h_ts','s1','user','readable timestamp check',?,?)", &.{ nano, iso });

    const hits = try searchMessagesFts(alloc, &s.db, "readable timestamp", .{});
    defer freeHits(alloc, hits);

    try testing.expectEqual(@as(usize, 1), hits.len);

    const created_at = hits[0].created_at;
    // `YYYY-MM-DD HH:MM:SS`: dashes at 4/7, space at 10, colons at 13/16,
    // digits everywhere else.
    const shape_ok = created_at.len == 19 and
        std.ascii.isDigit(created_at[0]) and std.ascii.isDigit(created_at[1]) and
        std.ascii.isDigit(created_at[2]) and std.ascii.isDigit(created_at[3]) and
        created_at[4] == '-' and
        std.ascii.isDigit(created_at[5]) and std.ascii.isDigit(created_at[6]) and
        created_at[7] == '-' and
        std.ascii.isDigit(created_at[8]) and std.ascii.isDigit(created_at[9]) and
        created_at[10] == ' ' and
        std.ascii.isDigit(created_at[11]) and std.ascii.isDigit(created_at[12]) and
        created_at[13] == ':' and
        std.ascii.isDigit(created_at[14]) and std.ascii.isDigit(created_at[15]) and
        created_at[16] == ':' and
        std.ascii.isDigit(created_at[17]) and std.ascii.isDigit(created_at[18]);

    if (!shape_ok) {
        std.debug.print(
            "\nsearchMessagesFts created_at = \"{s}\" — expected YYYY-MM-DD HH:MM:SS, not a nanosecond epoch\n",
            .{created_at},
        );
    }
    try testing.expect(shape_ok);
    try testing.expectEqualStrings(iso, created_at);
    try testing.expect(!std.mem.eql(u8, created_at, nano));
}

// ════════════════════════════════════════════════════════════════════════════
// Inlined from llm_history_compacted_messages_test.zig
// ════════════════════════════════════════════════════════════════════════════

fn llmHistoryCompactedMessagesSetupDb() !struct {
    db: database.Db,
    threaded: std.Io.Threaded,
} {
    const alloc = testing.allocator;
    var threaded = std.Io.Threaded.init(alloc, .{});
    errdefer threaded.deinit();
    const io = threaded.io();
    var db: database.Db = .{};
    errdefer db.deinit();
    try test_db.openMemory(&db, io);

    try db.exec(alloc,
        \\CREATE TABLE llm_history (
        \\  id TEXT PRIMARY KEY,
        \\  session_id TEXT NOT NULL,
        \\  model TEXT,
        \\  response_content TEXT,
        \\  role TEXT,
        \\  tool_call_id TEXT,
        \\  tool_name TEXT,
        \\  is_feed_to_llm INTEGER DEFAULT 1,
        \\  agent TEXT,
        \\  created_at_nano TEXT DEFAULT (datetime('now')),
        \\  -- Mirrors Migration 059 in production: a regular TEXT column
        \\  -- populated by INSERT/UPDATE triggers. We CAN'T use a STORED
        \\  -- GENERATED ALWAYS AS column here because `datetime(...,
        \\  -- 'localtime')` is non-deterministic (depends on the system
        \\  -- timezone) — SQLite silently DROPS such columns from CREATE
        \\  -- TABLE / ALTER TABLE ADD COLUMN. Production uses triggers for
        \\  -- the same reason. The since/until filters on
        \\  -- getCompactedMessages bind to this column, so the test
        \\  -- schema must include it. The llmHistoryCompactedMessagesSeedMessage helper below
        \\  -- explicitly populates `created_iso` (mirrors the
        \\  -- application code in `saveMessage`).
        \\  created_iso TEXT,
        \\  -- Anthropic cache breakdown columns (Migration 074). The
        \\  -- saveMessage INSERT must reference both columns, so the
        \\  -- test fixture mirrors the production schema even when the
        \\  -- test doesn't read them.
        \\  cache_creation_input_tokens INTEGER DEFAULT 0,
        \\  cache_read_input_tokens INTEGER DEFAULT 0
        \\)
    , &.{});
    return .{ .db = db, .threaded = threaded };
}

fn llmHistoryCompactedMessagesTeardownDb(s: *@TypeOf(llmHistoryCompactedMessagesSetupDb() catch @panic("llmHistoryCompactedMessagesSetupDb failed in the llm_history test fixture"))) void {
    s.db.deinit();
    s.threaded.deinit();
}

fn llmHistoryCompactedMessagesSeedMessage(
    alloc: std.mem.Allocator,
    db: *database.Db,
    id: []const u8,
    sess: []const u8,
    role: []const u8,
    content: []const u8,
    is_feed: u8,
    created_at: []const u8,
) !void {
    const feed_str = if (is_feed == 1) "1" else "0";

    // `created_at` is either: - A microsecond timestamp string (e.g.
    // "1785000000000000"), OR - A pre-formatted ISO localtime string (e.g.
    // "2025-01-01 00:01:00").
    var created_iso_buf: [20]u8 = undefined;
    const created_iso_len: usize = blk: {
        if (created_at.len >= 10 and std.mem.indexOfScalar(u8, created_at, '-') == null) {
            // Looks like a microsecond integer — convert via SQLite.
            var q = try db.queryRow(alloc, "SELECT datetime(? / 1000000, 'unixepoch')", &.{created_at});
            defer q.deinit(alloc);
            const iso = q.values[0];
            const len = iso.len;
            if (len > created_iso_buf.len) return error.TimestampTooLong;
            @memcpy(created_iso_buf[0..len], iso);
            break :blk len;
        }
        // Already ISO-formatted (e.g. tests using literal "YYYY-MM-DD HH:MM:SS").
        if (created_at.len > created_iso_buf.len) return error.TimestampTooLong;
        @memcpy(created_iso_buf[0..created_at.len], created_at);
        break :blk created_at.len;
    };
    const created_iso: []const u8 = created_iso_buf[0..created_iso_len];

    const sql =
        \\INSERT INTO llm_history (id, session_id, role, response_content, is_feed_to_llm, created_at_nano, created_iso)
        \\VALUES (?, ?, ?, ?, ?, ?, ?)
    ;
    try db.exec(alloc, sql, &.{ id, sess, role, content, feed_str, created_at, created_iso });
}

test "getCompactedMessages: returns only is_feed_to_llm=0 messages for session" {
    var s = try llmHistoryCompactedMessagesSetupDb();
    defer llmHistoryCompactedMessagesTeardownDb(&s);
    const alloc = testing.allocator;

    try llmHistoryCompactedMessagesSeedMessage(alloc, &s.db, "h1", "sess_1", "user", "Fix bug", 1, "2025-01-01 00:00:00");
    try llmHistoryCompactedMessagesSeedMessage(alloc, &s.db, "h2", "sess_1", "assistant", "OK", 1, "2025-01-01 00:01:00");
    try llmHistoryCompactedMessagesSeedMessage(alloc, &s.db, "h3", "sess_1", "user", "More", 0, "2025-01-01 00:02:00");
    try llmHistoryCompactedMessagesSeedMessage(alloc, &s.db, "h4", "sess_1", "assistant", "Done", 0, "2025-01-01 00:03:00");
    try llmHistoryCompactedMessagesSeedMessage(alloc, &s.db, "h5", "sess_2", "user", "other session", 0, "2025-01-01 00:04:00");

    const results = try getCompactedMessages(alloc, &s.db, "sess_1", .{});
    defer {
        for (results) |m| {
            var copy = m;
            copy.deinit(alloc);
        }
        alloc.free(results);
    }

    try testing.expectEqual(@as(usize, 2), results.len);
    try testing.expectEqualStrings("h3", results[0].id);
    try testing.expectEqualStrings("h4", results[1].id);
}

test "getCompactedMessages: respects limit" {
    var s = try llmHistoryCompactedMessagesSetupDb();
    defer llmHistoryCompactedMessagesTeardownDb(&s);
    const alloc = testing.allocator;
    var i: usize = 0;
    while (i < 30) : (i += 1) {
        var buf: [16]u8 = undefined;
        const id = try std.fmt.bufPrint(&buf, "h{d}", .{i});
        try llmHistoryCompactedMessagesSeedMessage(alloc, &s.db, id, "sess_1", "user", "msg", 0, "2025-01-01 00:00:00");
    }
    const results = try getCompactedMessages(alloc, &s.db, "sess_1", .{ .limit = 5 });
    defer {
        for (results) |m| {
            var copy = m;
            copy.deinit(alloc);
        }
        alloc.free(results);
    }
    try testing.expectEqual(@as(usize, 5), results.len);
}

test "getCompactedMessages: filters by message_ids when provided" {
    var s = try llmHistoryCompactedMessagesSetupDb();
    defer llmHistoryCompactedMessagesTeardownDb(&s);
    const alloc = testing.allocator;
    try llmHistoryCompactedMessagesSeedMessage(alloc, &s.db, "h1", "sess_1", "user", "A", 0, "2025-01-01 00:00:00");
    try llmHistoryCompactedMessagesSeedMessage(alloc, &s.db, "h2", "sess_1", "user", "B", 0, "2025-01-01 00:01:00");
    try llmHistoryCompactedMessagesSeedMessage(alloc, &s.db, "h3", "sess_1", "user", "C", 0, "2025-01-01 00:02:00");

    const ids = [_][]const u8{ "h1", "h3" };
    const results = try getCompactedMessages(alloc, &s.db, "sess_1", .{ .message_ids = &ids });
    defer {
        for (results) |m| {
            var copy = m;
            copy.deinit(alloc);
        }
        alloc.free(results);
    }
    try testing.expectEqual(@as(usize, 2), results.len);
    try testing.expectEqualStrings("h1", results[0].id);
    try testing.expectEqualStrings("h3", results[1].id);
}

test "getCompactedMessages: returns empty slice when session has no compacted messages" {
    var s = try llmHistoryCompactedMessagesSetupDb();
    defer llmHistoryCompactedMessagesTeardownDb(&s);
    const alloc = testing.allocator;
    try llmHistoryCompactedMessagesSeedMessage(alloc, &s.db, "h1", "sess_1", "user", "active", 1, "2025-01-01 00:00:00");

    const results = try getCompactedMessages(alloc, &s.db, "sess_1", .{});
    defer {
        for (results) |m| {
            var copy = m;
            copy.deinit(alloc);
        }
        alloc.free(results);
    }
    try testing.expectEqual(@as(usize, 0), results.len);
}

// ────────────────────────────────────────────────────────────────────────
// Regression tests for the since/until bug (historical note: fixed under the
// old global history search; the `created_iso` semantics are unchanged).

test "getCompactedMessages: filters by since using ISO date string (regression)" {
    var s = try llmHistoryCompactedMessagesSetupDb();
    defer llmHistoryCompactedMessagesTeardownDb(&s);
    const alloc = testing.allocator;

    // Two compacted messages at known microsecond timestamps. They
    // compare against `is_feed_to_llm=0` so they pass the default filter.
    const old_micros: []const u8 = "1780000000000000";
    const new_micros: []const u8 = "1785000000000000";
    try llmHistoryCompactedMessagesSeedMessage(alloc, &s.db, "h_old", "sess_1", "user", "old", 0, old_micros);
    try llmHistoryCompactedMessagesSeedMessage(alloc, &s.db, "h_new", "sess_1", "user", "new", 0, new_micros);

    // Compute the ISO for `new_micros` using the SAME expression the
    // migration uses — that's what `created_iso` will contain.
    var iso_q = try s.db.queryRow(alloc, "SELECT datetime(? / 1000000, 'unixepoch')", &.{new_micros});
    defer iso_q.deinit(alloc);
    const new_iso = iso_q.values[0];

    const results = try getCompactedMessages(alloc, &s.db, "sess_1", .{
        .since = new_iso,
    });
    defer {
        for (results) |m| {
            var copy = m;
            copy.deinit(alloc);
        }
        alloc.free(results);
    }
    try testing.expectEqual(@as(usize, 1), results.len);
    try testing.expectEqualStrings("h_new", results[0].id);
    try testing.expectEqual(@as(u32, 1), results[0].total_count);
}

test "getCompactedMessages: filters by until using ISO date string (regression)" {
    var s = try llmHistoryCompactedMessagesSetupDb();
    defer llmHistoryCompactedMessagesTeardownDb(&s);
    const alloc = testing.allocator;

    const old_micros: []const u8 = "1780000000000000";
    const new_micros: []const u8 = "1785000000000000";
    try llmHistoryCompactedMessagesSeedMessage(alloc, &s.db, "h_old", "sess_1", "user", "old", 0, old_micros);
    try llmHistoryCompactedMessagesSeedMessage(alloc, &s.db, "h_new", "sess_1", "user", "new", 0, new_micros);

    var iso_q = try s.db.queryRow(alloc, "SELECT datetime(? / 1000000, 'unixepoch')", &.{old_micros});
    defer iso_q.deinit(alloc);
    const old_iso = iso_q.values[0];

    const results = try getCompactedMessages(alloc, &s.db, "sess_1", .{
        .until = old_iso,
    });
    defer {
        for (results) |m| {
            var copy = m;
            copy.deinit(alloc);
        }
        alloc.free(results);
    }
    try testing.expectEqual(@as(usize, 1), results.len);
    try testing.expectEqualStrings("h_old", results[0].id);
}

test "getCompactedMessages: since AND until together produce a date range (regression)" {
    var s = try llmHistoryCompactedMessagesSetupDb();
    defer llmHistoryCompactedMessagesTeardownDb(&s);
    const alloc = testing.allocator;

    const old_micros: []const u8 = "1780000000000000";
    const mid_micros: []const u8 = "1783000000000000";
    const new_micros: []const u8 = "1785000000000000";
    try llmHistoryCompactedMessagesSeedMessage(alloc, &s.db, "h_old", "sess_1", "user", "old", 0, old_micros);
    try llmHistoryCompactedMessagesSeedMessage(alloc, &s.db, "h_mid", "sess_1", "user", "mid", 0, mid_micros);
    try llmHistoryCompactedMessagesSeedMessage(alloc, &s.db, "h_new", "sess_1", "user", "new", 0, new_micros);

    var iso_q = try s.db.queryRow(alloc,
        \\SELECT datetime(? / 1000000, 'unixepoch') AS since_iso,
        \\       datetime(? / 1000000, 'unixepoch') AS until_iso
    , &.{ mid_micros, new_micros });
    defer iso_q.deinit(alloc);
    const since_iso = iso_q.values[0];
    const until_iso = iso_q.values[1];

    const results = try getCompactedMessages(alloc, &s.db, "sess_1", .{
        .since = since_iso,
        .until = until_iso,
    });
    defer {
        for (results) |m| {
            var copy = m;
            copy.deinit(alloc);
        }
        alloc.free(results);
    }
    // Expect 2: h_mid + h_new (inclusive window). h_old should be excluded.
    try testing.expectEqual(@as(usize, 2), results.len);
    var found_old = false;
    for (results) |m| {
        if (std.mem.eql(u8, m.id, "h_old")) found_old = true;
    }
    try testing.expect(!found_old);
}

test "saveMessage: writes a correct-year (2026-ish) created_iso from current time" {
    // Regression check for the year-58,507 bug. Pre-fix `saveMessage` passed
    // raw nanoseconds to the ISO conversion helper, producing year 58,507.
    const alloc = testing.allocator;
    var threaded = std.Io.Threaded.init(alloc, .{});
    defer threaded.deinit();
    const io = threaded.io();
    var db: database.Db = .{};
    defer db.deinit();
    try test_db.openMemory(&db, io);

    try db.exec(alloc,
        \\CREATE TABLE llm_history (
        \\    id TEXT PRIMARY KEY,
        \\    session_id TEXT NOT NULL,
        \\    model TEXT,
        \\    response_content TEXT,
        \\    finish_reason TEXT,
        \\    role TEXT,
        \\    tool_calls_json TEXT,
        \\    tool_call_id TEXT,
        \\    reasoning_content TEXT,
        \\    reasoning_id TEXT,
        \\    reasoning_encrypted_content TEXT,
        \\    is_feed_to_llm INTEGER DEFAULT 1,
        \\    agent TEXT,
        \\    loop_index INTEGER,
        \\    temperature REAL,
        \\    is_thinking INTEGER,
        \\    created_at_nano TEXT,
        \\    created_iso TEXT,
        \\    parent_session_id TEXT,
        \\    parent_id TEXT,
        \\    prompt_tokens INTEGER,
        \\    completion_tokens INTEGER,
        \\    total_tokens INTEGER,
        \\    cache_creation_input_tokens INTEGER DEFAULT 0,
        \\    cache_read_input_tokens INTEGER DEFAULT 0,
        \\    is_input INTEGER,
        \\    is_output INTEGER,
        \\    tool_name TEXT,
        \\    diffview_before TEXT,
        \\    diffview_after TEXT,
        \\    image_url TEXT,
        \\    video_url TEXT
        \\)
    , &.{});
    try db.exec(alloc,
        \\CREATE TABLE sessions (
        \\    id TEXT PRIMARY KEY,
        \\    cwd TEXT,
        \\    updated_at TEXT
        \\)
    , &.{});

    try saveMessage(alloc, io, &db, .{
        .session_id = "sess_regression",
        .model = "test",
        .cwd = "/tmp",
        .content = "hello",
        .reasoning_content = null,
        .role = "user",
        .finish_reason = null,
        .tool_calls = null,
        .tool_call_id = null,
        .agent_name = "test",
        .loop_index = 0,
        .temperature = 0.0,
        .is_thinking = false,
        .is_input = true,
        .is_output = false,
    });

    var q = try db.query(alloc, "SELECT created_iso FROM llm_history WHERE session_id = 'sess_regression'", &.{});
    defer q.deinit();
    const row = (try q.next()) orelse return error.RowMissing;
    defer row.deinit(alloc);

    // Year must be in the 2020s, not 58507.
    try testing.expect(std.mem.indexOf(u8, row.values[0], "20") != null);
    try testing.expect(std.mem.indexOf(u8, row.values[0], "58507") == null);
}

test "saveMessage: created_at column is stored as Unix microseconds (length <= 17)" {
    // Regression check: saveMessage must store `created_at` as microseconds
    // (16 digits for year 2026).
    const alloc = testing.allocator;
    var threaded = std.Io.Threaded.init(alloc, .{});
    defer threaded.deinit();
    const io = threaded.io();
    var db: database.Db = .{};
    defer db.deinit();
    try test_db.openMemory(&db, io);

    try db.exec(alloc,
        \\CREATE TABLE llm_history (
        \\    id TEXT PRIMARY KEY,
        \\    session_id TEXT NOT NULL,
        \\    model TEXT,
        \\    response_content TEXT,
        \\    finish_reason TEXT,
        \\    role TEXT,
        \\    tool_calls_json TEXT,
        \\    tool_call_id TEXT,
        \\    reasoning_content TEXT,
        \\    reasoning_id TEXT,
        \\    reasoning_encrypted_content TEXT,
        \\    is_feed_to_llm INTEGER DEFAULT 1,
        \\    agent TEXT,
        \\    loop_index INTEGER,
        \\    temperature REAL,
        \\    is_thinking INTEGER,
        \\    created_at_nano TEXT,
        \\    created_iso TEXT,
        \\    parent_session_id TEXT,
        \\    parent_id TEXT,
        \\    prompt_tokens INTEGER,
        \\    completion_tokens INTEGER,
        \\    total_tokens INTEGER,
        \\    cache_creation_input_tokens INTEGER DEFAULT 0,
        \\    cache_read_input_tokens INTEGER DEFAULT 0,
        \\    is_input INTEGER,
        \\    is_output INTEGER,
        \\    tool_name TEXT,
        \\    diffview_before TEXT,
        \\    diffview_after TEXT,
        \\    image_url TEXT,
        \\    video_url TEXT
        \\)
    , &.{});
    try db.exec(alloc,
        \\CREATE TABLE sessions (
        \\    id TEXT PRIMARY KEY,
        \\    cwd TEXT,
        \\    updated_at TEXT
        \\)
    , &.{});

    try saveMessage(alloc, io, &db, .{
        .session_id = "sess_micros",
        .model = "test",
        .cwd = "/tmp",
        .content = "hello",
        .reasoning_content = null,
        .role = "user",
        .finish_reason = null,
        .tool_calls = null,
        .tool_call_id = null,
        .agent_name = "test",
        .loop_index = 0,
        .temperature = 0.0,
        .is_thinking = false,
        .is_input = true,
        .is_output = false,
    });

    var q = try db.query(alloc, "SELECT created_at_nano FROM llm_history WHERE session_id = 'sess_micros'", &.{});
    defer q.deinit();
    const row = (try q.next()) orelse return error.RowMissing;
    defer row.deinit(alloc);

    // Microsecond format is at most 17 digits for any plausible
    // timestamp (year ~9999). 19 digits = nanoseconds, which is the
    // bug we're guarding against.
    try testing.expect(row.values[0].len <= 19);
}

// ════════════════════════════════════════════════════════════════════════════
// Inlined from llm_history_tool_call_loading_test.zig
// ════════════════════════════════════════════════════════════════════════════

fn llmHistoryToolCallLoadingSetupDb() !TestCtx {
    const alloc = testing.allocator;
    var threaded = std.Io.Threaded.init(alloc, .{});
    errdefer threaded.deinit();
    const io = threaded.io();
    var db: database.Db = .{};
    errdefer db.deinit();
    try test_db.openMemory(&db, io);

    // Walk every production migration (001 → 068) so the schema matches
    // production. Manual schema setup drifts the moment a migration lands;
    // see project memory `llm-history-test-use-migrations-module.md`.
    var manager = migration.MigrationManager.init(alloc, &db);
    defer manager.deinit();
    try migration.registerAllMigrations(&manager);
    try manager.runMigrations();

    return .{ .db = db, .threaded = threaded, .alloc = alloc };
}

fn llmHistoryToolCallLoadingTeardown(ctx: *TestCtx) void {
    ctx.db.deinit();
    ctx.threaded.deinit();
}

/// Insert a session row so we can FK-reference it in tests below.
/// The production schema (after all migrations) requires a
/// `sessions` row before llm_history rows reference its id.
fn llmHistoryToolCallLoadingCreateSession(ctx: *TestCtx, session_id: []const u8) !void {
    var buf: [256]u8 = undefined;
    const stmt = try std.fmt.bufPrint(buf[0..], "INSERT INTO sessions (id, name) VALUES ('{s}', 'test-session')", .{session_id});
    try ctx.db.exec(ctx.alloc, stmt, &.{});
}

test "saveToolResultPlaceholder inserts row with is_loading=1 and empty content" {
    var ctx = try llmHistoryToolCallLoadingSetupDb();
    defer llmHistoryToolCallLoadingTeardown(&ctx);
    try llmHistoryToolCallLoadingCreateSession(&ctx, "sess_1");

    const opts = SaveToolResultPlaceholderOptions{
        .session_id = "sess_1",
        .model = "test-model",
        .tool_call_id = "tcA",
        .tool_name = "bash",
        .loop_index = 0,
    };
    const new_id = try saveToolResultPlaceholder(ctx.alloc, ctx.threaded.io(), &ctx.db, opts);
    defer ctx.alloc.free(new_id);

    var q = try ctx.db.query(ctx.alloc, "SELECT response_content, is_loading, is_feed_to_llm " ++
        "FROM llm_history WHERE tool_call_id = ?", &.{"tcA"});
    defer q.deinit();
    const row = (try q.next()) orelse return error.RowMissing;
    defer row.deinit(ctx.alloc);
    try testing.expectEqualStrings("", row.values[0]);
    try testing.expectEqualStrings("1", row.values[1]);
    try testing.expectEqualStrings("1", row.values[2]);
}

test "saveToolResultPlaceholder enforces the UNIQUE INDEX on tool_call_id" {
    var ctx = try llmHistoryToolCallLoadingSetupDb();
    defer llmHistoryToolCallLoadingTeardown(&ctx);
    try llmHistoryToolCallLoadingCreateSession(&ctx, "sess_1");

    const opts = SaveToolResultPlaceholderOptions{
        .session_id = "sess_1",
        .model = "test-model",
        .tool_call_id = "tcA",
        .tool_name = "bash",
        .loop_index = 0,
    };
    const id1 = try saveToolResultPlaceholder(ctx.alloc, ctx.threaded.io(), &ctx.db, opts);
    defer ctx.alloc.free(id1);

    // Second placeholder with the SAME tool_call_id — must fail.
    const id2 = saveToolResultPlaceholder(ctx.alloc, ctx.threaded.io(), &ctx.db, opts);
    try testing.expectError(error.ExecuteFailed, id2);
}

test "saveToolResultPlaceholder allows multiple empty tool_call_id rows (assistant message shape)" {
    // The partial UNIQUE INDEX excludes empty-string tool_call_ids (`WHERE
    // tool_call_id IS NOT NULL AND tool_call_id != ''`).
    var ctx = try llmHistoryToolCallLoadingSetupDb();
    defer llmHistoryToolCallLoadingTeardown(&ctx);
    try llmHistoryToolCallLoadingCreateSession(&ctx, "sess_1");

    const opts = SaveToolResultPlaceholderOptions{
        .session_id = "sess_1",
        .model = "test-model",
        .tool_call_id = "",
        .tool_name = "bash",
        .loop_index = 0,
    };
    const id1 = try saveToolResultPlaceholder(ctx.alloc, ctx.threaded.io(), &ctx.db, opts);
    defer ctx.alloc.free(id1);
    const id2 = try saveToolResultPlaceholder(ctx.alloc, ctx.threaded.io(), &ctx.db, opts);
    defer ctx.alloc.free(id2);
}

test "updateToolResultById on a non-existent tool_call_id is a no-op (no error)" {
    var ctx = try llmHistoryToolCallLoadingSetupDb();
    defer llmHistoryToolCallLoadingTeardown(&ctx);

    // No pre-existing placeholder — the UPDATE must be a no-op,
    // returning Ok(()) with 0 rows affected.
    try updateToolResultById(ctx.alloc, ctx.threaded.io(), &ctx.db, "tc_ghost", .{
        .content = "should be discarded",
        .diffview_before = null,
        .diffview_after = null,
    });

    var q = try ctx.db.query(ctx.alloc, "SELECT 1 FROM llm_history WHERE tool_call_id = ?", &.{"tc_ghost"});
    defer q.deinit();
    try testing.expect((try q.next()) == null);
}

test "resolveStaleLoadingToolResults replaces all stranded placeholders with interrupted" {
    var ctx = try llmHistoryToolCallLoadingSetupDb();
    defer llmHistoryToolCallLoadingTeardown(&ctx);
    try llmHistoryToolCallLoadingCreateSession(&ctx, "sess_1");

    // Insert 3 stranded placeholders.
    for ([_][]const u8{ "tcA", "tcB", "tcC" }) |tc| {
        const opts = SaveToolResultPlaceholderOptions{
            .session_id = "sess_1",
            .model = "test-model",
            .tool_call_id = tc,
            .tool_name = "bash",
            .loop_index = 0,
        };
        const id = try saveToolResultPlaceholder(ctx.alloc, ctx.threaded.io(), &ctx.db, opts);
        defer ctx.alloc.free(id);
    }

    // Resolve them.
    try resolveStaleLoadingToolResults(ctx.alloc, &ctx.db, "sess_1");

    // All 3 should now have is_loading=0 and an interrupted-style content.
    for ([_][]const u8{ "tcA", "tcB", "tcC" }) |tc| {
        var q = try ctx.db.query(ctx.alloc, "SELECT response_content, is_loading FROM llm_history WHERE tool_call_id = ?", &.{tc});
        defer q.deinit();
        const row = (try q.next()) orelse return error.RowMissing;
        defer row.deinit(ctx.alloc);
        try testing.expectEqualStrings("0", row.values[1]);
        try testing.expect(std.mem.indexOf(u8, row.values[0], "interrupted") != null);
        try testing.expect(std.mem.indexOf(u8, row.values[0], "retry") != null);
    }
}

test "resolveStaleLoadingToolResults only touches the target session" {
    var ctx = try llmHistoryToolCallLoadingSetupDb();
    defer llmHistoryToolCallLoadingTeardown(&ctx);
    try llmHistoryToolCallLoadingCreateSession(&ctx, "sess_1");
    try llmHistoryToolCallLoadingCreateSession(&ctx, "sess_2");

    // Insert a stranded placeholder in each session.
    const opts1 = SaveToolResultPlaceholderOptions{
        .session_id = "sess_1",
        .model = "test-model",
        .tool_call_id = "tc_sess_1_x",
        .tool_name = "bash",
        .loop_index = 0,
    };
    const id1 = try saveToolResultPlaceholder(ctx.alloc, ctx.threaded.io(), &ctx.db, opts1);
    defer ctx.alloc.free(id1);

    const opts2 = SaveToolResultPlaceholderOptions{
        .session_id = "sess_2",
        .model = "test-model",
        .tool_call_id = "tc_sess_2_y",
        .tool_name = "bash",
        .loop_index = 0,
    };
    const id2 = try saveToolResultPlaceholder(ctx.alloc, ctx.threaded.io(), &ctx.db, opts2);
    defer ctx.alloc.free(id2);

    // Resolve only sess_1.
    try resolveStaleLoadingToolResults(ctx.alloc, &ctx.db, "sess_1");

    // sess_1:tc_sess_1_x is interrupted.
    var q1 = try ctx.db.query(ctx.alloc, "SELECT response_content, is_loading FROM llm_history " ++
        "WHERE session_id = ? AND tool_call_id = ?", &.{ "sess_1", "tc_sess_1_x" });
    defer q1.deinit();
    const row1 = (try q1.next()) orelse return error.RowMissing;
    defer row1.deinit(ctx.alloc);
    try testing.expectEqualStrings("0", row1.values[1]);
    try testing.expect(std.mem.indexOf(u8, row1.values[0], "interrupted") != null);

    // sess_2:tc_sess_2_y is still is_loading=1 with empty content.
    var q2 = try ctx.db.query(ctx.alloc, "SELECT is_loading, response_content FROM llm_history " ++
        "WHERE session_id = ? AND tool_call_id = ?", &.{ "sess_2", "tc_sess_2_y" });
    defer q2.deinit();
    const row2 = (try q2.next()) orelse return error.RowMissing;
    defer row2.deinit(ctx.alloc);
    try testing.expectEqualStrings("1", row2.values[0]);
    try testing.expectEqualStrings("", row2.values[1]);
}

// ════════════════════════════════════════════════════════════════════════════
// Inlined from llm_history_worker_info_test.zig
// ════════════════════════════════════════════════════════════════════════════

/// Open a fresh in-memory sqlite DB with the minimum schema needed for
/// `getActiveWorker` + `getWorkerBySessionId` (the `worker` + `sessions`
/// tables, the latter with `git_worktree_cwd` from Migration 046).
fn llmHistoryWorkerInfoSetupDb() !struct {
    db: database.Db,
    threaded: std.Io.Threaded,
} {
    const alloc = testing.allocator;
    var threaded = std.Io.Threaded.init(alloc, .{});
    errdefer threaded.deinit();
    const io = threaded.io();

    var db: database.Db = .{};
    errdefer db.deinit();
    try test_db.openMemory(&db, io);

    // Minimal `sessions` schema (matches the columns touched by
    // `getActiveWorker`'s JOIN). `git_worktree_cwd` (Migration 046)
    // is the column we're exercising — it is TEXT, NULLable.
    try db.exec(alloc,
        \\CREATE TABLE sessions (
        \\    id TEXT PRIMARY KEY,
        \\    name TEXT NOT NULL DEFAULT '',
        \\    status TEXT NOT NULL DEFAULT 'active',
        \\    cwd TEXT,
        \\    git_worktree_cwd TEXT,
        \\    selected_profile_model TEXT
        \\)
    , &.{});

    // Worker table — the full canonical schema.
    try db.exec(alloc,
        \\CREATE TABLE worker (
        \\    id TEXT PRIMARY KEY,
        \\    session_id TEXT NOT NULL,
        \\    working_directory TEXT,
        \\    last_activity_nano BIGINT DEFAULT (strftime('%s', 'now')),
        \\    last_activity_description TEXT,
        \\    created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP
        \\)
    , &.{});

    return .{ .db = db, .threaded = threaded };
}

// ─── Test 1: getActiveWorker pulls git_worktree_cwd from joined session ─

test "getActiveWorker returns git_worktree_cwd from joined sessions row" {
    const alloc = testing.allocator;
    var ctx = try llmHistoryWorkerInfoSetupDb();
    defer ctx.db.deinit();
    defer ctx.threaded.deinit();

    // Insert a session that has a bound worktree (Migration 046 semantics).
    try ctx.db.exec(alloc, "INSERT INTO sessions (id, name, git_worktree_cwd) VALUES ('s1', 'test', '/home/me/.worktrees/feature-x')", &.{});
    // Insert a worker row pointing at that session.
    try ctx.db.exec(alloc, "INSERT INTO worker (id, session_id, working_directory, last_activity_description) " ++
        "VALUES ('w1', 's1', '/home/me', 'working on the feature')", &.{});

    const workers = try getActiveWorker(alloc, &ctx.db);
    defer {
        for (workers) |*w| w.deinit(alloc);
        alloc.free(workers);
    }

    try testing.expectEqual(@as(usize, 1), workers.len);
    try testing.expectEqualStrings("s1", workers[0].session_id);
    try testing.expectEqualStrings("/home/me", workers[0].working_directory);
    try testing.expectEqualStrings("working on the feature", workers[0].last_activity_description);
    try testing.expectEqualStrings("/home/me/.worktrees/feature-x", workers[0].git_worktree_cwd);
}

// ─── Test 2: LEFT JOIN returns empty string when session has no worktree ─

test "getActiveWorker returns empty string when session row has NULL git_worktree_cwd" {
    const alloc = testing.allocator;
    var ctx = try llmHistoryWorkerInfoSetupDb();
    defer ctx.db.deinit();
    defer ctx.threaded.deinit();

    // Session exists but has no git_worktree_cwd (NULL).
    try ctx.db.exec(alloc, "INSERT INTO sessions (id, name) VALUES ('s1', 'test')", &.{});
    try ctx.db.exec(alloc, "INSERT INTO worker (id, session_id) VALUES ('w1', 's1')", &.{});

    const workers = try getActiveWorker(alloc, &ctx.db);
    defer {
        for (workers) |*w| w.deinit(alloc);
        alloc.free(workers);
    }

    try testing.expectEqual(@as(usize, 1), workers.len);
    // COALESCE(s.git_worktree_cwd, '') maps NULL → empty string so the prompt
    // builder's `if (worker.git_worktree_cwd.len > 0)` guard works as
    // designed (skips the "(git worktree: ...)" suffix when no worktree is
    try testing.expectEqualStrings("", workers[0].git_worktree_cwd);
}

// ─── Test 3: LEFT JOIN preserves orphan workers (no matching session) ───

test "getActiveWorker returns worker with empty git_worktree_cwd when session row missing" {
    const alloc = testing.allocator;
    var ctx = try llmHistoryWorkerInfoSetupDb();
    defer ctx.db.deinit();
    defer ctx.threaded.deinit();

    // Worker exists; no corresponding session row (deleted orphan — should
    // not happen in normal flow, but the LEFT JOIN must not filter it out).
    try ctx.db.exec(alloc, "INSERT INTO worker (id, session_id) VALUES ('w1', 'orphan_sid')", &.{});

    const workers = try getActiveWorker(alloc, &ctx.db);
    defer {
        for (workers) |*w| w.deinit(alloc);
        alloc.free(workers);
    }

    try testing.expectEqual(@as(usize, 1), workers.len);
    try testing.expectEqualStrings("orphan_sid", workers[0].session_id);
    try testing.expectEqualStrings("", workers[0].git_worktree_cwd);
}

// ─── Test 4: deinit frees git_worktree_cwd (memory leak regression) ─────

test "WorkerInfo.deinit frees git_worktree_cwd without leaking" {
    const alloc = testing.allocator;
    var ctx = try llmHistoryWorkerInfoSetupDb();
    defer ctx.db.deinit();
    defer ctx.threaded.deinit();

    // Populated git_worktree_cwd — the case that would leak if deinit forgot
    // the field. The `testing.allocator` will flag any leaked allocation.
    try ctx.db.exec(alloc, "INSERT INTO sessions (id, name, git_worktree_cwd) VALUES ('s1', 't', '/some/abs/path')", &.{});
    try ctx.db.exec(alloc, "INSERT INTO worker (id, session_id) VALUES ('w1', 's1')", &.{});

    const workers = try getActiveWorker(alloc, &ctx.db);
    defer {
        for (workers) |*w| w.deinit(alloc);
        alloc.free(workers);
    }

    try testing.expectEqual(@as(usize, 1), workers.len);
    try testing.expect(workers[0].git_worktree_cwd.len > 0);
}

// ─── Test 5: getWorkerBySessionId returns git_worktree_cwd ──────────────

test "getWorkerBySessionId returns git_worktree_cwd from joined session" {
    const alloc = testing.allocator;
    var ctx = try llmHistoryWorkerInfoSetupDb();
    defer ctx.db.deinit();
    defer ctx.threaded.deinit();

    try ctx.db.exec(alloc, "INSERT INTO sessions (id, name, git_worktree_cwd) VALUES ('s1', 't', '/worktree/path')", &.{});
    try ctx.db.exec(alloc, "INSERT INTO worker (id, session_id, last_activity_description) VALUES ('w1', 's1', 'hello')", &.{});

    const opt = try getWorkerBySessionId(alloc, &ctx.db, "s1");
    var worker = (opt orelse return error.ExpectedWorker);
    defer worker.deinit(alloc);

    try testing.expectEqualStrings("s1", worker.session_id);
    try testing.expectEqualStrings("hello", worker.last_activity_description);
    try testing.expectEqualStrings("/worktree/path", worker.git_worktree_cwd);
}

// ─── Test 6: getWorkerBySessionId returns null when worker row absent ───

test "getWorkerBySessionId returns null when no worker row matches" {
    const alloc = testing.allocator;
    var ctx = try llmHistoryWorkerInfoSetupDb();
    defer ctx.db.deinit();
    defer ctx.threaded.deinit();

    const opt = try getWorkerBySessionId(alloc, &ctx.db, "no_such_sid");
    try testing.expect(opt == null);
}

// ─── Test 7: getWorkerBySessionId returns empty for orphan worker ────────

test "getWorkerBySessionId returns worker with empty git_worktree_cwd for orphan row" {
    const alloc = testing.allocator;
    var ctx = try llmHistoryWorkerInfoSetupDb();
    defer ctx.db.deinit();
    defer ctx.threaded.deinit();

    // Worker exists, session row missing.
    try ctx.db.exec(alloc, "INSERT INTO worker (id, session_id) VALUES ('w1', 'orphan')", &.{});

    const opt = try getWorkerBySessionId(alloc, &ctx.db, "orphan");
    var worker = (opt orelse return error.ExpectedWorker);
    defer worker.deinit(alloc);

    try testing.expectEqualStrings("orphan", worker.session_id);
    try testing.expectEqualStrings("", worker.git_worktree_cwd);
}

// =============================================================================
// Session progressive tool persistence (Migration 085)
// =============================================================================

const ProgressiveTestCtx = struct {
    db: database.Db,
    threaded: std.Io.Threaded,
};

fn progressiveSetupDb() !ProgressiveTestCtx {
    const alloc = testing.allocator;
    var threaded = std.Io.Threaded.init(alloc, .{});
    errdefer threaded.deinit();
    const io = threaded.io();
    var db: database.Db = .{};
    errdefer db.deinit();
    try test_db.openMemory(&db, io);
    try db.exec(alloc,
        \\CREATE TABLE session_progressive_tool (
        \\    session_id TEXT NOT NULL,
        \\    tool_name TEXT NOT NULL,
        \\    server_name TEXT NOT NULL DEFAULT '',
        \\    loaded_at_nano BIGINT NOT NULL DEFAULT 0,
        \\    PRIMARY KEY (session_id, tool_name)
        \\)
    , &.{});
    return .{ .db = db, .threaded = threaded };
}

test "saveProgressiveTool: first call inserts, the second is a no-op returning false" {
    const alloc = testing.allocator;
    var ctx = try progressiveSetupDb();
    defer ctx.db.deinit();
    defer ctx.threaded.deinit();
    var lg = logger_mod.Logger.init(alloc, std.testing.io, .{});

    const first = try saveProgressiveTool(alloc, &ctx.db, &lg, "s1", "glob", "");
    try testing.expect(first);

    const second = try saveProgressiveTool(alloc, &ctx.db, &lg, "s1", "glob", "");
    try testing.expect(!second);

    const rows = try getProgressiveTools(alloc, &ctx.db, "s1");
    defer {
        for (rows) |r| r.deinit(alloc);
        alloc.free(rows);
    }
    try testing.expectEqual(@as(usize, 1), rows.len);
    try testing.expectEqualStrings("glob", rows[0].tool_name);
}

test "saveProgressiveTool: stores the server name for MCP tools" {
    const alloc = testing.allocator;
    var ctx = try progressiveSetupDb();
    defer ctx.db.deinit();
    defer ctx.threaded.deinit();
    var lg = logger_mod.Logger.init(alloc, std.testing.io, .{});

    _ = try saveProgressiveTool(alloc, &ctx.db, &lg, "s1", "mcp_context7_query-docs", "context7");

    const rows = try getProgressiveTools(alloc, &ctx.db, "s1");
    defer {
        for (rows) |r| r.deinit(alloc);
        alloc.free(rows);
    }
    try testing.expectEqual(@as(usize, 1), rows.len);
    try testing.expectEqualStrings("context7", rows[0].server_name);
}

test "saveProgressiveTool / isProgressiveToolEquipped: empty ids are inert" {
    const alloc = testing.allocator;
    var ctx = try progressiveSetupDb();
    defer ctx.db.deinit();
    defer ctx.threaded.deinit();
    var lg = logger_mod.Logger.init(alloc, std.testing.io, .{});

    // Empty session → nothing written, reported as not inserted.
    try testing.expect(!try saveProgressiveTool(alloc, &ctx.db, &lg, "", "glob", ""));
    // Empty tool name → same.
    try testing.expect(!try saveProgressiveTool(alloc, &ctx.db, &lg, "s1", "", ""));

    const rows = try getProgressiveTools(alloc, &ctx.db, "s1");
    defer {
        for (rows) |r| r.deinit(alloc);
        alloc.free(rows);
    }
    try testing.expectEqual(@as(usize, 0), rows.len);

    try testing.expect(!try isProgressiveToolEquipped(alloc, &ctx.db, "", "glob"));
    try testing.expect(!try isProgressiveToolEquipped(alloc, &ctx.db, "s1", "glob"));
}

test "isProgressiveToolEquipped detects a row written by saveProgressiveTool" {
    const alloc = testing.allocator;
    var ctx = try progressiveSetupDb();
    defer ctx.db.deinit();
    defer ctx.threaded.deinit();
    var lg = logger_mod.Logger.init(alloc, std.testing.io, .{});

    _ = try saveProgressiveTool(alloc, &ctx.db, &lg, "s1", "kanban_list", "");
    try testing.expect(try isProgressiveToolEquipped(alloc, &ctx.db, "s1", "kanban_list"));
    // Another session is unaffected — the set is per session.
    try testing.expect(!try isProgressiveToolEquipped(alloc, &ctx.db, "s2", "kanban_list"));
}

test "getProgressiveTools: unknown session is empty and deleteProgressiveTool removes a row" {
    const alloc = testing.allocator;
    var ctx = try progressiveSetupDb();
    defer ctx.db.deinit();
    defer ctx.threaded.deinit();
    var lg = logger_mod.Logger.init(alloc, std.testing.io, .{});

    const none = try getProgressiveTools(alloc, &ctx.db, "nope");
    defer alloc.free(none);
    try testing.expectEqual(@as(usize, 0), none.len);

    _ = try saveProgressiveTool(alloc, &ctx.db, &lg, "s1", "glob", "");
    try deleteProgressiveTool(alloc, &ctx.db, "s1", "glob");

    const rows = try getProgressiveTools(alloc, &ctx.db, "s1");
    defer {
        for (rows) |r| r.deinit(alloc);
        alloc.free(rows);
    }
    try testing.expectEqual(@as(usize, 0), rows.len);
}

test "getProgressiveTools: order is deterministic for tools equipped in the same second" {
    const alloc = testing.allocator;
    var ctx = try progressiveSetupDb();
    defer ctx.db.deinit();
    defer ctx.threaded.deinit();

    // Same loaded_at_nano for all three (the second-resolution caveat).
    try ctx.db.exec(alloc, "INSERT INTO session_progressive_tool (session_id, tool_name, server_name, loaded_at_nano) VALUES ('s1','zeta','',5), ('s1','alpha','',5), ('s1','mid','',5)", &.{});

    const rows = try getProgressiveTools(alloc, &ctx.db, "s1");
    defer {
        for (rows) |r| r.deinit(alloc);
        alloc.free(rows);
    }
    try testing.expectEqual(@as(usize, 3), rows.len);
    try testing.expectEqualStrings("alpha", rows[0].tool_name);
    try testing.expectEqualStrings("mid", rows[1].tool_name);
    try testing.expectEqualStrings("zeta", rows[2].tool_name);
}

test "saveMessage: user envelope carries owner identity, assistant carries profile name" {
    // Follow-up on the Option A envelopes: when the session has an owner
    // (`sessions.user_id -> users.name`) and a picked profile
    // (`sessions.selected_profile_model`), the persisted envelopes carry
    const alloc = testing.allocator;
    var threaded = std.Io.Threaded.init(alloc, .{});
    defer threaded.deinit();
    const io = threaded.io();
    var db: database.Db = .{};
    defer db.deinit();
    try test_db.openMemory(&db, io);

    try db.exec(alloc,
        \\CREATE TABLE llm_history (
        \\    id TEXT PRIMARY KEY,
        \\    session_id TEXT NOT NULL,
        \\    model TEXT,
        \\    response_content TEXT,
        \\    finish_reason TEXT,
        \\    role TEXT,
        \\    tool_calls_json TEXT,
        \\    tool_call_id TEXT,
        \\    reasoning_content TEXT,
        \\    reasoning_id TEXT,
        \\    reasoning_encrypted_content TEXT,
        \\    is_feed_to_llm INTEGER DEFAULT 1,
        \\    agent TEXT,
        \\    loop_index INTEGER,
        \\    temperature REAL,
        \\    is_thinking INTEGER,
        \\    created_at_nano TEXT,
        \\    created_iso TEXT,
        \\    parent_session_id TEXT,
        \\    parent_id TEXT,
        \\    prompt_tokens INTEGER,
        \\    completion_tokens INTEGER,
        \\    total_tokens INTEGER,
        \\    cache_creation_input_tokens INTEGER DEFAULT 0,
        \\    cache_read_input_tokens INTEGER DEFAULT 0,
        \\    is_input INTEGER,
        \\    is_output INTEGER,
        \\    tool_name TEXT,
        \\    diffview_before TEXT,
        \\    diffview_after TEXT,
        \\    image_url TEXT,
        \\    video_url TEXT
        \\)
    , &.{});
    try db.exec(alloc,
        \\CREATE TABLE sessions (
        \\    id TEXT PRIMARY KEY,
        \\    user_id TEXT,
        \\    selected_profile_model TEXT,
        \\    cwd TEXT,
        \\    updated_at TEXT
        \\)
    , &.{});
    try db.exec(alloc,
        \\CREATE TABLE users (
        \\    id TEXT PRIMARY KEY,
        \\    name TEXT NOT NULL DEFAULT ''
        \\)
    , &.{});
    try db.exec(alloc, "INSERT INTO sessions (id, user_id, selected_profile_model, cwd) VALUES ('s_owned', 'u1', '900ribu', '/tmp')", &.{});
    try db.exec(alloc, "INSERT INTO users (id, name) VALUES ('u1', 'Budi')", &.{});
    try db.exec(alloc, "INSERT INTO sessions (id, cwd) VALUES ('s_anon', '/tmp')", &.{});
    try db.exec(alloc, "INSERT INTO users (id, name) VALUES ('u2', '')", &.{});
    try db.exec(alloc, "INSERT INTO sessions (id, user_id, cwd) VALUES ('s_noname', 'u2', '/tmp')", &.{});
    try saveMessage(alloc, io, &db, .{
        .session_id = "s_owned",
        .model = "MiniMax-M3",
        .cwd = "/tmp",
        .content = "i wanna ask",
        .reasoning_content = null,
        .role = "user",
        .finish_reason = null,
        .tool_calls = null,
        .tool_call_id = null,
        .agent_name = "Agent",
        .loop_index = 0,
        .temperature = 0.2,
        .is_thinking = false,
        .is_input = true,
        .is_output = false,
    });
    try saveMessage(alloc, io, &db, .{
        .session_id = "s_owned",
        .model = "MiniMax-M3",
        .cwd = "/tmp",
        .content = "hey human",
        .reasoning_content = null,
        .role = "assistant",
        .finish_reason = null,
        .tool_calls = null,
        .tool_call_id = null,
        .agent_name = "Agent",
        .loop_index = 0,
        .temperature = 0.2,
        .is_thinking = false,
        .is_input = false,
        .is_output = true,
    });
    try saveMessage(alloc, io, &db, .{
        .session_id = "s_anon",
        .model = "MiniMax-M3",
        .cwd = "/tmp",
        .content = "anon hi",
        .reasoning_content = null,
        .role = "user",
        .finish_reason = null,
        .tool_calls = null,
        .tool_call_id = null,
        .agent_name = "Agent",
        .loop_index = 0,
        .temperature = 0.2,
        .is_thinking = false,
        .is_input = true,
        .is_output = false,
    });
    try saveMessage(alloc, io, &db, .{
        .session_id = "s_noname",
        .model = "MiniMax-M3",
        .cwd = "/tmp",
        .content = "no name hi",
        .reasoning_content = null,
        .role = "user",
        .finish_reason = null,
        .tool_calls = null,
        .tool_call_id = null,
        .agent_name = "Agent",
        .loop_index = 0,
        .temperature = 0.2,
        .is_thinking = false,
        .is_input = true,
        .is_output = false,
    });

    const Case = struct { session: []const u8, role: []const u8, key: []const u8, want: []const u8 };
    const cases = [_]Case{
        .{ .session = "s_owned", .role = "user", .key = "user", .want = "u1" },
        .{ .session = "s_owned", .role = "user", .key = "name", .want = "Budi" },
        .{ .session = "s_owned", .role = "user", .key = "msg", .want = "i wanna ask" },
        .{ .session = "s_owned", .role = "assistant", .key = "model", .want = "900ribu" },
        .{ .session = "s_owned", .role = "assistant", .key = "msg", .want = "hey human" },
        .{ .session = "s_anon", .role = "user", .key = "user", .want = "" },
        .{ .session = "s_anon", .role = "user", .key = "name", .want = "Agent" },
        .{ .session = "s_anon", .role = "user", .key = "msg", .want = "anon hi" },
        .{ .session = "s_noname", .role = "user", .key = "user", .want = "u2" },
        .{ .session = "s_noname", .role = "user", .key = "name", .want = "Agent" },
        .{ .session = "s_noname", .role = "user", .key = "msg", .want = "no name hi" },
    };
    for (cases) |c| {
        const sql = try std.fmt.allocPrint(alloc, "SELECT response_content FROM llm_history WHERE session_id='{s}' AND role='{s}'", .{ c.session, c.role });
        defer alloc.free(sql);
        var q = try db.query(alloc, sql, &.{});
        defer q.deinit();
        const row = (try q.next()) orelse return error.RowMissing;
        defer row.deinit(alloc);
        var parsed = try std.json.parseFromSlice(std.json.Value, alloc, row.values[0], .{});
        defer parsed.deinit();
        const got = parsed.value.object.get(c.key) orelse return error.KeyMissing;
        try testing.expectEqualStrings(c.want, got.string);
    }
}

// ─────────────────────────────────────────────────────────────────────────
// Behaviour: `cwd` and `cursor` arrive from HTTP query strings, so a filter
// value must never change the shape of the WHERE clause it lands in.

/// Two sessions in different directories, owned by different users.
fn setupOwnedSessionsDb() !struct { db: database.Db, threaded: std.Io.Threaded } {
    const alloc = testing.allocator;
    var threaded = std.Io.Threaded.init(alloc, .{});
    errdefer threaded.deinit();
    var db: database.Db = .{};
    errdefer db.deinit();
    try test_db.openMemory(&db, threaded.io());

    try db.exec(alloc,
        \\CREATE TABLE sessions (
        \\    id TEXT PRIMARY KEY,
        \\    name TEXT NOT NULL,
        \\    status TEXT NOT NULL DEFAULT 'active',
        \\    cwd TEXT NOT NULL DEFAULT '',
        \\    user_id TEXT,
        \\    created_at TIMESTAMP,
        \\    updated_at TIMESTAMP,
        \\    selected_profile_model TEXT,
        \\    is_auto_retry_until_stop INTEGER NOT NULL DEFAULT 0,
        \\    last_finish_reason TEXT,
        \\    last_human_touched_at_nano BIGINT,
        \\    git_worktree_cwd TEXT,
        \\    is_pinned INTEGER NOT NULL DEFAULT 0,
        \\    pinned_position INTEGER NOT NULL DEFAULT 0
        \\)
    , &.{});
    try db.exec(alloc, "CREATE TABLE llm_history (id TEXT PRIMARY KEY, session_id TEXT, agent TEXT)", &.{});
    // The list's correlated subquery reads this table, so it must exist.
    try db.exec(alloc, "CREATE TABLE workspace_item_tasks (id TEXT PRIMARY KEY, name TEXT, workspace_item_id TEXT)", &.{});
    try db.exec(alloc,
        \\INSERT INTO sessions (id, name, cwd, user_id, created_at, updated_at) VALUES
        \\  ('s_mine', 'Mine', '/work/a', 'user_a', '2026-09-20 00:00:00', '2026-09-20 00:00:00'),
        \\  ('s_theirs', 'Theirs', '/work/b', 'user_b', '2026-09-21 00:00:00', '2026-09-21 00:00:00')
    , &.{});
    return .{ .db = db, .threaded = threaded };
}

fn freeSessionList(alloc: std.mem.Allocator, result: anytype) void {
    for (result.sessions) |session| session.deinit(alloc);
    alloc.free(result.sessions);
}

test "a cwd filter returns only the sessions in that directory" {
    const alloc = testing.allocator;
    var ctx = try setupOwnedSessionsDb();
    defer ctx.db.deinit();
    defer ctx.threaded.deinit();

    const result = try getSessionListWithCursor(
        alloc,
        &ctx.db,
        null,
        null,
        "/work/a",
        null,
        "user_a",
        10,
        null,
        .created_at,
        .desc,
    );
    defer freeSessionList(alloc, result);

    try testing.expectEqual(@as(usize, 1), result.sessions.len);
    try testing.expectEqualStrings("s_mine", result.sessions[0].session_id);
    try testing.expectEqual(@as(u32, 1), result.total);
}

test "a cwd filter carrying an OR does not reveal another owner's sessions" {
    const alloc = testing.allocator;
    var ctx = try setupOwnedSessionsDb();
    defer ctx.db.deinit();
    defer ctx.threaded.deinit();

    const result = try getSessionListWithCursor(
        alloc,
        &ctx.db,
        null,
        null,
        "x' OR 1=1 OR s.cwd='x",
        null,
        "user_a",
        10,
        null,
        .created_at,
        .desc,
    );
    defer freeSessionList(alloc, result);

    try testing.expectEqual(@as(usize, 0), result.sessions.len);
}

test "a cursor carrying an OR does not widen the session list" {
    const alloc = testing.allocator;
    var ctx = try setupOwnedSessionsDb();
    defer ctx.db.deinit();
    defer ctx.threaded.deinit();

    // The system user sees every row, so the cursor is the only filter that
    // could fail here: a literal comparison keeps both rows out.
    const result = try getSessionListWithCursor(
        alloc,
        &ctx.db,
        null,
        null,
        null,
        null,
        auth_common.system_user_id,
        10,
        "0' OR 1=1 OR s.created_at < '0",
        .created_at,
        .desc,
    );
    defer freeSessionList(alloc, result);

    try testing.expectEqual(@as(usize, 0), result.sessions.len);
}

test "a task cursor carrying an OR does not escape the item's tasks" {
    const alloc = testing.allocator;
    var ctx = try setupDb();
    defer ctx.db.deinit();
    defer ctx.threaded.deinit();

    try ctx.db.exec(alloc,
        \\INSERT INTO workspace_item_tasks (id, name, workspace_item_id, updated_at) VALUES
        \\  ('task_a', 'A', 'wi_1', '2026-09-20 00:00:00'),
        \\  ('task_b', 'B', 'wi_1', '2026-09-21 00:00:00')
    , &.{});

    const page = try listWorkspaceItemTasksWithCursor(
        alloc,
        &ctx.db,
        "wi_1",
        10,
        "0' OR 1=1 OR t.updated_at < '0|1",
        .updated_at,
        .desc,
        null,
        null,
    );
    defer freeTasks(alloc, page.tasks);

    try testing.expectEqual(@as(usize, 0), page.tasks.len);
}
