//! `POST /api/terminal/sessions/:id/resize` — set the PTY window size. Body:
//! `{ cols, rows }` (both required, integers in [2, 1000]). Success: 200 `{
//! ok: true, cols, rows }`.

const std = @import("std");
const http_response = @import("http_response.zig");
const pabrikcore = @import("pabrikcore");
const gserverz = pabrikcore.gserverz;
const terminal_session = @import("terminal_session.zig");
const auth_common = @import("auth_common.zig");

pub const TerminalResizeBody = struct {
    cols: ?u16 = null,
    rows: ?u16 = null,
};

pub const TerminalResizeResponse = struct {
    ok: bool,
    cols: u16,
    rows: u16,
};

pub fn terminalResizeHandler(
    ctx: gserverz.HttpContext,
    req: gserverz.HttpRequest,
    res: gserverz.HttpResponse,
) !gserverz.HttpResponse {
    const allocator = ctx.allocator;

    const id = req.params.get("id") orelse {
        return res.jsonResponse(.{
            .status_code = 400,
            .data = try http_response.makeErrorResponse(allocator, .{ .@"error" = "Missing id" }),
        });
    };
    if (id.len == 0) {
        return res.jsonResponse(.{
            .status_code = 400,
            .data = try http_response.makeErrorResponse(allocator, .{ .@"error" = "Missing id" }),
        });
    }

    if (req.body.len == 0) {
        return res.jsonResponse(.{
            .status_code = 400,
            .data = try http_response.makeErrorResponse(allocator, .{ .@"error" = "Missing JSON body" }),
        });
    }
    const parsed = std.json.parseFromSliceLeaky(TerminalResizeBody, allocator, req.body, .{}) catch {
        return res.jsonResponse(.{
            .status_code = 400,
            .data = try http_response.makeErrorResponse(allocator, .{ .@"error" = "Invalid JSON body" }),
        });
    };
    const cols = parsed.cols orelse {
        return res.jsonResponse(.{
            .status_code = 400,
            .data = try http_response.makeErrorResponse(allocator, .{ .@"error" = "cols is required" }),
        });
    };
    const rows = parsed.rows orelse {
        return res.jsonResponse(.{
            .status_code = 400,
            .data = try http_response.makeErrorResponse(allocator, .{ .@"error" = "rows is required" }),
        });
    };

    // Owner check (plan 2026-09-25, W2.5): a foreign terminal id is
    // indistinguishable from a missing one (404, never 403).
    var owner_buf: [128]u8 = undefined;
    const owner: []const u8 = auth_common.resolveOwnerInto(&owner_buf, req.headers) orelse "";
    const session = terminal_session.getSessionForOwner(id, owner) orelse {
        return res.jsonResponse(.{
            .status_code = 404,
            .data = try http_response.makeErrorResponse(allocator, .{ .@"error" = "terminal session not found" }),
        });
    };

    terminal_session.resizeSession(session, cols, rows) catch |err| {
        const status: u16 = switch (err) {
            error.InvalidSize => 400,
            error.SessionExited => 410,
            error.UnsupportedPlatform => 501,
            error.ResizeFailed, error.OutOfMemory => 500,
            else => 500,
        };
        const message: []const u8 = switch (err) {
            error.InvalidSize => "cols/rows must be in [2, 1000]",
            error.SessionExited => "terminal session has exited",
            error.UnsupportedPlatform => "terminal sessions are not supported on this platform",
            else => "failed to resize terminal",
        };
        return res.jsonResponse(.{
            .status_code = status,
            .data = try http_response.makeErrorResponse(allocator, .{ .@"error" = message }),
        });
    };

    const json_str = try std.json.Stringify.valueAlloc(allocator, TerminalResizeResponse{
        .ok = true,
        .cols = cols,
        .rows = rows,
    }, .{});
    return res.jsonResponse(.{ .status_code = 200, .data = json_str });
}

const testing = std.testing;

test "resize body requires both dims" {
    var missing = try std.json.parseFromSlice(TerminalResizeBody, testing.allocator, "{\"cols\":80}", .{});
    defer missing.deinit();
    try testing.expect(missing.value.rows == null);
    var full = try std.json.parseFromSlice(TerminalResizeBody, testing.allocator, "{\"cols\":100,\"rows\":40}", .{});
    defer full.deinit();
    try testing.expectEqual(@as(u16, 100), full.value.cols.?);
    try testing.expectEqual(@as(u16, 40), full.value.rows.?);
}
