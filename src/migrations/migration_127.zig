const std = @import("std");
const test_db = @import("../testing/test_db.zig");
const common = @import("common.zig");

const Backend = common.Backend;
const dialect = common.dialect;

pub const Migration127BackfillSessionTimestamps = struct {
    pub const version: u32 = 127;
    pub const name = "backfill_session_timestamps";

    pub fn up(db: *Backend, allocator: std.mem.Allocator) anyerror!void {
        const from_history = if (dialect.is_postgres)
            \\UPDATE sessions SET created_at = (
            \\    SELECT to_char(to_timestamp(MIN(h.created_at_nano) / 1000000000), 'YYYY-MM-DD HH24:MI:SS')
            \\    FROM llm_history h
            \\    WHERE h.session_id = sessions.id AND h.created_at_nano >= 1000000000000000
            \\)
            \\WHERE (created_at IS NULL OR created_at = '')
            \\  AND EXISTS (
            \\    SELECT 1 FROM llm_history h
            \\    WHERE h.session_id = sessions.id AND h.created_at_nano >= 1000000000000000
            \\  )
        else
            \\UPDATE sessions SET created_at = (
            \\    SELECT strftime('%Y-%m-%d %H:%M:%S', MIN(h.created_at_nano) / 1000000000, 'unixepoch')
            \\    FROM llm_history h
            \\    WHERE h.session_id = sessions.id AND h.created_at_nano >= 1000000000000000
            \\)
            \\WHERE (created_at IS NULL OR created_at = '')
            \\  AND EXISTS (
            \\    SELECT 1 FROM llm_history h
            \\    WHERE h.session_id = sessions.id AND h.created_at_nano >= 1000000000000000
            \\  )
        ;
        try db.exec(allocator, from_history, &[_][]const u8{});

        try db.exec(allocator,
            \\UPDATE sessions SET updated_at = created_at
            \\WHERE updated_at IS NULL AND created_at IS NOT NULL
        , &[_][]const u8{});
    }
};

const testing = std.testing;

fn openDb(alloc: std.mem.Allocator) !struct { db: Backend, threaded: std.Io.Threaded } {
    var threaded = std.Io.Threaded.init(alloc, .{});
    errdefer threaded.deinit();
    var db: Backend = .{};
    errdefer db.deinit();
    try test_db.openMemory(&db, threaded.io());
    try db.exec(alloc,
        \\CREATE TABLE sessions (
        \\    id TEXT PRIMARY KEY,
        \\    name TEXT NOT NULL,
        \\    created_at TIMESTAMP DEFAULT NULL,
        \\    updated_at TIMESTAMP DEFAULT NULL
        \\)
    , &[_][]const u8{});
    try db.exec(alloc,
        \\CREATE TABLE llm_history (
        \\    id TEXT PRIMARY KEY,
        \\    session_id TEXT NOT NULL,
        \\    created_at_nano INTEGER
        \\)
    , &[_][]const u8{});
    return .{ .db = db, .threaded = threaded };
}

fn valueOf(alloc: std.mem.Allocator, db: *Backend, id: []const u8, column: []const u8) ![]u8 {
    var sql_buf: [128]u8 = undefined;
    const sql = std.fmt.bufPrint(&sql_buf, "SELECT {s} FROM sessions WHERE id = ?", .{column}) catch
        return error.BufferTooSmall;
    var row = try db.queryRow(alloc, sql, &[_][]const u8{id});
    defer row.deinit(alloc);
    return try alloc.dupe(u8, row.values[0]);
}

test "Migration127 dates a session from its first message" {
    const alloc = testing.allocator;
    var ctx = try openDb(alloc);
    defer ctx.db.deinit();
    defer ctx.threaded.deinit();
    const db = &ctx.db;

    try db.exec(alloc, "INSERT INTO sessions (id, name) VALUES ('s_null', 'orphan')", &[_][]const u8{});
    try db.exec(alloc,
        \\INSERT INTO llm_history (id, session_id, created_at_nano) VALUES
        \\  ('h2', 's_null', 1793559620488534418),
        \\  ('h3', 's_null', 1793559800000000000)
    , &[_][]const u8{});

    try Migration127BackfillSessionTimestamps.up(db, alloc);

    const created = try valueOf(alloc, db, "s_null", "created_at");
    defer alloc.free(created);
    try testing.expectEqualStrings("2026-11-01 19:00:20", created);

    const updated = try valueOf(alloc, db, "s_null", "updated_at");
    defer alloc.free(updated);
    try testing.expectEqualStrings("2026-11-01 19:00:20", updated);
}

test "Migration127 leaves a session that already had a timestamp alone" {
    const alloc = testing.allocator;
    var ctx = try openDb(alloc);
    defer ctx.db.deinit();
    defer ctx.threaded.deinit();
    const db = &ctx.db;

    try db.exec(alloc,
        \\INSERT INTO sessions (id, name, created_at, updated_at)
        \\VALUES ('s_ok', 'has a date', '2026-01-02 03:04:05', '2026-02-03 04:05:06')
    , &[_][]const u8{});
    try db.exec(
        alloc,
        "INSERT INTO llm_history (id, session_id, created_at_nano) VALUES ('h1', 's_ok', 1793559620488534418)",
        &[_][]const u8{},
    );

    try Migration127BackfillSessionTimestamps.up(db, alloc);

    const created = try valueOf(alloc, db, "s_ok", "created_at");
    defer alloc.free(created);
    try testing.expectEqualStrings("2026-01-02 03:04:05", created);
}

test "Migration127 never dates a session from a millisecond row as if it were nanoseconds" {
    const alloc = testing.allocator;
    var ctx = try openDb(alloc);
    defer ctx.db.deinit();
    defer ctx.threaded.deinit();
    const db = &ctx.db;

    try db.exec(alloc, "INSERT INTO sessions (id, name) VALUES ('s_ms', 'millis only')", &[_][]const u8{});
    try db.exec(
        alloc,
        "INSERT INTO llm_history (id, session_id, created_at_nano) VALUES ('h4', 's_ms', 1788164863663)",
        &[_][]const u8{},
    );

    try Migration127BackfillSessionTimestamps.up(db, alloc);

    const created = try valueOf(alloc, db, "s_ms", "created_at");
    defer alloc.free(created);
    try testing.expectEqualStrings("", created);
}

test "Migration127 replaying is a no-op" {
    const alloc = testing.allocator;
    var ctx = try openDb(alloc);
    defer ctx.db.deinit();
    defer ctx.threaded.deinit();
    const db = &ctx.db;

    try db.exec(alloc, "INSERT INTO sessions (id, name) VALUES ('s_null', 'orphan')", &[_][]const u8{});
    try db.exec(
        alloc,
        "INSERT INTO llm_history (id, session_id, created_at_nano) VALUES ('h1', 's_null', 1793559620488534418)",
        &[_][]const u8{},
    );

    try Migration127BackfillSessionTimestamps.up(db, alloc);
    try Migration127BackfillSessionTimestamps.up(db, alloc);

    const created = try valueOf(alloc, db, "s_null", "created_at");
    defer alloc.free(created);
    try testing.expectEqualStrings("2026-11-01 19:00:20", created);
}

test "Migration127 is registered in allMigrations" {
    for (@import("migration.zig").allMigrations) |m| {
        if (m.version == Migration127BackfillSessionTimestamps.version) return;
    }
    return error.Migration127NotRegistered;
}
