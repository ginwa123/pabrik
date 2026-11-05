//! `DELETE …/document-folders/:folder_id`. Deletes the folder, never its
//! contents: children move one level up, and the count in the response lets the
//! UI promise "0 documents deleted" and be right.

const std = @import("std");
const pabrikcore = @import("pabrikcore");
const test_db = pabrikcore.test_db;
const gserverz = pabrikcore.gserverz;
const http_response = @import("http_response.zig");
const folders_store = @import("../agentic_loop/document_folders_store.zig");

pub const FolderDeleteInput = struct {
    workspace_id: []const u8,
    folder_id: []const u8,
};

pub const FolderDeleteOutput = struct {
    folder_id: []const u8,
    reparented_documents: usize,
};

fn useCase(
    allocator: std.mem.Allocator,
    db: *pabrikcore.database.Db,
    input: FolderDeleteInput,
) folders_store.DeleteFolderError!FolderDeleteOutput {
    if (input.workspace_id.len == 0 or input.folder_id.len == 0) return error.IdsRequired;
    return .{
        .folder_id = input.folder_id,
        .reparented_documents = try folders_store.deleteFolder(allocator, db, input.workspace_id, input.folder_id),
    };
}

pub fn documentFoldersDeleteHandler(
    ctx: gserverz.HttpContext,
    req: gserverz.HttpRequest,
    res: gserverz.HttpResponse,
) !gserverz.HttpResponse {
    const allocator = ctx.allocator;

    const di = try pabrikcore.getSingleton();
    const sqlite_db = di.db;

    const output = useCase(allocator, sqlite_db, .{
        .workspace_id = req.params.get("workspace_id") orelse "",
        .folder_id = req.params.get("folder_id") orelse "",
    }) catch |err| {
        const status: u16 = switch (err) {
            error.IdsRequired => 400,
            error.NotFound => 404,
            error.DeleteFailed, error.QueryFailed, error.TransactionFailed, error.OutOfMemory => 500,
        };
        const message: []const u8 = switch (err) {
            error.IdsRequired => "workspace_id and folder_id required",
            error.NotFound => "folder not found in this workspace",
            error.DeleteFailed => "DB error",
            error.QueryFailed => "DB error",
            error.TransactionFailed => "DB error",
            error.OutOfMemory => "Out of memory",
        };
        return res.jsonResponse(.{
            .status_code = status,
            .data = try http_response.makeErrorResponse(allocator, .{ .@"error" = message }),
        });
    };

    const data = try std.json.Stringify.valueAlloc(allocator, .{
        .id = output.folder_id,
        .success = true,
        .reparented_documents = output.reparented_documents,
    }, .{});
    return res.jsonResponse(.{ .status_code = 200, .data = data });
}

// ─── Tests ──────────────────────────────────────────────────────────────

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
    return .{ .db = db, .threaded = threaded };
}

test "useCase: deleting a folder reports the documents it kept" {
    const alloc = testing.allocator;
    var ctx = try setupDb();
    defer ctx.threaded.deinit();
    defer ctx.db.deinit();

    const doomed = try folders_store.createFolder(alloc, &ctx.db, .{ .workspace_id = "ws_1", .name = "Doomed" });
    defer folders_store.freeFolderRow(alloc, doomed);

    const row = try @import("../agentic_loop/documents_store.zig").createDocument(alloc, &ctx.db, .{
        .workspace_id = "ws_1",
        .title = "Inside",
        .folder_id = doomed.id,
    });
    defer @import("../agentic_loop/documents_store.zig").freeDocumentRow(alloc, row);

    const output = try useCase(alloc, &ctx.db, .{
        .workspace_id = "ws_1",
        .folder_id = doomed.id,
    });
    try testing.expectEqual(@as(usize, 1), output.reparented_documents);

    const folders = try folders_store.listFolders(alloc, &ctx.db, "ws_1");
    defer folders_store.freeFolderRows(alloc, folders);
    try testing.expectEqual(@as(usize, 0), folders.len);

    const after = try @import("../agentic_loop/documents_store.zig").getDocument(alloc, &ctx.db, "ws_1", row.id);
    defer @import("../agentic_loop/documents_store.zig").freeDocumentRow(alloc, after);
    try testing.expectEqual(@as(?[]const u8, null), after.folder_id);
}

test "useCase: an unknown folder is a NotFound and no error is invented" {
    const alloc = testing.allocator;
    var ctx = try setupDb();
    defer ctx.threaded.deinit();
    defer ctx.db.deinit();

    try testing.expectError(
        error.NotFound,
        useCase(alloc, &ctx.db, .{ .workspace_id = "ws_1", .folder_id = "fld_missing" }),
    );
}

test "useCase: an empty workspace_id is refused" {
    const alloc = testing.allocator;
    var ctx = try setupDb();
    defer ctx.threaded.deinit();
    defer ctx.db.deinit();

    try testing.expectError(
        error.IdsRequired,
        useCase(alloc, &ctx.db, .{ .workspace_id = "", .folder_id = "fld_x" }),
    );
}
