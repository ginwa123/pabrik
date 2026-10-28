const std = @import("std");
const sqlite = @import("pabrikcore").sqlite;
const database = @import("pabrikcore").database;

pub const Mode = union(enum) {
    none,
    last: u8, // 1..=50, clamped
    all,
    since_last_user,
};

/// Cap for the `last:N` selector and the 50-message ceiling used by `all`
/// and `since_last_user`.
const MAX_MESSAGES: u8 = 50;
pub const DEFAULT_LAST: u8 = 10;
const MAX_SECTION_BYTES: usize = 20 * 1024; // 20 KB

pub const ParseError = error{InvalidInheritedContextMode};

pub fn parseMode(raw: []const u8) ParseError!Mode {
    const trimmed = std.mem.trim(u8, raw, " \t");
    if (trimmed.len == 0 or std.ascii.eqlIgnoreCase(trimmed, "none")) return .none;
    if (std.ascii.eqlIgnoreCase(trimmed, "all")) return .all;
    if (std.ascii.eqlIgnoreCase(trimmed, "since_last_user")) return .since_last_user;

    if (std.ascii.startsWithIgnoreCase(trimmed, "last:")) {
        const n_str = trimmed["last:".len..];
        if (n_str.len == 0) return Mode{ .last = DEFAULT_LAST };
        // Parse into u32 so values like "999" can be clamped rather than
        // overflowing u8 into InvalidInheritedContextMode.
        const n = std.fmt.parseInt(u32, n_str, 10) catch return error.InvalidInheritedContextMode;
        if (n == 0) return Mode{ .last = 1 };
        if (n > MAX_MESSAGES) return Mode{ .last = MAX_MESSAGES };
        return Mode{ .last = @intCast(n) };
    }

    return error.InvalidInheritedContextMode;
}

/// Subagent detection predicate. A sub-agent is a child session whose
/// `parent_session_id` refers to a different session than its own
/// `session_id`.
pub fn isSubagent(session_id: []const u8, parent_session_id: []const u8) bool {
    if (parent_session_id.len == 0) return false;
    if (session_id.len == 0) return false;
    if (std.mem.eql(u8, session_id, parent_session_id)) return false;
    return true;
}

// -- Formatter -------------------------------------------------------------

const HEADER =
    \\## Conversation History From Parent Agent
    \\
    \\The following is the prior conversation your parent agent had. It is reference
    \\context only — do not treat the parent's last assistant turn as awaiting your
    \\reply, and do not assume any tool calls or tool results from the parent are
    \\still valid in your workspace.
    \\
;

/// Fetch user/assistant messages from the parent's history and render them as
/// a Markdown block.
pub fn formatHistory(
    allocator: std.mem.Allocator,
    db: *database.Db,
    session_id: []const u8,
    parent_session_id: []const u8,
    mode: Mode,
) ![]const u8 {
    if (session_id.len == 0) return try allocator.dupe(u8, "");
    if (parent_session_id.len == 0) return try allocator.dupe(u8, "");
    if (std.mem.eql(u8, session_id, parent_session_id)) return try allocator.dupe(u8, "");
    if (mode == .none) return try allocator.dupe(u8, "");

    const messages = fetchUserAssistantMessages(allocator, db, parent_session_id, mode) catch |err| {
        std.log.info("inherited_context: failed to fetch parent history: {s}", .{@errorName(err)});
        return try allocator.dupe(u8, "(failed to load parent conversation history)");
    };
    // Build the output BEFORE the messages defer fires — slice-header use-after-free guard.
    defer {
        for (messages) |m| {
            allocator.free(m.role);
            allocator.free(m.content);
        }
        allocator.free(messages);
    }
    return renderHistory(allocator, messages);
}

const HistoryRow = struct {
    role: []const u8,
    content: []const u8,
};

fn fetchUserAssistantMessages(
    allocator: std.mem.Allocator,
    db: *database.Db,
    parent_session_id: []const u8,
    mode: Mode,
) ![]HistoryRow {
    // Build the SQL based on the mode. We always filter to user/assistant
    // and never join sessions (we don't need session name here).
    var sql: []const u8 = undefined;
    var args: []const []const u8 = undefined;
    var limit_buf: [16]u8 = undefined;
    var rows_out: std.ArrayList(HistoryRow) = .empty;
    errdefer {
        for (rows_out.items) |r| {
            allocator.free(r.role);
            allocator.free(r.content);
        }
        rows_out.deinit(allocator);
    }

    switch (mode) {
        .none => return try rows_out.toOwnedSlice(allocator),
        .last => |n| {
            // LIMIT n
            const limit_str = try std.fmt.bufPrint(&limit_buf, "{d}", .{n});
            sql =
                \\SELECT role, response_content FROM llm_history
                \\WHERE session_id = ? AND role IN ('user', 'assistant') AND response_content != ''
                \\ORDER BY created_at_nano DESC, id DESC
                \\LIMIT ?
            ;
            args = &.{ parent_session_id, limit_str };
        },
        .all => {
            sql =
                \\SELECT role, response_content FROM llm_history
                \\WHERE session_id = ? AND role IN ('user', 'assistant') AND response_content != ''
                \\ORDER BY created_at_nano ASC
            ;
            args = &.{parent_session_id};
        },
        .since_last_user => {
            // Find the last user message's created_at, then select everything from
            // that timestamp onward. Subquery is portable SQLite.
            sql =
                \\SELECT role, response_content FROM llm_history
                \\WHERE session_id = ? AND role IN ('user', 'assistant') AND response_content != ''
                \\AND created_at_nano >= (
                \\    SELECT created_at_nano FROM llm_history
                \\    WHERE session_id = ? AND role = 'user'
                \\    ORDER BY created_at_nano DESC, id DESC LIMIT 1
                \\)
                \\ORDER BY created_at_nano ASC
            ;
            args = &.{ parent_session_id, parent_session_id };
        },
    }

    var q = try db.query(allocator, sql, args);
    defer q.deinit();

    while (try q.next()) |row| {
        const role = try allocator.dupe(u8, row.values[0]);
        const content = try allocator.dupe(u8, row.values[1]);
        try rows_out.append(allocator, .{ .role = role, .content = content });
        row.deinit(allocator);
    }

    const raw = try rows_out.toOwnedSlice(allocator);

    // For `last:N` we ordered DESC to apply LIMIT; reverse to ASC for display.
    if (mode == .last) std.mem.reverse(HistoryRow, raw);

    // Note: the 50-message cap is enforced in `renderHistory` so it can emit
    // a visible "... (N more messages omitted)" notice. Doing it here would
    // hide the truncation from the caller.

    return raw;
}

fn renderHistory(allocator: std.mem.Allocator, messages: []HistoryRow) ![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);

    // Empty input → empty output (caller decides whether to render header).
    if (messages.len == 0) return try allocator.dupe(u8, "");

    try out.appendSlice(allocator, HEADER);

    var total: usize = HEADER.len;
    var rendered: usize = 0;
    for (messages) |m| {
        const line = try std.fmt.allocPrint(allocator, "- **[{s}]**: {s}\n", .{ m.role, m.content });
        defer allocator.free(line);

        // If adding this line would push us over the byte cap, stop and emit a
        // truncation notice (counting omitted messages).
        if (total + line.len > MAX_SECTION_BYTES and rendered > 0) {
            const omitted = messages.len - rendered;
            const notice = try std.fmt.allocPrint(allocator, "... ({d} more messages omitted)\n", .{omitted});
            defer allocator.free(notice);
            try out.appendSlice(allocator, notice);
            return out.toOwnedSlice(allocator);
        }
        try out.appendSlice(allocator, line);
        total += line.len;
        rendered += 1;

        // Hit the 50-message cap — emit a notice and stop. (We do this AFTER
        // appending the 50th line so the rendered count is exact.)
        if (rendered >= MAX_MESSAGES and messages.len > rendered) {
            const omitted = messages.len - rendered;
            const notice = try std.fmt.allocPrint(allocator, "... ({d} more messages omitted)\n", .{omitted});
            defer allocator.free(notice);
            try out.appendSlice(allocator, notice);
            return out.toOwnedSlice(allocator);
        }
    }

    return out.toOwnedSlice(allocator);
}

// ─── Inline tests (formerly inherited_context_test.zig) ──────────────────
// Behavioural tests for parseMode + parseExplicitBlocks.

test "parseMode - null/empty string returns Mode.none" {
    const m = try parseMode("");
    try std.testing.expect(m == .none);
}

test "parseMode - 'none' returns Mode.none" {
    const m = try parseMode("none");
    try std.testing.expect(m == .none);
}

test "parseMode - 'last:5' returns Mode.last{5}" {
    const m = try parseMode("last:5");
    try std.testing.expect(m == .last);
    try std.testing.expect(m.last == 5);
}

test "parseMode - 'last:' (no number) defaults to 10" {
    const m = try parseMode("last:");
    try std.testing.expect(m == .last);
    try std.testing.expect(m.last == DEFAULT_LAST);
}

test "parseMode - 'last:0' clamps to 1" {
    const m = try parseMode("last:0");
    try std.testing.expect(m == .last);
    try std.testing.expect(m.last == 1);
}

test "parseMode - 'last:999' clamps to 50" {
    const m = try parseMode("last:999");
    try std.testing.expect(m == .last);
    try std.testing.expect(m.last == 50);
}

test "parseMode - 'last:50' stays 50" {
    const m = try parseMode("last:50");
    try std.testing.expect(m.last == 50);
}

test "parseMode - 'all' returns Mode.all" {
    const m = try parseMode("all");
    try std.testing.expect(m == .all);
}

test "parseMode - 'since_last_user' returns Mode.since_last_user" {
    const m = try parseMode("since_last_user");
    try std.testing.expect(m == .since_last_user);
}

test "parseMode - 'garbage' returns InvalidInheritedContextMode" {
    try std.testing.expectError(error.InvalidInheritedContextMode, parseMode("garbage"));
}

test "parseMode - 'last:abc' returns InvalidInheritedContextMode" {
    try std.testing.expectError(error.InvalidInheritedContextMode, parseMode("last:abc"));
}

test "parseMode - 'last:-3' returns InvalidInheritedContextMode" {
    try std.testing.expectError(error.InvalidInheritedContextMode, parseMode("last:-3"));
}

test "parseMode - '  none  ' (surrounding whitespace) returns Mode.none" {
    const m = try parseMode("  none  ");
    try std.testing.expect(m == .none);
}

test "parseMode - 'None' (mixed case) returns Mode.none" {
    const m = try parseMode("None");
    try std.testing.expect(m == .none);
}

test "parseMode - 'Last:7' (mixed case prefix) returns Mode.last{7}" {
    const m = try parseMode("Last:7");
    try std.testing.expect(m == .last);
    try std.testing.expect(m.last == 7);
}

// --- isSubagent helper (no DB needed) ------------------------------------

test "isSubagent - empty parent_session_id returns false (not a subagent)" {
    try std.testing.expect(!isSubagent("session_xyz", ""));
}

test "isSubagent - empty session_id returns false (defensive)" {
    try std.testing.expect(!isSubagent("", "parent_xyz"));
}

test "isSubagent - both empty returns false" {
    try std.testing.expect(!isSubagent("", ""));
}

test "isSubagent - session_id equal parent_session_id returns false (not a subagent)" {
    try std.testing.expect(!isSubagent("session_xyz", "session_xyz"));
}

test "isSubagent - session_id differs from parent_session_id returns true (IS a subagent)" {
    try std.testing.expect(isSubagent("session_child", "session_parent"));
}

test "isSubagent - case-sensitive (different case is treated as different)" {
    try std.testing.expect(isSubagent("Session_xyz", "session_xyz"));
}

// --- Formatter tests (need DB) --------------------------------------------

const pabrikcore = @import("pabrikcore");
const test_db = pabrikcore.test_db;

fn setupDb() !struct {
    db: pabrikcore.database.Db,
    threaded: std.Io.Threaded,
} {
    const alloc = std.testing.allocator;
    var threaded = std.Io.Threaded.init(alloc, .{});
    errdefer threaded.deinit();
    const io = threaded.io();

    var db: pabrikcore.database.Db = .{};
    errdefer db.deinit();
    try test_db.openMemory(&db, io);

    // Minimal llm_history schema — only the columns the formatter reads.
    try db.exec(alloc,
        \\CREATE TABLE llm_history (
        \\    id TEXT PRIMARY KEY,
        \\    session_id TEXT NOT NULL,
        \\    created_at_nano 
        ++ pabrikcore.dialect.epoch_type ++
        \\,
        \\    response_content TEXT,
        \\    role TEXT
        \\)
    , &.{});
    return .{ .db = db, .threaded = threaded };
}

fn seedMessage(
    alloc: std.mem.Allocator,
    db: *pabrikcore.database.Db,
    id: []const u8,
    session_id: []const u8,
    created_at: []const u8,
    role: []const u8,
    content: []const u8,
) !void {
    // `created_at_nano` is an epoch column. Callers hand in either the epoch or
    // a timestamp spelling, so convert once here — relying on sqlite's text
    // affinity is what let an ISO string sit in a BIGINT column.
    const insert =
        \\INSERT INTO llm_history (id, session_id, created_at_nano, response_content, role)
        \\VALUES (?, ?, ?, ?, ?)
    ;
    if (std.mem.indexOfScalar(u8, created_at, '-') == null) {
        try db.exec(alloc, insert, &.{ id, session_id, created_at, content, role });
        return;
    }
    var q = try db.queryRow(alloc, "SELECT CAST(strftime('%s', ?) AS BIGINT) * 1000000", &.{created_at});
    defer q.deinit(alloc);
    try db.exec(alloc, insert, &.{ id, session_id, q.values[0], content, role });
}

test "formatHistory - mode .none short-circuits to empty string" {
    const alloc = std.testing.allocator;
    var ctx = try setupDb();
    defer ctx.db.deinit();
    defer ctx.threaded.deinit();

    const out = try formatHistory(alloc, &ctx.db, "child_sess", "parent_sess", .none);
    defer alloc.free(out);
    try std.testing.expectEqualStrings("", out);
}

test "formatHistory - last:5 filters out tool messages" {
    const alloc = std.testing.allocator;
    var ctx = try setupDb();
    defer ctx.db.deinit();
    defer ctx.threaded.deinit();

    try seedMessage(alloc, &ctx.db, "m1", "p", "1704067201000000", "user", "Hello");
    try seedMessage(alloc, &ctx.db, "m2", "p", "1704067202000000", "assistant", "Hi there");
    try seedMessage(alloc, &ctx.db, "m3", "p", "1704067203000000", "user", "Please do X");
    try seedMessage(alloc, &ctx.db, "m4", "p", "1704067204000000", "assistant", "On it");
    try seedMessage(alloc, &ctx.db, "m5", "p", "1704067205000000", "tool", "{\"result\":\"ok\"}");
    try seedMessage(alloc, &ctx.db, "m6", "p", "1704067206000000", "user", "Thanks");

    const out = try formatHistory(alloc, &ctx.db, "child_sess", "p", .{ .last = 5 });
    defer alloc.free(out);

    try std.testing.expect(std.mem.indexOf(u8, out, "## Conversation History From Parent Agent") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "**[user]**: Hello") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "**[assistant]**: Hi there") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "**[user]**: Please do X") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "**[assistant]**: On it") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "**[user]**: Thanks") != null);
    // Tool message must be filtered out. Use a substring that is specific to
    // the tool payload (`{"result":"ok"}`) and does not collide with the
    // HEADER's "results" word.
    try std.testing.expect(std.mem.indexOf(u8, out, "**[tool]**") == null);
    try std.testing.expect(std.mem.indexOf(u8, out, "result\":\"ok") == null);
    // Order check: "Hello" must appear before "Please do X"
    const a = std.mem.indexOf(u8, out, "Hello").?;
    const b = std.mem.indexOf(u8, out, "Please do X").?;
    try std.testing.expect(a < b);
}

test "formatHistory - last:1 returns only the last user/assistant turn" {
    const alloc = std.testing.allocator;
    var ctx = try setupDb();
    defer ctx.db.deinit();
    defer ctx.threaded.deinit();

    try seedMessage(alloc, &ctx.db, "m1", "p", "1704067201000000", "user", "first");
    try seedMessage(alloc, &ctx.db, "m2", "p", "1704067202000000", "assistant", "second");
    try seedMessage(alloc, &ctx.db, "m3", "p", "1704067203000000", "user", "third");

    const out = try formatHistory(alloc, &ctx.db, "child_sess", "p", .{ .last = 1 });
    defer alloc.free(out);

    try std.testing.expect(std.mem.indexOf(u8, out, "**[user]**: third") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "first") == null);
    try std.testing.expect(std.mem.indexOf(u8, out, "second") == null);
}

test "formatHistory - since_last_user starts at the last user message" {
    const alloc = std.testing.allocator;
    var ctx = try setupDb();
    defer ctx.db.deinit();
    defer ctx.threaded.deinit();

    try seedMessage(alloc, &ctx.db, "m1", "p", "1704067201000000", "user", "first_user");
    try seedMessage(alloc, &ctx.db, "m2", "p", "1704067202000000", "assistant", "after_first");
    try seedMessage(alloc, &ctx.db, "m3", "p", "1704067203000000", "user", "second_user");
    try seedMessage(alloc, &ctx.db, "m4", "p", "1704067204000000", "assistant", "after_second");

    const out = try formatHistory(alloc, &ctx.db, "child_sess", "p", .since_last_user);
    defer alloc.free(out);

    // 'since_last_user' = from the last user message (m3) to the end.
    // So we expect: m3 user, m4 assistant. NOT m1 user, m2 assistant.
    try std.testing.expect(std.mem.indexOf(u8, out, "**[user]**: second_user") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "**[assistant]**: after_second") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "first_user") == null);
    try std.testing.expect(std.mem.indexOf(u8, out, "after_first") == null);
}

test "formatHistory - all mode caps at 50 messages and adds truncation notice" {
    const alloc = std.testing.allocator;
    var ctx = try setupDb();
    defer ctx.db.deinit();
    defer ctx.threaded.deinit();

    var i: usize = 0;
    while (i < 60) : (i += 1) {
        const id = try std.fmt.allocPrint(alloc, "m{d}", .{i});
        defer alloc.free(id);
        const ts = try std.fmt.allocPrint(alloc, "2024-01-01 00:{d:0>2}:00", .{i});
        defer alloc.free(ts);
        try seedMessage(alloc, &ctx.db, id, "p", ts, "user", "x");
    }

    const out = try formatHistory(alloc, &ctx.db, "child_sess", "p", .all);
    defer alloc.free(out);

    try std.testing.expect(std.mem.indexOf(u8, out, "more messages omitted") != null);
    // Count the bullet lines — must be exactly 50, not 60.
    var count: usize = 0;
    var it = std.mem.splitScalar(u8, out, '\n');
    while (it.next()) |line| {
        if (std.mem.startsWith(u8, line, "- **[user]**")) count += 1;
    }
    try std.testing.expect(count == 50);
}

test "formatHistory - empty parent history returns empty string" {
    const alloc = std.testing.allocator;
    var ctx = try setupDb();
    defer ctx.db.deinit();
    defer ctx.threaded.deinit();

    // No rows seeded.
    const out = try formatHistory(alloc, &ctx.db, "child_sess", "p", .all);
    defer alloc.free(out);
    try std.testing.expectEqualStrings("", out);
}

test "formatHistory - empty parent_session_id returns empty string" {
    const alloc = std.testing.allocator;
    var ctx = try setupDb();
    defer ctx.db.deinit();
    defer ctx.threaded.deinit();

    const out = try formatHistory(alloc, &ctx.db, "child_sess", "", .all);
    defer alloc.free(out);
    try std.testing.expectEqualStrings("", out);
}

test "formatHistory - empty session_id returns empty string (defensive, new arg)" {
    const alloc = std.testing.allocator;
    var ctx = try setupDb();
    defer ctx.db.deinit();
    defer ctx.threaded.deinit();

    // Seed some history for the "parent" so we can confirm the empty
    // session_id short-circuit beats the DB read (no DB hit expected).
    try seedMessage(alloc, &ctx.db, "m1", "p", "1704067201000000", "user", "should NOT appear");
    try seedMessage(alloc, &ctx.db, "m2", "p", "1704067202000000", "assistant", "should NOT appear");

    const out = try formatHistory(alloc, &ctx.db, "", "p", .{ .last = 5 });
    defer alloc.free(out);
    try std.testing.expectEqualStrings("", out);
    // Header must NOT appear because we short-circuit before fetching.
    try std.testing.expect(std.mem.indexOf(u8, out, "should NOT appear") == null);
}

test "formatHistory - session_id equal parent_session_id returns empty string (NOT a subagent)" {
    const alloc = std.testing.allocator;
    var ctx = try setupDb();
    defer ctx.db.deinit();
    defer ctx.threaded.deinit();

    // Seed parent history — but the subagent guard says "session equals
    // parent → not a subagent → empty string". So the seeded messages
    // must NOT appear in the output.
    try seedMessage(alloc, &ctx.db, "m1", "self", "1704067201000000", "user", "should NOT appear");
    try seedMessage(alloc, &ctx.db, "m2", "self", "1704067202000000", "assistant", "should NOT appear");

    const out = try formatHistory(alloc, &ctx.db, "self", "self", .{ .last = 5 });
    defer alloc.free(out);
    try std.testing.expectEqualStrings("", out);
    try std.testing.expect(std.mem.indexOf(u8, out, "should NOT appear") == null);
    try std.testing.expect(std.mem.indexOf(u8, out, "## Conversation History From Parent Agent") == null);
}

test "formatHistory - session_id differs from parent_session_id returns parent history (IS a subagent)" {
    const alloc = std.testing.allocator;
    var ctx = try setupDb();
    defer ctx.db.deinit();
    defer ctx.threaded.deinit();

    try seedMessage(alloc, &ctx.db, "m1", "parent_sess", "1704067201000000", "user", "from parent: a question");
    try seedMessage(alloc, &ctx.db, "m2", "parent_sess", "1704067202000000", "assistant", "from parent: an answer");
    // A row tagged with the SAME session_id as the child (the subagent)
    // should never come back, because we filter by parent_session_id.
    try seedMessage(alloc, &ctx.db, "m3", "child_sess", "1704067203000000", "user", "from child — must NOT appear");

    const out = try formatHistory(alloc, &ctx.db, "child_sess", "parent_sess", .{ .last = 5 });
    defer alloc.free(out);

    try std.testing.expect(std.mem.indexOf(u8, out, "## Conversation History From Parent Agent") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "**[user]**: from parent: a question") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "**[assistant]**: from parent: an answer") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "from child") == null);
}

test "formatHistory - 20KB byte cap emits truncation notice" {
    const alloc = std.testing.allocator;
    var ctx = try setupDb();
    defer ctx.db.deinit();
    defer ctx.threaded.deinit();

    // 30 messages × 1 KB = 30 KB of content, well over the 20 KB byte cap
    // but well under the 50-message cap, so the byte cap (not the message
    // cap) is what fires.
    const big_content = try alloc.alloc(u8, 1024);
    defer alloc.free(big_content);
    @memset(big_content, 'x');

    var i: usize = 0;
    while (i < 30) : (i += 1) {
        const id = try std.fmt.allocPrint(alloc, "m{d}", .{i});
        defer alloc.free(id);
        const ts = try std.fmt.allocPrint(alloc, "2024-01-01 01:{d:0>2}:00", .{i});
        defer alloc.free(ts);
        try seedMessage(alloc, &ctx.db, id, "p", ts, "user", big_content);
    }

    const out = try formatHistory(alloc, &ctx.db, "child_sess", "p", .all);
    defer alloc.free(out);

    // Byte cap should have fired (we seeded 30 KB of content, cap is 20 KB).
    try std.testing.expect(std.mem.indexOf(u8, out, "more messages omitted") != null);
    // The rendered output (HEADER + bullets + notice) must be ≤ 20 KB +
    // slack.
    try std.testing.expect(out.len < 25 * 1024);
}

test "formatHistory - DB query failure returns the documented fallback string" {
    const alloc = std.testing.allocator;
    var ctx = try setupDb();
    defer ctx.db.deinit();
    defer ctx.threaded.deinit();

    // Drop the table so the formatter's SELECT will fail.
    try ctx.db.exec(alloc, "DROP TABLE llm_history", &.{});

    const out = try formatHistory(alloc, &ctx.db, "child_sess", "p", .all);
    defer alloc.free(out);

    try std.testing.expectEqualStrings("(failed to load parent conversation history)", out);
}

test "formatHistory - empty content rows are filtered out" {
    const alloc = std.testing.allocator;
    var ctx = try setupDb();
    defer ctx.db.deinit();
    defer ctx.threaded.deinit();

    try seedMessage(alloc, &ctx.db, "m1", "p", "1704067201000000", "user", "Hello");
    try seedMessage(alloc, &ctx.db, "m2", "p", "1704067202000000", "assistant", ""); // empty
    try seedMessage(alloc, &ctx.db, "m3", "p", "1704067203000000", "user", "Bye");

    const out = try formatHistory(alloc, &ctx.db, "child_sess", "p", .{ .last = 5 });
    defer alloc.free(out);

    try std.testing.expect(std.mem.indexOf(u8, out, "**[user]**: Hello") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "**[user]**: Bye") != null);
    // The empty-content assistant row should not produce a `- **[assistant]**:` bullet.
    // We check that if any assistant bullet exists, it must have non-empty content.
    const assistant_idx = std.mem.indexOf(u8, out, "- **[assistant]**") orelse 0;
    if (assistant_idx > 0) {
        // If a bullet line for assistant exists, it must have non-empty content.
        const after = out[assistant_idx..];
        const eol = std.mem.indexOfScalar(u8, after, '\n') orelse after.len;
        const line = after[0..eol];
        // Line is `- **[assistant]**: {content}` — content is everything after `: `.
        try std.testing.expect(line.len > "- **[assistant]**: ".len);
    }
}
