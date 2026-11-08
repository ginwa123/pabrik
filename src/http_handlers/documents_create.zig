//! `POST /api/workspaces/:workspace_id/documents`. Creates a markdown
//! document owned by `workspace_id`.

const std = @import("std");
const pabrikcore = @import("pabrikcore");
const test_db = pabrikcore.test_db;
const gserverz = pabrikcore.gserverz;
const http_response = @import("http_response.zig");
const documents_store = @import("../modules/agent/loop/documents_store.zig");
const document_events = @import("../modules/agent/loop/document_events.zig");

/// Request body.
const CreateDocumentBody = struct {
    title: []const u8 = "",
    content: []const u8 = "",
    format: []const u8 = "",
    /// Absent or null creates the document at the root.
    folder_id: ?[]const u8 = null,
};

pub const DocumentsCreateError = error{
    WorkspaceIdRequired,
    TitleRequired,
    ContentTooLarge,
    FolderNotFound,
    InsertFailed,
    RowNotFoundAfterInsert,
    OutOfMemory,
};

pub const DocumentsCreateInput = struct {
    workspace_id: []const u8,
    body: CreateDocumentBody,
};

pub const DocumentsCreateOutput = struct {
    document: documents_store.DocumentRow,
};

// =====================================================================
// Use case
// =====================================================================

fn useCase(
    allocator: std.mem.Allocator,
    store: documents_store.Store,
    input: DocumentsCreateInput,
) DocumentsCreateError!DocumentsCreateOutput {
    if (input.workspace_id.len == 0) return error.WorkspaceIdRequired;
    return .{ .document = try store.createDocument(allocator, .{
        .workspace_id = input.workspace_id,
        .title = input.body.title,
        .content = input.body.content,
        .format = input.body.format,
        .folder_id = input.body.folder_id,
    }) };
}

// =====================================================================
// Handler
// =====================================================================

pub fn documentsCreateHandler(
    ctx: gserverz.HttpContext,
    req: gserverz.HttpRequest,
    res: gserverz.HttpResponse,
) !gserverz.HttpResponse {
    const allocator = ctx.allocator;

    const di = try pabrikcore.getSingleton();
    const sqlite_db = di.db;

    const workspace_id = req.params.get("workspace_id") orelse "";

    // An empty body is legal — it means "blank note with the default
    // title", and the store owns the title validation so the agent tool
    // gets the same rule. Only unparseable JSON is a 400 here.
    var body = CreateDocumentBody{};
    if (req.body.len > 0) {
        body = std.json.parseFromSliceLeaky(CreateDocumentBody, allocator, req.body, .{}) catch {
            return res.jsonResponse(.{
                .status_code = 400,
                .data = try http_response.makeErrorResponse(allocator, .{ .@"error" = "Invalid JSON body" }),
            });
        };
    }

    const output = useCase(allocator, .{ .db = sqlite_db, .storage = di.objectStore() }, .{
        .workspace_id = workspace_id,
        .body = body,
    }) catch |err| {
        const status: u16 = switch (err) {
            error.WorkspaceIdRequired, error.TitleRequired => 400,
            error.ContentTooLarge => 413,
            error.FolderNotFound => 404,
            error.InsertFailed, error.RowNotFoundAfterInsert, error.OutOfMemory => 500,
        };
        const message: []const u8 = switch (err) {
            error.WorkspaceIdRequired => "workspace_id required",
            error.TitleRequired => "title is required",
            error.ContentTooLarge => "content exceeds the 4 MiB per-document cap",
            error.FolderNotFound => "folder not found in this workspace",
            error.InsertFailed => "DB error",
            error.RowNotFoundAfterInsert => "row missing after insert (DB inconsistency)",
            error.OutOfMemory => "Out of memory",
        };
        return res.jsonResponse(.{
            .status_code = status,
            .data = try http_response.makeErrorResponse(allocator, .{ .@"error" = message }),
        });
    };
    defer documents_store.freeDocumentRow(allocator, output.document);

    // A create changes the tree every window is showing.
    document_events.emitDocumentEvent(allocator, di.event_bus, .{
        .action = "created",
        .workspace_id = output.document.workspace_id,
        .document_id = output.document.id,
        .folder_id = output.document.folder_id orelse "",
        .title = output.document.title,
    });

    const data = try std.json.Stringify.valueAlloc(allocator, .{
        .document = http_response.makeDocumentResponse(output.document),
    }, .{});
    return res.jsonResponse(.{ .status_code = 201, .data = data });
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
    try migration.Migration122AddDocumentPosition.up(&db, testing.allocator);
    try migration.Migration140AddDocumentFolders.up(&db, testing.allocator);
    try migration.Migration143AddDocumentContentKey.up(&db, testing.allocator);
    return .{ .db = db, .threaded = threaded };
}

test "useCase: empty workspace_id returns WorkspaceIdRequired" {
    const alloc = testing.allocator;
    var ctx = try setupDb();
    defer ctx.threaded.deinit();
    defer ctx.db.deinit();

    try testing.expectError(
        error.WorkspaceIdRequired,
        useCase(alloc, .{ .db = &ctx.db }, .{ .workspace_id = "", .body = .{ .title = "x" } }),
    );
}

test "useCase: a blank or whitespace-only title returns TitleRequired" {
    const alloc = testing.allocator;
    var ctx = try setupDb();
    defer ctx.threaded.deinit();
    defer ctx.db.deinit();

    try testing.expectError(
        error.TitleRequired,
        useCase(alloc, .{ .db = &ctx.db }, .{ .workspace_id = "ws_1", .body = .{ .title = "" } }),
    );
    try testing.expectError(
        error.TitleRequired,
        useCase(alloc, .{ .db = &ctx.db }, .{ .workspace_id = "ws_1", .body = .{ .title = "   \n\t " } }),
    );
}

test "useCase: creates a markdown document and stamps both timestamps" {
    const alloc = testing.allocator;
    var ctx = try setupDb();
    defer ctx.threaded.deinit();
    defer ctx.db.deinit();

    const output = try useCase(alloc, .{ .db = &ctx.db }, .{
        .workspace_id = "ws_1",
        .body = .{ .title = "  Release notes  ", .content = "# v1\n\nship it" },
    });
    defer documents_store.freeDocumentRow(alloc, output.document);

    try testing.expectEqualStrings("ws_1", output.document.workspace_id);
    // Trimmed — the sidebar row must not render leading padding.
    try testing.expectEqualStrings("Release notes", output.document.title);
    try testing.expectEqualStrings("# v1\n\nship it", output.document.preview);
    try testing.expectEqualStrings("markdown", output.document.format);
    try testing.expect(output.document.id.len > 0);
    try testing.expect(output.document.created_at.len > 0);
    try testing.expect(output.document.updated_at.len > 0);
}

test "useCase: an empty body is stored as \"\" not NULL" {
    const alloc = testing.allocator;
    var ctx = try setupDb();
    defer ctx.threaded.deinit();
    defer ctx.db.deinit();

    // The empty slice would bind as SQL NULL and violate
    // `content TEXT NOT NULL`; COALESCE(NULLIF(?, ''), '') is what stops
    // that, so a blank note must survive the round-trip.
    const output = try useCase(alloc, .{ .db = &ctx.db }, .{
        .workspace_id = "ws_1",
        .body = .{ .title = "Blank", .content = "" },
    });
    defer documents_store.freeDocumentRow(alloc, output.document);
    try testing.expectEqualStrings("", output.document.content);
}

test "useCase: an explicit format is honoured, an empty one falls back to markdown" {
    const alloc = testing.allocator;
    var ctx = try setupDb();
    defer ctx.threaded.deinit();
    defer ctx.db.deinit();

    const plain = try useCase(alloc, .{ .db = &ctx.db }, .{
        .workspace_id = "ws_1",
        .body = .{ .title = "Text", .content = "x", .format = "text" },
    });
    defer documents_store.freeDocumentRow(alloc, plain.document);
    try testing.expectEqualStrings("text", plain.document.format);

    const fallback = try useCase(alloc, .{ .db = &ctx.db }, .{
        .workspace_id = "ws_1",
        .body = .{ .title = "Default", .content = "x", .format = "" },
    });
    defer documents_store.freeDocumentRow(alloc, fallback.document);
    try testing.expectEqualStrings("markdown", fallback.document.format);
}

test "useCase: the new document is invisible from another workspace" {
    const alloc = testing.allocator;
    var ctx = try setupDb();
    defer ctx.threaded.deinit();
    defer ctx.db.deinit();

    const output = try useCase(alloc, .{ .db = &ctx.db }, .{
        .workspace_id = "ws_1",
        .body = .{ .title = "Secret", .content = "nope" },
    });
    defer documents_store.freeDocumentRow(alloc, output.document);

    try testing.expectError(
        error.NotFound,
        documents_store.getDocument(alloc, &ctx.db, "ws_2", output.document.id),
    );
}
