// Functional tests for Migration 082 — `sessions.last_human_touched_at_nano`.
// Zig port of `tests/functional/session_human_touched_at_test.py` (same test
// names, same order).

const std = @import("std");
const testing = std.testing;
const harness = @import("harness.zig");
const Harness = harness.Harness;
const gpa = testing.allocator;
const io = testing.io;

// ============================================================================
// Helpers — wire
// ============================================================================

/// Monotonic milliseconds (`.awake`, not the wall clock — an NTP step
/// must not extend a poll deadline).
fn nowMs() i64 {
    return std.Io.Timestamp.now(io, .awake).toMilliseconds();
}

/// `PUT /api/llm/session/:session_id {"name": ...}`. Auto-creates the row,
/// which is exactly the "spin up a session without invoking /api/llm/session"
/// the Python helper documented.
fn putSession(h: *Harness, sid: []const u8, name: []const u8) !void {
    const path = try std.fmt.allocPrint(gpa, "/api/llm/session/{s}", .{sid});
    defer gpa.free(path);
    const body = try std.json.Stringify.valueAlloc(gpa, .{ .name = name }, .{});
    defer gpa.free(body);

    var r = try h.http(io, .PUT, path, .{ .json_body = body, .expect = &.{200} });
    defer r.deinit();
}

/// The single `sessions[]` entry whose `session_id == id`. Borrows from
/// `doc`, so the caller must keep the `Response` it was parsed from alive for
/// the duration of the borrow.
fn findSessionInList(doc: *const harness.Json, id: []const u8) !std.json.Value {
    const sessions = doc.array("sessions") orelse {
        std.debug.print("session list has no `sessions` array\n", .{});
        return error.TestUnexpectedResult;
    };

    var found: ?std.json.Value = null;
    for (sessions.items) |item| {
        const o = switch (item) {
            .object => |m| m,
            else => continue,
        };
        const n = switch (o.get("session_id") orelse continue) {
            .string => |s| s,
            else => continue,
        };
        if (!std.mem.eql(u8, n, id)) continue;
        if (found != null) {
            std.debug.print("expected exactly 1 match for {s}, found more\n", .{id});
            return error.TestUnexpectedResult;
        }
        found = item;
    }
    if (found == null) {
        std.debug.print("expected exactly 1 match for {s}, found 0\n", .{id});
        return error.TestUnexpectedResult;
    }
    return found.?;
}

/// `GET /api/llm/session?limit=100`, the only GET shape the list
/// endpoint exposes (there is no single-GET `/api/llm/session/:id` for
/// the list's fields).
fn fetchList(h: *Harness) !harness.Response {
    return h.http(io, .GET, "/api/llm/session", .{
        .params = &.{.{ .name = "limit", .value = "100" }},
        .expect = &.{200},
    });
}

/// Python's `entry.get(key) or ""` — a missing key, a JSON `null` and a
/// non-string all collapse to `""`.
fn jsonStringField(value: std.json.Value, key: []const u8) []const u8 {
    const o = switch (value) {
        .object => |m| m,
        else => return "",
    };
    return switch (o.get(key) orelse return "") {
        .string => |s| s,
        else => return "",
    };
}

// ============================================================================
// Helpers — sqlite3 CLI
// ============================================================================

fn exitCode(term: std.process.Child.Term) ?u8 {
    return switch (term) {
        .exited => |c| c,
        else => null,
    };
}

/// Skip unless a `sqlite3` CLI is present and speaks `-json`. `-json` landed
/// in SQLite 3.33 (2020).
fn requireSqlite3Cli() !void {
    const res = std.process.run(gpa, io, .{
        .argv = &.{ "sqlite3", "-json", ":memory:", "SELECT 1 AS probe;" },
    }) catch |err| {
        std.debug.print("sqlite3 CLI unavailable ({s}); skipping DB assertions\n", .{@errorName(err)});
        return error.SkipZigTest;
    };
    defer {
        gpa.free(res.stdout);
        gpa.free(res.stderr);
    }
    const code = exitCode(res.term);
    if (code == null or code.? != 0 or std.mem.indexOf(u8, res.stdout, "\"probe\"") == null) {
        std.debug.print(
            "sqlite3 CLI lacks -json support (rc={?}, out={s}); skipping DB assertions\n",
            .{ code, res.stdout },
        );
        return error.SkipZigTest;
    }
}

/// `sqlite3 -json` prints ZERO BYTES for an empty result set, not `[]`.
fn parseSqliteJson(out: []const u8) !std.json.Parsed(std.json.Value) {
    if (std.mem.trim(u8, out, " \t\r\n").len == 0) {
        return std.json.parseFromSlice(std.json.Value, gpa, "[]", .{});
    }
    return std.json.parseFromSlice(std.json.Value, gpa, out, .{});
}

/// Single-quote `s` as an SQL literal, doubling embedded quotes. Owned.
fn sqlLit(s: []const u8) ![]u8 {
    var out: std.Io.Writer.Allocating = .init(gpa);
    errdefer out.deinit();
    out.writer.writeByte('\'') catch return error.OutOfMemory;
    for (s) |c| {
        if (c == '\'') out.writer.writeByte('\'') catch return error.OutOfMemory;
        out.writer.writeByte(c) catch return error.OutOfMemory;
    }
    out.writer.writeByte('\'') catch return error.OutOfMemory;
    return out.toOwnedSlice();
}

/// The agent DB inside the isolated tmpdir HOME (Linux/macOS layout).
fn dbPath(temp_dir: []const u8) ![]u8 {
    return harness.harnessPath(gpa, temp_dir, &.{ ".config", "pabrik", "agent.db" });
}

/// Run one statement against `db_path`, return the CLI's stdout (owned).
/// `.timeout 5000` is the `busy_timeout` the server's WAL connection needs; a
/// bare CLI invocation would otherwise fail with SQLITE_BUSY.
fn sqliteRun(db_path: []const u8, sql: []const u8) ![]u8 {
    const res = std.process.run(gpa, io, .{
        .argv = &.{ "sqlite3", "-cmd", ".timeout 5000", "-json", db_path, sql },
    }) catch |err| {
        std.debug.print("sqlite3 did not spawn: {s}\n", .{@errorName(err)});
        return error.SkipZigTest;
    };
    defer gpa.free(res.stderr);

    const code = exitCode(res.term) orelse {
        gpa.free(res.stdout);
        std.debug.print("sqlite3 was killed by a signal: {any}\n", .{res.term});
        return error.TestUnexpectedResult;
    };
    if (code != 0) {
        defer gpa.free(res.stdout);
        std.debug.print("sqlite3 exited {d}: {s}\nsql: {s}\n", .{ code, res.stderr, sql });
        return error.TestUnexpectedResult;
    }
    return res.stdout;
}

/// INSERT a `sessions` row with the DEFAULT (NULL) stamp, bypassing the
/// helper which always triggers a stamp via the PUT path.
fn insertNullStampRow(temp_dir: []const u8, sid: []const u8, name: []const u8) !void {
    const db = try dbPath(temp_dir);
    defer gpa.free(db);
    const id_lit = try sqlLit(sid);
    defer gpa.free(id_lit);
    const name_lit = try sqlLit(name);
    defer gpa.free(name_lit);
    const sql = try std.fmt.allocPrint(
        gpa,
        "INSERT INTO sessions (id, name, status) VALUES ({s}, {s}, 'active')",
        .{ id_lit, name_lit },
    );
    defer gpa.free(sql);

    const out = try sqliteRun(db, sql);
    defer gpa.free(out);
}

/// The RAW column, bypassing the SELECT-layer conversion: null when the row
/// is missing, null when the column is NULL (pre-Migration-082 or never
/// touched).
fn selectHumanTouched(temp_dir: []const u8, sid: []const u8) !?i64 {
    const db = try dbPath(temp_dir);
    defer gpa.free(db);
    std.Io.Dir.cwd().access(io, db, .{}) catch {
        std.debug.print("db not found at {s}\n", .{db});
        return error.TestUnexpectedResult;
    };
    const lit = try sqlLit(sid);
    defer gpa.free(lit);
    const sql = try std.fmt.allocPrint(
        gpa,
        "SELECT last_human_touched_at_nano FROM sessions WHERE id = {s}",
        .{lit},
    );
    defer gpa.free(sql);

    const out = try sqliteRun(db, sql);
    defer gpa.free(out);
    var parsed = try parseSqliteJson(out);
    defer parsed.deinit();

    const arr = switch (parsed.value) {
        .array => |a| a,
        else => return error.TestUnexpectedResult,
    };
    if (arr.items.len == 0) return null; // no such row
    const o = switch (arr.items[0]) {
        .object => |m| m,
        else => return error.TestUnexpectedResult,
    };
    const cell = o.get("last_human_touched_at_nano") orelse return null;
    return switch (cell) {
        .integer => |i| i,
        .null => null,
        else => {
            std.debug.print("last_human_touched_at_nano is neither an integer nor null\n", .{});
            return error.TestUnexpectedResult;
        },
    };
}

/// True iff `s` is a non-empty run of ASCII digits — the shape Python's
/// `str.isdigit()` checked on the rendered stamp.
fn allDigits(s: []const u8) bool {
    if (s.len == 0) return false;
    for (s) |c| {
        if (c < '0' or c > '9') return false;
    }
    return true;
}

// ============================================================================
// Test 1: PUT stamps the column
// ============================================================================

// PUT /api/llm/session/:session_id (any field) bumps the
// sessions.last_human_touched_at_nano column. Task 4 invariant.
test "put_session_stamps_last_human_touched_at_nano" {
    try harness.requirePabrikBin(io, gpa);
    try requireSqlite3Cli();
    var h = try Harness.boot(io, gpa, .{});
    defer h.deinit(io) catch |err| {
        std.debug.print("teardown: {s}\n", .{@errorName(err)});
    };

    const sid = "sess_human_touched_put_001";

    // Insert a row directly with NULL stamp (bypasses the helper which
    // always triggers a stamp via the PUT path - we need a NULL column
    // as the baseline to assert "PUT bumps it").
    try insertNullStampRow(h.temp_dir, sid, "Baseline row");
    if ((try selectHumanTouched(h.temp_dir, sid)) != null) {
        std.debug.print("the baseline row must start with a NULL stamp\n", .{});
        return error.TestUnexpectedResult;
    }

    // First PUT sets the stamp (any field triggers it - the handler
    // stamps AFTER applying the update, so even a no-op body works).
    try putSession(&h, sid, "renamed");

    const stamp = (try selectHumanTouched(h.temp_dir, sid)) orelse {
        std.debug.print("PUT should stamp last_human_touched_at_nano\n", .{});
        return error.TestUnexpectedResult;
    };

    // unix-ms integer string: 10+ digits.
    const rendered = try std.fmt.allocPrint(gpa, "{d}", .{stamp});
    defer gpa.free(rendered);
    if (!allDigits(rendered) or rendered.len < 10) {
        std.debug.print(
            "stamp should be a unix-ms integer string (>= 10 digits), got '{s}'\n",
            .{rendered},
        );
        return error.TestUnexpectedResult;
    }
}

// ============================================================================
// Test 2: GET surfaces the wire field as SQLite datetime UTC
// ============================================================================

// GET /api/llm/session (the list endpoint - pabrik has no single-GET
// `/api/llm/session/:id` route) returns last_human_touched_at in the
// SELECT-layer-converted wire shape: SQLite datetime UTC ('YYYY-MM-DD
test "get_session_returns_last_human_touched_as_sqlite_datetime" {
    try harness.requirePabrikBin(io, gpa);
    var h = try Harness.boot(io, gpa, .{});
    defer h.deinit(io) catch |err| {
        std.debug.print("teardown: {s}\n", .{@errorName(err)});
    };

    const sid = "sess_human_touched_get_001";
    try putSession(&h, sid, "human-touched-session");
    try putSession(&h, sid, "stamped");

    var r = try fetchList(&h);
    defer r.deinit();
    var doc = try r.json();
    defer doc.deinit();

    const entry = try findSessionInList(&doc, sid);
    const human = jsonStringField(entry, "last_human_touched_at");

    // Wire shape: exactly 19 chars ('YYYY-MM-DD HH:MM:SS').
    if (human.len != 19) {
        std.debug.print("expected 19 chars, got {d}: '{s}'\n", .{ human.len, human });
        return error.TestUnexpectedResult;
    }
    // Format: digits + hyphens + space + colon separators, no unix-ms
    // digits.
    const want_seps = [_]struct { at: usize, c: u8 }{
        .{ .at = 4, .c = '-' },
        .{ .at = 7, .c = '-' },
        .{ .at = 10, .c = ' ' },
        .{ .at = 13, .c = ':' },
        .{ .at = 16, .c = ':' },
    };
    for (want_seps) |w| {
        if (human[w.at] != w.c) {
            std.debug.print(
                "expected '{c}' at index {d} of '{s}', got '{c}'\n",
                .{ w.c, w.at, human, human[w.at] },
            );
            return error.TestUnexpectedResult;
        }
    }
    // Not the raw unix-ms integer (which would be a long string of
    // digits).
    if (allDigits(human)) {
        std.debug.print(
            "wire field should be a SQLite datetime, not raw unix-ms: '{s}'\n",
            .{human},
        );
        return error.TestUnexpectedResult;
    }
}

// ============================================================================
// Test 3: legacy NULL rows return empty string on the wire
// ============================================================================

// A legacy row (column is NULL because the row existed before Migration 082
// ran, or was created via raw SQL bypassing the migration) returns
// `last_human_touched_at: ""` on the wire.
test "get_session_returns_empty_when_last_human_touched_never_stamped" {
    try harness.requirePabrikBin(io, gpa);
    try requireSqlite3Cli();
    var h = try Harness.boot(io, gpa, .{});
    defer h.deinit(io) catch |err| {
        std.debug.print("teardown: {s}\n", .{@errorName(err)});
    };

    const sid = "sess_legacy_null_001";
    // A bare INSERT gives the column DEFAULT (NULL per Migration 082).
    try insertNullStampRow(h.temp_dir, sid, "Legacy NULL row");

    var r = try fetchList(&h);
    defer r.deinit();
    var doc = try r.json();
    defer doc.deinit();

    const entry = try findSessionInList(&doc, sid);
    // The SELECT-layer uses `CASE WHEN ... IS NULL ... THEN ''` so the
    // JSON serializer emits a JSON empty string (not null).
    const human = jsonStringField(entry, "last_human_touched_at");
    if (human.len != 0) {
        std.debug.print(
            "expected empty string for a legacy row, got '{s}'\n",
            .{human},
        );
        return error.TestUnexpectedResult;
    }
}

// ============================================================================
// Test 4: GET /api/llm/session (list) includes the new field
// ============================================================================

// GET /api/llm/session (the list endpoint) returns last_human_touched_at
// on every session. Same SELECT-layer conversion as the single-GET
// path, so the wire shape is consistent across endpoints.
test "list_sessions_includes_last_human_touched" {
    try harness.requirePabrikBin(io, gpa);
    var h = try Harness.boot(io, gpa, .{});
    defer h.deinit(io) catch |err| {
        std.debug.print("teardown: {s}\n", .{@errorName(err)});
    };

    const sid = "sess_human_touched_list_001";
    try putSession(&h, sid, "human-touched-session");
    try putSession(&h, sid, "stamped-for-list");

    var r = try h.http(io, .GET, "/api/llm/session", .{
        .params = &.{.{ .name = "limit", .value = "50" }},
        .expect = &.{200},
    });
    defer r.deinit();
    var doc = try r.json();
    defer doc.deinit();

    if (doc.array("sessions") == null) {
        std.debug.print("list response has no `sessions` array: {s}\n", .{r.body});
        return error.TestUnexpectedResult;
    }
    const entry = try findSessionInList(&doc, sid);

    // Field is present (even if its value is empty for legacy rows) —
    // this is the `in` check Python made on the DICT, which needs an
    // object view rather than the collapsing `jsonStringField`.
    const o = switch (entry) {
        .object => |m| m,
        else => return error.TestUnexpectedResult,
    };
    const field = o.get("last_human_touched_at") orelse {
        std.debug.print(
            "list endpoint must include last_human_touched_at on every session\n",
            .{},
        );
        return error.TestUnexpectedResult;
    };
    const human = switch (field) {
        .string => |s| s,
        else => {
            std.debug.print(
                "`last_human_touched_at` must be a string, got {s}\n",
                .{@tagName(field)},
            );
            return error.TestUnexpectedResult;
        },
    };
    // For our stamped session, the value is the wire datetime string.
    if (human.len != 19) {
        std.debug.print("expected a 19-char datetime, got '{s}'\n", .{human});
        return error.TestUnexpectedResult;
    }
}

// ============================================================================
// Test 5: subsequent PUTs overwrite (most-recent-wins)
// ============================================================================

// A second PUT bumps the stamp forward - the helper is idempotent but
// always overwrites with `now_unix_ms` (null arg). Plan D1.
test "subsequent_puts_overwrite_last_human_touched" {
    try harness.requirePabrikBin(io, gpa);
    try requireSqlite3Cli();
    var h = try Harness.boot(io, gpa, .{});
    defer h.deinit(io) catch |err| {
        std.debug.print("teardown: {s}\n", .{@errorName(err)});
    };

    const sid = "sess_overwrite_stamp_001";
    try putSession(&h, sid, "human-touched-session");
    try putSession(&h, sid, "first");

    const first_stamp = (try selectHumanTouched(h.temp_dir, sid)) orelse {
        std.debug.print("the first PUT did not stamp the column\n", .{});
        return error.TestUnexpectedResult;
    };

    // Brief sleep so the second timestamp is strictly greater
    // (unix-ms resolution, so even 1ms is enough on most systems).
    std.Io.sleep(io, .fromMilliseconds(50), .awake) catch {};

    try putSession(&h, sid, "second");

    const second_stamp = (try selectHumanTouched(h.temp_dir, sid)) orelse {
        std.debug.print("the second PUT cleared the stamp\n", .{});
        return error.TestUnexpectedResult;
    };
    if (second_stamp <= first_stamp) {
        std.debug.print(
            "second stamp {d} should be > first stamp {d}\n",
            .{ second_stamp, first_stamp },
        );
        return error.TestUnexpectedResult;
    }
}

// Body-analysis barrier. An unreferenced helper is never type-checked, so
// a stdlib rename inside one stays invisible until a caller appears.
comptime {
    _ = nowMs;
    _ = putSession;
    _ = findSessionInList;
    _ = fetchList;
    _ = jsonStringField;
    _ = exitCode;
    _ = requireSqlite3Cli;
    _ = parseSqliteJson;
    _ = sqlLit;
    _ = dbPath;
    _ = sqliteRun;
    _ = insertNullStampRow;
    _ = selectHumanTouched;
    _ = allDigits;
}
