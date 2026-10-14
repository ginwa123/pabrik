//! GET /api/subagent/progress/:tool_call_id — live spawn-batch snapshot.
//! 2026-09-04 spawn-subagent-refresh-persist (task_1788505292766_1): Progress
//! events are SSE-ephemeral, so a page refresh mid-run wipes ChatView's

const std = @import("std");
const http_response = @import("http_response.zig");
const pabrikcore = @import("pabrikcore");
const gserverz = pabrikcore.gserverz;
const helpers = @import("helpers");
const ai_mod = pabrikcore.ai_mod;
const subagent_progress = ai_mod.subagent_progress;

/// Get the live snapshot for one spawn_sub_agent batch.
pub fn subAgentProgressGetHandler(ctx: gserverz.HttpContext, req: gserverz.HttpRequest, res: gserverz.HttpResponse) !gserverz.HttpResponse {
    const allocator = ctx.allocator;
    const tool_call_id = req.params.get("tool_call_id") orelse {
        return res.jsonResponse(.{ .status_code = 400, .data = try http_response.makeErrorResponse(allocator, .{ .@"error" = "tool_call_id required" }) });
    };
    if (tool_call_id.len == 0) {
        return res.jsonResponse(.{ .status_code = 400, .data = try http_response.makeErrorResponse(allocator, .{ .@"error" = "tool_call_id required" }) });
    }

    const rows = try subagent_progress.getSnapshot(allocator, tool_call_id);

    // Build the JSON body manually — `data` must be a pre-serialized JSON
    // string (see worker_get.zig / stream_get.zig pattern), not an anonymous
    // struct.
    var buf: std.ArrayList(u8) = .empty;
    try buf.print(allocator, "{{\"tool_call_id\":{f},\"progress\":[", .{std.json.fmt(tool_call_id, .{})});
    for (rows, 0..) |row, i| {
        if (i > 0) try buf.appendSlice(allocator, ",");
        try buf.print(allocator, "{{\"agent_name\":{f},\"status\":\"{s}\",\"agent_index\":{},\"total_agents\":{},\"subagent_session_id\":{f},\"elapsed_ms\":{}}}", .{
            std.json.fmt(row.agent_name, .{}),
            row.status.toStr(),
            row.agent_index,
            row.total_agents,
            std.json.fmt(row.subagent_session_id, .{}),
            row.elapsed_ms,
        });
    }
    try buf.appendSlice(allocator, "]}");
    const body = try buf.toOwnedSlice(allocator);

    return res.jsonResponse(.{
        .status_code = 200,
        .data = body,
    });
}
