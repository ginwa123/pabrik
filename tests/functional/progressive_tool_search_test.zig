// Functional tests for progressive tool search (`search_tool` / `view_tool` /
// `use_tool`).

const std = @import("std");
const builtin = @import("builtin");
const testing = std.testing;
const harness = @import("harness.zig");
const Harness = harness.Harness;
const Io = std.Io;
const gpa = testing.allocator;
const io = testing.io;

// `[STREAM START] model=stub-model | messages=2 | tools=5 | streaming=true`
// The Python module compiled this to a regex; the port scans for the two
// literal markers instead.
const STREAM_MARKER = "[STREAM START]";
const TOOLS_KEY = "tools=";

// The three progressive meta-tools that must always be listed — they
// are ordinary tools as far as the registry is concerned.
const PROGRESSIVE_TOOL_NAMES = [_][]const u8{ "search_tool", "view_tool", "use_tool" };

// A fresh kanban item seeds DEFAULT_AGENT_TOOLS + DEFAULT_KANBAN_TOOLS.
const AGENT_DEFAULTS: u32 = 25;
const KANBAN_ONLY_DEFAULTS: u32 = 2;
const KANBAN_SEEDED_TOOLS: u32 = AGENT_DEFAULTS + KANBAN_ONLY_DEFAULTS; // 27

// A tool that is NOT in the seeded set and is not design-only, so
// equipping it is legal for a kanban item and observably adds exactly
// one tool.
const NOT_SEEDED_KANBAN_TOOL = "set_git_worktree";

/// Python `_wait_for_tool_count`'s `timeout_s`.
const TOOL_COUNT_TIMEOUT_S: f64 = 45.0;
/// Tail size handed to `Harness.tailLog`. Python passed 4000 lines.
const LOG_TAIL_LINES: usize = 4000;
/// Python's `time.sleep(0.2)` between log re-reads.
const POLL_INTERVAL_MS: i64 = 200;

// ============================================================================
// Helpers
// ============================================================================

/// Monotonic milliseconds (`.awake` = monotonic, not wall clock) — the
/// deadline basis `Io.sleep` needs.
fn nowMs() i64 {
    return Io.Timestamp.now(io, .awake).toMilliseconds();
}

/// The `N` in a `[STREAM START] ... tools=N` line, or `null`.
fn toolsValueOnStreamLine(line: []const u8) ?i64 {
    const at = std.mem.indexOf(u8, line, TOOLS_KEY) orelse return null;
    var i = at + TOOLS_KEY.len;
    var buf: [20]u8 = undefined;
    var n: usize = 0;
    while (i < line.len and std.ascii.isDigit(line[i]) and n < buf.len) : (i += 1) {
        buf[n] = line[i];
        n += 1;
    }
    if (n == 0) return null;
    return std.fmt.parseInt(i64, buf[0..n], 10) catch null;
}

/// The largest `tools=N` over every `[STREAM START]` line in `tail`,
/// or -1 when there is none.
fn maxToolsInLog(tail: []const u8) i64 {
    var best: i64 = -1;
    var cursor: usize = 0;
    while (std.mem.indexOfPos(u8, tail, cursor, STREAM_MARKER)) |pos| {
        const rest = tail[pos..];
        const line_end = std.mem.indexOfScalar(u8, rest, '\n') orelse rest.len;
        if (toolsValueOnStreamLine(rest[0..line_end])) |n| {
            if (n > best) best = n;
        }
        cursor = pos + 1;
    }
    return best;
}

/// The largest `tools=N` seen within `timeout_s`, i.e. the main agent
/// call's tool count. The session-name generator call that precedes it
/// reports `tools=0`, hence "largest" rather than "last".
fn waitForToolCount(h: *Harness, timeout_s: f64) !i64 {
    const deadline = nowMs() + @as(i64, @intFromFloat(timeout_s * 1000.0));
    var tail: []u8 = "";
    errdefer if (tail.len > 0) gpa.free(tail);

    var best: i64 = -1;
    var done = false;
    while (!done and nowMs() < deadline) {
        if (tail.len > 0) {
            gpa.free(tail);
            tail = "";
        }
        tail = try h.tailLog(io, gpa, LOG_TAIL_LINES);
        best = maxToolsInLog(tail);
        if (best > 0) done = true;
        if (!done) Io.sleep(io, .fromMilliseconds(POLL_INTERVAL_MS), .awake) catch {};
    }

    if (!done or best <= 0) {
        const excerpt = if (tail.len > 6000) tail[tail.len - 6000 ..] else tail;
        std.debug.print(
            "no '[STREAM START] ... tools=N' line with N>0 within {d}s.\n--- log tail ---\n{s}\n",
            .{ @as(u32, @intFromFloat(timeout_s)), excerpt },
        );
        return error.TestUnexpectedResult;
    }
    gpa.free(tail);
    return best;
}

/// A plain (unbound) chat session — the `pabrik-tui` body shape.
fn queuePlainMessage(h: *Harness, session_id: []const u8, allowed_tools: []const u8) !void {
    const body = try std.fmt.allocPrint(gpa,
        \\{{"session_id":"{s}","queue_message":"hello from the progressive tool search test","cwd_session":"{s}","allowed_tools":"{s}","image_urls":"","selected_profile_model":"","is_auto_retry_until_stop":""}}
    , .{ session_id, h.temp_dir, allowed_tools });
    defer gpa.free(body);

    var r = try h.http(io, .POST, "/api/llm/session", .{
        .json_body = body,
        .expect = &.{ 201, 500 },
    });
    defer r.deinit();
}

/// Skip unless a `sqlite3` CLI is present and speaks `-json`.
fn requireSqlite3Cli() !void {
    const res = std.process.run(gpa, io, .{
        .argv = &.{ "sqlite3", "-json", ":memory:", "SELECT 1 AS probe;" },
    }) catch |err| {
        std.debug.print("sqlite3 CLI unavailable ({s}); skipping the equip-row seed\n", .{@errorName(err)});
        return error.SkipZigTest;
    };
    defer {
        gpa.free(res.stdout);
        gpa.free(res.stderr);
    }
    const code: ?u8 = switch (res.term) {
        .exited => |c| c,
        else => null,
    };
    if (code == null or code.? != 0 or std.mem.indexOf(u8, res.stdout, "\"probe\"") == null) {
        std.debug.print(
            "sqlite3 CLI lacks -json support (rc={?}, out={s}); skipping the equip-row seed\n",
            .{ code, res.stdout },
        );
        return error.SkipZigTest;
    }
}

/// Exit code for a finished child, or null if a signal stopped it.
fn exitCode(term: std.process.Child.Term) ?u8 {
    return switch (term) {
        .exited => |c| c,
        else => null,
    };
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

/// Agent DB inside the isolated tmpdir HOME (Linux layout).
/// Python `_db_path`.
fn dbPath(temp_dir: []const u8) ![]u8 {
    return harness.harnessPath(gpa, temp_dir, &.{ ".config", "pabrik", "agent.db" });
}

/// Run one statement against `db_path`; caller frees the returned stdout.
fn sqliteRun(db_path: []const u8, sql: []const u8) ![]u8 {
    const res = std.process.run(gpa, io, .{
        // `.timeout 5000` is the CLI's spelling of Python's
        // `busy_timeout`; the agent DB is WAL-mode and the server holds
        // a connection open for the whole test.
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

/// `sqlite3 -json` prints ZERO BYTES for an empty result set — not `[]`.
fn parseSqliteJson(out: []const u8) !std.json.Parsed(std.json.Value) {
    if (std.mem.trim(u8, out, " \t\r\n").len == 0) {
        return std.json.parseFromSlice(std.json.Value, gpa, "[]", .{});
    }
    return std.json.parseFromSlice(std.json.Value, gpa, out, .{});
}

/// Insert an equip row directly, the way a previous iteration would
/// have. Python `_equip_row`.
fn equipRow(h: *Harness, session_id: []const u8, tool_name: []const u8) !void {
    const db = try dbPath(h.temp_dir);
    defer gpa.free(db);
    const sid = try sqlLit(session_id);
    defer gpa.free(sid);
    const tool = try sqlLit(tool_name);
    defer gpa.free(tool);

    const sql = try std.fmt.allocPrint(
        gpa,
        "INSERT OR IGNORE INTO session_progressive_tool" ++
            " (session_id, tool_name, server_name, loaded_at_nano)" ++
            " VALUES ({s}, {s}, '', strftime('%s','now'))",
        .{ sid, tool },
    );
    defer gpa.free(sql);

    const out = try sqliteRun(db, sql);
    gpa.free(out);
}

/// `SELECT COUNT(*) AS n` for one session's equip rows.
fn countEquipRows(h: *Harness, session_id: []const u8) !u64 {
    const db = try dbPath(h.temp_dir);
    defer gpa.free(db);
    const sid = try sqlLit(session_id);
    defer gpa.free(sid);

    const sql = try std.fmt.allocPrint(
        gpa,
        "SELECT COUNT(*) AS n FROM session_progressive_tool WHERE session_id = {s}",
        .{sid},
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
    if (arr.items.len != 1) {
        std.debug.print("expected exactly one COUNT row, got {d}: {s}\n", .{ arr.items.len, out });
        return error.TestUnexpectedResult;
    }
    const row = switch (arr.items[0]) {
        .object => |o| o,
        else => return error.TestUnexpectedResult,
    };
    return switch (row.get("n") orelse return error.TestUnexpectedResult) {
        .integer => |i| if (i < 0) 0 else @intCast(i),
        else => return error.TestUnexpectedResult,
    };
}

// ============================================================================
// Tests
// ============================================================================

// A plain chat session has no workspace item, so `self_item_type` is "" — not
// agent/kanban — and the three progressive tools must NOT be injected. This
// is what scopes the default to the two modes the user asked for.
test "unbound_chat_session_does_not_get_the_meta_tools" {
    try harness.requirePabrikBin(io, gpa);

    // Python's `stub_harness` fixture: WITH a stub LLM profile, so the
    // workflow reaches its loop and emits the STREAM line at all.
    var h = try Harness.boot(io, gpa, .{ .stub_llm_profile = true });
    defer h.deinit(io) catch |err| {
        std.debug.print("teardown: {s}", .{@errorName(err)});
    };

    try queuePlainMessage(&h, "prog-test-unbound", "read_file,glob");

    const got = try waitForToolCount(&h, TOOL_COUNT_TIMEOUT_S);
    if (got != 2) {
        std.debug.print(
            "a session with no workspace item must get only its 2 allowlisted " ++
                "built-ins (no progressive tools), got {d}\n",
            .{got},
        );
        return error.TestUnexpectedResult;
    }
}

// `PRIMARY KEY(session_id, tool_name)` is the DB half of "if it is
// already equipped, do not insert" — INSERT OR IGNORE leaves exactly
// one row, which is what makes `use_tool`'s inserted=false honest.
test "duplicate_equip_row_is_rejected_by_the_primary_key" {
    try harness.requirePabrikBin(io, gpa);
    try requireSqlite3Cli();

    var h = try Harness.boot(io, gpa, .{ .stub_llm_profile = true });
    defer h.deinit(io) catch |err| {
        std.debug.print("teardown: {s}", .{@errorName(err)});
    };

    const session_id = "prog-test-dup";
    try equipRow(&h, session_id, NOT_SEEDED_KANBAN_TOOL);
    try equipRow(&h, session_id, NOT_SEEDED_KANBAN_TOOL);

    const n = try countEquipRows(&h, session_id);
    if (n != 1) {
        std.debug.print("expected exactly one row after two identical equips, got {d}\n", .{n});
        return error.TestUnexpectedResult;
    }
}

comptime {
    // Body-analysis barrier — see `harness.zig`'s note: an unreferenced
    // function body is never type-checked, so a stdlib rename inside one
    // stays invisible until a caller appears.
    _ = nowMs;
    _ = toolsValueOnStreamLine;
    _ = maxToolsInLog;
    _ = waitForToolCount;
    _ = queuePlainMessage;
    _ = requireSqlite3Cli;
    _ = exitCode;
    _ = sqlLit;
    _ = dbPath;
    _ = sqliteRun;
    _ = parseSqliteJson;
    _ = equipRow;
    _ = countEquipRows;
    _ = PROGRESSIVE_TOOL_NAMES;
    _ = KANBAN_SEEDED_TOOLS;
    _ = builtin;
}
