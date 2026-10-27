const std = @import("std");
const pabrikcore = @import("pabrikcore");
const test_db = pabrikcore.test_db;
const LLMHistory = @import("llm_history_row.zig").LLMHistory;

const sqlite = pabrikcore.sqlite;
const database = pabrikcore.database;
const testing = std.testing;
const Backend = database.Db;

pub fn GetLLMHistoriesInput(comptime DB: type) type {
    return struct {
        allocator: std.mem.Allocator,
        db: DB,
        session_id: []const u8,
    };
}

pub fn getLLMHistories(
    comptime DB: type,
    obj: GetLLMHistoriesInput(DB),
) ![]LLMHistory {
    const allocator = obj.allocator;
    const db = obj.db;
    const session_id = obj.session_id;

    var results: std.ArrayList(LLMHistory) = .empty;

    const sql =
        \\SELECT
        \\    h.id,
        \\    h.session_id,
        \\    h.model,
        \\    h.created_at_nano AS created_at,
        \\    h.response_content,
        \\    h.finish_reason,
        \\    COALESCE(h.role, 'assistant'),
        \\    COALESCE(h.tool_calls_json, ''),
        \\    COALESCE(h.reasoning_content, ''),
        \\    COALESCE(h.reasoning_id, ''),
        \\    COALESCE(h.reasoning_encrypted_content, ''),
        \\    COALESCE(h.agent, 'Agent'),
        \\    COALESCE(s.name, ''),
        \\    COALESCE(h.loop_index, 0),
        \\    COALESCE(h.tool_name, ''),
        \\    COALESCE(h.parent_session_id, ''),
        \\    COALESCE(h.temperature, 0.2),
        \\    COALESCE(h.is_thinking, 0),
        \\    COALESCE(h.prompt_tokens, 0),
        \\    COALESCE(h.completion_tokens, 0),
        \\    COALESCE(h.total_tokens, 0),
        \\    COALESCE(h.is_input, 0),
        \\    COALESCE(h.is_output, 0),
        \\    COALESCE(h.diffview_before, ''),
        \\    COALESCE(h.diffview_after, ''),
        \\    COALESCE(h.image_url, ''),
        \\    COALESCE(h.video_url, ''),
        \\    COALESCE(h.tool_call_id, ''),
        \\    COALESCE(h.file_attachments, '')
        \\FROM llm_history h
        \\LEFT JOIN sessions s ON h.session_id = s.id
        \\WHERE h.session_id = ?
        \\AND (h.is_feed_to_llm = 1 OR h.is_feed_to_llm IS NULL)
        \\ORDER BY h.created_at_nano ASC
    ;

    var rows = try db.query(allocator, sql, &.{session_id});
    defer rows.deinit();

    while (try rows.next()) |row| {
        const parent_session_id_str = row.values[15];
        const diffview_before_str = row.values[23];
        const diffview_after_str = row.values[24];
        const image_url_str = row.values[25];
        const video_url_str = row.values[26];
        const history = LLMHistory{
            .id = try allocator.dupe(u8, row.values[0]),
            .session_id = try allocator.dupe(u8, row.values[1]),
            .model = try allocator.dupe(u8, row.values[2]),
            .created_at = try allocator.dupe(u8, row.values[3]),
            .response_content = try allocator.dupe(u8, row.values[4]),
            .finish_reason = try allocator.dupe(u8, row.values[5]),
            .role = try allocator.dupe(u8, row.values[6]),
            .tool_calls_json = try allocator.dupe(u8, row.values[7]),
            .reasoning_content = if (row.values[8].len > 0) try allocator.dupe(u8, row.values[8]) else null,
            .reasoning_id = if (row.values[9].len > 0) try allocator.dupe(u8, row.values[9]) else null,
            .reasoning_encrypted_content = if (row.values[10].len > 0) try allocator.dupe(u8, row.values[10]) else null,
            .agent = try allocator.dupe(u8, row.values[11]),
            .session_name = try allocator.dupe(u8, row.values[12]),
            .loop_index = std.fmt.parseInt(u32, row.values[13], 10) catch 0,
            .tool_name = try allocator.dupe(u8, row.values[14]),
            .parent_session_id = if (parent_session_id_str.len > 0) try allocator.dupe(u8, parent_session_id_str) else null,
            .temperature = std.fmt.parseFloat(f32, row.values[16]) catch 0.2,
            .is_thinking = std.mem.eql(u8, row.values[17], "1"),
            .prompt_tokens = std.fmt.parseInt(u32, row.values[18], 10) catch 0,
            .completion_tokens = std.fmt.parseInt(u32, row.values[19], 10) catch 0,
            .total_tokens = std.fmt.parseInt(u32, row.values[20], 10) catch 0,
            .is_input = parseRowBool(row.values[21]),
            .is_output = parseRowBool(row.values[22]),
            .diffview_before = if (diffview_before_str.len > 0) try allocator.dupe(u8, diffview_before_str) else null,
            .diffview_after = if (diffview_after_str.len > 0) try allocator.dupe(u8, diffview_after_str) else null,
            .image_urls = if (image_url_str.len > 0) blk: {
                var urls = std.ArrayList([]const u8).empty;
                errdefer {
                    for (urls.items) |u| allocator.free(u);
                    urls.deinit(allocator);
                }
                var iter = std.mem.splitScalar(u8, image_url_str, '|');
                while (iter.next()) |url| {
                    if (url.len > 0) {
                        try urls.append(allocator, try allocator.dupe(u8, url));
                    }
                }
                // CRITICAL: use toOwnedSlice (not `urls.items`) so the
                // returned slice is sized to `items.len`.
                break :blk if (urls.items.len > 0) try urls.toOwnedSlice(allocator) else null;
            } else null,
            .video_urls = if (video_url_str.len > 0) blk: {
                var urls = std.ArrayList([]const u8).empty;
                errdefer {
                    for (urls.items) |u| allocator.free(u);
                    urls.deinit(allocator);
                }
                var iter = std.mem.splitScalar(u8, video_url_str, '|');
                while (iter.next()) |url| {
                    if (url.len > 0) {
                        try urls.append(allocator, try allocator.dupe(u8, url));
                    }
                }
                break :blk if (urls.items.len > 0) try urls.toOwnedSlice(allocator) else null;
            } else null,
            .tool_call_id = if (row.values[27].len > 0) try allocator.dupe(u8, row.values[27]) else null,
            .file_attachments = if (row.values[28].len > 0) try allocator.dupe(u8, row.values[28]) else null,
        };
        try results.append(allocator, history);
        row.deinit(allocator);
    }

    return results.toOwnedSlice(allocator);
}

fn parseRowBool(s: []const u8) bool {
    if (s.len == 0) return false;
    return s[0] == '1';
}

// ─── Tests
// ──────────────────────────────────────────────────────────────────
// `getLLMHistories` is a 24-column SELECT with a LEFT JOIN, COALESCE

const IdxAgent = 11;
const IdxSessionName = 12;
const IdxLoopIndex = 13;
const IdxToolName = 14;
const IdxParentSession = 15;
const IdxTemperature = 16;
const IdxIsThinking = 17;
const IdxPromptTokens = 18;
const IdxCompletionTokens = 19;
const IdxTotalTokens = 20;
const IdxIsInput = 21;
const IdxIsOutput = 22;
const IdxDiffviewBefore = 23;
const IdxDiffviewAfter = 24;
const IdxImageUrl = 25;
const IdxToolCallId = 26;

fn setupDb() !struct { db: database.Db, threaded: std.Io.Threaded } {
    const alloc = testing.allocator;
    var threaded = std.Io.Threaded.init(alloc, .{});
    errdefer threaded.deinit();
    const io = threaded.io();
    var db: database.Db = .{};
    errdefer db.deinit();
    try test_db.openMemory(&db, io);
    // Minimum schema that satisfies the production SELECT.
    try db.exec(alloc,
        \\CREATE TABLE llm_history (
        \\    id TEXT PRIMARY KEY,
        \\    session_id TEXT,
        \\    model TEXT,
        \\    created_at_nano TEXT,
        \\    response_content TEXT,
        \\    finish_reason TEXT,
        \\    role TEXT,
        \\    tool_calls_json TEXT,
        \\    tool_call_id TEXT,
        \\    reasoning_content TEXT,
        \\    reasoning_id TEXT,
        \\    reasoning_encrypted_content TEXT,
        \\    is_feed_to_llm INTEGER DEFAULT 1,
        \\    agent TEXT,
        \\    loop_index INTEGER DEFAULT 0,
        \\    temperature REAL DEFAULT 0.2,
        \\    is_thinking INTEGER DEFAULT 0,
        \\    tool_name TEXT,
        \\    parent_session_id TEXT,
        \\    prompt_tokens INTEGER DEFAULT 0,
        \\    completion_tokens INTEGER DEFAULT 0,
        \\    total_tokens INTEGER DEFAULT 0,
        \\    is_input INTEGER DEFAULT 0,
        \\    is_output INTEGER DEFAULT 0,
        \\    diffview_before TEXT,
        \\    diffview_after TEXT,
        \\    image_url TEXT,
        \\    video_url TEXT,
        \\    file_attachments TEXT
        \\)
    , &.{});
    try db.exec(alloc,
        \\CREATE TABLE sessions (
        \\    id TEXT PRIMARY KEY,
        \\    name TEXT
        \\)
    , &.{});
    return .{ .db = db, .threaded = threaded };
}

/// Insert a llm_history row with sensible defaults. Caller can override
/// individual fields by passing custom `image_url`, `is_feed_to_llm`, etc.
fn seedRow(
    db: *database.Db,
    id: []const u8,
    session_id: []const u8,
    created_at: []const u8,
) !void {
    try db.exec(testing.allocator, "INSERT INTO llm_history (id, session_id, created_at_nano, response_content, role, is_feed_to_llm) " ++
        "VALUES (?, ?, ?, '', 'assistant', 1)", &.{ id, session_id, created_at });
}

/// Free every `LLMHistory` returned by `getLLMHistories` — the caller
/// owns each row's heap slices.
fn freeHistories(histories: []LLMHistory) void {
    for (histories) |*h| h.deinit(testing.allocator);
}

test "getLLMHistories returns an empty slice when there are no rows" {
    var s = try setupDb();
    defer s.db.deinit();
    defer s.threaded.deinit();
    const result = try getLLMHistories(*Backend, .{ .allocator = testing.allocator, .db = &s.db, .session_id = "s1" });
    defer testing.allocator.free(result);
    try testing.expectEqual(@as(usize, 0), result.len);
}

test "getLLMHistories returns rows for the matching session_id in created_at ASC order" {
    var s = try setupDb();
    defer s.db.deinit();
    defer s.threaded.deinit();

    try seedRow(&s.db, "h1", "s1", "2024-01-01 00:00:00");
    try seedRow(&s.db, "h2", "s1", "2025-01-01 00:00:00");
    try seedRow(&s.db, "h3", "s2", "2025-06-01 00:00:00"); // different session
    try seedRow(&s.db, "h4", "s1", "2024-06-01 00:00:00");

    const result = try getLLMHistories(*Backend, .{ .allocator = testing.allocator, .db = &s.db, .session_id = "s1" });
    defer {
        freeHistories(result);
        testing.allocator.free(result);
    }
    try testing.expectEqual(@as(usize, 3), result.len);
    try testing.expectEqualStrings("h1", result[0].id);
    try testing.expectEqualStrings("h4", result[1].id);
    try testing.expectEqualStrings("h2", result[2].id);
}

test "getLLMHistories LEFT JOIN falls back to empty session_name when no session row exists" {
    var s = try setupDb();
    defer s.db.deinit();
    defer s.threaded.deinit();
    try seedRow(&s.db, "h1", "orphan", "2025-01-01 00:00:00");
    // No row in `sessions` for "orphan" — COALESCE returns ''.

    const result = try getLLMHistories(*Backend, .{ .allocator = testing.allocator, .db = &s.db, .session_id = "orphan" });
    defer {
        freeHistories(result);
        testing.allocator.free(result);
    }
    try testing.expectEqual(@as(usize, 1), result.len);
    try testing.expectEqualStrings("", result[0].session_name);
}

test "getLLMHistories LEFT JOIN populates session_name when the session row exists" {
    var s = try setupDb();
    defer s.db.deinit();
    defer s.threaded.deinit();
    try s.db.exec(testing.allocator, "INSERT INTO sessions (id, name) VALUES ('s_named', 'My Chat')", &.{});
    try seedRow(&s.db, "h1", "s_named", "2025-01-01 00:00:00");

    const result = try getLLMHistories(*Backend, .{ .allocator = testing.allocator, .db = &s.db, .session_id = "s_named" });
    defer {
        freeHistories(result);
        testing.allocator.free(result);
    }
    try testing.expectEqualStrings("My Chat", result[0].session_name);
}

test "getLLMHistories parses numeric fields (loop_index, tokens, temperature)" {
    var s = try setupDb();
    defer s.db.deinit();
    defer s.threaded.deinit();
    try s.db.exec(testing.allocator, "INSERT INTO llm_history (id, session_id, created_at_nano, loop_index, prompt_tokens, completion_tokens, total_tokens, temperature) " ++
        "VALUES ('h', 's', '2025-01-01', 7, 100, 50, 150, 0.7)", &.{});

    const result = try getLLMHistories(*Backend, .{ .allocator = testing.allocator, .db = &s.db, .session_id = "s" });
    defer {
        freeHistories(result);
        testing.allocator.free(result);
    }
    try testing.expectEqual(@as(u32, 7), result[0].loop_index);
    try testing.expectEqual(@as(u32, 100), result[0].prompt_tokens);
    try testing.expectEqual(@as(u32, 50), result[0].completion_tokens);
    try testing.expectEqual(@as(u32, 150), result[0].total_tokens);
    try testing.expectEqual(@as(f32, 0.7), result[0].temperature);
}

test "getLLMHistories parses bool flags (is_input, is_output, is_thinking)" {
    var s = try setupDb();
    defer s.db.deinit();
    defer s.threaded.deinit();
    try s.db.exec(testing.allocator, "INSERT INTO llm_history (id, session_id, created_at_nano, is_input, is_output, is_thinking) " ++
        "VALUES ('h', 's', '2025-01-01', 1, 0, 1)", &.{});

    const result = try getLLMHistories(*Backend, .{ .allocator = testing.allocator, .db = &s.db, .session_id = "s" });
    defer {
        freeHistories(result);
        testing.allocator.free(result);
    }
    try testing.expect(result[0].is_input);
    try testing.expect(!result[0].is_output);
    try testing.expect(result[0].is_thinking);
}

test "getLLMHistories filters out rows where is_feed_to_llm = 0" {
    var s = try setupDb();
    defer s.db.deinit();
    defer s.threaded.deinit();
    try s.db.exec(testing.allocator, "INSERT INTO llm_history (id, session_id, created_at_nano, is_feed_to_llm) " ++
        "VALUES ('h_yes', 's', '2025-01-01', 1)", &.{});
    try s.db.exec(testing.allocator, "INSERT INTO llm_history (id, session_id, created_at_nano, is_feed_to_llm) " ++
        "VALUES ('h_no',  's', '2025-01-02', 0)", &.{});

    const result = try getLLMHistories(*Backend, .{ .allocator = testing.allocator, .db = &s.db, .session_id = "s" });
    defer {
        freeHistories(result);
        testing.allocator.free(result);
    }
    try testing.expectEqual(@as(usize, 1), result.len);
    try testing.expectEqualStrings("h_yes", result[0].id);
}

test "getLLMHistories includes rows where is_feed_to_llm is NULL (treats NULL as 1)" {
    var s = try setupDb();
    defer s.db.deinit();
    defer s.threaded.deinit();
    try s.db.exec(testing.allocator, "INSERT INTO llm_history (id, session_id, created_at_nano, is_feed_to_llm) " ++
        "VALUES ('h_null', 's', '2025-01-01', NULL)", &.{});

    const result = try getLLMHistories(*Backend, .{ .allocator = testing.allocator, .db = &s.db, .session_id = "s" });
    defer {
        freeHistories(result);
        testing.allocator.free(result);
    }
    try testing.expectEqual(@as(usize, 1), result.len);
    try testing.expectEqualStrings("h_null", result[0].id);
}

test "getLLMHistories splits pipe-separated image_url into image_urls array" {
    var s = try setupDb();
    defer s.db.deinit();
    defer s.threaded.deinit();
    try s.db.exec(testing.allocator, "INSERT INTO llm_history (id, session_id, created_at_nano, image_url) " ++
        "VALUES ('h', 's', '2025-01-01', 'url1||url2||url3')", &.{});

    const result = try getLLMHistories(*Backend, .{ .allocator = testing.allocator, .db = &s.db, .session_id = "s" });
    defer {
        freeHistories(result);
        testing.allocator.free(result);
    }
    try testing.expectEqual(@as(usize, 3), result[0].image_urls.?.len);
    try testing.expectEqualStrings("url1", result[0].image_urls.?[0]);
    try testing.expectEqualStrings("url2", result[0].image_urls.?[1]);
    try testing.expectEqualStrings("url3", result[0].image_urls.?[2]);
}

test "getLLMHistories image_urls is null when image_url column is empty" {
    var s = try setupDb();
    defer s.db.deinit();
    defer s.threaded.deinit();
    try s.db.exec(testing.allocator, "INSERT INTO llm_history (id, session_id, created_at_nano, image_url) " ++
        "VALUES ('h', 's', '2025-01-01', '')", &.{});

    const result = try getLLMHistories(*Backend, .{ .allocator = testing.allocator, .db = &s.db, .session_id = "s" });
    defer {
        freeHistories(result);
        testing.allocator.free(result);
    }
    try testing.expect(result[0].image_urls == null);
}

test "getLLMHistories keeps a single image_url as a one-element array (no leading/trailing ||)" {
    var s = try setupDb();
    defer s.db.deinit();
    defer s.threaded.deinit();
    try s.db.exec(testing.allocator, "INSERT INTO llm_history (id, session_id, created_at_nano, image_url) " ++
        "VALUES ('h', 's', '2025-01-01', 'only-one')", &.{});

    const result = try getLLMHistories(*Backend, .{ .allocator = testing.allocator, .db = &s.db, .session_id = "s" });
    defer {
        freeHistories(result);
        testing.allocator.free(result);
    }
    try testing.expectEqual(@as(usize, 1), result[0].image_urls.?.len);
    try testing.expectEqualStrings("only-one", result[0].image_urls.?[0]);
}

test "getLLMHistories sets nullable fields to null when DB column is empty" {
    var s = try setupDb();
    defer s.db.deinit();
    defer s.threaded.deinit();
    try seedRow(&s.db, "h", "s", "2025-01-01 00:00:00");
    // All nullable columns are empty by default in the seedRow call.

    const result = try getLLMHistories(*Backend, .{ .allocator = testing.allocator, .db = &s.db, .session_id = "s" });
    defer {
        freeHistories(result);
        testing.allocator.free(result);
    }
    try testing.expect(result[0].reasoning_content == null);
    try testing.expect(result[0].parent_session_id == null);
    try testing.expect(result[0].diffview_before == null);
    try testing.expect(result[0].diffview_after == null);
    try testing.expect(result[0].image_urls == null);
    try testing.expect(result[0].tool_call_id == null);
}

test "getLLMHistories populates nullable fields when DB has content" {
    var s = try setupDb();
    defer s.db.deinit();
    defer s.threaded.deinit();
    try s.db.exec(testing.allocator, "INSERT INTO llm_history (id, session_id, created_at_nano, reasoning_content, parent_session_id, " ++
        "diffview_before, diffview_after, tool_call_id) " ++
        "VALUES ('h', 's', '2025-01-01', 'r', 'p', 'b', 'a', 't')", &.{});

    const result = try getLLMHistories(*Backend, .{ .allocator = testing.allocator, .db = &s.db, .session_id = "s" });
    defer {
        freeHistories(result);
        testing.allocator.free(result);
    }
    try testing.expectEqualStrings("r", result[0].reasoning_content.?);
    try testing.expectEqualStrings("p", result[0].parent_session_id.?);
    try testing.expectEqualStrings("b", result[0].diffview_before.?);
    try testing.expectEqualStrings("a", result[0].diffview_after.?);
    try testing.expectEqualStrings("t", result[0].tool_call_id.?);
}

// Silence "unused" warnings on the column-index constants — they're
// documentation, not yet used by the tests above.
comptime {
    _ = IdxAgent;
    _ = IdxSessionName;
    _ = IdxLoopIndex;
    _ = IdxToolName;
    _ = IdxParentSession;
    _ = IdxTemperature;
    _ = IdxIsThinking;
    _ = IdxPromptTokens;
    _ = IdxCompletionTokens;
    _ = IdxTotalTokens;
    _ = IdxIsInput;
    _ = IdxIsOutput;
    _ = IdxDiffviewBefore;
    _ = IdxDiffviewAfter;
    _ = IdxImageUrl;
    _ = IdxToolCallId;
}
