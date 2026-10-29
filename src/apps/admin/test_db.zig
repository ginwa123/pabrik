//! A throwaway database for the console's tests: `:memory:` on sqlite, a temp
//! database on postgres. A postgres build without `POSTGRES_TEST_CONNINFO`
//! skips, unless `PABRIK_DB_TESTS_REQUIRE_SERVER=1` demands a failure.

const std = @import("std");
const databases = @import("databases");
const dialect = @import("dialect");

const database = databases.database;
const testing = std.testing;

pub const require_server_env = "PABRIK_DB_TESTS_REQUIRE_SERVER";

pub const Fixture = struct {
    temp: ?database.TempDb = null,
    memory: database.Db = .{},

    /// A database this test owns outright, with nothing in it.
    pub fn open(self: *Fixture) !*database.Db {
        if (comptime dialect.is_postgres) {
            if (!database.tempDbAvailable()) {
                if (std.c.getenv(require_server_env) != null) return error.NoPostgresServer;
                return error.SkipZigTest;
            }
            self.temp = try database.createTempDb(testing.allocator, .{});
            return &self.temp.?.db;
        }
        try self.memory.init(testing.io, ":memory:");
        return &self.memory;
    }

    pub fn deinit(self: *Fixture) void {
        if (self.temp) |*temp| {
            temp.deinit();
        } else {
            self.memory.deinit();
        }
    }
};

test "the fixture hands out a database the compiled backend can write to" {
    var fixture: Fixture = .{};
    defer fixture.deinit();
    const db = try fixture.open();

    try db.exec(testing.allocator, "CREATE TABLE probe (v TEXT NOT NULL)", &.{});
    try db.exec(testing.allocator, "INSERT INTO probe (v) VALUES (?)", &.{"written"});

    var row = try db.queryRow(testing.allocator, "SELECT v FROM probe", &.{});
    defer row.deinit(testing.allocator);
    try testing.expectEqualStrings("written", row.values[0]);
}
