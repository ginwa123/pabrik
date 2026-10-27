//! `GET /api/workspaces/:workspace_id/documents`. Returns `{documents,
//! count}` for one workspace, most-recently-updated first.

const std = @import("std");
const pabrikcore = @import("pabrikcore");
const gserverz = pabrikcore.gserverz;
const http_response = @import("http_response.zig");
const documents_store = @import("../agentic_loop/documents_store.zig");

pub const DocumentsListError = error{
    WorkspaceIdRequired,
    QueryFailed,
    OutOfMemory,
};

pub const DocumentsListInput = struct {
    workspace_id: []const u8,
};

pub const DocumentsListOutput = struct {
    /// Owned slice; the caller frees it with
    /// `documents_store.freeDocumentRows`.
    documents: []documents_store.DocumentRow,
};

// =====================================================================
// Use case
// =====================================================================

fn useCase(
    allocator: std.mem.Allocator,
    db: *pabrikcore.database.Db,
    input: DocumentsListInput,
) DocumentsListError!DocumentsListOutput {
    if (input.workspace_id.len == 0) return error.WorkspaceIdRequired;
    return .{ .documents = try documents_store.listDocuments(allocator, db, input.workspace_id) };
}

// =====================================================================
// Handler
// =====================================================================

pub fn documentsListHandler(
    ctx: gserverz.HttpContext,
    req: gserverz.HttpRequest,
    res: gserverz.HttpResponse,
) !gserverz.HttpResponse {
    const allocator = ctx.allocator;

    const di = try pabrikcore.getSingleton();
    const sqlite_db = di.db;

    const workspace_id = req.params.get("workspace_id") orelse "";

    const output = useCase(allocator, sqlite_db, .{ .workspace_id = workspace_id }) catch |err| {
        const status: u16 = switch (err) {
            error.WorkspaceIdRequired => 400,
            error.QueryFailed, error.OutOfMemory => 500,
        };
        const message: []const u8 = switch (err) {
            error.WorkspaceIdRequired => "workspace_id required",
            error.QueryFailed => "DB error",
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
    try db.init(io, ":memory:");

    try migration.Migration098CreateDocuments.up(&db, testing.allocator);
    return .{ .db = db, .threaded = threaded };
}

test "useCase: empty workspace_id returns WorkspaceIdRequired" {
    const alloc = testing.allocator;
    var ctx = try setupDb();
    defer ctx.threaded.deinit();
    defer ctx.db.deinit();

    try testing.expectError(
        error.WorkspaceIdRequired,
        useCase(alloc, &ctx.db, .{ .workspace_id = "" }),
    );
}

test "useCase: a workspace with no documents returns an empty list" {
    const alloc = testing.allocator;
    var ctx = try setupDb();
    defer ctx.threaded.deinit();
    defer ctx.db.deinit();

    const output = try useCase(alloc, &ctx.db, .{ .workspace_id = "ws_1" });
    defer documents_store.freeDocumentRows(alloc, output.documents);
    try testing.expectEqual(@as(usize, 0), output.documents.len);
}

test "useCase: never returns another workspace's documents" {
    const alloc = testing.allocator;
    var ctx = try setupDb();
    defer ctx.threaded.deinit();
    defer ctx.db.deinit();

    try ctx.db.exec(alloc,
        \\INSERT INTO documents (id, workspace_id, title, content) VALUES
        \\  ('doc_a', 'ws_1', 'A', 'body a'),
        \\  ('doc_b', 'ws_2', 'B', 'body b')
    , &.{});

    const mine = try useCase(alloc, &ctx.db, .{ .workspace_id = "ws_1" });
    defer documents_store.freeDocumentRows(alloc, mine.documents);
    try testing.expectEqual(@as(usize, 1), mine.documents.len);
    try testing.expectEqualStrings("doc_a", mine.documents[0].id);
    try testing.expectEqualStrings("body a", mine.documents[0].content);

    // The foreign workspace sees only its own row — no leak in either
    // direction, and no "empty because mis-scoped" false negative.
    const theirs = try useCase(alloc, &ctx.db, .{ .workspace_id = "ws_2" });
    defer documents_store.freeDocumentRows(alloc, theirs.documents);
    try testing.expectEqual(@as(usize, 1), theirs.documents.len);
    try testing.expectEqualStrings("doc_b", theirs.documents[0].id);
}

// ─── Route contracts ────────────────────────────────────────────────────
// `matchRoute` walks one shared table in REGISTRATION ORDER, so whether a
// literal segment is reachable is a property of that TABLE, not of this
