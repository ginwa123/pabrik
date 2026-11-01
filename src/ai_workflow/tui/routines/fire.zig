const std = @import("std");
const pabrikcore = @import("pabrikcore");
const test_db = pabrikcore.test_db;
const sqlite = pabrikcore.sqlite;
const database = pabrikcore.database;
const ai_workflow = pabrikcore.ai_mod.ai_workflow;

const model = @import("model.zig");
const cron = @import("cron.zig");

pub const FireError = error{
    NotARoutine,
    Disabled,
    AlreadyRunning,
};

pub fn fireWorkspaceRoutine(
    allocator: std.mem.Allocator,
    db: *database.Db,
    di: *pabrikcore.App,
    io: std.Io,
    routine_id: []const u8,
) anyerror!void {
    const routine = model.loadWorkspaceRoutineById(allocator, db, routine_id) catch |err| switch (err) {
        error.RoutineNotFound => return FireError.NotARoutine,
        else => return err,
    };
    defer routine.deinit(allocator);

    if (!routine.enabled) return FireError.Disabled;

    if (!try model.claimForRun(allocator, db, routine.id)) return FireError.AlreadyRunning;

    var next_sqlite: []const u8 = "";
    var next_sqlite_owned: ?[]u8 = null;
    defer if (next_sqlite_owned) |b| allocator.free(b);
    if (routine.schedule.len > 0) {
        const now_ns: i128 = @intCast(std.Io.Timestamp.now(io, .real).nanoseconds);
        const next_ns = cron.nextFireTime(routine.schedule, now_ns) catch |err| {
            try model.markFailed(allocator, db, routine.id, "schedule is not a valid cron expression", "");
            return err;
        };
        next_sqlite_owned = try formatSqliteDatetime(allocator, next_ns);
        next_sqlite = next_sqlite_owned.?;
    }

    const sid = try di.allocator.dupe(u8, routine.id);
    errdefer di.allocator.free(sid);
    const payload = try buildPayload(di.allocator, routine, next_sqlite);
    errdefer payload.deinit(di.allocator);
    const cwd = try di.allocator.dupe(u8, "");
    errdefer di.allocator.free(cwd);
    const bmsg = try di.allocator.dupe(u8, "");
    errdefer di.allocator.free(bmsg);
    const atools = try di.allocator.dupe(u8, "");
    errdefer di.allocator.free(atools);
    const iurls = try di.allocator.dupe(u8, "");
    errdefer di.allocator.free(iurls);

    try di.group_emit_session_create.concurrent(
        io,
        runFire,
        .{ di, sid, payload.message, cwd, bmsg, atools, iurls, payload.selected_profile_model },
    );
}

/// The two slices are allocator-owned: free them with deinit, or hand them to
/// the fire — which frees them itself. Never both.
pub const Payload = struct {
    message: []u8,
    selected_profile_model: []u8,

    pub fn deinit(self: Payload, allocator: std.mem.Allocator) void {
        allocator.free(self.message);
        allocator.free(self.selected_profile_model);
    }
};

pub fn buildPayload(
    allocator: std.mem.Allocator,
    routine: model.Routine,
    next_run_at_sqlite: []const u8,
) !Payload {
    const schedule_label = if (routine.schedule.len > 0) routine.schedule else "(manual)";
    const message = try formatRoutineMessage(allocator, schedule_label, routine.instruction, next_run_at_sqlite);
    errdefer allocator.free(message);
    return .{
        .message = message,
        .selected_profile_model = try allocator.dupe(u8, routine.selected_profile_model),
    };
}

fn runFire(
    di: *pabrikcore.App,
    sid: []u8,
    qmsg: []u8,
    cwd: []u8,
    bmsg: []u8,
    atools: []u8,
    iurls: []u8,
    spm: []u8,
) void {
    defer di.allocator.free(sid);
    defer di.allocator.free(qmsg);
    defer di.allocator.free(cwd);
    defer di.allocator.free(bmsg);
    defer di.allocator.free(atools);
    defer di.allocator.free(iurls);
    defer di.allocator.free(spm);

    di.event_bus.emit(ai_workflow.RunParamsNew, "ai_worker_flow", .{
        .parent_session_id = sid,
        .session_id = sid,
        .message = qmsg,
        .cwd = cwd,
        .body = bmsg,
        .allowed_tools = atools,
        .is_sub_agent = false,
        .image_urls = iurls,
        .selected_profile_model = spm,
    });

    markRunFinished(di.allocator, di.db, sid, @intCast(std.Io.Timestamp.now(di.io, .real).nanoseconds)) catch |err| {
        if (pabrikcore.loggermod.getGlobal()) |logger| {
            logger.warnFmt("routine fire: could not record the run outcome for {s}: {s}", .{ sid, @errorName(err) });
        }
    };
}

pub fn markRunFinished(
    allocator: std.mem.Allocator,
    db: *database.Db,
    routine_id: []const u8,
    now_unix_nanos: i128,
) !void {
    const routine = model.loadWorkspaceRoutineById(allocator, db, routine_id) catch |err| switch (err) {
        error.RoutineNotFound => return,
        else => return err,
    };
    defer routine.deinit(allocator);

    var next_sqlite: []const u8 = "";
    var next_sqlite_owned: ?[]u8 = null;
    defer if (next_sqlite_owned) |b| allocator.free(b);
    if (routine.enabled and routine.schedule.len > 0) {
        const next_ns = cron.nextFireTime(routine.schedule, now_unix_nanos) catch {
            try model.markFailed(allocator, db, routine_id, "schedule is not a valid cron expression", "");
            return;
        };
        next_sqlite_owned = try formatSqliteDatetime(allocator, next_ns);
        next_sqlite = next_sqlite_owned.?;
    }

    try model.markSuccess(allocator, db, routine_id, next_sqlite);
}

pub fn formatRoutineMessage(
    allocator: std.mem.Allocator,
    schedule: []const u8,
    instruction: []const u8,
    next_run_at_sqlite: []const u8,
) ![]u8 {
    return std.fmt.allocPrint(allocator, "This is an automated workspace-routine fire.\n" ++
        "- Schedule: {s}\n" ++
        "- Next fire: {s}\n" ++
        "\n" ++
        "{s}", .{ schedule, next_run_at_sqlite, instruction });
}

pub fn formatSqliteDatetime(allocator: std.mem.Allocator, unix_nanos: i128) ![]u8 {
    const secs: i64 = @intCast(@divTrunc(unix_nanos, std.time.ns_per_s));
    const epoch_seconds: std.time.epoch.EpochSeconds = .{ .secs = @intCast(secs) };
    const day_seconds = epoch_seconds.getDaySeconds();
    const year_day = epoch_seconds.getEpochDay().calculateYearDay();
    const month_day = year_day.calculateMonthDay();
    return std.fmt.allocPrint(allocator, "{d:04}-{d:02}-{d:02} {d:02}:{d:02}:{d:02}", .{
        year_day.year,
        month_day.month.numeric(),
        month_day.day_index + 1,
        @as(u32, @intCast(day_seconds.getHoursIntoDay())),
        @as(u32, @intCast(day_seconds.getMinutesIntoHour())),
        @as(u32, @intCast(day_seconds.getSecondsIntoMinute())),
    });
}

// ===== Tests merged from fire_test.zig (2026-09-29 flatten) ===== Behavioral
// tests for `fire.zig` (Task 3 of the workspace-items-routines plan).

const testing = std.testing;

const migration = pabrikcore.migrations_mod.migration;
const Migration084ReplaceRoutinesWithWorkspaceRoutines = migration.Migration084ReplaceRoutinesWithWorkspaceRoutines;
const Migration124AddRoutineSelectedProfileModel = migration.Migration124AddRoutineSelectedProfileModel;

// ─── Test helpers ─────────────────────────────────────────────────────────

/// Open a fresh in-memory sqlite DB with the minimal parent tables,
/// then run Migration 084. Mirrors the helper in `model.zig`.
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
    try Migration124AddRoutineSelectedProfileModel.up(&db, alloc);

    return .{ .db = db, .threaded = threaded };
}

fn insertParentItem(db: *database.Db, alloc: std.mem.Allocator, id: []const u8) !void {
    try db.exec(alloc, "INSERT INTO workspace_items (id, workspace_id, item_type) VALUES (?, 'ws1', 'routine')", &.{id});
}

// ─── Test 1: atomic claim (second fire returns AlreadyRunning) ────────────

test "fireWorkspaceRoutine rejects a second concurrent fire (atomic claim)" {
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
        .next_run_at = "2000-01-01 00:00:00",
    });
    // Pre-claim the row by setting last_status to 'running'.
    try ctx.db.exec(alloc, "UPDATE workspace_routines SET last_status = 'running' WHERE id = 'item_1'", &.{});

    const err = fireWorkspaceRoutine(alloc, &ctx.db, undefined, ctx.threaded.io(), "item_1") catch |e| e;
    try testing.expectEqual(FireError.AlreadyRunning, err);

    const status_dup = blk: {
        var q = try ctx.db.query(alloc, "SELECT last_status FROM workspace_routines WHERE id = 'item_1'", &.{});
        defer q.deinit();
        const row = (try q.next()) orelse return error.TestFailed;
        defer row.deinit(alloc);
        // Dup the slice so the test can read it after row.deinit
        // fires (otherwise row.values[0] becomes a dangling slice
        // and the expectEqualStrings call below segfaults in debug).
        break :blk try alloc.dupe(u8, row.values[0]);
    };
    defer alloc.free(status_dup);
    try testing.expectEqualStrings("running", status_dup);
}

// ─── Test 2: id with no routine row returns NotARoutine ───────────────────

test "fireWorkspaceRoutine on a non-routine id returns NotARoutine" {
    const alloc = testing.allocator;
    var ctx = try setupDb();
    defer ctx.db.deinit();
    defer ctx.threaded.deinit();

    // `di` is not read on the `NotARoutine` path (the load fails
    // before the di.group_emit call), so `undefined` is safe.
    const err = fireWorkspaceRoutine(alloc, &ctx.db, undefined, ctx.threaded.io(), "nope") catch |e| e;
    try testing.expectEqual(FireError.NotARoutine, err);
}

// ─── Test 3: disabled routine returns Disabled ───────────────────────────

test "fireWorkspaceRoutine on a disabled routine returns Disabled" {
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
        .enabled = false,
        .next_run_at = "2000-01-01 00:00:00",
    });

    // `di` is not read on the `Disabled` path (the disabled check
    // runs before the claim), so `undefined` is safe.
    const err = fireWorkspaceRoutine(alloc, &ctx.db, undefined, ctx.threaded.io(), "item_1") catch |e| e;
    try testing.expectEqual(FireError.Disabled, err);

    // The row must still be disabled (the disabled check returns
    // before the claim, so last_status is unchanged).
    const enabled_int = blk: {
        var q = try ctx.db.query(alloc, "SELECT enabled FROM workspace_routines WHERE id = 'item_1'", &.{});
        defer q.deinit();
        const row = (try q.next()) orelse return error.TestFailed;
        defer row.deinit(alloc);
        // The Row's slice is freed by `row.deinit(alloc)` above; parse
        // it into a value (i64) before the defer fires.
        break :blk try std.fmt.parseInt(i64, row.values[0], 10);
    };
    try testing.expectEqual(@as(i64, 0), enabled_int);
}

// ─── Test 4: formatRoutineMessage wraps the instruction with context ──────

test "formatRoutineMessage produces a structured metadata header followed by the instruction" {
    const alloc = testing.allocator;
    const msg = try formatRoutineMessage(
        alloc,
        "*/5 * * * *",
        "do the thing",
        "2025-01-15 09:00:00",
    );
    defer alloc.free(msg);
    const expected =
        "This is an automated workspace-routine fire.\n" ++
        "- Schedule: */5 * * * *\n" ++
        "- Next fire: 2025-01-15 09:00:00\n" ++
        "\n" ++
        "do the thing";
    try testing.expectEqualStrings(expected, msg);
}

test "formatRoutineMessage preserves multi-line and special-char instruction verbatim" {
    // The `{s}` format specifier embeds the slice bytes literally — the
    // routine's `instruction` may contain newlines, colons, and other
    // punctuation that the LLM needs to see unchanged.
    const alloc = testing.allocator;
    const msg = try formatRoutineMessage(
        alloc,
        "0 9 * * 1-5",
        "step 1: read logs\nstep 2: summarize",
        "2025-01-20 09:00:00",
    );
    defer alloc.free(msg);
    try testing.expect(std.mem.indexOf(u8, msg, "step 1: read logs\nstep 2: summarize") != null);
    try testing.expect(std.mem.indexOf(u8, msg, "- Schedule: 0 9 * * 1-5") != null);
    try testing.expect(std.mem.indexOf(u8, msg, "- Next fire: 2025-01-20 09:00:00") != null);
}

test "formatRoutineMessage places metadata header first and instruction last" {
    // The LLM-friendly property: meta header is the FIRST thing the LLM reads
    // (sets context), the actual task is the LAST thing (clear instruction
    // boundary), and they're separated by a blank line.
    const alloc = testing.allocator;
    const msg = try formatRoutineMessage(
        alloc,
        "*/5 * * * *",
        "do the thing",
        "2025-01-15 09:00:00",
    );
    defer alloc.free(msg);

    // First line is the meta header.
    try testing.expect(std.mem.startsWith(u8, msg, "This is an automated workspace-routine fire."));

    // The instruction is the trailing text (no trailing newline).
    try testing.expect(std.mem.endsWith(u8, msg, "do the thing"));

    // A blank line separates the meta block from the task.
    try testing.expect(std.mem.indexOf(u8, msg, "\n\n") != null);
}

test "a fire under a routine that chose a model hands that model to the agent workflow" {
    const alloc = testing.allocator;
    const payload = try buildPayload(alloc, .{
        .id = "item_1",
        .workspace_item_id = "item_1",
        .instruction = "collect the security issues",
        .schedule = "0 9 * * *",
        .enabled = true,
        .selected_profile_model = "900ribu",
    }, "2025-01-16 09:00:00");
    defer payload.deinit(alloc);

    try testing.expectEqualStrings("900ribu", payload.selected_profile_model);
    try testing.expect(std.mem.endsWith(u8, payload.message, "collect the security issues"));
}

test "a fire under a routine with no chosen model leaves the agent on the backend cascade" {
    const alloc = testing.allocator;
    const payload = try buildPayload(alloc, .{
        .id = "item_1",
        .workspace_item_id = "item_1",
        .instruction = "collect the security issues",
        .schedule = "",
        .enabled = true,
    }, "");
    defer payload.deinit(alloc);

    try testing.expectEqualStrings("", payload.selected_profile_model);
    try testing.expect(std.mem.indexOf(u8, payload.message, "- Schedule: (manual)") != null);
}

test "markRunFinished records success and schedules the next fire from the completion time" {
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
        .next_run_at = "2025-06-13 09:00:00",
    });
    _ = try model.claimForRun(alloc, &ctx.db, "item_1");

    try markRunFinished(alloc, &ctx.db, "item_1", 1749808800 * std.time.ns_per_s);

    var loaded = try model.loadWorkspaceRoutineById(alloc, &ctx.db, "item_1");
    defer loaded.deinit(alloc);

    try testing.expectEqual(model.RoutineRunStatus.success, loaded.last_status);
    try testing.expectEqualStrings("2025-06-14 09:00:00", loaded.next_run_at.?);
    try testing.expect(loaded.last_run_at != null);
    try testing.expect(loaded.last_error == null);
}

test "markRunFinished leaves a manual-only routine without a next fire" {
    const alloc = testing.allocator;
    var ctx = try setupDb();
    defer ctx.db.deinit();
    defer ctx.threaded.deinit();

    try insertParentItem(&ctx.db, alloc, "item_1");
    try model.insertWorkspaceRoutine(alloc, &ctx.db, .{
        .id = "item_1",
        .workspace_item_id = "item_1",
        .instruction = "x",
        .schedule = "",
        .enabled = true,
        .next_run_at = null,
    });
    _ = try model.claimForRun(alloc, &ctx.db, "item_1");

    try markRunFinished(alloc, &ctx.db, "item_1", 1749808800 * std.time.ns_per_s);

    var loaded = try model.loadWorkspaceRoutineById(alloc, &ctx.db, "item_1");
    defer loaded.deinit(alloc);

    try testing.expectEqual(model.RoutineRunStatus.success, loaded.last_status);
    try testing.expect(loaded.next_run_at == null);
}
