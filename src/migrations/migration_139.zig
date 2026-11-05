const std = @import("std");
const test_db = @import("../testing/test_db.zig");
const common = @import("common.zig");

const Backend = common.Backend;
const dialect = common.dialect;
const addColumnIfMissing = common.addColumnIfMissing;

pub const Migration139AddRoutineCwd = struct {
    pub const version: u32 = 139;
    pub const name = "add_routine_cwd";

    pub fn up(db: *Backend, allocator: std.mem.Allocator) anyerror!void {
        try addColumnIfMissing(
            .{ .db = db },
            allocator,
            "workspace_routines",
            "cwd",
            "cwd TEXT NOT NULL DEFAULT ''",
        );
    }
};

const testing = std.testing;

fn openDb(alloc: std.mem.Allocator) !struct { db: Backend, threaded: std.Io.Threaded } {
    var threaded = std.Io.Threaded.init(alloc, .{});
    errdefer threaded.deinit();
    var db: Backend = .{};
    errdefer db.deinit();
    try test_db.openMemory(&db, threaded.io());
    try db.exec(alloc,
        \\CREATE TABLE workspace_routines (
        \\  id TEXT PRIMARY KEY,
        \\  workspace_item_id TEXT NOT NULL UNIQUE,
        \\  instruction TEXT NOT NULL DEFAULT '',
        \\  enabled INTEGER NOT NULL DEFAULT 1
        \\)
    , &[_][]const u8{});
    return .{ .db = db, .threaded = threaded };
}

fn cwdOf(alloc: std.mem.Allocator, db: *Backend, id: []const u8) ![]u8 {
    var row = try db.queryRow(
        alloc,
        "SELECT cwd FROM workspace_routines WHERE id = ?",
        &[_][]const u8{id},
    );
    defer row.deinit(alloc);
    return try alloc.dupe(u8, row.values[0]);
}

test "Migration139 leaves a routine that never chose a cwd on the item path fallback" {
    const alloc = testing.allocator;
    var ctx = try openDb(alloc);
    defer ctx.db.deinit();
    defer ctx.threaded.deinit();
    const db = &ctx.db;

    try db.exec(
        alloc,
        "INSERT INTO workspace_routines (id, workspace_item_id) VALUES ('r_old', 'r_old')",
        &[_][]const u8{},
    );

    try Migration139AddRoutineCwd.up(db, alloc);

    const cwd = try cwdOf(alloc, db, "r_old");
    defer alloc.free(cwd);
    try testing.expectEqualStrings("", cwd);
}

test "Migration139 keeps the cwd an already-migrated routine chose" {
    const alloc = testing.allocator;
    var ctx = try openDb(alloc);
    defer ctx.db.deinit();
    defer ctx.threaded.deinit();
    const db = &ctx.db;

    try Migration139AddRoutineCwd.up(db, alloc);
    try db.exec(
        alloc,
        "INSERT INTO workspace_routines (id, workspace_item_id, cwd) " ++
            "VALUES ('r_new', 'r_new', '/proj/other')",
        &[_][]const u8{},
    );

    const cwd = try cwdOf(alloc, db, "r_new");
    defer alloc.free(cwd);
    try testing.expectEqualStrings("/proj/other", cwd);
}

test "Migration139 replaying is a no-op" {
    const alloc = testing.allocator;
    var ctx = try openDb(alloc);
    defer ctx.db.deinit();
    defer ctx.threaded.deinit();
    const db = &ctx.db;

    try Migration139AddRoutineCwd.up(db, alloc);
    try Migration139AddRoutineCwd.up(db, alloc);

    var row = try db.queryRow(
        alloc,
        "SELECT COUNT(*) FROM " ++ comptime dialect.tableColumns("workspace_routines") ++
            " WHERE name = 'cwd'",
        &[_][]const u8{},
    );
    defer row.deinit(alloc);
    try testing.expectEqualStrings("1", row.values[0]);
}

test "Migration139 is registered in allMigrations" {
    for (@import("migration.zig").allMigrations) |m| {
        if (m.version == Migration139AddRoutineCwd.version) return;
    }
    return error.Migration139NotRegistered;
}
