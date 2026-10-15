//! Wire test: an openai-style CHAT turn must NOT carry the non-standard
//! `thinking` / `enable_thinking` request params.

const std = @import("std");
const testing = std.testing;
const harness = @import("harness.zig");
const Harness = harness.Harness;
const gpa = testing.allocator;
const io = testing.io;

const Io = std.Io;

/// The OpenAI chat-completions SSE transcript the stub replays verbatim.
const SSE_STREAM =
    "data: {\"id\":\"chatcmpl-1\",\"object\":\"chat.completion.chunk\"," ++
    "\"choices\":[{\"index\":0,\"delta\":{\"role\":\"assistant\",\"content\":\"\"}," ++
    "\"finish_reason\":null}]}\n" ++
    "\n" ++
    "data: {\"id\":\"chatcmpl-1\",\"object\":\"chat.completion.chunk\"," ++
    "\"choices\":[{\"index\":0,\"delta\":{\"content\":\"hello from stub\"}," ++
    "\"finish_reason\":null}]}\n" ++
    "\n" ++
    "data: {\"id\":\"chatcmpl-1\",\"object\":\"chat.completion.chunk\"," ++
    "\"choices\":[{\"index\":0,\"delta\":{},\"finish_reason\":\"stop\"}]}\n" ++
    "\n" ++
    "data: [DONE]\n" ++
    "\n";

/// Cap on the recorded request body — a runaway client must not grow the
/// accumulation without bound.
const MAX_BODY_BYTES = 1 << 20;

/// One recorded upstream request body. Owned by the Stub.
const Recorded = struct {
    body: []u8,

    fn deinit(self: *Recorded) void {
        gpa.free(self.body);
    }
};

/// A configurable one-request-at-a-time stub LLM upstream that records
/// request BODIES.
const Stub = struct {
    io: Io,
    port: u16,
    server: Io.net.Server,
    thread: std.Thread,
    stop: std.atomic.Value(bool) = .init(false),
    /// Guards `reqs`; the serve thread appends while the test reads.
    /// `std.Io.Mutex`, not `std.Thread.Mutex`: Zig 0.16 deleted the latter,
    /// and the replacement takes the `Io` handle for its contended path.
    mutex: Io.Mutex = .init,
    reqs: std.ArrayList(Recorded) = .empty,

    /// Bind and start serving on `stub`. An OUT-PARAMETER, and that is
    /// load-bearing.
    fn start(stub: *Stub) !void {
        stub.* = .{
            .io = io,
            .port = 0,
            .server = undefined,
            .thread = undefined,
        };
        stub.port = try harness.findFreePortRandom(gpa);
        const addr: Io.net.IpAddress = .{ .ip4 = .loopback(stub.port) };
        stub.server = try addr.listen(io, .{ .reuse_address = true });
        errdefer stub.server.deinit(io);
        stub.thread = try std.Thread.spawn(.{}, serve, .{stub});
    }

    /// Wake the blocked `accept`, join, and free.
    fn deinit(self: *Stub) void {
        self.stop.store(true, .release);

        const addr: Io.net.IpAddress = .{ .ip4 = .loopback(self.port) };
        if (addr.connect(self.io, .{ .mode = .stream })) |conn| {
            var c = conn;
            c.close(self.io);
        } else |_| {
            // Listener already gone: `accept` returned an error and the
            // serve loop has exited. Nothing to wake.
        }

        self.thread.join();
        self.server.deinit(self.io);
        for (self.reqs.items) |*r| r.deinit();
        self.reqs.deinit(gpa);
    }

    /// Copy every recorded body out. Owned by the caller.
    fn snapshot(self: *Stub) !std.ArrayList(Recorded) {
        var out: std.ArrayList(Recorded) = .empty;
        errdefer {
            for (out.items) |*r| r.deinit();
            out.deinit(gpa);
        }
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        for (self.reqs.items) |r| {
            try out.append(gpa, .{ .body = try gpa.dupe(u8, r.body) });
        }
        return out;
    }
};

fn serve(stub: *Stub) void {
    while (!stub.stop.load(.acquire)) {
        // `defer` inside a loop body runs at the end of THAT iteration,
        // so each accepted socket is closed before the next accept —
        // the connection is what the upstream does per POST.
        var stream = stub.server.accept(stub.io) catch break;
        defer stream.close(stub.io);
        if (stub.stop.load(.acquire)) break;
        handleRequest(stub, stream) catch {};
    }
}

/// Read one request (head AND body), record the body, reply with the SSE
/// transcript.
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
        if (head_acc.written().len > MAX_BODY_BYTES) break;
        if (std.mem.indexOf(u8, head_acc.written(), "\r\n\r\n")) |i| head_len = i + 4;
    }
    // No complete head: nothing worth recording, and nothing to answer.
    if (head_len == 0) return;

    var body_acc: Io.Writer.Allocating = .init(gpa);
    defer body_acc.deinit();
    var remaining = contentLength(head_acc.written()[0..head_len]);
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

    stub.mutex.lockUncancelable(stub.io);
    defer stub.mutex.unlock(stub.io);
    try stub.reqs.append(gpa, .{ .body = try gpa.dupe(u8, body_acc.written()) });

    const response = try std.fmt.allocPrint(
        gpa,
        "HTTP/1.1 200 OK\r\n" ++
            "Content-Type: text/event-stream\r\n" ++
            "Content-Length: {d}\r\n" ++
            "Connection: close\r\n" ++
            "\r\n" ++
            "{s}",
        .{ SSE_STREAM.len, SSE_STREAM },
    );
    defer gpa.free(response);

    var wbuf: [8 * 1024]u8 = undefined;
    var sw = stream.writer(stub.io, &wbuf);
    try sw.interface.writeAll(response);
    try sw.interface.flush();
}

/// Split an HTTP head into lines, skipping the request line.
fn headerLines(head: []const u8) std.mem.SplitIterator(u8, .sequence) {
    var it = std.mem.splitSequence(u8, head, "\r\n");
    _ = it.next(); // request line
    return it;
}

/// The value of `name` in a recorded head, or null.
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

/// `deadline = time.monotonic() + 60.0` — the assistant-reply budget.
const POLL_BUDGET_MS: i64 = 60_000;
/// `time.sleep(0.5)` between polls.
const POLL_INTERVAL_MS: i64 = 500;

/// Poll `GET /api/llm/session/<id>/messages` until an assistant message
/// with content lands. Returns an OWNED copy of its text.
fn waitForAssistantReply(h: *Harness, stub: *Stub, session_id: []const u8) ![]u8 {
    const path = try std.fmt.allocPrint(gpa, "/api/llm/session/{s}/messages", .{session_id});
    defer gpa.free(path);

    const params = [_]Harness.Param{
        .{ .name = "sort_by", .value = "created_at" },
        .{ .name = "direction", .value = "asc" },
        .{ .name = "limit", .value = "100" },
    };

    const deadline = std.Io.Timestamp.now(io, .awake).toMilliseconds() + POLL_BUDGET_MS;
    while (std.Io.Timestamp.now(io, .awake).toMilliseconds() < deadline) {
        var r = try h.http(io, .GET, path, .{ .params = &params, .expect = &.{200} });
        defer r.deinit();

        var doc = try r.json();
        defer doc.deinit();

        const messages = doc.array("messages") orelse
            return error.TestUnexpectedResult;
        for (messages.items) |m| {
            if (m != .object) continue;
            const obj = m.object;
            const role = obj.get("role") orelse continue;
            if (role != .string or !std.mem.eql(u8, role.string, "assistant")) continue;
            const content = obj.get("content") orelse continue;
            if (content != .string or content.string.len == 0) continue;
            return gpa.dupe(u8, content.string);
        }

        // Sleep the INTERVAL, capped by what is left of the budget — never
        // the whole remainder.
        const remaining = deadline - std.Io.Timestamp.now(io, .awake).toMilliseconds();
        if (remaining > 0) {
            const nap = @min(remaining, POLL_INTERVAL_MS);
            std.Io.sleep(io, .fromMilliseconds(nap), .awake) catch {};
        }
    }

    // Say WHICH failure it was: zero recorded requests means the profile
    // never pointed at the stub; a non-zero count means the turn reached the
    // upstream and the SSE transcript is what failed to parse.
    const tail = try h.tailLog(io, gpa, 40);
    defer gpa.free(tail);
    std.debug.print(
        "worker turn never produced an assistant message within {d}ms; " ++
            "the stub received {d} request(s)\n" ++
            "--- last 40 lines of the factory log ---\n{s}\n",
        .{ POLL_BUDGET_MS, stub.reqs.items.len, tail },
    );
    return error.TestUnexpectedResult;
}

/// Install an openai profile pointing at the stub and run one chat turn.
/// `thinking` is the profile's raw `thinking` string — the exact value the
/// Edit-profile modal's Thinking dropdown writes ("off" / "on" / "auto").
fn runTurnWithThinking(h: *Harness, stub: *Stub, thinking: []const u8, session_id: []const u8) !void {
    const stub_url = try std.fmt.allocPrint(gpa, "http://127.0.0.1:{d}/v1/chat/completions", .{stub.port});
    defer gpa.free(stub_url);

    // Mirrors the pabrik_config PUT shape. `url_style: "openai"` is what
    // selects `buildJsonOpenAIRequest` in `Agent.callStreaming`.
    const cfg_body = try std.fmt.allocPrint(gpa,
        \\{{"api_endpoint":"{s}","api_key":"sk-openai-test","model":"stub-model","url_style":"openai","profiles":{{"oa-stub":{{"model":"stub-model","base_url":"{s}","api_key":"sk-openai-test","url_style":"openai","thinking":"{s}"}}}},"active_profile":"oa-stub"}}
    , .{ stub_url, stub_url, thinking });
    defer gpa.free(cfg_body);
    {
        var r = try h.http(io, .PUT, "/api/config/pabrik", .{
            .json_body = cfg_body,
            .expect = &.{200},
        });
        defer r.deinit();
    }

    // The exact `sendChatMessage` wire (session_id + queue_message + profile
    // selection).
    const session_body = try std.fmt.allocPrint(gpa,
        \\{{"session_id":"{s}","queue_message":"say hi","cwd_session":"","image_urls":"","selected_profile_model":"oa-stub","is_auto_retry_until_stop":""}}
    , .{session_id});
    defer gpa.free(session_body);
    {
        // `expect=(200, 201, 500)` — the worker runs in the background,
        // so a 500 here can still be a healthy boot with a failed turn
        // that the poll below reports on.
        var r = try h.http(io, .POST, "/api/llm/session", .{
            .json_body = session_body,
            .expect = &.{ 200, 201, 500 },
        });
        defer r.deinit();
    }

    const assistant_text = try waitForAssistantReply(h, stub, session_id);
    defer gpa.free(assistant_text);
    if (std.mem.indexOf(u8, assistant_text, "hello from stub") == null) {
        std.debug.print("assistant reply should be the stub text, got: {s}\n", .{assistant_text});
        return error.TestUnexpectedResult;
    }
}

/// Assert that NO recorded request body carries `thinking` or
/// `enable_thinking`, and that the body IS valid JSON with the core
/// chat-completions fields present.
fn assertNoThinkingParams(stub: *Stub) !void {
    var seen = try stub.snapshot();
    defer {
        for (seen.items) |*r| r.deinit();
        seen.deinit(gpa);
    }
    if (seen.items.len == 0) {
        std.debug.print("stub upstream received no requests\n", .{});
        return error.TestUnexpectedResult;
    }
    for (seen.items, 0..) |r, i| {
        // Substring check first — cheap, and it catches the field under any
        // spelling (`"thinking"`, `"enable_thinking"`, and the
        // `reasoning_content` echo is a DIFFERENT field, so it must not trip
        if (std.mem.indexOf(u8, r.body, "\"thinking\"") != null or
            std.mem.indexOf(u8, r.body, "\"enable_thinking\"") != null)
        {
            std.debug.print(
                "request {d}: openai chat body must NOT carry thinking/enable_thinking, got: {s}\n",
                .{ i, r.body },
            );
            return error.TestUnexpectedResult;
        }

        // Parsed check — the authoritative one. A substring scan can be
        // fooled by a message whose CONTENT mentions the word; a parsed
        // key lookup cannot.
        var parsed = std.json.parseFromSlice(std.json.Value, gpa, r.body, .{}) catch {
            std.debug.print("request {d}: body is not valid JSON: {s}\n", .{ i, r.body });
            return error.TestUnexpectedResult;
        };
        defer parsed.deinit();
        const obj = switch (parsed.value) {
            .object => |o| o,
            else => {
                std.debug.print("request {d}: body is not a JSON object\n", .{i});
                return error.TestUnexpectedResult;
            },
        };
        if (obj.get("thinking") != null or obj.get("enable_thinking") != null) {
            std.debug.print(
                "request {d}: parsed body still carries thinking/enable_thinking: {s}\n",
                .{ i, r.body },
            );
            return error.TestUnexpectedResult;
        }
        // Positive controls: the same builder emits these, so their
        // presence proves the body is the real chat-completions shape
        // and the absence above is not "we recorded an empty request".
        if (obj.get("model") == null or obj.get("messages") == null) {
            std.debug.print(
                "request {d}: body is missing model/messages — not a chat-completions body: {s}\n",
                .{ i, r.body },
            );
            return error.TestUnexpectedResult;
        }
    }
}

// ============================================================================
// Test 1: thinking "off" — the reported bug
// ============================================================================

// The exact reported failure: Thinking = "Off" in the Edit-profile modal,
// openai body shape, strict upstream.
test "openai_chat_turn_thinking_off_omits_thinking_and_enable_thinking" {
    try harness.requirePabrikBin(io, gpa);

    // Registered FIRST so it runs LAST: the recorded bodies are read by
    // the assertions, and the serve thread must outlive the harness
    // teardown's shutdown of the child.
    var stub: Stub = undefined;
    try stub.start();
    defer stub.deinit();

    // `stub_llm_profile` is load-bearing, not a convenience: without a
    // configured profile the binary has no model to run the turn with, so
    // nothing ever reaches the stub.
    var h = try Harness.boot(io, gpa, .{ .stub_llm_profile = true });
    defer h.deinit(io) catch |err| {
        std.debug.print("teardown: {s}\n", .{@errorName(err)});
    };

    const session_id = try std.fmt.allocPrint(gpa, "sess_oa_thinkoff_{d}", .{
        std.Io.Timestamp.now(io, .real).toSeconds(),
    });
    defer gpa.free(session_id);

    try runTurnWithThinking(&h, &stub, "off", session_id);
    try assertNoThinkingParams(&stub);
}

// ============================================================================
// Test 2: thinking "on" — the control
// ============================================================================

// The positive control for Test 1's absence assertions.
test "openai_chat_turn_thinking_on_also_omits_thinking_and_enable_thinking" {
    try harness.requirePabrikBin(io, gpa);

    var stub: Stub = undefined;
    try stub.start();
    defer stub.deinit();

    var h = try Harness.boot(io, gpa, .{ .stub_llm_profile = true });
    defer h.deinit(io) catch |err| {
        std.debug.print("teardown: {s}\n", .{@errorName(err)});
    };

    const session_id = try std.fmt.allocPrint(gpa, "sess_oa_thinkon_{d}", .{
        std.Io.Timestamp.now(io, .real).toSeconds(),
    });
    defer gpa.free(session_id);

    try runTurnWithThinking(&h, &stub, "on", session_id);
    try assertNoThinkingParams(&stub);
}

comptime {
    // Body-analysis barrier: an unreferenced function is never
    // type-checked, so a stdlib rename inside one would stay invisible
    // until some caller appeared.
    _ = Stub;
    _ = Stub.start;
    _ = Stub.deinit;
    _ = Stub.snapshot;
    _ = serve;
    _ = handleRequest;
    _ = headerLines;
    _ = headerValue;
    _ = contentLength;
    _ = waitForAssistantReply;
    _ = runTurnWithThinking;
    _ = assertNoThinkingParams;
    _ = Harness.boot;
}
