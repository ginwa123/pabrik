//! `POST /api/llm/session/reorder_pinned`. Body: `{ "ordered_ids": ["id1",
//! "id2", ...] }` (top-to-bottom display order of the pinned subset).

const std = @import("std");
const http_response = @import("http_response.zig");
const pabrikcore = @import("pabrikcore");
const gserverz = pabrikcore.gserverz;

pub const SessionReorderPinnedError = error{
    BodyRequired,
    InvalidJson,
    OrderedIdsRequired,
    OrderedIdsMustBeArray,
    ReorderFailed,
    OutOfMemory,
};

pub fn sessionReorderPinnedHandler(
    ctx: gserverz.HttpContext,
    req: gserverz.HttpRequest,
    res: gserverz.HttpResponse,
) !gserverz.HttpResponse {
    const allocator = ctx.allocator;

    const body = req.body;
    if (body.len == 0) {
        return res.jsonResponse(.{
            .status_code = 400,
            .data = try http_response.makeErrorResponse(allocator, .{ .@"error" = "body required" }),
        });
    }

    const parsed = std.json.parseFromSliceLeaky(std.json.Value, allocator, body, .{}) catch {
        return res.jsonResponse(.{
            .status_code = 400,
            .data = try http_response.makeErrorResponse(allocator, .{ .@"error" = "Invalid JSON" }),
        });
    };

    const ordered_ids_val = parsed.object.get("ordered_ids") orelse {
        return res.jsonResponse(.{
            .status_code = 400,
            .data = try http_response.makeErrorResponse(allocator, .{ .@"error" = "ordered_ids required" }),
        });
    };
    if (ordered_ids_val != .array) {
        return res.jsonResponse(.{
            .status_code = 400,
            .data = try http_response.makeErrorResponse(allocator, .{ .@"error" = "ordered_ids must be an array" }),
        });
    }

    var ids = std.ArrayList([]const u8).empty;
    defer ids.deinit(allocator);
    for (ordered_ids_val.array.items) |item| {
        if (item == .string) try ids.append(allocator, item.string);
    }

    const di = pabrikcore.getSingleton() catch {
        return res.jsonResponse(.{
            .status_code = 500,
            .data = try http_response.makeErrorResponse(allocator, .{ .@"error" = "Failed to reorder pinned sessions" }),
        });
    };
    pabrikcore.llm_history.reorderPinnedSessions(allocator, di.db, ids.items) catch {
        return res.jsonResponse(.{
            .status_code = 500,
            .data = try http_response.makeErrorResponse(allocator, .{ .@"error" = "Failed to reorder pinned sessions" }),
        });
    };

    return res.jsonResponse(.{
        .status_code = 200,
        .data = try http_response.makeTasksReorderPinnedResponse(allocator, ids.items.len),
    });
}

const testing = std.testing;

test "reorderPinnedSessions assigns DESC positions in display order" {
    const alloc = testing.allocator;
    var threaded = std.Io.Threaded.init(alloc, .{});
    defer threaded.deinit();
    const io = threaded.io();
    var db: pabrikcore.database.Db = .{};
    defer db.deinit();
    try db.init(io, ":memory:");
    try db.exec(alloc,
        \\CREATE TABLE sessions (
        \\  id TEXT PRIMARY KEY,
        \\  name TEXT NOT NULL DEFAULT '',
        \\  updated_at DATETIME DEFAULT CURRENT_TIMESTAMP,
        \\  is_pinned INTEGER NOT NULL DEFAULT 0,
        \\  pinned_position INTEGER NOT NULL DEFAULT 0
        \\)
    , &.{});
    try db.exec(alloc, "INSERT INTO sessions (id, name, is_pinned, pinned_position) VALUES ('a','A',1,2), ('b','B',1,1), ('c','C',1,0), ('u','U',0,0)", &.{});

    const ids = [_][]const u8{ "c", "a", "b" };
    try pabrikcore.llm_history.reorderPinnedSessions(alloc, &db, &ids);

    var q = try db.query(alloc, "SELECT id, pinned_position FROM sessions WHERE is_pinned = 1 ORDER BY pinned_position DESC", &.{});
    defer q.deinit();
    var order = std.ArrayList(u8).empty;
    defer order.deinit(alloc);
    while (try q.next()) |row| {
        defer row.deinit(alloc);
        try order.appendSlice(alloc, row.values[0]);
        try order.append(alloc, ',');
    }
    try testing.expectEqualStrings("c,a,b,", order.items);
}
