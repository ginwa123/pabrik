//! `POST /api/bench/seed/sessions?rows=N` — BENCHMARK-ONLY seeding for
//! `benchmark/run.sh`. Gated by `PABRIK_BENCH_SEED=1`; 404 when off, so a
//! production binary never exposes it.

const std = @import("std");
const pabrikcore = @import("pabrikcore");
const test_db = pabrikcore.test_db;
const gserverz = pabrikcore.gserverz;

pub const default_rows: u32 = 50;
pub const max_rows: u32 = 1_000;

/// Three directories no git repository owns, so every row exercises the
/// "no badge" answer the sidebar pays for on a plain folder.
pub const seed_cwds = [_][]const u8{
    "/pabrik-bench/cwd-a",
    "/pabrik-bench/cwd-b",
    "/pabrik-bench/cwd-c",
};

const seed_sql_head = pabrikcore.dialect.upsert_verb ++
    " INTO sessions (id, name, status, cwd, created_at, updated_at) VALUES (";
const seed_sql_tail = ")" ++
    (if (pabrikcore.dialect.is_postgres)
        " ON CONFLICT (id) DO UPDATE SET name = EXCLUDED.name, status = EXCLUDED.status," ++
            " cwd = EXCLUDED.cwd, created_at = EXCLUDED.created_at, updated_at = EXCLUDED.updated_at"
    else
        "");

/// 2026-01-01T00:00:00Z, the first seeded row's timestamp.
const seed_epoch: u64 = 1_767_225_600;

fn seedTimestamp(buf: []u8, row: u32) ![]const u8 {
    const stamp = std.time.epoch.EpochSeconds{ .secs = seed_epoch + @as(u64, row) * 60 };
    const day = stamp.getEpochDay().calculateYearDay();
    const month = day.calculateMonthDay();
    const clock = stamp.getDaySeconds();
    return std.fmt.bufPrint(buf, "{d:0>4}-{d:0>2}-{d:0>2} {d:0>2}:{d:0>2}:{d:0>2}", .{
        day.year,
        month.month.numeric(),
        month.day_index + 1,
        clock.getHoursIntoDay(),
        clock.getMinutesIntoHour(),
        clock.getSecondsIntoMinute(),
    });
}

fn gateEnabled() bool {
    const value = std.c.getenv("PABRIK_BENCH_SEED") orelse return false;
    return std.mem.eql(u8, std.mem.span(value), "1");
}

pub fn parseRows(raw: ?[]const u8) u32 {
    const text = raw orelse return default_rows;
    const parsed = std.fmt.parseInt(u32, text, 10) catch return default_rows;
    if (parsed == 0) return default_rows;
    return @min(parsed, max_rows);
}

/// Insert `rows` synthetic sessions, replacing any left by a previous run.
pub fn seedSessions(allocator: std.mem.Allocator, db: *pabrikcore.database.Db, rows: u32) !void {
    var n: u32 = 1;
    while (n <= @min(rows, max_rows)) : (n += 1) {
        var stamp_buf: [24]u8 = undefined;
        const stamp = try seedTimestamp(&stamp_buf, n);

        const sql = try std.fmt.allocPrint(
            allocator,
            "{s}'bench-{d:0>4}', 'Bench session {d:0>4}', 'active', '{s}', '{s}', '{s}'{s}",
            .{ seed_sql_head, n, n, seed_cwds[(n - 1) % seed_cwds.len], stamp, stamp, seed_sql_tail },
        );
        defer allocator.free(sql);

        try db.exec(allocator, sql, &.{});
    }
}

pub fn benchSeedSessionsHandler(
    ctx: gserverz.HttpContext,
    req: gserverz.HttpRequest,
    res: gserverz.HttpResponse,
) !gserverz.HttpResponse {
    const allocator = ctx.allocator;

    if (!gateEnabled()) {
        return res.jsonResponse(.{
            .status_code = 404,
            .data = try std.fmt.allocPrint(allocator, "{{\"error\":\"not found\"}}", .{}),
        });
    }

    const rows = parseRows(req.query.get("rows"));
    const di = pabrikcore.getSingleton() catch {
        return res.jsonResponse(.{
            .status_code = 500,
            .data = try std.fmt.allocPrint(allocator, "{{\"error\":\"singleton unavailable\"}}", .{}),
        });
    };

    seedSessions(allocator, di.db, rows) catch |err| {
        return res.jsonResponse(.{
            .status_code = 500,
            .data = try std.fmt.allocPrint(allocator, "{{\"error\":\"seed failed: {s}\"}}", .{@errorName(err)}),
        });
    };

    return res.jsonResponse(.{
        .status_code = 200,
        .data = try std.fmt.allocPrint(allocator, "{{\"inserted\":{d},\"cwds\":{d}}}", .{ rows, seed_cwds.len }),
    });
}

pub const documents_workspace_id = "bench-docs";
pub const documents_workspace_name = "Bench documents";

fn ensureDocumentsWorkspace(allocator: std.mem.Allocator, db: *pabrikcore.database.Db) !void {
    var q = db.query(allocator, "SELECT id FROM workspaces WHERE id = ?", &.{documents_workspace_id}) catch
        return error.QueryFailed;
    defer q.deinit();
    if (q.next() catch return error.QueryFailed) |row| {
        row.deinit(allocator);
        return;
    }
    try db.exec(
        allocator,
        "INSERT INTO workspaces (id, name) VALUES (?, ?)",
        &.{ documents_workspace_id, documents_workspace_name },
    );
}

fn seedDocumentId(buf: []u8, row: u32) ![]const u8 {
    return std.fmt.bufPrint(buf, "bench-doc-{d:0>4}", .{row});
}

pub fn seedDocuments(allocator: std.mem.Allocator, db: *pabrikcore.database.Db, rows: u32) !void {
    const bounded = @min(rows, max_rows);
    try ensureDocumentsWorkspace(allocator, db);
    try db.exec(
        allocator,
        "DELETE FROM documents WHERE workspace_id = ?",
        &.{documents_workspace_id},
    );

    var n: u32 = 1;
    while (n <= bounded) : (n += 1) {
        var id_buf: [32]u8 = undefined;
        const id = try seedDocumentId(&id_buf, n);
        var title_buf: [48]u8 = undefined;
        const title = try std.fmt.bufPrint(&title_buf, "Bench document {d:0>4}", .{n});
        var created_buf: [24]u8 = undefined;
        const created = try seedTimestamp(&created_buf, n);
        var updated_buf: [24]u8 = undefined;
        const updated = try seedTimestamp(&updated_buf, n);
        var position_buf: [16]u8 = undefined;
        const position = try std.fmt.bufPrint(&position_buf, "{d}", .{n - 1});

        try db.exec(
            allocator,
            \\INSERT INTO documents (id, workspace_id, title, content, format, created_at, updated_at, position)
            \\VALUES (?, ?, ?, '', 'markdown', ?, ?, ?)
        , &.{ id, documents_workspace_id, title, created, updated, position });
    }
}

pub fn benchSeedDocumentsHandler(
    ctx: gserverz.HttpContext,
    req: gserverz.HttpRequest,
    res: gserverz.HttpResponse,
) !gserverz.HttpResponse {
    const allocator = ctx.allocator;

    if (!gateEnabled()) {
        return res.jsonResponse(.{
            .status_code = 404,
            .data = try std.fmt.allocPrint(allocator, "{{\"error\":\"not found\"}}", .{}),
        });
    }

    const rows = parseRows(req.query.get("rows"));
    const di = pabrikcore.getSingleton() catch {
        return res.jsonResponse(.{
            .status_code = 500,
            .data = try std.fmt.allocPrint(allocator, "{{\"error\":\"singleton unavailable\"}}", .{}),
        });
    };

    seedDocuments(allocator, di.db, rows) catch |err| {
        return res.jsonResponse(.{
            .status_code = 500,
            .data = try std.fmt.allocPrint(allocator, "{{\"error\":\"seed failed: {s}\"}}", .{@errorName(err)}),
        });
    };

    return res.jsonResponse(.{
        .status_code = 200,
        .data = try std.fmt.allocPrint(allocator, "{{\"inserted\":{d},\"workspace_id\":\"{s}\"}}", .{ rows, documents_workspace_id }),
    });
}

// ===================================================================== Tests

const testing = std.testing;

const SeedCtx = struct {
    db: pabrikcore.database.Db,
    threaded: std.Io.Threaded,
};

fn setupDb() !SeedCtx {
    const alloc = testing.allocator;
    var threaded = std.Io.Threaded.init(alloc, .{});
    errdefer threaded.deinit();
    var db: pabrikcore.database.Db = .{};
    errdefer db.deinit();
    try test_db.openMemory(&db, threaded.io());
    try db.exec(alloc,
        \\CREATE TABLE sessions (
        \\  id TEXT PRIMARY KEY,
        \\  name TEXT NOT NULL,
        \\  status TEXT NOT NULL DEFAULT 'active',
        \\  cwd TEXT,
        \\  created_at TIMESTAMP DEFAULT NULL,
        \\  updated_at TIMESTAMP DEFAULT NULL
        \\)
    , &.{});
    return .{ .db = db, .threaded = threaded };
}

fn teardown(ctx: *SeedCtx) void {
    ctx.db.deinit();
    ctx.threaded.deinit();
}

fn countRows(ctx: *SeedCtx, sql: []const u8) !u32 {
    var rows = try ctx.db.query(testing.allocator, sql, &.{});
    defer rows.deinit();
    const row = (try rows.next()) orelse return 0;
    defer row.deinit(testing.allocator);
    return std.fmt.parseInt(u32, row.values[0], 10) catch 0;
}

test "seeding fifty rows leaves fifty sessions spread over the three directories" {
    var ctx = try setupDb();
    defer teardown(&ctx);

    try seedSessions(testing.allocator, &ctx.db, 50);

    try testing.expectEqual(@as(u32, 50), try countRows(&ctx, "SELECT COUNT(*) FROM sessions"));
    try testing.expectEqual(@as(u32, 3), try countRows(&ctx, "SELECT COUNT(DISTINCT cwd) FROM sessions"));
    try testing.expectEqual(@as(u32, 50), try countRows(&ctx, "SELECT COUNT(DISTINCT created_at) FROM sessions"));
    try testing.expectEqual(@as(u32, 0), try countRows(&ctx, "SELECT COUNT(*) FROM sessions WHERE cwd NOT IN ('/pabrik-bench/cwd-a','/pabrik-bench/cwd-b','/pabrik-bench/cwd-c')"));
}

test "seeding twice replaces instead of duplicating" {
    var ctx = try setupDb();
    defer teardown(&ctx);

    try seedSessions(testing.allocator, &ctx.db, 50);
    try seedSessions(testing.allocator, &ctx.db, 50);

    try testing.expectEqual(@as(u32, 50), try countRows(&ctx, "SELECT COUNT(*) FROM sessions"));
}

test "a seeded row carries the same id, name and timestamps every run" {
    var ctx = try setupDb();
    defer teardown(&ctx);

    try seedSessions(testing.allocator, &ctx.db, 2);

    var rows = try ctx.db.query(
        testing.allocator,
        "SELECT id, name, cwd, created_at FROM sessions ORDER BY id",
        &.{},
    );
    defer rows.deinit();

    const first = (try rows.next()).?;
    defer first.deinit(testing.allocator);
    try testing.expectEqualStrings("bench-0001", first.values[0]);
    try testing.expectEqualStrings("Bench session 0001", first.values[1]);
    try testing.expectEqualStrings("/pabrik-bench/cwd-a", first.values[2]);
    try testing.expect(std.mem.indexOf(u8, first.values[3], "2026-01-01") != null);

    const second = (try rows.next()).?;
    defer second.deinit(testing.allocator);
    try testing.expectEqualStrings("bench-0002", second.values[0]);
    try testing.expectEqualStrings("/pabrik-bench/cwd-b", second.values[2]);
}

test "rows defaults to fifty and is clamped to the ceiling" {
    try testing.expectEqual(default_rows, parseRows(null));
    try testing.expectEqual(default_rows, parseRows(""));
    try testing.expectEqual(default_rows, parseRows("0"));
    try testing.expectEqual(default_rows, parseRows("not a number"));
    try testing.expectEqual(@as(u32, 7), parseRows("7"));
    try testing.expectEqual(max_rows, parseRows("999999"));
}

fn setupDocumentsDb() !SeedCtx {
    const alloc = testing.allocator;
    var threaded = std.Io.Threaded.init(alloc, .{});
    errdefer threaded.deinit();
    var db: pabrikcore.database.Db = .{};
    errdefer db.deinit();
    try test_db.openMemory(&db, threaded.io());
    try db.exec(alloc,
        \\CREATE TABLE workspaces (
        \\  id TEXT PRIMARY KEY,
        \\  name TEXT NOT NULL DEFAULT ''
        \\)
    , &.{});
    try db.exec(alloc,
        \\CREATE TABLE documents (
        \\  id TEXT PRIMARY KEY,
        \\  workspace_id TEXT NOT NULL,
        \\  title TEXT NOT NULL DEFAULT '',
        \\  content TEXT NOT NULL DEFAULT '',
        \\  format TEXT NOT NULL DEFAULT 'markdown',
        \\  created_at TIMESTAMP DEFAULT NULL,
        \\  updated_at TIMESTAMP DEFAULT NULL,
        \\  position INTEGER NOT NULL DEFAULT 0
        \\)
    , &.{});
    return .{ .db = db, .threaded = threaded };
}

test "seeding documents creates the bench workspace and the rows the list route reads" {
    var ctx = try setupDocumentsDb();
    defer teardown(&ctx);

    try seedDocuments(testing.allocator, &ctx.db, 50);

    try testing.expectEqual(@as(u32, 1), try countRows(&ctx, "SELECT COUNT(*) FROM workspaces WHERE id = 'bench-docs'"));
    try testing.expectEqual(@as(u32, 50), try countRows(&ctx, "SELECT COUNT(*) FROM documents WHERE workspace_id = 'bench-docs'"));
}

test "seeded documents order by position, not by updated_at" {
    var ctx = try setupDocumentsDb();
    defer teardown(&ctx);

    try seedDocuments(testing.allocator, &ctx.db, 3);

    var by_position = try ctx.db.query(
        testing.allocator,
        "SELECT id FROM documents WHERE workspace_id = 'bench-docs' ORDER BY position ASC, updated_at DESC, id DESC",
        &.{},
    );
    defer by_position.deinit();
    const first = (try by_position.next()).?;
    defer first.deinit(testing.allocator);
    try testing.expectEqualStrings("bench-doc-0001", first.values[0]);

    var by_recency = try ctx.db.query(
        testing.allocator,
        "SELECT id FROM documents WHERE workspace_id = 'bench-docs' ORDER BY updated_at DESC, id DESC",
        &.{},
    );
    defer by_recency.deinit();
    const newest = (try by_recency.next()).?;
    defer newest.deinit(testing.allocator);
    try testing.expectEqualStrings("bench-doc-0003", newest.values[0]);
}

test "seeding documents twice replaces instead of duplicating" {
    var ctx = try setupDocumentsDb();
    defer teardown(&ctx);

    try seedDocuments(testing.allocator, &ctx.db, 50);
    try seedDocuments(testing.allocator, &ctx.db, 50);

    try testing.expectEqual(@as(u32, 50), try countRows(&ctx, "SELECT COUNT(*) FROM documents WHERE workspace_id = 'bench-docs'"));
}

test "a seeded document carries the same id, title and position every run" {
    var ctx = try setupDocumentsDb();
    defer teardown(&ctx);

    try seedDocuments(testing.allocator, &ctx.db, 2);

    var rows = try ctx.db.query(
        testing.allocator,
        "SELECT id, title, position, created_at FROM documents WHERE workspace_id = 'bench-docs' ORDER BY id",
        &.{},
    );
    defer rows.deinit();

    const first = (try rows.next()).?;
    defer first.deinit(testing.allocator);
    try testing.expectEqualStrings("bench-doc-0001", first.values[0]);
    try testing.expectEqualStrings("Bench document 0001", first.values[1]);
    try testing.expectEqualStrings("0", first.values[2]);
    try testing.expect(std.mem.indexOf(u8, first.values[3], "2026-01-01") != null);

    const second = (try rows.next()).?;
    defer second.deinit(testing.allocator);
    try testing.expectEqualStrings("bench-doc-0002", second.values[0]);
    try testing.expectEqualStrings("1", second.values[2]);
}
