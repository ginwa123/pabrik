//! The SQLite connection policy pabrik opens its database with. Every knob
//! is overridable from the command line (`pabrik --db-read-conns=4`), so an
//! operator can trade RAM for throughput without rebuilding.

const std = @import("std");
const databases = @import("databases");
const cli_flags = @import("../cli/flags.zig");

/// The measured-best sqlite policy for pabrik's agent database. The numbers
/// are measured against the real 4.6 GB agent.db; the reasoning for each one
/// sits on the field it belongs to.
pub const best: databases.database.SqliteConfig = .{
    // FULL, not WAL's usual NORMAL pairing.
    .synchronous = .full,
    .busy_timeout_ms = 15_000,
    .read_conns = 1, // warm floor: readers opened up front at boot
    // 0 = no POLICY cap: read concurrency tracks in-flight reads rather
    // than a fixed pool size, which is what removed the queueing that cost
    // 70% of read throughput.
    .max_read_conns = 0,
    // CAPPING IS A TRAP, measured: at 8 the RSS fell to 50 MB but 8-way latency went to 15.09 s, because
    // `reader_wait_ms` is 5 s and a read that finds every reader busy waits the whole budget before it falls back
    // to the write connection. The idle reaper bounds the pool instead.
    .cache_size_kb = 512,
    // THE RAM LEVER: the cache is PER CONNECTION and the pool is elastic,
    // so it is multiplied by the concurrency a burst reaches. 512 KiB (down
    // from SQLite's 2 MiB default) measured RSS 208 -> 134 MB, latency flat.
    .mmap_size_bytes = 256 * 1024 * 1024,
    .journal_size_limit_bytes = 64 * 1024 * 1024,
    .wal_autocheckpoint_pages = 1_000,
    // An idle reader above the warm floor is closed after this long: 30 s,
    // down from the package's 60 s default, so a burst's readers go sooner.
    .max_idle_time_ms = 30_000,
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

// -- CLI overrides --------------------------------------------------------- Every field of
// `best` an operator might retune, as an optional override. Null means "use `best`", so a bare
// boot is the policy above verbatim.

/// Which knob a `--db-*` flag names. One variant per flag, so a typo is a
/// named error rather than a silently ignored argument.
pub const Knob = enum {
    read_conns,
    max_read_conns,
    cache_size_kb,
    mmap_size_bytes,
    journal_size_limit_bytes,
    wal_autocheckpoint_pages,
    busy_timeout_ms,
    max_idle_time_ms,
};

/// A parsed `--db-*` override, before it is applied.
pub const Override = struct {
    knob: Knob,
    /// The raw text the user passed, kept for the error message.
    raw: []const u8,
    value: u64,
};

/// What `parseOverride` rejected.
pub const OverrideError = error{
    /// `--db-cache-size-kb` with no `=value`.
    MissingValue,
    /// The value did not parse as a non-negative integer.
    InvalidValue,
    /// The flag name is not one this build knows.
    UnknownKnob,
    OutOfMemory,
};

/// The flag name for a knob, without the leading `--`. It comes from the one
/// table, so a knob cannot exist without its flag.
pub fn flagName(knob: Knob) []const u8 {
    return switch (knob) {
        inline else => |k| cli_flags.dbFlagName(@tagName(k)),
    };
}

/// The knob a flag names, or null when the name is not one of ours. Accepts
/// both `db-read-conns` and `db_read_conns`; the dashed one is canonical.
pub fn knobForFlag(flag: []const u8) ?Knob {
    const tag = cli_flags.dbKnobTag(flag) orelse return null;
    inline for (@typeInfo(Knob).@"enum".fields) |f| {
        if (std.mem.eql(u8, f.name, tag)) return @field(Knob, f.name);
    }
    return null;
}

/// Parse one `--db-<knob>=<value>` argument. The `=` form is required (not
/// `--db-read-conns 4`) so a missing value is unambiguous: a space-separated
/// form would let `--db-read-conns --auth` eat the next flag as the value.
pub fn parseOverride(arg: []const u8) OverrideError!Override {
    const eq = std.mem.indexOfScalar(u8, arg, '=') orelse
        return error.MissingValue;
    const flag = arg[0..eq];
    const raw = arg[eq + 1 ..];
    if (raw.len == 0) return error.MissingValue;

    const knob = knobForFlag(flag) orelse return error.UnknownKnob;
    const value = std.fmt.parseInt(u64, raw, 10) catch
        return error.InvalidValue;
    return .{ .knob = knob, .raw = raw, .value = value };
}

/// Collect every `--db-*` override out of `args` (argv WITHOUT argv[0]).
/// Unknown arguments are ignored, matching how `cli_args.parse` treats
/// anything it does not recognise - a `--db-*` flag is only special here.
pub fn parseOverrides(
    allocator: std.mem.Allocator,
    args: []const []const u8,
    out: *std.ArrayList(Override),
) OverrideError!void {
    out.clearRetainingCapacity();
    for (args) |arg| {
        if (!std.mem.startsWith(u8, arg, "--db-") and
            !std.mem.startsWith(u8, arg, "--db_")) continue;
        const parsed = try parseOverride(arg);
        try out.append(allocator, parsed);
    }
}

/// Apply `overrides` on top of `best`, returning the policy to open with.
/// Later flags win, so `--db-read-conns=1 --db-read-conns=4` opens 4 - the
/// same last-one-wins rule `cli_args.parse` uses for `--port`.
pub fn resolve(overrides: []const Override) databases.database.SqliteConfig {
    var cfg = best;
    for (overrides) |o| {
        switch (o.knob) {
            .read_conns => cfg.read_conns = @intCast(o.value),
            // A cap at or below the warm floor is clamped UP to the floor by
            // the pool (`ReaderPool.effectiveCap`), so passing 0 here means
            // "no policy cap" and passing 1 with `read_conns = 4` yields 4.
            .max_read_conns => cfg.max_read_conns = @intCast(o.value),
            .cache_size_kb => cfg.cache_size_kb = @intCast(@min(o.value, std.math.maxInt(u32))),
            .mmap_size_bytes => cfg.mmap_size_bytes = o.value,
            .journal_size_limit_bytes => cfg.journal_size_limit_bytes = @bitCast(o.value),
            .wal_autocheckpoint_pages => cfg.wal_autocheckpoint_pages = @intCast(@min(o.value, std.math.maxInt(u32))),
            .busy_timeout_ms => cfg.busy_timeout_ms = @intCast(@min(o.value, std.math.maxInt(u32))),
            .max_idle_time_ms => cfg.max_idle_time_ms = o.value,
        }
    }
    return cfg;
}

/// The postgres connection policy pabrik opens its database with: a pool sized
/// for a desktop workload, under a server-side cap that a refused connection can
/// recover from. Empty on a sqlite-only build, where the module is not compiled.
pub const postgres_best: databases.database.PostgresConfig = if (databases.database.backend_is_postgres) .{
    .conns = 7,
    .max_conns = 32,
    .conn_wait_ms = 5_000,
    .max_idle_time_ms = 60_000,
} else .{};

/// Both backends' policies at once, so an open call site stays identical whichever
/// `-Ddb_used` list the app was built with. The `--db-*` knobs tune the sqlite half.
pub fn resolveConfig(overrides: []const Override) databases.database.Config {
    return .{ .sqlite = resolve(overrides), .postgres = postgres_best };
}

/// The user-facing message for an `OverrideError`, naming the offending flag.
pub fn reportOverrideError(arg: []const u8, err: OverrideError) void {
    switch (err) {
        error.MissingValue => std.log.err(
            "Error: {s} requires a value (e.g. {s}=512)",
            .{ arg, arg },
        ),
        error.InvalidValue => std.log.err(
            "Error: {s}: value is not a non-negative integer",
            .{arg},
        ),
        error.UnknownKnob => std.log.err(
            "Error: unknown database flag {s}",
            .{arg},
        ),
        error.OutOfMemory => std.log.err("Error: out of memory parsing {s}", .{arg}),
    }
}

/// Read one single-column pragma back from a live connection.
fn readPragmaInt(db: *databases.database.Db, allocator: std.mem.Allocator, sql: []const u8) !i64 {
    var row = try db.queryRow(allocator, sql, &.{});
    defer row.deinit(allocator);
    if (row.values.len == 0) return error.NoValue;
    return std.fmt.parseInt(i64, row.values[0], 10);
}

/// A fresh database path inside a per-test temp directory. WHY NOT `/tmp/...`: that directory does not exist on Windows, so `sqlite3_open` fails with
/// `FileNotFound` and every test in this file goes red on the Windows runner while passing on Linux and macOS. `testing.tmpDir` is the portable equivalent
/// and cleans itself up. The caller owns the returned slice and must free it; `dir` must outlive the database, so keep it alive until after `db.deinit()`.
fn freshDbPath(dir: *std.testing.TmpDir, name: []const u8) ![:0]const u8 {
    var dir_buf: [std.fs.max_path_bytes]u8 = undefined;
    const dir_len = try dir.dir.realPath(std.testing.io, &dir_buf);
    const joined = try std.fs.path.join(std.testing.allocator, &.{ dir_buf[0..dir_len], name });
    defer std.testing.allocator.free(joined);
    return std.testing.allocator.dupeZ(u8, joined);
}

test "the policy pabrik opens with is the policy the connection reports" {
    // A postgres build cannot open a sqlite path at all, and these tests
    // assert sqlite pragmas: there is nothing to check on this backend.
    if (databases.database.backend_is_postgres) return error.SkipZigTest;
    // The point of this file is that these values are APPLIED, not just
    // declared - a struct that compiles proves nothing about the pragmas.
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const path = try freshDbPath(&tmp, "config.db");
    defer allocator.free(path);

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
    try std.testing.expectEqual(@as(i64, -512), try readPragmaInt(&db, allocator, "PRAGMA cache_size"));
    try std.testing.expectEqual(@as(i64, 64 * 1024 * 1024), try readPragmaInt(&db, allocator, "PRAGMA journal_size_limit"));
    try std.testing.expectEqual(@as(i64, 1_000), try readPragmaInt(&db, allocator, "PRAGMA wal_autocheckpoint"));
    // mmap_size may be clamped by the build/host, so assert "on", not a value.
    try std.testing.expect(try readPragmaInt(&db, allocator, "PRAGMA mmap_size") > 0);
}

test "a pooled connection still reads and writes correctly" {
    // A postgres build cannot open a sqlite path at all, and these tests
    // assert sqlite pragmas: there is nothing to check on this backend.
    if (databases.database.backend_is_postgres) return error.SkipZigTest;
    // Reader pooling must be invisible: a write on the primary connection
    // has to be visible to the next read, which lands on a reader.
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const path = try freshDbPath(&tmp, "pool.db");
    defer allocator.free(path);

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
    // A postgres build cannot open a sqlite path at all, and these tests
    // assert sqlite pragmas: there is nothing to check on this backend.
    if (databases.database.backend_is_postgres) return error.SkipZigTest;
    // The regression this file could not see: with reader pooling, a
    // connection handed out while a `Rows` from it is still open serves the
    // OLD snapshot, because the live iterator holds that connection's read
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const path = try freshDbPath(&tmp, "visibility.db");
    defer allocator.free(path);

    var db: databases.database.Db = .{};
    defer db.deinit();
    try databases.database.openWithConfig(&db, io, .{ .sqlite_path = path }, best);

    try db.exec(allocator, "CREATE TABLE t (id INTEGER PRIMARY KEY, v TEXT NOT NULL)", &.{});
    try db.exec(allocator, "INSERT INTO t (id, v) VALUES (1, 'v0')", &.{});

    const sql = "SELECT v FROM t WHERE id = ?";
    // Round i asserts: the pre-write read sees the value round i-1 wrote, and the post-write read sees round i's
    // own value. Both reads are served by whatever reader the pool hands back. `prev_buf[0..prev_len]` is exactly
    // the previous value's length - a fixed 16-byte buffer would compare the padding too.
    var prev_buf: [16]u8 = undefined;
    var prev_len: usize = 2;
    @memcpy(prev_buf[0..2], "v0");
    var want_buf: [16]u8 = undefined;
    var i: usize = 0;
    while (i < 25) : (i += 1) {
        const want = try std.fmt.bufPrint(&want_buf, "v{d}", .{i});

        {
            var rows = try db.query(allocator, sql, &.{"1"});
            defer rows.deinit();
            const row = (try rows.next()) orelse return error.NoRow;
            defer row.deinit(allocator);
            try std.testing.expectEqualStrings(prev_buf[0..prev_len], row.values[0]);
        }

        try db.exec(allocator, "UPDATE t SET v = ? WHERE id = ?", &.{ want, "1" });

        var rows = try db.query(allocator, sql, &.{"1"});
        defer rows.deinit();
        const row = (try rows.next()) orelse return error.NoRow;
        defer row.deinit(allocator);
        try std.testing.expectEqualStrings(want, row.values[0]);

        @memcpy(prev_buf[0..want.len], want);
        prev_len = want.len;
    }
}

test "page cache cost per concurrent read is known and bounded" {
    // The cache is PER CONNECTION, so the number that matters is the product The cache is PER CONNECTION, so the number that matters is
    // the product - and with an ELASTIC pool the connection count is the concurrency, not a constant in this file. At the 24 readers a
    // 32-way burst was measured to open, the pool must stay inside a budget an operator calls "small".
    try std.testing.expectEqual(@as(u32, 512), best.cache_size_kb);
    try std.testing.expectEqual(@as(u32, 512), pageCacheBudgetKb(0));
    try std.testing.expect(pageCacheBudgetKb(24) <= 32 * 1024);

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
    // The warning this answers - warning: sqlite: reader pool unavailable
    // (PoolExhausted); serving this read on the write connection - says
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

// -- Override behaviour ----------------------------------------------------

test "no overrides leaves the policy exactly as declared" {
    // A bare `pabrik` boot must be the policy above, not a near-miss of it.
    const cfg = resolve(&.{});
    try std.testing.expectEqual(best.read_conns, cfg.read_conns);
    try std.testing.expectEqual(best.max_read_conns, cfg.max_read_conns);
    try std.testing.expectEqual(best.cache_size_kb, cfg.cache_size_kb);
    try std.testing.expectEqual(best.mmap_size_bytes, cfg.mmap_size_bytes);
    try std.testing.expectEqual(best.max_idle_time_ms, cfg.max_idle_time_ms);
}

test "an override changes only the knob it names" {
    // The failure this pins: a parser that reset the whole struct to
    // defaults and then applied one field would silently drop the others.
    const cfg = resolve(&.{.{ .knob = .cache_size_kb, .raw = "4096", .value = 4096 }});
    try std.testing.expectEqual(@as(u32, 4096), cfg.cache_size_kb);
    try std.testing.expectEqual(best.read_conns, cfg.read_conns);
    try std.testing.expectEqual(best.max_read_conns, cfg.max_read_conns);
    try std.testing.expectEqual(best.synchronous, cfg.synchronous);
    try std.testing.expectEqual(best.busy_timeout_ms, cfg.busy_timeout_ms);
}

test "the last override for a knob wins" {
    const cfg = resolve(&.{
        .{ .knob = .read_conns, .raw = "1", .value = 1 },
        .{ .knob = .read_conns, .raw = "4", .value = 4 },
    });
    try std.testing.expectEqual(@as(usize, 4), cfg.read_conns);
}

test "every knob round-trips through its flag name" {
    // A knob whose flag name does not parse back is a flag the user cannot
    // reach, which is the whole point of the feature.
    inline for (@typeInfo(Knob).@"enum".fields) |f| {
        const knob: Knob = @field(Knob, f.name);
        var buf: [80]u8 = undefined;
        const arg = try std.fmt.bufPrint(&buf, "--{s}=7", .{flagName(knob)});
        const parsed = try parseOverride(arg);
        try std.testing.expectEqual(knob, parsed.knob);
        try std.testing.expectEqual(@as(u64, 7), parsed.value);
    }
}

test "an override is rejected when it has no value or a non-numeric one" {
    try std.testing.expectError(error.MissingValue, parseOverride("--db-read-conns"));
    try std.testing.expectError(error.MissingValue, parseOverride("--db-read-conns="));
    try std.testing.expectError(error.InvalidValue, parseOverride("--db-read-conns=many"));
    try std.testing.expectError(error.InvalidValue, parseOverride("--db-read-conns=-1"));
    try std.testing.expectError(error.UnknownKnob, parseOverride("db-nope=1"));
}

test "the underscore spelling of a flag names the same knob" {
    // Operators type both; only one may be canonical or the help text lies.
    const dashed = try parseOverride("--db-cache-size-kb=256");
    const underscored = try parseOverride("--db_cache_size_kb=256");
    try std.testing.expectEqual(dashed.knob, underscored.knob);
    try std.testing.expectEqual(@as(u64, 256), underscored.value);
}

test "parseOverrides collects db flags and ignores everything else" {
    var list: std.ArrayList(Override) = .empty;
    defer list.deinit(std.testing.allocator);
    const argv = [_][]const u8{
        "--port",                  "8080",
        "--db-read-conns=4",       "--auth",
        "--db-cache-size-kb=1024", "stray",
    };
    try parseOverrides(std.testing.allocator, &argv, &list);
    try std.testing.expectEqual(@as(usize, 2), list.items.len);
    try std.testing.expectEqual(Knob.read_conns, list.items[0].knob);
    try std.testing.expectEqual(Knob.cache_size_kb, list.items[1].knob);

    const cfg = resolve(list.items);
    try std.testing.expectEqual(@as(usize, 4), cfg.read_conns);
    try std.testing.expectEqual(@as(u32, 1024), cfg.cache_size_kb);
}

test "an override is applied to a live connection, not just to the struct" {
    // A postgres build cannot open a sqlite path at all, and these tests
    // assert sqlite pragmas: there is nothing to check on this backend.
    if (databases.database.backend_is_postgres) return error.SkipZigTest;
    // The struct is only a promise; this is the one that proves the pragma
    // the server will actually run with is the one the flag asked for.
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const path = try freshDbPath(&tmp, "override.db");
    defer allocator.free(path);

    const cfg = resolve(&.{.{ .knob = .cache_size_kb, .raw = "128", .value = 128 }});
    var db: databases.database.Db = .{};
    defer db.deinit();
    try databases.database.openWithConfig(&db, io, .{ .sqlite_path = path }, cfg);

    try std.testing.expectEqual(@as(i64, -128), try readPragmaInt(&db, allocator, "PRAGMA cache_size"));
}
