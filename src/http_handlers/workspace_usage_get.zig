//! `GET /api/workspaces/:workspace_id/usage` — token, cache and tool totals
//! for one workspace over a range. Every field is derived from `llm_history`
//! through `sessions`; nothing here is stored.

const std = @import("std");
const http_response = @import("http_response.zig");
const pabrikcore = @import("pabrikcore");
const test_db = pabrikcore.test_db;
const gserverz = pabrikcore.gserverz;
const gate = @import("workspace_members_gate.zig");

pub const WorkspaceUsageError = error{
    InvalidRange,
    QueryFailed,
    OutOfMemory,
};

pub const Range = struct {
    days: i64,
    label: []const u8,
};

pub const default_range = "30d";

pub fn parseRange(raw: ?[]const u8) ?Range {
    const value = raw orelse return .{ .days = 30, .label = default_range };
    if (value.len == 0) return .{ .days = 30, .label = default_range };
    if (std.mem.eql(u8, value, "7d")) return .{ .days = 7, .label = "7d" };
    if (std.mem.eql(u8, value, "30d")) return .{ .days = 30, .label = "30d" };
    if (std.mem.eql(u8, value, "90d")) return .{ .days = 90, .label = "90d" };
    return null;
}

pub const Totals = struct {
    calls: i64 = 0,
    sessions: i64 = 0,
    input_tokens: i64 = 0,
    output_tokens: i64 = 0,
    cache_read_tokens: i64 = 0,
    cache_creation_tokens: i64 = 0,
    calls_with_cache: i64 = 0,
    excluded_calls: i64 = 0,
    tool_calls: i64 = 0,
    cache_hit_rate: ?f64 = null,
};

pub const DailyPoint = struct {
    day: []const u8,
    calls: i64 = 0,
    input_tokens: i64 = 0,
    cache_read_tokens: i64 = 0,
    cache_hit_rate: ?f64 = null,
};

pub const ModelRow = struct {
    model: []const u8,
    calls: i64 = 0,
    input_tokens: i64 = 0,
    calls_with_cache: i64 = 0,
    cache_hit_rate: ?f64 = null,
};

pub const ToolRow = struct {
    tool_name: []const u8,
    calls: i64 = 0,
};

pub const ReasonRow = struct {
    reason: []const u8,
    calls: i64 = 0,
};

pub const SeriesPoint = struct {
    i: i64,
    at: []const u8,
    input_tokens: i64 = 0,
    cache_read_tokens: i64 = 0,
    rate: ?f64 = null,
};

pub const CacheSeries = struct {
    session_id: []const u8,
    model: []const u8,
    total_calls: i64 = 0,
    cache_hit_rate: ?f64 = null,
    calls: []const SeriesPoint = &.{},
};

pub const WorkspaceUsageJson = struct {
    workspace_id: []const u8,
    range: []const u8,
    totals: Totals = .{},
    daily: []const DailyPoint = &.{},
    models: []const ModelRow = &.{},
    tools: []const ToolRow = &.{},
    finish_reasons: []const ReasonRow = &.{},
    cache_series: ?CacheSeries = null,
};

const SCOPE =
    \\FROM llm_history h JOIN sessions s ON s.id = h.session_id
    \\WHERE s.workspace_id = ? AND h.prompt_tokens > 0
    \\  AND h.created_at_nano > CAST(? AS INTEGER)
;

const RATED_READ = "CASE WHEN h.cache_read_input_tokens <= h.prompt_tokens THEN h.cache_read_input_tokens ELSE 0 END";

const TOTALS_SQL =
    "SELECT COUNT(*), " ++
    "       COALESCE(SUM(CASE WHEN h.cache_read_input_tokens <= h.prompt_tokens THEN h.prompt_tokens ELSE 0 END), 0), " ++
    "       COALESCE(SUM(h.completion_tokens), 0), " ++
    "       COALESCE(SUM(" ++ RATED_READ ++ "), 0), " ++
    "       COALESCE(SUM(h.cache_creation_input_tokens), 0), " ++
    "       COALESCE(SUM(CASE WHEN h.cache_read_input_tokens > 0 OR h.cache_creation_input_tokens > 0 THEN 1 ELSE 0 END), 0), " ++
    "       COALESCE(SUM(CASE WHEN h.cache_read_input_tokens > h.prompt_tokens THEN 1 ELSE 0 END), 0), " ++
    "       COUNT(DISTINCT h.session_id) " ++ SCOPE;

const DAILY_SQL =
    "SELECT substr(h.created_iso, 1, 10), COUNT(*), " ++
    "       COALESCE(SUM(h.prompt_tokens), 0), " ++
    "       COALESCE(SUM(" ++ RATED_READ ++ "), 0), " ++
    "       COALESCE(SUM(CASE WHEN h.cache_read_input_tokens > 0 OR h.cache_creation_input_tokens > 0 THEN 1 ELSE 0 END), 0) " ++
    SCOPE ++ " GROUP BY 1 ORDER BY 1";

const MODELS_SQL =
    "SELECT COALESCE(h.model, ''), COUNT(*), " ++
    "       COALESCE(SUM(CASE WHEN h.cache_read_input_tokens <= h.prompt_tokens THEN h.prompt_tokens ELSE 0 END), 0), " ++
    "       COALESCE(SUM(" ++ RATED_READ ++ "), 0), " ++
    "       COALESCE(SUM(CASE WHEN h.cache_read_input_tokens > 0 OR h.cache_creation_input_tokens > 0 THEN 1 ELSE 0 END), 0) " ++
    SCOPE ++ " GROUP BY 1 ORDER BY 3 DESC LIMIT 8";

const SHAPE_SCOPE =
    \\FROM llm_history h JOIN sessions s ON s.id = h.session_id
    \\WHERE s.workspace_id = ? AND h.created_at_nano > CAST(? AS INTEGER)
;

const TOOLS_SQL =
    "SELECT h.tool_name, COUNT(*) " ++ SHAPE_SCOPE ++
    "  AND h.role = 'tool' AND h.tool_name IS NOT NULL AND h.tool_name <> '' " ++
    "GROUP BY 1 ORDER BY 2 DESC LIMIT 8";

const REASONS_SQL =
    "SELECT COALESCE(h.finish_reason, ''), COUNT(*) " ++ SHAPE_SCOPE ++
    "  AND h.role = 'assistant' GROUP BY 1 ORDER BY 2 DESC LIMIT 8";

const LATEST_CACHED_SESSION_SQL =
    "SELECT h.session_id " ++ SCOPE ++
    "  AND h.cache_read_input_tokens > 0 ORDER BY h.created_at_nano DESC LIMIT 1";

const TOOL_TOTAL_SQL =
    "SELECT COUNT(*)" ++ SHAPE_SCOPE ++ "  AND h.role = 'tool' AND h.tool_name IS NOT NULL AND h.tool_name <> ''";

const SERIES_SQL =
    \\SELECT COALESCE(h.created_iso, ''), h.prompt_tokens, COALESCE(h.cache_read_input_tokens, 0)
    \\FROM llm_history h WHERE h.session_id = ? AND h.prompt_tokens > 0
    \\ORDER BY h.created_at_nano LIMIT 120
;

const SERIES_META_SQL =
    "SELECT COALESCE(h.model, ''), COUNT(*), " ++
    "       COALESCE(SUM(CASE WHEN h.cache_read_input_tokens <= h.prompt_tokens THEN h.prompt_tokens ELSE 0 END), 0), " ++
    "       COALESCE(SUM(" ++ RATED_READ ++ "), 0) " ++
    "FROM llm_history h WHERE h.session_id = ?";

fn colInt(text: []const u8) i64 {
    return std.fmt.parseInt(i64, text, 10) catch 0;
}

fn round2(x: f64) f64 {
    return @round(x * 100.0) / 100.0;
}

fn rateOf(read: i64, input: i64) ?f64 {
    if (input <= 0) return null;
    return round2(100.0 * @as(f64, @floatFromInt(read)) / @as(f64, @floatFromInt(input)));
}

fn reportedRate(read: i64, input: i64, calls_with_cache: i64) ?f64 {
    if (calls_with_cache <= 0) return null;
    return rateOf(read, input);
}

fn dupe(allocator: std.mem.Allocator, text: []const u8) WorkspaceUsageError![]const u8 {
    return allocator.dupe(u8, text) catch return error.OutOfMemory;
}

pub fn useCase(
    allocator: std.mem.Allocator,
    db: *pabrikcore.database.Db,
    workspace_id: []const u8,
    range: Range,
    cutoff_ns: i64,
) WorkspaceUsageError![]const u8 {
    var cutoff_buf: [24]u8 = undefined;
    const cutoff = std.fmt.bufPrint(&cutoff_buf, "{d}", .{cutoff_ns}) catch return error.QueryFailed;

    var totals: Totals = .{};
    if (workspace_id.len > 0) {
        var rows = db.query(allocator, TOTALS_SQL, &.{ workspace_id, cutoff }) catch return error.QueryFailed;
        defer rows.deinit();
        if (rows.next() catch return error.QueryFailed) |row| {
            if (row.values.len >= 8) {
                totals.calls = colInt(row.values[0]);
                totals.input_tokens = colInt(row.values[1]);
                totals.output_tokens = colInt(row.values[2]);
                totals.cache_read_tokens = colInt(row.values[3]);
                totals.cache_creation_tokens = colInt(row.values[4]);
                totals.calls_with_cache = colInt(row.values[5]);
                totals.excluded_calls = colInt(row.values[6]);
                totals.sessions = colInt(row.values[7]);
            }
            row.deinit(allocator);
        }
    }
    totals.cache_hit_rate = reportedRate(totals.cache_read_tokens, totals.input_tokens, totals.calls_with_cache);

    var daily: std.ArrayList(DailyPoint) = .empty;
    var models: std.ArrayList(ModelRow) = .empty;
    var tools: std.ArrayList(ToolRow) = .empty;
    var reasons: std.ArrayList(ReasonRow) = .empty;
    var series_points: std.ArrayList(SeriesPoint) = .empty;
    var series: ?CacheSeries = null;

    if (workspace_id.len > 0) {
        {
            var rows = db.query(allocator, DAILY_SQL, &.{ workspace_id, cutoff }) catch return error.QueryFailed;
            defer rows.deinit();
            while (rows.next() catch return error.QueryFailed) |row| {
                defer row.deinit(allocator);
                if (row.values.len < 5) continue;
                const input = colInt(row.values[2]);
                const read = colInt(row.values[3]);
                daily.append(allocator, .{
                    .day = try dupe(allocator, row.values[0]),
                    .calls = colInt(row.values[1]),
                    .input_tokens = input,
                    .cache_read_tokens = read,
                    .cache_hit_rate = reportedRate(read, input, colInt(row.values[4])),
                }) catch return error.OutOfMemory;
            }
        }
        {
            var rows = db.query(allocator, MODELS_SQL, &.{ workspace_id, cutoff }) catch return error.QueryFailed;
            defer rows.deinit();
            while (rows.next() catch return error.QueryFailed) |row| {
                defer row.deinit(allocator);
                if (row.values.len < 5) continue;
                const input = colInt(row.values[2]);
                const read = colInt(row.values[3]);
                const with_cache = colInt(row.values[4]);
                models.append(allocator, .{
                    .model = try dupe(allocator, row.values[0]),
                    .calls = colInt(row.values[1]),
                    .input_tokens = input,
                    .calls_with_cache = with_cache,
                    .cache_hit_rate = reportedRate(read, input, with_cache),
                }) catch return error.OutOfMemory;
            }
        }
        {
            var rows = db.query(allocator, TOOL_TOTAL_SQL, &.{ workspace_id, cutoff }) catch return error.QueryFailed;
            defer rows.deinit();
            if (rows.next() catch return error.QueryFailed) |row| {
                defer row.deinit(allocator);
                if (row.values.len >= 1) totals.tool_calls = colInt(row.values[0]);
            }
        }
        {
            var rows = db.query(allocator, TOOLS_SQL, &.{ workspace_id, cutoff }) catch return error.QueryFailed;
            defer rows.deinit();
            while (rows.next() catch return error.QueryFailed) |row| {
                defer row.deinit(allocator);
                if (row.values.len < 2) continue;
                tools.append(allocator, .{
                    .tool_name = try dupe(allocator, row.values[0]),
                    .calls = colInt(row.values[1]),
                }) catch return error.OutOfMemory;
            }
        }
        {
            var rows = db.query(allocator, REASONS_SQL, &.{ workspace_id, cutoff }) catch return error.QueryFailed;
            defer rows.deinit();
            while (rows.next() catch return error.QueryFailed) |row| {
                defer row.deinit(allocator);
                if (row.values.len < 2) continue;
                const raw = row.values[0];
                reasons.append(allocator, .{
                    .reason = if (raw.len == 0) "none" else try dupe(allocator, raw),
                    .calls = colInt(row.values[1]),
                }) catch return error.OutOfMemory;
            }
        }

        var cached_session: ?[]const u8 = null;
        {
            var rows = db.query(allocator, LATEST_CACHED_SESSION_SQL, &.{ workspace_id, cutoff }) catch return error.QueryFailed;
            defer rows.deinit();
            if (rows.next() catch return error.QueryFailed) |row| {
                defer row.deinit(allocator);
                if (row.values.len >= 1 and row.values[0].len > 0) {
                    cached_session = try dupe(allocator, row.values[0]);
                }
            }
        }

        if (cached_session) |session_id| {
            var model_name: []const u8 = "";
            var total_calls: i64 = 0;
            var total_rate: ?f64 = null;
            {
                var rows = db.query(allocator, SERIES_META_SQL, &.{session_id}) catch return error.QueryFailed;
                defer rows.deinit();
                if (rows.next() catch return error.QueryFailed) |row| {
                    defer row.deinit(allocator);
                    if (row.values.len >= 4) {
                        model_name = try dupe(allocator, row.values[0]);
                        total_calls = colInt(row.values[1]);
                        total_rate = rateOf(colInt(row.values[3]), colInt(row.values[2]));
                    }
                }
            }
            {
                var rows = db.query(allocator, SERIES_SQL, &.{session_id}) catch return error.QueryFailed;
                defer rows.deinit();
                var index: i64 = 0;
                while (rows.next() catch return error.QueryFailed) |row| {
                    defer row.deinit(allocator);
                    if (row.values.len < 3) continue;
                    index += 1;
                    const input = colInt(row.values[1]);
                    const read = colInt(row.values[2]);
                    const clamped: i64 = if (read > input) 0 else read;
                    series_points.append(allocator, .{
                        .i = index,
                        .at = try dupe(allocator, row.values[0]),
                        .input_tokens = input,
                        .cache_read_tokens = clamped,
                        .rate = rateOf(clamped, input),
                    }) catch return error.OutOfMemory;
                }
            }
            series = .{
                .session_id = session_id,
                .model = model_name,
                .total_calls = total_calls,
                .cache_hit_rate = total_rate,
                .calls = series_points.items,
            };
        }
    }

    return std.json.Stringify.valueAlloc(allocator, WorkspaceUsageJson{
        .workspace_id = workspace_id,
        .range = range.label,
        .totals = totals,
        .daily = daily.items,
        .models = models.items,
        .tools = tools.items,
        .finish_reasons = reasons.items,
        .cache_series = series,
    }, .{}) catch return error.OutOfMemory;
}

pub fn workspaceUsageHandler(
    ctx: gserverz.HttpContext,
    req: gserverz.HttpRequest,
    res: gserverz.HttpResponse,
) !gserverz.HttpResponse {
    const allocator = ctx.allocator;

    const workspace_id = req.params.get("workspace_id") orelse "";
    if (workspace_id.len == 0) {
        return res.jsonResponse(.{
            .status_code = 400,
            .data = try http_response.makeErrorResponse(allocator, .{ .@"error" = "Missing workspace_id" }),
        });
    }

    const range = parseRange(req.query.get("range")) orelse {
        return res.jsonResponse(.{
            .status_code = 400,
            .data = try http_response.makeErrorResponse(allocator, .{ .@"error" = "range must be 7d, 30d or 90d" }),
        });
    };

    const di = try pabrikcore.getSingleton();

    gate.checkRequest(allocator, di.db, di.auth_enabled, req.headers, workspace_id, .read) catch |err| {
        return res.jsonResponse(.{
            .status_code = gate.statusFor(err),
            .data = try http_response.makeErrorResponse(allocator, .{ .@"error" = gate.messageFor(err) }),
        });
    };

    const now_ms = std.Io.Clock.now(.real, ctx.io).toMilliseconds();
    const cutoff_ns = (now_ms - range.days * 86_400_000) * 1_000_000;

    const body = useCase(allocator, di.db, workspace_id, range, cutoff_ns) catch |err| {
        const message: []const u8 = switch (err) {
            error.InvalidRange => "range must be 7d, 30d or 90d",
            error.QueryFailed => "Database query failed",
            error.OutOfMemory => "Out of memory",
        };
        const status: u16 = if (err == error.InvalidRange) 400 else 500;
        return res.jsonResponse(.{
            .status_code = status,
            .data = try http_response.makeErrorResponse(allocator, .{ .@"error" = message }),
        });
    };

    return res.jsonResponse(.{ .status_code = 200, .data = body });
}

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
    try test_db.openMemory(&db, io);

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
        \\  created_at_nano INTEGER NOT NULL DEFAULT 0,
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

const Row = struct {
    id: []const u8,
    session_id: []const u8,
    model: []const u8 = "m1",
    prompt: i64 = 0,
    completion: i64 = 0,
    read: i64 = 0,
    write: i64 = 0,
    at: i64 = 0,
    iso: []const u8 = "2026-10-20 10:00:00",
    tool: ?[]const u8 = null,
    reason: ?[]const u8 = null,
    role: []const u8 = "assistant",
};

fn insertWorkspace(ctx: *TestCtx, id: []const u8, workspace_id: []const u8) !void {
    const sql = try std.fmt.allocPrint(testing.allocator, "INSERT INTO sessions (id, workspace_id) VALUES ('{s}', '{s}')", .{ id, workspace_id });
    defer testing.allocator.free(sql);
    try ctx.db.exec(testing.allocator, sql, &.{});
}

fn insertRow(ctx: *TestCtx, r: Row) !void {
    const sql = try std.fmt.allocPrint(
        testing.allocator,
        "INSERT INTO llm_history (id, session_id, model, prompt_tokens, completion_tokens, cache_read_input_tokens, cache_creation_input_tokens, created_at_nano, created_iso, tool_name, finish_reason, role) " ++
            "VALUES ('{s}', '{s}', '{s}', {d}, {d}, {d}, {d}, {d}, '{s}', '{s}', '{s}', '{s}')",
        .{
            r.id,
            r.session_id,
            r.model,
            r.prompt,
            r.completion,
            r.read,
            r.write,
            r.at,
            r.iso,
            r.tool orelse "",
            r.reason orelse "",
            r.role,
        },
    );
    defer testing.allocator.free(sql);
    try ctx.db.exec(testing.allocator, sql, &.{});
}

fn run(ctx: *TestCtx, workspace_id: []const u8, range: Range, cutoff_ns: i64) !std.json.Parsed(std.json.Value) {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const json = try useCase(arena.allocator(), &ctx.db, workspace_id, range, cutoff_ns);
    return try std.json.parseFromSlice(std.json.Value, testing.allocator, json, .{});
}

fn num(value: std.json.Value) f64 {
    return switch (value) {
        .integer => |v| @floatFromInt(v),
        .float => |v| v,
        else => std.math.nan(f64),
    };
}

fn expectRate(expected: f64, actual: std.json.Value) !void {
    try testing.expectEqual(expected, num(actual));
}

fn at(json: std.json.Value, comptime path: []const u8) std.json.Value {
    var current = json;
    var it = std.mem.splitScalar(u8, path, '.');
    while (it.next()) |key| {
        current = current.object.get(key) orelse {
            std.debug.print("\n!! {s} is not in the payload !!\n", .{key});
            return .null;
        };
    }
    return current;
}

test "parseRange accepts the three ranges, defaults to 30d, and rejects the rest" {
    try testing.expectEqual(@as(i64, 7), parseRange("7d").?.days);
    try testing.expectEqual(@as(i64, 30), parseRange("30d").?.days);
    try testing.expectEqual(@as(i64, 90), parseRange("90d").?.days);
    try testing.expectEqualStrings("30d", parseRange(null).?.label);
    try testing.expectEqualStrings("30d", parseRange("").?.label);
    try testing.expect(parseRange("30") == null);
    try testing.expect(parseRange("1y") == null);
    try testing.expect(parseRange("7D") == null);
}

test "the empty workspace answers zeros and a null rate, never a fabricated 0%" {
    var ctx = try setupDb();
    defer teardown(&ctx);

    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const json = try useCase(arena.allocator(), &ctx.db, "ws_none", .{ .days = 30, .label = "30d" }, 0);

    try testing.expectEqualStrings(
        "{\"workspace_id\":\"ws_none\",\"range\":\"30d\",\"totals\":{\"calls\":0,\"sessions\":0,\"input_tokens\":0," ++
            "\"output_tokens\":0,\"cache_read_tokens\":0,\"cache_creation_tokens\":0,\"calls_with_cache\":0," ++
            "\"excluded_calls\":0,\"tool_calls\":0,\"cache_hit_rate\":null},\"daily\":[],\"models\":[],\"tools\":[]," ++
            "\"finish_reasons\":[],\"cache_series\":null}",
        json,
    );
}

test "totals sum only this workspace and only calls inside the range" {
    var ctx = try setupDb();
    defer teardown(&ctx);
    try insertWorkspace(&ctx, "s1", "ws_a");
    try insertWorkspace(&ctx, "s2", "ws_b");

    try insertRow(&ctx, .{ .id = "a1", .session_id = "s1", .prompt = 1000, .completion = 10, .read = 900, .at = 2000 });
    try insertRow(&ctx, .{ .id = "a2", .session_id = "s1", .prompt = 1000, .completion = 20, .read = 0, .at = 2000 });
    try insertRow(&ctx, .{ .id = "b1", .session_id = "s2", .prompt = 5000, .completion = 50, .read = 4000, .at = 2000 });
    try insertRow(&ctx, .{ .id = "a0", .session_id = "s1", .prompt = 7000, .completion = 70, .read = 6000, .at = 10 });

    const parsed = try run(&ctx, "ws_a", .{ .days = 30, .label = "30d" }, 1000);
    defer parsed.deinit();

    try testing.expectEqual(@as(i64, 2), at(parsed.value, "totals.calls").integer);
    try testing.expectEqual(@as(i64, 2000), at(parsed.value, "totals.input_tokens").integer);
    try testing.expectEqual(@as(i64, 30), at(parsed.value, "totals.output_tokens").integer);
    try testing.expectEqual(@as(i64, 900), at(parsed.value, "totals.cache_read_tokens").integer);
    try testing.expectEqual(@as(i64, 1), at(parsed.value, "totals.calls_with_cache").integer);
    try testing.expectEqual(@as(i64, 1), at(parsed.value, "totals.sessions").integer);
    try expectRate(45, at(parsed.value, "totals.cache_hit_rate"));
    try testing.expectEqual(@as(i64, 0), at(parsed.value, "totals.excluded_calls").integer);
}

test "a cache read larger than its prompt is excluded from the numerator, the denominator and the claim" {
    var ctx = try setupDb();
    defer teardown(&ctx);
    try insertWorkspace(&ctx, "s1", "ws_a");

    try insertRow(&ctx, .{ .id = "ok", .session_id = "s1", .prompt = 1000, .read = 500, .at = 2000 });
    try insertRow(&ctx, .{ .id = "bad", .session_id = "s1", .prompt = 17932, .read = 114048, .at = 2000 });

    const parsed = try run(&ctx, "ws_a", .{ .days = 30, .label = "30d" }, 1000);
    defer parsed.deinit();

    try testing.expectEqual(@as(i64, 2), at(parsed.value, "totals.calls").integer);
    try testing.expectEqual(@as(i64, 1), at(parsed.value, "totals.excluded_calls").integer);
    try testing.expectEqual(@as(i64, 1000), at(parsed.value, "totals.input_tokens").integer);
    try testing.expectEqual(@as(i64, 500), at(parsed.value, "totals.cache_read_tokens").integer);
    try expectRate(50, at(parsed.value, "totals.cache_hit_rate"));
}

test "daily, models, tools and finish reasons stay under eight rows and keep their order" {
    var ctx = try setupDb();
    defer teardown(&ctx);
    try insertWorkspace(&ctx, "s1", "ws_a");

    try insertRow(&ctx, .{ .id = "r1", .session_id = "s1", .model = "big", .prompt = 900, .read = 800, .iso = "2026-10-20 10:00:00", .reason = "tool_calls", .at = 2000 });
    try insertRow(&ctx, .{ .id = "r2", .session_id = "s1", .model = "big", .prompt = 100, .read = 0, .iso = "2026-10-21 10:00:00", .reason = "tool_calls", .at = 2000 });
    try insertRow(&ctx, .{ .id = "r3", .session_id = "s1", .model = "small", .prompt = 50, .read = 0, .iso = "2026-10-21 11:00:00", .reason = null, .at = 2000 });
    try insertRow(&ctx, .{ .id = "t1", .session_id = "s1", .role = "tool", .tool = "command", .iso = "2026-10-21 10:00:01", .at = 2000 });
    try insertRow(&ctx, .{ .id = "t2", .session_id = "s1", .role = "tool", .tool = "command", .iso = "2026-10-21 10:00:02", .at = 2000 });
    try insertRow(&ctx, .{ .id = "t3", .session_id = "s1", .role = "tool", .tool = "read_file", .iso = "2026-10-21 10:00:03", .at = 2000 });
    try insertRow(&ctx, .{ .id = "u1", .session_id = "s1", .role = "user", .iso = "2026-10-21 10:00:00", .at = 2000 });

    const parsed = try run(&ctx, "ws_a", .{ .days = 30, .label = "30d" }, 1000);
    defer parsed.deinit();

    const daily = at(parsed.value, "daily").array;
    try testing.expectEqual(@as(usize, 2), daily.items.len);
    try testing.expectEqualStrings("2026-10-20", daily.items[0].object.get("day").?.string);
    try expectRate(88.89, daily.items[0].object.get("cache_hit_rate").?);

    const models = at(parsed.value, "models").array;
    try testing.expectEqual(@as(usize, 2), models.items.len);
    try testing.expectEqualStrings("big", models.items[0].object.get("model").?.string);
    try testing.expectEqual(@as(i64, 1000), models.items[0].object.get("input_tokens").?.integer);
    try testing.expectEqual(@as(i64, 1), models.items[0].object.get("calls_with_cache").?.integer);
    try expectRate(80, models.items[0].object.get("cache_hit_rate").?);
    try testing.expectEqual(std.json.Value.null, models.items[1].object.get("cache_hit_rate").?);

    try testing.expectEqual(@as(i64, 3), at(parsed.value, "totals.tool_calls").integer);

    const tools = at(parsed.value, "tools").array;
    try testing.expectEqual(@as(usize, 2), tools.items.len);
    try testing.expectEqualStrings("command", tools.items[0].object.get("tool_name").?.string);
    try testing.expectEqual(@as(i64, 2), tools.items[0].object.get("calls").?.integer);

    const reasons = at(parsed.value, "finish_reasons").array;
    try testing.expectEqual(@as(usize, 2), reasons.items.len);
    try testing.expectEqualStrings("tool_calls", reasons.items[0].object.get("reason").?.string);
    try testing.expectEqual(@as(i64, 2), reasons.items[0].object.get("calls").?.integer);
    try testing.expectEqualStrings("none", reasons.items[1].object.get("reason").?.string);
}

test "cache_series is the most recent session that reported cache, with its own rate" {
    var ctx = try setupDb();
    defer teardown(&ctx);
    try insertWorkspace(&ctx, "old", "ws_a");
    try insertWorkspace(&ctx, "new", "ws_a");

    try insertRow(&ctx, .{ .id = "o1", .session_id = "old", .model = "m-old", .prompt = 100, .read = 50, .at = 1000 });
    try insertRow(&ctx, .{ .id = "n1", .session_id = "new", .model = "m-new", .prompt = 1000, .read = 0, .at = 5000 });
    try insertRow(&ctx, .{ .id = "n2", .session_id = "new", .model = "m-new", .prompt = 1000, .read = 950, .at = 5001 });

    const parsed = try run(&ctx, "ws_a", .{ .days = 30, .label = "30d" }, 0);
    defer parsed.deinit();

    const series = at(parsed.value, "cache_series");
    try testing.expectEqualStrings("new", series.object.get("session_id").?.string);
    try testing.expectEqualStrings("m-new", series.object.get("model").?.string);
    try testing.expectEqual(@as(i64, 2), series.object.get("total_calls").?.integer);
    try expectRate(47.5, series.object.get("cache_hit_rate").?);

    const calls = series.object.get("calls").?.array;
    try testing.expectEqual(@as(usize, 2), calls.items.len);
    try testing.expectEqual(@as(i64, 1), calls.items[0].object.get("i").?.integer);
    try expectRate(0, calls.items[0].object.get("rate").?);
    try expectRate(95, calls.items[1].object.get("rate").?);
}

test "a workspace with calls but no cache counter reports a null rate and no series" {
    var ctx = try setupDb();
    defer teardown(&ctx);
    try insertWorkspace(&ctx, "s1", "ws_a");
    try insertRow(&ctx, .{ .id = "r1", .session_id = "s1", .prompt = 4000, .read = 0, .at = 2000 });

    const parsed = try run(&ctx, "ws_a", .{ .days = 30, .label = "30d" }, 1000);
    defer parsed.deinit();

    try testing.expectEqual(@as(i64, 1), at(parsed.value, "totals.calls").integer);
    try testing.expectEqual(std.json.Value.null, at(parsed.value, "totals.cache_hit_rate"));
    try testing.expectEqual(std.json.Value.null, at(parsed.value, "cache_series"));
}
