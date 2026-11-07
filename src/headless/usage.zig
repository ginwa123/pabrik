const std = @import("std");
const pabrikcore = @import("pabrikcore");

const args = @import("args.zig");
const boot_mod = @import("boot.zig");

const usage_handler = pabrikcore.http_handlers.workspace_usage;

pub const range_hint = usage_handler.range_hint;

pub fn run(
    allocator: std.mem.Allocator,
    backend: *boot_mod.Backend,
    a: args.UsageArgs,
) usage_handler.WorkspaceUsageError![]const u8 {
    const now_ns = std.Io.Clock.now(.real, backend.io).toMilliseconds() * 1_000_000;
    return runWithDb(allocator, backend.ctx.db, a, now_ns);
}

pub fn runWithDb(
    allocator: std.mem.Allocator,
    db: *pabrikcore.database.Db,
    a: args.UsageArgs,
    now_ns: i64,
) usage_handler.WorkspaceUsageError![]const u8 {
    const range = usage_handler.parseRange(if (a.range.len == 0) null else a.range) orelse
        return error.InvalidRange;
    const cutoff_ns = now_ns - range.days * 86_400_000 * 1_000_000;
    return usage_handler.useCase(allocator, db, a.workspace_id, range, cutoff_ns);
}

const testing = std.testing;
const test_db = pabrikcore.test_db;

const TestCtx = struct {
    db: pabrikcore.database.Db,
    threaded: std.Io.Threaded,
};

fn setupDb() !TestCtx {
    const alloc = testing.allocator;
    var threaded = std.Io.Threaded.init(alloc, .{});
    errdefer threaded.deinit();
    var db: pabrikcore.database.Db = .{};
    errdefer db.deinit();
    try test_db.openMemory(&db, threaded.io());

    try db.exec(alloc,
        \\CREATE TABLE sessions (id TEXT PRIMARY KEY, workspace_id TEXT NOT NULL)
    , &.{});
    try db.exec(alloc,
        \\CREATE TABLE llm_history (
        \\  id TEXT PRIMARY KEY,
        \\  session_id TEXT NOT NULL,
        \\  model TEXT,
        \\  prompt_tokens INTEGER NOT NULL DEFAULT 0,
        \\  completion_tokens INTEGER NOT NULL DEFAULT 0,
        \\  cache_read_input_tokens INTEGER NOT NULL DEFAULT 0,
        \\  cache_creation_input_tokens INTEGER NOT NULL DEFAULT 0,
        \\  created_at_nano BIGINT NOT NULL DEFAULT 0,
        \\  created_iso TEXT,
        \\  tool_name TEXT,
        \\  finish_reason TEXT,
        \\  role TEXT
        \\)
    , &.{});

    return .{ .db = db, .threaded = threaded };
}

fn teardown(ctx: *TestCtx) void {
    ctx.db.deinit();
    ctx.threaded.deinit();
}

fn insertHistory(ctx: *TestCtx, id: []const u8, prompt: i64, read: i64, at_ns: i64) !void {
    const sql = try std.fmt.allocPrint(
        testing.allocator,
        "INSERT INTO llm_history (id, session_id, model, prompt_tokens, cache_read_input_tokens, created_at_nano, created_iso, role) " ++
            "VALUES ('{s}', 's1', 'm1', {d}, {d}, {d}, '2026-10-20 10:00:00', 'assistant')",
        .{ id, prompt, read, at_ns },
    );
    defer testing.allocator.free(sql);
    try ctx.db.exec(testing.allocator, sql, &.{});
}

const day_ns: i64 = 86_400_000 * 1_000_000;

fn seed(ctx: *TestCtx, now_ns: i64) !void {
    try ctx.db.exec(testing.allocator, "INSERT INTO sessions (id, workspace_id) VALUES ('s1', 'ws_a')", &.{});
    try insertHistory(ctx, "recent", 1000, 900, now_ns - day_ns / 24);
    try insertHistory(ctx, "older", 5000, 0, now_ns - 3 * day_ns);
}

fn totalInt(json: []const u8, key: []const u8) !i64 {
    const parsed = try std.json.parseFromSlice(std.json.Value, testing.allocator, json, .{});
    defer parsed.deinit();
    const totals_value = parsed.value.object.get("totals") orelse return error.MissingTotals;
    const field = totals_value.object.get(key) orelse return error.MissingField;
    return field.integer;
}

test "usage: the range sets the window the totals cover" {
    var ctx = try setupDb();
    defer teardown(&ctx);
    const now_ns: i64 = 10 * day_ns;
    try seed(&ctx, now_ns);

    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();

    const one_day = try runWithDb(arena.allocator(), &ctx.db, .{ .workspace_id = "ws_a", .range = "1d" }, now_ns);
    try testing.expectEqual(@as(i64, 1), try totalInt(one_day, "calls"));
    try testing.expectEqual(@as(i64, 1000), try totalInt(one_day, "input_tokens"));

    const seven_days = try runWithDb(arena.allocator(), &ctx.db, .{ .workspace_id = "ws_a", .range = "7d" }, now_ns);
    try testing.expectEqual(@as(i64, 2), try totalInt(seven_days, "calls"));
}

test "usage: no range prints the window the HTTP endpoint defaults to" {
    var ctx = try setupDb();
    defer teardown(&ctx);
    const now_ns: i64 = 10 * day_ns;
    try seed(&ctx, now_ns);

    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();

    const json = try runWithDb(arena.allocator(), &ctx.db, .{ .workspace_id = "ws_a" }, now_ns);

    const parsed = try std.json.parseFromSlice(std.json.Value, testing.allocator, json, .{});
    defer parsed.deinit();
    try testing.expectEqualStrings("30d", parsed.value.object.get("range").?.string);
    try testing.expectEqual(@as(i64, 2), parsed.value.object.get("totals").?.object.get("calls").?.integer);
}

test "usage: a range the endpoint does not accept is refused instead of silently widened" {
    var ctx = try setupDb();
    defer teardown(&ctx);

    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();

    try testing.expectError(
        error.InvalidRange,
        runWithDb(arena.allocator(), &ctx.db, .{ .workspace_id = "ws_a", .range = "14d" }, 10 * day_ns),
    );
}
