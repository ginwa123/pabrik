//! The `--saas` substrate for a shell command: resolve the session's workspace,
//! map the host `cwd` onto the guest's `/workspace`, and run there through
//! `pabrik-vmd`. Local mode installs nothing.

const std = @import("std");
const pabrikcore = @import("pabrikcore");
const test_db = pabrikcore.test_db;
const sqlite = pabrikcore.sqlite;
const database = pabrikcore.database;
const runtime_mode = @import("../runtime_mode.zig");
const workspace_scope = @import("workspace_scope.zig");
const workspace_vm = @import("workspace_vm.zig");
const shell = @import("../modules/agent/tools/shell.zig");
const vmd = @import("../vmd/vmd_client.zig");
const rpc = @import("../vmd/rpc.zig");
const policy = @import("../vmd/policy.zig");

pub const Error = error{
    GuestWorkspaceUnknown,
    /// The workspace is not VM-backed: no Firecracker, no host fallback.
    GuestWorkspaceNotVm,
    GuestCwdOutsideWorkspace,
    GuestManagerUnavailable,
    GuestManagerRefused,
};

/// What the executor needs to place a command: the session it belongs to. No
/// database or no session means there is no workspace to place it in, and the
/// executor refuses rather than guessing.
pub const GuestContext = struct {
    db: ?*database.Db,
    session_id: ?[]const u8,
    /// The Stop button. It reaches the HOST's wait for the manager's reply —
    /// it cannot kill the guest's process, which stays bounded by the
    /// request's own `timeout_ms` that the daemon enforces.
    cancel_hook: ?shell.CancelHook = null,
};

/// True when this process runs a session's commands in a workspace VM.
pub fn guestModeActive() bool {
    return runtime_mode.vm_backend_available and runtime_mode.currentMode() == .saas;
}

/// The workspace a session's commands belong to, or null when it does not
/// resolve to one. Under `--saas` this is also the VM they run in.
pub fn workspaceIdFor(
    allocator: std.mem.Allocator,
    db: *database.Db,
    session_id: []const u8,
) !?[]u8 {
    return workspace_scope.resolveWorkspaceId(allocator, db, session_id);
}

/// The name of a fresh job log. The manager owns the DIRECTORY and turns this
/// into a path, so the only thing chosen here stays a name.
pub fn jobLogName(allocator: std.mem.Allocator, io: std.Io) ![]u8 {
    const ts: i64 = @intCast(@divTrunc(std.Io.Timestamp.now(io, .real).nanoseconds, 1_000_000));
    return std.fmt.allocPrint(allocator, "bg_{d}.log", .{ts});
}

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
    _ = argv_prefix;
    const ctx: *const GuestContext = @ptrCast(@alignCast(ctx_ptr));

    // The host path's own guards, in the same order: a call with no deadline
    // or no absolute cwd is the caller's mistake in either substrate.
    const cwd = input.cwd orelse return error.MandatoryCwdMissing;
    if (cwd.len == 0) return error.MandatoryCwdMissing;
    if (!std.fs.path.isAbsolute(cwd)) return error.CwdNotAbsolute;
    const mode = shell.resolvedMode(input);
    // The host's deadline rule: required and bounded in the foreground, and
    // never consulted by the detached modes.
    var timeout_sec: u32 = 0;
    if (!mode.isDetached()) {
        timeout_sec = input.timeout orelse return error.TimeoutMissing;
        if (timeout_sec == 0) return error.TimeoutMissing;
        if (timeout_sec > shell.MAX_TIMEOUT_SEC) return error.TimeoutTooLarge;
    }

    // Fail closed: no session or no database means there is nowhere to place
    // the command, and running it on the host is not an option. Where it
    // belongs is asked BEFORE whether a manager is up.
    const db = ctx.db orelse return Error.GuestWorkspaceUnknown;
    const session_id = ctx.session_id orelse return Error.GuestWorkspaceUnknown;

    const workspace_id = (try workspace_scope.resolveWorkspaceId(allocator, db, session_id)) orelse
        return Error.GuestWorkspaceUnknown;
    defer allocator.free(workspace_id);
    if (!workspace_vm.isVmWorkspace(allocator, db, workspace_id)) return Error.GuestWorkspaceNotVm;
    const root = (try workspace_scope.resolveWorkspaceRoot(allocator, db, session_id)) orelse
        return Error.GuestWorkspaceUnknown;
    defer allocator.free(root);
    const cwd_rel = policy.relativeWorkspace(root, cwd) orelse return Error.GuestCwdOutsideWorkspace;

    const socket = runtime_mode.socketPath() orelse return Error.GuestManagerUnavailable;

    if (mode.isDetached()) {
        return spawnGuestJob(allocator, io, input, socket, workspace_id, cwd_rel);
    }

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
    }, guestProbe(ctx.cancel_hook)) catch |err| switch (err) {
        error.Cancelled => return cancelledByUser(allocator, input.command),
        else => return managerError(err),
    };
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

/// Detach the command INSIDE the workspace's VM. The reply's shape is the host
/// path's own — `PID: <guest pid>`, the guest's log path — so the tool records
/// a job the same way in either substrate.
fn spawnGuestJob(
    allocator: std.mem.Allocator,
    io: std.Io,
    input: shell.ShellInput,
    socket: []const u8,
    workspace_id: []const u8,
    cwd_rel: []const u8,
) !shell.ShellOutput {
    const log_name = try jobLogName(allocator, io);
    defer allocator.free(log_name);

    var client = vmd.Client.init(allocator, socket);
    const spawned = client.spawn(.{
        .workspace_id = workspace_id,
        .argv = &.{ policy.guest_shell, "-c", input.command },
        .cwd_rel = cwd_rel,
        .log_name = log_name,
    }) catch |err| return managerError(err);
    defer spawned.deinit(allocator);

    const stdout = try std.fmt.allocPrint(allocator, "PID: {d}\nLog: {s}", .{ spawned.pid, spawned.log_path });
    errdefer allocator.free(stdout);
    const stderr = try allocator.dupe(u8, "No errors.");
    errdefer allocator.free(stderr);
    const command = try copyCommandShaped(allocator, input.command);

    return .{
        .command = command,
        .stdout = stdout,
        .stderr = stderr,
        .exit_code = 0,
        .truncated = false,
        .timeout = false,
    };
}

/// The host path reports a detached command's text cut to 50 bytes, and the
/// tool's payload shape must not depend on the substrate.
fn copyCommandShaped(allocator: std.mem.Allocator, command: []const u8) ![]u8 {
    if (command.len <= 50) return allocator.dupe(u8, command);
    const cut = try allocator.alloc(u8, 53);
    @memcpy(cut[0..50], command[0..50]);
    @memcpy(cut[50..53], "...");
    return cut;
}

/// Adapt the tool-side hook to the transport's own probe type (the two are
/// structurally identical; the dependency arrow only points one way).
fn guestProbe(hook: ?shell.CancelHook) ?vmd.CancelProbe {
    const h = hook orelse return null;
    return .{ .ctx = h.ctx, .is_cancelled = h.is_cancelled };
}

/// What a stopped guest run reports. `exit_code` is -1, not -9: nothing was
/// signalled — the host stopped waiting, while the daemon still owns the
/// command until its `timeout_ms`. Saying SIGKILL here would be a lie the
/// transcript would carry.
fn cancelledByUser(allocator: std.mem.Allocator, command: []const u8) !shell.ShellOutput {
    const stderr = "Cancelled by the user while waiting for the workspace VM. " ++
        "The guest command keeps running until its own timeout; nothing on the host is waiting for it.";
    return .{
        .command = try copyCommandShaped(allocator, command),
        .stdout = try allocator.dupe(u8, "No output produced. The command was cancelled before it returned."),
        .stderr = try allocator.dupe(u8, stderr),
        .exit_code = -1,
        .truncated = false,
        .timeout = false,
        .cancelled = true,
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

const GuestTestCtx = struct {
    db: database.Db,
    threaded: std.Io.Threaded,

    fn deinit(self: *GuestTestCtx) void {
        self.db.deinit();
        self.threaded.deinit();
    }
};

/// The smallest database whose session resolves to a workspace: one item with a
/// path, one task linked to it, one session.
fn guestTestCtx() !GuestTestCtx {
    var threaded = std.Io.Threaded.init(testing.allocator, .{});
    errdefer threaded.deinit();
    var db: database.Db = .{};
    errdefer db.deinit();
    try test_db.openMemory(&db, threaded.io());

    try db.exec(testing.allocator,
        \\CREATE TABLE sessions (id TEXT PRIMARY KEY, name TEXT NOT NULL, status TEXT, cwd TEXT, workspace_id TEXT)
    , &.{});
    try db.exec(testing.allocator,
        \\CREATE TABLE workspace_items (id TEXT PRIMARY KEY, workspace_id TEXT, item_type TEXT, name TEXT, path TEXT, position INTEGER)
    , &.{});
    try db.exec(testing.allocator,
        \\CREATE TABLE workspace_item_tasks (id TEXT PRIMARY KEY, name TEXT NOT NULL, workspace_item_id TEXT NOT NULL)
    , &.{});
    try db.exec(testing.allocator,
        \\INSERT INTO workspace_items (id, workspace_id, item_type, name, path, position) VALUES ('i1','w1','kanban','A','/proj/a',1)
    , &.{});
    try db.exec(testing.allocator,
        \\INSERT INTO workspace_item_tasks (id, name, workspace_item_id) VALUES ('s1','T1','i1')
    , &.{});
    try db.exec(testing.allocator,
        \\INSERT INTO sessions (id, name, status, cwd) VALUES ('s1','Task one','active','/proj/a')
    , &.{});

    return .{ .db = db, .threaded = threaded };
}

test "jobLogName: every minted name is one the manager accepts" {
    const name = try jobLogName(testing.allocator, testing.io);
    defer testing.allocator.free(name);
    try testing.expect(policy.logNameValid(name));
    try testing.expect(std.mem.startsWith(u8, name, "bg_"));
}

test "runGuest: a detached call goes to the manager, not to an unsupported wall" {
    runtime_mode.setCurrent(.saas);
    defer runtime_mode.setCurrent(.local);
    if (!runtime_mode.vm_backend_available) return;

    // No database, so no workspace resolves — and the refusal must be THAT, not
    // "detached commands are unsupported inside the VM".
    const ctx = GuestContext{ .db = null, .session_id = "s" };
    const executor = executorFor(&ctx).?;
    const result = executor.run(executor.ctx, testing.allocator, testing.io, &.{}, .{
        .command = "make -j4",
        .cwd = "/tmp",
        .mode = .background,
    });
    try testing.expectError(Error.GuestWorkspaceUnknown, result);
}

test "runGuest: a detached call in a real workspace asks for a guest job" {
    runtime_mode.setCurrent(.saas);
    defer runtime_mode.setCurrent(.local);
    if (!runtime_mode.vm_backend_available) return;

    var ctx = try guestTestCtx();
    defer ctx.deinit();
    runtime_mode.setManagerSocket(null);
    defer runtime_mode.setManagerSocket(null);

    const guest = GuestContext{ .db = &ctx.db, .session_id = "s1" };
    const executor = executorFor(&guest).?;
    // `mode=background` is a legal call now: the workspace resolves, so the
    // only thing missing is the manager itself.
    const result = executor.run(executor.ctx, testing.allocator, testing.io, &.{}, .{
        .command = "make -j4",
        .cwd = "/proj/a",
        .mode = .background,
    });
    try testing.expectError(Error.GuestManagerUnavailable, result);
}

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
