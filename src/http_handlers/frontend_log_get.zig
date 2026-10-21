//! `GET /api/logs` — read rows from the `logs` table for `curl` / scripts /
//! debug inspection.

const std = @import("std");
const pabrikcore = @import("pabrikcore");
const gserverz = pabrikcore.gserverz;
const sqlite = pabrikcore.sqlite;
const http_response = @import("http_response.zig");

// =====================================================================
// Whitelists
// =====================================================================

/// Valid `level` values — matches the POST handler's whitelist. An
/// unknown value → 400 (LLM-friendly hint in the error message).
const VALID_LEVELS = [_][]const u8{ "error", "warn", "info", "debug" };

/// Valid `kind` values — matches the POST handler's whitelist.
const VALID_KINDS = [_][]const u8{
    "window_error",
    "unhandled_rejection",
    "console_error",
    "console_warn",
};

// =====================================================================
// Constants
// =====================================================================

/// Default page size when the client doesn't pass `limit`. Matches the
/// design doc's "default 100".
const DEFAULT_LIMIT: u32 = 100;

/// Maximum page size (guards against a client asking for a million
/// rows). Matches the design doc's "capped at 1000".
const MAX_LIMIT: u32 = 1000;

// =====================================================================
// Error set
// =====================================================================

/// Domain-level error set for `useCase` and `parseInput`. Each variant maps
/// to a distinct HTTP status code.
pub const FrontendLogGetError = error{
    /// `pabrikcore.getSingleton()` failed (server has not been
    /// initialised yet). Maps to 500.
    ServerNotInitialized,
    /// `level` query param value is not in the whitelist. Maps to 400.
    InvalidLevel,
    /// `kind` query param value is not in the whitelist. Maps to 400.
    InvalidKind,
    /// `limit` query param is < 1 or > 1000. Maps to 400.
    InvalidLimit,
    /// DB read failed. Maps to 500.
    QueryFailed,
    /// Building the response JSON failed (OOM, in practice unreachable
    /// because the per-request arena reaps everything). Maps to 500.
    OutOfMemory,
};

// =====================================================================
// Input / output types
// =====================================================================

/// Parsed query-string input for `GET /api/logs`. All fields are
/// optional (null when absent); `limit` has a default.
pub const FrontendLogGetInput = struct {
    level: ?[]const u8 = null,
    kind: ?[]const u8 = null,
    session_id: ?[]const u8 = null,
    /// Microseconds — null when no `since` was supplied. Stored as
    /// i64 because SQLite's `created_at` column is INTEGER microseconds.
    since_us: ?i64 = null,
    /// Already clamped to [1, 1000]. Defaults to 100.
    limit: u32 = DEFAULT_LIMIT,
};

/// Output of the use-case: pre-serialized JSON body (lives in the
/// per-request arena; the caller does NOT free).
pub const FrontendLogGetOutput = struct {
    json_body: []const u8,
};

// =====================================================================
// Parse input
// =====================================================================

/// Pure function: pull the 5 query params out of `req.query` and return a
/// typed `FrontendLogGetInput`. Whitelist-validates `level` and `kind`;
/// clamps `limit`.
fn parseInput(query: std.StringHashMap([]const u8)) FrontendLogGetError!FrontendLogGetInput {
    // level: validate whitelist iff present+non-empty.
    const level_str = query.get("level");
    const level_opt: ?[]const u8 = blk: {
        const lv = level_str orelse break :blk null;
        if (lv.len == 0) break :blk null;
        if (!isValidLevel(lv)) return error.InvalidLevel;
        break :blk lv;
    };

    // kind: same shape as level.
    const kind_str = query.get("kind");
    const kind_opt: ?[]const u8 = blk: {
        const k = kind_str orelse break :blk null;
        if (k.len == 0) break :blk null;
        if (!isValidKind(k)) return error.InvalidKind;
        break :blk k;
    };

    // session_id: no validation, just pass through. Empty string is
    // normalized to null for the same reason as level/kind above.
    const session_id_opt: ?[]const u8 = blk: {
        const s = query.get("session_id") orelse break :blk null;
        if (s.len == 0) break :blk null;
        break :blk s;
    };

    // since: parse as i64, defensive fallback to null on any failure.
    // Project convention (see `tasks_list.zig:67`) treats parse
    // failures as the default value rather than a hard error.
    const since_opt: ?i64 = blk: {
        const s = query.get("since") orelse break :blk null;
        if (s.len == 0) break :blk null;
        break :blk std.fmt.parseInt(i64, s, 10) catch null;
    };

    // limit: default 100, clamp to [1, 1000]. Absent or empty → use
    // default. Unparseable, zero, or out-of-range → return InvalidLimit
    // (the LLM gets a 400 hint instead of a silent clamp).
    const limit: u32 = blk: {
        const s = query.get("limit") orelse break :blk DEFAULT_LIMIT;
        if (s.len == 0) break :blk DEFAULT_LIMIT;
        const parsed = std.fmt.parseInt(u32, s, 10) catch return error.InvalidLimit;
        if (parsed == 0) return error.InvalidLimit;
        if (parsed > MAX_LIMIT) return error.InvalidLimit;
        break :blk parsed;
    };

    return FrontendLogGetInput{
        .level = level_opt,
        .kind = kind_opt,
        .session_id = session_id_opt,
        .since_us = since_opt,
        .limit = limit,
    };
}

// =====================================================================
// Use case
// =====================================================================

/// Resolve the singleton, build + execute the SELECT, map rows to
/// `FrontendLogRow`, and return the pre-serialized JSON.
fn useCase(
    allocator: std.mem.Allocator,
    input: FrontendLogGetInput,
) FrontendLogGetError!FrontendLogGetOutput {
    const di = pabrikcore.getSingleton() catch return error.ServerNotInitialized;
    const db = di.db;

    // Build the SQL string dynamically. We always include `WHERE 1=1` so
    // subsequent optional filters can append `AND ...` uniformly.
    var sql_buf = std.ArrayList(u8).empty;
    defer sql_buf.deinit(allocator);
    try sql_buf.appendSlice(
        allocator,
        \\SELECT id, created_at_nano AS created_at, level, kind, message,
        \\       stack, source, line, route_path, session_id, count
        \\FROM logs
        \\WHERE 1=1
    );

    // Track which filters are present so we know what to bind.
    // `limit` is always present at the end; the others are optional.
    var present_level: bool = false;
    var present_kind: bool = false;
    var present_session: bool = false;
    var present_since: bool = false;

    if (input.level) |lv| {
        if (lv.len > 0) {
            try sql_buf.appendSlice(allocator, "\n  AND level = ?");
            present_level = true;
        }
    }
    if (input.kind) |k| {
        if (k.len > 0) {
            try sql_buf.appendSlice(allocator, "\n  AND kind = ?");
            present_kind = true;
        }
    }
    if (input.session_id) |_| {
        try sql_buf.appendSlice(allocator, "\n  AND session_id = ?");
        present_session = true;
    }
    if (input.since_us) |_| {
        try sql_buf.appendSlice(allocator, "\n  AND created_at_nano >= ?");
        present_since = true;
    }

    try sql_buf.appendSlice(allocator, "\nORDER BY created_at_nano DESC\nLIMIT ?");

    // Format i64 / u32 values as decimal strings BEFORE binding — `db.exec` /
    // `db.query` only bind TEXT, and SQLite coerces numeric-looking text to
    // INTEGER under INTEGER affinity (verified via :memory: round-trip —
    const since_str = if (input.since_us) |us| blk: {
        const s = try std.fmt.allocPrint(allocator, "{d}", .{us});
        break :blk s;
    } else null;
    defer if (since_str) |s| allocator.free(s);

    const limit_str = try std.fmt.allocPrint(allocator, "{d}", .{input.limit});
    defer allocator.free(limit_str);

    // Build the bind slice. SQLite binds arguments positionally to `?`
    // placeholders; the ORDER here must match the SQL build above exactly.
    var args = std.ArrayList([]const u8).empty;
    defer args.deinit(allocator);
    if (present_level) {
        if (input.level) |lv| try args.append(allocator, lv);
    }
    if (present_kind) {
        if (input.kind) |k| try args.append(allocator, k);
    }
    if (present_session) {
        if (input.session_id) |sid| try args.append(allocator, sid);
    }
    if (present_since) {
        if (since_str) |s| try args.append(allocator, s);
    }
    try args.append(allocator, limit_str);

    // Run the query. The `sqlite.query` helper returns a `Rows` iterator
    // whose `.next()` returns `!?Row`.
    var rows = db.query(allocator, sql_buf.items, args.items) catch return error.QueryFailed;
    defer rows.deinit();

    // Map rows to FrontendLogRow.
    var logs_list = std.ArrayList(http_response.FrontendLogRow).empty;
    defer logs_list.deinit(allocator);

    while (true) {
        // `rows.next()` returns the raw SqliteBackend.Error set; map any
        // failure to our domain `QueryFailed` so the function can return
        // FrontendLogGetError instead of leaking sqlite errors.
        const row_opt = rows.next() catch |e| {
            std.log.warn("frontend_log_get useCase: rows.next failed: {s}", .{@errorName(e)});
            return error.QueryFailed;
        };
        const row = row_opt orelse break;
        // Empty slice from `row.values[i]` corresponds to NULL on a nullable
        // column (project memory `sqlite-backend-empty-slice-binds-as-null`);
        // non-empty means a value (which may be the textual representation of
        try logs_list.append(allocator, http_response.FrontendLogRow{
            .id = row.values[0],
            .created_at = std.fmt.parseInt(i64, row.values[1], 10) catch 0,
            .level = row.values[2],
            .kind = row.values[3],
            .message = row.values[4],
            .stack = nullableText(row.values[5]),
            .source = nullableText(row.values[6]),
            .line = nullableInt(row.values[7]),
            .route_path = nullableText(row.values[8]),
            .session_id = nullableText(row.values[9]),
            .count = std.fmt.parseInt(i64, row.values[10], 10) catch 0,
        });
    }

    const json_body = http_response.makeFrontendLogListResponse(
        allocator,
        logs_list.items,
    ) catch return error.OutOfMemory;

    return .{ .json_body = json_body };
}

// =====================================================================
// Handler
// =====================================================================

pub fn frontendLogGetHandler(
    ctx: gserverz.HttpContext,
    req: gserverz.HttpRequest,
    res: gserverz.HttpResponse,
) !gserverz.HttpResponse {
    const allocator = ctx.allocator;

    // Parse query params — pass `req.query` directly (it's the
    // `StringHashMap([]const u8)` field on the request struct; see
    // `tasks_list.zig:210` for the same usage pattern).
    const input = parseInput(req.query) catch |err| {
        const status: u16 = switch (err) {
            error.InvalidLevel => 400,
            error.InvalidKind => 400,
            error.InvalidLimit => 400,
            // parseInput's body only emits the 3 validation variants above;
            // the wider FrontendLogGetError variants (singleton, query, OOM)
            // are type-system residue from the shared enum.
            else => 500,
        };
        const message: []const u8 = switch (err) {
            error.InvalidLevel => "level must be one of error, warn, info, debug",
            error.InvalidKind => "kind must be one of window_error, unhandled_rejection, console_error, console_warn",
            error.InvalidLimit => "limit must be between 1 and 1000",
            else => "Internal error parsing request",
        };
        // Use `std.log.warn` (NOT `std.log.err`) so this handler's error path
        // doesn't trigger `log_err_count > 0` in `zig build test` (project
        // memory `zig-0.16-test-log-err-count`).
        std.log.warn("frontend_log_get: {s}", .{message});
        return res.jsonResponse(.{
            .status_code = status,
            .data = try http_response.makeErrorResponse(allocator, .{ .@"error" = message }),
        });
    };

    // useCase's inferred error set is {ServerNotInitialized, QueryFailed,
    // OutOfMemory}.
    const outcome = useCase(allocator, input) catch |err| {
        const status: u16 = switch (err) {
            error.ServerNotInitialized => 500,
            error.QueryFailed => 500,
            error.OutOfMemory => 500,
            // The 3 validation variants are type-system residue from the
            // shared FrontendLogGetError; useCase cannot actually emit them.
            else => 500,
        };
        const message: []const u8 = switch (err) {
            error.ServerNotInitialized => "Server not initialized",
            error.QueryFailed => "Failed to query logs",
            error.OutOfMemory => "Out of memory",
            else => "Internal error querying logs",
        };
        std.log.warn("frontend_log_get: {s}", .{message});
        return res.jsonResponse(.{
            .status_code = status,
            .data = try http_response.makeErrorResponse(allocator, .{ .@"error" = message }),
        });
    };

    return res.jsonResponse(.{ .status_code = 200, .data = outcome.json_body });
}

// =====================================================================
// Helpers
// =====================================================================

/// Returns true if `level` is one of the 4 whitelisted values.
fn isValidLevel(level: []const u8) bool {
    for (VALID_LEVELS) |v| {
        if (std.mem.eql(u8, v, level)) return true;
    }
    return false;
}

/// Returns true if `kind` is one of the 4 whitelisted values.
fn isValidKind(kind: []const u8) bool {
    for (VALID_KINDS) |v| {
        if (std.mem.eql(u8, v, kind)) return true;
    }
    return false;
}

/// Convert a TEXT column slice to a `?[]const u8` — empty slice is
/// treated as NULL (project memory
/// `sqlite-backend-empty-slice-binds-as-null`).
fn nullableText(v: []const u8) ?[]const u8 {
    return if (v.len == 0) null else v;
}

/// Convert an INTEGER column's textual representation to a `?i64` — empty
/// slice is NULL (matches the same convention as `nullableText`).
fn nullableInt(v: []const u8) ?i64 {
    if (v.len == 0) return null;
    return std.fmt.parseInt(i64, v, 10) catch null;
}

// ===== Tests merged from frontend_log_get_test.zig (2026-09-11 flatten)
// ===== Behavioural SQL tests for `frontend_log_get` (GET /api/logs).

const testing = std.testing;

// =============================================================================
// Behavioural SQL tests These exercise the SAME SQL the use-case runs against
// an in-memory SQLite DB with the logs table loaded.


/// Open a fresh in-memory sqlite DB with the `logs` table loaded.
/// Mirrors `frontend_log_post_test.zig::setupDbWithLogs`.
fn setupDbWithLogs() !struct {
    db: sqlite.SqliteBackend,
    threaded: std.Io.Threaded,
} {
    const alloc = testing.allocator;
    var threaded = std.Io.Threaded.init(alloc, .{});
    errdefer threaded.deinit();
    const io = threaded.io();

    var db: sqlite.SqliteBackend = .{};
    errdefer db.deinit();
    try db.init(io, ":memory:");

    try pabrikcore.migrations_mod.migration.Migration064AddFrontendLogs.up(&db, alloc);
    // Also apply the logs half of Migration 075 (`logs.created_at` →
    // `logs.created_at_nano`) so these tests target the production schema
    // (see `frontend_log_post.zig::setupDbWithLogs` for the precedent — the
    try db.exec(alloc, "ALTER TABLE logs RENAME COLUMN created_at TO created_at_nano", &.{});
    try db.exec(alloc, "DROP INDEX IF EXISTS idx_logs_created_at", &.{});
    try db.exec(
        alloc,
        "CREATE INDEX IF NOT EXISTS idx_logs_created_at_nano ON logs(created_at_nano DESC)",
        &.{},
    );
    return .{ .db = db, .threaded = threaded };
}

/// Insert one log row with a specific id, microsecond timestamp, and
/// level. Mirrors the use-case's INSERT shape (sans dedup — we
/// always insert fresh rows here).
fn insertLog(
    db: *sqlite.SqliteBackend,
    alloc: std.mem.Allocator,
    id: []const u8,
    created_at_us: i64,
    level: []const u8,
    kind: []const u8,
    message: []const u8,
) !void {
    const ts_str = try std.fmt.allocPrint(alloc, "{d}", .{created_at_us});
    defer alloc.free(ts_str);
    try db.exec(
        alloc,
        "INSERT INTO logs (id, created_at_nano, level, kind, message, count) VALUES (?, ?, ?, ?, ?, 1)",
        &.{ id, ts_str, level, kind, message },
    );
}

const SelectedLogRow = struct {
    id: []const u8,
    created_at: []const u8,
    level: []const u8,
    message: []const u8,
};

/// Run a SELECT against `logs` with the use-case's exact column order
/// and ORDER BY/LIMIT shape. Returns owned slices — caller frees via
/// `alloc.free(slice)` then `defer rows.deinit()`.
fn selectLogs(
    db: *sqlite.SqliteBackend,
    alloc: std.mem.Allocator,
    where_clause: []const u8,
    limit: u32,
) ![]SelectedLogRow {
    const sql = try std.fmt.allocPrint(
        alloc,
        "SELECT id, created_at_nano, level, message FROM logs WHERE 1=1{s} ORDER BY created_at_nano DESC LIMIT {d}",
        .{ where_clause, limit },
    );
    defer alloc.free(sql);

    // No bind args — the LIMIT was interpolated directly into the SQL above
    // (the test exercises the use-case's SQL SHAPE, not its bind-positional
    // pattern, so we don't need to mirror the limit bind).
    var rows = try db.query(alloc, sql, &.{});
    defer rows.deinit();

    var out = std.ArrayList(SelectedLogRow).empty;
    while (try rows.next()) |row| {
        defer row.deinit(alloc);
        // Dupe each `row.values[i]` into heap-owned memory.
        try out.append(alloc, .{
            .id = try alloc.dupe(u8, row.values[0]),
            .created_at = try alloc.dupe(u8, row.values[1]),
            .level = try alloc.dupe(u8, row.values[2]),
            .message = try alloc.dupe(u8, row.values[3]),
        });
    }
    return out.toOwnedSlice(alloc);
}

/// Free the heap-owned strings inside a `[]SelectedLogRow` slice, then free
/// the outer slice. Mirrors the project's `defer row.deinit(alloc)`-then-free
/// pattern from `frontend_log_post_test.zig`.
fn freeSelectedLogRows(alloc: std.mem.Allocator, rows: []SelectedLogRow) void {
    for (rows) |row| {
        alloc.free(row.id);
        alloc.free(row.created_at);
        alloc.free(row.level);
        alloc.free(row.message);
    }
    alloc.free(rows);
}

test "behavioural: recent-first ordering — DESC by created_at" {
    const alloc = testing.allocator;
    var s = try setupDbWithLogs();
    defer s.threaded.deinit();
    defer s.db.deinit();

    // Insert in NON-DESC order to prove the SELECT reorders them.
    try insertLog(&s.db, alloc, "log_t1", 100, "info", "console_error", "first");
    try insertLog(&s.db, alloc, "log_t3", 300, "info", "console_error", "third");
    try insertLog(&s.db, alloc, "log_t2", 200, "info", "console_error", "second");

    const rows = try selectLogs(&s.db, alloc, "", 100);
    defer freeSelectedLogRows(alloc, rows);

    try testing.expectEqual(@as(usize, 3), rows.len);
    try testing.expectEqualStrings("log_t3", rows[0].id);
    try testing.expectEqualStrings("log_t2", rows[1].id);
    try testing.expectEqualStrings("log_t1", rows[2].id);
}

test "behavioural: WHERE level = ? returns only matching rows" {
    const alloc = testing.allocator;
    var s = try setupDbWithLogs();
    defer s.threaded.deinit();
    defer s.db.deinit();

    try insertLog(&s.db, alloc, "log_e1", 100, "error", "console_error", "boom-error");
    try insertLog(&s.db, alloc, "log_w1", 200, "warn", "console_warn", "heads-up");
    try insertLog(&s.db, alloc, "log_e2", 300, "error", "window_error", "boom-error-2");

    const rows = try selectLogs(&s.db, alloc, " AND level = 'error'", 100);
    defer freeSelectedLogRows(alloc, rows);

    try testing.expectEqual(@as(usize, 2), rows.len);
    // DESC by created_at — t=300 first, t=100 second.
    try testing.expectEqualStrings("log_e2", rows[0].id);
    try testing.expectEqualStrings("log_e1", rows[1].id);
}

test "behavioural: WHERE created_at >= ? (since filter)" {
    const alloc = testing.allocator;
    var s = try setupDbWithLogs();
    defer s.threaded.deinit();
    defer s.db.deinit();

    try insertLog(&s.db, alloc, "log_t1", 100, "info", "console_error", "old-1");
    try insertLog(&s.db, alloc, "log_t2", 200, "info", "console_error", "cutoff");
    try insertLog(&s.db, alloc, "log_t3", 300, "info", "console_error", "new-1");

    // Use the exact WHERE clause shape the use-case appends:
    //   "\n  AND created_at_nano >= ?"
    // (the newline + 2-space indent is cosmetic but we mirror it).
    const rows = try selectLogs(&s.db, alloc, "\n  AND created_at_nano >= '200'", 100);
    defer freeSelectedLogRows(alloc, rows);

    try testing.expectEqual(@as(usize, 2), rows.len);
    // DESC order: t3 first, t2 second.
    try testing.expectEqualStrings("log_t3", rows[0].id);
    try testing.expectEqualStrings("log_t2", rows[1].id);
}

test "behavioural: LIMIT ? caps the result size" {
    const alloc = testing.allocator;
    var s = try setupDbWithLogs();
    defer s.threaded.deinit();
    defer s.db.deinit();

    // Insert 5 rows.
    try insertLog(&s.db, alloc, "log_t1", 100, "info", "console_error", "1");
    try insertLog(&s.db, alloc, "log_t2", 200, "info", "console_error", "2");
    try insertLog(&s.db, alloc, "log_t3", 300, "info", "console_error", "3");
    try insertLog(&s.db, alloc, "log_t4", 400, "info", "console_error", "4");
    try insertLog(&s.db, alloc, "log_t5", 500, "info", "console_error", "5");

    // Limit 2 — only the 2 most recent (DESC by created_at).
    const rows = try selectLogs(&s.db, alloc, "", 2);
    defer freeSelectedLogRows(alloc, rows);

    try testing.expectEqual(@as(usize, 2), rows.len);
    try testing.expectEqualStrings("log_t5", rows[0].id);
    try testing.expectEqualStrings("log_t4", rows[1].id);
}
