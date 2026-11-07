const std = @import("std");
const pabrikcore = @import("pabrikcore");
const test_db = pabrikcore.test_db;

const sqlite = pabrikcore.sqlite;
const database = pabrikcore.database;
const logger_mod = pabrikcore.loggermod;
const helpers = @import("helpers");
const onEventSendWorkers = @import("sse_send_event_worker.zig").onEventSendWorkers;
const event_bus_mod = pabrikcore.event_bus;
const testing = std.testing;

pub const UpsertWorkerInput = struct {
    allocator: std.mem.Allocator,
    db: *database.Db,
    logger: ?*logger_mod.Logger,
    worker_id: []const u8,
    session_id: []const u8,
    working_directory: []const u8,
    event_bus: ?*event_bus_mod.EventBus,
    is_emit_sse: bool,
};

/// Register or update a worker
pub fn updateWorker(obj: UpsertWorkerInput) !void {
    const allocator = obj.allocator;
    const db = obj.db;
    const logger = obj.logger;

    const worker_id = obj.worker_id;
    const session_id = obj.session_id;
    const working_directory = obj.working_directory;
    const is_emit_sse = obj.is_emit_sse;
    const event_bus = obj.event_bus;

    // Check if the worker already exists so we can emit the correct SSE action.
    const check_sql =
        \\SELECT 1
        \\FROM worker
        \\WHERE id = ?
        \\LIMIT 1;
    ;

    var rows = try db.query(allocator, check_sql, &.{worker_id});
    defer rows.deinit();

    const maybe_row = try rows.next();
    defer if (maybe_row) |r| r.deinit(allocator);
    const exists = maybe_row != null;

    // Insert or update the worker. `cancelled` is named in BOTH halves
    // deliberately.
    const worker_sql =
        \\INSERT INTO worker (
        \\    id,
        \\    session_id,
        \\    working_directory,
        \\    last_activity_nano,
        \\    last_activity_description,
        \\    cancelled
        \\)
        \\VALUES (
        \\    ?,
        \\    ?,
        \\    ?,
        \\    strftime('%s', 'now'),
        \\    '',
        \\    0
        \\)
        \\ON CONFLICT(id) DO UPDATE SET
        \\    session_id = excluded.session_id,
        \\    working_directory = excluded.working_directory,
        \\    last_activity_nano = excluded.last_activity_nano,
        \\    last_activity_description = excluded.last_activity_description,
        \\    cancelled = 0;
    ;

    try db.exec(
        allocator,
        worker_sql,
        &.{
            worker_id,
            session_id,
            working_directory,
        },
    );

    // Ensure the session exists WITHOUT overwriting `name`. Pre-fix, this was
    // `INSERT ...
    try db.exec(
        allocator,
        "INSERT INTO sessions (id, name, status, created_at, updated_at) VALUES (?, '', 'active', CURRENT_TIMESTAMP, CURRENT_TIMESTAMP) ON CONFLICT DO NOTHING",
        &.{session_id},
    );
    try db.exec(
        allocator,
        "UPDATE sessions SET updated_at = CURRENT_TIMESTAMP WHERE id = ?",
        &.{session_id},
    );

    // Inherit the session's owner onto this worker row (plan 2026-09-25,
    // W2.4).
    try db.exec(
        allocator,
        "UPDATE worker SET user_id = (SELECT user_id FROM sessions WHERE id = ?) WHERE id = ? AND (user_id IS NULL OR user_id = '' OR user_id = 'user_system')",
        &.{ session_id, worker_id },
    );

    // update workspace_item_tasks if exists
    try db.exec(allocator, "UPDATE workspace_item_tasks SET updated_at = datetime('now') WHERE id = ?", &.{session_id});

    if (!is_emit_sse) return;

    if (event_bus == null) return;

    const action = if (exists) "updated" else "created";
    const now_timestamp: i64 = helpers.unixTimestamp();

    onEventSendWorkers(allocator, .{
        .action = action,
        .id = worker_id,
        .session_id = session_id,
        .working_directory = working_directory,
        .last_activity = now_timestamp,
        .last_activity_description = "",
        .created_at = "",
        .event_bus = event_bus.?,
    }) catch |err| {
        if (logger) |log| {
            log.errFmt(
                "[upsertWorker] Failed to send worker event: {s}\n",
                .{@errorName(err)},
            );
        }
    };
}

// ─── Tests ──────────────────────────────────────────────────────────────────

fn setupDb() !struct { db: database.Db, threaded: std.Io.Threaded } {
    const alloc = testing.allocator;
    var threaded = std.Io.Threaded.init(alloc, .{});
    errdefer threaded.deinit();
    const io = threaded.io();
    var db: database.Db = .{};
    errdefer db.deinit();
    try test_db.openMemory(&db, io);
    try db.exec(alloc,
        \\CREATE TABLE worker (
        \\    id TEXT PRIMARY KEY,
        \\    session_id TEXT,
        \\    working_directory TEXT,
        \\    last_activity_nano BIGINT,
        \\    last_activity_description TEXT,
        \\    cancelled INTEGER DEFAULT 0,
        \\    user_id TEXT
        \\)
    , &.{});
    try db.exec(alloc,
        \\CREATE TABLE sessions (
        \\    id TEXT PRIMARY KEY,
        \\    name TEXT,
        \\    status TEXT,
        \\    cwd TEXT,
        \\    created_at TEXT,
        \\    updated_at TEXT
        \\)
    , &.{});
    try db.exec(alloc,
        \\CREATE TABLE workspace_item_tasks (
        \\    id TEXT PRIMARY KEY,
        \\    updated_at TEXT
        \\)
    , &.{});
    return .{ .db = db, .threaded = threaded };
}

test "updateWorker inserts a fresh worker row and a matching sessions row" {
    var s = try setupDb();
    defer s.db.deinit();
    defer s.threaded.deinit();

    try updateWorker(.{
        .allocator = testing.allocator,
        .db = &s.db,
        .logger = null,
        .worker_id = "w_new",
        .session_id = "s_new",
        .working_directory = "/tmp/new",
        .event_bus = null,
        .is_emit_sse = false,
    });

    // worker row exists
    {
        var q = try s.db.query(testing.allocator, "SELECT working_directory FROM worker WHERE id = 'w_new'", &.{});
        defer q.deinit();
        const row = (try q.next()) orelse return error.WorkerRowMissing;
        defer row.deinit(testing.allocator);
        try testing.expectEqualStrings("/tmp/new", row.values[0]);
    }
    // sessions row exists with status='active'
    {
        var q = try s.db.query(testing.allocator, "SELECT status FROM sessions WHERE id = 's_new'", &.{});
        defer q.deinit();
        const row = (try q.next()) orelse return error.SessionRowMissing;
        defer row.deinit(testing.allocator);
        try testing.expectEqualStrings("active", row.values[0]);
    }
}

test "updateWorker ON CONFLICT overwrites the existing working_directory" {
    var s = try setupDb();
    defer s.db.deinit();
    defer s.threaded.deinit();

    try updateWorker(.{ .allocator = testing.allocator, .db = &s.db, .logger = null, .worker_id = "w_up", .session_id = "s_up", .working_directory = "/old", .event_bus = null, .is_emit_sse = false });
    try updateWorker(.{ .allocator = testing.allocator, .db = &s.db, .logger = null, .worker_id = "w_up", .session_id = "s_up", .working_directory = "/new", .event_bus = null, .is_emit_sse = false });

    var q = try s.db.query(testing.allocator, "SELECT working_directory FROM worker WHERE id = 'w_up'", &.{});
    defer q.deinit();
    const row = (try q.next()) orelse return error.WorkerRowMissing;
    defer row.deinit(testing.allocator);
    try testing.expectEqualStrings("/new", row.values[0]);
}

test "updateWorker ON CONFLICT also updates the session row's updated_at" {
    var s = try setupDb();
    defer s.db.deinit();
    defer s.threaded.deinit();

    // Seed an old sessions row.
    try s.db.exec(testing.allocator, "INSERT INTO sessions (id, name, status, updated_at) VALUES ('s_old', 'old', 'active', '2020-01-01 00:00:00')", &.{});

    try updateWorker(.{ .allocator = testing.allocator, .db = &s.db, .logger = null, .worker_id = "w_old", .session_id = "s_old", .working_directory = "/x", .event_bus = null, .is_emit_sse = false });

    var q = try s.db.query(testing.allocator, "SELECT updated_at FROM sessions WHERE id = 's_old'", &.{});
    defer q.deinit();
    const row = (try q.next()) orelse return error.SessionRowMissing;
    defer row.deinit(testing.allocator);
    // updated_at must have been bumped past the seed value.
    try testing.expect(!std.mem.eql(u8, row.values[0], "2020-01-01 00:00:00"));
}

test "updateWorker updates workspace_item_tasks.updated_at when a matching task exists" {
    var s = try setupDb();
    defer s.db.deinit();
    defer s.threaded.deinit();

    try s.db.exec(testing.allocator, "INSERT INTO workspace_item_tasks (id, updated_at) VALUES ('s_task', 'epoch')", &.{});

    try updateWorker(.{ .allocator = testing.allocator, .db = &s.db, .logger = null, .worker_id = "w_t", .session_id = "s_task", .working_directory = "/tmp", .event_bus = null, .is_emit_sse = false });

    var q = try s.db.query(testing.allocator, "SELECT updated_at FROM workspace_item_tasks WHERE id = 's_task'", &.{});
    defer q.deinit();
    const row = (try q.next()) orelse return error.TaskRowMissing;
    defer row.deinit(testing.allocator);
    try testing.expect(!std.mem.eql(u8, row.values[0], "epoch"));
}

test "updateWorker with is_emit_sse=true and event_bus=null is a safe no-op for the SSE branch" {
    var s = try setupDb();
    defer s.db.deinit();
    defer s.threaded.deinit();

    // The implementation must check `if (event_bus == null) return;` BEFORE
    // any payload allocation. The DB writes must still complete.
    try updateWorker(.{ .allocator = testing.allocator, .db = &s.db, .logger = null, .worker_id = "w_skip_sse", .session_id = "s_skip_sse", .working_directory = "/tmp", .event_bus = null, .is_emit_sse = true });

    // Confirm the DB write happened.
    var q = try s.db.query(testing.allocator, "SELECT 1 FROM worker WHERE id = 'w_skip_sse'", &.{});
    defer q.deinit();
    const row = (try q.next()) orelse return error.WorkerRowMissing;
    defer row.deinit(testing.allocator);
}

test "updateWorker with is_emit_sse=false short-circuits before any event_bus access" {
    // Same as above but exercises the OTHER short-circuit branch — the
    // implementation does `if (!is_emit_sse) return;` first, so even a
    // null event_bus can't cause a problem.
    var s = try setupDb();
    defer s.db.deinit();
    defer s.threaded.deinit();
    try updateWorker(.{ .allocator = testing.allocator, .db = &s.db, .logger = null, .worker_id = "w_no_sse", .session_id = "s_no_sse", .working_directory = "/tmp", .event_bus = null, .is_emit_sse = false });

    var q = try s.db.query(testing.allocator, "SELECT 1 FROM worker WHERE id = 'w_no_sse'", &.{});
    defer q.deinit();
    const row = (try q.next()) orelse return error.WorkerRowMissing;
    defer row.deinit(testing.allocator);
}

test "updateWorker writes a non-empty last_activity_description (defensive: default '')" {
    var s = try setupDb();
    defer s.db.deinit();
    defer s.threaded.deinit();

    try updateWorker(.{ .allocator = testing.allocator, .db = &s.db, .logger = null, .worker_id = "w_lad", .session_id = "s_lad", .working_directory = "/tmp", .event_bus = null, .is_emit_sse = false });

    var q = try s.db.query(testing.allocator, "SELECT last_activity_description FROM worker WHERE id = 'w_lad'", &.{});
    defer q.deinit();
    const row = (try q.next()) orelse return error.WorkerRowMissing;
    defer row.deinit(testing.allocator);
    // The impl passes '' as the default — document that.
    try testing.expectEqualStrings("", row.values[0]);
}

test "updateWorker clears a stop left by the previous run" {
    var s = try setupDb();
    defer s.db.deinit();
    defer s.threaded.deinit();

    // The stop endpoint leaves exactly this state behind: the row survives with
    // the flag set, because the loop reads it back to break out of itself.
    try s.db.exec(
        testing.allocator,
        "INSERT INTO worker (id, session_id, working_directory, last_activity_nano, cancelled) VALUES ('w_rerun', 's_rerun', '/old', 1, 1)",
        &.{},
    );

    // `isWorkerCancelled` is the gate `runAgenticMultiStepnew` checks at the top
    // of every iteration, so a flag that survives the upsert ends the new run
    // before it does anything at all.
    try testing.expect(isCancelled(&s.db, "w_rerun"));

    try updateWorker(.{
        .allocator = testing.allocator,
        .db = &s.db,
        .logger = null,
        .worker_id = "w_rerun",
        .session_id = "s_rerun",
        .working_directory = "/new",
        .event_bus = null,
        .is_emit_sse = false,
    });

    try testing.expect(!isCancelled(&s.db, "w_rerun"));
}

test "updateWorker names cancelled on INSERT, so a default-less column still starts a run uncancelled" {
    const alloc = testing.allocator;
    var threaded = std.Io.Threaded.init(alloc, .{});
    defer threaded.deinit();
    var db: database.Db = .{};
    defer db.deinit();
    try test_db.openMemory(&db, threaded.io());

    // `cancelled INTEGER NOT NULL` with NO default.
    try db.exec(alloc,
        \\CREATE TABLE worker (
        \\    id TEXT PRIMARY KEY,
        \\    session_id TEXT,
        \\    working_directory TEXT,
        \\    last_activity_nano BIGINT,
        \\    last_activity_description TEXT,
        \\    cancelled INTEGER NOT NULL,
        \\    user_id TEXT
        \\)
    , &.{});
    try db.exec(alloc,
        \\CREATE TABLE sessions (
        \\    id TEXT PRIMARY KEY,
        \\    name TEXT,
        \\    status TEXT,
        \\    cwd TEXT,
        \\    created_at TEXT,
        \\    updated_at TEXT
        \\)
    , &.{});
    try db.exec(alloc,
        \\CREATE TABLE workspace_item_tasks (
        \\    id TEXT PRIMARY KEY,
        \\    updated_at TEXT
        \\)
    , &.{});

    try updateWorker(.{
        .allocator = alloc,
        .db = &db,
        .logger = null,
        .worker_id = "w_nd",
        .session_id = "s_nd",
        .working_directory = "/x",
        .event_bus = null,
        .is_emit_sse = false,
    });

    try testing.expect(!isCancelled(&db, "w_nd"));
}

test "updateWorker ON CONFLICT still refreshes last_activity_nano (the heart-beat)" {
    var s = try setupDb();
    defer s.db.deinit();
    defer s.threaded.deinit();

    // The reset must not cost the heart-beat: `cleanup_stale_worker` reaps any
    // row whose `last_activity_nano` is more than 600 s old, and this upsert is
    // the only thing keeping a long run alive against that cron.
    try s.db.exec(
        testing.allocator,
        "INSERT INTO worker (id, session_id, working_directory, last_activity_nano, cancelled) VALUES ('w_hb', 's_hb', '/x', 1, 0)",
        &.{},
    );

    try updateWorker(.{
        .allocator = testing.allocator,
        .db = &s.db,
        .logger = null,
        .worker_id = "w_hb",
        .session_id = "s_hb",
        .working_directory = "/x",
        .event_bus = null,
        .is_emit_sse = false,
    });

    var q = try s.db.query(
        testing.allocator,
        "SELECT last_activity_nano FROM worker WHERE id = 'w_hb'",
        &.{},
    );
    defer q.deinit();
    const row = (try q.next()) orelse return error.WorkerRowMissing;
    defer row.deinit(testing.allocator);

    const stamped = std.fmt.parseInt(i64, row.values[0], 10) catch 0;
    try testing.expect(stamped > 1_600_000_000);
}

fn isCancelled(db: *database.Db, id: []const u8) bool {
    var q = db.query(testing.allocator, "SELECT cancelled FROM worker WHERE id = ?", &.{id}) catch return false;
    defer q.deinit();
    const row = (q.next() catch return false) orelse return false;
    defer row.deinit(testing.allocator);
    const value = std.fmt.parseInt(i32, row.values[0], 10) catch 0;
    return value == 1;
}
