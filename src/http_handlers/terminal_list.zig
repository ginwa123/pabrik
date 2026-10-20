//! `GET /api/terminal/sessions` — the live terminal sessions the caller may
//! drive, so a window-level footer can list them grouped per workspace. The
//! substrate follows the runtime: host ptys locally, workspace VMs under saas.

const std = @import("std");
const http_response = @import("http_response.zig");
const pabrikcore = @import("pabrikcore");
const gserverz = pabrikcore.gserverz;
const terminal_session = @import("terminal_session.zig");
const terminal_guest = @import("terminal_guest.zig");
const runtime_mode = @import("../runtime_mode.zig");
const auth_common = @import("auth_common.zig");

/// One session on the wire. The fields a launcher needs: which workspace it
/// belongs to, where its shell started, and the console it got.
pub const TerminalSessionSummary = struct {
    id: []const u8,
    workspace_id: []const u8,
    cwd: []const u8,
    cols: u16,
    rows: u16,
    exited: bool,
    backend: []const u8,
};

pub const TerminalListResponse = struct {
    sessions: []const TerminalSessionSummary,
};

pub fn terminalListHandler(
    ctx: gserverz.HttpContext,
    req: gserverz.HttpRequest,
    res: gserverz.HttpResponse,
) !gserverz.HttpResponse {
    const allocator = ctx.allocator;

    // Owner for the list (plan 2026-09-25, W2.5). Server-derived from the
    // `pabrik_session` cookie only — never a body/query/header field.
    var owner_buf: [128]u8 = undefined;
    const owner: []const u8 = auth_common.resolveOwnerInto(&owner_buf, req.headers) orelse "";

    const rows = switch (runtime_mode.currentMode()) {
        .saas => try terminal_guest.listSessionsForOwner(allocator, owner),
        .local => try terminal_session.listSessionsForOwner(allocator, owner),
    };
    defer terminal_session.freeSessionSummaries(allocator, rows);

    const sessions = try allocator.alloc(TerminalSessionSummary, rows.len);
    defer allocator.free(sessions);
    for (rows, 0..) |row, i| {
        sessions[i] = .{
            .id = row.id,
            .workspace_id = row.workspace_id,
            .cwd = row.cwd,
            .cols = row.cols,
            .rows = row.rows,
            .exited = row.exited,
            .backend = row.backend,
        };
    }

    const json_str = try std.json.Stringify.valueAlloc(allocator, TerminalListResponse{
        .sessions = sessions,
    }, .{});
    return res.jsonResponse(.{ .status_code = 200, .data = json_str });
}

// ---------------------------------------------------------------------
// Inline tests: the wire shape, and the rule that decides whose shells
// are in it.

const testing = std.testing;

test "the list response serializes one session per row" {
    const json = try std.json.Stringify.valueAlloc(testing.allocator, TerminalListResponse{
        .sessions = &[_]TerminalSessionSummary{.{
            .id = "term-3",
            .workspace_id = "ws_1",
            .cwd = "/home/you/project",
            .cols = 80,
            .rows = 24,
            .exited = false,
            .backend = "posix-pty",
        }},
    }, .{});
    defer testing.allocator.free(json);
    try testing.expect(std.mem.indexOf(u8, json, "\"sessions\"") != null);
    try testing.expect(std.mem.indexOf(u8, json, "term-3") != null);
    try testing.expect(std.mem.indexOf(u8, json, "ws_1") != null);
    try testing.expect(std.mem.indexOf(u8, json, "/home/you/project") != null);
    try testing.expect(std.mem.indexOf(u8, json, "posix-pty") != null);
}

test "an empty list is an empty array, not a missing key" {
    const json = try std.json.Stringify.valueAlloc(testing.allocator, TerminalListResponse{
        .sessions = &[_]TerminalSessionSummary{},
    }, .{});
    defer testing.allocator.free(json);
    try testing.expectEqualStrings("{\"sessions\":[]}", json);
}
