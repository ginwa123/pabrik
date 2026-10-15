//! Wire test: an anthropic-style CHAT turn sends `x-api-key` +
//! `anthropic-version` (and `x-opencode-session`), not Bearer.

const std = @import("std");
const testing = std.testing;
const harness = @import("harness.zig");
const Harness = harness.Harness;
const gpa = testing.allocator;
const io = testing.io;

const Io = std.Io;

/// The Anthropic SSE transcript the stub replays verbatim.
const SSE_STREAM =
    "event: message_start\n" ++
    "data: {\"type\":\"message_start\",\"message\":{\"id\":\"msg_1\",\"type\":\"message\"," ++
    "\"role\":\"assistant\",\"content\":[],\"model\":\"stub-claude\",\"stop_reason\":null," ++
    "\"stop_sequence\":null,\"usage\":{\"input_tokens\":8,\"output_tokens\":1}}}\n" ++
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
    "event: message_delta\n" ++
    "data: {\"type\":\"message_delta\",\"delta\":{\"stop_reason\":\"end_turn\"," ++
    "\"stop_sequence\":null},\"usage\":{\"output_tokens\":4}}\n" ++
    "\n" ++
    "event: message_stop\n" ++
    "data: {\"type\":\"message_stop\"}\n" ++
    "\n";

/// A recorded upstream request head. Owned by the Stub; copied by the test
/// before the server is stopped. Only the HEAD is kept.
const MAX_HEAD_BYTES = 1 << 18;

/// A one-request-headers stub Anthropic SSE upstream, served from a
/// background thread.
const Stub = struct {
    io: Io,
    port: u16,
    server: Io.net.Server,
    thread: std.Thread,
    stop: std.atomic.Value(bool) = .init(false),
    /// Guards `heads`; the serve thread appends while the test reads.
    mutex: Io.Mutex = .init,
    heads: std.ArrayList([]u8) = .empty,

    /// Copy every recorded head out. Owned by the caller.
    fn snapshot(self: *Stub) !std.ArrayList([]u8) {
        var out: std.ArrayList([]u8) = .empty;
        errdefer {
            for (out.items) |h| gpa.free(h);
            out.deinit(gpa);
        }
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        for (self.heads.items) |h| try out.append(gpa, try gpa.dupe(u8, h));
        return out;
    }
};

fn startStub(stub: *Stub) !void {
    stub.port = try harness.findFreePortRandom(gpa);
    const addr: Io.net.IpAddress = .{ .ip4 = .loopback(stub.port) };
    stub.server = try addr.listen(io, .{ .reuse_address = true });
    errdefer stub.server.deinit(io);
    stub.thread = try std.Thread.spawn(.{}, serveStub, .{stub});
}

/// Wake the blocked `accept`, join, and free. See the header note.
fn stopStub(stub: *Stub) void {
    stub.stop.store(true, .release);

    const addr: Io.net.IpAddress = .{ .ip4 = .loopback(stub.port) };
    if (addr.connect(stub.io, .{ .mode = .stream })) |conn| {
        var c = conn;
        c.close(stub.io);
    } else |_| {
        // Listener already gone: `accept` returned an error and the
        // serve loop has exited. Nothing to wake.
    }

    stub.thread.join();
    stub.server.deinit(stub.io);
    for (stub.heads.items) |h| gpa.free(h);
    stub.heads.deinit(gpa);
}

fn serveStub(stub: *Stub) void {
    while (!stub.stop.load(.acquire)) {
        // `defer` inside a loop body runs at the end of THAT
        // iteration, so each accepted socket is closed before the next
        // accept — the connection is what the upstream does per POST.
        var stream = stub.server.accept(stub.io) catch break;
        defer stream.close(stub.io);
        if (stub.stop.load(.acquire)) break;
        handleRequest(stub, stream) catch {};
    }
}

/// Read one request, record its head, reply with the SSE transcript. THE HEAD
/// AND THE BODY OVERLAP IN THE SOCKET BUFFER, and getting that wrong hangs
/// the whole suite.
fn handleRequest(stub: *Stub, stream: Io.net.Stream) !void {
    var rbuf: [64 * 1024]u8 = undefined;
    var sr = stream.reader(stub.io, &rbuf);
    const r = &sr.interface;

    var acc: Io.Writer.Allocating = .init(gpa);
    defer acc.deinit();

    // Length of the request head within `acc`, or 0 while incomplete.
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
    // No complete head: nothing worth recording, and nothing to answer.
    if (head_len == 0) return;

    const head = acc.written()[0..head_len];

    // Drain whatever of the body is still unread. A full agent prompt is
    // tens of KB, and a client cannot be answered mid-frame; it is not
    // recorded because no assertion in this suite looks at a body.
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

    stub.mutex.lockUncancelable(stub.io);
    defer stub.mutex.unlock(stub.io);
    try stub.heads.append(gpa, try gpa.dupe(u8, head));

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

/// `deadline = time.monotonic() + 60.0` — the assistant-reply budget.
const POLL_BUDGET_MS: i64 = 60_000;
/// `time.sleep(0.5)` between polls.
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

        const messages = doc.array("messages") orelse
            return error.TestUnexpectedResult; // Python: `.get("messages", [])`
        for (messages.items) |m| {
            if (m != .object) continue;
            const obj = m.object;
            const role = obj.get("role") orelse continue;
            if (role != .string or !std.mem.eql(u8, role.string, "assistant")) continue;
            const content = obj.get("content") orelse continue;
            if (content != .string or content.string.len == 0) continue;
            return gpa.dupe(u8, content.string);
        }

        // Sleep the Python's `time.sleep(0.5)` INTERVAL, capped by what is
        // left of the budget — never the whole remainder.
        const remaining = deadline - std.Io.Timestamp.now(io, .awake).toMilliseconds();
        if (remaining > 0) {
            const nap = @min(remaining, POLL_INTERVAL_MS);
            std.Io.sleep(io, .fromMilliseconds(nap), .awake) catch {};
        }
    }

    // The Python's message ("the stub may not have been hit or the SSE did
    // not parse") named two very different failures and gave the reader
    // nothing to tell them apart.
    const tail = try h.tailLog(io, gpa, 40);
    defer gpa.free(tail);
    std.debug.print(
        "worker turn never produced an assistant message within {d}ms; " ++
            "the stub received {d} request(s)\n" ++
            "--- last 40 lines of the factory log ---\n{s}\n",
        .{ POLL_BUDGET_MS, stub.heads.items.len, tail },
    );
    return error.TestUnexpectedResult;
}

// Full worker turn against a stub Anthropic SSE upstream.
test "anthropic_chat_turn_sends_x_api_key_not_bearer" {
    try harness.requirePabrikBin(io, gpa);

    // Registered FIRST so it runs LAST: the recorded heads are read by
    // the assertions, and the serve thread must outlive the harness
    // teardown's shutdown of the child.
    var stub: Stub = .{
        .io = io,
        .port = 0,
        .server = undefined,
        .thread = undefined,
    };
    try startStub(&stub);
    defer stopStub(&stub);

    // `stub_llm_profile` is load-bearing, not a convenience: without a
    // configured profile the binary has no model to run the turn with, so
    // nothing ever reaches the stub.
    var h = try Harness.boot(io, gpa, .{ .stub_llm_profile = true });
    defer h.deinit(io) catch |err| {
        std.debug.print("teardown: {s}\n", .{@errorName(err)});
    };

    const stub_url = try std.fmt.allocPrint(gpa, "http://127.0.0.1:{d}/v1/messages", .{stub.port});
    defer gpa.free(stub_url);

    // 1.
    const cfg_body = try std.fmt.allocPrint(gpa,
        \\{{"api_endpoint":"{s}","api_key":"sk-ant-test","model":"stub-claude","url_style":"anthropic","profiles":{{"ant-stub":{{"model":"stub-claude","base_url":"{s}","api_key":"sk-ant-test","url_style":"anthropic"}}}},"active_profile":"ant-stub"}}
    , .{ stub_url, stub_url });
    defer gpa.free(cfg_body);
    {
        var r = try h.http(io, .PUT, "/api/config/pabrik", .{
            .json_body = cfg_body,
            .expect = &.{200},
        });
        defer r.deinit();
    }

    // 2. Send the first chat message — the exact sendChatMessage wire
    // (session_id + queue_message + profile selection).
    const session_id = try std.fmt.allocPrint(gpa, "sess_anthropic_hdr_{d}", .{
        std.Io.Timestamp.now(io, .real).toSeconds(),
    });
    defer gpa.free(session_id);

    const session_body = try std.fmt.allocPrint(gpa,
        \\{{"session_id":"{s}","queue_message":"say hi","cwd_session":"","image_urls":"","selected_profile_model":"ant-stub","is_auto_retry_until_stop":""}}
    , .{session_id});
    defer gpa.free(session_body);
    {
        // Python: `expect=(200, 201, 500)` — the worker runs in the
        // background, so a 500 here can still be a healthy boot with a
        // failed turn that the poll below reports on.
        var r = try h.http(io, .POST, "/api/llm/session", .{
            .json_body = session_body,
            .expect = &.{ 200, 201, 500 },
        });
        defer r.deinit();
    }

    // 3. Poll until the assistant reply lands (the worker turn
    // completes against the stub).
    const assistant_text = try waitForAssistantReply(&h, &stub, session_id);
    defer gpa.free(assistant_text);
    if (std.mem.indexOf(u8, assistant_text, "hello from stub") == null) {
        std.debug.print("assistant reply should be the stub text, got: {s}\n", .{assistant_text});
        return error.TestUnexpectedResult;
    }

    // 4. Header contract on EVERY stub request (chat turn +
    // session auto-naming all go through Agent.callStreaming).
    var seen = try stub.snapshot();
    defer {
        for (seen.items) |h2| gpa.free(h2);
        seen.deinit(gpa);
    }
    if (seen.items.len == 0) {
        std.debug.print("stub upstream received no requests\n", .{});
        return error.TestUnexpectedResult;
    }
    for (seen.items, 0..) |head, i| {
        if (!std.mem.eql(u8, headerValue(head, "x-api-key") orelse "", "sk-ant-test")) {
            std.debug.print(
                "request {d}: anthropic chat must send x-api-key, got: {s}\n",
                .{ i, head },
            );
            return error.TestUnexpectedResult;
        }
        if (!std.mem.eql(u8, headerValue(head, "anthropic-version") orelse "", "2023-06-01")) {
            std.debug.print(
                "request {d}: anthropic chat must send anthropic-version, got: {s}\n",
                .{ i, head },
            );
            return error.TestUnexpectedResult;
        }
        if (hasHeader(head, "authorization")) {
            std.debug.print(
                "request {d}: anthropic chat must NOT send Bearer auth, got: {s}\n",
                .{ i, head },
            );
            return error.TestUnexpectedResult;
        }
        // Python: `assert headers.get("x-opencode-session")` — a
        // TRUTHINESS check, so an absent header and an empty one fail
        // alike. `orelse ""` plus the length test is the same shape.
        const sess_hdr = headerValue(head, "x-opencode-session") orelse "";
        if (sess_hdr.len == 0) {
            std.debug.print(
                "request {d}: chat must send x-opencode-session, got: {s}\n",
                .{ i, head },
            );
            return error.TestUnexpectedResult;
        }
    }
}

comptime {
    // Body-analysis barrier: an unreferenced function is never
    // type-checked, so a stdlib rename inside one would stay invisible
    // until some caller appeared.
    _ = Stub;
    _ = Stub.snapshot;
    _ = startStub;
    _ = stopStub;
    _ = serveStub;
    _ = handleRequest;
    _ = headerLines;
    _ = headerValue;
    _ = hasHeader;
    _ = contentLength;
    _ = waitForAssistantReply;
    _ = Harness.boot;
}
