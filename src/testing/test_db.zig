const std = @import("std");
const databases = @import("databases");
const helpers = @import("helpers");
const dialect = @import("pabrikcore").dialect;

pub const database = databases.database;
pub const TempDb = database.TempDb;

pub const require_env = "PABRIK_DB_TESTS_REQUIRE_SERVER";
pub const conninfo_env = "POSTGRES_TEST_CONNINFO";

pub fn available() bool {
    return database.tempDbAvailable();
}

pub fn skipUnlessAvailable() error{ SkipZigTest, NoPostgresServer }!void {
    if (available()) return;
    if (std.c.getenv(require_env) != null) return error.NoPostgresServer;
    return error.SkipZigTest;
}

pub fn create(allocator: std.mem.Allocator) !TempDb {
    try skipUnlessAvailable();
    return database.createTempDb(allocator, .{ .base_conninfo = try quietBaseConninfo() });
}

pub fn createWith(allocator: std.mem.Allocator, config: database.Config) !TempDb {
    try skipUnlessAvailable();
    return database.createTempDb(allocator, .{
        .config = config,
        .base_conninfo = try quietBaseConninfo(),
    });
}

pub fn handle(temp: *TempDb) *database.Db {
    return &temp.db;
}

/// A postgres test database is a SCHEMA, not a database: creating one per test
/// would cost a `CREATE DATABASE` (and a leftover) for every setup. One schema
/// per test process, wiped on every open, gives a `:memory:`-fresh schema.
const schema_prefix = "pabrik_test_";

var base_conninfo: ?[]const u8 = null;
var swept: bool = false;
var schema_name: ?[]const u8 = null;

fn longLived() std.mem.Allocator {
    return std.heap.page_allocator;
}

/// Postgres reports every skipped `CREATE INDEX IF NOT EXISTS` and every object
/// a `DROP SCHEMA … CASCADE` takes as a NOTICE, and Zig relays a PASSING step's
/// stderr as a block shaped exactly like a failure. It rides in the conninfo.
const quiet_option = "-cclient_min_messages=warning";

/// The temp-database path splits a conninfo on spaces, so the option has to stay
/// one token: `-csetting=value` is the form both libpq and the server accept.
fn quietBaseConninfo() !?[:0]const u8 {
    if (!database.backend_is_postgres) return null;
    const base = ensureBaseConninfo() catch return null;
    const already = std.mem.indexOf(u8, base, "options=") != null;
    const quiet: [:0]const u8 = if (already)
        try std.fmt.allocPrintSentinel(longLived(), "{s}", .{base}, 0)
    else
        try std.fmt.allocPrintSentinel(
            longLived(),
            "{s} options={s}",
            .{ std.mem.trimEnd(u8, base, " "), quiet_option },
            0,
        );
    return quiet;
}

fn pidAlive(pid: []const u8) bool {
    var buf: [64]u8 = undefined;
    const path = std.fmt.bufPrintZ(&buf, "/proc/{s}", .{pid}) catch return true;
    return std.c.access(path.ptr, 0) == 0;
}

/// The instance the scratch schemas live on. An explicit `POSTGRES_TEST_CONNINFO`
/// wins; otherwise the two ports a local server is normally on are probed, so
/// `zig build test -Ddb_used=postgres` works without exporting anything.
fn ensureBaseConninfo() ![]const u8 {
    if (base_conninfo) |base| return base;

    if (std.c.getenv(conninfo_env)) |raw| {
        const base = try longLived().dupe(u8, std.mem.span(raw));
        base_conninfo = base;
        return base;
    }

    const candidates = [_][:0]const u8{
        "host=127.0.0.1 port=5432 dbname=postgres",
        "host=127.0.0.1 port=5433 dbname=postgres",
        "host=/tmp port=54329 dbname=postgres",
    };
    for (candidates) |candidate| {
        var probe = database.createTempDb(longLived(), .{ .base_conninfo = candidate }) catch continue;
        const base = longLived().dupe(u8, candidate) catch {
            probe.deinit();
            return error.OutOfMemory;
        };
        probe.deinit();
        base_conninfo = base;
        return base;
    }
    return error.NoPostgresServer;
}

fn ensureSchemaName() ![]const u8 {
    if (schema_name) |name| return name;
    const name = try std.fmt.allocPrint(longLived(), "{s}{d}", .{ schema_prefix, helpers.process_status.getCurrentProcessIdInt() });
    schema_name = name;
    return name;
}

/// Drop the schemas a previous, now-dead test process left behind. Without
/// this the instance collects one schema per shard run, for ever.
fn dropDeadSchemas(db: *database.Db) void {
    var doomed: std.ArrayList([]u8) = .empty;
    defer {
        for (doomed.items) |name| longLived().free(name);
        doomed.deinit(longLived());
    }

    // The rows must be closed BEFORE the drops: an open iterator holds a
    // reader connection, and `exec` wants the writer.
    {
        var rows = db.query(
            longLived(),
            "SELECT schema_name FROM information_schema.schemata WHERE schema_name LIKE 'pabrik_test_%'",
            &.{},
        ) catch return;
        defer rows.deinit();

        while (rows.next() catch null) |row| {
            defer row.deinit(longLived());
            const suffix = row.values[0][schema_prefix.len..];
            if (pidAlive(suffix)) continue;
            const copy = longLived().dupe(u8, row.values[0]) catch continue;
            doomed.append(longLived(), copy) catch continue;
        }
    }

    for (doomed.items) |name| {
        var buf: [256]u8 = undefined;
        const sql = std.fmt.bufPrint(&buf, "DROP SCHEMA IF EXISTS {s} CASCADE", .{name}) catch continue;
        db.exec(longLived(), sql, &.{}) catch {};
    }
}

/// Open a database the way the compiled backend can, with a fresh schema:
/// `:memory:` on sqlite, a per-process schema on postgres. This is what the
/// test setups call instead of `db.init(io, ":memory:")`.
pub fn openMemory(db: *database.Db, io: std.Io) !void {
    if (!database.backend_is_postgres) return db.init(io, ":memory:");

    // No instance answering means there is nothing to test against: skip, the
    // same contract `create()` uses, unless CI demands a server.
    const base = ensureBaseConninfo() catch |err| {
        if (std.c.getenv(require_env) != null) return err;
        return error.SkipZigTest;
    };
    const schema = try ensureSchemaName();
    const conninfo = try std.fmt.allocPrintSentinel(
        longLived(),
        "{s} options='-csearch_path={s} {s}'",
        .{ std.mem.trimEnd(u8, base, " "), schema, quiet_option },
        0,
    );

    try db.init(io, conninfo);
    if (!swept) {
        swept = true;
        dropDeadSchemas(db);
    }

    var buf: [256]u8 = undefined;
    const drop = try std.fmt.bufPrint(&buf, "DROP SCHEMA IF EXISTS {s} CASCADE", .{schema});
    try db.exec(longLived(), drop, &.{});
    const make = try std.fmt.bufPrint(&buf, "CREATE SCHEMA {s}", .{schema});
    try db.exec(longLived(), make, &.{});

    // The sqlite spellings a setup's own DDL and the code under test use.
    for (dialect.sqlite_time_functions) |sql| try db.exec(longLived(), sql, &.{});
}

test "openMemory hands out a database the compiled backend can write to" {
    const testing = std.testing;
    var db: database.Db = .{};
    defer db.deinit();

    try openMemory(&db, testing.io);

    try db.exec(testing.allocator, "CREATE TABLE probe (v TEXT NOT NULL)", &.{});
    try db.exec(testing.allocator, "INSERT INTO probe (v) VALUES (?)", &.{"written"});

    var row = try db.queryRow(testing.allocator, "SELECT v FROM probe", &.{});
    defer row.deinit(testing.allocator);
    try testing.expectEqualStrings("written", row.values[0]);
}

test "openMemory starts every caller on an empty database" {
    const testing = std.testing;

    {
        var first: database.Db = .{};
        defer first.deinit();
        try openMemory(&first, testing.io);
        try first.exec(testing.allocator, "CREATE TABLE leftover (v TEXT NOT NULL)", &.{});
        try first.exec(testing.allocator, "INSERT INTO leftover (v) VALUES (?)", &.{"still here"});
    }

    var second: database.Db = .{};
    defer second.deinit();
    try openMemory(&second, testing.io);
    try second.exec(testing.allocator, "CREATE TABLE leftover (v TEXT NOT NULL)", &.{});

    var row = try second.queryRow(testing.allocator, "SELECT COUNT(*) FROM leftover", &.{});
    defer row.deinit(testing.allocator);
    try testing.expectEqualStrings("0", row.values[0]);
}
