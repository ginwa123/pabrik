//! `DELETE /api/llm/message/:message_id`. Removes ONE `llm_history` row and
//! returns it whole, so the client can offer an undo. 409 while the loop is
//! still writing the row.

const std = @import("std");
const http_response = @import("http_response.zig");
const pabrikcore = @import("pabrikcore");
const test_db = pabrikcore.test_db;
const gserverz = pabrikcore.gserverz;
const llm_history = pabrikcore.llm_history;

pub const MessageDeleteError = error{
    IdRequired,
    NotFound,
    StillStreaming,
    DeleteFailed,
};

pub const MessageDeleteInput = struct {
    message_id: []const u8,
};

/// Transport-agnostic: the HTTP handler and `pabrik headless message-delete`
/// both call this, so the CLI cannot drift from the endpoint.
pub fn useCase(
    allocator: std.mem.Allocator,
    db: *pabrikcore.database.Db,
    input: MessageDeleteInput,
) MessageDeleteError!llm_history.MessageRow {
    if (input.message_id.len == 0) return error.IdRequired;
    return llm_history.deleteMessageById(allocator, db, input.message_id) catch |err| switch (err) {
        error.NotFound => error.NotFound,
        error.StillStreaming => error.StillStreaming,
        else => error.DeleteFailed,
    };
}

pub fn messageDeleteHandler(
    ctx: gserverz.HttpContext,
    req: gserverz.HttpRequest,
    res: gserverz.HttpResponse,
) !gserverz.HttpResponse {
    const allocator = ctx.allocator;
    const message_id = req.params.get("message_id") orelse "";

    const di = try pabrikcore.getSingleton();
    const row = useCase(allocator, di.db, .{ .message_id = message_id }) catch |err| {
        const status: u16 = switch (err) {
            error.IdRequired => 400,
            error.NotFound => 404,
            error.StillStreaming => 409,
            error.DeleteFailed => 500,
        };
        const message: []const u8 = switch (err) {
            error.IdRequired => "message_id required",
            error.NotFound => "message not found",
            error.StillStreaming => "message is still streaming",
            error.DeleteFailed => "Failed to delete message",
        };
        return res.jsonResponse(.{
            .status_code = status,
            .data = try http_response.makeErrorResponse(allocator, .{ .@"error" = message }),
        });
    };

    const data = try std.json.Stringify.valueAlloc(allocator, .{ .deleted = .{ .row = row } }, .{});
    return res.jsonResponse(.{ .status_code = 200, .data = data });
}

// ─── Tests ──────────────────────────────────────────────────────────────

const testing = std.testing;

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
        \\CREATE TABLE llm_history (
        \\  id TEXT PRIMARY KEY, session_id TEXT NOT NULL, model TEXT NOT NULL DEFAULT 'm',
        \\  response_content TEXT, tool_calls_json TEXT, finish_reason TEXT, usage_json TEXT,
        \\  created_at_nano INTEGER DEFAULT 0, role TEXT DEFAULT 'assistant',
        \\  reasoning_content TEXT, is_feed_to_llm INTEGER DEFAULT 1, agent TEXT DEFAULT 'Agent',
        \\  loop_index INTEGER DEFAULT 0, temperature REAL DEFAULT 0.2, is_thinking INTEGER DEFAULT 0,
        \\  parent_session_id TEXT, parent_id TEXT, prompt_tokens INTEGER DEFAULT 0,
        \\  completion_tokens INTEGER DEFAULT 0, total_tokens INTEGER DEFAULT 0,
        \\  is_input INTEGER DEFAULT 0, is_output INTEGER DEFAULT 0, tool_name TEXT,
        \\  diffview_before TEXT, diffview_after TEXT, image_url TEXT, tool_call_id TEXT,
        \\  created_iso TEXT, is_loading INTEGER DEFAULT 0,
        \\  cache_creation_input_tokens INTEGER DEFAULT 0, cache_read_input_tokens INTEGER DEFAULT 0,
        \\  reasoning_id TEXT, reasoning_encrypted_content TEXT, video_url TEXT,
        \\  file_attachments TEXT, file_attachments_meta TEXT
        \\)
    , &.{});
    return .{ .db = db, .threaded = threaded };
}

fn seed(ctx: *TestCtx, id: []const u8, loading: bool) !void {
    try ctx.db.exec(testing.allocator,
        "INSERT INTO llm_history (id, session_id, model, response_content, is_loading) VALUES (?, 's1', 'm', 'hello', ?)",
        &.{ id, if (loading) "1" else "0" },
    );
}

fn countRows(ctx: *TestCtx) !u32 {
    var q = try ctx.db.query(testing.allocator, "SELECT COUNT(*) FROM llm_history", &.{});
    defer q.deinit();
    const row = (try q.next()) orelse return 0;
    defer row.deinit(testing.allocator);
    return try std.fmt.parseInt(u32, row.values[0], 10);
}

test "useCase: empty id is IdRequired" {
    var ctx = try setupDb();
    defer ctx.db.deinit();
    defer ctx.threaded.deinit();
    try testing.expectError(error.IdRequired, useCase(testing.allocator, &ctx.db, .{ .message_id = "" }));
}

test "useCase: unknown id is NotFound" {
    var ctx = try setupDb();
    defer ctx.db.deinit();
    defer ctx.threaded.deinit();
    try testing.expectError(error.NotFound, useCase(testing.allocator, &ctx.db, .{ .message_id = "nope" }));
}

test "useCase: a streaming row is StillStreaming and survives" {
    var ctx = try setupDb();
    defer ctx.db.deinit();
    defer ctx.threaded.deinit();
    try seed(&ctx, "m1", true);
    try testing.expectError(error.StillStreaming, useCase(testing.allocator, &ctx.db, .{ .message_id = "m1" }));
    try testing.expectEqual(@as(u32, 1), try countRows(&ctx));
}

test "useCase: deletes exactly one row and returns it whole" {
    var ctx = try setupDb();
    defer ctx.db.deinit();
    defer ctx.threaded.deinit();
    try seed(&ctx, "m1", false);
    try seed(&ctx, "m2", false);

    const row = try useCase(testing.allocator, &ctx.db, .{ .message_id = "m1" });
    defer llm_history.freeMessageRow(testing.allocator, &row);

    try testing.expectEqualStrings("m1", row.id);
    try testing.expectEqualStrings("s1", row.session_id);
    try testing.expectEqualStrings("hello", row.response_content);
    try testing.expectEqualStrings("1", row.is_feed_to_llm);
    try testing.expectEqual(@as(u32, 1), try countRows(&ctx));
}
