//! `POST /api/llm/message/restore`. Body: `{ "row": { ...the object the
//! delete returned... } }`. Re-inserts the row with the same id, so an undo
//! puts back exactly what left.

const std = @import("std");
const http_response = @import("http_response.zig");
const pabrikcore = @import("pabrikcore");
const test_db = pabrikcore.test_db;
const gserverz = pabrikcore.gserverz;
const llm_history = pabrikcore.llm_history;

pub const MessageRestoreError = error{
    RowRequired,
    InvalidJson,
    AlreadyExists,
    RestoreFailed,
};

pub const MessageRestoreInput = struct {
    row: llm_history.MessageRow,
};

/// Transport-agnostic: the HTTP handler and `pabrik headless message-restore`
/// both call this.
pub fn useCase(
    allocator: std.mem.Allocator,
    db: *pabrikcore.database.Db,
    input: MessageRestoreInput,
) MessageRestoreError!void {
    if (input.row.id.len == 0) return error.RowRequired;
    return llm_history.restoreMessage(allocator, db, input.row) catch |err| switch (err) {
        error.AlreadyExists => error.AlreadyExists,
        else => error.RestoreFailed,
    };
}

pub fn messageRestoreHandler(
    ctx: gserverz.HttpContext,
    req: gserverz.HttpRequest,
    res: gserverz.HttpResponse,
) !gserverz.HttpResponse {
    const allocator = ctx.allocator;

    if (req.body.len == 0) {
        return res.jsonResponse(.{
            .status_code = 400,
            .data = try http_response.makeErrorResponse(allocator, .{ .@"error" = "row required" }),
        });
    }

    const Body = struct { row: llm_history.MessageRow };
    const parsed = std.json.parseFromSliceLeaky(Body, allocator, req.body, .{}) catch {
        return res.jsonResponse(.{
            .status_code = 400,
            .data = try http_response.makeErrorResponse(allocator, .{ .@"error" = "Invalid JSON" }),
        });
    };

    const di = try pabrikcore.getSingleton();
    useCase(allocator, di.db, .{ .row = parsed.row }) catch |err| {
        const status: u16 = switch (err) {
            error.RowRequired => 400,
            error.InvalidJson => 400,
            error.AlreadyExists => 409,
            error.RestoreFailed => 500,
        };
        const message: []const u8 = switch (err) {
            error.RowRequired => "row required",
            error.InvalidJson => "Invalid JSON",
            error.AlreadyExists => "message already exists",
            error.RestoreFailed => "Failed to restore message",
        };
        return res.jsonResponse(.{
            .status_code = status,
            .data = try http_response.makeErrorResponse(allocator, .{ .@"error" = message }),
        });
    };

    const data = try std.json.Stringify.valueAlloc(allocator, .{ .restored = .{ .id = parsed.row.id } }, .{});
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

fn seed(ctx: *TestCtx, id: []const u8) !void {
    try ctx.db.exec(testing.allocator,
        "INSERT INTO llm_history (id, session_id, model, response_content, usage_json, temperature, prompt_tokens) VALUES (?, 's1', 'm', 'hello', '{\"p\":7}', 0.7, 42)",
        &.{id},
    );
}

fn countRows(ctx: *TestCtx) !u32 {
    var q = try ctx.db.query(testing.allocator, "SELECT COUNT(*) FROM llm_history", &.{});
    defer q.deinit();
    const row = (try q.next()) orelse return 0;
    defer row.deinit(testing.allocator);
    return try std.fmt.parseInt(u32, row.values[0], 10);
}

test "useCase: an empty id is RowRequired" {
    var ctx = try setupDb();
    defer ctx.db.deinit();
    defer ctx.threaded.deinit();
    var row: llm_history.MessageRow = undefined;
    inline for (std.meta.fields(llm_history.MessageRow)) |f| @field(row, f.name) = "";
    try testing.expectError(error.RowRequired, useCase(testing.allocator, &ctx.db, .{ .row = row }));
}

test "useCase: restores a deleted row byte-identical, including usage_json" {
    var ctx = try setupDb();
    defer ctx.db.deinit();
    defer ctx.threaded.deinit();
    try seed(&ctx, "m1");

    const before = (try llm_history.getMessageRow(testing.allocator, &ctx.db, "m1")).?;
    defer llm_history.freeMessageRow(testing.allocator, &before);

    const deleted = try llm_history.deleteMessageById(testing.allocator, &ctx.db, "m1");
    defer llm_history.freeMessageRow(testing.allocator, &deleted);
    try testing.expectEqual(@as(u32, 0), try countRows(&ctx));

    try useCase(testing.allocator, &ctx.db, .{ .row = deleted });
    try testing.expectEqual(@as(u32, 1), try countRows(&ctx));

    const after = (try llm_history.getMessageRow(testing.allocator, &ctx.db, "m1")).?;
    defer llm_history.freeMessageRow(testing.allocator, &after);

    inline for (std.meta.fields(llm_history.MessageRow)) |f| {
        try testing.expectEqualStrings(@field(before, f.name), @field(after, f.name));
    }
}

test "useCase: an id that already exists is AlreadyExists" {
    var ctx = try setupDb();
    defer ctx.db.deinit();
    defer ctx.threaded.deinit();
    try seed(&ctx, "m1");
    const row = (try llm_history.getMessageRow(testing.allocator, &ctx.db, "m1")).?;
    defer llm_history.freeMessageRow(testing.allocator, &row);
    try testing.expectError(error.AlreadyExists, useCase(testing.allocator, &ctx.db, .{ .row = row }));
}
