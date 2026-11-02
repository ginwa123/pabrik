//! The 30-day retention pass over `logs`, the table `POST /api/logs` writes to.
//! It is a debugging aid, not an audit log: on the live database 96% of its rows
//! were warn-level frontend noise and 597 MB of its 600 MB of message text was
//! past this window.

const std = @import("std");
const pabrikcore = @import("pabrikcore");
const test_db = pabrikcore.test_db;
const database = pabrikcore.database;
const loggermod = pabrikcore.loggermod;
const reclaim = pabrikcore.boot_db_reclaim;
const testing = std.testing;

pub const retention_days: i64 = 30;

/// Rows per `DELETE`. One statement over 45,000 rows holds the write lock for as
/// long as it takes to walk them; 500 at a time keeps every lock short enough for
/// a live request to get in between batches.
pub const batch_rows: usize = 500;

/// Ceiling on batches per tick, so a backlog is worked down over several ticks
/// instead of in one long pass.
pub const max_batches: usize = 200;

const seconds_per_day: i64 = 86_400;
const micros_per_second: i64 = 1_000_000;

/// `logs.created_at_nano` holds MICROseconds — `frontend_log_post` stamps
/// `microsecondsNow()` — even though migration 075 named it `_nano`. A row that
/// really holds 19-digit nanos must not read as 1970, so the cutoff is scaled by
/// the row's own magnitude instead of trusting the column name. Migration 075's
/// rename is where the two units met; P4 is where they are meant to be unified.
const older_than_cutoff =
    "created_at_nano < CASE WHEN created_at_nano >= 100000000000000000 " ++
    "THEN CAST(? AS INTEGER) * 1000 ELSE CAST(? AS INTEGER) END";

pub const PruneLogsInput = struct {
    allocator: std.mem.Allocator,
    db: *database.Db,
    logger: ?*loggermod.Logger,
    now_unix: i64,
    retention_days: i64 = retention_days,
    batch_rows: usize = batch_rows,
    max_batches: usize = max_batches,
};

pub const PruneResult = struct {
    deleted: usize = 0,
    batches: usize = 0,
    released_pages: i64 = 0,
};

pub fn pruneLogs(input: PruneLogsInput) anyerror!PruneResult {
    const allocator = input.allocator;
    const db = input.db;

    var result = PruneResult{};
    const cutoff_unix = input.now_unix - input.retention_days * seconds_per_day;
    const cutoff_str = try std.fmt.allocPrint(allocator, "{d}", .{cutoff_unix * micros_per_second});
    defer allocator.free(cutoff_str);
    const batch_str = try std.fmt.allocPrint(allocator, "{d}", .{input.batch_rows});
    defer allocator.free(batch_str);

    const delete_sql = "DELETE FROM logs WHERE id IN (" ++
        " SELECT id FROM logs WHERE " ++ older_than_cutoff ++
        " ORDER BY created_at_nano LIMIT ?)";

    while (result.batches < input.max_batches) {
        try db.exec(allocator, delete_sql, &.{ cutoff_str, cutoff_str, batch_str });
        const rows: usize = @intCast(db.changes());
        result.batches += 1;
        result.deleted += rows;
        if (rows < input.batch_rows) break;
    }

    if (result.deleted == 0) return result;

    // The rows are gone but their pages are not: hand back what fits in one tick.
    const released = try reclaim.releaseFreePages(db, allocator);
    result.released_pages = released.pages_before - released.pages_after;
    return result;
}

pub fn handle(ctx: ?*anyopaque, now_unix: i64) void {
    _ = ctx;

    const di = pabrikcore.getSingleton() catch return;
    var arena = std.heap.ArenaAllocator.init(di.allocator);
    defer arena.deinit();

    const result = pruneLogs(.{
        .allocator = arena.allocator(),
        .db = di.db,
        .logger = di.logger,
        .now_unix = now_unix,
    }) catch |err| {
        di.logger.errFmt("[prune_logs] tick failed: {s}\n", .{@errorName(err)});
        return;
    };

    // A tick that deleted nothing is the normal case once the backlog is gone.
    if (result.deleted == 0) return;
    di.logger.infoFmt(
        "[prune_logs] deleted={d} batches={d} released_pages={d}",
        .{ result.deleted, result.batches, result.released_pages },
    );
}

// ─── Tests ───────────────────────────────────────────────────────────────

const Ctx = struct {
    db: database.Db = .{},
    threaded: std.Io.Threaded,
    arena: std.heap.ArenaAllocator,

    fn deinit(self: *Ctx) void {
        self.db.deinit();
        self.threaded.deinit();
        self.arena.deinit();
    }
};

fn setupCtx() !Ctx {
    const alloc = testing.allocator;
    var arena = std.heap.ArenaAllocator.init(alloc);
    errdefer arena.deinit();
    const a = arena.allocator();

    var threaded = std.Io.Threaded.init(alloc, .{});
    errdefer threaded.deinit();

    var db: database.Db = .{};
    errdefer db.deinit();
    try test_db.openMemory(&db, threaded.io());

    try db.exec(a,
        \\CREATE TABLE logs (
        \\  id TEXT PRIMARY KEY,
        \\  created_at_nano INTEGER NOT NULL,
        \\  level TEXT NOT NULL,
        \\  kind TEXT NOT NULL,
        \\  message TEXT NOT NULL,
        \\  stack TEXT,
        \\  source TEXT,
        \\  line INTEGER,
        \\  route_path TEXT,
        \\  session_id TEXT,
        \\  count INTEGER NOT NULL DEFAULT 1
        \\)
    , &.{});

    return .{ .db = db, .threaded = threaded, .arena = arena };
}

/// A fixed instant, so every test states its own age rather than reading a clock.
const now: i64 = 1_790_000_000;

fn stampMicros(db: *database.Db, a: std.mem.Allocator, id: []const u8, unix_seconds: i64) !void {
    const value = try std.fmt.allocPrint(a, "{d}", .{unix_seconds * micros_per_second});
    try db.exec(a, "INSERT INTO logs (id, created_at_nano, level, kind, message) VALUES (?, ?, 'warn', 'console_warn', 'x')", &.{ id, value });
}

fn stampNanos(db: *database.Db, a: std.mem.Allocator, id: []const u8, unix_seconds: i64) !void {
    const value = try std.fmt.allocPrint(a, "{d}", .{unix_seconds * 1_000_000_000});
    try db.exec(a, "INSERT INTO logs (id, created_at_nano, level, kind, message) VALUES (?, ?, 'warn', 'console_warn', 'x')", &.{ id, value });
}

fn rowCount(db: *database.Db, a: std.mem.Allocator, id: []const u8) !usize {
    var row = try db.queryRow(a, "SELECT COUNT(*) FROM logs WHERE id = ?", &.{id});
    defer row.deinit(a);
    return std.fmt.parseInt(usize, row.values[0], 10) catch 0;
}

test "pruneLogs deletes a row past the window and keeps one inside it" {
    var ctx = try setupCtx();
    defer ctx.deinit();
    const a = ctx.arena.allocator();

    try stampMicros(&ctx.db, a, "old", now - 31 * seconds_per_day);
    try stampMicros(&ctx.db, a, "fresh", now - 29 * seconds_per_day);

    const result = try pruneLogs(.{ .allocator = a, .db = &ctx.db, .logger = null, .now_unix = now });

    try testing.expectEqual(@as(usize, 1), result.deleted);
    try testing.expectEqual(@as(usize, 0), try rowCount(&ctx.db, a, "old"));
    try testing.expectEqual(@as(usize, 1), try rowCount(&ctx.db, a, "fresh"));
}

test "pruneLogs keeps a row exactly at the window's edge" {
    var ctx = try setupCtx();
    defer ctx.deinit();
    const a = ctx.arena.allocator();

    try stampMicros(&ctx.db, a, "edge", now - retention_days * seconds_per_day);

    const result = try pruneLogs(.{ .allocator = a, .db = &ctx.db, .logger = null, .now_unix = now });

    try testing.expectEqual(@as(usize, 0), result.deleted);
    try testing.expectEqual(@as(usize, 1), try rowCount(&ctx.db, a, "edge"));
}

test "pruneLogs reads a 19-digit nano stamp by magnitude, not by the column name" {
    var ctx = try setupCtx();
    defer ctx.deinit();
    const a = ctx.arena.allocator();

    try stampNanos(&ctx.db, a, "nano_old", now - 31 * seconds_per_day);
    try stampNanos(&ctx.db, a, "nano_fresh", now - 29 * seconds_per_day);

    const result = try pruneLogs(.{ .allocator = a, .db = &ctx.db, .logger = null, .now_unix = now });

    try testing.expectEqual(@as(usize, 1), result.deleted);
    try testing.expectEqual(@as(usize, 0), try rowCount(&ctx.db, a, "nano_old"));
    try testing.expectEqual(@as(usize, 1), try rowCount(&ctx.db, a, "nano_fresh"));
}

test "pruneLogs works through a backlog larger than one batch" {
    var ctx = try setupCtx();
    defer ctx.deinit();
    const a = ctx.arena.allocator();

    const over_a_batch = batch_rows + 150;
    for (0..over_a_batch) |i| {
        var id_buf: [32]u8 = undefined;
        const id = try std.fmt.bufPrint(&id_buf, "old_{d}", .{i});
        try stampMicros(&ctx.db, a, id, now - 40 * seconds_per_day);
    }

    const result = try pruneLogs(.{ .allocator = a, .db = &ctx.db, .logger = null, .now_unix = now });

    try testing.expectEqual(over_a_batch, result.deleted);
    try testing.expectEqual(@as(usize, 2), result.batches);

    var row = try ctx.db.queryRow(a, "SELECT COUNT(*) FROM logs", &.{});
    defer row.deinit(a);
    try testing.expectEqualStrings("0", row.values[0]);
}

test "pruneLogs leaves a table with nothing past the window untouched" {
    var ctx = try setupCtx();
    defer ctx.deinit();
    const a = ctx.arena.allocator();

    try stampMicros(&ctx.db, a, "fresh", now - seconds_per_day);

    const result = try pruneLogs(.{ .allocator = a, .db = &ctx.db, .logger = null, .now_unix = now });

    try testing.expectEqual(@as(usize, 0), result.deleted);
    try testing.expectEqual(@as(i64, 0), result.released_pages);
}
