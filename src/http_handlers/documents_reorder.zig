const std = @import("std");
const pabrikcore = @import("pabrikcore");
const test_db = pabrikcore.test_db;
const gserverz = pabrikcore.gserverz;
const http_response = @import("http_response.zig");
const documents_store = @import("../agentic_loop/documents_store.zig");

const ReorderBody = struct {
    ordered_ids: []const []const u8 = &.{},
};

pub const DocumentsReorderInput = struct {
    workspace_id: []const u8,
    ordered_ids: []const []const u8,
};

pub const DocumentsReorderOutput = struct {
    documents: []documents_store.DocumentRow,
};

fn useCase(
    allocator: std.mem.Allocator,
    db: *pabrikcore.database.Db,
    input: DocumentsReorderInput,
) (documents_store.ReorderDocumentsError || documents_store.ListDocumentsError)!DocumentsReorderOutput {
    if (input.workspace_id.len == 0) return error.WorkspaceIdRequired;
    try documents_store.reorderDocuments(allocator, db, input.workspace_id, input.ordered_ids);
    return .{ .documents = try documents_store.listDocuments(allocator, db, input.workspace_id) };
}

pub fn documentsReorderHandler(
    ctx: gserverz.HttpContext,
    req: gserverz.HttpRequest,
    res: gserverz.HttpResponse,
) !gserverz.HttpResponse {
    const allocator = ctx.allocator;

    const di = try pabrikcore.getSingleton();
    const sqlite_db = di.db;

    if (req.body.len == 0) {
        return res.jsonResponse(.{
            .status_code = 400,
            .data = try http_response.makeErrorResponse(allocator, .{ .@"error" = "Request body required" }),
        });
    }

    const body = std.json.parseFromSliceLeaky(ReorderBody, allocator, req.body, .{}) catch {
        return res.jsonResponse(.{
            .status_code = 400,
            .data = try http_response.makeErrorResponse(allocator, .{ .@"error" = "Invalid JSON body" }),
        });
    };

    const output = useCase(allocator, sqlite_db, .{
        .workspace_id = req.params.get("workspace_id") orelse "",
        .ordered_ids = body.ordered_ids,
    }) catch |err| {
        const status: u16 = switch (err) {
            error.WorkspaceIdRequired, error.EmptyOrder, error.DuplicateDocumentId => 400,
            error.DocumentNotFound => 404,
            error.QueryFailed, error.TransactionFailed, error.UpdateFailed, error.OutOfMemory => 500,
        };
        const message: []const u8 = switch (err) {
            error.WorkspaceIdRequired => "workspace_id required",
            error.EmptyOrder => "ordered_ids must be non-empty",
            error.DuplicateDocumentId => "ordered_ids contains a duplicate document id",
            error.DocumentNotFound => "document not found in this workspace",
            error.QueryFailed => "DB error",
            error.TransactionFailed => "DB error",
            error.UpdateFailed => "DB error",
            error.OutOfMemory => "Out of memory",
        };
        return res.jsonResponse(.{
            .status_code = status,
            .data = try http_response.makeErrorResponse(allocator, .{ .@"error" = message }),
        });
    };
    defer documents_store.freeDocumentRows(allocator, output.documents);

    const data = try http_response.makeDocumentListResponse(allocator, output.documents);
    return res.jsonResponse(.{ .status_code = 200, .data = data });
}

const testing = std.testing;
const database = pabrikcore.database;
const migration = @import("../migrations/migration.zig");

const TestCtx = struct {
    db: database.Db,
    threaded: std.Io.Threaded,
};

fn setupDb() !TestCtx {
    var threaded = std.Io.Threaded.init(testing.allocator, .{});
    errdefer threaded.deinit();
    var db: database.Db = .{};
    errdefer db.deinit();
    try test_db.openMemory(&db, threaded.io());

    try migration.Migration098CreateDocuments.up(&db, testing.allocator);
    try migration.Migration122AddDocumentPosition.up(&db, testing.allocator);
    try db.exec(testing.allocator,
        \\INSERT INTO documents (id, workspace_id, title, content, updated_at) VALUES
        \\  ('doc_a', 'ws_1', 'A', 'body a', '2026-09-01 10:00:00'),
        \\  ('doc_b', 'ws_1', 'B', 'body b', '2026-09-02 10:00:00'),
        \\  ('doc_x', 'ws_2', 'X', 'body x', '2026-09-01 10:00:00')
    , &.{});
    return .{ .db = db, .threaded = threaded };
}

fn ids(alloc: std.mem.Allocator, rows: []const documents_store.DocumentRow) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(alloc);
    for (rows, 0..) |row, i| {
        if (i > 0) try out.append(alloc, ',');
        try out.appendSlice(alloc, row.id);
    }
    return out.toOwnedSlice(alloc);
}

test "useCase: a reorder persists and the response lists the documents in the new order" {
    const alloc = testing.allocator;
    var ctx = try setupDb();
    defer ctx.threaded.deinit();
    defer ctx.db.deinit();

    const output = try useCase(alloc, &ctx.db, .{
        .workspace_id = "ws_1",
        .ordered_ids = &[_][]const u8{ "doc_a", "doc_b" },
    });
    defer documents_store.freeDocumentRows(alloc, output.documents);

    const order = try ids(alloc, output.documents);
    defer alloc.free(order);
    try testing.expectEqualStrings("doc_a,doc_b", order);
}

test "useCase: a reorder never returns another workspace's documents" {
    const alloc = testing.allocator;
    var ctx = try setupDb();
    defer ctx.threaded.deinit();
    defer ctx.db.deinit();

    const output = try useCase(alloc, &ctx.db, .{
        .workspace_id = "ws_1",
        .ordered_ids = &[_][]const u8{ "doc_b", "doc_a" },
    });
    defer documents_store.freeDocumentRows(alloc, output.documents);

    try testing.expectEqual(@as(usize, 2), output.documents.len);
    try testing.expectEqualStrings("doc_b", output.documents[0].id);
}

test "useCase: another workspace's id is refused and the stored order is unchanged" {
    const alloc = testing.allocator;
    var ctx = try setupDb();
    defer ctx.threaded.deinit();
    defer ctx.db.deinit();

    try testing.expectError(
        error.DocumentNotFound,
        useCase(alloc, &ctx.db, .{
            .workspace_id = "ws_1",
            .ordered_ids = &[_][]const u8{ "doc_x", "doc_a" },
        }),
    );

    const after = try useCase(alloc, &ctx.db, .{
        .workspace_id = "ws_1",
        .ordered_ids = &[_][]const u8{ "doc_b", "doc_a" },
    });
    defer documents_store.freeDocumentRows(alloc, after.documents);
    try testing.expectEqualStrings("doc_b", after.documents[0].id);
}

test "useCase: an empty ordered_ids and an empty workspace are refused" {
    const alloc = testing.allocator;
    var ctx = try setupDb();
    defer ctx.threaded.deinit();
    defer ctx.db.deinit();

    try testing.expectError(
        error.EmptyOrder,
        useCase(alloc, &ctx.db, .{ .workspace_id = "ws_1", .ordered_ids = &[_][]const u8{} }),
    );
    try testing.expectError(
        error.WorkspaceIdRequired,
        useCase(alloc, &ctx.db, .{
            .workspace_id = "",
            .ordered_ids = &[_][]const u8{"doc_a"},
        }),
    );
}
