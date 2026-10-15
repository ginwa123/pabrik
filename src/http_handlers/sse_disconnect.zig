//! Notify server that the client is disconnecting from an SSE stream. This
//! removes ALL SSE connections for the session (forceful disconnect of the
//! entire session).

const std = @import("std");
const pabrikcore = @import("pabrikcore");
const gserverz = pabrikcore.gserverz;

pub const SseDisconnectError = error{
    ServerNotAvailable,
};

/// Outcome of the SSE-disconnect use-case.
pub const SseDisconnectResult = struct {
    removed_clients: u32,
};

// =====================================================================
// Use case
// =====================================================================

fn useCase(session_id: []const u8) SseDisconnectError!SseDisconnectResult {
    const server = gserverz.global_server orelse return error.ServerNotAvailable;
    const removed_count = server.sse_manager.removeSession(session_id);
    std.log.info("SSE: Session {s} disconnected, {d} client(s) removed", .{ session_id, removed_count });
    return .{ .removed_clients = removed_count };
}

// =====================================================================
// Handler
// =====================================================================

/// Notify server that client is disconnecting from SSE stream.
pub fn sseDisconnectHandler(
    ctx: gserverz.HttpContext,
    req: gserverz.HttpRequest,
    res: gserverz.HttpResponse,
) !gserverz.HttpResponse {
    const allocator = ctx.allocator;

    // Per `pabrik-http-handler-thin-wrapper-pattern`, use
    // `req.params.get` rather than the (non-existent) `path_param`.
    const session_id = req.params.get("session_id") orelse {
        return res.jsonResponse(.{
            .status_code = 400,
            .data = "{\"error\":\"Missing session_id\"}",
        });
    };

    const outcome = useCase(session_id) catch |err| {
        const status: u16 = switch (err) {
            error.ServerNotAvailable => 500,
        };
        const message: []const u8 = switch (err) {
            error.ServerNotAvailable => "Server not available",
        };
        return res.jsonResponse(.{
            .status_code = status,
            .data = try std.fmt.allocPrint(allocator, "{{\"error\":\"{s}\"}}", .{message}),
        });
    };

    const body = try std.fmt.allocPrint(
        allocator,
        "{{\"status\":\"disconnected\",\"removed_clients\":{d}}}",
        .{outcome.removed_clients},
    );
    return res.jsonResponse(.{ .status_code = 200, .data = body });
}