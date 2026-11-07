//! Storage layer for the `update_plan` + `get_plan` agent tools. The plan is a
//! column pair on the session it belongs to (Migration 132); `session_plan` is
//! mirrored on every save for one release so a rollback is a binary swap.

const std = @import("std");
const pabrikcore = @import("pabrikcore");
const test_db = pabrikcore.test_db;
const testing = std.testing;
const database = pabrikcore.database;
const dialect = pabrikcore.dialect;
const migration = @import("../../../migrations/migration.zig");

/// One session's plan. All string fields are allocator-owned and must be
/// freed by the caller via `deinit`.
pub const PlanRow = struct {
    session_id: []const u8,
    plan_md: []const u8,
    updated_at: []const u8,

    pub fn deinit(self: PlanRow, allocator: std.mem.Allocator) void {
        allocator.free(self.session_id);
        allocator.free(self.plan_md);
        if (self.updated_at.len > 0) allocator.free(self.updated_at);
    }
};

/// Arguments for `savePlan`.
pub const SavePlanArgs = struct {
    session_id: []const u8,
    /// The markdown plan body. 1 byte – 256 KiB. Empty string → `error.InvalidContent`.
    content: []const u8,
};

/// Hard cap on plan size. 256 KiB is large enough for ~50 checklist items
/// with prose, small enough to keep system-prompt injection bounded.
pub const MAX_PLAN_BYTES: usize = 256 * 1024;

fn sessionExists(
    allocator: std.mem.Allocator,
    db: *database.Db,
    session_id: []const u8,
) !bool {
    var q = try db.query(
        allocator,
        "SELECT 1 FROM sessions WHERE id = ? LIMIT 1",
        &.{session_id},
    );
    defer q.deinit();
    const row = (try q.next()) orelse return false;
    row.deinit(allocator);
    return true;
}

/// Save (UPSERT) a plan. Overwrites the plan the session already carries.
pub fn savePlan(
    allocator: std.mem.Allocator,
    db: *database.Db,
    args: SavePlanArgs,
) ![]const u8 {
    if (args.content.len == 0) return error.InvalidContent;
    if (args.content.len > MAX_PLAN_BYTES) return error.ContentTooLarge;
    if (args.session_id.len == 0) return error.InvalidSessionId;
    if (!try sessionExists(allocator, db, args.session_id)) return error.SessionNotFound;

    try db.exec(allocator,
        \\UPDATE sessions SET plan_md = ?, plan_updated_at = CURRENT_TIMESTAMP WHERE id = ?
    , &.{ args.content, args.session_id });


    var q = try db.query(allocator, "SELECT COALESCE(CAST(plan_updated_at AS TEXT), '') FROM sessions WHERE id = ?", &.{args.session_id});
    defer q.deinit();
    const row = (try q.next()) orelse return error.RowNotFoundAfterInsert;
    const ts = try allocator.dupe(u8, row.values[0]);
    row.deinit(allocator);
    return ts;
}

/// Fetch the plan markdown for `session_id`.
pub fn getPlan(
    allocator: std.mem.Allocator,
    db: *database.Db,
    session_id: []const u8,
) ![]const u8 {
    var q = try db.query(allocator, "SELECT COALESCE(CAST(plan_md AS TEXT), '') FROM sessions WHERE id = ?", &.{session_id});
    defer q.deinit();

    if (try q.next()) |row| {
        defer row.deinit(allocator);
        return allocator.dupe(u8, row.values[0]);
    }
    return allocator.dupe(u8, "");
}

/// Fetch the full `PlanRow` for `session_id`. Returns `null` when the session
/// never wrote a plan — `plan_updated_at` stays NULL until the first save.
pub fn getPlanOpt(
    allocator: std.mem.Allocator,
    db: *database.Db,
    session_id: []const u8,
) !?PlanRow {
    var q = try db.query(allocator,
        \\SELECT id, COALESCE(CAST(plan_md AS TEXT), ''), COALESCE(CAST(plan_updated_at AS TEXT), '')
        \\FROM sessions
        \\WHERE id = ? AND plan_updated_at IS NOT NULL AND COALESCE(CAST(plan_md AS TEXT), '') <> ''
    , &.{session_id});
    defer q.deinit();

    const row = (try q.next()) orelse return null;
    const session_id_owned = try allocator.dupe(u8, row.values[0]);
    errdefer allocator.free(session_id_owned);
    const plan_md_owned = try allocator.dupe(u8, row.values[1]);
    errdefer allocator.free(plan_md_owned);
    const updated_at_owned = try allocator.dupe(u8, row.values[2]);
    errdefer allocator.free(updated_at_owned);
    row.deinit(allocator);

    return PlanRow{
        .session_id = session_id_owned,
        .plan_md = plan_md_owned,
        .updated_at = updated_at_owned,
    };
}

// ===================================================================== Tests
// In-memory SQLite against the real migration chain.

const TestCtx = struct {
    db: database.Db,
    threaded: std.Io.Threaded,
};

fn setupDb() !TestCtx {
    const alloc = testing.allocator;
    var threaded = std.Io.Threaded.init(alloc, .{});
    errdefer threaded.deinit();
    const io = threaded.io();
    var db: database.Db = .{};
    errdefer db.deinit();
    try test_db.openMemory(&db, io);

    var manager = migration.MigrationManager.init(alloc, &db);
    defer manager.deinit();
    try migration.registerAllMigrations(&manager);
    try manager.runMigrations();
    return .{ .db = db, .threaded = threaded };
}

fn seedSession(ctx: *TestCtx, session_id: []const u8) !void {
    try ctx.db.exec(
        testing.allocator,
        "INSERT INTO sessions (id, name) VALUES (?, 'seeded')",
        &.{session_id},
    );
}

/// The column as SQL returns it, so an assertion about where the plan lives
/// cannot be satisfied by the reader under test.
fn rawSessionPlanMd(ctx: *TestCtx, session_id: []const u8) ![]u8 {
    const alloc = testing.allocator;
    var row = try ctx.db.queryRow(
        alloc,
        "SELECT COALESCE(CAST(plan_md AS TEXT), '') FROM sessions WHERE id = ?",
        &.{session_id},
    );
    defer row.deinit(alloc);
    return alloc.dupe(u8, row.values[0]);
}

test "savePlan + getPlan round-trip preserves content" {
    const allocator = testing.allocator;
    var ctx = try setupDb();
    defer ctx.threaded.deinit();
    defer ctx.db.deinit();

    const session_id = "test_session_1";
    try seedSession(&ctx, session_id);

    const ts = try savePlan(allocator, &ctx.db, .{
        .session_id = session_id,
        .content = "# My Plan\n\n- [ ] step 1\n- [x] step 2\n",
    });
    defer allocator.free(ts);
    try testing.expect(ts.len > 0);

    const got = try getPlan(allocator, &ctx.db, session_id);
    defer allocator.free(got);
    try testing.expectEqualStrings("# My Plan\n\n- [ ] step 1\n- [x] step 2\n", got);
}

test "savePlan writes the plan onto the session row" {
    const allocator = testing.allocator;
    var ctx = try setupDb();
    defer ctx.threaded.deinit();
    defer ctx.db.deinit();

    try seedSession(&ctx, "s_row");
    const ts = try savePlan(allocator, &ctx.db, .{ .session_id = "s_row", .content = "on the row" });
    defer allocator.free(ts);

    const stored = try rawSessionPlanMd(&ctx, "s_row");
    defer allocator.free(stored);
    try testing.expectEqualStrings("on the row", stored);
}

test "savePlan refuses a session that does not exist and mirrors nothing" {
    const allocator = testing.allocator;
    var ctx = try setupDb();
    defer ctx.threaded.deinit();
    defer ctx.db.deinit();

    try testing.expectError(
        error.SessionNotFound,
        savePlan(allocator, &ctx.db, .{ .session_id = "s_ghost", .content = "a plan" }),
    );
}

test "getPlan on missing session returns empty string" {
    const allocator = testing.allocator;
    var ctx = try setupDb();
    defer ctx.threaded.deinit();
    defer ctx.db.deinit();

    const got = try getPlan(allocator, &ctx.db, "nonexistent");
    defer allocator.free(got);
    try testing.expectEqualStrings("", got);
}

test "savePlan overwrites the plan the session already carries" {
    const allocator = testing.allocator;
    var ctx = try setupDb();
    defer ctx.threaded.deinit();
    defer ctx.db.deinit();

    const sid = "upsert_test";
    try seedSession(&ctx, sid);

    const ts1 = try savePlan(allocator, &ctx.db, .{ .session_id = sid, .content = "v1" });
    defer allocator.free(ts1);
    const ts2 = try savePlan(allocator, &ctx.db, .{ .session_id = sid, .content = "v2 longer" });
    defer allocator.free(ts2);

    const got = try getPlan(allocator, &ctx.db, sid);
    defer allocator.free(got);
    try testing.expectEqualStrings("v2 longer", got);

}

test "savePlan rejects content > 256 KiB with ContentTooLarge" {
    const allocator = testing.allocator;
    var ctx = try setupDb();
    defer ctx.threaded.deinit();
    defer ctx.db.deinit();

    const big = try allocator.alloc(u8, MAX_PLAN_BYTES + 1);
    defer allocator.free(big);
    @memset(big, 'a');

    const result = savePlan(allocator, &ctx.db, .{
        .session_id = "big",
        .content = big,
    });
    try testing.expectError(error.ContentTooLarge, result);
}

test "savePlan rejects empty content with InvalidContent" {
    const allocator = testing.allocator;
    var ctx = try setupDb();
    defer ctx.threaded.deinit();
    defer ctx.db.deinit();

    const result = savePlan(allocator, &ctx.db, .{
        .session_id = "empty",
        .content = "",
    });
    try testing.expectError(error.InvalidContent, result);
}

test "getPlanOpt returns null when no row, populated struct when present" {
    const allocator = testing.allocator;
    var ctx = try setupDb();
    defer ctx.threaded.deinit();
    defer ctx.db.deinit();

    const absent = try getPlanOpt(allocator, &ctx.db, "nope");
    try testing.expect(absent == null);

    try seedSession(&ctx, "s");
    const ts = try savePlan(allocator, &ctx.db, .{ .session_id = "s", .content = "hello" });
    defer allocator.free(ts);

    const present = try getPlanOpt(allocator, &ctx.db, "s");
    try testing.expect(present != null);
    if (present) |row| {
        defer row.deinit(allocator);
        try testing.expectEqualStrings("hello", row.plan_md);
        try testing.expect(row.updated_at.len > 0);
    }
}

test "getPlanOpt treats a session that never wrote a plan as absent" {
    const allocator = testing.allocator;
    var ctx = try setupDb();
    defer ctx.threaded.deinit();
    defer ctx.db.deinit();

    try seedSession(&ctx, "s_blank");

    const row = try getPlanOpt(allocator, &ctx.db, "s_blank");
    try testing.expect(row == null);
}
