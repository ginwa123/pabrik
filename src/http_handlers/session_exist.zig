//! `GET /api/sessions/:session_id/exist` — check if a session exists. Layered
//! as `useCase` (resolve singleton + read DB) and a thin handler that maps
//! the result + errors to status codes / JSON.

const std = @import("std");
const pabrikcore = @import("pabrikcore");
const gserverz = pabrikcore.gserverz;
const http_response = pabrikcore.http_response;
const tui_check_session_exists = pabrikcore.tui_check_session_exists;

pub const SessionExistError = error{
    ServerNotInitialized,
};

pub const SessionExistResult = struct {
    session_id: []const u8,
    exists: bool,
};

// =====================================================================
// Use case
// =====================================================================

fn useCase(
    allocator: std.mem.Allocator,
    session_id: []const u8,
) SessionExistError!SessionExistResult {
    const server = gserverz.global_server orelse return error.ServerNotInitialized;
    const server_ctx = server.ctx orelse return error.ServerNotInitialized;
    // `pabrikcore.ai_workflow` never existed (the agent loop is exposed as
    // `pabrikcore.ai_mod`), so this cast never type-checked — the handler is
    // unregistered (see the commented-out route in http_routes.zig), which is
    const ctxTui = @as(*pabrikcore.App, @ptrCast(@alignCast(server_ctx)));
    const sqlite_db = ctxTui.db;
    const exists = tui_check_session_exists.check_session_exists(allocator, sqlite_db, session_id);
    return .{ .session_id = session_id, .exists = exists };
}

// =====================================================================
// Handler
// =====================================================================

pub fn sessionExistHandler(
    ctx: gserverz.HttpContext,
    req: gserverz.HttpRequest,
    res: gserverz.HttpResponse,
    _: *anyopaque,
) !gserverz.HttpResponse {
    const allocator = ctx.allocator;

    const session_id = req.params.get("session_id") orelse {
        return res.jsonResponse(.{
            .status_code = 400,
            .data = try http_response.makeErrorResponse(allocator, .{ .@"error" = "Missing session_id" }),
        });
    };

    const outcome = useCase(allocator, session_id) catch |err| {
        const status: u16 = switch (err) {
            error.ServerNotInitialized => 500,
        };
        const message: []const u8 = switch (err) {
            error.ServerNotInitialized => "Server not initialized",
        };
        return res.jsonResponse(.{
            .status_code = status,
            .data = try http_response.makeErrorResponse(allocator, .{ .@"error" = message }),
        });
    };

    return res.jsonResponse(.{
        .status_code = 200,
        .data = try std.fmt.allocPrint(
            allocator,
            "{{\"session_id\":\"{s}\",\"exists\":{s}}}",
            .{ outcome.session_id, if (outcome.exists) "true" else "false" },
        ),
    });
}