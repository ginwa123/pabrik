// Functional e2e for the right-sidebar terminal HTTP endpoints. Zig port of
// `tests/functional/terminal_session_test.py` (same test names, same order).

const std = @import("std");
const builtin = @import("builtin");
const testing = std.testing;
const harness = @import("harness.zig");
const Harness = harness.Harness;
const gpa = testing.allocator;
const io = testing.io;

/// The shell every terminal in this suite runs. Windows has no `/bin/sh`;
/// `cmd.exe` is its interactive equivalent, and the assertions below hold
/// for it unchanged — a marker line goes in and the marker comes out. The
const SHELL = if (builtin.os.tag == .windows)
    "C:\\Windows\\System32\\cmd.exe"
else
    "/bin/sh";

/// How a line ends on this host's shell. `cmd.exe` reads in cooked mode and
/// commits on CR, so its lines end CRLF; a POSIX shell is happy with LF.
/// Not cosmetic: a bare LF works on most `cmd.exe` builds but is not the
const LINE_END = if (builtin.os.tag == .windows) "\r\n" else "\n";

/// Monotonic milliseconds (`.awake`, not the wall clock — an NTP step
/// must not extend a poll deadline).
fn nowMs() i64 {
    return std.Io.Timestamp.now(io, .awake).toMilliseconds();
}

/// `"echo <marker>"` + this platform's line end, as an OWNED buffer.
/// Written with `allocPrint` rather than `"echo " ++ marker ++ "\n"`, which
/// only compiles for comptime-known operands — and a marker is exactly the
fn echoLine(marker: []const u8) ![]u8 {
    return std.fmt.allocPrint(gpa, "echo {s}{s}", .{ marker, LINE_END });
}

// ============================================================================
// Helpers
// ============================================================================

/// One `GET /api/terminal/sessions/<id>/output` answer, with every string
/// COPIED so it can outlive the `Response` it came from.
const OutputPage = struct {
    data: []u8,
    cursor: i64,
    exited: bool,
    exit_code: ?i64,

    fn deinit(self: *OutputPage) void {
        gpa.free(self.data);
        self.* = undefined;
    }
};

/// `POST /api/terminal/sessions` with the Python `_create` body: `{"shell":
/// ...}` plus `"cwd"` only when `cwd` is non-null (so the no-cwd call really
/// sends no `cwd` key at all, like Python's `if cwd is not None`).
fn createRaw(
    h: *Harness,
    cwd: ?[]const u8,
    shell: []const u8,
    expect: []const u16,
) !harness.Response {
    const body = if (cwd) |c|
        try std.json.Stringify.valueAlloc(gpa, .{ .shell = shell, .cwd = c }, .{})
    else
        try std.json.Stringify.valueAlloc(gpa, .{ .shell = shell }, .{});
    defer gpa.free(body);

    return h.http(io, .POST, "/api/terminal/sessions", .{
        .json_body = body,
        .expect = expect,
    });
}

/// `POST /api/terminal/sessions` → the new terminal's id (owned).
fn create(h: *Harness, cwd: ?[]const u8) ![]u8 {
    var r = try createRaw(h, cwd, SHELL, &.{201});
    defer r.deinit();
    var doc = try r.json();
    defer doc.deinit();
    return gpa.dupe(u8, doc.str("id") orelse {
        std.debug.print("terminal create returned no id: {s}\n", .{r.body});
        return error.TestUnexpectedResult;
    });
}

/// `POST /api/terminal/sessions/<id>/input {"data": ...}`.
fn inputRaw(
    h: *Harness,
    sid: []const u8,
    data: []const u8,
    expect: []const u16,
) !harness.Response {
    const body = try std.json.Stringify.valueAlloc(gpa, .{ .data = data }, .{});
    defer gpa.free(body);
    const path = try std.fmt.allocPrint(gpa, "/api/terminal/sessions/{s}/input", .{sid});
    defer gpa.free(path);
    return h.http(io, .POST, path, .{ .json_body = body, .expect = expect });
}

/// `GET /api/terminal/sessions/<id>/output?cursor=N`. The cursor goes through
/// `.params`, which the harness PERCENT-ENCODES — never pre-encode it here.
fn outputRaw(
    h: *Harness,
    sid: []const u8,
    cursor: i64,
    expect: []const u16,
) !harness.Response {
    const path = try std.fmt.allocPrint(gpa, "/api/terminal/sessions/{s}/output", .{sid});
    defer gpa.free(path);
    var buf: [32]u8 = undefined;
    const cs = try std.fmt.bufPrint(&buf, "{d}", .{cursor});
    return h.http(io, .GET, path, .{
        .params = &.{.{ .name = "cursor", .value = cs }},
        .expect = expect,
    });
}

/// The 200 flavour of `outputRaw`, parsed into OWNED bytes.
fn outputPage(h: *Harness, sid: []const u8, cursor: i64) !OutputPage {
    var r = try outputRaw(h, sid, cursor, &.{200});
    defer r.deinit();
    var doc = try r.json();
    defer doc.deinit();

    const data: []const u8 = doc.str("data") orelse "";
    return .{
        .data = try gpa.dupe(u8, data),
        .cursor = doc.int("cursor") orelse cursor,
        .exited = doc.boolean("exited") orelse false,
        .exit_code = doc.int("exit_code"),
    };
}

/// Poll output until `marker` appears (the frontend poll replay). Returns the
/// page that satisfied the marker (owned).
fn pollFor(
    h: *Harness,
    sid: []const u8,
    marker: []const u8,
    deadline_ms: i64,
) !OutputPage {
    const deadline = nowMs() + deadline_ms;
    var cursor: i64 = 0;

    var seen: std.Io.Writer.Allocating = .init(gpa);
    defer seen.deinit();

    var last: ?OutputPage = null;
    defer if (last) |*p| p.deinit();

    while (nowMs() < deadline) {
        const page = try outputPage(h, sid, cursor);
        if (last) |*p| p.deinit();
        last = page;

        seen.writer.writeAll(page.data) catch return error.OutOfMemory;
        if (std.mem.indexOf(u8, seen.written(), marker) != null) break;
        if (page.exited) break;
        cursor = page.cursor;
        std.Io.sleep(io, .fromMilliseconds(300), .awake) catch {};
    }

    if (std.mem.indexOf(u8, seen.written(), marker) == null) {
        std.debug.print(
            "marker {s} never appeared for {s}; seen={s}\n",
            .{ marker, sid, seen.written() },
        );
        return error.TestUnexpectedResult;
    }
    const out = last orelse {
        std.debug.print("no output page was ever read for {s}\n", .{sid});
        return error.TestUnexpectedResult;
    };
    last = null;
    return out;
}

/// Poll forward until the session stops producing output; return the cursor.
/// A PTY never really stops: after the marker round-trips, the shell redraws
/// its prompt and re-emits the command echo.
fn settleCursor(
    h: *Harness,
    sid: []const u8,
    quiet_reads: u32,
    deadline_ms: i64,
) !i64 {
    const deadline = nowMs() + deadline_ms;
    var cursor: i64 = 0;
    var quiet: u32 = 0;
    while (nowMs() < deadline and quiet < quiet_reads) {
        var page = try outputPage(h, sid, cursor);
        defer page.deinit();
        cursor = page.cursor;
        if (page.data.len == 0) {
            quiet += 1;
        } else {
            quiet = 0;
            std.Io.sleep(io, .fromMilliseconds(200), .awake) catch {};
        }
    }
    return cursor;
}

/// Python's `finally: harness.http("DELETE", ...)`.
fn deleteSession(h: *Harness, sid: []const u8) void {
    const path = std.fmt.allocPrint(gpa, "/api/terminal/sessions/{s}", .{sid}) catch return;
    defer gpa.free(path);
    var r = h.http(io, .DELETE, path, .{ .expect = &.{ 200, 404 } }) catch return;
    defer r.deinit();
}

// ============================================================================
// Tests
// ============================================================================

// Create -> echo a marker -> poll until it comes back -> cursor advances.
test "create_input_output_round_trip" {
    try harness.requirePabrikBin(io, gpa);
    var h = try Harness.boot(io, gpa, .{});
    defer h.deinit(io) catch |err| {
        std.debug.print("teardown: {s}\n", .{@errorName(err)});
    };

    // `cwd` is derived from the harness tempdir: absolute on every
    // platform, and a directory that certainly exists.
    const cwd = try harness.harnessPath(gpa, h.temp_dir, &.{});
    defer gpa.free(cwd);

    var created = try createRaw(&h, cwd, SHELL, &.{201});
    defer created.deinit();
    const sid = blk: {
        var doc = try created.json();
        defer doc.deinit();
        const id = doc.str("id") orelse {
            std.debug.print("terminal create returned no id: {s}\n", .{created.body});
            return error.TestUnexpectedResult;
        };
        if (id.len == 0) {
            std.debug.print("terminal create returned an empty id\n", .{});
            return error.TestUnexpectedResult;
        }
        const pid = doc.int("pid") orelse {
            std.debug.print("terminal create returned no integer `pid`: {s}\n", .{created.body});
            return error.TestUnexpectedResult;
        };
        if (pid == 0) {
            std.debug.print("terminal create reported pid 0\n", .{});
            return error.TestUnexpectedResult;
        }
        break :blk try gpa.dupe(u8, id);
    };
    defer gpa.free(sid);
    defer deleteSession(&h, sid);

    const marker = "MARKER-9d2c41";
    {
        const line = try echoLine(marker);
        defer gpa.free(line);
        var r = try inputRaw(&h, sid, line, &.{200});
        defer r.deinit();
        var doc = try r.json();
        defer doc.deinit();
        if (doc.boolean("ok") != true) {
            std.debug.print("input ack is not ok: {s}\n", .{r.body});
            return error.TestUnexpectedResult;
        }
        const bytes = doc.int("bytes") orelse 0;
        if (bytes <= 0) {
            std.debug.print("input ack reported {d} bytes: {s}\n", .{ bytes, r.body });
            return error.TestUnexpectedResult;
        }
    }

    {
        var page = try pollFor(&h, sid, marker, 20_000);
        defer page.deinit();
    }

    // Let the prompt redraw drain, then hold the cursor fixed: a repeat read
    // at a cursor the server has already served must come back empty.
    const settled = try settleCursor(&h, sid, 2, 10_000);
    if (settled <= 0) {
        std.debug.print("session produced no output at all\n", .{});
        return error.TestUnexpectedResult;
    }
    {
        var r = try outputRaw(&h, sid, settled, &.{200});
        defer r.deinit();
        var doc = try r.json();
        defer doc.deinit();
        const data: []const u8 = doc.str("data") orelse "";
        if (data.len != 0) {
            std.debug.print(
                "re-reading from settled cursor {d} replayed \"{s}\"\n",
                .{ settled, data },
            );
            return error.TestUnexpectedResult;
        }
    }
}

// Resize round-trips dims; delete is 200 then 404; output 404s after.
test "resize_and_delete" {
    try harness.requirePabrikBin(io, gpa);
    var h = try Harness.boot(io, gpa, .{});
    defer h.deinit(io) catch |err| {
        std.debug.print("teardown: {s}\n", .{@errorName(err)});
    };

    const cwd = try harness.harnessPath(gpa, h.temp_dir, &.{});
    defer gpa.free(cwd);
    const sid = try create(&h, cwd);
    defer gpa.free(sid);

    const resize_path = try std.fmt.allocPrint(gpa, "/api/terminal/sessions/{s}/resize", .{sid});
    defer gpa.free(resize_path);

    {
        const body =
            \\{"cols":100,"rows":40}
        ;
        var r = try h.http(io, .POST, resize_path, .{ .json_body = body, .expect = &.{200} });
        defer r.deinit();
        var doc = try r.json();
        defer doc.deinit();
        try testing.expectEqual(@as(i64, 100), doc.int("cols") orelse -1);
        try testing.expectEqual(@as(i64, 40), doc.int("rows") orelse -1);
    }

    // Bad dims are 400, not a resize.
    {
        const bad =
            \\{"cols":1,"rows":40}
        ;
        var r = try h.http(io, .POST, resize_path, .{ .json_body = bad, .expect = &.{400} });
        defer r.deinit();
    }

    {
        const path = try std.fmt.allocPrint(gpa, "/api/terminal/sessions/{s}", .{sid});
        defer gpa.free(path);
        var r = try h.http(io, .DELETE, path, .{ .expect = &.{200} });
        defer r.deinit();
        var doc = try r.json();
        defer doc.deinit();
        if (doc.boolean("ok") != true) {
            std.debug.print("delete did not report ok: {s}\n", .{r.body});
            return error.TestUnexpectedResult;
        }
    }
    {
        const path = try std.fmt.allocPrint(gpa, "/api/terminal/sessions/{s}", .{sid});
        defer gpa.free(path);
        var r = try h.http(io, .DELETE, path, .{ .expect = &.{404} });
        defer r.deinit();
    }
    {
        var r = try outputRaw(&h, sid, 0, &.{404});
        defer r.deinit();
    }
    {
        var r = try inputRaw(&h, sid, "echo hi\n", &.{404});
        defer r.deinit();
    }
}

// Relative cwd is 400; cwd-that-is-a-file is 404; empty cwd falls back to
// the server cwd (201, not 400) so cwd-less chats work.
test "create_validation" {
    try harness.requirePabrikBin(io, gpa);
    var h = try Harness.boot(io, gpa, .{});
    defer h.deinit(io) catch |err| {
        std.debug.print("teardown: {s}\n", .{@errorName(err)});
    };

    // Relative cwd: the literal is the point of the assertion, and it is
    // relative on every platform.
    {
        var r = try createRaw(&h, "relative/path", SHELL, &.{400});
        defer r.deinit();
    }

    // Empty cwd falls back to the SERVER's cwd rather than 400ing.
    {
        var r = try createRaw(&h, "", SHELL, &.{201});
        defer r.deinit();
        var doc = try r.json();
        defer doc.deinit();
        const id = doc.str("id") orelse {
            std.debug.print("empty-cwd create returned no id: {s}\n", .{r.body});
            return error.TestUnexpectedResult;
        };
        if (id.len == 0) {
            std.debug.print("expected a session id from the empty-cwd create\n", .{});
            return error.TestUnexpectedResult;
        }
        const sid = try gpa.dupe(u8, id);
        defer gpa.free(sid);
        defer deleteSession(&h, sid);
    }

    // A cwd that does not exist is 404, not 201. Derived from the
    // tempdir so it is absolute on every platform.
    {
        const missing = try harness.harnessPath(gpa, h.temp_dir, &.{"pabrik-terminal-never-exists-9d2c41"});
        defer gpa.free(missing);
        var r = try createRaw(&h, missing, SHELL, &.{404});
        defer r.deinit();
    }

    // No body at all is a validation error, and the error body carries
    // an `error` key.
    {
        var r = try h.http(io, .POST, "/api/terminal/sessions", .{ .expect = &.{400} });
        defer r.deinit();
        var doc = try r.json();
        defer doc.deinit();
        if (doc.get("error") == null) {
            std.debug.print("bodiless create body has no `error`: {s}\n", .{r.body});
            return error.TestUnexpectedResult;
        }
    }
}

// All per-session endpoints 404 an unknown id (no traversal: the id is
// an opaque registry key, never a path).
test "unknown_session_is_404" {
    try harness.requirePabrikBin(io, gpa);
    var h = try Harness.boot(io, gpa, .{});
    defer h.deinit(io) catch |err| {
        std.debug.print("teardown: {s}\n", .{@errorName(err)});
    };

    const ghost = "term-does-not-exist";
    {
        var r = try outputRaw(&h, ghost, 0, &.{404});
        defer r.deinit();
    }
    {
        var r = try inputRaw(&h, ghost, "echo hi\n", &.{404});
        defer r.deinit();
    }
    {
        const path = try std.fmt.allocPrint(gpa, "/api/terminal/sessions/{s}/resize", .{ghost});
        defer gpa.free(path);
        const body =
            \\{"cols":80,"rows":24}
        ;
        var r = try h.http(io, .POST, path, .{ .json_body = body, .expect = &.{404} });
        defer r.deinit();
    }
    {
        const path = try std.fmt.allocPrint(gpa, "/api/terminal/sessions/{s}", .{ghost});
        defer gpa.free(path);
        var r = try h.http(io, .DELETE, path, .{ .expect = &.{404} });
        defer r.deinit();
    }
}

// A shell that exits cleanly reports exited + code 0, and further input is
// 410 (not 500).
test "input_after_exit_is_410" {
    try harness.requirePabrikBin(io, gpa);
    var h = try Harness.boot(io, gpa, .{});
    defer h.deinit(io) catch |err| {
        std.debug.print("teardown: {s}\n", .{@errorName(err)});
    };

    const cwd = try harness.harnessPath(gpa, h.temp_dir, &.{});
    defer gpa.free(cwd);
    const sid = try create(&h, cwd);
    defer gpa.free(sid);
    defer deleteSession(&h, sid);

    {
        var r = try inputRaw(&h, sid, "exit" ++ LINE_END, &.{200});
        defer r.deinit();
    }

    // Poll until `exited` flips, mirroring Python's `while ... deadline`.
    const deadline = nowMs() + 15_000;
    var cursor: i64 = 0;
    var exited = false;
    var exit_code: ?i64 = null;
    while (nowMs() < deadline) {
        var page = try outputPage(&h, sid, cursor);
        defer page.deinit();
        if (page.exited) {
            exited = true;
            exit_code = page.exit_code;
            break;
        }
        cursor = page.cursor;
        std.Io.sleep(io, .fromMilliseconds(300), .awake) catch {};
    }
    if (!exited) {
        std.debug.print("session {s} never exited within 15s\n", .{sid});
        return error.TestUnexpectedResult;
    }
    if (exit_code == null or exit_code.? != 0) {
        std.debug.print("expected exit code 0, got {?}\n", .{exit_code});
        return error.TestUnexpectedResult;
    }

    // Further input is 410 with an `error` key.
    {
        var r = try inputRaw(&h, sid, "echo hi\n", &.{410});
        defer r.deinit();
        var doc = try r.json();
        defer doc.deinit();
        if (doc.get("error") == null) {
            std.debug.print("410 body has no `error`: {s}\n", .{r.body});
            return error.TestUnexpectedResult;
        }
    }
}

// Two sessions on the same server never see each other's bytes: a marker
// sent to A appears only in A's output and vice versa.
test "two_sessions_are_isolated" {
    try harness.requirePabrikBin(io, gpa);
    var h = try Harness.boot(io, gpa, .{});
    defer h.deinit(io) catch |err| {
        std.debug.print("teardown: {s}\n", .{@errorName(err)});
    };

    const cwd = try harness.harnessPath(gpa, h.temp_dir, &.{});
    defer gpa.free(cwd);

    const id_a = try create(&h, cwd);
    defer gpa.free(id_a);
    const id_b = try create(&h, cwd);
    defer gpa.free(id_b);
    defer deleteSession(&h, id_a);
    defer deleteSession(&h, id_b);

    if (std.mem.eql(u8, id_a, id_b)) {
        std.debug.print("session ids must differ, both were \"{s}\"\n", .{id_a});
        return error.TestUnexpectedResult;
    }

    const marker_a = "ISOLATION-A-6c1e";
    const marker_b = "ISOLATION-B-9f4d";
    {
        const line = try echoLine(marker_a);
        defer gpa.free(line);
        var r = try inputRaw(&h, id_a, line, &.{200});
        defer r.deinit();
    }
    {
        const line = try echoLine(marker_b);
        defer gpa.free(line);
        var r = try inputRaw(&h, id_b, line, &.{200});
        defer r.deinit();
    }

    var out_a = try pollFor(&h, id_a, marker_a, 20_000);
    defer out_a.deinit();
    var out_b = try pollFor(&h, id_b, marker_b, 20_000);
    defer out_b.deinit();

    if (std.mem.indexOf(u8, out_a.data, marker_b) != null) {
        std.debug.print("B leaked into A: \"{s}\"\n", .{out_a.data});
        return error.TestUnexpectedResult;
    }
    if (std.mem.indexOf(u8, out_b.data, marker_a) != null) {
        std.debug.print("A leaked into B: \"{s}\"\n", .{out_b.data});
        return error.TestUnexpectedResult;
    }

    // Full-buffer check: replay from 0 still shows no cross-talk.
    {
        var full_a = try outputPage(&h, id_a, 0);
        defer full_a.deinit();
        if (std.mem.indexOf(u8, full_a.data, marker_b) != null) {
            std.debug.print("B leaked into A's full buffer: \"{s}\"\n", .{full_a.data});
            return error.TestUnexpectedResult;
        }
    }
    {
        var full_b = try outputPage(&h, id_b, 0);
        defer full_b.deinit();
        if (std.mem.indexOf(u8, full_b.data, marker_a) != null) {
            std.debug.print("A leaked into B's full buffer: \"{s}\"\n", .{full_b.data});
            return error.TestUnexpectedResult;
        }
    }
}

// Body-analysis barrier. An unreferenced helper is never type-checked, so
// a stdlib rename inside one stays invisible until a caller appears.
comptime {
    _ = nowMs;
    _ = echoLine;
    _ = OutputPage.deinit;
    _ = createRaw;
    _ = create;
    _ = inputRaw;
    _ = outputRaw;
    _ = outputPage;
    _ = pollFor;
    _ = settleCursor;
    _ = deleteSession;
}
