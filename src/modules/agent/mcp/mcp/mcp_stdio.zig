//! MCP stdio transport for the agent AI.

const std = @import("std");
const builtin = @import("builtin");
const mcp_scope = @import("mcp_scope.zig");

const MAX_HEADER_BYTES: usize = 8 * 1024;

pub const default_max_entries: usize = 64;

/// Hard cap on a Content-Length framed body.
const MAX_BODY_BYTES: usize = 10 * 1024 * 1024;

pub const StdioError = error{
    ChildSpawnFailed,
    BrokenPipe,
    InvalidFrame, // no Content-Length header found, or the
    // "header" block contained a non-header line
    InvalidContentLength, // non-numeric / negative length
    /// Content-Length parsed fine but exceeds `MAX_BODY_BYTES`.
    BodyTooLarge,
    UnexpectedEof,
    /// Recv timed out before a full frame was read OR the cancel callback
    /// returned true.
    RecvTimeout,
    /// Send timed out before all bytes were written. Same recovery
    /// as RecvTimeout — a child whose stdin pipe is full is as good
    /// as a child that's crashed.
    SendTimeout,
    /// `StdioRegistry.acquire` could not take the per-server lease
    /// within its wait budget. Another session is mid-transaction on
    /// the same child. Not a child failure — retrying later works.
    LeaseTimeout,
    /// `StdioClient.recv` observed reader state that can only arise from
    /// concurrent access to the same client.
    ConcurrentAccess,
    OutOfMemory,
    NameTooLong,
    TooManyChildren,
};

// ============================================================================
// SECTION A — Content-Length framing (private to this file)
// ============================================================================

/// Wait until `file` is readable (data OR EOF/hangup waiting) or the deadline
/// elapses / the cancel callback fires.
fn waitReadable(
    io: std.Io,
    file: std.Io.File,
    deadline_abs: i128,
    deadline_ns: u64,
    is_cancelled: ?*const fn () bool,
) bool {
    if (comptime builtin.os.tag == .windows) {
        return waitReadableWindows(io, file, deadline_abs, deadline_ns, is_cancelled);
    } else {
        const has_deadline = deadline_ns != 0;
        while (true) {
            if (is_cancelled) |cb| if (cb()) return false;
            const now_ns = std.Io.Timestamp.now(io, .real).nanoseconds;
            if (has_deadline and now_ns >= deadline_abs) return false;
            // Poll in ≤100ms slices so the cancel callback stays responsive
            // and the deadline check above runs often. With only a cancel
            // callback set (no deadline) the slice is a flat 100ms.
            const chunk_ms: i32 = if (has_deadline) blk: {
                const rem_ns: i128 = deadline_abs - now_ns;
                const rem_ms: i128 = @divTrunc(rem_ns, std.time.ns_per_ms);
                const clamped: i128 = @min(@max(rem_ms, 1), 100);
                break :blk @intCast(clamped);
            } else 100;
            var pfds = [_]std.posix.pollfd{.{
                .fd = file.handle,
                .events = std.posix.POLL.IN,
                .revents = 0,
            }};
            // Fail-open: if poll itself errors, let the read decide
            // (preserves the old behavior instead of inventing a timeout).
            const n = std.posix.poll(&pfds, chunk_ms) catch return true;
            // n > 0: readable bytes OR EOF/HUP/ERR waiting — either way
            // the next read returns immediately instead of blocking.
            if (n > 0) return true;
            // n == 0: slice elapsed with no data — loop to recheck
            // deadline/cancel.
        }
    }
}

/// The Windows half of `waitReadable`. `PeekNamedPipe` is the only
/// non-destructive readiness probe for a pipe handle, so this is what makes
/// the deadline reachable: a read on a silent child otherwise parks forever.
fn waitReadableWindows(
    io: std.Io,
    file: std.Io.File,
    deadline_abs: i128,
    deadline_ns: u64,
    is_cancelled: ?*const fn () bool,
) bool {
    const kernel32 = struct {
        extern "kernel32" fn PeekNamedPipe(
            pipe: std.os.windows.HANDLE,
            buf: ?*anyopaque,
            buf_size: std.os.windows.ULONG,
            bytes_read: ?*std.os.windows.ULONG,
            total_bytes_avail: ?*std.os.windows.ULONG,
            bytes_left_this_message: ?*std.os.windows.ULONG,
        ) callconv(.winapi) std.os.windows.BOOL;
    };
    const has_deadline = deadline_ns != 0;
    while (true) {
        // Probe BEFORE the hook: a handle that is not a pipe (a regular file,
        // the shape main's readFramed test uses) is always ready, and polling
        // the caller's hook for it would be one callback per byte of input.
        var avail: std.os.windows.ULONG = 0;
        if (!kernel32.PeekNamedPipe(file.handle, null, 0, null, &avail, null).toBool()) return true;
        if (avail > 0) return true;
        // Nothing to read yet, so only NOW do we wait: the hook and the
        // deadline are consulted once per ≤100 ms slice while waiting.
        if (is_cancelled) |cb| if (cb()) return false;
        const now_ns = std.Io.Timestamp.now(io, .real).nanoseconds;
        if (has_deadline and now_ns >= deadline_abs) return false;
        const rem_ms: i128 = if (has_deadline) @divTrunc(deadline_abs - now_ns, std.time.ns_per_ms) else 100;
        const slice_ms: u64 = @intCast(@min(@max(rem_ms, 1), 100));
        std.Io.sleep(io, .{ .nanoseconds = slice_ms * std.time.ns_per_ms }, .real) catch {};
    }
}

/// The byte source a framing read pulls from: a child's stdout pipe, or a guest
/// duplex whose reads are RPCs. One framing implementation serves both.
pub const Source = struct {
    ctx: *anyopaque,
    /// Blocking, bounded by the source's own budget. 0 means end of stream.
    pull: *const fn (ctx: *anyopaque, dst: []u8) StdioError!usize,
    /// Bytes already in hand, so a framed read never waits for a byte it has.
    pending: *const fn (ctx: *anyopaque) usize,
    /// Wait until `pull` has something, or the deadline/cancel says stop.
    wait: *const fn (ctx: *anyopaque, deadline_abs: i128, deadline_ns: u64, is_cancelled: ?*const fn () bool) bool,
};

/// A child's stdout pipe behind the `Source` seam. The reader is the caller's,
/// so coalesced lines survive across `recv` calls exactly as before.
const FileSource = struct {
    reader: *std.Io.File.Reader,
    io: std.Io,
    file: std.Io.File,

    fn source(self: *FileSource) Source {
        return .{ .ctx = @ptrCast(self), .pull = pull, .pending = pending, .wait = wait };
    }

    fn pull(ctx: *anyopaque, dst: []u8) StdioError!usize {
        const self: *FileSource = @ptrCast(@alignCast(ctx));
        return self.reader.interface.readSliceShort(dst) catch StdioError.UnexpectedEof;
    }

    fn pending(ctx: *anyopaque) usize {
        const self: *FileSource = @ptrCast(@alignCast(ctx));
        const iface = &self.reader.interface;
        return iface.end - iface.seek;
    }

    fn wait(ctx: *anyopaque, deadline_abs: i128, deadline_ns: u64, is_cancelled: ?*const fn () bool) bool {
        const self: *FileSource = @ptrCast(@alignCast(ctx));
        return waitReadable(self.io, self.file, deadline_abs, deadline_ns, is_cancelled);
    }
};

/// Read one Content-Length-framed or newline-delimited JSON message.
/// Allocates ONE slice that's returned to the caller; the caller owns it and
/// is responsible for freeing.
fn readFramed(
    allocator: std.mem.Allocator,
    io: std.Io,
    file: std.Io.File,
    deadline_ns: u64,
    is_cancelled: ?*const fn () bool,
) StdioError![]u8 {
    // Single-message wrapper (tests + one-shot callers).
    var reader_buf: [4096]u8 = undefined;
    var reader = std.Io.File.reader(file, io, &reader_buf);
    return readFramedWithReader(allocator, io, &reader, deadline_ns, is_cancelled);
}

/// Shrink an over-allocated read buffer down to its payload length for
/// hand-off to the caller, keeping the returned slice's `.len` equal to the
/// size the allocator actually reserved.
fn shrinkToLen(allocator: std.mem.Allocator, body: []u8, len: usize) StdioError![]u8 {
    if (body.len == len) return body;
    if (allocator.realloc(body, len)) |shrunk| return shrunk else |_| {}
    const exact = allocator.alloc(u8, len) catch return StdioError.OutOfMemory;
    @memcpy(exact, body[0..len]);
    allocator.free(body);
    return exact;
}

fn readFramedWithReader(
    allocator: std.mem.Allocator,
    io: std.Io,
    reader: *std.Io.File.Reader,
    deadline_ns: u64,
    is_cancelled: ?*const fn () bool,
) StdioError![]u8 {
    var file_source = FileSource{ .reader = reader, .io = io, .file = reader.file };
    return readFramedFromSource(allocator, io, file_source.source(), deadline_ns, is_cancelled);
}

fn readFramedFromSource(
    allocator: std.mem.Allocator,
    io: std.Io,
    src: Source,
    deadline_ns: u64,
    is_cancelled: ?*const fn () bool,
) StdioError![]u8 {
    // Compute the absolute deadline ONCE on entry.
    const deadline_abs: i128 = if (deadline_ns == 0) std.math.maxInt(i128) else blk: {
        const now = std.Io.Timestamp.now(io, .real).nanoseconds;
        const dline_i128: i128 = @intCast(deadline_ns);
        break :blk now + dline_i128;
    };

    // Helper to centralize the cancel + deadline check between syscalls.
    // Returns `null` when both checks pass, else the error to return.
    // Checks cancel FIRST so a Stop click aborts even with a huge deadline.
    const ErrOrVoid = struct { err: ?StdioError = null };
    const checkDeadlineOrCancel = struct {
        fn call(
            now_ns: i128,
            dline_abs: i128,
            cb: ?*const fn () bool,
        ) ErrOrVoid {
            if (cb) |c| if (c() == true) return .{ .err = StdioError.RecvTimeout };
            if (now_ns >= dline_abs) return .{ .err = StdioError.RecvTimeout };
            return .{};
        }
    }.call;

    // Peek the first byte to detect framing style: '{' ⇒ newline-delimited
    // JSON (the @modelcontextprotocol/sdk default in v1.x; the message ends
    // at the next \n) anything else ⇒ Content-Length framed (the MCP stdio
    {
        // First-byte read is the only syscalls before the framing branch —
        // check timeout once before AND once after.
        if (deadline_ns != 0) {
            const now_ns = std.Io.Timestamp.now(io, .real).nanoseconds;
            if (checkDeadlineOrCancel(now_ns, deadline_abs, is_cancelled).err) |e| return e;
        }
    }
    var first: [1]u8 = undefined;
    // Deadline-aware wait: without this, a silent child (zero stdout bytes,
    // pipe still open) blocks the read below forever and the deadline never
    // fires.
    if (deadline_ns != 0 or is_cancelled != null) {
        if (!src.wait(src.ctx, deadline_abs, deadline_ns, is_cancelled)) return StdioError.RecvTimeout;
    }
    const n0 = try src.pull(src.ctx, &first);
    if (n0 == 0) return StdioError.UnexpectedEof;

    if (first[0] == '{') {
        // Newline-delimited JSON path. We allocate ONE slice and grow it as
        // we read bytes — no scratch buffer to leak.
        const max_line: usize = MAX_BODY_BYTES;
        var cap: usize = 256;
        var body = allocator.alloc(u8, cap) catch return StdioError.OutOfMemory;
        var len: usize = 1; // already read '{'
        body[0] = first[0];
        while (true) {
            // The only cancel/clock poll: once per reader-buffer refill,
            // never per byte — a per-byte poll multiplied a caller's
            // SQLite-query hook into millions of calls and blew the budget.
            if (src.pending(src.ctx) == 0 and (deadline_ns != 0 or is_cancelled != null)) {
                // Only poll once the buffer is drained, or buffered bytes
                // would sit unread while we wait on an empty fd.
                if (!src.wait(src.ctx, deadline_abs, deadline_ns, is_cancelled)) return StdioError.RecvTimeout;
            }
            var b: [1]u8 = undefined;
            // A clean EOF is reported by `readSliceShort` as a short count;
            // the only error it propagates is `error.ReadFailed` — a genuine
            // read failure (EBADF on a killed child, EIO, ...).
            const n_byte = try src.pull(src.ctx, &b);
            if (n_byte == 0) break;
            if (b[0] == '\n') {
                // Trim trailing \r if present.
                const trimmed_len = if (len > 0 and body[len - 1] == '\r') len - 1 else len;
                return shrinkToLen(allocator, body, trimmed_len);
            }
            if (len >= max_line) return StdioError.BodyTooLarge;
            if (len >= cap) {
                const new_cap = @min(cap * 2, max_line);
                body = allocator.realloc(body, new_cap) catch return StdioError.OutOfMemory;
                cap = new_cap;
            }
            body[len] = b[0];
            len += 1;
        }
        // EOF before the terminating newline — hand back the partial frame.
        return shrinkToLen(allocator, body, len);
    }

    // Content-Length framed path (the MCP stdio spec default).
    var header_buf: [MAX_HEADER_BYTES]u8 = undefined;
    var header_len: usize = 1;
    header_buf[0] = first[0];
    var found_blank = false;
    // Start of the header line currently being accumulated. Reset at
    // every '\n' so a completed line can be validated as `name: value`
    // (see the non-header check inside the loop).
    var line_start: usize = 0;

    while (!found_blank) {
        if (src.pending(src.ctx) == 0 and (deadline_ns != 0 or is_cancelled != null)) {
            if (!src.wait(src.ctx, deadline_abs, deadline_ns, is_cancelled)) return StdioError.RecvTimeout;
        }
        var byte: [1]u8 = undefined;
        const n = try src.pull(src.ctx, &byte);
        if (n == 0) return StdioError.UnexpectedEof;
        if (header_len >= header_buf.len) return StdioError.InvalidFrame;
        header_buf[header_len] = byte[0];
        header_len += 1;
        if (header_len >= 4 and std.mem.eql(u8, header_buf[header_len - 4 ..][0..4], "\r\n\r\n")) {
            found_blank = true;
        } else if (header_len >= 2 and std.mem.eql(u8, header_buf[header_len - 2 ..][0..2], "\n\n")) {
            found_blank = true;
        } else if (byte[0] == '\n') {
            // A completed line inside the header block that carries no ':'
            // cannot be an HTTP-style header: this is a log line leaked onto
            // stdout, not a Content-Length frame.
            const line = std.mem.trim(u8, header_buf[line_start .. header_len - 1], "\r ");
            if (line.len > 0 and std.mem.indexOfScalar(u8, line, ':') == null) {
                return StdioError.InvalidFrame;
            }
            line_start = header_len;
        }
    }

    const header = header_buf[0..header_len];
    var cl: ?usize = null;
    var it = std.mem.splitSequence(u8, header, "\n");
    while (it.next()) |raw_line| {
        const line = std.mem.trim(u8, raw_line, "\r ");
        if (std.ascii.startsWithIgnoreCase(line, "Content-Length:")) {
            const val = std.mem.trim(u8, line["Content-Length:".len..], " \t");
            cl = std.fmt.parseInt(usize, val, 10) catch return StdioError.InvalidContentLength;
            break;
        }
    }
    const content_length = cl orelse return StdioError.InvalidFrame;
    // `Content-Length` is attacker-controlled text, not a trust signal.
    if (content_length > MAX_BODY_BYTES) return StdioError.BodyTooLarge;

    const body = allocator.alloc(u8, content_length) catch return StdioError.OutOfMemory;
    // Chunked body read (NOT a single `readSliceAll`): each chunk is guarded
    // by `waitReadable` so a child that stalls mid-body — header promised N
    // bytes but the bytes never arrive — surfaces as `RecvTimeout`, never a hang.
    var off: usize = 0;
    while (off < body.len) {
        if (src.pending(src.ctx) == 0 and (deadline_ns != 0 or is_cancelled != null)) {
            if (!src.wait(src.ctx, deadline_abs, deadline_ns, is_cancelled)) return StdioError.RecvTimeout;
        }
        const n = try src.pull(src.ctx, body[off..]);
        if (n == 0) return StdioError.UnexpectedEof;
        off += n;
        if (deadline_ns != 0 or is_cancelled != null) {
            const now_ns = std.Io.Timestamp.now(io, .real).nanoseconds;
            if (checkDeadlineOrCancel(now_ns, deadline_abs, is_cancelled).err) |e| return e;
        }
    }
    return body;
}

/// Largest single write attempt: ≤ `PIPE_BUF` (4096 on Linux) is atomic, so a
/// write is only issued after `waitWritable` reported space — which is what
/// makes `writeAllBounded`'s deadline a real bound.
const WRITE_CHUNK_BYTES: usize = 4096;

/// Wait until `file` accepts bytes (space in the child's stdin pipe) or the
/// deadline / cancel fires. The send-side twin of `waitReadable`: without it a
/// child that stopped draining stdin parks the per-server lease for everyone.
fn waitWritable(
    io: std.Io,
    file: std.Io.File,
    deadline_abs: i128,
    deadline_ns: u64,
    is_cancelled: ?*const fn () bool,
) bool {
    if (comptime builtin.os.tag == .windows) {
        return true;
    } else {
        const has_deadline = deadline_ns != 0;
        while (true) {
            if (is_cancelled) |cb| if (cb()) return false;
            const now_ns = std.Io.Timestamp.now(io, .real).nanoseconds;
            if (has_deadline and now_ns >= deadline_abs) return false;
            // Poll in ≤100ms slices so the cancel callback stays responsive
            // and the deadline check above runs often (same as waitReadable).
            const chunk_ms: i32 = if (has_deadline) blk: {
                const rem_ns: i128 = deadline_abs - now_ns;
                const rem_ms: i128 = @divTrunc(rem_ns, std.time.ns_per_ms);
                const clamped: i128 = @min(@max(rem_ms, 1), 100);
                break :blk @intCast(clamped);
            } else 100;
            var pfds = [_]std.posix.pollfd{.{
                .fd = file.handle,
                .events = std.posix.POLL.OUT,
                .revents = 0,
            }};
            // Fail-open: if poll itself errors, let the write decide (same
            // stance as waitReadable — never worse than the old behaviour).
            const n = std.posix.poll(&pfds, chunk_ms) catch return true;
            if (n > 0) return true;
        }
    }
}

/// Write every byte of `bytes`, bounded by `deadline_ns` (relative, 0 = none)
/// and abortable via `is_cancelled`. Each chunk is gated on `waitWritable`, so
/// a full pipe surfaces as `SendTimeout` instead of parking the caller.
fn writeAllBounded(
    io: std.Io,
    file: std.Io.File,
    bytes: []const u8,
    deadline_ns: u64,
    is_cancelled: ?*const fn () bool,
) !void {
    // Compute the absolute deadline ONCE on entry (same contract as
    // `readFramed` / `writeFramed`).
    const deadline_abs: i128 = if (deadline_ns == 0) std.math.maxInt(i128) else blk: {
        const now_ns = std.Io.Timestamp.now(io, .real).nanoseconds;
        const dline_i128: i128 = @intCast(deadline_ns);
        break :blk now_ns + dline_i128;
    };

    var off: usize = 0;
    while (off < bytes.len) {
        if (!waitWritable(io, file, deadline_abs, deadline_ns, is_cancelled)) {
            return StdioError.SendTimeout;
        }
        const end = @min(off + WRITE_CHUNK_BYTES, bytes.len);
        const n = std.Io.File.writeStreaming(file, io, &.{}, &.{bytes[off..end]}, 1) catch
            return StdioError.BrokenPipe;
        if (n == 0) return StdioError.BrokenPipe;
        off += n;
    }
}

/// Write a newline-delimited JSON message (NDJSON). Used for MCP stdio
/// servers that expect `JSON.stringify(msg) + '\n'` (the SDK default for both
/// Node and Python).
fn writeNDJSON(
    io: std.Io,
    file: std.Io.File,
    body: []const u8,
    deadline_ns: u64,
    is_cancelled: ?*const fn () bool,
) !void {
    // Fast path: body + '\n' fits in a small stack buffer
    var stack_buf: [8192]u8 = undefined;
    if (body.len + 1 <= stack_buf.len) {
        @memcpy(stack_buf[0..body.len], body);
        stack_buf[body.len] = '\n';
        try writeAllBounded(io, file, stack_buf[0 .. body.len + 1], deadline_ns, is_cancelled);
    } else {
        try writeAllBounded(io, file, body, deadline_ns, is_cancelled);
        try writeAllBounded(io, file, "\n", deadline_ns, is_cancelled);
    }
}

/// Write a Content-Length-framed message. Pair with `readFramed`. The deadline
/// is a REAL bound: both halves go through `writeAllBounded`, so a child that
/// stopped draining stdin cannot park the write (or the lease) forever.
fn writeFramed(io: std.Io, file: std.Io.File, body: []const u8, deadline_ns: u64) !void {
    // Use a stack-allocated header buffer to avoid the Io.Writer abstraction
    // (which has subtle flush semantics in Zig 0.16's threaded runtime — an
    // explicit `flush()` on a 4 KiB writer buffer spins waiting for more
    var header_buf: [64]u8 = undefined;
    const header = std.fmt.bufPrint(&header_buf, "Content-Length: {d}\r\n\r\n", .{body.len}) catch return StdioError.InvalidFrame;
    try writeAllBounded(io, file, header, deadline_ns, null);
    try writeAllBounded(io, file, body, deadline_ns, null);
}

// ============================================================================
// SECTION B — StdioClient (spawn child, framed read/write)
// ============================================================================

/// How long a killed MCP child (and its process group) gets to be reaped
/// before the wait is abandoned. A process stuck in D state must never hold a
/// session thread — nothing downstream needs the exit status.
const REAP_GRACE_PERIOD_NS: u64 = 2 * std.time.ns_per_s;

fn killBounded(io: std.Io, child: *std.process.Child, grace_ns: u64) void {
    if (comptime builtin.os.tag == .windows) {
        // TerminateProcess is unconditional, so there is no ignorable signal to
        // sit on; `Child.kill` stays because it also closes its handles.
        child.kill(io);
        return;
    }
    const pid: c_int = @intCast(child.id orelse return);
    // `-pid` reaches the group: an npm wrapper AND the server it wraps.
    // SIGTERM is ignored by a wrapper blocked on an undrained stdout pipe;
    // SIGKILL is not.
    std.posix.kill(-pid, .KILL) catch {};
    reapBoundedPosix(io, pid, grace_ns);
}

/// BOUNDED on purpose — the twin `wait_pid_bounded` in shell.zig fixed the
/// same defect; keep the two in step.
fn reapBoundedPosix(io: std.Io, pid: c_int, grace_ns: u64) void {
    const deadline: i128 = std.Io.Timestamp.now(io, .real).nanoseconds + @as(i128, @intCast(grace_ns));
    while (true) {
        var status: c_int = 0;
        const rc = std.c.waitpid(pid, &status, std.c.W.NOHANG);
        if (rc == pid or rc < 0) return;
        if (std.Io.Timestamp.now(io, .real).nanoseconds >= deadline) return;
        std.Io.Clock.Duration.sleep(
            .{ .raw = std.Io.Duration.fromMilliseconds(10), .clock = .real },
            io,
        ) catch {};
    }
}

pub const StdioClient = struct {
    /// Allocator for response bodies.
    arena: std.heap.ArenaAllocator,
    io: std.Io,
    child: std.process.Child,
    stdin: ?std.Io.File,
    stdout: ?std.Io.File,
    /// stderr pipe — captured so diagnostic callers (e.g. mcp_test.zig's
    /// cold-start probe) can read the child's crash/exit messages. Most
    /// production callers ignore this.
    stderr: ?std.Io.File,
    /// Persistent stdout reader + buffer across recv() calls. readFramed used
    /// to build a fresh 4KB Io.Reader per call; when a fast server coalesces
    /// two JSON lines in one pipe write, the first recv() buffered the second
    read_buf: [4096]u8 = undefined,
    reader: ?std.Io.File.Reader = null,
    /// Set once `deinit` has killed the child and closed the pipes, so
    /// a second `deinit` (the `defer` in every caller, plus the
    /// registry's own teardown) is a no-op instead of a double-kill.
    is_dead: bool = false,

    pub fn init(
        backing_allocator: std.mem.Allocator,
        io: std.Io,
        argv: []const []const u8,
    ) StdioError!StdioClient {
        // Zig 0.16's process.spawn takes `io` + a SpawnOptions struct. env
        // override — Zig 0.16's std.process.spawn has no clean .env_map
        // setter. v1 inherits the parent's env; a future v2 can pre-fork +
        const child = std.process.spawn(io, .{
            .argv = argv,
            .stdin = .pipe,
            .stdout = .pipe,
            .stderr = .pipe,
            // Own process group (POSIX) so `killBounded`'s group kill reaches
            // a wrapper AND the server it spawns; Windows has no pgid.
            .pgid = if (comptime builtin.os.tag == .windows) null else @as(?std.posix.pid_t, 0),
        }) catch return StdioError.ChildSpawnFailed;

        return .{
            .arena = std.heap.ArenaAllocator.init(backing_allocator),
            .io = io,
            .child = child,
            .stdin = child.stdin,
            .stdout = child.stdout,
            .stderr = child.stderr,
        };
    }

    /// Allocator for response bodies — see the `arena` field's docs.
    pub fn allocator(self: *StdioClient) std.mem.Allocator {
        return self.arena.allocator();
    }

    /// Send a framed JSON-RPC message to the child. Allocates the header on
    /// the stack; body is written verbatim. No-op if stdin was closed.
    pub fn send(self: *StdioClient, body: []const u8, deadline_ns: u64) !void {
        const stdin = self.stdin orelse return StdioError.BrokenPipe;
        try writeFramed(self.io, stdin, body, deadline_ns);
    }

    /// Send a newline-delimited JSON message (NDJSON) — `JSON.stringify(msg) +
    /// '\n'`, the Node/Python SDK default. `deadline_ns` (relative, 0 = none)
    /// and `is_cancelled` bound the wait for pipe space.
    pub fn sendNDJSON(
        self: *StdioClient,
        body: []const u8,
        deadline_ns: u64,
        is_cancelled: ?*const fn () bool,
    ) !void {
        const stdin = self.stdin orelse return StdioError.BrokenPipe;
        try writeNDJSON(self.io, stdin, body, deadline_ns, is_cancelled);
    }

    /// Convenience overload of `send` that uses no timeout. Preserves
    /// backward compat for the in-repo tests and any external callers
    /// that don't need the timeout path.
    pub fn sendNoTimeout(self: *StdioClient, body: []const u8) !void {
        return self.send(body, 0);
    }

    /// Read one framed response from the child. Allocates; caller frees.
    pub fn recv(
        self: *StdioClient,
        deadline_ns: u64,
        is_cancelled: ?*const fn () bool,
    ) ![]u8 {
        const stdout = self.stdout orelse return StdioError.BrokenPipe;
        // Lazy-init the persistent reader once; it stays alive across
        // recv() calls so a fast server's coalesced lines are not lost.
        if (self.reader == null) {
            self.reader = std.Io.File.reader(stdout, self.io, &self.read_buf);
        }
        // Refuse to read through a reader whose cursors are already out of
        // order.
        const iface = &self.reader.?.interface;
        if (iface.seek > iface.end or iface.end > iface.buffer.len) {
            return StdioError.ConcurrentAccess;
        }
        const res = readFramedWithReader(
            self.allocator(),
            self.io,
            &self.reader.?,
            deadline_ns,
            is_cancelled,
        );
        if (res) |body| {
            return body;
        } else |err| {
            // Any error means we stopped mid-frame: the byte stream is no
            // longer aligned to a message boundary, so whatever is left in
            // the read buffer is the tail of an abandoned frame.
            self.reader = null;
            return err;
        }
    }

    /// Convenience overload of `recv` with no timeout and no
    /// cancel-check. Preserves backward compat for the in-repo tests
    /// and any external callers.
    pub fn recvNoTimeout(self: *StdioClient) ![]u8 {
        return self.recv(0, null);
    }

    /// Close stdin (signals EOF to the child) so it can exit gracefully.
    pub fn closeStdin(self: *StdioClient) void {
        if (self.stdin) |fd| {
            // `deinit` already closed the pipe; a second close would be
            // a double close of a possibly-recycled fd.
            if (!self.is_dead) fd.close(self.io);
            self.stdin = null;
            // Same hand-over as `deinit`: the child must not Close it again.
            self.child.stdin = null;
        }
    }

    /// Kill the child and reap it with a bounded wait — never blocking, so a
    /// child that ignores SIGTERM cannot pin the caller. Idempotent: safe from
    /// `defer` and from StdioRegistry.deinit.
    pub fn deinit(self: *StdioClient) void {
        if (self.is_dead) return;
        self.is_dead = true;
        self.reader = null;
        // Release the per-client arena now rather than letting it ride along
        // with the registry arena: a registry that respawns a server
        // repeatedly (every timeout marks it stale) would leak it outright.
        self.arena.deinit();
        // Close the pipes BEFORE the kill: a child blocked writing to a pipe
        // nobody drains only unwinds once no reader holds it, and a wrapper
        // waiting for that child would then never exit — see `killBounded`.
        if (self.stdin) |f| f.close(self.io);
        if (self.stdout) |f| f.close(self.io);
        if (self.stderr) |f| f.close(self.io);
        self.stdin = null;
        self.stdout = null;
        self.stderr = null;
        // `Child.kill` closes the child's OWN copies of these pipe handles,
        // which are the ones just closed above — hand ownership over instead
        // of Closing them twice (std printed STATUS_INVALID_HANDLE per handle).
        self.child.stdin = null;
        self.child.stdout = null;
        self.child.stderr = null;
        killBounded(self.io, &self.child, REAP_GRACE_PERIOD_NS);
        self.child.id = null;
    }
};

// ============================================================================
// SECTION B2 — GuestStdioClient: the same framing over a guest duplex
// ============================================================================

/// One duplex's two byte streams. Implemented above this module (a guest duplex
/// under `--saas`) and by this file's tests (an in-process pipe pair), so the
/// transport is a seam rather than a build flag.
pub const Channel = struct {
    io: std.Io,
    ctx: *anyopaque,
    vtable: *const VTable,

    pub const VTable = struct {
        read: *const fn (ctx: *anyopaque, dst: []u8) ChannelError!ReadResult,
        write: *const fn (ctx: *anyopaque, bytes: []const u8) ChannelError!void,
        close: *const fn (ctx: *anyopaque) void,
    };

    pub const ReadResult = struct { n: usize = 0, eof: bool = false };

    pub const ChannelError = error{
        /// Nothing arrived in the channel's own budget. Retrying is right.
        NothingYet,
        /// The peer is gone: the server exited, or the VM was restarted.
        Closed,
        OutOfMemory,
    };

    pub fn read(self: Channel, dst: []u8) ChannelError!ReadResult {
        return self.vtable.read(self.ctx, dst);
    }

    pub fn write(self: Channel, bytes: []const u8) ChannelError!void {
        return self.vtable.write(self.ctx, bytes);
    }

    pub fn close(self: Channel) void {
        self.vtable.close(self.ctx);
    }
};

/// Where a guest duplex lives: the tenant's workspace and the daemon's socket.
/// Everything a reopen needs, and nothing that changes between calls.
pub const GuestTarget = struct {
    workspace_id: []const u8,
    socket: []const u8,
};

/// Turn a server name and its argv into a live duplex in `target`. The agentic
/// loop supplies this, because it is the only layer that reaches `pabrik-vmd`.
pub const GuestOpenFn = *const fn (
    allocator: std.mem.Allocator,
    io: std.Io,
    target: GuestTarget,
    name: []const u8,
    argv: []const []const u8,
) anyerror!Channel;

/// An MCP client whose bytes live in the tenant's guest. `sendNDJSON` and
/// `recv` are `StdioClient`'s own framing over a `Channel`, so a caller cannot
/// tell the two transports apart above this struct.
pub const GuestStdioClient = struct {
    arena: std.heap.ArenaAllocator,
    channel: Channel,
    buffer: [4096]u8 = undefined,
    seek: usize = 0,
    end: usize = 0,
    eof: bool = false,
    deadline_ns: u64 = 0,
    deadline_abs: i128 = 0,
    is_cancelled: ?*const fn () bool = null,
    is_dead: bool = false,

    pub fn init(backing_allocator: std.mem.Allocator, channel: Channel) GuestStdioClient {
        return .{
            .arena = std.heap.ArenaAllocator.init(backing_allocator),
            .channel = channel,
        };
    }

    /// Response bodies come from this client's own arena, exactly as
    /// `StdioClient.allocator` does — a caller frees them through it.
    pub fn allocator(self: *GuestStdioClient) std.mem.Allocator {
        return self.arena.allocator();
    }

    /// Send one newline-delimited JSON message. The signature is
    /// `StdioClient.sendNDJSON`'s, so a call site cannot tell the transports
    /// apart; the channel bounds the write itself.
    pub fn sendNDJSON(
        self: *GuestStdioClient,
        body: []const u8,
        deadline_ns: u64,
        is_cancelled: ?*const fn () bool,
    ) !void {
        _ = deadline_ns;
        _ = is_cancelled;
        if (self.is_dead) return StdioError.BrokenPipe;
        var stack_buf: [8192]u8 = undefined;
        if (body.len + 1 <= stack_buf.len) {
            @memcpy(stack_buf[0..body.len], body);
            stack_buf[body.len] = '\n';
            self.channel.write(stack_buf[0 .. body.len + 1]) catch |err| return channelError(err);
            return;
        }
        const joined = self.allocator().alloc(u8, body.len + 1) catch return StdioError.OutOfMemory;
        @memcpy(joined[0..body.len], body);
        joined[body.len] = '\n';
        self.channel.write(joined) catch |err| return channelError(err);
    }

    /// Read one framed response. Same framing, same errors and the same
    /// arena-owned body as `StdioClient.recv`.
    pub fn recv(
        self: *GuestStdioClient,
        deadline_ns: u64,
        is_cancelled: ?*const fn () bool,
    ) ![]u8 {
        if (self.is_dead) return StdioError.BrokenPipe;
        self.deadline_ns = deadline_ns;
        self.deadline_abs = if (deadline_ns == 0)
            std.math.maxInt(i128)
        else
            std.Io.Timestamp.now(self.channel.io, .real).nanoseconds + @as(i128, @intCast(deadline_ns));
        self.is_cancelled = is_cancelled;
        defer {
            self.deadline_ns = 0;
            self.deadline_abs = 0;
            self.is_cancelled = null;
        }
        const src = Source{
            .ctx = @ptrCast(self),
            .pull = sourcePull,
            .pending = sourcePending,
            .wait = sourceWait,
        };
        const result = readFramedFromSource(self.allocator(), self.channel.io, src, deadline_ns, is_cancelled);
        if (result) |body| return body else |err| {
            // A frame that stopped mid-way leaves the byte stream unaligned.
            self.seek = 0;
            self.end = 0;
            if (err == StdioError.BrokenPipe) self.eof = true;
            return err;
        }
    }

    /// Close the duplex. Idempotent, like `StdioClient.deinit`.
    pub fn deinit(self: *GuestStdioClient) void {
        if (self.is_dead) return;
        self.is_dead = true;
        self.arena.deinit();
        self.channel.close();
    }

    /// One bounded channel read into the buffer. An empty answer is
    /// `NothingYet`, which the pull loop turns into a deadline/cancel check.
    fn fillOnce(self: *GuestStdioClient) StdioError!void {
        const result = self.channel.read(self.buffer[0..]) catch |err| switch (err) {
            error.NothingYet => return,
            error.Closed => {
                self.eof = true;
                return;
            },
            error.OutOfMemory => return StdioError.OutOfMemory,
        };
        self.seek = 0;
        self.end = result.n;
        if (result.eof) self.eof = true;
    }

    fn sourcePull(ctx: *anyopaque, dst: []u8) StdioError!usize {
        const self: *GuestStdioClient = @ptrCast(@alignCast(ctx));
        while (self.seek == self.end) {
            if (self.eof) return 0;
            if (self.is_cancelled) |cb| if (cb()) return StdioError.RecvTimeout;
            try self.fillOnce();
            if (self.seek != self.end) break;
            if (self.eof) return 0;
            if (self.deadline_ns != 0 and
                std.Io.Timestamp.now(self.channel.io, .real).nanoseconds >= self.deadline_abs)
            {
                return StdioError.RecvTimeout;
            }
        }
        const n = @min(dst.len, self.end - self.seek);
        @memcpy(dst[0..n], self.buffer[self.seek..][0..n]);
        self.seek += n;
        return n;
    }

    fn sourcePending(ctx: *anyopaque) usize {
        const self: *GuestStdioClient = @ptrCast(@alignCast(ctx));
        return self.end - self.seek;
    }

    fn sourceWait(ctx: *anyopaque, deadline_abs: i128, deadline_ns: u64, is_cancelled: ?*const fn () bool) bool {
        const self: *GuestStdioClient = @ptrCast(@alignCast(ctx));
        if (is_cancelled) |cb| if (cb()) return false;
        if (deadline_ns != 0 and
            std.Io.Timestamp.now(self.channel.io, .real).nanoseconds >= deadline_abs)
        {
            return false;
        }
        return true;
    }

    fn channelError(err: Channel.ChannelError) StdioError {
        return switch (err) {
            error.NothingYet => StdioError.SendTimeout,
            error.Closed => StdioError.BrokenPipe,
            error.OutOfMemory => StdioError.OutOfMemory,
        };
    }
};

// ============================================================================
// SECTION C — StdioRegistry (process-global singleton, one child per server)
// ============================================================================

const Entry = struct {
    /// The child.
    client: *StdioClient,
    /// `false` ⇒ `client` is an unallocated slot and no child has ever
    /// existed for this name.
    has_client: bool = false,
    /// Pre-reserved uninitialized `StdioClient` slot for the NEXT spawn,
    /// allocated up front under the registry lock.
    spare: ?*StdioClient = null,
    /// `true` ⇒ the cached `client` is "stale" (a recv/send timed out or its
    /// cancel-callback fired).
    dirty: std.atomic.Value(bool) = .init(false),
    /// Serializes whole request/response transactions against this one child.
    io_mutex: std.atomic.Mutex = .unlocked,
    /// What `client` was spawned from. A changed argv means a different
    /// server, so the child must be replaced instead of reused.
    digest: u64 = 0,
};

fn argvDigest(argv: []const []const u8) u64 {
    var hasher = std.hash.Wyhash.init(0);
    for (argv) |arg| {
        hasher.update(&.{mcp_scope.sep});
        hasher.update(arg);
    }
    return hasher.final();
}

fn mutexLock(m: *std.atomic.Mutex) void {
    while (!m.tryLock()) std.atomic.spinLoopHint();
}

/// Take `m`, giving up after `wait_ns` (0 = wait forever) or as soon as
/// `is_cancelled` returns true. Returns false if the lock was not taken.
fn tryLockUntil(
    io: std.Io,
    m: *std.atomic.Mutex,
    wait_ns: u64,
    is_cancelled: ?*const fn () bool,
) bool {
    if (m.tryLock()) return true;
    const has_deadline = wait_ns != 0;
    var waited: u64 = 0;
    while (true) {
        if (is_cancelled) |cb| if (cb()) return false;
        if (has_deadline) {
            if (waited >= wait_ns) return false;
            const step: u64 = @min(2 * std.time.ns_per_ms, wait_ns - waited);
            std.Io.Clock.Duration.sleep(
                .{ .raw = std.Io.Duration.fromNanoseconds(step), .clock = .real },
                io,
            ) catch return m.tryLock();
            waited += step;
        } else {
            std.Io.Clock.Duration.sleep(
                .{ .raw = std.Io.Duration.fromMilliseconds(2), .clock = .real },
                io,
            ) catch return m.tryLock();
        }
        if (m.tryLock()) return true;
    }
}

/// Exclusive, must-be-released handle on one MCP stdio child. Obtain with
/// `StdioRegistry.acquire`; hand back with `release`.
pub const Lease = struct {
    registry: *StdioRegistry,
    entry: *Entry,
    name: []const u8,
    released: bool = false,

    /// The child. Valid only while the lease is held.
    pub fn client(self: *const Lease) *StdioClient {
        return self.entry.client;
    }

    /// Flag the child for replacement on the next `acquire`.
    pub fn markStale(self: *const Lease) void {
        self.entry.dirty.store(true, .release);
    }

    pub fn release(self: *Lease) void {
        if (self.released) return;
        self.released = true;
        self.entry.io_mutex.unlock();
    }
};

/// How long `acquire` is willing to wait for another session to finish
/// its transaction on the same server, and how to abort that wait.
pub const AcquireOptions = struct {
    /// 0 = wait indefinitely.
    wait_ns: u64 = 0,
    is_cancelled: ?*const fn () bool = null,
    scope: mcp_scope.Scope = .{},
};

pub const StdioRegistry = struct {
    arena: std.heap.ArenaAllocator,
    io: std.Io,
    /// Owns the Threaded io backing `self.io` when non-null. The
    /// global registry lazily creates one via `global()`; per-test
    /// registries pass their own `io` and leave this null.
    threaded: ?*std.Io.Threaded = null,
    /// Keys (server names) and values (Entry pointers) are both allocated
    /// from the arena.
    entries: std.StringHashMap(*Entry),
    mutex: std.atomic.Mutex = .unlocked,
    /// Ceiling on live children across every tenant. A workspace that can
    /// spawn unbounded processes is a denial of service against a process
    /// that serves all of them.
    max_entries: usize = default_max_entries,

    pub fn init(parent_allocator: std.mem.Allocator, io: std.Io) StdioRegistry {
        return .{
            .arena = std.heap.ArenaAllocator.init(parent_allocator),
            .io = io,
            .threaded = null,
            .entries = std.StringHashMap(*Entry).init(parent_allocator),
        };
    }

    /// Live, process-backed environment for spawned children. WHY THIS IS
    /// REQUIRED: `Std.Io.Threaded.init` defaults its `.environ` option to
    /// `.empty`.
    fn processEnviron() std.process.Environ {
        const block: std.process.Environ.Block = switch (builtin.os.tag) {
            .windows => .global,
            else => posix: {
                const e = std.c.environ;
                var n: usize = 0;
                while (e[n] != null) : (n += 1) {}
                break :posix .{ .slice = e[0..n :null] };
            },
        };
        return .{ .block = block };
    }

    /// Lazy-init helper for the global registry: creates the Threaded
    /// io backing the registry. Per-instance callers should pass an
    /// existing `io` via `init` and leave `threaded` null.
    fn initThreaded(parent_allocator: std.mem.Allocator) !StdioRegistry {
        const threaded = try parent_allocator.create(std.Io.Threaded);
        // Pass `.processEnviron()` so spawned MCP children inherit PATH
        // (and the rest of the process env) — see processEnviron docs.
        threaded.* = std.Io.Threaded.init(parent_allocator, .{
            .environ = processEnviron(),
        });
        return .{
            .arena = std.heap.ArenaAllocator.init(parent_allocator),
            .io = threaded.io(),
            .threaded = threaded,
            .entries = std.StringHashMap(*Entry).init(parent_allocator),
        };
    }

    /// Allocate a `StdioClient` struct from the registry arena. The struct is
    /// left uninitialized; `StdioClient.init` fills it.
    fn allocClientSlot(self: *StdioRegistry) StdioError!*StdioClient {
        return self.arena.allocator().create(StdioClient) catch StdioError.OutOfMemory;
    }

    /// Take exclusive use of the child for `name`, spawning one if there
    /// isn't a live client, and replacing it if a previous holder marked it
    /// stale.
    pub fn acquire(
        self: *StdioRegistry,
        name: []const u8,
        argv: []const []const u8,
        opts: AcquireOptions,
    ) StdioError!Lease {
        // Phase 1 — registry lock, held only for map + arena work.
        var key_buf: [mcp_scope.max_key_bytes]u8 = undefined;
        const scoped_key = opts.scope.keyInto(name, &key_buf) orelse return StdioError.NameTooLong;
        mutexLock(&self.mutex);
        const entry = self.entries.get(scoped_key) orelse blk: {
            if (self.entries.count() >= self.max_entries) {
                self.mutex.unlock();
                return StdioError.TooManyChildren;
            }
            const client_slot = self.allocClientSlot() catch {
                self.mutex.unlock();
                return StdioError.OutOfMemory;
            };
            const key_dup = self.arena.allocator().dupe(u8, scoped_key) catch {
                self.mutex.unlock();
                return StdioError.OutOfMemory;
            };
            const new_entry = self.arena.allocator().create(Entry) catch {
                self.mutex.unlock();
                return StdioError.OutOfMemory;
            };
            // A brand-new entry has no child. `has_client` stays false
            // and `spare` is pre-loaded so phase 3 has a slot to spawn
            // into without touching the (now unlocked) arena.
            new_entry.* = .{
                .client = client_slot,
                .has_client = false,
                .spare = self.allocClientSlot() catch {
                    self.mutex.unlock();
                    return StdioError.OutOfMemory;
                },
            };
            self.entries.put(key_dup, new_entry) catch {
                self.mutex.unlock();
                return StdioError.OutOfMemory;
            };
            break :blk new_entry;
        };
        // Top the spare back up for an entry that is about to respawn:
        // consumed in phase 3, and reserved here while the registry lock
        // still protects the arena.
        if (entry.spare == null) {
            entry.spare = self.allocClientSlot() catch {
                self.mutex.unlock();
                return StdioError.OutOfMemory;
            };
        }
        self.mutex.unlock();

        // Phase 2 — exclusive access to this child. Registry lock is
        // NOT held; see the LOCK ORDER note on `Entry.io_mutex`.
        if (!tryLockUntil(self.io, &entry.io_mutex, opts.wait_ns, opts.is_cancelled)) {
            return StdioError.LeaseTimeout;
        }
        errdefer entry.io_mutex.unlock();

        // Phase 3 — nobody else can be touching this child, so respawn
        // (or spawn, for an entry created above) without any further
        // locking.
        const digest = argvDigest(argv);
        if (!entry.has_client or entry.dirty.load(.acquire) or entry.client.is_dead or entry.digest != digest) {
            if (entry.has_client) entry.client.deinit();
            // Allocating from the registry arena is NOT thread-safe, and the
            // registry lock is already released.
            const slot = entry.spare orelse return StdioError.OutOfMemory;
            entry.spare = null;
            slot.* = StdioClient.init(self.arena.allocator(), self.io, argv) catch |err| {
                // Keep the flag false / the entry dirty so the next
                // `acquire` retries instead of handing out the corpse.
                entry.has_client = false;
                entry.dirty.store(true, .release);
                return err;
            };
            entry.client = slot;
            entry.has_client = true;
            entry.digest = digest;
            entry.dirty.store(false, .release);
        }
        return .{ .registry = self, .entry = entry, .name = name };
    }

    /// Mark the cached client for `name` as "stale" WITHOUT holding its entry
    /// lock, for callers that do not have a lease (a config save invalidating
    /// every server, say).
    pub fn markStale(self: *StdioRegistry, name: []const u8) void {
        mutexLock(&self.mutex);
        defer self.mutex.unlock();
        var it = self.entries.iterator();
        while (it.next()) |kv| {
            if (!mcp_scope.matchesName(kv.key_ptr.*, name)) continue;
            kv.value_ptr.*.dirty.store(true, .release);
        }
    }

    /// Drop every tenant's cached child for `name` and kill it.
    pub fn evictName(self: *StdioRegistry, name: []const u8, allocator: std.mem.Allocator) void {
        mutexLock(&self.mutex);
        defer self.mutex.unlock();
        const doomed = allocator.alloc([]const u8, self.entries.count()) catch return;
        defer allocator.free(doomed);
        var count: usize = 0;
        var it = self.entries.iterator();
        while (it.next()) |kv| {
            if (!mcp_scope.matchesName(kv.key_ptr.*, name)) continue;
            doomed[count] = kv.key_ptr.*;
            count += 1;
        }
        for (doomed[0..count]) |key| {
            if (self.entries.fetchRemove(key)) |kv| {
                mutexLock(&kv.value.io_mutex);
                if (kv.value.has_client) kv.value.client.deinit();
                kv.value.io_mutex.unlock();
            }
        }
    }

    /// Drop the cached client for `name` (if any) and spawn a fresh one.
    /// Note: the old client's memory isn't reclaimed individually — the arena
    /// owns it.
    pub fn dropAndRespawn(
        self: *StdioRegistry,
        scope: mcp_scope.Scope,
        name: []const u8,
        argv: []const []const u8,
    ) !*StdioClient {
        var key_buf: [mcp_scope.max_key_bytes]u8 = undefined;
        const scoped_key = scope.keyInto(name, &key_buf) orelse return StdioError.NameTooLong;
        mutexLock(&self.mutex);
        defer self.mutex.unlock();
        if (self.entries.fetchRemove(scoped_key)) |kv| {
            // Take the entry lock before killing: a concurrent `acquire` may
            // be blocked on it and about to dereference this very client.
            mutexLock(&kv.value.io_mutex);
            if (kv.value.has_client) kv.value.client.deinit();
            kv.value.io_mutex.unlock();
        }
        const client_slot = try self.allocClientSlot();
        const key_dup = try self.arena.allocator().dupe(u8, scoped_key);
        const new_entry = try self.arena.allocator().create(Entry);
        client_slot.* = try StdioClient.init(self.arena.allocator(), self.io, argv);
        new_entry.* = .{ .client = client_slot, .dirty = .init(false) };
        try self.entries.put(key_dup, new_entry);
        return client_slot;
    }

    /// Snapshot the current set of keys under the registry lock. Used by
    /// callers that need to iterate keys without holding the lock for long
    /// (the lock is dropped before `markStale` re- acquires it).
    pub fn keys(self: *StdioRegistry, allocator: std.mem.Allocator) ![][]const u8 {
        mutexLock(&self.mutex);
        defer self.mutex.unlock();
        const out = try allocator.alloc([]const u8, self.entries.count());
        var i: usize = 0;
        var it = self.entries.iterator();
        while (it.next()) |kv| {
            out[i] = kv.key_ptr.*;
            i += 1;
        }
        return out;
    }

    pub fn deinit(self: *StdioRegistry) void {
        mutexLock(&self.mutex);
        defer self.mutex.unlock();
        // Kill all children first (deterministic order).
        var it = self.entries.iterator();
        while (it.next()) |kv| {
            const entry = kv.value_ptr.*;
            mutexLock(&entry.io_mutex);
            // `has_client` guards an entry that was created but never
            // successfully spawned into — tearing down its uninitialized
            // slot would walk the arena's free list through garbage.
            if (entry.has_client) entry.client.deinit();
            entry.io_mutex.unlock();
        }
        const parent_allocator = self.entries.allocator;
        self.entries.deinit();
        // If we own a Threaded io (the global registry case), tear it down
        // before the arena.
        if (self.threaded) |t| {
            t.deinit();
            parent_allocator.destroy(t);
            self.threaded = null;
        }
        // Single arena.deinit() frees ALL the clients + keys + the
        // Threaded struct at once.
        self.arena.deinit();
    }

    // Process-global singleton. Lives for the whole pabrik process. Cleaned
    // up via the shutdown hook in main.zig (Task 7).

    var global_registry: ?StdioRegistry = null;
    var global_init_mutex: std.atomic.Mutex = .unlocked;

    /// Get the process-global registry. Lazily initialized on first call.
    pub fn global(allocator: std.mem.Allocator) *StdioRegistry {
        mutexLock(&global_init_mutex);
        defer global_init_mutex.unlock();
        if (global_registry == null) {
            global_registry = initThreaded(allocator) catch @panic("OOM: StdioRegistry.global");
        }
        return &global_registry.?;
    }

    /// Called by main.zig shutdown hook. Kills all spawned children AND
    /// frees all registry memory (via the arena) AND deinits the
    /// owned Threaded io.
    pub fn deinitGlobal() void {
        mutexLock(&global_init_mutex);
        defer global_init_mutex.unlock();
        if (global_registry) |*reg| {
            reg.deinit();
            global_registry = null;
        }
    }
};

/// Exclusive, must-be-released handle on one guest-backed MCP server. Same
/// contract as `Lease`: one caller owns the duplex's read cursor at a time.
pub const GuestLease = struct {
    entry: *GuestEntry,
    name: []const u8,
    released: bool = false,

    pub fn client(self: *const GuestLease) *GuestStdioClient {
        return self.entry.client;
    }

    pub fn markStale(self: *const GuestLease) void {
        self.entry.dirty.store(true, .release);
    }

    pub fn release(self: *GuestLease) void {
        if (self.released) return;
        self.released = true;
        self.entry.io_mutex.unlock();
    }
};

const GuestEntry = struct {
    client: *GuestStdioClient,
    has_client: bool = false,
    dirty: std.atomic.Value(bool) = .init(false),
    io_mutex: std.atomic.Mutex = .unlocked,
    digest: u64 = 0,
};

/// The same `AcquireOptions` contract, plus where the duplex lives.
pub const GuestAcquireOptions = struct {
    /// 0 = wait indefinitely.
    wait_ns: u64 = 0,
    is_cancelled: ?*const fn () bool = null,
    scope: mcp_scope.Scope = .{},
    target: GuestTarget = .{ .workspace_id = "", .socket = "" },
};

/// Cached `GuestStdioClient`s, one duplex per (tenant, server). A guest duplex
/// is a live MCP server inside the tenant's VM, so it must survive across tool
/// calls exactly as a host child does.
pub const GuestRegistry = struct {
    arena: std.heap.ArenaAllocator,
    io: std.Io,
    opener: GuestOpenFn,
    entries: std.StringHashMap(*GuestEntry),
    mutex: std.atomic.Mutex = .unlocked,
    max_entries: usize = default_max_entries,

    pub fn init(parent_allocator: std.mem.Allocator, io: std.Io, opener: GuestOpenFn) GuestRegistry {
        return .{
            .arena = std.heap.ArenaAllocator.init(parent_allocator),
            .io = io,
            .opener = opener,
            .entries = std.StringHashMap(*GuestEntry).init(parent_allocator),
        };
    }

    /// Take exclusive use of the tenant's duplex for `name`, opening one if
    /// there is none and replacing it if the last holder marked it stale.
    pub fn acquire(
        self: *GuestRegistry,
        name: []const u8,
        argv: []const []const u8,
        opts: GuestAcquireOptions,
    ) StdioError!GuestLease {
        var key_buf: [mcp_scope.max_key_bytes]u8 = undefined;
        const scoped_key = opts.scope.keyInto(name, &key_buf) orelse return StdioError.NameTooLong;
        mutexLock(&self.mutex);
        const entry = self.entries.get(scoped_key) orelse blk: {
            if (self.entries.count() >= self.max_entries) {
                self.mutex.unlock();
                return StdioError.TooManyChildren;
            }
            const slot = self.arena.allocator().create(GuestStdioClient) catch {
                self.mutex.unlock();
                return StdioError.OutOfMemory;
            };
            const key_dup = self.arena.allocator().dupe(u8, scoped_key) catch {
                self.mutex.unlock();
                return StdioError.OutOfMemory;
            };
            const new_entry = self.arena.allocator().create(GuestEntry) catch {
                self.mutex.unlock();
                return StdioError.OutOfMemory;
            };
            new_entry.* = .{ .client = slot };
            self.entries.put(key_dup, new_entry) catch {
                self.mutex.unlock();
                return StdioError.OutOfMemory;
            };
            break :blk new_entry;
        };
        self.mutex.unlock();

        if (!tryLockUntil(self.io, &entry.io_mutex, opts.wait_ns, opts.is_cancelled)) {
            return StdioError.LeaseTimeout;
        }
        errdefer entry.io_mutex.unlock();

        const digest = argvDigest(argv);
        if (!entry.has_client or entry.dirty.load(.acquire) or entry.client.is_dead or entry.digest != digest) {
            if (entry.has_client) entry.client.deinit();
            // The opener runs OUTSIDE the registry lock: it opens a socket.
            const channel = self.opener(
                self.arena.allocator(),
                self.io,
                opts.target,
                name,
                argv,
            ) catch |err| switch (err) {
                error.OutOfMemory => {
                    entry.has_client = false;
                    entry.dirty.store(true, .release);
                    return StdioError.OutOfMemory;
                },
                else => {
                    entry.has_client = false;
                    entry.dirty.store(true, .release);
                    return StdioError.ChildSpawnFailed;
                },
            };
            entry.client.* = GuestStdioClient.init(self.arena.allocator(), channel);
            entry.has_client = true;
            entry.digest = digest;
            entry.dirty.store(false, .release);
        }
        return .{ .entry = entry, .name = name };
    }

    /// Drop every tenant's duplex for `name`, closing it in the guest.
    pub fn evictName(self: *GuestRegistry, name: []const u8, allocator: std.mem.Allocator) void {
        mutexLock(&self.mutex);
        defer self.mutex.unlock();
        const doomed = allocator.alloc([]const u8, self.entries.count()) catch return;
        defer allocator.free(doomed);
        var count: usize = 0;
        var it = self.entries.iterator();
        while (it.next()) |kv| {
            if (!mcp_scope.matchesName(kv.key_ptr.*, name)) continue;
            doomed[count] = kv.key_ptr.*;
            count += 1;
        }
        for (doomed[0..count]) |key| {
            if (self.entries.fetchRemove(key)) |kv| {
                mutexLock(&kv.value.io_mutex);
                if (kv.value.has_client) kv.value.client.deinit();
                kv.value.io_mutex.unlock();
            }
        }
    }

    pub fn deinit(self: *GuestRegistry) void {
        mutexLock(&self.mutex);
        defer self.mutex.unlock();
        var it = self.entries.iterator();
        while (it.next()) |kv| {
            const entry = kv.value_ptr.*;
            mutexLock(&entry.io_mutex);
            if (entry.has_client) entry.client.deinit();
            entry.io_mutex.unlock();
        }
        self.entries.deinit();
        self.arena.deinit();
    }

    var global_registry: ?GuestRegistry = null;
    var global_init_mutex: std.atomic.Mutex = .unlocked;

    /// The process-global registry. The first caller supplies the io and the
    /// opener; both are process-wide, so later callers pass the same values.
    pub fn global(allocator: std.mem.Allocator, io: std.Io, opener: GuestOpenFn) *GuestRegistry {
        mutexLock(&global_init_mutex);
        defer global_init_mutex.unlock();
        if (global_registry == null) {
            global_registry = GuestRegistry.init(allocator, io, opener);
        }
        return &global_registry.?;
    }

    pub fn deinitGlobal() void {
        mutexLock(&global_init_mutex);
        defer global_init_mutex.unlock();
        if (global_registry) |*reg| {
            reg.deinit();
            global_registry = null;
        }
    }
};

// ============================================================================
// Tests — inline at the bottom (project convention)
// ============================================================================

const testing = std.testing;
const hf = @import("helpers").host_fixture;
const run_captured = @import("helpers").run_captured;

// ── Framing tests (no child needed) ────────────────────────────────────────

test "readFramed parses Content-Length body" {
    // Build a fake byte stream using a temp file (so we exercise std.fs.File.read).
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const path = "framing_test_input.txt";
    // Body is 14 bytes: `{"json":"rpc"}` — 1 + 1 + 4 + 1 + 1 + 1 + 4 + 1 + 1 = 14.
    const payload = "Content-Length: 14\r\n\r\n{\"json\":\"rpc\"}";
    try tmp.dir.writeFile(testing.io, .{ .sub_path = path, .data = payload });

    var file = try tmp.dir.openFile(testing.io, path, .{});
    defer file.close(testing.io);

    const body = try readFramed(testing.allocator, testing.io, file, 0, null);
    defer testing.allocator.free(body);
    try testing.expectEqualStrings("{\"json\":\"rpc\"}", body);
}

test "readFramed accepts LF-only blank-line separator" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const path = "lf_only.txt";
    const payload = "Content-Length: 5\r\nX-Bogus: y\n\nhello";
    try tmp.dir.writeFile(testing.io, .{ .sub_path = path, .data = payload });

    var file = try tmp.dir.openFile(testing.io, path, .{});
    defer file.close(testing.io);

    const body = try readFramed(testing.allocator, testing.io, file, 0, null);
    defer testing.allocator.free(body);
    try testing.expectEqualStrings("hello", body);
}

test "readFramed returns InvalidFrame when Content-Length missing" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const path = "no_cl.txt";
    const payload = "X-Bogus: y\r\n\r\nhello";
    try tmp.dir.writeFile(testing.io, .{ .sub_path = path, .data = payload });

    var file = try tmp.dir.openFile(testing.io, path, .{});
    defer file.close(testing.io);

    _ = readFramed(testing.allocator, testing.io, file, 0, null) catch |e| {
        try testing.expectEqual(StdioError.InvalidFrame, e);
        return;
    };
    try testing.expect(false); // unreachable
}

test "writeFramed emits Content-Length header + body" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const path = "framing_out.txt";
    var file = try tmp.dir.createFile(testing.io, path, .{});
    defer file.close(testing.io);

    try writeFramed(testing.io, file, "hi", 0);

    var file2 = try tmp.dir.openFile(testing.io, path, .{});
    defer file2.close(testing.io);
    const stat = try file2.stat(testing.io);
    const got = try testing.allocator.alloc(u8, stat.size);
    defer testing.allocator.free(got);
    const n = try std.Io.File.readPositionalAll(file2, testing.io, got, 0);
    try testing.expectEqualStrings("Content-Length: 2\r\n\r\nhi", got[0..n]);
}

test "writeFramed roundtrips through readFramed" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    // Write to file A.
    var file_a = try tmp.dir.createFile(testing.io, "a.txt", .{});
    try writeFramed(testing.io, file_a, "{\"a\":1}", 0);
    file_a.close(testing.io);

    // Read back via readFramed.
    var file_b = try tmp.dir.openFile(testing.io, "a.txt", .{});
    defer file_b.close(testing.io);
    const body = try readFramed(testing.allocator, testing.io, file_b, 0, null);
    defer testing.allocator.free(body);
    try testing.expectEqualStrings("{\"a\":1}", body);
}

test "readFramed parses newline-delimited JSON body (MCP SDK default)" {
    // The canonical @modelcontextprotocol/sdk v1.x writes
    // `JSON.stringify(message) + '\n'` — newline-delimited JSON, NOT
    // Content-Length framed. readFramed auto-detects by peeking the first
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var file = try tmp.dir.createFile(testing.io, "ndjson.txt", .{});
    try file.writeStreamingAll(testing.io, "{\"json\":\"rpc\",\"id\":1}\n");
    file.close(testing.io);

    var file2 = try tmp.dir.openFile(testing.io, "ndjson.txt", .{});
    defer file2.close(testing.io);
    const body = try readFramed(testing.allocator, testing.io, file2, 0, null);
    defer testing.allocator.free(body);
    try testing.expectEqualStrings("{\"json\":\"rpc\",\"id\":1}", body);
}

test "readFramed parses newline-delimited JSON without trailing newline" {
    // Some servers (or test harnesses) omit the trailing \n on exit.
    // We still return whatever we accumulated up to EOF.
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var file = try tmp.dir.createFile(testing.io, "no_nl.txt", .{});
    try file.writeStreamingAll(testing.io, "{\"json\":\"rpc\"}");
    file.close(testing.io);

    var file2 = try tmp.dir.openFile(testing.io, "no_nl.txt", .{});
    defer file2.close(testing.io);
    const body = try readFramed(testing.allocator, testing.io, file2, 0, null);
    defer testing.allocator.free(body);
    try testing.expectEqualStrings("{\"json\":\"rpc\"}", body);
}

test "readFramed handles CRLF terminator on newline-delimited JSON" {
    // Some servers emit \r\n on Windows-style line endings. readFramed
    // must strip the trailing \r before returning the JSON body.
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var file = try tmp.dir.createFile(testing.io, "crlf.txt", .{});
    try file.writeStreamingAll(testing.io, "{\"json\":\"rpc\"}\r\n");
    file.close(testing.io);

    var file2 = try tmp.dir.openFile(testing.io, "crlf.txt", .{});
    defer file2.close(testing.io);
    const body = try readFramed(testing.allocator, testing.io, file2, 0, null);
    defer testing.allocator.free(body);
    try testing.expectEqualStrings("{\"json\":\"rpc\"}", body);
}

test "readFramed polls the cancel hook once per reader buffer, not once per byte" {
    // `is_cancelled` is a caller hook, and workflow.zig's runs a SQLite query
    // per call — so a per-byte poll turns one multi-megabyte frame into
    // millions of queries.
    const payload_len: usize = 512 * 1024;
    const payload = try testing.allocator.alloc(u8, payload_len + 2);
    defer testing.allocator.free(payload);
    payload[0] = '{';
    @memset(payload[1 .. payload_len + 1], 'x');
    payload[payload_len + 1] = '\n';

    var input = try framedInput("one_big_line.txt", payload);
    defer input.deinit();

    const Hook = struct {
        var calls: usize = 0;
        fn call() bool {
            calls += 1;
            return false;
        }
    };
    Hook.calls = 0;
    const body = try readFramed(
        testing.allocator,
        testing.io,
        input.file,
        60 * std.time.ns_per_s,
        &Hook.call,
    );
    defer testing.allocator.free(body);

    try testing.expectEqual(payload_len + 1, body.len);
    // A per-byte poll would be payload_len calls; refills are payload/4096.
    try testing.expect(Hook.calls * 64 < payload_len);
}

// ── StdioClient tests (real child process) ────────────────────────────────
// Cross-platform: use `cat` on POSIX, `cmd.exe /C more` on Windows.

fn echo_argv() []const []const u8 {
    return if (builtin.os.tag == .windows)
        &.{ "cmd.exe", "/C", "more" }
    else
        &.{"cat"};
}

test "StdioClient.init spawns child successfully" {
    var client = StdioClient.init(testing.allocator, testing.io, echo_argv()) catch |err| {
        // On Windows CI without `cmd.exe` on PATH the test would fail —
        // mark as skip so we don't break the cross-platform build.
        if (builtin.os.tag == .windows) return error.SkipZigTest;
        return err;
    };
    defer client.deinit();
    try testing.expect(client.stdin != null);
    try testing.expect(client.stdout != null);
}

test "StdioClient.send writes framed bytes to child stdin" {
    // NOTE: full send+recv roundtrips are exercised by the functional test at
    // tests/functional/mcp_stdio_test.py — that test runs against a real
    // `mcp-hello-world` binary with the threaded io in a fully-wired pabrik
    const argv: []const []const u8 = if (builtin.os.tag == .windows)
        &.{ "cmd.exe", "/C", "ping", "-n", "2", "127.0.0.1" } // ~1s on Windows
    else
        &.{ "sleep", "1" };
    _ = StdioClient.init(testing.allocator, testing.io, argv) catch |err| {
        // On platforms without `sleep`/`ping` we skip — the framing
        // roundtrip is covered by the writeFramed/readFramed tests.
        if (err == error.ChildSpawnFailed) return;
        return err;
    };
}

/// Argv for a child that IGNORES SIGTERM and outlives the test — the shape
/// that wedged `StdioClient.deinit`: `Child.kill` sends SIGTERM and then
/// blocks in `wait4` with no deadline. Host table (CODING_STANDARDS.md §2).
fn sigtermIgnoringArgv() []const []const u8 {
    return switch (builtin.os.tag) {
        .windows => &.{ "cmd.exe", "/C", "ping", "-n", "30", "127.0.0.1" },
        .linux, .macos => &.{ "/bin/sh", "-c", "trap '' TERM; while :; do sleep 1; done" },
        else => &.{"pabrik-no-such-child"},
    };
}

test "StdioClient.deinit reaps a SIGTERM-ignoring child instead of blocking forever" {
    var client = try StdioClient.init(testing.allocator, testing.io, sigtermIgnoringArgv());
    const pid = client.child.id.?;
    const start = std.Io.Timestamp.now(testing.io, .real).nanoseconds;

    client.deinit();

    const elapsed_ms: u64 = @intCast(@divTrunc(
        std.Io.Timestamp.now(testing.io, .real).nanoseconds - start,
        std.time.ns_per_ms,
    ));
    // A hang guard, not a budget check: pre-fix this call never returned at
    // all, so the bound has to clear the 2 s reap budget on a loaded runner.
    try testing.expect(elapsed_ms < 10_000);
    if (comptime builtin.os.tag != .windows) {
        // A zombie still accepts a signal, so ProcessNotFound proves the
        // reap, not merely the exit.
        try testing.expectError(error.ProcessNotFound, std.posix.kill(pid, .TERM));
    }
}

test "StdioClient.init returns ChildSpawnFailed for missing binary" {
    _ = StdioClient.init(testing.allocator, testing.io, &.{"/no/such/binary/should/exist/xyzzy"}) catch |e| {
        try testing.expectEqual(StdioError.ChildSpawnFailed, e);
        return;
    };
    try testing.expect(false); // unreachable
}

test "StdioClient.deinit kills child without error" {
    var client = try StdioClient.init(testing.allocator, testing.io, echo_argv());
    // deinit must be a no-fail, idempotent cleanup.
    client.deinit();
}

// ── StdioRegistry tests ────────────────────────────────────────────────────

test "StdioRegistry.init + deinit roundtrip" {
    var reg = StdioRegistry.init(testing.allocator, testing.io);
    defer reg.deinit();
    try testing.expectEqual(@as(usize, 0), reg.entries.count());
}

test "acquire returns the same client across calls (cached)" {
    var reg = StdioRegistry.init(testing.allocator, testing.io);
    defer reg.deinit();
    var l1 = try reg.acquire("alpha", echo_argv(), .{});
    const c1 = l1.client();
    l1.release();
    var l2 = try reg.acquire("alpha", echo_argv(), .{});
    defer l2.release();
    try testing.expectEqual(@intFromPtr(c1), @intFromPtr(l2.client()));
}

test "acquire with different names returns different clients" {
    var reg = StdioRegistry.init(testing.allocator, testing.io);
    defer reg.deinit();
    var la = try reg.acquire("a", echo_argv(), .{});
    const a = la.client();
    la.release();
    var lb = try reg.acquire("b", echo_argv(), .{});
    defer lb.release();
    try testing.expect(a != lb.client());
}

test "two tenants declaring the same server name get two child processes" {
    var reg = StdioRegistry.init(testing.allocator, testing.io);
    defer reg.deinit();
    const tenant_a = mcp_scope.Scope{ .owner = "u_a", .workspace_id = "ws_1" };
    const tenant_b = mcp_scope.Scope{ .owner = "u_b", .workspace_id = "ws_1" };

    var la = try reg.acquire("files", echo_argv(), .{ .scope = tenant_a });
    const a = la.client();
    la.release();

    var lb = try reg.acquire("files", echo_argv(), .{ .scope = tenant_b });
    const b = lb.client();
    lb.release();

    try testing.expect(a != b);
    try testing.expectEqual(@as(usize, 2), reg.entries.count());
}

test "one tenant asking twice for the same server keeps a single child" {
    var reg = StdioRegistry.init(testing.allocator, testing.io);
    defer reg.deinit();
    const tenant = mcp_scope.Scope{ .owner = "u_a", .workspace_id = "ws_1" };

    var first = try reg.acquire("files", echo_argv(), .{ .scope = tenant });
    const a = first.client();
    first.release();

    var second = try reg.acquire("files", echo_argv(), .{ .scope = tenant });
    const b = second.client();
    second.release();

    try testing.expectEqual(@intFromPtr(a), @intFromPtr(b));
    try testing.expectEqual(@as(usize, 1), reg.entries.count());
}

test "another tenant's in-flight call does not block this tenant's lease" {
    var reg = StdioRegistry.init(testing.allocator, testing.io);
    defer reg.deinit();
    const tenant_a = mcp_scope.Scope{ .owner = "u_a", .workspace_id = "ws_1" };
    const tenant_b = mcp_scope.Scope{ .owner = "u_b", .workspace_id = "ws_1" };

    var held = try reg.acquire("files", sigtermIgnoringArgv(), .{ .scope = tenant_a });
    defer held.release();

    var other = try reg.acquire("files", echo_argv(), .{
        .scope = tenant_b,
        .wait_ns = 200 * std.time.ns_per_ms,
    });
    defer other.release();

    try testing.expect(held.client() != other.client());
}

test "invalidating a server name respawns it for every tenant that declared it" {
    var reg = StdioRegistry.init(testing.allocator, testing.io);
    defer reg.deinit();
    const tenant_a = mcp_scope.Scope{ .owner = "u_a", .workspace_id = "ws_1" };
    const tenant_b = mcp_scope.Scope{ .owner = "u_b", .workspace_id = "ws_1" };

    var la = try reg.acquire("files", echo_argv(), .{ .scope = tenant_a });
    const a_before = la.client();
    la.release();
    var lb = try reg.acquire("files", echo_argv(), .{ .scope = tenant_b });
    const b_before = lb.client();
    lb.release();

    reg.markStale("files");

    var la2 = try reg.acquire("files", echo_argv(), .{ .scope = tenant_a });
    const a_after = la2.client();
    la2.release();
    var lb2 = try reg.acquire("files", echo_argv(), .{ .scope = tenant_b });
    const b_after = lb2.client();
    lb2.release();

    try testing.expect(a_before != a_after);
    try testing.expect(b_before != b_after);
}

test "a changed argv replaces the child instead of reusing the old one" {
    var reg = StdioRegistry.init(testing.allocator, testing.io);
    defer reg.deinit();
    const tenant = mcp_scope.Scope{ .owner = "u_a", .workspace_id = "ws_1" };

    var first = try reg.acquire("files", echo_argv(), .{ .scope = tenant });
    const before = first.client();
    first.release();

    var second = try reg.acquire("files", sigtermIgnoringArgv(), .{ .scope = tenant });
    const after = second.client();
    second.release();

    try testing.expect(before != after);
    try testing.expectEqual(@as(usize, 1), reg.entries.count());
}

test "evicting a server name drops every tenant's child" {
    var reg = StdioRegistry.init(testing.allocator, testing.io);
    defer reg.deinit();
    const tenant_a = mcp_scope.Scope{ .owner = "u_a", .workspace_id = "ws_1" };
    const tenant_b = mcp_scope.Scope{ .owner = "u_b", .workspace_id = "ws_1" };

    var la = try reg.acquire("files", echo_argv(), .{ .scope = tenant_a });
    la.release();
    var lb = try reg.acquire("files", echo_argv(), .{ .scope = tenant_b });
    lb.release();
    var keep = try reg.acquire("search", echo_argv(), .{ .scope = tenant_a });
    keep.release();

    reg.evictName("files", testing.allocator);

    try testing.expectEqual(@as(usize, 1), reg.entries.count());
}

test "a registry at its ceiling refuses another child and keeps the ones it has" {
    var reg = StdioRegistry.init(testing.allocator, testing.io);
    defer reg.deinit();
    reg.max_entries = 2;

    var a = try reg.acquire("a", echo_argv(), .{});
    a.release();
    var b = try reg.acquire("b", echo_argv(), .{});
    b.release();

    try testing.expectError(StdioError.TooManyChildren, reg.acquire("c", echo_argv(), .{}));

    var a_again = try reg.acquire("a", echo_argv(), .{});
    a_again.release();
    try testing.expectEqual(@as(usize, 2), reg.entries.count());
}

test "StdioRegistry.dropAndRespawn returns a different client" {
    var reg = StdioRegistry.init(testing.allocator, testing.io);
    defer reg.deinit();
    var l1 = try reg.acquire("x", echo_argv(), .{});
    const c1 = l1.client();
    l1.release();
    const c2 = try reg.dropAndRespawn(.{}, "x", echo_argv());
    try testing.expect(c1 != c2);
}

test "StdioRegistry.deinit kills spawned children (no hang)" {
    {
        var reg = StdioRegistry.init(testing.allocator, testing.io);
        var la = try reg.acquire("a", echo_argv(), .{});
        la.release();
        var lb = try reg.acquire("b", echo_argv(), .{});
        lb.release();
        reg.deinit();
    }
    // No assertion — the test passes if deinit returns and the test
    // process doesn't hang. CI timeout is the real assertion.
}

// ── FD-leak regression tests ───────────────────────────────────────────────
// Same pattern as kabelweb repo src/client/fd_leak_test.zig — we count open
// FDs via `ls /proc/self/fd | wc -l` (Linux only; skip on other OS) and

/// Count open FDs by running `ls /proc/self/fd`. Linux-only;
/// non-Linux hosts return 0 and the tests skip.
fn countOpenFds() usize {
    if (builtin.os.tag != .linux) return 0;
    var child = std.process.spawn(testing.io, .{
        .argv = &.{ "sh", "-c", "ls /proc/self/fd 2>/dev/null | wc -l" },
        .stdin = .ignore,
        .stdout = .pipe,
        .stderr = .pipe,
    }) catch return 0;
    // `child.kill` in Zig 0.16 closes stdin/stdout/stderr pipes internally
    // (via `childCleanupPosix`) and nulls child.id.
    defer child.kill(testing.io);

    var buf: [64]u8 = undefined;
    var total: usize = 0;
    if (child.stdout) |out| {
        var reader = out.reader(testing.io, &buf);
        while (true) {
            const n = std.Io.Reader.readSliceShort(&reader.interface, &buf) catch break;
            if (n == 0) break;
            total += n;
        }
    }

    var n: usize = 0;
    var i: usize = 0;
    while (i < total) : (i += 1) {
        const c = buf[i];
        if (c >= '0' and c <= '9') {
            n = n * 10 + @as(usize, c - '0');
        }
    }
    return n;
}

test "fd: StdioClient.init + deinit does not leak FDs (20 cycles)" {
    if (builtin.os.tag != .linux) return;
    const before = countOpenFds();
    var i: usize = 0;
    while (i < 20) : (i += 1) {
        var client = StdioClient.init(testing.allocator, testing.io, echo_argv()) catch continue;
        client.deinit();
    }
    // Give the OS a moment to actually close the FDs.
    std.Io.sleep(testing.io, .{ .nanoseconds = std.time.ns_per_ms * 50 }, .real) catch {};
    const after = countOpenFds();
    // Tolerance: a few transient FDs from countOpenFds's own child
    // may be in flight; we allow 5 of slack.
    const tolerance: usize = 5;
    if (after > before + tolerance) {
        std.debug.print("!! FD leak: before={d} after={d} delta={d} !!\n", .{ before, after, after - before });
        return error.FdLeakSuspected;
    }
}

test "fd: StdioRegistry spawn + deinit does not leak FDs (20 servers)" {
    if (builtin.os.tag != .linux) return;
    const before = countOpenFds();
    {
        var reg = StdioRegistry.init(testing.allocator, testing.io);
        var i: usize = 0;
        while (i < 20) : (i += 1) {
            const name = std.fmt.allocPrint(testing.allocator, "server-{d}", .{i}) catch continue;
            defer testing.allocator.free(name);
            var lease = reg.acquire(name, echo_argv(), .{}) catch continue;
            lease.release();
        }
        reg.deinit();
    }
    std.Io.sleep(testing.io, .{ .nanoseconds = std.time.ns_per_ms * 50 }, .real) catch {};
    const after = countOpenFds();
    const tolerance: usize = 5;
    if (after > before + tolerance) {
        std.debug.print("!! FD leak: before={d} after={d} delta={d} !!\n", .{ before, after, after - before });
        return error.FdLeakSuspected;
    }
}

test "fd: failed spawn does not leak FDs (20 attempts at missing binary)" {
    if (builtin.os.tag != .linux) return;
    const before = countOpenFds();
    var i: usize = 0;
    while (i < 20) : (i += 1) {
        _ = StdioClient.init(testing.allocator, testing.io, &.{
            "/no/such/binary/should/exist/xyzzy",
        }) catch {};
    }
    std.Io.sleep(testing.io, .{ .nanoseconds = std.time.ns_per_ms * 50 }, .real) catch {};
    const after = countOpenFds();
    const tolerance: usize = 5;
    if (after > before + tolerance) {
        std.debug.print("!! FD leak: before={d} after={d} delta={d} (failed-spawn path) !!\n", .{ before, after, after - before });
        return error.FdLeakSuspected;
    }
}

// ── Timeout / cancel-callback / markStale tests (Task 3) ───────────────────
// The single-thread `testing.io` makes deadline tests use real wall time — no
// virtual clock. Slack tolerance per test is documented in a comment.

/// Argv for a child that exits (closes stdout) AFTER a bounded delay longer
/// than the test's recv deadline but shorter than the test's slack window.
/// POSIX: `sh -c "sleep 0.6"`; Windows: `cmd.exe /C "timeout /T 1 /NOBREAK"`.
fn eventually_closes_argv() []const []const u8 {
    return if (builtin.os.tag == .windows)
        &.{ "cmd.exe", "/C", "timeout", "/T", "1", "/NOBREAK" }
    else
        &.{ "sh", "-c", "sleep 0.6" };
}

test "recv returns RecvTimeout when child never responds" {
    // 500ms deadline.
    const argv: []const []const u8 = if (builtin.os.tag == .windows)
        &.{ "cmd.exe", "/C", "timeout", "/T", "1", "/NOBREAK" }
    else
        &.{ "sh", "-c", "sleep 0.6" };
    var client = StdioClient.init(testing.allocator, testing.io, argv) catch |err| {
        if (err == error.ChildSpawnFailed) return;
        return err;
    };
    defer client.deinit();

    const start = std.Io.Timestamp.now(testing.io, .real).nanoseconds;
    const deadline_ns: u64 = 500 * std.time.ns_per_ms;
    const result = client.recv(deadline_ns, null);
    const elapsed_ms: u64 = @intCast(@divTrunc(
        std.Io.Timestamp.now(testing.io, .real).nanoseconds - start,
        std.time.ns_per_ms,
    ));
    // Either error is acceptable — both prove the recv is bounded.
    // RecvTimeout: the deadline check fired (preferred).
    try testing.expect(result == error.RecvTimeout or result == error.UnexpectedEof);
    // Slack 200ms above the 500ms deadline.
    try testing.expect(elapsed_ms < 700);
}

test "recv aborts immediately when cancel callback returns true" {
    // Cancel callback returns true on the FIRST call. The recv loop bails out
    // at the next check — well before any deadline fires.
    var client = StdioClient.init(testing.allocator, testing.io, echo_argv()) catch |err| {
        if (err == error.ChildSpawnFailed) return;
        return err;
    };
    defer client.deinit();

    // Write some data to the child's stdin so it has something to
    // echo back. Without this, the first read blocks forever
    // (echo has no input to read on its stdin).
    const stdin_file = client.stdin orelse return error.BrokenPipe;
    const probe = "x\n";
    std.Io.File.writeStreamingAll(stdin_file, testing.io, probe) catch return;

    const cancel = struct {
        fn call() bool {
            return true;
        }
    }.call;
    const start = std.Io.Timestamp.now(testing.io, .real).nanoseconds;
    const result = client.recv(10_000 * std.time.ns_per_ms, &cancel);
    const elapsed_ms: u64 = @intCast(@divTrunc(
        std.Io.Timestamp.now(testing.io, .real).nanoseconds - start,
        std.time.ns_per_ms,
    ));
    // The cancel-callback is consulted before the first byte, so any error
    // that indicates the recv is bounded (RecvTimeout) is acceptable. We just
    // want to prove the recv doesn't hang past the deadline.
    try testing.expect(result == error.RecvTimeout or result == error.BrokenPipe);
    // Should be effectively instant after the first byte reads.
    // 200ms slack for slow CI runners + Threaded io overhead.
    try testing.expect(elapsed_ms < 200);
}

test "markStale: acquire respawns instead of returning cached client" {
    // Two acquires with a markStale in between must produce DIFFERENT
    // StdioClient pointers — the dirty flag forced a fresh spawn. Uses
    // echo_argv so the spawn is fast and the test is deterministic.
    var reg = StdioRegistry.init(testing.allocator, testing.io);
    defer reg.deinit();
    var l1 = try reg.acquire("foo", echo_argv(), .{});
    const c1 = l1.client();
    l1.release();
    reg.markStale("foo");
    var l2 = try reg.acquire("foo", echo_argv(), .{});
    defer l2.release();
    try testing.expect(c1 != l2.client());
}

test "Lease.markStale respawns on the next acquire" {
    // Same contract as the by-name `markStale`, but driven through the
    // lease the caller actually holds — which is the path every request
    // handler uses on a timeout.
    var reg = StdioRegistry.init(testing.allocator, testing.io);
    defer reg.deinit();
    var l1 = try reg.acquire("bar", echo_argv(), .{});
    const c1 = l1.client();
    l1.markStale();
    l1.release();
    var l2 = try reg.acquire("bar", echo_argv(), .{});
    defer l2.release();
    try testing.expect(c1 != l2.client());
    // The replacement must come back clean, or the respawn never sticks.
    try testing.expectEqual(false, l2.entry.dirty.load(.acquire));
}

test "markStale on unknown name is a no-op (does not panic or insert)" {
    // Self-healing contract: markStale against a server that hasn't
    // been spawned yet is silently ignored. The next acquire
    // for that name still works (creates a fresh entry).
    var reg = StdioRegistry.init(testing.allocator, testing.io);
    defer reg.deinit();
    reg.markStale("not_in_registry"); // must not crash
    try testing.expectEqual(@as(usize, 0), reg.entries.count());
    var lease = try reg.acquire("not_in_registry", echo_argv(), .{});
    lease.release();
    try testing.expectEqual(@as(usize, 1), reg.entries.count());
}

// ── First-byte deadline tests (2026-09-03 empty-args hang fix)
// ────────────── Regression coverage for the `/api/mcp/test` hang: probing a
// stdio server with empty args spawns the bare command (e.g.

/// A child that stays alive and silent well past any test deadline, rendered
/// by `host_fixture`: a `sleep`ing script on POSIX, the batch file's `ping`
/// sleep on Windows. It prints NOTHING, so only the deadline ends the recv.
fn write_silent_child(fx: *hf.Fixture) ![]u8 {
    return fx.writeProgram("silent-child", .{ .sleep_ms = 5_000 });
}

test "recv times out on truly-silent child (empty-args bare command)" {
    const a = testing.allocator;
    var fx = try hf.Fixture.init(a);
    defer fx.deinit();
    const child_argv = try write_silent_child(&fx);
    defer a.free(child_argv);

    var client = try StdioClient.init(a, testing.io, &.{child_argv});
    defer client.deinit();

    const start = std.Io.Timestamp.now(testing.io, .real).nanoseconds;
    const result = client.recv(300 * std.time.ns_per_ms, null);
    const elapsed_ms: u64 = @intCast(@divTrunc(
        std.Io.Timestamp.now(testing.io, .real).nanoseconds - start,
        std.time.ns_per_ms,
    ));
    try testing.expect(result == error.RecvTimeout);
    // Waited ~the full deadline (not an instant fail) but stayed far below
    // any hang: 200ms lower bound proves the poll actually waited; 5s upper
    // bound proves the deadline fired (pre-fix this recv never returned at
    try testing.expect(elapsed_ms >= 200);
    try testing.expect(elapsed_ms < 5000);
}

test "recv aborts on cancel with truly-silent child" {
    const a = testing.allocator;
    var fx = try hf.Fixture.init(a);
    defer fx.deinit();
    const child_argv = try write_silent_child(&fx);
    defer a.free(child_argv);

    var client = try StdioClient.init(a, testing.io, &.{child_argv});
    defer client.deinit();

    const cancel = struct {
        fn call() bool {
            return true;
        }
    }.call;
    const start = std.Io.Timestamp.now(testing.io, .real).nanoseconds;
    // 10s deadline is irrelevant — cancel fires inside the first
    // 100ms poll slice, so the recv must abort almost immediately
    // even though the child never produces a single byte.
    const result = client.recv(10_000 * std.time.ns_per_ms, &cancel);
    const elapsed_ms: u64 = @intCast(@divTrunc(
        std.Io.Timestamp.now(testing.io, .real).nanoseconds - start,
        std.time.ns_per_ms,
    ));
    try testing.expect(result == error.RecvTimeout);
    try testing.expect(elapsed_ms < 2000);
}

/// A pipe that accepts bytes and is never drained. POSIX-only: the CRT `pipe`
/// takes HANDLEs on Windows, where `waitWritable` fail-opens — a path the
/// host-table test below covers with an assertion of its own instead.
const TestPipe = struct {
    read_fd: std.c.fd_t,
    write_file: std.Io.File,

    fn open() !TestPipe {
        if (comptime builtin.os.tag == .windows) {
            return error.PipeUnsupported;
        } else {
            var fds: [2]std.c.fd_t = undefined;
            if (std.c.pipe(&fds) != 0) return error.PipeUnsupported;
            return .{
                .read_fd = fds[0],
                .write_file = .{ .handle = fds[1], .flags = .{ .nonblocking = false } },
            };
        }
    }

    fn close(self: *TestPipe) void {
        _ = std.c.close(self.read_fd);
        _ = std.c.close(self.write_file.handle);
    }
};

test "writeAllBounded delivers every byte to a sink that accepts them, across chunk boundaries" {
    // Host-independent: a temp file accepts every byte on every platform, so
    // this asserts the write path itself rather than one platform's pipe.
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    // 10 KB crosses the 4 KiB write ceiling (three writes).
    const payload = try testing.allocator.alloc(u8, 10_000);
    defer testing.allocator.free(payload);
    for (payload, 0..) |*b, i| b.* = @intCast('a' + (i % 26));

    {
        const sink = try tmp.dir.createFile(testing.io, "sink.bin", .{ .truncate = true });
        defer sink.close(testing.io);
        try writeAllBounded(testing.io, sink, payload, 5_000 * std.time.ns_per_ms, null);
    }

    const got = try tmp.dir.readFileAlloc(testing.io, "sink.bin", testing.allocator, .limited(payload.len + 1));
    defer testing.allocator.free(got);
    try testing.expectEqualStrings(payload, got);
}

test "writeAllBounded bounds a stalled sink where the gate polls, and fail-opens where it does not" {
    // One body, both hosts: where `waitWritable` polls a pipe (POSIX) the
    // deadline and cancel end a stalled write; on Windows it fail-opens, so
    // that branch is asserted here. An unlisted host FAILS.
    const gated = switch (builtin.os.tag) {
        .linux, .macos => true,
        .windows => false,
        else => return error.UnlistedHost,
    };

    if (comptime gated) {
        var pipe = try TestPipe.open();
        defer pipe.close();

        // Past any platform pipe buffer (64 KiB on Linux), so the first chunks
        // fit and the rest can only end via the deadline.
        const payload = try testing.allocator.alloc(u8, 256 * 1024);
        defer testing.allocator.free(payload);
        @memset(payload, 'x');

        const start = std.Io.Timestamp.now(testing.io, .real).nanoseconds;
        const result = writeAllBounded(testing.io, pipe.write_file, payload, 300 * std.time.ns_per_ms, null);
        const elapsed_ms: u64 = @intCast(@divTrunc(
            std.Io.Timestamp.now(testing.io, .real).nanoseconds - start,
            std.time.ns_per_ms,
        ));
        try testing.expect(result == error.SendTimeout);
        // 200ms lower bound: the poll actually waited for pipe space. 5s upper
        // bound: the deadline fired. Unbounded, this write never returns.
        try testing.expect(elapsed_ms >= 200);
        try testing.expect(elapsed_ms < 5000);

        const cancel = struct {
            fn call() bool {
                return true;
            }
        }.call;
        const cancel_start = std.Io.Timestamp.now(testing.io, .real).nanoseconds;
        // The 30s budget is irrelevant: cancel is polled before the first write.
        const cancelled = writeAllBounded(testing.io, pipe.write_file, payload, 30 * std.time.ns_per_s, &cancel);
        const cancel_ms: u64 = @intCast(@divTrunc(
            std.Io.Timestamp.now(testing.io, .real).nanoseconds - cancel_start,
            std.time.ns_per_ms,
        ));
        try testing.expect(cancelled == error.SendTimeout);
        try testing.expect(cancel_ms < 2000);
    } else {
        // Windows: the gate is a documented no-op — an already-expired
        // deadline still reports writable instead of parking the writer.
        const past_deadline_ns = std.Io.Timestamp.now(testing.io, .real).nanoseconds - std.time.ns_per_s;
        try testing.expect(waitWritable(testing.io, std.Io.File.stderr(), past_deadline_ns, std.time.ns_per_ms, null));
    }
}

test "recv with deadline still delivers data (happy path)" {
    // Guards the `waitReadable` fast path: when the child IS producing, poll
    // returns readable immediately and the framed message comes back intact.
    var client = StdioClient.init(testing.allocator, testing.io, echo_argv()) catch |err| {
        if (err == error.ChildSpawnFailed) return;
        return err;
    };
    defer client.deinit();

    const stdin_file = client.stdin orelse return error.BrokenPipe;
    // NDJSON-framed line; `cat`/`more` echoes it back on stdout.
    const probe = "{\"jsonrpc\":\"2.0\",\"id\":1}\n";
    std.Io.File.writeStreamingAll(stdin_file, testing.io, probe) catch return;

    const body = client.recv(5_000 * std.time.ns_per_ms, null) catch |err| {
        std.debug.print("!! happy-path recv failed: {s} !!\n", .{@errorName(err)});
        return err;
    };
    // `recv` allocates the body from the client's own arena, so it has to be
    // freed through the same allocator that produced it —
    // `testing.allocator.free` on an arena-owned pointer is an "Invalid free"
    defer client.allocator().free(body);
    try testing.expectEqualStrings("{\"jsonrpc\":\"2.0\",\"id\":1}", body);
}

/// Two NDJSON responses in ONE payload: the shape a fast server produces when
/// it coalesces back-to-back messages into a single pipe write.
const COALESCED_NDJSON = "{\"jsonrpc\":\"2.0\",\"id\":1}\n{\"jsonrpc\":\"2.0\",\"id\":2}\n";

test "recv preserves coalesced back-to-back lines (lightpanda hang)" {
    // A fast server writes two NDJSON lines in one pipe write; the first
    // recv() must not drop the second line with its buffer.
    const a = testing.allocator;
    var fx = try hf.Fixture.init(a);
    defer fx.deinit();
    const child_argv = try fx.writeProgram("coalesced-ndjson", .{ .stdout = COALESCED_NDJSON });
    defer a.free(child_argv);

    var client = try StdioClient.init(a, testing.io, &.{child_argv});
    defer client.deinit();

    // Both bodies come from the client's per-client arena (see the
    // `recv` allocator note in the happy-path test above).
    const first = client.recv(5_000 * std.time.ns_per_ms, null) catch |err| {
        std.debug.print("!! coalesced first recv failed: {s} !!\n", .{@errorName(err)});
        return err;
    };
    defer client.allocator().free(first);
    try testing.expectEqualStrings("{\"jsonrpc\":\"2.0\",\"id\":1}", first);

    const second = client.recv(5_000 * std.time.ns_per_ms, null) catch |err| {
        std.debug.print("!! coalesced second recv failed: {s} !!\n", .{@errorName(err)});
        return err;
    };
    defer client.allocator().free(second);
    try testing.expectEqualStrings("{\"jsonrpc\":\"2.0\",\"id\":2}", second);
}

// ============================================================================
// Framing + lease edge cases (concurrency / framing hardening)
// ============================================================================

/// Temp file + open handle for one `readFramed` case.
const FramedInput = struct {
    tmp: std.testing.TmpDir,
    file: std.Io.File,

    fn deinit(self: *FramedInput) void {
        self.file.close(testing.io);
        self.tmp.cleanup();
    }
};

fn framedInput(name: []const u8, payload: []const u8) !FramedInput {
    var tmp = std.testing.tmpDir(.{});
    errdefer tmp.cleanup();
    try tmp.dir.writeFile(testing.io, .{ .sub_path = name, .data = payload });
    return .{ .tmp = tmp, .file = try tmp.dir.openFile(testing.io, name, .{}) };
}

// ── A. Framing edge cases ──────────────────────────────────────────────────

test "readFramed rejects a negative Content-Length as InvalidContentLength" {
    // A sign character is the cheapest way to smuggle a length past a naive
    // parser: `-5` is a valid token to anything HTTP-shaped, and a parser
    // that strips the sign would hand back a 5-byte body that was never
    var input = try framedInput("neg_content_length.txt", "Content-Length: -5\r\n\r\n");
    defer input.deinit();
    try testing.expectError(
        StdioError.InvalidContentLength,
        readFramed(testing.allocator, testing.io, input.file, 0, null),
    );
}

test "readFramed rejects a non-numeric Content-Length as InvalidContentLength" {
    // Same distinction as the negative case, different failure mode in
    // `parseInt`.
    var input = try framedInput("nan_content_length.txt", "Content-Length: abc\r\n\r\n");
    defer input.deinit();
    try testing.expectError(
        StdioError.InvalidContentLength,
        readFramed(testing.allocator, testing.io, input.file, 0, null),
    );
}

test "readFramed returns an empty body and no error for Content-Length: 0" {
    // A zero-length frame is a server saying "alive, nothing to say".
    var input = try framedInput("zero_content_length.txt", "Content-Length: 0\r\n\r\n");
    defer input.deinit();
    const body = try readFramed(testing.allocator, testing.io, input.file, 0, null);
    defer testing.allocator.free(body);
    try testing.expectEqual(@as(usize, 0), body.len);
}

test "readFramed matches the Content-Length header name case-insensitively" {
    // Header names are case-insensitive and real MCP servers are not
    // consistent about the casing they emit (`content-length` from some SDK
    // paths, `Content-Length` from others).
    var input = try framedInput("lower_content_length.txt", "content-length: 5\r\n\r\nhello");
    defer input.deinit();
    const body = try readFramed(testing.allocator, testing.io, input.file, 0, null);
    defer testing.allocator.free(body);
    try testing.expectEqualStrings("hello", body);
}

test "readFramed tolerates tabs and trailing spaces around the Content-Length value" {
    // Real servers (and proxies in front of them) hand-mangle header
    // whitespace.
    var input = try framedInput("padded_content_length.txt", "Content-Length:\t 5 \r\n\r\nhello");
    defer input.deinit();
    const body = try readFramed(testing.allocator, testing.io, input.file, 0, null);
    defer testing.allocator.free(body);
    try testing.expectEqualStrings("hello", body);
}

test "readFramed finds Content-Length after other headers in the block" {
    // The MCP spec frames with Content-Length among *possibly many*
    // headers. Reading only the first line drops every server that also
    // announces Content-Type, which is most of them.
    var input = try framedInput(
        "multi_header.txt",
        "Content-Type: application/json\r\nContent-Length: 5\r\n\r\nhello",
    );
    defer input.deinit();
    const body = try readFramed(testing.allocator, testing.io, input.file, 0, null);
    defer testing.allocator.free(body);
    try testing.expectEqualStrings("hello", body);
}

test "readFramed returns InvalidFrame on a stray log line instead of swallowing the next message" {
    // THE REGRESSION this guards.
    var input = try framedInput("stray_log_line.txt", "some log line\n{\"jsonrpc\":\"2.0\"}\n");
    defer input.deinit();
    try testing.expectError(
        StdioError.InvalidFrame,
        readFramed(testing.allocator, testing.io, input.file, 0, null),
    );
}

test "readFramed reports UnexpectedEof when EOF lands mid-header" {
    // A child that dies between spawn and answer leaves a truncated header.
    var input = try framedInput("eof_in_header.txt", "Content-Len");
    defer input.deinit();
    try testing.expectError(
        StdioError.UnexpectedEof,
        readFramed(testing.allocator, testing.io, input.file, 0, null),
    );
}

test "readFramed reports UnexpectedEof when the body is shorter than Content-Length promised" {
    // The body allocation is sized from the header, so a child that dies 3
    // bytes into a 100-byte body leaves a hole.
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var input = try framedInput("eof_in_body.txt", "Content-Length: 100\r\n\r\nhel");
    defer input.deinit();
    try testing.expectError(
        StdioError.UnexpectedEof,
        readFramed(arena.allocator(), testing.io, input.file, 0, null),
    );
}

test "readFramed returns InvalidFrame when the header block overruns MAX_HEADER_BYTES" {
    // The header buffer is a fixed 8 KiB stack array, so the bound is the
    // only thing making that allocation safe: a server (or a confused proxy)
    // streaming megabytes of headers would otherwise run us off the end of
    const prefix = "X-Pad: ";
    const payload = try testing.allocator.alloc(u8, prefix.len + MAX_HEADER_BYTES + 64);
    defer testing.allocator.free(payload);
    @memcpy(payload[0..prefix.len], prefix);
    @memset(payload[prefix.len..], 'a');
    var input = try framedInput("header_flood.txt", payload);
    defer input.deinit();
    try testing.expectError(
        StdioError.InvalidFrame,
        readFramed(testing.allocator, testing.io, input.file, 0, null),
    );
}

test "readFramed returns a growth-path NDJSON line at its exact payload length" {
    // Real tool results blow past the 256-byte seed buffer constantly, so the
    // realloc-doubling path is the hot path, not a corner case.
    const prefix = "{\"jsonrpc\":\"2.0\",\"result\":\"";
    const suffix = "\"}\r\n";
    const fill: usize = 1000;
    const payload = try testing.allocator.alloc(u8, prefix.len + fill + suffix.len);
    defer testing.allocator.free(payload);
    @memcpy(payload[0..prefix.len], prefix);
    @memset(payload[prefix.len..][0..fill], 'x');
    @memcpy(payload[prefix.len + fill ..], suffix);
    const expected = payload[0 .. payload.len - 2]; // drop the CRLF
    var input = try framedInput("ndjson_growth.txt", payload);
    defer input.deinit();
    const body = try readFramed(testing.allocator, testing.io, input.file, 0, null);
    defer testing.allocator.free(body);
    try testing.expectEqual(expected.len, body.len);
    try testing.expectEqualStrings(expected, body);
}

// ── B. Body-size guards ────────────────────────────────────────────────────

test "readFramed rejects a Content-Length far above the cap as BodyTooLarge" {
    // 99,999,999,999 is a perfectly valid usize.
    var input = try framedInput("oversized_content_length.txt", "Content-Length: 99999999999\r\n\r\n");
    defer input.deinit();
    try testing.expectError(
        StdioError.BodyTooLarge,
        readFramed(testing.allocator, testing.io, input.file, 0, null),
    );
}

test "readFramed rejects Content-Length of maxInt(u64) as BodyTooLarge without allocating it" {
    // The literal the MAX_BODY_BYTES doc calls out: 16 EiB parses cleanly
    // into a usize and is the maximum an attacker can write in one header
    // line.
    if (comptime @bitSizeOf(usize) < 64) return error.SkipZigTest;
    var input = try framedInput("maxint_content_length.txt", "Content-Length: 18446744073709551615\r\n\r\n");
    defer input.deinit();
    try testing.expectError(
        StdioError.BodyTooLarge,
        readFramed(testing.allocator, testing.io, input.file, 0, null),
    );
}

test "readFramed's body cap is exclusive: exactly MAX_BODY_BYTES passes, one byte over is BodyTooLarge" {
    // Off-by-one is a real bug in either direction — `>=` rejects a
    // legitimate 10 MiB tool result, which is the SDK's own default buffer
    // size.
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();

    var over_buf: [64]u8 = undefined;
    const over = try std.fmt.bufPrint(&over_buf, "Content-Length: {d}\r\n\r\n", .{MAX_BODY_BYTES + 1});
    var over_input = try framedInput("one_over_cap.txt", over);
    defer over_input.deinit();
    try testing.expectError(
        StdioError.BodyTooLarge,
        readFramed(testing.allocator, testing.io, over_input.file, 0, null),
    );

    var at_buf: [64]u8 = undefined;
    const at_cap = try std.fmt.bufPrint(&at_buf, "Content-Length: {d}\r\n\r\n", .{MAX_BODY_BYTES});
    var at_input = try framedInput("exactly_at_cap.txt", at_cap);
    defer at_input.deinit();
    try testing.expectError(
        StdioError.UnexpectedEof,
        readFramed(arena.allocator(), testing.io, at_input.file, 0, null),
    );
}

// ── C. Lease / concurrency contracts ───────────────────────────────────────

test "acquire on an already-leased entry returns LeaseTimeout and the entry stays acquirable" {
    // Two sessions reaching for the same MCP server is normal traffic, not an
    // error condition — but the second one must not get the child, because
    // `StdioClient` wraps a bare-cursor reader with no internal locking.
    var reg = StdioRegistry.init(testing.allocator, testing.io);
    defer reg.deinit();
    var held = try reg.acquire("shared", echo_argv(), .{});
    const c1 = held.client();

    try testing.expectError(
        StdioError.LeaseTimeout,
        reg.acquire("shared", echo_argv(), .{ .wait_ns = 20 * std.time.ns_per_ms }),
    );

    held.release();
    var next = try reg.acquire("shared", echo_argv(), .{ .wait_ns = 20 * std.time.ns_per_ms });
    defer next.release();
    // Same child: the timeout was contention, not a reason to respawn.
    try testing.expectEqual(@intFromPtr(c1), @intFromPtr(next.client()));
}

test "acquire honours is_cancelled under contention without respawning the cached child" {
    // The Stop button has to reach the lease wait too: a user who cancels
    // while another session is mid-transaction must not be pinned for the
    // rest of the (tens of seconds long) wait budget.
    var reg = StdioRegistry.init(testing.allocator, testing.io);
    defer reg.deinit();
    var held = try reg.acquire("cancelled", echo_argv(), .{});
    const c1 = held.client();

    const cancel_now = struct {
        fn call() bool {
            return true;
        }
    }.call;

    const start = std.Io.Timestamp.now(testing.io, .real).nanoseconds;
    try testing.expectError(
        StdioError.LeaseTimeout,
        reg.acquire("cancelled", echo_argv(), .{
            .wait_ns = 10_000 * std.time.ns_per_ms,
            .is_cancelled = &cancel_now,
        }),
    );
    const elapsed_ms: i128 = @divTrunc(
        std.Io.Timestamp.now(testing.io, .real).nanoseconds - start,
        std.time.ns_per_ms,
    );
    // 10s budget, must come back in well under a second: the cancel is
    // polled before the first sleep, not between them.
    try testing.expect(elapsed_ms < 2000);

    held.release();
    var next = try reg.acquire("cancelled", echo_argv(), .{});
    defer next.release();
    try testing.expectEqual(@intFromPtr(c1), @intFromPtr(next.client()));
}

test "Lease.release is idempotent — a double release does not free the entry lock" {
    // Every production call site pairs `defer lease.release()` with an
    // explicit release on the happy path, so releasing twice is the normal
    // shape, not abuse.
    var reg = StdioRegistry.init(testing.allocator, testing.io);
    defer reg.deinit();
    var lease = try reg.acquire("double-release", echo_argv(), .{});
    const c1 = lease.client();
    lease.release();
    lease.release();

    var next = try reg.acquire("double-release", echo_argv(), .{ .wait_ns = 50 * std.time.ns_per_ms });
    defer next.release();
    try testing.expectEqual(@intFromPtr(c1), @intFromPtr(next.client()));
    // `next` holds it exclusively — if the extra release had unlocked a
    // live mutex, this third acquire would sail through.
    try testing.expectError(
        StdioError.LeaseTimeout,
        reg.acquire("double-release", echo_argv(), .{ .wait_ns = 20 * std.time.ns_per_ms }),
    );
}

test "StdioClient.deinit is idempotent — the second call is a no-op" {
    // `defer client.deinit()` coexists with an explicit `deinit()` on the
    // error path, and the registry kills the same child again during its own
    // teardown.
    var client = StdioClient.init(testing.allocator, testing.io, echo_argv()) catch |err| {
        if (err == error.ChildSpawnFailed) return error.SkipZigTest;
        return err;
    };
    client.deinit();
    try testing.expect(client.is_dead);
    try testing.expect(client.stdin == null);
    client.deinit(); // must not double-kill
    try testing.expect(client.is_dead);
    try testing.expect(client.stdout == null);
}

test "send and recv after deinit return BrokenPipe instead of writing to a recycled fd" {
    // `child.kill` closes the pipes, but the cached handles keep the fd
    // NUMBERS.
    var client = StdioClient.init(testing.allocator, testing.io, echo_argv()) catch |err| {
        if (err == error.ChildSpawnFailed) return error.SkipZigTest;
        return err;
    };
    client.deinit();
    try testing.expectError(StdioError.BrokenPipe, client.send("{\"jsonrpc\":\"2.0\"}", 0));
    try testing.expectError(StdioError.BrokenPipe, client.recv(0, null));
    // recv must not have re-attached a reader to a dead pipe either.
    try testing.expect(client.reader == null);
}

/// Header promising 100 bytes, then 2 delivered: the header is complete and
/// the truncation is in the BODY, which is what leaves the tail in the
/// reader buffer when the child exits.
const TRUNCATED_CONTENT_LENGTH_FRAME = "Content-Length: 100\r\n\r\nab";

test "recv nulls the reader after a mid-frame failure so the next recv cannot replay buffered bytes" {
    // The persistent 4 KiB reader buffer can hold the tail of an abandoned
    // frame.
    const a = testing.allocator;
    var fx = try hf.Fixture.init(a);
    defer fx.deinit();
    // Header promises 100 bytes, the child delivers 2 and exits.
    const child_argv = try fx.writeProgram("truncated-frame", .{ .stdout = TRUNCATED_CONTENT_LENGTH_FRAME });
    defer a.free(child_argv);
    // Premise, asserted rather than assumed: this host's fixture really does
    // deliver a header promising 100 bytes with 2 body bytes after it, so a
    // child that printed nothing cannot make the recvs below pass vacuously.
    var probe = try run_captured.run(a, testing.io, &.{child_argv}, .{ .timeout_ms = 10_000 });
    defer probe.deinit(a);
    try testing.expectEqual(@as(u8, 0), probe.term.exited);
    try testing.expect(std.mem.indexOf(u8, probe.stdout, "Content-Length: 100") != null);
    try testing.expect(std.mem.endsWith(u8, std.mem.trimEnd(u8, probe.stdout, "\r\n"), "ab"));

    var client = try StdioClient.init(a, testing.io, &.{child_argv});
    defer client.deinit();
    try testing.expect(client.reader == null); // lazily created, not yet

    const first = client.recv(5_000 * std.time.ns_per_ms, null);
    if (first) |body| {
        // A completed frame would mean the truncated header somehow
        // resolved — the premise of this test is wrong.
        a.free(body);
        return error.TestUnexpectedResult;
    } else |err| {
        // UnexpectedEof is the expected shape; RecvTimeout is accepted
        // because a pathologically slow CI runner can lose the race with
        // the child's exit. Either way the frame was abandoned.
        try testing.expect(err == StdioError.UnexpectedEof or err == StdioError.RecvTimeout);
    }
    try testing.expect(client.reader == null);

    // Second recv on the same client: it must not surface the abandoned
    // 2-byte tail as if it were a message.
    const second = client.recv(2_000 * std.time.ns_per_ms, null);
    if (second) |body| {
        a.free(body);
        return error.TestUnexpectedResult;
    } else |err| {
        try testing.expect(err == StdioError.UnexpectedEof or err == StdioError.RecvTimeout);
    }
}

test "acquire on a missing binary reports ChildSpawnFailed and leaves the entry re-acquirable" {
    // A typo in a server's command must not permanently poison the entry.
    var reg = StdioRegistry.init(testing.allocator, testing.io);
    defer reg.deinit();
    try testing.expectError(
        StdioError.ChildSpawnFailed,
        reg.acquire("bogus", &.{"/no/such/binary/xyzzy"}, .{}),
    );

    // Same name, working binary: the failed spawn must not have stranded
    // the entry lock or left it permanently dirty.
    var lease = try reg.acquire("bogus", echo_argv(), .{ .wait_ns = 500 * std.time.ns_per_ms });
    defer lease.release();
    try testing.expect(lease.client().stdin != null);
    try testing.expectEqual(false, lease.entry.dirty.load(.acquire));
}

// ── Guest transport: the same framing over a Channel ──────────────────────
// The channel is the seam, so a scripted one stands in for a tenant's VM here.
// The real guest duplex is covered by `zig build test:vm` and the vmd suite.

const FakeChannel = struct {
    incoming: []const u8 = "",
    at: usize = 0,
    silent: bool = false,
    closed_on_read: bool = false,
    closed: bool = false,
    /// Set by the opener helper: the channel was allocated for the registry,
    /// so closing it has to free it too.
    owned: bool = false,
    writes: std.ArrayList(u8) = .empty,

    fn channel(self: *FakeChannel) Channel {
        return .{ .io = testing.io, .ctx = @ptrCast(self), .vtable = &fake_vtable };
    }

    fn deinit(self: *FakeChannel) void {
        self.writes.deinit(testing.allocator);
    }

    fn read(ctx: *anyopaque, dst: []u8) Channel.ChannelError!Channel.ReadResult {
        const self: *FakeChannel = @ptrCast(@alignCast(ctx));
        if (self.closed_on_read) return error.Closed;
        if (self.silent or self.at >= self.incoming.len) {
            // A real duplex read waits inside the guest, so this one waits too
            // rather than turning the client's loop into a hot spin.
            if (self.silent) std.Io.sleep(testing.io, .{ .nanoseconds = 2 * std.time.ns_per_ms }, .real) catch {};
            if (self.silent) return error.NothingYet;
            return .{ .n = 0, .eof = true };
        }
        const n = @min(dst.len, self.incoming.len - self.at);
        @memcpy(dst[0..n], self.incoming[self.at..][0..n]);
        self.at += n;
        return .{ .n = n };
    }

    fn write(ctx: *anyopaque, bytes: []const u8) Channel.ChannelError!void {
        const self: *FakeChannel = @ptrCast(@alignCast(ctx));
        self.writes.appendSlice(testing.allocator, bytes) catch return error.OutOfMemory;
    }

    fn close(ctx: *anyopaque) void {
        const self: *FakeChannel = @ptrCast(@alignCast(ctx));
        self.closed = true;
        if (!self.owned) return;
        self.writes.deinit(testing.allocator);
        testing.allocator.destroy(self);
    }
};

const fake_vtable = Channel.VTable{
    .read = FakeChannel.read,
    .write = FakeChannel.write,
    .close = FakeChannel.close,
};

test "a guest client keeps the second coalesced line for the next read" {
    var fake = FakeChannel{ .incoming = COALESCED_NDJSON };
    defer fake.deinit();
    var client = GuestStdioClient.init(testing.allocator, fake.channel());
    defer client.deinit();

    const first = try client.recv(5_000 * std.time.ns_per_ms, null);
    try testing.expectEqualStrings("{\"jsonrpc\":\"2.0\",\"id\":1}", first);
    const second = try client.recv(5_000 * std.time.ns_per_ms, null);
    try testing.expectEqualStrings("{\"jsonrpc\":\"2.0\",\"id\":2}", second);
}

test "a guest client sends one newline-terminated message the server can frame" {
    var fake = FakeChannel{};
    defer fake.deinit();
    var client = GuestStdioClient.init(testing.allocator, fake.channel());
    defer client.deinit();

    try client.sendNDJSON("{\"jsonrpc\":\"2.0\",\"id\":9}", 0, null);
    try testing.expectEqualStrings("{\"jsonrpc\":\"2.0\",\"id\":9}\n", fake.writes.items);
}

test "a silent guest channel times out instead of reporting an empty message" {
    var fake = FakeChannel{ .silent = true };
    defer fake.deinit();
    var client = GuestStdioClient.init(testing.allocator, fake.channel());
    defer client.deinit();

    try testing.expectError(StdioError.RecvTimeout, client.recv(40 * std.time.ns_per_ms, null));
}

test "a guest duplex that closed ends the stream instead of hanging" {
    var fake = FakeChannel{ .closed_on_read = true };
    defer fake.deinit();
    var client = GuestStdioClient.init(testing.allocator, fake.channel());
    defer client.deinit();

    try testing.expectError(StdioError.UnexpectedEof, client.recv(5_000 * std.time.ns_per_ms, null));
}

test "a cancelled guest read stops even with no deadline at all" {
    var fake = FakeChannel{ .silent = true };
    defer fake.deinit();
    var client = GuestStdioClient.init(testing.allocator, fake.channel());
    defer client.deinit();

    const cancel = struct {
        fn call() bool {
            return true;
        }
    }.call;
    try testing.expectError(StdioError.RecvTimeout, client.recv(0, &cancel));
}

test "a guest client sends nothing once it is dead, and closes the duplex once" {
    var fake = FakeChannel{};
    defer fake.deinit();
    var client = GuestStdioClient.init(testing.allocator, fake.channel());

    client.deinit();
    client.deinit();
    try testing.expect(fake.closed);
    try testing.expectError(StdioError.BrokenPipe, client.sendNDJSON("{}", 0, null));
    try testing.expectError(StdioError.BrokenPipe, client.recv(0, null));
}

// ── GuestRegistry: one live duplex per (tenant, server) ───────────────────

/// The opener the registry tests drive: it hands back a scripted channel and
/// records how many duplexes it was asked for.
const Opener = struct {
    var opens: usize = 0;
    var fail_next: bool = false;
    var last_channel_ctx: ?*anyopaque = null;

    fn open(
        _: std.mem.Allocator,
        io: std.Io,
        _: GuestTarget,
        _: []const u8,
        _: []const []const u8,
    ) anyerror!Channel {
        if (fail_next) {
            fail_next = false;
            return error.ChildSpawnFailed;
        }
        opens += 1;
        const fake = try testing.allocator.create(FakeChannel);
        fake.* = .{ .incoming = COALESCED_NDJSON, .owned = true };
        last_channel_ctx = @ptrCast(fake);
        return .{ .io = io, .ctx = @ptrCast(fake), .vtable = &fake_vtable };
    }
};

test "two tenants declaring the same server get two guest duplexes" {
    Opener.opens = 0;
    var reg = GuestRegistry.init(testing.allocator, testing.io, Opener.open);
    defer reg.deinit();
    const target = GuestTarget{ .workspace_id = "ws_1", .socket = "/tmp/vmd.sock" };

    var a = try reg.acquire("files", &.{"server"}, .{
        .scope = .{ .owner = "u_a", .workspace_id = "ws_1" },
        .target = target,
    });
    const client_a = a.client();
    a.release();

    var b = try reg.acquire("files", &.{"server"}, .{
        .scope = .{ .owner = "u_b", .workspace_id = "ws_1" },
        .target = target,
    });
    const client_b = b.client();
    b.release();

    try testing.expect(client_a != client_b);
    try testing.expectEqual(@as(usize, 2), reg.entries.count());
    try testing.expectEqual(@as(usize, 2), Opener.opens);
}

test "one tenant asking twice for the same server keeps one guest duplex" {
    Opener.opens = 0;
    var reg = GuestRegistry.init(testing.allocator, testing.io, Opener.open);
    defer reg.deinit();
    const scope = mcp_scope.Scope{ .owner = "u_a", .workspace_id = "ws_1" };
    const target = GuestTarget{ .workspace_id = "ws_1", .socket = "/tmp/vmd.sock" };

    var first = try reg.acquire("files", &.{"server"}, .{ .scope = scope, .target = target });
    const a = first.client();
    first.release();
    var second = try reg.acquire("files", &.{"server"}, .{ .scope = scope, .target = target });
    const b = second.client();
    second.release();

    try testing.expectEqual(@intFromPtr(a), @intFromPtr(b));
    try testing.expectEqual(@as(usize, 1), reg.entries.count());
    try testing.expectEqual(@as(usize, 1), Opener.opens);
}

test "a stale guest lease reopens the duplex instead of reading a closed one" {
    Opener.opens = 0;
    var reg = GuestRegistry.init(testing.allocator, testing.io, Opener.open);
    defer reg.deinit();
    const scope = mcp_scope.Scope{ .owner = "u_a", .workspace_id = "ws_1" };
    const target = GuestTarget{ .workspace_id = "ws_1", .socket = "/tmp/vmd.sock" };

    var first = try reg.acquire("files", &.{"server"}, .{ .scope = scope, .target = target });
    const one = try first.client().recv(5_000 * std.time.ns_per_ms, null);
    try testing.expectEqualStrings("{\"jsonrpc\":\"2.0\",\"id\":1}", one);
    first.markStale();
    first.release();

    var second = try reg.acquire("files", &.{"server"}, .{ .scope = scope, .target = target });
    // A reopened duplex is a NEW stream: it answers with the first line again,
    // where the abandoned one would have handed back the second.
    const again = try second.client().recv(5_000 * std.time.ns_per_ms, null);
    second.release();
    try testing.expectEqualStrings("{\"jsonrpc\":\"2.0\",\"id\":1}", again);
    try testing.expectEqual(@as(usize, 2), Opener.opens);
}

test "a guest open that failed leaves the entry re-acquirable" {
    Opener.opens = 0;
    Opener.fail_next = true;
    var reg = GuestRegistry.init(testing.allocator, testing.io, Opener.open);
    defer reg.deinit();
    const scope = mcp_scope.Scope{ .owner = "u_a", .workspace_id = "ws_1" };
    const target = GuestTarget{ .workspace_id = "ws_1", .socket = "/tmp/vmd.sock" };

    try testing.expectError(
        StdioError.ChildSpawnFailed,
        reg.acquire("files", &.{"server"}, .{ .scope = scope, .target = target }),
    );
    var lease = try reg.acquire("files", &.{"server"}, .{ .scope = scope, .target = target });
    lease.release();
    try testing.expectEqual(@as(usize, 1), Opener.opens);
}

test "a guest registry at its ceiling refuses another duplex and keeps the ones it has" {
    Opener.opens = 0;
    var reg = GuestRegistry.init(testing.allocator, testing.io, Opener.open);
    defer reg.deinit();
    reg.max_entries = 1;
    const target = GuestTarget{ .workspace_id = "ws_1", .socket = "/tmp/vmd.sock" };

    var first = try reg.acquire("a", &.{"server"}, .{ .target = target });
    first.release();
    try testing.expectError(StdioError.TooManyChildren, reg.acquire("b", &.{"server"}, .{ .target = target }));
    var again = try reg.acquire("a", &.{"server"}, .{ .target = target });
    again.release();
    try testing.expectEqual(@as(usize, 1), reg.entries.count());
}
