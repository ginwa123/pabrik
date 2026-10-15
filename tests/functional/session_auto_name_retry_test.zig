// Functional regression: a failed auto-name call must not strand the session
// as "New Chat" forever.

const std = @import("std");
const testing = std.testing;
const harness = @import("harness.zig");
const Harness = harness.Harness;
const gpa = testing.allocator;
const io = testing.io;

const Io = std.Io;

const SESSION_ID = "sess_auto_name_retry_1";
const GENERATED_NAME = "wire-verified-auto-name";

/// Cap on the recorded request head — a runaway client must not grow the
/// accumulation without bound.
const MAX_HEAD_BYTES = 1 << 18;

// ============================================================================
// Stub upstream
// ============================================================================

/// A stub LLM upstream that fails the FIRST session-name request with
/// HTTP 503. Python's `_StubState` + `_StubHandler` + `_start_stub`.
const Stub = struct {
    io: Io,
    port: u16,
    server: Io.net.Server,
    thread: std.Thread,
    stop: std.atomic.Value(bool) = .init(false),
    mutex: Io.Mutex = .init,
    /// How many tool-call rounds the main turn drives before answering
    /// with a plain stop. Python's `tool_rounds`.
    tool_rounds: usize,
    /// When true the name request ALWAYS 503s. Python's
    /// `name_always_fails`.
    name_always_fails: bool,
    name_calls: usize = 0,
    name_failures_served: usize = 0,
    agent_calls: usize = 0,

    /// Bind and start serving on `stub` (an OUT-PARAMETER — the serve
    /// thread is handed `stub`'s address, so it must live at a stable
    /// address in the caller's frame; see `llm_test_test.zig`).
    fn start(stub: *Stub, tool_rounds: usize, name_always_fails: bool) !void {
        stub.* = .{
            .io = io,
            .port = 0,
            .server = undefined,
            .thread = undefined,
            .tool_rounds = tool_rounds,
            .name_always_fails = name_always_fails,
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

    fn nameCallCount(self: *Stub) usize {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        return self.name_calls;
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

/// Classify + answer one upstream request. Python's `_StubHandler.do_POST`.
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

    // Python's `classify`: the name call carries NO `tools` array while
    // the main agent turn always does.
    const is_name = std.mem.indexOf(u8, body, "SessionNameGenerator") != null or
        (std.mem.indexOf(u8, body, "\"tools\"") == null and
            std.mem.indexOf(u8, body, "SessionName") != null);

    var status: u16 = 200;
    var content_type: []const u8 = "text/event-stream";
    var payload: []u8 = &.{};
    defer if (payload.len > 0) gpa.free(payload);

    if (is_name) {
        stub.mutex.lockUncancelable(stub.io);
        stub.name_calls += 1;
        const first = stub.name_failures_served == 0;
        const reject = first or stub.name_always_fails;
        if (reject) stub.name_failures_served += 1;
        stub.mutex.unlock(stub.io);

        if (reject) {
            status = 503;
            content_type = "application/json";
            payload = try std.fmt.allocPrint(
                gpa,
                "{{\"error\":{{\"message\":\"{s}\",\"type\":\"{s}\"}}}}",
                .{ "name call rejected", "rate_limit_error" },
            );
        } else {
            payload = try textSse(GENERATED_NAME);
        }
    } else {
        stub.mutex.lockUncancelable(stub.io);
        stub.agent_calls += 1;
        const round_index = stub.agent_calls;
        const tool_rounds = stub.tool_rounds;
        stub.mutex.unlock(stub.io);

        if (tool_rounds > 0 and round_index <= tool_rounds) {
            const call_id = try std.fmt.allocPrint(gpa, "call_round_{d}", .{round_index});
            defer gpa.free(call_id);
            payload = try toolCallSse(call_id);
        } else {
            payload = try textSse("done");
        }
    }

    const response = try std.fmt.allocPrint(
        gpa,
        "HTTP/1.1 {d} {s}\r\n" ++
            "Content-Type: {s}\r\n" ++
            "Content-Length: {d}\r\n" ++
            "Connection: close\r\n" ++
            "\r\n",
        .{ status, reasonPhrase(status), content_type, payload.len },
    );
    defer gpa.free(response);

    var wbuf: [8 * 1024]u8 = undefined;
    var sw = stream.writer(stub.io, &wbuf);
    try sw.interface.writeAll(response);
    try sw.interface.writeAll(payload);
    try sw.interface.flush();
}

/// OpenAI-style SSE stream carrying a plain assistant message.
/// Python's `_text_sse`.
fn textSse(text: []const u8) ![]u8 {
    return std.fmt.allocPrint(
        gpa,
        "data: {{\"id\":\"chatcmpl-stub-text\",\"object\":\"chat.completion.chunk\",\"model\":\"stub-model\",\"choices\":[{{\"index\":0,\"delta\":{{\"role\":\"assistant\",\"content\":\"{s}\"}},\"finish_reason\":null}}]}}\n\n" ++
            "data: {{\"id\":\"chatcmpl-stub-text\",\"object\":\"chat.completion.chunk\",\"model\":\"stub-model\",\"choices\":[{{\"index\":0,\"delta\":{{}},\"finish_reason\":\"stop\"}}]}}\n\n" ++
            "data: [DONE]\n\n",
        .{text},
    );
}

/// One tool-call round-trip. Python's `_tool_call_sse`.
fn toolCallSse(call_id: []const u8) ![]u8 {
    const arguments = "{\\\"path\\\":\\\"AGENTS.md\\\",\\\"limit\\\":1}";
    return std.fmt.allocPrint(
        gpa,
        "data: {{\"id\":\"chatcmpl-stub-tool\",\"object\":\"chat.completion.chunk\",\"model\":\"stub-model\",\"choices\":[{{\"index\":0,\"delta\":{{\"role\":\"assistant\",\"content\":null,\"tool_calls\":[{{\"index\":0,\"id\":\"{s}\",\"type\":\"function\",\"function\":{{\"name\":\"read_file\",\"arguments\":\"{s}\"}}}}]}},\"finish_reason\":null}}]}}\n\n" ++
            "data: {{\"id\":\"chatcmpl-stub-tool\",\"object\":\"chat.completion.chunk\",\"model\":\"stub-model\",\"choices\":[{{\"index\":0,\"delta\":{{}},\"finish_reason\":\"tool_calls\"}}]}}\n\n" ++
            "data: [DONE]\n\n",
        .{ call_id, arguments },
    );
}

fn reasonPhrase(status: u16) []const u8 {
    return switch (status) {
        200 => "OK",
        503 => "Service Unavailable",
        else => "Status",
    };
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

/// Point the server's active profile at this run's stub. Python's
/// config-PUT preamble.
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

/// Queue one user message on the session. Python's `_send_turn`.
fn sendTurn(h: *Harness, message: []const u8, profile: []const u8, allowed_tools: []const u8) !void {
    const cwd = h.temp_dir;
    const body = try std.fmt.allocPrint(
        gpa,
        "{{\"session_id\":\"{s}\",\"queue_message\":\"{s}\",\"cwd_session\":\"{s}\"," ++
            "\"allowed_tools\":\"{s}\",\"image_urls\":\"\",\"selected_profile_model\":\"{s}\"," ++
            "\"is_auto_retry_until_stop\":\"\"}}",
        .{ SESSION_ID, message, cwd, allowed_tools, profile },
    );
    defer gpa.free(body);

    var r = try h.http(io, .POST, "/api/llm/session", .{
        .json_body = body,
        .expect = &.{ 200, 201, 500 },
        .timeout_s = 30.0,
    });
    defer r.deinit();
}

/// `(sessions.name, workspace_item_tasks.name)` for the session.
/// Python's `_read_names`. Both are owned optionals; null when the row
/// (or the column) is absent.
const Names = struct {
    session: ?[]u8 = null,
    task: ?[]u8 = null,

    fn deinit(self: *Names) void {
        if (self.session) |s| gpa.free(s);
        if (self.task) |t| gpa.free(t);
        self.* = .{};
    }
};

/// Skip unless a `sqlite3` CLI is present.
fn requireSqlite3Cli() !void {
    const res = std.process.run(gpa, io, .{
        .argv = &.{ "sqlite3", "-json", ":memory:", "SELECT 1 AS probe;" },
    }) catch {
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
    if (!ok) return error.SkipZigTest;
}

fn readNames(h: *Harness) !Names {
    const db_path = try harness.harnessPath(gpa, h.temp_dir, &.{ ".config", "pabrik", "agent.db" });
    defer gpa.free(db_path);

    const sql = try std.fmt.allocPrint(
        gpa,
        "SELECT s.name AS name, t.name AS task_name FROM sessions s " ++
            "LEFT JOIN workspace_item_tasks t ON t.id = s.id WHERE s.id = '{s}';",
        .{SESSION_ID},
    );
    defer gpa.free(sql);

    const res = std.process.run(gpa, io, .{
        .argv = &.{ "sqlite3", "-cmd", ".timeout 5000", "-json", db_path, sql },
    }) catch |err| {
        std.debug.print("sqlite3 did not spawn: {s}\n", .{@errorName(err)});
        return error.SkipZigTest;
    };
    defer {
        gpa.free(res.stdout);
        gpa.free(res.stderr);
    }
    switch (res.term) {
        .exited => |c| if (c != 0) {
            std.debug.print("sqlite3 exited {d}: {s}\n", .{ c, res.stderr });
            return error.TestUnexpectedResult;
        },
        else => return error.TestUnexpectedResult,
    }

    var names: Names = .{};
    errdefer names.deinit();
    const trimmed = std.mem.trim(u8, res.stdout, " \t\r\n");
    if (trimmed.len == 0 or std.mem.eql(u8, trimmed, "[]")) return names;

    const parsed = std.json.parseFromSlice(std.json.Value, gpa, trimmed, .{}) catch |err| {
        std.debug.print("sqlite3 output did not parse ({s}): {s}\n", .{ @errorName(err), res.stdout });
        return error.TestUnexpectedResult;
    };
    defer parsed.deinit();
    const rows = switch (parsed.value) {
        .array => |a| a,
        else => return error.TestUnexpectedResult,
    };
    if (rows.items.len == 0) return names;
    const row = switch (rows.items[0]) {
        .object => |o| o,
        else => return error.TestUnexpectedResult,
    };
    if (row.get("name")) |v| {
        if (v == .string) names.session = try gpa.dupe(u8, v.string);
    }
    if (row.get("task_name")) |v| {
        if (v == .string) names.task = try gpa.dupe(u8, v.string);
    }
    return names;
}

fn sessionNameEquals(names: *const Names, want: []const u8) bool {
    const s = names.session orelse return false;
    return std.mem.eql(u8, s, want);
}

fn sessionNameIsPlaceholder(names: *const Names) bool {
    const s = names.session orelse return false;
    return std.mem.eql(u8, s, "New Chat") or std.mem.eql(u8, s, "New Session");
}

// ============================================================================
// Tests
// ============================================================================

// Turn 1's name call is rejected; turn 2 must still name the session.
test "failed_auto_name_call_is_retried_on_the_next_turn" {
    try harness.requirePabrikBin(io, gpa);
    try requireSqlite3Cli();

    var stub: Stub = undefined;
    try stub.start(0, false);
    defer stub.deinit();

    var h = try Harness.boot(io, gpa, .{ .stub_llm_profile = true });
    defer h.deinit(io) catch |err| {
        std.debug.print("teardown: {s}\n", .{@errorName(err)});
    };

    const profile = "autoname-stub";
    try useStubProfile(&h, stub.port, profile);

    // ── Turn 1: the name call fails (HTTP 503), the main turn runs.
    try sendTurn(&h, "please fix the login bug on mobile", profile, "");

    // Wait until turn 1 has actually reached the stub's NAME endpoint.
    {
        const deadline = nowMs() + 60_000;
        while (stub.nameCallCount() < 1 and nowMs() < deadline) sleepMs(100);
        if (stub.nameCallCount() < 1) {
            const tail = try h.tailLog(io, gpa, 50);
            defer gpa.free(tail);
            std.debug.print("turn 1 never attempted a session-name call — this run proved nothing. log tail:\n{s}\n", .{tail});
            return error.TestUnexpectedResult;
        }
    }
    // The rejected name call must leave the placeholder in place.
    {
        const deadline = nowMs() + 60_000;
        var first: Names = .{};
        defer first.deinit();
        var seen = false;
        while (nowMs() < deadline) {
            var n = try readNames(&h);
            if (n.session != null) {
                first.deinit();
                first = n;
                seen = true;
                break;
            }
            n.deinit();
            if (!h.health(io)) break;
            sleepMs(250);
        }
        if (!seen) {
            std.debug.print("session row never appeared after turn 1\n", .{});
            return error.TestUnexpectedResult;
        }
        if (!sessionNameIsPlaceholder(&first)) {
            const tail = try h.tailLog(io, gpa, 50);
            defer gpa.free(tail);
            std.debug.print(
                "turn 1's name call was rejected with 503, so the session must still be a placeholder; got {s}\n--- log tail ---\n{s}\n",
                .{ first.session orelse "(null)", tail },
            );
            return error.TestUnexpectedResult;
        }
        if (stub.nameCallCount() != 1) {
            std.debug.print("expected exactly 1 name attempt in turn 1, got {d}\n", .{stub.nameCallCount()});
            return error.TestUnexpectedResult;
        }
    }

    // ── Turn 2: the name call now succeeds, and the placeholder gate
    //    must let it through.
    try sendTurn(&h, "any update on that?", profile, "");

    {
        const deadline = nowMs() + 60_000;
        var final: Names = .{};
        defer final.deinit();
        var ok = false;
        while (nowMs() < deadline) {
            var n = try readNames(&h);
            if (sessionNameEquals(&n, GENERATED_NAME)) {
                final.deinit();
                final = n;
                ok = true;
                break;
            }
            n.deinit();
            if (!h.health(io)) break;
            sleepMs(250);
        }
        if (!ok) {
            const tail = try h.tailLog(io, gpa, 100);
            defer gpa.free(tail);
            std.debug.print(
                "the session is STILL a placeholder after the second turn: the failed auto-name call was never retried\nnames={s}\n--- log tail ---\n{s}\n",
                .{ final.session orelse "(null)", tail },
            );
            return error.TestUnexpectedResult;
        }
        // The rename cascades to the linked task row ONLY when one
        // exists (a plain chat session has no workspace_item_tasks row).
        if (final.task) |t| {
            if (!std.mem.eql(u8, t, GENERATED_NAME)) {
                std.debug.print("sessions.name was renamed but the task row was not: {s}\n", .{t});
                return error.TestUnexpectedResult;
            }
        }
    }

    if (stub.nameCallCount() < 2) {
        std.debug.print("expected a second session-name call on turn 2; saw {d}\n", .{stub.nameCallCount()});
        return error.TestUnexpectedResult;
    }
}

// A session that already has a real name must keep it.
test "existing_name_is_never_overwritten_by_the_generator" {
    try harness.requirePabrikBin(io, gpa);
    try requireSqlite3Cli();

    var stub: Stub = undefined;
    try stub.start(0, false);
    defer stub.deinit();

    var h = try Harness.boot(io, gpa, .{ .stub_llm_profile = true });
    defer h.deinit(io) catch |err| {
        std.debug.print("teardown: {s}\n", .{@errorName(err)});
    };

    const profile = "autoname-stub";
    try useStubProfile(&h, stub.port, profile);

    try sendTurn(&h, "first message", profile, "");
    {
        // Best-effort wait, mirroring the Python original: its
        // `_wait_for_name(..., GENERATED_NAME, 60.0)` return value is
        // DISCARDED (no assert).
        const deadline = nowMs() + 60_000;
        while (nowMs() < deadline) {
            var n = try readNames(&h);
            defer n.deinit();
            if (sessionNameEquals(&n, GENERATED_NAME)) break;
            if (!h.health(io)) break;
            sleepMs(250);
        }
    }

    // The user renames the chat by hand (the frontend's rename call).
    {
        const url = try std.fmt.allocPrint(gpa, "/api/llm/session/{s}", .{SESSION_ID});
        defer gpa.free(url);
        const body = "{\"name\":\"my hand-picked title\"}";
        var r = try h.http(io, .PUT, url, .{
            .json_body = body,
            .expect = &.{ 200, 204 },
        });
        defer r.deinit();
    }
    {
        var n = try readNames(&h);
        defer n.deinit();
        const got = n.session orelse {
            std.debug.print("session row missing after hand rename\n", .{});
            return error.TestUnexpectedResult;
        };
        if (!std.mem.eql(u8, got, "my hand-picked title")) {
            const tail = try h.tailLog(io, gpa, 50);
            defer gpa.free(tail);
            std.debug.print("hand rename did not land: {s}\n--- log tail ---\n{s}\n", .{ got, tail });
            return error.TestUnexpectedResult;
        }
    }

    const name_calls_before = stub.nameCallCount();
    const agent_calls_before = stub.agentCallCount();

    // A further turn must NOT call the generator again. Wait for the
    // turn-2 worker to demonstrably reach the stub BEFORE asserting.
    try sendTurn(&h, "second message", profile, "");
    {
        const deadline = nowMs() + 60_000;
        while (stub.agentCallCount() <= agent_calls_before and nowMs() < deadline) sleepMs(100);
        if (stub.agentCallCount() <= agent_calls_before) {
            std.debug.print("turn 2's main turn never reached the stub\n", .{});
            return error.TestUnexpectedResult;
        }
    }
    // Give a wrongly-running name call a beat to land after the turn.
    {
        const deadline = nowMs() + 2_000;
        while (stub.nameCallCount() <= name_calls_before and nowMs() < deadline) sleepMs(100);
    }

    {
        var n = try readNames(&h);
        defer n.deinit();
        const got = n.session orelse {
            std.debug.print("session row missing after turn 2\n", .{});
            return error.TestUnexpectedResult;
        };
        if (!std.mem.eql(u8, got, "my hand-picked title")) {
            std.debug.print("the auto-name generator overwrote an existing name: {s}\n", .{got});
            return error.TestUnexpectedResult;
        }
    }
    if (stub.nameCallCount() != name_calls_before) {
        std.debug.print("the generator ran again for an already-named session: {d} -> {d}\n", .{ name_calls_before, stub.nameCallCount() });
        return error.TestUnexpectedResult;
    }
}

// A failing name call must cost ONE LLM round-trip per turn, not one
// per tool-call iteration.
test "name_call_is_not_repeated_per_tool_call_iteration" {
    try harness.requirePabrikBin(io, gpa);
    try requireSqlite3Cli();

    var stub: Stub = undefined;
    try stub.start(3, true);
    defer stub.deinit();

    var h = try Harness.boot(io, gpa, .{ .stub_llm_profile = true });
    defer h.deinit(io) catch |err| {
        std.debug.print("teardown: {s}\n", .{@errorName(err)});
    };

    const profile = "autoname-stub";
    try useStubProfile(&h, stub.port, profile);

    try sendTurn(&h, "run three tool rounds please", profile, "read_file");

    // Wait until the turn has driven every scripted tool round.
    {
        const deadline = nowMs() + 90_000;
        while (stub.agentCallCount() < 4 and nowMs() < deadline) sleepMs(100);
        if (stub.agentCallCount() < 4) {
            const tail = try h.tailLog(io, gpa, 60);
            defer gpa.free(tail);
            std.debug.print(
                "the turn never reached the scripted tool rounds (agent calls={d}).\n--- log tail ---\n{s}\n",
                .{ stub.agentCallCount(), tail },
            );
            return error.TestUnexpectedResult;
        }
    }

    if (stub.nameCallCount() != 1) {
        std.debug.print(
            "the auto-name call ran {d} times for ONE turn of {d} LLM requests — the per-iteration bound is missing\n",
            .{ stub.nameCallCount(), stub.agentCallCount() },
        );
        return error.TestUnexpectedResult;
    }
}
