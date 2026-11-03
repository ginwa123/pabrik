//! `POST /api/logs` — persist a frontend error event to the `logs` table.

const std = @import("std");
const pabrikcore = @import("pabrikcore");
const test_db = pabrikcore.test_db;
const gserverz = pabrikcore.gserverz;
const sqlite = pabrikcore.sqlite;
const database = pabrikcore.database;
const http_response = @import("http_response.zig");

/// JSON request body for `POST /api/logs`.
const FrontendLogBody = struct {
    events: []const FrontendLogEvent = &.{},

    pub const FrontendLogEvent = struct {
        level: []const u8,
        kind: []const u8,
        message: []const u8,
        stack: ?[]const u8 = null,
        source: ?[]const u8 = null,
        line: ?i64 = null,
        route_path: ?[]const u8 = null,
        session_id: ?[]const u8 = null,
    };
};

/// Domain-level error set for `useCase`. Each variant maps to a distinct HTTP
/// status code.
pub const FrontendLogPostError = error{
    /// `getSingleton()` failed — server not initialised. Maps to 500.
    ServerNotInitialized,
    /// Generated log id couldn't be allocated (OOM). Maps to 500.
    IdAllocationFailed,
    /// `level` field missing. Maps to 400.
    MissingLevel,
    /// `level` value is not in the whitelist. Maps to 400.
    InvalidLevel,
    /// `kind` field missing. Maps to 400.
    MissingKind,
    /// `kind` value is not in the whitelist. Maps to 400.
    InvalidKind,
    /// `message` field missing or empty. Maps to 400.
    MissingMessage,
    /// DB read (dedup SELECT) failed. Maps to 500.
    DedupQueryFailed,
    /// DB write (UPDATE or INSERT) failed. Maps to 500.
    PersistFailed,
};

// =====================================================================
// Whitelists
// =====================================================================

/// Valid `level` values. Anything else → 400.
const VALID_LEVELS = [_][]const u8{ "error", "warn", "info", "debug" };

/// Valid `kind` values. Anything else → 400.
const VALID_KINDS = [_][]const u8{
    "window_error",
    "unhandled_rejection",
    "console_error",
    "console_warn",
};

// =====================================================================
// Use case
// =====================================================================

fn useCase(
    allocator: std.mem.Allocator,
    db: *database.Db,
    body: FrontendLogBody.FrontendLogEvent,
) FrontendLogPostError!void {
    return useCaseAt(allocator, db, body, microsecondsNow());
}

/// `useCase` with the clock injected, so the 1-second dedup window is
/// something a test sets rather than something it races.
fn useCaseAt(
    allocator: std.mem.Allocator,
    db: *database.Db,
    body: FrontendLogBody.FrontendLogEvent,
    now_us: i64,
) FrontendLogPostError!void {
    if (body.level.len == 0) return error.MissingLevel;
    if (!isValidLevel(body.level)) return error.InvalidLevel;
    if (body.kind.len == 0) return error.MissingKind;
    if (!isValidKind(body.kind)) return error.InvalidKind;
    if (body.message.len == 0) return error.MissingMessage;

    // Capped BEFORE the dedup key is read, because the stored message IS the
    // key: two 40 KB events that differ only past byte 8192 are one event here.
    const capped = capMessage(body.message);

    // Row id = "log_<microseconds>". Allocates from the per-request
    // arena (the caller's `allocator`); freed at scope exit. On OOM,
    // surface 500 — the caller has no fallback id source.
    const id = idForRow(allocator) catch return error.IdAllocationFailed;
    defer allocator.free(id);

    // `db.exec` only binds text — integer values must be formatted as decimal
    // strings before binding.
    const now_us_str = std.fmt.allocPrint(allocator, "{d}", .{now_us}) catch return error.IdAllocationFailed;
    defer allocator.free(now_us_str);
    const dedup_cutoff_str = std.fmt.allocPrint(allocator, "{d}", .{now_us - 1_000_000}) catch return error.IdAllocationFailed;
    defer allocator.free(dedup_cutoff_str);
    const line_str = std.fmt.allocPrint(allocator, "{d}", .{body.line orelse 0}) catch return error.IdAllocationFailed;
    defer allocator.free(line_str);

    // Dedup check: same kind + message + stack within the last 1 second. The
    // `COALESCE(stack,'') = COALESCE(?,'')` form treats NULL and "" as equivalent
    // dedup keys (matches the design doc contract).
    const dedup_sql =
        \\SELECT id FROM logs
        \\WHERE kind = ?
        \\  AND message = ?
        \\  AND COALESCE(stack,'') = COALESCE(?,'')
        \\  AND created_at_nano >= ?
        \\LIMIT 1
    ;
    var dedup_rows = db.query(
        allocator,
        dedup_sql,
        &.{
            body.kind,
            capped.text,
            body.stack orelse "",
            dedup_cutoff_str,
        },
    ) catch return error.DedupQueryFailed;
    defer dedup_rows.deinit();

    if (dedup_rows.next() catch |e| {
        std.log.warn("frontend_log_post useCase: dedup_rows.next failed: {s}", .{@errorName(e)});
        return error.DedupQueryFailed;
    }) |dedup_row| {
        defer dedup_row.deinit(allocator);
        // Existing row matches the dedup key. Increment its count
        // and return — no second row is created.
        db.exec(
            allocator,
            "UPDATE logs SET count = count + 1 WHERE id = ?",
            &.{dedup_row.values[0]},
        ) catch return error.PersistFailed;
        return;
    }

    // Fresh event — insert a new row.
    const insert_sql =
        \\INSERT INTO logs (
        \\  id, created_at_nano, level, kind, message, message_truncated,
        \\  stack, source, line, route_path, session_id, count
        \\) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, 1)
    ;
    // For nullable TEXT columns (stack/source/route_path/session_id),
    // `db.exec` binds empty slice as NULL (project memory
    // `sqlite-backend-empty-slice-binds-as-null`).
    db.exec(
        allocator,
        insert_sql,
        &.{
            id,
            now_us_str,
            body.level,
            body.kind,
            capped.text,
            if (capped.truncated) "1" else "0",
            body.stack orelse "",
            body.source orelse "",
            line_str,
            body.route_path orelse "",
            body.session_id orelse "",
        },
    ) catch return error.PersistFailed;
}

// =====================================================================
// Handler
// =====================================================================

pub fn frontendLogPostHandler(
    ctx: gserverz.HttpContext,
    req: gserverz.HttpRequest,
    res: gserverz.HttpResponse,
) !gserverz.HttpResponse {
    const allocator = ctx.allocator;

    const di = pabrikcore.getSingleton() catch {
        return res.jsonResponse(.{
            .status_code = 500,
            .data = try http_response.makeErrorResponse(allocator, .{ .@"error" = "Server not initialized" }),
        });
    };

    if (req.body.len == 0) {
        return res.jsonResponse(.{
            .status_code = 400,
            .data = try http_response.makeErrorResponse(allocator, .{ .@"error" = "missing required field: events" }),
        });
    }

    // Per-request arena owns the parsed value (Leaky variant — see
    // `memories_create.zig:181` for the precedent).
    const parsed = std.json.parseFromSliceLeaky(FrontendLogBody, allocator, req.body, .{}) catch {
        return res.jsonResponse(.{
            .status_code = 400,
            .data = try http_response.makeErrorResponse(allocator, .{ .@"error" = "Invalid JSON body" }),
        });
    };

    if (parsed.events.len == 0) {
        // Frontend client always sends a non-empty batch (it's wrapping its
        // in-memory queue), so an empty `events` array is user-error or
        // caller misconfiguration — surface as 400 with a clear message.
        return res.jsonResponse(.{
            .status_code = 400,
            .data = try http_response.makeErrorResponse(allocator, .{ .@"error" = "missing required field: events" }),
        });
    }

    // Run the use case once per event.
    for (parsed.events) |event| {
        useCase(allocator, di.db, event) catch |err| {
        const status: u16 = switch (err) {
            error.ServerNotInitialized => 500,
            error.IdAllocationFailed => 500,
            error.MissingLevel => 400,
            error.InvalidLevel => 400,
            error.MissingKind => 400,
            error.InvalidKind => 400,
            error.MissingMessage => 400,
            error.DedupQueryFailed => 500,
            error.PersistFailed => 500,
        };
        const message: []const u8 = switch (err) {
            error.ServerNotInitialized => "Server not initialized",
            error.IdAllocationFailed => "Failed to generate log id",
            // Validation messages use a canonical shape the frontend
            // parses: "missing required field: X" for an absent field,
            // "X must be one of ..." for present-but-wrong.
            error.MissingLevel => "missing required field: level",
            error.InvalidLevel => "level must be one of error, warn, info, debug",
            error.MissingKind => "missing required field: kind",
            error.InvalidKind => "kind must be one of window_error, unhandled_rejection, console_error, console_warn",
            error.MissingMessage => "missing required field: message",
            error.DedupQueryFailed => "Failed to dedup log",
            error.PersistFailed => "Failed to persist log",
        };
        // Use `std.log.warn` (NOT `std.log.err`) so this handler's error-path
        // doesn't trigger `log_err_count > 0` in `zig build test`. User-input
        // errors are warnings, not programmer errors.
        std.log.warn("frontend_log_post: {s}", .{message});
        return res.jsonResponse(.{
            .status_code = status,
            .data = try http_response.makeErrorResponse(allocator, .{ .@"error" = message }),
        });
    };
    }

    // 204 No Content — empty body.
    return gserverz.HttpResponse.init(204, "No Content", allocator).withBody("");
}

// =====================================================================
// Helpers
// =====================================================================

/// The bytes of `message` one `logs` row keeps. The live database averaged
/// 10,832 bytes per row and peaked at 1,009,888 — one serialized error object
/// or one component stack — and nothing reads past the first screen of it.
pub const message_byte_cap: usize = 8 * 1024;

pub const CappedMessage = struct { text: []const u8, truncated: bool };

/// `message` cut to `message_byte_cap` bytes without splitting a UTF-8
/// character, plus whether anything was cut.
pub fn capMessage(message: []const u8) CappedMessage {
    if (message.len <= message_byte_cap) return .{ .text = message, .truncated = false };
    var end = message_byte_cap;
    while (end > 0 and (message[end] & 0xC0) == 0x80) end -= 1;
    return .{ .text = message[0..end], .truncated = true };
}

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

/// Generate the canonical `log_<microseconds>` id for a new row. On OOM,
/// propagates the alloc error to the caller (the useCase catches it as
/// `error.IdAllocationFailed` and the handler returns 500).
fn idForRow(allocator: std.mem.Allocator) ![]u8 {
    const us = microsecondsNow();
    return std.fmt.allocPrint(allocator, "log_{d}", .{us});
}

/// Current Unix time in microseconds. `std.time.microTimestamp()` was REMOVED
/// in Zig 0.16.
fn microsecondsNow() i64 {
    const ns = @import("helpers").unixTimestampNanos();
    const us: i64 = @intCast(@divTrunc(ns, std.time.ns_per_us));
    return if (us < 0) 0 else us;
}

// ===== Tests merged from frontend_log_post_test.zig (2026-09-11 flatten)
// ===== Behavioural SQL dedup tests (Task 2.3) for `frontend_log_post` (POST
// /api/logs, Chunk 2 of

const testing = std.testing;

// =============================================================================
// Behavioural SQL dedup tests (Task 2.3) These exercise the SAME SQL the
// use-case runs against an in-memory SQLite DB with the logs table loaded.


/// Open a fresh in-memory sqlite DB with the `logs` table loaded.
/// Mirrors the `setupDb063` helper in `migration.zig` and the
/// `routines/Scheduler.zig` pattern.
fn setupDbWithLogs() !struct {
    db: database.Db,
    threaded: std.Io.Threaded,
} {
    const alloc = testing.allocator;
    var threaded = std.Io.Threaded.init(alloc, .{});
    errdefer threaded.deinit();
    const io = threaded.io();

    var db: database.Db = .{};
    errdefer db.deinit();
    try test_db.openMemory(&db, io);

    try pabrikcore.migrations_mod.migration.Migration064AddFrontendLogs.up(&db, alloc);
    try pabrikcore.migrations_mod.migration.Migration130AddLogMessageTruncated.up(&db, alloc);
    // Production DBs also run Migration 075, which renames `logs.created_at`
    // → `logs.created_at_nano`.
    try db.exec(alloc, "ALTER TABLE logs RENAME COLUMN created_at TO created_at_nano", &.{});
    try db.exec(alloc, "DROP INDEX IF EXISTS idx_logs_created_at", &.{});
    try db.exec(
        alloc,
        "CREATE INDEX IF NOT EXISTS idx_logs_created_at_nano ON logs(created_at_nano DESC)",
        &.{},
    );
    return .{ .db = db, .threaded = threaded };
}

test "dedup SQL: same kind+message+stack within 1s increments count" {
    const alloc = testing.allocator;
    var s = try setupDbWithLogs();
    defer s.threaded.deinit();
    defer s.db.deinit();

    const now_us: i64 = 1_784_226_123_456_789;
    // The `db.exec` / `db.query` helpers only bind TEXT — microsecond values
    // are formatted as decimal strings (the project convention; SQLite
    // coerces the numeric-looking text to INTEGER under INTEGER affinity,
    const now_us_str = try std.fmt.allocPrint(alloc, "{d}", .{now_us});
    defer alloc.free(now_us_str);
    const dedup_cutoff_str = try std.fmt.allocPrint(alloc, "{d}", .{now_us - 1_000_000});
    defer alloc.free(dedup_cutoff_str);

    // Insert first row at now.
    try s.db.exec(
        alloc,
        "INSERT INTO logs (id, created_at_nano, level, kind, message, stack, count) VALUES (?, ?, ?, ?, ?, ?, 1)",
        &.{ "log_first", now_us_str, "error", "console_error", "boom", "stack-A" },
    );

    // Dedup SELECT — same key within last 1s → matches.
    var rows = try s.db.query(
        alloc,
        "SELECT id FROM logs WHERE kind = ? AND message = ? AND COALESCE(stack,'') = COALESCE(?,'') AND created_at_nano >= ? LIMIT 1",
        &.{ "console_error", "boom", "stack-A", dedup_cutoff_str },
    );
    defer rows.deinit();

    const row = (try rows.next()) orelse return error.ExpectedDedupMatch;
    defer row.deinit(alloc);
    try testing.expectEqualStrings("log_first", row.values[0]);

    // Increment count via UPDATE.
    try s.db.exec(alloc, "UPDATE logs SET count = count + 1 WHERE id = ?", &.{"log_first"});

    // Verify count is now 2 and row count is still 1.
    var count_rows = try s.db.query(alloc, "SELECT count FROM logs WHERE id = ?", &.{"log_first"});
    defer count_rows.deinit();
    const count_row = (try count_rows.next()) orelse return error.RowMissing;
    defer count_row.deinit(alloc);
    try testing.expectEqualStrings("2", count_row.values[0]);

    var total_rows = try s.db.query(alloc, "SELECT COUNT(*) FROM logs", &.{});
    defer total_rows.deinit();
    const total_row = (try total_rows.next()) orelse return error.RowMissing;
    defer total_row.deinit(alloc);
    try testing.expectEqualStrings("1", total_row.values[0]);
}

test "dedup SQL: different stack within 1s does NOT match (insert second row)" {
    const alloc = testing.allocator;
    var s = try setupDbWithLogs();
    defer s.threaded.deinit();
    defer s.db.deinit();

    const now_us: i64 = 1_784_226_123_456_789;
    const now_us_str = try std.fmt.allocPrint(alloc, "{d}", .{now_us});
    defer alloc.free(now_us_str);
    const dedup_cutoff_str = try std.fmt.allocPrint(alloc, "{d}", .{now_us - 1_000_000});
    defer alloc.free(dedup_cutoff_str);

    // Insert first row with stack-A.
    try s.db.exec(
        alloc,
        "INSERT INTO logs (id, created_at_nano, level, kind, message, stack, count) VALUES (?, ?, ?, ?, ?, ?, 1)",
        &.{ "log_first", now_us_str, "error", "console_error", "boom", "stack-A" },
    );

    // Dedup query with a DIFFERENT stack — should NOT match.
    var rows = try s.db.query(
        alloc,
        "SELECT id FROM logs WHERE kind = ? AND message = ? AND COALESCE(stack,'') = COALESCE(?,'') AND created_at_nano >= ? LIMIT 1",
        &.{ "console_error", "boom", "stack-B", dedup_cutoff_str },
    );
    defer rows.deinit();

    const row_opt = try rows.next();
    if (row_opt) |r| {
        defer r.deinit(alloc);
        // dedup should NOT match — bug!
        return error.UnexpectedDedupMatch;
    }
    // Verify the row count is still 1 (would become 2 if a new INSERT
    // landed; the handler does the INSERT after no-match).
    var count_rows = try s.db.query(alloc, "SELECT COUNT(*) FROM logs", &.{});
    defer count_rows.deinit();
    const count_row = (try count_rows.next()) orelse return error.RowMissing;
    defer count_row.deinit(alloc);
    try testing.expectEqualStrings("1", count_row.values[0]);
}

test "dedup SQL: same key but >1s apart does NOT match (no dedup across window)" {
    const alloc = testing.allocator;
    var s = try setupDbWithLogs();
    defer s.threaded.deinit();
    defer s.db.deinit();

    const t1: i64 = 1_784_226_123_456_789;
    const t1_str = try std.fmt.allocPrint(alloc, "{d}", .{t1});
    defer alloc.free(t1_str);
    // t2 is 1.5 seconds past t1 — clearly outside the 1s dedup window.
    const t2: i64 = t1 + 1_500_000;
    const t2_str = try std.fmt.allocPrint(alloc, "{d}", .{t2});
    defer alloc.free(t2_str);
    // Dedup cutoff at t2 = t1 + 0.5s, which is BEFORE t1, so the t1
    // row is excluded from the dedup query.
    const dedup_cutoff_str = try std.fmt.allocPrint(alloc, "{d}", .{t2 - 1_000_000});
    defer alloc.free(dedup_cutoff_str);

    // Row at t1 with stack-A.
    try s.db.exec(
        alloc,
        "INSERT INTO logs (id, created_at_nano, level, kind, message, stack, count) VALUES (?, ?, ?, ?, ?, ?, 1)",
        &.{ "log_t1", t1_str, "error", "console_error", "boom", "stack-A" },
    );

    // Dedup at t2 with same key — t1 is BEFORE cut-off → no match →
    // handler would INSERT a new row.
    var rows = try s.db.query(
        alloc,
        "SELECT id FROM logs WHERE kind = ? AND message = ? AND COALESCE(stack,'') = COALESCE(?,'') AND created_at_nano >= ? LIMIT 1",
        &.{ "console_error", "boom", "stack-A", dedup_cutoff_str },
    );
    defer rows.deinit();

    const row_opt = try rows.next();
    if (row_opt) |r| {
        defer r.deinit(alloc);
        return error.UnexpectedDedupMatchAcrossWindow;
    }
    // Original row stays untouched.
    var count_rows = try s.db.query(alloc, "SELECT COUNT(*) FROM logs", &.{});
    defer count_rows.deinit();
    const count_row = (try count_rows.next()) orelse return error.RowMissing;
    defer count_row.deinit(alloc);
    try testing.expectEqualStrings("1", count_row.values[0]);
}

test "capMessage keeps a message that is exactly the cap, unmarked" {
    const at_cap = try testing.allocator.alloc(u8, message_byte_cap);
    defer testing.allocator.free(at_cap);
    @memset(at_cap, 'a');

    const capped = capMessage(at_cap);

    try testing.expect(!capped.truncated);
    try testing.expectEqual(message_byte_cap, capped.text.len);
}

test "capMessage cuts a message one byte over the cap to the cap, and says so" {
    const over = try testing.allocator.alloc(u8, message_byte_cap + 1);
    defer testing.allocator.free(over);
    @memset(over, 'a');

    const capped = capMessage(over);

    try testing.expect(capped.truncated);
    try testing.expectEqual(message_byte_cap, capped.text.len);
}

test "capMessage never leaves half a multi-byte character at the cut" {
    // '€' is three bytes (E2 82 AC); placing it so byte 8192 is its SECOND
    // byte is the case a naive `message[0..8192]` gets wrong.
    const message = try testing.allocator.alloc(u8, message_byte_cap + 8);
    defer testing.allocator.free(message);
    @memset(message, 'a');
    @memcpy(message[message_byte_cap - 1 ..][0..3], "€");

    const capped = capMessage(message);

    try testing.expect(capped.truncated);
    try testing.expectEqual(message_byte_cap - 1, capped.text.len);
    try testing.expect(std.unicode.utf8ValidateSlice(capped.text));
}

test "a long message is stored at the cap and marked truncated" {
    const alloc = testing.allocator;
    var s = try setupDbWithLogs();
    defer s.threaded.deinit();
    defer s.db.deinit();

    const long = try alloc.alloc(u8, 40 * 1024);
    defer alloc.free(long);
    @memset(long, 'x');

    try useCaseAt(alloc, &s.db, .{
        .level = "warn",
        .kind = "console_warn",
        .message = long,
    }, 1_784_226_123_456_789);

    var row = try s.db.queryRow(alloc, "SELECT LENGTH(message), message_truncated FROM logs", &.{});
    defer row.deinit(alloc);
    try testing.expectEqualStrings("8192", row.values[0]);
    try testing.expectEqualStrings("1", row.values[1]);
}

test "a short message is stored whole and unmarked" {
    const alloc = testing.allocator;
    var s = try setupDbWithLogs();
    defer s.threaded.deinit();
    defer s.db.deinit();

    try useCaseAt(alloc, &s.db, .{
        .level = "error",
        .kind = "console_error",
        .message = "TypeError: x is not a function",
    }, 1_784_226_123_456_789);

    var row = try s.db.queryRow(alloc, "SELECT message, message_truncated FROM logs", &.{});
    defer row.deinit(alloc);
    try testing.expectEqualStrings("TypeError: x is not a function", row.values[0]);
    try testing.expectEqualStrings("0", row.values[1]);
}

test "two events that differ only past the cap are one row, counted twice" {
    const alloc = testing.allocator;
    var s = try setupDbWithLogs();
    defer s.threaded.deinit();
    defer s.db.deinit();

    const first = try alloc.alloc(u8, 40 * 1024);
    defer alloc.free(first);
    @memset(first, 'x');
    const second = try alloc.alloc(u8, 40 * 1024);
    defer alloc.free(second);
    @memset(second, 'x');
    // Both differences live beyond byte 8192, so both are cut away.
    first[9000] = 'A';
    second[9000] = 'B';
    second[12000] = 'C';

    const now_us: i64 = 1_784_226_123_456_789;
    try useCaseAt(alloc, &s.db, .{ .level = "warn", .kind = "console_warn", .message = first }, now_us);
    try useCaseAt(alloc, &s.db, .{ .level = "warn", .kind = "console_warn", .message = second }, now_us);

    var row = try s.db.queryRow(alloc, "SELECT COUNT(*), COALESCE(SUM(count), 0) FROM logs", &.{});
    defer row.deinit(alloc);
    try testing.expectEqualStrings("1", row.values[0]);
    try testing.expectEqualStrings("2", row.values[1]);
}
