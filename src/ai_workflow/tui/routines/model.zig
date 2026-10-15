//! `workspace_routines` model — DB row struct + CRUD helpers. Retargeted from
//! the deleted per-task `routines` table (Migration 044) to
//! `workspace_routines` (Migration 084).

const std = @import("std");
const pabrikcore = @import("pabrikcore");
const SqliteBackend = pabrikcore.sqlite.SqliteBackend;
const Scheduler = @import("Scheduler.zig");

/// Canonical status values written to the `workspace_routines.last_status`
/// column.
pub const RoutineRunStatus = enum {
    idle,
    success,
    failed,
    running,

    /// String representation for the `last_status` column.
    pub fn dbValue(self: RoutineRunStatus) []const u8 {
        return switch (self) {
            .idle => "idle",
            .success => "success",
            .failed => "failed",
            .running => "running",
        };
    }

    /// Inverse of `dbValue` — NULL or the empty string decodes to `.idle`,
    /// unknown strings also decode to `.idle` (defensive default).
    pub fn fromDb(text: ?[]const u8) RoutineRunStatus {
        const t = text orelse return .idle;
        if (t.len == 0) return .idle;
        if (std.mem.eql(u8, t, "success")) return .success;
        if (std.mem.eql(u8, t, "failed")) return .failed;
        if (std.mem.eql(u8, t, "running")) return .running;
        return .idle;
    }
};

/// In-memory representation of one row in the `workspace_routines`
/// table. All string fields are owned and must be freed with `deinit`.
pub const Routine = struct {
    id: []const u8,
    workspace_item_id: []const u8,
    description: []const u8 = "",
    instruction: []const u8 = "",
    schedule: []const u8 = "",
    enabled: bool,
    next_run_at: ?[]const u8 = null,
    last_run_at: ?[]const u8 = null,
    last_status: RoutineRunStatus = .idle,
    last_error: ?[]const u8 = null,
    created_at: ?[]const u8 = null,
    updated_at: ?[]const u8 = null,

    pub fn deinit(self: Routine, allocator: std.mem.Allocator) void {
        allocator.free(self.id);
        allocator.free(self.workspace_item_id);
        if (self.description.len > 0) allocator.free(self.description);
        if (self.instruction.len > 0) allocator.free(self.instruction);
        if (self.schedule.len > 0) allocator.free(self.schedule);
        if (self.next_run_at) |v| allocator.free(v);
        if (self.last_run_at) |v| allocator.free(v);
        if (self.last_error) |v| allocator.free(v);
        if (self.created_at) |v| allocator.free(v);
        if (self.updated_at) |v| allocator.free(v);
    }
};

/// Insert a new routine row. `next_run_at` null writes SQL NULL (manual-run
/// only).
pub fn insertWorkspaceRoutine(allocator: std.mem.Allocator, db: *SqliteBackend, r: Routine) !void {
    _ = try db.exec(allocator,
        \\INSERT INTO workspace_routines (id, workspace_item_id, description, instruction, schedule, enabled, next_run_at)
        \\VALUES (?, ?, COALESCE(NULLIF(?, ''), ''), COALESCE(NULLIF(?, ''), ''), COALESCE(NULLIF(?, ''), ''), ?, ?)
    , &.{
        r.id,
        r.workspace_item_id,
        r.description,
        r.instruction,
        r.schedule,
        if (r.enabled) "1" else "0",
        r.next_run_at orelse "",
    });
}

/// Load the routine for a given workspace-routine `id` (which equals its
/// `workspace_item_id` per the D3 identity). Returns `error.RoutineNotFound`
/// if no row matches.
pub fn loadWorkspaceRoutineById(allocator: std.mem.Allocator, db: *SqliteBackend, id: []const u8) !Routine {
    var q = try db.query(allocator,
        \\SELECT id, workspace_item_id, description, instruction, schedule, enabled, next_run_at,
        \\       last_run_at, last_status, last_error, created_at, updated_at
        \\FROM workspace_routines WHERE id = ?
    , &.{id});
    defer q.deinit();

    const row = (try q.next()) orelse return error.RoutineNotFound;
    defer row.deinit(allocator);

    // enabled is INTEGER — the Row API returns it as the text "1" or "0".
    const enabled_int = std.fmt.parseInt(i64, row.values[5], 10) catch 0;

    return .{
        .id = try allocator.dupe(u8, row.values[0]),
        .workspace_item_id = try allocator.dupe(u8, row.values[1]),
        .description = try allocator.dupe(u8, row.values[2]),
        .instruction = try allocator.dupe(u8, row.values[3]),
        .schedule = try allocator.dupe(u8, row.values[4]),
        .enabled = enabled_int == 1,
        .next_run_at = try nullIfEmpty(allocator, row.values[6]),
        // NULL columns arrive as empty strings in the Row API; translate
        // empty → null so the in-memory model matches the SQL NULL.
        .last_run_at = try nullIfEmpty(allocator, row.values[7]),
        .last_status = RoutineRunStatus.fromDb(nullIfEmptyConst(row.values[8])),
        .last_error = try nullIfEmpty(allocator, row.values[9]),
        .created_at = try nullIfEmpty(allocator, row.values[10]),
        .updated_at = try nullIfEmpty(allocator, row.values[11]),
    };
}

/// Return the ids of every enabled routine whose `next_run_at` is at or
/// before `now_sqlite` (formatted as an SQLite DATETIME literal, e.g.
pub fn listDueWorkspaceRoutineIds(allocator: std.mem.Allocator, db: *SqliteBackend, now_sqlite: []const u8) ![][]u8 {
    var q = try db.query(allocator,
        \\SELECT id FROM workspace_routines
        \\WHERE enabled = 1
        \\  AND next_run_at <= ?
        \\  AND (last_status IS NULL OR last_status != 'running')
    , &.{now_sqlite});
    defer q.deinit();

    var out: std.ArrayList([]u8) = .empty;
    errdefer {
        for (out.items) |item| allocator.free(item);
        out.deinit(allocator);
    }

    while (try q.next()) |row| {
        defer row.deinit(allocator);
        try out.append(allocator, try allocator.dupe(u8, row.values[0]));
    }
    return out.toOwnedSlice(allocator);
}

/// Atomically transition a routine's `last_status` to `'running'` iff it is
/// not already `'running'`.
pub fn claimForRun(allocator: std.mem.Allocator, db: *SqliteBackend, routine_id: []const u8) !bool {
    db.exec(allocator,
        \\UPDATE workspace_routines
        \\   SET last_status = 'running', updated_at = datetime('now')
        \\ WHERE id = ?
        \\   AND (last_status IS NULL OR last_status != 'running')
    , &.{routine_id}) catch |err| {
        std.log.warn("claimForRun: UPDATE failed for {s}: {s}", .{ routine_id, @errorName(err) });
        return false;
    };

    // 1 → we won the claim; 0 → another caller claimed it first
    // (or the row is gone).
    return db.changes() > 0;
}

/// Mark a routine as having completed successfully: set `last_status =
/// 'success'`, bump `next_run_at` to the cron-computed next firing time,
/// stamp `last_run_at` to now, and clear `last_error`.
pub fn markSuccess(allocator: std.mem.Allocator, db: *SqliteBackend, routine_id: []const u8, next_run_at_sqlite: []const u8) !void {
    _ = try db.exec(allocator,
        \\UPDATE workspace_routines
        \\   SET last_run_at = datetime('now'),
        \\       next_run_at = ?,
        \\       last_status = 'success',
        \\       last_error = '',
        \\       updated_at = datetime('now')
        \\ WHERE id = ?
    , &.{ next_run_at_sqlite, routine_id });
}

/// Mark a routine as failed with the given error message, and advance its
/// `next_run_at` so the scheduler picks a future run.
pub fn markFailed(allocator: std.mem.Allocator, db: *SqliteBackend, routine_id: []const u8, err_msg: []const u8, next_run_at_sqlite: []const u8) !void {
    _ = try db.exec(allocator,
        \\UPDATE workspace_routines
        \\   SET last_status = 'failed',
        \\       last_error = COALESCE(NULLIF(?, ''), ''),
        \\       next_run_at = ?,
        \\       updated_at = datetime('now')
        \\ WHERE id = ?
    , &.{ err_msg, next_run_at_sqlite, routine_id });
}

/// Iterate over all enabled routines, recompute `next_run_at` via
/// `cron.nextFireTime`, and UPDATE the row.
pub fn recomputeAllNextRunAt(
    allocator: std.mem.Allocator,
    db: *SqliteBackend,
    compute_fn: *const fn (schedule: []const u8, now_unix_nanos: i128) anyerror![]const u8,
    now_unix_nanos: i128,
) !void {
    _ = compute_fn;
    _ = now_unix_nanos;
    const di = pabrikcore.getSingleton() catch return;
    try Scheduler.recomputeDueNextRunAt(allocator, db, di.io);
}

/// Dupe a Row-API text slice, translating the empty string (SQL NULL)
/// to Zig null.
fn nullIfEmpty(allocator: std.mem.Allocator, v: []const u8) !?[]u8 {
    if (v.len == 0) return null;
    return try allocator.dupe(u8, v);
}

/// Non-allocating variant for `fromDb` inputs.
fn nullIfEmptyConst(v: []const u8) ?[]const u8 {
    if (v.len == 0) return null;
    return v;
}

// ===== Tests merged from model_test.zig (2026-09-29 flatten) =====
// Behavioral tests for the `workspace_routines` model (Task 3 of the
// workspace-items-routines plan).

const testing = std.testing;

const sqlite = pabrikcore.sqlite;

const migration = pabrikcore.migrations_mod.migration;
const Migration084ReplaceRoutinesWithWorkspaceRoutines = migration.Migration084ReplaceRoutinesWithWorkspaceRoutines;

// ─── Test helpers ─────────────────────────────────────────────────────────

/// Open a fresh in-memory sqlite DB with the minimal parent tables,
/// then run Migration 084 to bring it to the post-migration state.
fn setupDb() !struct {
    db: sqlite.SqliteBackend,
    threaded: std.Io.Threaded,
} {
    const alloc = testing.allocator;
    var threaded = std.Io.Threaded.init(alloc, .{});
    errdefer threaded.deinit();
    const io = threaded.io();

    var db: sqlite.SqliteBackend = .{};
    errdefer db.deinit();
    try db.init(io, ":memory:");

    // Migration 084's UPDATE touches workspace_item_tasks, and the
    // FK references workspace_items — both must exist.
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
/// rows.
fn scalarText(alloc: std.mem.Allocator, db: *sqlite.SqliteBackend, sql: []const u8, args: []const []const u8) !?[]u8 {
    var q = try db.query(alloc, sql, args);
    defer q.deinit();
    if (try q.next()) |row| {
        defer row.deinit(alloc);
        return try alloc.dupe(u8, row.values[0]);
    }
    return null;
}

/// Insert a parent workspace_item row.
fn insertParentItem(db: *sqlite.SqliteBackend, alloc: std.mem.Allocator, id: []const u8) !void {
    try db.exec(alloc,
        "INSERT INTO workspace_items (id, workspace_id, item_type) VALUES (?, 'ws1', 'routine')",
        &.{id});
}

// ─── Test 1: insert + load round-trip ─────────────────────────────────────

test "Routine: insert + load round-trip" {
    const alloc = testing.allocator;
    var ctx = try setupDb();
    defer ctx.db.deinit();
    defer ctx.threaded.deinit();

    try insertParentItem(&ctx.db, alloc, "item_1");

    const inserted = Routine{
        .id = "item_1",
        .workspace_item_id = "item_1",
        .instruction = "do the thing",
        .schedule = "*/5 * * * *",
        .enabled = true,
        .next_run_at = "2099-01-01 00:00:00",
    };
    try insertWorkspaceRoutine(alloc, &ctx.db, inserted);

    var loaded = try loadWorkspaceRoutineById(alloc, &ctx.db, "item_1");
    defer loaded.deinit(alloc);

    try testing.expectEqualStrings("item_1", loaded.id);
    try testing.expectEqualStrings("item_1", loaded.workspace_item_id);
    try testing.expectEqualStrings("*/5 * * * *", loaded.schedule);
    try testing.expectEqualStrings("do the thing", loaded.instruction);
    try testing.expect(loaded.enabled);
    try testing.expectEqualStrings("2099-01-01 00:00:00", loaded.next_run_at.?);
    // Nullable fields on a freshly-inserted row are NULL.
    try testing.expect(loaded.last_run_at == null);
    try testing.expectEqual(RoutineRunStatus.idle, loaded.last_status);
    try testing.expect(loaded.last_error == null);
    // created_at + updated_at are auto-populated by CURRENT_TIMESTAMP
    // defaults, so they should be non-null.
    try testing.expect(loaded.created_at != null);
    try testing.expect(loaded.updated_at != null);
}

// ─── Test 2: listDueWorkspaceRoutineIds filters correctly ────────────────

test "Routine: listDueWorkspaceRoutineIds returns only enabled with next_run_at <= now" {
    const alloc = testing.allocator;
    var ctx = try setupDb();
    defer ctx.db.deinit();
    defer ctx.threaded.deinit();

    try insertParentItem(&ctx.db, alloc, "item_1");
    try insertParentItem(&ctx.db, alloc, "item_2");
    try insertParentItem(&ctx.db, alloc, "item_3");
    try insertParentItem(&ctx.db, alloc, "item_4");

    // Routine A: enabled=1, next_run_at past → DUE
    try insertWorkspaceRoutine(alloc, &ctx.db, .{
        .id = "item_1",
        .workspace_item_id = "item_1",
        .instruction = "a",
        .schedule = "* * * * *",
        .enabled = true,
        .next_run_at = "2000-01-01 00:00:00",
    });
    // Routine B: enabled=1, next_run_at in the future → NOT DUE
    try insertWorkspaceRoutine(alloc, &ctx.db, .{
        .id = "item_2",
        .workspace_item_id = "item_2",
        .instruction = "b",
        .schedule = "* * * * *",
        .enabled = true,
        .next_run_at = "2099-01-01 00:00:00",
    });
    // Routine C: enabled=0 (disabled), next_run_at past → NOT DUE
    try insertWorkspaceRoutine(alloc, &ctx.db, .{
        .id = "item_3",
        .workspace_item_id = "item_3",
        .instruction = "c",
        .schedule = "* * * * *",
        .enabled = false,
        .next_run_at = "2000-01-01 00:00:00",
    });
    // Routine D: manual-only (NULL next_run_at) → NOT DUE
    try insertWorkspaceRoutine(alloc, &ctx.db, .{
        .id = "item_4",
        .workspace_item_id = "item_4",
        .instruction = "d",
        .schedule = "",
        .enabled = true,
        .next_run_at = null,
    });

    const due = try listDueWorkspaceRoutineIds(alloc, &ctx.db, "2025-01-01 00:00:00");
    defer {
        for (due) |id| alloc.free(id);
        alloc.free(due);
    }

    try testing.expectEqual(@as(usize, 1), due.len);
    try testing.expectEqualStrings("item_1", due[0]);
}

// ─── Test 3: claimForRun is atomic (first wins, second loses) ─────────────

test "Routine: claimForRun atomically transitions to running" {
    const alloc = testing.allocator;
    var ctx = try setupDb();
    defer ctx.db.deinit();
    defer ctx.threaded.deinit();

    try insertParentItem(&ctx.db, alloc, "item_1");
    try insertWorkspaceRoutine(alloc, &ctx.db, .{
        .id = "item_1",
        .workspace_item_id = "item_1",
        .instruction = "a",
        .schedule = "* * * * *",
        .enabled = true,
        .next_run_at = "2000-01-01 00:00:00",
    });

    const first = try claimForRun(alloc, &ctx.db, "item_1");
    try testing.expect(first);

    // A second claim on the same id must fail because last_status is
    // now 'running' (the WHERE clause excludes already-running rows).
    const second = try claimForRun(alloc, &ctx.db, "item_1");
    try testing.expect(!second);

    // Sanity-check the row was actually updated.
    const status = try scalarText(alloc, &ctx.db,
        "SELECT last_status FROM workspace_routines WHERE id = 'item_1'", &.{});
    defer if (status) |s| alloc.free(s);
    try testing.expect(status != null);
    try testing.expectEqualStrings("running", status.?);
}

// ─── Test 4: markSuccess updates last_status and next_run_at ─────────────

test "Routine: markSuccess updates last_status and next_run_at" {
    const alloc = testing.allocator;
    var ctx = try setupDb();
    defer ctx.db.deinit();
    defer ctx.threaded.deinit();

    try insertParentItem(&ctx.db, alloc, "item_1");
    try insertWorkspaceRoutine(alloc, &ctx.db, .{
        .id = "item_1",
        .workspace_item_id = "item_1",
        .instruction = "a",
        .schedule = "* * * * *",
        .enabled = true,
        .next_run_at = "2000-01-01 00:00:00",
    });
    // Claim it first (markSuccess is normally called after a successful run).
    _ = try claimForRun(alloc, &ctx.db, "item_1");

    try markSuccess(alloc, &ctx.db, "item_1", "2099-01-01 00:00:00");

    var loaded = try loadWorkspaceRoutineById(alloc, &ctx.db, "item_1");
    defer loaded.deinit(alloc);

    try testing.expectEqual(RoutineRunStatus.success, loaded.last_status);
    try testing.expectEqualStrings("2099-01-01 00:00:00", loaded.next_run_at.?);
    // last_run_at is set to datetime('now') — just assert non-null.
    try testing.expect(loaded.last_run_at != null);
    // last_error is cleared on success.
    try testing.expect(loaded.last_error == null);
}

// ─── Test 5: RoutineRunStatus enum mapping (pure unit test, no DB) ───────

test "RoutineRunStatus enum mapping" {
    // .dbValue() — the canonical strings written to the DB column.
    try testing.expectEqualStrings("idle", RoutineRunStatus.idle.dbValue());
    try testing.expectEqualStrings("success", RoutineRunStatus.success.dbValue());
    try testing.expectEqualStrings("failed", RoutineRunStatus.failed.dbValue());
    try testing.expectEqualStrings("running", RoutineRunStatus.running.dbValue());

    // .fromDb() — round-trip every value.
    try testing.expectEqual(RoutineRunStatus.idle, RoutineRunStatus.fromDb(null));
    try testing.expectEqual(RoutineRunStatus.idle, RoutineRunStatus.fromDb(""));
    try testing.expectEqual(RoutineRunStatus.idle, RoutineRunStatus.fromDb("idle"));
    try testing.expectEqual(RoutineRunStatus.success, RoutineRunStatus.fromDb("success"));
    try testing.expectEqual(RoutineRunStatus.failed, RoutineRunStatus.fromDb("failed"));
    try testing.expectEqual(RoutineRunStatus.running, RoutineRunStatus.fromDb("running"));
    // Unknown string → .idle (defensive default).
    try testing.expectEqual(RoutineRunStatus.idle, RoutineRunStatus.fromDb("bogus"));
}

// ─── Test 6: markFailed sets last_status=failed, last_error, and advances next_run_at ───

test "Routine: markFailed sets last_status=failed and last_error" {
    const alloc = testing.allocator;
    var ctx = try setupDb();
    defer ctx.db.deinit();
    defer ctx.threaded.deinit();

    try insertParentItem(&ctx.db, alloc, "item_1");
    try insertWorkspaceRoutine(alloc, &ctx.db, .{
        .id = "item_1",
        .workspace_item_id = "item_1",
        .instruction = "x",
        .schedule = "*/5 * * * *",
        .enabled = true,
        .next_run_at = "2000-01-01 00:00:00",
    });

    try markFailed(alloc, &ctx.db, "item_1", "LLM rate limit", "2099-01-01 00:00:00");

    var loaded = try loadWorkspaceRoutineById(alloc, &ctx.db, "item_1");
    defer loaded.deinit(alloc);

    try testing.expectEqual(RoutineRunStatus.failed, loaded.last_status);
    try testing.expectEqualStrings("LLM rate limit", loaded.last_error.?);
    try testing.expectEqualStrings("2099-01-01 00:00:00", loaded.next_run_at.?);
    // Routine should STAY enabled (a transient failure must not silently
    // disable a recurring job — the user disables it explicitly).
    try testing.expect(loaded.enabled);
}
