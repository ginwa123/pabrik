// Functional tests for the `session_created` SSE gate.
//
// ─── THE BUG THIS FILE PINS ────────────────────────────────────────────────
// The user's report: "when i queue message why i fetch sessions ?" — the
// Network tab showed three requests for one send:
//
//   1. POST /api/llm/session                     (the send itself)
//   2. GET  /api/llm/session/:sid/background_processes
//   3. GET  /api/llm/session?sort_by=updated_at&direction=desc&limit=30
//
// Request 3 is the desktop sidebar (ChatsList.vue) re-fetching its whole
// list. It fires because `App.insert_worker` — the concurrent task behind
// `emit_run_agent`, i.e. behind EVERY send — ran
// `INSERT OR IGNORE INTO sessions` and then emitted `session_created`
// UNCONDITIONALLY. `INSERT OR IGNORE` is a no-op for a row that already
// exists, which is every send into an existing chat, so the backend was
// announcing "a session was created" for a session that was not.
//
// The frontend's `onSessionEvent` → `scheduleSseReload` (400 ms debounce)
// → `loadChats()` treats that as "the list changed" and refetches page 1.
//
// ─── THE FIX ───────────────────────────────────────────────────────────────
// `insert_worker` now reads `db.changes()` immediately after the INSERT
// (per-connection state, and `exec` holds the backend mutex for the whole
// statement, so nothing can interleave) and returns early when it is 0.
// Same idiom as `llm_history.saveProgressiveTool` and every primitive in
// `skill_evals_db.zig`.
//
// ─── WHY A FUNCTIONAL TEST AND NOT A UNIT TEST ────────────────────────────
// `insert_worker` is a private method on the process-wide `App` singleton
// and reaches the event bus through `getSingleton()`. A unit test would
// have to build a whole `App` (db, Io, logger, event bus, server) and keep
// every pointer alive across the call — the first attempt did exactly that
// and died with a general-protection fault inside `db.exec`'s mutex,
// because the `Io.Threaded` the backend captured had already been torn
// down. The honest witness is the real binary over a real socket: boot it,
// open an SSE stream on the `sessions` channel, send a message, and count
// the `session_created` frames that arrive.
//
// The other two requests in the screenshot are legitimate and are NOT
// asserted against here: `POST /api/llm/session` is the send itself, and
// `background_processes` is BackgroundCommandsPopup's mount fetch.

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
/// passes. Consuming (not scanning) is deliberate — see the file header of
/// `sse_endtoend_test.zig` for why a "does the list contain a match?" check
/// would pass on frames the trigger never produced.
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
///
/// The stub LLM profile points at a port that never answers, so the worker
/// will fail its first LLM call. That is fine and is the point: the
/// `session_created` emit happens in `insert_worker`, BEFORE any LLM call,
/// so the frame under test is on the wire regardless of what the model does.
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
        // AFTER the session row + SSE frame are already committed. The
        // assertion is on the SSE frame, not on this status.
        .expect = &.{ 201, 500 },
    });
    r.deinit();
}

/// `PUT /api/llm/session/:id` — auto-creates the row via
/// `ensureSessionExists`, so a session can exist before any message is
/// sent. This is how the test sets up the "existing session" case without
/// depending on a first send succeeding.
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

// The regression. The session row already exists (created by the PUT), so
// `insert_worker`'s `INSERT OR IGNORE` is a no-op — and pre-fix it emitted
// `session_created` anyway, which is what made the sidebar refetch.
//
// The assertion is an ABSENCE, so it needs a positive control: the same
// stream must have delivered the `connected` handshake, proving the
// subscription is live and a missing frame means "not emitted" rather than
// "never listened". Without that control this test would pass against a
// server that emits nothing at all.
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

// The other half of the contract, and the reason the gate is
// `db.changes() > 0` rather than "never emit". A brand-new session must
// still announce itself, or the sidebar would never show a new chat until
// a manual refresh.
//
// No PUT here: the row does not exist yet, so `insert_worker`'s INSERT is
// the one that creates it.
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
