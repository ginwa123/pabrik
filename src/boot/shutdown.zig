//! Graceful-shutdown state for the server process (Ctrl+C / SIGTERM). The
//! handler runs IN SIGNAL CONTEXT: it only stores a bool and calls
//! `GinwaServer.shutdown()` (async-signal-safe).

const std = @import("std");
const database = @import("databases").database;
const gserverz = @import("kabelweb").server;
const db_config = @import("db_config.zig");

// Live server pointer the signal handler closes. Set once after
// `GinwaServer.init`; the handler is process-lifetime so it is never cleared.
var shutdown_server: ?*gserverz.GinwaServer = null;
var shutdown_requested: std.atomic.Value(bool) = .init(false);

pub fn handleShutdownSignal() void {
    shutdown_requested.store(true, .seq_cst);
    if (shutdown_server) |gs| gs.shutdown();
}

/// Install the live server pointer; call once after `GinwaServer.init`.
pub fn setServer(gs: *gserverz.GinwaServer) void {
    shutdown_server = gs;
}

/// Clear a previously recorded shutdown (lets `main` start from a known state).
pub fn reset() void {
    shutdown_requested.store(false, .seq_cst);
}

/// True once the signal handler has run.
pub fn isRequested() bool {
    return shutdown_requested.load(.seq_cst);
}

/// Log the live SQLite connection's settings at boot, so a future
/// "database is locked" report carries the ACTUAL configuration.
/// No-op on a postgres build (that backend has no pragmas to read back).
pub fn logSqliteConfig(allocator: std.mem.Allocator, db: *database.Db) void {
    if (database.backend_is_postgres) return;
    const applied = db.readConfig(allocator) catch |err| {
        std.log.warn("sqlite: could not read back connection config ({s})", .{@errorName(err)});
        return;
    };
    std.log.info("sqlite: journal_mode={s} busy_timeout={d}ms synchronous={d} wal_autocheckpoint={d} journal_size_limit={d}", .{
        applied.journalMode(),
        applied.busy_timeout_ms,
        applied.synchronous,
        applied.wal_autocheckpoint_pages,
        applied.journal_size_limit_bytes,
    });
    // The reader pool is a separate set of decisions from the pragmas, and
    // the only warning it produces ("reader pool unavailable (PoolExhausted);
    // serving this read on the write connection") is unreadable without them.
    var pool_buf: [128]u8 = undefined;
    const pool_line = db_config.describeReaderPool(&pool_buf) catch return;
    std.log.info("sqlite: {s}", .{pool_line});
    // The two knobs that decide how much RAM the pool can commit to, logged
    // from the LIVE pool rather than from `db_config.best`, so a `--db-*`
    // override is visible in the boot log instead of only in the source.

    // `cache_size_kb` is per connection and the pool is elastic, so the
    // number that matters is the product with the concurrency reached.
    if (!database.backend_is_postgres) {
        const live = db.pool.cfg;
        std.log.info(
            "sqlite: page_cache={d}KiB/conn mmap={d}MiB/conn idle_reap={d}ms readers_now={d}",
            .{
                live.cache_size_kb,
                live.mmap_size_bytes / (1024 * 1024),
                live.max_idle_time_ms,
                db.pool.count(),
            },
        );
    }
}

test "shutdown: signal with no server only sets the requested flag" {
    reset();
    try std.testing.expect(!isRequested());
    handleShutdownSignal();
    try std.testing.expect(isRequested());
    reset();
}

test "shutdown: reset clears a previously requested shutdown" {
    handleShutdownSignal();
    try std.testing.expect(isRequested());
    reset();
    try std.testing.expect(!isRequested());
}
