// SSE auth-rejection must terminate the stream, never hang it.
//
// Zig port of `tests/functional/sse_auth_test.py` (same test names,
// same order).
//
// Wire regression for "SSE always connecting on app launch": kabelweb
// sends the SSE 200 headers BEFORE the handler runs, so the handler's
// `res.jsonResponse(401)` on auth failure never reached the wire. The
// client stayed registered and received heartbeats forever without ever
// seeing `event: connected` — SseClient sat in 'connecting' forever.
//
// Contract pinned here:
//   * `--auth` on, no cookie: stream carries `event: auth_error`, then
//     ENDS promptly (EOF). No immortal `data: ping` tail, no `connected`.
//   * `--auth` on, valid cookie: `event: connected` arrives (happy path).
//   * unknown `?channels=` token: stream ENDS promptly (same zombie
//     pattern lived on the 400 paths).
//
// Boots a real binary against an isolated tmpdir HOME (never port 8081).
//
// ── WHY THERE IS A HAND-ROLLED SSE CLIENT HERE ─────────────────────────────
// `Harness.http` CANNOT read this endpoint: it calls
// `reader.streamRemaining(...)`, which on a `text/event-stream` response
// blocks until the server closes the connection — and a healthy SSE
// stream never closes, so `streamRemaining` never returns. The idiom
// below is the one `background_process_sse_test.zig` established:
// `std.http.Client` directly, `req.sendBodiless()`, `req.receiveHead`
// for the status + Content-Type, then `resp.reader(&buf)` read LINE BY
// LINE on a watchdog thread that `shutdown(.recv)`s the socket to
// release a parked read.
//
// This suite needs one capability the background-process port does not:
// it must distinguish EOF from a TIMEOUT (every assertion here is "the
// stream ENDED"). So `readEvents` records `eof` separately from
// `read_error`, and `waitForEnd` polls `done`.
//
// `SseStream` is heap-allocated, not returned by value: `std.http.Client`
// embeds a `ConnectionPool` with an `Io.Mutex` and `Response.request`
// points back at the request, so the trio is UNCOPYABLE — a by-value
// return bit-copies the mutex state and leaves `resp.request` dangling.

const std = @import("std");
const testing = std.testing;
const harness = @import("harness.zig");
const Harness = harness.Harness;

const gpa = testing.allocator;
const io = testing.io;

/// Python `_read_sse(..., timeout_s=10.0)` — the unauth + unknown-channel
/// budgets.
const reject_timeout_ms: i64 = 10_000;
/// Python `_read_sse(..., timeout_s=8.0)` — the authed happy path.
const authed_timeout_ms: i64 = 8_000;

/// Transfer buffer for the response body reader.
///
/// NOT `&.{}`: `Response.reader(transfer_buffer)` uses that slice as the
/// reader's own buffer for a chunked body, and `takeDelimiter` reports
/// `error.StreamTooLong` the moment the buffer fills without a newline
/// — which, on a stream with no `\n` yet, is immediately. An SSE frame
/// is a few hundred bytes, so 8 KiB is generous.
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

/// An open SSE connection plus the state the reader thread fills in.
///
/// The test thread owns the pointer; the reader thread writes into it.
/// `stop` / `done` are the cross-thread handshake — see `readEvents`.
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
    ///
    /// `events`, `eof` and `read_error` are guarded by `mutex`: the
    /// reader thread appends while the test thread polls, and an
    /// unsynchronised read of `events.items` during the reader's
    /// `append` is a use-after-free. `Io.Mutex` is the equivalent of
    /// Python's `queue.Queue`.
    mutex: std.Io.Mutex = .init,
    events: std.ArrayList(SseEvent) = .empty,
    /// Set by the reader thread when the stream ended cleanly. This is
    /// the assertion every test here makes — a rejected stream must
    /// CLOSE, not merely stop emitting.
    eof: bool = false,
    /// Set by the reader thread when the stream errored or ended for a
    /// reason other than EOF.
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

/// Open `GET /api/events?channels=<channels>` and capture the response
/// head. Caller owns the returned pointer and must `deinit` it.
fn openSse(port: u16, channels: []const u8, cookie: ?[]const u8) !*SseStream {
    const s = try gpa.create(SseStream);
    errdefer gpa.destroy(s);

    // `gpa.create` returns UNINITIALIZED memory — it does NOT run the
    // struct's field default initializers. `s.* = .{}` applies all of
    // them in one shot; an uninitialised `Io.Mutex` is not a lock at
    // all, and `lockUncancelable` on garbage state parks the test
    // thread on a futex nobody will ever wake.
    s.* = .{ .client = .{ .allocator = gpa, .io = io }, .req = undefined };

    const url = try std.fmt.allocPrint(gpa, "http://127.0.0.1:{d}/api/events?channels={s}", .{ port, channels });
    defer gpa.free(url);

    // `extra_headers` borrows the array for the duration of the
    // request, so the array must stay alive until `receiveHead`
    // returns. A FIXED-SIZE array with a runtime length does that in
    // one frame; an `if`-expression returning two differently-sized
    // array literals would not compile (the if-else must agree on a
    // single type).
    var extra: [2]std.http.Header = undefined;
    extra[0] = .{ .name = "Accept", .value = "text/event-stream" };
    const header_count: usize = if (cookie) |c| blk: {
        extra[1] = .{ .name = "Cookie", .value = c };
        break :blk extra.len;
    } else 1;

    s.req = s.client.request(.GET, try std.Uri.parse(url), .{
        .redirect_behavior = .unhandled,
        .extra_headers = extra[0..header_count],
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
    // so touching `head` afterwards is a use-after-free (a general
    // protection fault inside `mem.eqlBytes`).
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
/// The SSE grammar (per unified_events_sse.zig `forwardToClients` and
/// `terminateSseStream`):
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
        // ONE LINE, not the whole stream: this is what makes the read
        // incremental.
        //
        // `takeDelimiter` (NOT `takeDelimiterExclusive`) is the correct
        // primitive, and the difference is load-bearing.
        // `takeDelimiterExclusive` "advances the seek position up to
        // (but NOT past) the delimiter" — it leaves the `\n` in the
        // buffer. The next call therefore finds that same `\n`
        // immediately and returns an EMPTY slice, forever. A reader
        // built on it livelocks: it spins on empty strings, never sees
        // `error.EndOfStream`, and a `waitForEnd` deadline expires with
        // the stream long since closed. It "works" only when the first
        // line of the stream is the event you were waiting for, which
        // is why the background-process port never noticed.
        //
        // `takeDelimiter` consumes the delimiter and maps a clean
        // end-of-stream to `null` — exactly Python's `readline()`
        // returning `b""`. `raw_line` borrows the reader's buffer and
        // is copied out below before the next read.
        const maybe_line = reader.takeDelimiter('\n') catch |err| {
            const msg = switch (err) {
                error.ReadFailed => "read failed",
                error.StreamTooLong => "line exceeded the transfer buffer",
            };
            s.mutex.lockUncancelable(io);
            s.eof = false;
            s.read_error = gpa.dupe(u8, msg) catch null;
            s.mutex.unlock(io);
            return;
        } orelse {
            // `null` == the server closed the stream cleanly. This is
            // the EOF every assertion in this suite is about.
            s.mutex.lockUncancelable(io);
            s.eof = true;
            s.read_error = gpa.dupe(u8, "stream ended") catch null;
            s.mutex.unlock(io);
            return;
        };
        const line = std.mem.trimEnd(u8, maybe_line, "\r");

        if (line.len == 0) {
            // Blank line → dispatch whatever we accumulated.
            if (current_name) |name| {
                // `std.mem.join` allocates an owned buffer but types it
                // `[]const u8`; the constCast is sound because the
                // buffer is ours to hand to `gpa.free`.
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

/// Spawn the reader thread and register the defer that makes every
/// early-return path safe.
///
/// `releaseReader` MUST precede `join`: a stream the server holds open
/// parks the reader in `readv` forever, and `join` on a parked thread
/// deadlocks the whole suite. Registering the pair as ONE defer means
/// a `return error.TestUnexpectedResult` half way through a test cannot
/// skip the shutdown.
fn spawnReader(s: *SseStream) !std.Thread {
    const t = try std.Thread.spawn(.{}, readEvents, .{s});
    errdefer t.join();
    return t;
}

/// Release a blocked `readEvents` by shutting the socket's read side.
///
/// `shutdown(SHUT_RD)` makes the pending `readv` return 0, which the
/// net layer reports as `error.EndOfStream`, and the reader exits.
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
        // Holding the mutex across the sleep starves the reader: the
        // loop re-acquires the instant the sleep ends, so the reader —
        // which needs the same lock to append — misses every window.
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
        if (finished) return false;
        if (nowMs() >= deadline) return false;
        std.Io.sleep(io, .fromMilliseconds(20), .awake) catch {};
    }
}

/// Wait until the reader thread stops (EOF, error, or deadline).
/// Returns true iff the stream finished before the deadline.
fn waitForEnd(s: *SseStream, timeout_ms: i64) bool {
    const deadline = nowMs() + timeout_ms;
    while (true) {
        if (s.done.load(.acquire)) return true;
        if (nowMs() >= deadline) return false;
        std.Io.sleep(io, .fromMilliseconds(20), .awake) catch {};
    }
}

/// True iff an event named `want` was seen. Reads under the mutex.
fn sawEvent(s: *SseStream, want: []const u8) bool {
    s.mutex.lockUncancelable(io);
    defer s.mutex.unlock(io);
    for (s.events.items) |e| {
        if (std.mem.eql(u8, e.name, want)) return true;
    }
    return false;
}

/// A copy of the event names seen so far, for the failure message.
fn seenNames(s: *SseStream) []u8 {
    s.mutex.lockUncancelable(io);
    defer s.mutex.unlock(io);
    var out: std.Io.Writer.Allocating = .init(gpa);
    errdefer out.deinit();
    for (s.events.items) |e| out.writer.print("{s} ", .{e.name}) catch break;
    return out.toOwnedSlice() catch |err| {
        out.deinit();
        std.debug.print("could not render the seen-events list: {s}\n", .{@errorName(err)});
        return gpa.dupe(u8, "<unavailable>") catch @panic("dupe of the <unavailable> literal failed");
    };
}

/// Boot a harness with `--auth` (the gate is opt-in).
fn bootAuth() !Harness {
    return Harness.boot(io, gpa, .{ .extra_args = &.{"--auth"} });
}

/// Run `pabrik create-admin` against the harness HOME.
///
/// `runPabrikCommand` prepends the resolved binary itself, so `argv`
/// starts at the SUBCOMMAND — passing the binary again would make the
/// subcommand dispatch miss (it matches argv[1]) and boot a SERVER,
/// which then tries to bind the default port.
fn createAdmin(home: []const u8, email: []const u8, password: []const u8) !void {
    var r = try harness.runPabrikCommand(io, gpa, home, &.{
        "create-admin", "--email", email, "--password", password,
    }, 30_000);
    defer r.deinit(gpa);
    if (r.exit_code == null or r.exit_code.? != 0) {
        std.debug.print("create-admin failed (rc={?}): {s}\n", .{ r.exit_code, r.stderr });
        return error.TestUnexpectedResult;
    }
}

/// Log in and return the raw session token (Python `_login`).
///
/// The login POST needs no cookie and no streaming, so it goes through
/// the ordinary harness client with `.assert_status = false` — the
/// status IS one of the assertions here (`assert status == 200`).
fn login(h: *Harness, email: []const u8, password: []const u8) ![]u8 {
    const body = try std.fmt.allocPrint(
        gpa,
        "{{\"email\":\"{s}\",\"password\":\"{s}\"}}",
        .{ email, password },
    );
    defer gpa.free(body);

    var r = try h.http(io, .POST, "/api/auth/login", .{
        .json_body = body,
        .assert_status = false,
    });
    defer r.deinit();
    if (r.status != 200) {
        std.debug.print("login failed (status={d}): {s}\n", .{ r.status, r.body });
        return error.TestUnexpectedResult;
    }
    const set_cookie = r.header("Set-Cookie") orelse "";
    if (std.mem.indexOf(u8, set_cookie, "pabrik_session=") == null) {
        std.debug.print("login sent no pabrik_session cookie: {s}\n", .{set_cookie});
        return error.TestUnexpectedResult;
    }
    // `split("pabrik_session=", 1)[1].split(";", 1)[0].strip()`:
    // the token is the text BETWEEN the name and the next `;`. The
    // harness's `afterFirst` returns the text AFTER a delimiter, which
    // here would be the attribute list (`Path=/; HttpOnly`) — wrong
    // tool for this direction, hence the manual split.
    var attrs = std.mem.splitSequence(u8, set_cookie, ";");
    const first_attr = attrs.next() orelse return error.TestUnexpectedResult;
    const raw_token = harness.afterFirst(first_attr, "pabrik_session=") orelse
        return error.TestUnexpectedResult;
    return gpa.dupe(u8, std.mem.trim(u8, raw_token, " \t\r\n"));
}

// --auth on, no cookie: auth_error event, then EOF. Never a hang.
test "unauth_sse_terminates_with_auth_error" {
    try harness.requirePabrikBin(io, gpa);

    var h = try bootAuth();
    defer h.deinit(io) catch |err| {
        std.debug.print("teardown: {s}\n", .{@errorName(err)});
    };

    const s = try openSse(h.port, "workers", null);
    defer s.deinit();

    // The headers are sent before the handler runs, so even a rejection
    // arrives as a 200 `text/event-stream`.
    if (s.status != 200 or std.mem.indexOf(u8, s.content_type, "text/event-stream") == null) {
        std.debug.print("expected an SSE 200 handshake, got {d} {s}\n", .{ s.status, s.content_type });
        return error.TestUnexpectedResult;
    }

    const reader = try spawnReader(s);
    defer {
        releaseReader(s);
        reader.join();
    }

    // Wait for the STREAM to end rather than for a single event: the
    // contract is "auth_error, then EOF", and a stream that emits
    // auth_error and then keeps pinging is exactly the regression.
    const ended = waitForEnd(s, reject_timeout_ms);

    if (!sawEvent(s, "auth_error")) {
        const names = seenNames(s);
        defer gpa.free(names);
        std.debug.print("expected auth_error, got events=[{s}]\n", .{names});
        return error.TestUnexpectedResult;
    }
    if (sawEvent(s, "connected")) {
        std.debug.print("rejected stream must never handshake\n", .{});
        return error.TestUnexpectedResult;
    }
    if (!ended or !s.eof) {
        s.mutex.lockUncancelable(io);
        const reason = if (s.read_error) |m| m else "<none>";
        s.mutex.unlock(io);
        std.debug.print(
            "rejected SSE stream must END (server closes it); reader stopped={any}, eof={}, read_error={s} — zombie ping stream is back\n",
            .{ ended, s.eof, reason },
        );
        return error.TestUnexpectedResult;
    }
}

// --auth on, valid cookie: the connected handshake arrives.
test "authed_sse_gets_connected" {
    try harness.requirePabrikBin(io, gpa);

    var h = try bootAuth();
    defer h.deinit(io) catch |err| {
        std.debug.print("teardown: {s}\n", .{@errorName(err)});
    };

    try createAdmin(h.temp_dir, "sse@example.com", "supersecret123");
    const token = try login(&h, "sse@example.com", "supersecret123");
    defer gpa.free(token);

    const cookie = try std.fmt.allocPrint(gpa, "pabrik_session={s}", .{token});
    defer gpa.free(cookie);

    const s = try openSse(h.port, "workers", cookie);
    defer s.deinit();

    const reader = try spawnReader(s);
    defer {
        releaseReader(s);
        reader.join();
    }

    if (!waitForEvent(s, "connected", authed_timeout_ms)) {
        const names = seenNames(s);
        defer gpa.free(names);
        std.debug.print("expected connected handshake, got [{s}]\n", .{names});
        return error.TestUnexpectedResult;
    }
}

// Unknown ?channels= token: stream ends promptly instead of hanging.
//
// NOTE the fixture difference from the two tests above: Python asked
// for the shared `harness` fixture (a plain boot, NO `--auth`), so this
// pins the 400-path zombie pattern in isolation from the auth gate.
test "unknown_channel_terminates" {
    try harness.requirePabrikBin(io, gpa);

    var h = try Harness.boot(io, gpa, .{});
    defer h.deinit(io) catch |err| {
        std.debug.print("teardown: {s}\n", .{@errorName(err)});
    };

    const s = try openSse(h.port, "nope_not_a_channel", null);
    defer s.deinit();

    const reader = try spawnReader(s);
    defer {
        releaseReader(s);
        reader.join();
    }

    const ended = waitForEnd(s, reject_timeout_ms);

    if (sawEvent(s, "connected")) {
        std.debug.print("a rejected channel must not handshake\n", .{});
        return error.TestUnexpectedResult;
    }
    if (!ended or !s.eof) {
        s.mutex.lockUncancelable(io);
        const reason = if (s.read_error) |m| m else "<none>";
        s.mutex.unlock(io);
        std.debug.print(
            "400-path SSE stream must END; reader stopped={any}, eof={}, read_error={s} — zombie stream is back\n",
            .{ ended, s.eof, reason },
        );
        return error.TestUnexpectedResult;
    }
}
