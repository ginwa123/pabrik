// Functional e2e for session background-process HTTP endpoints. Zig port of
// `tests/functional/background_processes_api_test.py` (same test names, same
// order).

const std = @import("std");
const builtin = @import("builtin");
const testing = std.testing;
const harness = @import("harness.zig");
const Harness = harness.Harness;
const Io = std.Io;
const gpa = testing.allocator;
const io = testing.io;

// A PID that can never be alive on Linux (max pid is 4194304 by
// default; kill(999999999, 0) -> ESRCH). Fits in i32 so both the cron's
// parseInt(i32) and the endpoint's parseInt(u32) accept the row.
const DEAD_PID: i64 = 999_999_999;
const DEAD_PID_2: i64 = 999_999_998;

/// The pid of THIS test process — Python's `os.getpid()`, i.e. the
/// always-alive probe row.
fn selfPid() u32 {
    if (builtin.os.tag == .windows) return @intCast(std.os.windows.GetCurrentProcessId());
    return @intCast(std.os.linux.getpid());
}

// ============================================================================
// Helpers
// ============================================================================

/// Agent DB inside the isolated tmpdir HOME (Linux layout).
/// Python `_db_path`.
fn dbPath(temp_dir: []const u8) ![]u8 {
    return harness.harnessPath(gpa, temp_dir, &.{ ".config", "pabrik", "agent.db" });
}

/// Skip unless a `sqlite3` CLI is present and speaks `-json`.
fn requireSqlite3Cli() !void {
    const res = std.process.run(gpa, io, .{
        .argv = &.{ "sqlite3", "-json", ":memory:", "SELECT 1 AS probe;" },
    }) catch |err| {
        std.debug.print("sqlite3 CLI unavailable ({s}); skipping the bg-row seed\n", .{@errorName(err)});
        return error.SkipZigTest;
    };
    defer {
        gpa.free(res.stdout);
        gpa.free(res.stderr);
    }
    const code: ?u8 = switch (res.term) {
        .exited => |c| c,
        else => null,
    };
    if (code == null or code.? != 0 or std.mem.indexOf(u8, res.stdout, "\"probe\"") == null) {
        std.debug.print(
            "sqlite3 CLI lacks -json support (rc={?}, out={s}); skipping the bg-row seed\n",
            .{ code, res.stdout },
        );
        return error.SkipZigTest;
    }
}

/// Exit code for a finished child, or null if a signal stopped it.
fn exitCode(term: std.process.Child.Term) ?u8 {
    return switch (term) {
        .exited => |c| c,
        else => null,
    };
}

/// Single-quote `s` as an SQL literal, doubling embedded quotes. Owned.
fn sqlLit(s: []const u8) ![]u8 {
    var out: std.Io.Writer.Allocating = .init(gpa);
    errdefer out.deinit();
    out.writer.writeByte('\'') catch return error.OutOfMemory;
    for (s) |c| {
        if (c == '\'') out.writer.writeByte('\'') catch return error.OutOfMemory;
        out.writer.writeByte(c) catch return error.OutOfMemory;
    }
    out.writer.writeByte('\'') catch return error.OutOfMemory;
    return out.toOwnedSlice();
}

/// Run one statement against `db_path`; caller frees the returned stdout.
fn sqliteRun(db_path: []const u8, sql: []const u8) ![]u8 {
    const res = std.process.run(gpa, io, .{
        .argv = &.{ "sqlite3", "-cmd", ".timeout 5000", "-json", db_path, sql },
    }) catch |err| {
        std.debug.print("sqlite3 did not spawn: {s}\n", .{@errorName(err)});
        return error.SkipZigTest;
    };
    defer gpa.free(res.stderr);

    const code = exitCode(res.term) orelse {
        gpa.free(res.stdout);
        std.debug.print("sqlite3 was killed by a signal: {any}\n", .{res.term});
        return error.TestUnexpectedResult;
    };
    if (code != 0) {
        defer gpa.free(res.stdout);
        std.debug.print("sqlite3 exited {d}: {s}\nsql: {s}\n", .{ code, res.stderr, sql });
        return error.TestUnexpectedResult;
    }
    return res.stdout;
}

/// Write `contents` to `path`, creating (or truncating) it.
fn writeFile(path: []const u8, contents: []const u8) !void {
    var f = try std.Io.Dir.cwd().createFile(io, path, .{});
    defer f.close(io);
    try f.writeStreamingAll(io, contents);
}

/// `PUT /api/llm/session/:id` auto-creates the sessions row
/// (`ensureSessionExists`); no LLM profile needed. Python
/// `_create_session`.
fn createSession(h: *Harness, session_id: []const u8) !void {
    const path = try std.fmt.allocPrint(gpa, "/api/llm/session/{s}", .{session_id});
    defer gpa.free(path);
    const body = try std.fmt.allocPrint(gpa, "{{\"name\":\"bg-api-{s}\"}}", .{session_id});
    defer gpa.free(body);

    var r = try h.http(io, .PUT, path, .{ .json_body = body, .expect = &.{200} });
    defer r.deinit();
}

/// Insert a `session_background_process` row WHILE the binary runs. Schema
/// mirrors migration 014: `(session_id, pid, command, log_path, started_at,
/// status)` with composite PK `(session_id, pid)`.
fn insertBgRow(
    h: *Harness,
    session_id: []const u8,
    pid: i64,
    command: []const u8,
    log_path: []const u8,
    status: []const u8,
) !void {
    const db = try dbPath(h.temp_dir);
    defer gpa.free(db);
    const sid = try sqlLit(session_id);
    defer gpa.free(sid);
    const cmd = try sqlLit(command);
    defer gpa.free(cmd);
    const lp = try sqlLit(log_path);
    defer gpa.free(lp);
    const st = try sqlLit(status);
    defer gpa.free(st);

    const sql = try std.fmt.allocPrint(
        gpa,
        "INSERT INTO session_background_process" ++
            " (session_id, pid, command, log_path, started_at, status)" ++
            " VALUES ({s}, {d}, {s}, {s}, {d}, {s})",
        .{ sid, pid, cmd, lp, Io.Timestamp.now(io, .real).toSeconds(), st },
    );
    defer gpa.free(sql);

    const out = try sqliteRun(db, sql);
    gpa.free(out);
}

/// `GET .../background_processes` → the whole body. Owned (a
/// `harness.Json` aliases the response body, so it may not be returned
/// from a helper).
fn getListBody(h: *Harness, session_id: []const u8) ![]u8 {
    const path = try std.fmt.allocPrint(gpa, "/api/llm/session/{s}/background_processes", .{session_id});
    defer gpa.free(path);

    var r = try h.http(io, .GET, path, .{ .expect = &.{200} });
    defer r.deinit();
    return gpa.dupe(u8, r.body);
}

/// `GET .../background_processes/:pid/log[?max_bytes=N]` → the whole body.
/// Owned. `max_bytes` goes through `.params`, NOT a hand-built query string:
/// the harness percent-encodes both the name and the value.
fn getLogBody(
    h: *Harness,
    session_id: []const u8,
    pid: i64,
    max_bytes: ?[]const u8,
    expect: []const u16,
) ![]u8 {
    const path = try std.fmt.allocPrint(
        gpa,
        "/api/llm/session/{s}/background_processes/{d}/log",
        .{ session_id, pid },
    );
    defer gpa.free(path);

    const params = [_]Harness.Param{.{
        .name = "max_bytes",
        .value = max_bytes orelse "",
    }};

    var r = try h.http(io, .GET, path, .{
        .params = if (max_bytes != null) params[0..] else &.{},
        .expect = expect,
    });
    defer r.deinit();
    return gpa.dupe(u8, r.body);
}

/// Parse owned bytes into a `harness.Json`.
fn parseJson(bytes: []const u8) !harness.Json {
    return .{ .parsed = try std.json.parseFromSlice(std.json.Value, gpa, bytes, .{}) };
}

/// Python's `isinstance(v, bool)` — the wire must send a real JSON bool,
/// not `0`/`1`/a string.
fn expectBool(obj: std.json.ObjectMap, key: []const u8, want: bool, ctx: []const u8) !void {
    const v = obj.get(key) orelse {
        std.debug.print("{s}: `{s}` is absent\n", .{ ctx, key });
        return error.TestUnexpectedResult;
    };
    const got = switch (v) {
        .bool => |b| b,
        else => {
            std.debug.print("{s}: `{s}` is not a bool: {any}\n", .{ ctx, key, v });
            return error.TestUnexpectedResult;
        },
    };
    if (got != want) {
        std.debug.print("{s}: `{s}` = {any}, expected {any}\n", .{ ctx, key, got, want });
        return error.TestUnexpectedResult;
    }
}

/// Python's `isinstance(v, int)` — a wire NUMBER, never a quoted string.
fn expectInt(obj: std.json.ObjectMap, key: []const u8, ctx: []const u8) !i64 {
    const v = obj.get(key) orelse {
        std.debug.print("{s}: `{s}` is absent\n", .{ ctx, key });
        return error.TestUnexpectedResult;
    };
    return switch (v) {
        .integer => |i| i,
        else => {
            std.debug.print("{s}: `{s}` is not an int: {any}\n", .{ ctx, key, v });
            return error.TestUnexpectedResult;
        },
    };
}

/// Python's `assert obj.get(key) == want` for a string field.
fn expectStr(obj: std.json.ObjectMap, key: []const u8, want: []const u8, ctx: []const u8) !void {
    const v = obj.get(key) orelse {
        std.debug.print("{s}: `{s}` is absent\n", .{ ctx, key });
        return error.TestUnexpectedResult;
    };
    const got = switch (v) {
        .string => |x| x,
        else => {
            std.debug.print("{s}: `{s}` is not a string: {any}\n", .{ ctx, key, v });
            return error.TestUnexpectedResult;
        },
    };
    if (!std.mem.eql(u8, got, want)) {
        std.debug.print("{s}: `{s}` = \"{s}\", expected \"{s}\"\n", .{ ctx, key, got, want });
        return error.TestUnexpectedResult;
    }
}

/// The document's ROOT object, borrowed from `doc`.
fn requireRootObject(doc: *const harness.Json, raw: []const u8) !std.json.ObjectMap {
    return switch (doc.value().*) {
        .object => |o| o,
        else => {
            std.debug.print("response root is not an object: {s}\n", .{raw});
            return error.TestUnexpectedResult;
        },
    };
}

/// Assert every key in `keys` is present on `obj`.
fn expectKeysPresent(obj: std.json.ObjectMap, keys: []const []const u8, ctx: []const u8) !void {
    for (keys) |k| {
        if (obj.get(k) == null) {
            std.debug.print("{s}: process entry missing `{s}`\n", .{ ctx, k });
            return error.TestUnexpectedResult;
        }
    }
}

/// The `processes` array from a list body.
fn processesOf(doc: *const harness.Json, raw: []const u8) !std.json.Array {
    return doc.array("processes") orelse {
        std.debug.print("background_processes body has no `processes` array: {s}\n", .{raw});
        return error.TestUnexpectedResult;
    };
}

/// Python's `{p["pid"]: p for p in processes}[pid]`.
fn findProcess(arr: std.json.Array, pid: i64, raw: []const u8) !std.json.ObjectMap {
    for (arr.items) |entry| {
        const o = switch (entry) {
            .object => |x| x,
            else => {
                std.debug.print("process entry is not an object: {s}\n", .{raw});
                return error.TestUnexpectedResult;
            },
        };
        const v = switch (o.get("pid") orelse {
            std.debug.print("process entry has no `pid`: {s}\n", .{raw});
            return error.TestUnexpectedResult;
        }) {
            .integer => |i| i,
            else => {
                std.debug.print("process entry `pid` is not an int: {s}\n", .{raw});
                return error.TestUnexpectedResult;
            },
        };
        if (v == pid) return o;
    }
    std.debug.print("no process entry with pid {d}: {s}\n", .{ pid, raw });
    return error.TestUnexpectedResult;
}

// ============================================================================
// Test 1: empty session -> 200 { processes: [], count: 0 }
// ============================================================================

// A session with no bg rows returns an empty list (200, not 404).
test "list_empty_for_fresh_session" {
    try harness.requirePabrikBin(io, gpa);
    var h = try Harness.boot(io, gpa, .{});
    defer h.deinit(io) catch |err| {
        std.debug.print("teardown: {s}", .{@errorName(err)});
    };

    const session_id = "sess_bg_api_empty_001";
    try createSession(&h, session_id);

    const raw = try getListBody(&h, session_id);
    defer gpa.free(raw);
    var doc = try parseJson(raw);
    defer doc.deinit();

    // Python `body.get("processes") == []` — an ABSENT key must fail, so
    // `orelse` rather than a defaulted empty array.
    const processes = try processesOf(&doc, raw);
    if (processes.items.len != 0) {
        std.debug.print("expected [], got {d} processes: {s}\n", .{ processes.items.len, raw });
        return error.TestUnexpectedResult;
    }

    const count = doc.int("count") orelse {
        std.debug.print("background_processes body has no integer `count`: {s}\n", .{raw});
        return error.TestUnexpectedResult;
    };
    if (count != 0) {
        std.debug.print("expected count=0, got {d}: {s}\n", .{ count, raw });
        return error.TestUnexpectedResult;
    }
}

// ============================================================================
// Test 2: list shape + live running flags
// ============================================================================

// Seeded rows come back with the exact wire shape; `running` is
// computed live (dead PID -> false, own PID -> true) regardless of the
// status column.
test "list_shape_and_running_flags" {
    try harness.requirePabrikBin(io, gpa);
    try requireSqlite3Cli();
    var h = try Harness.boot(io, gpa, .{});
    defer h.deinit(io) catch |err| {
        std.debug.print("teardown: {s}", .{@errorName(err)});
    };

    const session_id = "sess_bg_api_list_001";
    try createSession(&h, session_id);

    const live_pid = selfPid();
    const live_log = try harness.harnessPath(gpa, h.temp_dir, &.{"bg-api-live.log"});
    defer gpa.free(live_log);
    try writeFile(live_log, "live output\n");
    const dead_log = try harness.harnessPath(gpa, h.temp_dir, &.{"bg-api-dead.log"});
    defer gpa.free(dead_log);
    try writeFile(dead_log, "dead output\n");

    // Dead row keeps status='running' (stale-column case); live row
    // keeps status='completed' (inverse stale case) — the endpoint must
    // report OS truth either way.
    try insertBgRow(&h, session_id, DEAD_PID, "sleep 10", dead_log, "running");
    try insertBgRow(&h, session_id, live_pid, "pytest-probe", live_log, "completed");

    const raw = try getListBody(&h, session_id);
    defer gpa.free(raw);
    var doc = try parseJson(raw);
    defer doc.deinit();

    const count = doc.int("count") orelse {
        std.debug.print("background_processes body has no integer `count`: {s}\n", .{raw});
        return error.TestUnexpectedResult;
    };
    if (count != 2) {
        std.debug.print("expected count=2, got {d}: {s}\n", .{ count, raw });
        return error.TestUnexpectedResult;
    }

    const processes = try processesOf(&doc, raw);
    if (processes.items.len != 2) {
        std.debug.print("expected 2 process entries, got {d}: {s}\n", .{ processes.items.len, raw });
        return error.TestUnexpectedResult;
    }

    // `set(procs) == {DEAD_PID, live_pid}` — assert the pids by looking
    // each one up and then asserting the count is exactly 2, which is
    // the set-equality without building a map.
    const dead = try findProcess(processes, DEAD_PID, raw);
    const live = try findProcess(processes, live_pid, raw);

    for ([_]std.json.ObjectMap{ dead, live }) |p| {
        try expectKeysPresent(p, &.{
            "pid", "command", "log_path", "started_at", "status", "running",
        }, "process entry");
        // Type assertions: `pid`/`started_at` are ints, `running` a bool.
        _ = try expectInt(p, "pid", "process entry");
        _ = try expectInt(p, "started_at", "process entry");
        const r = p.get("running") orelse return error.TestUnexpectedResult;
        switch (r) {
            .bool => {},
            else => {
                std.debug.print("process entry `running` is not a bool: {s}\n", .{raw});
                return error.TestUnexpectedResult;
            },
        }
    }

    try expectStr(dead, "command", "sleep 10", "dead process");
    try expectStr(dead, "log_path", dead_log, "dead process");
    try expectBool(dead, "running", false, "dead process");

    try expectStr(live, "command", "pytest-probe", "live process");
    try expectBool(live, "running", true, "live process");
    // Status column is echoed verbatim (not overwritten by live-ness).
    try expectStr(live, "status", "completed", "live process");
}

// Rows for another session never leak into this session's list.
test "list_scoped_to_session" {
    try harness.requirePabrikBin(io, gpa);
    try requireSqlite3Cli();
    var h = try Harness.boot(io, gpa, .{});
    defer h.deinit(io) catch |err| {
        std.debug.print("teardown: {s}", .{@errorName(err)});
    };

    const session_a = "sess_bg_api_scope_a_001";
    const session_b = "sess_bg_api_scope_b_001";
    try createSession(&h, session_a);
    try createSession(&h, session_b);

    try insertBgRow(&h, session_a, DEAD_PID, "cmd-a", "/tmp/bg-scope-a.log", "running");
    try insertBgRow(&h, session_b, DEAD_PID_2, "cmd-b", "/tmp/bg-scope-b.log", "running");

    const raw = try getListBody(&h, session_a);
    defer gpa.free(raw);
    var doc = try parseJson(raw);
    defer doc.deinit();

    const count = doc.int("count") orelse {
        std.debug.print("background_processes body has no integer `count`: {s}\n", .{raw});
        return error.TestUnexpectedResult;
    };
    if (count != 1) {
        std.debug.print("expected count=1, got {d}: {s}\n", .{ count, raw });
        return error.TestUnexpectedResult;
    }
    const processes = try processesOf(&doc, raw);
    if (processes.items.len != 1) {
        std.debug.print("expected 1 process entry, got {d}: {s}\n", .{ processes.items.len, raw });
        return error.TestUnexpectedResult;
    }
    const only = switch (processes.items[0]) {
        .object => |o| o,
        else => {
            std.debug.print("process entry is not an object: {s}\n", .{raw});
            return error.TestUnexpectedResult;
        },
    };
    try expectStr(only, "command", "cmd-a", "scoped process");
}

// ============================================================================
// Test 3: log tail
// ============================================================================

// A small log returns its full content with truncated=false.
test "log_full_content_under_cap" {
    try harness.requirePabrikBin(io, gpa);
    try requireSqlite3Cli();
    var h = try Harness.boot(io, gpa, .{});
    defer h.deinit(io) catch |err| {
        std.debug.print("teardown: {s}", .{@errorName(err)});
    };

    const session_id = "sess_bg_api_log_full_001";
    try createSession(&h, session_id);

    const content = "line one\nline two\ntail-marker-3e8f1a\n";
    const log_path = try harness.harnessPath(gpa, h.temp_dir, &.{"bg-api-full.log"});
    defer gpa.free(log_path);
    try writeFile(log_path, content);
    try insertBgRow(&h, session_id, DEAD_PID, "sleep 10", log_path, "running");

    const raw = try getLogBody(&h, session_id, DEAD_PID, null, &.{200});
    defer gpa.free(raw);
    var doc = try parseJson(raw);
    defer doc.deinit();
    // The log body IS a flat object at the ROOT (`{pid, log_path,
    // total_bytes, truncated, content}`), so the assertions read it
    // directly rather than through a key.
    const log_obj = try requireRootObject(&doc, raw);

    if ((doc.int("pid") orelse return error.TestUnexpectedResult) != DEAD_PID) {
        std.debug.print("pid mismatch: {s}\n", .{raw});
        return error.TestUnexpectedResult;
    }
    try expectStr(log_obj, "log_path", log_path, "log body");

    // `total_bytes == len(content.encode())` — byte length, not rune
    // count. The fixture is ASCII so the two agree, but `.len` is the
    // one the server means.
    const total = doc.int("total_bytes") orelse {
        std.debug.print("total_bytes mismatch: {s}\n", .{raw});
        return error.TestUnexpectedResult;
    };
    if (total != @as(i64, @intCast(content.len))) {
        std.debug.print("total_bytes = {d}, expected {d}: {s}\n", .{ total, content.len, raw });
        return error.TestUnexpectedResult;
    }

    try expectBool(log_obj, "truncated", false, "log body");
    try expectStr(log_obj, "content", content, "log body");
}

// A log bigger than max_bytes returns the LAST max_bytes bytes with
// truncated=true and the full size in total_bytes.
test "log_tail_when_over_cap" {
    try harness.requirePabrikBin(io, gpa);
    try requireSqlite3Cli();
    var h = try Harness.boot(io, gpa, .{});
    defer h.deinit(io) catch |err| {
        std.debug.print("teardown: {s}", .{@errorName(err)});
    };

    const session_id = "sess_bg_api_log_tail_001";
    try createSession(&h, session_id);

    const head_marker = "HEAD-marker-aaaa";
    const tail_marker = "TAIL-marker-zzzz";

    const filler = try gpa.alloc(u8, 500);
    defer gpa.free(filler);
    @memset(filler, 'A');

    const payload = try std.fmt.allocPrint(gpa, "{s}{s}{s}", .{ head_marker, filler, tail_marker });
    defer gpa.free(payload);

    const log_path = try harness.harnessPath(gpa, h.temp_dir, &.{"bg-api-tail.log"});
    defer gpa.free(log_path);
    try writeFile(log_path, payload);
    try insertBgRow(&h, session_id, DEAD_PID, "make", log_path, "running");

    const raw = try getLogBody(&h, session_id, DEAD_PID, "100", &.{200});
    defer gpa.free(raw);
    var doc = try parseJson(raw);
    defer doc.deinit();
    // The log body IS a flat object at the ROOT (`{pid, log_path,
    // total_bytes, truncated, content}`), so the assertions read it
    // directly rather than through a key.
    const log_obj = try requireRootObject(&doc, raw);

    const total = doc.int("total_bytes") orelse {
        std.debug.print("total_bytes mismatch: {s}\n", .{raw});
        return error.TestUnexpectedResult;
    };
    if (total != @as(i64, @intCast(payload.len))) {
        std.debug.print("total_bytes = {d}, expected {d}: {s}\n", .{ total, payload.len, raw });
        return error.TestUnexpectedResult;
    }
    try expectBool(log_obj, "truncated", true, "log body");

    const content = doc.str("content") orelse "";
    if (content.len != 100) {
        std.debug.print("expected 100 tail bytes, got {d}: {s}\n", .{ content.len, content });
        return error.TestUnexpectedResult;
    }
    if (!std.mem.endsWith(u8, content, tail_marker)) {
        std.debug.print("tail must end with marker: {s}\n", .{content});
        return error.TestUnexpectedResult;
    }
    if (std.mem.indexOf(u8, content, head_marker) != null) {
        std.debug.print("head must be cut off: {s}\n", .{content});
        return error.TestUnexpectedResult;
    }
}

// A row whose log file is gone returns 200 with the
// "(log file not found)" marker and total_bytes 0 (queue-marker
// convention — not a 404).
test "log_missing_file_returns_not_found_marker" {
    try harness.requirePabrikBin(io, gpa);
    try requireSqlite3Cli();
    var h = try Harness.boot(io, gpa, .{});
    defer h.deinit(io) catch |err| {
        std.debug.print("teardown: {s}", .{@errorName(err)});
    };

    const session_id = "sess_bg_api_log_missing_001";
    try createSession(&h, session_id);

    // The path is under the harness tempdir but is NEVER created, so
    // there is nothing to clean up beyond the tempdir itself.
    const missing = try harness.harnessPath(gpa, h.temp_dir, &.{"pabrik-bg-api-never-exists-4244.log"});
    defer gpa.free(missing);
    try insertBgRow(&h, session_id, DEAD_PID, "sleep 5", missing, "running");

    const raw = try getLogBody(&h, session_id, DEAD_PID, null, &.{200});
    defer gpa.free(raw);
    var doc = try parseJson(raw);
    defer doc.deinit();
    // The log body IS a flat object at the ROOT (`{pid, log_path,
    // total_bytes, truncated, content}`), so the assertions read it
    // directly rather than through a key.
    const log_obj = try requireRootObject(&doc, raw);

    const total = doc.int("total_bytes") orelse {
        std.debug.print("expected total_bytes=0: {s}\n", .{raw});
        return error.TestUnexpectedResult;
    };
    if (total != 0) {
        std.debug.print("expected total_bytes=0, got {d}: {s}\n", .{ total, raw });
        return error.TestUnexpectedResult;
    }
    try expectBool(log_obj, "truncated", false, "missing-log body");
    try expectStr(log_obj, "content", "(log file not found)", "missing-log body");
}

// An unknown (session, pid) pair is a 404 — and the log_path is never
// client-controlled (no traversal possible: there is no path param at
// all).
test "log_unknown_pid_returns_404" {
    try harness.requirePabrikBin(io, gpa);
    var h = try Harness.boot(io, gpa, .{});
    defer h.deinit(io) catch |err| {
        std.debug.print("teardown: {s}", .{@errorName(err)});
    };

    const session_id = "sess_bg_api_log_404_001";
    try createSession(&h, session_id);

    const raw = try getLogBody(&h, session_id, 123_456_789, null, &.{404});
    defer gpa.free(raw);
    var doc = try parseJson(raw);
    defer doc.deinit();

    if (doc.get("error") == null) {
        std.debug.print("expected an error envelope: {s}\n", .{raw});
        return error.TestUnexpectedResult;
    }
}

comptime {
    // Body-analysis barrier — see `harness.zig`'s note: an unreferenced
    // function body is never type-checked, so a stdlib rename inside one
    // stays invisible until a caller appears.
    _ = selfPid;
    _ = dbPath;
    _ = requireSqlite3Cli;
    _ = exitCode;
    _ = sqlLit;
    _ = sqliteRun;
    _ = writeFile;
    _ = createSession;
    _ = insertBgRow;
    _ = getListBody;
    _ = getLogBody;
    _ = parseJson;
    _ = expectBool;
    _ = expectInt;
    _ = expectStr;
    _ = expectKeysPresent;
    _ = requireRootObject;
    _ = processesOf;
    _ = findProcess;
}
