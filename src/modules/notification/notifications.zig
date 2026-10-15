
const std = @import("std");
const builtin = @import("builtin");
const log = std.log.scoped(.notifications);

/// Maximum characters of the body we pass to the OS. notify-send and friends
/// don't have a hard limit, but very long bodies look bad in toast UIs and
/// are truncated visually anyway. 140 chars is roughly 2 sentences.
pub const MAX_BODY_LEN: usize = 140;

pub const NotifyError = error{
    /// The OS notification binary is not installed (e.g. notify-send on a
    /// Linux box without libnotify) or the spawn failed. Caller should log
    /// and continue — a notification failure must not break the LLM workflow.
    BinaryNotFound,
    OutOfMemory,
};

/// Build the argv that would be spawned for the current OS. Public so tests
/// can assert on the command shape without actually running it.
pub fn buildCommand(allocator: std.mem.Allocator, title: []const u8, body: []const u8) ![]const []const u8 {
    const truncated = try truncateBody(allocator, body, MAX_BODY_LEN);
    errdefer allocator.free(truncated);

    var args: std.ArrayList([]const u8) = .empty;
    // On any error path, free all the strings we've already appended plus
    // the ArrayList's backing buffer.
    errdefer {
        for (args.items) |arg| allocator.free(arg);
        args.deinit(allocator);
    }

    switch (builtin.os.tag) {
        .linux => {
            try args.append(allocator, try allocator.dupe(u8, "notify-send"));
            try args.append(allocator, try allocator.dupe(u8, "--app-name=pabrik"));
            try args.append(allocator, try allocator.dupe(u8, title));
            try args.append(allocator, truncated);
        },
        .macos => {
            // AppleScript: display notification "body" with title "title"
            // Body and title are escaped for double-quote and backslash
            // insertion.
            const title_esc = try escapeAppleScript(allocator, title);
            defer allocator.free(title_esc);
            const body_esc = try escapeAppleScript(allocator, truncated);
            defer allocator.free(body_esc);
            const script = try std.fmt.allocPrint(
                allocator,
                "display notification \"{s}\" with title \"{s}\"",
                .{ body_esc, title_esc },
            );
            errdefer allocator.free(script);
            try args.append(allocator, try allocator.dupe(u8, "osascript"));
            try args.append(allocator, try allocator.dupe(u8, "-e"));
            try args.append(allocator, script);
            // `truncated` was consumed by escapeAppleScript (which copies)
            // and the errdefer only fires on error. Free it now since we're
            // about to return successfully.
            allocator.free(truncated);
        },
        .windows => {
            // PowerShell stub: uses MessageBox (a blocking modal) instead of
            // a proper toast.
            const script = try std.fmt.allocPrint(
                allocator,
                "[System.Reflection.Assembly]::LoadWithPartialName('System.Windows.Forms') | Out-Null; " ++
                    "[System.Windows.Forms.MessageBox]::Show('{s}', '{s}')",
                .{ title, truncated },
            );
            errdefer allocator.free(script);
            try args.append(allocator, try allocator.dupe(u8, "powershell"));
            try args.append(allocator, try allocator.dupe(u8, "-NoProfile"));
            try args.append(allocator, try allocator.dupe(u8, "-Command"));
            try args.append(allocator, script);
            // `truncated` was consumed by allocPrint (which copies); free
            // it now since the errdefer only fires on error and we're
            // about to return successfully.
            allocator.free(truncated);
        },
        else => {
            log.warn("notifications: unsupported OS {s}; skipping", .{@tagName(builtin.os.tag)});
            // truncated is no longer needed — free it manually.
            allocator.free(truncated);
        },
    }

    return try args.toOwnedSlice(allocator);
}

/// Fire an OS notification using the platform's native CLI (notify-send /
/// osascript / PowerShell).
pub fn notify(io: std.Io, allocator: std.mem.Allocator, title: []const u8, body: []const u8) NotifyError!void {
    const cmd = buildCommand(allocator, title, body) catch return error.OutOfMemory;
    defer {
        for (cmd) |arg| allocator.free(arg);
        allocator.free(cmd);
    }
    if (cmd.len == 0) return; // Unsupported OS — already logged inside buildCommand.
    return notifyWithArgv(io, cmd);
}

/// Test-only helper: spawn a specific binary path. Used by the
/// `BinaryNotFound` test. Production code uses `notify()` which calls
/// `buildCommand` to pick the path.
pub fn notifyWithPath(io: std.Io, allocator: std.mem.Allocator, path: []const u8, title: []const u8, body: []const u8) NotifyError!void {
    const truncated = try truncateBody(allocator, body, MAX_BODY_LEN);
    defer allocator.free(truncated);
    const argv = try allocator.dupe([]const u8, &[_][]const u8{
        path,
        title,
        truncated,
    });
    defer allocator.free(argv);
    return notifyWithArgv(io, argv);
}

/// Args passed to the reaper thread. The struct is copied onto the thread's
/// stack for the thread's lifetime, so no heap allocation is needed.
const ReaperArgs = struct {
    io: std.Io,
    child: std.process.Child,
};

/// One-shot reaper thread: blocks on `child.wait` so the OS can reap the
/// child when it exits.
fn reapChild(args: ReaperArgs) void {
    var local = args;
    _ = local.child.wait(local.io) catch {};
}

fn notifyWithArgv(io: std.Io, argv: []const []const u8) NotifyError!void {
    // Any spawn failure (file not found, permission denied, etc.) is
    // collapsed into `BinaryNotFound` so the LLM workflow logs it and moves
    // on.
    var child = std.process.spawn(io, .{
        .argv = argv,
        .stdin = .ignore,
        .stdout = .ignore,
        .stderr = .ignore,
    }) catch return error.BinaryNotFound;
    if (child.id == null) return error.BinaryNotFound;

    // Fire-and-forget from the LLM workflow's perspective: we must not block
    // waiting for notify-send to exit (a slow toast library would freeze the
    // chat).
    const args = ReaperArgs{ .io = io, .child = child };
    if (std.Thread.spawn(.{}, reapChild, .{args})) |thread| {
        thread.detach();
    } else |_| {
        // Thread spawn failed (out of memory / thread limit). Fall back to
        // inline `child.kill(io)` to at least prevent zombie accumulation.
        child.kill(io);
    }
}

/// Truncate `body` to `max` characters, appending an ellipsis when truncated.
/// Always returns a freshly-allocated slice that the caller owns and must
/// `allocator.free()`.
pub fn truncateBody(allocator: std.mem.Allocator, body: []const u8, max: usize) ![]u8 {
    if (body.len <= max) return try allocator.dupe(u8, body);
    const ellipsis: []const u8 = "…";
    const cut = max - ellipsis.len;
    var out = try allocator.alloc(u8, max);
    @memcpy(out[0..cut], body[0..cut]);
    @memcpy(out[cut..max], ellipsis);
    return out;
}

fn escapeAppleScript(allocator: std.mem.Allocator, s: []const u8) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);
    for (s) |c| {
        switch (c) {
            '"', '\\' => try out.append(allocator, '\\'),
            else => {},
        }
        try out.append(allocator, c);
    }
    return out.toOwnedSlice(allocator);
}

// ===== Tests merged from notifications_test.zig (2026-09-29 flatten) =====
const testing = std.testing;

// ---------------------------------------------------------------------------
// truncateBody: pure helper, no OS-specific code
// ---------------------------------------------------------------------------

test "truncateBody returns input unchanged when shorter than max" {
    const allocator = testing.allocator;
    {
        const result = try truncateBody(allocator, "hello", 140);
        defer allocator.free(result);
        try testing.expectEqualStrings("hello", result);
    }
    {
        const result = try truncateBody(allocator, "", 140);
        defer allocator.free(result);
        try testing.expectEqualStrings("", result);
    }
}

test "truncateBody cuts to max-1 chars and appends an ellipsis" {
    const allocator = testing.allocator;
    var long: [500]u8 = undefined;
    @memset(&long, 'x');
    const result = try truncateBody(allocator, &long, 10);
    defer allocator.free(result);
    try testing.expectEqual(@as(usize, 10), result.len);
    try testing.expect(std.mem.endsWith(u8, result, "…"));
}

test "truncateBody at the boundary returns the original (no ellipsis)" {
    const allocator = testing.allocator;
    var input_buf: [140]u8 = undefined;
    @memset(&input_buf, 'x');
    const result = try truncateBody(allocator, &input_buf, 140);
    defer allocator.free(result);
    try testing.expectEqual(@as(usize, 140), result.len);
    try testing.expectEqualStrings(&input_buf, result);
}

// ---------------------------------------------------------------------------
// buildCommand: per-OS argv construction (skipped on non-matching OS)
// ---------------------------------------------------------------------------

test "buildCommand on Linux returns notify-send as the first arg" {
    if (builtin.os.tag != .linux) return;
    const allocator = testing.allocator;
    const cmd = try buildCommand(allocator, "Title", "Body text");
    defer {
        for (cmd) |arg| allocator.free(arg);
        allocator.free(cmd);
    }
    try testing.expect(cmd.len >= 4);
    try testing.expectEqualStrings("notify-send", cmd[0]);
    try testing.expectEqualStrings("--app-name=pabrik", cmd[1]);
    try testing.expectEqualStrings("Title", cmd[2]);
    try testing.expectEqualStrings("Body text", cmd[3]);
}

test "buildCommand on macOS returns osascript with display notification script" {
    if (builtin.os.tag != .macos) return;
    const allocator = testing.allocator;
    const cmd = try buildCommand(allocator, "Title", "Body");
    defer {
        for (cmd) |arg| allocator.free(arg);
        allocator.free(cmd);
    }
    try testing.expectEqualStrings("osascript", cmd[0]);
    try testing.expectEqualStrings("-e", cmd[1]);
    try testing.expect(std.mem.indexOf(u8, cmd[2], "display notification") != null);
    try testing.expect(std.mem.indexOf(u8, cmd[2], "Title") != null);
}

test "buildCommand on Windows returns powershell with the notification" {
    if (builtin.os.tag != .windows) return;
    const allocator = testing.allocator;
    const cmd = try buildCommand(allocator, "Title", "Body");
    defer {
        for (cmd) |arg| allocator.free(arg);
        allocator.free(cmd);
    }
    try testing.expectEqualStrings("powershell", cmd[0]);
    try testing.expectEqualStrings("-NoProfile", cmd[1]);
    try testing.expect(std.mem.indexOf(u8, cmd[3], "Title") != null);
    try testing.expect(std.mem.indexOf(u8, cmd[3], "Body") != null);
}

test "buildCommand truncates body longer than 140 chars" {
    const allocator = testing.allocator;
    var long: [500]u8 = undefined;
    @memset(&long, 'x');
    const cmd = try buildCommand(allocator, "T", &long);
    defer {
        for (cmd) |arg| allocator.free(arg);
        allocator.free(cmd);
    }
    // Every argv item should be bounded by the platform's argv-item length
    // limit.
    const max_arg_len: usize = if (builtin.os.tag == .windows) 400 else 350;
    for (cmd) |arg| {
        try testing.expect(arg.len <= max_arg_len);
    }
    // The body (truncated to 140 chars + ellipsis "…") should be present in
    // the command's output.
    var all_args: std.ArrayList(u8) = .empty;
    defer all_args.deinit(allocator);
    for (cmd) |arg| {
        try all_args.appendSlice(allocator, arg);
        try all_args.append(allocator, '\n');
    }
    // The body should appear in the rendered command as 137 'x' chars
    // (MAX_BODY_LEN=140 minus ellipsis_len=3) followed by the ellipsis.
    var expected_body_buf: [MAX_BODY_LEN]u8 = undefined;
    @memset(expected_body_buf[0 .. MAX_BODY_LEN - 3], 'x');
    @memcpy(
        expected_body_buf[MAX_BODY_LEN - 3 ..][0..3],
        "…",
    );
    const expected_body_substr: []const u8 = &expected_body_buf;
    try testing.expect(std.mem.indexOf(u8, all_args.items, expected_body_substr) != null);
}

// ---------------------------------------------------------------------------
// notifyWithPath: tests the BinaryNotFound error path without needing notify-send
// ---------------------------------------------------------------------------

test "notifyWithPath returns BinaryNotFound when the binary does not exist" {
    const allocator = testing.allocator;
    const result = notifyWithPath(testing.io, allocator, "/nonexistent/path/notify-send", "T", "B");
    try testing.expectError(error.BinaryNotFound, result);
}

test "notifyWithPath returns BinaryNotFound for an empty path" {
    const allocator = testing.allocator;
    const result = notifyWithPath(testing.io, allocator, "", "T", "B");
    try testing.expectError(error.BinaryNotFound, result);
}

// ---------------------------------------------------------------------------
// notifyWithPath positive path: spawn /bin/true (exits immediately) to verify
// the spawn-and-reap pipeline works.

test "notifyWithPath with /bin/true returns success and does not leak" {
    if (builtin.os.tag == .windows) return; // no `true` binary on Windows
    const allocator = testing.allocator;
    // `/bin/true` exists on Linux but NOT on macOS — BSD true lives at
    // `/usr/bin/true` (modern macOS no longer carries the legacy `/bin`
    // symlink alias, so a hardcoded `/bin/true` spawn fails with
    const true_bin: []const u8 = if (builtin.os.tag == .macos) "/usr/bin/true" else "/bin/true";
    // true exits immediately. If the function blocks on a
    // synchronous child.wait, the test still passes (the wait is
    // microseconds).
    try notifyWithPath(testing.io, allocator, true_bin, "T", "B");
    // No explicit assertion needed: returning from notifyWithPath
    // without error is the success criterion.
}
