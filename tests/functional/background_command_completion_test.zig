// Functional e2e for background-command completion (Tasks 1-3). Zig port of
// `tests/functional/background_command_completion_test.py` (same test names,
// same order).

const std = @import("std");
const testing = std.testing;
const harness = @import("harness.zig");
const Harness = harness.Harness;

const Io = std.Io;

const gpa = testing.allocator;
const io = testing.io;

/// A PID that can never be alive on Linux (max pid is 4194304 by
/// default; kill(999999999, 0) -> ESRCH). Fits in i32 so the cron's
/// parseInt(i32) accepts the row instead of skipping it as corrupt.
const DEAD_PID: i64 = 999_999_999;

/// Poll cadence for the cron tick (fires every minute on the minute,
/// so worst-case wait is ~60s + processing). 5s interval x 18 polls =
/// 90s budget keeps the suite under ~2min even on a slow CI runner.
const POLL_INTERVAL_MS: i64 = 5_000;
const POLL_ATTEMPTS: usize = 18;
/// POLL_INTERVAL_MS x POLL_ATTEMPTS, in seconds — the budget the failure
/// message quotes back to the reader.
const POLL_BUDGET_S: u32 = 90;

/// A unique marker planted in the fake background log; the completion
/// envelope must carry it verbatim.
const MARKER = "bg-completion-marker-7f3a9c";

/// Skip unless a `sqlite3` CLI is present and speaks `-json`. Exit code for a
/// finished child, or null if a signal stopped it.
fn exitCode(term: std.process.Child.Term) ?u8 {
    return switch (term) {
        .exited => |c| c,
        else => null,
    };
}

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
    const code = exitCode(res.term);
    if (code == null or code.? != 0 or std.mem.indexOf(u8, res.stdout, "\"probe\"") == null) {
        std.debug.print(
            "sqlite3 CLI lacks -json support (rc={?}, out={s}); skipping the bg-row seed\n",
            .{ code, res.stdout },
        );
        return error.SkipZigTest;
    }
}

/// `sqlite3 -json` prints ZERO BYTES for an empty result set — not `[]`.
fn parseSqliteJson(allocator: std.mem.Allocator, out: []const u8) !std.json.Parsed(std.json.Value) {
    if (std.mem.trim(u8, out, " \t\r\n").len == 0) {
        return std.json.parseFromSlice(std.json.Value, allocator, "[]", .{});
    }
    return std.json.parseFromSlice(std.json.Value, allocator, out, .{});
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

/// Agent DB inside the isolated tmpdir HOME (Linux layout). Python `_db_path`.
fn dbPath(temp_dir: []const u8) ![]u8 {
    return harness.harnessPath(gpa, temp_dir, &.{ ".config", "pabrik", "agent.db" });
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

/// PUT auto-creates the sessions row (ensureSessionExists); no LLM needed.
/// Python `_create_session`.
fn createSession(h: *Harness, session_id: []const u8) !void {
    const path = try std.fmt.allocPrint(gpa, "/api/llm/session/{s}", .{session_id});
    defer gpa.free(path);
    const body = try std.fmt.allocPrint(gpa, "{{\"name\":\"bg-completion-{s}\"}}", .{session_id});
    defer gpa.free(body);

    var r = try h.http(io, .PUT, path, .{ .json_body = body, .expect = &.{200} });
    defer r.deinit();
}

/// `GET .../queue_messages` → the parsed body, owned by the caller.
fn getQueue(h: *Harness, session_id: []const u8) !harness.Json {
    const path = try std.fmt.allocPrint(gpa, "/api/llm/session/{s}/queue_messages", .{session_id});
    defer gpa.free(path);

    var r = try h.http(io, .GET, path, .{ .expect = &.{200} });
    defer r.deinit();
    return r.json();
}

/// Insert a `session_background_process` row WHILE the binary runs. Schema
/// mirrors migration 014: `(session_id, pid, command, log_path, started_at,
/// status)` with composite PK `(session_id, pid)`.
fn insertBgRow(
    temp_dir: []const u8,
    session_id: []const u8,
    pid: i64,
    command: []const u8,
    log_path: []const u8,
) !void {
    const db = try dbPath(temp_dir);
    defer gpa.free(db);
    const sid = try sqlLit(session_id);
    defer gpa.free(sid);
    const pid_s = try std.fmt.allocPrint(gpa, "{d}", .{pid});
    defer gpa.free(pid_s);
    const cmd = try sqlLit(command);
    defer gpa.free(cmd);
    const lp = try sqlLit(log_path);
    defer gpa.free(lp);

    const sql = try std.fmt.allocPrint(
        gpa,
        "INSERT INTO session_background_process" ++
            " (session_id, pid, command, log_path, started_at, status)" ++
            " VALUES ({s}, {s}, {s}, {s}, {d}, 'running')",
        .{ sid, pid_s, cmd, lp, Io.Timestamp.now(io, .real).toSeconds() },
    );
    defer gpa.free(sql);

    const out = try sqliteRun(db, sql);
    gpa.free(out);
}

/// `SELECT COUNT(*) AS n ...` for one session. Python `_count_bg_rows`.
fn countBgRows(temp_dir: []const u8, session_id: []const u8) !u64 {
    const db = try dbPath(temp_dir);
    defer gpa.free(db);
    const sid = try sqlLit(session_id);
    defer gpa.free(sid);

    const sql = try std.fmt.allocPrint(
        gpa,
        "SELECT COUNT(*) AS n FROM session_background_process WHERE session_id = {s}",
        .{sid},
    );
    defer gpa.free(sql);

    const out = try sqliteRun(db, sql);
    defer gpa.free(out);

    var parsed = try parseSqliteJson(gpa, out);
    defer parsed.deinit();

    const arr = switch (parsed.value) {
        .array => |a| a,
        else => return error.TestUnexpectedResult,
    };
    if (arr.items.len != 1) return error.TestUnexpectedResult;
    const n = switch (arr.items[0]) {
        .object => |o| o,
        else => return error.TestUnexpectedResult,
    };
    return switch (n.get("n") orelse return error.TestUnexpectedResult) {
        .integer => |i| if (i < 0) 0 else @intCast(i),
        else => return error.TestUnexpectedResult,
    };
}

/// The first queue message containing `needle`, dupe'd for the caller. Python
/// looped `for entry in body.get("messages", []): msg = entry.get("message",
/// "")`.
fn findQueueMessage(doc: *const harness.Json, needle: []const u8) !?[]u8 {
    const arr = doc.array("messages") orelse return null;
    for (arr.items) |entry| {
        const o = switch (entry) {
            .object => |m| m,
            else => continue,
        };
        const msg = switch (o.get("message") orelse continue) {
            .string => |s| s,
            else => continue,
        };
        if (std.mem.indexOf(u8, msg, needle) != null) return try gpa.dupe(u8, msg);
    }
    return null;
}

// GET .../queue_messages on a session with no queued rows returns
// {messages: [], count: 0} — the baseline the polling test asserts
// against before the cron tick fires.
test "queue_messages_empty_for_fresh_bg_session" {
    try harness.requirePabrikBin(io, gpa);
    var h = try Harness.boot(io, gpa, .{});
    defer h.deinit(io) catch |err| {
        std.debug.print("teardown: {s}\n", .{@errorName(err)});
    };

    const session_id = "sess_bg_completion_empty_001";
    try createSession(&h, session_id);

    var body = try getQueue(&h, session_id);
    defer body.deinit();

    // Python: `body.get("messages") == []` — an ABSENT key must fail, so
    // `orelse` rather than a defaulted empty array.
    const messages = body.array("messages") orelse {
        std.debug.print("queue_messages body has no `messages` array\n", .{});
        return error.TestUnexpectedResult;
    };
    if (messages.items.len != 0) {
        std.debug.print("fresh session should have no queue messages, got {d}\n", .{messages.items.len});
        return error.TestUnexpectedResult;
    }

    // Python: `body.get("count") == 0`. `doc.int` returns null for a
    // non-integer, so a missing or string-typed `count` also fails here —
    // which is what `body.get("count") == 0` did.
    const count = body.int("count") orelse {
        std.debug.print("queue_messages body has no integer `count`\n", .{});
        return error.TestUnexpectedResult;
    };
    if (count != 0) {
        std.debug.print("fresh session should have count=0, got {d}\n", .{count});
        return error.TestUnexpectedResult;
    }
}

// A bg row with a dead PID is picked up by the per-minute cron: the Task 1
// envelope lands in queue_messages and the row is deleted. Polls (cron ticks
// on the minute; worst case ~60s wait).
test "dead_background_process_notifies_completion_queue" {
    try harness.requirePabrikBin(io, gpa);
    try requireSqlite3Cli();
    var h = try Harness.boot(io, gpa, .{});
    defer h.deinit(io) catch |err| {
        std.debug.print("teardown: {s}\n", .{@errorName(err)});
    };

    const session_id = "sess_bg_completion_core_001";
    try createSession(&h, session_id);
    {
        var body = try getQueue(&h, session_id);
        defer body.deinit();
        const count = body.int("count") orelse {
            std.debug.print("queue_messages body has no integer `count`\n", .{});
            return error.TestUnexpectedResult;
        };
        if (count != 0) {
            std.debug.print("fresh session should have count=0, got {d}\n", .{count});
            return error.TestUnexpectedResult;
        }
    }

    // Log file lives inside the isolated tmpdir so the binary (same
    // host, same fs) can read it; content is a unique marker the
    // envelope must contain verbatim.
    const log_path = try harness.harnessPath(gpa, h.temp_dir, &.{"bg-completion-test.log"});
    defer gpa.free(log_path);
    {
        var f = try std.Io.Dir.cwd().createFile(io, log_path, .{});
        defer f.close(io);
        try f.writeStreamingAll(io, "line one\n" ++ MARKER ++ "\nline three\n");
    }
    const command = "sleep 10";

    try insertBgRow(h.temp_dir, session_id, DEAD_PID, command, log_path);
    if (try countBgRows(h.temp_dir, session_id) != 1) {
        std.debug.print("the seeded bg row did not land\n", .{});
        return error.TestUnexpectedResult;
    }

    // Poll for the envelope.
    var envelope: ?[]u8 = null;
    {
        var attempt: usize = 0;
        while (attempt < POLL_ATTEMPTS) : (attempt += 1) {
            Io.sleep(io, .fromMilliseconds(POLL_INTERVAL_MS), .awake) catch {};
            var body = try getQueue(&h, session_id);
            defer body.deinit();
            if (try findQueueMessage(&body, MARKER)) |e| {
                envelope = e;
                break;
            }
        }
    }
    defer if (envelope) |e| gpa.free(e);

    const env = envelope orelse {
        const left = try countBgRows(h.temp_dir, session_id);
        std.debug.print(
            "cron did not notify completion within ~{d}s; bg rows left: {d}\n",
            .{ POLL_BUDGET_S, left },
        );
        return error.TestUnexpectedResult;
    };

    // JSON envelope shape (background_process.zig: buildCompletionMessage):
    // {pid,command,stdout,truncated,...} object. Role stays user — no
    // tool_call_id, no prose header, no quote fence.
    if (std.mem.indexOf(u8, env, "\"pid\":") == null) {
        std.debug.print("envelope missing pid key: {s}\n", .{env});
        return error.TestUnexpectedResult;
    }
    if (std.mem.indexOf(u8, env, "\"pid\":999999999") == null) {
        std.debug.print("envelope pid mismatch: {s}\n", .{env});
        return error.TestUnexpectedResult;
    }
    if (std.mem.indexOf(u8, env, "\"command\":\"sleep 10\"") == null) {
        std.debug.print("envelope command mismatch: {s}\n", .{env});
        return error.TestUnexpectedResult;
    }
    if (std.mem.indexOf(u8, env, MARKER) == null) {
        std.debug.print("envelope missing log content: {s}\n", .{env});
        return error.TestUnexpectedResult;
    }
    if (std.mem.indexOf(u8, env, "\"truncated\":false") == null) {
        std.debug.print("envelope truncated flag mismatch: {s}\n", .{env});
        return error.TestUnexpectedResult;
    }
    if (std.mem.indexOf(u8, env, "\"\"\"\"\"") != null) {
        std.debug.print("envelope still uses quote fence: {s}\n", .{env});
        return error.TestUnexpectedResult;
    }

    // Notify-then-delete: the row must be gone once notified (allow one
    // extra poll for the DELETE to land if the test raced the tick
    // between the queue INSERT and the batch DELETE).
    var waits: usize = 0;
    while (waits < 3) : (waits += 1) {
        if (try countBgRows(h.temp_dir, session_id) == 0) break;
        Io.sleep(io, .fromMilliseconds(2000), .awake) catch {};
    }
    if (try countBgRows(h.temp_dir, session_id) != 0) {
        std.debug.print("notified bg row should be deleted from session_background_process\n", .{});
        return error.TestUnexpectedResult;
    }
}
