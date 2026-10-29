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

const seed_sql =
    \\INSERT OR REPLACE INTO sessions (id, name, status, cwd, created_at, updated_at)
    \\VALUES (?, ?, 'active', ?,
    \\        strftime('%Y-%m-%d %H:%M:%S', '2026-01-01 00:00:00', ?),
    \\        strftime('%Y-%m-%d %H:%M:%S', '2026-01-01 00:00:00', ?))
;

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
        var id_buf: [16]u8 = undefined;
        var name_buf: [32]u8 = undefined;
        var offset_buf: [16]u8 = undefined;

        const id = try std.fmt.bufPrint(&id_buf, "bench-{d:0>4}", .{n});
        const name = try std.fmt.bufPrint(&name_buf, "Bench session {d:0>4}", .{n});
        const offset = try std.fmt.bufPrint(&offset_buf, "+{d} seconds", .{n * 60});

        try db.exec(allocator, seed_sql, &.{
            id,
            name,
            seed_cwds[(n - 1) % seed_cwds.len],
            offset,
            offset,
        });
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
    try testing.expectEqualStrings("2026-01-01 00:01:00", first.values[3]);

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
