// Functional wire test: REST `skills` + SSE `session_skills` agree after skill equip.
//
// Zig port of `tests/functional/session_skills_live_test.py`
// (same test names, same order).
//
// Python docstring, preserved verbatim:
//
//   """Functional wire test: REST `skills` + SSE `session_skills` agree after skill equip.
//
//   Plan Task 5: docs/superpowers/plans/2026-09-08-live-session-skills-sse.md
//
//   Flow:
//     1. PUT /api/llm/session/:id creates the session row (no LLM needed).
//     2. Seed one session_skills row, then REST GET messages asserts
//        body["skills"][0]["skill_name"].
//     3. Open SSE /api/events?channels=llm, POST one agent turn, drain until
//        llm_full with matching session_id, assert
//        data["session_skills"][0]["skill_name"].
//     4. Explicit key-name contract: REST key is `skills`, SSE key is
//        `session_skills` (locks the mismatch so future renames fail loudly).
//
//   Seed method: direct sqlite3 INSERT into session_skills (NOT the real
//   get_skill/add_skill tool path — that path needs a live LLM plus skill .md
//   files on disk; the contract under test here is DB -> REST/SSE
//   serialization, and the inserted row is byte-identical to what
//   handle_tool.zig SaveSkill writes: INSERT OR REPLACE INTO session_skills
//   (session_id, skill_name, content, loaded_at_nano) with
//   strftime('%s','now')).
//   """
//
// ─── WHY THERE IS A HAND-ROLLED SSE CLIENT HERE ──────────────────────────────
// `Harness.http` cannot serve this test. It calls `reader.streamRemaining`,
// which on a `text/event-stream` response blocks until the server closes the
// connection — and the server holds the stream open for the life of the
// session, so `streamRemaining` never returns. Python's `urllib.request.urlopen`
// returned as soon as the RESPONSE HEAD parsed and drained the body line by
// line on a daemon thread with a deadline; this port keeps that shape:
// `std.http.Client` directly, `sendBodiless`, `receiveHead`, then a reader
// thread doing line-at-a-time `takeDelimiterInclusive('\n')` until a `stop`
// flag or a `shutdown(.recv)` releases it.
//
// The stream is HEAP-ALLOCATED because `std.http.Client` embeds a
// `ConnectionPool` with an `Io.Mutex` and `Response.request` is a `*Request`
// into the frame that produced it — both make the trio uncopyable, so
// returning it by value would bit-copy a mutex and leave a dangling
// `resp.request`.
//
// ─── WHY THE SEED GOES IN THROUGH THE `sqlite3` CLI ─────────────────────────
// Python used the stdlib `sqlite3` MODULE. This package links no SQLite and
// will not grow one (`tests/functional/build.zig` has no dependency on
// `pabrikcore` precisely so a suite can never "pass" without crossing the
// wire), so the port spawns the `sqlite3` COMMAND-LINE tool — the same idiom
// `chat_right_sidebar_git_test.zig` uses for `git`. The SQL is byte-identical
// to `llm_history.saveSkill`'s, so the seeded row is still byte-identical to
// what `handle_tool.zig` writes, which is the whole premise of the seed.

const std = @import("std");
const testing = std.testing;
const harness = @import("harness.zig");
const Harness = harness.Harness;

const Io = std.Io;

const gpa = testing.allocator;
const io = testing.io;

const SKILL_NAME = "live-wire-skill";
const SKILL_CONTENT = "live wire content";
const SESSION_ID = "sess_skills_live_001";

/// Python `_drain_until(..., timeout_s=60.0)`.
const SSE_DRAIN_TIMEOUT_MS: i64 = 60_000;

/// Transfer buffer for the response body reader.
///
/// NOT `&.{}`: `Response.reader(transfer_buffer)` uses that slice as the
/// reader's own buffer for a chunked body, and the delimiter read reports
/// `error.StreamTooLong` the instant it fills without a newline — which, on a
/// stream with no `\n` yet, is immediately.
const transfer_buffer_len = 8 * 1024;

/// Monotonic milliseconds (`.awake` = monotonic, not wall clock).
fn nowMs() i64 {
    return Io.Timestamp.now(io, .awake).toMilliseconds();
}

// ─── sqlite3 CLI helpers ────────────────────────────────────────────────────

/// Skip unless a `sqlite3` CLI is present and speaks `-json`.
/// Exit code for a finished child, or null if a signal stopped it.
///
/// `Child.Term` is a tagged union, NOT an optional: `.exited` is a `u8`
/// field, so `res.term.exited orelse ...` does not compile and a bare
/// `res.term.exited != 0` would silently read the wrong field on a
/// signalled run.
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
        std.debug.print("sqlite3 CLI unavailable ({s}); skipping the session_skills seed\n", .{@errorName(err)});
        return error.SkipZigTest;
    };
    defer {
        gpa.free(res.stdout);
        gpa.free(res.stderr);
    }
    const code = exitCode(res.term);
    if (code == null or code.? != 0 or std.mem.indexOf(u8, res.stdout, "\"probe\"") == null) {
        std.debug.print(
            "sqlite3 CLI lacks -json support (rc={?}, out={s}); skipping the session_skills seed\n",
            .{ code, res.stdout },
        );
        return error.SkipZigTest;
    }
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
        .argv = &.{ "sqlite3", "-cmd", ".timeout 5000", db_path, sql },
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

/// `INSERT OR REPLACE INTO session_skills (...)` — the exact statement
/// `llm_history.saveSkill` runs. Python `_seed_session_skill`.
fn seedSessionSkill(temp_dir: []const u8) !void {
    const db = try harness.harnessPath(gpa, temp_dir, &.{ ".config", "pabrik", "agent.db" });
    defer gpa.free(db);

    // Python asserted the DB exists before touching it; the table only
    // exists once the server has migrated, so a missing file means the
    // harness booted a binary that never opened its DB.
    std.Io.Dir.cwd().access(io, db, .{}) catch {
        std.debug.print("agent.db missing at {s}\n", .{db});
        return error.TestUnexpectedResult;
    };

    const sid = try sqlLit(SESSION_ID);
    defer gpa.free(sid);
    const name = try sqlLit(SKILL_NAME);
    defer gpa.free(name);
    const content = try sqlLit(SKILL_CONTENT);
    defer gpa.free(content);

    const sql = try std.fmt.allocPrint(
        gpa,
        "INSERT OR REPLACE INTO session_skills" ++
            " (session_id, skill_name, content, loaded_at_nano)" ++
            " VALUES ({s}, {s}, {s}, strftime('%s', 'now'))",
        .{ sid, name, content },
    );
    defer gpa.free(sql);

    const out = try sqliteRun(db, sql);
    gpa.free(out);
}

// ─── SSE client ─────────────────────────────────────────────────────────────

/// One parsed SSE frame: the `event:` name plus the joined `data:` lines.
const SseEvent = struct {
    name: []u8,
    data: []u8,

    fn deinit(self: *SseEvent) void {
        gpa.free(self.name);
        gpa.free(self.data);
        self.* = undefined;
    }
};

/// An open SSE connection plus the state the reader thread fills in.
const SseStream = struct {
    client: std.http.Client,
    req: std.http.Client.Request,
    /// The transfer buffer `body` reads out of. Owned here so its address
    /// outlives every read.
    transfer_buffer: [transfer_buffer_len]u8 = undefined,
    /// `req.reader` after `resp.reader(&transfer_buffer)`.
    body: *std.Io.Reader = undefined,
    status: u16 = 0,
    /// Duplicated from the response head (which `resp.reader()` invalidates).
    content_type: []u8 = "",
    /// Set by the test thread to release the reader.
    stop: std.atomic.Value(bool) = .init(false),
    /// Set by the reader thread once it has stopped touching `events`.
    done: std.atomic.Value(bool) = .init(false),
    /// Frames parsed so far.
    ///
    /// Guarded by `mutex`: the reader appends while the test thread polls,
    /// and an unsynchronised read of `events.items` during the reader's
    /// `append` is a use-after-free (the ArrayList realloc frees the old
    /// buffer). Python's `queue.Queue` was this lock.
    mutex: Io.Mutex = .init,
    events: std.ArrayList(SseEvent) = .empty,
    /// Set by the reader thread when the stream errored or ended.
    read_error: ?[]u8 = null,

    fn deinit(self: *SseStream) void {
        self.req.deinit();
        self.client.deinit();
        gpa.free(self.content_type);
        for (self.events.items) |*e| e.deinit();
        self.events.deinit(gpa);
        if (self.read_error) |m| gpa.free(m);
        gpa.destroy(self);
    }
};

/// Open `GET /api/events?channels=<channels>` and capture the response head.
/// Caller owns the returned pointer and must `deinit` it.
fn openSse(port: u16, channels: []const u8) !*SseStream {
    const s = try gpa.create(SseStream);
    errdefer gpa.destroy(s);

    // `gpa.create` returns UNINITIALIZED memory — it does NOT run the
    // struct's field default initializers. Every field with a default
    // (`mutex`, `stop`, `done`, `events`, `read_error`) must be assigned
    // here or it stays garbage, and an uninitialised `Io.Mutex` is not a
    // lock at all. `s.* = .{...}` applies all the defaults in one shot.
    s.* = .{ .client = .{ .allocator = gpa, .io = io }, .req = undefined };

    const url = try std.fmt.allocPrint(gpa, "http://127.0.0.1:{d}/api/events?channels={s}", .{ port, channels });
    defer gpa.free(url);

    s.req = s.client.request(.GET, try std.Uri.parse(url), .{
        .redirect_behavior = .unhandled,
        .extra_headers = &.{
            // What the browser's `EventSource` sends; the handler keys off
            // the query string, but sending it keeps the request identical
            // to the one under test.
            .{ .name = "Accept", .value = "text/event-stream" },
        },
    }) catch |err| {
        s.client.deinit();
        return err;
    };
    errdefer {
        s.req.deinit();
        s.client.deinit();
    }

    try s.req.sendBodiless();
    var resp = try s.req.receiveHead(&.{});
    s.status = @intFromEnum(resp.head.status);

    // Headers FIRST: `resp.reader()` calls `head.invalidateStrings()`, so
    // touching `head` afterwards is a use-after-free.
    {
        var hit = resp.head.iterateHeaders();
        while (hit.next()) |kv| {
            if (std.ascii.eqlIgnoreCase(kv.name, "content-type")) {
                s.content_type = try gpa.dupe(u8, kv.value);
                break;
            }
        }
    }

    s.body = resp.reader(&s.transfer_buffer);
    return s;
}

/// Read SSE frames until `stop` is set, the stream ends, or an error
/// occurs. Runs on its own thread.
///
/// The grammar (per `unified_events_sse.zig` `forwardToClients`):
///     event: <name>\n
///     data: <line>\n
///     \n            <- blank line dispatches the frame
fn readEvents(s: *SseStream) void {
    defer s.done.store(true, .release);

    const reader = s.body;

    var current_name: ?[]u8 = null;
    defer if (current_name) |n| gpa.free(n);

    var data_lines: std.ArrayList([]u8) = .empty;
    defer {
        for (data_lines.items) |d| gpa.free(d);
        data_lines.deinit(gpa);
    }

    while (!s.stop.load(.acquire)) {
        // One LINE, not the whole stream: this is what makes the read
        // incremental. `error.EndOfStream` is a clean server close.
        //
        // `takeDelimiterINCLUSIVE`, never `takeDelimiterExclusive`. The
        // exclusive form advances "up to (but not past) the delimiter" —
        // it leaves the `\n` in the buffer. The next call therefore sees a
        // delimiter at position 0 and returns a ZERO-LENGTH slice, for
        // ever: the reader spins at full speed, every line reads as the
        // blank-line frame terminator, and every frame after the first is
        // dispatched as an EMPTY one. The first frame still dispatches,
        // which is exactly why a handshake-only assertion passes against
        // this and a push assertion does not.
        const raw_line = reader.takeDelimiterInclusive('\n') catch |err| {
            const msg = switch (err) {
                error.EndOfStream => "stream ended",
                error.ReadFailed => "read failed",
                error.StreamTooLong => "line exceeded the transfer buffer",
            };
            const owned = gpa.dupe(u8, msg) catch return;
            s.mutex.lockUncancelable(io);
            s.read_error = owned;
            s.mutex.unlock(io);
            return;
        };
        const line = std.mem.trimEnd(u8, std.mem.trimEnd(u8, raw_line, "\n"), "\r");

        if (line.len == 0) {
            // Blank line → dispatch whatever we accumulated.
            if (current_name) |name| {
                // `std.mem.join` allocates an owned buffer but types it
                // `[]const u8`; the constCast is sound because the buffer is
                // ours to hand to `gpa.free`.
                const joined = std.mem.join(gpa, "\n", data_lines.items) catch "";
                const data: []u8 = @constCast(joined);
                s.mutex.lockUncancelable(io);
                s.events.append(gpa, .{ .name = name, .data = data }) catch {
                    s.mutex.unlock(io);
                    gpa.free(name);
                    gpa.free(data);
                    for (data_lines.items) |d| gpa.free(d);
                    data_lines.clearRetainingCapacity();
                    return;
                };
                s.mutex.unlock(io);
                current_name = null;
            }
            for (data_lines.items) |d| gpa.free(d);
            data_lines.clearRetainingCapacity();
            continue;
        }

        if (std.mem.startsWith(u8, line, "event:")) {
            if (current_name) |old| gpa.free(old);
            current_name = gpa.dupe(u8, std.mem.trim(u8, line["event:".len..], " \t")) catch null;
        } else if (std.mem.startsWith(u8, line, "data:")) {
            const v = gpa.dupe(u8, std.mem.trim(u8, line["data:".len..], " \t")) catch continue;
            data_lines.append(gpa, v) catch {
                gpa.free(v);
                continue;
            };
        }
        // `:` comment lines and unknown fields are ignored, matching both
        // the browser EventSource parser and the Python reader.
    }
}

/// Release a blocked `readEvents` by shutting the socket's read side.
///
/// Without this the reader thread parks in `readv` forever on a stream that
/// never ends; `shutdown(SHUT_RD)` makes the pending read return 0, which
/// surfaces as `error.EndOfStream`.
fn releaseReader(s: *SseStream) void {
    s.stop.store(true, .release);
    s.req.connection.?.stream_reader.stream.shutdown(io, .recv) catch {};
}

/// True iff `data` is an `llm_full` payload for `session_id` carrying a
/// NON-EMPTY `session_skills` array.
///
/// Python's predicate:
///   ev == "llm_full" and isinstance(data, dict)
///     and data.get("session_id") == SESSION_ID
///     and isinstance(data.get("session_skills"), list) and len(...) > 0
fn llmFullHasSkills(data: []const u8, session_id: []const u8) bool {
    var parsed = std.json.parseFromSlice(std.json.Value, gpa, data, .{}) catch return false;
    defer parsed.deinit();

    const obj = switch (parsed.value) {
        .object => |o| o,
        else => return false,
    };
    const sid = switch (obj.get("session_id") orelse return false) {
        .string => |s| s,
        else => return false,
    };
    if (!std.mem.eql(u8, sid, session_id)) return false;
    const skills = switch (obj.get("session_skills") orelse return false) {
        .array => |a| a,
        else => return false,
    };
    return skills.items.len > 0;
}

/// Wait for an `llm_full` frame for `session_id` with non-empty
/// `session_skills`. Returns an OWNED copy of the event's `data` payload
/// (the caller frees it), or `null` if the deadline or the stream ends
/// first.
///
/// A monotonic CURSOR over the append-only event list is the analogue of
/// Python's `queue.Queue.get(timeout=0.5)` drain: frames already rejected
/// by the predicate are never re-examined, and the mutex is released before
/// each sleep (holding it across the sleep starves the reader, which needs
/// the same lock to append).
fn drainUntilLlmFull(s: *SseStream, session_id: []const u8, timeout_ms: i64) !?[]u8 {
    const deadline = nowMs() + timeout_ms;
    var cursor: usize = 0;

    while (true) {
        s.mutex.lockUncancelable(io);
        var hit: ?usize = null;
        var i: usize = if (cursor < s.events.items.len) cursor else s.events.items.len;
        while (i < s.events.items.len) : (i += 1) {
            const e = s.events.items[i];
            if (!std.mem.eql(u8, e.name, "llm_full")) continue;
            if (!llmFullHasSkills(e.data, session_id)) continue;
            hit = i;
            break;
        }
        cursor = s.events.items.len;
        const finished = s.done.load(.acquire);
        s.mutex.unlock(io);

        if (hit) |idx| {
            // Dupe AFTER the unlock: `gpa.dupe` can fail, and returning
            // while holding the lock would strand the reader thread.
            s.mutex.lockUncancelable(io);
            defer s.mutex.unlock(io);
            return try gpa.dupe(u8, s.events.items[idx].data);
        }
        if (finished) return null;
        if (nowMs() >= deadline) return null;
        Io.sleep(io, .fromMilliseconds(50), .awake) catch {};
    }
}

/// A copy of the event names seen so far, for the failure message.
fn seenNames(s: *SseStream) []u8 {
    s.mutex.lockUncancelable(io);
    defer s.mutex.unlock(io);
    var out: std.Io.Writer.Allocating = .init(gpa);
    errdefer out.deinit();
    for (s.events.items) |e| out.writer.print("{s} ", .{e.name}) catch break;
    return out.toOwnedSlice() catch |err| {
        out.deinit();
        std.debug.print("could not render the seen-events list: {s}\n", .{@errorName(err)});
        return gpa.dupe(u8, "<unavailable>") catch @panic("dupe of the <unavailable> literal failed");
    };
}

// ─── HTTP helpers ───────────────────────────────────────────────────────────

/// `PUT /api/llm/session/:id` creates the session row (no LLM needed).
/// Python step 1.
fn createSessionRow(h: *Harness) !void {
    const path = try std.fmt.allocPrint(gpa, "/api/llm/session/{s}", .{SESSION_ID});
    defer gpa.free(path);
    const body = try std.json.Stringify.valueAlloc(gpa, .{ .name = "skills-live" }, .{});
    defer gpa.free(body);

    var r = try h.http(io, .PUT, path, .{ .json_body = body, .expect = &.{200} });
    defer r.deinit();
}

/// One `{skill_name, ...}` entry's name, borrowed from `arr`.
fn skillNameAt(arr: std.json.Array, i: usize) ?[]const u8 {
    const o = switch (arr.items[i]) {
        .object => |m| m,
        else => return null,
    };
    return switch (o.get("skill_name") orelse return null) {
        .string => |s| s,
        else => return null,
    };
}

test "rest_and_sse_skills_agree" {
    try harness.requirePabrikBin(io, gpa);
    try requireSqlite3Cli();
    var h = try Harness.boot(io, gpa, .{ .stub_llm_profile = true });
    defer h.deinit(io) catch |err| {
        std.debug.print("teardown: {s}\n", .{@errorName(err)});
    };

    // 1. Create session row without running the agent.
    try createSessionRow(&h);

    // 2. Seed one skill row (direct insert — see module docstring).
    try seedSessionSkill(h.temp_dir);

    // 3. REST: top-level `skills` carries the seeded skill.
    //
    // The RESPONSE is held alongside the parsed document, not dropped in a
    // nested block: the failure messages below print the raw wire body (a
    // `std.json.Value` has no `{s}` formatter), so `r.body` has to still be
    // alive when one of them fires.
    const rest_path = try std.fmt.allocPrint(gpa, "/api/llm/session/{s}/messages", .{SESSION_ID});
    defer gpa.free(rest_path);
    var rest_resp = try h.http(io, .GET, rest_path, .{
        .params = &.{.{ .name = "limit", .value = "10" }},
        .expect = &.{200},
    });
    defer rest_resp.deinit();
    var body = try rest_resp.json();
    defer body.deinit();

    // Python: `assert "skills" in body` — an ABSENT key must fail.
    const rest_skills = body.array("skills") orelse {
        std.debug.print("REST must use key 'skills'; body={s}\n", .{rest_resp.body});
        return error.TestUnexpectedResult;
    };
    // Python: `assert "session_skills" not in body`.
    if (body.get("session_skills") != null) {
        std.debug.print(
            "REST must NOT use SSE key 'session_skills' at top level; body={s}\n",
            .{rest_resp.body},
        );
        return error.TestUnexpectedResult;
    }
    if (rest_skills.items.len != 1) {
        std.debug.print("expected exactly 1 REST skill, got {d}\n", .{rest_skills.items.len});
        return error.TestUnexpectedResult;
    }
    const rest_name = skillNameAt(rest_skills, 0) orelse {
        std.debug.print("REST skill entry has no string `skill_name`\n", .{});
        return error.TestUnexpectedResult;
    };
    try testing.expectEqualStrings(SKILL_NAME, rest_name);

    // 4. SSE: open llm channel, trigger one turn, drain for fresh llm_full.
    const s = try openSse(h.port, "llm");
    defer s.deinit();

    try testing.expectEqual(@as(u16, 200), s.status);
    if (std.mem.indexOf(u8, s.content_type, "text/event-stream") == null) {
        std.debug.print("expected SSE content-type, got '{s}'\n", .{s.content_type});
        return error.TestUnexpectedResult;
    }

    // DEFERRING THE JOIN LAST IS LOAD-BEARING: defers run LIFO, so
    // `reader.join()` must fire BEFORE `s.deinit()` frees the SseStream the
    // reader thread is writing frames into.
    const reader = try std.Thread.spawn(.{}, readEvents, .{s});
    defer reader.join();

    {
        // Python accepted 200 / 201 / 500: the stub LLM points at a dead
        // port, so the turn may fail outright. The `llm_full` frame is
        // emitted by the queue-message insert BEFORE the LLM call.
        const turn = try std.json.Stringify.valueAlloc(gpa, .{
            .session_id = SESSION_ID,
            .session_name = "skills-live",
            .queue_message = "ping",
        }, .{});
        defer gpa.free(turn);

        var posted = try h.http(io, .POST, "/api/llm/session", .{
            .json_body = turn,
            .expect = &.{ 200, 201, 500 },
        });
        posted.deinit();
    }

    const found = try drainUntilLlmFull(s, SESSION_ID, SSE_DRAIN_TIMEOUT_MS);
    releaseReader(s);

    if (found == null) {
        const names = seenNames(s);
        defer gpa.free(names);
        s.mutex.lockUncancelable(io);
        const reason = if (s.read_error) |m| m else "";
        s.mutex.unlock(io);

        if (reason.len > 0) {
            std.debug.print(
                "no llm_full with non-empty session_skills arrived within 60s; stream reported: {s}\n",
                .{reason},
            );
        } else {
            std.debug.print(
                "no llm_full with non-empty session_skills arrived within 60s; saw: [{s}]\n",
                .{names},
            );
        }
        return error.TestUnexpectedResult;
    }
    const payload = found.?;
    defer gpa.free(payload);

    // 4b. Explicit key-name contract, asserted against the live payload.
    var data = try std.json.parseFromSlice(std.json.Value, gpa, payload, .{});
    defer data.deinit();
    const obj = switch (data.value) {
        .object => |o| o,
        else => {
            std.debug.print("llm_full data is not an object: {s}\n", .{payload});
            return error.TestUnexpectedResult;
        },
    };
    const sse_skills = switch (obj.get("session_skills") orelse {
        std.debug.print("SSE must use key 'session_skills'; data={s}\n", .{payload});
        return error.TestUnexpectedResult;
    }) {
        .array => |a| a,
        else => {
            std.debug.print("SSE `session_skills` is not an array: {s}\n", .{payload});
            return error.TestUnexpectedResult;
        },
    };
    if (obj.get("skills") != null) {
        std.debug.print("SSE must NOT use REST key 'skills'; data={s}\n", .{payload});
        return error.TestUnexpectedResult;
    }

    var saw_seeded = false;
    for (sse_skills.items, 0..) |_, i| {
        const name = skillNameAt(sse_skills, i) orelse {
            std.debug.print("SSE session_skills[{d}] has no string `skill_name`\n", .{i});
            return error.TestUnexpectedResult;
        };
        if (std.mem.eql(u8, name, SKILL_NAME)) saw_seeded = true;
    }
    if (!saw_seeded) {
        std.debug.print("SSE session_skills missing '{s}'\n", .{SKILL_NAME});
        return error.TestUnexpectedResult;
    }

    // 5. Cross-wire agreement: REST and SSE carry the same skill set.
    // Python: `set(names) == rest_names` with `rest_names == {SKILL_NAME}`.
    // The REST side was pinned to exactly one entry named SKILL_NAME above,
    // so equality holds iff every SSE name is SKILL_NAME and it appears once.
    for (sse_skills.items, 0..) |_, i| {
        const name = skillNameAt(sse_skills, i).?;
        if (!std.mem.eql(u8, name, SKILL_NAME)) {
            std.debug.print(
                "REST/SSE skill sets disagree: REST={{{s}}} SSE carries '{s}'\n",
                .{ SKILL_NAME, name },
            );
            return error.TestUnexpectedResult;
        }
    }
}
