const std = @import("std");
const test_db = @import("../testing/test_db.zig");
const common = @import("common.zig");

const Backend = common.Backend;
const addColumnIfMissing = common.addColumnIfMissing;
const helpers = @import("helpers");
const dialect = common.dialect;

/// Migration 142 — a session can hold a roster of agents instead of one.
/// `group_lead` marks a group, `session_group_members` is its roster, and
/// `target_agent` lets an interrupt name one member.
pub const Migration142AddSessionGroup = struct {
    pub const version: u32 = 142;
    pub const name = "add_session_group";

    const table = "session_group_members";

    pub fn up(db: *Backend, allocator: std.mem.Allocator) anyerror!void {
        try db.exec(allocator,
            \\CREATE TABLE IF NOT EXISTS session_group_members (
            \\    session_id TEXT NOT NULL,
            \\    agent_name TEXT NOT NULL,
            \\    role TEXT NOT NULL DEFAULT 'worker',
            \\    position INTEGER NOT NULL DEFAULT 0,
            \\    created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
        ++ comptime dialect.foreignKey("FOREIGN KEY (session_id) REFERENCES sessions(id) ON DELETE CASCADE") ++
            \\    ,
            \\    PRIMARY KEY (session_id, agent_name)
            \\)
        , &[_][]const u8{});

        try db.exec(allocator, "CREATE INDEX IF NOT EXISTS idx_session_group_members_session " ++
            "ON session_group_members(session_id, position)", &[_][]const u8{});

        try addColumnIfMissing(
            .{ .db = db },
            allocator,
            "sessions",
            "group_lead",
            "group_lead TEXT",
        );

        try addColumnIfMissing(
            .{ .db = db },
            allocator,
            "session_queue_messages",
            "target_agent",
            "target_agent TEXT",
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
    try db.exec(alloc, "CREATE TABLE session_queue_messages (id TEXT PRIMARY KEY, session_id TEXT NOT NULL)", &[_][]const u8{});
    return .{ .db = db, .threaded = threaded };
}

fn columnNames(ctx: *TestCtx, comptime table_name: []const u8) ![]const []const u8 {
    const alloc = testing.allocator;
    var q = try ctx.db.query(alloc, "SELECT name FROM " ++ comptime dialect.tableColumns(table_name), &[_][]const u8{});
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

fn countRows(ctx: *TestCtx, sql: []const u8) !i64 {
    var row = try ctx.db.queryRow(testing.allocator, sql, &[_][]const u8{});
    defer row.deinit(testing.allocator);
    return std.fmt.parseInt(i64, row.values[0], 10);
}

test "Migration142 gives a session a group lead column" {
    var ctx = try setupDb();
    defer ctx.db.deinit();
    defer ctx.threaded.deinit();

    try Migration142AddSessionGroup.up(&ctx.db, testing.allocator);

    const names = try columnNames(&ctx, "sessions");
    defer freeColumnNames(names);
    try testing.expect(hasColumn(names, "group_lead"));
}

test "Migration142 gives a queued message a target agent column" {
    var ctx = try setupDb();
    defer ctx.db.deinit();
    defer ctx.threaded.deinit();

    try Migration142AddSessionGroup.up(&ctx.db, testing.allocator);

    const names = try columnNames(&ctx, "session_queue_messages");
    defer freeColumnNames(names);
    try testing.expect(hasColumn(names, "target_agent"));
}

test "Migration142 creates a roster that keeps one row per agent per session" {
    var ctx = try setupDb();
    defer ctx.db.deinit();
    defer ctx.threaded.deinit();

    try ctx.db.exec(testing.allocator, "INSERT INTO sessions (id) VALUES ('s_1')", &[_][]const u8{});
    try Migration142AddSessionGroup.up(&ctx.db, testing.allocator);

    try ctx.db.exec(testing.allocator,
        \\INSERT INTO session_group_members (session_id, agent_name, role, position)
        \\VALUES ('s_1', 'Engineer', 'lead', 0)
    , &[_][]const u8{});

    const duplicate = ctx.db.exec(testing.allocator,
        \\INSERT INTO session_group_members (session_id, agent_name, role, position)
        \\VALUES ('s_1', 'Engineer', 'worker', 1)
    , &[_][]const u8{});
    if (duplicate) |_| return error.SecondRowAccepted else |_| {}
    try testing.expectEqual(@as(i64, 1), try countRows(&ctx, "SELECT COUNT(*) FROM session_group_members"));
}

test "Migration142 holds one roster per session" {
    var ctx = try setupDb();
    defer ctx.db.deinit();
    defer ctx.threaded.deinit();

    try ctx.db.exec(testing.allocator, "INSERT INTO sessions (id) VALUES ('s_1'), ('s_2')", &[_][]const u8{});
    try Migration142AddSessionGroup.up(&ctx.db, testing.allocator);

    try ctx.db.exec(testing.allocator,
        \\INSERT INTO session_group_members (session_id, agent_name, role, position)
        \\VALUES ('s_1', 'Engineer', 'lead', 0),
        \\       ('s_1', 'Android Engineer', 'worker', 1),
        \\       ('s_2', 'Engineer', 'lead', 0)
    , &[_][]const u8{});

    try testing.expectEqual(
        @as(i64, 2),
        try countRows(&ctx, "SELECT COUNT(*) FROM session_group_members WHERE session_id = 's_1'"),
    );
    try testing.expectEqual(
        @as(i64, 1),
        try countRows(&ctx, "SELECT COUNT(*) FROM session_group_members WHERE session_id = 's_2'"),
    );
}

test "Migration142 replaying is a no-op" {
    var ctx = try setupDb();
    defer ctx.db.deinit();
    defer ctx.threaded.deinit();

    try ctx.db.exec(testing.allocator, "INSERT INTO sessions (id) VALUES ('s_1')", &[_][]const u8{});
    try Migration142AddSessionGroup.up(&ctx.db, testing.allocator);
    try ctx.db.exec(testing.allocator,
        \\INSERT INTO session_group_members (session_id, agent_name, role, position)
        \\VALUES ('s_1', 'Engineer', 'lead', 0)
    , &[_][]const u8{});
    try Migration142AddSessionGroup.up(&ctx.db, testing.allocator);

    try testing.expectEqual(@as(i64, 1), try countRows(&ctx, "SELECT COUNT(*) FROM session_group_members"));
}

test "Migration142 is registered in allMigrations" {
    for (migration.allMigrations) |m| {
        if (m.version == Migration142AddSessionGroup.version) return;
    }
    return error.Migration142NotRegistered;
}
