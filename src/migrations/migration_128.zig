const std = @import("std");
const test_db = @import("../testing/test_db.zig");
const common = @import("common.zig");

const Backend = common.Backend;
const dialect = common.dialect;

pub const Migration128FtsExternalContent = struct {
    pub const version: u32 = 128;
    pub const name = "fts_external_content";

    pub const content_table = "llm_history";
    pub const content_column = "response_content";
    pub const fts_column_index = 0;

    pub fn up(db: *Backend, allocator: std.mem.Allocator) anyerror!void {
        if (!dialect.has_fts5) return;

        var tx = try db.begin();
        defer tx.commitOrRollback() catch {};
        errdefer tx.rollback() catch {};

        inline for (.{ "llm_history_ai", "llm_history_ad", "llm_history_au" }) |trigger| {
            try tx.exec(allocator, "DROP TRIGGER IF EXISTS " ++ trigger, &[_][]const u8{});
        }

        try tx.exec(allocator, "DROP TABLE IF EXISTS messages_fts", &[_][]const u8{});

        try tx.exec(allocator,
            \\CREATE VIRTUAL TABLE messages_fts USING fts5(
            \\    response_content,
            \\    content='llm_history',
            \\    content_rowid='rowid',
            \\    tokenize='porter unicode61 remove_diacritics 2'
            \\)
        , &[_][]const u8{});

        try tx.exec(allocator,
            \\INSERT INTO messages_fts(messages_fts) VALUES('rebuild')
        , &[_][]const u8{});

        try tx.exec(allocator,
            \\CREATE TRIGGER llm_history_ai AFTER INSERT ON llm_history BEGIN
            \\  INSERT INTO messages_fts(rowid, response_content)
            \\  VALUES (new.rowid, COALESCE(new.response_content, ''));
            \\END
        , &[_][]const u8{});

        try tx.exec(allocator,
            \\CREATE TRIGGER llm_history_ad AFTER DELETE ON llm_history BEGIN
            \\  INSERT INTO messages_fts(messages_fts, rowid, response_content)
            \\  VALUES ('delete', old.rowid, COALESCE(old.response_content, ''));
            \\END
        , &[_][]const u8{});

        try tx.exec(allocator,
            \\CREATE TRIGGER llm_history_au AFTER UPDATE ON llm_history BEGIN
            \\  INSERT INTO messages_fts(messages_fts, rowid, response_content)
            \\  VALUES ('delete', old.rowid, COALESCE(old.response_content, ''));
            \\  INSERT INTO messages_fts(rowid, response_content)
            \\  VALUES (new.rowid, COALESCE(new.response_content, ''));
            \\END
        , &[_][]const u8{});

        try tx.commit();
    }
};

const testing = std.testing;

fn openDb(alloc: std.mem.Allocator) !struct { db: Backend, threaded: std.Io.Threaded } {
    var threaded = std.Io.Threaded.init(alloc, .{});
    errdefer threaded.deinit();
    var db: Backend = .{};
    errdefer db.deinit();
    try test_db.openMemory(&db, threaded.io());
    if (!dialect.has_fts5) return .{ .db = db, .threaded = threaded };

    try db.exec(alloc,
        \\CREATE TABLE llm_history (
        \\    id TEXT PRIMARY KEY,
        \\    session_id TEXT NOT NULL,
        \\    response_content TEXT
        \\)
    , &[_][]const u8{});
    try db.exec(alloc,
        \\CREATE VIRTUAL TABLE messages_fts USING fts5(
        \\    content,
        \\    tokenize='porter unicode61 remove_diacritics 2'
        \\)
    , &[_][]const u8{});
    try db.exec(alloc,
        \\CREATE TRIGGER llm_history_ai AFTER INSERT ON llm_history BEGIN
        \\  INSERT INTO messages_fts(rowid, content) VALUES (new.rowid, COALESCE(new.response_content, ''));
        \\END
    , &[_][]const u8{});
    try db.exec(alloc,
        \\CREATE TRIGGER llm_history_ad AFTER DELETE ON llm_history BEGIN
        \\  DELETE FROM messages_fts WHERE rowid = old.rowid;
        \\END
    , &[_][]const u8{});
    try db.exec(alloc,
        \\CREATE TRIGGER llm_history_au AFTER UPDATE ON llm_history BEGIN
        \\  DELETE FROM messages_fts WHERE rowid = old.rowid;
        \\  INSERT INTO messages_fts(rowid, content) VALUES (new.rowid, COALESCE(new.response_content, ''));
        \\END
    , &[_][]const u8{});
    return .{ .db = db, .threaded = threaded };
}

fn count(alloc: std.mem.Allocator, db: *Backend, sql: []const u8, args: []const []const u8) !u64 {
    var row = try db.queryRow(alloc, sql, args);
    defer row.deinit(alloc);
    return std.fmt.parseInt(u64, row.values[0], 10) catch 0;
}

fn matches(alloc: std.mem.Allocator, db: *Backend, term: []const u8) !u64 {
    return count(
        alloc,
        db,
        "SELECT COUNT(*) FROM messages_fts WHERE messages_fts MATCH ?",
        &[_][]const u8{term},
    );
}

test "Migration128 leaves one copy of the corpus instead of two" {
    const alloc = testing.allocator;
    var ctx = try openDb(alloc);
    defer ctx.db.deinit();
    defer ctx.threaded.deinit();
    const db = &ctx.db;
    if (!dialect.has_fts5) return;

    try db.exec(alloc,
        \\INSERT INTO llm_history (id, session_id, response_content) VALUES
        \\  ('h1', 's1', 'the deploy script waits for the tunnel'),
        \\  ('h2', 's1', 'a migration that rewrites the ledger')
    , &[_][]const u8{});

    try Migration128FtsExternalContent.up(db, alloc);

    const shadow = try count(
        alloc,
        db,
        "SELECT COUNT(*) FROM " ++ comptime dialect.tables_source ++ " WHERE name = 'messages_fts_content'",
        &[_][]const u8{},
    );
    try testing.expectEqual(@as(u64, 0), shadow);

    try testing.expectEqual(@as(u64, 1), try matches(alloc, db, "tunnel"));
    try testing.expectEqual(@as(u64, 1), try matches(alloc, db, "digging") + try matches(alloc, db, "migration"));
}

test "Migration128 keeps the index in step when a message changes" {
    const alloc = testing.allocator;
    var ctx = try openDb(alloc);
    defer ctx.db.deinit();
    defer ctx.threaded.deinit();
    const db = &ctx.db;
    if (!dialect.has_fts5) return;

    try Migration128FtsExternalContent.up(db, alloc);

    try db.exec(
        alloc,
        "INSERT INTO llm_history (id, session_id, response_content) VALUES ('h1', 's1', 'an obsolete phrase')",
        &[_][]const u8{},
    );
    try testing.expectEqual(@as(u64, 1), try matches(alloc, db, "obsolete"));

    try db.exec(
        alloc,
        "UPDATE llm_history SET response_content = 'a replacement phrase' WHERE id = 'h1'",
        &[_][]const u8{},
    );
    try testing.expectEqual(@as(u64, 0), try matches(alloc, db, "obsolete"));
    try testing.expectEqual(@as(u64, 1), try matches(alloc, db, "replacement"));

    try db.exec(alloc, "DELETE FROM llm_history WHERE id = 'h1'", &[_][]const u8{});
    try testing.expectEqual(@as(u64, 0), try matches(alloc, db, "replacement"));
}

test "Migration128 replaying is a no-op" {
    const alloc = testing.allocator;
    var ctx = try openDb(alloc);
    defer ctx.db.deinit();
    defer ctx.threaded.deinit();
    const db = &ctx.db;
    if (!dialect.has_fts5) return;

    try db.exec(
        alloc,
        "INSERT INTO llm_history (id, session_id, response_content) VALUES ('h1', 's1', 'the tunnel')",
        &[_][]const u8{},
    );

    try Migration128FtsExternalContent.up(db, alloc);
    try Migration128FtsExternalContent.up(db, alloc);

    try testing.expectEqual(@as(u64, 1), try matches(alloc, db, "tunnel"));
}

test "Migration128 is registered in allMigrations" {
    for (@import("migration.zig").allMigrations) |m| {
        if (m.version == Migration128FtsExternalContent.version) return;
    }
    return error.Migration128NotRegistered;
}
