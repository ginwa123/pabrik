// Functional wire verification for `command`'s `is_stop` parameter.

const std = @import("std");
const testing = std.testing;
const harness = @import("harness.zig");
const Harness = harness.Harness;

const gpa = testing.allocator;
const io = testing.io;

const Io = std.Io;

const SESSION_ID = "sess_command_is_stop_1";
/// The `tool_call.id` the stub mints for its FIRST scripted round. Asserted
/// back out of the DB: the row that carries it is the proof the batch was
/// persisted before the break. Later rounds mint `call_round_<n>`.
const CALL_ID = "call_round_1";

/// Cap on the recorded request head — a runaway client must not grow the
/// accumulation without bound. Mirrors the auto-name stub.
const MAX_HEAD_BYTES = 1 << 18;

// ============================================================================
// Stub upstream
// ============================================================================

/// An OpenAI-compatible upstream that, on the FIRST agent round, answers with
/// one `command` tool call; on every later round, with a plain stop.
pub const StubRound = struct {
    tool: []const u8,
    args: []const u8,
};

const Stub = struct {
    io: Io,
    port: u16,
    server: Io.net.Server,
    thread: std.Thread,
    stop: std.atomic.Value(bool) = .init(false),
    mutex: Io.Mutex = .init,
    /// Absolute `cwd` handed to the tool. The server refuses a relative one.
    cwd: []const u8,
    /// The scripted turn per agent round. Rounds past the end answer with a
    /// plain `stop`, which is how every script terminates.
    rounds: []const StubRound,
    agent_calls: usize = 0,
    /// Most recent `"pid":<n>` seen in a request body — the model's view of
    /// "which process am I looking at".
    last_pid: ?u32 = null,

    fn start(
        stub: *Stub,
        cwd: []const u8,
        rounds: []const StubRound,
    ) !void {
        stub.* = .{
            .io = io,
            .port = 0,
            .server = undefined,
            .thread = undefined,
            .cwd = cwd,
            .rounds = rounds,
        };
        stub.port = try harness.findFreePortRandom(gpa);
        const addr: Io.net.IpAddress = .{ .ip4 = .loopback(stub.port) };
        stub.server = try addr.listen(io, .{ .reuse_address = true });
        errdefer stub.server.deinit(io);
        stub.thread = try std.Thread.spawn(.{}, serve, .{stub});
    }

    /// Wake the blocked `accept`, join.
    fn deinit(self: *Stub) void {
        self.stop.store(true, .release);
        const addr: Io.net.IpAddress = .{ .ip4 = .loopback(self.port) };
        if (addr.connect(self.io, .{ .mode = .stream })) |conn| {
            var c = conn;
            c.close(self.io);
        } else |_| {}
        self.thread.join();
        self.server.deinit(self.io);
    }

    fn agentCallCount(self: *Stub) usize {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        return self.agent_calls;
    }
};

fn serve(stub: *Stub) void {
    while (!stub.stop.load(.acquire)) {
        var stream = stub.server.accept(stub.io) catch break;
        defer stream.close(stub.io);
        if (stub.stop.load(.acquire)) break;
        handleRequest(stub, stream) catch {};
    }
}

fn handleRequest(stub: *Stub, stream: Io.net.Stream) !void {
    var rbuf: [64 * 1024]u8 = undefined;
    var sr = stream.reader(stub.io, &rbuf);
    const r = &sr.interface;

    var head_acc: Io.Writer.Allocating = .init(gpa);
    defer head_acc.deinit();
    var head_len: usize = 0;
    while (head_len == 0) {
        r.fill(1) catch break;
        const b = r.buffered();
        if (b.len == 0) break;
        head_acc.writer.writeAll(b) catch break;
        r.toss(b.len);
        if (head_acc.written().len > MAX_HEAD_BYTES) break;
        if (std.mem.indexOf(u8, head_acc.written(), "\r\n\r\n")) |i| head_len = i + 4;
    }
    if (head_len == 0) return;
    const head = head_acc.written()[0..head_len];

    var body_acc: Io.Writer.Allocating = .init(gpa);
    defer body_acc.deinit();
    var remaining = contentLength(head);
    if (head_acc.written().len > head_len) {
        const already = head_acc.written()[head_len..];
        try body_acc.writer.writeAll(already);
        remaining -|= already.len;
    }
    while (remaining > 0) {
        r.fill(1) catch break;
        const b = r.buffered();
        if (b.len == 0) break;
        const take = @min(b.len, remaining);
        try body_acc.writer.writeAll(b[0..take]);
        r.toss(take);
        remaining -= take;
    }
    const body = body_acc.written();

    // The session-name request is a separate, earlier call that carries no
    // `tools` array; answer it so it cannot pollute the counter this test
    // depends on. (Same classifier the auto-name suite uses.)
    const is_name = std.mem.indexOf(u8, body, "SessionNameGenerator") != null or
        (std.mem.indexOf(u8, body, "\"tools\"") == null and
            std.mem.indexOf(u8, body, "SessionName") != null);

    var payload: []u8 = &.{};
    defer if (payload.len > 0) gpa.free(payload);

    if (is_name) {
        payload = try textSse("is-stop-probe-session");
    } else {
        stub.mutex.lockUncancelable(stub.io);
        stub.agent_calls += 1;
        const round_index = stub.agent_calls;
        stub.mutex.unlock(stub.io);

        stub.mutex.lockUncancelable(stub.io);
        stub.last_pid = lastPidInBody(body) orelse stub.last_pid;
        const seen_pid = stub.last_pid;
        stub.mutex.unlock(stub.io);

        if (round_index <= stub.rounds.len) {
            const round = stub.rounds[round_index - 1];
            const args = try substitutePid(gpa, round.args, seen_pid);
            defer gpa.free(args);
            const call_id = try std.fmt.allocPrint(gpa, "call_round_{d}", .{round_index});
            defer gpa.free(call_id);
            payload = try toolCallSse(.{ .tool = round.tool, .args = args }, call_id);
        } else {
            payload = try textSse("done");
        }
    }

    const response = try std.fmt.allocPrint(
        gpa,
        "HTTP/1.1 200 OK\r\n" ++
            "Content-Type: text/event-stream\r\n" ++
            "Content-Length: {d}\r\n" ++
            "Connection: close\r\n" ++
            "\r\n",
        .{payload.len},
    );
    defer gpa.free(response);

    var wbuf: [8 * 1024]u8 = undefined;
    var sw = stream.writer(stub.io, &wbuf);
    try sw.interface.writeAll(response);
    try sw.interface.writeAll(payload);
    try sw.interface.flush();
}

/// OpenAI-style SSE stream carrying a plain assistant message.
fn textSse(text: []const u8) ![]u8 {
    return std.fmt.allocPrint(
        gpa,
        "data: {{\"id\":\"chatcmpl-stub-text\",\"object\":\"chat.completion.chunk\",\"model\":\"stub-model\",\"choices\":[{{\"index\":0,\"delta\":{{\"role\":\"assistant\",\"content\":\"{s}\"}},\"finish_reason\":null}}]}}\n\n" ++
            "data: {{\"id\":\"chatcmpl-stub-text\",\"object\":\"chat.completion.chunk\",\"model\":\"stub-model\",\"choices\":[{{\"index\":0,\"delta\":{{}},\"finish_reason\":\"stop\"}}]}}\n\n" ++
            "data: [DONE]\n\n",
        .{text},
    );
}

/// Build a `command` round with `cwd` filled in and `extra` appended verbatim,
/// so a test states exactly which parameters it exercises — and, just as
/// importantly, which it OMITS.
pub fn commandRound(allocator: std.mem.Allocator, cwd: []const u8, command: []const u8, extra: []const u8) !StubRound {
    var args_buf: Io.Writer.Allocating = .init(allocator);
    defer args_buf.deinit();
    const w = &args_buf.writer;
    try w.writeAll("{\"command\":");
    try writeJsonString(w, command);
    try w.writeAll(",\"cwd\":");
    try writeJsonString(w, cwd);
    try w.writeAll(",\"timeout\":30");
    try w.writeAll(extra);
    try w.writeAll("}");
    return .{ .tool = "command", .args = try args_buf.toOwnedSlice() };
}

/// The most recent `"pid":<digits>` anywhere in the request body.
fn lastPidInBody(body: []const u8) ?u32 {
    const needle = "\"pid\":";
    var found: ?u32 = null;
    var i: usize = 0;
    while (std.mem.indexOfPos(u8, body, i, needle)) |at| {
        const start = at + needle.len;
        var end = start;
        while (end < body.len and body[end] >= '0' and body[end] <= '9') end += 1;
        if (end > start) found = std.fmt.parseInt(u32, body[start..end], 10) catch found;
        i = end;
    }
    return found;
}

/// Replace `{PID}` with `pid`, or copy when the script has no placeholder.
fn substitutePid(allocator: std.mem.Allocator, args: []const u8, pid: ?u32) ![]u8 {
    const at = std.mem.indexOf(u8, args, "{PID}") orelse return allocator.dupe(u8, args);
    const pid_text = try std.fmt.allocPrint(allocator, "{d}", .{pid orelse 0});
    defer allocator.free(pid_text);
    return std.fmt.allocPrint(allocator, "{s}{s}{s}", .{ args[0..at], pid_text, args[at + "{PID}".len ..] });
}

/// One tool-call round-trip, `finish_reason: "tool_calls"`.
fn toolCallSse(round: StubRound, call_id: []const u8) ![]u8 {
    const args_json = try jsonStringEscape(gpa, round.args);
    defer gpa.free(args_json);

    return std.fmt.allocPrint(
        gpa,
        "data: {{\"id\":\"chatcmpl-stub-tool\",\"object\":\"chat.completion.chunk\",\"model\":\"stub-model\",\"choices\":[{{\"index\":0,\"delta\":{{\"role\":\"assistant\",\"content\":\"calling {s}\",\"tool_calls\":[{{\"index\":0,\"id\":\"{s}\",\"type\":\"function\",\"function\":{{\"name\":\"{s}\",\"arguments\":\"{s}\"}}}}]}},\"finish_reason\":null}}]}}\n\n" ++
            "data: {{\"id\":\"chatcmpl-stub-tool\",\"object\":\"chat.completion.chunk\",\"model\":\"stub-model\",\"choices\":[{{\"index\":0,\"delta\":{{}},\"finish_reason\":\"tool_calls\"}}]}}\n\n" ++
            "data: [DONE]\n\n",
        .{ round.tool, call_id, round.tool, args_json },
    );
}

/// Write `s` as a JSON string literal (quotes included), escaping `"` and `\`.
fn writeJsonString(w: *Io.Writer, s: []const u8) !void {
    try w.writeByte('"');
    for (s) |c| switch (c) {
        '"' => try w.writeAll("\\\""),
        '\\' => try w.writeAll("\\\\"),
        else => try w.writeByte(c),
    };
    try w.writeByte('"');
}

/// Escape `s` so it can sit INSIDE a JSON string (the SSE `arguments` field is
/// a string holding JSON). Returns an owned slice.
fn jsonStringEscape(allocator: std.mem.Allocator, s: []const u8) ![]u8 {
    var buf: std.ArrayList(u8) = .empty;
    errdefer buf.deinit(allocator);
    for (s) |c| switch (c) {
        '"' => try buf.appendSlice(allocator, "\\\""),
        '\\' => try buf.appendSlice(allocator, "\\\\"),
        else => try buf.append(allocator, c),
    };
    return buf.toOwnedSlice(allocator);
}

fn headerValue(head: []const u8, name: []const u8) ?[]const u8 {
    var it = std.mem.splitSequence(u8, head, "\r\n");
    _ = it.next(); // request line
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

// ============================================================================
// Helpers
// ============================================================================

fn nowMs() i64 {
    return std.Io.Timestamp.now(io, .awake).toMilliseconds();
}

fn sleepMs(ms: i64) void {
    std.Io.sleep(io, .fromMilliseconds(ms), .awake) catch {};
}

/// Skip unless a `sqlite3` CLI is present and speaks `-json` (SQLite 3.33+).
fn requireSqlite3Cli() !void {
    const res = std.process.run(gpa, io, .{
        .argv = &.{ "sqlite3", "-json", ":memory:", "SELECT 1 AS probe;" },
    }) catch {
        std.debug.print("sqlite3 CLI unavailable; skipping\n", .{});
        return error.SkipZigTest;
    };
    defer {
        gpa.free(res.stdout);
        gpa.free(res.stderr);
    }
    const ok = switch (res.term) {
        .exited => |c| c == 0 and std.mem.indexOf(u8, res.stdout, "probe") != null,
        else => false,
    };
    if (!ok) {
        std.debug.print("sqlite3 CLI lacks -json support; skipping\n", .{});
        return error.SkipZigTest;
    }
}

/// Point the server's active profile at this run's stub.
fn useStubProfile(h: *Harness, stub_port: u16, profile: []const u8) !void {
    const stub_url = try std.fmt.allocPrint(gpa, "http://127.0.0.1:{d}/v1/chat/completions", .{stub_port});
    defer gpa.free(stub_url);
    const body = try std.fmt.allocPrint(
        gpa,
        "{{\"api_endpoint\":\"{s}\",\"api_key\":\"sk-stub-test\",\"model\":\"stub-model\",\"url_style\":\"openai\"," ++
            "\"profiles\":{{\"{s}\":{{\"model\":\"stub-model\",\"base_url\":\"{s}\",\"api_key\":\"sk-stub-test\",\"url_style\":\"openai\"}}}}," ++
            "\"active_profile\":\"{s}\"}}",
        .{ stub_url, profile, stub_url, profile },
    );
    defer gpa.free(body);

    var r = try h.http(io, .PUT, "/api/config/pabrik", .{
        .json_body = body,
        .expect = &.{200},
    });
    defer r.deinit();
}

/// Queue one user message on the session (this is what starts the run).
fn sendTurn(h: *Harness, message: []const u8, profile: []const u8) !void {
    const body = try std.fmt.allocPrint(
        gpa,
        "{{\"session_id\":\"{s}\",\"queue_message\":\"{s}\",\"cwd_session\":\"{s}\"," ++
            "\"allowed_tools\":\"\",\"image_urls\":\"\",\"selected_profile_model\":\"{s}\"," ++
            "\"is_auto_retry_until_stop\":\"\"}}",
        .{ SESSION_ID, message, h.temp_dir, profile },
    );
    defer gpa.free(body);

    var r = try h.http(io, .POST, "/api/llm/session", .{
        .json_body = body,
        .expect = &.{ 200, 201, 500 },
        .timeout_s = 30.0,
    });
    defer r.deinit();
}

fn dbPath(h: *Harness) ![]u8 {
    return harness.harnessPath(gpa, h.temp_dir, &.{ ".config", "pabrik", "agent.db" });
}

/// Run one statement through the `sqlite3` CLI and return its stdout.
fn sqlRun(db_path: []const u8, sql: []const u8) ![]u8 {
    const res = std.process.run(gpa, io, .{
        .argv = &.{ "sqlite3", "-cmd", ".timeout 5000", "-json", db_path, sql },
    }) catch |err| {
        std.debug.print("sqlite3 did not spawn: {s}\n", .{@errorName(err)});
        return error.SkipZigTest;
    };
    gpa.free(res.stderr);
    switch (res.term) {
        .exited => |code| if (code != 0) {
            std.debug.print("sqlite3 exited {d} for sql: {s}\n", .{ code, sql });
            gpa.free(res.stdout);
            return error.TestUnexpectedResult;
        },
        else => {
            gpa.free(res.stdout);
            return error.TestUnexpectedResult;
        },
    }
    return res.stdout;
}

/// First column of the first row as an owned string; null when no row.
/// `sqlite3 -json` prints ZERO BYTES for an empty result set, not `[]`.
fn firstCell(db_path: []const u8, sql: []const u8) !?[]u8 {
    const out = try sqlRun(db_path, sql);
    defer gpa.free(out);
    const trimmed = std.mem.trim(u8, out, " \t\r\n");
    if (trimmed.len == 0 or std.mem.eql(u8, trimmed, "[]")) return null;

    const parsed = try std.json.parseFromSlice(std.json.Value, gpa, trimmed, .{});
    defer parsed.deinit();
    const rows = switch (parsed.value) {
        .array => |a| a,
        else => return error.TestUnexpectedResult,
    };
    if (rows.items.len == 0) return null;
    const row = switch (rows.items[0]) {
        .object => |o| o,
        else => return error.TestUnexpectedResult,
    };
    var it = row.iterator();
    const entry = it.next() orelse return null;
    return switch (entry.value_ptr.*) {
        .string => |s| try gpa.dupe(u8, s),
        .integer => |i| try std.fmt.allocPrint(gpa, "{d}", .{i}),
        .null => null,
        else => error.TestUnexpectedResult,
    };
}

fn scalarCount(db_path: []const u8, sql: []const u8) !i64 {
    const cell = (try firstCell(db_path, sql)) orelse return 0;
    defer gpa.free(cell);
    return std.fmt.parseInt(i64, cell, 10);
}

/// Poll until the worker row for the session is gone, or the deadline passes.
/// `deleteWorker` is the last thing the turn does, so its absence is the
/// "turn over" signal both tests wait on.
fn waitForTurnEnd(h: *Harness, db_path: []const u8, timeout_ms: i64) !void {
    const deadline = nowMs() + timeout_ms;
    while (nowMs() < deadline) {
        const n = try scalarCount(db_path, "SELECT COUNT(*) AS n FROM worker WHERE id = '" ++ SESSION_ID ++ "';");
        if (n == 0) return;
        sleepMs(100);
    }
    const tail = try h.tailLog(io, gpa, 40);
    defer gpa.free(tail);
    std.debug.print("the turn never ended (worker row still present). log tail:\n{s}\n", .{tail});
    return error.TestUnexpectedResult;
}

// ============================================================================
// `mode` — the silence contract, over the wire
// ============================================================================

/// `{pid, kind, status}` for the newest `session_background_process` row of the
/// session, or null when the run recorded none.
const BgRow = struct {
    pid: u32,
    kind: []u8,
    status: []u8,

    fn deinit(self: *BgRow) void {
        gpa.free(self.kind);
        gpa.free(self.status);
    }
};

fn newestBackgroundRow(db_path: []const u8) !?BgRow {
    const out = try sqlRun(db_path,
        \\SELECT pid, kind, status FROM session_background_process
        \\WHERE session_id = 'sess_command_is_stop_1'
        \\ORDER BY started_at DESC LIMIT 1;
    );
    defer gpa.free(out);
    const trimmed = std.mem.trim(u8, out, " \t\r\n");
    if (trimmed.len == 0 or std.mem.eql(u8, trimmed, "[]")) return null;

    const parsed = try std.json.parseFromSlice(std.json.Value, gpa, trimmed, .{});
    defer parsed.deinit();
    const rows = switch (parsed.value) {
        .array => |a| a,
        else => return error.TestUnexpectedResult,
    };
    if (rows.items.len == 0) return null;
    const row = switch (rows.items[0]) {
        .object => |o| o,
        else => return error.TestUnexpectedResult,
    };
    const pid_v = row.get("pid") orelse return error.TestUnexpectedResult;
    const kind_v = row.get("kind") orelse return error.TestUnexpectedResult;
    const status_v = row.get("status") orelse return error.TestUnexpectedResult;
    return BgRow{
        .pid = switch (pid_v) {
            .integer => |i| @intCast(i),
            .string => |str| try std.fmt.parseInt(u32, str, 10),
            else => return error.TestUnexpectedResult,
        },
        .kind = try gpa.dupe(u8, kind_v.string),
        .status = try gpa.dupe(u8, status_v.string),
    };
}

/// How many queue rows mention this PID. The completion envelope carries
/// `"pid":<n>`, which makes "was the agent told?" answerable without depending
/// on how the drain leaves the table behind.
fn queuedMentions(db_path: []const u8, pid: u32) !i64 {
    const sql = try std.fmt.allocPrint(
        gpa,
        "SELECT COUNT(*) AS n FROM session_queue_messages WHERE session_id = 'sess_command_is_stop_1' " ++
            "AND message LIKE '%\"pid\":{d}%';",
        .{pid},
    );
    defer gpa.free(sql);
    return scalarCount(db_path, sql);
}

// ============================================================================
// Tests
// ============================================================================

test "is_stop ends the turn after one model call, with the batch persisted" {
    try harness.requirePabrikBin(io, gpa);
    try requireSqlite3Cli();

    var h = try Harness.boot(io, gpa, .{ .stub_llm_profile = true });
    defer h.deinit(io) catch |err| {
        std.debug.print("teardown: {s}\n", .{@errorName(err)});
    };

    var stub: Stub = undefined;
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    const script = [_]StubRound{
        try commandRound(arena.allocator(), h.temp_dir, "echo is-stop-probe", ",\"is_stop\":true"),
    };
    try stub.start(h.temp_dir, &script);
    defer stub.deinit();

    const profile = "is-stop-stub";
    try useStubProfile(&h, stub.port, profile);
    try sendTurn(&h, "run the probe and stop", profile);

    const db_path = try dbPath(&h);
    defer gpa.free(db_path);
    try waitForTurnEnd(&h, db_path, 60_000);

    // THE ASSERTION THIS FILE EXISTS FOR. The loop broke instead of calling
    // the model again, so the stub saw exactly one agent round.
    sleepMs(1500);
    const calls = stub.agentCallCount();
    if (calls != 1) {
        std.debug.print("expected exactly 1 model call after is_stop, saw {d}\n", .{calls});
        return error.TestUnexpectedResult;
    }

    // The provider's own value for that round was `tool_calls`; the loop
    // overwrites it with `stop`, because `last_finish_reason` answers "is
    // anything still in flight" and a batch that ended the turn is not.
    const fr = (try firstCell(db_path, "SELECT COALESCE(last_finish_reason, '') AS fr FROM sessions WHERE id = '" ++ SESSION_ID ++ "';")) orelse {
        std.debug.print("no sessions row for {s} — the run never started\n", .{SESSION_ID});
        return error.TestUnexpectedResult;
    };
    defer gpa.free(fr);
    try testing.expectEqualStrings("stop", fr);

    // The batch was PERSISTED before the break. A `tool_call_id` with no
    // `role=tool` row is what makes a provider reject the NEXT turn, and the
    // mid-batch abort this test forbids is exactly how that happens.
    const tool_rows = try scalarCount(
        db_path,
        "SELECT COUNT(*) AS n FROM llm_history WHERE session_id = '" ++ SESSION_ID ++
            "' AND role = 'tool' AND tool_call_id = '" ++ CALL_ID ++ "';",
    );
    try testing.expectEqual(@as(i64, 1), tool_rows);

    // The assistant row keeps `tool_calls` — that IS what the provider
    // returned, and the transcript has to stay truthful about it.
    const assistant_rows = try scalarCount(
        db_path,
        "SELECT COUNT(*) AS n FROM llm_history WHERE session_id = '" ++ SESSION_ID ++
            "' AND role = 'assistant' AND finish_reason = 'tool_calls';",
    );
    try testing.expectEqual(@as(i64, 1), assistant_rows);
}

test "without is_stop the loop calls the model again (positive control)" {
    // Byte-for-byte the same run as the test above, minus the parameter.
    try harness.requirePabrikBin(io, gpa);
    try requireSqlite3Cli();

    var h = try Harness.boot(io, gpa, .{ .stub_llm_profile = true });
    defer h.deinit(io) catch |err| {
        std.debug.print("teardown: {s}\n", .{@errorName(err)});
    };

    var stub: Stub = undefined;
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    const script = [_]StubRound{
        // `is_stop` omitted entirely — the pre-existing argument set.
        try commandRound(arena.allocator(), h.temp_dir, "echo is-stop-probe", ""),
    };
    try stub.start(h.temp_dir, &script);
    defer stub.deinit();

    const profile = "no-is-stop-stub";
    try useStubProfile(&h, stub.port, profile);
    try sendTurn(&h, "run the probe", profile);

    const db_path = try dbPath(&h);
    defer gpa.free(db_path);
    try waitForTurnEnd(&h, db_path, 60_000);

    // The loop looped BACK: round 1 was the tool call, round 2 the plain
    // stop. That is the behaviour `is_stop` exists to override.
    const calls = stub.agentCallCount();
    if (calls < 2) {
        std.debug.print("expected the loop to call the model again without is_stop, saw {d} call(s)\n", .{calls});
        return error.TestUnexpectedResult;
    }

    // And the finish reason is the provider's own `stop` from round 2 — the
    // value `is_stop` has to reproduce deliberately.
    const fr = (try firstCell(db_path, "SELECT COALESCE(last_finish_reason, '') AS fr FROM sessions WHERE id = '" ++ SESSION_ID ++ "';")) orelse
        return error.TestUnexpectedResult;
    defer gpa.free(fr);
    try testing.expectEqualStrings("stop", fr);

    // The tool result is still persisted exactly once — `is_stop` changed
    // WHEN the loop ends, not whether the batch is written.
    const tool_rows = try scalarCount(
        db_path,
        "SELECT COUNT(*) AS n FROM llm_history WHERE session_id = '" ++ SESSION_ID ++
            "' AND role = 'tool' AND tool_call_id = '" ++ CALL_ID ++ "';",
    );
    try testing.expectEqual(@as(i64, 1), tool_rows);
}

test "background_persistence queues NOTHING when the service exits" {
    // THE contract of the third mode: the process detaches, runs, exits — and
    // the agent is never told.
    try harness.requirePabrikBin(io, gpa);
    try requireSqlite3Cli();

    var h = try Harness.boot(io, gpa, .{ .stub_llm_profile = true });
    defer h.deinit(io) catch |err| {
        std.debug.print("teardown: {s}\n", .{@errorName(err)});
    };

    var stub: Stub = undefined;
    // `sleep 1`, not a dev server: the process has to EXIT inside the test for
    // "no message was queued" to mean anything. A never-exiting server would
    // satisfy the assertion trivially and prove nothing.
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    const script = [_]StubRound{
        try commandRound(
            arena.allocator(),
            h.temp_dir,
            "sleep 1",
            ",\"mode\":\"background_persistence\",\"is_stop\":true",
        ),
    };
    try stub.start(h.temp_dir, &script);
    defer stub.deinit();

    const profile = "persistence-stub";
    try useStubProfile(&h, stub.port, profile);
    try sendTurn(&h, "start the dev server and stop", profile);

    const db_path = try dbPath(&h);
    defer gpa.free(db_path);
    try waitForTurnEnd(&h, db_path, 60_000);

    var row = (try newestBackgroundRow(db_path)) orelse {
        std.debug.print("no session_background_process row: the detached process was never recorded\n", .{});
        return error.TestUnexpectedResult;
    };
    defer row.deinit();

    // The mode reached the DB as a kind. `service` is what the cron filters on.
    try testing.expectEqualStrings("service", row.kind);

    // Wait for the process to exit AND for the reaper to notice — the row
    // flipping to `exited` IS that notice.
    var exited = false;
    const exit_deadline = nowMs() + 30_000;
    while (nowMs() < exit_deadline) {
        var fresh = (try newestBackgroundRow(db_path)) orelse break;
        defer fresh.deinit();
        if (std.mem.eql(u8, fresh.status, "exited")) {
            exited = true;
            break;
        }
        sleepMs(200);
    }
    if (!exited) {
        std.debug.print("the service row never reached status='exited' — the reaper did not run\n", .{});
        return error.TestUnexpectedResult;
    }

    // Give the NOTIFY path every chance to fire before declaring it silent: the
    // watcher polls on a 2 s clock, so a regression lands well inside this
    // window.
    sleepMs(6000);

    // THE assertion, and it is deliberately about the WAKE rather than about
    // the queue row.
    const calls = stub.agentCallCount();
    if (calls != 1) {
        std.debug.print(
            "background_persistence woke the agent ({d} model calls, expected 1) — the service must be silent\n",
            .{calls},
        );
        return error.TestUnexpectedResult;
    }

    // Corroboration, and honest about its limit: it holds only because nothing
    // was woken to drain a row.
    const mentions = try queuedMentions(db_path, row.pid);
    if (mentions != 0) {
        std.debug.print("background_persistence queued {d} message(s) for pid {d} — it must be silent\n", .{ mentions, row.pid });
        return error.TestUnexpectedResult;
    }
}

test "background DOES queue the completion — the control for the test above" {
    // The same run with the other detached mode. Without this, "no queue
    // message" would also be satisfied by an execution path that never reaches
    // the notification code at all.
    try harness.requirePabrikBin(io, gpa);
    try requireSqlite3Cli();

    var h = try Harness.boot(io, gpa, .{ .stub_llm_profile = true });
    defer h.deinit(io) catch |err| {
        std.debug.print("teardown: {s}\n", .{@errorName(err)});
    };

    var stub: Stub = undefined;
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    const script = [_]StubRound{
        try commandRound(
            arena.allocator(),
            h.temp_dir,
            "sleep 1",
            ",\"mode\":\"background\",\"is_stop\":true",
        ),
    };
    try stub.start(h.temp_dir, &script);
    defer stub.deinit();

    const profile = "background-stub";
    try useStubProfile(&h, stub.port, profile);
    try sendTurn(&h, "run the job and stop", profile);

    const db_path = try dbPath(&h);
    defer gpa.free(db_path);
    try waitForTurnEnd(&h, db_path, 60_000);

    var row = (try newestBackgroundRow(db_path)) orelse return error.TestUnexpectedResult;
    defer row.deinit();
    try testing.expectEqualStrings("job", row.kind);

    // This is the positive control: the SAME machinery must TALK here. The
    // observable is the wake — a model call that the is_stop turn did not
    // make.
    const deadline = nowMs() + 30_000;
    var calls = stub.agentCallCount();
    while (nowMs() < deadline and calls < 2) {
        sleepMs(250);
        calls = stub.agentCallCount();
    }
    if (calls < 2) {
        std.debug.print(
            "background mode never woke the agent for pid {d} ({d} model calls) — the control failed, so the silence test proved nothing\n",
            .{ row.pid, calls },
        );
        return error.TestUnexpectedResult;
    }
}

// ============================================================================
// `process` — what the agent can see of what it started
// ============================================================================

/// Every `process` tool result this session persisted, concatenated.
fn processToolRows(db_path: []const u8) ![]u8 {
    return sqlRun(db_path,
        \\SELECT COALESCE(group_concat(response_content, ' --ROW-- '), '') AS blob
        \\FROM llm_history
        \\WHERE session_id = 'sess_command_is_stop_1' AND tool_name = 'process';
    );
}

/// True when the `sqlite3 -json` output carries no blob at all.
fn blobIsEmpty(json_out: []const u8) bool {
    const t = std.mem.trim(u8, json_out, " \t\r\n");
    return t.len == 0 or std.mem.indexOf(u8, t, "\"blob\":\"\"") != null;
}

test "process: the agent can see a service it started" {
    try harness.requirePabrikBin(io, gpa);
    try requireSqlite3Cli();

    var h = try Harness.boot(io, gpa, .{ .stub_llm_profile = true });
    defer h.deinit(io) catch |err| {
        std.debug.print("teardown: {s}\n", .{@errorName(err)});
    };

    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    const a = arena.allocator();

    const script = [_]StubRound{
        // Start a SERVICE. No `is_stop`: the turn must continue so the next
        // round runs.
        try commandRound(
            a,
            h.temp_dir,
            "sh -c 'echo service-marker; sleep 30'",
            ",\"mode\":\"background_persistence\"",
        ),
        // Ask what is running.
        .{ .tool = "process", .args = "{\"action\":\"list\"}" },
    };

    var stub: Stub = undefined;
    try stub.start(h.temp_dir, &script);
    defer stub.deinit();

    const profile = "process-stub";
    try useStubProfile(&h, stub.port, profile);
    try sendTurn(&h, "start the service, then show me what is running", profile);

    const db_path = try dbPath(&h);
    defer gpa.free(db_path);

    // Wait for the RESULT, not for the turn. The result is the claim; whether
    // the turn has ended is a different question with several legitimate
    // answers (a queued message, a wake).
    var rows = try processToolRows(db_path);
    defer gpa.free(rows);
    const deadline = nowMs() + 60_000;
    while (nowMs() < deadline and blobIsEmpty(rows)) {
        sleepMs(250);
        gpa.free(rows);
        rows = try processToolRows(db_path);
    }
    if (blobIsEmpty(rows)) {
        std.debug.print("`process` produced no tool result (model_calls={d})\n", .{stub.agentCallCount()});
        return error.TestUnexpectedResult;
    }

    // The service's own command text travelled through `list` — this session's
    // row, read back by the tool. Nothing else could put it in the payload.
    if (std.mem.indexOf(u8, rows, "service-marker") == null) {
        std.debug.print("`process list` did not report the service this session started. rows:\n{s}\n", .{rows});
        return error.TestUnexpectedResult;
    }
    // ...and `kind` is on the wire, which is what tells the model it will never
    // be notified about this one.
    if (std.mem.indexOf(u8, rows, "service") == null) {
        std.debug.print("`process list` did not report the kind. rows:\n{s}\n", .{rows});
        return error.TestUnexpectedResult;
    }
    // The refusal path did not fire: the tool found a process it owns, so the
    // session scoping is not hiding this session's own rows.
    if (std.mem.indexOf(u8, rows, "is not a process this session started") != null) {
        std.debug.print("`process` refused its own session's process\n", .{});
        return error.TestUnexpectedResult;
    }

    // The DB half of the same claim.
    var row = (try newestBackgroundRow(db_path)) orelse return error.TestUnexpectedResult;
    defer row.deinit();
    try testing.expectEqualStrings("service", row.kind);
}
