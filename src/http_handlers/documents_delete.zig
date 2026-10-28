//! `DELETE /api/workspaces/:workspace_id/documents/:document_id`. Removes one
//! document.

const std = @import("std");
const pabrikcore = @import("pabrikcore");
const test_db = pabrikcore.test_db;
const gserverz = pabrikcore.gserverz;
const http_response = @import("http_response.zig");
const documents_store = @import("../agentic_loop/documents_store.zig");

pub const DocumentsDeleteError = error{
    IdsRequired,
    NotFound,
    DeleteFailed,
};

pub const DocumentsDeleteInput = struct {
    workspace_id: []const u8,
    document_id: []const u8,
};

// =====================================================================
// Use case
// =====================================================================

fn useCase(
    allocator: std.mem.Allocator,
    db: *pabrikcore.database.Db,
    input: DocumentsDeleteInput,
) DocumentsDeleteError!void {
    if (input.workspace_id.len == 0 or input.document_id.len == 0) {
        return error.IdsRequired;
    }
    try documents_store.deleteDocument(allocator, db, input.workspace_id, input.document_id);
}

// =====================================================================
// Handler
// =====================================================================

pub fn documentsDeleteHandler(
    ctx: gserverz.HttpContext,
    req: gserverz.HttpRequest,
    res: gserverz.HttpResponse,
) !gserverz.HttpResponse {
    const allocator = ctx.allocator;

    const di = try pabrikcore.getSingleton();
    const sqlite_db = di.db;

    const document_id = req.params.get("document_id") orelse "";

    useCase(allocator, sqlite_db, .{
        .workspace_id = req.params.get("workspace_id") orelse "",
        .document_id = document_id,
    }) catch |err| {
        const status: u16 = switch (err) {
            error.IdsRequired => 400,
            error.NotFound => 404,
            error.DeleteFailed => 500,
        };
        const message: []const u8 = switch (err) {
            error.IdsRequired => "workspace_id and document_id required",
            error.NotFound => "document not found",
            error.DeleteFailed => "DB error",
        };
        return res.jsonResponse(.{
            .status_code = status,
            .data = try http_response.makeErrorResponse(allocator, .{ .@"error" = message }),
        });
    };

    const data = try std.json.Stringify.valueAlloc(allocator, .{
        .id = document_id,
        .success = true,
    }, .{});
    return res.jsonResponse(.{ .status_code = 200, .data = data });
}

// ─── Tests ──────────────────────────────────────────────────────────────

const sqlite = pabrikcore.sqlite;
const database = pabrikcore.database;
const testing = std.testing;
const migration = @import("../migrations/migration.zig");

const TestCtx = struct {
    db: database.Db,
    threaded: std.Io.Threaded,
};

fn setupDb() !TestCtx {
    var threaded = std.Io.Threaded.init(testing.allocator, .{});
    errdefer threaded.deinit();
    const io = threaded.io();
    var db: database.Db = .{};
    errdefer db.deinit();
    try test_db.openMemory(&db, io);

    try migration.Migration098CreateDocuments.up(&db, testing.allocator);
    try db.exec(testing.allocator,
        \\INSERT INTO documents (id, workspace_id, title, content) VALUES
        \\  ('doc_a', 'ws_1', 'A', 'body a'),
        \\  ('doc_b', 'ws_2', 'B', 'body b')
    , &.{});
    return .{ .db = db, .threaded = threaded };
}

fn countRows(ctx: *TestCtx) !usize {
    const alloc = testing.allocator;
    var q = try ctx.db.query(alloc, "SELECT COUNT(*) FROM documents", &.{});
    defer q.deinit();
    const row = (try q.next()) orelse return error.RowMissing;
    defer row.deinit(alloc);
    return std.fmt.parseInt(usize, row.values[0], 10) catch 0;
}

test "useCase: empty ids return IdsRequired" {
    const alloc = testing.allocator;
    var ctx = try setupDb();
    defer ctx.threaded.deinit();
    defer ctx.db.deinit();

    try testing.expectError(
        error.IdsRequired,
        useCase(alloc, &ctx.db, .{ .workspace_id = "ws_1", .document_id = "" }),
    );
}

test "useCase: deletes the document and leaves the sibling alone" {
    const alloc = testing.allocator;
    var ctx = try setupDb();
    defer ctx.threaded.deinit();
    defer ctx.db.deinit();

    try useCase(alloc, &ctx.db, .{ .workspace_id = "ws_1", .document_id = "doc_a" });

    try testing.expectError(
        error.NotFound,
        documents_store.getDocument(alloc, &ctx.db, "ws_1", "doc_a"),
    );
    // The other workspace's row is untouched — the scope is in the
    // WHERE clause, so a delete cannot reach across.
    const survivor = try documents_store.getDocument(alloc, &ctx.db, "ws_2", "doc_b");
    defer documents_store.freeDocumentRow(alloc, survivor);
    try testing.expectEqualStrings("doc_b", survivor.id);
}

test "useCase: another workspace's document id deletes nothing" {
    const alloc = testing.allocator;
    var ctx = try setupDb();
    defer ctx.threaded.deinit();
    defer ctx.db.deinit();

    try testing.expectError(
        error.NotFound,
        useCase(alloc, &ctx.db, .{ .workspace_id = "ws_2", .document_id = "doc_a" }),
    );
    try testing.expectEqual(@as(usize, 2), try countRows(&ctx));
}

test "useCase: deleting the same document twice reports NotFound the second time" {
    const alloc = testing.allocator;
    var ctx = try setupDb();
    defer ctx.threaded.deinit();
    defer ctx.db.deinit();

    try useCase(alloc, &ctx.db, .{ .workspace_id = "ws_1", .document_id = "doc_a" });
    try testing.expectError(
        error.NotFound,
        useCase(alloc, &ctx.db, .{ .workspace_id = "ws_1", .document_id = "doc_a" }),
    );
    try testing.expectEqual(@as(usize, 1), try countRows(&ctx));
}
