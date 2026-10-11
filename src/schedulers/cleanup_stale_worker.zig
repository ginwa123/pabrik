const std = @import("std");
const pabrikcore = @import("pabrikcore");
const sqlite = pabrikcore.sqlite;
// Route `delete_worker` through `pabrikcore` (the
// `root` module) instead of @import'ing it directly. The exe
// module compiles `main.zig` which imports `cleanup_stale_worker.zig`;
// if we reach into `src/agentic_loop/` directly, those
// files end up in TWO modules (root via root.zig → mod.zig AND main
// via cleanup_stale_worker.zig) and Zig's "file exists in two modules"
// error fires. The exe module already has `pabrikcore` as an import
// (per build.zig), so route through it.
const delete_worker_mod = pabrikcore.ai_mod.delete_worker;
const event_bus_mod = pabrikcore.event_bus;
const logger_mod = pabrikcore.loggermod;
const testing = std.testing;

/// How old `worker.last_activity_nano` must be (in seconds) before the
/// cleanup tick considers the row stale. 10 minutes per the user spec.
pub const stale_threshold_seconds: i64 = 600;

pub const CleanupStaleWorkerInput = struct {
    allocator: std.mem.Allocator,
    db: *sqlite.SqliteBackend,
    logger: ?*logger_mod.Logger,
    event_bus: ?*event_bus_mod.EventBus,
    now_unix: i64,
    threshold_seconds: i64 = stale_threshold_seconds,
};

pub const CleanupResult = struct {
    stale_count: usize = 0,
    deleted_count: usize = 0,
};

/// Delete every worker row whose `last_activity_nano` is older than
/// `now_unix - threshold_seconds` (or NULL). Reuses `deleteWorker` so
/// the SSE `action="deleted"` event fires and the UI updates.
/// The worker row is the single source of truth for "is this session
/// running" (see `is_worker_running.zig`), so deleting the row is the
/// whole cleanup — there is no in-memory registry to clear.
///
/// Per-row isolation: if one row's `deleteWorker` fails, log via
/// `logger.?errFmt` and continue to the next row — the cron tick
/// must NOT abort the whole batch on a single bad row.
pub fn cleanupStaleWorkers(input: CleanupStaleWorkerInput) anyerror!CleanupResult {
    const allocator = input.allocator;
    const db = input.db;
    const event_bus = input.event_bus;
    const logger = input.logger;

    var result = CleanupResult{};
    const cutoff = input.now_unix - input.threshold_seconds;
    const cutoff_str = try std.fmt.allocPrint(allocator, "{d}", .{cutoff});

    const sql =
        \\SELECT id
        \\FROM worker
        \\WHERE last_activity_nano IS NULL OR last_activity_nano < ?
    ;

    var rows = try db.query(allocator, sql, &.{cutoff_str});
    defer rows.deinit();

    while (try rows.next()) |row| {
        defer row.deinit(allocator);

        const id = row.values[0];
        result.stale_count += 1;

        // Delete the worker row + emit the SSE `action="deleted"`
        // event. `deleteWorker` uses `id` as the primary key, which
        // matches the worker.id column (== session_id in practice
        // — see update_worker.zig:503).
        delete_worker_mod.deleteWorker(.{
            .allocator = allocator,
            .db = db,
            .logger = logger,
            .session_id = id,
            .event_bus = event_bus,
            .is_emit_sse = true,
        }) catch |err| {
            if (logger) |log| {
                log.errFmt(
                    "[cleanup_stale_worker] deleteWorker failed for session_id={s}: {s}\n",
                    .{ id, @errorName(err) },
                );
            }
            continue;
        };

        result.deleted_count += 1;
    }

    return result;
}

/// Cron callback. Signature is fixed by
/// `cronjob_manager.register` (`kabelweb repo src/server/cronjob_manager.zig:87`):
/// `*const fn (ctx: ?*anyopaque, now_unix: i64) void`.
///
/// Returns `void` (not `!void`) — DB errors are caught and logged
/// inside, never propagated. The cron thread MUST NOT panic.
pub fn handle(ctx: ?*anyopaque, now_unix: i64) void {
    _ = ctx;

    const di = pabrikcore.getSingleton() catch return;
    const allocator = di.allocator;
    const logger = di.logger;

    // Per-tick arena — all SQL allocations live for the duration of
    // the cleanupStaleWorkers call. Cheaper than per-row alloc/free.
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const result = cleanupStaleWorkers(.{
        .allocator = a,
        .db = di.db,
        .logger = logger,
        .event_bus = di.event_bus,
        .now_unix = now_unix,
    }) catch |err| {
        logger.errFmt("[cleanup_stale_worker] tick failed: {s}\n", .{@errorName(err)});
        return;
    };

    logger.infoFmt(
        "[cleanup_stale_worker] tick summary: stale={d} deleted={d}",
        .{ result.stale_count, result.deleted_count },
    );
}

// ─── Tests ───────────────────────────────────────────────────────────────
//
// Tests are intentionally INLINE in this file (no separate _test.zig),
// matching the project's existing convention for files that have both
// impl + tests (delete_worker.zig, update_worker.zig, is_worker_running.zig).
// The file is aggregated into the test module graph via
// src/schedulers/test_runner.zig → src/root.zig:612.

const TestCtx = struct {
    db: sqlite.SqliteBackend,
    threaded: std.Io.Threaded,
    arena: std.heap.ArenaAllocator,

    fn deinit(self: *TestCtx) void {
        self.db.deinit();
        self.threaded.deinit();
        self.arena.deinit();
    }
};

fn setupCtx() !TestCtx {
    const alloc = testing.allocator;
    var arena = std.heap.ArenaAllocator.init(alloc);
    errdefer arena.deinit();
    const arena_alloc = arena.allocator();

    var threaded = std.Io.Threaded.init(alloc, .{});
    errdefer threaded.deinit();
    const io = threaded.io();

    var db: sqlite.SqliteBackend = .{};
    errdefer db.deinit();
    try db.init(io, ":memory:");

    // Minimal schema matching the production worker table (after
    // migration 075). We use the column types from
    // src/migrations/migration.zig:294-330 + 3198-3218.
    try db.exec(arena_alloc,
        \\CREATE TABLE worker (
        \\    id TEXT PRIMARY KEY,
        \\    session_id TEXT NOT NULL,
        \\    working_directory TEXT,
        \\    last_activity_nano INTEGER,
        \\    last_activity_description TEXT,
        \\    created_at DATETIME DEFAULT CURRENT_TIMESTAMP
        \\)
    , &.{});

    return .{
        .db = db,
        .threaded = threaded,
        .arena = arena,
    };
}

/// Insert a worker row with an explicit `last_activity_nano` value
/// (passed as a string — SQLite type-coerces into INTEGER). Returns
/// the row's id for convenience.
fn seedWorker(
    db: *sqlite.SqliteBackend,
    arena_alloc: std.mem.Allocator,
    id: []const u8,
    session_id: []const u8,
    last_activity_nano: []const u8,
) !void {
    const sql =
        \\INSERT INTO worker (id, session_id, working_directory, last_activity_nano)
        \\VALUES (?, ?, '/tmp', ?)
    ;
    try db.exec(arena_alloc, sql, &.{ id, session_id, last_activity_nano });
}

/// Convenience: returns the row count for the given id (0 or 1).
fn rowExists(
    db: *sqlite.SqliteBackend,
    arena_alloc: std.mem.Allocator,
    id: []const u8,
) !usize {
    var rows = try db.query(arena_alloc, "SELECT 1 FROM worker WHERE id = ?", &.{id});
    defer rows.deinit();
    var count: usize = 0;
    while (try rows.next()) |row| {
        defer row.deinit(arena_alloc);
        count += 1;
    }
    return count;
}

test "cleanupStaleWorkers deletes a worker whose last_activity_nano is older than the threshold" {
    var ctx = try setupCtx();
    defer ctx.deinit();
    const a = ctx.arena.allocator();
    const now: i64 = 1_000_000;

    try seedWorker(&ctx.db, a, "w_old", "s_old", "100"); // 990_000 seconds before now
    try seedWorker(&ctx.db, a, "w_fresh", "s_fresh", "999_500"); // 500 seconds before now

    _ = try cleanupStaleWorkers(.{
        .allocator = a,
        .db = &ctx.db,
        .logger = null,
        .event_bus = null,
        .now_unix = now,
    });

    try testing.expectEqual(@as(usize, 0), try rowExists(&ctx.db, a, "w_old"));
    try testing.expectEqual(@as(usize, 1), try rowExists(&ctx.db, a, "w_fresh"));
}

test "cleanupStaleWorkers keeps a worker whose last_activity_nano is fresher than the threshold" {
    var ctx = try setupCtx();
    defer ctx.deinit();
    const a = ctx.arena.allocator();
    const now: i64 = 1_000_000;

    // 599 seconds before now — strictly FRESHER than the 600-second
    // threshold (uses `<`, not `<=`).
    try seedWorker(&ctx.db, a, "w_fresh", "s_fresh", "999_401");

    _ = try cleanupStaleWorkers(.{
        .allocator = a,
        .db = &ctx.db,
        .logger = null,
        .event_bus = null,
        .now_unix = now,
    });

    try testing.expectEqual(@as(usize, 1), try rowExists(&ctx.db, a, "w_fresh"));
}

test "cleanupStaleWorkers treats NULL last_activity_nano as stale (pre-migration-075 rows)" {
    var ctx = try setupCtx();
    defer ctx.deinit();
    const a = ctx.arena.allocator();
    const now: i64 = 1_000_000;

    // NULL last_activity_nano (pre-migration-075 rows may look like this)
    try ctx.db.exec(
        a,
        "INSERT INTO worker (id, session_id, last_activity_nano) VALUES ('w_null', 's_null', NULL)",
        &.{},
    );

    _ = try cleanupStaleWorkers(.{
        .allocator = a,
        .db = &ctx.db,
        .logger = null,
        .event_bus = null,
        .now_unix = now,
    });

    try testing.expectEqual(@as(usize, 0), try rowExists(&ctx.db, a, "w_null"));
}

test "cleanupStaleWorkers is a no-op when the worker table is empty" {
    var ctx = try setupCtx();
    defer ctx.deinit();
    const a = ctx.arena.allocator();

    const result = try cleanupStaleWorkers(.{
        .allocator = a,
        .db = &ctx.db,
        .logger = null,
        .event_bus = null,
        .now_unix = 1_000_000,
    });

    try testing.expectEqual(@as(usize, 0), result.stale_count);
    try testing.expectEqual(@as(usize, 0), result.deleted_count);
}

test "cleanupStaleWorkers processes multiple stale workers in one call" {
    var ctx = try setupCtx();
    defer ctx.deinit();
    const a = ctx.arena.allocator();
    const now: i64 = 1_000_000;

    try seedWorker(&ctx.db, a, "w_a", "s_a", "100");
    try seedWorker(&ctx.db, a, "w_b", "s_b", "200");
    try seedWorker(&ctx.db, a, "w_c", "s_c", "300");
    try seedWorker(&ctx.db, a, "w_fresh", "s_fresh", "999_500");

    const result = try cleanupStaleWorkers(.{
        .allocator = a,
        .db = &ctx.db,
        .logger = null,
        .event_bus = null,
        .now_unix = now,
    });

    try testing.expectEqual(@as(usize, 3), result.stale_count);
    try testing.expectEqual(@as(usize, 3), result.deleted_count);
    try testing.expectEqual(@as(usize, 0), try rowExists(&ctx.db, a, "w_a"));
    try testing.expectEqual(@as(usize, 0), try rowExists(&ctx.db, a, "w_b"));
    try testing.expectEqual(@as(usize, 0), try rowExists(&ctx.db, a, "w_c"));
    try testing.expectEqual(@as(usize, 1), try rowExists(&ctx.db, a, "w_fresh"));
}

// ─── Boundary tests ─────────────────────────────────────────────────────

test "cleanupStaleWorkers does NOT delete a worker whose last_activity_nano is exactly at the threshold" {
    var ctx = try setupCtx();
    defer ctx.deinit();
    const a = ctx.arena.allocator();
    // now_unix - threshold_seconds = 1000 - 600 = 400 (boundary)
    // `<` means 400 is NOT considered stale.
    const now: i64 = 1000;
    try seedWorker(&ctx.db, a, "w_boundary", "s_boundary", "400");

    _ = try cleanupStaleWorkers(.{
        .allocator = a,
        .db = &ctx.db,
        .logger = null,
        .event_bus = null,
        .now_unix = now,
    });

    try testing.expectEqual(@as(usize, 1), try rowExists(&ctx.db, a, "w_boundary"));
}

test "cleanupStaleWorkers keeps a fresh worker row" {
    var ctx = try setupCtx();
    defer ctx.deinit();
    const a = ctx.arena.allocator();
    const now: i64 = 1_000_000;

    // Fresh row (last_activity close to now) — the helper keeps it.
    try seedWorker(&ctx.db, a, "w_fresh", "s_fresh", "999_500");

    _ = try cleanupStaleWorkers(.{
        .allocator = a,
        .db = &ctx.db,
        .logger = null,
        .event_bus = null,
        .now_unix = now,
    });

    try testing.expectEqual(@as(usize, 1), try rowExists(&ctx.db, a, "w_fresh"));
}

// ─── Failure-tolerance test ─────────────────────────────────────────────

test "cleanupStaleWorkers returns the DB error when the worker table itself is missing" {
    // Simulate the "table does not exist" failure path by creating
    // a DB with NO worker table and confirming the helper propagates
    // the error rather than panicking. The cron wrapper (handle)
    // is responsible for catching + logging — the helper just
    // surfaces the error.
    //
    // Uses an arena (not std.testing.allocator) so the
    // allocPrint'd cutoff_str from the production code path doesn't
    // trigger a leak in the testing allocator — per the review
    // feedback, the production code intentionally omits the
    // per-allocation `defer free` (the caller's arena frees it).
    const alloc = testing.allocator;
    var arena = std.heap.ArenaAllocator.init(alloc);
    defer arena.deinit();
    const a = arena.allocator();

    var threaded = std.Io.Threaded.init(alloc, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var db: sqlite.SqliteBackend = .{};
    defer db.deinit();
    try db.init(io, ":memory:");
    // NO CREATE TABLE — the query will fail with "no such table".

    const result = cleanupStaleWorkers(.{
        .allocator = a,
        .db = &db,
        .logger = null,
        .event_bus = null,
        .now_unix = 1_000_000,
    });

    // We don't pin the specific SqliteBackend Error variant here —
    // the SqliteBackend maps missing-table to PrepareFailed
    // (Sqlite.zig:568) which the helper propagates verbatim. The
    // cron wrapper (handle) is responsible for catching + logging.
    try testing.expectError(error.PrepareFailed, result);
}
