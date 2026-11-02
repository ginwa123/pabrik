const std = @import("std");
const test_db = @import("../testing/test_db.zig");
const common = @import("common.zig");
const timestamp_columns = @import("timestamp_columns.zig");

const Backend = common.Backend;
const dialect = common.dialect;
const dropColumnIfExists = common.dropColumnIfExists;

/// Migration 138 — step 3 of 3: the legacy columns and the text `created_iso`
/// go. It is staged, not in `allMigrations`, so they drop in the release AFTER
/// the read switch. It refuses while a legacy value has no millisecond twin.
pub const Migration138ContractTimestampMilliseconds = struct {
    pub const version: u32 = 138;
    pub const name = "contract_timestamps_to_milliseconds";

    /// Columns that only ever duplicated a millisecond column, so there is no
    /// `Move` for them — `created_iso` is `llm_history.created_at_ms` as text.
    pub const duplicates = [_]struct { table: []const u8, column: []const u8 }{
        .{ .table = "llm_history", .column = "created_iso" },
    };

    pub fn up(db: *Backend, allocator: std.mem.Allocator) anyerror!void {
        try refuseWhenALegacyValueIsUnconverted(db, allocator);

        for (timestamp_columns.legacy_indexes) |index_name| {
            const ddl = try std.fmt.allocPrint(allocator, "DROP INDEX IF EXISTS {s}", .{index_name});
            defer allocator.free(ddl);
            try db.exec(allocator, ddl, &[_][]const u8{});
        }

        for (timestamp_columns.moves) |move| {
            try dropColumnIfExists(.{ .db = db }, allocator, move.table, move.from);
        }
        for (duplicates) |dup| {
            try dropColumnIfExists(.{ .db = db }, allocator, dup.table, dup.column);
        }
    }

    fn refuseWhenALegacyValueIsUnconverted(db: *Backend, allocator: std.mem.Allocator) !void {
        for (timestamp_columns.moves) |move| {
            if (!try dialect.columnExists(.{ .db = db }, allocator, move.table, move.from)) continue;
            if (!try dialect.columnExists(.{ .db = db }, allocator, move.table, move.to)) continue;

            const guard_sql = try timestamp_columns.guardSql(allocator, move);
            defer allocator.free(guard_sql);
            const sql = try std.fmt.allocPrint(
                allocator,
                "SELECT COUNT(*) FROM {s} WHERE {s} IS NULL AND {s}",
                .{ move.table, move.to, guard_sql },
            );
            defer allocator.free(sql);

            var row = try db.queryRow(allocator, sql, &[_][]const u8{});
            defer row.deinit(allocator);
            const unconverted = try std.fmt.parseInt(i64, row.values[0], 10);
            if (unconverted != 0) return error.TimestampsNotBackfilled;
        }
    }
};

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
    "CREATE INDEX idx_llm_history_session_created ON llm_history(session_id, created_at_nano DESC)",
    "CREATE INDEX idx_llm_history_created_iso ON llm_history(created_iso)",
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

fn openSwitched(alloc: std.mem.Allocator) !TestCtx {
    var ctx = try openDb(alloc);
    errdefer ctx.db.deinit();
    errdefer ctx.threaded.deinit();
    try @import("migration_136.zig").Migration136ExpandTimestampMilliseconds.up(&ctx.db, alloc);
    try @import("migration_137.zig").Migration137BackfillTimestampMilliseconds.up(&ctx.db, alloc);
    return ctx;
}

fn hasColumn(alloc: std.mem.Allocator, db: *Backend, table: []const u8, column: []const u8) !bool {
    return dialect.columnExists(.{ .db = db }, alloc, table, column);
}

test "Migration138 drops every legacy timestamp column once it is carried over" {
    const alloc = testing.allocator;
    var ctx = try openSwitched(alloc);
    defer ctx.db.deinit();
    defer ctx.threaded.deinit();

    try ctx.db.exec(
        alloc,
        "INSERT INTO llm_history (id, created_at_nano, created_iso) VALUES ('h1', 1785055688918585706, '2026-07-26 08:48:08')",
        &[_][]const u8{},
    );
    try @import("migration_137.zig").Migration137BackfillTimestampMilliseconds.up(&ctx.db, alloc);

    try Migration138ContractTimestampMilliseconds.up(&ctx.db, alloc);

    for (timestamp_columns.moves) |move| {
        try testing.expect(!try hasColumn(alloc, &ctx.db, move.table, move.from));
        try testing.expect(try hasColumn(alloc, &ctx.db, move.table, move.to));
    }
    try testing.expect(!try hasColumn(alloc, &ctx.db, "llm_history", "created_iso"));
}

test "Migration138 refuses to drop a timestamp that never reached its millisecond twin" {
    const alloc = testing.allocator;
    var ctx = try openSwitched(alloc);
    defer ctx.db.deinit();
    defer ctx.threaded.deinit();

    try ctx.db.exec(
        alloc,
        "INSERT INTO llm_history (id, created_at_nano) VALUES ('h1', 1785055688918585706)",
        &[_][]const u8{},
    );

    try testing.expectError(
        error.TimestampsNotBackfilled,
        Migration138ContractTimestampMilliseconds.up(&ctx.db, alloc),
    );
    try testing.expect(try hasColumn(alloc, &ctx.db, "llm_history", "created_at_nano"));
}

test "Migration138 replaying after the columns are gone is a no-op" {
    const alloc = testing.allocator;
    var ctx = try openSwitched(alloc);
    defer ctx.db.deinit();
    defer ctx.threaded.deinit();

    try Migration138ContractTimestampMilliseconds.up(&ctx.db, alloc);
    try Migration138ContractTimestampMilliseconds.up(&ctx.db, alloc);

    try testing.expect(!try hasColumn(alloc, &ctx.db, "llm_history", "created_at_nano"));
}

test "Migration138 stays out of allMigrations until the release after the read switch" {
    for (@import("migration.zig").allMigrations) |m| {
        if (m.version == Migration138ContractTimestampMilliseconds.version) {
            return error.ContractShippedWithReadSwitch;
        }
    }
}
