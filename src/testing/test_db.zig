const std = @import("std");
const databases = @import("databases");

pub const database = databases.database;
pub const TempDb = database.TempDb;

pub const require_env = "PABRIK_DB_TESTS_REQUIRE_SERVER";

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
    return database.createTempDb(allocator, .{});
}

pub fn createWith(allocator: std.mem.Allocator, config: database.Config) !TempDb {
    try skipUnlessAvailable();
    return database.createTempDb(allocator, .{ .config = config });
}

pub fn handle(temp: *TempDb) *database.Db {
    return &temp.db;
}
