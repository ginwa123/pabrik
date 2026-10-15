//! Storage layer for the `update_plan` + `get_plan` agent tools.

const std = @import("std");
const testing = std.testing;
const sqlite = @import("pabrikcore").sqlite;
const migration = @import("../migrations/migration.zig");

/// One row in `session_plan`. All string fields are allocator-owned and
/// must be freed by the caller via `deinit`.
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

/// Save (UPSERT) a plan. Overwrites any existing row for `session_id`.
pub fn savePlan(
    allocator: std.mem.Allocator,
    db: *sqlite.SqliteBackend,
    args: SavePlanArgs,
) ![]const u8 {
    if (args.content.len == 0) return error.InvalidContent;
    if (args.content.len > MAX_PLAN_BYTES) return error.ContentTooLarge;
    if (args.session_id.len == 0) return error.InvalidSessionId;

    var binds: [2][]const u8 = .{ args.session_id, args.content };
    try db.exec(allocator,
        \\INSERT INTO session_plan (session_id, plan_md, updated_at)
        \\VALUES (?, ?, CURRENT_TIMESTAMP)
        \\ON CONFLICT(session_id) DO UPDATE SET
        \\    plan_md = excluded.plan_md,
        \\    updated_at = CURRENT_TIMESTAMP
    , &binds);

    var q = try db.query(allocator,
        "SELECT updated_at FROM session_plan WHERE session_id = ?",
        &.{args.session_id});
    defer q.deinit();
    const row = (try q.next()) orelse return error.RowNotFoundAfterInsert;
    const ts = try allocator.dupe(u8, row.values[0]);
    row.deinit(allocator);
    return ts;
}

/// Fetch the plan markdown for `session_id`.
pub fn getPlan(
    allocator: std.mem.Allocator,
    db: *sqlite.SqliteBackend,
    session_id: []const u8,
) ![]const u8 {
    var q = try db.query(allocator,
        "SELECT plan_md FROM session_plan WHERE session_id = ?",
        &.{session_id});
    defer q.deinit();

    if (try q.next()) |row| {
        defer row.deinit(allocator);
        if (row.values[0].len == 0) return allocator.dupe(u8, "");
        return allocator.dupe(u8, row.values[0]);
    }
    return allocator.dupe(u8, "");
}

/// Fetch the full `PlanRow` for `session_id`. Returns `null` when absent
/// (matches `agent_memories.getMemoryById` convention). Used by the
/// compaction enrichment to also carry the `updated_at` timestamp.
pub fn getPlanOpt(
    allocator: std.mem.Allocator,
    db: *sqlite.SqliteBackend,
    session_id: []const u8,
) !?PlanRow {
    var q = try db.query(allocator,
        "SELECT session_id, plan_md, COALESCE(updated_at, '') FROM session_plan WHERE session_id = ?",
        &.{session_id});
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

const TestCtx = struct {
    db: sqlite.SqliteBackend,
    threaded: std.Io.Threaded,
};

fn setupDb() !TestCtx {
    const alloc = testing.allocator;
    var threaded = std.Io.Threaded.init(alloc, .{});
    errdefer threaded.deinit();
    const io = threaded.io();
    var db: sqlite.SqliteBackend = .{};
    errdefer db.deinit();
    try db.init(io, ":memory:");

    var manager = migration.MigrationManager.init(alloc, &db);
    defer manager.deinit();
    try migration.registerAllMigrations(&manager);
    try manager.runMigrations();
    return .{ .db = db, .threaded = threaded };
}

// ─── Test 1: round-trip save + getPlan returns the same content ──────────

test "savePlan + getPlan round-trip preserves content" {
    const allocator = testing.allocator;
    var ctx = try setupDb();
    defer ctx.threaded.deinit();
    defer ctx.db.deinit();

    const session_id = "test_session_1";
    {
        const ts = try savePlan(allocator, &ctx.db, .{
            .session_id = session_id,
            .content = "# My Plan\n\n- [ ] step 1\n- [x] step 2\n",
        });
        defer allocator.free(ts);
    }

    const got = try getPlan(allocator, &ctx.db, session_id);
    defer allocator.free(got);
    try testing.expectEqualStrings("# My Plan\n\n- [ ] step 1\n- [x] step 2\n", got);
}

// ─── Test 2: getPlan on missing session returns empty string ─────────────

test "getPlan on missing session returns empty string" {
    const allocator = testing.allocator;
    var ctx = try setupDb();
    defer ctx.threaded.deinit();
    defer ctx.db.deinit();

    const got = try getPlan(allocator, &ctx.db, "nonexistent");
    defer allocator.free(got);
    try testing.expectEqualStrings("", got);
}

// ─── Test 3: UPSERT semantics — second save replaces the first ────────────

test "savePlan overwrites existing row (UPSERT semantics)" {
    const allocator = testing.allocator;
    var ctx = try setupDb();
    defer ctx.threaded.deinit();
    defer ctx.db.deinit();

    const sid = "upsert_test";

    {
        const ts1 = try savePlan(allocator, &ctx.db, .{ .session_id = sid, .content = "v1" });
        defer allocator.free(ts1);
        const ts2 = try savePlan(allocator, &ctx.db, .{ .session_id = sid, .content = "v2 longer" });
        defer allocator.free(ts2);
    }

    const got = try getPlan(allocator, &ctx.db, sid);
    defer allocator.free(got);
    try testing.expectEqualStrings("v2 longer", got);

    // Confirm there is still exactly ONE row in the DB (UPSERT, not
    // INSERT-OR-APPEND).
    var q = try ctx.db.query(allocator,
        "SELECT COUNT(*) FROM session_plan WHERE session_id = ?",
        &.{sid});
    defer q.deinit();
    const row = (try q.next()) orelse return error.RowMissing;
    defer row.deinit(allocator);
    try testing.expectEqualStrings("1", row.values[0]);
}

// ─── Test 4: content > MAX_PLAN_BYTES returns ContentTooLarge ─────────────

test "savePlan rejects content > 256 KiB with ContentTooLarge" {
    const allocator = testing.allocator;
    var ctx = try setupDb();
    defer ctx.threaded.deinit();
    defer ctx.db.deinit();

    const big = try allocator.alloc(u8, MAX_PLAN_BYTES + 1);
    defer allocator.free(big);
    @memset(big, 'a');

    const result = savePlan(allocator, &ctx.db, .{
        .session_id = "big", .content = big,
    });
    try testing.expectError(error.ContentTooLarge, result);
}

// ─── Test 5: empty content returns InvalidContent ─────────────────────────

test "savePlan rejects empty content with InvalidContent" {
    const allocator = testing.allocator;
    var ctx = try setupDb();
    defer ctx.threaded.deinit();
    defer ctx.db.deinit();

    const result = savePlan(allocator, &ctx.db, .{
        .session_id = "empty", .content = "",
    });
    try testing.expectError(error.InvalidContent, result);
}

// ─── Test 6: getPlanOpt — null when absent, populated PlanRow when present

test "getPlanOpt returns null when no row, populated struct when present" {
    const allocator = testing.allocator;
    var ctx = try setupDb();
    defer ctx.threaded.deinit();
    defer ctx.db.deinit();

    // absent
    const absent = try getPlanOpt(allocator, &ctx.db, "nope");
    try testing.expect(absent == null);

    // present
    {
        const ts = try savePlan(allocator, &ctx.db, .{ .session_id = "s", .content = "hello" });
        defer allocator.free(ts);
    }
    const present = try getPlanOpt(allocator, &ctx.db, "s");
    try testing.expect(present != null);
    if (present) |row| {
        defer row.deinit(allocator);
        try testing.expectEqualStrings("hello", row.plan_md);
        try testing.expect(row.updated_at.len > 0);
    }
}