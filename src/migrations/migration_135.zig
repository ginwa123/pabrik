const std = @import("std");
const test_db = @import("../testing/test_db.zig");
const common = @import("common.zig");

const Backend = common.Backend;
const dialect = common.dialect;

/// Migration 135 — drop the two RBAC tables nothing ever wrote. Migration 077
/// created `user_companies` + `user_company_members` for an org/tenant model
/// that was built but never adopted: zero rows, zero application call sites.
pub const Migration135DropUnusedRbacTables = struct {
    pub const version: u32 = 135;
    pub const name = "drop_unused_rbac_tables";

    /// Child before parent, so postgres never sees a table that another one
    /// still references.
    pub const dropped_tables = [_][]const u8{ "user_company_members", "user_companies" };

    pub fn up(db: *Backend, allocator: std.mem.Allocator) anyerror!void {
        for (dropped_tables) |table| {
            if (!try dialect.tableExists(.{ .db = db }, allocator, table)) continue;
            var ddl_buf: [128]u8 = undefined;
            const ddl = try std.fmt.bufPrint(&ddl_buf, "DROP TABLE {s}{s}", .{ table, dialect.drop_cascade });
            try db.exec(allocator, ddl, &[_][]const u8{});
        }
    }
};

const testing = std.testing;

const rbac_schema = [_][]const u8{
    "CREATE TABLE users (id TEXT PRIMARY KEY, email TEXT NOT NULL)",
    "CREATE TABLE workspaces (id TEXT PRIMARY KEY, name TEXT NOT NULL)",
    \\CREATE TABLE user_companies (
    \\    id TEXT PRIMARY KEY,
    \\    name TEXT NOT NULL,
    \\    slug TEXT NOT NULL UNIQUE,
    \\    is_active INTEGER NOT NULL DEFAULT 1
    \\)
    ,
    \\CREATE TABLE user_company_members (
    \\    user_id TEXT NOT NULL,
    \\    user_company_id TEXT NOT NULL,
    \\    role TEXT NOT NULL DEFAULT 'member',
    \\    PRIMARY KEY (user_id, user_company_id)
    \\)
    ,
    "CREATE INDEX idx_user_companies_slug ON user_companies(slug)",
    "CREATE INDEX idx_user_company_members_user ON user_company_members(user_id)",
};

const TestCtx = struct { db: Backend, threaded: std.Io.Threaded };

fn openDb(alloc: std.mem.Allocator) !TestCtx {
    var threaded = std.Io.Threaded.init(alloc, .{});
    errdefer threaded.deinit();
    var db: Backend = .{};
    errdefer db.deinit();
    try test_db.openMemory(&db, threaded.io());
    return .{ .db = db, .threaded = threaded };
}

fn openRbacDb(alloc: std.mem.Allocator) !TestCtx {
    var ctx = try openDb(alloc);
    errdefer ctx.db.deinit();
    errdefer ctx.threaded.deinit();
    for (rbac_schema) |ddl| try ctx.db.exec(alloc, ddl, &[_][]const u8{});
    return ctx;
}

fn exists(alloc: std.mem.Allocator, db: *Backend, table: []const u8) !bool {
    return dialect.tableExists(.{ .db = db }, alloc, table);
}

test "Migration135 drops both RBAC tables" {
    const alloc = testing.allocator;
    var ctx = try openRbacDb(alloc);
    defer ctx.db.deinit();
    defer ctx.threaded.deinit();
    const db = &ctx.db;

    try Migration135DropUnusedRbacTables.up(db, alloc);

    for (Migration135DropUnusedRbacTables.dropped_tables) |table| {
        try testing.expect(!try exists(alloc, db, table));
    }
}

test "Migration135 keeps the tables the RBAC model was attached to" {
    const alloc = testing.allocator;
    var ctx = try openRbacDb(alloc);
    defer ctx.db.deinit();
    defer ctx.threaded.deinit();
    const db = &ctx.db;

    try db.exec(alloc, "INSERT INTO users (id, email) VALUES ('u_1', 'u@x')", &[_][]const u8{});
    try db.exec(alloc, "INSERT INTO workspaces (id, name) VALUES ('ws_1', 'W')", &[_][]const u8{});

    try Migration135DropUnusedRbacTables.up(db, alloc);

    try testing.expect(try exists(alloc, db, "users"));
    try testing.expect(try exists(alloc, db, "workspaces"));

    var row = try db.queryRow(alloc, "SELECT COUNT(*) FROM users", &[_][]const u8{});
    defer row.deinit(alloc);
    try testing.expectEqualStrings("1", row.values[0]);
}

test "Migration135 drops the indexes that belonged to the dropped tables" {
    const alloc = testing.allocator;
    var ctx = try openRbacDb(alloc);
    defer ctx.db.deinit();
    defer ctx.threaded.deinit();
    const db = &ctx.db;

    try Migration135DropUnusedRbacTables.up(db, alloc);

    var row = try db.queryRow(
        alloc,
        "SELECT COUNT(*) FROM " ++ comptime dialect.indexes_source ++
            " WHERE type = 'index' AND name IN ('idx_user_companies_slug', 'idx_user_company_members_user')",
        &[_][]const u8{},
    );
    defer row.deinit(alloc);
    try testing.expectEqualStrings("0", row.values[0]);
}

test "Migration135 is a no-op on a database that never had the RBAC tables" {
    const alloc = testing.allocator;
    var ctx = try openDb(alloc);
    defer ctx.db.deinit();
    defer ctx.threaded.deinit();
    const db = &ctx.db;

    try db.exec(alloc, "CREATE TABLE users (id TEXT PRIMARY KEY, email TEXT NOT NULL)", &[_][]const u8{});

    try Migration135DropUnusedRbacTables.up(db, alloc);
    try Migration135DropUnusedRbacTables.up(db, alloc);

    try testing.expect(try exists(alloc, db, "users"));
}

test "Migration135 is registered in allMigrations" {
    for (@import("migration.zig").allMigrations) |m| {
        if (m.version == Migration135DropUnusedRbacTables.version and
            std.mem.eql(u8, m.name, Migration135DropUnusedRbacTables.name)) return;
    }
    return error.Migration135NotRegistered;
}
