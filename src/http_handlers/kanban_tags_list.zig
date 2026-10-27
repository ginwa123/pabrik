//! `GET /api/workspaces/:ws_id/items/:item_id/kanban/tags?limit=N&offset=K`.
//! Returns one page of distinct tags from tasks belonging to the given kanban
//! workspace item, ordered by frequency DESC then most-recent usage DESC.

const std = @import("std");
const testing = std.testing;
const http_response = @import("http_response.zig");
const pabrikcore = @import("pabrikcore");
const gserverz = pabrikcore.gserverz;
const ai_mod = pabrikcore.ai_mod;
const llm_history = ai_mod.llm_history;

const DEFAULT_LIMIT: u32 = 8;
const MAX_LIMIT: u32 = 50;

pub const KanbanTagsListError = error{
    OutOfMemory,
    DbError,
};

pub const KanbanTagsListInput = struct {
    workspace_item_id: []const u8,
    limit: u32,
    offset: u32,
};

pub const KanbanTagsListResult = []const u8; // pre-serialized JSON

// =====================================================================
// Use case
// =====================================================================

pub fn useCase(
    allocator: std.mem.Allocator,
    db: *pabrikcore.database.Db,
    input: KanbanTagsListInput,
) KanbanTagsListError!KanbanTagsListResult {
    const page = llm_history.listKanbanDistinctTags(
        allocator,
        db,
        input.workspace_item_id,
        input.limit,
        input.offset,
    ) catch return KanbanTagsListError.DbError;
    defer page.deinit(allocator);

    var response_suggestions: std.ArrayList(http_response.KanbanTagSuggestionResponse) = .empty;
    defer response_suggestions.deinit(allocator);

    for (page.tags) |s| {
        try response_suggestions.append(allocator, .{
            .name = s.name,
            .count = s.count,
            .last_used_at = s.last_used_at,
        });
    }

    return http_response.makeKanbanTagsListResponse(
        allocator,
        response_suggestions.items,
        page.has_more,
    );
}

// =====================================================================
// Handler
// =====================================================================

pub fn kanbanTagsListHandler(
    ctx: gserverz.HttpContext,
    req: gserverz.HttpRequest,
    res: gserverz.HttpResponse,
) !gserverz.HttpResponse {
    const allocator = ctx.allocator;

    const item_id = req.params.get("item_id") orelse "";
    if (item_id.len == 0) {
        return res.jsonResponse(.{
            .status_code = 400,
            .data = try http_response.makeErrorResponse(allocator, .{ .@"error" = "item_id required" }),
        });
    }

    // Parse `limit` query param with clamping. Default 8, max 50.
    const limit_str = req.query.get("limit") orelse "8";
    const limit_parsed = std.fmt.parseInt(u32, limit_str, 10) catch DEFAULT_LIMIT;
    const limit: u32 = if (limit_parsed == 0)
        DEFAULT_LIMIT
    else if (limit_parsed > MAX_LIMIT)
        MAX_LIMIT
    else
        limit_parsed;

    // Parse `offset` query param. Default 0. No upper clamp (a
    // user-paginating past the end just gets an empty page).
    const offset_str = req.query.get("offset") orelse "0";
    const offset = std.fmt.parseInt(u32, offset_str, 10) catch 0;

    const di = try pabrikcore.getSingleton();
    const sqlite_db = di.db;

    const data = useCase(allocator, sqlite_db, .{
        .workspace_item_id = item_id,
        .limit = limit,
        .offset = offset,
    }) catch |err| {
        const status: u16 = switch (err) {
            KanbanTagsListError.DbError => 500,
            KanbanTagsListError.OutOfMemory => 500,
        };
        const message: []const u8 = switch (err) {
            KanbanTagsListError.DbError => "Failed to fetch tag suggestions",
            KanbanTagsListError.OutOfMemory => "Out of memory",
        };
        return res.jsonResponse(.{
            .status_code = status,
            .data = try http_response.makeErrorResponse(allocator, .{ .@"error" = message }),
        });
    };

    return res.jsonResponse(.{ .status_code = 200, .data = data });
}
// ===================================================================== Tests
// for useCase

fn setupDbWithTagsForHandler() !struct { db: pabrikcore.database.Db, threaded: std.Io.Threaded } {
    const alloc = testing.allocator;
    var threaded = std.Io.Threaded.init(alloc, .{});
    errdefer threaded.deinit();
    const io = threaded.io();
    var db: pabrikcore.database.Db = .{};
    errdefer db.deinit();
    try db.init(io, ":memory:");
    try db.exec(alloc, "CREATE TABLE workspace_items (id TEXT PRIMARY KEY, workspace_id TEXT NOT NULL)", &.{});
    try db.exec(alloc,
        \\CREATE TABLE workspace_item_tasks (
        \\  id TEXT PRIMARY KEY,
        \\  workspace_item_id TEXT NOT NULL,
        \\  updated_at TEXT DEFAULT CURRENT_TIMESTAMP,
        \\  tags TEXT NOT NULL DEFAULT ''
        \\)
    , &.{});
    try db.exec(alloc, "INSERT INTO workspace_items (id, workspace_id) VALUES ('item_x', 'ws_x')", &.{});
    return .{ .db = db, .threaded = threaded };
}

test "useCase returns empty tags array + has_more=false for kanban with no tasks" {
    var s = try setupDbWithTagsForHandler();
    defer s.threaded.deinit();
    defer s.db.deinit();
    const result = try useCase(testing.allocator, &s.db, .{
        .workspace_item_id = "item_x",
        .limit = 8,
        .offset = 0,
    });
    defer testing.allocator.free(result);
    const parsed = try std.json.parseFromSlice(std.json.Value, testing.allocator, result, .{});
    defer parsed.deinit();
    try testing.expect(parsed.value.object.get("tags").?.array.items.len == 0);
    try testing.expect(parsed.value.object.get("has_more").?.bool == false);
}

test "useCase paginates: limit=2 returns 2 tags + has_more=true when 5 distinct tags exist" {
    var s = try setupDbWithTagsForHandler();
    defer s.threaded.deinit();
    defer s.db.deinit();
    const alloc = testing.allocator;
    try s.db.exec(alloc, "INSERT INTO workspace_item_tasks (id, workspace_item_id, tags) VALUES ('t1', 'item_x', '[\"a\",\"b\",\"c\",\"d\",\"e\"]')", &.{});
    const result = try useCase(alloc, &s.db, .{
        .workspace_item_id = "item_x",
        .limit = 2,
        .offset = 0,
    });
    defer alloc.free(result);
    const parsed = try std.json.parseFromSlice(std.json.Value, alloc, result, .{});
    defer parsed.deinit();
    try testing.expectEqual(@as(usize, 2), parsed.value.object.get("tags").?.array.items.len);
    try testing.expect(parsed.value.object.get("has_more").?.bool == true);
}

test "useCase returns has_more=false on the last page" {
    var s = try setupDbWithTagsForHandler();
    defer s.threaded.deinit();
    defer s.db.deinit();
    const alloc = testing.allocator;
    try s.db.exec(alloc, "INSERT INTO workspace_item_tasks (id, workspace_item_id, tags) VALUES ('t1', 'item_x', '[\"a\",\"b\",\"c\"]')", &.{});
    const result = try useCase(alloc, &s.db, .{
        .workspace_item_id = "item_x",
        .limit = 2,
        .offset = 2,
    });
    defer alloc.free(result);
    const parsed = try std.json.parseFromSlice(std.json.Value, alloc, result, .{});
    defer parsed.deinit();
    try testing.expectEqual(@as(usize, 1), parsed.value.object.get("tags").?.array.items.len);
    try testing.expect(parsed.value.object.get("has_more").?.bool == false);
}

test "useCase combines with offset to skip past the first page" {
    var s = try setupDbWithTagsForHandler();
    defer s.threaded.deinit();
    defer s.db.deinit();
    const alloc = testing.allocator;
    try s.db.exec(alloc, "INSERT INTO workspace_item_tasks (id, workspace_item_id, tags) VALUES ('t1', 'item_x', '[\"a\",\"b\",\"c\",\"d\",\"e\"]')", &.{});
    const page1 = try useCase(alloc, &s.db, .{
        .workspace_item_id = "item_x",
        .limit = 2,
        .offset = 0,
    });
    defer alloc.free(page1);
    const page2 = try useCase(alloc, &s.db, .{
        .workspace_item_id = "item_x",
        .limit = 2,
        .offset = 2,
    });
    defer alloc.free(page2);
    const p1 = try std.json.parseFromSlice(std.json.Value, alloc, page1, .{});
    defer p1.deinit();
    const p2 = try std.json.parseFromSlice(std.json.Value, alloc, page2, .{});
    defer p2.deinit();
    const p1_name = p1.value.object.get("tags").?.array.items[0].object.get("name").?.string;
    const p2_name = p2.value.object.get("tags").?.array.items[0].object.get("name").?.string;
    try testing.expect(!std.mem.eql(u8, p1_name, p2_name));
}
