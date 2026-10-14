//! `GET /api/workspaces/:workspace_id/documents/:document_id`. Returns
//! `{document}` for one document.

const std = @import("std");
const pabrikcore = @import("pabrikcore");
const gserverz = pabrikcore.gserverz;
const http_response = @import("http_response.zig");
const documents_store = @import("../agentic_loop/documents_store.zig");

pub const DocumentsGetError = error{
    IdsRequired,
    NotFound,
    QueryFailed,
    OutOfMemory,
};

pub const DocumentsGetInput = struct {
    workspace_id: []const u8,
    document_id: []const u8,
};

pub const DocumentsGetOutput = struct {
    document: documents_store.DocumentRow,
};

// =====================================================================
// Use case
// =====================================================================

fn useCase(
    allocator: std.mem.Allocator,
    db: *pabrikcore.sqlite.SqliteBackend,
    input: DocumentsGetInput,
) DocumentsGetError!DocumentsGetOutput {
    if (input.workspace_id.len == 0 or input.document_id.len == 0) {
        return error.IdsRequired;
    }
    return .{ .document = try documents_store.getDocument(
        allocator,
        db,
        input.workspace_id,
        input.document_id,
    ) };
}

// =====================================================================
// Handler
// =====================================================================

pub fn documentsGetHandler(
    ctx: gserverz.HttpContext,
    req: gserverz.HttpRequest,
    res: gserverz.HttpResponse,
) !gserverz.HttpResponse {
    const allocator = ctx.allocator;

    const di = try pabrikcore.getSingleton();
    const sqlite_db = di.db;

    const output = useCase(allocator, sqlite_db, .{
        .workspace_id = req.params.get("workspace_id") orelse "",
        .document_id = req.params.get("document_id") orelse "",
    }) catch |err| {
        const status: u16 = switch (err) {
            error.IdsRequired => 400,
            error.NotFound => 404,
            error.QueryFailed, error.OutOfMemory => 500,
        };
        const message: []const u8 = switch (err) {
            error.IdsRequired => "workspace_id and document_id required",
            // One message for "no such id" and "belongs to another
            // workspace" on purpose — see the file header.
            error.NotFound => "document not found",
            error.QueryFailed => "DB error",
            error.OutOfMemory => "Out of memory",
        };
        return res.jsonResponse(.{
            .status_code = status,
            .data = try http_response.makeErrorResponse(allocator, .{ .@"error" = message }),
        });
    };
    defer documents_store.freeDocumentRow(allocator, output.document);

    const data = try std.json.Stringify.valueAlloc(allocator, .{
        .document = http_response.makeDocumentResponse(output.document),
    }, .{});
    return res.jsonResponse(.{ .status_code = 200, .data = data });
}

// ─── Tests ──────────────────────────────────────────────────────────────

const sqlite = pabrikcore.sqlite;
const testing = std.testing;
const migration = @import("../migrations/migration.zig");

const TestCtx = struct {
    db: sqlite.SqliteBackend,
    threaded: std.Io.Threaded,
};

fn setupDb() !TestCtx {
    var threaded = std.Io.Threaded.init(testing.allocator, .{});
    errdefer threaded.deinit();
    const io = threaded.io();
    var db: sqlite.SqliteBackend = .{};
    errdefer db.deinit();
    try db.init(io, ":memory:");

    try migration.Migration098CreateDocuments.up(&db, testing.allocator);
    try db.exec(testing.allocator,
        \\INSERT INTO documents (id, workspace_id, title, content) VALUES
        \\  ('doc_a', 'ws_1', 'A', 'body a'),
        \\  ('doc_b', 'ws_2', 'B', 'body b')
    , &.{});
    return .{ .db = db, .threaded = threaded };
}

test "useCase: empty ids return IdsRequired" {
    const alloc = testing.allocator;
    var ctx = try setupDb();
    defer ctx.threaded.deinit();
    defer ctx.db.deinit();

    try testing.expectError(
        error.IdsRequired,
        useCase(alloc, &ctx.db, .{ .workspace_id = "", .document_id = "doc_a" }),
    );
    try testing.expectError(
        error.IdsRequired,
        useCase(alloc, &ctx.db, .{ .workspace_id = "ws_1", .document_id = "" }),
    );
}

test "useCase: happy path returns the document body" {
    const alloc = testing.allocator;
    var ctx = try setupDb();
    defer ctx.threaded.deinit();
    defer ctx.db.deinit();

    const output = try useCase(alloc, &ctx.db, .{ .workspace_id = "ws_1", .document_id = "doc_a" });
    defer documents_store.freeDocumentRow(alloc, output.document);

    try testing.expectEqualStrings("doc_a", output.document.id);
    try testing.expectEqualStrings("A", output.document.title);
    try testing.expectEqualStrings("body a", output.document.content);
    try testing.expectEqualStrings("markdown", output.document.format);
}

test "useCase: another workspace's document id is NotFound, not forbidden" {
    const alloc = testing.allocator;
    var ctx = try setupDb();
    defer ctx.threaded.deinit();
    defer ctx.db.deinit();

    try testing.expectError(
        error.NotFound,
        useCase(alloc, &ctx.db, .{ .workspace_id = "ws_2", .document_id = "doc_a" }),
    );
    try testing.expectError(
        error.NotFound,
        useCase(alloc, &ctx.db, .{ .workspace_id = "ws_1", .document_id = "nope" }),
    );
}
