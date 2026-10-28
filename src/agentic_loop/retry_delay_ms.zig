const std = @import("std");
const testing = std.testing;
const builtin = @import("builtin");
const pabrikcore = @import("pabrikcore");
const test_db = pabrikcore.test_db;
const isWorkerCancelled = @import("is_worker_cancelled.zig").isWorkerCancelled;

const logger_mod = pabrikcore.loggermod;
const sqlite = pabrikcore.sqlite;
const database = pabrikcore.database;
const IsWorkerCancelledInput = @import("is_worker_cancelled.zig").IsWorkerCancelledInput;

// Portable sleep helper. We can't use std.c.timespec directly because it's
// broken on Windows in Zig 0.16 (see test_sleep.zig for the upstream
// analysis).
extern "kernel32" fn Sleep(dw_milliseconds: u32) callconv(.winapi) void;

const WorkflowNanoSleepTimespec = extern struct {
    sec: c_long,
    nsec: c_long,
};
extern "c" fn nanosleep(req: *const WorkflowNanoSleepTimespec, rem: ?*WorkflowNanoSleepTimespec) c_int;

fn sleepChunk(chunk_ms: u32) void {
    if (comptime builtin.os.tag == .windows) {
        // Win32 Sleep takes a DWORD (u32) of milliseconds. Saturate
        // at u32 max so a huge chunk_ms doesn't wrap to 0.
        const ms_dword: u32 = std.math.cast(u32, chunk_ms) orelse std.math.maxInt(u32);
        Sleep(ms_dword);
    } else {
        const ts = WorkflowNanoSleepTimespec{
            .sec = 0,
            // Explicit c_long cast — `chunk_ms * std.time.ns_per_ms` produces
            // a `u32` (chunk_ms's type) which the linker can't coerce to
            // c_long on Windows (where c_long=i32).
            .nsec = @as(c_long, @intCast(chunk_ms * std.time.ns_per_ms)),
        };
        _ = nanosleep(&ts, null);
    }
}

pub const RetryDelayMsInput = struct {
    allocator: std.mem.Allocator,
    delay_ms: u32,
    db: *database.Db,
    session_id: []const u8,
    io: std.Io,
    logger: *logger_mod.Logger,
};

pub fn retryDelayMs(
    obj: RetryDelayMsInput,
) bool {
    const allocator = obj.allocator;
    const delay_ms = obj.delay_ms;
    const db = obj.db;
    const session_id = obj.session_id;
    const io = obj.io;
    const logger = obj.logger;

    if (delay_ms == 0) return true;

    const deadline_ns: i96 = std.Io.Clock.now(.real, io).nanoseconds +
        @as(i96, @intCast(delay_ms)) * std.time.ns_per_ms;

    while (true) {
        // Cancellation check — same shape as the loop-top check at
        // workflow.zig:276 so the cancel UX is consistent.
        if (isWorkerCancelled(IsWorkerCancelledInput{
            .allocator = allocator,
            .db = db,
            .session_id = session_id,
        })) {
            const now_ns = std.Io.Clock.now(.real, io).nanoseconds;
            const remaining_ns: i96 = @max(deadline_ns - now_ns, 0);
            const remaining_ms: u32 = @intCast(@divFloor(remaining_ns, std.time.ns_per_ms));
            logger.infoFmt(
                "Retry delay interrupted by worker cancellation: session_id={s} remaining={d}ms",
                .{ session_id, remaining_ms },
            );
            return false;
        }
        if (std.Io.Clock.now(.real, io).nanoseconds >= deadline_ns) return true;

        const now_ns = std.Io.Clock.now(.real, io).nanoseconds;
        const remaining_ns: i96 = @max(deadline_ns - now_ns, 0);
        const remaining_ms: u32 = @intCast(@divFloor(
            remaining_ns,
            std.time.ns_per_ms,
        ));
        const chunk_ms: u32 = if (remaining_ms > 50) 50 else remaining_ms;

        sleepChunk(chunk_ms);
    }
}

fn setupDb() !struct {
    db: database.Db,
    threaded: std.Io.Threaded,
} {
    const alloc = testing.allocator;
    var threaded = std.Io.Threaded.init(alloc, .{});
    errdefer threaded.deinit();
    const io = threaded.io();
    var db: database.Db = .{};
    errdefer db.deinit();
    try test_db.openMemory(&db, io);
    try db.exec(alloc, "CREATE TABLE workers (id TEXT PRIMARY KEY)", &.{});
    return .{ .db = db, .threaded = threaded };
}

fn teardownDb(s: *@TypeOf(setupDb() catch @panic("setupDb failed in the retry_delay_ms test fixture"))) void {
    s.db.deinit();
    s.threaded.deinit();
}

test "retryDelayMs does not panic over 200 calls with delay_ms = 1 (race-window stress)" {
    if (builtin.mode != .Debug) return error.SkipZigTest;

    var s = try setupDb();
    defer teardownDb(&s);
    const alloc = testing.allocator;

    var lg = logger_mod.Logger.init(alloc, std.testing.io, .{});
    defer lg.deinit();

    var i: usize = 0;
    while (i < 200) : (i += 1) {
        const result = retryDelayMs(.{
            .allocator = alloc,
            .delay_ms = 1,
            .db = &s.db,
            .session_id = "race_test_session",
            .io = s.threaded.io(),
            .logger = &lg,
        });
        try testing.expect(result == true);
    }
}
