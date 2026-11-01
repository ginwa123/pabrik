const std = @import("std");
const test_db = @import("../testing/test_db.zig");
const common = @import("common.zig");

const Backend = common.Backend;
const dialect = common.dialect;
const addColumnIfMissing = common.addColumnIfMissing;

/// `DEFAULT ''` is the contract: the empty sentinel means "backend cascade", so
/// every pre-existing row keeps the agent it already ran under.
pub const Migration124AddRoutineSelectedProfileModel = struct {
    pub const version: u32 = 124;
    pub const name = "add_routine_selected_profile_model";

    pub fn up(db: *Backend, allocator: std.mem.Allocator) anyerror!void {
        try addColumnIfMissing(
            .{ .db = db },
            allocator,
            "workspace_routines",
            "selected_profile_model",
            "selected_profile_model TEXT NOT NULL DEFAULT ''",
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

fn profileModelOf(alloc: std.mem.Allocator, db: *Backend, id: []const u8) ![]u8 {
    var row = try db.queryRow(
        alloc,
        "SELECT selected_profile_model FROM workspace_routines WHERE id = ?",
        &[_][]const u8{id},
    );
    defer row.deinit(alloc);
    return try alloc.dupe(u8, row.values[0]);
}

test "Migration124 leaves a routine that never chose a model on the backend cascade" {
    const alloc = testing.allocator;
    var ctx = try openDb(alloc);
    defer ctx.db.deinit();
    defer ctx.threaded.deinit();
    const db = &ctx.db;

    try db.exec(alloc,
        "INSERT INTO workspace_routines (id, workspace_item_id) VALUES ('r_old', 'r_old')",
        &[_][]const u8{},
    );

    try Migration124AddRoutineSelectedProfileModel.up(db, alloc);

    const model = try profileModelOf(alloc, db, "r_old");
    defer alloc.free(model);
    try testing.expectEqualStrings("", model);
}

test "Migration124 keeps the model an already-migrated routine chose" {
    const alloc = testing.allocator;
    var ctx = try openDb(alloc);
    defer ctx.db.deinit();
    defer ctx.threaded.deinit();
    const db = &ctx.db;

    try Migration124AddRoutineSelectedProfileModel.up(db, alloc);
    try db.exec(alloc,
        "INSERT INTO workspace_routines (id, workspace_item_id, selected_profile_model) " ++
            "VALUES ('r_new', 'r_new', '900ribu')",
        &[_][]const u8{},
    );

    const model = try profileModelOf(alloc, db, "r_new");
    defer alloc.free(model);
    try testing.expectEqualStrings("900ribu", model);
}

test "Migration124 replaying is a no-op" {
    const alloc = testing.allocator;
    var ctx = try openDb(alloc);
    defer ctx.db.deinit();
    defer ctx.threaded.deinit();
    const db = &ctx.db;

    try Migration124AddRoutineSelectedProfileModel.up(db, alloc);
    try Migration124AddRoutineSelectedProfileModel.up(db, alloc);

    var row = try db.queryRow(
        alloc,
        "SELECT COUNT(*) FROM " ++ comptime dialect.tableColumns("workspace_routines") ++
            " WHERE name = 'selected_profile_model'",
        &[_][]const u8{},
    );
    defer row.deinit(alloc);
    try testing.expectEqualStrings("1", row.values[0]);
}

test "Migration124 is registered in allMigrations" {
    for (@import("migration.zig").allMigrations) |m| {
        if (m.version == Migration124AddRoutineSelectedProfileModel.version) return;
    }
    return error.Migration124NotRegistered;
}
