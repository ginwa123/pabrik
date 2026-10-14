// Functional regression for "the second turn never shows up in pabrik-tui".
// Zig port of `tests/functional/tui_turn_streaming_test.py` (same test names,
// same order).

const std = @import("std");
const testing = std.testing;
const builtin = @import("builtin");
const harness = @import("harness.zig");
const Harness = harness.Harness;

const Io = std.Io;
const linux = std.os.linux;
const posix = std.posix;

const gpa = testing.allocator;
const io = testing.io;

// ============================================================================
// Turn fixtures
// ============================================================================

const TURN1_USER = "first question";
const TURN1_REPLY = "FIRST-TURN-REPLY";
const TURN2_USER = "second question";
const TURN2_REPLY = "SECOND-TURN-REPLY";

/// What the fake backend serves. It advances one step per GET so the
/// client observes: turn 1 streaming -> turn 1 stop -> turn 2 user ->
/// turn 2 stop.
const TURN1 = [_][]const u8{
    \\{"id":"u1","role":"user","content":"first question"}
    ,
    \\{"id":"a1","role":"assistant","content":"FIRST-TURN-REPLY","finish_reason":"stop"}
    ,
};

const TURN2_USER_ROW =
    \\{"id":"u2","role":"user","content":"second question"}
;
const TURN2_REPLY_ROW =
    \\{"id":"a2","role":"assistant","content":"SECOND-TURN-REPLY","finish_reason":"stop"}
;

// Only reached once the client sends its SECOND message — a client that
// stops polling (the bug) never asks for these.
const SEQ_AFTER_POST_1 = [_][]const u8{
    TURN1[0],
    TURN1[0],
    TURN1[1],
    TURN1[0],
    TURN1[1],
    TURN1[0],
    TURN1[1],
};
const SEQ_AFTER_POST_2 = [_][]const u8{
    TURN1[0],        TURN1[1],        TURN2_USER_ROW,
    TURN1[0],        TURN1[1],        TURN2_USER_ROW,
    TURN1[0],        TURN1[1],        TURN2_USER_ROW,
    TURN2_REPLY_ROW, TURN1[0],        TURN1[1],
    TURN2_USER_ROW,  TURN2_REPLY_ROW,
};

/// Join a sequence of message rows into `{"messages":[...]}`. `{"messages":[
/// <seq[index]> ]}` — ONE poll step, not the whole sequence. Owned by the
/// caller.
fn messagesBody(allocator: std.mem.Allocator, seq: []const []const u8, index: usize) ![]u8 {
    const rows = seq[index .. index + 1];
    var w: Io.Writer.Allocating = .init(allocator);
    errdefer w.deinit();
    const out = &w.writer;
    try out.writeAll("{\"messages\":[");
    for (rows, 0..) |row, i| {
        if (i > 0) try out.writeAll(",");
        try out.writeAll(row);
    }
    try out.writeAll("]}");
    return w.toOwnedSlice();
}

// ============================================================================
// Stub backend
// ============================================================================

/// A one-request-at-a-time HTTP stub serving the two-turn sequence, driven by
/// its own thread.
const Backend = struct {
    io: Io,
    port: u16 = 0,
    server: Io.net.Server = undefined,
    thread: std.Thread = undefined,
    /// Named `stop_flag`, not `stop`: the method below is `stop`, and a
    /// struct cannot carry a field and a function of the same name.
    stop_flag: std.atomic.Value(bool) = .init(false),
    /// Guards `posts` / `gets`: the serve thread writes them while the test
    /// reads `posts` after the TUI has been driven.
    mutex: Io.Mutex = .init,
    posts: usize = 0,
    gets: usize = 0,

    fn start(self: *Backend) !void {
        self.port = try harness.findFreePortRandom(gpa);
        const addr: Io.net.IpAddress = .{ .ip4 = .loopback(self.port) };
        self.server = try addr.listen(self.io, .{ .reuse_address = true });
        errdefer self.server.deinit(self.io);
        self.thread = try std.Thread.spawn(.{}, serve, .{self});
    }

    /// Wake the blocked `accept`, join, and free.
    fn stop(self: *Backend) void {
        self.stop_flag.store(true, .release);
        const addr: Io.net.IpAddress = .{ .ip4 = .loopback(self.port) };
        if (addr.connect(self.io, .{ .mode = .stream })) |conn| {
            var c = conn;
            c.close(self.io);
        } else |_| {}
        self.thread.join();
        self.server.deinit(self.io);
    }

    fn readPosts(self: *Backend) usize {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        return self.posts;
    }
};

fn serve(b: *Backend) void {
    while (true) {
        // `defer` inside a loop body runs at the end of THAT iteration,
        // so each accepted socket is closed before the next accept.
        var stream = b.server.accept(b.io) catch break;
        defer stream.close(b.io);
        if (b.stop_flag.load(.acquire)) break;
        handleRequest(b, stream) catch {};
    }
}

fn handleRequest(b: *Backend, stream: Io.net.Stream) !void {
    var rbuf: [64 * 1024]u8 = undefined;
    var sr = stream.reader(b.io, &rbuf);
    const r = &sr.interface;

    var acc: Io.Writer.Allocating = .init(gpa);
    defer acc.deinit();

    // THE HEAD AND THE BODY OVERLAP IN THE SOCKET BUFFER. `fill(1)` reads a
    // whole syscall's worth, so one call typically returns the head AND the
    // first chunk of the body.
    var head_len: usize = 0;
    while (head_len == 0) {
        r.fill(1) catch return;
        const chunk = r.buffered();
        if (chunk.len == 0) return;
        acc.writer.writeAll(chunk) catch return;
        r.toss(chunk.len);
        if (std.mem.indexOf(u8, acc.written(), "\r\n\r\n")) |i| head_len = i + 4;
    }
    const head = acc.written()[0..head_len];

    var remaining = contentLength(head);
    if (acc.written().len > head_len) remaining -|= acc.written().len - head_len;
    while (remaining > 0) {
        r.fill(1) catch return;
        const chunk = r.buffered();
        if (chunk.len == 0) return;
        const take = @min(chunk.len, remaining);
        remaining -= take;
        r.toss(take);
    }

    var lines = std.mem.splitSequence(u8, head, "\r\n");
    const request_line = lines.next() orelse return;

    const is_post = std.mem.startsWith(u8, request_line, "POST ");
    if (is_post) {
        b.mutex.lockUncancelable(b.io);
        b.posts += 1;
        // Turn 2 begins: reset the GET sequence so the client sees turn 1's
        // rows (including its `stop`) followed by turn 2's.
        if (b.posts > 1) b.gets = 0;
        b.mutex.unlock(b.io);
    } else {
        b.mutex.lockUncancelable(b.io);
        const idx = b.gets;
        b.gets += 1;
        b.mutex.unlock(b.io);

        const seq: []const []const u8 = if (b.readPosts() <= 1) &SEQ_AFTER_POST_1 else &SEQ_AFTER_POST_2;
        // `min(gets, len(seq) - 1)` — the sequence sticks on its last
        // entry rather than wrapping.
        const step = @min(idx, seq.len - 1);
        const body = try messagesBody(gpa, seq, step);
        defer gpa.free(body);
        try writeJson(stream, b.io, body);
        return;
    }

    // The POST reply is the session id.
    try writeJson(stream, b.io, "{\"session_id\":\"tui-turn-streaming\"}");
}

fn writeJson(stream: Io.net.Stream, io_: Io, body: []const u8) !void {
    var wbuf: [8 * 1024]u8 = undefined;
    var sw = stream.writer(io_, &wbuf);
    try sw.interface.print(
        "HTTP/1.1 200 OK\r\n" ++
            "Content-Type: application/json\r\n" ++
            "Content-Length: {d}\r\n" ++
            "Connection: close\r\n" ++
            "\r\n" ++
            "{s}",
        .{ body.len, body },
    );
    try sw.interface.flush();
}

fn contentLength(head: []const u8) usize {
    var lines = std.mem.splitSequence(u8, head, "\r\n");
    _ = lines.next(); // request line
    while (lines.next()) |line| {
        if (line.len == 0) break;
        const colon = std.mem.indexOfScalar(u8, line, ':') orelse continue;
        if (!std.ascii.eqlIgnoreCase(std.mem.trim(u8, line[0..colon], " \t"), "content-length")) continue;
        return std.fmt.parseInt(usize, std.mem.trim(u8, line[colon + 1 ..], " \t"), 10) catch 0;
    }
    return 0;
}

// ============================================================================
// PTY + the TUI child
// ============================================================================

const TIOCSPTLCK: u32 = 0x40045431;
const TIOCGPTN: u32 = 0x80045430;
const TIOCSWINSZ: u32 = 0x5414;

const Winsize = extern struct { row: u16, col: u16, xpixel: u16, ypixel: u16 };

fn checkedFd(rc: usize, what: []const u8) !posix.fd_t {
    if (std.posix.errno(rc) != .SUCCESS) {
        std.debug.print("open {s} failed: {t}\n", .{ what, std.posix.errno(rc) });
        return error.PtyUnavailable;
    }
    return @intCast(rc);
}

/// Open a PTY pair, sized 50x200 like the Python's `TIOCSWINSZ` ioctl.
fn openPty() !struct { master: posix.fd_t, slave: posix.fd_t } {
    const master = try checkedFd(
        linux.open("/dev/ptmx", .{ .ACCMODE = .RDWR, .NOCTTY = true }, 0),
        "/dev/ptmx",
    );
    errdefer _ = linux.close(master);

    // unlockpt: the ioctl ARGUMENT is a POINTER to an int, not the int.
    // Passing `0` faults, and the slave open then fails `EIO`.
    var unlock: c_int = 0;
    if (std.posix.errno(linux.ioctl(master, TIOCSPTLCK, @intFromPtr(&unlock))) != .SUCCESS) {
        std.debug.print("unlockpt (TIOCSPTLCK) failed\n", .{});
        return error.PtyUnavailable;
    }

    var pty_number: u32 = 0;
    if (std.posix.errno(linux.ioctl(master, TIOCGPTN, @intFromPtr(&pty_number))) != .SUCCESS) {
        std.debug.print("ptsname (TIOCGPTN) failed\n", .{});
        return error.PtyUnavailable;
    }

    var name_buf: [64]u8 = undefined;
    const pts_path = std.fmt.bufPrintZ(&name_buf, "/dev/pts/{d}", .{pty_number}) catch
        return error.PtyUnavailable;
    const slave = try posix.openat(
        posix.AT.FDCWD,
        pts_path,
        .{ .ACCMODE = .RDWR, .NOCTTY = true },
        0,
    );
    errdefer _ = linux.close(slave);

    const ws = Winsize{ .row = 50, .col = 200, .xpixel = 0, .ypixel = 0 };
    _ = linux.ioctl(slave, TIOCSWINSZ, @intFromPtr(&ws));

    return .{ .master = master, .slave = slave };
}

/// A running `pabrik-tui` attached to a PTY, with a reader thread
/// accumulating its output. This is Python's `_Tui`.
const Tui = struct {
    master: posix.fd_t,
    child: std.process.Child,
    reader: std.Thread,
    /// Set by `deinit`, polled by the reader thread.
    stop: std.atomic.Value(bool) = .init(false),
    mutex: Io.Mutex = .init,
    chunks: std.ArrayList(u8) = .empty,

    /// Resolve the `pabrik-tui` binary, or skip.
    fn resolveBin() ![]u8 {
        const env_bin = std.testing.environ.getAlloc(gpa, "PABRIK_TUI_BIN") catch "";
        defer gpa.free(env_bin);

        const candidates = [_][]const u8{
            env_bin,
            "zig-out/bin/pabrik-tui",
            "zig-out/bin/pabrik-tui.exe",
        };
        for (candidates) |c| {
            if (c.len == 0) continue;
            var buf: [std.fs.max_path_bytes]u8 = undefined;
            const len = std.Io.Dir.cwd().realPathFile(io, c, &buf) catch continue;
            if (isExecutable(buf[0..len])) return gpa.dupe(u8, buf[0..len]);
        }
        return error.SkipZigTest;
    }

    /// Returns a HEAP-ALLOCATED `*Tui`, or null after cleaning up. WHY A
    /// POINTER, NOT A VALUE.
    fn start(backend_port: u16) !?*Tui {
        if (comptime builtin.os.tag != .linux) return error.SkipZigTest;

        const bin = try resolveBin();
        defer gpa.free(bin);

        const pty = try openPty();
        errdefer _ = linux.close(pty.master);
        errdefer _ = linux.close(pty.slave);

        const url = try std.fmt.allocPrint(gpa, "http://127.0.0.1:{d}", .{backend_port});
        defer gpa.free(url);

        const slave_file: std.Io.File = .{ .handle = pty.slave, .flags = .{ .nonblocking = false } };
        const child = try std.process.spawn(io, .{
            .argv = &.{ bin, "--server", url },
            .stdin = .{ .file = slave_file },
            .stdout = .{ .file = slave_file },
            .stderr = .{ .file = slave_file },
            // Own process group, so the SIGTERM below reaches any subprocess
            // the TUI spawned.
            .pgid = 0,
        });
        // The child's stdio are dups; ours must go or the master never
        // sees EOF. Python did the same with `os.close(slave)`.
        _ = linux.close(pty.slave);

        const self = try gpa.create(Tui);
        // `gpa.create` does NOT apply field defaults. Assigning `.*`
        // applies them all in one shot; `child` is filled in below.
        self.* = .{
            .master = pty.master,
            .child = child,
            .reader = undefined,
        };
        errdefer gpa.destroy(self);
        self.reader = try std.Thread.spawn(.{}, drain, .{self});

        // Python's fixture: `time.sleep(1.5)` after spawn, before the first
        // keystroke.
        std.Io.sleep(io, .fromMilliseconds(1_500), .awake) catch {};
        return self;
    }

    /// Stop the child, stop the reader, free everything. Explicit ordering
    /// rather than a chain of `defer`s, because the order is load-bearing: 1.
    fn deinit(self: *Tui) void {
        harness.signalGroup(@intCast(self.child.id.?), harness.SIGTERM);
        // The TUI restores the terminal on the way out; give it a
        // moment before escalating, as Python's `wait(timeout=5)` did.
        std.Io.sleep(io, .fromMilliseconds(250), .awake) catch {};
        // `kill` is idempotent and reaps — do NOT call `wait` after it.
        self.child.kill(io);

        self.stop.store(true, .release);
        self.reader.join();

        _ = linux.close(self.master);

        self.chunks.deinit(gpa);
        gpa.destroy(self);
    }

    /// Type `text` one byte at a time (the TUI is in raw mode and reads
    /// key-by-key), then Enter, then let the frame settle.
    fn typeAndSend(self: *Tui, text: []const u8, settle_ms: i64) !void {
        for (text) |ch| {
            try self.writeMaster(&[_]u8{ch});
            std.Io.sleep(io, .fromMilliseconds(20), .awake) catch {};
        }
        try self.writeMaster("\r");
        std.Io.sleep(io, .fromMilliseconds(settle_ms), .awake) catch {};
    }

    /// Write to the PTY master (i.e. send input to the child).
    fn writeMaster(self: *Tui, bytes: []const u8) !void {
        const rc = linux.write(self.master, bytes.ptr, bytes.len);
        const errno = std.posix.errno(rc);
        if (errno != .SUCCESS) {
            std.debug.print("write to pty master failed: {t}\n", .{errno});
            return error.PtyWriteFailed;
        }
        const written: usize = @intCast(rc);
        if (written != bytes.len) return error.PtyWriteFailed;
    }

    /// Terminal output with CSI/OSC escape sequences stripped — Python's
    /// `_Tui.plain`. Returns an OWNED buffer the caller frees.
    fn plain(self: *Tui) ![]u8 {
        self.mutex.lockUncancelable(io);
        defer self.mutex.unlock(io);

        var w: Io.Writer.Allocating = .init(gpa);
        errdefer w.deinit();
        const out = &w.writer;

        var i: usize = 0;
        const src = self.chunks.items;
        while (i < src.len) {
            if (src[i] != 0x1b) {
                try out.writeByte(src[i]);
                i += 1;
                continue;
            }
            if (i + 1 >= src.len) break;
            switch (src[i + 1]) {
                // CSI: ESC [ <params> <final byte>
                '[' => {
                    var j = i + 2;
                    while (j < src.len) : (j += 1) {
                        const c = src[j];
                        if ((c >= '0' and c <= '9') or c == ';' or c == '?') continue;
                        break;
                    }
                    if (j < src.len and isAlpha(src[j])) j += 1;
                    i = j;
                },
                // OSC: ESC ] ... BEL
                ']' => {
                    var j = i + 2;
                    while (j < src.len and src[j] != 0x07) : (j += 1) {}
                    if (j < src.len) j += 1;
                    i = j;
                },
                else => {
                    // Not a sequence this regex matched — Python left
                    // the ESC byte in place too, so do the same.
                    try out.writeByte(src[i]);
                    i += 1;
                },
            }
        }
        return w.toOwnedSlice();
    }
};

/// THE FIRST LINE OF EVERY BOOTING TEST IN THIS FILE.
fn requireTuiBin() !void {
    const bin = try Tui.resolveBin();
    defer gpa.free(bin);
}

fn isAlpha(c: u8) bool {
    return (c >= 'A' and c <= 'Z') or (c >= 'a' and c <= 'z');
}

fn isExecutable(path: []const u8) bool {
    std.Io.Dir.cwd().access(io, path, .{ .execute = true }) catch return false;
    return true;
}

/// Drain the PTY master into `chunks` until `stop`.
fn drain(t: *Tui) void {
    var scratch: [16 * 1024]u8 = undefined;
    var fds = [_]posix.pollfd{.{
        .fd = t.master,
        .events = posix.POLL.IN,
        .revents = 0,
    }};

    while (!t.stop.load(.acquire)) {
        const ready = posix.poll(&fds, 100) catch 0;
        if (ready == 0) continue;
        // A PTY master reports EOF as `EIO` once the slave is gone, not
        // as a zero-length read. Either ends the loop.
        const got = posix.read(t.master, &scratch) catch break;
        if (got == 0) break;

        t.mutex.lockUncancelable(io);
        t.chunks.appendSlice(gpa, scratch[0..got]) catch {};
        t.mutex.unlock(io);
    }
}

// ============================================================================
// Tests
// ============================================================================

// Control: the turn that worked before must keep working.
test "first_turn_renders" {
    try requireTuiBin();

    var backend: Backend = .{ .io = io };
    try backend.start();
    defer backend.stop();

    var tui = (try Tui.start(backend.port)) orelse return error.TuiNotStarted;
    defer tui.deinit();

    try tui.typeAndSend(TURN1_USER, 6_000);

    const screen = try tui.plain();
    defer gpa.free(screen);

    if (std.mem.indexOf(u8, screen, TURN1_USER) == null) {
        std.debug.print("turn-1 user message missing; screen was:\n{s}\n", .{screen});
        return error.TestUnexpectedResult;
    }
    if (std.mem.indexOf(u8, screen, TURN1_REPLY) == null) {
        std.debug.print("turn-1 reply missing; screen was:\n{s}\n", .{screen});
        return error.TestUnexpectedResult;
    }
}

// The regression: a completed previous turn must not end the next one. The
// poll response always contains the whole session, so turn 1's
// `finish_reason="stop"` row is present during turn 2.
test "second_turn_renders_after_the_previous_turn_finished" {
    try requireTuiBin();

    var backend: Backend = .{ .io = io };
    try backend.start();
    defer backend.stop();

    var tui = (try Tui.start(backend.port)) orelse return error.TuiNotStarted;
    defer tui.deinit();

    try tui.typeAndSend(TURN1_USER, 6_000);
    {
        const screen = try tui.plain();
        defer gpa.free(screen);
        if (std.mem.indexOf(u8, screen, TURN1_REPLY) == null) {
            std.debug.print("turn-1 reply missing before turn 2; screen was:\n{s}\n", .{screen});
            return error.TestUnexpectedResult;
        }
    }

    try tui.typeAndSend(TURN2_USER, 8_000);

    const screen = try tui.plain();
    defer gpa.free(screen);

    if (std.mem.indexOf(u8, screen, TURN2_USER) == null) {
        std.debug.print(
            "turn-2 user message never reached the viewport — the TUI stopped " ++
                "polling after it saw turn 1's finish_reason=stop\nscreen was:\n{s}\n",
            .{screen},
        );
        return error.TestUnexpectedResult;
    }
    if (std.mem.indexOf(u8, screen, TURN2_REPLY) == null) {
        std.debug.print("turn-2 reply never reached the viewport; screen was:\n{s}\n", .{screen});
        return error.TestUnexpectedResult;
    }
    // The fake backend only serves turn 2's payloads once the client
    // has sent its second message, so reaching them proves polling
    // continued.
    if (backend.readPosts() != 2) {
        std.debug.print(
            "expected exactly 2 POSTs (one per typed message), got {d}\n",
            .{backend.readPosts()},
        );
        return error.TestUnexpectedResult;
    }
}

// Body-analysis barrier. An unreferenced function is never type-checked,
// so a stdlib rename inside one stays invisible until a caller appears.
comptime {
    _ = messagesBody;
    _ = Backend.start;
    _ = Backend.stop;
    _ = Backend.readPosts;
    _ = serve;
    _ = handleRequest;
    _ = writeJson;
    _ = contentLength;
    _ = checkedFd;
    _ = openPty;
    _ = Tui.resolveBin;
    _ = requireTuiBin;
    _ = Tui.start;
    _ = Tui.deinit;
    _ = Tui.typeAndSend;
    _ = Tui.plain;
    _ = isAlpha;
    _ = isExecutable;
    _ = drain;
}
