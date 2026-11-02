const std = @import("std");
const test_db = @import("../testing/test_db.zig");
const common = @import("common.zig");
const timestamp_columns = @import("timestamp_columns.zig");

const Backend = common.Backend;
const dialect = common.dialect;
const addColumnIfMissing = common.addColumnIfMissing;

/// Migration 136 — step 1 of 3: every timestamp column gets its millisecond
/// twin, nullable with no default, because NULL is "we do not know when" and a
/// default of 0 would say 1970. Migration 138 is the staged drop.
pub const Migration136ExpandTimestampMilliseconds = struct {
    pub const version: u32 = 136;
    pub const name = "expand_timestamps_to_milliseconds";

    pub fn up(db: *Backend, allocator: std.mem.Allocator) anyerror!void {
        for (timestamp_columns.moves) |move| {
            if (!try dialect.tableExists(.{ .db = db }, allocator, move.table)) continue;
            const definition = try std.fmt.allocPrint(
                allocator,
                "{s} {s}",
                .{ move.to, dialect.epoch_ms_type },
            );
            defer allocator.free(definition);
            try addColumnIfMissing(.{ .db = db }, allocator, move.table, move.to, definition);
        }
    }
};

const testing = std.testing;

const TestCtx = struct { db: Backend, threaded: std.Io.Threaded };

const legacy_schema = [_][]const u8{
    "CREATE TABLE llm_history (id TEXT PRIMARY KEY, created_at_nano NUMERIC, created_iso TEXT)",
    "CREATE TABLE logs (id TEXT PRIMARY KEY, created_at_nano BIGINT NOT NULL)",
    "CREATE TABLE session_skills (session_id TEXT NOT NULL, skill_name TEXT NOT NULL, loaded_at_nano BIGINT)",
    "CREATE TABLE worker (id TEXT PRIMARY KEY, last_activity_nano BIGINT)",
    "CREATE TABLE session_progressive_tool (session_id TEXT NOT NULL, tool_name TEXT NOT NULL, loaded_at_nano BIGINT)",
    "CREATE TABLE session_agents (session_id TEXT NOT NULL, agent_name TEXT NOT NULL, updated_at BIGINT)",
    "CREATE TABLE workspace_item_tasks (id TEXT PRIMARY KEY, last_human_touched_at_nano BIGINT)",
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

const legacy_rows = [_][]const u8{
    "INSERT INTO llm_history (id, created_at_nano, created_iso) VALUES ('r1', 1785055688918585706, '2026-07-26 08:48:08')",
    "INSERT INTO logs (id, created_at_nano) VALUES ('r1', 1785055763195466)",
    "INSERT INTO session_skills (session_id, skill_name, loaded_at_nano) VALUES ('r1', 'k1', 1785144090)",
    "INSERT INTO worker (id, last_activity_nano) VALUES ('r1', 1793596359)",
    "INSERT INTO session_progressive_tool (session_id, tool_name, loaded_at_nano) VALUES ('r1', 't1', 1789199897)",
    "INSERT INTO session_agents (session_id, agent_name, updated_at) VALUES ('r1', 'a1', 1789199897)",
    "INSERT INTO workspace_item_tasks (id, last_human_touched_at_nano) VALUES ('r1', 1793596233216)",
    "INSERT INTO sessions (id, created_at, updated_at, last_human_touched_at_nano, plan_updated_at, transcript_archived_at) VALUES ('r1', '2026-11-02 02:59:32', '2026-11-02 05:12:39', 1788164863663, '2026-11-01 10:00:00', '2026-10-30 09:00:00')",
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

fn columnCountOf(alloc: std.mem.Allocator, db: *Backend, table: []const u8, column: []const u8) !i64 {
    const sql = "SELECT COUNT(*) FROM " ++ dialect.table_columns_of_bound_table ++ " WHERE name = ?";
    var row = try db.queryRow(alloc, sql, &[_][]const u8{ table, column });
    defer row.deinit(alloc);
    return std.fmt.parseInt(i64, row.values[0], 10) catch 0;
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

test "Migration136 gives every legacy timestamp column a millisecond twin" {
    const alloc = testing.allocator;
    var ctx = try openDb(alloc);
    defer ctx.db.deinit();
    defer ctx.threaded.deinit();

    try Migration136ExpandTimestampMilliseconds.up(&ctx.db, alloc);

    for (timestamp_columns.moves) |move| {
        try testing.expectEqual(@as(i64, 1), try columnCountOf(alloc, &ctx.db, move.table, move.to));
    }
}

test "Migration136 leaves every pre-existing row unknown rather than claiming 1970" {
    const alloc = testing.allocator;
    var ctx = try openDb(alloc);
    defer ctx.db.deinit();
    defer ctx.threaded.deinit();

    for (legacy_rows) |insert| try ctx.db.exec(alloc, insert, &[_][]const u8{});

    try Migration136ExpandTimestampMilliseconds.up(&ctx.db, alloc);

    for (timestamp_columns.moves) |move| {
        try testing.expectEqual(@as(?i64, null), try valueOf(alloc, &ctx.db, move.table, move.to));
    }
}

test "Migration136 replaying is a no-op" {
    const alloc = testing.allocator;
    var ctx = try openDb(alloc);
    defer ctx.db.deinit();
    defer ctx.threaded.deinit();

    try Migration136ExpandTimestampMilliseconds.up(&ctx.db, alloc);
    try Migration136ExpandTimestampMilliseconds.up(&ctx.db, alloc);

    for (timestamp_columns.moves) |move| {
        try testing.expectEqual(@as(i64, 1), try columnCountOf(alloc, &ctx.db, move.table, move.to));
    }
}

test "Migration136 is registered in allMigrations" {
    for (@import("migration.zig").allMigrations) |m| {
        if (m.version == Migration136ExpandTimestampMilliseconds.version and
            std.mem.eql(u8, m.name, Migration136ExpandTimestampMilliseconds.name)) return;
    }
    return error.Migration136NotRegistered;
}
