//! `PATCH /api/llm/message/:message_id`. Body: `{ "is_feed_to_llm": 0 | 1 }`.
//! Drops one row from the model's context without deleting it: `getLLMHistories`
//! already filters on the column, and the transcript read path does not.

const std = @import("std");
const http_response = @import("http_response.zig");
const pabrikcore = @import("pabrikcore");
const test_db = pabrikcore.test_db;
const gserverz = pabrikcore.gserverz;
const llm_history = pabrikcore.llm_history;

pub const MessagePatchError = error{
    IdRequired,
    FeedRequired,
    NotFound,
    PatchFailed,
};

pub const MessagePatchInput = struct {
    message_id: []const u8,
    is_feed_to_llm: bool,
};

/// Transport-agnostic: the HTTP handler and `pabrik headless message-feed`
/// both call this.
pub fn useCase(
    allocator: std.mem.Allocator,
    db: *pabrikcore.database.Db,
    input: MessagePatchInput,
) MessagePatchError!void {
    if (input.message_id.len == 0) return error.IdRequired;
    return llm_history.setMessageFeedToLlm(allocator, db, input.message_id, input.is_feed_to_llm) catch |err| switch (err) {
        error.NotFound => error.NotFound,
        else => error.PatchFailed,
    };
}

pub fn messagePatchHandler(
    ctx: gserverz.HttpContext,
    req: gserverz.HttpRequest,
    res: gserverz.HttpResponse,
) !gserverz.HttpResponse {
    const allocator = ctx.allocator;
    const message_id = req.params.get("message_id") orelse "";

    if (req.body.len == 0) {
        return res.jsonResponse(.{
            .status_code = 400,
            .data = try http_response.makeErrorResponse(allocator, .{ .@"error" = "is_feed_to_llm required" }),
        });
    }

    const parsed = std.json.parseFromSliceLeaky(std.json.Value, allocator, req.body, .{}) catch {
        return res.jsonResponse(.{
            .status_code = 400,
            .data = try http_response.makeErrorResponse(allocator, .{ .@"error" = "Invalid JSON" }),
        });
    };

    const raw = parsed.object.get("is_feed_to_llm") orelse {
        return res.jsonResponse(.{
            .status_code = 400,
            .data = try http_response.makeErrorResponse(allocator, .{ .@"error" = "is_feed_to_llm required" }),
        });
    };
    // Both shapes are accepted: the wire sends 0/1, a hand-written curl may
    // send true/false.
    const feed: bool = switch (raw) {
        .bool => |b| b,
        .integer => |i| i != 0,
        else => {
            return res.jsonResponse(.{
                .status_code = 400,
                .data = try http_response.makeErrorResponse(allocator, .{ .@"error" = "is_feed_to_llm must be 0 or 1" }),
            });
        },
    };

    const di = try pabrikcore.getSingleton();
    useCase(allocator, di.db, .{ .message_id = message_id, .is_feed_to_llm = feed }) catch |err| {
        const status: u16 = switch (err) {
            error.IdRequired => 400,
            error.FeedRequired => 400,
            error.NotFound => 404,
            error.PatchFailed => 500,
        };
        const message: []const u8 = switch (err) {
            error.IdRequired => "message_id required",
            error.FeedRequired => "is_feed_to_llm required",
            error.NotFound => "message not found",
            error.PatchFailed => "Failed to update message",
        };
        return res.jsonResponse(.{
            .status_code = status,
            .data = try http_response.makeErrorResponse(allocator, .{ .@"error" = message }),
        });
    };

    const data = try std.json.Stringify.valueAlloc(allocator, .{
        .id = message_id,
        .is_feed_to_llm = feed,
    }, .{});
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
    try db.exec(alloc, "INSERT INTO llm_history (id, session_id, model) VALUES ('m1', 's1', 'm')", &.{});
    return .{ .db = db, .threaded = threaded };
}

fn feedOf(ctx: *TestCtx, id: []const u8) ![]const u8 {
    var q = try ctx.db.query(testing.allocator, "SELECT COALESCE(CAST(is_feed_to_llm AS TEXT), '1') FROM llm_history WHERE id = ?", &.{id});
    defer q.deinit();
    const row = (try q.next()) orelse return "missing";
    defer row.deinit(testing.allocator);
    return try testing.allocator.dupe(u8, row.values[0]);
}

test "useCase: drops a row from the model's context and puts it back" {
    var ctx = try setupDb();
    defer ctx.db.deinit();
    defer ctx.threaded.deinit();

    try useCase(testing.allocator, &ctx.db, .{ .message_id = "m1", .is_feed_to_llm = false });
    const off = try feedOf(&ctx, "m1");
    defer testing.allocator.free(off);
    try testing.expectEqualStrings("0", off);

    try useCase(testing.allocator, &ctx.db, .{ .message_id = "m1", .is_feed_to_llm = true });
    const on = try feedOf(&ctx, "m1");
    defer testing.allocator.free(on);
    try testing.expectEqualStrings("1", on);
}

test "useCase: the row survives the drop" {
    var ctx = try setupDb();
    defer ctx.db.deinit();
    defer ctx.threaded.deinit();
    try useCase(testing.allocator, &ctx.db, .{ .message_id = "m1", .is_feed_to_llm = false });
    const row = (try llm_history.getMessageRow(testing.allocator, &ctx.db, "m1")) orelse return error.MissingRow;
    defer llm_history.freeMessageRow(testing.allocator, &row);
    try testing.expectEqualStrings("0", row.is_feed_to_llm);
}

test "useCase: unknown id is NotFound, empty id is IdRequired" {
    var ctx = try setupDb();
    defer ctx.db.deinit();
    defer ctx.threaded.deinit();
    try testing.expectError(error.NotFound, useCase(testing.allocator, &ctx.db, .{ .message_id = "nope", .is_feed_to_llm = false }));
    try testing.expectError(error.IdRequired, useCase(testing.allocator, &ctx.db, .{ .message_id = "", .is_feed_to_llm = false }));
}
