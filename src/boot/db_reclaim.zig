//! The free pages a long-lived SQLite file hoards: how to hand the ones already
//! allocated back to the filesystem, and how to set the mode that lets the next
//! batch go without a full rebuild.
//!
//! Both need the file OUT of WAL mode for a few seconds, so they belong to a
//! maintenance window and never to a boot.

const std = @import("std");
const databases = @import("databases");
const dialect = @import("../dialect.zig");
const testing = std.testing;

pub const database = databases.database;

/// `PRAGMA auto_vacuum`, in SQLite's own numbering.
pub const Mode = enum(u8) {
    none = 0,
    full = 1,
    incremental = 2,

    pub fn text(self: Mode) []const u8 {
        return @tagName(self);
    }
};

/// Free pages are a SQLite file concept. A postgres build reports that instead
/// of pretending to reclaim anything.
pub const supported: bool = !dialect.is_postgres;

pub const Size = struct {
    pages: i64 = 0,
    page_size: i64 = 0,

    pub fn bytes(self: Size) i64 {
        return self.pages * self.page_size;
    }

    pub fn mib(self: Size) i64 {
        return @divTrunc(self.bytes(), 1024 * 1024);
    }
};

pub const ReclaimReport = struct {
    mode_before: Mode = .none,
    mode_after: Mode = .none,
    journal_mode_after: []const u8 = "",
    size_before: Size = .{},
    size_after: Size = .{},
};

pub const ReleaseReport = struct {
    pages_before: i64 = 0,
    pages_after: i64 = 0,
    steps: i64 = 0,
};

/// sqlite truncates ONE page per `PRAGMA incremental_vacuum`, so a release is a
/// loop. This is the loop's ceiling: a cron tick hands back at most this many
/// pages and leaves the rest to the next tick, so no tick runs long.
pub const pages_per_release: i64 = 256;

fn pragmaText(db: *database.Db, allocator: std.mem.Allocator, sql: []const u8) ![]u8 {
    var row = try db.queryRow(allocator, sql, &.{});
    defer row.deinit(allocator);
    if (row.values.len == 0) return error.NoPragmaValue;
    return allocator.dupe(u8, row.values[0]);
}

fn pragmaInt(db: *database.Db, allocator: std.mem.Allocator, sql: []const u8) !i64 {
    const raw = try pragmaText(db, allocator, sql);
    defer allocator.free(raw);
    return std.fmt.parseInt(i64, raw, 10) catch error.NoPragmaValue;
}

/// The auto-vacuum mode the database is IN. `PRAGMA auto_vacuum=INCREMENTAL`
/// does not move this on a database that already holds tables; only a `VACUUM`
/// does, which is why the readback and not the request is what callers see.
pub fn mode(db: *database.Db, allocator: std.mem.Allocator) !Mode {
    if (comptime !supported) return .none;
    return switch (try pragmaInt(db, allocator, "PRAGMA auto_vacuum")) {
        1 => .full,
        2 => .incremental,
        else => .none,
    };
}

pub fn size(db: *database.Db, allocator: std.mem.Allocator) !Size {
    if (comptime !supported) return .{};
    return .{
        .pages = try pragmaInt(db, allocator, "PRAGMA page_count"),
        .page_size = try pragmaInt(db, allocator, "PRAGMA page_size"),
    };
}

pub fn journalMode(db: *database.Db, allocator: std.mem.Allocator) ![]u8 {
    if (comptime !supported) return allocator.dupe(u8, "");
    return pragmaText(db, allocator, "PRAGMA journal_mode");
}

/// The maintenance-window pass: leave WAL, set the mode, `VACUUM` (the only
/// statement that both applies the mode and truncates the file), go back to WAL.
///
/// A WAL database cannot change its auto_vacuum setting in place, and a `VACUUM`
/// only applies the setting it finds — so the pragma has to land between the two
/// journal switches. The switch back is unconditional: leaving a live database in
/// DELETE mode serializes every reader behind the writer.
pub fn reclaim(db: *database.Db, allocator: std.mem.Allocator) !ReclaimReport {
    var report = ReclaimReport{
        .mode_before = try mode(db, allocator),
        .size_before = try size(db, allocator),
    };
    if (comptime !supported) {
        report.mode_after = report.mode_before;
        report.size_after = report.size_before;
        report.journal_mode_after = try allocator.dupe(u8, "");
        return report;
    }

    // `exec`, not a query: switching the journal mode has to happen on the WRITE
    // connection, and `db.query` may be served by a pooled reader that cannot
    // change it. The mode it lands in is read back below.
    try db.exec(allocator, "PRAGMA journal_mode = DELETE", &.{});
    // The restore is what keeps a live database usable, so it runs even when the
    // VACUUM fails.
    errdefer db.exec(allocator, "PRAGMA journal_mode = WAL", &.{}) catch {};

    try db.exec(allocator, "PRAGMA auto_vacuum = INCREMENTAL", &.{});
    try db.exec(allocator, "VACUUM", &.{});
    try db.exec(allocator, "PRAGMA journal_mode = WAL", &.{});

    report.mode_after = try mode(db, allocator);
    report.size_after = try size(db, allocator);
    report.journal_mode_after = try journalMode(db, allocator);
    return report;
}

/// Hand the free pages at the tail of the file back, up to `pages_per_release` of
/// them. A no-op until `reclaim` has run once: `incremental_vacuum` needs the mode
/// the vacuum sets, and asks for nothing before that.
pub fn releaseFreePages(db: *database.Db, allocator: std.mem.Allocator) !ReleaseReport {
    if (comptime !supported) return .{};
    if (try mode(db, allocator) != .incremental) return .{};

    var report = ReleaseReport{ .pages_before = (try size(db, allocator)).pages };
    report.pages_after = report.pages_before;

    // The pages a delete freed are still in frames of the log, and sqlite only
    // truncates the file once the log is empty — a PASSIVE checkpoint, which does
    // apply the frames, leaves the truncation with nothing to do. Measured: with
    // PASSIVE the file stays the same size, with TRUNCATE it shrinks. A checkpoint
    // that cannot take the lock is not an error: nothing shrinks, and the report
    // says so.
    db.exec(allocator, "PRAGMA wal_checkpoint(TRUNCATE)", &.{}) catch {};

    while (report.steps < pages_per_release) {
        try db.exec(allocator, "PRAGMA incremental_vacuum", &.{});
        const pages = (try size(db, allocator)).pages;
        if (pages >= report.pages_after) break;
        report.pages_after = pages;
        report.steps += 1;
    }
    return report;
}

// ─── Tests ───────────────────────────────────────────────────────────────
// Every one of these needs a REAL file: auto-vacuum, journal mode and
// incremental truncation are file-header facts that `:memory:` cannot express.

const FileDb = struct {
    threaded: std.Io.Threaded,
    db: database.Db = .{},
    tmp: testing.TmpDir,
    allocator: std.mem.Allocator = testing.allocator,

    fn open() !FileDb {
        const alloc = testing.allocator;
        var tmp = testing.tmpDir(.{});
        errdefer tmp.cleanup();

        var dir_buf: [std.fs.max_path_bytes]u8 = undefined;
        const dir_len = try tmp.dir.realPath(testing.io, &dir_buf);
        const joined = try std.fs.path.join(alloc, &.{ dir_buf[0..dir_len], "reclaim.db" });
        defer alloc.free(joined);
        const path = try alloc.dupeZ(u8, joined);
        defer alloc.free(path);

        var threaded = std.Io.Threaded.init(alloc, .{});
        errdefer threaded.deinit();

        var db: database.Db = .{};
        errdefer db.deinit();
        // No pooled readers: reclaim switches the journal mode, which sqlite
        // refuses while ANY other connection has the file open ("database is
        // locked"), idle or not. The command itself opens the same way.
        const open_config: database.OpenConfig = if (database.backend_is_postgres)
            .{ .postgres_conninfo = path }
        else
            .{ .sqlite_path = path };
        try database.openConfigured(&db, threaded.io(), open_config, .{
            .sqlite = .{ .read_conns = 0 },
            .postgres = .{},
        });

        return .{ .threaded = threaded, .db = db, .tmp = tmp };
    }

    fn deinit(self: *FileDb) void {
        self.db.deinit();
        self.threaded.deinit();
        self.tmp.cleanup();
    }

    fn exec(self: *FileDb, sql: []const u8) !void {
        try self.db.exec(self.allocator, sql, &.{});
    }

    /// Fill the file with `rows` 500-byte rows, then empty it: the case a prune
    /// leaves behind.
    fn fillThenEmpty(self: *FileDb, rows: usize) !void {
        try self.exec("CREATE TABLE ballast (v TEXT NOT NULL)");
        const value = try self.allocator.alloc(u8, 500);
        defer self.allocator.free(value);
        @memset(value, 'x');
        for (0..rows) |_| {
            try self.db.exec(self.allocator, "INSERT INTO ballast (v) VALUES (?)", &.{value});
        }
        try self.exec("DELETE FROM ballast");
    }
};

test "reclaim shrinks the file and leaves it in incremental mode" {
    if (comptime !supported) return;
    var ctx = try FileDb.open();
    defer ctx.deinit();

    try ctx.fillThenEmpty(2_000);
    try testing.expectEqual(Mode.none, try mode(&ctx.db, testing.allocator));

    const report = try reclaim(&ctx.db, testing.allocator);
    defer testing.allocator.free(report.journal_mode_after);

    try testing.expectEqual(Mode.none, report.mode_before);
    try testing.expectEqual(Mode.incremental, report.mode_after);
    try testing.expect(report.size_after.pages < report.size_before.pages);
    try testing.expectEqualStrings("wal", report.journal_mode_after);
}

test "reclaim puts the journal mode back, so the next boot is not serialized" {
    if (comptime !supported) return;
    var ctx = try FileDb.open();
    defer ctx.deinit();

    try ctx.fillThenEmpty(200);
    const report = try reclaim(&ctx.db, testing.allocator);
    defer testing.allocator.free(report.journal_mode_after);

    const after = try journalMode(&ctx.db, testing.allocator);
    defer testing.allocator.free(after);
    try testing.expectEqualStrings("wal", after);
}

test "reclaim a second time has nothing left to reclaim" {
    if (comptime !supported) return;
    var ctx = try FileDb.open();
    defer ctx.deinit();

    try ctx.fillThenEmpty(2_000);
    const first = try reclaim(&ctx.db, testing.allocator);
    defer testing.allocator.free(first.journal_mode_after);

    const second = try reclaim(&ctx.db, testing.allocator);
    defer testing.allocator.free(second.journal_mode_after);

    try testing.expectEqual(Mode.incremental, second.mode_before);
    try testing.expectEqual(second.size_before.pages, second.size_after.pages);
}

test "releaseFreePages hands back the pages a delete freed" {
    if (comptime !supported) return;
    var ctx = try FileDb.open();
    defer ctx.deinit();

    const first = try reclaim(&ctx.db, testing.allocator);
    defer testing.allocator.free(first.journal_mode_after);

    try ctx.fillThenEmpty(2_000);
    const report = try releaseFreePages(&ctx.db, testing.allocator);

    try testing.expect(report.steps > 0);
    try testing.expect(report.pages_after < report.pages_before);
}

test "releaseFreePages does nothing before reclaim has set the mode" {
    if (comptime !supported) return;
    var ctx = try FileDb.open();
    defer ctx.deinit();

    try ctx.fillThenEmpty(2_000);
    const report = try releaseFreePages(&ctx.db, testing.allocator);

    try testing.expectEqual(@as(i64, 0), report.steps);
    try testing.expectEqual(report.pages_before, report.pages_after);
}
