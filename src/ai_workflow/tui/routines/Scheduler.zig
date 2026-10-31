const std = @import("std");
const pabrikcore = @import("pabrikcore");
const test_db = pabrikcore.test_db;
const sqlite = pabrikcore.sqlite;
const database = pabrikcore.database;
const dialect = pabrikcore.dialect;
const logger_mod = pabrikcore.loggermod;

const model = @import("model.zig");
const cron = @import("cron.zig");
const fire = @import("fire.zig");

pub const TICK_INTERVAL_NS: i128 = 5 * std.time.ns_per_s;

pub const stale_run_timeout_seconds: i64 = 30 * 60;

fn warn(comptime fmt: []const u8, args: anytype) void {
    if (logger_mod.getGlobal()) |logger| logger.warnFmt(fmt, args);
}

pub fn resetStuckRunning(allocator: std.mem.Allocator, db: *database.Db) !usize {
    const err_msg = "process killed (restart detected)";
    const sql = "UPDATE workspace_routines SET last_status = 'failed', last_error = ?, updated_at = " ++
        dialect.now_stamp ++ " WHERE last_status = 'running'";
    _ = try db.exec(allocator, sql, &.{err_msg});
    const changed = db.changes();
    if (changed <= 0) return 0;
    return @intCast(changed);
}

pub fn seedMissingNextRunAt(
    allocator: std.mem.Allocator,
    db: *database.Db,
    io: std.Io,
) !usize {
    var rows = try db.query(allocator,
        "SELECT id, schedule FROM workspace_routines WHERE enabled = 1 AND schedule != '' AND (next_run_at IS NULL OR next_run_at = '')", &.{});
    defer rows.deinit();

    const now_ns: i128 = @intCast(std.Io.Timestamp.now(io, .real).nanoseconds);

    const Pending = struct {
        id: []u8,
        next_sqlite: []u8,
    };
    var to_update: std.ArrayList(Pending) = .empty;
    defer {
        for (to_update.items) |item| {
            allocator.free(item.id);
            allocator.free(item.next_sqlite);
        }
        to_update.deinit(allocator);
    }

    while (try rows.next()) |row| {
        defer row.deinit(allocator);
        const id = try allocator.dupe(u8, row.values[0]);
        errdefer allocator.free(id);
        const schedule = row.values[1];

        const next_ns = cron.nextFireTime(schedule, now_ns) catch |err| {
            warn("scheduler: {s} has an unusable schedule ({s}): {s}", .{ id, schedule, @errorName(err) });
            allocator.free(id);
            continue;
        };

        try to_update.append(allocator, .{
            .id = id,
            .next_sqlite = try fire.formatSqliteDatetime(allocator, next_ns),
        });
    }

    for (to_update.items) |item| {
        _ = try db.exec(allocator,
            "UPDATE workspace_routines SET next_run_at = ?, updated_at = CURRENT_TIMESTAMP WHERE id = ?",
            &.{ item.next_sqlite, item.id });
    }
    return to_update.items.len;
}

pub fn fireDueRoutines(
    allocator: std.mem.Allocator,
    db: *database.Db,
    di: *pabrikcore.App,
    io: std.Io,
) !usize {
    const now_ns: i128 = @intCast(std.Io.Timestamp.now(io, .real).nanoseconds);
    const now_sqlite = try fire.formatSqliteDatetime(allocator, now_ns);
    defer allocator.free(now_sqlite);

    const due_ids = try model.listDueWorkspaceRoutineIds(allocator, db, now_sqlite);
    defer {
        for (due_ids) |id| allocator.free(id);
        allocator.free(due_ids);
    }

    var fired: usize = 0;
    for (due_ids) |routine_id| {
        fire.fireWorkspaceRoutine(allocator, db, di, io, routine_id) catch |err| switch (err) {
            error.NotARoutine, error.Disabled, error.AlreadyRunning => continue,
            else => {
                warn("scheduler: fireWorkspaceRoutine failed for {s}: {s}", .{ routine_id, @errorName(err) });
                continue;
            },
        };
        fired += 1;
    }
    return fired;
}

pub fn start(
    allocator: std.mem.Allocator,
    db: *database.Db,
    di: *pabrikcore.App,
    io: std.Io,
) !void {
    _ = resetStuckRunning(allocator, db) catch |err| blk: {
        warn("scheduler: resetStuckRunning failed: {s}", .{@errorName(err)});
        break :blk 0;
    };
    _ = seedMissingNextRunAt(allocator, db, io) catch |err| blk: {
        warn("scheduler: seedMissingNextRunAt failed: {s}", .{@errorName(err)});
        break :blk 0;
    };

    while (true) {
        _ = model.reclaimStaleRuns(allocator, db, stale_run_timeout_seconds) catch |err| blk: {
            warn("scheduler: reclaimStaleRuns failed: {s}", .{@errorName(err)});
            break :blk 0;
        };
        _ = fireDueRoutines(allocator, db, di, io) catch |err| {
            warn("scheduler: fireDueRoutines failed: {s}", .{@errorName(err)});
        };
        try std.Io.sleep(io, .{ .nanoseconds = TICK_INTERVAL_NS }, .real);
    }
}

// ===== Tests merged from scheduler_test.zig (2026-09-29 flatten) =====
// Behavioral tests for `Scheduler.zig` (Task 3 of the
// workspace-items-routines plan).

const testing = std.testing;

const migration = pabrikcore.migrations_mod.migration;
const Migration084ReplaceRoutinesWithWorkspaceRoutines = migration.Migration084ReplaceRoutinesWithWorkspaceRoutines;

// ─── Test helpers ─────────────────────────────────────────────────────────

/// Open a fresh in-memory sqlite DB with the minimal parent tables
/// and run Migration 084. Mirrors the helper in `model.zig`.
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

    try db.exec(alloc,
        \\CREATE TABLE workspace_item_tasks (
        \\    id TEXT PRIMARY KEY,
        \\    name TEXT NOT NULL,
        \\    workspace_item_id TEXT NOT NULL,
        \\    task_type TEXT NOT NULL DEFAULT 'standard'
        \\)
    , &.{});
    try db.exec(alloc,
        \\CREATE TABLE workspace_items (
        \\    id TEXT PRIMARY KEY,
        \\    workspace_id TEXT,
        \\    item_type TEXT NOT NULL
        \\)
    , &.{});

    try Migration084ReplaceRoutinesWithWorkspaceRoutines.up(&db, alloc);

    return .{ .db = db, .threaded = threaded };
}

/// Run a single-column SELECT and return a duplicated copy of the
/// first row's first column. Returns null when the query produces no
/// rows. Mirrors the helper in `model.zig`.
fn scalarText(alloc: std.mem.Allocator, db: *database.Db, sql: []const u8, args: []const []const u8) !?[]u8 {
    var q = try db.query(alloc, sql, args);
    defer q.deinit();
    if (try q.next()) |row| {
        defer row.deinit(alloc);
        return try alloc.dupe(u8, row.values[0]);
    }
    return null;
}

fn insertParentItem(db: *database.Db, alloc: std.mem.Allocator, id: []const u8) !void {
    try db.exec(alloc,
        "INSERT INTO workspace_items (id, workspace_id, item_type) VALUES (?, 'ws1', 'routine')",
        &.{id});
}

// ─── Test 1: resetStuckRunning ────────────────────────────────────────────

test "Scheduler.resetStuckRunning marks running rows as failed" {
    const alloc = testing.allocator;
    var ctx = try setupDb();
    defer ctx.db.deinit();
    defer ctx.threaded.deinit();

    try insertParentItem(&ctx.db, alloc, "item_1");
    try model.insertWorkspaceRoutine(alloc, &ctx.db, .{
        .id = "item_1",
        .workspace_item_id = "item_1",
        .instruction = "x",
        .schedule = "*/5 * * * *",
        .enabled = true,
        .next_run_at = "2099-01-01 00:00:00",
    });
    // Simulate a crashed previous process: routine is stuck in 'running'.
    try ctx.db.exec(alloc,
        "UPDATE workspace_routines SET last_status = 'running' WHERE id = 'item_1'",
        &.{});

    const reset = try resetStuckRunning(alloc, &ctx.db);
    try testing.expectEqual(@as(usize, 1), reset);

    const status = try scalarText(alloc, &ctx.db,
        "SELECT last_status FROM workspace_routines WHERE id = 'item_1'", &.{});
    defer if (status) |s| alloc.free(s);
    const err_msg = try scalarText(alloc, &ctx.db,
        "SELECT last_error FROM workspace_routines WHERE id = 'item_1'", &.{});
    defer if (err_msg) |s| alloc.free(s);

    try testing.expect(status != null);
    try testing.expectEqualStrings("failed", status.?);
    try testing.expect(err_msg != null);
    try testing.expectEqualStrings("process killed (restart detected)", err_msg.?);
}

// ─── Test 2: startup seeding does not swallow a missed fire ───────────────

test "Scheduler.seedMissingNextRunAt gives a scheduled routine its first next_run_at" {
    const alloc = testing.allocator;
    var ctx = try setupDb();
    defer ctx.db.deinit();
    defer ctx.threaded.deinit();

    try insertParentItem(&ctx.db, alloc, "item_1");
    try model.insertWorkspaceRoutine(alloc, &ctx.db, .{
        .id = "item_1",
        .workspace_item_id = "item_1",
        .instruction = "x",
        .schedule = "0 9 * * *",
        .enabled = true,
        .next_run_at = null,
    });

    const seeded = try seedMissingNextRunAt(alloc, &ctx.db, ctx.threaded.io());
    try testing.expectEqual(@as(usize, 1), seeded);

    const next = try scalarText(alloc, &ctx.db,
        "SELECT next_run_at FROM workspace_routines WHERE id = 'item_1'", &.{});
    defer if (next) |s| alloc.free(s);

    try testing.expect(next != null);
    try testing.expect(std.mem.indexOf(u8, next.?, " 09:00:00") != null);
}

test "Scheduler.seedMissingNextRunAt keeps an overdue routine due so the missed fire still runs" {
    const alloc = testing.allocator;
    var ctx = try setupDb();
    defer ctx.db.deinit();
    defer ctx.threaded.deinit();

    try insertParentItem(&ctx.db, alloc, "item_1");
    try model.insertWorkspaceRoutine(alloc, &ctx.db, .{
        .id = "item_1",
        .workspace_item_id = "item_1",
        .instruction = "x",
        .schedule = "0 9 * * *",
        .enabled = true,
        .next_run_at = "2000-01-01 00:00:00",
    });

    const seeded = try seedMissingNextRunAt(alloc, &ctx.db, ctx.threaded.io());
    try testing.expectEqual(@as(usize, 0), seeded);

    const next = try scalarText(alloc, &ctx.db,
        "SELECT next_run_at FROM workspace_routines WHERE id = 'item_1'", &.{});
    defer if (next) |s| alloc.free(s);

    try testing.expectEqualStrings("2000-01-01 00:00:00", next.?);

    const due = try model.listDueWorkspaceRoutineIds(alloc, &ctx.db, "2025-01-01 00:00:00");
    defer {
        for (due) |id| alloc.free(id);
        alloc.free(due);
    }
    try testing.expectEqual(@as(usize, 1), due.len);
    try testing.expectEqualStrings("item_1", due[0]);
}
