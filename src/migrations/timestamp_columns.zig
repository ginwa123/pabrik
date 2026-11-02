const std = @import("std");
const test_db = @import("../testing/test_db.zig");
const common = @import("common.zig");

const Backend = common.Backend;
const dialect = common.dialect;

/// The units this schema stored under one `_nano` name, plus the
/// `YYYY-MM-DD HH:MM:SS` text some timestamp columns hold instead.
pub const Unit = enum { nano, micro, milli, second, text };

/// One timestamp column moving to the schema's single unit: where it lands,
/// which legacy column it comes from, and what that legacy column counts.
pub const Move = struct {
    table: []const u8,
    to: []const u8,
    from: []const u8,
    unit: Unit,
};

/// The earliest instant each unit can still name and be a value this schema
/// wrote. Below its floor a legacy number belongs to a different unit.
pub const floor = struct {
    pub const nano: u64 = 1_000_000_000_000_000;
    pub const micro: u64 = 100_000_000_000_000;
    pub const milli: u64 = 1_000_000_000_000;
    pub const second: u64 = 1_000_000_000;
};

/// Every column migration 136 adds, 137 backfills and 138 drops the legacy
/// half of. Each `from` column's unit was measured from the live database.
pub const moves = [_]Move{
    .{ .table = "llm_history", .to = "created_at_ms", .from = "created_at_nano", .unit = .nano },
    .{ .table = "logs", .to = "created_at_ms", .from = "created_at_nano", .unit = .micro },
    .{ .table = "session_skills", .to = "loaded_at_ms", .from = "loaded_at_nano", .unit = .second },
    .{ .table = "worker", .to = "last_activity_at_ms", .from = "last_activity_nano", .unit = .second },
    .{ .table = "session_progressive_tool", .to = "loaded_at_ms", .from = "loaded_at_nano", .unit = .second },
    .{ .table = "session_agents", .to = "updated_at_ms", .from = "updated_at", .unit = .second },
    .{ .table = "workspace_item_tasks", .to = "last_human_touched_at_ms", .from = "last_human_touched_at_nano", .unit = .milli },
    .{ .table = "sessions", .to = "last_human_touched_at_ms", .from = "last_human_touched_at_nano", .unit = .milli },
    .{ .table = "sessions", .to = "created_at_ms", .from = "created_at", .unit = .text },
    .{ .table = "sessions", .to = "updated_at_ms", .from = "updated_at", .unit = .text },
    .{ .table = "sessions", .to = "plan_updated_at_ms", .from = "plan_updated_at", .unit = .text },
    .{ .table = "sessions", .to = "transcript_archived_at_ms", .from = "transcript_archived_at", .unit = .text },
};

/// An index that travels with a column: 137 creates the ms form and 138 drops
/// the legacy one, so neither release reads through the other's index.
pub const Index = struct {
    name: []const u8,
    table: []const u8,
    columns: []const u8,
};

pub const ms_indexes = [_]Index{
    .{ .name = "idx_llm_history_session_created_ms", .table = "llm_history", .columns = "session_id, created_at_ms DESC" },
    .{ .name = "idx_llm_history_created_session_ms", .table = "llm_history", .columns = "created_at_ms DESC, session_id" },
    .{ .name = "idx_llm_history_created_ms", .table = "llm_history", .columns = "created_at_ms" },
    .{ .name = "idx_logs_created_at_ms", .table = "logs", .columns = "created_at_ms DESC" },
    .{ .name = "idx_logs_session_created_ms", .table = "logs", .columns = "session_id, created_at_ms DESC" },
    .{ .name = "idx_logs_kind_created_ms", .table = "logs", .columns = "kind, created_at_ms DESC" },
    .{ .name = "idx_sessions_updated_at_ms", .table = "sessions", .columns = "updated_at_ms DESC" },
    .{ .name = "idx_sessions_cwd_created_ms", .table = "sessions", .columns = "cwd, created_at_ms DESC" },
    .{ .name = "idx_worker_last_activity_ms", .table = "worker", .columns = "last_activity_at_ms DESC" },
};

/// The legacy indexes 138 drops — each reads a column that is going away.
pub const legacy_indexes = [_][]const u8{
    "idx_llm_history_session_created",
    "idx_llm_history_created_session",
    "idx_llm_history_created_iso",
    "idx_logs_created_at_nano",
    "idx_logs_session_created",
    "idx_logs_kind_created",
    "idx_sessions_updated_at",
    "idx_sessions_cwd_created",
    "idx_worker_last_activity_nano",
};

/// The legacy value as epoch milliseconds. Integer division floors, so a
/// nanosecond value loses its sub-millisecond tail instead of rounding up.
pub fn toMsSql(allocator: std.mem.Allocator, move: Move) ![]u8 {
    return switch (move.unit) {
        .nano => std.fmt.allocPrint(allocator, "CAST({s} AS BIGINT) / 1000000", .{move.from}),
        .micro => std.fmt.allocPrint(allocator, "CAST({s} AS BIGINT) / 1000", .{move.from}),
        .milli => std.fmt.allocPrint(allocator, "CAST({s} AS BIGINT)", .{move.from}),
        .second => std.fmt.allocPrint(allocator, "CAST({s} AS BIGINT) * 1000", .{move.from}),
        .text => textToMsSql(allocator, move.from),
    };
}

fn textToMsSql(allocator: std.mem.Allocator, from: []const u8) ![]u8 {
    if (dialect.is_postgres) {
        return std.fmt.allocPrint(allocator, "CAST(EXTRACT(EPOCH FROM {s}) AS BIGINT) * 1000", .{from});
    }
    return std.fmt.allocPrint(
        allocator,
        "CASE WHEN length({s}) = 19 THEN CAST(strftime('%s', {s}) AS BIGINT) * 1000 END",
        .{ from, from },
    );
}

/// The predicate a legacy value must satisfy before it is converted. The cast
/// is what makes it safe: text that is not a number falls below every floor,
/// so the row stays NULL — unknown — instead of becoming 1970.
pub fn guardSql(allocator: std.mem.Allocator, move: Move) ![]u8 {
    const bound: u64 = switch (move.unit) {
        .nano => floor.nano,
        .micro => floor.micro,
        .milli => floor.milli,
        .second => floor.second,
        .text => return std.fmt.allocPrint(allocator, "{s} IS NOT NULL", .{move.from}),
    };
    return std.fmt.allocPrint(allocator, "CAST({s} AS BIGINT) >= {d}", .{ move.from, bound });
}

const testing = std.testing;

const TestCtx = struct { db: Backend, threaded: std.Io.Threaded };

fn probeSchema() []const u8 {
    if (dialect.is_postgres) {
        return "CREATE TABLE probe (legacy BIGINT, legacy_text TIMESTAMP, at_ms BIGINT)";
    }
    return "CREATE TABLE probe (legacy NUMERIC, legacy_text TIMESTAMP, at_ms INTEGER)";
}

fn openDb(alloc: std.mem.Allocator) !TestCtx {
    var threaded = std.Io.Threaded.init(alloc, .{});
    errdefer threaded.deinit();
    var db: Backend = .{};
    errdefer db.deinit();
    try test_db.openMemory(&db, threaded.io());
    try db.exec(alloc, probeSchema(), &[_][]const u8{});
    return .{ .db = db, .threaded = threaded };
}

fn convertOne(alloc: std.mem.Allocator, db: *Backend, move: Move, legacy: []const u8) !void {
    const to_sql = try toMsSql(alloc, move);
    defer alloc.free(to_sql);
    const guard_sql = try guardSql(alloc, move);
    defer alloc.free(guard_sql);

    const insert = try std.fmt.allocPrint(alloc, "INSERT INTO probe ({s}) VALUES (?)", .{move.from});
    defer alloc.free(insert);
    try db.exec(alloc, insert, &[_][]const u8{legacy});

    try applyBackfill(alloc, db, move);
}

fn applyBackfill(alloc: std.mem.Allocator, db: *Backend, move: Move) !void {
    const to_sql = try toMsSql(alloc, move);
    defer alloc.free(to_sql);
    const guard_sql = try guardSql(alloc, move);
    defer alloc.free(guard_sql);

    const update = try std.fmt.allocPrint(
        alloc,
        "UPDATE probe SET at_ms = {s} WHERE at_ms IS NULL AND {s}",
        .{ to_sql, guard_sql },
    );
    defer alloc.free(update);
    try db.exec(alloc, update, &[_][]const u8{});
}

fn atMsOf(alloc: std.mem.Allocator, db: *Backend) !?i64 {
    var row = try db.queryRow(alloc, "SELECT COALESCE(CAST(at_ms AS TEXT), '') FROM probe", &[_][]const u8{});
    defer row.deinit(alloc);
    if (row.values[0].len == 0) return null;
    return try std.fmt.parseInt(i64, row.values[0], 10);
}

fn moveFor(unit: Unit) Move {
    return switch (unit) {
        .text => .{ .table = "probe", .to = "at_ms", .from = "legacy_text", .unit = .text },
        else => .{ .table = "probe", .to = "at_ms", .from = "legacy", .unit = unit },
    };
}

test "a nanosecond value lands on the same instant in milliseconds" {
    const alloc = testing.allocator;
    var ctx = try openDb(alloc);
    defer ctx.db.deinit();
    defer ctx.threaded.deinit();

    try convertOne(alloc, &ctx.db, moveFor(.nano), "1785055688918585706");

    try testing.expectEqual(@as(?i64, 1785055688918), try atMsOf(alloc, &ctx.db));
}

test "a microsecond value lands on the same instant in milliseconds" {
    const alloc = testing.allocator;
    var ctx = try openDb(alloc);
    defer ctx.db.deinit();
    defer ctx.threaded.deinit();

    try convertOne(alloc, &ctx.db, moveFor(.micro), "1785055763195466");

    try testing.expectEqual(@as(?i64, 1785055763195), try atMsOf(alloc, &ctx.db));
}

test "a millisecond value is carried over unchanged" {
    const alloc = testing.allocator;
    var ctx = try openDb(alloc);
    defer ctx.db.deinit();
    defer ctx.threaded.deinit();

    try convertOne(alloc, &ctx.db, moveFor(.milli), "1788164863663");

    try testing.expectEqual(@as(?i64, 1788164863663), try atMsOf(alloc, &ctx.db));
}

test "a second value gains the three digits milliseconds need" {
    const alloc = testing.allocator;
    var ctx = try openDb(alloc);
    defer ctx.db.deinit();
    defer ctx.threaded.deinit();

    try convertOne(alloc, &ctx.db, moveFor(.second), "1785144090");

    try testing.expectEqual(@as(?i64, 1785144090000), try atMsOf(alloc, &ctx.db));
}

test "a text timestamp lands on the same instant in milliseconds" {
    const alloc = testing.allocator;
    var ctx = try openDb(alloc);
    defer ctx.db.deinit();
    defer ctx.threaded.deinit();

    try convertOne(alloc, &ctx.db, moveFor(.text), "2026-11-02 02:59:32");

    try testing.expectEqual(@as(?i64, 1793588372000), try atMsOf(alloc, &ctx.db));
}

test "a number from the wrong unit stays unknown instead of becoming 1970" {
    const alloc = testing.allocator;
    var ctx = try openDb(alloc);
    defer ctx.db.deinit();
    defer ctx.threaded.deinit();

    try convertOne(alloc, &ctx.db, moveFor(.nano), "1785144090");

    try testing.expectEqual(@as(?i64, null), try atMsOf(alloc, &ctx.db));
}

test "a value millis cannot tell apart from seconds stays unknown" {
    const alloc = testing.allocator;
    var ctx = try openDb(alloc);
    defer ctx.db.deinit();
    defer ctx.threaded.deinit();

    try convertOne(alloc, &ctx.db, moveFor(.milli), "1785144090");

    try testing.expectEqual(@as(?i64, null), try atMsOf(alloc, &ctx.db));
}

test "an empty timestamp stays unknown instead of becoming 1970" {
    const alloc = testing.allocator;
    var ctx = try openDb(alloc);
    defer ctx.db.deinit();
    defer ctx.threaded.deinit();

    try convertOne(alloc, &ctx.db, moveFor(.text), "");

    try testing.expectEqual(@as(?i64, null), try atMsOf(alloc, &ctx.db));
}

test "an already converted row is never overwritten by a replay" {
    const alloc = testing.allocator;
    var ctx = try openDb(alloc);
    defer ctx.db.deinit();
    defer ctx.threaded.deinit();

    try convertOne(alloc, &ctx.db, moveFor(.second), "1785144090");
    try ctx.db.exec(alloc, "UPDATE probe SET legacy = 1600000000", &[_][]const u8{});
    try applyBackfill(alloc, &ctx.db, moveFor(.second));

    try testing.expectEqual(@as(?i64, 1785144090000), try atMsOf(alloc, &ctx.db));
}

test "no two columns move onto the same name in one table" {
    for (moves, 0..) |a, i| {
        for (moves[i + 1 ..]) |b| {
            if (!std.mem.eql(u8, a.table, b.table)) continue;
            try testing.expect(!std.mem.eql(u8, a.to, b.to));
        }
    }
}

test "every move lands on a millisecond column with a new name" {
    for (moves) |move| {
        try testing.expect(std.mem.endsWith(u8, move.to, "_at_ms"));
        try testing.expect(!std.mem.eql(u8, move.to, move.from));
    }
}
