//! Exporting documents as downloads: `GET .../documents/:id/export` answers one file,
//! `POST .../documents/export` answers one zip. Both go through `documents_export`, the same
//! module the headless CLI uses, so a download and `pabrik headless documents export` agree.

const std = @import("std");
const pabrikcore = @import("pabrikcore");
const test_db = pabrikcore.test_db;
const gserverz = pabrikcore.gserverz;
const http_response = @import("http_response.zig");
const documents_store = @import("../modules/agent/loop/documents_store.zig");
const documents_export = @import("../modules/agent/loop/documents_export.zig");

fn errorResponse(
    allocator: std.mem.Allocator,
    res: gserverz.HttpResponse,
    err: documents_export.ExportError,
) !gserverz.HttpResponse {
    const status: u16 = switch (err) {
        error.IdsRequired, error.NoDocuments => 400,
        error.NotFound => 404,
        error.QueryFailed, error.TooManyEntries, error.OutOfMemory => 500,
    };
    const message: []const u8 = switch (err) {
        error.IdsRequired => "workspace_id and document_id required",
        error.NoDocuments => "document_ids must name at least one document",
        // One message for "no such id" and "belongs to another workspace",
        // matching the GET handler: this call must not probe another
        // workspace's row ids.
        error.NotFound => "document not found",
        error.QueryFailed => "DB error",
        error.TooManyEntries => "too many documents for one archive",
        error.OutOfMemory => "Out of memory",
    };
    return res.jsonResponse(.{
        .status_code = status,
        .data = try http_response.makeErrorResponse(allocator, .{ .@"error" = message }),
    });
}

pub fn documentsExportHandler(
    ctx: gserverz.HttpContext,
    req: gserverz.HttpRequest,
    res: gserverz.HttpResponse,
) !gserverz.HttpResponse {
    const allocator = ctx.allocator;

    const di = try pabrikcore.getSingleton();
    const file = documents_export.exportOne(
        allocator,
        .{ .db = di.db, .storage = di.objectStore() },
        req.params.get("workspace_id") orelse "",
        req.params.get("document_id") orelse "",
    ) catch |err| return errorResponse(allocator, res, err);

    const disposition = try documents_export.contentDisposition(allocator, file.name);
    return gserverz.HttpResponse.init(200, "OK", allocator)
        .withBody(file.bytes)
        .setContentType(file.mime)
        .withHeader("Content-Disposition", disposition)
        .withHeader("X-Content-Type-Options", "nosniff")
        .withHeader("Cache-Control", "no-store");
}

const ExportBody = struct {
    document_ids: []const []const u8 = &.{},
};

pub fn documentsExportZipHandler(
    ctx: gserverz.HttpContext,
    req: gserverz.HttpRequest,
    res: gserverz.HttpResponse,
) !gserverz.HttpResponse {
    const allocator = ctx.allocator;

    const di = try pabrikcore.getSingleton();

    var body = ExportBody{};
    if (req.body.len > 0) {
        body = std.json.parseFromSliceLeaky(ExportBody, allocator, req.body, .{}) catch {
            return res.jsonResponse(.{
                .status_code = 400,
                .data = try http_response.makeErrorResponse(allocator, .{ .@"error" = "Invalid JSON body" }),
            });
        };
    }

    const archive = documents_export.exportMany(
        allocator,
        .{ .db = di.db, .storage = di.objectStore() },
        req.params.get("workspace_id") orelse "",
        body.document_ids,
    ) catch |err| return errorResponse(allocator, res, err);

    const disposition = try documents_export.contentDisposition(allocator, archive.name);
    return gserverz.HttpResponse.init(200, "OK", allocator)
        .withBody(archive.bytes)
        .setContentType(archive.mime)
        .withHeader("Content-Disposition", disposition)
        .withHeader("X-Content-Type-Options", "nosniff")
        .withHeader("Cache-Control", "no-store");
}

// ─── Tests ──────────────────────────────────────────────────────────────

const database = pabrikcore.database;
const testing = std.testing;
const migration = @import("../migrations/migration.zig");
const memory_backend = pabrikcore.storage.memory;

const TestCtx = struct {
    db: database.Db,
    threaded: std.Io.Threaded,
    objects: memory_backend.MemoryStorage,

    fn deinit(self: *TestCtx) void {
        self.objects.deinit();
        self.db.deinit();
        self.threaded.deinit();
    }

    fn store(self: *TestCtx) documents_store.Store {
        return .{ .db = &self.db, .storage = self.objects.asStorage() };
    }
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
    try migration.Migration144DropDocumentContent.up(&db, testing.allocator);
    try migration.Migration148AddDocumentIcon.up(&db, testing.allocator);
    return .{
        .db = db,
        .threaded = threaded,
        .objects = memory_backend.MemoryStorage.init(testing.allocator),
    };
}

test "exportOne: a markdown document exports its body under a .md name" {
    const alloc = testing.allocator;
    var ctx = try setupDb();
    defer ctx.deinit();

    const created = try ctx.store().createDocument(alloc, .{
        .workspace_id = "ws_1",
        .title = "Release plan",
        .content = "# v1\n\nship it",
    });
    defer documents_store.freeDocumentRow(alloc, created);

    const file = try documents_export.exportOne(alloc, ctx.store(), "ws_1", created.id);
    defer {
        alloc.free(file.name);
        alloc.free(file.bytes);
    }

    try testing.expectEqualStrings("Release plan.md", file.name);
    try testing.expectEqualStrings("text/markdown; charset=utf-8", file.mime);
    try testing.expectEqualStrings("# v1\n\nship it", file.bytes);
}

test "exportOne: an office document exports its snapshot as .json" {
    const alloc = testing.allocator;
    var ctx = try setupDb();
    defer ctx.deinit();

    const body = "{\"kind\":\"sheet\",\"snapshot\":{\"sheets\":{}}}";
    const created = try ctx.store().createDocument(alloc, .{
        .workspace_id = "ws_1",
        .title = "Budget",
        .content = body,
        .format = documents_store.FORMAT_OFFICE,
    });
    defer documents_store.freeDocumentRow(alloc, created);

    const file = try documents_export.exportOne(alloc, ctx.store(), "ws_1", created.id);
    defer {
        alloc.free(file.name);
        alloc.free(file.bytes);
    }

    try testing.expectEqualStrings("Budget.json", file.name);
    try testing.expectEqualStrings("application/json", file.mime);
    try testing.expectEqualStrings(body, file.bytes);
}

test "exportOne: another workspace's document is NotFound, not exported" {
    const alloc = testing.allocator;
    var ctx = try setupDb();
    defer ctx.deinit();

    const created = try ctx.store().createDocument(alloc, .{
        .workspace_id = "ws_1",
        .title = "Secret",
        .content = "nope",
    });
    defer documents_store.freeDocumentRow(alloc, created);

    try testing.expectError(error.NotFound, documents_export.exportOne(alloc, ctx.store(), "ws_2", created.id));
    try testing.expectError(error.NotFound, documents_export.exportOne(alloc, ctx.store(), "ws_1", "doc_missing"));
}

test "exportOne: an empty id is refused before any read" {
    const alloc = testing.allocator;
    var ctx = try setupDb();
    defer ctx.deinit();

    try testing.expectError(error.IdsRequired, documents_export.exportOne(alloc, ctx.store(), "", "doc_a"));
    try testing.expectError(error.IdsRequired, documents_export.exportOne(alloc, ctx.store(), "ws_1", ""));
}

test "exportMany: two documents become one zip holding both bodies" {
    const alloc = testing.allocator;
    var ctx = try setupDb();
    defer ctx.deinit();

    const first = try ctx.store().createDocument(alloc, .{
        .workspace_id = "ws_1",
        .title = "Plan",
        .content = "# plan",
    });
    defer documents_store.freeDocumentRow(alloc, first);
    const second = try ctx.store().createDocument(alloc, .{
        .workspace_id = "ws_1",
        .title = "Notes",
        .content = "notes",
    });
    defer documents_store.freeDocumentRow(alloc, second);

    const archive = try documents_export.exportMany(alloc, ctx.store(), "ws_1", &.{ first.id, second.id });
    defer alloc.free(archive.bytes);

    try testing.expectEqualStrings("documents.zip", archive.name);
    try testing.expectEqualStrings("application/zip", archive.mime);
    try testing.expectEqual(@as(usize, 2), archive.count);
    try testing.expect(std.mem.startsWith(u8, archive.bytes, "PK\x03\x04"));
    try testing.expect(std.mem.indexOf(u8, archive.bytes, "Plan.md") != null);
    try testing.expect(std.mem.indexOf(u8, archive.bytes, "Notes.md") != null);
    try testing.expect(std.mem.indexOf(u8, archive.bytes, "# plan") != null);
}

test "exportMany: two documents with the same title get distinct entries" {
    const alloc = testing.allocator;
    var ctx = try setupDb();
    defer ctx.deinit();

    const first = try ctx.store().createDocument(alloc, .{
        .workspace_id = "ws_1",
        .title = "Untitled document",
        .content = "one",
    });
    defer documents_store.freeDocumentRow(alloc, first);
    const second = try ctx.store().createDocument(alloc, .{
        .workspace_id = "ws_1",
        .title = "Untitled document",
        .content = "two",
    });
    defer documents_store.freeDocumentRow(alloc, second);

    const archive = try documents_export.exportMany(alloc, ctx.store(), "ws_1", &.{ first.id, second.id });
    defer alloc.free(archive.bytes);

    try testing.expect(std.mem.indexOf(u8, archive.bytes, "Untitled document.md") != null);
    try testing.expect(std.mem.indexOf(u8, archive.bytes, "Untitled document (2).md") != null);
}

test "exportMany: an empty id list is refused rather than zipped empty" {
    const alloc = testing.allocator;
    var ctx = try setupDb();
    defer ctx.deinit();

    try testing.expectError(error.NoDocuments, documents_export.exportMany(alloc, ctx.store(), "ws_1", &.{}));
}

test "exportMany: one unknown id fails the whole archive instead of dropping it" {
    const alloc = testing.allocator;
    var ctx = try setupDb();
    defer ctx.deinit();

    const created = try ctx.store().createDocument(alloc, .{
        .workspace_id = "ws_1",
        .title = "Plan",
        .content = "x",
    });
    defer documents_store.freeDocumentRow(alloc, created);

    try testing.expectError(
        error.NotFound,
        documents_export.exportMany(alloc, ctx.store(), "ws_1", &.{ created.id, "doc_missing" }),
    );
}
