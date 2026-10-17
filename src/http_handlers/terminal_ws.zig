//! `WS /api/terminal/ws?id=<session-id>` — duplex PTY streaming.

const std = @import("std");
const pabrikcore = @import("pabrikcore");
const gserverz = pabrikcore.gserverz;
const terminal_session = @import("terminal_session.zig");
const auth_common = @import("auth_common.zig");
const ws_frames = gserverz.ws_frames;

/// How long one pump tick blocks waiting for activity. This is the
/// websocket's latency floor, and the one number the two hosts disagree
/// on: POSIX `poll(2)` wakes the instant the shell writes, so it can
/// afford to block for a while; a ConPTY host has no waitable console
/// handle (`terminal_session.waitReadable` says why) and has to re-check
/// the console on a tick, so its tick is short.
const pump_tick_ms: c_int = if (terminal_session.pty_backend == .conpty) 20 else 100;

/// Max buffered client bytes before a complete frame must arrive.
/// Control frames are tiny (keystrokes, resize JSON); anything larger
/// is a protocol error and ends the socket.
const max_pending: usize = 64 * 1024;
/// PTY bytes forwarded per loop iteration (split into 16 KiB frames).
const max_forward_per_tick: usize = 64 * 1024;
const out_frame_chunk: usize = 16 * 1024;
/// Largest single WS payload we accept from the client (paste guard).
const max_client_payload: usize = 1024 * 1024;

pub const WsControl = struct {
    type: []const u8 = "",
    data: ?[]const u8 = null,
    cols: ?u16 = null,
    rows: ?u16 = null,
};

/// Wire length of the FIRST frame in `buf` (header + mask key +
/// payload). Client frames must be masked; unmasked → InvalidFrame.
/// Short buffer → IncompleteFrame. Absurd lengths → FrameTooLarge.
pub fn frameWireLen(buf: []const u8) !usize {
    if (buf.len < 2) return error.IncompleteFrame;
    const masked = (buf[1] & 0x80) != 0;
    if (!masked) return error.InvalidFrame;
    const len7: usize = buf[1] & 0x7F;
    var header: usize = 2;
    var payload: usize = 0;
    if (len7 < 126) {
        payload = len7;
    } else if (len7 == 126) {
        if (buf.len < 4) return error.IncompleteFrame;
        payload = (@as(usize, buf[2]) << 8) | buf[3];
        header = 4;
    } else {
        if (buf.len < 10) return error.IncompleteFrame;
        var len64: u64 = 0;
        for (buf[2..10]) |b| len64 = (len64 << 8) | b;
        if (len64 > max_client_payload) return error.FrameTooLarge;
        // usize is 64-bit on every target we serve WS on.
        payload = @intCast(len64);
        header = 10;
    }
    const total = header + 4 + payload; // +4 masking key
    if (buf.len < total) return error.IncompleteFrame;
    return total;
}

fn sendBinary(server: *gserverz.GinwaServer, allocator: std.mem.Allocator, fd: i32, bytes: []const u8) !void {
    var off: usize = 0;
    while (off < bytes.len) {
        const end = @min(off + out_frame_chunk, bytes.len);
        const wire = try ws_frames.encodeFrame(allocator, .{ .opcode = .binary, .payload = bytes[off..end] });
        defer allocator.free(wire);
        _ = try server.sendToClient(fd, wire);
        off = end;
    }
}

fn sendExit(server: *gserverz.GinwaServer, allocator: std.mem.Allocator, fd: i32, exit_code: ?i32) !void {
    const body = try std.json.Stringify.valueAlloc(allocator, .{
        .type = "exit",
        .exit_code = exit_code,
    }, .{});
    defer allocator.free(body);
    const wire = try ws_frames.encodeFrame(allocator, .{ .opcode = .text, .payload = body });
    defer allocator.free(wire);
    _ = try server.sendToClient(fd, wire);
}

fn sendPong(server: *gserverz.GinwaServer, allocator: std.mem.Allocator, fd: i32, payload: []const u8) !void {
    const wire = try ws_frames.encodeFrame(allocator, .{ .opcode = .pong, .payload = payload });
    defer allocator.free(wire);
    _ = try server.sendToClient(fd, wire);
}

fn handleControl(
    server: *gserverz.GinwaServer,
    allocator: std.mem.Allocator,
    fd: i32,
    session: *terminal_session.Session,
    payload: []const u8,
) !bool {
    // Returns false when the socket should close (session exited).
    const parsed = std.json.parseFromSliceLeaky(WsControl, allocator, payload, .{}) catch return true;
    if (std.mem.eql(u8, parsed.type, "input")) {
        const data = parsed.data orelse return true;
        if (data.len == 0) return true;
        _ = terminal_session.writeInput(session, data) catch |err| {
            if (err == error.SessionExited) {
                const out = terminal_session.readOutput(session, std.math.maxInt(u64));
                try sendExit(server, allocator, fd, out.exit_code);
                return false;
            }
            return true; // transient write failure — keep the socket.
        };
        return true;
    }
    if (std.mem.eql(u8, parsed.type, "resize")) {
        const cols = parsed.cols orelse return true;
        const rows = parsed.rows orelse return true;
        terminal_session.resizeSession(session, cols, rows) catch {};
        return true;
    }
    return true; // unknown type — ignore, keep the socket.
}

pub fn terminalWsHandler(
    ctx: gserverz.HttpContext,
    req: gserverz.HttpRequest,
    server_ptr: *anyopaque,
    client_fd: i32,
    client_id: *[16]u8,
) !void {
    _ = client_id;
    // Manual auth gate: kabelweb ws() does not run middleware.
    var owner_buf: [128]u8 = undefined;
    var owner: []const u8 = "";
    if (pabrikcore.getSingleton()) |di| {
        if (di.auth_enabled) {
            const tok = auth_common.parseSessionToken(req.headers) orelse return;
            const sess = auth_common.lookupSession(ctx.allocator, di.db, tok) orelse return;
            if (sess.user_id.len <= owner_buf.len) {
                @memcpy(owner_buf[0..sess.user_id.len], sess.user_id);
                owner = owner_buf[0..sess.user_id.len];
            }
            auth_common.freeSessionLookup(ctx.allocator, sess);
        }
    } else |_| {}
    const server: *gserverz.GinwaServer = @ptrCast(@alignCast(server_ptr));
    const allocator = ctx.allocator;

    const id = req.query.get("id") orelse return;
    if (id.len == 0) return;
    const session = terminal_session.getSessionForOwner(id, owner) orelse return;
    // Attach = explicit user action (tab switch): refresh the user
    // stamp so switching back to a session keeps it alive.
    terminal_session.touchUser(session);

    // No PTY backend on this host: the close handshake runs on return.
    // Both real backends pump through the SAME loop below — POSIX forkpty
    // and Windows ConPTY differ only in `waitReadable`, which picks the
    // host's readiness primitive (poll(2) vs WSAPoll + PeekNamedPipe).
    if (comptime terminal_session.is_pty_os) {
        return pump(server, allocator, client_fd, id, session);
    } else {
        return;
    }
}

/// Connection pump (every host with a PTY backend — see the gate above).
fn pump(
    server: *gserverz.GinwaServer,
    allocator: std.mem.Allocator,
    client_fd: i32,
    id: []const u8,
    session: *terminal_session.Session,
) !void {
    _ = session;
    // Attach flush: everything currently buffered, then stream.
    // Owned copy under the session lock — no borrow survives the
    // unlock, so a concurrent drain realloc can't free what we send.
    {
        const attached = terminal_session.getSession(id) orelse return;
        const out = terminal_session.readOutputAlloc(allocator, attached, 0) catch return;
        defer allocator.free(out.data);
        if (out.data.len > 0) {
            // Cap the attach burst (long-lived sessions may hold 256 KiB).
            const burst = out.data[0..@min(out.data.len, max_forward_per_tick)];
            sendBinary(server, allocator, client_fd, burst) catch return;
        }
        if (out.exited) {
            sendExit(server, allocator, client_fd, out.exit_code) catch {};
            return;
        }
    }
    var cursor: u64 = if (terminal_session.getSession(id)) |s| s.totalCursor() else return;

    var net_buf: [8192]u8 = undefined;
    var pending = std.ArrayList(u8).empty;
    defer pending.deinit(allocator);

    while (true) {
        // Re-resolve the session every tick: DELETE or the idle sweep
        // may have freed it while we held no lock. A null lookup ends
        // the socket; the session is gone so there is nothing to pump.
        const live = terminal_session.getSession(id) orelse return;
        // Multiplex console + socket (no threads — one tick, both sides).
        const ready = terminal_session.waitReadable(live, client_fd, pump_tick_ms);

        // PTY → socket.
        if (ready.pty) {
            const cur = terminal_session.getSession(id) orelse return;
            const out = terminal_session.readOutputAlloc(allocator, cur, cursor) catch return;
            defer allocator.free(out.data);
            cursor = out.cursor;
            if (out.data.len > 0) {
                const burst = out.data[0..@min(out.data.len, max_forward_per_tick)];
                sendBinary(server, allocator, client_fd, burst) catch return;
            }
            if (out.exited) {
                sendExit(server, allocator, client_fd, out.exit_code) catch {};
                return;
            }
        } else {
            // No PTY bytes, but the child may have exited silently.
            const cur = terminal_session.getSession(id) orelse return;
            const out = terminal_session.readOutputAlloc(allocator, cur, cursor) catch return;
            defer allocator.free(out.data);
            cursor = out.cursor;
            if (out.exited) {
                sendExit(server, allocator, client_fd, out.exit_code) catch {};
                return;
            }
        }

        // Socket → PTY.
        if (!ready.sock) continue;
        const n = server.recvFromClient(client_fd, &net_buf) catch return;
        if (n == 0) return; // peer closed
        if (pending.items.len + n > max_pending) return;
        pending.appendSlice(allocator, net_buf[0..n]) catch return;

        // Handle every complete frame in the buffer.
        while (pending.items.len > 0) {
            const wire_len = frameWireLen(pending.items) catch |err| {
                if (err == error.IncompleteFrame) break;
                return; // InvalidFrame / FrameTooLarge — protocol error.
            };
            var frame = ws_frames.parseFrame(allocator, pending.items[0..wire_len]) catch return;
            defer frame.deinit(allocator);

            switch (frame.opcode) {
                .text => {
                    const cur = terminal_session.getSession(id) orelse return;
                    const keep = handleControl(server, allocator, client_fd, cur, frame.payload) catch return;
                    if (!keep) return;
                },
                .binary => {}, // binary C→S is ignored (input goes via JSON).
                .ping => sendPong(server, allocator, client_fd, frame.payload) catch return,
                .close => return,
                else => {},
            }

            // Shift the consumed frame off the buffer.
            const rest = pending.items.len - wire_len;
            std.mem.copyForwards(u8, pending.items[0..rest], pending.items[wire_len..]);
            pending.items.len = rest;
        }
    }
}

// ---------------------------------------------------------------------
// Inline tests (framing + control parsing; the live socket is covered by the
// functional WS harness test).

const testing = std.testing;

fn maskedTextFrame(allocator: std.mem.Allocator, payload: []const u8) ![]u8 {
    // Minimal masked client frame (FIN + text, len < 126).
    var out = std.ArrayList(u8).empty;
    errdefer out.deinit(allocator);
    try out.append(allocator, 0x81);
    try out.append(allocator, 0x80 | @as(u8, @intCast(payload.len)));
    const mask = [_]u8{ 0x12, 0x34, 0x56, 0x78 };
    try out.appendSlice(allocator, &mask);
    for (payload, 0..) |b, i| try out.append(allocator, b ^ mask[i % 4]);
    return out.toOwnedSlice(allocator);
}

test "frameWireLen measures a masked text frame" {
    const wire = try maskedTextFrame(testing.allocator, "hi");
    defer testing.allocator.free(wire);
    try testing.expectEqual(wire.len, try frameWireLen(wire));
}

test "frameWireLen handles 16-bit extended length" {
    var payload: [300]u8 = undefined;
    @memset(&payload, 'A');
    var out = std.ArrayList(u8).empty;
    defer out.deinit(testing.allocator);
    try out.append(testing.allocator, 0x82); // FIN + binary
    try out.append(testing.allocator, 0x80 | 126);
    try out.append(testing.allocator, 0x01); // 300 >> 8
    try out.append(testing.allocator, 0x2C); // 300 & 0xFF
    try out.appendSlice(testing.allocator, &[_]u8{ 1, 2, 3, 4 }); // mask
    try out.appendSlice(testing.allocator, &payload);
    try testing.expectEqual(out.items.len, try frameWireLen(out.items));
}

test "frameWireLen reports IncompleteFrame on short buffers" {
    try testing.expectError(error.IncompleteFrame, frameWireLen(&[_]u8{}));
    try testing.expectError(error.IncompleteFrame, frameWireLen(&[_]u8{0x81}));
    const wire = try maskedTextFrame(testing.allocator, "hello");
    defer testing.allocator.free(wire);
    try testing.expectError(error.IncompleteFrame, frameWireLen(wire[0 .. wire.len - 1]));
}

test "frameWireLen rejects unmasked frames" {
    // Server→client style frame (no mask bit) must never arrive C→S.
    try testing.expectError(error.InvalidFrame, frameWireLen(&[_]u8{ 0x81, 0x02, 'h', 'i' }));
}

test "control JSON parses input and resize shapes" {
    var input = try std.json.parseFromSlice(WsControl, testing.allocator, "{\"type\":\"input\",\"data\":\"ls\\n\"}", .{});
    defer input.deinit();
    try testing.expectEqualStrings("input", input.value.type);
    try testing.expectEqualStrings("ls\n", input.value.data.?);

    var resize = try std.json.parseFromSlice(WsControl, testing.allocator, "{\"type\":\"resize\",\"cols\":100,\"rows\":40}", .{});
    defer resize.deinit();
    try testing.expectEqualStrings("resize", resize.value.type);
    try testing.expectEqual(@as(u16, 100), resize.value.cols.?);
}
