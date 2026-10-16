//! Cronjob - close the SQLite readers the pool has stopped using.
//! The pool is elastic and uncapped, so a burst leaves readers open; this is
//! the tick that gives that memory back. See `reapIdleReaders`.

const std = @import("std");
const pabrikcore = @import("pabrikcore");
const database = pabrikcore.database;
const db_config = pabrikcore.boot_db_config;

const testing = std.testing;

/// Close every pooled reader that has been idle past the configured age, and
/// report how many were closed. Never fails: a pool that cannot be reaped is
/// a pool that keeps its memory, which beats a crashed server.
pub fn reapIdleReaders(db: *database.Db, io: std.Io) usize {
    // WHY A TICK AT ALL. The pool reaps inline on `release` and on the
    // `claim` slow path, so with no traffic nothing ever shrinks it:
    // measured on the real 4.6 GB agent.db, a 32-way burst left 24 readers

    // (49 fds) open and ~160 MB of RSS more than 100 s after it ended.
    //
    // Postgres has no reader pool to reap, so this is a no-op there - the

    // same shape `openWithConfig`'s ignored `sqlite_config` uses to stay
    // callable from either build.
    if (database.backend_is_postgres) return 0;
    const before = db.pool.count();
    db.pool.reapIdle(io);
    const after = db.pool.count();
    // `count` is monotone except for reaping, so this cannot wrap; the
    // subtraction is the number of connections the pass closed.
    return before - after;
}

/// The cron callback. Registered on the 1 s cron in `main.zig`; the interval
/// it actually enforces is `db_config.reap_interval_ms`, checked against the
/// last time this ran rather than the cron's own cadence.
var last_reap_ms: i64 = 0;

pub fn handle(ctx: ?*anyopaque, now_unix: i64) void {
    _ = ctx;

    const di = pabrikcore.getSingleton() catch return;
    const io = di.io;

    // The cron fires once a minute; this is what lets the tick be tuned
    // independently of the cron's cadence. `now_unix` is the cron's MATCH
    // time, not the wall clock, so it is minute-aligned and monotonic.
    const now_ms = @as(i64, @intCast(now_unix)) * std.time.ms_per_s;
    if (last_reap_ms != 0 and now_ms - last_reap_ms < @as(i64, @intCast(db_config.reap_interval_ms))) {
        return;
    }
    last_reap_ms = now_ms;

    const reaped = reapIdleReaders(di.db, io);
    // Logged unconditionally, not only when something was closed: a tick
    // that reports "closed 0" is what tells an operator the pool is at its
    // floor, which is the difference between "working" and "not running".
    di.logger.infoFmt(
        "[reap_idle_readers] closed {d} idle reader(s); {d} remain",
        .{ reaped, di.db.pool.count() },
    );
}

/// Reset the tick's memory of when it last ran. Test-only: without it a
/// second test in the same process would see the first test's timestamp and
/// return early, so the behaviour under test would never run.
pub fn resetForTest() void {
    last_reap_ms = 0;
}

// ─── Test helpers ────────────────────────────────────────────────────────

/// A fresh database path inside a per-test temp directory. WHY NOT `/tmp/...`: that directory does not exist on
/// Windows, so `sqlite3_open` fails with `FileNotFound` and these tests go red on the Windows runner while passing
/// on Linux and macOS. `testing.tmpDir` is the portable equivalent and cleans itself up.
fn freshDbPath(dir: *testing.TmpDir, name: []const u8) ![:0]const u8 {
    var dir_buf: [std.fs.max_path_bytes]u8 = undefined;
    const dir_len = try dir.dir.realPath(testing.io, &dir_buf);
    const joined = try std.fs.path.join(testing.allocator, &.{ dir_buf[0..dir_len], name });
    defer testing.allocator.free(joined);
    return testing.allocator.dupeZ(u8, joined);
}

/// Open a fresh database at `path` with `read_conns` warm readers and a
/// 20 ms idle age, so a test does not wait the 30 s the server uses.
fn openTestDb(io: std.Io, path: [:0]const u8, read_conns: usize) !database.Db {
    var db: database.Db = .{};
    errdefer db.deinit();
    // The allocator is supplied so `testing.allocator` can see the pool's
    // connections: a reader allocated from the default allocator leaks
    // invisibly, and a leaked reader is exactly the bug this file is about.
    try database.openWithConfig(&db, io, .{ .sqlite_path = path }, .{
        .read_conns = read_conns,
        .max_idle_time_ms = 20,
        .allocator = testing.allocator,
    });
    return db;
}

/// Hold `n` reads open at once, which is what forces the pool to open one
/// reader per read - the same shape as concurrent requests in the server.
fn holdReads(db: *database.Db, allocator: std.mem.Allocator, held: []database.Db.Rows) !void {
    for (held) |*rows| {
        rows.* = try db.query(allocator, "SELECT v FROM t WHERE id = ?", &.{"1"});
    }
}

/// Wait past the 20 ms idle age the test databases are opened with.
fn outliveIdleAge(io: std.Io) void {
    std.Io.sleep(io, .{ .nanoseconds = 60 * std.time.ns_per_ms }, .awake) catch
        @panic("could not sleep past the idle age");
}

test "reaping closes readers the pool opened for a burst" {
    // The behaviour this whole file is for: a burst grows the pool, and the
    // tick has to bring it back down to the warm floor afterwards.
    resetForTest();
    const io = testing.io;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const path = try freshDbPath(&tmp, "burst.db");
    defer testing.allocator.free(path);

    var db = try openTestDb(io, path, 1);
    defer db.deinit();

    const allocator = testing.allocator;
    try db.exec(allocator, "CREATE TABLE t (id INTEGER PRIMARY KEY, v TEXT)", &.{});
    try db.exec(allocator, "INSERT INTO t (id, v) VALUES (1, 'x')", &.{});

    var held: [6]database.Db.Rows = undefined;
    try holdReads(&db, allocator, &held);
    // Every claim is outstanding while the iterators are live, which is the
    // state a burst leaves behind.
    try testing.expectEqual(@as(usize, held.len), db.outstandingClaims());
    const grown = db.pool.count();
    try testing.expect(grown > db_config.best.read_conns);

    for (&held) |*rows| rows.deinit();

    // Freshly released: nothing is old enough yet, so a tick right now must
    // NOT close anything. This is the guard that stops the reaper from
    // yanking a reader out from under a read that is about to reuse it.
    try testing.expectEqual(@as(usize, 0), reapIdleReaders(&db, io));
    try testing.expectEqual(grown, db.pool.count());

    // Past the idle age, one tick closes everything above the warm floor.
    outliveIdleAge(io);
    const reaped = reapIdleReaders(&db, io);
    try testing.expect(reaped > 0);
    // Never below the warm floor: the pool must keep the readers it opens at
    // boot, or the next burst pays to reopen them.
    try testing.expectEqual(db_config.best.read_conns, db.pool.count());
    // Every claim was released, so nothing is leaked.
    try testing.expectEqual(@as(usize, 0), db.outstandingClaims());
}

test "reaping leaves the warm floor open" {
    // A pool at its floor has nothing to give back, and must not be emptied:
    // `read_conns` readers exist so the first burst does not pay to open them.
    resetForTest();
    const io = testing.io;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const path = try freshDbPath(&tmp, "floor.db");
    defer testing.allocator.free(path);

    var db = try openTestDb(io, path, 2);
    defer db.deinit();

    try testing.expectEqual(@as(usize, 2), db.pool.count());

    // Well past the idle age: the two warm readers are the oldest things in
    // the pool, and the reaper must still leave them open.
    outliveIdleAge(io);
    try testing.expectEqual(@as(usize, 0), reapIdleReaders(&db, io));
    try testing.expectEqual(@as(usize, 2), db.pool.count());
}

test "a read still works after the pool has been reaped" {
    // The regression that matters: reaping closes connections, and a pool
    // that handed out a stale index afterwards would serve the wrong
    // connection or crash. Prove the pool is still usable.
    resetForTest();
    const io = testing.io;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const path = try freshDbPath(&tmp, "reuse.db");
    defer testing.allocator.free(path);

    var db = try openTestDb(io, path, 1);
    defer db.deinit();

    const allocator = testing.allocator;
    try db.exec(allocator, "CREATE TABLE t (id INTEGER PRIMARY KEY, v TEXT NOT NULL)", &.{});
    try db.exec(allocator, "INSERT INTO t (id, v) VALUES (1, 'before')", &.{});

    // Grow, release, wait past the idle age, then reap.
    var held: [4]database.Db.Rows = undefined;
    try holdReads(&db, allocator, &held);
    for (&held) |*rows| rows.deinit();
    outliveIdleAge(io);
    const reaped = reapIdleReaders(&db, io);
    try testing.expect(reaped > 0);

    // Write, then read through whatever the pool hands back now.
    try db.exec(allocator, "UPDATE t SET v = 'after' WHERE id = 1", &.{});
    var row = try db.queryRow(allocator, "SELECT v FROM t WHERE id = ?", &.{"1"});
    defer row.deinit(allocator);
    try testing.expectEqualStrings("after", row.values[0]);
    try testing.expectEqual(@as(usize, 0), db.outstandingClaims());
}
