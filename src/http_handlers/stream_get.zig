//! GET /api/llm/session/:session_id/stream — in-flight stream snapshot.
//! 2026-09-02 stream-resume-on-reselect (task_1787673548905_0): When the user
//! closes/re-selects a chat session mid-stream, ChatView drops its

const std = @import("std");
const http_response = @import("http_response.zig");
const pabrikcore = @import("pabrikcore");
const gserverz = pabrikcore.gserverz;
const helpers = @import("helpers");
const ai_mod = pabrikcore.ai_mod;
const stream_snapshot = ai_mod.stream_snapshot;

/// Get the in-flight stream snapshot for a session.
pub fn streamGetHandler(ctx: gserverz.HttpContext, req: gserverz.HttpRequest, res: gserverz.HttpResponse) !gserverz.HttpResponse {
    const allocator = ctx.allocator;
    const session_id = req.params.get("session_id") orelse {
        return res.jsonResponse(.{ .status_code = 400, .data = try http_response.makeErrorResponse(allocator, .{ .@"error" = "session_id required" }) });
    };
    if (session_id.len == 0) {
        return res.jsonResponse(.{ .status_code = 400, .data = try http_response.makeErrorResponse(allocator, .{ .@"error" = "session_id required" }) });
    }

    const snap = try stream_snapshot.getSnapshot(allocator, session_id);

    // Build the JSON body manually — `data` must be a pre-serialized
    // JSON string (see worker_get.zig pattern), not an anonymous struct.
    const body = try std.fmt.allocPrint(
        allocator,
        "{{\"active\":{},\"content\":{f}}}",
        .{ snap.active, std.json.fmt(snap.content, .{}) },
    );

    return res.jsonResponse(.{
        .status_code = 200,
        .data = body,
    });
}
