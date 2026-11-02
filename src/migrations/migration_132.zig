const std = @import("std");
const test_db = @import("../testing/test_db.zig");
const common = @import("common.zig");

const Backend = common.Backend;
const dialect = common.dialect;
const addColumnIfMissing = common.addColumnIfMissing;

/// Migration 132 — step 1 of 3 for `session_plan`: the plan moves onto its
/// session. `plan_updated_at` is nullable because sqlite refuses
/// `ADD COLUMN … DEFAULT CURRENT_TIMESTAMP`, and NULL is "never wrote a plan".
pub const Migration132ExpandSessionPlan = struct {
    pub const version: u32 = 132;
    pub const name = "expand_session_plan_onto_sessions";

    pub const plan_md_column = "plan_md";
    pub const plan_updated_at_column = "plan_updated_at";

    pub fn up(db: *Backend, allocator: std.mem.Allocator) anyerror!void {
        try addColumnIfMissing(
            .{ .db = db },
            allocator,
            "sessions",
            plan_md_column,
            "plan_md TEXT NOT NULL DEFAULT ''",
        );
        try addColumnIfMissing(
            .{ .db = db },
            allocator,
            "sessions",
            plan_updated_at_column,
            "plan_updated_at TIMESTAMP",
        );
    }
};

const testing = std.testing;

const schema = [_][]const u8{
    "CREATE TABLE sessions (id TEXT PRIMARY KEY, name TEXT NOT NULL)",
    "CREATE TABLE session_plan (session_id TEXT PRIMARY KEY, plan_md TEXT NOT NULL DEFAULT '', updated_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP)",
};

fn openDb(alloc: std.mem.Allocator) !struct { db: Backend, threaded: std.Io.Threaded } {
    var threaded = std.Io.Threaded.init(alloc, .{});
    errdefer threaded.deinit();
    var db: Backend = .{};
    errdefer db.deinit();
    try test_db.openMemory(&db, threaded.io());
    for (schema) |ddl| try db.exec(alloc, ddl, &[_][]const u8{});
    return .{ .db = db, .threaded = threaded };
}

fn columnCount(alloc: std.mem.Allocator, db: *Backend, column: []const u8) !i64 {
    var row = try db.queryRow(
        alloc,
        "SELECT COUNT(*) FROM " ++ comptime dialect.tableColumns("sessions") ++ " WHERE name = ?",
        &[_][]const u8{column},
    );
    defer row.deinit(alloc);
    return std.fmt.parseInt(i64, row.values[0], 10);
}

fn planMdOf(alloc: std.mem.Allocator, db: *Backend, session_id: []const u8) ![]u8 {
    var row = try db.queryRow(
        alloc,
        "SELECT COALESCE(CAST(plan_md AS TEXT), '') FROM sessions WHERE id = ?",
        &[_][]const u8{session_id},
    );
    defer row.deinit(alloc);
    return try alloc.dupe(u8, row.values[0]);
}

fn planUpdatedAtOf(alloc: std.mem.Allocator, db: *Backend, session_id: []const u8) ![]u8 {
    var row = try db.queryRow(
        alloc,
        "SELECT COALESCE(CAST(plan_updated_at AS TEXT), '') FROM sessions WHERE id = ?",
        &[_][]const u8{session_id},
    );
    defer row.deinit(alloc);
    return try alloc.dupe(u8, row.values[0]);
}

test "Migration132 leaves a session that never wrote a plan with no plan" {
    const alloc = testing.allocator;
    var ctx = try openDb(alloc);
    defer ctx.db.deinit();
    defer ctx.threaded.deinit();
    const db = &ctx.db;

    try db.exec(alloc, "INSERT INTO sessions (id, name) VALUES ('s_old', 'Old')", &[_][]const u8{});

    try Migration132ExpandSessionPlan.up(db, alloc);

    const plan = try planMdOf(alloc, db, "s_old");
    defer alloc.free(plan);
    try testing.expectEqualStrings("", plan);

    // The timestamp, not the empty body, is what tells a reader "no plan ever".
    const written_at = try planUpdatedAtOf(alloc, db, "s_old");
    defer alloc.free(written_at);
    try testing.expectEqualStrings("", written_at);
}

test "Migration132 replaying adds no second pair of columns" {
    const alloc = testing.allocator;
    var ctx = try openDb(alloc);
    defer ctx.db.deinit();
    defer ctx.threaded.deinit();
    const db = &ctx.db;

    try Migration132ExpandSessionPlan.up(db, alloc);
    try Migration132ExpandSessionPlan.up(db, alloc);

    try testing.expectEqual(
        @as(i64, 1),
        try columnCount(alloc, db, Migration132ExpandSessionPlan.plan_md_column),
    );
    try testing.expectEqual(
        @as(i64, 1),
        try columnCount(alloc, db, Migration132ExpandSessionPlan.plan_updated_at_column),
    );
}

test "Migration132 is registered in allMigrations" {
    for (@import("migration.zig").allMigrations) |m| {
        if (m.version == Migration132ExpandSessionPlan.version and
            std.mem.eql(u8, m.name, Migration132ExpandSessionPlan.name)) return;
    }
    return error.Migration132NotRegistered;
}
