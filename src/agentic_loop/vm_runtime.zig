//! The `--saas` substrate for a shell command: it resolves the session's
//! workspace, maps the tool's host `cwd` onto the guest's `/workspace` tree and
//! runs the command there through `pabrik-vmd`. Local mode installs nothing.

const std = @import("std");
const pabrikcore = @import("pabrikcore");
const sqlite = pabrikcore.sqlite;
const runtime_mode = @import("../runtime_mode.zig");
const workspace_scope = @import("workspace_scope.zig");
const shell = @import("../modules/agent/tools/shell.zig");
const vmd = @import("../vmd/vmd_client.zig");
const rpc = @import("../vmd/rpc.zig");
const policy = @import("../vmd/policy.zig");

pub const Error = error{
    GuestWorkspaceUnknown,
    GuestCwdOutsideWorkspace,
    GuestDetachedUnsupported,
    GuestManagerUnavailable,
    GuestManagerRefused,
};

/// What the executor needs to place a command: the session it belongs to. No
/// database or no session means there is no workspace to place it in, and the
/// executor refuses rather than guessing.
pub const GuestContext = struct {
    db: ?*sqlite.SqliteBackend,
    session_id: ?[]const u8,
};

/// The executor for this process, or null when commands belong on the host.
pub fn executorFor(ctx: *const GuestContext) ?shell.Executor {
    if (!runtime_mode.vm_backend_available) return null;
    if (runtime_mode.currentMode() != .saas) return null;
    return .{ .ctx = ctx, .run = runGuest };
}

fn runGuest(
    ctx_ptr: *const anyopaque,
    allocator: std.mem.Allocator,
    io: std.Io,
    argv_prefix: []const []const u8,
    input: shell.ShellInput,
) anyerror!shell.ShellOutput {
    _ = io;
    _ = argv_prefix;
    const ctx: *const GuestContext = @ptrCast(@alignCast(ctx_ptr));

    // The host path's own guards, in the same order: a call with no deadline
    // or no absolute cwd is the caller's mistake in either substrate.
    const cwd = input.cwd orelse return error.MandatoryCwdMissing;
    if (cwd.len == 0) return error.MandatoryCwdMissing;
    if (!std.fs.path.isAbsolute(cwd)) return error.CwdNotAbsolute;
    if (shell.resolvedMode(input).isDetached()) return Error.GuestDetachedUnsupported;
    const timeout_sec = input.timeout orelse return error.TimeoutMissing;
    if (timeout_sec == 0) return error.TimeoutMissing;
    if (timeout_sec > shell.MAX_TIMEOUT_SEC) return error.TimeoutTooLarge;

    const socket = runtime_mode.socketPath() orelse return Error.GuestManagerUnavailable;
    // Fail closed: with no session or no database there is no workspace to
    // place the command in, and running it on the host is not an option.
    const db = ctx.db orelse return Error.GuestWorkspaceUnknown;
    const session_id = ctx.session_id orelse return Error.GuestWorkspaceUnknown;

    const workspace_id = (try workspace_scope.resolveWorkspaceId(allocator, db, session_id)) orelse
        return Error.GuestWorkspaceUnknown;
    defer allocator.free(workspace_id);
    const root = (try workspace_scope.resolveWorkspaceRoot(allocator, db, session_id)) orelse
        return Error.GuestWorkspaceUnknown;
    defer allocator.free(root);
    const cwd_rel = policy.relativeToRoot(root, cwd) orelse return Error.GuestCwdOutsideWorkspace;

    const max_output = input.max_output orelse 20 * 1024;
    const max_lines = input.max_lines orelse 1000;
    // A base64 frame costs more than the bytes it carries, so the request
    // cannot ask for a capture the reply could not hold.
    const budget = @min(max_output, rpc.max_output_bytes_limit);

    var client = vmd.Client.init(allocator, socket);
    const outcome = client.exec(.{
        .workspace_id = workspace_id,
        .argv = &.{ policy.guest_shell, "-c", input.command },
        .cwd_rel = cwd_rel,
        .timeout_ms = timeout_sec * 1000,
        .max_output_bytes = budget,
    }) catch |err| return managerError(err);
    defer outcome.deinit(allocator);

    const stdout = try shapeCapture(allocator, outcome.stdout, max_output, max_lines, "No output produced.");
    errdefer allocator.free(stdout.bytes);
    const stderr = try shapeCapture(allocator, outcome.stderr, max_output, max_lines, "No errors.");
    errdefer allocator.free(stderr.bytes);
    const command = try allocator.dupe(u8, input.command);

    return .{
        .command = command,
        .stdout = stdout.bytes,
        .stderr = stderr.bytes,
        .exit_code = clampExit(outcome.code),
        .truncated = stdout.truncated or stderr.truncated or max_output > budget,
        .timeout = outcome.timed_out,
        .stdout_lines = stdout.lines,
        .stderr_lines = stderr.lines,
    };
}

fn managerError(err: anyerror) anyerror {
    return switch (err) {
        error.ConnectFailed, error.SocketFailed, error.IoFailed, error.Timeout => Error.GuestManagerUnavailable,
        error.ServerFailure => Error.GuestManagerRefused,
        else => err,
    };
}

fn clampExit(code: i64) i32 {
    if (code > std.math.maxInt(i32)) return std.math.maxInt(i32);
    if (code < std.math.minInt(i32)) return std.math.minInt(i32);
    return @intCast(code);
}

const Captured = struct {
    bytes: []u8,
    lines: usize,
    truncated: bool,
};

/// The host reader's policy, applied to bytes that arrived in one piece: the
/// byte ceiling, the line ceiling, and the empty-capture placeholder.
fn shapeCapture(
    allocator: std.mem.Allocator,
    raw: []const u8,
    max_output: usize,
    max_lines: usize,
    placeholder: []const u8,
) !Captured {
    var keep = @min(raw.len, max_output);
    var truncated = raw.len > keep;
    var lines: usize = 0;
    for (raw[0..keep], 0..) |byte, i| {
        if (byte != '\n') continue;
        lines += 1;
        if (lines == max_lines) {
            keep = i + 1;
            truncated = truncated or raw.len > keep;
            break;
        }
    }
    const bytes = try shell.shapeCapture(allocator, raw[0..keep], max_output, placeholder);
    return .{ .bytes = bytes, .lines = lines, .truncated = truncated };
}

// ============================================================================
// Behaviour tests — the pure half. A live VM is the smoke scripts' job.
// ============================================================================

const testing = std.testing;

test "executorFor: local mode installs no executor at all" {
    try testing.expectEqual(runtime_mode.Mode.local, runtime_mode.currentMode());
    try testing.expect(executorFor(&GuestContext{ .db = null, .session_id = "s" }) == null);
}

test "executorFor: the guest executor is installed exactly when the backend can run it" {
    const ctx = GuestContext{ .db = null, .session_id = "s" };
    runtime_mode.setCurrent(.saas);
    defer runtime_mode.setCurrent(.local);
    if (runtime_mode.vm_backend_available) {
        try testing.expect(executorFor(&ctx) != null);
    } else {
        // No substrate for a VM on this host, so there is nothing to install.
        try testing.expect(executorFor(&ctx) == null);
    }
}

test "shapeCapture: a long capture is cut at the byte ceiling and reported" {
    const allocator = testing.allocator;
    const raw = "0123456789";
    const cut = try shapeCapture(allocator, raw, 4, 1000, "placeholder");
    defer allocator.free(cut.bytes);
    try testing.expectEqualStrings("0123", cut.bytes);
    try testing.expect(cut.truncated);
    try testing.expectEqual(@as(usize, 0), cut.lines);
}

test "shapeCapture: the line ceiling cuts a capture the byte ceiling would keep" {
    const allocator = testing.allocator;
    const raw = "one\ntwo\nthree\nfour\n";
    const cut = try shapeCapture(allocator, raw, 1000, 2, "placeholder");
    defer allocator.free(cut.bytes);
    try testing.expectEqualStrings("one\ntwo\n", cut.bytes);
    try testing.expectEqual(@as(usize, 2), cut.lines);
    try testing.expect(cut.truncated);
}

test "shapeCapture: an empty capture reads as its placeholder and cuts nothing" {
    const allocator = testing.allocator;
    const cut = try shapeCapture(allocator, "", 1000, 1000, "No output produced.");
    defer allocator.free(cut.bytes);
    try testing.expectEqualStrings("No output produced.", cut.bytes);
    try testing.expect(!cut.truncated);
    try testing.expectEqual(@as(usize, 0), cut.lines);
}

test "shapeCapture: a capture inside every ceiling is returned whole" {
    const allocator = testing.allocator;
    const raw = "line one\nline two\n";
    const cut = try shapeCapture(allocator, raw, 1000, 1000, "placeholder");
    defer allocator.free(cut.bytes);
    try testing.expectEqualStrings(raw, cut.bytes);
    try testing.expect(!cut.truncated);
    try testing.expectEqual(@as(usize, 2), cut.lines);
}

test "managerError: a manager that is not there and one that refuses are told apart" {
    try testing.expectEqual(Error.GuestManagerUnavailable, managerError(error.ConnectFailed));
    try testing.expectEqual(Error.GuestManagerUnavailable, managerError(error.Timeout));
    try testing.expectEqual(Error.GuestManagerRefused, managerError(error.ServerFailure));
    // Anything else keeps its own name, so a protocol bug is not disguised
    // as a missing daemon.
    try testing.expectEqual(error.ProtocolViolation, managerError(error.ProtocolViolation));
}
