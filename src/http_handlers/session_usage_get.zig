//! `GET /api/llm/session/:session_id/usage` — token usage + cache hit rate.
//! DERIVED, not stored.

const std = @import("std");
const http_response = @import("http_response.zig");
const pabrikcore = @import("pabrikcore");
const gserverz = pabrikcore.gserverz;

pub const SessionUsageError = error{
    QueryFailed,
    /// `std.json.Stringify.valueAlloc` can fail with `OutOfMemory`.
    /// Unreachable on the per-request arena, but the type system
    /// requires the variant.
    OutOfMemory,
};

/// Wire shape. `cache_hit_rate` is a percentage in 0..100 with two decimals,
/// or `null` when the session has no input tokens at all (nothing to divide
/// by) — never a fabricated 0 for an empty session.
pub const SessionUsageJson = struct {
    session_id: []const u8,
    cache_hit_rate: ?f64 = null,
    cache_read_tokens: i64 = 0,
    cache_creation_tokens: i64 = 0,
    total_input_tokens: i64 = 0,
    /// Rows that reported cache counters (`cache_read` or `cache_creation`
    /// non-zero). 0 means the provider reported none — see the file header.
    calls_with_cache: i64 = 0,
};

// =====================================================================
// Use case
// =====================================================================

/// One aggregate row per session. Every column is COALESCE'd because SQLite
/// answers `SUM` over zero rows with NULL, and this backend reads a NULL as
/// an empty slice — indistinguishable from the string "".
const USAGE_SQL =
    \\SELECT COALESCE(SUM(prompt_tokens), 0),
    \\       COALESCE(SUM(cache_read_input_tokens), 0),
    \\       COALESCE(SUM(cache_creation_input_tokens), 0),
    \\       COALESCE(SUM(CASE WHEN cache_read_input_tokens > 0 OR cache_creation_input_tokens > 0
    \\                         THEN 1 ELSE 0 END), 0)
    \\FROM llm_history WHERE session_id = ?
;

/// `i64` from a column read as text; a NULL (empty slice) or garbage reads as
/// 0, which is the same value the COALESCE would have produced.
fn colInt(text: []const u8) i64 {
    return std.fmt.parseInt(i64, text, 10) catch 0;
}

/// Two decimals, so the wire value is stable and a client never renders
/// `93.66666666666667`.
fn round2(x: f64) f64 {
    return @round(x * 100.0) / 100.0;
}

fn useCase(
    allocator: std.mem.Allocator,
    db: *pabrikcore.database.Db,
    session_id: []const u8,
) SessionUsageError![]const u8 {
    var total_input: i64 = 0;
    var cache_read: i64 = 0;
    var cache_creation: i64 = 0;
    var calls_with_cache: i64 = 0;

    // Empty id: nothing to aggregate, and an empty bind would reach SQLite as
    // NULL — skip the query rather than rely on that.
    if (session_id.len > 0) {
        var rows = db.query(allocator, USAGE_SQL, &.{session_id}) catch return error.QueryFailed;
        defer rows.deinit();

        // An aggregate with no GROUP BY always yields exactly one row.
        if (rows.next() catch return error.QueryFailed) |row| {
            if (row.values.len >= 4) {
                total_input = colInt(row.values[0]);
                cache_read = colInt(row.values[1]);
                cache_creation = colInt(row.values[2]);
                calls_with_cache = colInt(row.values[3]);
            }
            row.deinit(allocator);
        }
    }

    const rate: ?f64 = if (total_input > 0)
        round2(100.0 * @as(f64, @floatFromInt(cache_read)) / @as(f64, @floatFromInt(total_input)))
    else
        null;

    return try std.json.Stringify.valueAlloc(allocator, SessionUsageJson{
        .session_id = session_id,
        .cache_hit_rate = rate,
        .cache_read_tokens = cache_read,
        .cache_creation_tokens = cache_creation,
        .total_input_tokens = total_input,
        .calls_with_cache = calls_with_cache,
    }, .{});
}

// =====================================================================
// Handler
// =====================================================================

/// GET /api/llm/session/:session_id/usage
pub fn sessionUsageHandler(
    ctx: gserverz.HttpContext,
    req: gserverz.HttpRequest,
    res: gserverz.HttpResponse,
) !gserverz.HttpResponse {
    const allocator = ctx.allocator;

    const session_id = req.params.get("session_id") orelse {
        return res.jsonResponse(.{
            .status_code = 400,
            .data = try http_response.makeErrorResponse(allocator, .{ .@"error" = "Missing session_id" }),
        });
    };
    if (session_id.len == 0) {
        return res.jsonResponse(.{
            .status_code = 400,
            .data = try http_response.makeErrorResponse(allocator, .{ .@"error" = "Missing session_id" }),
        });
    }

    const di = try pabrikcore.getSingleton();
    const sqlite_db = di.db;

    const response = useCase(allocator, sqlite_db, session_id) catch |err| {
        const message: []const u8 = switch (err) {
            error.QueryFailed => "Database query failed",
            error.OutOfMemory => "Out of memory",
        };
        return res.jsonResponse(.{
            .status_code = 500,
            .data = try http_response.makeErrorResponse(allocator, .{ .@"error" = message }),
        });
    };

    return res.jsonResponse(.{ .status_code = 200, .data = response });
}

// =====================================================================
// Tests — the aggregate itself (in-memory SQLite)
// =====================================================================

const testing = std.testing;

const TestCtx = struct {
    db: pabrikcore.database.Db,
    threaded: std.Io.Threaded,
};

fn setupDb() !TestCtx {
    const alloc = testing.allocator;
    var threaded = std.Io.Threaded.init(alloc, .{});
    errdefer threaded.deinit();
    const io = threaded.io();
    var db: pabrikcore.database.Db = .{};
    errdefer db.deinit();
    try db.init(io, ":memory:");

    // Only the columns USAGE_SQL reads. A minimal schema is deliberate: if
    // the query ever grows a dependency on another column, this setup stops
    // compiling/running rather than silently passing.
    try db.exec(alloc,
        \\CREATE TABLE llm_history (
        \\  id TEXT PRIMARY KEY,
        \\  session_id TEXT NOT NULL,
        \\  prompt_tokens INTEGER NOT NULL DEFAULT 0,
        \\  cache_read_input_tokens INTEGER NOT NULL DEFAULT 0,
        \\  cache_creation_input_tokens INTEGER NOT NULL DEFAULT 0
        \\)
    , &.{});

    return .{ .db = db, .threaded = threaded };
}

fn teardown(ctx: *TestCtx) void {
    ctx.db.deinit();
    ctx.threaded.deinit();
}

fn insertRow(ctx: *TestCtx, id: []const u8, session_id: []const u8, prompt: i64, read: i64, write: i64) !void {
    const sql = try std.fmt.allocPrint(
        testing.allocator,
        "INSERT INTO llm_history (id, session_id, prompt_tokens, cache_read_input_tokens, cache_creation_input_tokens) VALUES ('{s}', '{s}', {d}, {d}, {d})",
        .{ id, session_id, prompt, read, write },
    );
    defer testing.allocator.free(sql);
    try ctx.db.exec(testing.allocator, sql, &.{});
}

/// Parse the useCase's JSON so a claim about a FIELD is a claim about that
/// field, not about the whole blob.
fn run(ctx: *TestCtx, session_id: []const u8) !std.json.Parsed(std.json.Value) {
    const json = try useCase(testing.allocator, &ctx.db, session_id);
    defer testing.allocator.free(json);
    return std.json.parseFromSlice(std.json.Value, testing.allocator, json, .{});
}

/// The rate as `f64`.
fn rateOf(obj: std.json.ObjectMap) ?f64 {
    return switch (obj.get("cache_hit_rate") orelse return null) {
        .float => |f| f,
        .integer => |i| @floatFromInt(i),
        else => null,
    };
}

test "useCase: cache hit rate is cache-read over total input, across every row of the session" {
    var ctx = try setupDb();
    defer teardown(&ctx);

    // Two calls with different cache behaviour, plus one input row that
    // carries no usage at all (the user message every turn writes).
    try insertRow(&ctx, "h1", "s1", 1000, 900, 0);
    try insertRow(&ctx, "h2", "s1", 500, 100, 50);
    try insertRow(&ctx, "h3", "s1", 0, 0, 0);
    // Another session's rows must not leak into s1's numbers.
    try insertRow(&ctx, "h4", "s2", 9999, 9999, 9999);

    var doc = try run(&ctx, "s1");
    defer doc.deinit();
    const obj = doc.value.object;

    try testing.expectEqualStrings("s1", obj.get("session_id").?.string);
    // (900 + 100) / (1000 + 500) = 66.666...%
    try testing.expectEqual(@as(f64, 66.67), rateOf(obj).?);
    try testing.expectEqual(@as(i64, 1000), obj.get("cache_read_tokens").?.integer);
    try testing.expectEqual(@as(i64, 50), obj.get("cache_creation_tokens").?.integer);
    try testing.expectEqual(@as(i64, 1500), obj.get("total_input_tokens").?.integer);
    // h1 + h2 reported cache; the zero-usage input row did not.
    try testing.expectEqual(@as(i64, 2), obj.get("calls_with_cache").?.integer);
}

test "useCase: a session with no rows reports zeros and a null rate, never a fabricated 0%" {
    var ctx = try setupDb();
    defer teardown(&ctx);

    var doc = try run(&ctx, "never_used");
    defer doc.deinit();
    const obj = doc.value.object;

    try testing.expect(obj.get("cache_hit_rate").? == .null);
    try testing.expectEqual(@as(i64, 0), obj.get("cache_read_tokens").?.integer);
    try testing.expectEqual(@as(i64, 0), obj.get("total_input_tokens").?.integer);
    try testing.expectEqual(@as(i64, 0), obj.get("calls_with_cache").?.integer);
}

test "useCase: tokens recorded with no cache counters keep rate 0 and calls_with_cache 0" {
    // The positive control for the absence claim above: this session HAS
    // input tokens, so the rate is a real 0 — while `calls_with_cache == 0`
    // still tells a client the provider reported nothing (see file header).
    var ctx = try setupDb();
    defer teardown(&ctx);

    try insertRow(&ctx, "h1", "s1", 4000, 0, 0);

    var doc = try run(&ctx, "s1");
    defer doc.deinit();
    const obj = doc.value.object;

    try testing.expectEqual(@as(f64, 0.0), rateOf(obj).?);
    try testing.expectEqual(@as(i64, 4000), obj.get("total_input_tokens").?.integer);
    try testing.expectEqual(@as(i64, 0), obj.get("calls_with_cache").?.integer);
}

test "useCase: a cache WRITE alone is not a hit — it counts as cache data but stays out of the numerator" {
    var ctx = try setupDb();
    defer teardown(&ctx);

    try insertRow(&ctx, "h1", "s1", 1000, 0, 800);

    var doc = try run(&ctx, "s1");
    defer doc.deinit();
    const obj = doc.value.object;

    try testing.expectEqual(@as(f64, 0.0), rateOf(obj).?);
    try testing.expectEqual(@as(i64, 800), obj.get("cache_creation_tokens").?.integer);
    try testing.expectEqual(@as(i64, 1), obj.get("calls_with_cache").?.integer);
}

test "useCase: a fully cached session reads 100%, and an empty id short-circuits to zeros" {
    var ctx = try setupDb();
    defer teardown(&ctx);

    try insertRow(&ctx, "h1", "s1", 1000, 1000, 0);

    var doc = try run(&ctx, "s1");
    defer doc.deinit();
    try testing.expectEqual(@as(f64, 100.0), rateOf(doc.value.object).?);

    // Empty id: no query, zeros, and no session_id echo beyond the given "".
    var empty = try run(&ctx, "");
    defer empty.deinit();
    try testing.expect(empty.value.object.get("cache_hit_rate").? == .null);
    try testing.expectEqual(@as(i64, 0), empty.value.object.get("total_input_tokens").?.integer);
}

test "wire: the response carries exactly the documented keys" {
    // Pins the contract a client codes against: a renamed or dropped field is
    // a breaking change, and this is the only place that says so.
    var ctx = try setupDb();
    defer teardown(&ctx);
    try insertRow(&ctx, "h1", "s1", 1000, 250, 0);

    var doc = try run(&ctx, "s1");
    defer doc.deinit();
    const obj = doc.value.object;

    try testing.expectEqual(@as(usize, 6), obj.count());
    for ([_][]const u8{
        "session_id",
        "cache_hit_rate",
        "cache_read_tokens",
        "cache_creation_tokens",
        "total_input_tokens",
        "calls_with_cache",
    }) |key| {
        try testing.expect(obj.get(key) != null);
    }
}

test "wire: the serialized body is byte-stable — field order, float rendering, null rate" {
    // The whole response is asserted as TEXT because three separate things a
    // client depends on are invisible to a field-by-field check: the field
    // ORDER, the rendering of the rate (Zig's shortest round-trip form emits
    var ctx = try setupDb();
    defer teardown(&ctx);
    try insertRow(&ctx, "h1", "s1", 1000, 900, 0);

    const json = try useCase(testing.allocator, &ctx.db, "s1");
    defer testing.allocator.free(json);
    try testing.expectEqualStrings(
        "{\"session_id\":\"s1\",\"cache_hit_rate\":90,\"cache_read_tokens\":900," ++
            "\"cache_creation_tokens\":0,\"total_input_tokens\":1000,\"calls_with_cache\":1}",
        json,
    );

    const empty = try useCase(testing.allocator, &ctx.db, "nobody");
    defer testing.allocator.free(empty);
    try testing.expectEqualStrings(
        "{\"session_id\":\"nobody\",\"cache_hit_rate\":null,\"cache_read_tokens\":0," ++
            "\"cache_creation_tokens\":0,\"total_input_tokens\":0,\"calls_with_cache\":0}",
        empty,
    );
}
