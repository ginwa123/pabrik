//! Functional test for the `--static-dir` concurrency defect that kept
//! `tests/functional_ui/code_editor_viewer_ui_test.py` red for a week.
//!
//! SYMPTOM. The UI suite is the only one that boots pabrik with
//! `--static-dir`, so it is the only one that loads the production bundle
//! from pabrik's own static handler. Intermittently, a `GET` for a bundle
//! asset came back with ZERO bytes and a closed connection — the browser
//! reported `net::ERR_EMPTY_RESPONSE`, the entry chunk never ran, the app
//! never mounted, and whichever of the file's tests happened to be loading
//! assets timed out waiting for `[data-testid="code-editor"]`. Three
//! different tests in that one file failed this way across a week, on main
//! and on branches.
//!
//! CAUSE (kabelweb `src/server/event_loop.zig`, pinned by `build.zig.zon`).
//! Every static response is written RAW and its connection is closed right
//! after it — `runStaticServe` owns the conn fd, flips it to BLOCKING,
//! serves, and closes. The reactor's connection scan, however, indexed
//! `conns.items` with the POLL ARRAY SLOT number, and the same tick already
//! mutated `conns.items` before the scan (the listener drain appends, the
//! completion drain removes). A removal shifts the tail down, so a POLLNVAL
//! that belonged to a conn the static worker had just closed was applied to
//! an UNRELATED connection: a brand-new conn was torn down before its
//! request was answered -> zero bytes + close. The same mixup made the loop
//! `recv` on an fd the worker had just made blocking, stalling the reactor
//! for seconds.
//!
//! WHAT THIS PINS. The invariant a client depends on: a request that was
//! actually sent ALWAYS gets a response. A closed-with-zero-bytes connection
//! is the failure, and it needs concurrency (a hijacked handoff racing the
//! accept of a fresh conn) to appear — hence the hammer below. The
//! dependency's own unit-level guard is kabelweb's
//! `event loop: a hijacked conn's closed fd never kills another connection`.
//!
//! THE OTHER HALF OF THE DEFECT — WHY THE PROCESS ITSELF MUST SURVIVE. The
//! same mis-indexed close closes a descriptor that the static pool still
//! owns, so the pool's own `close` lands on a RECYCLED descriptor number.
//! Zig's `Io.Threaded` treats `EBADF` from `close` as
//! `recoverableOsBugDetected()`, which in a Debug build is `unreachable`:
//! it panics `reached unreachable code` and aborts the ENTIRE server —
//! every running agent session with it. That is the crash pabrik's own
//! reporter recorded twelve times in `$TMPDIR/agentic_coding.log`
//! (`std/Io/Threaded.zig closeFd`, victim frames
//! `src/modules/static_files.zig:279`, `:323` and
//! `src/http_static/static_serve.zig:147`). A truncated asset is bad; a
//! dead server is worse, and the zero-byte assertion cannot see it: a
//! response can arrive intact and the process still die on a later close.
//! So the hammer also asserts the child is STILL ALIVE and wrote NO crash
//! report — the process-survival half of the same invariant.
//!
//! WHY IT IS NOT A `h.http(...)` LOOP. `Harness.http` speaks one request per
//! call with its own connection management; the defect lives in the reactor's
//! fd bookkeeping under parallel short-lived connections, so the client here
//! opens a bare `Io.net` stream per request, exactly like the browser's
//! per-asset connections do.

const std = @import("std");
const builtin = @import("builtin");
const testing = std.testing;
const harness = @import("harness.zig");
const Harness = harness.Harness;
const Allocator = std.mem.Allocator;

const Io = std.Io;

const gpa = testing.allocator;
const io = testing.io;

/// The asset every hammer request asks for.
const ASSET = "asset.js";

/// Small, but not empty: a zero-byte response is the failure mode, so the
/// server has to have something to send.
const ASSET_BODY =
    "// static-serve hammer asset\n" ++
    "export const marker = 'STATIC_SERVE_HAMMER_5c21e8';\n";

/// One request per connection: the shape a browser uses for bundle assets.
const REQUEST =
    "GET /" ++ ASSET ++ " HTTP/1.1\r\n" ++
    "Host: 127.0.0.1\r\n" ++
    "Accept: */*\r\n" ++
    "Connection: close\r\n" ++
    "\r\n";

/// How many connections each hammer thread opens.
const REQUESTS_PER_THREAD = 80;

/// Parallel connections. Six is what a browser opens per origin, and it is
/// enough for the hijack handoff to race an accept.
const THREADS = 6;

/// Write `contents` to the absolute `path`, creating/truncating it.
fn writeFileAt(path: []const u8, contents: []const u8) !void {
    var f = try std.Io.Dir.cwd().createFile(io, path, .{});
    defer f.close(io);
    try f.writeStreamingAll(io, contents);
}

/// Give the socket a receive deadline (Python's `s.settimeout(n)`).
///
/// The socket is then read with a raw `std.posix.read`, NOT through
/// `Io.net`'s reader: a deadline turns a silent peer into `EAGAIN`, and
/// `std.Io.Threaded.netReadPosix` panics outright on `EAGAIN` ("programmer bug
/// caused syscall error: AGAIN"). That is the whole reason this suite is
/// POSIX-only — a stalled reactor has to be an assertion, not a panic.
fn armRecvDeadline(handle: std.posix.socket_t, seconds: i64) void {
    const tv = std.posix.timeval{ .sec = @intCast(seconds), .usec = 0 };
    std.posix.setsockopt(
        handle,
        std.posix.SOL.SOCKET,
        std.posix.SO.RCVTIMEO,
        std.mem.asBytes(&tv),
    ) catch {};
}

/// The banner pabrik's crash reporter writes at the head of every report
/// (`src/service/crash_handler.zig::emitCrashReport`). The report goes to
/// the crash log file AND is mirrored to stderr, which the harness captures
/// into `Harness.log_path` — so this banner is observable from the test even
/// when the child died before it could answer another request.
const CRASH_BANNER = "=== CRASH:";

/// Count crash reports in captured child output. Pure — the positive
/// control below pins that it fires on the banner and not on prose.
fn crashReportCount(log: []const u8) usize {
    var n: usize = 0;
    var i: usize = 0;
    while (std.mem.indexOfPos(u8, log, i, CRASH_BANNER)) |at| {
        n += 1;
        i = at + CRASH_BANNER.len;
    }
    return n;
}

/// The harness's captured stdout+stderr for the child, whole.
fn readChildLog(h: *Harness, allocator: Allocator) ![]u8 {
    return std.Io.Dir.cwd().readFileAlloc(io, h.log_path, allocator, .limited(4 << 20)) catch |err| switch (err) {
        error.FileNotFound => try allocator.dupe(u8, ""),
        else => return err,
    };
}

const Hammer = struct {
    port: u16,
    served: std.atomic.Value(u64) = std.atomic.Value(u64).init(0),
    /// Connections that came back with zero bytes. The bug.
    bare_close: std.atomic.Value(u64) = std.atomic.Value(u64).init(0),
};

/// Send one request on a fresh connection and read to EOF.
fn requestOnce(h: *Hammer) void {
    const addr: Io.net.IpAddress = .{ .ip4 = .loopback(h.port) };
    // `.timeout = .none` is mandatory on POSIX: `Io.net.connect` panics when
    // a timeout is requested. The receive deadline below is the real bound.
    var stream = addr.connect(io, .{ .mode = .stream, .timeout = .none }) catch return;
    defer stream.close(io);
    const handle = stream.socket.handle;
    armRecvDeadline(handle, 3);

    {
        // The request goes through `Io.net`'s writer: only the RECEIVE side
        // carries a deadline, so no `EAGAIN` can reach `Io`'s read path.
        var wbuf: [256]u8 = undefined;
        var sw = stream.writer(io, &wbuf);
        sw.interface.writeAll(REQUEST) catch return;
        sw.interface.flush() catch return;
    }

    var buf: [4096]u8 = undefined;
    var total: usize = 0;
    while (total < 1000) {
        // The deadline (or a reset) breaks out with whatever arrived; that is
        // the point — zero bytes is the observation under test.
        const n = std.posix.read(handle, &buf) catch break;
        if (n == 0) break; // orderly EOF
        total += n;
    }

    if (total == 0) {
        _ = h.bare_close.fetchAdd(1, .monotonic);
    } else {
        _ = h.served.fetchAdd(1, .monotonic);
    }
}

fn hammer(h: *Hammer) void {
    for (0..REQUESTS_PER_THREAD) |_| requestOnce(h);
}

// A static asset is never answered with zero bytes, however many connections
// are in flight. This is the invariant the UI suite's bundle load depends on.
test "static_serve_answers_every_request_under_concurrency" {
    // POSIX-only: the client read needs a receive deadline, and the only way
    // to get one is SO_RCVTIMEO + a raw `read` (see `armRecvDeadline`).
    if (comptime builtin.os.tag == .windows) return error.SkipZigTest;
    try harness.requirePabrikBin(io, gpa);

    const scratch = try harness.makeScratchDir(gpa);
    // DEFER ORDER IS LIFO: `free` runs LAST, after the cleanup read it.
    defer gpa.free(scratch);
    defer harness.cleanupExtraDir(io, gpa, scratch);

    const static_dir = try std.fs.path.join(gpa, &.{ scratch, "static-serve-hammer" });
    defer gpa.free(static_dir);
    try std.Io.Dir.cwd().createDirPath(io, static_dir);
    {
        const asset_path = try std.fs.path.join(gpa, &.{ static_dir, ASSET });
        defer gpa.free(asset_path);
        try writeFileAt(asset_path, ASSET_BODY);
    }

    // `extra_args` borrows, so the argv slice must outlive the boot.
    const args = [_][]const u8{ "--static-dir", static_dir };

    var h = try Harness.boot(io, gpa, .{
        .stub_llm_profile = true,
        .extra_args = &args,
    });
    defer h.deinit(io) catch |err| {
        std.debug.print("teardown: {s}\n", .{@errorName(err)});
    };

    // Positive control first: the dir really is being served, so a later
    // all-zero result cannot pass vacuously.
    {
        var r = try h.http(io, .GET, "/" ++ ASSET, .{});
        defer r.deinit();
        if (std.mem.indexOf(u8, r.text(), "STATIC_SERVE_HAMMER_5c21e8") == null) {
            std.debug.print("GET /{s} did not serve the fixture: {s}\n", .{ ASSET, r.body });
            return error.TestUnexpectedResult;
        }
    }

    var state = Hammer{ .port = h.port };
    var threads: [THREADS]std.Thread = undefined;
    for (&threads) |*t| t.* = try std.Thread.spawn(.{}, hammer, .{&state});
    for (&threads) |*t| t.join();

    // Read the child's output BEFORE asserting on anything else: if the
    // server died, the crash report is the evidence and the failure has to
    // quote it (a dead server also makes every later request fail, which
    // would otherwise surface as a confusing "served == 0").
    const child_log = try readChildLog(&h, gpa);
    defer gpa.free(child_log);
    const crashes = crashReportCount(child_log);
    const alive = h.health(io);
    if (crashes != 0 or !alive) {
        std.debug.print(
            "the static-serve hammer KILLED THE SERVER: crashes={d} alive={}\n" ++
                "A Debug build turns the double close into `reached unreachable code`\n" ++
                "(`recoverableOsBugDetected`) and the process aborts, taking every\n" ++
                "running agent session with it.\n",
            .{ crashes, alive },
        );
        if (std.mem.lastIndexOf(u8, child_log, CRASH_BANNER)) |at| {
            const from = if (at > 600) at - 600 else 0;
            std.debug.print("---- last crash report ----\n{s}\n", .{child_log[from..]});
        } else {
            const tail = try h.tailLog(io, gpa, 40);
            defer gpa.free(tail);
            std.debug.print("---- last log lines ----\n{s}\n", .{tail});
        }
        return error.TestUnexpectedResult;
    }

    const served = state.served.load(.monotonic);
    const bare = state.bare_close.load(.monotonic);
    try testing.expect(served > 0);
    if (bare != 0) {
        std.debug.print(
            "static serve closed {d} of {d} connections with ZERO bytes — that is " ++
                "net::ERR_EMPTY_RESPONSE in a browser, and one lost asset stops the " ++
                "production bundle from mounting\n",
            .{ bare, bare + served },
        );
        return error.TestUnexpectedResult;
    }
}

// Positive control for the crash detector: it fires on the reporter's
// banner and stays silent on prose that merely says "CRASH".
test "crashReportCount counts the reporter's banner (positive control)" {
    try testing.expectEqual(@as(usize, 0), crashReportCount(""));
    try testing.expectEqual(@as(usize, 0), crashReportCount("all good\ninfo: serving\n"));
    // Prose, not a banner: a detector without a positive control could pass
    // vacuously by never matching anything.
    try testing.expectEqual(@as(usize, 0), crashReportCount("CRASH: reached unreachable code\n"));
    try testing.expectEqual(
        @as(usize, 1),
        crashReportCount("x\n=== CRASH: received signal ABRT (signal number 6) ===\nbody\n"),
    );
    try testing.expectEqual(
        @as(usize, 2),
        crashReportCount("=== CRASH: a\nbody\n=== CRASH: b\nbody\n"),
    );
}
