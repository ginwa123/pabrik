//! The SQLite connection policy pabrik opens its database with.

const std = @import("std");
const databases = @import("databases");

/// The measured-best sqlite policy for pabrik's agent database.
pub const best: databases.database.SqliteConfig = .{
    // FULL, not WAL's usual NORMAL pairing.
    .synchronous = .full,
    .busy_timeout_ms = 15_000,
    .read_conns = 1, // warm floor: readers opened up front at boot
    // 0 = no POLICY cap: read concurrency tracks in-flight reads rather than
    // a fixed pool size, which is what removed the queueing that cost 70% of
    // read throughput.
    .max_read_conns = 0,
    .cache_size_kb = 2_000, // 2 MiB per connection (SQLite default)
    .mmap_size_bytes = 256 * 1024 * 1024,
    .journal_size_limit_bytes = 64 * 1024 * 1024,
    .wal_autocheckpoint_pages = 1_000,
};

/// Page cache this policy commits to for `readers` pooled readers plus the
/// single write connection, in KiB.
pub fn pageCacheBudgetKb(readers: u32) u32 {
    return best.cache_size_kb * (readers + 1);
}

/// The reader-pool policy as one boot-log line. WHY A LINE AND NOT A COMMENT.
pub fn describeReaderPool(buf: []u8) ![]const u8 {
    return std.fmt.bufPrint(
        buf,
        "readers warm_floor={d} policy_cap={d} fd_backstop={d}",
        .{ best.read_conns, best.max_read_conns, databases.sqlite.fdDerivedReaderCap() },
    );
}

/// Read one single-column pragma back from a live connection.
fn readPragmaInt(db: *databases.database.Db, allocator: std.mem.Allocator, sql: []const u8) !i64 {
    var row = try db.queryRow(allocator, sql, &.{});
    defer row.deinit(allocator);
    if (row.values.len == 0) return error.NoValue;
    return std.fmt.parseInt(i64, row.values[0], 10);
}

/// Close the database and its WAL siblings so a test starts from nothing.
fn removeDbFiles(io: std.Io, path: [:0]const u8) void {
    std.Io.Dir.deleteFileAbsolute(io, path) catch {};
    var buf: [512]u8 = undefined;
    const wal = std.fmt.bufPrintZ(&buf, "{s}-wal", .{path}) catch return;
    std.Io.Dir.deleteFileAbsolute(io, wal) catch {};
    const shm = std.fmt.bufPrintZ(&buf, "{s}-shm", .{path}) catch return;
    std.Io.Dir.deleteFileAbsolute(io, shm) catch {};
}

test "the policy pabrik opens with is the policy the connection reports" {
    // The point of this file is that these values are APPLIED, not just
    // declared — a struct that compiles proves nothing about the pragmas.
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    const path = "/tmp/pabrik_db_config_test.db";

    removeDbFiles(io, path);
    defer removeDbFiles(io, path);

    var db: databases.database.Db = .{};
    defer db.deinit();
    try databases.database.openWithConfig(&db, io, .{ .sqlite_path = path }, best);

    // Copy the pragma out BEFORE `deinit`: `row.values` are freed by it, so
    // comparing the slice afterwards would read freed memory.
    var mode_buf: [16]u8 = undefined;
    var mode_len: usize = 0;
    {
        var row = try db.queryRow(allocator, "PRAGMA journal_mode", &.{});
        defer row.deinit(allocator);
        mode_len = @min(row.values[0].len, mode_buf.len);
        @memcpy(mode_buf[0..mode_len], row.values[0][0..mode_len]);
    }
    try std.testing.expectEqualStrings("wal", mode_buf[0..mode_len]);
    try std.testing.expectEqual(@as(i64, 15_000), try readPragmaInt(&db, allocator, "PRAGMA busy_timeout"));
    // 2 = FULL (0 OFF, 1 NORMAL, 3 EXTRA).
    try std.testing.expectEqual(@as(i64, 2), try readPragmaInt(&db, allocator, "PRAGMA synchronous"));
    // SQLite reports the page cache as a NEGATIVE KiB count.
    try std.testing.expectEqual(@as(i64, -2_000), try readPragmaInt(&db, allocator, "PRAGMA cache_size"));
    try std.testing.expectEqual(@as(i64, 64 * 1024 * 1024), try readPragmaInt(&db, allocator, "PRAGMA journal_size_limit"));
    try std.testing.expectEqual(@as(i64, 1_000), try readPragmaInt(&db, allocator, "PRAGMA wal_autocheckpoint"));
    // mmap_size may be clamped by the build/host, so assert "on", not a value.
    try std.testing.expect(try readPragmaInt(&db, allocator, "PRAGMA mmap_size") > 0);
}

test "a pooled connection still reads and writes correctly" {
    // Reader pooling must be invisible: a write on the primary connection
    // has to be visible to the next read, which lands on a reader.
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    const path = "/tmp/pabrik_db_config_pool_test.db";

    removeDbFiles(io, path);
    defer removeDbFiles(io, path);

    var db: databases.database.Db = .{};
    defer db.deinit();
    try databases.database.openWithConfig(&db, io, .{ .sqlite_path = path }, best);

    try db.exec(allocator, "CREATE TABLE t (id INTEGER PRIMARY KEY, v TEXT NOT NULL)", &.{});
    try db.exec(allocator, "INSERT INTO t (id, v) VALUES (?, ?)", &.{ "1", "written" });

    // Several reads in a row exercise more than one reader connection.
    var i: usize = 0;
    while (i < 20) : (i += 1) {
        var row = try db.queryRow(allocator, "SELECT v FROM t WHERE id = ?", &.{"1"});
        defer row.deinit(allocator);
        try std.testing.expectEqualStrings("written", row.values[0]);
    }

    // `last_insert_rowid()` is connection state, not table data: it must be
    // answered by the connection that inserted, or it returns 0.
    try db.exec(allocator, "INSERT INTO t (v) VALUES (?)", &.{"second"});
    var id_row = try db.queryRow(allocator, "SELECT last_insert_rowid()", &.{});
    defer id_row.deinit(allocator);
    try std.testing.expectEqualStrings("2", id_row.values[0]);
}

test "a committed write is visible to the next pooled read" {
    // The regression this file could not see: with reader pooling, a
    // connection handed out while a `Rows` from it is still open serves the
    // OLD snapshot, because the live iterator holds that connection's read
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    const path = "/tmp/pabrik_db_config_visibility_test.db";

    removeDbFiles(io, path);
    defer removeDbFiles(io, path);

    var db: databases.database.Db = .{};
    defer db.deinit();
    try databases.database.openWithConfig(&db, io, .{ .sqlite_path = path }, best);

    try db.exec(allocator, "CREATE TABLE t (id INTEGER PRIMARY KEY, v TEXT NOT NULL)", &.{});
    try db.exec(allocator, "INSERT INTO t (id, v) VALUES (1, 'v0')", &.{});

    const sql = "SELECT v FROM t WHERE id = ?";
    // Round i asserts: the pre-write read sees the value round i-1 wrote,
    // and the post-write read sees round i's own value. Both reads are
    // served by whatever reader the pool hands back.
    var prev_buf: [16]u8 = @splat(0);
    var want_buf: [16]u8 = @splat(0);
    @memcpy(prev_buf[0..2], "v0");
    var i: usize = 0;
    while (i < 25) : (i += 1) {
        const want = try std.fmt.bufPrint(&want_buf, "v{d}", .{i});

        {
            var rows = try db.query(allocator, sql, &.{"1"});
            defer rows.deinit();
            const row = (try rows.next()) orelse return error.NoRow;
            defer row.deinit(allocator);
            try std.testing.expectEqualStrings(&prev_buf, row.values[0]);
        }

        try db.exec(allocator, "UPDATE t SET v = ? WHERE id = ?", &.{ want, "1" });

        var rows = try db.query(allocator, sql, &.{"1"});
        defer rows.deinit();
        const row = (try rows.next()) orelse return error.NoRow;
        defer row.deinit(allocator);
        try std.testing.expectEqualStrings(want, row.values[0]);

        @memcpy(prev_buf[0..want.len], want);
    }
}

test "page cache cost per concurrent read is known and bounded" {
    // The cache is PER CONNECTION, so the number that matters is the product
    // — and with an ELASTIC pool the connection count is the concurrency, not
    // a constant in this file.
    try std.testing.expectEqual(@as(u32, 2_000), best.cache_size_kb);
    try std.testing.expectEqual(@as(u32, 2_000), pageCacheBudgetKb(0));
    try std.testing.expect(pageCacheBudgetKb(best.read_conns) <= 128 * 1024);

    // Unlimited GROWTH is deliberate: a read must never queue behind another
    // read, which is what cost 70% of read throughput before.
    try std.testing.expectEqual(@as(usize, 0), best.max_read_conns);
    try std.testing.expect(databases.sqlite.fdDerivedReaderCap() > best.read_conns);
    try std.testing.expect(databases.sqlite.FDS_PER_READER > 0);
    // A warm floor must exist, or the first burst of concurrent reads each
    // pays to open a connection.
    try std.testing.expect(best.read_conns > 0);
    try std.testing.expectEqual(databases.sqlite.Synchronous.full, best.synchronous);
}

test "the boot log names the pool's warm floor, policy cap and descriptor backstop" {
    // The warning this answers — warning: sqlite: reader pool unavailable
    // (PoolExhausted); serving this read on the write connection — says
    // nothing about how many readers exist or what stops there being more,
    var buf: [128]u8 = undefined;
    const line = try describeReaderPool(&buf);

    var expected_warm: [32]u8 = undefined;
    try std.testing.expect(std.mem.indexOf(
        u8,
        line,
        try std.fmt.bufPrint(&expected_warm, "warm_floor={d}", .{best.read_conns}),
    ) != null);

    var expected_cap: [32]u8 = undefined;
    try std.testing.expect(std.mem.indexOf(
        u8,
        line,
        try std.fmt.bufPrint(&expected_cap, "policy_cap={d}", .{best.max_read_conns}),
    ) != null);

    var expected_backstop: [48]u8 = undefined;
    try std.testing.expect(std.mem.indexOf(
        u8,
        line,
        try std.fmt.bufPrint(&expected_backstop, "fd_backstop={d}", .{databases.sqlite.fdDerivedReaderCap()}),
    ) != null);
}
