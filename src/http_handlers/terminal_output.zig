//! `GET /api/terminal/sessions/:id/output?cursor=N` — poll terminal output since
//! the absolute `cursor`. A `gterm-` id is a shell inside a workspace VM whose
//! bytes come from the guest; every other id is a host pty.

const std = @import("std");
const http_response = @import("http_response.zig");
const pabrikcore = @import("pabrikcore");
const gserverz = pabrikcore.gserverz;
const terminal_session = @import("terminal_session.zig");
const terminal_guest = @import("terminal_guest.zig");
const auth_common = @import("auth_common.zig");

pub const TerminalOutputResponse = struct {
    data: []const u8,
    cursor: u64,
    exited: bool,
    exit_code: ?i32,
};

fn missingId(allocator: std.mem.Allocator, res: gserverz.HttpResponse) !gserverz.HttpResponse {
    return res.jsonResponse(.{
        .status_code = 400,
        .data = try http_response.makeErrorResponse(allocator, .{ .@"error" = "Missing id" }),
    });
}

fn notFound(allocator: std.mem.Allocator, res: gserverz.HttpResponse) !gserverz.HttpResponse {
    return res.jsonResponse(.{
        .status_code = 404,
        .data = try http_response.makeErrorResponse(allocator, .{ .@"error" = "terminal session not found" }),
    });
}

fn outOfMemory(allocator: std.mem.Allocator, res: gserverz.HttpResponse) !gserverz.HttpResponse {
    return res.jsonResponse(.{
        .status_code = 500,
        .data = try http_response.makeErrorResponse(allocator, .{ .@"error" = "Out of memory" }),
    });
}

pub fn terminalOutputHandler(
    ctx: gserverz.HttpContext,
    req: gserverz.HttpRequest,
    res: gserverz.HttpResponse,
) !gserverz.HttpResponse {
    const allocator = ctx.allocator;

    const id = req.params.get("id") orelse return missingId(allocator, res);
    if (id.len == 0) return missingId(allocator, res);

    // Owner check (plan 2026-09-25, W2.5): a foreign terminal id is
    // indistinguishable from a missing one (404, never 403).
    var owner_buf: [128]u8 = undefined;
    const owner: []const u8 = auth_common.resolveOwnerInto(&owner_buf, req.headers) orelse "";
    const cursor = terminal_session.parseCursor(req.query.get("cursor"));

    if (terminal_guest.isGuestId(id)) return guestOutput(allocator, res, id, owner, cursor);

    const session = terminal_session.getSessionForOwner(id, owner) orelse return notFound(allocator, res);
    // Owned copy under the session lock: no borrow into the live ring
    // buffer survives the unlock, so a concurrent drain realloc can
    // never free memory we still read (heap UAF -> remap abort).
    const owned = terminal_session.readOutputAlloc(allocator, session, cursor) catch
        return outOfMemory(allocator, res);
    defer allocator.free(owned.data);

    // Strip NUL bytes for JSON safety.
    const clean = stripNul(allocator, owned.data) catch return outOfMemory(allocator, res);

    const json_str = try std.json.Stringify.valueAlloc(allocator, TerminalOutputResponse{
        .data = clean,
        .cursor = owned.cursor,
        .exited = owned.exited,
        .exit_code = owned.exit_code,
    }, .{});
    return res.jsonResponse(.{ .status_code = 200, .data = json_str });
}

/// The same wire shape, read from the shell inside the workspace's VM.
fn guestOutput(
    allocator: std.mem.Allocator,
    res: gserverz.HttpResponse,
    id: []const u8,
    owner: []const u8,
    cursor: u64,
) !gserverz.HttpResponse {
    const session = terminal_guest.getSessionForOwner(id, owner) orelse return notFound(allocator, res);
    const socket = terminal_guest.socketPath() orelse return res.jsonResponse(.{
        .status_code = 503,
        .data = try http_response.makeErrorResponse(allocator, .{ .@"error" = "the workspace VM manager is not running" }),
    });
    const owned = terminal_guest.readOutputAlloc(allocator, socket, session, cursor) catch |err| {
        const status: u16 = switch (err) {
            error.ManagerUnavailable, error.ManagerRefused => 503,
            else => 500,
        };
        const message: []const u8 = switch (err) {
            error.ManagerUnavailable => "the workspace VM manager is not running",
            error.ManagerRefused => "the workspace VM refused the read",
            else => "failed to read the terminal",
        };
        return res.jsonResponse(.{
            .status_code = status,
            .data = try http_response.makeErrorResponse(allocator, .{ .@"error" = message }),
        });
    };
    defer allocator.free(owned.data);

    const clean = stripNul(allocator, owned.data) catch return outOfMemory(allocator, res);
    const json_str = try std.json.Stringify.valueAlloc(allocator, TerminalOutputResponse{
        .data = clean,
        .cursor = owned.cursor,
        .exited = owned.exited,
        .exit_code = owned.exit_code,
    }, .{});
    return res.jsonResponse(.{ .status_code = 200, .data = json_str });
}

/// Copy `raw` minus NUL bytes into an owned slice.
pub fn stripNul(allocator: std.mem.Allocator, raw: []const u8) ![]u8 {
    var kept: usize = 0;
    for (raw) |b| {
        if (b != 0) kept += 1;
    }
    const out = try allocator.alloc(u8, kept);
    var i: usize = 0;
    for (raw) |b| {
        if (b == 0) continue;
        out[i] = b;
        i += 1;
    }
    return out;
}

const testing = std.testing;

test "stripNul removes NUL bytes and keeps the rest" {
    const out = try stripNul(testing.allocator, "a\x00b\x00c");
    defer testing.allocator.free(out);
    try testing.expectEqualStrings("abc", out);
}

test "stripNul passes clean input through" {
    const out = try stripNul(testing.allocator, "hello");
    defer testing.allocator.free(out);
    try testing.expectEqualStrings("hello", out);
}
