//! Cronjob - close the SQLite readers the pool has stopped using.
//! The pool is elastic and uncapped, so a burst leaves readers open; this is
//! the tick that gives that memory back. Interval owned by ruangsql's pool.

const pabrikcore = @import("pabrikcore");
const database = pabrikcore.database;

/// The cron callback. Registered on the 1 s cron in `main.zig`.
pub fn handle(ctx: ?*anyopaque, now_unix: i64) void {
    _ = ctx;
    _ = now_unix;

    const di = pabrikcore.getSingleton() catch return;
    const io = di.io;

    // Postgres has no reader pool to reap, so this is a no-op there - the
    // same shape `openWithConfig`'s ignored `sqlite_config` uses to stay
    // callable from either build.
    if (database.backend_is_postgres) {
        di.logger.infoFmt("[reap_idle_readers] closed 0 idle reader(s); 0 remain", .{});
        return;
    }

    const before = di.db.pool.count();
    // The pool now owns the interval: `reapIdleThrottled` skips the pass
    // when one ran inside `reap_interval_ms`, so this can fire on any
    // cadence without re-scanning an idle list that cannot have changed.
    di.db.pool.reapIdleThrottled(io);
    const after = di.db.pool.count();
    // `count` is monotone except for reaping, so this cannot wrap; the
    // subtraction is the number of connections the pass closed.
    const reaped = before - after;
    // Logged unconditionally, not only when something was closed: a tick
    // that reports "closed 0" is what tells an operator the pool is at its
    // floor, which is the difference between "working" and "not running".
    di.logger.infoFmt(
        "[reap_idle_readers] closed {d} idle reader(s); {d} remain",
        .{ reaped, after },
    );
}
