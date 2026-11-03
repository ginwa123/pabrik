const std = @import("std");
const test_db = @import("../testing/test_db.zig");
const common = @import("common.zig");

const Backend = common.Backend;
const dialect = common.dialect;

/// Step 3 of 3 for `session_plan`: drop the legacy table. Staged, not
/// registered — it ships a release after the read switch, and refuses to drop
/// while any legacy plan is missing from its session.
pub const Migration134ContractSessionPlan = struct {
    pub const version: u32 = 134;
    pub const name = "contract_session_plan";

    pub const legacy_table = "session_plan";

    pub fn up(db: *Backend, allocator: std.mem.Allocator) anyerror!void {
        if (!try dialect.tableExists(.{ .db = db }, allocator, legacy_table)) return;

        var row = try db.queryRow(
            allocator,
            \\SELECT COUNT(*) FROM session_plan p
            \\LEFT JOIN sessions s ON s.id = p.session_id
            \\WHERE COALESCE(CAST(p.plan_md AS TEXT), '') <> ''
            \\  AND (
            \\      s.id IS NULL
            \\      OR COALESCE(CAST(s.plan_md AS TEXT), '') <> COALESCE(CAST(p.plan_md AS TEXT), '')
            \\  )
        ,
            &[_][]const u8{},
        );
        defer row.deinit(allocator);

        const unsynced = try std.fmt.parseInt(i64, row.values[0], 10);
        if (unsynced != 0) return error.SessionPlanNotBackfilled;

        try db.exec(allocator, "DROP TABLE " ++ legacy_table ++ dialect.drop_cascade, &[_][]const u8{});
    }
};

const testing = std.testing;

const schema = [_][]const u8{
    "CREATE TABLE sessions (id TEXT PRIMARY KEY, name TEXT NOT NULL, plan_md TEXT NOT NULL DEFAULT '', plan_updated_at TIMESTAMP)",
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

fn legacyTableExists(alloc: std.mem.Allocator, db: *Backend) !bool {
    return dialect.tableExists(.{ .db = db }, alloc, Migration134ContractSessionPlan.legacy_table);
}

test "Migration134 drops the legacy table once every plan sits on its session" {
    const alloc = testing.allocator;
    var ctx = try openDb(alloc);
    defer ctx.db.deinit();
    defer ctx.threaded.deinit();
    const db = &ctx.db;

    try db.exec(alloc, "INSERT INTO sessions (id, name, plan_md) VALUES ('s_1', 'S1', 'the plan')", &[_][]const u8{});
    try db.exec(alloc, "INSERT INTO session_plan (session_id, plan_md) VALUES ('s_1', 'the plan')", &[_][]const u8{});

    try Migration134ContractSessionPlan.up(db, alloc);

    try testing.expect(!try legacyTableExists(alloc, db));
}

test "Migration134 refuses to drop a plan that never reached its session" {
    const alloc = testing.allocator;
    var ctx = try openDb(alloc);
    defer ctx.db.deinit();
    defer ctx.threaded.deinit();
    const db = &ctx.db;

    try db.exec(alloc, "INSERT INTO sessions (id, name) VALUES ('s_1', 'S1')", &[_][]const u8{});
    try db.exec(alloc, "INSERT INTO session_plan (session_id, plan_md) VALUES ('s_1', 'only copy')", &[_][]const u8{});

    try testing.expectError(error.SessionPlanNotBackfilled, Migration134ContractSessionPlan.up(db, alloc));
    try testing.expect(try legacyTableExists(alloc, db));
}

test "Migration134 refuses to drop a plan whose session no longer exists" {
    const alloc = testing.allocator;
    var ctx = try openDb(alloc);
    defer ctx.db.deinit();
    defer ctx.threaded.deinit();
    const db = &ctx.db;

    try db.exec(alloc, "INSERT INTO session_plan (session_id, plan_md) VALUES ('s_deleted', 'orphan plan')", &[_][]const u8{});

    try testing.expectError(error.SessionPlanNotBackfilled, Migration134ContractSessionPlan.up(db, alloc));
    try testing.expect(try legacyTableExists(alloc, db));
}

test "Migration134 is a no-op once the legacy table is gone" {
    const alloc = testing.allocator;
    var ctx = try openDb(alloc);
    defer ctx.db.deinit();
    defer ctx.threaded.deinit();
    const db = &ctx.db;

    try db.exec(alloc, "DROP TABLE session_plan", &[_][]const u8{});

    try Migration134ContractSessionPlan.up(db, alloc);
}

test "Migration134 ships now the read switch has, and drops the legacy table" {
    var registered = false;
    for (@import("migration.zig").allMigrations) |m| {
        if (m.version == Migration134ContractSessionPlan.version) registered = true;
    }
    try testing.expect(registered);

    const alloc = testing.allocator;
    var ctx = try openDb(alloc);
    defer ctx.db.deinit();
    defer ctx.threaded.deinit();
    const db = &ctx.db;

    try db.exec(alloc, "INSERT INTO sessions (id, name, plan_md) VALUES ('s1', 'seeded', 'the plan')", &[_][]const u8{});
    try db.exec(alloc, "INSERT INTO session_plan (session_id, plan_md) VALUES ('s1', 'the plan')", &[_][]const u8{});

    try Migration134ContractSessionPlan.up(db, alloc);

    var row = try db.queryRow(alloc, "SELECT COUNT(*) FROM " ++
        comptime dialect.tables_source ++ " WHERE type = 'table' AND name = 'session_plan'", &[_][]const u8{});
    defer row.deinit(alloc);
    try testing.expectEqualStrings("0", row.values[0]);

    var plan = try db.queryRow(alloc, "SELECT COALESCE(CAST(plan_md AS TEXT), '') FROM sessions WHERE id = 's1'", &[_][]const u8{});
    defer plan.deinit(alloc);
    try testing.expectEqualStrings("the plan", plan.values[0]);
}
