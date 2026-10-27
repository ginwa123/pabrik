//! Stop/cancel an LLM session by setting the `cancelled` flag in the DB. The
//! workflow's loop checks this flag and breaks out, stopping the async IO.

const std = @import("std");
const pabrikcore = @import("pabrikcore");
const http_response = @import("http_response.zig");
const gserverz = pabrikcore.gserverz;
const llm_history = pabrikcore.llm_history;

pub const SessionStopError = error{
    MissingSessionId,
    CancelFailed,
    GlobalContextNotInitialized,
};

// =====================================================================
// Use case
// =====================================================================

fn useCase(
    allocator: std.mem.Allocator,
    db: *pabrikcore.database.Db,
    session_id: []const u8,
) SessionStopError!void {
    llm_history.cancelSession(allocator, db, session_id) catch return error.CancelFailed;
}

// =====================================================================
// Handler
// =====================================================================

pub fn sessionStopHandler(
    ctx: gserverz.HttpContext,
    req: gserverz.HttpRequest,
    res: gserverz.HttpResponse,
) !gserverz.HttpResponse {
    const allocator = ctx.allocator;

    const di = try pabrikcore.getSingleton();

    const session_id = req.params.get("session") orelse {
        return res.jsonResponse(.{
            .status_code = 400,
            .data = try http_response.makeErrorResponse(allocator, .{ .@"error" = "Missing session_id path parameter" }),
        });
    };

    useCase(allocator, di.db, session_id) catch |err| {
        const status: u16 = switch (err) {
            error.MissingSessionId => 400,
            error.CancelFailed, error.GlobalContextNotInitialized => 500,
        };
        const message: []const u8 = switch (err) {
            error.MissingSessionId => "Missing session_id path parameter",
            error.CancelFailed => @errorName(err),
            error.GlobalContextNotInitialized => "Global context not initialized",
        };
        return res.jsonResponse(.{
            .status_code = status,
            .data = try http_response.makeErrorResponse(allocator, .{ .@"error" = message }),
        });
    };

    const success_json = try std.fmt.allocPrint(
        allocator,
        "{{\"success\":true,\"session_id\":\"{s}\"}}",
        .{session_id},
    );
    return res.jsonResponse(.{
        .status_code = 200,
        .data = success_json,
    });
}