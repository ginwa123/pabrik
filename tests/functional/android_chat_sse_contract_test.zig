// Wire-contract test for the native Android chat event stream. Zig port of
// `tests/functional/android_chat_sse_contract_test.py` (same test names, same
// order).

const std = @import("std");
const testing = std.testing;
const harness = @import("harness.zig");
const Harness = harness.Harness;
const gpa = testing.allocator;
const io = testing.io;
const Io = std.Io;

/// `SseChannels.eventsPath()`, minus the `/api/events?` prefix. Spelled out
/// rather than imported, because the point is to fail when one side moves and
/// the other does not.
const chat_channels = "llm,queue,sessions,workers";

/// The names `decodeChatFrameUnsafe` has a branch for on these channels. A
/// frame outside this set lands on its `else -> null` and is dropped in
/// silence — the exact failure this file exists to make visible.
const known_events = [_][]const u8{
    "connected",
    "llm_chunk",
    "llm_full",
    "session_created",
    "session_updated",
    "session_deleted",
    "session_unknown",
    "queue_queued",
    "queue_deleted",
    "queue_unknown",
    // The app's single socket also carries the workers channel (see
    // `chat_channels` above), and a real turn upserts a worker.
    "worker_created",
    "worker_updated",
    "worker_deleted",
};

/// The keys the Kotlin row mapper reads off an `llm_full`. All of them are
/// present on every real row, including the ones that are empty.
const full_row_keys = [_][]const u8{
    "id",
    "index",
    "type",
    "session_id",
    "role",
    "content",
    "finish_reason",
    "reasoning_content",
    "tool_call_id",
    "tool_name",
    "tool_calls_json",
    "diffview_before",
    "diffview_after",
    "image_url",
    "video_url",
    "is_error",
};

/// Reused by the emitter-driven cases. The emitter takes the session id in
/// the body, so no real row has to exist for it.
const session_id_const = "sess_android_chat_sse_contract";

// ============================================================================
// SSE client
// ============================================================================

/// bytes, so 8 KiB is generous.
const transfer_buffer_len = 8 * 1024;

/// Monotonic milliseconds (`.awake` is monotonic — an NTP step must not
/// stretch or shrink a deadline).
fn nowMs() i64 {
    return Io.Timestamp.now(io, .awake).toMilliseconds();
}

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
///
/// The test thread owns the pointer; the reader thread writes into it.
const SseStream = struct {
    client: std.http.Client,
    req: std.http.Client.Request,
    /// The transfer buffer `body` reads out of. Owned here so its address
    /// outlives every read.
    transfer_buffer: [transfer_buffer_len]u8 = undefined,
    /// `req.reader` after `resp.reader(&transfer_buffer)`.
    body: *Io.Reader = undefined,
    status: u16 = 0,
    /// Duplicated from the response head (which `resp.reader()` invalidates).
    content_type: []u8 = "",
    transfer_encoding: []u8 = "",
    has_content_length: bool = false,
    /// Set by the test thread to release the reader.
    stop: std.atomic.Value(bool) = .init(false),
    /// Set by the reader thread once it has stopped touching `events`.
    done: std.atomic.Value(bool) = .init(false),
    /// Frames parsed so far — Python's `queue.Queue`.
    mutex: Io.Mutex = .init,
    events: std.ArrayList(SseEvent) = .empty,
    /// Set by the reader thread when the stream errored or ended.
    read_error: ?[]u8 = null,

    fn deinit(self: *SseStream) void {
        self.req.deinit();
        self.client.deinit();
        gpa.free(self.content_type);
        gpa.free(self.transfer_encoding);
        for (self.events.items) |*e| e.deinit();
        self.events.deinit(gpa);
        if (self.read_error) |m| gpa.free(m);
        gpa.destroy(self);
    }

    /// A DEEP COPY of the frames collected so far. Caller owns the slice
    /// (free it with `freeSnapshot`).
    fn snapshot(self: *SseStream) ![]SseEvent {
        self.mutex.lockUncancelable(io);
        defer self.mutex.unlock(io);
        const out = try gpa.alloc(SseEvent, self.events.items.len);
        errdefer {
            for (out) |*e| e.deinit();
            gpa.free(out);
        }
        for (self.events.items, out) |e, *o| {
            o.* = .{
                .name = try gpa.dupe(u8, e.name),
                .data = try gpa.dupe(u8, e.data),
            };
        }
        return out;
    }

    /// Free a snapshot returned by `snapshot`.
    fn freeSnapshot(frames: []SseEvent) void {
        for (frames) |*e| e.deinit();
        gpa.free(frames);
    }

    /// Pop the FIRST frame named `want`, discarding everything before it,
    /// and RETURN it (ownership passes to the caller).
    fn drainUntilMatchingKeep(self: *SseStream, want: []const u8, timeout_ms: i64) ?SseEvent {
        const deadline = nowMs() + timeout_ms;
        while (true) {
            self.mutex.lockUncancelable(io);
            if (self.events.items.len > 0) {
                var e = self.events.orderedRemove(0);
                self.mutex.unlock(io);
                if (std.mem.eql(u8, e.name, want)) return e;
                e.deinit();
                continue;
            }
            const finished = self.done.load(.acquire);
            self.mutex.unlock(io);
            if (finished) return null;
            if (nowMs() >= deadline) return null;
            Io.sleep(io, .fromMilliseconds(20), .awake) catch {};
        }
    }
};

/// Open `GET /api/events?channels=<channels>` and capture the response head.
/// The caller owns the returned pointer and must `deinit` it.
fn openSse(port: u16, channels: []const u8) !*SseStream {
    const s = try gpa.create(SseStream);
    errdefer gpa.destroy(s);

    // `gpa.create` returns UNINITIALIZED memory — it does NOT run the
    // struct's field default initializers, and an uninitialised
    // `Io.Mutex` is not a lock at all.
    s.* = .{ .client = .{ .allocator = gpa, .io = io }, .req = undefined };

    const url = try std.fmt.allocPrint(
        gpa,
        "http://127.0.0.1:{d}/api/events?channels={s}",
        .{ port, channels },
    );
    defer gpa.free(url);

    s.req = s.client.request(.GET, try std.Uri.parse(url), .{
        .redirect_behavior = .unhandled,
        .extra_headers = &.{
            // What the browser's `EventSource` sends.
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
                gpa.free(s.content_type);
                s.content_type = try gpa.dupe(u8, kv.value);
            } else if (std.ascii.eqlIgnoreCase(kv.name, "transfer-encoding")) {
                gpa.free(s.transfer_encoding);
                s.transfer_encoding = try gpa.dupe(u8, kv.value);
            } else if (std.ascii.eqlIgnoreCase(kv.name, "content-length")) {
                s.has_content_length = true;
            }
        }
    }

    s.body = resp.reader(&s.transfer_buffer);
    return s;
}

/// Read SSE frames from `s` until `stop` is set, the stream ends, or an error
/// occurs. Runs on its own thread. The SSE grammar: event: <name>\n data:
/// <line>\n \n <- blank line dispatches the frame
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
        const raw_line_opt = reader.takeDelimiter('\n') catch |err| {
            const msg = switch (err) {
                error.ReadFailed => "read failed",
                error.StreamTooLong => "line exceeded the transfer buffer",
            };
            const owned = gpa.dupe(u8, msg) catch return;
            s.mutex.lockUncancelable(io);
            s.read_error = owned;
            s.mutex.unlock(io);
            return;
        };
        if (raw_line_opt == null) {
            const owned = gpa.dupe(u8, "stream ended") catch return;
            s.mutex.lockUncancelable(io);
            s.read_error = owned;
            s.mutex.unlock(io);
            return;
        }
        const raw_line = raw_line_opt.?;
        const line = std.mem.trimEnd(u8, raw_line, "\r");

        if (line.len == 0) {
            // Blank line → dispatch whatever we accumulated.
            if (current_name) |name| {
                const joined = std.mem.join(gpa, "\n", data_lines.items) catch "";
                const data: []u8 = @constCast(joined);
                s.mutex.lockUncancelable(io);
                s.events.append(gpa, .{ .name = name, .data = data }) catch {
                    s.mutex.unlock(io);
                    gpa.free(name);
                    gpa.free(data);
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

/// Release a blocked `readEvents` by shutting the socket's read side. Without
/// this the reader thread parks in `readv` forever on an SSE stream that
/// never ends.
fn releaseReader(s: *SseStream) void {
    s.stop.store(true, .release);
    s.req.connection.?.stream_reader.stream.shutdown(io, .recv) catch {};
}

/// Python `_collect(events_q, seconds)`: let the pump run for the whole
/// window so a slow frame is not a failure, then take everything it saw.
fn collectFrames(s: *SseStream, window_ms: i64) ![]SseEvent {
    const deadline = nowMs() + window_ms;
    while (nowMs() < deadline and !s.done.load(.acquire)) {
        Io.sleep(io, .fromMilliseconds(20), .awake) catch {};
    }
    return s.snapshot();
}

/// Open the chat SSE channel, spawn the reader, run `body`, then release +
/// join + free the stream, and return whatever the body produced.
fn withChatStream(
    comptime T: type,
    h: *Harness,
    comptime body: fn (*Harness, *SseStream) anyerror!T,
) !T {
    const s = try openSse(h.port, chat_channels);
    defer s.deinit();

    const thread = try std.Thread.spawn(.{}, readEvents, .{s});
    defer {
        releaseReader(s);
        thread.join();
    }

    return body(h, s);
}

// ============================================================================
// Frame helpers
// ============================================================================

/// One SSE frame whose `data:` payload parsed as JSON. Owns everything.
const OwnedFrame = struct {
    name: []u8,
    data: []u8,
    doc: harness.Json,

    fn deinit(self: *OwnedFrame) void {
        self.doc.deinit();
        gpa.free(self.name);
        gpa.free(self.data);
        self.* = undefined;
    }
};

/// Pop frames named `want` until one parses as JSON AND `pred` accepts it.
/// Anything else (wrong name, unparseable, predicate miss) is discarded —
/// Python's `_drain_until(events_q, predicate, timeout)`.
fn drainWhere(
    comptime Ctx: type,
    s: *SseStream,
    want: []const u8,
    timeout_ms: i64,
    ctx: Ctx,
    pred: *const fn (Ctx, *const harness.Json) bool,
) ?OwnedFrame {
    const deadline = nowMs() + timeout_ms;
    while (nowMs() < deadline) {
        const remaining = deadline - nowMs();
        var ev = s.drainUntilMatchingKeep(want, remaining) orelse return null;
        var doc: harness.Json = .{ .parsed = std.json.parseFromSlice(
            std.json.Value,
            gpa,
            ev.data,
            .{ .allocate = .alloc_always },
        ) catch {
            ev.deinit();
            continue;
        } };
        if (pred(ctx, &doc)) {
            return .{ .name = ev.name, .data = ev.data, .doc = doc };
        }
        doc.deinit();
        ev.deinit();
    }
    return null;
}

fn matchSessionId(sid: []const u8, doc: *const harness.Json) bool {
    const v = doc.get("session_id") orelse return false;
    return switch (v) {
        .string => |s| std.mem.eql(u8, s, sid),
        else => false,
    };
}

fn matchId(sid: []const u8, doc: *const harness.Json) bool {
    const v = doc.get("id") orelse return false;
    return switch (v) {
        .string => |s| std.mem.eql(u8, s, sid),
        else => false,
    };
}

const TypeAndSession = struct { typ: []const u8, sid: []const u8 };

fn matchTypeAndSession(ctx: TypeAndSession, doc: *const harness.Json) bool {
    const t = doc.get("type") orelse return false;
    const ok_type = switch (t) {
        .string => |s| std.mem.eql(u8, s, ctx.typ),
        else => false,
    };
    if (!ok_type) return false;
    return matchSessionId(ctx.sid, doc);
}

const IndexCtx = struct { index: i64 };

fn matchIndex(ctx: IndexCtx, doc: *const harness.Json) bool {
    const v = doc.get("index") orelse return false;
    return switch (v) {
        .integer => |i| i == ctx.index,
        else => false,
    };
}

const ContentCtx = struct { content: []const u8 };

fn matchContent(ctx: ContentCtx, doc: *const harness.Json) bool {
    const v = doc.get("content") orelse return false;
    return switch (v) {
        .string => |s| std.mem.eql(u8, s, ctx.content),
        else => false,
    };
}

fn isKnownEvent(name: []const u8) bool {
    for (known_events) |k| {
        if (std.mem.eql(u8, name, k)) return true;
    }
    return false;
}

/// Queue a turn on the stub profile and return the session it created.
/// Caller owns the returned slice.
fn runATurn(h: *Harness) ![]u8 {
    const req_body = try std.json.Stringify.valueAlloc(gpa, .{
        .queue_message = "android chat sse contract",
        .allowed_tools = "",
    }, .{});
    defer gpa.free(req_body);

    var r = try h.http(io, .POST, "/api/llm/session", .{
        .json_body = req_body,
        .expect = &.{201},
    });
    defer r.deinit();

    var doc = try r.json();
    defer doc.deinit();

    const sid = doc.str("session_id") orelse doc.str("id") orelse {
        std.debug.print("the create reply carried no session id: {s}\n", .{r.body});
        return error.TestUnexpectedResult;
    };
    return try gpa.dupe(u8, sid);
}

/// POST `inner` (a JSON object literal) to the test-only emitter with
/// `session_id` merged in.
fn emit(h: *Harness, sid: []const u8, inner: []const u8) !void {
    // `inner` starts with `{`; splice the session id in after it.
    const req_body = try std.fmt.allocPrint(gpa, "{{\"session_id\":\"{s}\",{s}", .{ sid, inner[1..] });
    defer gpa.free(req_body);

    var r = try h.http(io, .POST, "/api/dev/sse/emit_llm", .{
        .json_body = req_body,
        .expect = &.{200},
    });
    defer r.deinit();
}

// The test-only emitter gate (`PABRIK_TEST_SSE_EMIT=1`) reaches the child via
// `BootOptions.extra_env` — never via the parent process env, which `boot`
// must leave untouched so one suite cannot leak a gate into the next.

// ============================================================================
// The subscription itself
// ============================================================================

// The app's one channel set returns 200 SSE, not a terminated stream.
// `parseChannels` rejects an unknown token and the handler's only response to
// that is to close the stream — a 200 that never emits `connected`.
test "the_chat_channel_set_is_accepted" {
    try harness.requirePabrikBin(io, gpa);
    var h = try Harness.boot(io, gpa, .{ .stub_llm_profile = true });
    defer h.deinit(io) catch |err| {
        std.debug.print("teardown: {s}", .{@errorName(err)});
    };

    const s = try openSse(h.port, chat_channels);
    defer s.deinit();

    try testing.expectEqual(@as(u16, 200), s.status);
    if (std.mem.indexOf(u8, s.content_type, "text/event-stream") == null) {
        std.debug.print("expected SSE, got content-type {s}\n", .{s.content_type});
        return error.TestUnexpectedResult;
    }
}

// `event: connected` is the only liveness signal the server offers. The web's
// `SseClient` stays in `connecting` without it.
test "the_chat_stream_handshakes" {
    try harness.requirePabrikBin(io, gpa);
    var h = try Harness.boot(io, gpa, .{ .stub_llm_profile = true });
    defer h.deinit(io) catch |err| {
        std.debug.print("teardown: {s}", .{@errorName(err)});
    };

    const result = try withChatStream(?OwnedFrame, &h, struct {
        fn run(_: *Harness, s: *SseStream) !?OwnedFrame {
            const ev = s.drainUntilMatchingKeep("connected", 15_000) orelse return null;
            var doc: harness.Json = .{ .parsed = try std.json.parseFromSlice(
                std.json.Value,
                gpa,
                ev.data,
                .{ .allocate = .alloc_always },
            ) };
            errdefer doc.deinit();
            return OwnedFrame{ .name = ev.name, .data = ev.data, .doc = doc };
        }
    }.run);
    var frame = result orelse {
        std.debug.print("no `connected` handshake on the chat channels\n", .{});
        return error.TestUnexpectedResult;
    };
    defer frame.deinit();

    const v = frame.doc.get("connected") orelse {
        std.debug.print("handshake payload is not {{\"connected\": true}}: {s}\n", .{frame.data});
        return error.TestUnexpectedResult;
    };
    try testing.expectEqual(true, switch (v) {
        .bool => |b| b,
        else => {
            std.debug.print("handshake `connected` is not a bool: {s}\n", .{frame.data});
            return error.TestUnexpectedResult;
        },
    });
}

// `Transfer-Encoding: chunked`, because the body never ends. The reader has
// to see frames as the server writes them.
test "the_stream_is_chunked_with_no_content_length" {
    try harness.requirePabrikBin(io, gpa);
    var h = try Harness.boot(io, gpa, .{ .stub_llm_profile = true });
    defer h.deinit(io) catch |err| {
        std.debug.print("teardown: {s}", .{@errorName(err)});
    };

    const s = try openSse(h.port, chat_channels);
    defer s.deinit();

    var lower_buf: [64]u8 = undefined;
    const lower = std.ascii.lowerString(&lower_buf, s.transfer_encoding);
    if (!std.mem.eql(u8, lower, "chunked")) {
        std.debug.print("expected Transfer-Encoding: chunked, got {s}\n", .{s.transfer_encoding});
        return error.TestUnexpectedResult;
    }
    if (s.has_content_length) {
        std.debug.print("an SSE stream must not carry Content-Length\n", .{});
        return error.TestUnexpectedResult;
    }
}

// ============================================================================
// A real turn
// ============================================================================

// Every frame a turn produces is one `decodeChatFrame` has a branch for.
test "a_real_turn_emits_only_frames_the_client_decodes" {
    try harness.requirePabrikBin(io, gpa);
    var h = try Harness.boot(io, gpa, .{ .stub_llm_profile = true });
    defer h.deinit(io) catch |err| {
        std.debug.print("teardown: {s}", .{@errorName(err)});
    };

    const frames = try withChatStream([]SseEvent, &h, struct {
        fn run(hh: *Harness, s: *SseStream) ![]SseEvent {
            gpa.free(try runATurn(hh));
            return collectFrames(s, 6_000);
        }
    }.run);
    defer SseStream.freeSnapshot(frames);

    if (frames.len == 0) {
        std.debug.print("a turn produced no frames at all on the chat channels\n", .{});
        return error.TestUnexpectedResult;
    }
    for (frames) |f| {
        if (!isKnownEvent(f.name)) {
            std.debug.print(
                "unexpected frame {s} on the chat channels; either the backend gained an event the Android client drops, or the client needs a branch for it\n",
                .{f.name},
            );
            return error.TestUnexpectedResult;
        }
    }
}

// `llm_full` is the frame the client upserts into the transcript.
test "a_real_turn_delivers_a_canonical_full_row" {
    try harness.requirePabrikBin(io, gpa);
    var h = try Harness.boot(io, gpa, .{ .stub_llm_profile = true });
    defer h.deinit(io) catch |err| {
        std.debug.print("teardown: {s}", .{@errorName(err)});
    };

    const result = try withChatStream(?OwnedFrame, &h, struct {
        fn run(hh: *Harness, s: *SseStream) !?OwnedFrame {
            const sid = try runATurn(hh);
            defer gpa.free(sid);
            return drainWhere([]const u8, s, "llm_full", 10_000, sid, &matchSessionId);
        }
    }.run);
    var frame = result orelse {
        std.debug.print("the turn never delivered an llm_full frame\n", .{});
        return error.TestUnexpectedResult;
    };
    defer frame.deinit();

    const obj = switch (frame.doc.value().*) {
        .object => |o| o,
        else => {
            std.debug.print("llm_full payload is not an object: {s}\n", .{frame.data});
            return error.TestUnexpectedResult;
        },
    };
    for (full_row_keys) |k| {
        if (obj.get(k) == null) {
            std.debug.print(
                "llm_full omitted {s}; the client's row mapper reads these by name and a missing key is not the same as an empty value\n",
                .{k},
            );
            return error.TestUnexpectedResult;
        }
    }
    const id = frame.doc.str("id") orelse "";
    if (id.len == 0) {
        std.debug.print("an idless row cannot be merged, keyed, or de-duplicated\n", .{});
        return error.TestUnexpectedResult;
    }
    try testing.expectEqualStrings("full", frame.doc.str("type") orelse "");
    const role = frame.doc.str("role") orelse "";
    if (role.len == 0) {
        std.debug.print("a row with no role is drawn as neither a turn nor a tool\n", .{});
        return error.TestUnexpectedResult;
    }
    _ = frame.doc.boolean("is_error") orelse {
        std.debug.print(
            "the client branches on `is_error` to tell a diagnostic from a chat turn, so it has to be a real boolean on every row: {s}\n",
            .{frame.data},
        );
        return error.TestUnexpectedResult;
    };
}

// `finish_reason` is `"null"`, not a JSON null, on a real row.
test "a_null_finish_reason_reaches_the_wire_as_the_string_null" {
    try harness.requirePabrikBin(io, gpa);
    var h = try Harness.boot(io, gpa, .{ .stub_llm_profile = true });
    defer h.deinit(io) catch |err| {
        std.debug.print("teardown: {s}", .{@errorName(err)});
    };

    const result = try withChatStream(?OwnedFrame, &h, struct {
        fn run(hh: *Harness, s: *SseStream) !?OwnedFrame {
            const sid = try runATurn(hh);
            defer gpa.free(sid);
            return drainWhere([]const u8, s, "llm_full", 10_000, sid, &matchSessionId);
        }
    }.run);
    var frame = result orelse {
        std.debug.print("the turn never delivered an llm_full frame\n", .{});
        return error.TestUnexpectedResult;
    };
    defer frame.deinit();

    const v = frame.doc.get("finish_reason") orelse {
        std.debug.print("llm_full has no finish_reason: {s}\n", .{frame.data});
        return error.TestUnexpectedResult;
    };
    switch (v) {
        .null => {},
        .string => |str| {
            if (!std.mem.eql(u8, str, "null")) {
                std.debug.print(
                    "finish_reason is now {s}. The client filters the literal string \"null\"; if the server stopped sending it, revisit optNullableString rather than assuming the filter is dead code.\n",
                    .{str},
                );
                return error.TestUnexpectedResult;
            }
        },
        else => {
            std.debug.print("finish_reason is neither null nor a string: {s}\n", .{frame.data});
            return error.TestUnexpectedResult;
        },
    }
}

// A real row spans several `data:` lines, and the client rejoins them. The
// server serialises with `.whitespace = .indent_4` and then prefixes *each*
// resulting line.
test "every_llm_full_row_is_pretty_printed_across_data_lines" {
    try harness.requirePabrikBin(io, gpa);
    var h = try Harness.boot(io, gpa, .{ .stub_llm_profile = true });
    defer h.deinit(io) catch |err| {
        std.debug.print("teardown: {s}", .{@errorName(err)});
    };

    const result = try withChatStream(?OwnedFrame, &h, struct {
        fn run(hh: *Harness, s: *SseStream) !?OwnedFrame {
            const sid = try runATurn(hh);
            defer gpa.free(sid);
            return drainWhere([]const u8, s, "llm_full", 10_000, sid, &matchSessionId);
        }
    }.run);
    var frame = result orelse {
        std.debug.print("the turn never delivered an llm_full frame\n", .{});
        return error.TestUnexpectedResult;
    };
    defer frame.deinit();

    // The reader only produces a parsed document when the whole payload was
    // rejoined and parsed, so reaching here at all is the assertion — and the
    // newline pins the pretty-printing explicitly rather than incidentally.
    switch (frame.doc.value().*) {
        .object => {},
        else => {
            std.debug.print("llm_full payload is not an object: {s}\n", .{frame.data});
            return error.TestUnexpectedResult;
        },
    }
    if (std.mem.indexOfScalar(u8, frame.data, '\n') == null) {
        std.debug.print("llm_full arrived on a single data: line; the server stopped pretty-printing: {s}\n", .{frame.data});
        return error.TestUnexpectedResult;
    }
}

// `session_created` names the session in `id`; `queue_*` in `session_id`.
test "a_turn_announces_its_session_and_its_queue" {
    try harness.requirePabrikBin(io, gpa);
    var h = try Harness.boot(io, gpa, .{ .stub_llm_profile = true });
    defer h.deinit(io) catch |err| {
        std.debug.print("teardown: {s}", .{@errorName(err)});
    };

    const s = try openSse(h.port, chat_channels);
    defer s.deinit();

    const thread = try std.Thread.spawn(.{}, readEvents, .{s});
    defer {
        releaseReader(s);
        thread.join();
    }

    const sid = try runATurn(&h);
    defer gpa.free(sid);

    var created = drainWhere([]const u8, s, "session_created", 15_000, sid, &matchId) orelse {
        std.debug.print("no session_created frame for the new chat\n", .{});
        return error.TestUnexpectedResult;
    };
    defer created.deinit();
    try testing.expectEqualStrings(sid, created.doc.str("id") orelse "");

    var queued = drainWhere([]const u8, s, "queue_queued", 15_000, sid, &matchSessionId) orelse {
        std.debug.print("no queue_queued frame for the turn\n", .{});
        return error.TestUnexpectedResult;
    };
    defer queued.deinit();
    try testing.expectEqualStrings(sid, queued.doc.str("session_id") orelse "");
    // The decoder derives the action from the event name, so the payload's
    // own copy is informational; a disagreement means one side is guessing.
    try testing.expectEqualStrings("queued", queued.doc.str("action") orelse "");
}

// ============================================================================
// llm_chunk, through the test-only emitter
// ============================================================================

// `type: "chunk"` + `content` + `session_id` + `index`. The backend sends
// *raw provider deltas*, so the client appends rather than replaces.
test "a_chunk_frame_carries_the_fields_the_phone_appends" {
    try harness.requirePabrikBin(io, gpa);
    var h = try Harness.boot(io, gpa, .{ .stub_llm_profile = true, .extra_env = &.{.{ "PABRIK_TEST_SSE_EMIT", "1" }} });
    defer h.deinit(io) catch |err| {
        std.debug.print("teardown: {s}", .{@errorName(err)});
    };

    const result = try withChatStream(?OwnedFrame, &h, struct {
        fn run(hh: *Harness, s: *SseStream) !?OwnedFrame {
            try emit(hh, session_id_const, "{\"type\":\"chunk\",\"content\":\"Hel\",\"index\":7}");
            return drainWhere(
                TypeAndSession,
                s,
                "llm_chunk",
                15_000,
                .{ .typ = "chunk", .sid = session_id_const },
                &matchTypeAndSession,
            );
        }
    }.run);
    var frame = result orelse {
        std.debug.print("no llm_chunk frame arrived\n", .{});
        return error.TestUnexpectedResult;
    };
    defer frame.deinit();

    try testing.expectEqualStrings("chunk", frame.doc.str("type") orelse "");
    try testing.expectEqualStrings("Hel", frame.doc.str("content") orelse "");
    try testing.expectEqualStrings(session_id_const, frame.doc.str("session_id") orelse "");
    // The client reads `index` and defaults it to 0 when absent.
    if (frame.doc.get("index") == null) {
        std.debug.print("chunk frame has no `index`: {s}\n", .{frame.data});
        return error.TestUnexpectedResult;
    }
}

// A chunk with empty `content` is a chunk, not something to discard. The
// decoder drops a frame only when BOTH `content` and `reasoning_content` are
// absent.
test "an_empty_delta_still_carries_the_content_key" {
    try harness.requirePabrikBin(io, gpa);
    var h = try Harness.boot(io, gpa, .{ .stub_llm_profile = true, .extra_env = &.{.{ "PABRIK_TEST_SSE_EMIT", "1" }} });
    defer h.deinit(io) catch |err| {
        std.debug.print("teardown: {s}", .{@errorName(err)});
    };

    const result = try withChatStream(?OwnedFrame, &h, struct {
        fn run(hh: *Harness, s: *SseStream) !?OwnedFrame {
            try emit(hh, session_id_const, "{\"type\":\"chunk\",\"content\":\"\",\"index\":1}");
            return drainWhere(IndexCtx, s, "llm_chunk", 15_000, .{ .index = 1 }, &matchIndex);
        }
    }.run);
    var frame = result orelse {
        std.debug.print("an empty-content chunk never arrived\n", .{});
        return error.TestUnexpectedResult;
    };
    defer frame.deinit();

    const v = frame.doc.get("content") orelse {
        std.debug.print(
            "an empty delta must still carry the key; the client reads it with a nullable getter and cannot tell an absent key from an absent field: {s}\n",
            .{frame.data},
        );
        return error.TestUnexpectedResult;
    };
    try testing.expectEqualStrings("", switch (v) {
        .string => |str| str,
        else => {
            std.debug.print("chunk `content` is not a string: {s}\n", .{frame.data});
            return error.TestUnexpectedResult;
        },
    });
}

// `type: "chunk_final"` ends the turn; `type: "chunk"` continues it. The
// ViewModel calls `finishStreaming()` on the former and appends a delta on
// the latter.
test "a_chunk_final_frame_is_distinguishable_from_a_chunk" {
    try harness.requirePabrikBin(io, gpa);
    var h = try Harness.boot(io, gpa, .{ .stub_llm_profile = true, .extra_env = &.{.{ "PABRIK_TEST_SSE_EMIT", "1" }} });
    defer h.deinit(io) catch |err| {
        std.debug.print("teardown: {s}", .{@errorName(err)});
    };

    const result = try withChatStream(?OwnedFrame, &h, struct {
        fn run(hh: *Harness, s: *SseStream) !?OwnedFrame {
            try emit(hh, session_id_const, "{\"type\":\"chunk_final\",\"index\":3}");
            return drainWhere(
                TypeAndSession,
                s,
                "llm_chunk",
                15_000,
                .{ .typ = "chunk_final", .sid = session_id_const },
                &matchTypeAndSession,
            );
        }
    }.run);
    var frame = result orelse {
        std.debug.print("no chunk_final frame arrived\n", .{});
        return error.TestUnexpectedResult;
    };
    defer frame.deinit();

    try testing.expectEqualStrings("chunk_final", frame.doc.str("type") orelse "");
    try testing.expectEqualStrings(session_id_const, frame.doc.str("session_id") orelse "");
    // The client reads finish_reason off a chunk_final; a real run's frame
    // carries the token counts nested under `usage`, never at the top level.
    if (frame.doc.get("finish_reason") == null) {
        std.debug.print("chunk_final has no finish_reason: {s}\n", .{frame.data});
        return error.TestUnexpectedResult;
    }
    // `usage` is a nullable nested object on the real wire. Absent or null
    // are both fine — the client reports no token count — but a *top-level*
    // `total_tokens` would be the bug that `optNullableObject` exists to fix.
    if (frame.doc.get("total_tokens")) |tt| switch (tt) {
        .null => {},
        else => {
            if (frame.doc.get("usage") == null) {
                std.debug.print(
                    "total_tokens at the top level of a chunk_final is what the client used to read, and it is null on every real turn: {s}\n",
                    .{frame.data},
                );
                return error.TestUnexpectedResult;
            }
        },
    };
}

// `is_error: true` has to survive the trip, or a retry notice is a turn. The
// client renders a diagnostic as an error card and never persists it.
test "a_diagnostic_delta_is_flagged_is_error" {
    try harness.requirePabrikBin(io, gpa);
    var h = try Harness.boot(io, gpa, .{ .stub_llm_profile = true, .extra_env = &.{.{ "PABRIK_TEST_SSE_EMIT", "1" }} });
    defer h.deinit(io) catch |err| {
        std.debug.print("teardown: {s}", .{@errorName(err)});
    };

    const s = try openSse(h.port, chat_channels);
    defer s.deinit();

    const thread = try std.Thread.spawn(.{}, readEvents, .{s});
    defer {
        releaseReader(s);
        thread.join();
    }

    try emit(&h, session_id_const, "{\"type\":\"full\",\"content\":\"TooManyRetries\",\"index\":0,\"role\":\"assistant\",\"finish_reason\":\"stop\",\"is_error\":true}");

    var frame = drainWhere(ContentCtx, s, "llm_chunk", 15_000, .{ .content = "TooManyRetries" }, &matchContent) orelse
        drainWhere(ContentCtx, s, "llm_full", 15_000, .{ .content = "TooManyRetries" }, &matchContent) orelse {
        std.debug.print("the is_error frame never arrived\n", .{});
        return error.TestUnexpectedResult;
    };
    defer frame.deinit();

    if (!isKnownEvent(frame.name)) {
        std.debug.print("an unknown event name for a diagnostic: {s}\n", .{frame.name});
        return error.TestUnexpectedResult;
    }
    const flag = frame.doc.boolean("is_error") orelse {
        std.debug.print(
            "is_error was not carried; the client branches on it to avoid writing a diagnostic into the transcript: {s}\n",
            .{frame.data},
        );
        return error.TestUnexpectedResult;
    };
    try testing.expectEqual(true, flag);
}
