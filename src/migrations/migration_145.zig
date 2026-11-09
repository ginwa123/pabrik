const std = @import("std");
const test_db = @import("../testing/test_db.zig");
const common = @import("common.zig");

const Backend = common.Backend;
const addColumnIfMissing = common.addColumnIfMissing;
const dialect = common.dialect;

/// Migration 145 — a session can carry one pending delegation: the agent the
/// next turn belongs to, set by the `delegate_agent` tool.
pub const Migration145AddPendingDelegate = struct {
    pub const version: u32 = 145;
    pub const name = "add_pending_delegate";

    pub fn up(db: *Backend, allocator: std.mem.Allocator) anyerror!void {
        try addColumnIfMissing(
            .{ .db = db },
            allocator,
            "sessions",
            "pending_delegate",
            "pending_delegate TEXT",
        );
    }
};

const testing = std.testing;
const migration = @import("migration.zig");

const TestCtx = struct {
    db: Backend,
    threaded: std.Io.Threaded,
};

fn setupDb() !TestCtx {
    const alloc = testing.allocator;
    var threaded = std.Io.Threaded.init(alloc, .{});
    errdefer threaded.deinit();
    var db: Backend = .{};
    errdefer db.deinit();
    try test_db.openMemory(&db, threaded.io());
    try db.exec(alloc, "CREATE TABLE sessions (id TEXT PRIMARY KEY)", &[_][]const u8{});
    return .{ .db = db, .threaded = threaded };
}

fn columnNames(ctx: *TestCtx) ![]const []const u8 {
    const alloc = testing.allocator;
    var q = try ctx.db.query(alloc, "SELECT name FROM " ++ comptime dialect.tableColumns("sessions"), &[_][]const u8{});
    defer q.deinit();

    var out: std.ArrayList([]const u8) = .empty;
    errdefer {
        for (out.items) |c| alloc.free(c);
        out.deinit(alloc);
    }
    while (try q.next()) |row| {
        defer row.deinit(alloc);
        try out.append(alloc, try alloc.dupe(u8, row.values[0]));
    }
    return out.toOwnedSlice(alloc);
}

fn freeColumnNames(names: []const []const u8) void {
    for (names) |c| testing.allocator.free(c);
    testing.allocator.free(names);
}

fn hasColumn(names: []const []const u8, wanted: []const u8) bool {
    for (names) |c| {
        if (std.mem.eql(u8, c, wanted)) return true;
    }
    return false;
}

test "Migration145 gives a session a pending delegate column" {
    var ctx = try setupDb();
    defer ctx.db.deinit();
    defer ctx.threaded.deinit();

    try Migration145AddPendingDelegate.up(&ctx.db, testing.allocator);

    const names = try columnNames(&ctx);
    defer freeColumnNames(names);
    try testing.expect(hasColumn(names, "pending_delegate"));
}

test "Migration145 keeps the rows a session already had" {
    var ctx = try setupDb();
    defer ctx.db.deinit();
    defer ctx.threaded.deinit();

    try ctx.db.exec(testing.allocator, "INSERT INTO sessions (id) VALUES ('s_1')", &[_][]const u8{});
    try Migration145AddPendingDelegate.up(&ctx.db, testing.allocator);

    var row = try ctx.db.queryRow(testing.allocator, "SELECT id FROM sessions WHERE id = 's_1'", &[_][]const u8{});
    defer row.deinit(testing.allocator);
    try testing.expectEqualStrings("s_1", row.values[0]);
}

test "Migration145 replaying is a no-op" {
    var ctx = try setupDb();
    defer ctx.db.deinit();
    defer ctx.threaded.deinit();

    try Migration145AddPendingDelegate.up(&ctx.db, testing.allocator);
    try Migration145AddPendingDelegate.up(&ctx.db, testing.allocator);

    const names = try columnNames(&ctx);
    defer freeColumnNames(names);
    var count: usize = 0;
    for (names) |c| {
        if (std.mem.eql(u8, c, "pending_delegate")) count += 1;
    }
    try testing.expectEqual(@as(usize, 1), count);
}

test "Migration145 is registered in allMigrations" {
    for (migration.allMigrations) |m| {
        if (m.version == Migration145AddPendingDelegate.version) return;
    }
    return error.Migration145NotRegistered;
}
