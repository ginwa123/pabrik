const std = @import("std");
const test_db = @import("../testing/test_db.zig");
const common = @import("common.zig");
const timestamp_columns = @import("timestamp_columns.zig");

const Backend = common.Backend;
const dialect = common.dialect;

/// Migration 137 — step 2 of 3: each millisecond column is filled from the
/// legacy column at that column's own unit. A value below the unit's floor is
/// left NULL, so a mis-united number can never turn into 1970.
pub const Migration137BackfillTimestampMilliseconds = struct {
    pub const version: u32 = 137;
    pub const name = "backfill_timestamps_to_milliseconds";

    pub fn up(db: *Backend, allocator: std.mem.Allocator) anyerror!void {
        for (timestamp_columns.moves) |move| {
            if (!try dialect.columnExists(.{ .db = db }, allocator, move.table, move.from)) continue;
            if (!try dialect.columnExists(.{ .db = db }, allocator, move.table, move.to)) continue;
            try backfillOne(.{ .db = db }, allocator, move);
        }
        try createMsIndexes(.{ .db = db }, allocator);
    }
};

fn backfillOne(db: dialect.DbOrTx, allocator: std.mem.Allocator, move: timestamp_columns.Move) !void {
    const to_sql = try timestamp_columns.toMsSql(allocator, move);
    defer allocator.free(to_sql);
    const guard_sql = try timestamp_columns.guardSql(allocator, move);
    defer allocator.free(guard_sql);

    const sql = try std.fmt.allocPrint(
        allocator,
        "UPDATE {s} SET {s} = {s} WHERE {s} IS NULL AND {s}",
        .{ move.table, move.to, to_sql, move.to, guard_sql },
    );
    defer allocator.free(sql);
    try db.exec(allocator, sql, &[_][]const u8{});
}

fn createMsIndexes(db: dialect.DbOrTx, allocator: std.mem.Allocator) !void {
    for (timestamp_columns.ms_indexes) |index| {
        if (!try dialect.tableExists(db, allocator, index.table)) continue;
        const ddl = try std.fmt.allocPrint(
            allocator,
            "CREATE INDEX IF NOT EXISTS {s} ON {s}({s})",
            .{ index.name, index.table, index.columns },
        );
        defer allocator.free(ddl);
        try db.exec(allocator, ddl, &[_][]const u8{});
    }
}

const testing = std.testing;

const TestCtx = struct { db: Backend, threaded: std.Io.Threaded };

const legacy_schema = [_][]const u8{
    "CREATE TABLE llm_history (id TEXT PRIMARY KEY, session_id TEXT, created_at_nano NUMERIC, created_iso TEXT)",
    "CREATE TABLE logs (id TEXT PRIMARY KEY, session_id TEXT, kind TEXT, created_at_nano BIGINT NOT NULL)",
    "CREATE TABLE session_skills (session_id TEXT NOT NULL, skill_name TEXT NOT NULL, loaded_at_nano BIGINT)",
    "CREATE TABLE worker (id TEXT PRIMARY KEY, session_id TEXT, last_activity_nano BIGINT)",
    "CREATE TABLE session_progressive_tool (session_id TEXT NOT NULL, tool_name TEXT NOT NULL, loaded_at_nano BIGINT)",
    "CREATE TABLE session_agents (session_id TEXT NOT NULL, agent_name TEXT NOT NULL, updated_at BIGINT)",
    "CREATE TABLE workspace_item_tasks (id TEXT PRIMARY KEY, workspace_item_id TEXT, last_human_touched_at_nano BIGINT)",
    \\CREATE TABLE sessions (
    \\  id TEXT PRIMARY KEY,
    \\  cwd TEXT,
    \\  created_at TIMESTAMP DEFAULT NULL,
    \\  updated_at TIMESTAMP DEFAULT NULL,
    \\  last_human_touched_at_nano BIGINT,
    \\  plan_updated_at TIMESTAMP,
    \\  transcript_archived_at TIMESTAMP
    \\)
    ,
};

fn openDb(alloc: std.mem.Allocator) !TestCtx {
    var threaded = std.Io.Threaded.init(alloc, .{});
    errdefer threaded.deinit();
    var db: Backend = .{};
    errdefer db.deinit();
    try test_db.openMemory(&db, threaded.io());
    for (legacy_schema) |ddl| try db.exec(alloc, ddl, &[_][]const u8{});
    return .{ .db = db, .threaded = threaded };
}

fn openMigrated(alloc: std.mem.Allocator) !TestCtx {
    var ctx = try openDb(alloc);
    errdefer ctx.db.deinit();
    errdefer ctx.threaded.deinit();
    try @import("migration_136.zig").Migration136ExpandTimestampMilliseconds.up(&ctx.db, alloc);
    return ctx;
}

fn valueOf(alloc: std.mem.Allocator, db: *Backend, table: []const u8, column: []const u8) !?i64 {
    const sql = try std.fmt.allocPrint(
        alloc,
        "SELECT COALESCE(CAST({s} AS TEXT), '') FROM {s} LIMIT 1",
        .{ column, table },
    );
    defer alloc.free(sql);
    var row = try db.queryRow(alloc, sql, &[_][]const u8{});
    defer row.deinit(alloc);
    if (row.values[0].len == 0) return null;
    return try std.fmt.parseInt(i64, row.values[0], 10);
}

test "Migration137 converts a nanosecond column to milliseconds" {
    const alloc = testing.allocator;
    var ctx = try openMigrated(alloc);
    defer ctx.db.deinit();
    defer ctx.threaded.deinit();

    try ctx.db.exec(
        alloc,
        "INSERT INTO llm_history (id, created_at_nano, created_iso) VALUES ('h1', 1785055688918585706, '2026-07-26 08:48:08')",
        &[_][]const u8{},
    );

    try Migration137BackfillTimestampMilliseconds.up(&ctx.db, alloc);

    try testing.expectEqual(@as(?i64, 1785055688918), try valueOf(alloc, &ctx.db, "llm_history", "created_at_ms"));
}

test "Migration137 converts a microsecond column to milliseconds" {
    const alloc = testing.allocator;
    var ctx = try openMigrated(alloc);
    defer ctx.db.deinit();
    defer ctx.threaded.deinit();

    try ctx.db.exec(
        alloc,
        "INSERT INTO logs (id, created_at_nano) VALUES ('l1', 1785055763195466)",
        &[_][]const u8{},
    );

    try Migration137BackfillTimestampMilliseconds.up(&ctx.db, alloc);

    try testing.expectEqual(@as(?i64, 1785055763195), try valueOf(alloc, &ctx.db, "logs", "created_at_ms"));
}

test "Migration137 converts a seconds column to milliseconds" {
    const alloc = testing.allocator;
    var ctx = try openMigrated(alloc);
    defer ctx.db.deinit();
    defer ctx.threaded.deinit();

    try ctx.db.exec(
        alloc,
        "INSERT INTO worker (id, last_activity_nano) VALUES ('w1', 1793596359)",
        &[_][]const u8{},
    );

    try Migration137BackfillTimestampMilliseconds.up(&ctx.db, alloc);

    try testing.expectEqual(@as(?i64, 1793596359000), try valueOf(alloc, &ctx.db, "worker", "last_activity_at_ms"));
}

test "Migration137 carries a millisecond column over unchanged" {
    const alloc = testing.allocator;
    var ctx = try openMigrated(alloc);
    defer ctx.db.deinit();
    defer ctx.threaded.deinit();

    try ctx.db.exec(
        alloc,
        "INSERT INTO workspace_item_tasks (id, last_human_touched_at_nano) VALUES ('t1', 1793596233216)",
        &[_][]const u8{},
    );

    try Migration137BackfillTimestampMilliseconds.up(&ctx.db, alloc);

    try testing.expectEqual(
        @as(?i64, 1793596233216),
        try valueOf(alloc, &ctx.db, "workspace_item_tasks", "last_human_touched_at_ms"),
    );
}

test "Migration137 converts a text timestamp column to milliseconds" {
    const alloc = testing.allocator;
    var ctx = try openMigrated(alloc);
    defer ctx.db.deinit();
    defer ctx.threaded.deinit();

    try ctx.db.exec(
        alloc,
        "INSERT INTO sessions (id, created_at, updated_at) VALUES ('s1', '2026-11-02 02:59:32', '2026-11-02 05:12:39')",
        &[_][]const u8{},
    );

    try Migration137BackfillTimestampMilliseconds.up(&ctx.db, alloc);

    try testing.expectEqual(@as(?i64, 1793588372000), try valueOf(alloc, &ctx.db, "sessions", "created_at_ms"));
    try testing.expectEqual(@as(?i64, 1793596359000), try valueOf(alloc, &ctx.db, "sessions", "updated_at_ms"));
}

test "Migration137 leaves a session that never had a timestamp unknown" {
    const alloc = testing.allocator;
    var ctx = try openMigrated(alloc);
    defer ctx.db.deinit();
    defer ctx.threaded.deinit();

    try ctx.db.exec(alloc, "INSERT INTO sessions (id) VALUES ('s_empty')", &[_][]const u8{});
    try ctx.db.exec(
        alloc,
        "INSERT INTO sessions (id, created_at, updated_at) VALUES ('s_set', '2026-11-02 02:59:32', '2026-11-02 02:59:32')",
        &[_][]const u8{},
    );

    try Migration137BackfillTimestampMilliseconds.up(&ctx.db, alloc);

    var row = try ctx.db.queryRow(
        alloc,
        "SELECT COALESCE(CAST(created_at_ms AS TEXT), 'NULL') FROM sessions WHERE id = 's_empty'",
        &[_][]const u8{},
    );
    defer row.deinit(alloc);
    try testing.expectEqualStrings("NULL", row.values[0]);
}

test "Migration137 replaying is a no-op" {
    const alloc = testing.allocator;
    var ctx = try openMigrated(alloc);
    defer ctx.db.deinit();
    defer ctx.threaded.deinit();

    try ctx.db.exec(
        alloc,
        "INSERT INTO logs (id, created_at_nano) VALUES ('l1', 1785055763195466)",
        &[_][]const u8{},
    );

    try Migration137BackfillTimestampMilliseconds.up(&ctx.db, alloc);
    try Migration137BackfillTimestampMilliseconds.up(&ctx.db, alloc);

    try testing.expectEqual(@as(?i64, 1785055763195), try valueOf(alloc, &ctx.db, "logs", "created_at_ms"));
}

test "Migration137 gives the chat history its millisecond index" {
    const alloc = testing.allocator;
    var ctx = try openMigrated(alloc);
    defer ctx.db.deinit();
    defer ctx.threaded.deinit();

    try Migration137BackfillTimestampMilliseconds.up(&ctx.db, alloc);

    var row = try ctx.db.queryRow(
        alloc,
        "SELECT COUNT(*) FROM " ++ dialect.indexes_source ++ " WHERE type = 'index' AND name = 'idx_llm_history_session_created_ms'",
        &[_][]const u8{},
    );
    defer row.deinit(alloc);
    try testing.expectEqualStrings("1", row.values[0]);
}

test "Migration137 is registered in allMigrations" {
    for (@import("migration.zig").allMigrations) |m| {
        if (m.version == Migration137BackfillTimestampMilliseconds.version and
            std.mem.eql(u8, m.name, Migration137BackfillTimestampMilliseconds.name)) return;
    }
    return error.Migration137NotRegistered;
}
