//! `fire.zig` — the per-fire work for a workspace routine. Retargeted from
//! per-task routines (Migration 044) to `workspace_routines` (Migration 084).

const std = @import("std");
const pabrikcore = @import("pabrikcore");
const sqlite = pabrikcore.sqlite;
const database = pabrikcore.database;
const ai_workflow = pabrikcore.ai_mod.ai_workflow;

const model = @import("model.zig");
const cron = @import("cron.zig");

/// Errors returned by `fireWorkspaceRoutine`. These are all SENTINELS — the
/// fire pipeline does NOT propagate underlying errors (e.g.
pub const FireError = error{
    /// No `workspace_routines` row for this id.
    NotARoutine,
    /// The routine exists but `enabled = false`.
    Disabled,
    /// A previous fire is still in flight (`last_status = 'running'`).
    AlreadyRunning,
};

/// Fire a single workspace routine.
pub fn fireWorkspaceRoutine(
    allocator: std.mem.Allocator,
    db: *database.Db,
    di: *pabrikcore.App,
    io: std.Io,
    routine_id: []const u8,
) anyerror!void {
    // 1) Load the routine row. A missing row means the id is not a
    //    workspace routine.
    const routine = model.loadWorkspaceRoutineById(allocator, db, routine_id) catch |err| switch (err) {
        error.RoutineNotFound => return FireError.NotARoutine,
        else => return err,
    };
    defer routine.deinit(allocator);

    if (!routine.enabled) return FireError.Disabled;

    // 2) Atomic claim. `claimForRun` is a single conditional UPDATE;
    //    a second concurrent fire on the same row sees zero affected
    //    rows and `claimForRun` returns false.
    if (!try model.claimForRun(allocator, db, routine.id)) return FireError.AlreadyRunning;

    // 3) Compute the new `next_run_at` ONCE and use it for both the
    //    LLM message and the post-submit markSuccess. Manual-only
    //    routines (empty schedule) keep NULL — there is no next fire.
    var next_sqlite: []const u8 = "";
    var next_sqlite_owned: ?[]u8 = null;
    defer if (next_sqlite_owned) |b| allocator.free(b);
    if (routine.schedule.len > 0) {
        const now_ns: i128 = @intCast(std.Io.Timestamp.now(io, .real).nanoseconds);
        const next_ns = try cron.nextFireTime(routine.schedule, now_ns);
        next_sqlite_owned = try formatSqliteDatetime(allocator, next_ns);
        next_sqlite = next_sqlite_owned.?;
    }

    // 4) Heap-allocate strings for the concurrent task. The callback owns
    // these and frees them when done (mirrors `session_create.zig:141-159`).
    const sid = try di.allocator.dupe(u8, routine.id);
    errdefer di.allocator.free(sid);
    const schedule_label = if (routine.schedule.len > 0) routine.schedule else "(manual)";
    const qmsg = try formatRoutineMessage(di.allocator, schedule_label, routine.instruction, next_sqlite);
    errdefer di.allocator.free(qmsg);
    const cwd = try di.allocator.dupe(u8, "");
    errdefer di.allocator.free(cwd);
    const bmsg = try di.allocator.dupe(u8, "");
    errdefer di.allocator.free(bmsg);
    const atools = try di.allocator.dupe(u8, "");
    errdefer di.allocator.free(atools);
    const iurls = try di.allocator.dupe(u8, "");
    errdefer di.allocator.free(iurls);
    const spm = try di.allocator.dupe(u8, "");
    errdefer di.allocator.free(spm);

    // 5) Submit the LLM work to the Io group. The callback emits the event;
    // the Io runtime processes the event via `CallbackAiWorkerFlow` in a
    // worker thread.
    try di.group_emit_session_create.concurrent(
        io,
        runFire,
        .{ di, sid, qmsg, cwd, bmsg, atools, iurls, spm },
    );

    // 6) Mark success and advance next_run_at. The LLM is fire-and-forget —
    // we don't wait for it to complete before marking success.
    try model.markSuccess(allocator, db, routine.id, next_sqlite);
}

/// Callback for `group_emit_session_create.concurrent`. Emits the LLM event
/// to the event bus.
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
}

// ─── Helpers ──────────────────────────────────────────────────────────────

/// Format the user-style message that gets sent to the LLM when a routine
/// fires.
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

/// Convert unix nanos (i128) to a SQLite DATETIME literal `YYYY-MM-DD
/// HH:MM:SS`.
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
    try db.init(io, ":memory:");

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

fn insertParentItem(db: *database.Db, alloc: std.mem.Allocator, id: []const u8) !void {
    try db.exec(alloc,
        "INSERT INTO workspace_items (id, workspace_id, item_type) VALUES (?, 'ws1', 'routine')",
        &.{id});
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
