// Functional e2e for background_process SSE push. Zig port of
// `tests/functional/background_process_sse_test.py` (same test names, same
// order).

const std = @import("std");
const testing = std.testing;
const harness = @import("harness.zig");
const Harness = harness.Harness;

const Io = std.Io;

const gpa = testing.allocator;
const io = testing.io;

/// How long the stream may take to deliver the `connected` handshake.
/// Python `_drain_until(..., timeout_s=3.0)`.
const handshake_timeout_ms: i64 = 3_000;

/// Transfer buffer for the response body reader.
const transfer_buffer_len = 8 * 1024;

/// Monotonic milliseconds (`.awake` = monotonic, not wall clock).
fn nowMs() i64 {
    return std.Io.Timestamp.now(io, .awake).toMilliseconds();
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

/// An open SSE connection plus the state the reader thread fills in. The test
/// thread owns the pointer; the reader thread writes into it. `stop` / `done`
/// are the cross-thread handshake — see `readEvents`.
const SseStream = struct {
    client: std.http.Client,
    req: std.http.Client.Request,
    /// The transfer buffer `body` reads out of. Owned here so its
    /// address outlives every read.
    transfer_buffer: [transfer_buffer_len]u8 = undefined,
    /// `req.reader` after `resp.reader(&transfer_buffer)`.
    body: *std.Io.Reader = undefined,
    status: u16 = 0,
    /// Duplicated from the response head (which `resp.reader()`
    /// invalidates).
    content_type: []u8 = "",
    /// Set by the test thread to release the reader.
    stop: std.atomic.Value(bool) = .init(false),
    /// Set by the reader thread once it has stopped touching `events`.
    done: std.atomic.Value(bool) = .init(false),
    /// Frames parsed so far.
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
        const gpa2 = gpa;
        gpa2.destroy(self);
    }
};

/// Open `GET /api/events?channels=<channels>` and capture the response
/// head. Caller owns the returned pointer and must `deinit` it.
fn openSse(port: u16, channels: []const u8) !*SseStream {
    const s = try gpa.create(SseStream);
    errdefer gpa.destroy(s);

    // `gpa.create` returns UNINITIALIZED memory — it does NOT run the
    // struct's field default initializers.
    s.* = .{ .client = .{ .allocator = gpa, .io = io }, .req = undefined };

    const url = try std.fmt.allocPrint(gpa, "http://127.0.0.1:{d}/api/events?channels={s}", .{ port, channels });
    defer gpa.free(url);

    s.req = s.client.request(.GET, try std.Uri.parse(url), .{
        .redirect_behavior = .unhandled,
        .extra_headers = &.{
            // What the browser's `EventSource` sends; the handler keys
            // off the query string, not this, but sending it keeps the
            // request identical to the one under test.
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

    // Headers FIRST: `resp.reader()` calls `head.invalidateStrings()`,
    // so touching `head` afterwards is a use-after-free.
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

/// Read SSE frames from `s` until `stop` is set, the stream ends, or an error
/// occurs. Runs on its own thread.
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
        const raw_line_opt = reader.takeDelimiter('\n') catch |err| {
            // `takeDelimiter` has a NARROWER error set than the
            // delimiter-splitting variants: clean EOF is `null`, not
            // `error.EndOfStream`.
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
        // A clean server close: `null` here, not `error.EndOfStream`.
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
                // `std.mem.join` allocates an owned buffer but types it
                // `[]const u8`; the constCast is sound because the buffer is
                // ours to hand to `gpa.free` (and nothing mutates it).
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
        // `:` comment lines and unknown fields are ignored, matching
        // both the browser EventSource parser and the Python reader.
    }
}

/// Release a blocked `readEvents` by shutting the socket's read side. Without
/// this the reader thread parks in `readv` forever on an SSE stream that
/// never ends.
fn releaseReader(s: *SseStream) void {
    s.stop.store(true, .release);
    s.req.connection.?.stream_reader.stream.shutdown(io, .recv) catch {};
}

/// Wait until an event named `want` is in `s.events`, or the deadline
/// passes. Returns true iff the event was seen.
fn waitForEvent(s: *SseStream, want: []const u8, timeout_ms: i64) bool {
    const deadline = nowMs() + timeout_ms;
    while (true) {
        // Snapshot under the lock, then RELEASE it before sleeping.
        s.mutex.lockUncancelable(io);
        const found = blk: {
            for (s.events.items) |e| {
                if (std.mem.eql(u8, e.name, want)) break :blk true;
            }
            break :blk false;
        };
        const finished = s.done.load(.acquire);
        s.mutex.unlock(io);

        if (found) return true;
        // Nothing more is coming: the reader has stopped.
        if (finished) return false;
        if (nowMs() >= deadline) return false;
        std.Io.sleep(io, .fromMilliseconds(20), .awake) catch {};
    }
}

/// A copy of the event names seen so far, for the failure message.
fn seenNames(s: *SseStream) []u8 {
    s.mutex.lockUncancelable(io);
    defer s.mutex.unlock(io);
    var out: std.Io.Writer.Allocating = .init(gpa);
    errdefer out.deinit();
    for (s.events.items) |e| out.writer.print("{s} ", .{e.name}) catch break;
    // `toOwnedSlice` can only fail with OutOfMemory, and a
    // best-effort DIAGNOSTIC string is the wrong place to propagate
    // one — the caller is already on the failure path.
    return out.toOwnedSlice() catch |err| {
        out.deinit();
        std.debug.print("could not render the seen-events list: {s}\n", .{@errorName(err)});
        return gpa.dupe(u8, "<unavailable>") catch @panic("dupe of the <unavailable> literal failed");
    };
}

// GET /api/events?channels=background_process returns 200 SSE + connected.
test "background_process_channel_handshake" {
    try harness.requirePabrikBin(io, gpa);
    var h = try Harness.boot(io, gpa, .{});
    defer h.deinit(io) catch |err| {
        std.debug.print("teardown: {s}\n", .{@errorName(err)});
    };

    const s = try openSse(h.port, "background_process");
    defer s.deinit();

    try testing.expectEqual(@as(u16, 200), s.status);
    if (std.mem.indexOf(u8, s.content_type, "text/event-stream") == null) {
        std.debug.print("expected SSE content-type, got '{s}'\n", .{s.content_type});
        return error.TestUnexpectedResult;
    }

    const reader = try std.Thread.spawn(.{}, readEvents, .{s});
    defer reader.join();

    const got = waitForEvent(s, "connected", handshake_timeout_ms);
    releaseReader(s);

    if (!got) {
        const names = seenNames(s);
        defer gpa.free(names);

        s.mutex.lockUncancelable(io);
        const reason = if (s.read_error) |m| m else "";
        s.mutex.unlock(io);

        if (reason.len > 0) {
            std.debug.print("expected 'connected' event within 3s, stream reported: {s}\n", .{reason});
        } else {
            std.debug.print("expected 'connected' event within 3s; saw: [{s}]\n", .{names});
        }
        return error.TestUnexpectedResult;
    }
}

// Frontend fetches once on mount — list endpoint still 200 with shape.
test "background_process_list_still_serves_initial_fetch" {
    try harness.requirePabrikBin(io, gpa);
    var h = try Harness.boot(io, gpa, .{});
    defer h.deinit(io) catch |err| {
        std.debug.print("teardown: {s}\n", .{@errorName(err)});
    };

    // A real session id, not a made-up shape: the list handler is keyed
    // on the sessions table and answers `{ processes: [], count: 0 }`
    // for a session that exists with no background rows.
    const session_id = "sess_bg_sse_001";

    {
        const path = try std.fmt.allocPrint(gpa, "/api/llm/session/{s}", .{session_id});
        defer gpa.free(path);
        const body = try std.fmt.allocPrint(gpa, "{{\"name\":\"bg-sse-{s}\"}}", .{session_id});
        defer gpa.free(body);
        var r = try h.http(io, .PUT, path, .{ .json_body = body, .expect = &.{200} });
        defer r.deinit();
    }

    const path = try std.fmt.allocPrint(gpa, "/api/llm/session/{s}/background_processes", .{session_id});
    defer gpa.free(path);
    var r = try h.http(io, .GET, path, .{ .expect = &.{200} });
    defer r.deinit();

    var doc = try r.json();
    defer doc.deinit();

    // `assert body["processes"] == []` — an ABSENT key must fail, so
    // `orelse` rather than a defaulted empty array.
    const processes = doc.array("processes") orelse {
        std.debug.print("background_processes body has no `processes` array: {s}\n", .{r.body});
        return error.TestUnexpectedResult;
    };
    if (processes.items.len != 0) {
        std.debug.print("expected no background processes, got {d}: {s}\n", .{ processes.items.len, r.body });
        return error.TestUnexpectedResult;
    }

    const count = doc.int("count") orelse {
        std.debug.print("background_processes body has no integer `count`: {s}\n", .{r.body});
        return error.TestUnexpectedResult;
    };
    try testing.expectEqual(@as(i64, 0), count);
}