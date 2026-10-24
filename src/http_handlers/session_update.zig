const std = @import("std");
const root_mod = @import("pabrikcore");
const gserverz = root_mod.gserverz;
const llm_history = root_mod.llm_history;
const http_response = @import("http_response.zig");
const auth_common = @import("auth_common.zig");

/// Request body for updating an existing session
pub const RequestSessionUpdate = struct {
    /// Name of a profile in LlmConfig.profiles_models.
    /// Empty string OR missing key = clear (use top-level config).
    selected_profile_model: []const u8 = "",
    /// Optional — also support renaming in the same endpoint for symmetry.
    /// Empty string OR missing key = unchanged.
    name: []const u8 = "",
    /// Migration 063 — toggle the unattended-mode flag. "1" to enable,
    /// "0" to disable. Empty string OR missing key = unchanged
    /// (preserves today's "no-op when omitted" behavior).
    is_auto_retry_until_stop: []const u8 = "",
};

/// Response body for session update
pub const ResponseSessionUpdate = struct {
    id: []const u8,
    name: []const u8,
    status: []const u8,
    selected_profile_model: []const u8,
    /// Migration 063 — echo the current unattended-mode flag back so
    /// the frontend's reactive Pinia store refreshes from the response.
    is_auto_retry_until_stop: []const u8,
};

/// PUT /api/session/:session_id PUT /api/llm/session/:session_id Body (JSON,
/// all fields optional): - selected_profile_model: profile name to assign to
/// this session (empty/null = clear) - name: new session name (empty/null =
pub fn sessionUpdateHandler(ctx: gserverz.HttpContext, req: gserverz.HttpRequest, res: gserverz.HttpResponse) !gserverz.HttpResponse {
    const allocator = ctx.allocator;
    const session_id = req.params.get("session_id") orelse {
        return res.jsonResponse(.{ .status_code = 400, .data = try http_response.makeErrorResponse(allocator, .{ .@"error" = "Missing session_id" }) });
    };

    if (session_id.len == 0) {
        return res.jsonResponse(.{ .status_code = 400, .data = try http_response.makeErrorResponse(allocator, .{ .@"error" = "Missing session_id" }) });
    }

    const parsed = std.json.parseFromSliceLeaky(RequestSessionUpdate, allocator, req.body, .{
        .ignore_unknown_fields = true,
    }) catch |err| {
        return res.jsonResponse(.{ .status_code = 400, .data = try http_response.makeErrorResponse(allocator, .{ .@"error" = @errorName(err) }) });
    };

    // Get the singleton DB handle
    const di = try root_mod.getSingleton();
    const sqlite_db = di.db;

    // Plan 2026-08-06-set-active-profile-default — ensure the row exists
    // before any UPDATE.
    _ = try llm_history.ensureSessionExists(allocator, sqlite_db, session_id);

    // Claim an ownerless row created by the ensure above (same pattern as
    // session_create + session_mark_touched). Only claims ownerless rows.
    if (di.auth_enabled) {
        const stamp_owner = auth_common.resolveRequestUserId(allocator, di.db, di.auth_enabled, req.headers) catch null;
        defer if (stamp_owner) |o| allocator.free(o);
        if (stamp_owner) |o| {
            if (!auth_common.isSharedOwner(o)) {
                _ = di.db.exec(allocator,
                    "UPDATE sessions SET user_id = ? WHERE id = ? AND (user_id IS NULL OR user_id = '' OR user_id = 'user_system')",
                    &[_][]const u8{ o, session_id },
                ) catch {};
            }
        }
    }

    // Update selected_profile_model (always — even if empty, to allow clearing)
    try llm_history.updateSessionSelectedProfileModel(allocator, sqlite_db, session_id, parsed.selected_profile_model);

    // Optionally update name
    if (parsed.name.len > 0) {
        try llm_history.updateSessionName(allocator, sqlite_db, session_id, parsed.name);
    }

    // Migration 063 — toggle unattended mode.
    if (parsed.is_auto_retry_until_stop.len > 0) {
        try llm_history.updateSessionAutoRetryUntilStop(
            allocator,
            sqlite_db,
            session_id,
            parsed.is_auto_retry_until_stop,
        );
    }

    // Re-read for the response
    const session = (try llm_history.getSession(allocator, sqlite_db, session_id)) orelse {
        return res.jsonResponse(.{ .status_code = 404, .data = try http_response.makeErrorResponse(allocator, .{ .@"error" = "session not found" }) });
    };
    defer session.deinit(allocator);

    // NEW (plan 2026-08-29-chat-sidebar-last-human-touched, Task 4): Stamp
    // `sessions.last_human_touched_at_nano` when the user genuinely edits a
    // field (rename / profile switch / unattended toggle).
    llm_history.updateSessionLastHumanTouchedAt(
        allocator, sqlite_db, session_id, null,
    ) catch |stamp_err| {
        if (root_mod.loggermod.getGlobal()) |logger| {
            logger.warnFmt("session_update: stamp last_human_touched_at failed (non-fatal): {s}", .{@errorName(stamp_err)});
        }
    };

    const data = try http_response.makeSessionUpdateResponse(allocator, .{
        .id = session.id,
        .name = session.name,
        .status = session.status,
        .selected_profile_model = session.selected_profile_model,
        // Migration 063 — echo the (post-update) flag value so the
        // frontend's PUT response reflects the new state.
        .is_auto_retry_until_stop = session.is_auto_retry_until_stop,
    });

    return res.jsonResponse(.{ .status_code = 200, .data = data });
}

// ===== Tests merged from session_update_test.zig (2026-09-11 flatten) =====
// The stamp helper's effect is `sessions.last_human_touched_at_nano` moving
// when a user renames / re-profiles / toggles unattended on a session.
