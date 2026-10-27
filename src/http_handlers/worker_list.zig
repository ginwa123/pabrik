//! `GET /api/workers` — list all workers.

const std = @import("std");
const http_response = @import("http_response.zig");
const pabrikcore = @import("pabrikcore");
const auth_common = @import("auth_common.zig");
const gserverz = pabrikcore.gserverz;

pub const WorkerListError = error{
    QueryFailed,
    OutOfMemory,
};

pub const WorkerListInput = struct {
    limit: u32,
    session_id_filter: ?[]const u8,
};

pub const WorkerListResult = struct {
    json: []const u8,
    count: u32,
};

// =====================================================================
// Use case
// =====================================================================

fn useCase(
    allocator: std.mem.Allocator,
    db: *pabrikcore.database.Db,
    input: WorkerListInput,
    owner: []const u8,
) WorkerListError!WorkerListResult {
    // Only the query string lives in the arena — it is dead the moment
    // `db.query` returns.
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const q = arena.allocator();

    // Build query with optional session_id filter. SQL convention: alias the
    // table (`w`) so the column references stay unambiguous when filters grow
    // (see project memory pabrik-sql-alias-tables.md).
    const base_sql = "SELECT w.id, w.session_id, w.working_directory, w.last_activity_nano AS last_activity, w.last_activity_description, w.created_at FROM worker w";

    // `cancelled = 0` is the whole reason a client can trust this list.
    var where_sql: []const u8 = "WHERE w.cancelled = 0";

    if (input.session_id_filter != null) {
        where_sql = try std.fmt.allocPrint(q, "{s} AND w.session_id = ?", .{where_sql});
    }
    // Owner scope (plan 2026-09-25, W2.4). Skipped only for the shared/system
    // user, i.e. auth off, where the system user sees every worker.
    if (!auth_common.isSharedOwner(owner)) {
        where_sql = try std.fmt.allocPrint(
            q,
            "{s} AND " ++ auth_common.ownerVisibilityClause("w"),
            .{where_sql},
        );
    }

    const query_sql = try std.fmt.allocPrint(
        q,
        "{s} {s} ORDER BY w.last_activity_nano DESC",
        .{ base_sql, where_sql },
    );

    // Bound exactly as before the `cancelled` predicate existed: the
    // visibility clause contributes two `?` (one compared against the system
    // sentinel, one bound to the owner) and the session filter one more.
    const query_params: []const []const u8 = if (input.session_id_filter) |sid|
        if (auth_common.isSharedOwner(owner))
            &[_][]const u8{sid}
        else
            &[_][]const u8{ sid, owner, owner }
    else if (auth_common.isSharedOwner(owner))
        &[_][]const u8{}
    else
        &[_][]const u8{ owner, owner };

    var rows = db.query(allocator, query_sql, query_params) catch return error.QueryFailed;
    // Owns a pooled reader until `deinit`; draining `next()` does not return it.
    defer rows.deinit();

    var workers = std.ArrayList(http_response.WorkerInfo).empty;
    while (true) {
        const row_opt = rows.next() catch break;
        const row = row_opt orelse break;

        try workers.append(allocator, .{
            .id = row.values[0],
            .session_id = row.values[1],
            .working_directory = row.values[2],
            .last_activity = row.values[3],
            .last_activity_description = row.values[4],
            .created_at = row.values[5],
            .status = "running",
            .is_running = true,
            .queue_count = 0,
        });

        if (workers.items.len >= input.limit) break;
    }

    const count: u32 = @intCast(workers.items.len);
    const json = try http_response.makeWorkerListResponse(allocator, workers.items, count);
    return .{ .json = json, .count = count };
}

// =====================================================================
// Handler
// =====================================================================

pub fn workerListHandler(
    ctx: gserverz.HttpContext,
    req: gserverz.HttpRequest,
    res: gserverz.HttpResponse,
) !gserverz.HttpResponse {
    const allocator = ctx.allocator;

    const di = try pabrikcore.getSingleton();
    const sqlite_db = di.db;

    const limit_str = req.query.get("limit") orelse "50";
    const limit = std.fmt.parseInt(u32, limit_str, 10) catch 50;

    const input = WorkerListInput{
        .limit = limit,
        .session_id_filter = req.query.get("session_id"),
    };

    // Server-derived owner (cookie only). Scopes the list so B never sees A's
    // running workers; auth off resolves to the system user, who sees all.
    const owner = auth_common.resolveRequestUserId(allocator, sqlite_db, di.auth_enabled, req.headers) catch "";
    defer if (owner.len > 0) allocator.free(owner);

    const outcome = useCase(allocator, sqlite_db, input, owner) catch |err| {
        const status: u16 = switch (err) {
            error.QueryFailed => 500,
            error.OutOfMemory => 500,
        };
        const message: []const u8 = switch (err) {
            error.QueryFailed => "Database query failed",
            error.OutOfMemory => "Out of memory",
        };
        return res.jsonResponse(.{
            .status_code = status,
            .data = try http_response.makeErrorResponse(allocator, .{ .@"error" = message }),
        });
    };

    _ = outcome.count;
    return res.jsonResponse(.{ .status_code = 200, .data = outcome.json });
}

// ─── Tests
// ──────────────────────────────────────────────────────────────────
// Registered in `src/root.zig`'s `test { }` block — the same lazy-compilation

const testing = std.testing;
const sqlite = pabrikcore.sqlite;
const database = pabrikcore.database;

/// Production shape of `worker` after migrations 019/020/075/093 + the
/// `cancelled` column. `user_id` is read by the owner-visibility clause, so a
/// table without it would not exercise the scoped query at all.
fn setupDb() !struct { db: database.Db, threaded: std.Io.Threaded } {
    const alloc = testing.allocator;
    var threaded = std.Io.Threaded.init(alloc, .{});
    errdefer threaded.deinit();
    var db: database.Db = .{};
    errdefer db.deinit();
    try db.init(threaded.io(), ":memory:");
    try db.exec(alloc,
        \\CREATE TABLE worker (
        \\    id TEXT PRIMARY KEY,
        \\    session_id TEXT NOT NULL,
        \\    working_directory TEXT,
        \\    last_activity_nano INTEGER,
        \\    last_activity_description TEXT,
        \\    created_at DATETIME DEFAULT CURRENT_TIMESTAMP,
        \\    cancelled INTEGER DEFAULT 0,
        \\    user_id TEXT
        \\)
    , &.{});
    return .{ .db = db, .threaded = threaded };
}

fn seedWorker(
    db: *database.Db,
    arena_alloc: std.mem.Allocator,
    id: []const u8,
    session_id: []const u8,
    cancelled: []const u8,
) !void {
    try db.exec(arena_alloc,
        \\INSERT INTO worker (id, session_id, working_directory, last_activity_nano, cancelled)
        \\VALUES (?, ?, '/tmp', strftime('%s','now'), ?)
    , &.{ id, session_id, cancelled });
}

/// `useCase` allocates its rows and its JSON from the allocator it is handed
/// and never frees either, so the tests hand it an arena instead of
/// `testing.allocator` — otherwise every test would fail on a leak that the
fn listAs(
    db: *database.Db,
    arena_alloc: std.mem.Allocator,
    input: WorkerListInput,
    owner: []const u8,
) !WorkerListResult {
    return useCase(arena_alloc, db, input, owner);
}

test "a worker row the user stopped is not listed as running" {
    var s = try setupDb();
    defer s.db.deinit();
    defer s.threaded.deinit();

    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    try seedWorker(&s.db, a, "w_live", "s_live", "0");
    try seedWorker(&s.db, a, "w_stopped", "s_stopped", "1");

    // The shared owner sees every worker, so this is the unscoped listing the
    // Android client's bootstrap actually reads.
    const result = try listAs(&s.db, a, .{ .limit = 50, .session_id_filter = null }, "");

    try testing.expectEqual(@as(u32, 1), result.count);
    try testing.expect(std.mem.indexOf(u8, result.json, "s_live") != null);
    try testing.expect(std.mem.indexOf(u8, result.json, "s_stopped") == null);
}

test "a session_id filter composes with the cancelled filter" {
    var s = try setupDb();
    defer s.db.deinit();
    defer s.threaded.deinit();

    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    try seedWorker(&s.db, a, "w_a", "s_a", "0");
    try seedWorker(&s.db, a, "w_a2", "s_a", "1");
    try seedWorker(&s.db, a, "w_b", "s_b", "0");

    const result = try listAs(
        &s.db,
        a,
        .{ .limit = 50, .session_id_filter = "s_a" },
        "",
    );

    // The live row for `s_a`; not its cancelled twin, and not `s_b`.
    try testing.expectEqual(@as(u32, 1), result.count);
    try testing.expect(std.mem.indexOf(u8, result.json, "w_a\"") != null);
    try testing.expect(std.mem.indexOf(u8, result.json, "w_a2") == null);
    try testing.expect(std.mem.indexOf(u8, result.json, "s_b") == null);
}

test "a real owner's listing excludes another owner's cancelled row and their live one" {
    var s = try setupDb();
    defer s.db.deinit();
    defer s.threaded.deinit();

    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    try s.db.exec(a,
        \\INSERT INTO worker (id, session_id, working_directory, last_activity_nano, cancelled, user_id)
        \\VALUES ('w_mine', 's_mine', '/tmp', strftime('%s','now'), 0, 'user_a')
    , &.{});
    try s.db.exec(a,
        \\INSERT INTO worker (id, session_id, working_directory, last_activity_nano, cancelled, user_id)
        \\VALUES ('w_stopped_mine', 's_stopped_mine', '/tmp', strftime('%s','now'), 1, 'user_a')
    , &.{});
    try s.db.exec(a,
        \\INSERT INTO worker (id, session_id, working_directory, last_activity_nano, cancelled, user_id)
        \\VALUES ('w_theirs', 's_theirs', '/tmp', strftime('%s','now'), 0, 'user_b')
    , &.{});

    const result = try listAs(
        &s.db,
        a,
        .{ .limit = 50, .session_id_filter = null },
        "user_a",
    );

    try testing.expectEqual(@as(u32, 1), result.count);
    try testing.expect(std.mem.indexOf(u8, result.json, "w_mine\"") != null);
    try testing.expect(std.mem.indexOf(u8, result.json, "w_stopped_mine") == null);
    try testing.expect(std.mem.indexOf(u8, result.json, "s_theirs") == null);
}

test "every listed row still reports itself as running (the Android parser's premise)" {
    var s = try setupDb();
    defer s.db.deinit();
    defer s.threaded.deinit();

    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    try seedWorker(&s.db, a, "w_live", "s_live", "0");

    const result = try listAs(&s.db, a, .{ .limit = 50, .session_id_filter = null }, "");

    // `WorkerApi.parseRunningSessionIds` projects the *presence* of a row
    // down to the id set and never reads these two fields, precisely because
    // they are literals.
    try testing.expect(std.mem.indexOf(u8, result.json, "\"status\":\"running\"") != null);
    try testing.expect(std.mem.indexOf(u8, result.json, "\"is_running\":true") != null);
}

test "limit caps the list, and the default is the server's own" {
    var s = try setupDb();
    defer s.db.deinit();
    defer s.threaded.deinit();

    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    try seedWorker(&s.db, a, "w_1", "s_1", "0");
    try seedWorker(&s.db, a, "w_2", "s_2", "0");
    try seedWorker(&s.db, a, "w_3", "s_3", "0");

    const one = try listAs(&s.db, a, .{ .limit = 1, .session_id_filter = null }, "");
    const many = try listAs(&s.db, a, .{ .limit = 50, .session_id_filter = null }, "");

    try testing.expectEqual(@as(u32, 1), one.count);
    try testing.expectEqual(@as(u32, 3), many.count);
}

test "a missing worker table surfaces as QueryFailed rather than an empty list" {
    var s = try setupDb();
    defer s.db.deinit();
    defer s.threaded.deinit();

    try s.db.exec(testing.allocator, "DROP TABLE worker", &.{});

    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();

    // An empty list on a broken table is the worst possible answer: every
    // client would read it as "nothing is running" and clear its spinners.
    try testing.expectError(
        error.QueryFailed,
        listAs(&s.db, arena.allocator(), .{ .limit = 50, .session_id_filter = null }, ""),
    );
}

test "repeated listings hand their pooled reader back instead of exhausting the pool" {
    // FILE-BACKED, deliberately: `initWithConfig` skips pooling for
    // `:memory:` (a second connection would see an empty database), so the
    // in-memory `setupDb` above cannot observe this at all.
    const alloc = testing.allocator;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    var dir_buf: [std.fs.max_path_bytes]u8 = undefined;
    const dir_len = try tmp.dir.realPath(testing.io, &dir_buf);
    const joined = try std.fs.path.join(alloc, &.{ dir_buf[0..dir_len], "pool.db" });
    defer alloc.free(joined);
    const path = try alloc.dupeZ(u8, joined);
    defer alloc.free(path);

    var threaded = std.Io.Threaded.init(alloc, .{});
    defer threaded.deinit();

    var db: database.Db = .{};
    defer db.deinit();
    // ONE reader, and a budget short enough to fail fast: with a single
    // reader, a second listing that finds the pool empty has no way to grow
    // it, so it waits and then falls back onto the write connection.
    try db.initWithConfig(threaded.io(), path, .{
        .read_conns = 1,
        .max_read_conns = 1,
        .reader_wait_ms = 20,
    });

    try db.exec(alloc,
        \\CREATE TABLE worker (
        \\    id TEXT PRIMARY KEY,
        \\    session_id TEXT NOT NULL,
        \\    working_directory TEXT,
        \\    last_activity_nano INTEGER,
        \\    last_activity_description TEXT,
        \\    created_at DATETIME DEFAULT CURRENT_TIMESTAMP,
        \\    cancelled INTEGER DEFAULT 0,
        \\    user_id TEXT
        \\)
    , &.{});
    try db.exec(alloc,
        \\INSERT INTO worker (id, session_id, working_directory) VALUES ('w1', 's1', '/tmp')
    , &.{});

    var arena = std.heap.ArenaAllocator.init(alloc);
    defer arena.deinit();
    const a = arena.allocator();

    // This endpoint is polled continuously, so repeat it: one call proves
    // nothing, and the single pooled reader is what makes the second one
    // decisive.
    for (0..5) |_| {
        const result = try listAs(&db, a, .{ .limit = 50, .session_id_filter = null }, "");
        try testing.expectEqual(@as(u32, 1), result.count);
    }

    // Every listing found a reader waiting for it.
    try testing.expectEqual(@as(u64, 0), db.readFallbackCount());

    // And nothing is still checked out. This catches the leak on its own,
    // without relying on the pool filling up: a deinited cursor returns its
    // reader, and a drained one does not.
    try testing.expectEqual(@as(usize, 0), db.outstandingClaims());
}
