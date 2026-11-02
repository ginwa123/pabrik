const std = @import("std");
const test_db = @import("../testing/test_db.zig");
const common = @import("common.zig");

const Backend = common.Backend;
const dialect = common.dialect;

/// Migration 133 — step 2 of 3 for `session_plan`: every plan the legacy table
/// holds is copied onto its session. The `<> ''` guard is the whole safety
/// property — an empty legacy row can never blank a plan the parent already
/// carries.
pub const Migration133BackfillSessionPlan = struct {
    pub const version: u32 = 133;
    pub const name = "backfill_session_plan_onto_sessions";

    pub const legacy_table = "session_plan";

    pub fn up(db: *Backend, allocator: std.mem.Allocator) anyerror!void {
        if (!try dialect.tableExists(.{ .db = db }, allocator, legacy_table)) return;

        try db.exec(allocator,
            \\UPDATE sessions SET
            \\    plan_md = (
            \\        SELECT COALESCE(CAST(p.plan_md AS TEXT), '')
            \\        FROM session_plan p WHERE p.session_id = sessions.id
            \\    ),
            \\    plan_updated_at = (
            \\        SELECT p.updated_at
            \\        FROM session_plan p WHERE p.session_id = sessions.id
            \\    )
            \\WHERE EXISTS (
            \\    SELECT 1 FROM session_plan p
            \\    WHERE p.session_id = sessions.id
            \\      AND COALESCE(CAST(p.plan_md AS TEXT), '') <> ''
            \\)
        , &[_][]const u8{});
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

test "Migration133 copies each session's legacy plan onto its row" {
    const alloc = testing.allocator;
    var ctx = try openDb(alloc);
    defer ctx.db.deinit();
    defer ctx.threaded.deinit();
    const db = &ctx.db;

    try db.exec(alloc, "INSERT INTO sessions (id, name) VALUES ('s_1', 'S1')", &[_][]const u8{});
    try db.exec(
        alloc,
        "INSERT INTO session_plan (session_id, plan_md, updated_at) VALUES ('s_1', '# Plan\n- [ ] step', '2026-10-01 08:00:00')",
        &[_][]const u8{},
    );

    try Migration133BackfillSessionPlan.up(db, alloc);

    const plan = try planMdOf(alloc, db, "s_1");
    defer alloc.free(plan);
    try testing.expectEqualStrings("# Plan\n- [ ] step", plan);

    const written_at = try planUpdatedAtOf(alloc, db, "s_1");
    defer alloc.free(written_at);
    try testing.expectEqualStrings("2026-10-01 08:00:00", written_at);
}

test "Migration133 leaves a session whose legacy plan is empty alone" {
    const alloc = testing.allocator;
    var ctx = try openDb(alloc);
    defer ctx.db.deinit();
    defer ctx.threaded.deinit();
    const db = &ctx.db;

    try db.exec(alloc, "INSERT INTO sessions (id, name) VALUES ('s_1', 'S1')", &[_][]const u8{});
    try db.exec(alloc, "INSERT INTO session_plan (session_id, plan_md) VALUES ('s_1', '')", &[_][]const u8{});

    try Migration133BackfillSessionPlan.up(db, alloc);

    const plan = try planMdOf(alloc, db, "s_1");
    defer alloc.free(plan);
    try testing.expectEqualStrings("", plan);

    const written_at = try planUpdatedAtOf(alloc, db, "s_1");
    defer alloc.free(written_at);
    try testing.expectEqualStrings("", written_at);
}

test "Migration133 keeps a plan the session already carries when the legacy row is empty" {
    const alloc = testing.allocator;
    var ctx = try openDb(alloc);
    defer ctx.db.deinit();
    defer ctx.threaded.deinit();
    const db = &ctx.db;

    try db.exec(
        alloc,
        "INSERT INTO sessions (id, name, plan_md, plan_updated_at) VALUES ('s_1', 'S1', 'live plan', '2026-11-01 10:00:00')",
        &[_][]const u8{},
    );
    try db.exec(alloc, "INSERT INTO session_plan (session_id, plan_md) VALUES ('s_1', '')", &[_][]const u8{});

    try Migration133BackfillSessionPlan.up(db, alloc);

    const plan = try planMdOf(alloc, db, "s_1");
    defer alloc.free(plan);
    try testing.expectEqualStrings("live plan", plan);

    const written_at = try planUpdatedAtOf(alloc, db, "s_1");
    defer alloc.free(written_at);
    try testing.expectEqualStrings("2026-11-01 10:00:00", written_at);
}

test "Migration133 is a no-op once the legacy table is gone" {
    const alloc = testing.allocator;
    var ctx = try openDb(alloc);
    defer ctx.db.deinit();
    defer ctx.threaded.deinit();
    const db = &ctx.db;

    try db.exec(alloc, "INSERT INTO sessions (id, name) VALUES ('s_1', 'S1')", &[_][]const u8{});
    try db.exec(alloc, "DROP TABLE session_plan", &[_][]const u8{});

    try Migration133BackfillSessionPlan.up(db, alloc);

    const plan = try planMdOf(alloc, db, "s_1");
    defer alloc.free(plan);
    try testing.expectEqualStrings("", plan);
}

test "Migration133 replaying over unchanged input leaves the same plan" {
    const alloc = testing.allocator;
    var ctx = try openDb(alloc);
    defer ctx.db.deinit();
    defer ctx.threaded.deinit();
    const db = &ctx.db;

    try db.exec(alloc, "INSERT INTO sessions (id, name) VALUES ('s_1', 'S1')", &[_][]const u8{});
    try db.exec(alloc, "INSERT INTO session_plan (session_id, plan_md) VALUES ('s_1', 'plan v1')", &[_][]const u8{});

    try Migration133BackfillSessionPlan.up(db, alloc);
    try Migration133BackfillSessionPlan.up(db, alloc);

    const plan = try planMdOf(alloc, db, "s_1");
    defer alloc.free(plan);
    try testing.expectEqualStrings("plan v1", plan);
}

test "Migration133 is registered in allMigrations" {
    for (@import("migration.zig").allMigrations) |m| {
        if (m.version == Migration133BackfillSessionPlan.version and
            std.mem.eql(u8, m.name, Migration133BackfillSessionPlan.name)) return;
    }
    return error.Migration133NotRegistered;
}
