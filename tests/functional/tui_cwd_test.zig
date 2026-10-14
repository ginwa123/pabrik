// Functional tests for pabrik-tui cwd fix. Zig port of
// `tests/functional/tui_cwd_test.py` (same test names, same order).

const std = @import("std");
const testing = std.testing;
const harness = @import("harness.zig");
const Harness = harness.Harness;
const gpa = testing.allocator;
const io = testing.io;

/// How long `_wait_for_session_cwd` polled before giving up.
const poll_timeout_ms: i64 = 5_000;
/// Python's `time.sleep(0.05)` between polls.
const poll_interval_ms: i64 = 50;

/// Monotonic milliseconds (`.awake`, not the wall clock — an NTP step
/// must not extend the deadline).
fn nowMs() i64 {
    return std.Io.Timestamp.now(io, .awake).toMilliseconds();
}

/// One `GET /api/llm/session/<id>` answer. `exists` false means the row is
/// not there yet — 404, which is the EXPECTED answer while the worker has not
/// inserted it, not a failure.
const SessionCwd = struct {
    exists: bool,
    cwd: []u8,
};

/// Read `sessions.cwd` over the wire. See the file header for why this is the
/// wire and not a SQLite read.
fn readSessionCwd(h: *Harness, session_id: []const u8) !SessionCwd {
    const path = try std.fmt.allocPrint(gpa, "/api/llm/session/{s}", .{session_id});
    defer gpa.free(path);

    // `assert_status = false`: the 404 is data here, so it must not go
    // through the harness's status assertion.
    var r = try h.http(io, .GET, path, .{
        .expect = &.{ 200, 404 },
        .assert_status = false,
    });
    defer r.deinit();

    if (r.status != 200) return .{ .exists = false, .cwd = gpa.dupe(u8, "") catch return error.OutOfMemory };

    var doc = try r.json();
    defer doc.deinit();
    const cwd = doc.str("cwd") orelse "";
    return .{
        .exists = true,
        .cwd = gpa.dupe(u8, cwd) catch return error.OutOfMemory,
    };
}

/// Poll `readSessionCwd` until the row appears, or the deadline passes.
/// Returns an OWNED cwd (the caller frees), or null when the row never
/// appeared.
fn waitForSessionCwd(h: *Harness, session_id: []const u8) !?[]u8 {
    const deadline = nowMs() + poll_timeout_ms;
    while (nowMs() < deadline) {
        const got = try readSessionCwd(h, session_id);
        // Every branch owns `got.cwd`; a not-found answer carries an
        // empty placeholder that has to be released too, or a 5-second
        // poll leaks one buffer per 50ms iteration.
        if (got.exists) return got.cwd;
        gpa.free(got.cwd);
        std.Io.sleep(io, .fromMilliseconds(poll_interval_ms), .awake) catch {};
    }
    return null;
}

/// The exact JSON body the TUI's `transport.buildSendBody` produces (see
/// `src/apps/cli/src/tui/transport.zig`) — `POST /api/llm/session` with every
/// field the desktop client also sends.
fn sendBody(gpa_: std.mem.Allocator, session_id: []const u8, message: []const u8, cwd_session: []const u8) ![]u8 {
    return std.json.Stringify.valueAlloc(gpa_, .{
        .session_id = session_id,
        .queue_message = message,
        .cwd_session = cwd_session,
        .allowed_tools = "all",
        .image_urls = "",
        .selected_profile_model = "",
        .is_auto_retry_until_stop = "",
    }, .{});
}

/// The cwd the TUI would report for `<temp_dir>/my-proj`. `os.path.realpath`
/// in Python resolves the EXISTING prefix of a path whose leaf does not
/// exist, then appends the leaf verbatim.
fn tuiCwdUnderTemp(h: *Harness, leaf: []const u8) ![]u8 {
    const real_temp = try harness.canonical(io, gpa, h.temp_dir);
    defer gpa.free(real_temp);
    return std.fs.path.join(gpa, &.{ real_temp, leaf });
}

// POST with cwd_session='/tmp/my-proj' → sessions.cwd == that path. This is
// what pabrik-tui now does: it captures the shell's cwd via realPath and
// sends it as cwd_session.
test "tui_cwd_reaches_backend_as_working_directory" {
    try harness.requirePabrikBin(io, gpa);
    var h = try Harness.boot(io, gpa, .{});
    defer h.deinit(io) catch |err| {
        std.debug.print("teardown: {s}\n", .{@errorName(err)});
    };

    const session_id = "tui-cwd-test-001";
    const cwd = try tuiCwdUnderTemp(&h, "my-proj");
    defer gpa.free(cwd);

    const body = try sendBody(gpa, session_id, "hello from tui", cwd);
    defer gpa.free(body);
    {
        // Python: `expect=(201, 500)` — the worker runs in the
        // background, so a 500 here is still a healthy boot with a
        // turn that failed, which the poll below reports on.
        var r = try h.http(io, .POST, "/api/llm/session", .{
            .json_body = body,
            .expect = &.{ 201, 500 },
        });
        defer r.deinit();
    }

    const got = (try waitForSessionCwd(&h, session_id)) orelse {
        std.debug.print(
            "sessions row for '{s}' never appeared within {d}s\n",
            .{ session_id, poll_timeout_ms / 1000 },
        );
        return error.TestUnexpectedResult;
    };
    defer gpa.free(got);

    if (!std.mem.eql(u8, got, cwd)) {
        std.debug.print(
            "sessions.cwd must equal the cwd_session sent by TUI. " ++
                "Expected '{s}', got '{s}'. If got is a sandbox path, " ++
                "transport.buildSendBody is still hardcoding \"\".\n",
            .{ cwd, got },
        );
        return error.TestUnexpectedResult;
    }
}

// POST with cwd_session='' → sessions.cwd is the sandbox path. Empty cwd is
// the sentinel for "no override" — the backend falls back to createSandbox →
// ~/.local/share/pabrik/data/apps/<session_id>.
test "tui_empty_cwd_falls_back_to_sandbox" {
    try harness.requirePabrikBin(io, gpa);
    var h = try Harness.boot(io, gpa, .{});
    defer h.deinit(io) catch |err| {
        std.debug.print("teardown: {s}\n", .{@errorName(err)});
    };

    const session_id = "tui-cwd-test-002";

    const body = try sendBody(gpa, session_id, "hello with empty cwd", "");
    defer gpa.free(body);
    {
        var r = try h.http(io, .POST, "/api/llm/session", .{
            .json_body = body,
            .expect = &.{ 201, 500 },
        });
        defer r.deinit();
    }

    const got = (try waitForSessionCwd(&h, session_id)) orelse {
        std.debug.print(
            "sessions row for '{s}' never appeared within {d}s\n",
            .{ session_id, poll_timeout_ms / 1000 },
        );
        return error.TestUnexpectedResult;
    };
    defer gpa.free(got);

    // Windows joins the sandbox with backslashes
    // (C:\...\pabrik-func-XXX\.local\share\pabrik\data\apps\<session>); POSIX
    // uses forward slashes.
    const normalized = try gpa.dupe(u8, got);
    defer gpa.free(normalized);
    for (normalized) |*c| {
        if (c.* == '\\') c.* = '/';
    }

    const sandbox_ok = std.mem.indexOf(u8, normalized, ".local/share/pabrik/data/apps") != null;
    const tmp_ok = std.mem.indexOf(u8, normalized, "/tmp") != null;
    if (!sandbox_ok and !tmp_ok) {
        std.debug.print(
            "empty cwd_session should fall back to sandbox (or /tmp). Got '{s}'\n",
            .{got},
        );
        return error.TestUnexpectedResult;
    }

    // Must NOT be the explicit cwd the sibling test sends.
    const explicit = try tuiCwdUnderTemp(&h, "my-proj");
    defer gpa.free(explicit);
    if (std.mem.eql(u8, got, explicit)) {
        std.debug.print("empty cwd should not equal explicit cwd, got '{s}'\n", .{got});
        return error.TestUnexpectedResult;
    }
}

// cwd with spaces and quotes must survive JSON escaping.
// transport.buildSendBody now uses encodeJsonString for cwd, so paths like
// '/tmp/my project' or '/tmp/a\"b' must round-trip.
test "tui_cwd_with_special_chars_round_trips" {
    try harness.requirePabrikBin(io, gpa);
    var h = try Harness.boot(io, gpa, .{});
    defer h.deinit(io) catch |err| {
        std.debug.print("teardown: {s}\n", .{@errorName(err)});
    };

    const session_id = "tui-cwd-test-003";
    const cwd = try tuiCwdUnderTemp(&h, "my project with spaces");
    defer gpa.free(cwd);

    const body = try sendBody(gpa, session_id, "hello", cwd);
    defer gpa.free(body);
    {
        var r = try h.http(io, .POST, "/api/llm/session", .{
            .json_body = body,
            .expect = &.{ 201, 500 },
        });
        defer r.deinit();
    }

    const got = (try waitForSessionCwd(&h, session_id)) orelse {
        std.debug.print("sessions row for '{s}' never appeared\n", .{session_id});
        return error.TestUnexpectedResult;
    };
    defer gpa.free(got);

    if (!std.mem.eql(u8, got, cwd)) {
        std.debug.print(
            "cwd with spaces must round-trip. Expected '{s}', got '{s}'\n",
            .{ cwd, got },
        );
        return error.TestUnexpectedResult;
    }
}

// Body-analysis barrier. An unreferenced function is never type-checked,
// so a stdlib rename inside one stays invisible until a caller appears.
comptime {
    _ = readSessionCwd;
    _ = waitForSessionCwd;
    _ = sendBody;
    _ = tuiCwdUnderTemp;
    _ = nowMs;
}
