// Functional wire test: the `worker` table is the single source of truth
// for "is this session running".
//
// A follow-up `POST /api/llm/session` for a session that already has a
// `worker` row must QUEUE the message (`session_queue_messages`) and must
// NOT start a second run: the worker row is left untouched (no heartbeat
// upsert) and no `llm_history` rows appear.
//
// Why this file exists: `workflow.zig`'s gate used to be
// `isWorkerRunning AND active_loops.contains(...)` — two sources of truth
// that disagreed after a crash (stale row, empty in-memory map), so a
// second message either queued behind a dead worker forever or, with only
// the row present, started a duplicate run. The gate is now the worker
// row alone; this test pins the wire-visible half of that contract.
//
// Method: seed a FRESH worker row directly (simulating a live loop —
// `last_activity_nano` 100s old, well inside the 600s stale threshold so
// the cron cannot reap it mid-test), POST the exact body the composer
// sends, then assert over the DB via the `sqlite3` CLI idiom
// `ask_user_test.zig` established (this package links no SQLite, so
// every assertion crosses the process boundary).
//
// The `last_activity_nano`-unchanged assertion is the sharp one: the old
// code path ran `touchCheckpointWorkers` (an upsert) before its first LLM
// call, so a duplicate run would stamp the row within milliseconds. An
// untouched row proves no run started.

const std = @import("std");
const testing = std.testing;
const harness = @import("harness.zig");
const askuser = @import("ask_user_test.zig");
const Harness = harness.Harness;

const gpa = testing.allocator;
const io = testing.io;

/// `POST /api/llm/session` — the composer's send path for a follow-up
/// message on an existing session.
fn postMessage(h: *Harness, session_id: []const u8, message: []const u8) !void {
    const body = try std.json.Stringify.valueAlloc(gpa, .{
        .session_id = session_id,
        .queue_message = message,
        .cwd_session = h.temp_dir,
    }, .{});
    defer gpa.free(body);

    var r = try h.http(io, .POST, "/api/llm/session", .{ .json_body = body, .expect = &.{201} });
    defer r.deinit();
}

/// Poll `cond` until it returns true or the deadline passes. `emit_run_agent`
/// schedules the gate on a concurrent task, so the queue row lands just
/// after the HTTP response (same write-behind shape as `waitForWorker`).
fn pollFor(temp_dir: []const u8, sql: []const u8, timeout_ms: i64) !bool {
    const deadline = askuser.nowMs() + timeout_ms;
    while (askuser.nowMs() < deadline) {
        if ((try askuser.scalarCount(temp_dir, sql)) > 0) return true;
        askuser.sleepMs(50);
    }
    return false;
}

test "follow_up_message_to_running_session_is_queued_and_starts_no_run" {
    try harness.requirePabrikBin(io, gpa);
    const sqlite = try askuser.requireSqlite3Cli();
    defer gpa.free(sqlite);
    var h = try Harness.boot(io, gpa, .{});
    defer h.deinit(io) catch |err| {
        std.debug.print("teardown: {s}\n", .{@errorName(err)});
    };

    const session_id = try askuser.createSession(&h, "worker-gate-probe");
    defer gpa.free(session_id);
    const sid_lit = try askuser.sqlLit(session_id);
    defer gpa.free(sid_lit);

    // A live loop heartbeats `last_activity_nano` (unix seconds, despite
    // the name) every iteration: 100s old reads as running and is far
    // from the 600s stale threshold, so the cron cannot reap it mid-test.
    const now_s = std.Io.Timestamp.now(io, .real).toSeconds();
    const seed_sql = try std.fmt.allocPrint(
        gpa,
        "INSERT INTO worker (id, session_id, working_directory, last_activity_nano) VALUES ({s}, {s}, '/tmp', {d})",
        .{ sid_lit, sid_lit, now_s - 100 },
    );
    defer gpa.free(seed_sql);
    try askuser.execSql(h.temp_dir, seed_sql);

    // `CAST(... AS TEXT)`: `sqlite3 -json` renders INTEGER columns as JSON
    // numbers, and `firstCellString` only accepts strings.
    const nano_sql = try std.fmt.allocPrint(
        gpa,
        "SELECT CAST(last_activity_nano AS TEXT) AS nano FROM worker WHERE id = {s}",
        .{sid_lit},
    );
    defer gpa.free(nano_sql);
    const baseline_nano = (try askuser.firstCellString(h.temp_dir, nano_sql, "nano")) orelse {
        std.debug.print("seeded worker row must be readable\n", .{});
        return error.TestUnexpectedResult;
    };
    defer gpa.free(baseline_nano);

    // The exact follow-up the composer sends while a run is in flight.
    try postMessage(&h, session_id, "second message while running");

    // The message lands in the queue (write-behind: poll, don't assume).
    const queue_sql = try std.fmt.allocPrint(
        gpa,
        "SELECT COUNT(*) AS n FROM session_queue_messages WHERE session_id = {s}",
        .{sid_lit},
    );
    defer gpa.free(queue_sql);
    if (!try pollFor(h.temp_dir, queue_sql, 10_000)) {
        std.debug.print("follow-up message was never queued\n", .{});
        return error.TestUnexpectedResult;
    }
    try testing.expectEqual(@as(i64, 1), try askuser.scalarCount(h.temp_dir, queue_sql));

    // No run started: the worker row is byte-identical (a duplicate run
    // would have upserted `last_activity_nano` before its first LLM call)
    // and the run wrote no history rows.
    const after_nano = (try askuser.firstCellString(h.temp_dir, nano_sql, "nano")) orelse {
        std.debug.print("worker row must still exist after the follow-up\n", .{});
        return error.TestUnexpectedResult;
    };
    defer gpa.free(after_nano);
    try testing.expectEqualStrings(baseline_nano, after_nano);

    const history_sql = try std.fmt.allocPrint(
        gpa,
        "SELECT COUNT(*) AS n FROM llm_history WHERE session_id = {s}",
        .{sid_lit},
    );
    defer gpa.free(history_sql);
    try testing.expectEqual(@as(i64, 0), try askuser.scalarCount(h.temp_dir, history_sql));
}
