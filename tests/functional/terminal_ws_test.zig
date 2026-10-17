// Functional e2e for the terminal duplex WebSocket. Zig port of
// `tests/functional/terminal_ws_test.py` (same test names, same order).

const std = @import("std");
const builtin = @import("builtin");
const testing = std.testing;
const harness = @import("harness.zig");
const Harness = harness.Harness;

const Io = std.Io;

const gpa = testing.allocator;
const io = testing.io;

/// RFC 6455 §1.3 — the GUID appended to `Sec-WebSocket-Key` before
/// hashing to produce `Sec-WebSocket-Accept`.
const WS_MAGIC = "258EAFA5-E914-47DA-95CA-C5AB0DC85B11";

/// Read buffer for the socket. Must exceed the largest frame payload
/// this suite will see; see hazard (1) in the header.
const rd_buf_len = 128 * 1024;

/// The shell every terminal in this suite runs. Windows has no `/bin/sh`;
/// `cmd.exe` is its interactive equivalent and every assertion below holds
/// for it unchanged.
const SHELL = if (builtin.os.tag == .windows)
    "C:\\Windows\\System32\\cmd.exe"
else
    "/bin/sh";

/// Write buffer for the socket. One frame is at most a few hundred
/// bytes here, but `Stream.Writer` needs a real buffer to own.
const wr_buf_len = 8 * 1024;

/// Monotonic milliseconds (`.awake` is monotonic, not wall clock).
fn nowMs() i64 {
    return Io.Timestamp.now(io, .awake).toMilliseconds();
}

/// A file-local PRNG for the two places a test needs unpredictable bytes: the
/// handshake key and the per-frame mask.
var prng: std.Random.DefaultPrng = undefined;
var prng_ready = false;

fn randU64() u64 {
    if (!prng_ready) {
        const ts: u64 = @bitCast(@as(i64, Io.Timestamp.now(io, .real).toMilliseconds()));
        const addr = @intFromPtr(&prng);
        prng = .init(ts ^ @as(u64, @bitCast(@as(i64, @intCast(addr)))) ^ 0x9E3779B97F4A7C15);
        prng_ready = true;
    }
    return prng.random().int(u64);
}

/// A shutdown watchdog for ONE blocking read. Python expressed the same
/// budget with `sock.settimeout(remaining)`.
const ReadDeadline = struct {
    stop: std.atomic.Value(bool),
    thread: std.Thread,

    /// The caller owns the result and MUST `disarm` it.
    fn start(stream: *const Io.net.Stream, ms: i64) !*ReadDeadline {
        const self = try gpa.create(ReadDeadline);
        errdefer gpa.destroy(self);
        // `gpa.create` does not run field defaults, so `stop` is assigned
        // explicitly — an uninitialised atomic the watchdog happens to read
        // as "already fired" would shut the socket down on its first poll.
        self.* = .{ .stop = .init(false), .thread = undefined };
        self.thread = std.Thread.spawn(.{}, watch, .{ stream, &self.stop, ms }) catch |err| {
            gpa.destroy(self);
            return err;
        };
        return self;
    }

    fn watch(stream: *const Io.net.Stream, stop: *std.atomic.Value(bool), ms: i64) void {
        const deadline = nowMs() + ms;
        while (nowMs() < deadline) {
            if (stop.load(.acquire)) return;
            Io.sleep(io, .fromMilliseconds(20), .awake) catch return;
        }
        // Re-check: the read may have completed in the same window this loop
        // last polled, and shutting down a socket that is about to be read
        // again would turn a clean EOF into an error the caller mistakes for
        if (stop.load(.acquire)) return;
        stream.shutdown(io, .recv) catch {};
    }

    fn disarm(self: *ReadDeadline) void {
        self.stop.store(true, .release);
        self.thread.join();
        const gpa2 = gpa;
        gpa2.destroy(self);
    }
};

/// A blocking raw-socket WebSocket client (test-only, IPv4). The Python
/// version was a class over `socket.create_connection` with a `self.buf`
/// leftover buffer.
const WsConn = struct {
    stream: Io.net.Stream,
    rd_buf: [rd_buf_len]u8 = undefined,
    reader: Io.net.Stream.Reader,
    wr_buf: [wr_buf_len]u8 = undefined,
    writer: Io.net.Stream.Writer,
    /// The `Sec-WebSocket-Key` we sent, base64 (24 chars, OWNED).
    key: []u8,
    /// True once `deinit` must not double-close.
    closed: bool = false,

    /// Open a socket to `127.0.0.1:port` and send the upgrade request
    /// for `path`. The response head is NOT read here — the caller
    /// does that with `readHttpResponse`, matching the Python.
    fn connect(port: u16, path: []const u8) !*WsConn {
        const self = try gpa.create(WsConn);
        errdefer gpa.destroy(self);
        // `gpa.create` does NOT run field default initialisers, so the
        // defaults (`closed`, and the two `undefined` buffers) are
        // applied here rather than assumed.
        self.* = .{ .stream = undefined, .reader = undefined, .writer = undefined, .key = undefined };

        const addr: Io.net.IpAddress = .{ .ip4 = .loopback(port) };
        // `.timeout = .none` IS DELIBERATE, not a dropped feature.
        self.stream = try addr.connect(io, .{ .mode = .stream });
        errdefer self.stream.close(io);

        // Built AFTER `self` is final, so the stored buffer addresses
        // are the heap ones the test will read and write.
        self.reader = self.stream.reader(io, self.rd_buf[0..]);
        self.writer = self.stream.writer(io, self.wr_buf[0..]);

        // 16 random bytes, base64-encoded — exactly what Python's
        // `base64.b64encode(os.urandom(16))` produced.
        var nonce: [16]u8 = undefined;
        var r = randU64();
        for (&nonce) |*b| {
            b.* = @truncate(r);
            r >>= 8;
        }
        const key_len = std.base64.standard.Encoder.calcSize(nonce.len);
        self.key = try gpa.alloc(u8, key_len);
        errdefer gpa.free(self.key);
        _ = std.base64.standard.Encoder.encode(self.key, &nonce);
        const key = self.key;

        const req = try std.fmt.allocPrint(
            gpa,
            "GET {s} HTTP/1.1\r\n" ++
                "Host: 127.0.0.1\r\n" ++
                "Upgrade: websocket\r\n" ++
                "Connection: Upgrade\r\n" ++
                "Sec-WebSocket-Key: {s}\r\n" ++
                "Sec-WebSocket-Version: 13\r\n" ++
                "\r\n",
            .{ path, key },
        );
        defer gpa.free(req);
        try self.writer.interface.writeAll(req);
        try self.writer.interface.flush();

        return self;
    }

    fn deinit(self: *WsConn) void {
        if (!self.closed) {
            self.stream.close(io);
            self.closed = true;
        }
        gpa.free(self.key);
        const gpa2 = gpa;
        gpa2.destroy(self);
    }

    /// The status line + headers of the upgrade response. Python's
    /// `read_http_response` returned `(status_line, headers)` with header
    /// NAMES lowercased.
    fn readHttpResponse(self: *WsConn, deadline_ms: i64) !HttpHead {
        var guard = try ReadDeadline.start(&self.stream, deadline_ms);
        defer guard.disarm();

        var raw: std.Io.Writer.Allocating = .init(gpa);
        // `errdefer`, NOT `defer`: on the success path `toOwnedSlice`
        // below TAKES the buffer, and a `defer` deinit would then free
        // memory `HttpHead.raw` still points at.
        errdefer raw.deinit();

        var seen: usize = 0;
        while (true) {
            const b = self.reader.interface.takeByte() catch |err| {
                std.debug.print("EOF/err during WS handshake ({s}); read {s}\n", .{ @errorName(err), raw.written() });
                return error.TestUnexpectedResult;
            };
            try raw.writer.writeByte(b);
            seen += 1;
            // Stop right after the blank line that ends the head.
            if (seen >= 4) {
                const w = raw.written();
                if (std.mem.eql(u8, w[w.len - 4 ..], "\r\n\r\n")) break;
            }
            if (seen > 16 * 1024) {
                std.debug.print("no CRLFCRLF in the first 16 KiB of the WS handshake\n", .{});
                return error.TestUnexpectedResult;
            }
        }

        // `raw_head` is owned by the `HttpHead`: the two views below
        // are sub-slices of it, so keeping the owner is what frees it.
        const raw_head = try raw.toOwnedSlice();
        errdefer gpa.free(raw_head);
        const first_nl = std.mem.indexOf(u8, raw_head, "\r\n") orelse raw_head.len;
        return .{
            .raw_head = raw_head,
            .status_line = raw_head[0..first_nl],
            .headers = raw_head[first_nl + 2 ..],
        };
    }

    /// One decoded frame.
    const Frame = struct {
        opcode: u8,
        /// OWNED — the payload is unmasked into a fresh buffer.
        payload: []u8,

        fn deinit(self: *Frame) void {
            gpa.free(self.payload);
            self.* = undefined;
        }
    };

    /// Read the next frame, giving up after `deadline_ms`.
    fn readFrame(self: *WsConn, deadline_ms: i64) !Frame {
        var guard = try ReadDeadline.start(&self.stream, deadline_ms);
        defer guard.disarm();

        const r = &self.reader.interface;

        const b0 = r.takeByte() catch |err| return readFailure("first frame header byte", err);
        const b1 = r.takeByte() catch |err| return readFailure("second frame header byte", err);

        const opcode: u8 = b0 & 0x0F;
        const masked = (b1 & 0x80) != 0;
        const len7: usize = b1 & 0x7F;

        var length: usize = 0;
        if (len7 < 126) {
            length = len7;
        } else if (len7 == 126) {
            var ext: [2]u8 = undefined;
            @memcpy(&ext, r.takeArray(2) catch |err| return readFailure("16-bit length", err));
            length = std.mem.readInt(u16, &ext, .big);
        } else {
            var ext: [8]u8 = undefined;
            @memcpy(&ext, r.takeArray(8) catch |err| return readFailure("64-bit length", err));
            const wide = std.mem.readInt(u64, &ext, .big);
            if (wide > rd_buf_len) {
                std.debug.print("server announced a {d}-byte payload; buffer is {d}\n", .{ wide, rd_buf_len });
                return error.TestUnexpectedResult;
            }
            length = @intCast(wide);
        }

        // Hazard (1): `take` asserts rather than grows, so an
        // over-long payload is a clear failure here instead of a
        // DebugAllocator abort inside the stdlib.
        if (length > rd_buf_len) {
            std.debug.print("frame payload {d} exceeds the {d}-byte reader buffer\n", .{ length, rd_buf_len });
            return error.TestUnexpectedResult;
        }

        var mask: [4]u8 = .{ 0, 0, 0, 0 };
        if (masked) @memcpy(&mask, r.takeArray(4) catch |err| return readFailure("mask key", err));

        const payload = try gpa.alloc(u8, length);
        errdefer gpa.free(payload);
        if (length > 0) {
            @memcpy(payload, r.take(length) catch |err| return readFailure("payload", err));
            if (masked) {
                for (payload, 0..) |*b, i| b.* ^= mask[i % 4];
            }
        }
        return .{ .opcode = opcode, .payload = payload };
    }

    fn readFailure(what: []const u8, err: anyerror) anyerror {
        std.debug.print("WS read failed while reading the {s}: {s}\n", .{ what, @errorName(err) });
        return error.TestUnexpectedResult;
    }

    /// Send one MASKED client frame. `fin` is always 1 — the Python's
    /// `send_text` / `send_close` did not fragment either.
    fn sendFrame(self: *WsConn, opcode: u8, payload: []const u8) !void {
        if (payload.len > 125) {
            std.debug.print("client frame of {d} bytes exceeds the 125-byte single-byte length form\n", .{payload.len});
            return error.TestUnexpectedResult;
        }

        var mask: [4]u8 = undefined;
        var r = randU64();
        for (&mask) |*b| {
            b.* = @truncate(r);
            r >>= 8;
        }

        var frame: [2 + 4 + 125]u8 = undefined;
        frame[0] = 0x80 | (opcode & 0x0F); // FIN + opcode
        frame[1] = 0x80 | @as(u8, @truncate(payload.len)); // MASK + 7-bit length
        @memcpy(frame[2..6], &mask);
        for (payload, 0..) |b, i| frame[6 + i] = b ^ mask[i % 4];

        try self.writer.interface.writeAll(frame[0 .. 6 + payload.len]);
        try self.writer.interface.flush();
    }

    fn sendText(self: *WsConn, text: []const u8) !void {
        return self.sendFrame(0x1, text);
    }

    fn sendClose(self: *WsConn) !void {
        return self.sendFrame(0x8, "");
    }
};

/// The upgrade response. `status_line` and `headers` are VIEWS into
/// `raw_head`, which the struct owns — one allocation for all three.
const HttpHead = struct {
    /// The whole head, terminator included. Freed by `deinit`.
    raw_head: []u8,
    /// e.g. `HTTP/1.1 101 Switching Protocols`.
    status_line: []const u8,
    /// Everything after the status line, INCLUDING the trailing CRLFCRLF.
    headers: []const u8,

    fn deinit(self: *HttpHead) void {
        gpa.free(self.raw_head);
        self.* = undefined;
    }

    /// Case-insensitive header lookup — header names are
    /// case-insensitive per RFC 9110 and the Python lowercased them.
    fn get(self: *const HttpHead, name: []const u8) ?[]const u8 {
        var it = std.mem.splitSequence(u8, std.mem.trimEnd(u8, self.headers, "\r\n"), "\r\n");
        while (it.next()) |line| {
            if (line.len == 0) continue;
            const colon = std.mem.indexOfScalar(u8, line, ':') orelse continue;
            const k = std.mem.trim(u8, line[0..colon], " \t");
            if (!std.ascii.eqlIgnoreCase(k, name)) continue;
            return std.mem.trim(u8, line[colon + 1 ..], " \t");
        }
        return null;
    }
};

/// `base64(sha1(key + WS_MAGIC))` — the value the server must echo in
/// `Sec-WebSocket-Accept` (RFC 6455 §4.2.2 step 5.2).
fn expectedAccept(key: []const u8) ![]u8 {
    // `key` is a runtime slice, so the concatenation cannot be a
    // comptime-sized stack array. `Io.Writer.Allocating` is the 0.16
    // idiom for "build a string I own".
    var buf: std.Io.Writer.Allocating = .init(gpa);
    defer buf.deinit();
    try buf.writer.writeAll(key);
    try buf.writer.writeAll(WS_MAGIC);

    var digest: [std.crypto.hash.Sha1.digest_length]u8 = undefined;
    std.crypto.hash.Sha1.hash(buf.written(), &digest, .{});

    const out = try gpa.alloc(u8, std.base64.standard.Encoder.calcSize(digest.len));
    _ = std.base64.standard.Encoder.encode(out, &digest);
    return out;
}

/// `_create_session` — `POST /api/terminal/sessions`, return the OWNED
/// terminal id.
fn createSession(h: *Harness) ![]u8 {
    // `std.json.Stringify`, never a hand-built template: `h.temp_dir` is a
    // Windows path full of backslashes, and `{"cwd":"C:\Users\..."}` is not
    // JSON — the server answers 400 and the failure looks like a terminal
    const body = try std.json.Stringify.valueAlloc(gpa, .{ .cwd = h.temp_dir, .shell = SHELL }, .{});
    defer gpa.free(body);

    var r = try h.http(io, .POST, "/api/terminal/sessions", .{ .json_body = body, .expect = &.{201} });
    defer r.deinit();
    var doc = try r.json();
    defer doc.deinit();
    const id = doc.str("id") orelse {
        std.debug.print("terminal session create returned no id: {s}\n", .{r.body});
        return error.TestUnexpectedResult;
    };
    return gpa.dupe(u8, id);
}

/// `_collect_until` — read frames until a binary payload contains `marker`.
/// Returns the accumulated PTY bytes (OWNED), or null when the deadline
/// passed / the stream closed first.
fn collectUntil(ws: *WsConn, marker: []const u8, deadline_ms: i64) !?[]u8 {
    var seen: std.ArrayList(u8) = .empty;
    errdefer seen.deinit(gpa);

    const deadline = nowMs() + deadline_ms;
    while (nowMs() < deadline) {
        const remaining = deadline - nowMs();
        var frame = ws.readFrame(@max(remaining, 1_000)) catch |err| {
            // The Python let a timeout/EOF out of the loop and then failed
            // the marker assertion with `seen`.
            std.debug.print("stopped collecting: {s}; seen {d} bytes so far\n", .{ @errorName(err), seen.items.len });
            seen.deinit(gpa);
            return null;
        };
        defer frame.deinit();

        if (frame.opcode == 0x2) {
            // binary — PTY bytes
            try seen.appendSlice(gpa, frame.payload);
            if (std.mem.indexOf(u8, seen.items, marker) != null) {
                return try seen.toOwnedSlice(gpa);
            }
        } else if (frame.opcode == 0x1) {
            // text — JSON control frames (`exit`). No assertion reads
            // them here; a decode failure is exactly what the Python's
            // `except (ValueError, UnicodeDecodeError): pass` ignored.
        } else if (frame.opcode == 0x8) {
            break; // close
        }
    }
    // Deadline reached with frames still arriving, or the server sent a
    // close: same leak hazard as the read-failure path above.
    seen.deinit(gpa);
    return null;
}

/// Render `seen` for a failure message, with non-printable bytes
/// escaped (raw PTY output is full of them).
fn escapeForMessage(gpa_: std.mem.Allocator, s: []const u8) []u8 {
    var out: std.Io.Writer.Allocating = .init(gpa_);
    for (s) |c| {
        switch (c) {
            0x20...0x21, 0x23...0x5B, 0x5D...0x7E => out.writer.writeByte(c) catch break,
            else => out.writer.print("\\x{x:0>2}", .{c}) catch break,
        }
    }
    return out.toOwnedSlice() catch blk: {
        out.deinit();
        break :blk gpa_.dupe(u8, "<unavailable>") catch @panic("dupe of the <unavailable> literal failed");
    };
}

// ============================================================================
// Tests
// ============================================================================

// Handshake (101 + valid accept) → masked input → binary echo.
test "ws_echo_round_trip" {
    try harness.requirePabrikBin(io, gpa);

    var h = try Harness.boot(io, gpa, .{});
    defer h.deinit(io) catch |err| {
        std.debug.print("teardown: {s}", .{@errorName(err)});
    };

    const session_id = try createSession(&h);
    defer gpa.free(session_id);

    const path = try std.fmt.allocPrint(gpa, "/api/terminal/ws?id={s}", .{session_id});
    defer gpa.free(path);

    const ws = try WsConn.connect(h.port, path);
    defer ws.deinit();

    // 1. Handshake.
    var head = try ws.readHttpResponse(10_000);
    defer head.deinit();

    if (std.mem.indexOf(u8, head.status_line, "101") == null) {
        std.debug.print("expected 101, got '{s}'\n", .{head.status_line});
        return error.TestUnexpectedResult;
    }
    {
        const want = try expectedAccept(ws.key);
        defer gpa.free(want);
        const got = head.get("sec-websocket-accept") orelse {
            std.debug.print("no sec-websocket-accept in: {s}\n", .{head.headers});
            return error.TestUnexpectedResult;
        };
        if (!std.mem.eql(u8, got, want)) {
            std.debug.print("bad accept key: got '{s}', want '{s}'\n", .{ got, want });
            return error.TestUnexpectedResult;
        }
    }

    // 2. Masked input → binary echo back. The two frames mirror the CLIENT:
    // the typed text, then Enter as a bare `\r` (xterm's onData) — never CRLF.
    // A suite that writes its own CRLF tests its spelling, not the contract.
    const marker = "WS-MARK-4f8e2a";
    {
        const msg = try std.fmt.allocPrint(gpa, "{{\"type\":\"input\",\"data\":\"echo {s}\"}}", .{marker});
        defer gpa.free(msg);
        try ws.sendText(msg);
    }
    try ws.sendText("{\"type\":\"input\",\"data\":\"\\r\"}");

    const seen = (try collectUntil(ws, marker, 20_000)) orelse {
        std.debug.print("marker '{s}' never arrived\n", .{marker});
        return error.TestUnexpectedResult;
    };
    defer gpa.free(seen);
    if (std.mem.indexOf(u8, seen, marker) == null) {
        const printable = escapeForMessage(gpa, seen);
        defer gpa.free(printable);
        std.debug.print("marker '{s}' missing from the PTY bytes: {s}\n", .{ marker, printable });
        return error.TestUnexpectedResult;
    }

    try ws.sendClose();

    // Teardown of the session, exactly as the Python's `finally`.
    {
        const del = try std.fmt.allocPrint(gpa, "/api/terminal/sessions/{s}", .{session_id});
        defer gpa.free(del);
        var r = try h.http(io, .DELETE, del, .{ .expect = &.{200} });
        defer r.deinit();
    }
}

// Attaching to an unknown id yields NO PTY bytes — the server runs the
// close handshake (a close frame) or drops the socket.
test "ws_unknown_id_rejected" {
    try harness.requirePabrikBin(io, gpa);

    var h = try Harness.boot(io, gpa, .{});
    defer h.deinit(io) catch |err| {
        std.debug.print("teardown: {s}", .{@errorName(err)});
    };

    const ws = try WsConn.connect(h.port, "/api/terminal/ws?id=term-does-not-exist");
    defer ws.deinit();

    var head = try ws.readHttpResponse(10_000);
    defer head.deinit();

    if (std.mem.indexOf(u8, head.status_line, "101") == null) {
        std.debug.print("expected 101 upgrade, got '{s}'\n", .{head.status_line});
        return error.TestUnexpectedResult;
    }

    // Python: `sock.settimeout(5.0)` then `read_frame(deadline_s=5.0)`,
    // accepting EITHER a close frame OR a timeout/EOF — but never PTY bytes.
    if (ws.readFrame(5_000)) |frame| {
        var f = frame;
        defer f.deinit();
        if (f.opcode != 0x8) {
            std.debug.print("expected close frame, got opcode {x} with {d} payload bytes\n", .{ f.opcode, f.payload.len });
            return error.TestUnexpectedResult;
        }
    } else |_| {
        // Timed out or EOF without a frame — also acceptable, and
        // provably "no PTY bytes arrived" because nothing did.
        std.debug.print("socket ended without a close frame (also acceptable)\n", .{});
    }
}

// Resize over the socket is accepted; the REST output endpoint keeps
// serving the same session (the Phase 2 fallback path is intact).
test "ws_resize_and_rest_fallback" {
    try harness.requirePabrikBin(io, gpa);

    var h = try Harness.boot(io, gpa, .{});
    defer h.deinit(io) catch |err| {
        std.debug.print("teardown: {s}", .{@errorName(err)});
    };

    const session_id = try createSession(&h);
    defer gpa.free(session_id);

    const path = try std.fmt.allocPrint(gpa, "/api/terminal/ws?id={s}", .{session_id});
    defer gpa.free(path);

    const ws = try WsConn.connect(h.port, path);
    defer ws.deinit();

    {
        var head = try ws.readHttpResponse(10_000);
        defer head.deinit();
        if (std.mem.indexOf(u8, head.status_line, "101") == null) {
            std.debug.print("expected 101, got '{s}'\n", .{head.status_line});
            return error.TestUnexpectedResult;
        }
    }

    try ws.sendText("{\"type\":\"resize\",\"cols\":100,\"rows\":40}");

    const marker = "WS-RESIZE-7b3d";
    {
        const msg = try std.fmt.allocPrint(gpa, "{{\"type\":\"input\",\"data\":\"echo {s}\\n\"}}", .{marker});
        defer gpa.free(msg);
        try ws.sendText(msg);
    }

    const seen = (try collectUntil(ws, marker, 20_000)) orelse {
        std.debug.print("marker '{s}' never arrived after resize\n", .{marker});
        return error.TestUnexpectedResult;
    };
    defer gpa.free(seen);

    try ws.sendClose();
    // Drop the socket before polling REST, exactly as the Python's
    // `finally: ws.close()` inside the `try`.
    ws.stream.close(io);
    ws.closed = true;

    // REST fallback still works on the same session afterwards.
    {
        const out = try std.fmt.allocPrint(gpa, "/api/terminal/sessions/{s}/output", .{session_id});
        defer gpa.free(out);
        var r = try h.http(io, .GET, out, .{
            .params = &.{.{ .name = "cursor", .value = "0" }},
            .expect = &.{200},
        });
        defer r.deinit();
        var doc = try r.json();
        defer doc.deinit();
        // Python: `r.json().get("cursor", 0) > 0` — an absent key
        // defaults to 0, which fails the comparison, so the key must be
        // present.
        const cursor = doc.int("cursor") orelse {
            std.debug.print("output body has no integer `cursor`: {s}\n", .{r.body});
            return error.TestUnexpectedResult;
        };
        if (cursor <= 0) {
            std.debug.print("REST fallback cursor did not advance: {s}\n", .{r.body});
            return error.TestUnexpectedResult;
        }
    }

    {
        const del = try std.fmt.allocPrint(gpa, "/api/terminal/sessions/{s}", .{session_id});
        defer gpa.free(del);
        var r = try h.http(io, .DELETE, del, .{ .expect = &.{200} });
        defer r.deinit();
    }
}
