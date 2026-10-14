//! Wire test: `GET /api/llm/session/:session_id/usage` reports the cache hit
//! rate the provider actually reported.
//!
//! The `sessions` table stores no token column, so the endpoint DERIVES the
//! rate from one aggregate over `llm_history`. That makes the whole chain
//! load-bearing: the Anthropic SSE parser must fold `cache_read_input_tokens`
//! into `prompt_tokens` and persist it, and the aggregate must divide the two
//! sums. A unit test can only reach the aggregate; this suite drives a real
//! turn against a stub upstream and reads the number back off the wire.
//!
//! THE STUB UPSTREAM
//! -----------------
//! Same shape as `anthropic_chat_headers_test.zig`: an in-process listener on
//! a free loopback port that answers every POST with one Anthropic SSE
//! transcript. The transcript reports `input_tokens: 100` and
//! `cache_read_input_tokens: 900` on `message_start`, so every persisted row
//! carries prompt=1000 / cache_read=900 — a 90% hit rate, and one whose ratio
//! (9/10) holds no matter how many calls the turn makes (the auto-naming call
//! goes through the same stub).
//!
//! `Server.accept` is a blocking `accept4(2)` and closing a listening socket
//! does not wake a thread already blocked in it, so `stopStub` sets the stop
//! flag and then makes ONE throwaway self-connect to unblock the loop — see
//! the longer note in `anthropic_chat_headers_test.zig`.

const std = @import("std");
const testing = std.testing;
const harness = @import("harness.zig");
const Harness = harness.Harness;
const gpa = testing.allocator;
const io = testing.io;

const Io = std.Io;

/// The Anthropic SSE transcript the stub replays verbatim. The trailing blank
/// line after `message_stop` matters: the parser consumes event/data pairs,
/// and a truncated final event would make the assertions pass for a reason
/// that is not the usage contract.
const SSE_STREAM =
    "event: message_start\n" ++
    "data: {\"type\":\"message_start\",\"message\":{\"id\":\"msg_1\",\"type\":\"message\"," ++
    "\"role\":\"assistant\",\"content\":[],\"model\":\"stub-claude\",\"stop_reason\":null," ++
    "\"stop_sequence\":null,\"usage\":{\"input_tokens\":100,\"cache_read_input_tokens\":900," ++
    "\"output_tokens\":1}}}\n" ++
    "\n" ++
    "event: content_block_start\n" ++
    "data: {\"type\":\"content_block_start\",\"index\":0," ++
    "\"content_block\":{\"type\":\"text\",\"text\":\"\"}}\n" ++
    "\n" ++
    "event: content_block_delta\n" ++
    "data: {\"type\":\"content_block_delta\",\"index\":0," ++
    "\"delta\":{\"type\":\"text_delta\",\"text\":\"hello from stub\"}}\n" ++
    "\n" ++
    "event: content_block_stop\n" ++
    "data: {\"type\":\"content_block_stop\",\"index\":0}\n" ++
    "\n" ++
    // `output_tokens` > 0 is what makes the parser emit a usage chunk for the
    // delta, and the aggregator keeps the LAST usage chunk with total > 0 —
    // this one is what gets persisted.
    "event: message_delta\n" ++
    "data: {\"type\":\"message_delta\",\"delta\":{\"stop_reason\":\"end_turn\"," ++
    "\"stop_sequence\":null},\"usage\":{\"output_tokens\":10}}\n" ++
    "\n" ++
    "event: message_stop\n" ++
    "data: {\"type\":\"message_stop\"}\n" ++
    "\n";

/// A stub Anthropic SSE upstream served from a background thread.
const Stub = struct {
    io: Io,
    port: u16,
    server: Io.net.Server,
    thread: std.Thread,
    stop: std.atomic.Value(bool) = .init(false),
    /// Requests answered. Lets a failure say whether the turn ever reached the
    /// stub (0) or reached it and failed to parse (non-zero) — two very
    /// different bugs that otherwise read the same.
    served: std.atomic.Value(usize) = .init(0),
};

fn startStub(stub: *Stub) !void {
    stub.port = try harness.findFreePortRandom(gpa);
    const addr: Io.net.IpAddress = .{ .ip4 = .loopback(stub.port) };
    stub.server = try addr.listen(io, .{ .reuse_address = true });
    errdefer stub.server.deinit(io);
    stub.thread = try std.Thread.spawn(.{}, serveStub, .{stub});
}

/// Wake the blocked `accept`, join, and free. See the file header.
fn stopStub(stub: *Stub) void {
    stub.stop.store(true, .release);

    const addr: Io.net.IpAddress = .{ .ip4 = .loopback(stub.port) };
    if (addr.connect(stub.io, .{ .mode = .stream })) |conn| {
        var c = conn;
        c.close(stub.io);
    } else |_| {
        // Listener already gone: `accept` returned an error and the serve
        // loop has exited. Nothing to wake.
    }

    stub.thread.join();
    stub.server.deinit(stub.io);
}

fn serveStub(stub: *Stub) void {
    while (!stub.stop.load(.acquire)) {
        // `defer` inside a loop body runs at the end of THAT iteration, so
        // each accepted socket is closed before the next accept.
        var stream = stub.server.accept(stub.io) catch break;
        defer stream.close(stub.io);
        if (stub.stop.load(.acquire)) break;
        handleRequest(stub, stream) catch {};
    }
}

/// Read one request, drain its body, reply with the SSE transcript.
///
/// The head and the body overlap in the socket buffer, so everything read is
/// accumulated and only the `\r\n\r\n`-terminated prefix is treated as the
/// head — the naive version discards already-buffered body bytes and then
/// blocks in the drain waiting for bytes the client already sent.
fn handleRequest(stub: *Stub, stream: Io.net.Stream) !void {
    var rbuf: [64 * 1024]u8 = undefined;
    var sr = stream.reader(stub.io, &rbuf);
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
        if (acc.written().len > (1 << 18)) break;
        if (std.mem.indexOf(u8, acc.written(), "\r\n\r\n")) |i| head_len = i + 4;
    }
    if (head_len == 0) return;

    const head = acc.written()[0..head_len];
    var remaining = contentLength(head);
    if (acc.written().len > head_len) remaining -|= acc.written().len - head_len;
    while (remaining > 0) {
        r.fill(1) catch break;
        const b = r.buffered();
        if (b.len == 0) break;
        const take = @min(b.len, remaining);
        remaining -= take;
        r.toss(take);
    }

    _ = stub.served.fetchAdd(1, .monotonic);

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

const POLL_BUDGET_MS: i64 = 60_000;
const POLL_INTERVAL_MS: i64 = 500;

/// Poll `GET /api/llm/session/<id>/messages` until an assistant message with
/// content lands. Returns an OWNED copy of its text.
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

        const messages = doc.array("messages") orelse return error.TestUnexpectedResult;
        for (messages.items) |m| {
            if (m != .object) continue;
            const obj = m.object;
            const role = obj.get("role") orelse continue;
            if (role != .string or !std.mem.eql(u8, role.string, "assistant")) continue;
            const content = obj.get("content") orelse continue;
            if (content != .string or content.string.len == 0) continue;
            return gpa.dupe(u8, content.string);
        }

        const remaining = deadline - std.Io.Timestamp.now(io, .awake).toMilliseconds();
        if (remaining > 0) {
            std.Io.sleep(io, .fromMilliseconds(@min(remaining, POLL_INTERVAL_MS)), .awake) catch {};
        }
    }

    const tail = try h.tailLog(io, gpa, 40);
    defer gpa.free(tail);
    std.debug.print(
        "worker turn never produced an assistant message within {d}ms; the stub answered {d} request(s)\n" ++
            "--- last 40 lines of the factory log ---\n{s}\n",
        .{ POLL_BUDGET_MS, stub.served.load(.monotonic), tail },
    );
    return error.TestUnexpectedResult;
}

/// Install an Anthropic-style profile pointing at the stub. Mirrors the
/// `pabrik_config` PUT shape; `url_style: "anthropic"` is what selects the
/// Anthropic body + header path in `Agent.callStreaming`.
fn putAnthropicProfile(h: *Harness, stub_url: []const u8) !void {
    const cfg_body = try std.fmt.allocPrint(gpa,
        \\{{"api_endpoint":"{s}","api_key":"sk-ant-test","model":"stub-claude","url_style":"anthropic","profiles":{{"ant-stub":{{"model":"stub-claude","base_url":"{s}","api_key":"sk-ant-test","url_style":"anthropic"}}}},"active_profile":"ant-stub"}}
    , .{ stub_url, stub_url });
    defer gpa.free(cfg_body);

    var r = try h.http(io, .PUT, "/api/config/pabrik", .{
        .json_body = cfg_body,
        .expect = &.{200},
    });
    defer r.deinit();
}

fn uniqueSessionId(prefix: []const u8) ![]u8 {
    return std.fmt.allocPrint(gpa, "{s}_{d}", .{
        prefix,
        std.Io.Timestamp.now(io, .real).toSeconds(),
    });
}

fn usagePath(prefix: []const u8, session_id: []const u8) ![]u8 {
    return std.fmt.allocPrint(gpa, "{s}/session/{s}/usage", .{ prefix, session_id });
}

// A real Anthropic turn against the stub, then the rate read back off the wire.
test "session_usage_reports_the_cache_read_ratio_the_provider_reported" {
    try harness.requirePabrikBin(io, gpa);

    // Registered FIRST so it runs LAST: the serve thread must outlive the
    // harness teardown's shutdown of the child.
    var stub: Stub = .{
        .io = io,
        .port = 0,
        .server = undefined,
        .thread = undefined,
    };
    try startStub(&stub);
    defer stopStub(&stub);

    var h = try Harness.boot(io, gpa, .{ .stub_llm_profile = true });
    defer h.deinit(io) catch |err| {
        std.debug.print("teardown: {s}\n", .{@errorName(err)});
    };

    const stub_url = try std.fmt.allocPrint(gpa, "http://127.0.0.1:{d}/v1/messages", .{stub.port});
    defer gpa.free(stub_url);
    try putAnthropicProfile(&h, stub_url);

    const session_id = try uniqueSessionId("sess_usage_rate");
    defer gpa.free(session_id);

    // The exact sendChatMessage wire.
    const session_body = try std.fmt.allocPrint(gpa,
        \\{{"session_id":"{s}","queue_message":"say hi","cwd_session":"","image_urls":"","selected_profile_model":"ant-stub","is_auto_retry_until_stop":""}}
    , .{session_id});
    defer gpa.free(session_body);
    {
        // The worker runs in the background, so a 500 here can still be a
        // healthy boot with a failed turn the poll below reports on.
        var r = try h.http(io, .POST, "/api/llm/session", .{
            .json_body = session_body,
            .expect = &.{ 200, 201, 500 },
        });
        defer r.deinit();
    }

    const assistant_text = try waitForAssistantReply(&h, &stub, session_id);
    defer gpa.free(assistant_text);
    if (std.mem.indexOf(u8, assistant_text, "hello from stub") == null) {
        std.debug.print("assistant reply should be the stub text, got: {s}\n", .{assistant_text});
        return error.TestUnexpectedResult;
    }

    const path = try usagePath("/api/llm", session_id);
    defer gpa.free(path);

    var r = try h.http(io, .GET, path, .{ .expect = &.{200} });
    defer r.deinit();
    var doc = try r.json();
    defer doc.deinit();

    if (!std.mem.eql(u8, doc.str("session_id") orelse "", session_id)) {
        std.debug.print("usage echoes the wrong session_id: {s}\n", .{r.body});
        return error.TestUnexpectedResult;
    }

    // Every persisted row reports prompt=1000 / cache_read=900, so the rate is
    // 90% regardless of how many calls the turn made.
    const got = doc.number("cache_hit_rate") orelse {
        std.debug.print("usage carries no numeric cache_hit_rate: {s}\n", .{r.body});
        return error.TestUnexpectedResult;
    };
    if (@abs(got - 90.0) > 0.001) {
        std.debug.print("expected a 90% cache hit rate, got {d}: {s}\n", .{ got, r.body });
        return error.TestUnexpectedResult;
    }

    const read = doc.int("cache_read_tokens") orelse -1;
    const total = doc.int("total_input_tokens") orelse -1;
    if (read <= 0) {
        std.debug.print("cache_read_tokens must be positive, got {d}: {s}\n", .{ read, r.body });
        return error.TestUnexpectedResult;
    }
    // 900/1000 = 9/10 — an integer identity, so it cannot pass on a rounding
    // coincidence and does not depend on the call count.
    if (read * 10 != total * 9) {
        std.debug.print(
            "cache_read ({d}) over total input ({d}) must be 9/10: {s}\n",
            .{ read, total, r.body },
        );
        return error.TestUnexpectedResult;
    }
    // The stub reports no cache WRITES; a non-zero value here would mean the
    // write counter is being fed from somewhere it should not be.
    if ((doc.int("cache_creation_tokens") orelse -1) != 0) {
        std.debug.print("cache_creation_tokens must stay 0: {s}\n", .{r.body});
        return error.TestUnexpectedResult;
    }
    // The provider DID report cache counters, so a client must not render this
    // as "not reported".
    if ((doc.int("calls_with_cache") orelse 0) <= 0) {
        std.debug.print("calls_with_cache must be positive: {s}\n", .{r.body});
        return error.TestUnexpectedResult;
    }
    // Self-consistency: the rate is exactly the two integers it claims to
    // divide, rounded to two decimals.
    const implied = @round(100.0 * @as(f64, @floatFromInt(read)) / @as(f64, @floatFromInt(total)) * 100.0) / 100.0;
    if (@abs(got - implied) > 0.001) {
        std.debug.print(
            "cache_hit_rate {d} does not match {d}/{d} = {d}: {s}\n",
            .{ got, read, total, implied, r.body },
        );
        return error.TestUnexpectedResult;
    }
}

// A session that has made no calls reports a null rate — never a fabricated
// 0% — and both route prefixes answer identically.
test "session_usage_is_null_before_any_call_and_matches_on_both_prefixes" {
    try harness.requirePabrikBin(io, gpa);

    var h = try Harness.boot(io, gpa, .{});
    defer h.deinit(io) catch |err| {
        std.debug.print("teardown: {s}\n", .{@errorName(err)});
    };

    const session_id = try uniqueSessionId("sess_usage_empty");
    defer gpa.free(session_id);

    // Create the session row without running a turn.
    {
        const body = try std.fmt.allocPrint(gpa, "{{\"name\":\"usage-empty-chat\"}}", .{});
        defer gpa.free(body);
        const path = try std.fmt.allocPrint(gpa, "/api/llm/session/{s}", .{session_id});
        defer gpa.free(path);
        var r = try h.http(io, .PUT, path, .{ .json_body = body, .expect = &.{200} });
        defer r.deinit();
    }

    const llm_path = try usagePath("/api/llm", session_id);
    defer gpa.free(llm_path);
    const plain_path = try usagePath("/api", session_id);
    defer gpa.free(plain_path);

    var a = try h.http(io, .GET, llm_path, .{ .expect = &.{200} });
    defer a.deinit();
    {
        var doc = try a.json();
        defer doc.deinit();
        // No input tokens to divide by: `null`, not 0. A fabricated 0% here
        // would read as "the cache never hit" for a session that never called.
        const rate_val = doc.get("cache_hit_rate") orelse {
            std.debug.print("usage has no cache_hit_rate key: {s}\n", .{a.body});
            return error.TestUnexpectedResult;
        };
        if (rate_val != .null) {
            std.debug.print("a session with no calls must report a null rate: {s}\n", .{a.body});
            return error.TestUnexpectedResult;
        }
        if ((doc.int("cache_read_tokens") orelse -1) != 0) return error.TestUnexpectedResult;
        if ((doc.int("total_input_tokens") orelse -1) != 0) return error.TestUnexpectedResult;
        if ((doc.int("cache_creation_tokens") orelse -1) != 0) return error.TestUnexpectedResult;
        if ((doc.int("calls_with_cache") orelse -1) != 0) return error.TestUnexpectedResult;
    }

    // The `/api/session/` alias resolves to the same handler and the same body.
    var b = try h.http(io, .GET, plain_path, .{ .expect = &.{200} });
    defer b.deinit();
    if (!std.mem.eql(u8, a.body, b.body)) {
        std.debug.print(
            "the two prefixes must answer identically:\n  {s}\n  {s}\n",
            .{ a.body, b.body },
        );
        return error.TestUnexpectedResult;
    }
}

comptime {
    // Body-analysis barrier: an unreferenced function is never type-checked,
    // so a stdlib rename inside one would stay invisible until a caller
    // appeared.
    _ = Stub;
    _ = startStub;
    _ = stopStub;
    _ = serveStub;
    _ = handleRequest;
    _ = headerValue;
    _ = contentLength;
    _ = waitForAssistantReply;
    _ = putAnthropicProfile;
    _ = uniqueSessionId;
    _ = usagePath;
    _ = Harness.boot;
}
