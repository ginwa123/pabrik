const std = @import("std");
const pabrikcore = @import("pabrikcore");
const test_db = pabrikcore.test_db;
const Backend = pabrikcore.database.Db;

pub const RoutineRunStatus = enum {
    idle,
    success,
    failed,
    running,

    pub fn dbValue(self: RoutineRunStatus) []const u8 {
        return switch (self) {
            .idle => "idle",
            .success => "success",
            .failed => "failed",
            .running => "running",
        };
    }

    pub fn fromDb(text: ?[]const u8) RoutineRunStatus {
        const t = text orelse return .idle;
        if (t.len == 0) return .idle;
        if (std.mem.eql(u8, t, "success")) return .success;
        if (std.mem.eql(u8, t, "failed")) return .failed;
        if (std.mem.eql(u8, t, "running")) return .running;
        return .idle;
    }
};

pub const Routine = struct {
    id: []const u8,
    workspace_item_id: []const u8,
    description: []const u8 = "",
    instruction: []const u8 = "",
    schedule: []const u8 = "",
    /// The profile name this routine fires under. Empty = the backend's
    /// `active_agent` → top-level-config cascade.
    selected_profile_model: []const u8 = "",
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
        if (self.selected_profile_model.len > 0) allocator.free(self.selected_profile_model);
        if (self.next_run_at) |v| allocator.free(v);
        if (self.last_run_at) |v| allocator.free(v);
        if (self.last_error) |v| allocator.free(v);
        if (self.created_at) |v| allocator.free(v);
        if (self.updated_at) |v| allocator.free(v);
    }
};

pub fn insertWorkspaceRoutine(allocator: std.mem.Allocator, db: *Backend, r: Routine) !void {
    _ = try db.exec(allocator,
        \\INSERT INTO workspace_routines (id, workspace_item_id, description, instruction, schedule, enabled, next_run_at, selected_profile_model)
        \\VALUES (?, ?, COALESCE(NULLIF(?, ''), ''), COALESCE(NULLIF(?, ''), ''), COALESCE(NULLIF(?, ''), ''), ?, ?, COALESCE(NULLIF(?, ''), ''))
    , &.{
        r.id,
        r.workspace_item_id,
        r.description,
        r.instruction,
        r.schedule,
        if (r.enabled) "1" else "0",
        r.next_run_at orelse "",
        r.selected_profile_model,
    });
}

pub fn loadWorkspaceRoutineById(allocator: std.mem.Allocator, db: *Backend, id: []const u8) !Routine {
    var q = try db.query(allocator,
        \\SELECT id, workspace_item_id, description, instruction, schedule, enabled, next_run_at,
        \\       last_run_at, last_status, last_error, created_at, updated_at,
        \\       COALESCE(CAST(selected_profile_model AS TEXT), '')
        \\FROM workspace_routines WHERE id = ?
    , &.{id});
    defer q.deinit();

    const row = (try q.next()) orelse return error.RoutineNotFound;
    defer row.deinit(allocator);

    const enabled_int = std.fmt.parseInt(i64, row.values[5], 10) catch 0;

    return .{
        .id = try allocator.dupe(u8, row.values[0]),
        .workspace_item_id = try allocator.dupe(u8, row.values[1]),
        .description = try allocator.dupe(u8, row.values[2]),
        .instruction = try allocator.dupe(u8, row.values[3]),
        .schedule = try allocator.dupe(u8, row.values[4]),
        .enabled = enabled_int == 1,
        .next_run_at = try nullIfEmpty(allocator, row.values[6]),
        .last_run_at = try nullIfEmpty(allocator, row.values[7]),
        .last_status = RoutineRunStatus.fromDb(nullIfEmptyConst(row.values[8])),
        .last_error = try nullIfEmpty(allocator, row.values[9]),
        .created_at = try nullIfEmpty(allocator, row.values[10]),
        .updated_at = try nullIfEmpty(allocator, row.values[11]),
        .selected_profile_model = try allocator.dupe(u8, row.values[12]),
    };
}

pub fn listDueWorkspaceRoutineIds(allocator: std.mem.Allocator, db: *Backend, now_sqlite: []const u8) ![][]u8 {
    var q = try db.query(allocator,
        \\SELECT id FROM workspace_routines
        \\WHERE enabled = 1
        \\  AND next_run_at IS NOT NULL
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

pub fn claimForRun(allocator: std.mem.Allocator, db: *Backend, routine_id: []const u8) !bool {
    _ = try db.exec(allocator,
        \\UPDATE workspace_routines
        \\   SET last_status = 'running', updated_at = datetime('now')
        \\ WHERE id = ?
        \\   AND (last_status IS NULL OR last_status != 'running')
    , &.{routine_id});

    return db.changes() > 0;
}

pub fn markSuccess(allocator: std.mem.Allocator, db: *Backend, routine_id: []const u8, next_run_at_sqlite: []const u8) !void {
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

pub fn markFailed(allocator: std.mem.Allocator, db: *Backend, routine_id: []const u8, err_msg: []const u8, next_run_at_sqlite: []const u8) !void {
    _ = try db.exec(allocator,
        \\UPDATE workspace_routines
        \\   SET last_status = 'failed',
        \\       last_error = COALESCE(NULLIF(?, ''), ''),
        \\       next_run_at = ?,
        \\       updated_at = datetime('now')
        \\ WHERE id = ?
    , &.{ err_msg, next_run_at_sqlite, routine_id });
}

pub fn reclaimStaleRuns(allocator: std.mem.Allocator, db: *Backend, stale_after_seconds: i64) !usize {
    const err_msg = "run did not finish before its timeout";
    const offset = try std.fmt.allocPrint(allocator, "-{d} seconds", .{stale_after_seconds});
    defer allocator.free(offset);
    _ = try db.exec(allocator,
        \\UPDATE workspace_routines
        \\   SET last_status = 'failed',
        \\       last_error = ?,
        \\       updated_at = datetime('now')
        \\ WHERE last_status = 'running'
        \\   AND updated_at <= datetime('now', ?)
    , &.{ err_msg, offset });
    const changed = db.changes();
    if (changed <= 0) return 0;
    return @intCast(changed);
}

fn nullIfEmpty(allocator: std.mem.Allocator, v: []const u8) !?[]u8 {
    if (v.len == 0) return null;
    return try allocator.dupe(u8, v);
}

fn nullIfEmptyConst(v: []const u8) ?[]const u8 {
    if (v.len == 0) return null;
    return v;
}

// ===== Tests merged from model_test.zig (2026-09-29 flatten) =====
// Behavioral tests for the `workspace_routines` model (Task 3 of the
// workspace-items-routines plan).

const testing = std.testing;

const sqlite = pabrikcore.sqlite;
const database = pabrikcore.database;

const migration = pabrikcore.migrations_mod.migration;
const Migration084ReplaceRoutinesWithWorkspaceRoutines = migration.Migration084ReplaceRoutinesWithWorkspaceRoutines;
const Migration124AddRoutineSelectedProfileModel = migration.Migration124AddRoutineSelectedProfileModel;

// ─── Test helpers ─────────────────────────────────────────────────────────

/// Open a fresh in-memory sqlite DB with the minimal parent tables,
/// then run Migration 084 to bring it to the post-migration state.
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
    try Migration124AddRoutineSelectedProfileModel.up(&db, alloc);

    return .{ .db = db, .threaded = threaded };
}

/// Run a single-column SELECT and return a duplicated copy of the
/// first row's first column. Returns null when the query produces no
/// rows.
fn scalarText(alloc: std.mem.Allocator, db: *database.Db, sql: []const u8, args: []const []const u8) !?[]u8 {
    var q = try db.query(alloc, sql, args);
    defer q.deinit();
    if (try q.next()) |row| {
        defer row.deinit(alloc);
        return try alloc.dupe(u8, row.values[0]);
    }
    return null;
}

/// Insert a parent workspace_item row.
fn insertParentItem(db: *database.Db, alloc: std.mem.Allocator, id: []const u8) !void {
    try db.exec(alloc, "INSERT INTO workspace_items (id, workspace_id, item_type) VALUES (?, 'ws1', 'routine')", &.{id});
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

test "Routine: the agent model it chose survives an insert and a load" {
    const alloc = testing.allocator;
    var ctx = try setupDb();
    defer ctx.db.deinit();
    defer ctx.threaded.deinit();

    try insertParentItem(&ctx.db, alloc, "item_1");

    try insertWorkspaceRoutine(alloc, &ctx.db, .{
        .id = "item_1",
        .workspace_item_id = "item_1",
        .instruction = "do the thing",
        .schedule = "0 9 * * *",
        .enabled = true,
        .next_run_at = "2099-01-01 00:00:00",
        .selected_profile_model = "900ribu",
    });

    var loaded = try loadWorkspaceRoutineById(alloc, &ctx.db, "item_1");
    defer loaded.deinit(alloc);

    try testing.expectEqualStrings("900ribu", loaded.selected_profile_model);
}

test "Routine: a routine with no chosen model loads an empty model, not a stale one" {
    const alloc = testing.allocator;
    var ctx = try setupDb();
    defer ctx.db.deinit();
    defer ctx.threaded.deinit();

    try insertParentItem(&ctx.db, alloc, "item_1");

    try insertWorkspaceRoutine(alloc, &ctx.db, .{
        .id = "item_1",
        .workspace_item_id = "item_1",
        .instruction = "do the thing",
        .schedule = "0 9 * * *",
        .enabled = true,
        .next_run_at = "2099-01-01 00:00:00",
    });

    var loaded = try loadWorkspaceRoutineById(alloc, &ctx.db, "item_1");
    defer loaded.deinit(alloc);

    try testing.expectEqualStrings("", loaded.selected_profile_model);
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
    const status = try scalarText(alloc, &ctx.db, "SELECT last_status FROM workspace_routines WHERE id = 'item_1'", &.{});
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

test "Routine: reclaimStaleRuns fails only the runs that outlived the timeout" {
    const alloc = testing.allocator;
    var ctx = try setupDb();
    defer ctx.db.deinit();
    defer ctx.threaded.deinit();

    try insertParentItem(&ctx.db, alloc, "item_1");
    try insertParentItem(&ctx.db, alloc, "item_2");
    try insertWorkspaceRoutine(alloc, &ctx.db, .{
        .id = "item_1",
        .workspace_item_id = "item_1",
        .instruction = "slow",
        .schedule = "0 9 * * *",
        .enabled = true,
        .next_run_at = "2000-01-01 00:00:00",
    });
    try insertWorkspaceRoutine(alloc, &ctx.db, .{
        .id = "item_2",
        .workspace_item_id = "item_2",
        .instruction = "fresh",
        .schedule = "0 9 * * *",
        .enabled = true,
        .next_run_at = "2000-01-01 00:00:00",
    });
    _ = try claimForRun(alloc, &ctx.db, "item_1");
    _ = try claimForRun(alloc, &ctx.db, "item_2");
    try ctx.db.exec(alloc, "UPDATE workspace_routines SET updated_at = datetime('now', '-2 hours') WHERE id = 'item_1'", &.{});

    const reclaimed = try reclaimStaleRuns(alloc, &ctx.db, 30 * 60);

    try testing.expectEqual(@as(usize, 1), reclaimed);
    var stale = try loadWorkspaceRoutineById(alloc, &ctx.db, "item_1");
    defer stale.deinit(alloc);
    var fresh = try loadWorkspaceRoutineById(alloc, &ctx.db, "item_2");
    defer fresh.deinit(alloc);
    try testing.expectEqual(RoutineRunStatus.failed, stale.last_status);
    try testing.expectEqualStrings("run did not finish before its timeout", stale.last_error.?);
    try testing.expectEqual(RoutineRunStatus.running, fresh.last_status);
}

test "Routine: a routine is not due while its previous run is still in flight" {
    const alloc = testing.allocator;
    var ctx = try setupDb();
    defer ctx.db.deinit();
    defer ctx.threaded.deinit();

    try insertParentItem(&ctx.db, alloc, "item_1");
    try insertWorkspaceRoutine(alloc, &ctx.db, .{
        .id = "item_1",
        .workspace_item_id = "item_1",
        .instruction = "slow",
        .schedule = "* * * * *",
        .enabled = true,
        .next_run_at = "2000-01-01 00:00:00",
    });

    const before = try listDueWorkspaceRoutineIds(alloc, &ctx.db, "2025-01-01 00:00:00");
    defer {
        for (before) |id| alloc.free(id);
        alloc.free(before);
    }
    try testing.expectEqual(@as(usize, 1), before.len);

    _ = try claimForRun(alloc, &ctx.db, "item_1");

    const during = try listDueWorkspaceRoutineIds(alloc, &ctx.db, "2025-01-01 00:00:00");
    defer {
        for (during) |id| alloc.free(id);
        alloc.free(during);
    }
    try testing.expectEqual(@as(usize, 0), during.len);
}
