// Functional: macOS's descriptor default must not turn a pooled SQLite read
// into a 5-second wait.
//
// WHY THIS TEST EXISTS. The `databases` package derives its reader-pool
// ceiling from the process's soft `RLIMIT_NOFILE`:
//
//     readerCapForSoftLimit(soft) = (soft - headroom) / FDS_PER_READER(2)
//
// macOS hands a process a soft limit of **256**, and that used to collide with
// `FD_HEADROOM` (256): the ceiling collapsed to **1**, so the elastic pool
// could never open a second reader past its warm floor, and every read that
// arrived while that one reader was busy burned the whole `reader_wait_ms`
// budget before falling back to the write connection:
//
//     warning: sqlite: reader pool unavailable after waiting 5000ms
//              (PoolExhausted); serving this read on the write connection
//
// ruangsql#9 scaled the reserve (`min(FD_HEADROOM, soft / 2)`), so 256 now
// funds 64 readers. This suite boots the REAL binary with the REAL macOS
// default and pins the observable end of that: the read latency on the wire,
// and a boot log whose `fd_backstop` is anything above the warm floor.
//
// The pre-fix negative control, measured through this harness with the old
// pin: `GET /api/llm/session` = 5.001 s and `fd_backstop=1`.

const std = @import("std");
const builtin = @import("builtin");
const testing = std.testing;
const harness = @import("harness.zig");
const Harness = harness.Harness;
const gpa = testing.allocator;
const io = testing.io;

/// macOS's default soft `RLIMIT_NOFILE` for a shell-launched process. Also
/// exactly the value `FD_HEADROOM` used to be, which is why it collapsed.
const MACOS_SOFT_NOFILE: u64 = 256;

/// The pool's warm floor. `read_conns = 1` in `src/boot/db_config.zig`, so a
/// ceiling of 1 is the collapsed state — no reader can ever be added.
const WARM_FLOOR: u64 = 1;

/// Read `fd_backstop=N` out of the boot log, or null when the line is absent.
fn fdBackstop(log: []const u8) ?u64 {
    const key = "fd_backstop=";
    const at = std.mem.indexOf(u8, log, key) orelse return null;
    var end = at + key.len;
    while (end < log.len and std.ascii.isDigit(log[end])) : (end += 1) {}
    if (end == at + key.len) return null;
    return std.fmt.parseInt(u64, log[at + key.len .. end], 10) catch null;
}

test "fd limit: macOS's 256 descriptor default still serves a pooled read fast" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;
    try harness.requirePabrikBin(io, gpa);

    var h = try Harness.boot(io, gpa, .{ .no_file_limit = MACOS_SOFT_NOFILE });
    defer h.deinit(io) catch |err| {
        std.debug.print("teardown: {s}\n", .{@errorName(err)});
    };

    // `GET /api/llm/session` is a pooled read. On a collapsed pool it takes
    // exactly `reader_wait_ms` (5000 ms) before degrading to the write
    // connection — that is the measured pre-fix number, not a guess.
    const started = std.Io.Timestamp.now(io, .awake).toMilliseconds();
    var r = try h.http(io, .GET, "/api/llm/session", .{ .expect = &.{200} });
    r.deinit();
    const took_ms = std.Io.Timestamp.now(io, .awake).toMilliseconds() - started;

    try testing.expect(took_ms < 1_000);

    // Latency alone could also be satisfied by a runner that was never
    // fd-starved — the harness forces 256, so it cannot be, but the boot log
    // is what proves WHICH ceiling that budget produced.
    const log = try h.tailLog(io, gpa, 400);
    defer gpa.free(log);
    const backstop = fdBackstop(log) orelse return error.TestUnexpectedResult;
    try testing.expect(backstop > WARM_FLOOR);
    // And the pool never had to fall back.
    try testing.expect(std.mem.indexOf(u8, log, "reader pool unavailable") == null);
}
