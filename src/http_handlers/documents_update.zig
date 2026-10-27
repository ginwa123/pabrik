//! `PATCH /api/workspaces/:workspace_id/documents/:document_id`. Partial
//! update.

const std = @import("std");
const pabrikcore = @import("pabrikcore");
const test_db = pabrikcore.test_db;
const gserverz = pabrikcore.gserverz;
const http_response = @import("http_response.zig");
const documents_store = @import("../agentic_loop/documents_store.zig");

/// PATCH body. Both fields are optional and both default to `null` so
/// `"content": null` in the wire JSON is distinguishable from
/// `"content": ""` — the latter is a real "clear the body" instruction.
const UpdateDocumentBody = struct {
    title: ?[]const u8 = null,
    content: ?[]const u8 = null,
};

pub const DocumentsUpdateError = error{
    IdsRequired,
    NotFound,
    ContentTooLarge,
    UpdateFailed,
    QueryFailed,
    OutOfMemory,
};

pub const DocumentsUpdateInput = struct {
    workspace_id: []const u8,
    document_id: []const u8,
    body: UpdateDocumentBody,
};

pub const DocumentsUpdateOutput = struct {
    document: documents_store.DocumentRow,
};

// =====================================================================
// Use case
// =====================================================================

fn useCase(
    allocator: std.mem.Allocator,
    db: *pabrikcore.database.Db,
    input: DocumentsUpdateInput,
) DocumentsUpdateError!DocumentsUpdateOutput {
    if (input.workspace_id.len == 0 or input.document_id.len == 0) {
        return error.IdsRequired;
    }
    return .{ .document = try documents_store.updateDocument(
        allocator,
        db,
        input.workspace_id,
        input.document_id,
        .{ .title = input.body.title, .content = input.body.content },
    ) };
}

// =====================================================================
// Handler
// =====================================================================

pub fn documentsUpdateHandler(
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

    const body = std.json.parseFromSliceLeaky(UpdateDocumentBody, allocator, req.body, .{}) catch {
        return res.jsonResponse(.{
            .status_code = 400,
            .data = try http_response.makeErrorResponse(allocator, .{ .@"error" = "Invalid JSON body" }),
        });
    };

    const output = useCase(allocator, sqlite_db, .{
        .workspace_id = req.params.get("workspace_id") orelse "",
        .document_id = req.params.get("document_id") orelse "",
        .body = body,
    }) catch |err| {
        const status: u16 = switch (err) {
            error.IdsRequired => 400,
            // A blank title is a 400 in spirit (the row would become
            // unfindable in the sidebar); the store reports it as
            // NotFound so it cannot be distinguished from a foreign id.
            error.NotFound => 400,
            error.ContentTooLarge => 413,
            error.UpdateFailed, error.QueryFailed, error.OutOfMemory => 500,
        };
        const message: []const u8 = switch (err) {
            error.IdsRequired => "workspace_id and document_id required",
            error.NotFound => "document not found, or title would be empty",
            error.ContentTooLarge => "content exceeds the 4 MiB per-document cap",
            error.UpdateFailed => "DB error",
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

test "useCase: empty ids return IdsRequired" {
    const alloc = testing.allocator;
    var ctx = try setupDb();
    defer ctx.threaded.deinit();
    defer ctx.db.deinit();

    try testing.expectError(
        error.IdsRequired,
        useCase(alloc, &ctx.db, .{
            .workspace_id = "ws_1",
            .document_id = "",
            .body = .{ .title = "x" },
        }),
    );
}

test "useCase: a title-only PATCH leaves the body intact" {
    const alloc = testing.allocator;
    var ctx = try setupDb();
    defer ctx.threaded.deinit();
    defer ctx.db.deinit();

    // The regression this guards: writing `content = ''` for an absent
    // field would silently destroy the document body.
    const output = try useCase(alloc, &ctx.db, .{
        .workspace_id = "ws_1",
        .document_id = "doc_a",
        .body = .{ .title = "A renamed" },
    });
    defer documents_store.freeDocumentRow(alloc, output.document);

    try testing.expectEqualStrings("A renamed", output.document.title);
    try testing.expectEqualStrings("body a", output.document.content);
}

test "useCase: a body-only PATCH leaves the title intact" {
    const alloc = testing.allocator;
    var ctx = try setupDb();
    defer ctx.threaded.deinit();
    defer ctx.db.deinit();

    const output = try useCase(alloc, &ctx.db, .{
        .workspace_id = "ws_1",
        .document_id = "doc_a",
        .body = .{ .content = "body a, revised" },
    });
    defer documents_store.freeDocumentRow(alloc, output.document);

    try testing.expectEqualStrings("A", output.document.title);
    try testing.expectEqualStrings("body a, revised", output.document.content);
}

test "useCase: an explicit empty content clears the body without tripping NOT NULL" {
    const alloc = testing.allocator;
    var ctx = try setupDb();
    defer ctx.threaded.deinit();
    defer ctx.db.deinit();

    const output = try useCase(alloc, &ctx.db, .{
        .workspace_id = "ws_1",
        .document_id = "doc_a",
        .body = .{ .content = "" },
    });
    defer documents_store.freeDocumentRow(alloc, output.document);
    try testing.expectEqualStrings("", output.document.content);
}

test "useCase: an empty patch is a no-op that still advances updated_at" {
    const alloc = testing.allocator;
    var ctx = try setupDb();
    defer ctx.threaded.deinit();
    defer ctx.db.deinit();

    // Backdate so a same-second CURRENT_TIMESTAMP write is still
    // detectable as a change.
    try ctx.db.exec(alloc,
        "UPDATE documents SET updated_at = '2000-01-01 00:00:00' WHERE id = 'doc_a'",
        &.{},
    );

    const output = try useCase(alloc, &ctx.db, .{
        .workspace_id = "ws_1",
        .document_id = "doc_a",
        .body = .{},
    });
    defer documents_store.freeDocumentRow(alloc, output.document);

    try testing.expectEqualStrings("A", output.document.title);
    try testing.expectEqualStrings("body a", output.document.content);
    try testing.expect(!std.mem.eql(u8, output.document.updated_at, "2000-01-01 00:00:00"));
}

test "useCase: a blank title is rejected and leaves the row untouched" {
    const alloc = testing.allocator;
    var ctx = try setupDb();
    defer ctx.threaded.deinit();
    defer ctx.db.deinit();

    try testing.expectError(
        error.NotFound,
        useCase(alloc, &ctx.db, .{
            .workspace_id = "ws_1",
            .document_id = "doc_a",
            .body = .{ .title = "   " },
        }),
    );

    const after = try useCase(alloc, &ctx.db, .{
        .workspace_id = "ws_1",
        .document_id = "doc_a",
        .body = .{},
    });
    defer documents_store.freeDocumentRow(alloc, after.document);
    try testing.expectEqualStrings("A", after.document.title);
}

test "useCase: another workspace's document cannot be edited" {
    const alloc = testing.allocator;
    var ctx = try setupDb();
    defer ctx.threaded.deinit();
    defer ctx.db.deinit();

    try testing.expectError(
        error.NotFound,
        useCase(alloc, &ctx.db, .{
            .workspace_id = "ws_2",
            .document_id = "doc_a",
            .body = .{ .content = "hijacked" },
        }),
    );

    // The owner's copy is unchanged — a rejected cross-workspace edit must
    // not have half-applied.
    const owner = try useCase(alloc, &ctx.db, .{
        .workspace_id = "ws_1",
        .document_id = "doc_a",
        .body = .{},
    });
    defer documents_store.freeDocumentRow(alloc, owner.document);
    try testing.expectEqualStrings("body a", owner.document.content);
}
