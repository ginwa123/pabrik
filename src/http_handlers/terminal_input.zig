//! `POST /api/terminal/sessions/:id/input` — write keystrokes to a PTY. Body:
//! `{ data }` (required, non-empty string — raw terminal input, e.g.
//! `"ls\n"`).

const std = @import("std");
const http_response = @import("http_response.zig");
const pabrikcore = @import("pabrikcore");
const gserverz = pabrikcore.gserverz;
const terminal_session = @import("terminal_session.zig");
const auth_common = @import("auth_common.zig");

pub const TerminalInputBody = struct {
    data: []const u8 = "",
};

pub const TerminalInputResponse = struct {
    ok: bool,
    bytes: usize,
};

pub fn terminalInputHandler(
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
    const parsed = std.json.parseFromSliceLeaky(TerminalInputBody, allocator, req.body, .{}) catch {
        return res.jsonResponse(.{
            .status_code = 400,
            .data = try http_response.makeErrorResponse(allocator, .{ .@"error" = "Invalid JSON body" }),
        });
    };
    if (parsed.data.len == 0) {
        return res.jsonResponse(.{
            .status_code = 400,
            .data = try http_response.makeErrorResponse(allocator, .{ .@"error" = "data must not be empty" }),
        });
    }

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

    const written = terminal_session.writeInput(session, parsed.data) catch |err| {
        const status: u16 = switch (err) {
            error.SessionExited => 410,
            error.UnsupportedPlatform => 501,
            error.WriteFailed, error.OutOfMemory => 500,
            else => 500,
        };
        const message: []const u8 = switch (err) {
            error.SessionExited => "terminal session has exited",
            error.UnsupportedPlatform => "terminal sessions require Linux or macOS",
            else => "failed to write to terminal",
        };
        return res.jsonResponse(.{
            .status_code = status,
            .data = try http_response.makeErrorResponse(allocator, .{ .@"error" = message }),
        });
    };

    const json_str = try std.json.Stringify.valueAlloc(allocator, TerminalInputResponse{
        .ok = true,
        .bytes = written,
    }, .{});
    return res.jsonResponse(.{ .status_code = 200, .data = json_str });
}

const testing = std.testing;

test "input body parses data" {
    var parsed = try std.json.parseFromSlice(TerminalInputBody, testing.allocator, "{\"data\":\"ls\\n\"}", .{});
    defer parsed.deinit();
    try testing.expectEqualStrings("ls\n", parsed.value.data);
}

test "input body defaults data to empty" {
    var parsed = try std.json.parseFromSlice(TerminalInputBody, testing.allocator, "{}", .{});
    defer parsed.deinit();
    try testing.expectEqualStrings("", parsed.value.data);
}
