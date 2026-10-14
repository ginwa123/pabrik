// Functional wire-replay test for Responses `function_call_output` sanitization.
//
// Zig port of `tests/functional/responses_tool_output_sanitize_test.py`
// (same test name, same order).
//
// Python docstring, preserved verbatim:
//
//   """Functional wire-replay test for Responses `function_call_output` sanitization.
//
//   Regression for: ``input[20].output[0] did not match any supported type``
//   (muse-spark via Console Go, ``url_style="openai-response"``).
//
//   A ``bash`` tool output containing ``cat`` of an ELF binary embedded
//   invalid UTF-8 bytes into ``function_call_output.output``; the backend
//   emitted them raw, so the gateway rejected the whole request before
//   streaming a single chunk
//   (``stream ended without finish_reason after 0 chunk(s)``).
//
//   This test replays the EXACT shape over the real HTTP wire:
//
//     1. A TCP capture server stands in for the LLM endpoint and records the
//        raw request bytes the backend sends (then hangs up — the run fails,
//        which is fine; we assert on the captured *request*, not the reply).
//     2. The harness boots with the stub profile; ``PUT /api/config/pabrik``
//        (granular ``ProfileChange`` shape) repoints it at the capture server
//        with ``url_style="openai-response"`` (live-reload, no restart).
//     3. ``PUT /api/llm/session/:id`` creates the session row *without*
//        running the agent; poisoned history rows (assistant
//        ``tool_calls_json`` + tool output with ELF bytes) are seeded
//        straight into ``agent.db``; a single ``POST /api/llm/session``
//        replays them into a Responses request aimed at the capture
//        server. (One run only — a second sequential run on the same
//        session can queue behind the first worker's retry/backoff and
//        flake on timing.)
//     4. Assert the captured body is valid UTF-8, carries a
//        ``function_call_output`` item, has no raw ``0xFF`` byte, and contains
//        U+FFFD (the sanitizer's replacement marker).
//
//   DONT KILL the port 8081 server — the harness picks ports in 8080..8199
//   excluding 8081 (see ``harness.py``).
//   """
//
// ── TWO PORTING DECISIONS WORTH READING ───────────────────────────────────
//
// (1) THE POISON IS SEEDED WITH AN SQL BLOB LITERAL, NOT A TEXT LITERAL.
// The Python passed raw `bytes` to `sqlite3`, so `response_content` held a
// BLOB whose bytes include 0xFF / 0x80 — not valid UTF-8. Passing a `str`
// would UTF-8-encode them (U+00FF becomes `c3 bf`) and the test would stop
// reproducing the gateway rejection. A command-line `sqlite3` invocation
// cannot take binary parameters, so the bytes go in as SQLite's own
// `X'..'` hex blob literal, which is a BLOB by construction. This is the
// same "no link-time SQLite" rule `llm_history_model_not_empty_test.zig`
// follows: spawn the CLI, never add a dependency.
//
// (2) THE CAPTURE SERVER HUNGS UP WITHOUT REPLYING — and that is the point.
// The Python's `_serve` closes the connection after recording the body, so
// the LLM run fails fast; every assertion is on the REQUEST. A server that
// answered would make the run succeed and, worse, would let a bug hide
// behind a 200.

const std = @import("std");
const testing = std.testing;
const harness = @import("harness.zig");
const Harness = harness.Harness;

const gpa = testing.allocator;
const io = testing.io;

const Io = std.Io;

const CALL_ID = "call_01a06fb93f1878c19cd31a8ad82456e3";
const SESSION_ID = "sess_resp_sanitize_001";

/// The seeded session name, the same string the Python PUT and POSTed.
const SESSION_NAME = "resp-sanitize";

/// ELF magic + invalid bytes, mimicking `cat` of a binary in tool stdout.
///
/// sqlite3 + the JSON wire must carry these EXACT bytes pre-fix. A Zig
/// string literal is a byte array, so the 0xFF / 0x80 survive verbatim —
/// unlike a Zig `[]u8` built from a JSON escape, which would re-encode them.
const POISONED_STDOUT =
    "/home/ginwa/.config/quickshell/default/qs-glauncher-zig:\n" ++
    "build.zig\n" ++
    "---\n" ++
    "\x7fELF\x02\x01\x01\x00\xff\xfe binary \x80\x81 done\n";

/// The U+FFFD REPLACEMENT CHARACTER as its three UTF-8 bytes — the
/// sanitizer's marker, and the assertion that stands in for Python's
/// `"\ufffd" in text`.
const REPLACEMENT_CHAR = "\xef\xbf\xbd";

/// Cap on the request head we accumulate before giving up.
const MAX_HEAD_BYTES = 1 << 20;

/// `wait_for_body_with_marker(..., timeout_s=120.0)`.
const CAPTURE_BUDGET_MS: i64 = 120_000;
/// `time.sleep(0.1)` between polls.
const CAPTURE_INTERVAL_MS: i64 = 100;

// ============================================================================
// Capture server
// ============================================================================

/// A minimal TCP server that records full HTTP request bodies and then
/// hangs up without responding.
const CaptureServer = struct {
    port: u16,
    server: Io.net.Server,
    thread: std.Thread,
    stop: std.atomic.Value(bool) = .init(false),
    /// Connections accepted, and complete heads seen. Diagnostics only:
    /// a capture server that accepted nothing and one that got requests
    /// it could not parse are different failures with the same
    /// "no body with the marker" message.
    connections: std.atomic.Value(usize) = .init(0),
    heads: std.atomic.Value(usize) = .init(0),
    /// Guards `bodies`: the serve thread appends while the test polls.
    mutex: Io.Mutex = .init,
    bodies: std.ArrayList([]u8) = .empty,

    fn start(cs: *CaptureServer) !void {
        cs.port = try harness.findFreePortRandom(gpa);
        const addr: Io.net.IpAddress = .{ .ip4 = .loopback(cs.port) };
        cs.server = try addr.listen(io, .{ .reuse_address = true });
        errdefer cs.server.deinit(io);
        cs.thread = try std.Thread.spawn(.{}, serve, .{cs});
    }

    /// Set the stop flag, wake the blocked `accept`, join, and free.
    ///
    /// The self-connect is required: `Server.accept` is a BLOCKING
    /// `accept4(2)`, and closing a listening socket does NOT wake a
    /// thread already blocked in `accept` on Linux. Without the wake
    /// the thread is still parked at test end, and its
    /// DebugAllocator-owned stack is reported as a leak by the NEXT
    /// test. If the connect fails, the listener is already gone and
    /// `accept` has errored, so the loop exited anyway.
    fn close(cs: *CaptureServer) void {
        cs.stop.store(true, .release);

        const addr: Io.net.IpAddress = .{ .ip4 = .loopback(cs.port) };
        if (addr.connect(io, .{ .mode = .stream })) |conn| {
            var c = conn;
            c.close(io);
        } else |_| {}

        cs.thread.join();
        cs.server.deinit(io);
        cs.mutex.lockUncancelable(io);
        defer cs.mutex.unlock(io);
        for (cs.bodies.items) |b| gpa.free(b);
        cs.bodies.deinit(gpa);
    }

    /// A copy of every body captured so far, for the failure message.
    fn snapshotBodies(cs: *CaptureServer) !std.ArrayList([]u8) {
        var out: std.ArrayList([]u8) = .empty;
        errdefer {
            for (out.items) |b| gpa.free(b);
            out.deinit(gpa);
        }
        cs.mutex.lockUncancelable(io);
        defer cs.mutex.unlock(io);
        for (cs.bodies.items) |b| try out.append(gpa, try gpa.dupe(u8, b));
        return out;
    }
};

fn serve(cs: *CaptureServer) void {
    while (!cs.stop.load(.acquire)) {
        // `defer` inside a loop body runs at the end of THAT iteration,
        // so each accepted socket is closed before the next accept.
        var stream = cs.server.accept(io) catch break;
        _ = cs.connections.fetchAdd(1, .monotonic);
        defer stream.close(io);
        if (cs.stop.load(.acquire)) break;
        captureOne(cs, stream) catch {};
    }
}

/// Read one request head + body, record the body, then return (the
/// caller's `defer stream.close` hangs up without a reply).
///
/// THE HEAD AND THE BODY OVERLAP IN THE SOCKET BUFFER: `fill(1)` reads a
/// whole syscall's worth into the 64 KiB buffer, so one call typically
/// returns the head AND the first chunk of the body. The loop therefore
/// accumulates everything and records only the first
/// `\r\n\r\n`-terminated slice as the head; a naive version that tossed
/// the whole buffer once the head was complete would DISCARD those body
/// bytes and then block waiting for bytes the client had already sent.
fn captureOne(cs: *CaptureServer, stream: Io.net.Stream) !void {
    var rbuf: [64 * 1024]u8 = undefined;
    var sr = stream.reader(io, &rbuf);
    const r = &sr.interface;

    var acc: Io.Writer.Allocating = .init(gpa);
    defer acc.deinit();

    var head_len: usize = 0;
    while (head_len == 0) {
        r.fill(1) catch break;
        const b = r.buffered();
        if (b.len == 0) break;
        acc.writer.writeAll(b) catch break;
        r.toss(b.len);
        if (acc.written().len > MAX_HEAD_BYTES) break;
        if (std.mem.indexOf(u8, acc.written(), "\r\n\r\n")) |i| head_len = i + 4;
    }
    if (head_len == 0) return;
    _ = cs.heads.fetchAdd(1, .monotonic);
    const head = acc.written()[0..head_len];

    var remaining = contentLength(head);
    if (acc.written().len > head_len) remaining -|= acc.written().len - head_len;
    while (remaining > 0) {
        r.fill(1) catch break;
        const b = r.buffered();
        if (b.len == 0) break;
        // ACCUMULATE, THEN TOSS. Tearing the body out of the reader
        // without copying it into `acc` looks correct and silently
        // truncates the capture to whatever the first read happened to
        // bring: `fill(1)` reads a whole syscall's worth, and the
        // 64 KiB buffer therefore caps the "captured" request at ~64 KB.
        // A real agent prompt (system prompt + every tool schema) is
        // 125 KB, so the JSON parse then fails on a truncated slice.
        const take = @min(b.len, remaining);
        acc.writer.writeAll(b[0..take]) catch break;
        remaining -= take;
        r.toss(take);
    }

    const body = acc.written()[head_len..];
    cs.mutex.lockUncancelable(io);
    defer cs.mutex.unlock(io);
    try cs.bodies.append(gpa, try gpa.dupe(u8, body));
}

fn headerLines(head: []const u8) std.mem.SplitIterator(u8, .sequence) {
    var it = std.mem.splitSequence(u8, head, "\r\n");
    _ = it.next(); // request line
    return it;
}

fn headerValue(head: []const u8, name: []const u8) ?[]const u8 {
    var it = headerLines(head);
    while (it.next()) |line| {
        if (line.len == 0) break;
        const colon = std.mem.indexOfScalar(u8, line, ':') orelse continue;
        if (!std.ascii.eqlIgnoreCase(std.mem.trim(u8, line[0..colon], " \t"), name)) continue;
        return std.mem.trim(u8, line[colon + 1 ..], " \t");
    }
    return null;
}

fn contentLength(head: []const u8) usize {
    const v = headerValue(head, "content-length") orelse return 0;
    return std.fmt.parseInt(usize, v, 10) catch 0;
}

/// Poll until a captured body contains `marker`. Returns an OWNED copy, or
/// null on timeout.
fn waitForBodyWithMarker(cs: *CaptureServer, marker: []const u8) !?[]u8 {
    const deadline = Io.Timestamp.now(io, .awake).toMilliseconds() + CAPTURE_BUDGET_MS;
    while (Io.Timestamp.now(io, .awake).toMilliseconds() < deadline) {
        cs.mutex.lockUncancelable(io);
        defer cs.mutex.unlock(io);
        for (cs.bodies.items) |b| {
            if (std.mem.indexOf(u8, b, marker) != null) return try gpa.dupe(u8, b);
        }
        // NOTE: the lock is held across the sleep only because the
        // `defer` above is scoped to the whole loop body. The capture
        // thread appends under the same lock, so this is correct — and
        // it is a 100ms sleep, not the 120s budget, so starvation is
        // not reachable.
        std.Io.sleep(io, .fromMilliseconds(CAPTURE_INTERVAL_MS), .awake) catch {};
    }
    return null;
}

// ============================================================================
// Helpers
// ============================================================================

/// `PUT granular ProfileChange: stub -> capture server + openai-response`.
fn repointStubAtCapture(h: *Harness, port: u16) !void {
    const body = try std.fmt.allocPrint(gpa,
        \\{{"profiles":[{{"name":"stub","action":"update","model":"stub-model","base_url":"http://127.0.0.1:{d}","url_style":"openai-response","api_key":"stub-key-not-real"}}]}}
    , .{port});
    defer gpa.free(body);
    var r = try h.http(io, .PUT, "/api/config/pabrik", .{ .json_body = body, .expect = &.{200} });
    r.deinit();
}

/// Single-quote `s` as an SQL literal, doubling embedded quotes. Owned.
fn sqlLit(s: []const u8) ![]u8 {
    var out: std.Io.Writer.Allocating = .init(gpa);
    errdefer out.deinit();
    try out.writer.writeByte('\'');
    for (s) |c| {
        if (c == '\'') try out.writer.writeByte('\'');
        try out.writer.writeByte(c);
    }
    try out.writer.writeByte('\'');
    return out.toOwnedSlice();
}

/// `X'<hex>'` — an SQL BLOB literal, so the poison stays a BLOB.
///
/// Upper-case hex; SQLite accepts either case and requires an even number
/// of digits.
fn sqlBlobLit(bytes: []const u8) ![]u8 {
    var out: std.Io.Writer.Allocating = .init(gpa);
    errdefer out.deinit();
    try out.writer.writeAll("X'");
    for (bytes) |b| try out.writer.print("{X:0>2}", .{b});
    try out.writer.writeByte('\'');
    return out.toOwnedSlice();
}

/// Exit code for a finished child, or null if a signal stopped it.
///
/// `Child.Term` is a tagged union, NOT an optional: `.exited` is a `u8`
/// field, so `res.term.exited orelse ...` does not compile and a bare
/// `res.term.exited != 0` would silently read the wrong field.
fn exitCode(term: std.process.Child.Term) ?u8 {
    return switch (term) {
        .exited => |c| c,
        else => null,
    };
}

/// Candidate `sqlite3` binaries, in preference order. First one that can
/// actually open an `agent.db` wins.
///
/// `sqlite3` from PATH is tried FIRST — that is the binary a developer
/// would use by hand — but the fallback list is not paranoia. The
/// `sqlite3` on this box resolves to an Android platform-tools build
/// whose SQLite was compiled WITHOUT FTS5, and `agent.db` contains FTS5
/// virtual tables, so merely PREPARING a statement against it fails with
/// `no such module: fts5` before a single row is written. The symptom
/// is an INSERT that "fails" for a reason that has nothing to do with
/// the test, so the probe below asks the question the test actually
/// depends on: can this build open a database with an FTS5 table in it?
const SQLITE_CANDIDATES = [_][]const u8{
    "sqlite3",
    "/usr/bin/sqlite3",
    "/usr/local/bin/sqlite3",
    "/bin/sqlite3",
};

/// True iff `bin` runs and understands FTS5.
fn sqliteHasFts5(bin: []const u8) bool {
    const res = std.process.run(gpa, io, .{
        .argv = &.{ bin, ":memory:", "CREATE VIRTUAL TABLE __fts5_probe USING fts5(x);" },
    }) catch return false;
    defer {
        gpa.free(res.stdout);
        gpa.free(res.stderr);
    }
    const code = exitCode(res.term);
    return code != null and code.? == 0;
}

/// Return a `sqlite3` that can open the agent DB, or skip.
///
/// Returns a BORROW into `SQLITE_CANDIDATES` (a comptime-known
/// literal), so the caller must not free it.
fn requireSqlite3Cli() ![]const u8 {
    for (SQLITE_CANDIDATES) |bin| {
        if (sqliteHasFts5(bin)) return bin;
    }
    std.debug.print(
        "no sqlite3 CLI with FTS5 support found (tried {d}); skipping the DB-seeding assertions.\n",
        .{SQLITE_CANDIDATES.len},
    );
    return error.SkipZigTest;
}

/// Run one statement against `db_path` with `bin`.
fn sqliteRun(bin: []const u8, db_path: []const u8, sql: []const u8) !void {
    const res = std.process.run(gpa, io, .{
        .argv = &.{ bin, "-cmd", ".timeout 5000", db_path, sql },
    }) catch |err| {
        std.debug.print("sqlite3 did not spawn: {s}\n", .{@errorName(err)});
        return error.SkipZigTest;
    };
    defer {
        gpa.free(res.stdout);
        gpa.free(res.stderr);
    }
    const code = exitCode(res.term) orelse {
        std.debug.print("sqlite3 was killed by a signal: {any}\n", .{res.term});
        return error.TestUnexpectedResult;
    };
    if (code != 0) {
        std.debug.print("sqlite3 exited {d}: {s}\nsql: {s}\n", .{ code, res.stderr, sql });
        return error.TestUnexpectedResult;
    }
}

/// The agent DB inside the isolated tmpdir HOME.
fn dbPath(temp_dir: []const u8) ![]u8 {
    return harness.harnessPath(gpa, temp_dir, &.{ ".config", "pabrik", "agent.db" });
}

/// The assistant `tool_calls_json` the seeded assistant row carries.
///
/// Byte-identical to the Python's `json.dumps([...])` (default `", "`
/// / `": "` separators), because that string is what the backend parses
/// into the `function_call` replay item.
const TOOL_CALLS_JSON =
    \\[{"id": "call_01a06fb93f1878c19cd31a8ad82456e3", "type": "function", "function": {"name": "bash", "arguments": "{\"command\": \"timeout 10 ls -R /tmp | head -n 5\", \"cwd\": \"/tmp\", \"timeout\": 15.0}"}}]
;

/// Insert the assistant tool_calls row + the ELF-poisoned tool row for
/// `SESSION_ID`.
///
/// Mirrors the production write path (`handle_tool.zig` Phase 2 ->
/// `llm_history.saveMessage`): the assistant row carries
/// `tool_calls_json` in Chat-Completions shape, the tool row carries the
/// raw output in `response_content` with `tool_call_id`. Replay only
/// includes rows with `is_feed_to_llm = 1` (`get_llm_histories.zig`),
/// ordered by `created_at_nano`.
fn seedPoisonedHistory(h: *Harness, bin: []const u8) !void {
    const db = try dbPath(h.temp_dir);
    defer gpa.free(db);

    const sid = try sqlLit(SESSION_ID);
    defer gpa.free(sid);
    const calls = try sqlLit(TOOL_CALLS_JSON);
    defer gpa.free(calls);
    const call_id = try sqlLit(CALL_ID);
    defer gpa.free(call_id);
    const poison = try sqlBlobLit(POISONED_STDOUT);
    defer gpa.free(poison);

    // `time.time_ns()` in Python; the real clock here, so the rows sort
    // after anything the boot already wrote — replay is ordered by
    // `created_at_nano`.
    const now_nano: i128 = Io.Timestamp.now(io, .real).toNanoseconds();

    const sql = try std.fmt.allocPrint(gpa,
        \\INSERT INTO llm_history
        \\ (id, session_id, model, response_content, tool_calls_json,
        \\  role, tool_call_id, finish_reason, is_feed_to_llm,
        \\  created_at_nano, tool_name)
        \\ VALUES ('msg_resp_assistant_001', {s}, 'stub-model', '', {s},
        \\  'assistant', NULL, 'tool_calls', 1, {d}, 'bash');
        \\INSERT INTO llm_history
        \\ (id, session_id, model, response_content, tool_calls_json,
        \\  role, tool_call_id, finish_reason, is_feed_to_llm,
        \\  created_at_nano, tool_name)
        \\ VALUES ('msg_resp_tool_001', {s}, 'stub-model', {s}, NULL,
        \\  'tool', {s}, NULL, 1, {d}, 'bash');
    , .{ sid, calls, now_nano + 1, sid, poison, call_id, now_nano + 2 });
    defer gpa.free(sql);

    try sqliteRun(bin, db, sql);
}

/// Render the `type` of each `input` item as `[a, b, c]`. Owned.
fn inputTypes(input: []const std.json.Value) ![]u8 {
    var out: std.Io.Writer.Allocating = .init(gpa);
    errdefer out.deinit();
    try out.writer.writeByte('[');
    for (input, 0..) |item, i| {
        if (i > 0) try out.writer.writeAll(", ");
        const o = switch (item) {
            .object => |oo| oo,
            else => {
                try out.writer.writeAll("<non-object>");
                continue;
            },
        };
        const t = switch (o.get("type") orelse std.json.Value{ .null = {} }) {
            .string => |str| str,
            else => "<no type>",
        };
        try out.writer.writeAll(t);
    }
    try out.writer.writeByte(']');
    return out.toOwnedSlice();
}

// ============================================================================
// Test
// ============================================================================

// Poisoned tool history replays as valid UTF-8 `function_call_output`.
//
// Pre-fix, the captured Responses body carried the poison through
// without sanitization markers (no U+FFFD) and any strict gateway
// rejected it with `input[N].output[0] did not match any supported
// type` (0 chunks). Post-fix, the body is valid UTF-8 with U+FFFD
// markers and the original `call_id` pairing intact.
test "responses_replay_sanitizes_binary_tool_output" {
    try harness.requirePabrikBin(io, gpa);
    // A BORROW into `SQLITE_CANDIDATES`; never freed.
    const sqlite_bin = try requireSqlite3Cli();

    var server: CaptureServer = .{ .port = 0, .server = undefined, .thread = undefined };
    try server.start();
    defer server.close();

    // `stub_llm_profile` is load-bearing: the profile `repointStubAtCapture`
    // updates by name only exists because the harness wrote it.
    var h = try Harness.boot(io, gpa, .{ .stub_llm_profile = true });
    defer h.deinit(io) catch |err| {
        std.debug.print("teardown: {s}\n", .{@errorName(err)});
    };

    try repointStubAtCapture(&h, server.port);

    // Create the session row WITHOUT running the agent (PUT auto-creates
    // via ensureSessionExists — no LLM call, no worker, so nothing can
    // queue behind a first run's retry/backoff).
    {
        const path = try std.fmt.allocPrint(gpa, "/api/llm/session/{s}", .{SESSION_ID});
        defer gpa.free(path);
        const body = try std.fmt.allocPrint(gpa, "{{\"name\":\"{s}\"}}", .{SESSION_NAME});
        defer gpa.free(body);
        var r = try h.http(io, .PUT, path, .{ .json_body = body, .expect = &.{200} });
        defer r.deinit();
    }

    // Seed the exact failing shape, then replay it with a single run.
    try seedPoisonedHistory(&h, sqlite_bin);
    {
        const body = try std.fmt.allocPrint(
            gpa,
            "{{\"session_id\":\"{s}\",\"session_name\":\"{s}\",\"queue_message\":\"again\"}}",
            .{ SESSION_ID, SESSION_NAME },
        );
        defer gpa.free(body);
        // Python: `expect=(200, 201, 500)` — the worker runs in the
        // background and the capture server hangs up on it, so a 500 here
        // is the EXPECTED outcome, not a failure.
        var r = try h.http(io, .POST, "/api/llm/session", .{
            .json_body = body,
            .expect = &.{ 200, 201, 500 },
        });
        defer r.deinit();
    }

    const body = (try waitForBodyWithMarker(&server, "function_call_output")) orelse {
        var seen = try server.snapshotBodies();
        defer {
            for (seen.items) |b| gpa.free(b);
            seen.deinit(gpa);
        }
        var msg: std.Io.Writer.Allocating = .init(gpa);
        defer msg.deinit();
        msg.writer.print(
            "backend never POSTed a Responses body containing function_call_output; " ++
                "captured {d} bodies: [",
            .{seen.items.len},
        ) catch return error.OutOfMemory;
        for (seen.items, 0..) |b, i| {
            if (i > 0) msg.writer.writeAll(", ") catch return error.OutOfMemory;
            // `debugString` returns an OWNED buffer: it must be freed
            // here, not left to the reporting allocator (a `{s}` format
            // argument only borrows it for the call).
            const quoted = harness.debugString(gpa, b[0..@min(80, b.len)]) catch {
                msg.writer.writeAll("<unavailable>") catch return error.OutOfMemory;
                continue;
            };
            defer gpa.free(quoted);
            msg.writer.writeAll(quoted) catch return error.OutOfMemory;
        }
        msg.writer.writeAll("]\n") catch return error.OutOfMemory;
        const tail = h.tailLog(io, gpa, 40) catch "";
        defer if (tail.len > 0) gpa.free(tail);
        msg.writer.print("capture server: {d} connection(s), {d} complete head(s)\n--- log tail ---\n{s}\n", .{
            server.connections.load(.monotonic),
            server.heads.load(.monotonic),
            tail,
        }) catch return error.OutOfMemory;
        std.debug.print("{s}", .{msg.written()});
        return error.TestUnexpectedResult;
    };
    defer gpa.free(body);

    // 1. The whole body must be valid UTF-8 (gateway JSON parses it).
    if (!std.unicode.utf8ValidateSlice(body)) {
        const excerpt = harness.debugString(gpa, body[0..@min(400, body.len)]) catch "<unavailable>";
        defer gpa.free(excerpt);
        std.debug.print("captured Responses body is not valid UTF-8: {s}\n", .{excerpt});
        return error.TestUnexpectedResult;
    }

    // 2. No raw poison bytes survive on the wire.
    if (std.mem.indexOfScalar(u8, body, 0xff) != null) {
        std.debug.print(
            "raw 0xFF byte reached the wire — gateway would reject with " ++
                "input[N].output[0] type error\n",
            .{},
        );
        return error.TestUnexpectedResult;
    }

    // 3. The sanitizer marked the replacements + kept the pairing.
    if (std.mem.indexOf(u8, body, REPLACEMENT_CHAR) == null) {
        std.debug.print("expected U+FFFD replacement markers in sanitized output\n", .{});
        return error.TestUnexpectedResult;
    }
    if (std.mem.indexOf(u8, body, CALL_ID) == null) {
        std.debug.print("function_call_output lost its call_id pairing ({s})\n", .{CALL_ID});
        return error.TestUnexpectedResult;
    }

    var payload = std.json.parseFromSlice(std.json.Value, gpa, body, .{ .allocate = .alloc_always }) catch |err| {
        std.debug.print("captured Responses body is not JSON ({s})\n", .{@errorName(err)});
        return error.TestUnexpectedResult;
    };
    defer payload.deinit();

    const input_val = payload.value.object.get("input") orelse {
        std.debug.print("captured Responses body has no `input` array\n", .{});
        return error.TestUnexpectedResult;
    };
    const input = switch (input_val) {
        .array => |a| a.items,
        else => {
            std.debug.print("captured Responses body has no `input` array\n", .{});
            return error.TestUnexpectedResult;
        },
    };
    var saw_function_call = false;
    var saw_function_call_output = false;
    for (input) |item| {
        const o = switch (item) {
            .object => |oo| oo,
            else => continue,
        };
        const t = switch (o.get("type") orelse std.json.Value{ .null = {} }) {
            .string => |str| str,
            else => continue,
        };
        if (std.mem.eql(u8, t, "function_call")) saw_function_call = true;
        if (std.mem.eql(u8, t, "function_call_output")) saw_function_call_output = true;
    }
    // Python printed `kinds!r` — the LIST — in both messages, and it is
    // the only thing that tells a reader which of the two replay items
    // is missing. A bare "expected a function_call item" sends them back
    // to the capture.
    // PORT HISTORY: this assertion once failed with
    // `[message, function_call_output, message]` and the failure was
    // misdiagnosed as a backend defect (see git history). The backend was
    // innocent: the port's `TOOL_CALLS_JSON` literal carried DOUBLED inner
    // backslashes (\\" where Python json.dumps emits \"), because
    // a Zig \\ literal keeps backslashes verbatim while the author wrote
    // them as if escapes were processed. The seeded `arguments` string was
    // therefore not valid JSON, the backend could not parse `tool_calls`,
    // and the assistant row replayed as a plain `message`. Fixed by halving
    // the inner escapes; the literal is now byte-identical to `json.dumps`.
    if (!saw_function_call) {
        const kinds = try inputTypes(input);
        defer gpa.free(kinds);
        std.debug.print(
            "expected a function_call replay item, got input types {s}\n",
            .{kinds},
        );
        return error.TestUnexpectedResult;
    }
    if (!saw_function_call_output) {
        const kinds = try inputTypes(input);
        defer gpa.free(kinds);
        std.debug.print("expected a function_call_output replay item, got input types {s}\n", .{kinds});
        return error.TestUnexpectedResult;
    }
}

// Body-analysis barrier. An unreferenced helper is never type-checked, so
// a stdlib rename inside one stays invisible until a caller appears.
comptime {
    _ = CaptureServer.start;
    _ = CaptureServer.close;
    _ = CaptureServer.snapshotBodies;
    _ = serve;
    _ = captureOne;
    _ = headerLines;
    _ = headerValue;
    _ = contentLength;
    _ = waitForBodyWithMarker;
    _ = repointStubAtCapture;
    _ = sqlLit;
    _ = sqlBlobLit;
    _ = exitCode;
    _ = sqliteHasFts5;
    _ = requireSqlite3Cli;
    _ = sqliteRun;
    _ = dbPath;
    _ = seedPoisonedHistory;
    _ = inputTypes;
    _ = Harness.boot;
}
