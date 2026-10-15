// Functional tests for the `session_created` SSE gate. ─── THE BUG THIS FILE
// PINS ──────────────────────────────────────────────── The user's report:
// "when i queue message why i fetch sessions ?" — the Network tab showed

const std = @import("std");
const testing = std.testing;
const harness = @import("harness.zig");
const Harness = harness.Harness;

const Io = std.Io;

const gpa = testing.allocator;
const io = testing.io;

const transfer_buffer_len = 8 * 1024;

fn nowMs() i64 {
    return Io.Timestamp.now(io, .awake).toMilliseconds();
}

const SseEvent = struct {
    name: []u8,
    data: []u8,

    fn deinit(self: *SseEvent) void {
        gpa.free(self.name);
        gpa.free(self.data);
        self.* = undefined;
    }
};

const SseStream = struct {
    client: std.http.Client,
    req: std.http.Client.Request,
    transfer_buffer: [transfer_buffer_len]u8 = undefined,
    body: *Io.Reader = undefined,
    status: u16 = 0,
    content_type: []u8 = "",
    stop: std.atomic.Value(bool) = .init(false),
    done: std.atomic.Value(bool) = .init(false),
    mutex: Io.Mutex = .init,
    events: std.ArrayList(SseEvent) = .empty,
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

fn openSse(port: u16, channels: []const u8) !*SseStream {
    const s = try gpa.create(SseStream);
    errdefer gpa.destroy(s);

    s.* = .{ .client = .{ .allocator = gpa, .io = io }, .req = undefined };

    const url = try std.fmt.allocPrint(gpa, "http://127.0.0.1:{d}/api/events?channels={s}", .{ port, channels });
    defer gpa.free(url);

    s.req = s.client.request(.GET, try std.Uri.parse(url), .{
        .redirect_behavior = .unhandled,
        .extra_headers = &.{
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
            if (current_name) |name| {
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
    }
}

fn releaseReader(s: *SseStream) void {
    s.stop.store(true, .release);
    s.req.connection.?.stream_reader.stream.shutdown(io, .recv) catch {};
}

/// Pop events until one is named `want`, the stream ends, or the deadline
/// passes.
fn drainMatching(s: *SseStream, want: []const u8, timeout_ms: i64) bool {
    const deadline = nowMs() + timeout_ms;
    while (true) {
        s.mutex.lockUncancelable(io);
        if (s.events.items.len > 0) {
            var e = s.events.orderedRemove(0);
            s.mutex.unlock(io);
            defer e.deinit();
            if (std.mem.eql(u8, e.name, want)) return true;
            continue;
        }
        const finished = s.done.load(.acquire);
        s.mutex.unlock(io);
        if (finished) return false;
        if (nowMs() >= deadline) return false;
        Io.sleep(io, .fromMilliseconds(20), .awake) catch {};
    }
}

/// How many queued frames are named `want` right now.
fn countNamed(s: *SseStream, want: []const u8) usize {
    s.mutex.lockUncancelable(io);
    defer s.mutex.unlock(io);
    var n: usize = 0;
    for (s.events.items) |e| {
        if (std.mem.eql(u8, e.name, want)) n += 1;
    }
    return n;
}

/// A copy of the queued event names, for a failure message.
fn seenNames(s: *SseStream) []u8 {
    s.mutex.lockUncancelable(io);
    defer s.mutex.unlock(io);
    var out: std.Io.Writer.Allocating = .init(gpa);
    errdefer out.deinit();
    for (s.events.items) |e| out.writer.print("{s} ", .{e.name}) catch break;
    // `toOwnedSlice` can only fail with OutOfMemory, and a best-effort
    // DIAGNOSTIC string is the wrong place to propagate one — the caller
    // is already on the failure path.
    return out.toOwnedSlice() catch @panic("toOwnedSlice of the rendered event list failed");
}

/// `POST /api/llm/session` with a queue_message — the exact wire body the
/// desktop app's `api.sendChatMessage` sends (minus the media fields).
fn sendMessage(h: *Harness, session_id: []const u8, message: []const u8) !void {
    const body = try std.fmt.allocPrint(
        gpa,
        "{{\"session_id\":\"{s}\",\"queue_message\":\"{s}\",\"cwd_session\":\"{s}\"}}",
        .{ session_id, message, h.temp_dir },
    );
    defer gpa.free(body);

    var r = try h.http(io, .POST, "/api/llm/session", .{
        .json_body = body,
        // 201 = queued. 500 is accepted too: with the stub profile the
        // worker's LLM call fails, and some builds surface that as a 500
        // AFTER the session row + SSE frame are already committed.
        .expect = &.{ 201, 500 },
    });
    r.deinit();
}

/// `PUT /api/llm/session/:id` — auto-creates the row via
/// `ensureSessionExists`, so a session can exist before any message is sent.
fn ensureSession(h: *Harness, session_id: []const u8, name: []const u8) !void {
    const path = try std.fmt.allocPrint(gpa, "/api/llm/session/{s}", .{session_id});
    defer gpa.free(path);
    const body = try std.fmt.allocPrint(gpa, "{{\"name\":\"{s}\"}}", .{name});
    defer gpa.free(body);
    var r = try h.http(io, .PUT, path, .{ .json_body = body, .expect = &.{200} });
    r.deinit();
}

// ============================================================================
// Test 1: a send into an EXISTING session emits NO session_created
// ============================================================================

// The regression.
test "send_into_existing_session_emits_no_session_created" {
    try harness.requirePabrikBin(io, gpa);

    var h = try Harness.boot(io, gpa, .{ .stub_llm_profile = true });
    defer h.deinit(io) catch |err| {
        std.debug.print("teardown: {s}\n", .{@errorName(err)});
    };

    const session_id = "sess_no_refetch_001";
    try ensureSession(&h, session_id, "Existing chat");

    const s = try openSse(h.port, "sessions");
    defer s.deinit();
    const reader = try std.Thread.spawn(.{}, readEvents, .{s});
    defer reader.join();

    // Positive control: the stream is live.
    if (!drainMatching(s, "connected", 3_000)) {
        releaseReader(s);
        std.debug.print("no connected handshake on the sessions channel\n", .{});
        return error.TestUnexpectedResult;
    }

    // The send under test.
    try sendMessage(&h, session_id, "hello there");

    // Give a buggy backend every chance to emit: the frontend's own
    // debounce is 400 ms, so wait well past it.
    Io.sleep(io, .fromMilliseconds(1_500), .awake) catch {};

    const created = countNamed(s, "session_created");
    releaseReader(s);

    if (created != 0) {
        const names = seenNames(s);
        defer gpa.free(names);
        std.debug.print(
            "send into existing session {s} emitted {d} session_created frame(s); saw: [{s}]\n",
            .{ session_id, created, names },
        );
        return error.TestUnexpectedResult;
    }
}

// ============================================================================
// Test 2: a send that CREATES the session DOES emit session_created
// ============================================================================

// The other half of the contract, and the reason the gate is `db.changes() >
// 0` rather than "never emit".
test "send_that_creates_session_emits_session_created" {
    try harness.requirePabrikBin(io, gpa);

    var h = try Harness.boot(io, gpa, .{ .stub_llm_profile = true });
    defer h.deinit(io) catch |err| {
        std.debug.print("teardown: {s}\n", .{@errorName(err)});
    };

    const session_id = "sess_fresh_create_001";

    const s = try openSse(h.port, "sessions");
    defer s.deinit();
    const reader = try std.Thread.spawn(.{}, readEvents, .{s});
    defer reader.join();

    if (!drainMatching(s, "connected", 3_000)) {
        releaseReader(s);
        std.debug.print("no connected handshake on the sessions channel\n", .{});
        return error.TestUnexpectedResult;
    }

    try sendMessage(&h, session_id, "first message");

    const got = drainMatching(s, "session_created", 5_000);
    releaseReader(s);

    if (!got) {
        const names = seenNames(s);
        defer gpa.free(names);
        std.debug.print(
            "send that creates session {s} emitted no session_created within 5s; saw: [{s}]\n",
            .{ session_id, names },
        );
        return error.TestUnexpectedResult;
    }
}
