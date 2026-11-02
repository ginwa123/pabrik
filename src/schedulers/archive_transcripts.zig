//! Moves the whole transcript of a session whose newest message is older than
//! 90 days into a sibling `archive.db`, so `agent.db` keeps only the chats
//! people still open.
//!
//! A session's messages move TOGETHER — the unit is the transcript, never the
//! row — and the `sessions` row stays behind with `transcript_archived_at` set.
//! Nothing a user wrote is deleted; it changes file.

const std = @import("std");
const pabrikcore = @import("pabrikcore");
const database = pabrikcore.database;
const dialect = pabrikcore.dialect;
const loggermod = pabrikcore.loggermod;
const reclaim = pabrikcore.boot_db_reclaim;
const testing = std.testing;

pub const retention_days: i64 = 90;

/// Sessions moved per tick. Every one of them is copied and deleted inside the
/// tick's single transaction, so this is about how long the write lock is held,
/// not about how much can be archived.
pub const sessions_per_tick: usize = 8;

pub const archive_file_name = "archive.db";

const seconds_per_day: i64 = 86_400;

pub const ArchiveInput = struct {
    allocator: std.mem.Allocator,
    db: *database.Db,
    logger: ?*loggermod.Logger,
    now_unix: i64,
    /// The sibling file to archive into. Empty on a build with no sqlite file to
    /// sit beside (postgres), where there is nothing to archive.
    archive_path: []const u8,
    retention_days: i64 = retention_days,
    sessions_per_tick: usize = sessions_per_tick,
};

pub const ArchiveResult = struct {
    sessions: usize = 0,
    rows: usize = 0,
    released_pages: i64 = 0,
};

/// Where the archive for `db_path` lives: beside it, so a backup or a move takes
/// both files.
pub fn archivePathNear(allocator: std.mem.Allocator, db_path: []const u8) ![]u8 {
    if (db_path.len == 0) return allocator.alloc(u8, 0);
    const dir = std.fs.path.dirname(db_path) orelse ".";
    return std.fs.path.join(allocator, &.{ dir, archive_file_name });
}

pub fn archiveTranscripts(input: ArchiveInput) anyerror!ArchiveResult {
    // Comptime split, so a postgres build never has to typecheck the sqlite
    // statements below.
    if (comptime dialect.is_postgres) return .{};
    return archiveTranscriptsSqlite(input);
}

fn archiveTranscriptsSqlite(input: ArchiveInput) anyerror!ArchiveResult {
    var result = ArchiveResult{};
    if (input.archive_path.len == 0) return result;

    const allocator = input.allocator;
    const db = input.db;

    try db.exec(allocator, "ATTACH DATABASE ? AS archive", &.{input.archive_path});
    // Registered BEFORE the transaction's rollback defer, so it runs after it:
    // `db.exec` while a transaction holds the backend mutex would deadlock. A
    // detach that fails leaks the alias, and every later tick then fails on the
    // ATTACH, so it is reported rather than swallowed.
    defer if (db.exec(allocator, "DETACH DATABASE archive", &.{})) |_| {} else |err| {
        if (input.logger) |log| {
            log.errFmt("[archive_transcripts] detach failed: {s}\n", .{@errorName(err)});
        }
    };

    // One transaction for the whole tick. It is also what makes the ATTACH
    // visible: `db.query` is served by a pooled READ connection, and an alias
    // attached on the write connection does not exist for those. Statement for
    // statement, `tx` stays on the one connection the alias was attached to.
    var tx = try db.begin();
    errdefer tx.rollback() catch {};

    try ensureArchiveTable(.{ .tx = &tx }, allocator);

    const cutoff_unix = input.now_unix - input.retention_days * seconds_per_day;
    const cutoff_str = try std.fmt.allocPrint(allocator, "{d}", .{cutoff_unix});
    defer allocator.free(cutoff_str);
    const limit_str = try std.fmt.allocPrint(allocator, "{d}", .{input.sessions_per_tick});
    defer allocator.free(limit_str);

    // A session qualifies only when its NEWEST message is past the window, so a
    // chat somebody reopened stays whole. The three exclusions are the sessions a
    // run is touching right now: a live turn, an unanswered question, and a
    // message still waiting in the queue.
    const candidates_sql =
        \\SELECT session_id FROM llm_history
        \\WHERE COALESCE(session_id, '') <> '' AND COALESCE(created_iso, '') <> ''
        \\GROUP BY session_id
        \\HAVING MAX(created_iso) < datetime(?, 'unixepoch')
        \\   AND session_id NOT IN (SELECT session_id FROM worker)
        \\   AND session_id NOT IN (SELECT session_id FROM session_pending_question WHERE status = 'pending')
        \\   AND session_id NOT IN (SELECT session_id FROM session_queue_messages)
        \\ORDER BY MAX(created_iso)
        \\LIMIT ?
    ;

    var session_ids: std.ArrayList([]u8) = .empty;
    defer {
        for (session_ids.items) |id| allocator.free(id);
        session_ids.deinit(allocator);
    }
    // Scoped so the reader is finished before the first write.
    {
        var rows = try tx.query(allocator, candidates_sql, &.{ cutoff_str, limit_str });
        defer rows.deinit();
        while (try rows.next()) |row| {
            defer row.deinit(allocator);
            try session_ids.append(allocator, try allocator.dupe(u8, row.values[0]));
        }
    }

    if (session_ids.items.len > 0) {
        const columns = try columnList(.{ .tx = &tx }, allocator);
        defer allocator.free(columns);

        for (session_ids.items) |session_id| {
            const moved = try archiveOne(.{ .tx = &tx }, allocator, columns, session_id);
            result.sessions += 1;
            result.rows += moved;
        }
    }

    try tx.commit();

    if (result.sessions == 0) return result;

    const released = try reclaim.releaseFreePages(db, allocator);
    result.released_pages = released.pages_before - released.pages_after;
    return result;
}

/// Copy every row of one session, prove the copy, and only then delete the
/// original. All of it inside the caller's transaction, so a replay after a
/// crash finds the session already moved and has nothing to do.
fn archiveOne(
    conn: database.DbOrTx,
    allocator: std.mem.Allocator,
    columns: []const u8,
    session_id: []const u8,
) !usize {
    const insert_sql = try std.fmt.allocPrint(
        allocator,
        "INSERT INTO archive.llm_history ({s}) SELECT {s} FROM main.llm_history WHERE session_id = ?",
        .{ columns, columns },
    );
    defer allocator.free(insert_sql);

    try conn.exec(allocator, insert_sql, &.{session_id});

    const copied = try count(conn, allocator, "SELECT COUNT(*) FROM archive.llm_history WHERE session_id = ?", session_id);
    const in_main = try count(conn, allocator, "SELECT COUNT(*) FROM main.llm_history WHERE session_id = ?", session_id);
    if (copied != in_main) return error.ArchiveCopyIncomplete;

    try conn.exec(allocator, "DELETE FROM main.llm_history WHERE session_id = ?", &.{session_id});
    try conn.exec(
        allocator,
        "UPDATE main.sessions SET transcript_archived_at = CURRENT_TIMESTAMP WHERE id = ?",
        &.{session_id},
    );
    return @intCast(copied);
}

/// The archive's `llm_history` is a COLLECTION of what was archived, so it is
/// copied from this database's own DDL — same columns as the rows arriving, and
/// no FTS shadow table or sync triggers, which is why a search of `agent.db`
/// cannot return an archived message.
fn ensureArchiveTable(conn: database.DbOrTx, allocator: std.mem.Allocator) !void {
    const existing = try count(
        conn,
        allocator,
        "SELECT COUNT(*) FROM archive.sqlite_master WHERE type = 'table' AND name = 'llm_history'",
        null,
    );
    if (existing == 0) {
        const ddl = try localDdl(conn, allocator);
        defer allocator.free(ddl);
        try conn.exec(allocator, ddl, &.{});
    }

    try conn.exec(
        allocator,
        "CREATE INDEX IF NOT EXISTS archive.idx_archive_llm_history_session ON llm_history(session_id, created_at_nano)",
        &.{},
    );
}

fn localDdl(conn: database.DbOrTx, allocator: std.mem.Allocator) ![]u8 {
    var row = try conn.queryRow(
        allocator,
        "SELECT sql FROM main.sqlite_master WHERE type = 'table' AND name = 'llm_history'",
        &.{},
    );
    defer row.deinit(allocator);
    if (row.values[0].len == 0) return error.LlmHistoryTableMissing;

    const ddl = row.values[0];
    const at = std.mem.indexOf(u8, ddl, "llm_history") orelse return error.LlmHistoryTableMissing;
    return std.fmt.allocPrint(allocator, "{s}archive.{s}", .{ ddl[0..at], ddl[at..] });
}

fn columnList(conn: database.DbOrTx, allocator: std.mem.Allocator) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);

    var rows = try conn.query(allocator, "SELECT name FROM pragma_table_info('llm_history') ORDER BY cid", &.{});
    defer rows.deinit();

    while (try rows.next()) |row| {
        defer row.deinit(allocator);
        if (out.items.len > 0) try out.appendSlice(allocator, ", ");
        try out.appendSlice(allocator, row.values[0]);
    }
    if (out.items.len == 0) return error.LlmHistoryTableMissing;
    return out.toOwnedSlice(allocator);
}

fn count(conn: database.DbOrTx, allocator: std.mem.Allocator, sql: []const u8, bind: ?[]const u8) !i64 {
    var row = if (bind) |b|
        try conn.queryRow(allocator, sql, &.{b})
    else
        try conn.queryRow(allocator, sql, &.{});
    defer row.deinit(allocator);
    return std.fmt.parseInt(i64, row.values[0], 10) catch 0;
}

pub fn handle(ctx: ?*anyopaque, now_unix: i64) void {
    _ = ctx;

    const di = pabrikcore.getSingleton() catch return;
    const archive_path = archivePathNear(di.allocator, di.db_path) catch return;
    defer di.allocator.free(archive_path);

    var arena = std.heap.ArenaAllocator.init(di.allocator);
    defer arena.deinit();

    const result = archiveTranscripts(.{
        .allocator = arena.allocator(),
        .db = di.db,
        .logger = di.logger,
        .now_unix = now_unix,
        .archive_path = archive_path,
    }) catch |err| {
        di.logger.errFmt("[archive_transcripts] tick failed: {s}\n", .{@errorName(err)});
        return;
    };

    if (result.sessions == 0) return;
    di.logger.infoFmt(
        "[archive_transcripts] sessions={d} rows={d} released_pages={d}",
        .{ result.sessions, result.rows, result.released_pages },
    );
}

// ─── Tests ───────────────────────────────────────────────────────────────
// The archive is a second FILE, so every test here runs on a real one.

const FilePair = struct {
    threaded: std.Io.Threaded,
    db: database.Db = .{},
    tmp: testing.TmpDir,
    archive_path: []u8,
    allocator: std.mem.Allocator = testing.allocator,

    fn open() !FilePair {
        const alloc = testing.allocator;
        var tmp = testing.tmpDir(.{});
        errdefer tmp.cleanup();

        var dir_buf: [std.fs.max_path_bytes]u8 = undefined;
        const dir_len = try tmp.dir.realPath(testing.io, &dir_buf);
        const joined = try std.fs.path.join(alloc, &.{ dir_buf[0..dir_len], "agent.db" });
        defer alloc.free(joined);
        const path = try alloc.dupeZ(u8, joined);
        defer alloc.free(path);

        var threaded = std.Io.Threaded.init(alloc, .{});
        errdefer threaded.deinit();

        var db: database.Db = .{};
        errdefer db.deinit();
        try db.init(threaded.io(), path);

        const joined_archive = try std.fs.path.join(alloc, &.{ dir_buf[0..dir_len], archive_file_name });
        defer alloc.free(joined_archive);
        const archive_path = try alloc.dupe(u8, joined_archive);

        var self: FilePair = .{ .threaded = threaded, .db = db, .tmp = tmp, .archive_path = archive_path };
        try self.seedSchema();
        return self;
    }

    fn deinit(self: *FilePair) void {
        self.db.deinit();
        self.threaded.deinit();
        self.tmp.cleanup();
        self.allocator.free(self.archive_path);
    }

    fn seedSchema(self: *FilePair) !void {
        const a = self.allocator;
        try self.db.exec(a,
            \\CREATE TABLE llm_history (
            \\  id TEXT PRIMARY KEY,
            \\  session_id TEXT,
            \\  response_content TEXT,
            \\  created_at_nano BIGINT,
            \\  created_iso TEXT
            \\)
        , &.{});
        try self.db.exec(a, "CREATE TABLE sessions (id TEXT PRIMARY KEY, transcript_archived_at TIMESTAMP)", &.{});
        try self.db.exec(a, "CREATE TABLE worker (session_id TEXT)", &.{});
        try self.db.exec(a, "CREATE TABLE session_pending_question (session_id TEXT, status TEXT)", &.{});
        try self.db.exec(a, "CREATE TABLE session_queue_messages (session_id TEXT)", &.{});
    }

    fn season(self: *FilePair, id: []const u8) !void {
        try self.db.exec(self.allocator, "INSERT INTO sessions (id) VALUES (?)", &.{id});
    }

    /// A transcript row stamped `unix_seconds`, in the format `created_iso` holds.
    fn say(self: *FilePair, id: []const u8, session_id: []const u8, unix_seconds: i64) !void {
        var buf: [24]u8 = undefined;
        const stamp = try std.fmt.bufPrint(&buf, "{d}", .{unix_seconds});
        try self.db.exec(
            self.allocator,
            "INSERT INTO llm_history (id, session_id, response_content, created_iso) VALUES (?, ?, 'hello', datetime(?, 'unixepoch'))",
            &.{ id, session_id, stamp },
        );
    }

    fn run(self: *FilePair, now_unix: i64) !ArchiveResult {
        return archiveTranscripts(.{
            .allocator = self.allocator,
            .db = &self.db,
            .logger = null,
            .now_unix = now_unix,
            .archive_path = self.archive_path,
        });
    }

    fn countIn(self: *FilePair, schema: []const u8, sql: []const u8, bind: ?[]const u8) !i64 {
        var buf: [256]u8 = undefined;
        const scoped = try std.fmt.bufPrint(&buf, "SELECT COUNT(*) FROM {s}.{s}", .{ schema, sql });
        return count(.{ .db = &self.db }, self.allocator, scoped, bind);
    }

    /// Re-open the archive on its own to prove the rows are IN that file, not
    /// merely attached to this connection.
    fn rowsInArchiveFile(self: *FilePair, session_id: []const u8) !i64 {
        self.db.exec(self.allocator, "DETACH DATABASE archive", &.{}) catch {};
        const path = try self.allocator.dupeZ(u8, self.archive_path);
        defer self.allocator.free(path);

        var archive: database.Db = .{};
        defer archive.deinit();
        try archive.init(self.threaded.io(), path);
        return count(.{ .db = &archive }, self.allocator, "SELECT COUNT(*) FROM llm_history WHERE session_id = ?", session_id);
    }
};

const now: i64 = 1_790_000_000;

test "the whole transcript of a chat past the window moves, and the chat stays" {
    var ctx = try FilePair.open();
    defer ctx.deinit();

    try ctx.season("s_old");
    try ctx.say("m1", "s_old", now - 120 * seconds_per_day);
    try ctx.say("m2", "s_old", now - 100 * seconds_per_day);

    const result = try ctx.run(now);

    try testing.expectEqual(@as(usize, 1), result.sessions);
    try testing.expectEqual(@as(usize, 2), result.rows);
    try testing.expectEqual(@as(i64, 0), try ctx.countIn("main", "llm_history WHERE session_id = ?", "s_old"));
    try testing.expectEqual(@as(i64, 2), try ctx.rowsInArchiveFile("s_old"));
    try testing.expectEqual(@as(i64, 1), try ctx.countIn("main", "sessions WHERE id = ?", "s_old"));

    var row = try ctx.db.queryRow(testing.allocator, "SELECT COALESCE(transcript_archived_at, '') FROM sessions WHERE id = 's_old'", &.{});
    defer row.deinit(testing.allocator);
    try testing.expect(row.values[0].len > 0);
}

test "a chat with one message inside the window is left whole" {
    var ctx = try FilePair.open();
    defer ctx.deinit();

    try ctx.season("s_live");
    try ctx.say("old", "s_live", now - 200 * seconds_per_day);
    try ctx.say("new", "s_live", now - 2 * seconds_per_day);

    const result = try ctx.run(now);

    try testing.expectEqual(@as(usize, 0), result.sessions);
    try testing.expectEqual(@as(i64, 2), try ctx.countIn("main", "llm_history WHERE session_id = ?", "s_live"));
}

test "a chat with a message still waiting in the queue is not moved" {
    var ctx = try FilePair.open();
    defer ctx.deinit();

    try ctx.season("s_queued");
    try ctx.say("m1", "s_queued", now - 120 * seconds_per_day);
    try ctx.db.exec(testing.allocator, "INSERT INTO session_queue_messages (session_id) VALUES ('s_queued')", &.{});

    const result = try ctx.run(now);

    try testing.expectEqual(@as(usize, 0), result.sessions);
    try testing.expectEqual(@as(i64, 1), try ctx.countIn("main", "llm_history WHERE session_id = ?", "s_queued"));
}

test "a chat with an unanswered question is not moved" {
    var ctx = try FilePair.open();
    defer ctx.deinit();

    try ctx.season("s_asking");
    try ctx.say("m1", "s_asking", now - 120 * seconds_per_day);
    try ctx.db.exec(testing.allocator, "INSERT INTO session_pending_question (session_id, status) VALUES ('s_asking', 'pending')", &.{});

    try testing.expectEqual(@as(usize, 0), (try ctx.run(now)).sessions);
    try testing.expectEqual(@as(i64, 1), try ctx.countIn("main", "llm_history WHERE session_id = ?", "s_asking"));
}

test "running the pass again finds nothing left to move" {
    var ctx = try FilePair.open();
    defer ctx.deinit();

    try ctx.season("s_old");
    try ctx.say("m1", "s_old", now - 120 * seconds_per_day);

    try testing.expectEqual(@as(usize, 1), (try ctx.run(now)).sessions);

    const second = try ctx.run(now);
    try testing.expectEqual(@as(usize, 0), second.sessions);
    try testing.expectEqual(@as(usize, 0), second.rows);
    try testing.expectEqual(@as(i64, 1), try ctx.rowsInArchiveFile("s_old"));
}

test "the pass moves no more than one tick's worth of chats" {
    var ctx = try FilePair.open();
    defer ctx.deinit();

    for (0..sessions_per_tick + 2) |i| {
        var buf: [32]u8 = undefined;
        const id = try std.fmt.bufPrint(&buf, "s_{d}", .{i});
        try ctx.season(id);
        var msg_buf: [32]u8 = undefined;
        try ctx.say(try std.fmt.bufPrint(&msg_buf, "m_{d}", .{i}), id, now - 120 * seconds_per_day);
    }

    const result = try ctx.run(now);

    try testing.expectEqual(sessions_per_tick, result.sessions);
    const remaining = try ctx.countIn("main", "llm_history", null);
    try testing.expectEqual(@as(i64, 2), remaining);
}
