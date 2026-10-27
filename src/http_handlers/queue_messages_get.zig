//! `GET /api/queue_messages/:session_id` — read all queued messages for a
//! session, oldest first. Layered as `useCase` (resolve singleton + DB query
//! + build JSON) and a thin handler that maps errors to status codes.

const std = @import("std");
const http_response = @import("http_response.zig");
const pabrikcore = @import("pabrikcore");
const gserverz = pabrikcore.gserverz;

pub const QueueMessagesError = error{
    MissingSessionId,
    GlobalContextNotInitialized,
    QueryFailed,
    /// `allocator.dupe` returned no memory. In production the per-request
    /// arena makes this unreachable but the type system requires the variant
    /// so `try allocator.dupe` propagates a typed error.
    OutOfMemory,
};

pub const QueueMessageEntry = struct {
    id: []const u8,
    message: []const u8,
};

pub const QueueMessagesResponse = struct {
    messages: []QueueMessageEntry,
    count: usize,
};

pub const QueueMessagesResult = []const u8; // pre-serialized JSON

// =====================================================================
// Use case
// =====================================================================

fn useCase(
    allocator: std.mem.Allocator,
    db: *pabrikcore.database.Db,
    session_id: []const u8,
) QueueMessagesError!QueueMessagesResult {
    const select_sql = "SELECT id, message FROM session_queue_messages WHERE session_id = ? ORDER BY created_at ASC";
    var rows = db.query(allocator, select_sql, &.{session_id}) catch return error.QueryFailed;
    // Owns a pooled reader until `deinit`; draining `next()` does not return it.
    defer rows.deinit();

    var messages = std.ArrayList(QueueMessageEntry).empty;
    errdefer messages.deinit(allocator);

    while (true) {
        const row_opt = rows.next() catch break;
        const row = row_opt orelse break;

        try messages.append(allocator, .{
            .id = try allocator.dupe(u8, row.values[0]),
            .message = try allocator.dupe(u8, row.values[1]),
        });
    }

    const response = QueueMessagesResponse{
        .messages = try messages.toOwnedSlice(allocator),
        .count = messages.items.len,
    };
    return try std.json.Stringify.valueAlloc(allocator, response, .{});
}

// =====================================================================
// Handler
// =====================================================================

pub fn queueMessagesGetHandler(
    ctx: gserverz.HttpContext,
    req: gserverz.HttpRequest,
    res: gserverz.HttpResponse,
) !gserverz.HttpResponse {
    const allocator = ctx.allocator;

    const session_id = req.params.get("session_id") orelse {
        return res.jsonResponse(.{
            .status_code = 400,
            .data = try http_response.makeErrorResponse(allocator, .{ .@"error" = "Missing session_id" }),
        });
    };

    const di = pabrikcore.getSingleton() catch {
        return res.jsonResponse(.{
            .status_code = 500,
            .data = try http_response.makeErrorResponse(allocator, .{ .@"error" = "Server not initialized" }),
        });
    };

    const json_str = useCase(allocator, di.db, session_id) catch |err| {
        const status: u16 = switch (err) {
            error.MissingSessionId => 400,
            error.GlobalContextNotInitialized => 500,
            error.QueryFailed => 500,
            error.OutOfMemory => 500,
        };
        const message: []const u8 = switch (err) {
            error.MissingSessionId => "Missing session_id",
            error.GlobalContextNotInitialized => "Server not initialized",
            error.QueryFailed => "Database query failed",
            error.OutOfMemory => "Out of memory",
        };
        return res.jsonResponse(.{
            .status_code = status,
            .data = try http_response.makeErrorResponse(allocator, .{ .@"error" = message }),
        });
    };

    return res.jsonResponse(.{ .status_code = 200, .data = json_str });
}