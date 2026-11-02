const std = @import("std");
const test_db = @import("../testing/test_db.zig");
const common = @import("common.zig");

const Backend = common.Backend;
const dialect = common.dialect;
const addColumnIfMissing = common.addColumnIfMissing;

/// Migration 131 — `sessions.transcript_archived_at`: when a session's
/// `llm_history` rows were moved to the sibling `archive.db`. NULL means the
/// transcript is still in this database.
pub const Migration131AddSessionTranscriptArchivedAt = struct {
    pub const version: u32 = 131;
    pub const name = "add_session_transcript_archived_at";

    pub const column = "transcript_archived_at";

    pub fn up(db: *Backend, allocator: std.mem.Allocator) anyerror!void {
        try addColumnIfMissing(
            .{ .db = db },
            allocator,
            "sessions",
            column,
            "transcript_archived_at TIMESTAMP",
        );
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
        \\  id TEXT PRIMARY KEY,
        \\  name TEXT NOT NULL,
        \\  status TEXT NOT NULL,
        \\  created_at TIMESTAMP,
        \\  updated_at TIMESTAMP
        \\)
    , &[_][]const u8{});
    return .{ .db = db, .threaded = threaded };
}

fn archivedAtOf(alloc: std.mem.Allocator, db: *Backend, id: []const u8) !?[]u8 {
    var row = try db.queryRow(
        alloc,
        "SELECT COALESCE(transcript_archived_at, '') FROM sessions WHERE id = ?",
        &[_][]const u8{id},
    );
    defer row.deinit(alloc);
    if (row.values[0].len == 0) return null;
    return try alloc.dupe(u8, row.values[0]);
}

test "Migration131 leaves a session written before it unarchived" {
    const alloc = testing.allocator;
    var ctx = try openDb(alloc);
    defer ctx.db.deinit();
    defer ctx.threaded.deinit();
    const db = &ctx.db;

    try db.exec(
        alloc,
        "INSERT INTO sessions (id, name, status) VALUES ('s_before', 'old chat', 'inactive')",
        &[_][]const u8{},
    );

    try Migration131AddSessionTranscriptArchivedAt.up(db, alloc);

    try testing.expect(try archivedAtOf(alloc, db, "s_before") == null);
}

test "Migration131 keeps the stamp an archive pass wrote" {
    const alloc = testing.allocator;
    var ctx = try openDb(alloc);
    defer ctx.db.deinit();
    defer ctx.threaded.deinit();
    const db = &ctx.db;

    try Migration131AddSessionTranscriptArchivedAt.up(db, alloc);
    try db.exec(
        alloc,
        "INSERT INTO sessions (id, name, status, transcript_archived_at) VALUES ('s_after', 'old chat', 'inactive', '2026-11-02 03:00:00')",
        &[_][]const u8{},
    );

    const stamp = (try archivedAtOf(alloc, db, "s_after")) orelse return error.StampMissing;
    defer alloc.free(stamp);
    try testing.expect(stamp.len > 0);
}

test "Migration131 replaying is a no-op" {
    const alloc = testing.allocator;
    var ctx = try openDb(alloc);
    defer ctx.db.deinit();
    defer ctx.threaded.deinit();
    const db = &ctx.db;

    try Migration131AddSessionTranscriptArchivedAt.up(db, alloc);
    try Migration131AddSessionTranscriptArchivedAt.up(db, alloc);

    var row = try db.queryRow(
        alloc,
        "SELECT COUNT(*) FROM " ++ comptime dialect.tableColumns("sessions") ++ " WHERE name = ?",
        &[_][]const u8{Migration131AddSessionTranscriptArchivedAt.column},
    );
    defer row.deinit(alloc);
    try testing.expectEqualStrings("1", row.values[0]);
}

test "Migration131 is registered in allMigrations" {
    for (@import("migration.zig").allMigrations) |m| {
        if (m.version == Migration131AddSessionTranscriptArchivedAt.version) return;
    }
    return error.Migration131NotRegistered;
}
