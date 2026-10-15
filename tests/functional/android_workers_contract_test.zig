// Wire-contract test for the native Android "worker is running" indicator.
// Zig port of `tests/functional/android_workers_contract_test.py` (same test
// names, same order).

const std = @import("std");
const testing = std.testing;
const harness = @import("harness.zig");
const Harness = harness.Harness;
const gpa = testing.allocator;
const io = testing.io;
const Io = std.Io;

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

    /// Pop the FIRST frame named `want`, discarding everything before it.
    /// Returns true iff a matching event was seen — Python's
    /// `_drain_until(events_q, lambda e, d: e == want, timeout)`.
    fn drainUntilMatching(self: *SseStream, want: []const u8, timeout_ms: i64) bool {
        const deadline = nowMs() + timeout_ms;
        while (true) {
            self.mutex.lockUncancelable(io);
            if (self.events.items.len > 0) {
                var e = self.events.orderedRemove(0);
                self.mutex.unlock(io);
                const hit = std.mem.eql(u8, e.name, want);
                e.deinit();
                if (hit) return true;
                continue;
            }
            // Snapshot `done` under the SAME lock, then RELEASE before
            // sleeping: holding the mutex across the sleep starves the
            // reader, which needs the same lock to append.
            const finished = self.done.load(.acquire);
            self.mutex.unlock(io);
            if (finished) return false;
            if (nowMs() >= deadline) return false;
            Io.sleep(io, .fromMilliseconds(20), .awake) catch {};
        }
    }

    /// Pop the FIRST frame named `want`, discarding everything before it, and
    /// RETURN it (ownership passes to the caller).
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
        // One LINE, not the whole stream — that is what makes the read
        // incremental.
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

// ============================================================================
// HTTP helpers
// ============================================================================

/// An owned response body plus a SELF-CONTAINED parse (`.alloc_always`,
/// so nothing aliases `bytes`).
const OwnedDoc = struct {
    bytes: []u8,
    doc: harness.Json,

    fn deinit(self: *OwnedDoc) void {
        self.doc.deinit();
        gpa.free(self.bytes);
        self.* = undefined;
    }

    /// The `workers` array, borrowed from `self.doc`.
    fn workers(self: *const OwnedDoc, ctx: []const u8) !std.json.Array {
        const v = self.doc.get("workers") orelse {
            std.debug.print("{s}: payload has no `workers`: {s}\n", .{ ctx, self.bytes });
            return error.TestUnexpectedResult;
        };
        return switch (v) {
            .array => |a| a,
            else => {
                std.debug.print("{s}: `workers` is not an array: {s}\n", .{ ctx, self.bytes });
                return error.TestUnexpectedResult;
            },
        };
    }
};

fn requestDoc(h: *Harness, method: harness.HttpMethod, path: []const u8, opts: harness.Harness.HttpOptions) !OwnedDoc {
    var r = try h.http(io, method, path, opts);
    defer r.deinit();
    const bytes = try gpa.dupe(u8, r.body);
    return .{
        .bytes = bytes,
        .doc = .{ .parsed = try std.json.parseFromSlice(
            std.json.Value,
            gpa,
            bytes,
            .{ .allocate = .alloc_always },
        ) },
    };
}

/// `GET /api/workers` with the given query params → the payload document.
fn getWorkers(h: *Harness, params: []const Harness.Param) !OwnedDoc {
    return requestDoc(h, .GET, "/api/workers", .{ .params = params, .expect = &.{200} });
}

/// Python `_running_ids`: presence of a row, `session_id` or `id`.
fn runningIds(doc: *const OwnedDoc, ctx: []const u8) ![]u8 {
    const rows = try doc.workers(ctx);
    var out: std.Io.Writer.Allocating = .init(gpa);
    errdefer out.deinit();
    for (rows.items) |row| {
        const obj = switch (row) {
            .object => |o| o,
            else => continue,
        };
        var session_id: []const u8 = "";
        if (obj.get("session_id")) |v| switch (v) {
            .string => |s| {
                if (s.len > 0) session_id = s;
            },
            else => {},
        };
        if (session_id.len == 0) {
            if (obj.get("id")) |v| switch (v) {
                .string => |s| session_id = s,
                else => {},
            };
        }
        if (session_id.len == 0) continue;
        out.writer.print("{s}\n", .{session_id}) catch return error.OutOfMemory;
    }
    return out.toOwnedSlice();
}

/// True iff `hay` (newline-separated ids) contains `needle`.
fn idsContain(hay: []const u8, needle: []const u8) bool {
    var it = std.mem.splitScalar(u8, hay, '\n');
    while (it.next()) |line| {
        if (std.mem.eql(u8, line, needle)) return true;
    }
    return false;
}

/// Python `_read_workers_until_populated`: poll until a row shows up.
fn readWorkersUntilPopulated(h: *Harness, timeout_ms: i64) !OwnedDoc {
    const deadline = nowMs() + timeout_ms;
    var last = try getWorkers(h, &.{.{ .name = "limit", .value = "50" }});
    errdefer last.deinit();
    while (nowMs() < deadline) {
        if ((try last.workers("poll")).items.len > 0) return last;
        last.deinit();
        last = try getWorkers(h, &.{.{ .name = "limit", .value = "50" }});
        Io.sleep(io, .fromMilliseconds(50), .awake) catch {};
    }
    return last;
}

/// `POST /api/llm/session {"queue_message": ..., "allowed_tools": ""}`. Used
/// only to make a worker register/deregister; the run itself is answered by
/// the harness's stub LLM.
fn queueLlmRun(h: *Harness, message: []const u8) !void {
    const body = try std.json.Stringify.valueAlloc(gpa, .{
        .queue_message = message,
        .allowed_tools = "",
    }, .{});
    defer gpa.free(body);

    var r = try h.http(io, .POST, "/api/llm/session", .{
        .json_body = body,
        .expect = &.{201},
    });
    defer r.deinit();
}

/// Open the workers SSE channel, run `body` with the reader already spawned,
/// then release + join + free the stream, and return whatever the body
/// produced.
fn withWorkerStream(
    comptime T: type,
    h: *Harness,
    comptime body: fn (*Harness, *SseStream) anyerror!T,
) !T {
    const s = try openSse(h.port, "workers");
    defer s.deinit();

    const thread = try std.Thread.spawn(.{}, readEvents, .{s});
    defer {
        releaseReader(s);
        thread.join();
    }

    return body(h, s);
}

/// The presence projection for ONE row: `session_id` preferred, `id` as the
/// fallback, empty when neither is usable. Borrows `obj`.
fn projectedId(obj: std.json.ObjectMap) []const u8 {
    if (obj.get("session_id")) |v| switch (v) {
        .string => |s| {
            if (s.len > 0) return s;
        },
        else => {},
    };
    if (obj.get("id")) |v| switch (v) {
        .string => |s| return s,
        else => {},
    };
    return "";
}

// ============================================================================
// GET /api/workers
// ============================================================================

// `workers` + `count`, and an array even with nothing running.
// `WorkerApi.parseRunningSessionIds` reads `workers` only.
test "workers_list_carries_the_envelope_the_android_client_reads" {
    try harness.requirePabrikBin(io, gpa);
    var h = try Harness.boot(io, gpa, .{});
    defer h.deinit(io) catch |err| {
        std.debug.print("teardown: {s}", .{@errorName(err)});
    };

    var payload = try getWorkers(&h, &.{.{ .name = "limit", .value = "50" }});
    defer payload.deinit();

    const rows = try payload.workers("workers envelope");
    const count = payload.doc.int("count") orelse {
        std.debug.print("workers payload has no integer `count`: {s}\n", .{payload.bytes});
        return error.TestUnexpectedResult;
    };
    // The Kotlin ignores `count`; it must not be the only thing that changes.
    try testing.expectEqual(@as(i64, @intCast(rows.items.len)), count);
}

// Every row must carry `id`, and `session_id` must be a string or null. `id`
// is the fallback the client uses whenever `session_id` is empty, so a row
// missing it entirely is a session the client cannot key a spinner on.
test "workers_list_keeps_the_id_fields_the_android_client_reads" {
    try harness.requirePabrikBin(io, gpa);
    var h = try Harness.boot(io, gpa, .{});
    defer h.deinit(io) catch |err| {
        std.debug.print("teardown: {s}", .{@errorName(err)});
    };

    try queueLlmRun(&h, "pin the workers contract");

    var payload = try readWorkersUntilPopulated(&h, 1000);
    defer payload.deinit();

    const rows = try payload.workers("workers id fields");
    if (rows.items.len == 0) {
        std.debug.print("SKIP: the stub LLM finishes the run before the list is readable\n", .{});
        return error.SkipZigTest;
    }

    for (rows.items) |row| {
        const obj = switch (row) {
            .object => |o| o,
            else => {
                std.debug.print("worker row is not an object: {s}\n", .{payload.bytes});
                return error.TestUnexpectedResult;
            },
        };
        const id = switch (obj.get("id") orelse {
            std.debug.print("worker row has no `id`: {s}\n", .{payload.bytes});
            return error.TestUnexpectedResult;
        }) {
            .string => |s| s,
            else => {
                std.debug.print("worker row `id` is not a string: {s}\n", .{payload.bytes});
                return error.TestUnexpectedResult;
            },
        };
        if (id.len == 0) {
            std.debug.print("worker row `id` is empty: {s}\n", .{payload.bytes});
            return error.TestUnexpectedResult;
        }
        if (obj.get("session_id")) |v| switch (v) {
            .string, .null => {},
            else => {
                std.debug.print("worker row `session_id` is neither null nor a string: {s}\n", .{payload.bytes});
                return error.TestUnexpectedResult;
            },
        };

        // The client's projection: presence, with `session_id` preferred.
        if (projectedId(obj).len == 0) {
            std.debug.print(
                "presence projection dropped row id '{s}': {s}\n",
                .{ id, payload.bytes },
            );
            return error.TestUnexpectedResult;
        }
    }
}

// `status`/`is_running` are literals — which is why presence is the signal.
// This is not an assertion that the backend is right; it pins the behaviour
// the Kotlin parser deliberately ignores.
test "every_returned_worker_row_reports_itself_as_running" {
    try harness.requirePabrikBin(io, gpa);
    var h = try Harness.boot(io, gpa, .{});
    defer h.deinit(io) catch |err| {
        std.debug.print("teardown: {s}", .{@errorName(err)});
    };

    var payload = try getWorkers(&h, &.{.{ .name = "limit", .value = "50" }});
    defer payload.deinit();

    const rows = try payload.workers("worker row literals");
    for (rows.items) |row| {
        const obj = switch (row) {
            .object => |o| o,
            else => {
                std.debug.print("worker row is not an object: {s}\n", .{payload.bytes});
                return error.TestUnexpectedResult;
            },
        };
        const is_running = switch (obj.get("is_running") orelse {
            std.debug.print("worker row has no `is_running`: {s}\n", .{payload.bytes});
            return error.TestUnexpectedResult;
        }) {
            .bool => |b| b,
            else => {
                std.debug.print("`is_running` is not a bool: {s}\n", .{payload.bytes});
                return error.TestUnexpectedResult;
            },
        };
        try testing.expectEqual(true, is_running);

        const status = switch (obj.get("status") orelse {
            std.debug.print("worker row has no `status`: {s}\n", .{payload.bytes});
            return error.TestUnexpectedResult;
        }) {
            .string => |s| s,
            else => {
                std.debug.print("`status` is not a string: {s}\n", .{payload.bytes});
                return error.TestUnexpectedResult;
            },
        };
        try testing.expectEqualStrings("running", status);

        // `queue_count` defaults to 0 in Python's assertion; only its type
        // matters here.
        if (obj.get("queue_count")) |v| switch (v) {
            .integer => {},
            else => {
                std.debug.print("`queue_count` is not an integer: {s}\n", .{payload.bytes});
                return error.TestUnexpectedResult;
            },
        };
    }
}

// `limit` caps the list, and the client's default is the server's default.
test "workers_limit_is_honoured" {
    try harness.requirePabrikBin(io, gpa);
    var h = try Harness.boot(io, gpa, .{});
    defer h.deinit(io) catch |err| {
        std.debug.print("teardown: {s}", .{@errorName(err)});
    };

    var one = try getWorkers(&h, &.{.{ .name = "limit", .value = "1" }});
    defer one.deinit();
    var many = try getWorkers(&h, &.{.{ .name = "limit", .value = "50" }});
    defer many.deinit();

    const one_rows = try one.workers("limit=1");
    const many_rows = try many.workers("limit=50");
    if (one_rows.items.len > 1) {
        std.debug.print("limit=1 returned {d} rows: {s}\n", .{ one_rows.items.len, one.bytes });
        return error.TestUnexpectedResult;
    }
    if (many_rows.items.len < one_rows.items.len) {
        std.debug.print("limit=50 returned fewer rows than limit=1: {s} vs {s}\n", .{ many.bytes, one.bytes });
        return error.TestUnexpectedResult;
    }

    if (one_rows.items.len == 0) return;
    const one_ids = try runningIds(&one, "limit=1 ids");
    defer gpa.free(one_ids);
    const many_ids = try runningIds(&many, "limit=50 ids");
    defer gpa.free(many_ids);
    var it = std.mem.splitScalar(u8, one_ids, '\n');
    while (it.next()) |id| {
        if (id.len == 0) continue;
        if (!idsContain(many_ids, id)) {
            std.debug.print("id '{s}' is in limit=1 but not in limit=50\n", .{id});
            return error.TestUnexpectedResult;
        }
    }
}

// ============================================================================
// GET /api/workers?session_id=…
// ============================================================================

// An idle session answers `workers: []`, never an absent field.
test "workers_by_session_id_returns_an_empty_array_not_a_missing_key" {
    try harness.requirePabrikBin(io, gpa);
    var h = try Harness.boot(io, gpa, .{});
    defer h.deinit(io) catch |err| {
        std.debug.print("teardown: {s}", .{@errorName(err)});
    };

    var payload = try getWorkers(&h, &.{
        .{ .name = "session_id", .value = "task_that_never_existed" },
        .{ .name = "limit", .value = "1" },
    });
    defer payload.deinit();

    const rows = try payload.workers("session_id filter");
    if (rows.items.len != 0) {
        std.debug.print("an unknown session should answer `workers: []`: {s}\n", .{payload.bytes});
        return error.TestUnexpectedResult;
    }
    const count = payload.doc.int("count") orelse {
        std.debug.print("workers payload has no integer `count`: {s}\n", .{payload.bytes});
        return error.TestUnexpectedResult;
    };
    try testing.expectEqual(@as(i64, 0), count);
}

// ============================================================================
// GET /api/events?channels=workers
// ============================================================================

// `channels=workers` returns 200 SSE and a `connected` frame.
test "workers_channel_handshake" {
    try harness.requirePabrikBin(io, gpa);
    var h = try Harness.boot(io, gpa, .{});
    defer h.deinit(io) catch |err| {
        std.debug.print("teardown: {s}", .{@errorName(err)});
    };

    // The handshake itself: 200 + an SSE content-type.
    {
        const s = try openSse(h.port, "workers");
        defer s.deinit();
        try testing.expectEqual(@as(u16, 200), s.status);
        if (std.mem.indexOf(u8, s.content_type, "text/event-stream") == null) {
            std.debug.print("expected SSE content-type, got '{s}'\n", .{s.content_type});
            return error.TestUnexpectedResult;
        }
    }

    _ = try withWorkerStream(void, &h, struct {
        fn body(h2: *Harness, s: *SseStream) !void {
            _ = h2;
            if (!s.drainUntilMatching("connected", 5000)) {
                std.debug.print("no `connected` handshake on the workers channel\n", .{});
                return error.TestUnexpectedResult;
            }
        }
    }.body);
}

// One connection, four channels, and a typo in it is silent.
// `SseChannels.eventsPath()` is `llm,queue,sessions,workers` and it is the
// app's only subscription.
test "the_shared_channel_set_carries_everything_the_app_needs" {
    try harness.requirePabrikBin(io, gpa);
    var h = try Harness.boot(io, gpa, .{});
    defer h.deinit(io) catch |err| {
        std.debug.print("teardown: {s}", .{@errorName(err)});
    };

    const channel_sets = [_][]const u8{
        "llm,queue,sessions,workers",
        "llm",
        "queue",
        "sessions",
        "workers",
    };
    for (channel_sets) |channels| {
        const s = openSse(h.port, channels) catch |err| {
            std.debug.print("channels={s}: handshake failed: {s}\n", .{ channels, @errorName(err) });
            return err;
        };
        defer s.deinit();
        try testing.expectEqual(@as(u16, 200), s.status);
        if (std.mem.indexOf(u8, s.content_type, "text/event-stream") == null) {
            std.debug.print("channels={s}: expected SSE content-type, got '{s}'\n", .{ channels, s.content_type });
            return error.TestUnexpectedResult;
        }
        // Nothing is subscribed to a stream nobody reads; close the socket
        // so the server is not left holding a dead peer.
        releaseReader(s);
    }
}

// `id` is always present, and `session_id` never disagrees with it. This is
// the invariant `decodeChatFrame` actually depends on.
test "worker_frames_always_carry_the_id_the_android_client_falls_back_to" {
    try harness.requirePabrikBin(io, gpa);
    var h = try Harness.boot(io, gpa, .{});
    defer h.deinit(io) catch |err| {
        std.debug.print("teardown: {s}", .{@errorName(err)});
    };

    const frames = try withWorkerStream([]SseEvent, &h, struct {
        fn body(h2: *Harness, s: *SseStream) ![]SseEvent {
            try queueLlmRun(h2, "wake a worker");
            return collectFrames(s, 3000);
        }
    }.body);
    defer SseStream.freeSnapshot(frames);

    var worker_frames: usize = 0;
    for (frames) |*e| {
        if (!std.mem.startsWith(u8, e.name, "worker_")) continue;
        worker_frames += 1;

        var doc: harness.Json = .{ .parsed = try std.json.parseFromSlice(
            std.json.Value,
            gpa,
            e.data,
            .{ .allocate = .alloc_always },
        ) };
        defer doc.deinit();

        const obj = switch (doc.value().*) {
            .object => |o| o,
            else => {
                std.debug.print("{s}: worker frame payload is not an object: {s}\n", .{ e.name, e.data });
                return error.TestUnexpectedResult;
            },
        };

        const id = switch (obj.get("id") orelse {
            std.debug.print("{s} omitted `id`; the client cannot fall back: {s}\n", .{ e.name, e.data });
            return error.TestUnexpectedResult;
        }) {
            .string => |s| s,
            else => {
                std.debug.print("{s}: `id` is not a string: {s}\n", .{ e.name, e.data });
                return error.TestUnexpectedResult;
            },
        };
        if (id.len == 0) {
            std.debug.print("{s}: `id` is empty: {s}\n", .{ e.name, e.data });
            return error.TestUnexpectedResult;
        }

        // The key is always present, even when blank — the client reads it
        // with `optString`, which yields "" for both a missing key and an
        // empty one.
        const sid_value = obj.get("session_id") orelse {
            std.debug.print("{s}: `session_id` key is absent: {s}\n", .{ e.name, e.data });
            return error.TestUnexpectedResult;
        };
        const session_id: ?[]const u8 = switch (sid_value) {
            .string => |s| s,
            .null => null,
            else => {
                std.debug.print("{s}: `session_id` is neither null nor a string: {s}\n", .{ e.name, e.data });
                return error.TestUnexpectedResult;
            },
        };
        if (session_id) |sid| {
            if (sid.len > 0 and !std.mem.eql(u8, sid, id)) {
                std.debug.print(
                    "{s} named two different sessions: session_id='{s}' id='{s}'. " ++
                        "The client prefers session_id, so a mismatch lights the " ++
                        "spinner on a session the worker is not running.\n",
                    .{ e.name, sid, id },
                );
                return error.TestUnexpectedResult;
            }
        }
    }

    if (worker_frames == 0) {
        std.debug.print(
            "SKIP: no worker frame in the window; the loop finished before the pump saw it\n",
            .{},
        );
        return error.SkipZigTest;
    }
}

// The delete path specifically: `session_id` is `""`, not merely absent.
test "a_worker_delete_frame_ships_an_empty_session_id" {
    try harness.requirePabrikBin(io, gpa);
    var h = try Harness.boot(io, gpa, .{});
    defer h.deinit(io) catch |err| {
        std.debug.print("teardown: {s}", .{@errorName(err)});
    };

    // `drainUntilMatchingKeep` CONSUMES the frames it scans past and hands
    // back the matching one, which is what Python's
    // `_, data = found` needs.
    var found = try withWorkerStream(?SseEvent, &h, struct {
        fn body(h2: *Harness, s: *SseStream) !?SseEvent {
            try queueLlmRun(h2, "start then stop");
            return s.drainUntilMatchingKeep("worker_deleted", 8000);
        }
    }.body);
    defer if (found) |*f| f.deinit();

    if (found == null) {
        std.debug.print("SKIP: no worker_deleted in the window; the loop had not finished\n", .{});
        return error.SkipZigTest;
    }

    var doc: harness.Json = .{ .parsed = try std.json.parseFromSlice(
        std.json.Value,
        gpa,
        found.?.data,
        .{ .allocate = .alloc_always },
    ) };
    defer doc.deinit();

    const session_id = doc.str("session_id") orelse {
        std.debug.print(
            "worker_deleted no longer populates session_id: {s}\n" ++
                "The client still handles it, but the Kotlin case that pins the " ++
                "empty string should be revisited to say which shape is on the wire.\n",
            .{found.?.data},
        );
        return error.TestUnexpectedResult;
    };
    try testing.expectEqualStrings("", session_id);

    const id = doc.str("id") orelse "";
    if (id.len == 0) {
        std.debug.print("worker_deleted carries an empty `id`: {s}\n", .{found.?.data});
        return error.TestUnexpectedResult;
    }
}

// `worker_created` / `worker_updated` / `worker_deleted`, and nothing else.
test "worker_frames_use_the_event_names_the_android_client_decodes" {
    try harness.requirePabrikBin(io, gpa);
    var h = try Harness.boot(io, gpa, .{});
    defer h.deinit(io) catch |err| {
        std.debug.print("teardown: {s}", .{@errorName(err)});
    };

    const frames = try withWorkerStream([]SseEvent, &h, struct {
        fn body(h2: *Harness, s: *SseStream) ![]SseEvent {
            try queueLlmRun(h2, "name the worker frames");
            return collectFrames(s, 3000);
        }
    }.body);
    defer SseStream.freeSnapshot(frames);

    const known = [_][]const u8{
        "connected",
        "worker_created",
        "worker_updated",
        "worker_deleted",
        "worker_unknown",
    };
    for (frames) |e| {
        var matched = false;
        for (known) |k| {
            if (std.mem.eql(u8, e.name, k)) {
                matched = true;
                break;
            }
        }
        if (!matched) {
            std.debug.print(
                "unexpected frame '{s}' on the workers channel; either the " ++
                    "backend gained an event the Android client drops, or the " ++
                    "client needs a branch for it\n",
                .{e.name},
            );
            return error.TestUnexpectedResult;
        }
    }
}

// ============================================================================
// Body-analysis barrier
// ============================================================================

comptime {
    _ = nowMs;
    _ = SseEvent.deinit;
    _ = SseStream.deinit;
    _ = SseStream.snapshot;
    _ = SseStream.freeSnapshot;
    _ = SseStream.drainUntilMatching;
    _ = SseStream.drainUntilMatchingKeep;
    _ = openSse;
    _ = readEvents;
    _ = releaseReader;
    _ = collectFrames;
    _ = OwnedDoc.deinit;
    _ = OwnedDoc.workers;
    _ = requestDoc;
    _ = getWorkers;
    _ = runningIds;
    _ = idsContain;
    _ = readWorkersUntilPopulated;
    _ = queueLlmRun;
    _ = projectedId;
    _ = withWorkerStream;
}
