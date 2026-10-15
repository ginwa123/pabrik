// Wire test: the `list_directory` tool no longer ABORTS the worker when the
// LLM passes a RELATIVE path.

const std = @import("std");
const testing = std.testing;
const harness = @import("harness.zig");
const Harness = harness.Harness;

const gpa = testing.allocator;
const io = testing.io;

const Io = std.Io;

// The relative path from the crash report, and the tool call id we can
// look for in the follow-up request (the one that carries the tool
// RESULT).
const RELATIVE_PATH = "frontend/src";
const TOOL_CALL_ID = "call_listdir_rel_1";

/// Marker strings that appear in the process log only if the worker
/// aborted.
const CRASH_MARKERS = [_][]const u8{
    "received signal ABRT",
    "reached unreachable code",
    "openDirAbsolute",
    "panic:",
};

/// OpenAI-style SSE stream carrying a tool_call for list_directory.
const TOOL_CALL_SSE =
    \\data: {"id": "chatcmpl-stub-toolcall", "object": "chat.completion.chunk", "model": "stub-model", "choices": [{"index": 0, "delta": {"role": "assistant", "content": null, "tool_calls": [{"index": 0, "id": "call_listdir_rel_1", "type": "function", "function": {"name": "list_directory", "arguments": "{\"path\": \"frontend/src\", \"hidden\": false, \"respect_ignore_files\": true}"}}]}, "finish_reason": null}]}
    \\
    \\data: {"id": "chatcmpl-stub-toolcall", "object": "chat.completion.chunk", "model": "stub-model", "choices": [{"index": 0, "delta": {}, "finish_reason": "tool_calls"}]}
    \\
    \\data: [DONE]
    \\
;

/// OpenAI-style SSE stream carrying a plain assistant message.
const TEXT_SSE =
    \\data: {"id": "chatcmpl-stub-text", "object": "chat.completion.chunk", "model": "stub-model", "choices": [{"index": 0, "delta": {"role": "assistant", "content": "listed the directory"}, "finish_reason": null}]}
    \\
    \\data: {"id": "chatcmpl-stub-text", "object": "chat.completion.chunk", "model": "stub-model", "choices": [{"index": 0, "delta": {}, "finish_reason": "stop"}]}
    \\
    \\data: [DONE]
    \\
;

/// Cap on the request head we accumulate before giving up. A full agent
/// prompt is tens of KB; 256 KiB is generous.
const MAX_HEAD_BYTES = 1 << 18;

// ============================================================================
// Stub upstream
// ============================================================================

/// A stateful OpenAI-shaped SSE upstream, served from a background thread.
const Stub = struct {
    port: u16,
    server: Io.net.Server,
    thread: std.Thread,
    stop: std.atomic.Value(bool) = .init(false),
    tool_call_served: std.atomic.Value(bool) = .init(false),
    /// Number of requests the stub answered. The Python recorded every body
    /// under a lock; the port only needs the count, because every decision
    /// the Python's `note()` made is made inline in `handleRequest` below.
    requests: std.atomic.Value(usize) = .init(0),

    fn start(stub: *Stub) !void {
        stub.port = try harness.findFreePortRandom(gpa);
        const addr: Io.net.IpAddress = .{ .ip4 = .loopback(stub.port) };
        stub.server = try addr.listen(io, .{ .reuse_address = true });
        errdefer stub.server.deinit(io);
        stub.thread = try std.Thread.spawn(.{}, serveStub, .{stub});
    }

    /// Wake the blocked `accept`, join, and free. See the header note.
    fn shutdown(stub: *Stub) void {
        stub.stop.store(true, .release);

        const addr: Io.net.IpAddress = .{ .ip4 = .loopback(stub.port) };
        if (addr.connect(io, .{ .mode = .stream })) |conn| {
            var c = conn;
            c.close(io);
        } else |_| {
            // Listener already gone: `accept` returned an error and the
            // serve loop has exited. Nothing to wake.
        }

        stub.thread.join();
        stub.server.deinit(io);
    }
};

fn serveStub(stub: *Stub) void {
    while (!stub.stop.load(.acquire)) {
        // `defer` inside a loop body runs at the end of THAT iteration,
        // so each accepted socket is closed before the next accept —
        // the connection is what the upstream does per POST.
        var stream = stub.server.accept(io) catch break;
        defer stream.close(io);
        if (stub.stop.load(.acquire)) break;
        handleRequest(stub, stream) catch {};
    }
}

/// The Python's `_StubState.note(body)` — record the request and report
/// whether THIS one should be answered with the tool call.
fn shouldServeToolCall(stub: *Stub, body: []const u8) bool {
    if (std.mem.indexOf(u8, body, TOOL_CALL_ID) != null) return false; // follow-up turn
    if (stub.tool_call_served.load(.acquire)) return false;
    if (std.mem.indexOf(u8, body, "list_directory") == null) return false;
    if (std.mem.indexOf(u8, body, "\"tools\"") == null) return false;
    stub.tool_call_served.store(true, .release);
    return true;
}

/// Read one request, decide the reply, send it. THE HEAD AND THE BODY OVERLAP
/// IN THE SOCKET BUFFER, and getting that wrong hangs the whole suite.
fn handleRequest(stub: *Stub, stream: Io.net.Stream) !void {
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

    const head = acc.written()[0..head_len];

    // Drain whatever of the body is still unread; a client cannot be
    // answered mid-frame.
    var remaining = contentLength(head);
    if (acc.written().len > head_len) remaining -|= acc.written().len - head_len;
    while (remaining > 0) {
        r.fill(1) catch break;
        const b = r.buffered();
        if (b.len == 0) break;
        // ACCUMULATE, THEN TOSS.
        const take = @min(b.len, remaining);
        acc.writer.writeAll(b[0..take]) catch break;
        remaining -= take;
        r.toss(take);
    }

    const body = acc.written()[head_len..];
    const serve_tool_call = shouldServeToolCall(stub, body);
    _ = stub.requests.fetchAdd(1, .monotonic);

    const sse: []const u8 = if (serve_tool_call) TOOL_CALL_SSE else TEXT_SSE;
    const response = try std.fmt.allocPrint(
        gpa,
        "HTTP/1.1 200 OK\r\n" ++
            "Content-Type: text/event-stream\r\n" ++
            "Content-Length: {d}\r\n" ++
            "Connection: close\r\n" ++
            "\r\n" ++
            "{s}",
        .{ sse.len, sse },
    );
    defer gpa.free(response);

    var wbuf: [8 * 1024]u8 = undefined;
    var sw = stream.writer(io, &wbuf);
    try sw.interface.writeAll(response);
    try sw.interface.flush();
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

// ============================================================================
// Polling
// ============================================================================

/// `deadline = time.monotonic() + 60.0` — the tool-row budget.
const POLL_BUDGET_MS: i64 = 60_000;
/// `time.sleep(0.5)` between polls.
const POLL_INTERVAL_MS: i64 = 500;

/// Poll the session-messages endpoint until the list_directory result lands.
/// Returns an OWNED copy of the row's `content`.
fn waitForToolRow(h: *Harness, session_id: []const u8) !?[]u8 {
    const path = try std.fmt.allocPrint(gpa, "/api/llm/session/{s}/messages", .{session_id});
    defer gpa.free(path);

    const params = [_]Harness.Param{
        .{ .name = "sort_by", .value = "created_at" },
        .{ .name = "direction", .value = "asc" },
        .{ .name = "limit", .value = "100" },
    };

    const deadline = Io.Timestamp.now(io, .awake).toMilliseconds() + POLL_BUDGET_MS;
    while (Io.Timestamp.now(io, .awake).toMilliseconds() < deadline) {
        var r = h.http(io, .GET, path, .{ .params = &params, .expect = &.{200} }) catch |err| {
            std.debug.print("messages poll failed: {s}\n", .{@errorName(err)});
            return null;
        };
        defer r.deinit();

        var doc = r.json() catch return null;
        defer doc.deinit();

        // An absent `messages` is Python's `.get("messages", [])` — an empty
        // list, not an error.
        const messages_list = doc.array("messages");
        const messages: []const std.json.Value =
            if (messages_list) |a| a.items else &.{};
        for (messages) |m| {
            const obj = switch (m) {
                .object => |o| o,
                else => continue,
            };
            const tool_name = switch (obj.get("tool_name") orelse std.json.Value{ .null = {} }) {
                .string => |s| s,
                else => continue,
            };
            if (!std.mem.eql(u8, tool_name, "list_directory")) continue;
            const content = switch (obj.get("content") orelse std.json.Value{ .string = "" }) {
                .string => |s| s,
                else => "",
            };
            if (std.mem.trim(u8, content, " \t\r\n").len == 0) continue;
            return try gpa.dupe(u8, content);
        }

        // A dead worker never fills the row — fail fast instead of
        // burning the whole timeout on a crashed process.
        if (!h.health(io)) return null;

        // Sleep the Python's `time.sleep(0.5)` INTERVAL, capped by what
        // is left of the budget — never the whole remainder.
        const remaining = deadline - Io.Timestamp.now(io, .awake).toMilliseconds();
        if (remaining > 0) {
            const nap = @min(remaining, POLL_INTERVAL_MS);
            Io.sleep(io, .fromMilliseconds(nap), .awake) catch {};
        }
    }
    return null;
}

/// The last 4000 BYTES of the log tail, owned. Python:
/// `harness.tail_log(4000)` then `log_tail[-4000:]`. The harness's `tailLog`
/// counts LINES, so the byte slice is applied here.
fn logExcerpt(h: *Harness) ![]u8 {
    const tail = try h.tailLog(io, gpa, 4000);
    defer gpa.free(tail);
    const clipped = if (tail.len > 4000) tail[tail.len - 4000 ..] else tail;
    return gpa.dupe(u8, clipped);
}

// ============================================================================
// Test
// ============================================================================

// The exact crash call, end-to-end: worker alive + path resolved.
test "list_directory_relative_path_does_not_abort_worker" {
    try harness.requirePabrikBin(io, gpa);

    // Registered FIRST so it runs LAST: the recorded requests are read
    // by the assertions, and the serve thread must outlive the harness
    // teardown's shutdown of the child.
    var stub: Stub = .{ .port = 0, .server = undefined, .thread = undefined };
    try stub.start();
    defer stub.shutdown();

    // `stub_llm_profile` is load-bearing, not a convenience: without a
    // configured profile the binary has no model to run the turn with, so
    // nothing ever reaches the stub.
    var h = try Harness.boot(io, gpa, .{ .stub_llm_profile = true });
    defer h.deinit(io) catch |err| {
        std.debug.print("teardown: {s}\n", .{@errorName(err)});
    };

    const stub_url = try std.fmt.allocPrint(gpa, "http://127.0.0.1:{d}/v1/chat/completions", .{stub.port});
    defer gpa.free(stub_url);

    // 1. Point a profile at the stub (mirrors anthropic_chat_headers_test).
    const cfg_body = try std.fmt.allocPrint(gpa,
        \\{{"api_endpoint":"{s}","api_key":"sk-stub-test","model":"stub-model","url_style":"openai","profiles":{{"rel-stub":{{"model":"stub-model","base_url":"{s}","api_key":"sk-stub-test","url_style":"openai"}}}},"active_profile":"rel-stub"}}
    , .{ stub_url, stub_url });
    defer gpa.free(cfg_body);
    {
        var r = try h.http(io, .PUT, "/api/config/pabrik", .{
            .json_body = cfg_body,
            .expect = &.{200},
        });
        defer r.deinit();
    }

    // 2. Workspace holding <cwd>/frontend/src/index.ts — the layout the
    // crashed session had.
    const ws = try harness.harnessPath(gpa, h.temp_dir, &.{"rel-path-ws"});
    defer gpa.free(ws);
    const src_dir = try harness.harnessPath(gpa, ws, &.{ "frontend", "src" });
    defer gpa.free(src_dir);
    try std.Io.Dir.cwd().createDirPath(io, src_dir);
    {
        const index_ts = try std.fs.path.join(gpa, &.{ src_dir, "index.ts" });
        defer gpa.free(index_ts);
        var f = try std.Io.Dir.cwd().createFile(io, index_ts, .{});
        defer f.close(io);
        try f.writeStreamingAll(io, "export const x = 1;\n");
    }

    // 3. Start a real worker turn — the sendChatMessage wire body.
    const session_id = try std.fmt.allocPrint(gpa, "sess_listdir_rel_{d}", .{
        Io.Timestamp.now(io, .real).toSeconds(),
    });
    defer gpa.free(session_id);

    const session_body = try std.json.Stringify.valueAlloc(gpa, .{
        .session_id = session_id,
        .queue_message = "list the frontend/src directory",
        .cwd_session = ws,
        .allowed_tools = "list_directory",
        .image_urls = "",
        .selected_profile_model = "rel-stub",
        .is_auto_retry_until_stop = "",
    }, .{});
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

    // 4. Wait for the tool result row.
    const row = try waitForToolRow(&h, session_id);

    // The process must still be alive: pre-fix this aborted.
    const log_tail = try logExcerpt(&h);
    defer gpa.free(log_tail);
    if (!h.health(io)) {
        std.debug.print(
            "pabrik died during the turn — the relative-path abort is back.\n--- log tail ---\n{s}\n",
            .{log_tail},
        );
        return error.TestUnexpectedResult;
    }
    for (CRASH_MARKERS) |marker| {
        if (std.mem.indexOf(u8, log_tail, marker) != null) {
            std.debug.print("log contains crash marker `{s}`:\n{s}\n", .{ marker, log_tail });
            return error.TestUnexpectedResult;
        }
    }

    if (!stub.tool_call_served.load(.acquire)) {
        std.debug.print(
            "the stub never served the list_directory tool call, so this run " ++
                "proved nothing.\n--- log tail ---\n{s}\n",
            .{log_tail},
        );
        return error.TestUnexpectedResult;
    }
    const content = row orelse {
        std.debug.print(
            "no list_directory tool result row appeared within 60s.\n--- log tail ---\n{s}\n",
            .{log_tail},
        );
        return error.TestUnexpectedResult;
    };
    defer gpa.free(content);

    // 5. The result is the resolved ABSOLUTE path under the session cwd, and
    // the listing succeeded (not an error envelope).
    var envelope = std.json.parseFromSlice(std.json.Value, gpa, content, .{ .allocate = .alloc_always }) catch |err| {
        std.debug.print("tool result content is not JSON ({s}): {s}\n", .{ @errorName(err), content });
        return error.TestUnexpectedResult;
    };
    defer envelope.deinit();

    const tool = switch (envelope.value.object.get("tool") orelse std.json.Value{ .null = {} }) {
        .string => |s| s,
        else => {
            std.debug.print("envelope has no `tool` string: {s}\n", .{content});
            return error.TestUnexpectedResult;
        },
    };
    if (!std.mem.eql(u8, tool, "list_directory")) {
        std.debug.print("envelope tool mismatch: {s}\n", .{content});
        return error.TestUnexpectedResult;
    }
    // Python: `envelope["success"] is True` — an IDENTITY check against the
    // bool `True`, so a `"true"` string or `1` fails.
    const success = switch (envelope.value.object.get("success") orelse std.json.Value{ .null = {} }) {
        .bool => |b| b,
        else => {
            std.debug.print("tool returned a non-boolean `success`: {s}\n", .{content});
            return error.TestUnexpectedResult;
        },
    };
    if (!success) {
        std.debug.print("tool returned an error envelope instead of a listing: {s}\n", .{content});
        return error.TestUnexpectedResult;
    }

    const data = switch (envelope.value.object.get("data") orelse std.json.Value{ .null = {} }) {
        .object => |o| o,
        else => {
            std.debug.print("envelope has no `data` object: {s}\n", .{content});
            return error.TestUnexpectedResult;
        },
    };
    const got_path = switch (data.get("path") orelse std.json.Value{ .null = {} }) {
        .string => |s| s,
        else => {
            std.debug.print("envelope data has no `path` string: {s}\n", .{content});
            return error.TestUnexpectedResult;
        },
    };
    if (!std.mem.eql(u8, got_path, src_dir)) {
        std.debug.print(
            "relative path must resolve against the SESSION cwd '{s}', got '{s}'\n",
            .{ src_dir, got_path },
        );
        return error.TestUnexpectedResult;
    }

    const entries_val = data.get("entries") orelse std.json.Value{ .null = {} };
    const entries: []const std.json.Value = switch (entries_val) {
        .array => |a| a.items,
        else => &.{},
    };
    var saw_index_ts = false;
    for (entries) |e| {
        const o = switch (e) {
            .object => |oo| oo,
            else => continue,
        };
        const n = switch (o.get("name") orelse std.json.Value{ .null = {} }) {
            .string => |s| s,
            else => continue,
        };
        if (std.mem.eql(u8, n, "index.ts")) saw_index_ts = true;
    }
    if (!saw_index_ts) {
        std.debug.print("expected index.ts in the listing, got {s}\n", .{content});
        return error.TestUnexpectedResult;
    }

    // 6. Params echo what the model sent (the relative form is preserved
    //    on the wire even though the listing used the absolute path).
    const parameters = switch (envelope.value.object.get("parameters") orelse std.json.Value{ .null = {} }) {
        .object => |o| o,
        else => {
            std.debug.print("envelope has no `parameters` object: {s}\n", .{content});
            return error.TestUnexpectedResult;
        },
    };
    const echoed = switch (parameters.get("path") orelse std.json.Value{ .null = {} }) {
        .string => |s| s,
        else => {
            std.debug.print("envelope parameters has no `path` string: {s}\n", .{content});
            return error.TestUnexpectedResult;
        },
    };
    if (!std.mem.eql(u8, echoed, RELATIVE_PATH)) {
        std.debug.print("envelope parameters.path must echo the relative form, got '{s}'\n", .{echoed});
        return error.TestUnexpectedResult;
    }
}

// Body-analysis barrier. An unreferenced helper is never type-checked, so
// a stdlib rename inside one stays invisible until a caller appears.
comptime {
    _ = Stub.start;
    _ = Stub.shutdown;
    _ = serveStub;
    _ = shouldServeToolCall;
    _ = handleRequest;
    _ = headerLines;
    _ = headerValue;
    _ = contentLength;
    _ = waitForToolRow;
    _ = logExcerpt;
    _ = Harness.boot;
}
