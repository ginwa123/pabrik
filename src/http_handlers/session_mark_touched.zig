//! `POST /api/session/:session_id/touched`. `POST
//! /api/llm/session/:session_id/touched`.

const std = @import("std");
const http_response = @import("http_response.zig");
const pabrikcore = @import("pabrikcore");
const gserverz = pabrikcore.gserverz;
const ai_mod = pabrikcore.ai_mod;
const llm_history = ai_mod.llm_history;
const on_event_sent = ai_mod.on_event_sent;
const auth_common = @import("auth_common.zig");

pub const MarkSessionTouchedError = error{
    SessionIdRequired,
    /// `std.json.Stringify.valueAlloc` can fail with `OutOfMemory`.
    /// Unreachable on the per-request arena, but the type system
    /// requires the variant.
    OutOfMemory,
};

pub const MarkSessionTouchedResult = []const u8; // pre-serialized JSON

// =====================================================================
// Use case
// =====================================================================

pub const MarkSessionTouchedResponse = struct {
    success: bool = true,
    session_id: []const u8,
};

fn useCase(
    allocator: std.mem.Allocator,
    db: *pabrikcore.sqlite.SqliteBackend,
    session_id: []const u8,
) MarkSessionTouchedError!MarkSessionTouchedResult {
    if (session_id.len == 0) return error.SessionIdRequired;

    // 1. Capture "now" once so the DB stamp and the SSE payload below
    //    agree on the exact unix-ms value (no second SELECT needed).
    const now_ms = llm_history.unixMillisNow();

    // 2. Ensure the row exists before any UPDATE (mirrors
    // session_update.zig:66).
    _ = llm_history.ensureSessionExists(allocator, db, session_id) catch {
        // Collapse storage errors to a single caller-handled variant
        // (matches the sibling pattern at
        // task_mark_human_touched.zig:70 — narrow use-case error sets).
        return error.SessionIdRequired;
    };

    // 3. Stamp the column with the captured timestamp (explicit value
    //    so the SSE payload matches the DB write exactly).
    llm_history.updateSessionLastHumanTouchedAt(allocator, db, session_id, now_ms) catch {
        return error.SessionIdRequired;
    };

    // 4. Re-read for the SSE payload (mirrors the update_session_status
    // pattern in llm_history.zig).
    const session = (llm_history.getSession(allocator, db, session_id) catch {
        return error.SessionIdRequired;
    }) orelse return error.SessionIdRequired;

    // 5. Emit SSE so connected sidebar clients clear the stale dot live.
    const touched_at_str = std.fmt.allocPrint(allocator, "{d}", .{now_ms}) catch {
        return error.OutOfMemory;
    };
    on_event_sent.onEventSendSessions(allocator, .{
        .action = "updated",
        .id = session.id,
        .name = session.name,
        .status = session.status,
        .cwd = session.cwd,
        .created_at = session.created_at,
        .updated_at = session.updated_at,
        .selected_profile_model = session.selected_profile_model,
        .git_worktree_cwd = session.git_worktree_cwd,
        .is_auto_retry_until_stop = session.is_auto_retry_until_stop,
        .last_finish_reason = session.last_finish_reason,
        .last_human_touched_at = touched_at_str,
    }) catch |err| {
        std.log.warn(
            "session_mark_touched: SSE emit failed (non-fatal): {s}",
            .{@errorName(err)},
        );
    };

    return try std.json.Stringify.valueAlloc(
        allocator,
        MarkSessionTouchedResponse{ .session_id = session_id },
        .{},
    );
}

// =====================================================================
// Handler
// =====================================================================

pub fn sessionMarkTouchedHandler(
    ctx: gserverz.HttpContext,
    req: gserverz.HttpRequest,
    res: gserverz.HttpResponse,
) !gserverz.HttpResponse {
    const allocator = ctx.allocator;

    const di = try pabrikcore.getSingleton();
    const sqlite_db = di.db;

    // The body is intentionally ignored — empty body and `{}` are both
    // accepted (the stamp needs no input beyond the path param).
    const session_id = req.params.get("session_id") orelse "";
    if (session_id.len == 0) {
        return res.jsonResponse(.{
            .status_code = 400,
            .data = try http_response.makeErrorResponse(allocator, .{ .@"error" = "session_id required" }),
        });
    }

    const data = useCase(allocator, sqlite_db, session_id) catch |err| {
        const status: u16 = switch (err) {
            error.SessionIdRequired => 400,
            error.OutOfMemory => 500,
        };
        const message: []const u8 = switch (err) {
            error.SessionIdRequired => "session_id required",
            error.OutOfMemory => "Out of memory",
        };
        return res.jsonResponse(.{
            .status_code = status,
            .data = try http_response.makeErrorResponse(allocator, .{ .@"error" = message }),
        });
    };

    // Claim an ownerless row created by ensureSessionExists above. Without
    // this, a brand-new chat opened in auth-on mode leaves its session row in
    // the shared bucket (visible to every user).
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

    return res.jsonResponse(.{ .status_code = 200, .data = data });
}
