//! One run thread per session, enforced by an OPTIMISTIC lock: the `worker` row
//! is the lock, `worker.run_token` is the lease, and the claim is one
//! compare-and-swap statement — no transaction, because SQLite has one writer.

const std = @import("std");
const pabrikcore = @import("pabrikcore");
const test_db = pabrikcore.test_db;
const helpers = @import("helpers");

const sqlite = pabrikcore.sqlite;
const database = pabrikcore.database;
const testing = std.testing;

/// A claimed session. `token` identifies THIS run; every later write carries it
/// so a run that lost its slot can never touch the row a different run owns.
pub const RunLease = struct {
    allocator: std.mem.Allocator,
    db: *database.Db,
    session_id: []const u8,
    token: []const u8,
};

pub const AcquireInput = struct {
    allocator: std.mem.Allocator,
    db: *database.Db,
    session_id: []const u8,
    working_directory: []const u8,
};

pub const AcquireResult = union(enum) {
    acquired: RunLease,
    busy,
};

/// Per-iteration state, read in the same statement that proves the lease is
/// still ours.
pub const IterationState = struct {
    is_auto_retry_until_stop: bool,
    is_cancelled: bool,
};

var token_counter = std.atomic.Value(u64).init(0);

fn newRunToken(allocator: std.mem.Allocator, io: std.Io) ![]const u8 {
    const now_ns = std.Io.Timestamp.now(io, .real).nanoseconds;
    const n = token_counter.fetchAdd(1, .monotonic);
    // `run-<pid>-<nanos>-<n>`: the pid lets a second process ask whether the
    // owner is still alive before it takes a lease over (see `isOwnerAlive`).
    return std.fmt.allocPrint(allocator, "run-{d}-{d}-{d}", .{
        helpers.process_status.getCurrentProcessIdInt(),
        now_ns,
        n,
    });
}

/// The pid embedded in a lease token, or null when the token was written by an
/// older build (or is empty).
pub fn ownerPid(token: []const u8) ?i32 {
    var it = std.mem.splitScalar(u8, token, '-');
    if (!std.mem.eql(u8, it.next() orelse return null, "run")) return null;
    const pid_text = it.next() orelse return null;
    const pid = std.fmt.parseInt(i32, pid_text, 10) catch return null;
    return if (pid > 0) pid else null;
}

/// Is the process that wrote `token` still running? A token with no pid (an
/// older build) answers `false`, so a boot may take it over.
pub fn isOwnerAlive(token: []const u8) bool {
    const pid = ownerPid(token) orelse return false;
    return helpers.process_status.isProcessRunning(pid);
}

/// Take over a row that carries no lease (a fresh row, or one a previous
/// process left behind). `WHERE ... run_token = ''` is the compare.
const take_free_row_sql =
    \\UPDATE worker
    \\SET session_id = ?,
    \\    working_directory = ?,
    \\    last_activity_nano = strftime('%s', 'now'),
    \\    last_activity_description = '',
    \\    cancelled = 0,
    \\    run_token = ?
    \\WHERE id = ? AND (run_token IS NULL OR run_token = '')
    \\RETURNING run_token;
;

/// No row at all: insert ours. `DO NOTHING` on a concurrent insert turns that
/// race into "no row returned" — the loser reports `.busy` instead of
/// overwriting the winner's lease.
const insert_claim_sql =
    \\INSERT INTO worker (
    \\    id,
    \\    session_id,
    \\    working_directory,
    \\    last_activity_nano,
    \\    last_activity_description,
    \\    cancelled,
    \\    run_token
    \\)
    \\VALUES (
    \\    ?,
    \\    ?,
    \\    ?,
    \\    strftime('%s', 'now'),
    \\    '',
    \\    0,
    \\    ?
    \\)
    \\ON CONFLICT(id) DO NOTHING
    \\RETURNING run_token;
;

/// Claim the session's single run slot. `.busy` means a different run holds the
/// lease right now — the caller must not enter the loop.
pub fn acquire(input: AcquireInput) !AcquireResult {
    const allocator = input.allocator;
    const db = input.db;
    const token = try newRunToken(allocator, db.io);

    if (try claimedRow(
        db,
        allocator,
        take_free_row_sql,
        &.{ input.session_id, input.working_directory, token, input.session_id },
    )) {
        return .{ .acquired = lease(allocator, db, input.session_id, token) };
    }

    if (try claimedRow(
        db,
        allocator,
        insert_claim_sql,
        &.{ input.session_id, input.session_id, input.working_directory, token },
    )) {
        return .{ .acquired = lease(allocator, db, input.session_id, token) };
    }

    return .busy;
}

fn lease(allocator: std.mem.Allocator, db: *database.Db, session_id: []const u8, token: []const u8) RunLease {
    return .{
        .allocator = allocator,
        .db = db,
        .session_id = session_id,
        .token = token,
    };
}

/// Run one claiming statement. A returned row means the statement really
/// changed the row; `RowNotFound` means the `WHERE` matched nothing (held by
/// another run, or a losing insert).
fn claimedRow(
    db: *database.Db,
    allocator: std.mem.Allocator,
    sql: []const u8,
    args: []const []const u8,
) !bool {
    var row = db.queryRow(allocator, sql, args) catch |err| switch (err) {
        error.RowNotFound => return false,
        else => return err,
    };
    row.deinit(allocator);
    return true;
}

/// Re-check the lease and read this iteration's state. `null` means the
/// session is not ours any more (row gone, or another run claimed it) — the
/// loop must leave.
pub fn beginIteration(
    allocator: std.mem.Allocator,
    db: *database.Db,
    session_id: []const u8,
    token: []const u8,
) !?IterationState {
    var row = db.queryRow(
        allocator,
        \\SELECT w.run_token,
        \\       COALESCE(w.cancelled, 0),
        \\       COALESCE(CAST(s.is_auto_retry_until_stop AS TEXT), '0')
        \\FROM worker w
        \\LEFT JOIN sessions s ON s.id = w.session_id
        \\WHERE w.id = ?
    ,
        &.{session_id},
    ) catch |err| switch (err) {
        error.RowNotFound => return null,
        else => return err,
    };
    defer row.deinit(allocator);

    if (!std.mem.eql(u8, row.values[0], token)) return null;

    return .{
        .is_auto_retry_until_stop = std.mem.eql(u8, row.values[2], "1"),
        .is_cancelled = std.mem.eql(u8, row.values[1], "1"),
    };
}

// ─── Tests ──────────────────────────────────────────────────────────────────

const TestCtx = struct {
    db: database.Db,
    threaded: std.Io.Threaded,
};

fn setupDb(alloc: std.mem.Allocator) !TestCtx {
    var threaded = std.Io.Threaded.init(alloc, .{});
    errdefer threaded.deinit();
    var db: database.Db = .{};
    errdefer db.deinit();
    try test_db.openMemory(&db, threaded.io());
    try db.exec(alloc,
        \\CREATE TABLE worker (
        \\    id TEXT PRIMARY KEY,
        \\    session_id TEXT NOT NULL,
        \\    working_directory TEXT,
        \\    last_activity_nano BIGINT,
        \\    last_activity_description TEXT,
        \\    cancelled INTEGER DEFAULT 0,
        \\    run_token TEXT NOT NULL DEFAULT ''
        \\)
    , &.{});
    try db.exec(alloc,
        \\CREATE TABLE sessions (
        \\    id TEXT PRIMARY KEY,
        \\    is_auto_retry_until_stop TEXT
        \\)
    , &.{});
    return .{ .db = db, .threaded = threaded };
}

fn teardown(ctx: *TestCtx) void {
    ctx.db.deinit();
    ctx.threaded.deinit();
}

fn readToken(alloc: std.mem.Allocator, db: *database.Db, session_id: []const u8) ![]const u8 {
    var row = try db.queryRow(alloc, "SELECT run_token FROM worker WHERE id = ?", &.{session_id});
    defer row.deinit(alloc);
    return try alloc.dupe(u8, row.values[0]);
}

test "acquire gives the first run a lease and stamps it on the worker row" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    var ctx = try setupDb(alloc);
    defer teardown(&ctx);

    const result = try acquire(.{
        .allocator = alloc,
        .db = &ctx.db,
        .session_id = "s1",
        .working_directory = "/tmp",
    });

    try testing.expect(result == .acquired);
    const held = result.acquired;
    try testing.expect(held.token.len > 0);
    try testing.expectEqualStrings(held.token, try readToken(alloc, &ctx.db, "s1"));
}

test "a second acquire on a held session is refused" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    var ctx = try setupDb(alloc);
    defer teardown(&ctx);

    _ = try acquire(.{ .allocator = alloc, .db = &ctx.db, .session_id = "s1", .working_directory = "/tmp" });
    const second = try acquire(.{ .allocator = alloc, .db = &ctx.db, .session_id = "s1", .working_directory = "/tmp" });

    try testing.expect(second == .busy);
}

test "acquire claims a session whose previous run left no lease behind" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    var ctx = try setupDb(alloc);
    defer teardown(&ctx);

    try ctx.db.exec(
        alloc,
        "INSERT INTO worker (id, session_id, working_directory, run_token) VALUES ('s1', 's1', '/tmp', '')",
        &.{},
    );

    const result = try acquire(.{ .allocator = alloc, .db = &ctx.db, .session_id = "s1", .working_directory = "/new" });

    try testing.expect(result == .acquired);
    var row = try ctx.db.queryRow(alloc, "SELECT working_directory FROM worker WHERE id = 's1'", &.{});
    defer row.deinit(alloc);
    try testing.expectEqualStrings("/new", row.values[0]);
}

test "acquire succeeds again once the previous run released the row" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    var ctx = try setupDb(alloc);
    defer teardown(&ctx);

    const first = try acquire(.{ .allocator = alloc, .db = &ctx.db, .session_id = "s1", .working_directory = "/tmp" });
    try ctx.db.exec(alloc, "DELETE FROM worker WHERE id = ? AND run_token = ?", &.{ "s1", first.acquired.token });

    const again = try acquire(.{ .allocator = alloc, .db = &ctx.db, .session_id = "s1", .working_directory = "/tmp" });

    try testing.expect(again == .acquired);
}

test "acquire leaves other sessions' leases alone" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    var ctx = try setupDb(alloc);
    defer teardown(&ctx);

    const other = try acquire(.{ .allocator = alloc, .db = &ctx.db, .session_id = "other", .working_directory = "/tmp" });
    _ = try acquire(.{ .allocator = alloc, .db = &ctx.db, .session_id = "s1", .working_directory = "/tmp" });

    try testing.expectEqualStrings(other.acquired.token, try readToken(alloc, &ctx.db, "other"));
}

test "ten sessions claim and hold their leases at the same time" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    var ctx = try setupDb(alloc);
    defer teardown(&ctx);

    var tokens: [10][]const u8 = undefined;
    for (&tokens, 0..) |*slot, i| {
        const session_id = try std.fmt.allocPrint(alloc, "session_{d}", .{i});
        const result = try acquire(.{
            .allocator = alloc,
            .db = &ctx.db,
            .session_id = session_id,
            .working_directory = "/tmp",
        });
        try testing.expect(result == .acquired);
        slot.* = result.acquired.token;
    }

    for (tokens, 0..) |token, i| {
        const session_id = try std.fmt.allocPrint(alloc, "session_{d}", .{i});
        const state = (try beginIteration(alloc, &ctx.db, session_id, token)).?;
        try testing.expect(!state.is_cancelled);
    }
}

test "ownerPid reads the pid a lease was stamped with" {
    try testing.expectEqual(@as(?i32, 4242), ownerPid("run-4242-1792928286959659946-0"));
    try testing.expectEqual(@as(?i32, null), ownerPid(""));
    try testing.expectEqual(@as(?i32, null), ownerPid("stale-token"));
    try testing.expectEqual(@as(?i32, null), ownerPid("run-notapid-1-2"));
}

test "isOwnerAlive says no for a lease with no pid in it" {
    try testing.expect(!isOwnerAlive("stale-token"));
}

test "acquire stamps the current pid into the lease it returns" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    var ctx = try setupDb(alloc);
    defer teardown(&ctx);

    const held = (try acquire(.{ .allocator = alloc, .db = &ctx.db, .session_id = "s1", .working_directory = "/tmp" })).acquired;

    try testing.expectEqual(
        @as(?i32, helpers.process_status.getCurrentProcessIdInt()),
        ownerPid(held.token),
    );
    try testing.expect(isOwnerAlive(held.token));
}

test "beginIteration reports the iteration state while the lease is ours" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    var ctx = try setupDb(alloc);
    defer teardown(&ctx);

    try ctx.db.exec(alloc, "INSERT INTO sessions (id, is_auto_retry_until_stop) VALUES ('s1', '1')", &.{});
    const held = (try acquire(.{ .allocator = alloc, .db = &ctx.db, .session_id = "s1", .working_directory = "/tmp" })).acquired;

    const state = (try beginIteration(alloc, &ctx.db, "s1", held.token)).?;

    try testing.expect(state.is_auto_retry_until_stop);
    try testing.expect(!state.is_cancelled);
}

test "beginIteration reports a cancellation flag set on the worker row" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    var ctx = try setupDb(alloc);
    defer teardown(&ctx);

    try ctx.db.exec(alloc, "INSERT INTO sessions (id, is_auto_retry_until_stop) VALUES ('s1', '0')", &.{});
    const held = (try acquire(.{ .allocator = alloc, .db = &ctx.db, .session_id = "s1", .working_directory = "/tmp" })).acquired;
    try ctx.db.exec(alloc, "UPDATE worker SET cancelled = 1 WHERE id = 's1'", &.{});

    const state = (try beginIteration(alloc, &ctx.db, "s1", held.token)).?;

    try testing.expect(state.is_cancelled);
}

test "beginIteration refuses a lease another run took over" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    var ctx = try setupDb(alloc);
    defer teardown(&ctx);

    try ctx.db.exec(alloc, "INSERT INTO sessions (id, is_auto_retry_until_stop) VALUES ('s1', '0')", &.{});
    const first = (try acquire(.{ .allocator = alloc, .db = &ctx.db, .session_id = "s1", .working_directory = "/tmp" })).acquired;
    try ctx.db.exec(alloc, "DELETE FROM worker WHERE id = 's1' AND run_token = ?", &.{first.token});
    _ = try acquire(.{ .allocator = alloc, .db = &ctx.db, .session_id = "s1", .working_directory = "/tmp" });

    try testing.expectEqual(@as(?IterationState, null), try beginIteration(alloc, &ctx.db, "s1", first.token));
}

test "beginIteration refuses once the worker row is gone" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    var ctx = try setupDb(alloc);
    defer teardown(&ctx);

    const held = (try acquire(.{ .allocator = alloc, .db = &ctx.db, .session_id = "s1", .working_directory = "/tmp" })).acquired;
    try ctx.db.exec(alloc, "DELETE FROM worker WHERE id = 's1'", &.{});

    try testing.expectEqual(@as(?IterationState, null), try beginIteration(alloc, &ctx.db, "s1", held.token));
}
