const std = @import("std");
const schemas = @import("schemas.zig");
const AgentTool = schemas.AgentTool;
const pabrikcore = @import("pabrikcore");
const sqlite = pabrikcore.sqlite;
const llm_history = pabrikcore.llm_history;
const workspace_scope = pabrikcore.workspace_scope;
const helpers = @import("helpers");
const sanitize = helpers.sanitize_control_chars;

/// Input for read_workspace_session.
///
/// ONE tool, four behaviors selected by which params are set:
/// - neither `query` nor `session_id` → LIST sessions in my workspace.
/// - `query` only → SEARCH message content across my workspace (FTS5).
/// - `session_id` only → READ that session's messages (same-workspace gate).
/// - BOTH → SEARCH-WITHIN: FTS restricted to that one session (still gated).
///
/// Scope is derived server-side from the calling session — there is no
/// `workspace_id` param (a client-supplied id would be a spoofing vector).
pub const ReadWorkspaceSessionInput = struct {
    /// Target session for READ / SEARCH-WITHIN. Must belong to the same
    /// workspace as the calling session or the call is denied.
    session_id: []const u8 = "",
    /// FTS5 query for SEARCH / SEARCH-WITHIN (auto-sanitized, OR recall).
    query: []const u8 = "",
    /// Comma-separated message ids. Returns full `content` for these ids
    /// (capped at `MAX_MESSAGE_IDS`). In SEARCH the lookup is restricted
    /// to workspace sessions — ids from other workspaces are skipped.
    message_ids: []const u8 = "",
    /// Optional exact-match role filter.
    role: []const u8 = "",
    /// Optional lower bound on created_at (inclusive). YYYY-MM-DD HH:MM:SS.
    since: []const u8 = "",
    /// Optional upper bound on created_at (inclusive).
    until: []const u8 = "",
    /// When true, restrict to rows with `is_feed_to_llm = 1` (currently in
    /// the LLM's live context). Mutually exclusive with `compacted_only`.
    live_only: bool = false,
    /// When true, restrict to rows with `is_feed_to_llm = 0` (dropped from
    /// the LLM's context by compaction). Mutually exclusive with
    /// `live_only`.
    compacted_only: bool = false,
    /// Optional exact-match filter on `tool_name`. Useful for "find every
    /// `command` invocation that ran `cargo test`".
    tool_name: []const u8 = "",
    /// Optional exact-match filter on `parent_session_id`. Useful for
    /// sub-agent debugging — find every message in any session whose parent
    /// is the given session_id.
    parent_session_id: []const u8 = "",
    /// Optional exact-match filter on `agent`. Useful when one session has
    /// multiple agents (planning vs chat vs sub-agent).
    agent: []const u8 = "",
    /// Max rows to return. Defaults to 20; capped at 200 (LIST caps at 50).
    limit: u32 = 20,
    /// Skip the first N results. SEARCH only — used to paginate through
    /// FTS results when there are more than `limit` matches. Combine with
    /// `<total_count>` to know when to stop. READ ignores this field (use
    /// `since`/`until` to paginate chronologically).
    offset: u32 = 0,
    /// Order direction for READ. "asc" (chronological forward, default) or
    /// "desc" (most-recent-first). SEARCH always orders by FTS rank.
    order: []const u8 = "asc",
    /// When true, the caller's OWN session is included in the results.
    ///
    /// Default false: the tool answers questions about OTHER sessions, so
    /// the current session is filtered out of LIST and SEARCH, and READ /
    /// SEARCH-WITHIN aimed at it is refused with a retry hint. Your live
    /// context already holds the current session — echoing it back just
    /// burns tokens. Pass true when you deliberately need it (e.g. pulling
    /// your own messages that compaction dropped, via `compacted_only`).
    is_current_session: bool = false,
};

/// Hard cap on how many `message_ids` the LLM can request at once.
/// Prevents a single call from dumping megabytes of full `content`
/// into the context. If the LLM needs more, it should split into
/// batches — the response includes `count` + `total_count` so it
/// can paginate by hand.
pub const MAX_MESSAGE_IDS: u32 = 50;

/// Hard cap on bytes of full `content` per individual message. When a
/// requested message_id's content exceeds this, the response includes
/// the first `MAX_FULL_CONTENT_BYTES` bytes plus `content_truncated=true`
/// so the LLM knows there's more. Default: 16 KB.
pub const MAX_FULL_CONTENT_BYTES: u32 = 16 * 1024;

/// Hard cap on LIST rows. Discovery should stay cheap — the LLM can
/// SEARCH once it knows what to look for.
pub const MAX_LIST_LIMIT: u32 = 50;

pub const read_workspace_session_tool_system_prompt =
    \\## Read Workspace Session Tool — Behavior
    \\Use `read_workspace_session` to discover, search, and read OTHER chat sessions in YOUR workspace.
    \\- No args → LIST sessions in your workspace (names + previews so you can pick one).
    \\- `query` → SEARCH message content across your workspace (FTS).
    \\- `session_id` → READ that session's messages. `query` + `session_id` → SEARCH-WITHIN one session.
    \\- Scope is automatic (your workspace only). Cross-workspace reads are denied, never leaked.
    \\- Your OWN session is excluded by default in every behavior. Pass `is_current_session: true`
    \\  only when you deliberately need it (e.g. your own messages dropped by compaction).
    \\
;

pub const read_workspace_session_tool = AgentTool{
    .type = "function",
    .function = .{
        .name = "read_workspace_session",
        .description =
        \\Discover, search, and read other chat sessions in YOUR workspace — including messages compacted out of the live context. Scope is derived server-side from your session: you can only ever see sessions in your own workspace; reads of another workspace's session are denied.
        \\
        \\FOUR BEHAVIORS (pick by params):
        \\- LIST (neither `query` nor `session_id`): sessions in your workspace with name, status, message count, last activity, and a preview of the latest human message. Use it to find "the conversation about X" when you don't know its session id.
        \\- SEARCH (`query` only): SQLite FTS5 over message content across your workspace. Returns ranked matches with a preview snippet + owning session id/name. For long result sets, read <total_count> and call again with offset=N until offset + count >= total_count.
        \\- READ (`session_id` only): messages of one session (live + compacted) as an index (id, role, created_at, preview); pass `message_ids` (up to 50) for full <content> bodies.
        \\- SEARCH-WITHIN (both `query` and `session_id`): FTS restricted to that one session.
        \\
        \\YOUR OWN SESSION (all four behaviors): excluded by default. LIST/SEARCH filter it out; READ/SEARCH-WITHIN aimed at it return an `error` telling you to retry. Set `is_current_session: true` to opt back in — you already hold the current session in your live context, so only ask deliberately (e.g. `compacted_only` to recover messages compaction dropped).
        \\
        \\FTS QUERY SANITIZATION: `.`, `-`, `:`, `*`, `^`, `(`, `)`, `"`, `+` are auto-sanitized — write `handle_tool.zig` or `AGENTS.md` without pre-escaping. Multi-word queries are joined with FTS5 OR (`a b` matches rows containing `a` OR `b`).
        \\
        \\RESPONSE (JSON fields): `count` = entries in THIS response (page size); `total_count` = matches before pagination (tells you whether more pages exist); per-message `content` truncated to 16 KB with `content_truncated=true` when there is more (call again with a narrower `message_ids` to fetch the rest); cross-workspace targets return `denied:true`, never content.
        \\
        \\Examples: {} list · {"query": "login bug fix"} search · {"session_id": "s_42"} read · {"session_id": "s_42", "query": "migration"} search-within · {"is_current_session": true, "compacted_only": true} own compacted messages.
        ,
        .parameters = .{
            .type = "object",
            .properties = &.{
                .{ .name = "session_id", .type = "string", .description = "Target session for READ / SEARCH-WITHIN. Must be in your workspace or the call is denied." },
                .{ .name = "query", .type = "string", .description = "FTS5 search query (auto-sanitized) for SEARCH / SEARCH-WITHIN." },
                .{ .name = "message_ids", .type = "string", .description = "Comma-separated ids. Returns full <content> for these ids (workspace-scoped). Capped at 50 per call — split into batches for more." },
                .{ .name = "role", .type = "string", .description = "Optional exact-match role filter: 'user', 'assistant', or 'tool'." },
                .{ .name = "tool_name", .type = "string", .description = "Optional exact-match filter on tool_name. Useful for finding every `command` / read_file / search invocation." },
                .{ .name = "parent_session_id", .type = "string", .description = "Optional exact-match filter on parent_session_id. Useful for tracing a sub-agent's full session." },
                .{ .name = "agent", .type = "string", .description = "Optional exact-match filter on agent name (e.g. 'main', 'planning', 'compaction')." },
                .{ .name = "live_only", .type = "boolean", .description = "If true, restrict to messages still in the LLM's live context (is_feed_to_llm=1). Mutually exclusive with compacted_only — omit both for live + compacted." },
                .{ .name = "compacted_only", .type = "boolean", .description = "If true, restrict to messages dropped by compaction (is_feed_to_llm=0). Mutually exclusive with live_only." },
                .{ .name = "since", .type = "string", .description = "Optional lower bound on created_at (inclusive). YYYY-MM-DD HH:MM:SS." },
                .{ .name = "until", .type = "string", .description = "Optional upper bound on created_at (inclusive)." },
                .{ .name = "limit", .type = "number", .description = "Max rows to return. Default 20, max 200 (LIST max 50)." },
                .{ .name = "offset", .type = "number", .description = "SEARCH only. Skip first N matches for pagination." },
                .{ .name = "order", .type = "string", .description = "READ only. 'asc' (chronological forward, default) or 'desc' (most-recent-first)." },
                .{ .name = "is_current_session", .type = "boolean", .description = "When true, the current session is included in the results. Default false — your own session is excluded from LIST/SEARCH and refused by READ/SEARCH-WITHIN." },
            },
            .required = &.{},
        },
        .system_prompt = read_workspace_session_tool_system_prompt,
    },
};

/// Parse `message_ids_csv` ("h_123,h_456") into a `[]const []const u8`.
fn parseMessageIds(allocator: std.mem.Allocator, csv: []const u8) ![]const []const u8 {
    if (csv.len == 0) return &.{};
    var ids: std.ArrayList([]const u8) = .empty;
    errdefer {
        for (ids.items) |id| allocator.free(id);
        ids.deinit(allocator);
    }
    var iter = std.mem.splitScalar(u8, csv, ',');
    while (iter.next()) |id| {
        const trimmed = std.mem.trim(u8, id, " \t");
        if (trimmed.len > 0) {
            try ids.append(allocator, try allocator.dupe(u8, trimmed));
        }
    }
    return try ids.toOwnedSlice(allocator);
}

fn jsonError(allocator: std.mem.Allocator, msg: []const u8) ![]u8 {
    const clean = try sanitize(allocator, msg);
    defer allocator.free(clean);
    return std.json.Stringify.valueAlloc(allocator, .{ .@"error" = clean }, .{});
}

fn deniedJSON(allocator: std.mem.Allocator, session_id: []const u8) ![]u8 {
    const clean = try sanitize(allocator, session_id);
    defer allocator.free(clean);
    return std.json.Stringify.valueAlloc(allocator, .{
        .denied = true,
        .session_id = clean,
        .message = "Session is not in your workspace.",
    }, .{});
}

/// Refusal for READ / SEARCH-WITHIN aimed at the caller's own session while
/// `is_current_session` is false. Carries the behavior name and zero counts
/// so the frontend renders its existing error panel instead of a blank
/// list, plus a hint the LLM can act on by adding one param.
fn currentSessionRefusedJSON(allocator: std.mem.Allocator, behavior: []const u8) ![]u8 {
    return std.json.Stringify.valueAlloc(allocator, .{
        .behavior = behavior,
        .is_current_session = false,
        .count = 0,
        .total_count = 0,
        .@"error" = "Your own session is excluded by default — this tool reads OTHER conversations. Retry with is_current_session=true to include the current session.",
    }, .{});
}

/// Owned copy of `ids` with the caller's own session removed, unless
/// `include_caller`. Free with `workspace_scope.freeSessionIds`.
///
/// An EMPTY result means "no peer sessions at all" (e.g. the caller is the
/// workspace's only session and is_current_session is false). Callers must
/// treat that as an empty result set — handing an empty id list to the FTS
/// query drops the `IN (...)` clause entirely and would leak every
/// workspace's hits.
fn withoutCallerSession(
    allocator: std.mem.Allocator,
    ids: []const []const u8,
    caller_session_id: []const u8,
    include_caller: bool,
) ![][]u8 {
    var out: std.ArrayList([]u8) = .empty;
    errdefer {
        for (out.items) |s| allocator.free(s);
        out.deinit(allocator);
    }
    for (ids) |id| {
        if (!include_caller and std.mem.eql(u8, id, caller_session_id)) continue;
        try out.append(allocator, try allocator.dupe(u8, id));
    }
    return try out.toOwnedSlice(allocator);
}

/// Execute read_workspace_session. Returns an XML string for the LLM.
/// `caller_session_id` is the session invoking the tool (server-side,
/// from the dispatch context — never from LLM input).
pub fn execute_read_workspace_session(
    allocator: std.mem.Allocator,
    io: std.Io,
    db: *sqlite.SqliteBackend,
    caller_session_id: []const u8,
    input: ReadWorkspaceSessionInput,
) ![]const u8 {
    _ = io; // Reserved for future streaming; not used in v1.

    if (input.live_only and input.compacted_only) {
        return jsonError(allocator, "live_only and compacted_only are mutually exclusive — pick one or neither.");
    }

    const feed_filter: llm_history.FeedFilter = if (input.live_only)
        .live_only
    else if (input.compacted_only)
        .compacted_only
    else
        .all;

    if (caller_session_id.len == 0) {
        return jsonError(allocator, "Missing caller session — cannot resolve workspace scope.");
    }

    const want_search = input.query.len > 0;
    const want_read = input.session_id.len > 0;

    if (!want_search and !want_read) {
        return executeList(allocator, db, caller_session_id, input);
    }

    // Self-targeting is opt-in. The tool exists to answer questions about
    // OTHER conversations, so READ / SEARCH-WITHIN aimed at the caller's own
    // session is refused with a hint instead of echoing back the context the
    // LLM already holds. Gated before the workspace lookup — self always
    // passes `isSameWorkspace`, so this is the only place that catches it.
    if (want_read and !input.is_current_session and
        std.mem.eql(u8, input.session_id, caller_session_id))
    {
        return currentSessionRefusedJSON(allocator, if (want_search) "search-within" else "read");
    }

    // SEARCH / READ / SEARCH-WITHIN all need the caller's workspace.
    const ws = try workspace_scope.resolveWorkspaceId(allocator, db, caller_session_id);
    defer if (ws) |w| allocator.free(w);
    if (ws == null) {
        return jsonError(allocator, "Current session is not linked to any workspace — cross-session history is unavailable.");
    }

    if (want_search and !want_read) {
        const ws_ids = try workspace_scope.workspaceSessionIds(allocator, db, ws.?);
        defer workspace_scope.freeSessionIds(allocator, ws_ids);
        // Drop the caller unless asked for it. `executeSearch` treats an
        // empty scoped set as "no results" rather than "no filter".
        const scoped_ids = try withoutCallerSession(allocator, ws_ids, caller_session_id, input.is_current_session);
        defer workspace_scope.freeSessionIds(allocator, scoped_ids);
        return executeSearch(allocator, db, scoped_ids, null, feed_filter, input);
    }

    // READ or SEARCH-WITHIN: gate the target session first.
    const allowed = try workspace_scope.isSameWorkspace(allocator, db, caller_session_id, input.session_id);
    if (!allowed) {
        return deniedJSON(allocator, input.session_id);
    }
    if (want_search) {
        return executeSearch(allocator, db, null, input.session_id, feed_filter, input);
    }
    return executeRead(allocator, db, input.session_id, feed_filter, input);
}

const SessionMeta = struct {
    id: []u8,
    name: []u8,
    status: []u8,
    message_count: u32,
    last_activity: []u8,
    preview: []u8,

    fn deinit(self: *const SessionMeta, allocator: std.mem.Allocator) void {
        allocator.free(self.id);
        allocator.free(self.name);
        allocator.free(self.status);
        allocator.free(self.last_activity);
        allocator.free(self.preview);
    }
};

fn executeList(
    allocator: std.mem.Allocator,
    db: *sqlite.SqliteBackend,
    caller_session_id: []const u8,
    input: ReadWorkspaceSessionInput,
) ![]const u8 {
    const ws = try workspace_scope.resolveWorkspaceId(allocator, db, caller_session_id);
    defer if (ws) |w| allocator.free(w);
    if (ws == null) {
        return jsonError(allocator, "Current session is not linked to any workspace — cross-session history is unavailable.");
    }

    const ws_ids = try workspace_scope.workspaceSessionIds(allocator, db, ws.?);
    defer workspace_scope.freeSessionIds(allocator, ws_ids);

    const list_limit = @min(input.limit, MAX_LIST_LIMIT);

    // Metadata for every workspace session except the caller's own —
    // unless `is_current_session` opted it back in.
    // Bound IN-list (never string-interpolated ids).
    var metas: std.ArrayList(SessionMeta) = .empty;
    errdefer {
        for (metas.items) |m| m.deinit(allocator);
        metas.deinit(allocator);
    }

    if (ws_ids.len > 0) {
        var sql: std.ArrayList(u8) = .empty;
        defer sql.deinit(allocator);
        try sql.appendSlice(allocator,
            \\SELECT s.id, COALESCE(s.name, ''), COALESCE(s.status, ''),
            \\  COUNT(h.id), COALESCE(MAX(h.created_at_nano), '')
            \\FROM sessions s LEFT JOIN llm_history h ON h.session_id = s.id
            \\WHERE s.id IN (
        );
        var bind_values: std.ArrayList([]const u8) = .empty;
        defer bind_values.deinit(allocator);
        for (ws_ids, 0..) |sid, i| {
            if (i > 0) try sql.append(allocator, ',');
            try sql.append(allocator, '?');
            try bind_values.append(allocator, sid);
        }
        try sql.appendSlice(allocator,
            \\)
            \\GROUP BY s.id
            \\ORDER BY COALESCE(MAX(h.created_at_nano), '') DESC, s.id ASC
        );

        var rows = try db.query(allocator, sql.items, bind_values.items);
        defer rows.deinit();
        while (try rows.next()) |row| {
            defer row.deinit(allocator);
            if (!input.is_current_session and std.mem.eql(u8, row.values[0], caller_session_id)) continue;
            if (metas.items.len >= list_limit) break;
            const preview = try latestUserPreview(allocator, db, row.values[0]);
            errdefer allocator.free(preview);
            try metas.append(allocator, .{
                .id = try allocator.dupe(u8, row.values[0]),
                .name = try allocator.dupe(u8, row.values[1]),
                .status = try allocator.dupe(u8, row.values[2]),
                .message_count = std.fmt.parseInt(u32, row.values[3], 10) catch 0,
                .last_activity = try allocator.dupe(u8, row.values[4]),
                .preview = preview,
            });
        }
    }

    const JsonSession = struct {
        id: []const u8,
        name: []const u8,
        status: []const u8,
        message_count: u32,
        last_activity: []const u8,
        preview: []const u8,
    };
    var clean = try allocator.alloc(JsonSession, metas.items.len);
    defer allocator.free(clean);
    var owned: std.ArrayList([]u8) = .empty;
    defer {
        for (owned.items) |s| allocator.free(s);
        owned.deinit(allocator);
    }
    for (metas.items, 0..) |m, i| {
        const id = try sanitize(allocator, m.id);
        try owned.append(allocator, id);
        const name = try sanitize(allocator, m.name);
        try owned.append(allocator, name);
        const status = try sanitize(allocator, m.status);
        try owned.append(allocator, status);
        const la = try sanitize(allocator, m.last_activity);
        try owned.append(allocator, la);
        const preview = try sanitize(allocator, m.preview);
        try owned.append(allocator, preview);
        clean[i] = .{
            .id = id,
            .name = name,
            .status = status,
            .message_count = m.message_count,
            .last_activity = la,
            .preview = preview,
        };
    }
    const out = try std.json.Stringify.valueAlloc(allocator, .{
        .behavior = "list",
        .limit = list_limit,
        .count = clean.len,
        .total_count = clean.len,
        .sessions = clean,
    }, .{});
    errdefer allocator.free(out);

    for (metas.items) |m| m.deinit(allocator);
    metas.deinit(allocator);
    return out;
}

/// First 100 chars of the latest user message in a session ("" when none).
fn latestUserPreview(
    allocator: std.mem.Allocator,
    db: *sqlite.SqliteBackend,
    session_id: []const u8,
) ![]u8 {
    var rows = try db.query(allocator,
        \\SELECT substr(COALESCE(response_content, ''), 1, 100) FROM llm_history
        \\WHERE session_id = ? AND role = 'user'
        \\ORDER BY rowid DESC LIMIT 1
    , &.{session_id});
    defer rows.deinit();
    if (try rows.next()) |row| {
        defer row.deinit(allocator);
        return try allocator.dupe(u8, row.values[0]);
    }
    return try allocator.dupe(u8, "");
}

fn executeSearch(
    allocator: std.mem.Allocator,
    db: *sqlite.SqliteBackend,
    ws_ids: ?[][]u8,
    within_session_id: ?[]const u8,
    feed_filter: llm_history.FeedFilter,
    input: ReadWorkspaceSessionInput,
) ![]const u8 {
    const effective_limit = @min(input.limit, 200);

    const opts = llm_history.SearchOptions{
        .session_id = within_session_id,
        .session_ids = if (ws_ids) |ids| ids else null,
        .role = if (input.role.len > 0) input.role else null,
        .since = if (input.since.len > 0) input.since else null,
        .until = if (input.until.len > 0) input.until else null,
        .feed_filter = feed_filter,
        .tool_name = if (input.tool_name.len > 0) input.tool_name else null,
        .parent_session_id = if (input.parent_session_id.len > 0) input.parent_session_id else null,
        .agent = if (input.agent.len > 0) input.agent else null,
        .limit = effective_limit,
        .offset = if (input.offset > 0) input.offset else null,
    };

    const hits = blk: {
        // An empty session-id set means "this workspace has no session other
        // than yours" (the caller is alone and is_current_session is false).
        // `searchMessagesFts` treats an empty `session_ids` as "no IN-clause"
        // and would return hits from EVERY workspace, so short-circuit to an
        // empty result set here instead.
        if (ws_ids) |ids| {
            if (ids.len == 0) break :blk try allocator.alloc(llm_history.SearchHit, 0);
        }
        break :blk llm_history.searchMessagesFts(allocator, db, input.query, opts) catch |err| {
            const msg = try std.fmt.allocPrint(allocator, "FTS search failed: {s}", .{@errorName(err)});
            defer allocator.free(msg);
            return jsonError(allocator, msg);
        };
    };
    defer {
        for (hits) |h| {
            var copy = h;
            copy.deinit(allocator);
        }
        allocator.free(hits);
    }

    const parsed_ids = try parseMessageIds(allocator, input.message_ids);
    defer {
        for (parsed_ids) |id| allocator.free(id);
        allocator.free(parsed_ids);
    }
    if (parsed_ids.len > MAX_MESSAGE_IDS) {
        const msg = try std.fmt.allocPrint(allocator, "Too many message_ids ({d} > max {d}). Split into batches of {d} or fewer.", .{ parsed_ids.len, MAX_MESSAGE_IDS, MAX_MESSAGE_IDS });
        defer allocator.free(msg);
        return jsonError(allocator, msg);
    }

    // Session names for the hits (readability — the LLM picks sessions by name).
    var names = try sessionNames(allocator, db, hits);
    defer {
        var it = names.iterator();
        while (it.next()) |e| {
            allocator.free(e.key_ptr.*);
            allocator.free(e.value_ptr.*);
        }
        names.deinit(allocator);
    }

    const total_count: u32 = if (hits.len > 0) hits[0].total_count else 0;
    const behavior: []const u8 = if (within_session_id != null) "search-within" else "search";

    const JsonHit = struct {
        id: []const u8,
        session_id: []const u8,
        session_name: ?[]const u8,
        role: []const u8,
        created_at: ?[]const u8,
        snippet: []const u8,
    };
    const JsonFull = struct {
        id: []const u8,
        session_id: []const u8,
        role: []const u8,
        content: []const u8,
        content_truncated: bool,
    };
    var owned: std.ArrayList([]u8) = .empty;
    defer {
        for (owned.items) |s| allocator.free(s);
        owned.deinit(allocator);
    }
    const clean_query = try sanitize(allocator, input.query);
    try owned.append(allocator, clean_query);
    const clean_within: ?[]u8 = if (within_session_id) |sid| try sanitize(allocator, sid) else null;
    if (clean_within) |s| try owned.append(allocator, s);

    var clean_hits = try allocator.alloc(JsonHit, hits.len);
    defer allocator.free(clean_hits);
    for (hits, 0..) |h, i| {
        const id = try sanitize(allocator, h.id);
        try owned.append(allocator, id);
        const sid = try sanitize(allocator, h.session_id);
        try owned.append(allocator, sid);
        const role = try sanitize(allocator, h.role);
        try owned.append(allocator, role);
        const snip = try sanitize(allocator, h.snippet);
        try owned.append(allocator, snip);
        const sname: ?[]u8 = if (names.get(h.session_id)) |n| try sanitize(allocator, n) else null;
        if (sname) |s| try owned.append(allocator, s);
        const ca: ?[]u8 = if (h.created_at.len > 0) try sanitize(allocator, h.created_at) else null;
        if (ca) |c| try owned.append(allocator, c);
        clean_hits[i] = .{
            .id = id,
            .session_id = sid,
            .session_name = sname,
            .role = role,
            .created_at = ca,
            .snippet = snip,
        };
    }

    // Full content block — workspace-scoped: ids resolving outside the
    // workspace are skipped, never leaked. Null when no message_ids
    // were requested.
    var clean_full: ?[]JsonFull = null;
    if (parsed_ids.len > 0) {
        const full_messages = llm_history.getMessagesByIds(allocator, db, parsed_ids) catch |err| {
            const msg = try std.fmt.allocPrint(allocator, "Database query failed: {s}", .{@errorName(err)});
            defer allocator.free(msg);
            return jsonError(allocator, msg);
        };
        defer {
            for (full_messages) |m| {
                var copy = m;
                copy.deinit(allocator);
            }
            allocator.free(full_messages);
        }

        var wanted: std.StringHashMapUnmanaged(void) = .empty;
        defer wanted.deinit(allocator);
        for (parsed_ids) |id| try wanted.put(allocator, id, {});

        var full_list: std.ArrayList(JsonFull) = .empty;
        defer full_list.deinit(allocator);
        for (full_messages) |m| {
            if (!wanted.contains(m.id)) continue;
            if (!isIdInWorkspace(ws_ids, within_session_id, m.session_id)) continue;
            const id = try sanitize(allocator, m.id);
            try owned.append(allocator, id);
            const sid = try sanitize(allocator, m.session_id);
            try owned.append(allocator, sid);
            const role = try sanitize(allocator, m.role);
            try owned.append(allocator, role);

            const was_truncated = m.content.len > MAX_FULL_CONTENT_BYTES;
            const content_src: []const u8 = if (was_truncated)
                m.content[0..MAX_FULL_CONTENT_BYTES]
            else
                m.content;
            const content = try sanitize(allocator, content_src);
            try owned.append(allocator, content);
            try full_list.append(allocator, .{
                .id = id,
                .session_id = sid,
                .role = role,
                .content = content,
                .content_truncated = was_truncated,
            });
        }
        clean_full = try full_list.toOwnedSlice(allocator);
    }
    defer if (clean_full) |s| allocator.free(s);

    return std.json.Stringify.valueAlloc(allocator, .{
        .behavior = behavior,
        .query = clean_query,
        .session_id = clean_within,
        .offset = input.offset,
        .limit = effective_limit,
        .count = clean_hits.len,
        .total_count = total_count,
        .results = clean_hits,
        .full_contents = clean_full,
    }, .{});
}

/// True when `session_id` belongs to the search scope: the workspace id
/// set, or the single within-session.
fn isIdInWorkspace(
    ws_ids: ?[][]u8,
    within_session_id: ?[]const u8,
    session_id: []const u8,
) bool {
    if (within_session_id) |sid| return std.mem.eql(u8, sid, session_id);
    if (ws_ids) |ids| {
        for (ids) |id| {
            if (std.mem.eql(u8, id, session_id)) return true;
        }
    }
    return false;
}

fn sessionNames(
    allocator: std.mem.Allocator,
    db: *sqlite.SqliteBackend,
    hits: []const llm_history.SearchHit,
) !std.StringHashMapUnmanaged([]u8) {
    var map: std.StringHashMapUnmanaged([]u8) = .empty;
    errdefer {
        var it = map.iterator();
        while (it.next()) |e| {
            allocator.free(e.key_ptr.*);
            allocator.free(e.value_ptr.*);
        }
        map.deinit(allocator);
    }
    // Distinct session ids only.
    var distinct: std.ArrayList([]const u8) = .empty;
    defer distinct.deinit(allocator);
    for (hits) |h| {
        var seen = false;
        for (distinct.items) |d| {
            if (std.mem.eql(u8, d, h.session_id)) {
                seen = true;
                break;
            }
        }
        if (!seen) try distinct.append(allocator, h.session_id);
    }
    if (distinct.items.len == 0) return map;

    var sql: std.ArrayList(u8) = .empty;
    defer sql.deinit(allocator);
    try sql.appendSlice(allocator, "SELECT id, COALESCE(name, '') FROM sessions WHERE id IN (");
    var bind_values: std.ArrayList([]const u8) = .empty;
    defer bind_values.deinit(allocator);
    for (distinct.items, 0..) |sid, i| {
        if (i > 0) try sql.append(allocator, ',');
        try sql.append(allocator, '?');
        try bind_values.append(allocator, sid);
    }
    try sql.append(allocator, ')');

    var rows = try db.query(allocator, sql.items, bind_values.items);
    defer rows.deinit();
    while (try rows.next()) |row| {
        defer row.deinit(allocator);
        const k = try allocator.dupe(u8, row.values[0]);
        errdefer allocator.free(k);
        const v = try allocator.dupe(u8, row.values[1]);
        try map.put(allocator, k, v);
    }
    return map;
}

fn executeRead(
    allocator: std.mem.Allocator,
    db: *sqlite.SqliteBackend,
    session_id: []const u8,
    feed_filter: llm_history.FeedFilter,
    input: ReadWorkspaceSessionInput,
) ![]const u8 {
    const parsed_ids = try parseMessageIds(allocator, input.message_ids);
    defer {
        for (parsed_ids) |id| allocator.free(id);
        allocator.free(parsed_ids);
    }
    if (parsed_ids.len > MAX_MESSAGE_IDS) {
        const msg = try std.fmt.allocPrint(allocator, "Too many message_ids ({d} > max {d}). Split into batches of {d} or fewer.", .{ parsed_ids.len, MAX_MESSAGE_IDS, MAX_MESSAGE_IDS });
        defer allocator.free(msg);
        return jsonError(allocator, msg);
    }
    const want_full = parsed_ids.len > 0;

    const order_enum: llm_history.CompactedMessagesOptions.Order = blk: {
        if (std.mem.eql(u8, input.order, "desc")) break :blk .desc;
        break :blk .asc;
    };

    const effective_limit = @min(input.limit, 200);

    const opts = llm_history.CompactedMessagesOptions{
        .message_ids = if (want_full) parsed_ids else null,
        .role = if (input.role.len > 0) input.role else null,
        .since = if (input.since.len > 0) input.since else null,
        .until = if (input.until.len > 0) input.until else null,
        .tool_name = if (input.tool_name.len > 0) input.tool_name else null,
        .parent_session_id = if (input.parent_session_id.len > 0) input.parent_session_id else null,
        .agent = if (input.agent.len > 0) input.agent else null,
        .limit = effective_limit,
        .feed_filter = feed_filter,
        .order = order_enum,
    };

    const messages = llm_history.getCompactedMessages(allocator, db, session_id, opts) catch |err| {
        const msg = try std.fmt.allocPrint(allocator, "Database query failed: {s}", .{@errorName(err)});
        defer allocator.free(msg);
        return jsonError(allocator, msg);
    };
    defer {
        for (messages) |m| {
            var copy = m;
            copy.deinit(allocator);
        }
        allocator.free(messages);
    }

    const total_count: u32 = if (messages.len > 0) messages[0].total_count else 0;

    var full_ids_set: std.StringHashMapUnmanaged(void) = .empty;
    defer full_ids_set.deinit(allocator);
    if (want_full) for (parsed_ids) |id| try full_ids_set.put(allocator, id, {});

    const JsonEntry = struct {
        id: []const u8,
        role: []const u8,
        created_at: ?[]const u8,
        preview: []const u8,
        tool_call_id: ?[]const u8,
        tool_name: ?[]const u8,
        content: ?[]const u8,
        content_truncated: ?bool,
    };
    var owned: std.ArrayList([]u8) = .empty;
    defer {
        for (owned.items) |s| allocator.free(s);
        owned.deinit(allocator);
    }
    const clean_sid = try sanitize(allocator, session_id);
    try owned.append(allocator, clean_sid);

    var clean_entries = try allocator.alloc(JsonEntry, messages.len);
    defer allocator.free(clean_entries);
    for (messages, 0..) |m, i| {
        const id = try sanitize(allocator, m.id);
        try owned.append(allocator, id);
        const role = try sanitize(allocator, m.role);
        try owned.append(allocator, role);
        const preview_src: []const u8 = if (m.content.len > 100) m.content[0..100] else m.content;
        const preview = try sanitize(allocator, preview_src);
        try owned.append(allocator, preview);
        const ca: ?[]u8 = if (m.created_at.len > 0) try sanitize(allocator, m.created_at) else null;
        if (ca) |c| try owned.append(allocator, c);

        const is_tool = std.mem.eql(u8, m.role, "tool");
        var tcid: ?[]u8 = null;
        var tn: ?[]u8 = null;
        if (is_tool) {
            if (m.tool_call_id) |t| {
                tcid = try sanitize(allocator, t);
                try owned.append(allocator, tcid.?);
            }
            if (m.tool_name) |t| {
                tn = try sanitize(allocator, t);
                try owned.append(allocator, tn.?);
            }
        }

        const want_content = want_full and full_ids_set.contains(m.id);
        var content: ?[]u8 = null;
        var was_truncated = false;
        if (want_content) {
            was_truncated = m.content.len > MAX_FULL_CONTENT_BYTES;
            const content_src: []const u8 = if (was_truncated)
                m.content[0..MAX_FULL_CONTENT_BYTES]
            else
                m.content;
            content = try sanitize(allocator, content_src);
            try owned.append(allocator, content.?);
        }
        clean_entries[i] = .{
            .id = id,
            .role = role,
            .created_at = ca,
            .preview = preview,
            .tool_call_id = tcid,
            .tool_name = tn,
            .content = content,
            .content_truncated = if (want_content) was_truncated else null,
        };
    }

    return std.json.Stringify.valueAlloc(allocator, .{
        .behavior = "read",
        .order = @tagName(order_enum),
        .session_id = clean_sid,
        .count = clean_entries.len,
        .total_count = total_count,
        .message_index = clean_entries,
    }, .{});
}

pub fn toJSONError(allocator: std.mem.Allocator, err_msg: []const u8) ![]u8 {
    return jsonError(allocator, err_msg);
}

const testing = std.testing;
const rws = @import("read_workspace_session.zig");

fn parseTestJson(alloc: std.mem.Allocator, out: []const u8) !std.json.Parsed(std.json.Value) {
    return std.json.parseFromSlice(std.json.Value, alloc, out, .{});
}

fn hasSessionId(sessions: std.json.Array, id: []const u8) bool {
    for (sessions.items) |s| {
        if (std.mem.eql(u8, s.object.get("id").?.string, id)) return true;
    }
    return false;
}

fn hasResultId(results: std.json.Array, id: []const u8) bool {
    for (results.items) |r| {
        if (std.mem.eql(u8, r.object.get("id").?.string, id)) return true;
    }
    return false;
}

const TestCtx = struct {
    db: sqlite.SqliteBackend,
    threaded: std.Io.Threaded,
};

fn setupDb() !TestCtx {
    const alloc = testing.allocator;
    var threaded = std.Io.Threaded.init(alloc, .{});
    errdefer threaded.deinit();
    const io = threaded.io();
    var db: sqlite.SqliteBackend = .{};
    errdefer db.deinit();
    try db.init(io, ":memory:");

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
        \\  created_iso TEXT DEFAULT (strftime('%Y-%m-%d %H:%M:%S', 'now'))
        \\)
    , &.{});
    try db.exec(alloc,
        \\CREATE VIRTUAL TABLE messages_fts USING fts5(
        \\    content
        \\)
    , &.{});
    try db.exec(alloc,
        \\CREATE TRIGGER llm_history_ai AFTER INSERT ON llm_history BEGIN
        \\  INSERT INTO messages_fts(rowid, content) VALUES (new.rowid, COALESCE(new.response_content, ''));
        \\END
    , &.{});
    try db.exec(alloc,
        \\CREATE TABLE sessions (
        \\  id TEXT PRIMARY KEY,
        \\  name TEXT NOT NULL,
        \\  status TEXT DEFAULT 'active',
        \\  cwd TEXT
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

    // Workspace w1: task-linked s1 + plain-chat s3 (cwd under /proj/a).
    // Workspace w2: task-linked s2.
    try db.exec(alloc,
        \\INSERT INTO workspace_items (id, workspace_id, item_type, name, path, position)
        \\VALUES ('i1', 'w1', 'kanban', 'A', '/proj/a', 1),
        \\       ('i2', 'w2', 'kanban', 'B', '/proj/b', 1)
    , &.{});
    try db.exec(alloc,
        \\INSERT INTO workspace_item_tasks (id, name, workspace_item_id)
        \\VALUES ('s1', 'T1', 'i1'), ('s2', 'T2', 'i2')
    , &.{});
    try db.exec(alloc,
        \\INSERT INTO sessions (id, name, status, cwd) VALUES
        \\  ('s1', 'Task one', 'active', '/proj/a'),
        \\  ('s2', 'Task two', 'active', '/proj/b'),
        \\  ('s3', 'Plain chat', 'active', '/proj/a/sub')
    , &.{});
    try db.exec(alloc,
        \\INSERT INTO llm_history (id, session_id, role, response_content, is_feed_to_llm)
        \\VALUES ('h1', 's1', 'user', 'the login bug needs fixing', 1),
        \\       ('h2', 's3', 'user', 'login page redesign notes', 0),
        \\       ('h3', 's2', 'user', 'unrelated deployment checklist', 1)
    , &.{});
    return .{ .db = db, .threaded = threaded };
}

test "read_workspace_session: LIST shows workspace peers, excludes self and other workspaces" {
    var s = try setupDb();
    defer {
        s.db.deinit();
        s.threaded.deinit();
    }
    const alloc = testing.allocator;

    const out = try rws.execute_read_workspace_session(alloc, s.threaded.io(), &s.db, "s1", .{});
    defer alloc.free(out);

    const parsed = try parseTestJson(alloc, out);
    defer parsed.deinit();
    const obj = parsed.value.object;
    try testing.expectEqualStrings("list", obj.get("behavior").?.string);
    const sessions = obj.get("sessions").?.array;
    // s3 (same workspace) listed with metadata.
    try testing.expect(hasSessionId(sessions, "s3"));
    var found_preview = false;
    for (sessions.items) |sess| {
        if (std.mem.eql(u8, sess.object.get("id").?.string, "s3")) {
            try testing.expectEqualStrings("Plain chat", sess.object.get("name").?.string);
            if (std.mem.indexOf(u8, sess.object.get("preview").?.string, "login page redesign notes") != null) {
                found_preview = true;
            }
        }
    }
    try testing.expect(found_preview);
    // Own session excluded, other workspace excluded.
    try testing.expect(!hasSessionId(sessions, "s1"));
    try testing.expect(!hasSessionId(sessions, "s2"));
    try testing.expectEqual(@as(i64, 1), obj.get("count").?.integer);
}

test "read_workspace_session: LIST includes the caller's own session only when opted in" {
    var s = try setupDb();
    defer {
        s.db.deinit();
        s.threaded.deinit();
    }
    const alloc = testing.allocator;

    const out = try rws.execute_read_workspace_session(alloc, s.threaded.io(), &s.db, "s1", .{
        .is_current_session = true,
    });
    defer alloc.free(out);

    const parsed = try parseTestJson(alloc, out);
    defer parsed.deinit();
    const obj = parsed.value.object;
    const sessions = obj.get("sessions").?.array;
    // s1 (caller) and s3 (peer) both listed; s2 is another workspace.
    try testing.expect(hasSessionId(sessions, "s1"));
    try testing.expect(hasSessionId(sessions, "s3"));
    try testing.expect(!hasSessionId(sessions, "s2"));
    try testing.expectEqual(@as(i64, 2), obj.get("count").?.integer);
}

test "read_workspace_session: SEARCH excludes the current session by default, includes it on opt-in" {
    var s = try setupDb();
    defer {
        s.db.deinit();
        s.threaded.deinit();
    }
    const alloc = testing.allocator;

    // h1 lives in s1, the caller — filtered out by default.
    const default_out = try rws.execute_read_workspace_session(alloc, s.threaded.io(), &s.db, "s1", .{
        .query = "login",
    });
    defer alloc.free(default_out);
    const default_parsed = try parseTestJson(alloc, default_out);
    defer default_parsed.deinit();
    const default_results = default_parsed.value.object.get("results").?.array;
    try testing.expect(!hasResultId(default_results, "h1"));
    try testing.expect(hasResultId(default_results, "h2"));

    // Opting back in surfaces the caller's own rows.
    const opted = try rws.execute_read_workspace_session(alloc, s.threaded.io(), &s.db, "s1", .{
        .query = "login",
        .is_current_session = true,
    });
    defer alloc.free(opted);
    const opted_parsed = try parseTestJson(alloc, opted);
    defer opted_parsed.deinit();
    const opted_results = opted_parsed.value.object.get("results").?.array;
    try testing.expect(hasResultId(opted_results, "h1"));
    try testing.expect(hasResultId(opted_results, "h2"));
}

test "read_workspace_session: SEARCH with no peer session returns empty, never a global hit" {
    var s = try setupDb();
    defer {
        s.db.deinit();
        s.threaded.deinit();
    }
    const alloc = testing.allocator;

    // w3 has exactly one session (s4) and it is the caller. Excluding the
    // caller leaves an empty id set — which must read as "no results", not
    // as "no filter", or the FTS query would sweep every workspace.
    try s.db.exec(alloc,
        \\INSERT INTO workspace_items (id, workspace_id, item_type, name, path, position)
        \\VALUES ('i3', 'w3', 'kanban', 'C', '/proj/c', 1)
    , &.{});
    try s.db.exec(
        alloc,
        "INSERT INTO sessions (id, name, status, cwd) VALUES ('s4', 'Alone', 'active', '/proj/c')",
        &.{},
    );
    // h4 is in w1 and h6 in the caller's w3: both match "unicorn".
    try s.db.exec(alloc,
        \\INSERT INTO llm_history (id, session_id, role, response_content, is_feed_to_llm)
        \\VALUES ('h4', 's3', 'user', 'unicorn parade downtown', 1),
        \\       ('h6', 's4', 'user', 'unicorn parade upstairs', 1)
    , &.{});

    const out = try rws.execute_read_workspace_session(alloc, s.threaded.io(), &s.db, "s4", .{
        .query = "unicorn",
    });
    defer alloc.free(out);
    const parsed = try parseTestJson(alloc, out);
    defer parsed.deinit();
    const obj = parsed.value.object;
    try testing.expectEqualStrings("search", obj.get("behavior").?.string);
    try testing.expectEqual(@as(i64, 0), obj.get("count").?.integer);
    try testing.expectEqual(@as(i64, 0), obj.get("total_count").?.integer);
    // Neither the other workspace's row nor the caller's own row leaks.
    const results = obj.get("results").?.array;
    try testing.expect(!hasResultId(results, "h4"));
    try testing.expect(!hasResultId(results, "h6"));

    // Opting in finds the caller's own row — and still nothing from w1.
    const opted = try rws.execute_read_workspace_session(alloc, s.threaded.io(), &s.db, "s4", .{
        .query = "unicorn",
        .is_current_session = true,
    });
    defer alloc.free(opted);
    const opted_parsed = try parseTestJson(alloc, opted);
    defer opted_parsed.deinit();
    const opted_results = opted_parsed.value.object.get("results").?.array;
    try testing.expect(hasResultId(opted_results, "h6"));
    try testing.expect(!hasResultId(opted_results, "h4"));
}

test "read_workspace_session: SEARCH is workspace-scoped" {
    var s = try setupDb();
    defer {
        s.db.deinit();
        s.threaded.deinit();
    }
    const alloc = testing.allocator;

    const out = try rws.execute_read_workspace_session(alloc, s.threaded.io(), &s.db, "s1", .{
        .query = "login",
        .is_current_session = true,
    });
    defer alloc.free(out);

    const parsed = try parseTestJson(alloc, out);
    defer parsed.deinit();
    const obj = parsed.value.object;
    try testing.expectEqualStrings("search", obj.get("behavior").?.string);
    const results = obj.get("results").?.array;
    try testing.expect(hasResultId(results, "h1"));
    try testing.expect(hasResultId(results, "h2"));
    // h3 lives in w2 — never surfaced.
    try testing.expect(!hasResultId(results, "h3"));

    // A term that exists ONLY in the other workspace returns zero hits.
    const out2 = try rws.execute_read_workspace_session(alloc, s.threaded.io(), &s.db, "s1", .{
        .query = "deployment",
    });
    defer alloc.free(out2);
    const parsed2 = try parseTestJson(alloc, out2);
    defer parsed2.deinit();
    try testing.expectEqual(@as(i64, 0), parsed2.value.object.get("count").?.integer);
}

test "read_workspace_session: READ same-workspace works, cross-workspace denied" {
    var s = try setupDb();
    defer {
        s.db.deinit();
        s.threaded.deinit();
    }
    const alloc = testing.allocator;

    const out = try rws.execute_read_workspace_session(alloc, s.threaded.io(), &s.db, "s1", .{
        .session_id = "s3",
    });
    defer alloc.free(out);
    const parsed = try parseTestJson(alloc, out);
    defer parsed.deinit();
    try testing.expectEqualStrings("read", parsed.value.object.get("behavior").?.string);
    try testing.expect(hasResultId(parsed.value.object.get("message_index").?.array, "h2"));

    const denied = try rws.execute_read_workspace_session(alloc, s.threaded.io(), &s.db, "s1", .{
        .session_id = "s2",
    });
    defer alloc.free(denied);
    const denied_parsed = try parseTestJson(alloc, denied);
    defer denied_parsed.deinit();
    try testing.expect(denied_parsed.value.object.get("denied").?.bool);
    // No content leaks through the denial.
    try testing.expect(std.mem.indexOf(u8, denied, "deployment") == null);
}

test "read_workspace_session: SEARCH-WITHIN gates the session first" {
    var s = try setupDb();
    defer {
        s.db.deinit();
        s.threaded.deinit();
    }
    const alloc = testing.allocator;

    const out = try rws.execute_read_workspace_session(alloc, s.threaded.io(), &s.db, "s1", .{
        .session_id = "s3",
        .query = "redesign",
    });
    defer alloc.free(out);
    const parsed = try parseTestJson(alloc, out);
    defer parsed.deinit();
    try testing.expectEqualStrings("search-within", parsed.value.object.get("behavior").?.string);
    try testing.expect(hasResultId(parsed.value.object.get("results").?.array, "h2"));

    const denied = try rws.execute_read_workspace_session(alloc, s.threaded.io(), &s.db, "s1", .{
        .session_id = "s2",
        .query = "deployment",
    });
    defer alloc.free(denied);
    const denied_parsed = try parseTestJson(alloc, denied);
    defer denied_parsed.deinit();
    try testing.expect(denied_parsed.value.object.get("denied").?.bool);
}

test "read_workspace_session: caller without workspace gets a clean error" {
    var s = try setupDb();
    defer {
        s.db.deinit();
        s.threaded.deinit();
    }
    const alloc = testing.allocator;

    try s.db.exec(alloc, "INSERT INTO sessions (id, name, status, cwd) VALUES ('sx', 'Lost', 'active', '/nowhere')", &.{});
    const out = try rws.execute_read_workspace_session(alloc, s.threaded.io(), &s.db, "sx", .{});
    defer alloc.free(out);
    const parsed = try parseTestJson(alloc, out);
    defer parsed.deinit();
    try testing.expect(std.mem.indexOf(u8, parsed.value.object.get("error").?.string, "not linked to any workspace") != null);
}

test "read_workspace_session: self-read refused by default, allowed on opt-in, guards enforced" {
    var s = try setupDb();
    defer {
        s.db.deinit();
        s.threaded.deinit();
    }
    const alloc = testing.allocator;

    // Reading your own session needs an explicit opt-in — otherwise the
    // response is a hint, not your own history back.
    const self = try rws.execute_read_workspace_session(alloc, s.threaded.io(), &s.db, "s1", .{
        .session_id = "s1",
    });
    defer alloc.free(self);
    const self_parsed = try parseTestJson(alloc, self);
    defer self_parsed.deinit();
    try testing.expectEqualStrings("read", self_parsed.value.object.get("behavior").?.string);
    try testing.expect(self_parsed.value.object.get("is_current_session").?.bool == false);
    try testing.expect(std.mem.indexOf(u8, self_parsed.value.object.get("error").?.string, "is_current_session=true") != null);
    // No content leaks through the refusal.
    try testing.expect(std.mem.indexOf(u8, self, "login bug") == null);

    // SEARCH-WITHIN on your own session is refused the same way.
    const self_search = try rws.execute_read_workspace_session(alloc, s.threaded.io(), &s.db, "s1", .{
        .session_id = "s1",
        .query = "login",
    });
    defer alloc.free(self_search);
    const self_search_parsed = try parseTestJson(alloc, self_search);
    defer self_search_parsed.deinit();
    try testing.expectEqualStrings("search-within", self_search_parsed.value.object.get("behavior").?.string);
    try testing.expect(std.mem.indexOf(u8, self_search_parsed.value.object.get("error").?.string, "is_current_session=true") != null);
    try testing.expect(std.mem.indexOf(u8, self_search, "login bug") == null);

    // Opting in restores the read.
    const opted = try rws.execute_read_workspace_session(alloc, s.threaded.io(), &s.db, "s1", .{
        .session_id = "s1",
        .is_current_session = true,
    });
    defer alloc.free(opted);
    const opted_parsed = try parseTestJson(alloc, opted);
    defer opted_parsed.deinit();
    try testing.expect(hasResultId(opted_parsed.value.object.get("message_index").?.array, "h1"));

    // live_only + compacted_only rejected.
    const both = try rws.execute_read_workspace_session(alloc, s.threaded.io(), &s.db, "s1", .{
        .session_id = "s3",
        .live_only = true,
        .compacted_only = true,
    });
    defer alloc.free(both);
    try testing.expect(std.mem.indexOf(u8, both, "mutually exclusive") != null);

    // message_ids cap enforced.
    const caps = try rws.execute_read_workspace_session(alloc, s.threaded.io(), &s.db, "s1", .{
        .session_id = "s3",
        .message_ids = "a,b,c,d,e,f,g,h,i,j,k,l,m,n,o,p,q,r,s,t,u,v,w,x,y,z,a1,b1,c1,d1,e1,f1,g1,h1,i1,j1,k1,l1,m1,n1,o1,p1,q1,r1,s1,t1,u1,v1,w1,x1,y1,z1,zz",
    });
    defer alloc.free(caps);
    try testing.expect(std.mem.indexOf(u8, caps, "Too many message_ids") != null);
}

test "read_workspace_session: tool schema advertises is_current_session and defaults it off" {
    // The JSON schema IS the wire contract with the LLM provider — the
    // registry HTTP endpoint only exposes {name, description}, so this is
    // the only place the new param can be asserted for the wire.
    const props = rws.read_workspace_session_tool.function.parameters.properties;

    var found = false;
    for (props) |p| {
        if (!std.mem.eql(u8, p.name, "is_current_session")) continue;
        found = true;
        try testing.expectEqualStrings("boolean", p.type);
        // The description has to say the default is off, otherwise the model
        // has no reason to ever set it.
        try testing.expect(std.mem.indexOf(u8, p.description, "Default false") != null);
    }
    try testing.expect(found);

    // Optional param — putting it in `required` would break every existing
    // call that omits it.
    for (rws.read_workspace_session_tool.function.parameters.required) |r| {
        try testing.expect(!std.mem.eql(u8, r, "is_current_session"));
    }

    // The struct default is what actually excludes the current session when
    // the model never sends the key at all.
    const default_input = ReadWorkspaceSessionInput{};
    try testing.expect(!default_input.is_current_session);

    // The tool description and system prompt both have to teach the flag, or
    // the model sees a param with no guidance.
    try testing.expect(std.mem.indexOf(u8, rws.read_workspace_session_tool.function.description, "is_current_session") != null);
    try testing.expect(std.mem.indexOf(u8, rws.read_workspace_session_tool_system_prompt, "is_current_session") != null);
}
