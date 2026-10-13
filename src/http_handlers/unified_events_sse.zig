//! Unified SSE stream endpoint for all server-pushed events.
//!
//! Replaces the 5 dedicated SSE routes registered in main.zig:
//!   - GET /api/workers/stream
//!   - GET /api/sessions/stream
//!   - GET /api/llm/stream/:session_id
//!   - GET /api/llm/session/:session_id/queue_messages/stream
//!   - GET /api/kanban/events
//!
//! The client opens ONE EventSource and declares which channel families
//! it cares about via the `?channels=` query parameter:
//!
//!   /api/events?channels=workers,sessions,kanban
//!   /api/events?channels=llm
//!   /api/events?channels=queue
//!   /api/events?channels=workers,sessions,kanban,llm,queue
//!
//! Channel tokens and the event_bus routing keys they fan out to:
//!   workers        → "workers"
//!   sessions       → "sessions"
//!   kanban         → "kanban_column", "kanban_task"
//!   design_element → "design_element" (central key — all workspaces' design
//!                    element create/update/delete events; the frontend
//!                    filters by `data.workspace_id` JS-side)
//!   llm            → "llm"          (central key — all sessions' LLM events)
//!   queue          → "queue"        (central key — all sessions' queue events)
//!   background_process → "background_process" (central key — all sessions'
//!                    background-process created/completed events; the
//!                    frontend filters by `data.session_id` JS-side)
//!   git_file_stage → "git_file_stage" (central key — the `git_file_staged` /
//!                    `git_file_unstaged` events emitted by
//!                    POST /api/git/stage and /api/git/unstage; the frontend
//!                    filters by `data.cwd` JS-side and moves ONE row instead
//!                    of re-fetching the whole git-status list)
//!   git_pr_state  → "git_pr_state" (central key — the `git_pr_state_merged` /
//!                    `git_pr_state_closed` events emitted by
//!                    POST /api/git/pr/merge and /api/git/pr/close; the
//!                    frontend invalidates the shared PR-status cache for
//!                    `data.cwd` + `data.branch`, so the sidebar branch icon and
//!                    the kanban card badge re-read after a merge)
//!
//! Plan: docs/superpowers/plans/2026-06-30-unify-sse-endpoints.md

const std = @import("std");
const pabrik_core = @import("pabrikcore");
const gserverz = pabrik_core.gserverz;
const ai_mod = pabrik_core.ai_mod;
const auth_common = @import("auth_common.zig");

/// Forward an SSE event to every client registered under `routing_key`.
///
/// Lifted verbatim from kanban_events_sse.zig:34-76. Subscription-lock-safe:
/// `getListClientsForSession` returns an owned copy of the client list, so
/// the SSE event loop can safely `unregisterSessionClient` on POLL.HUP
/// while we are still iterating here.
///
/// Per-user isolation (plan 2026-09-25, W3): the bus fans out by *family*
/// routing key, so without a filter every connected client receives every
/// user's events. Each client's owner is recorded at connect
/// (`registerClientOwner`); before sending, a client whose owner is a real
/// user and who cannot see `data.session_id` is skipped. An empty
/// `session_id` or an unknown owner (auth off) delivers, so the auth-off
/// path stays byte-identical.
fn forwardToClients(routing_key: []const u8, data: ai_mod.on_event_sent.SseEvent) void {
    const di = pabrik_core.getSingleton() catch return;
    const allocator = di.allocator;
    const server = di.server;

    const maybe_clients = ai_mod.getListClientsForSession(routing_key, allocator, false) catch return;
    defer if (maybe_clients) |c| allocator.free(c);
    const client_ids = maybe_clients orelse return;
    if (client_ids.len == 0) return;

    var buf: std.ArrayList(u8) = .empty;
    errdefer buf.deinit(allocator);

    if (data.event_type) |event_type| {
        buf.appendSlice(allocator, "event: ") catch return;
        buf.appendSlice(allocator, event_type) catch return;
        buf.append(allocator, '\n') catch return;
    }

    if (data.data.len == 0) {
        buf.appendSlice(allocator, "data: \n") catch return;
    } else {
        var iter = std.mem.splitScalar(u8, data.data, '\n');
        while (iter.next()) |line| {
            buf.appendSlice(allocator, "data: ") catch return;
            buf.appendSlice(allocator, line) catch return;
            buf.append(allocator, '\n') catch return;
        }
    }
    buf.append(allocator, '\n') catch return;

    const sse_event_data = buf.toOwnedSlice(allocator) catch return;
    defer allocator.free(sse_event_data);

    for (client_ids) |client_id| {
        if (!clientMayReceive(di, client_id, data)) continue;
        server.sse_manager.sendToClient(client_id, sse_event_data) catch {};
    }
}

/// True when the SSE client identified by `client_id` may receive an event
/// about `session_id`.
///
/// Deliver when:
///   - the client's owner is unknown (auth off / pre-registration), or
///   - the owner is the shared/system user (sees everything by decision), or
///   - the event's session cannot be resolved to a row the owner is denied.
///
/// Skip only for a real owner who is positively denied the event's session —
/// the leak this closes.
///
/// `SseEvent.session_id` is the real session id on the `sessions`, `llm`,
/// `queue` and `background_process` channels, but the *routing-key literal*
/// on `workers` ("workers") and `design_element` ("design_element") — those
/// publishers put the real id only in the JSON payload. So when the envelope
/// id does not name a session row, fall back to the payload's `session_id`
/// field before deciding; a payload that names no session either is
/// delivered (nothing to scope on).
fn clientMayReceive(di: *pabrik_core.App, client_id: [16]u8, data: ai_mod.on_event_sent.SseEvent) bool {
    const owner = pabrik_core.getClientOwner(client_id) orelse return true;
    if (auth_common.isSharedOwner(owner)) return true;

    // Resolve the session this event is about, then ask whether the owner
    // may see it. `null` means "cannot be attributed to a session" — deliver,
    // because there is nothing to scope on.
    const session_id = resolveEventSessionId(di.allocator, di.db, data) orelse return true;
    if (session_id.len == 0) return true;
    return auth_common.canSeeSession(di.allocator, di.db, session_id, owner);
}

/// Resolve the session id an SSE event is about, or null when it cannot be
/// attributed to one.
///
/// `SseEvent.session_id` is the real session id on the `sessions`, `llm`,
/// `queue` and `background_process` channels, but the *routing-key literal*
/// on `workers` ("workers") and `design_element` ("design_element") — those
/// publishers put the real id only in the JSON payload, and the worker
/// publishers leave the payload's `session_id` empty (the worker id is in
/// `id`). So the resolution order is:
///
///   1. the envelope id, when it names a session row;
///   2. the payload's `session_id`, when non-empty;
///   3. the payload's `id`, when it names a session row (worker events carry
///      the worker id there, and `worker.id` is not always the session id —
///      so also try the `worker` table's `session_id` for that id).
///
/// Returns an owned-by-arena slice (the fan-out is a short-lived callback).
fn resolveEventSessionId(
    allocator: std.mem.Allocator,
    db: *pabrikcore.sqlite.SqliteBackend,
    data: ai_mod.on_event_sent.SseEvent,
) ?[]const u8 {
    if (data.session_id.len > 0 and sessionRowExists(allocator, db, data.session_id)) {
        return data.session_id;
    }
    const payload = payloadFields(allocator, data.data) orelse return null;
    if (payload.session_id.len > 0) return payload.session_id;
    if (payload.id.len == 0) return null;
    if (sessionRowExists(allocator, db, payload.id)) return payload.id;
    // Worker events: `id` is the worker id; map it to its session.
    return workerSessionId(allocator, db, payload.id);
}

const PayloadFields = struct {
    session_id: []const u8 = "",
    id: []const u8 = "",
};

/// Extract `session_id` and `id` from an SSE payload. Null when the payload
/// is not a JSON object.
fn payloadFields(allocator: std.mem.Allocator, data: []const u8) ?PayloadFields {
    if (data.len == 0) return null;
    const parsed = std.json.parseFromSliceLeaky(std.json.Value, allocator, data, .{}) catch return null;
    const obj = switch (parsed) {
        .object => |o| o,
        else => return null,
    };
    var out = PayloadFields{};
    if (obj.get("session_id")) |v| {
        if (v == .string) out.session_id = v.string;
    }
    if (obj.get("id")) |v| {
        if (v == .string) out.id = v.string;
    }
    return out;
}

fn sessionRowExists(allocator: std.mem.Allocator, db: *pabrikcore.sqlite.SqliteBackend, id: []const u8) bool {
    if (id.len == 0) return false;
    var q = db.query(allocator, "SELECT 1 FROM sessions WHERE id = ?", &[_][]const u8{id}) catch return false;
    defer q.deinit();
    const row = q.next() catch return false;
    if (row) |r| {
        r.deinit(allocator);
        return true;
    }
    return false;
}

fn workerSessionId(allocator: std.mem.Allocator, db: *pabrikcore.sqlite.SqliteBackend, worker_id: []const u8) ?[]const u8 {
    if (worker_id.len == 0) return null;
    var q = db.query(allocator, "SELECT session_id FROM worker WHERE id = ?", &[_][]const u8{worker_id}) catch return null;
    defer q.deinit();
    const row = q.next() catch return null;
    const r = row orelse return null;
    defer r.deinit(allocator);
    if (r.values.len == 0) return null;
    return allocator.dupe(u8, r.values[0]) catch null;
}

/// ChannelList — the parsed result of `?channels=`.
pub const ChannelList = struct {
    /// Each entry is a routing key the handler must subscribe a
    /// callback to. Duplicates are not deduplicated (the SSE
    /// event_bus handles duplicate subscribers without error).
    routing_keys: []const []const u8,

    pub fn deinit(self: ChannelList, allocator: std.mem.Allocator) void {
        for (self.routing_keys) |k| allocator.free(k);
        allocator.free(self.routing_keys);
    }
};

/// Parse `?channels=workers,sessions,kanban,llm,queue`.
/// Returns the list of routing keys to subscribe + register. Returns
/// ChannelParseError on missing/empty/unknown channel tokens.
pub const ChannelParseError = error{
    MissingChannels,
    UnknownChannel,
    OutOfMemory,
};

/// `pub` so `unified_events_sse_test.zig` can import it for behavioral
/// tests (Plan Reviewer finding #3). The `pub` is harmless — the
/// function is only called from `unifiedEventsStreamHandler`.
pub fn parseChannels(allocator: std.mem.Allocator, raw: []const u8) ChannelParseError!ChannelList {
    // Trim whitespace from the raw value (the router does not trim).
    const trimmed = std.mem.trim(u8, raw, " \t");
    if (trimmed.len == 0) return error.MissingChannels;

    var routing_keys: std.ArrayListUnmanaged([]const u8) = .empty;
    errdefer {
        for (routing_keys.items) |k| allocator.free(k);
        routing_keys.deinit(allocator);
    }

    var iter = std.mem.splitScalar(u8, trimmed, ',');
    while (iter.next()) |token_raw| {
        const token = std.mem.trim(u8, token_raw, " \t");
        if (token.len == 0) continue; // skip empty tokens (e.g. ",,,")

        if (std.mem.eql(u8, token, "workers")) {
            try routing_keys.append(allocator, try allocator.dupe(u8, "workers"));
        } else if (std.mem.eql(u8, token, "sessions")) {
            try routing_keys.append(allocator, try allocator.dupe(u8, "sessions"));
        } else if (std.mem.eql(u8, token, "kanban")) {
            try routing_keys.append(allocator, try allocator.dupe(u8, "kanban_column"));
            try routing_keys.append(allocator, try allocator.dupe(u8, "kanban_task"));
        } else if (std.mem.eql(u8, token, "llm")) {
            try routing_keys.append(allocator, try allocator.dupe(u8, "llm"));
        } else if (std.mem.eql(u8, token, "queue")) {
            try routing_keys.append(allocator, try allocator.dupe(u8, "queue"));
        } else if (std.mem.eql(u8, token, "background_process")) {
            // Background-process lifecycle (`background_process_created` /
            // `background_process_completed` on the central
            // "background_process" key — see background_process_events.zig).
            // Single key covers both granular event types; the frontend
            // filters by `data.session_id` JS-side.
            try routing_keys.append(allocator, try allocator.dupe(u8, "background_process"));
        } else if (std.mem.eql(u8, token, "skill_evals")) {
            // Skill-eval lifecycle (`skill_evals_run_started` /
            // `_run_finished` / `_result_applied` on the central
            // "skill_evals" key — see skill_eval_events.zig). Single key
            // covers all three granular event types; the frontend filters
            // by `data.session_id` JS-side.
            try routing_keys.append(allocator, try allocator.dupe(u8, "skill_evals"));
        } else if (std.mem.eql(u8, token, "git_file_stage")) {
            // File stage/unstage (`git_file_staged` / `git_file_unstaged` on
            // the central "git_file_stage" key — see
            // git_file_stage_events.zig). Single key covers both granular
            // event types; the frontend filters by `data.cwd` JS-side.
            try routing_keys.append(allocator, try allocator.dupe(u8, "git_file_stage"));
        } else if (std.mem.eql(u8, token, "git_pr_state")) {
            // Change-request state (`git_pr_state_merged` /
            // `git_pr_state_closed` on the central "git_pr_state" key — see
            // git_pr_state_events.zig). Single key covers both granular event
            // types; the frontend filters by `data.cwd` JS-side and drops the
            // shared PR-status cache entry for `data.branch`.
            try routing_keys.append(allocator, try allocator.dupe(u8, "git_pr_state"));
        } else if (std.mem.eql(u8, token, "design_element")) {
            // Design-mode element mutations. The frontend
            // `createUnifiedSseConnection` sends this token; the
            // backend's `on_event_sent_design.zig` emits
            // `design_element_created/updated/deleted` on the central
            // "design_element" routing key. The single key covers all
            // three granular event types (the action discriminator
            // tells them apart JS-side).
            try routing_keys.append(allocator, try allocator.dupe(u8, "design_element"));
        } else {
            return error.UnknownChannel;
        }
    }

    // If the raw value was non-empty but every comma-delimited token
    // was empty (e.g. ",,,"), we still need to error. The trim+skip
    // path above would leave routing_keys empty without an explicit
    // error here — guard against that.
    if (routing_keys.items.len == 0) return error.MissingChannels;

    return ChannelList{ .routing_keys = try routing_keys.toOwnedSlice(allocator) };
}

// =============================================================================
// Callback structs (top-level, NOT inline).
//
// Each routing key gets its own callback. The routing key itself is
// hard-coded into the callback body — there's no closure capture of a
// loop variable (Pitfall 1: inline-struct capture trap). The handler
// picks the right callback by inspecting the routing-key SHAPE with
// an if/else chain (mirrors kanban_events_sse.zig:79-90).
// =============================================================================

/// Callback for `kanban_column` routing key — fires on column create/update/delete.
pub const CallbackUnifiedColumnStream = struct {
    pub fn callback(data: ai_mod.on_event_sent.SseEvent) void {
        forwardToClients("kanban_column", data);
    }
};

/// Callback for `kanban_task` routing key.
pub const CallbackUnifiedTaskStream = struct {
    pub fn callback(data: ai_mod.on_event_sent.SseEvent) void {
        forwardToClients("kanban_task", data);
    }
};

/// Callback for `workers` routing key.
pub const CallbackUnifiedWorkersStream = struct {
    pub fn callback(data: ai_mod.on_event_sent.SseEvent) void {
        forwardToClients("workers", data);
    }
};

/// Callback for `sessions` routing key.
pub const CallbackUnifiedSessionsStream = struct {
    pub fn callback(data: ai_mod.on_event_sent.SseEvent) void {
        forwardToClients("sessions", data);
    }
};

/// Callback for the central "llm" routing key. Forwards to every
/// client registered under "llm" — the frontend listener then
/// filters by `data.session_id` on the JS side.
pub const CallbackUnifiedLLMBroadcast = struct {
    pub fn callback(data: ai_mod.on_event_sent.SseEvent) void {
        forwardToClients("llm", data);
    }
};

/// Callback for the central "queue" routing key. Forwards to every
/// client registered under "queue" — the frontend listener then
/// filters by `data.session_id` on the JS side.
pub const CallbackUnifiedQueueBroadcast = struct {
    pub fn callback(data: ai_mod.on_event_sent.SseEvent) void {
        forwardToClients("queue", data);
    }
};

/// Callback for the central "design_element" routing key. Forwards
/// to every client registered under "design_element" — the frontend
/// listener (`designSse.ts` Pinia store) then filters by
/// `data.workspace_id` on the JS side and dispatches to the
/// `workspacesStore.fetchDesignElements` action.
pub const CallbackUnifiedDesignElementStream = struct {
    pub fn callback(data: ai_mod.on_event_sent.SseEvent) void {
        forwardToClients("design_element", data);
    }
};

/// Callback for the central "background_process" routing key. Forwards
/// to every client registered under "background_process" — the frontend
/// listener (`BackgroundCommandsPopup.vue`) then filters by
/// `data.session_id` on the JS side and re-fetches the list.
pub const CallbackUnifiedBackgroundProcessStream = struct {
    pub fn callback(data: ai_mod.on_event_sent.SseEvent) void {
        forwardToClients("background_process", data);
    }
};

/// Callback for the central "skill_evals" routing key. Forwards to every
/// client registered under "skill_evals" — the frontend listener then
/// filters by `data.session_id` on the JS side and re-fetches the eval
/// list for the Evals tab.
pub const CallbackUnifiedSkillEvalsStream = struct {
    pub fn callback(data: ai_mod.on_event_sent.SseEvent) void {
        forwardToClients("skill_evals", data);
    }
};

/// Callback for the central "git_file_stage" routing key. Forwards to every
/// client registered under "git_file_stage" — the frontend listener
/// (`SidebarDiffPanel.vue`) then filters by `data.cwd` on the JS side and
/// moves the ONE row the event names, instead of re-fetching the whole
/// git-status list.
pub const CallbackUnifiedGitFileStageStream = struct {
    pub fn callback(data: ai_mod.on_event_sent.SseEvent) void {
        forwardToClients("git_file_stage", data);
    }
};

/// Callback for the central "git_pr_state" routing key. Forwards to every
/// client registered under "git_pr_state" — the frontend listener then filters
/// by `data.cwd` / `data.branch` on the JS side and drops the shared PR-status
/// cache entry for that pair, so every badge (sidebar RECENT icon, kanban card)
/// re-reads the forge after a merge or close, in every tab.
pub const CallbackUnifiedGitPrStateStream = struct {
    pub fn callback(data: ai_mod.on_event_sent.SseEvent) void {
        forwardToClients("git_pr_state", data);
    }
};

/// Terminate an SSE stream the handler cannot serve (auth failure,
/// missing/empty/unknown `?channels=`).
///
/// kabelweb sends the `200 text/event-stream` headers AND registers the
/// fd BEFORE this handler runs, so a bare `return res.jsonResponse(...)`
/// never reaches the wire — without this call the browser holds an
/// immortal ping-only stream that never emits `event: connected`, and
/// the frontend SseClient sits in 'connecting' forever. Sends an
/// optional terminal named event, then removes the client so the
/// browser's EventSource errors out promptly instead of hanging.
fn terminateSseStream(ctx: gserverz.HttpContext, event_name: ?[]const u8, data_json: []const u8) void {
    const cid = ctx.client_id orelse return;
    const di = pabrik_core.getSingleton() catch return;
    if (event_name) |name| {
        var buf: [256]u8 = undefined;
        const frame = std.fmt.bufPrint(&buf, "event: {s}\ndata: {s}\n\n", .{ name, data_json }) catch return;
        di.server.sse_manager.sendToClient(cid, frame) catch {};
    }
    di.server.sse_manager.removeClient(cid, .explicit_shutdown);
}

/// SSE stream endpoint — single endpoint for all server-pushed events.
///
/// The `?channels=` query parameter is REQUIRED. Missing/empty/unknown
/// values terminate the stream (see `terminateSseStream` — a JSON error
/// body can never reach the wire once kabelweb has sent the SSE
/// headers).
pub fn unifiedEventsStreamHandler(
    ctx: gserverz.HttpContext,
    req: gserverz.HttpRequest,
    res: gserverz.HttpResponse,
) !gserverz.HttpResponse {
    const allocator = ctx.allocator;

    // Manual auth gate: kabelweb sse() does not run middleware.
    // The rejection paths terminate the stream explicitly — the 401
    // JSON below is type-compat only and never reaches the wire
    // (headers already sent); the `auth_error` event + removeClient
    // in terminateSseStream are what the browser actually observes.
    //
    // The resolved owner is kept for the per-user fan-out filter (W3):
    // it is recorded against this client_id below, so `forwardToClients`
    // can drop events about sessions this user cannot see.
    var owner_buf: ?[]const u8 = null;
    defer {
        if (owner_buf) |o| allocator.free(o);
    }
    if (pabrik_core.getSingleton()) |di_gate| {
        if (di_gate.auth_enabled) {
            const tok = auth_common.parseSessionToken(req.headers) orelse {
                terminateSseStream(ctx, "auth_error", "{\"error\":\"Unauthenticated\"}");
                return res.jsonResponse(.{ .status_code = 401, .data = "{\"error\":\"Unauthenticated\"}" });
            };
            const sess = auth_common.lookupSession(allocator, di_gate.db, tok) orelse {
                terminateSseStream(ctx, "auth_error", "{\"error\":\"Unauthenticated\"}");
                return res.jsonResponse(.{ .status_code = 401, .data = "{\"error\":\"Unauthenticated\"}" });
            };
            owner_buf = allocator.dupe(u8, sess.user_id) catch null;
            auth_common.freeSessionLookup(allocator, sess);
        }
    } else |_| {}

    // 1. Parse ?channels=
    const raw_channels = req.query.get("channels") orelse {
        terminateSseStream(ctx, null, "");
        return res.jsonResponse(.{
            .status_code = 400,
            .data = try std.fmt.allocPrint(allocator,
                \\{{"error":"missing channels query parameter"}}
            , .{}),
        });
    };
    var channels = parseChannels(allocator, raw_channels) catch |err| switch (err) {
        error.MissingChannels => {
            terminateSseStream(ctx, null, "");
            return res.jsonResponse(.{
                .status_code = 400,
                .data = try std.fmt.allocPrint(allocator,
                    \\{{"error":"missing or empty channels query parameter"}}
                , .{}),
            });
        },
        error.UnknownChannel => {
            terminateSseStream(ctx, null, "");
            return res.jsonResponse(.{
                .status_code = 400,
                .data = try std.fmt.allocPrint(allocator,
                    \\{{"error":"unknown channel in {s}"}}
                , .{raw_channels}),
            });
        },
        error.OutOfMemory => return error.OutOfMemory,
    };
    defer channels.deinit(allocator);

    // 2. Register + subscribe
    const di = try pabrik_core.getSingleton();
    const event_bus = di.event_bus;
    const server = di.server;

    if (ctx.client_id) |client_id| {
        const client_id_copy: [16]u8 = client_id;

        // 2a. Record this client's owner for the per-user fan-out filter
        // (W3). Absent/unknown owner => the fan-out delivers, so auth-off
        // (owner_buf == null) stays byte-identical.
        if (owner_buf) |o| {
            pabrik_core.registerClientOwner(client_id_copy, o);
        }

        // 2b. Register the client_id under EVERY routing key.
        // registerSessionClient dupes the key internally, so we can
        // pass each entry of channels.routing_keys (already-owned
        // slices) directly.
        for (channels.routing_keys) |rk| {
            ai_mod.registerSessionClient(rk, client_id_copy, true) catch {};
        }

        // 2b. Subscribe ONE callback per routing key. The callback
        // looks up the client list for ITS OWN routing key only —
        // see forwardToClients.
        for (channels.routing_keys) |rk| {
            // event_bus.subscribe dupes the key internally, so we can
            // pass each entry directly and it remains valid for the
            // call. See worker_sse.zig:81 and kanban_events_sse.zig:117.
            if (std.mem.eql(u8, rk, "kanban_column")) {
                event_bus.subscribe(ai_mod.on_event_sent.SseEvent, rk, CallbackUnifiedColumnStream.callback) catch {};
            } else if (std.mem.eql(u8, rk, "kanban_task")) {
                event_bus.subscribe(ai_mod.on_event_sent.SseEvent, rk, CallbackUnifiedTaskStream.callback) catch {};
            } else if (std.mem.eql(u8, rk, "workers")) {
                event_bus.subscribe(ai_mod.on_event_sent.SseEvent, rk, CallbackUnifiedWorkersStream.callback) catch {};
            } else if (std.mem.eql(u8, rk, "sessions")) {
                event_bus.subscribe(ai_mod.on_event_sent.SseEvent, rk, CallbackUnifiedSessionsStream.callback) catch {};
            } else if (std.mem.eql(u8, rk, "llm")) {
                event_bus.subscribe(ai_mod.on_event_sent.SseEvent, rk, CallbackUnifiedLLMBroadcast.callback) catch {};
            } else if (std.mem.eql(u8, rk, "queue")) {
                event_bus.subscribe(ai_mod.on_event_sent.SseEvent, rk, CallbackUnifiedQueueBroadcast.callback) catch {};
            } else if (std.mem.eql(u8, rk, "design_element")) {
                event_bus.subscribe(ai_mod.on_event_sent.SseEvent, rk, CallbackUnifiedDesignElementStream.callback) catch {};
            } else if (std.mem.eql(u8, rk, "background_process")) {
                event_bus.subscribe(ai_mod.on_event_sent.SseEvent, rk, CallbackUnifiedBackgroundProcessStream.callback) catch {};
            } else if (std.mem.eql(u8, rk, "skill_evals")) {
                event_bus.subscribe(ai_mod.on_event_sent.SseEvent, rk, CallbackUnifiedSkillEvalsStream.callback) catch {};
            } else if (std.mem.eql(u8, rk, "git_file_stage")) {
                event_bus.subscribe(ai_mod.on_event_sent.SseEvent, rk, CallbackUnifiedGitFileStageStream.callback) catch {};
            } else if (std.mem.eql(u8, rk, "git_pr_state")) {
                event_bus.subscribe(ai_mod.on_event_sent.SseEvent, rk, CallbackUnifiedGitPrStateStream.callback) catch {};
            }
        }

        // 3. Send the connected handshake (the verbatim byte sequence
        //    pinned by sse_handshake_test.zig:12).
        const connected_event = "event: connected\ndata: {\"connected\": true}\n\n";
        server.sse_manager.sendToClient(client_id_copy, connected_event) catch {};
    }

    return error.WouldBlock; // Keep connection open
}

// ===== Tests merged from sse_handshake_test.zig (2026-09-11 flatten) =====
// Regression test for the SSE `connected` event handshake.
//
// Why this file exists
// ────────────────────
// The frontend `SseStatusBadge`
// (src/apps/desktop/src/components/SseStatusBadge.vue) and the
// `SseClient` state machine
// (src/apps/desktop/src/helpers/sseClient.ts) only transition
// from `'connecting'` to `'open'` when the server sends the SSE
// `connected` named event:
//
//     event: connected\ndata: {"connected": true}\n\n
//
// Two of the four legacy backend SSE handlers used to skip this
// handshake, leaving the badge stuck on "Connecting…" forever
// (the stream was alive and streaming, but the badge had no
// signal to hide). See docs/plans/2026-06-05-stuck-connecting-badge.md
// for the full trace.
//
// After the 5→1 SSE endpoint unification (plan
// docs/superpowers/plans/2026-06-30-unify-sse-endpoints.md),
// only ONE backend SSE handler is registered
// (`unified_events_sse.zig`), so its `sendToClient` of the
// handshake is the single place the badge can get unstuck.
//
// The contract belongs in the python functional harness under
// tests/functional/: connect to the SSE endpoint and assert the
// first frame is `event: connected`. A source grep cannot fail for
// a behaviour break here — it only fails for a rename.

const pabrikcore = @import("pabrikcore");
const testing = std.testing;

// ─── Behavioral tests for parseChannels ────────────────────────────────
//
// Plan Reviewer finding #3: source-grep contracts only verify
// the file's shape, not the parser's correctness. A typo in the
// bare `llm`/`queue` token names, or an off-by-one in the kanban
// expansion would silently drop events in production. These
// behavioral tests pin the parser contract.
//
// To make `parseChannels` testable from this file, the production
// code must expose it as `pub fn` (currently `fn`). Chunk 1.1's
// implementation step promotes it to `pub`.

test "parseChannels: workers → 1 routing key" {
    const allocator = testing.allocator;
    const list = try parseChannels(allocator, "workers");
    defer list.deinit(allocator);
    try testing.expectEqual(@as(usize, 1), list.routing_keys.len);
    try testing.expectEqualStrings("workers", list.routing_keys[0]);
}

test "parseChannels: sessions,kanban → 3 routing keys (kanban expands)" {
    const allocator = testing.allocator;
    const list = try parseChannels(allocator, "sessions,kanban");
    defer list.deinit(allocator);
    try testing.expectEqual(@as(usize, 3), list.routing_keys.len);
    try testing.expectEqualStrings("sessions", list.routing_keys[0]);
    try testing.expectEqualStrings("kanban_column", list.routing_keys[1]);
    try testing.expectEqualStrings("kanban_task", list.routing_keys[2]);
}

test "parseChannels: llm:<sid> → error.UnknownChannel (superseded by bare 'llm')" {
    try testing.expectError(error.UnknownChannel, parseChannels(testing.allocator, "llm:chat-123"));
}

test "parseChannels: queue:<sid> → error.UnknownChannel (superseded by bare 'queue')" {
    try testing.expectError(error.UnknownChannel, parseChannels(testing.allocator, "queue:chat-abc"));
}

test "parseChannels: bare 'llm' → central 'llm' routing key" {
    const allocator = testing.allocator;
    const list = try parseChannels(allocator, "llm");
    defer list.deinit(allocator);
    try testing.expectEqual(@as(usize, 1), list.routing_keys.len);
    try testing.expectEqualStrings("llm", list.routing_keys[0]);
}

test "parseChannels: bare 'queue' → central 'queue' routing key" {
    const allocator = testing.allocator;
    const list = try parseChannels(allocator, "queue");
    defer list.deinit(allocator);
    try testing.expectEqual(@as(usize, 1), list.routing_keys.len);
    try testing.expectEqualStrings("queue", list.routing_keys[0]);
}

test "parseChannels: mixed 5 channels (bare llm+queue) → 6 routing keys (kanban expands)" {
    const allocator = testing.allocator;
    const list = try parseChannels(allocator, "workers,sessions,kanban,llm,queue");
    defer list.deinit(allocator);
    try testing.expectEqual(@as(usize, 6), list.routing_keys.len);
    // workers, sessions, kanban_column, kanban_task, llm, queue (in registration order)
    try testing.expectEqualStrings("workers", list.routing_keys[0]);
    try testing.expectEqualStrings("sessions", list.routing_keys[1]);
    try testing.expectEqualStrings("kanban_column", list.routing_keys[2]);
    try testing.expectEqualStrings("kanban_task", list.routing_keys[3]);
    try testing.expectEqualStrings("llm", list.routing_keys[4]);
    try testing.expectEqualStrings("queue", list.routing_keys[5]);
}

test "parseChannels: multiple bare tokens (llm+queue repeated) → 2 keys" {
    const allocator = testing.allocator;
    // Bare 'llm' and 'queue' tokens each register once under their
    // central key. The ChannelList does NOT deduplicate (see the
    // ChannelList docstring); the SSE event_bus handles duplicate
    // subscribers without error.
    const list = try parseChannels(allocator, "llm,llm,queue,queue");
    defer list.deinit(allocator);
    try testing.expectEqual(@as(usize, 4), list.routing_keys.len);
    try testing.expectEqualStrings("llm", list.routing_keys[0]);
    try testing.expectEqualStrings("llm", list.routing_keys[1]);
    try testing.expectEqualStrings("queue", list.routing_keys[2]);
    try testing.expectEqualStrings("queue", list.routing_keys[3]);
}

test "parseChannels: bare 'git_file_stage' → central 'git_file_stage' routing key" {
    const allocator = testing.allocator;
    const list = try parseChannels(allocator, "git_file_stage");
    defer list.deinit(allocator);
    try testing.expectEqual(@as(usize, 1), list.routing_keys.len);
    try testing.expectEqualStrings("git_file_stage", list.routing_keys[0]);
}

test "parseChannels: empty string → error.MissingChannels" {
    const allocator = testing.allocator;
    try testing.expectError(error.MissingChannels, parseChannels(allocator, ""));
}

test "parseChannels: whitespace-only → error.MissingChannels" {
    const allocator = testing.allocator;
    try testing.expectError(error.MissingChannels, parseChannels(allocator, "   "));
}

test "parseChannels: only commas → error.MissingChannels" {
    const allocator = testing.allocator;
    try testing.expectError(error.MissingChannels, parseChannels(allocator, ",,,"));
}

test "parseChannels: unknown channel → error.UnknownChannel" {
    const allocator = testing.allocator;
    try testing.expectError(error.UnknownChannel, parseChannels(allocator, "foo"));
}

test "parseChannels: llm: (per-session token removed) → error.UnknownChannel" {
    const allocator = testing.allocator;
    try testing.expectError(error.UnknownChannel, parseChannels(allocator, "llm:"));
}

test "parseChannels: queue: (per-session token removed) → error.UnknownChannel" {
    const allocator = testing.allocator;
    try testing.expectError(error.UnknownChannel, parseChannels(allocator, "queue:"));
}

test "parseChannels: trims whitespace around tokens" {
    const allocator = testing.allocator;
    const list = try parseChannels(allocator, "  workers , sessions  ");
    defer list.deinit(allocator);
    try testing.expectEqual(@as(usize, 2), list.routing_keys.len);
    try testing.expectEqualStrings("workers", list.routing_keys[0]);
    try testing.expectEqualStrings("sessions", list.routing_keys[1]);
}

// ===== Per-user fan-out filter (plan 2026-09-25, W3) =====================
//
// The bus fans out by family routing key, so the fan-out must resolve which
// session an event is about before deciding whether a client may see it.
// `SseEvent.session_id` is the real session id on the `sessions`/`llm`/
// `queue`/`background_process` channels but the routing-key literal on
// `workers`/`design_element`, and the worker publishers leave the payload's
// `session_id` empty (the worker id is in `id`). These tests pin the
// resolution order so a future publisher change cannot silently reopen the
// leak (an unresolvable event is delivered, so a wrong resolution is a leak,
// not a dropped frame).

fn testDb(alloc: std.mem.Allocator) !pabrikcore.sqlite.SqliteBackend {
    var db: pabrikcore.sqlite.SqliteBackend = .{};
    try db.init(std.testing.io, ":memory:");
    try db.exec(alloc, "CREATE TABLE sessions (id TEXT PRIMARY KEY, user_id TEXT)", &.{});
    try db.exec(alloc, "CREATE TABLE worker (id TEXT PRIMARY KEY, session_id TEXT)", &.{});
    try db.exec(alloc, "INSERT INTO sessions (id, user_id) VALUES ('s_a','user_a'), ('s_b','user_b')", &.{});
    try db.exec(alloc, "INSERT INTO worker (id, session_id) VALUES ('w_a','s_a')", &.{});
    return db;
}

test "resolveEventSessionId: envelope id wins when it names a session" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    var db = try testDb(alloc);
    defer db.deinit();

    const ev = ai_mod.on_event_sent.SseEvent{ .session_id = "s_a", .data = "{}" };
    const resolved = resolveEventSessionId(alloc, &db, ev) orelse return error.NotResolved;
    try std.testing.expectEqualStrings("s_a", resolved);
}

test "resolveEventSessionId: routing-key literal falls back to the payload session_id" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    var db = try testDb(alloc);
    defer db.deinit();

    // The `workers` channel sets the envelope id to the literal "workers".
    const ev = ai_mod.on_event_sent.SseEvent{
        .session_id = "workers",
        .data = "{\"action\":\"updated\",\"id\":\"w_a\",\"session_id\":\"s_a\"}",
    };
    const resolved = resolveEventSessionId(alloc, &db, ev) orelse return error.NotResolved;
    try std.testing.expectEqualStrings("s_a", resolved);
}

test "resolveEventSessionId: worker event with empty payload session_id maps id -> worker.session_id" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    var db = try testDb(alloc);
    defer db.deinit();

    // `llm_history.updateWorkerActivity` emits exactly this shape: the
    // envelope id is "workers", the payload's session_id is empty, and the
    // worker id is in `id`. Without the worker-table hop this event would be
    // delivered to every user (the leak).
    const ev = ai_mod.on_event_sent.SseEvent{
        .session_id = "workers",
        .data = "{\"action\":\"updated\",\"id\":\"w_a\",\"session_id\":\"\"}",
    };
    const resolved = resolveEventSessionId(alloc, &db, ev) orelse return error.NotResolved;
    try std.testing.expectEqualStrings("s_a", resolved);
}

test "resolveEventSessionId: unattributable event resolves to null (delivered)" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    var db = try testDb(alloc);
    defer db.deinit();

    // design_element events carry a workspace_id, not a session id — there is
    // nothing to scope on, so the fan-out must deliver rather than drop.
    const ev = ai_mod.on_event_sent.SseEvent{
        .session_id = "design_element",
        .data = "{\"action\":\"created\",\"workspace_id\":\"ws_1\"}",
    };
    try std.testing.expect(resolveEventSessionId(alloc, &db, ev) == null);
}

test "resolveEventSessionId: non-JSON payload with a literal envelope id resolves to null" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    var db = try testDb(alloc);
    defer db.deinit();

    const ev = ai_mod.on_event_sent.SseEvent{ .session_id = "workers", .data = "not json" };
    try std.testing.expect(resolveEventSessionId(alloc, &db, ev) == null);
}

test "payloadFields: extracts session_id and id, tolerates missing fields" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    const both = payloadFields(alloc, "{\"session_id\":\"s1\",\"id\":\"w1\"}") orelse return error.NoFields;
    try std.testing.expectEqualStrings("s1", both.session_id);
    try std.testing.expectEqualStrings("w1", both.id);

    const only_id = payloadFields(alloc, "{\"id\":\"w1\"}") orelse return error.NoFields;
    try std.testing.expectEqualStrings("", only_id.session_id);
    try std.testing.expectEqualStrings("w1", only_id.id);

    try std.testing.expect(payloadFields(alloc, "[]") == null);
    try std.testing.expect(payloadFields(alloc, "") == null);
}
