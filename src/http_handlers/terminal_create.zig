//! `POST /api/terminal/sessions` — spawn a shell on a fresh PTY: on THIS host in
//! local mode, inside the workspace's VM under `--saas`, which refuses when it
//! cannot name one rather than exposing the host filesystem.

const std = @import("std");
const http_response = @import("http_response.zig");
const pabrikcore = @import("pabrikcore");
const gserverz = pabrikcore.gserverz;
const terminal_session = @import("terminal_session.zig");
const terminal_guest = @import("terminal_guest.zig");
const runtime_mode = @import("../runtime_mode.zig");
const auth_common = @import("auth_common.zig");

pub const TerminalCreateError = error{
    UnsupportedPlatform,
    InvalidCwd,
    CwdNotDir,
    InvalidShell,
    InvalidSize,
    SpawnFailed,
    TooManySessions,
    OutOfMemory,
};

pub const TerminalCreateBody = struct {
    cwd: []const u8 = "",
    shell: ?[]const u8 = null,
    cols: ?u16 = null,
    rows: ?u16 = null,
    /// Which workspace's VM the shell runs in. Required under `--saas`; ignored
    /// in local mode, where the terminal is a host pty.
    workspace_id: ?[]const u8 = null,
};

pub const TerminalCreateResponse = struct {
    id: []const u8,
    pid: i32,
    /// Which console this session actually got — `"posix-pty"` on Linux and
    /// macOS, `"conpty"` for a real Windows pseudoconsole, `"pipe"` for the
    /// degraded Windows fallback, `"guest-pty"` inside a workspace VM.
    backend: []const u8,
};

pub fn terminalCreateHandler(
    ctx: gserverz.HttpContext,
    req: gserverz.HttpRequest,
    res: gserverz.HttpResponse,
) !gserverz.HttpResponse {
    const allocator = ctx.allocator;

    if (req.body.len == 0) {
        return res.jsonResponse(.{
            .status_code = 400,
            .data = try http_response.makeErrorResponse(allocator, .{ .@"error" = "Missing JSON body" }),
        });
    }
    const parsed = std.json.parseFromSliceLeaky(TerminalCreateBody, allocator, req.body, .{}) catch {
        return res.jsonResponse(.{
            .status_code = 400,
            .data = try http_response.makeErrorResponse(allocator, .{ .@"error" = "Invalid JSON body" }),
        });
    };
    // Empty string is "not provided" (strict-validator rule: "" must
    // not reach the use case as a value).
    const cwd = parsed.cwd;
    const shell: ?[]const u8 = if (parsed.shell) |s| (if (s.len == 0) null else s) else null;
    const workspace_id: ?[]const u8 = if (parsed.workspace_id) |w| (if (w.len == 0) null else w) else null;

    // Owner for the new PTY session (plan 2026-09-25, W2.5). Server-derived
    // from the `pabrik_session` cookie only — never a body/query/header
    // field.
    var owner_buf: [128]u8 = undefined;
    const owner: []const u8 = auth_common.resolveOwnerInto(&owner_buf, req.headers) orelse "";

    return switch (terminal_guest.routeFor(runtime_mode.currentMode(), workspace_id)) {
        .refuse => |message| res.jsonResponse(.{
            .status_code = 409,
            .data = try http_response.makeErrorResponse(allocator, .{ .@"error" = message }),
        }),
        .guest => |id| createGuest(allocator, req, res, id, cwd, parsed.cols, parsed.rows, owner),
        .host => createHost(ctx, res, cwd, workspace_id orelse "", shell, parsed.cols, parsed.rows, owner),
    };
}

/// A terminal inside the workspace's VM. Nothing here can reach the host shell:
/// the cwd that crosses the RPC is workspace-relative and the guest is the only
/// thing that forks.
fn createGuest(
    allocator: std.mem.Allocator,
    req: gserverz.HttpRequest,
    res: gserverz.HttpResponse,
    workspace_id: []const u8,
    cwd: []const u8,
    cols: ?u16,
    rows: ?u16,
    owner: []const u8,
) !gserverz.HttpResponse {
    _ = req;
    var refusal = terminal_guest.Refusal{};
    const info = terminal_guest.create(allocator, workspace_id, cwd, cols, rows, owner, &refusal) catch |err| {
        const status: u16 = switch (err) {
            error.InvalidSize => 400,
            error.WorkspaceInvalid => 400,
            error.TooManySessions => 429,
            error.UnsupportedPlatform => 501,
            error.ManagerUnavailable, error.ManagerRefused => 503,
            else => 500,
        };
        const message: []const u8 = switch (err) {
            error.InvalidSize => "cols/rows must be in [2, 1000]",
            error.WorkspaceInvalid => "workspace_id does not name a workspace",
            error.TooManySessions => "the workspace VM has no free terminal — close one to open a new shell",
            error.UnsupportedPlatform => "terminal sessions inside a workspace need a Linux host with a VM backend",
            error.ManagerUnavailable => "the workspace VM manager is not running",
            error.ManagerRefused => if (refusal.len > 0) refusal.text() else "the workspace VM refused the terminal",
            error.OutOfMemory => "Out of memory",
            else => "failed to create terminal session",
        };
        return res.jsonResponse(.{
            .status_code = status,
            .data = try http_response.makeErrorResponse(allocator, .{ .@"error" = message }),
        });
    };

    const json_str = try std.json.Stringify.valueAlloc(allocator, TerminalCreateResponse{
        .id = info.id,
        .pid = info.pid,
        .backend = info.backend,
    }, .{});
    return res.jsonResponse(.{ .status_code = 201, .data = json_str });
}

fn createHost(
    ctx: gserverz.HttpContext,
    res: gserverz.HttpResponse,
    cwd: []const u8,
    workspace_id: []const u8,
    shell: ?[]const u8,
    cols: ?u16,
    rows: ?u16,
    owner: []const u8,
) !gserverz.HttpResponse {
    const allocator = ctx.allocator;
    const info = terminal_session.createSession(ctx.io, cwd, workspace_id, shell, cols, rows, owner) catch |err| {
        const status: u16 = switch (err) {
            error.InvalidCwd, error.InvalidShell, error.InvalidSize => 400,
            error.CwdNotDir => 404,
            error.TooManySessions => 429,
            error.UnsupportedPlatform => 501,
            error.SpawnFailed, error.OutOfMemory => 500,
            // Unreachable on create (no session id involved yet) but
            // required for an exhaustive switch over SessionError.
            error.SessionNotFound, error.SessionExited, error.WriteFailed, error.ResizeFailed => 500,
        };
        const message: []const u8 = switch (err) {
            error.InvalidCwd => "cwd must be an absolute path",
            error.InvalidShell => "shell must be an absolute path",
            error.InvalidSize => "cols/rows must be in [2, 1000]",
            error.CwdNotDir => "cwd is not an existing directory",
            error.TooManySessions => "max 20 terminal sessions — close one to open a new shell",
            error.UnsupportedPlatform => "terminal sessions are not supported on this platform",
            error.SpawnFailed => "failed to spawn shell",
            error.OutOfMemory => "Out of memory",
            // Unreachable on create — see the status switch above.
            error.SessionNotFound, error.SessionExited, error.WriteFailed, error.ResizeFailed => "failed to create terminal session",
        };
        return res.jsonResponse(.{
            .status_code = status,
            .data = try http_response.makeErrorResponse(allocator, .{ .@"error" = message }),
        });
    };

    const json_str = try std.json.Stringify.valueAlloc(allocator, TerminalCreateResponse{
        .id = info.id,
        .pid = info.pid,
        .backend = info.backend,
    }, .{});
    return res.jsonResponse(.{ .status_code = 201, .data = json_str });
}

// ---------------------------------------------------------------------
// Inline tests (pure wire-shape checks; PTY spawn is covered by
// terminal_session.zig's posix echo test + the functional harness).

const testing = std.testing;
const terminal_guest_mod = @import("terminal_guest.zig");

test "empty body fields parse to defaults" {
    const parsed = try std.json.parseFromSliceLeaky(TerminalCreateBody, testing.allocator, "{}", .{});
    try testing.expectEqualStrings("", parsed.cwd);
    try testing.expect(parsed.shell == null);
    try testing.expect(parsed.cols == null);
    try testing.expect(parsed.rows == null);
    try testing.expect(parsed.workspace_id == null);
}

test "create body carries the workspace whose VM hosts the shell" {
    const parsed = try std.json.parseFromSliceLeaky(TerminalCreateBody, testing.allocator, "{\"workspace_id\":\"ws_1\",\"cwd\":\"/workspace\"}", .{});
    try testing.expectEqualStrings("ws_1", parsed.workspace_id.?);
    try testing.expectEqualStrings("/workspace", parsed.cwd);
}

test "create response serializes id + pid" {
    const json = try std.json.Stringify.valueAlloc(testing.allocator, TerminalCreateResponse{
        .id = "term-1",
        .pid = 4242,
        .backend = "conpty",
    }, .{});
    defer testing.allocator.free(json);
    try testing.expect(std.mem.indexOf(u8, json, "term-1") != null);
    try testing.expect(std.mem.indexOf(u8, json, "4242") != null);
    try testing.expect(std.mem.indexOf(u8, json, "conpty") != null);
}

test "a --saas create with no workspace is refused before any spawn" {
    // The route is what the handler switches on, so this is the refusal the
    // endpoint produces — a host shell is never the fallback.
    const route = terminal_guest_mod.routeFor(.saas, null);
    try testing.expectEqualStrings(terminal_guest_mod.workspace_hint, route.refuse);
}
