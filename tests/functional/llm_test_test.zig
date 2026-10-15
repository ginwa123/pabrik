// End-to-end functional test for `POST /api/llm/test` (the "Test" button on
// the Add/Edit profile modal).

const std = @import("std");
const testing = std.testing;
const harness = @import("harness.zig");
const Harness = harness.Harness;
const gpa = testing.allocator;
const io = testing.io;

const Io = std.Io;

/// Cap on the recorded request head — a runaway client must not grow the
/// accumulation without bound.
const MAX_HEAD_BYTES = 1 << 18;

// ============================================================================
// Stub upstream
// ============================================================================

/// One recorded upstream request. Owned by the Stub.
const Recorded = struct {
    head: []u8,
    body: []u8,

    fn deinit(self: *Recorded) void {
        gpa.free(self.head);
        gpa.free(self.body);
    }
};

/// A configurable one-request-at-a-time stub LLM upstream.
const Stub = struct {
    io: Io,
    port: u16,
    status: u16,
    payload: []const u8,
    server: Io.net.Server,
    thread: std.Thread,
    stop: std.atomic.Value(bool) = .init(false),
    /// Guards `reqs`; the serve thread appends while the test reads.
    /// `std.Io.Mutex`, not `std.Thread.Mutex`: Zig 0.16 deleted the latter,
    /// and the replacement takes the `Io` handle for its contended path.
    mutex: Io.Mutex = .init,
    reqs: std.ArrayList(Recorded) = .empty,
    /// REASONING-MODEL EMULATION. `0` (the default) answers every request
    /// with `payload` — a plain canned stub.
    reasoning_spend: u32 = 0,
    reasoning_payload: []const u8 = "",

    /// Bind and start serving on `stub`. An OUT-PARAMETER, and that is
    /// load-bearing.
    fn start(stub: *Stub, status: u16, payload: []const u8) !void {
        stub.* = .{
            .io = io,
            .port = 0,
            .status = status,
            .payload = payload,
            .server = undefined,
            .thread = undefined,
        };
        // `Io.net` has no getsockname — `Server` exposes only the socket and
        // the bound port is not readable back — so the port is picked the way
        // `Harness.boot` picks one for the child and then bound.
        stub.port = try harness.findFreePortRandom(gpa);
        const addr: Io.net.IpAddress = .{ .ip4 = .loopback(stub.port) };
        stub.server = try addr.listen(io, .{ .reuse_address = true });
        errdefer stub.server.deinit(io);
        stub.thread = try std.Thread.spawn(.{}, serve, .{stub});
    }

    /// Start a stub that behaves like a REASONING model: it answers with
    /// `payload` only when the request's output budget is larger than
    /// `reasoning_spend`, and with `reasoning_payload` otherwise.
    fn startReasoning(
        stub: *Stub,
        reasoning_spend: u32,
        reasoning_payload: []const u8,
        payload: []const u8,
    ) !void {
        try stub.start(200, payload);
        stub.reasoning_spend = reasoning_spend;
        stub.reasoning_payload = reasoning_payload;
    }

    /// The body to answer with. Plain `payload`, unless this is a reasoning
    /// stub whose `reasoning_spend` the request's budget fails to cover.
    fn payloadFor(self: *Stub, body: []const u8) []const u8 {
        if (self.reasoning_spend == 0) return self.payload;
        if (requestedBudget(body)) |budget| {
            if (budget > @as(i64, self.reasoning_spend)) return self.payload;
        }
        // No budget named at all counts as "not enough" — a provider that
        // lets the model think unbounded is not what this stub emulates.
        return self.reasoning_payload;
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

    /// Copy every recorded request out. Owned by the caller. Python read
    /// `server.state.last_*` — the LAST request — so the tests take
    /// `.items[len - 1]` from this snapshot.
    fn snapshot(self: *Stub) !std.ArrayList(Recorded) {
        var out: std.ArrayList(Recorded) = .empty;
        errdefer {
            for (out.items) |*r| r.deinit();
            out.deinit(gpa);
        }
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        for (self.reqs.items) |r| {
            try out.append(gpa, .{
                .head = try gpa.dupe(u8, r.head),
                .body = try gpa.dupe(u8, r.body),
            });
        }
        return out;
    }
};

fn serve(stub: *Stub) void {
    while (!stub.stop.load(.acquire)) {
        // `defer` inside a loop body runs at the end of THAT iteration,
        // so each accepted socket is closed before the next accept — the
        // connection is what the upstream does per POST.
        var stream = stub.server.accept(stub.io) catch break;
        defer stream.close(stub.io);
        if (stub.stop.load(.acquire)) break;
        handleRequest(stub, stream) catch {};
    }
}

/// Read one request (head AND body), record it, reply with the payload.
fn handleRequest(stub: *Stub, stream: Io.net.Stream) !void {
    var rbuf: [64 * 1024]u8 = undefined;
    var sr = stream.reader(stub.io, &rbuf);
    const r = &sr.interface;

    // HEAD AND BODY OVERLAP IN THE SOCKET BUFFER.
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
    // No complete head: nothing worth recording, and nothing to answer.
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

    stub.mutex.lockUncancelable(stub.io);
    defer stub.mutex.unlock(stub.io);
    try stub.reqs.append(gpa, .{
        .head = try gpa.dupe(u8, head),
        .body = try gpa.dupe(u8, body_acc.written()),
    });

    // A reasoning stub picks its answer from the request's budget; a plain
    // stub always sends `payload`.
    const payload = stub.payloadFor(body_acc.written());

    const response = try std.fmt.allocPrint(
        gpa,
        "HTTP/1.1 {d} {s}\r\n" ++
            "Content-Type: application/json\r\n" ++
            "Content-Length: {d}\r\n" ++
            "Connection: close\r\n" ++
            "\r\n" ++
            "{s}",
        .{ stub.status, reasonPhrase(stub.status), payload.len, payload },
    );
    defer gpa.free(response);

    var wbuf: [8 * 1024]u8 = undefined;
    var sw = stream.writer(stub.io, &wbuf);
    try sw.interface.writeAll(response);
    try sw.interface.flush();
}

/// The reason phrase Python's `BaseHTTPRequestHandler.send_response`
/// would have used for the statuses this suite stubs.
fn reasonPhrase(status: u16) []const u8 {
    return switch (status) {
        200 => "OK",
        400 => "Bad Request",
        401 => "Unauthorized",
        403 => "Forbidden",
        429 => "Too Many Requests",
        500 => "Internal Server Error",
        else => "Status",
    };
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

fn hasHeader(head: []const u8, name: []const u8) bool {
    var it = headerLines(head);
    while (it.next()) |line| {
        if (line.len == 0) break;
        const colon = std.mem.indexOfScalar(u8, line, ':') orelse continue;
        if (std.ascii.eqlIgnoreCase(std.mem.trim(u8, line[0..colon], " \t"), name)) return true;
    }
    return false;
}

fn contentLength(head: []const u8) usize {
    const v = headerValue(head, "content-length") orelse return 0;
    return std.fmt.parseInt(usize, v, 10) catch 0;
}

/// The output budget a request asked for: `max_output_tokens` (Responses
/// API) or `max_tokens` (chat completions / Anthropic). Null when the
/// request carries neither or the body is not JSON.
fn requestedBudget(body: []const u8) ?i64 {
    var parsed = std.json.parseFromSlice(std.json.Value, gpa, body, .{}) catch return null;
    defer parsed.deinit();
    const root = switch (parsed.value) {
        .object => |o| o,
        else => return null,
    };
    const v = root.get("max_output_tokens") orelse root.get("max_tokens") orelse return null;
    return switch (v) {
        .integer => |i| i,
        else => null,
    };
}

/// Every recorded request's output budget, oldest first. Owned.
fn stubBudgets(stub: *Stub) !std.ArrayList(i64) {
    var seen = try stub.snapshot();
    defer {
        for (seen.items) |*r| r.deinit();
        seen.deinit(gpa);
    }
    var out: std.ArrayList(i64) = .empty;
    errdefer out.deinit(gpa);
    for (seen.items) |r| {
        try out.append(gpa, requestedBudget(r.body) orelse 0);
    }
    return out;
}

/// Python's `_stub_body`: the last request's body, parsed.
fn stubBody(stub: *Stub) !std.json.Parsed(std.json.Value) {
    var seen = try stub.snapshot();
    defer {
        for (seen.items) |*r| r.deinit();
        seen.deinit(gpa);
    }
    if (seen.items.len == 0) {
        std.debug.print("stub upstream received no requests\n", .{});
        return error.TestUnexpectedResult;
    }
    return std.json.parseFromSlice(std.json.Value, gpa, seen.items[seen.items.len - 1].body, .{});
}

/// Python's `state.last_headers`: the last request's head.
fn stubHead(stub: *Stub) ![]u8 {
    var seen = try stub.snapshot();
    defer {
        for (seen.items) |*r| r.deinit();
        seen.deinit(gpa);
    }
    if (seen.items.len == 0) {
        std.debug.print("stub upstream received no requests\n", .{});
        return error.TestUnexpectedResult;
    }
    return gpa.dupe(u8, seen.items[seen.items.len - 1].head);
}

// ============================================================================
// Helpers
// ============================================================================

/// `POST /api/llm/test`; the endpoint always returns HTTP 200 (failure
/// surfaces as `ok: false`). Python's `_post_test`.
fn postTest(h: *Harness, body: []const u8) !harness.Response {
    return h.http(io, .POST, "/api/llm/test", .{
        .json_body = body,
        .expect = &.{200},
        .timeout_s = 30.0,
    });
}

/// Python's `assert result.get("ok") is False` — a missing key is a
/// failure, and `ok` must be exactly the JSON boolean false.
fn expectNotOk(doc: *const harness.Json, raw: []const u8) !void {
    if (doc.boolean("ok") != false) {
        std.debug.print("expected ok:false, got: {s}\n", .{raw});
        return error.TestUnexpectedResult;
    }
}

fn expectOk(doc: *const harness.Json, raw: []const u8) !void {
    if (doc.boolean("ok") != true) {
        std.debug.print("unexpected response: {s}\n", .{raw});
        return error.TestUnexpectedResult;
    }
}

fn expectReply(doc: *const harness.Json, want: []const u8) !void {
    const got = doc.str("reply") orelse {
        std.debug.print("response has no `reply`\n", .{});
        return error.TestUnexpectedResult;
    };
    if (!std.mem.eql(u8, got, want)) {
        std.debug.print("reply = \"{s}\", expected \"{s}\"\n", .{ got, want });
        return error.TestUnexpectedResult;
    }
}

/// Case-insensitive `in` over a haystack — Python's
/// `"model" in result.get("error","").lower()`.
fn containsIgnoreCase(haystack: []const u8, needle_lower: []const u8) bool {
    if (needle_lower.len > haystack.len) return false;
    var i: usize = 0;
    while (i + needle_lower.len <= haystack.len) : (i += 1) {
        if (std.ascii.eqlIgnoreCase(haystack[i..][0..needle_lower.len], needle_lower)) return true;
    }
    return false;
}

/// The probe's `base_url` for this run's stub port. Owned.
fn stubBaseUrl(port: u16, suffix: []const u8) ![]u8 {
    return std.fmt.allocPrint(gpa, "http://127.0.0.1:{d}{s}", .{ port, suffix });
}

/// The four-field probe body the frontend's Test button sends.
fn probeBody(model: []const u8, base_url: []const u8, api_key: []const u8, url_style: []const u8) ![]u8 {
    return std.fmt.allocPrint(
        gpa,
        "{{\"model\":\"{s}\",\"base_url\":\"{s}\",\"api_key\":\"{s}\",\"url_style\":\"{s}\"}}",
        .{ model, base_url, api_key, url_style },
    );
}

/// Canonical chat-completions reply.
const CHATCMPL_OK =
    \\{"id":"chatcmpl-1","choices":[{"message":{"role":"assistant","content":"ok"},"finish_reason":"stop"}]}
;

/// Canonical Anthropic `content[]` reply.
const MSG_OK =
    \\{"id":"msg_1","content":[{"type":"text","text":"ok"}],"stop_reason":"end_turn"}
;

/// Canonical Responses-API `output[]` reply.
const RESP_OK =
    \\{"id":"resp_1","output":[{"type":"message","content":[{"type":"output_text","text":"ok"}]}]}
;

/// What a reasoning model returns when its hidden reasoning consumed the
/// whole output budget: `status: "incomplete"`, no `message` item, and so no
/// `output_text` for the probe to show.
const CHATCMPL_TRUNCATED =
    \\{"id":"chatcmpl-1","choices":[{"message":{"role":"assistant","content":""},"finish_reason":"length"}]}
;

const RESP_REASONING_ONLY =
    \\{"id":"resp_6accc040156123a58d294be8e","object":"response","created_at":1791803456,"status":"incomplete","parallel_tool_calls":true,"temperature":1,"top_p":1,"max_output_tokens":16,"background":false,"incomplete_details":{"reason":"max_output_tokens"},"output":[{"id":"rs_1","type":"reasoning","summary":[]}],"usage":{"input_tokens":11,"output_tokens":16,"total_tokens":27}}
;

// ============================================================================
// Test 1: openai success
// ============================================================================

// Stub answers a chat-completions payload; the probe returns
// `{ok: true, reply: "ok"}` and the stub saw Bearer auth + prompt.
test "llm_test_openai_success_returns_reply" {
    try harness.requirePabrikBin(io, gpa);

    var stub: Stub = undefined;
    try stub.start(200, CHATCMPL_OK);
    defer stub.deinit();

    var h = try Harness.boot(io, gpa, .{ .stub_llm_profile = true });
    defer h.deinit(io) catch |err| {
        std.debug.print("teardown: {s}\n", .{@errorName(err)});
    };

    const base_url = try stubBaseUrl(stub.port, "/v1/chat/completions");
    defer gpa.free(base_url);
    const body = try probeBody("stub-model", base_url, "sk-test-stub", "openai");
    defer gpa.free(body);

    var r = try postTest(&h, body);
    defer r.deinit();
    var doc = try r.json();
    defer doc.deinit();

    try expectOk(&doc, r.body);
    {
        const model = doc.str("model") orelse {
            std.debug.print("response has no `model`: {s}\n", .{r.body});
            return error.TestUnexpectedResult;
        };
        if (!std.mem.eql(u8, model, "stub-model")) {
            std.debug.print("model = \"{s}\", expected \"stub-model\"\n", .{model});
            return error.TestUnexpectedResult;
        }
    }
    try expectReply(&doc, "ok");
    // Python: `isinstance(result.get("latency_ms"), int)`.
    switch (doc.get("latency_ms") orelse {
        std.debug.print("response has no `latency_ms`: {s}\n", .{r.body});
        return error.TestUnexpectedResult;
    }) {
        .integer, .float => {},
        else => {
            std.debug.print("latency_ms is not a number: {s}\n", .{r.body});
            return error.TestUnexpectedResult;
        },
    }

    const head = try stubHead(&stub);
    defer gpa.free(head);
    const auth = headerValue(head, "authorization") orelse "";
    if (!std.mem.eql(u8, auth, "Bearer sk-test-stub")) {
        std.debug.print("openai style must send Bearer auth, got: {s}\n", .{head});
        return error.TestUnexpectedResult;
    }

    var sent = try stubBody(&stub);
    defer sent.deinit();
    const sent_root = switch (sent.value) {
        .object => |o| o,
        else => return error.TestUnexpectedResult,
    };
    {
        const model = switch (sent_root.get("model") orelse return error.TestUnexpectedResult) {
            .string => |s| s,
            else => return error.TestUnexpectedResult,
        };
        if (!std.mem.eql(u8, model, "stub-model")) {
            std.debug.print("sent model = \"{s}\", expected \"stub-model\"\n", .{model});
            return error.TestUnexpectedResult;
        }
    }
    // Python searched `json.dumps(sent)`; searching the recorded bytes is
    // a strict superset of that (the needle has nothing to escape).
    const raw = try std.json.Stringify.valueAlloc(gpa, sent.value, .{});
    defer gpa.free(raw);
    if (std.mem.indexOf(u8, raw, "Reply with exactly: ok") == null) {
        std.debug.print("probe prompt not found in the sent body: {s}\n", .{raw});
        return error.TestUnexpectedResult;
    }
    // Python: `sent.get("stream") is False` — an ABSENT key is a failure.
    if (sent_root.get("stream") == null or sent_root.get("stream").? != .bool or
        sent_root.get("stream").?.bool)
    {
        std.debug.print("sent body must carry stream:false, got: {s}\n", .{raw});
        return error.TestUnexpectedResult;
    }
}

// ============================================================================
// Test 2: anthropic success
// ============================================================================

// Anthropic-style probe sends `x-api-key` (not Bearer) and parses the
// `content[]` text block.
test "llm_test_anthropic_success_uses_x_api_key" {
    try harness.requirePabrikBin(io, gpa);

    var stub: Stub = undefined;
    try stub.start(200, MSG_OK);
    defer stub.deinit();

    var h = try Harness.boot(io, gpa, .{ .stub_llm_profile = true });
    defer h.deinit(io) catch |err| {
        std.debug.print("teardown: {s}\n", .{@errorName(err)});
    };

    const base_url = try stubBaseUrl(stub.port, "/v1/messages");
    defer gpa.free(base_url);
    const body = try probeBody("stub-claude", base_url, "sk-ant-test", "anthropic");
    defer gpa.free(body);

    var r = try postTest(&h, body);
    defer r.deinit();
    var doc = try r.json();
    defer doc.deinit();

    try expectOk(&doc, r.body);
    try expectReply(&doc, "ok");

    const head = try stubHead(&stub);
    defer gpa.free(head);
    const api_key = headerValue(head, "x-api-key") orelse "";
    if (!std.mem.eql(u8, api_key, "sk-ant-test")) {
        std.debug.print("anthropic style must send x-api-key, got: {s}\n", .{head});
        return error.TestUnexpectedResult;
    }
    if (hasHeader(head, "authorization")) {
        std.debug.print("anthropic style must NOT send Bearer auth, got: {s}\n", .{head});
        return error.TestUnexpectedResult;
    }

    var sent = try stubBody(&stub);
    defer sent.deinit();
    const sent_root = switch (sent.value) {
        .object => |o| o,
        else => return error.TestUnexpectedResult,
    };
    const max_tokens = switch (sent_root.get("max_tokens") orelse {
        std.debug.print("sent body has no `max_tokens`\n", .{});
        return error.TestUnexpectedResult;
    }) {
        .integer => |i| i,
        else => {
            std.debug.print("`max_tokens` is not an integer\n", .{});
            return error.TestUnexpectedResult;
        },
    };
    // The Anthropic Messages API REQUIRES `max_tokens`; its value is the
    // probe's reasoning-safe budget (asserted behaviourally by the
    // reasoning-model tests below, not as a literal here).
    if (max_tokens <= 0) {
        std.debug.print("max_tokens = {d}, expected a positive budget\n", .{max_tokens});
        return error.TestUnexpectedResult;
    }
}

// ============================================================================
// Test 3: openai-response success
// ============================================================================

// Responses-style probe sends `input` and parses `output[]` message
// items.
test "llm_test_openai_response_success_parses_output_items" {
    try harness.requirePabrikBin(io, gpa);

    var stub: Stub = undefined;
    try stub.start(200, RESP_OK);
    defer stub.deinit();

    var h = try Harness.boot(io, gpa, .{ .stub_llm_profile = true });
    defer h.deinit(io) catch |err| {
        std.debug.print("teardown: {s}\n", .{@errorName(err)});
    };

    const base_url = try stubBaseUrl(stub.port, "/v1/responses");
    defer gpa.free(base_url);
    const body = try probeBody("stub-gpt", base_url, "sk-test-stub", "openai-response");
    defer gpa.free(body);

    var r = try postTest(&h, body);
    defer r.deinit();
    var doc = try r.json();
    defer doc.deinit();

    try expectOk(&doc, r.body);
    try expectReply(&doc, "ok");

    var sent = try stubBody(&stub);
    defer sent.deinit();
    const sent_root = switch (sent.value) {
        .object => |o| o,
        else => return error.TestUnexpectedResult,
    };
    const input = switch (sent_root.get("input") orelse {
        std.debug.print("sent body has no `input`\n", .{});
        return error.TestUnexpectedResult;
    }) {
        .string => |s| s,
        else => {
            std.debug.print("`input` is not a string\n", .{});
            return error.TestUnexpectedResult;
        },
    };
    if (std.mem.indexOf(u8, input, "Reply with exactly: ok") == null) {
        std.debug.print("probe prompt not found in `input`: {s}\n", .{input});
        return error.TestUnexpectedResult;
    }
}

// ============================================================================
// Test 9: a reasoning model answers — the budget must cover the thinking
// ============================================================================

// REGRESSION, the reported bug: the Edit-profile Test button said "LLM server
// response did not contain a reply" for a profile that works in a real chat
// turn.
test "llm_test_reasoning_model_still_replies_when_probe_allows_for_thinking" {
    try harness.requirePabrikBin(io, gpa);

    var stub: Stub = undefined;
    // 800 tokens of thinking: comfortably more than the old 16-token probe,
    // comfortably less than any sane reasoning-safe budget.
    try stub.startReasoning(800, RESP_REASONING_ONLY, RESP_OK);
    defer stub.deinit();

    var h = try Harness.boot(io, gpa, .{ .stub_llm_profile = true });
    defer h.deinit(io) catch |err| {
        std.debug.print("teardown: {s}\n", .{@errorName(err)});
    };

    const base_url = try stubBaseUrl(stub.port, "/v1/responses");
    defer gpa.free(base_url);
    const body = try probeBody("stub-reasoning-model", base_url, "sk-test-stub", "openai-response");
    defer gpa.free(body);

    var r = try postTest(&h, body);
    defer r.deinit();
    var doc = try r.json();
    defer doc.deinit();

    try expectOk(&doc, r.body);
    try expectReply(&doc, "ok");
}

// The same bug one wire style over.
test "llm_test_reasoning_model_still_replies_on_chat_completions_style" {
    try harness.requirePabrikBin(io, gpa);

    var stub: Stub = undefined;
    try stub.startReasoning(800, CHATCMPL_TRUNCATED, CHATCMPL_OK);
    defer stub.deinit();

    var h = try Harness.boot(io, gpa, .{ .stub_llm_profile = true });
    defer h.deinit(io) catch |err| {
        std.debug.print("teardown: {s}\n", .{@errorName(err)});
    };

    const base_url = try stubBaseUrl(stub.port, "/v1/chat/completions");
    defer gpa.free(base_url);
    const body = try probeBody("stub-reasoning-chat", base_url, "sk-test-stub", "openai");
    defer gpa.free(body);

    var r = try postTest(&h, body);
    defer r.deinit();
    var doc = try r.json();
    defer doc.deinit();

    try expectOk(&doc, r.body);
    try expectReply(&doc, "ok");
}

// ============================================================================
// Test 10: a model that never gets to write text — say so, and try harder
// ============================================================================

// A model whose thinking always eats the budget (the stub is set to a spend
// no probe budget can exceed) must not come back as the misleading "LLM
// server response did not contain a reply" — that reads as "your key is
test "llm_test_reasoning_only_model_retries_then_names_the_budget" {
    try harness.requirePabrikBin(io, gpa);

    var stub: Stub = undefined;
    // No finite budget can cover this spend, so the FIRST body comes back
    // every time — i.e. the model never produces text at all.
    try stub.startReasoning(std.math.maxInt(u32), RESP_REASONING_ONLY, RESP_OK);
    defer stub.deinit();

    var h = try Harness.boot(io, gpa, .{ .stub_llm_profile = true });
    defer h.deinit(io) catch |err| {
        std.debug.print("teardown: {s}\n", .{@errorName(err)});
    };

    const base_url = try stubBaseUrl(stub.port, "/v1/responses");
    defer gpa.free(base_url);
    const body = try probeBody("stub-reasoning-only", base_url, "sk-test-stub", "openai-response");
    defer gpa.free(body);

    var r = try postTest(&h, body);
    defer r.deinit();
    var doc = try r.json();
    defer doc.deinit();

    try expectNotOk(&doc, r.body);

    const message = doc.str("error") orelse "";
    if (containsIgnoreCase(message, "did not contain a reply")) {
        std.debug.print(
            "a budget-exhausted reasoning model must not be reported as a missing reply: {s}\n",
            .{r.body},
        );
        return error.TestUnexpectedResult;
    }
    if (!containsIgnoreCase(message, "reasoning") and !containsIgnoreCase(message, "budget")) {
        std.debug.print("error should name the cause (reasoning/budget): {s}\n", .{r.body});
        return error.TestUnexpectedResult;
    }

    // Behaviour 1 on the wire: exactly two probes, the second one with more
    // room than the first. A single request would mean the probe never tried
    // harder; an identical budget would mean the retry is theatre.
    var budgets = try stubBudgets(&stub);
    defer budgets.deinit(gpa);
    if (budgets.items.len != 2) {
        std.debug.print("expected one retry (2 probes), got {d}\n", .{budgets.items.len});
        return error.TestUnexpectedResult;
    }
    if (budgets.items[1] <= budgets.items[0]) {
        std.debug.print(
            "retry must offer a bigger budget, got {d} then {d}\n",
            .{ budgets.items[0], budgets.items[1] },
        );
        return error.TestUnexpectedResult;
    }
}

// ============================================================================
// Test 4: validation failures (no stub needed)
// ============================================================================

test "llm_test_missing_model_returns_clear_error" {
    try harness.requirePabrikBin(io, gpa);

    var h = try Harness.boot(io, gpa, .{ .stub_llm_profile = true });
    defer h.deinit(io) catch |err| {
        std.debug.print("teardown: {s}\n", .{@errorName(err)});
    };

    const body = try probeBody("", "http://127.0.0.1:9/x", "sk-test-stub", "openai");
    defer gpa.free(body);

    var r = try postTest(&h, body);
    defer r.deinit();
    var doc = try r.json();
    defer doc.deinit();

    try expectNotOk(&doc, r.body);
    const message = doc.str("error") orelse "";
    if (!containsIgnoreCase(message, "model")) {
        std.debug.print("error does not mention `model`: {s}\n", .{r.body});
        return error.TestUnexpectedResult;
    }
}

test "llm_test_bad_style_returns_clear_error" {
    try harness.requirePabrikBin(io, gpa);

    var h = try Harness.boot(io, gpa, .{ .stub_llm_profile = true });
    defer h.deinit(io) catch |err| {
        std.debug.print("teardown: {s}\n", .{@errorName(err)});
    };

    const body = try probeBody("m", "http://127.0.0.1:9/x", "sk-test-stub", "weird-thing");
    defer gpa.free(body);

    var r = try postTest(&h, body);
    defer r.deinit();
    var doc = try r.json();
    defer doc.deinit();

    try expectNotOk(&doc, r.body);
    const message = doc.str("error") orelse "";
    if (!containsIgnoreCase(message, "url_style")) {
        std.debug.print("error does not mention `url_style`: {s}\n", .{r.body});
        return error.TestUnexpectedResult;
    }
}

// ============================================================================
// Test 6: unreachable upstream fails fast
// ============================================================================

// Closed port (connection refused) returns `{ok: false}` quickly.
// Port 1 is used because the kernel refuses it; never port 8081.
test "llm_test_unreachable_returns_send_failure" {
    try harness.requirePabrikBin(io, gpa);

    var h = try Harness.boot(io, gpa, .{ .stub_llm_profile = true });
    defer h.deinit(io) catch |err| {
        std.debug.print("teardown: {s}\n", .{@errorName(err)});
    };

    const body = try probeBody("m", "http://127.0.0.1:1/x", "sk-test-stub", "openai");
    defer gpa.free(body);

    // `Io.Timestamp.now(io, .awake)` is the monotonic clock — the analogue of
    // `time.monotonic()`. `.real` would let an NTP step backwards produce a
    // negative elapsed and pass the bound for the wrong reason.
    const started = Io.Timestamp.now(io, .awake).toMilliseconds();

    var r = try postTest(&h, body);
    defer r.deinit();
    var doc = try r.json();
    defer doc.deinit();

    const elapsed_ms = Io.Timestamp.now(io, .awake).toMilliseconds() - started;

    try expectNotOk(&doc, r.body);
    const message = doc.str("error") orelse "";
    if (message.len == 0) {
        std.debug.print("expected non-empty error, got: {s}\n", .{r.body});
        return error.TestUnexpectedResult;
    }
    if (elapsed_ms >= 30_000) {
        std.debug.print("probe took {d}ms (>30s timeout!)\n", .{elapsed_ms});
        return error.TestUnexpectedResult;
    }
}

// ============================================================================
// Test 7: upstream 401 surfaces status in details
// ============================================================================

// A 401 from upstream (e.g. revoked key) returns `{ok: false}` with
// `details` naming the status so the modal shows WHY.
test "llm_test_upstream_401_returns_status_in_details" {
    try harness.requirePabrikBin(io, gpa);

    var stub: Stub = undefined;
    try stub.start(401, "{\"error\":{\"message\":\"invalid key\",\"type\":\"auth\"}}");
    defer stub.deinit();

    var h = try Harness.boot(io, gpa, .{ .stub_llm_profile = true });
    defer h.deinit(io) catch |err| {
        std.debug.print("teardown: {s}\n", .{@errorName(err)});
    };

    const base_url = try stubBaseUrl(stub.port, "/v1/chat/completions");
    defer gpa.free(base_url);
    const body = try probeBody("stub-model", base_url, "sk-revoked", "openai");
    defer gpa.free(body);

    var r = try postTest(&h, body);
    defer r.deinit();
    var doc = try r.json();
    defer doc.deinit();

    try expectNotOk(&doc, r.body);
    const details = doc.str("details") orelse "";
    if (std.mem.indexOf(u8, details, "http 401") == null) {
        std.debug.print("details should name the status, got: {s}\n", .{r.body});
        return error.TestUnexpectedResult;
    }
}

// ============================================================================
// Test 8: probe sends x-opencode-session (all styles)
// ============================================================================

// Regression for the Edit-profile Test button 400
// `{"type":"error","error":{"type":"MissingSessionID",...}}`: the
// anthropic-style probe must carry `x-opencode-session` or Console Go rejects
test "llm_test_probe_sends_opencode_session_anthropic" {
    try harness.requirePabrikBin(io, gpa);

    var stub: Stub = undefined;
    try stub.start(200, MSG_OK);
    defer stub.deinit();

    var h = try Harness.boot(io, gpa, .{ .stub_llm_profile = true });
    defer h.deinit(io) catch |err| {
        std.debug.print("teardown: {s}\n", .{@errorName(err)});
    };

    const base_url = try stubBaseUrl(stub.port, "/v1/messages");
    defer gpa.free(base_url);
    const body = try probeBody("stub-claude", base_url, "sk-ant-test", "anthropic");
    defer gpa.free(body);

    var r = try postTest(&h, body);
    defer r.deinit();
    var doc = try r.json();
    defer doc.deinit();

    try expectOk(&doc, r.body);

    const head = try stubHead(&stub);
    defer gpa.free(head);
    // Python: `assert state.last_headers.get("x-opencode-session")` — a
    // TRUTHINESS check, so an absent header and an empty one fail alike.
    const sess_hdr = headerValue(head, "x-opencode-session") orelse "";
    if (sess_hdr.len == 0) {
        std.debug.print("anthropic probe must send x-opencode-session, got: {s}\n", .{head});
        return error.TestUnexpectedResult;
    }
}

// Same header contract for the openai style — the gateway may require it
// there too, and the extra header is ignored by direct providers.
test "llm_test_probe_sends_opencode_session_openai" {
    try harness.requirePabrikBin(io, gpa);

    var stub: Stub = undefined;
    try stub.start(200, CHATCMPL_OK);
    defer stub.deinit();

    var h = try Harness.boot(io, gpa, .{ .stub_llm_profile = true });
    defer h.deinit(io) catch |err| {
        std.debug.print("teardown: {s}\n", .{@errorName(err)});
    };

    const base_url = try stubBaseUrl(stub.port, "/v1/chat/completions");
    defer gpa.free(base_url);
    const body = try probeBody("stub-model", base_url, "sk-test-stub", "openai");
    defer gpa.free(body);

    var r = try postTest(&h, body);
    defer r.deinit();
    var doc = try r.json();
    defer doc.deinit();

    try expectOk(&doc, r.body);

    const head = try stubHead(&stub);
    defer gpa.free(head);
    const sess_hdr = headerValue(head, "x-opencode-session") orelse "";
    if (sess_hdr.len == 0) {
        std.debug.print("openai probe must send x-opencode-session, got: {s}\n", .{head});
        return error.TestUnexpectedResult;
    }
}

// Body-analysis barrier. An unreferenced helper is never type-checked, so
// a stdlib rename inside one stays invisible until a caller appears.
comptime {
    _ = MAX_HEAD_BYTES;
    _ = CHATCMPL_OK;
    _ = MSG_OK;
    _ = RESP_OK;
    _ = Recorded.deinit;
    _ = Stub.start;
    _ = Stub.deinit;
    _ = Stub.snapshot;
    _ = serve;
    _ = handleRequest;
    _ = reasonPhrase;
    _ = headerLines;
    _ = headerValue;
    _ = hasHeader;
    _ = contentLength;
    _ = stubBody;
    _ = stubHead;
    _ = postTest;
    _ = expectNotOk;
    _ = expectOk;
    _ = expectReply;
    _ = containsIgnoreCase;
    _ = stubBaseUrl;
    _ = probeBody;
    _ = RESP_REASONING_ONLY;
    _ = CHATCMPL_TRUNCATED;
    _ = Stub.startReasoning;
    _ = Stub.payloadFor;
    _ = requestedBudget;
    _ = stubBudgets;
}
