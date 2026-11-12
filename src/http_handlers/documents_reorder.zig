const std = @import("std");
const pabrikcore = @import("pabrikcore");
const test_db = pabrikcore.test_db;
const gserverz = pabrikcore.gserverz;
const http_response = @import("http_response.zig");
const documents_store = @import("../modules/agent/loop/documents_store.zig");
const folders_store = @import("../modules/agent/loop/document_folders_store.zig");
const document_events = @import("../modules/agent/loop/document_events.zig");

const ReorderBody = struct {
    ordered_ids: []const []const u8 = &.{},
    /// Which level is being renumbered. Absent or null is the root, because a
    /// reorder always names exactly one sibling list.
    folder_id: ?[]const u8 = null,
};

pub const DocumentsReorderInput = struct {
    workspace_id: []const u8,
    folder_id: ?[]const u8 = null,
    ordered_ids: []const []const u8,
};

pub const DocumentsReorderOutput = struct {
    documents: []documents_store.DocumentRow,
    folders: []folders_store.FolderRow,
};

fn useCase(
    allocator: std.mem.Allocator,
    store: documents_store.Store,
    input: DocumentsReorderInput,
) (documents_store.ReorderDocumentsError || documents_store.ListDocumentsError)!DocumentsReorderOutput {
    if (input.workspace_id.len == 0) return error.WorkspaceIdRequired;
    try documents_store.reorderDocuments(allocator, store.db, input.workspace_id, input.folder_id, input.ordered_ids);
    return .{
        .documents = try store.listDocuments(allocator, input.workspace_id),
        .folders = try folders_store.listFolders(allocator, store.db, input.workspace_id),
    };
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

    const output = useCase(allocator, .{ .db = sqlite_db, .storage = di.objectStore() }, .{
        .workspace_id = req.params.get("workspace_id") orelse "",
        .folder_id = body.folder_id,
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
    defer folders_store.freeFolderRows(allocator, output.folders);

    // One event for the level that was renumbered: no single document names it.
    document_events.emitDocumentsChanged(
        allocator,
        di.event_bus,
        req.params.get("workspace_id") orelse "",
        body.folder_id orelse "",
        "",
    );

    const data = try http_response.makeDocumentListResponse(allocator, output.documents, output.folders, false);
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
    try migration.Migration140AddDocumentFolders.up(&db, testing.allocator);
    try migration.Migration143AddDocumentContentKey.up(&db, testing.allocator);
    try migration.Migration144DropDocumentContent.up(&db, testing.allocator);
    try migration.Migration148AddDocumentIcon.up(&db, testing.allocator);
    try db.exec(testing.allocator,
        \\INSERT INTO documents (id, workspace_id, title, updated_at) VALUES
        \\  ('doc_a', 'ws_1', 'A', '2026-09-01 10:00:00'),
        \\  ('doc_b', 'ws_1', 'B', '2026-09-02 10:00:00'),
        \\  ('doc_x', 'ws_2', 'X', '2026-09-01 10:00:00')
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

    const output = try useCase(alloc, .{ .db = &ctx.db }, .{
        .workspace_id = "ws_1",
        .ordered_ids = &[_][]const u8{ "doc_a", "doc_b" },
    });
    defer documents_store.freeDocumentRows(alloc, output.documents);
    defer folders_store.freeFolderRows(alloc, output.folders);

    const order = try ids(alloc, output.documents);
    defer alloc.free(order);
    try testing.expectEqualStrings("doc_a,doc_b", order);
}

test "useCase: a reorder never returns another workspace's documents" {
    const alloc = testing.allocator;
    var ctx = try setupDb();
    defer ctx.threaded.deinit();
    defer ctx.db.deinit();

    const output = try useCase(alloc, .{ .db = &ctx.db }, .{
        .workspace_id = "ws_1",
        .ordered_ids = &[_][]const u8{ "doc_b", "doc_a" },
    });
    defer documents_store.freeDocumentRows(alloc, output.documents);
    defer folders_store.freeFolderRows(alloc, output.folders);

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
        useCase(alloc, .{ .db = &ctx.db }, .{
            .workspace_id = "ws_1",
            .ordered_ids = &[_][]const u8{ "doc_x", "doc_a" },
        }),
    );

    const after = try useCase(alloc, .{ .db = &ctx.db }, .{
        .workspace_id = "ws_1",
        .ordered_ids = &[_][]const u8{ "doc_b", "doc_a" },
    });
    defer documents_store.freeDocumentRows(alloc, after.documents);
    defer folders_store.freeFolderRows(alloc, after.folders);
    try testing.expectEqualStrings("doc_b", after.documents[0].id);
}

test "useCase: an empty ordered_ids and an empty workspace are refused" {
    const alloc = testing.allocator;
    var ctx = try setupDb();
    defer ctx.threaded.deinit();
    defer ctx.db.deinit();

    try testing.expectError(
        error.EmptyOrder,
        useCase(alloc, .{ .db = &ctx.db }, .{ .workspace_id = "ws_1", .ordered_ids = &[_][]const u8{} }),
    );
    try testing.expectError(
        error.WorkspaceIdRequired,
        useCase(alloc, .{ .db = &ctx.db }, .{
            .workspace_id = "",
            .ordered_ids = &[_][]const u8{"doc_a"},
        }),
    );
}
