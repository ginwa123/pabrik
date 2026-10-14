// Functional tests for SSE end-to-end.
//
// Zig port of `tests/functional/sse_endtoend_test.py` (same test names,
// same order).
//
// Python docstring, preserved verbatim:
//
//   """Functional tests for SSE end-to-end.
//
//   Open an EventSource on /api/events, trigger a backend event, assert
//   the event arrives within 1s. The trickiest test in the suite — SSE
//   has backpressure, the connection must stay open across the test,
//   and the read loop must use a thread to avoid blocking the test.
//
//   Plan: docs/superpowers/plans/2026-07-26-functional-tests-with-real-data.md (Chunk 8)
//   """
//
// ─── WHY THERE IS A HAND-ROLLED SSE CLIENT HERE ─────────────────────────────
// `Harness.http` CANNOT open an SSE stream: it calls
// `reader.streamRemaining(...)`, which on a `text/event-stream` response
// blocks until the server closes the connection — and the server holds
// the stream open forever, so `streamRemaining` never returns. Python's
// `urllib.request.urlopen` returns as soon as the RESPONSE HEAD is
// parsed and drains the body line-by-line on a separate thread with a
// deadline; this port keeps that shape with `std.http.Client` directly,
// `req.receiveHead(&.{})` for the status + Content-Type, then a reader
// thread that pulls ONE LINE at a time and pushes parsed frames into a
// queue the test drains with a deadline.
//
// `background_process_sse_test.zig` has the same client. It is not
// `@import`ed from here because each suite owns its files; the two are
// deliberate duplicates rather than a shared module this worker is not
// allowed to add.
//
// ─── WHY THE QUEUE SEMANTICS ARE EXACT ──────────────────────────────────────
// Python's `_drain_until` POPS events and DISCARDS every non-matching
// one; test 4 relies on that, first draining the three `kanban_column`
// events the kanban create produced and only then asserting that a NEW
// one arrives after the add-column call. A "does the event list contain
// a match?" scan — which is the cheaper shape and is what
// `background_process_sse_test.zig` uses for its single handshake frame
// — would pass here on the events the trigger never produced. So
// `drainMatching` below removes the head of the queue on every
// iteration, exactly as `queue.Queue.get` did.

const std = @import("std");
const testing = std.testing;
const harness = @import("harness.zig");
const Harness = harness.Harness;

const Io = std.Io;

const gpa = testing.allocator;
const io = testing.io;

/// Transfer buffer for the response body reader.
///
/// NOT `&.{}`: `Response.reader(transfer_buffer)` uses the slice as the
/// reader's own buffer for a chunked body, and a frame without a `\n`
/// yet would immediately exhaust it. An SSE frame here is a few hundred
/// bytes, so 8 KiB is generous.
const transfer_buffer_len = 8 * 1024;

/// Monotonic milliseconds (`.awake` is monotonic, not wall clock — an
/// NTP step must not stretch or shrink a deadline).
fn nowMs() i64 {
    return Io.Timestamp.now(io, .awake).toMilliseconds();
}

/// One parsed SSE frame: the `event:` name plus the joined `data:` lines.
///
/// Python also ran `json.loads` over the payload and put the resulting
/// object on the queue. No assertion in this file reads the payload —
/// every predicate is `e == "<name>"` — so the raw text is kept instead
/// of a parsed tree, which also keeps the reader thread allocation-free
/// of a parse arena.
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
/// `stop` / `done` are the cross-thread handshake.
const SseStream = struct {
    client: std.http.Client,
    req: std.http.Client.Request,
    /// The transfer buffer `body` reads out of. Owned here so its
    /// address outlives every read.
    transfer_buffer: [transfer_buffer_len]u8 = undefined,
    /// `req.reader` after `resp.reader(&transfer_buffer)`.
    body: *Io.Reader = undefined,
    status: u16 = 0,
    /// Duplicated from the response head (which `resp.reader()`
    /// invalidates).
    content_type: []u8 = "",
    /// Set by the test thread to release the reader.
    stop: std.atomic.Value(bool) = .init(false),
    /// Set by the reader thread once it has stopped touching `events`.
    done: std.atomic.Value(bool) = .init(false),
    /// Frames parsed so far — Python's `queue.Queue`.
    ///
    /// Guarded by `mutex`: the reader thread appends while the test
    /// thread pops, and an unsynchronised read during the reader's
    /// `append` is a use-after-free (the ArrayList realloc frees the old
    /// buffer). `lockUncancelable` rather than `lock` because there is
    /// no cancellation point worth honouring inside a test.
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
/// head. The caller owns the returned pointer and must `deinit` it.
fn openSse(port: u16, channels: []const u8) !*SseStream {
    const s = try gpa.create(SseStream);
    errdefer gpa.destroy(s);

    // `gpa.create` returns UNINITIALIZED memory — it does NOT run the
    // struct's field default initializers. Every field with a default
    // (`mutex`, `stop`, `done`, `events`, `read_error`) must be
    // assigned here or it stays garbage, and an uninitialised
    // `Io.Mutex` is not a lock at all: `lockUncancelable` on garbage
    // state parks the test thread on a futex nobody will ever wake.
    // `s.* = .{...}` applies all the defaults in one shot; `req` is
    // genuinely assigned by `request()` below.
    s.* = .{ .client = .{ .allocator = gpa, .io = io }, .req = undefined };

    const url = try std.fmt.allocPrint(gpa, "http://127.0.0.1:{d}/api/events?channels={s}", .{ port, channels });
    defer gpa.free(url);

    s.req = s.client.request(.GET, try std.Uri.parse(url), .{
        .redirect_behavior = .unhandled,
        .extra_headers = &.{
            // What the browser's `EventSource` sends. The handler keys
            // off the query string, but sending it keeps the request
            // byte-identical to the one under test.
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

/// Read SSE frames from `s` until `stop` is set, the stream ends, or an
/// error occurs. Runs on its own thread.
///
/// The SSE grammar (per `unified_events_sse.zig`'s `forwardToClients`):
///
///     event: <name>\n
///     data: <line>\n
///     \n            <- blank line dispatches the frame
///
/// `data:` lines are joined with `\n`; a frame with an `event:` but no
/// `data:` dispatches with an empty payload.
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
        // incremental.
        //
        // `takeDelimiter` — NEVER `takeDelimiterExclusive`. The
        // Exclusive variant advances "up to (BUT NOT PAST) the
        // delimiter", so the `\n` stays in the buffer; the next call
        // finds a delimiter at position 0 and returns a ZERO-LENGTH
        // slice, forever. The loop livelocks at full speed and never
        // reaches clean EOF, so a closed stream reads as still-open.
        // `takeDelimiter` consumes the delimiter and maps clean EOF to
        // `null`, which is exactly Python's `readline()` returning
        // `b""`.
        const raw_line_opt = reader.takeDelimiter('\n') catch |err| {
            // `takeDelimiter` has a NARROWER error set than the
            // delimiter-splitting variants: clean EOF is `null`, not
            // `error.EndOfStream`. Only real I/O failures and an
            // over-long line reach here.
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
        // Reported through the SAME `read_error` channel as a failure —
        // the test only needs to know the reader stopped, and it
        // already polls that.
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
                // `[]const u8`; the constCast is sound because the
                // buffer is ours to hand to `gpa.free` (and nothing
                // mutates it).
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

/// Release a blocked `readEvents` by shutting the socket's read side.
///
/// Without this the reader thread parks in `readv` forever on an SSE
/// stream that never ends. `shutdown(SHUT_RD)` makes the pending
/// `readv` return 0, which `netReadPosix` reports as
/// `error.EndOfStream`, and the reader exits its loop.
fn releaseReader(s: *SseStream) void {
    s.stop.store(true, .release);
    s.req.connection.?.stream_reader.stream.shutdown(io, .recv) catch {};
}

/// Pop events off the queue until one is named `want`, the stream ends,
/// or the deadline passes. Returns true iff a MATCHING event was seen.
///
/// Consuming (rather than scanning) is the point — see the file header.
/// Python's `_drain_until(events_q, lambda e, d: e == want, timeout)`.
fn drainMatching(s: *SseStream, want: []const u8, timeout_ms: i64) bool {
    const deadline = nowMs() + timeout_ms;
    while (true) {
        s.mutex.lockUncancelable(io);
        if (s.events.items.len > 0) {
            var e = s.events.orderedRemove(0);
            s.mutex.unlock(io);
            // Scoped so the block's `defer` frees this event before the
            // next iteration takes the lock again.
            {
                defer e.deinit();
                if (std.mem.eql(u8, e.name, want)) return true;
            }
            continue;
        }
        // Snapshot `done` under the SAME lock, then RELEASE before
        // sleeping. Holding the mutex across `Io.sleep` starves the
        // reader: the loop re-acquires the instant the sleep ends, so
        // the reader — which needs the same lock to append — can miss
        // every window and the deadline expires with zero events seen.
        const finished = s.done.load(.acquire);
        s.mutex.unlock(io);

        // Nothing more is coming: the reader has stopped.
        if (finished) return false;
        if (nowMs() >= deadline) return false;
        Io.sleep(io, .fromMilliseconds(20), .awake) catch {};
    }
}

/// Discard up to `max_n` queued events, waiting at most `wait_ms` for
/// EACH one and breaking out of the loop on the first miss.
///
/// Python: `for _ in range(5): try events_q.get(timeout=0.3) except
/// queue.Empty: break`.
fn discardQueued(s: *SseStream, max_n: usize, wait_ms: i64) usize {
    var dropped: usize = 0;
    while (dropped < max_n) {
        const deadline = nowMs() + wait_ms;
        var got_one = false;
        while (true) {
            s.mutex.lockUncancelable(io);
            if (s.events.items.len > 0) {
                var e = s.events.orderedRemove(0);
                s.mutex.unlock(io);
                e.deinit();
                got_one = true;
                break;
            }
            const finished = s.done.load(.acquire);
            s.mutex.unlock(io);
            if (finished) return dropped;
            if (nowMs() >= deadline) break;
            Io.sleep(io, .fromMilliseconds(20), .awake) catch {};
        }
        if (!got_one) break;
        dropped += 1;
    }
    return dropped;
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

/// Why the reader stopped, or "" if it is still going.
fn readerReason(s: *SseStream) []u8 {
    s.mutex.lockUncancelable(io);
    defer s.mutex.unlock(io);
    const m = s.read_error orelse return gpa.dupe(u8, "") catch @panic("dupe of the empty SSE read_error failed");
    return gpa.dupe(u8, m) catch @panic("dupe of the SSE read_error failed");
}

/// `_create_workspace` — create a fresh workspace, return its OWNED id.
fn createWorkspace(h: *Harness) ![]u8 {
    var r = try h.http(io, .POST, "/api/workspaces", .{
        .json_body = "{\"name\":\"sse-ws\"}",
        .expect = &.{201},
    });
    defer r.deinit();
    var doc = try r.json();
    defer doc.deinit();
    const id = doc.str("id") orelse {
        std.debug.print("workspace create returned no id: {s}\n", .{r.body});
        return error.TestUnexpectedResult;
    };
    return gpa.dupe(u8, id);
}

/// `_create_kanban` — return the kanban item's OWNED id.
///
/// The backend returns the wrapped `{item, columns}` envelope (the
/// frontend's `api.createKanban` destructure relies on it); see
/// `workspace_items_create_kanban.zig::CreateKanbanResponseFull`.
fn createKanban(h: *Harness, ws_id: []const u8) ![]u8 {
    const url = try std.fmt.allocPrint(gpa, "/api/workspaces/{s}/items/kanban", .{ws_id});
    defer gpa.free(url);

    var r = try h.http(io, .POST, url, .{
        .json_body = "{\"name\":\"sse-kanban\"}",
        .expect = &.{201},
    });
    defer r.deinit();
    var doc = try r.json();
    defer doc.deinit();
    const item = doc.object("item") orelse {
        std.debug.print("kanban create has no `item` envelope: {s}\n", .{r.body});
        return error.TestUnexpectedResult;
    };
    const id_val = item.get("id") orelse {
        std.debug.print("kanban item has no id: {s}\n", .{r.body});
        return error.TestUnexpectedResult;
    };
    const id = switch (id_val) {
        .string => |sv| sv,
        else => {
            std.debug.print("kanban item id is not a string: {s}\n", .{r.body});
            return error.TestUnexpectedResult;
        },
    };
    return gpa.dupe(u8, id);
}

// ============================================================================
// Test 1: /api/events returns 200 with text/event-stream
// ============================================================================

// `GET /api/events?channels=workers` returns 200 with the SSE content type.
//
// No reader thread here: only the HEAD is needed, and the Python used a
// `with urlopen(...)` block that never read the body. `openSse` parses
// the head and stops there.
test "sse_handshake_returns_200" {
    try harness.requirePabrikBin(io, gpa);
    var h = try Harness.boot(io, gpa, .{});
    defer h.deinit(io) catch |err| {
        std.debug.print("teardown: {s}", .{@errorName(err)});
    };

    const s = try openSse(h.port, "workers");
    defer s.deinit();

    try testing.expectEqual(@as(u16, 200), s.status);
    if (std.mem.indexOf(u8, s.content_type, "text/event-stream") == null) {
        std.debug.print("SSE should have text/event-stream content-type, got '{s}'\n", .{s.content_type});
        return error.TestUnexpectedResult;
    }
}

// ============================================================================
// Test 2: connected event fires on subscribe
// ============================================================================

// Opening /api/events emits a `connected` event.
test "sse_connected_event_fires_on_subscribe" {
    try harness.requirePabrikBin(io, gpa);
    var h = try Harness.boot(io, gpa, .{});
    defer h.deinit(io) catch |err| {
        std.debug.print("teardown: {s}", .{@errorName(err)});
    };

    const s = try openSse(h.port, "workers");
    defer s.deinit();
    const reader = try std.Thread.spawn(.{}, readEvents, .{s});
    defer reader.join();

    const got = drainMatching(s, "connected", 3_000);
    // Release BEFORE asserting: the `defer reader.join()` above blocks
    // on a socket read that never returns on its own, so a failing
    // assertion here would hang the suite instead of failing it.
    releaseReader(s);

    if (!got) {
        const names = seenNames(s);
        defer gpa.free(names);
        const reason = readerReason(s);
        defer gpa.free(reason);
        if (reason.len > 0) {
            std.debug.print("expected 'connected' event within 3s, stream reported: {s}\n", .{reason});
        } else {
            std.debug.print("expected 'connected' event within 3s of subscribing; saw: [{s}]\n", .{names});
        }
        return error.TestUnexpectedResult;
    }
}

// ============================================================================
// Test 3: kanban create emits a kanban_column event
// ============================================================================

// Open SSE on the kanban channel; POST a kanban; assert a
// `kanban_column` event arrives.
test "kanban_create_emits_sse_event" {
    try harness.requirePabrikBin(io, gpa);
    var h = try Harness.boot(io, gpa, .{});
    defer h.deinit(io) catch |err| {
        std.debug.print("teardown: {s}", .{@errorName(err)});
    };

    const s = try openSse(h.port, "kanban");
    defer s.deinit();
    const reader = try std.Thread.spawn(.{}, readEvents, .{s});
    defer reader.join();

    // Wait for the connected event to be sure the stream is open.
    _ = drainMatching(s, "connected", 2_000);

    // Trigger: create a kanban (seeds 3 columns → 3 events).
    const ws_id = try createWorkspace(&h);
    defer gpa.free(ws_id);
    const kanban_id = try createKanban(&h, ws_id);
    defer gpa.free(kanban_id);

    const got = drainMatching(s, "kanban_column", 3_000);
    releaseReader(s);

    if (!got) {
        const names = seenNames(s);
        defer gpa.free(names);
        std.debug.print("expected a kanban_column SSE event within 3s of kanban create; saw: [{s}]\n", .{names});
        return error.TestUnexpectedResult;
    }
}

// ============================================================================
// Test 4: kanban column add emits another kanban_column event
// ============================================================================

// `POST /columns` emits a `kanban_column` event.
//
// The queue is drained FIRST, and that is what makes this test mean
// something: the kanban create above already emitted three
// `kanban_column` frames, and a "is one in the list?" check would find
// one of those and pass without the add-column ever being pushed.
test "kanban_add_column_emits_event" {
    try harness.requirePabrikBin(io, gpa);
    var h = try Harness.boot(io, gpa, .{});
    defer h.deinit(io) catch |err| {
        std.debug.print("teardown: {s}", .{@errorName(err)});
    };

    const s = try openSse(h.port, "kanban");
    defer s.deinit();
    const reader = try std.Thread.spawn(.{}, readEvents, .{s});
    defer reader.join();

    _ = drainMatching(s, "connected", 2_000);

    const ws_id = try createWorkspace(&h);
    defer gpa.free(ws_id);
    const kanban_id = try createKanban(&h, ws_id);
    defer gpa.free(kanban_id);

    // Drain the initial events from the kanban create.
    const drained = discardQueued(s, 5, 300);
    if (drained == 0) {
        // The Python's loop silently broke out of an empty queue here
        // and then still asserted on a NEW event. Refusing to continue
        // would change the test; keeping the count only makes the
        // vacuity visible if this ever starts failing for the wrong
        // reason.
        std.debug.print("note: kanban create queued {d} events before the drain\n", .{drained});
    }

    // Trigger: add a 4th column.
    {
        const url = try std.fmt.allocPrint(
            gpa,
            "/api/workspaces/{s}/items/{s}/kanban/columns",
            .{ ws_id, kanban_id },
        );
        defer gpa.free(url);
        var r = try h.http(io, .POST, url, .{
            .json_body = "{\"name\":\"extra\"}",
            .expect = &.{201},
        });
        defer r.deinit();
    }

    const got = drainMatching(s, "kanban_column", 3_000);
    releaseReader(s);

    if (!got) {
        const names = seenNames(s);
        defer gpa.free(names);
        std.debug.print("expected a kanban_column SSE event after add-column; saw: [{s}]\n", .{names});
        return error.TestUnexpectedResult;
    }
}

// ============================================================================
// Test 5: SSE client disconnect does not crash pabrik
// ============================================================================

// Open SSE, close it, then prove the server is still serving: a
// subsequent API call works.
test "sse_drops_quietly_when_client_closes" {
    try harness.requirePabrikBin(io, gpa);
    var h = try Harness.boot(io, gpa, .{});
    defer h.deinit(io) catch |err| {
        std.debug.print("teardown: {s}", .{@errorName(err)});
    };

    const s = try openSse(h.port, "workers");
    defer s.deinit();
    const reader = try std.Thread.spawn(.{}, readEvents, .{s});
    // Registered AFTER `s.deinit`, so LIFO runs the JOIN first: a
    // reader thread still parked in `readv` would read a socket the
    // teardown already closed.
    defer reader.join();

    // Wait briefly to ensure the SSE connection is registered.
    Io.sleep(io, .fromMilliseconds(200), .awake) catch {};
    // Close the client side.
    releaseReader(s);
    // Give the server a moment to notice.
    Io.sleep(io, .fromMilliseconds(200), .awake) catch {};

    // Subsequent API call should still work (server didn't crash).
    var r = try h.http(io, .GET, "/api/workspaces", .{ .expect = &.{200} });
    defer r.deinit();
    var doc = try r.json();
    defer doc.deinit();
    if (doc.get("workspaces") == null) {
        std.debug.print("GET /api/workspaces has no `workspaces` key after the SSE drop: {s}\n", .{r.body});
        return error.TestUnexpectedResult;
    }
}
