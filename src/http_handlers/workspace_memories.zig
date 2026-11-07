const std = @import("std");
const http_response = @import("http_response.zig");
const pabrikcore = @import("pabrikcore");
const test_db = pabrikcore.test_db;
const gserverz = pabrikcore.gserverz;
const gate = @import("workspace_members_gate.zig");
const agent_memories = pabrikcore.agent_memories;

pub const WorkspaceMemoriesError = error{
    InvalidContent,
    ContentTooLarge,
    NotFound,
    QueryFailed,
    OutOfMemory,
};

pub const MemoryJson = struct {
    id: []const u8,
    content: []const u8,
    tags: []const []const u8,
    created_at: []const u8,
    updated_at: []const u8,
};

pub const ListJson = struct {
    workspace_id: []const u8,
    query: []const u8,
    memories: []const MemoryJson,
    total_count: u32,
    limit: u32,
    offset: u32,
};

pub const GetJson = struct {
    memory: ?MemoryJson,
};

pub const CreateJson = struct {
    memory: MemoryJson,
};

pub const DeleteJson = struct {
    success: bool,
    id: []const u8,
};

pub const default_limit: u32 = 50;
pub const max_limit: u32 = 200;

pub fn parseLimit(raw: ?[]const u8) u32 {
    const text = raw orelse return default_limit;
    const value = std.fmt.parseInt(u32, text, 10) catch return default_limit;
    if (value == 0) return default_limit;
    return @min(value, max_limit);
}

pub fn parseOffset(raw: ?[]const u8) u32 {
    const text = raw orelse return 0;
    return std.fmt.parseInt(u32, text, 10) catch 0;
}

fn splitTags(allocator: std.mem.Allocator, tags: []const u8) WorkspaceMemoriesError![]const []const u8 {
    if (tags.len == 0) return &.{};

    var parts: std.ArrayList([]const u8) = .empty;
    var it = std.mem.splitSequence(u8, tags, "||");
    while (it.next()) |part| {
        if (part.len == 0) continue;
        parts.append(allocator, part) catch return error.OutOfMemory;
    }
    return parts.toOwnedSlice(allocator) catch return error.OutOfMemory;
}

fn toJson(allocator: std.mem.Allocator, row: agent_memories.MemoryRow) WorkspaceMemoriesError!MemoryJson {
    return .{
        .id = row.id,
        .content = row.content,
        .tags = try splitTags(allocator, row.tags),
        .created_at = row.created_at,
        .updated_at = row.updated_at,
    };
}

pub fn listUseCase(
    allocator: std.mem.Allocator,
    db: *pabrikcore.database.Db,
    workspace_id: []const u8,
    query: []const u8,
    limit: u32,
    offset: u32,
) WorkspaceMemoriesError![]const u8 {
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const scratch = arena.allocator();

    const page = agent_memories.listMemories(scratch, db, .{
        .workspace_id = workspace_id,
        .query = query,
        .limit = limit,
        .offset = offset,
    }) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return error.QueryFailed,
    };

    const memories = scratch.alloc(MemoryJson, page.rows.len) catch return error.OutOfMemory;
    for (page.rows, 0..) |row, i| {
        memories[i] = try toJson(scratch, row);
    }

    return std.json.Stringify.valueAlloc(allocator, ListJson{
        .workspace_id = workspace_id,
        .query = query,
        .memories = memories,
        .total_count = page.total_count,
        .limit = limit,
        .offset = offset,
    }, .{}) catch return error.OutOfMemory;
}

pub fn getUseCase(
    allocator: std.mem.Allocator,
    db: *pabrikcore.database.Db,
    workspace_id: []const u8,
    id: []const u8,
) WorkspaceMemoriesError![]const u8 {
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const scratch = arena.allocator();

    const row = agent_memories.getMemoryById(scratch, db, id, workspace_id) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return error.QueryFailed,
    };

    const memory: ?MemoryJson = if (row) |r| try toJson(scratch, r) else null;

    return std.json.Stringify.valueAlloc(allocator, GetJson{ .memory = memory }, .{}) catch return error.OutOfMemory;
}

pub fn createUseCase(
    allocator: std.mem.Allocator,
    db: *pabrikcore.database.Db,
    workspace_id: []const u8,
    content: []const u8,
    tags: []const []const u8,
) WorkspaceMemoriesError![]const u8 {
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const scratch = arena.allocator();

    const row = agent_memories.saveMemory(scratch, db, .{
        .content = content,
        .tags = tags,
        .workspace_id = workspace_id,
    }) catch |err| switch (err) {
        error.InvalidContent => return error.InvalidContent,
        error.ContentTooLarge => return error.ContentTooLarge,
        error.OutOfMemory => return error.OutOfMemory,
        else => return error.QueryFailed,
    };

    return std.json.Stringify.valueAlloc(allocator, CreateJson{ .memory = try toJson(scratch, row) }, .{}) catch return error.OutOfMemory;
}

pub fn deleteUseCase(
    allocator: std.mem.Allocator,
    db: *pabrikcore.database.Db,
    workspace_id: []const u8,
    id: []const u8,
) WorkspaceMemoriesError![]const u8 {
    const removed = agent_memories.deleteMemory(allocator, db, id, workspace_id) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return error.QueryFailed,
    };
    if (!removed) return error.NotFound;

    return std.json.Stringify.valueAlloc(allocator, DeleteJson{ .success = true, .id = id }, .{}) catch return error.OutOfMemory;
}

fn statusFor(err: WorkspaceMemoriesError) u16 {
    return switch (err) {
        error.InvalidContent, error.ContentTooLarge => 400,
        error.NotFound => 404,
        error.QueryFailed, error.OutOfMemory => 500,
    };
}

fn messageFor(err: WorkspaceMemoriesError) []const u8 {
    return switch (err) {
        error.InvalidContent => "content is required",
        error.ContentTooLarge => "content is larger than 1 MiB",
        error.NotFound => "Memory not found",
        error.QueryFailed => "Database query failed",
        error.OutOfMemory => "Out of memory",
    };
}

fn fail(
    allocator: std.mem.Allocator,
    res: gserverz.HttpResponse,
    err: WorkspaceMemoriesError,
) !gserverz.HttpResponse {
    return res.jsonResponse(.{
        .status_code = statusFor(err),
        .data = try http_response.makeErrorResponse(allocator, .{ .@"error" = messageFor(err) }),
    });
}

fn gateFailure(
    allocator: std.mem.Allocator,
    res: gserverz.HttpResponse,
    err: gate.GateError,
) !gserverz.HttpResponse {
    return res.jsonResponse(.{
        .status_code = gate.statusFor(err),
        .data = try http_response.makeErrorResponse(allocator, .{ .@"error" = gate.messageFor(err) }),
    });
}

pub fn workspaceMemoriesListHandler(
    ctx: gserverz.HttpContext,
    req: gserverz.HttpRequest,
    res: gserverz.HttpResponse,
) !gserverz.HttpResponse {
    const allocator = ctx.allocator;
    const workspace_id = req.params.get("workspace_id") orelse "";
    if (workspace_id.len == 0) return fail(allocator, res, error.InvalidContent);

    const di = try pabrikcore.getSingleton();
    gate.checkRequest(allocator, di.db, di.auth_enabled, req.headers, workspace_id, .read) catch |err| {
        return gateFailure(allocator, res, err);
    };

    const body = listUseCase(
        allocator,
        di.db,
        workspace_id,
        req.query.get("q") orelse "",
        parseLimit(req.query.get("limit")),
        parseOffset(req.query.get("offset")),
    ) catch |err| return fail(allocator, res, err);

    return res.jsonResponse(.{ .status_code = 200, .data = body });
}

pub fn workspaceMemoryGetHandler(
    ctx: gserverz.HttpContext,
    req: gserverz.HttpRequest,
    res: gserverz.HttpResponse,
) !gserverz.HttpResponse {
    const allocator = ctx.allocator;
    const workspace_id = req.params.get("workspace_id") orelse "";
    const memory_id = req.params.get("memory_id") orelse "";
    if (workspace_id.len == 0 or memory_id.len == 0) return fail(allocator, res, error.NotFound);

    const di = try pabrikcore.getSingleton();
    gate.checkRequest(allocator, di.db, di.auth_enabled, req.headers, workspace_id, .read) catch |err| {
        return gateFailure(allocator, res, err);
    };

    const body = getUseCase(allocator, di.db, workspace_id, memory_id) catch |err| return fail(allocator, res, err);
    return res.jsonResponse(.{ .status_code = 200, .data = body });
}

const CreateBody = struct {
    content: []const u8,
    tags: []const []const u8 = &.{},
};

pub fn workspaceMemoryCreateHandler(
    ctx: gserverz.HttpContext,
    req: gserverz.HttpRequest,
    res: gserverz.HttpResponse,
) !gserverz.HttpResponse {
    const allocator = ctx.allocator;
    const workspace_id = req.params.get("workspace_id") orelse "";
    if (workspace_id.len == 0) return fail(allocator, res, error.InvalidContent);

    if (req.body.len == 0) {
        return res.jsonResponse(.{
            .status_code = 400,
            .data = try http_response.makeErrorResponse(allocator, .{ .@"error" = "Request body required" }),
        });
    }

    const parsed = std.json.parseFromSliceLeaky(CreateBody, allocator, req.body, .{}) catch {
        return res.jsonResponse(.{
            .status_code = 400,
            .data = try http_response.makeErrorResponse(allocator, .{ .@"error" = "Invalid JSON body" }),
        });
    };

    const di = try pabrikcore.getSingleton();
    gate.checkRequest(allocator, di.db, di.auth_enabled, req.headers, workspace_id, .read) catch |err| {
        return gateFailure(allocator, res, err);
    };

    const body = createUseCase(allocator, di.db, workspace_id, parsed.content, parsed.tags) catch |err| {
        return fail(allocator, res, err);
    };
    return res.jsonResponse(.{ .status_code = 201, .data = body });
}

pub fn workspaceMemoryDeleteHandler(
    ctx: gserverz.HttpContext,
    req: gserverz.HttpRequest,
    res: gserverz.HttpResponse,
) !gserverz.HttpResponse {
    const allocator = ctx.allocator;
    const workspace_id = req.params.get("workspace_id") orelse "";
    const memory_id = req.params.get("memory_id") orelse "";
    if (workspace_id.len == 0 or memory_id.len == 0) return fail(allocator, res, error.NotFound);

    const di = try pabrikcore.getSingleton();
    gate.checkRequest(allocator, di.db, di.auth_enabled, req.headers, workspace_id, .read) catch |err| {
        return gateFailure(allocator, res, err);
    };

    const body = deleteUseCase(allocator, di.db, workspace_id, memory_id) catch |err| return fail(allocator, res, err);
    return res.jsonResponse(.{ .status_code = 200, .data = body });
}

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

    const migration = pabrikcore.migrations_mod.migration;
    var manager = migration.MigrationManager.init(alloc, &db);
    defer manager.deinit();
    try migration.registerAllMigrations(&manager);
    try manager.runMigrations();

    return .{ .db = db, .threaded = threaded };
}

fn teardown(ctx: *TestCtx) void {
    ctx.db.deinit();
    ctx.threaded.deinit();
}

fn parse(allocator: std.mem.Allocator, json: []const u8) !std.json.Parsed(std.json.Value) {
    return std.json.parseFromSlice(std.json.Value, allocator, json, .{});
}

test "listUseCase: answers the workspace's rows with their tags split out" {
    var ctx = try setupDb();
    defer teardown(&ctx);

    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    _ = try createUseCase(a, &ctx.db, "ws_a", "the deploy target is staging", &.{ "ops", "deploy" });
    _ = try createUseCase(a, &ctx.db, "ws_b", "another workspace's note", &.{"other"});

    const json = try listUseCase(a, &ctx.db, "ws_a", "", 50, 0);
    const parsed = try parse(testing.allocator, json);
    defer parsed.deinit();

    const memories = parsed.value.object.get("memories").?.array;
    try testing.expectEqual(@as(usize, 1), memories.items.len);
    try testing.expectEqualStrings("the deploy target is staging", memories.items[0].object.get("content").?.string);
    try testing.expectEqual(@as(i64, 1), parsed.value.object.get("total_count").?.integer);

    const tags = memories.items[0].object.get("tags").?.array;
    try testing.expectEqual(@as(usize, 2), tags.items.len);
    try testing.expectEqualStrings("ops", tags.items[0].string);
    try testing.expectEqualStrings("deploy", tags.items[1].string);
}

test "listUseCase: an empty workspace answers an empty list, not an error" {
    var ctx = try setupDb();
    defer teardown(&ctx);

    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();

    const json = try listUseCase(arena.allocator(), &ctx.db, "ws_none", "", 50, 0);
    const parsed = try parse(testing.allocator, json);
    defer parsed.deinit();

    try testing.expectEqual(@as(usize, 0), parsed.value.object.get("memories").?.array.items.len);
    try testing.expectEqual(@as(i64, 0), parsed.value.object.get("total_count").?.integer);
}

test "getUseCase: a memory from another workspace reads as null" {
    var ctx = try setupDb();
    defer teardown(&ctx);

    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const created = try parse(testing.allocator, try createUseCase(a, &ctx.db, "ws_a", "owned by ws_a", &.{}));
    defer created.deinit();
    const id = created.value.object.get("memory").?.object.get("id").?.string;

    const own = try parse(testing.allocator, try getUseCase(a, &ctx.db, "ws_a", id));
    defer own.deinit();
    try testing.expectEqualStrings("owned by ws_a", own.value.object.get("memory").?.object.get("content").?.string);

    const stolen = try parse(testing.allocator, try getUseCase(a, &ctx.db, "ws_b", id));
    defer stolen.deinit();
    try testing.expectEqual(std.json.Value.null, stolen.value.object.get("memory").?);
}

test "createUseCase: empty content is refused instead of stored" {
    var ctx = try setupDb();
    defer teardown(&ctx);

    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();

    try testing.expectError(
        error.InvalidContent,
        createUseCase(arena.allocator(), &ctx.db, "ws_a", "", &.{}),
    );
}

test "deleteUseCase: removes the row and reports the id it removed" {
    var ctx = try setupDb();
    defer teardown(&ctx);

    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const created = try parse(testing.allocator, try createUseCase(a, &ctx.db, "ws_a", "delete me", &.{}));
    defer created.deinit();
    const id = created.value.object.get("memory").?.object.get("id").?.string;

    const deleted = try parse(testing.allocator, try deleteUseCase(a, &ctx.db, "ws_a", id));
    defer deleted.deinit();
    try testing.expect(deleted.value.object.get("success").?.bool);
    try testing.expectEqualStrings(id, deleted.value.object.get("id").?.string);

    const after = try parse(testing.allocator, try listUseCase(a, &ctx.db, "ws_a", "", 50, 0));
    defer after.deinit();
    try testing.expectEqual(@as(usize, 0), after.value.object.get("memories").?.array.items.len);
}

test "deleteUseCase: a memory from another workspace is not found" {
    var ctx = try setupDb();
    defer teardown(&ctx);

    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const created = try parse(testing.allocator, try createUseCase(a, &ctx.db, "ws_a", "keep me", &.{}));
    defer created.deinit();
    const id = created.value.object.get("memory").?.object.get("id").?.string;

    try testing.expectError(error.NotFound, deleteUseCase(a, &ctx.db, "ws_b", id));
}

test "parseLimit: clamps to the page ceiling and falls back on junk" {
    try testing.expectEqual(default_limit, parseLimit(null));
    try testing.expectEqual(default_limit, parseLimit(""));
    try testing.expectEqual(default_limit, parseLimit("0"));
    try testing.expectEqual(default_limit, parseLimit("lots"));
    try testing.expectEqual(@as(u32, 10), parseLimit("10"));
    try testing.expectEqual(max_limit, parseLimit("100000"));
}

test "parseOffset: junk reads as the first page" {
    try testing.expectEqual(@as(u32, 0), parseOffset(null));
    try testing.expectEqual(@as(u32, 0), parseOffset("nope"));
    try testing.expectEqual(@as(u32, 20), parseOffset("20"));
}

test "listUseCase: the query narrows to matching bodies and tags" {
    var ctx = try setupDb();
    defer teardown(&ctx);

    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    _ = try createUseCase(a, &ctx.db, "ws_a", "the deploy target is staging", &.{"ops"});
    _ = try createUseCase(a, &ctx.db, "ws_a", "the design tokens live in style.css", &.{"frontend"});

    const by_body = try parse(testing.allocator, try listUseCase(a, &ctx.db, "ws_a", "deploy", 50, 0));
    defer by_body.deinit();
    try testing.expectEqual(@as(usize, 1), by_body.value.object.get("memories").?.array.items.len);
    try testing.expectEqualStrings("the deploy target is staging", by_body.value.object.get("memories").?.array.items[0].object.get("content").?.string);

    const by_tag = try parse(testing.allocator, try listUseCase(a, &ctx.db, "ws_a", "frontend", 50, 0));
    defer by_tag.deinit();
    try testing.expectEqual(@as(usize, 1), by_tag.value.object.get("memories").?.array.items.len);

    const no_match = try parse(testing.allocator, try listUseCase(a, &ctx.db, "ws_a", "kubernetes", 50, 0));
    defer no_match.deinit();
    try testing.expectEqual(@as(usize, 0), no_match.value.object.get("memories").?.array.items.len);
    try testing.expectEqual(@as(i64, 0), no_match.value.object.get("total_count").?.integer);
}
