//! `POST /api/workspaces/:workspace_id/document-folders`. Creates a folder,
//! at the root when `parent_id` is absent or null.

const std = @import("std");
const pabrikcore = @import("pabrikcore");
const test_db = pabrikcore.test_db;
const gserverz = pabrikcore.gserverz;
const http_response = @import("http_response.zig");
const folders_store = @import("../agentic_loop/document_folders_store.zig");

const CreateFolderBody = struct {
    name: []const u8 = "",
    parent_id: ?[]const u8 = null,
};

pub const FolderCreateInput = struct {
    workspace_id: []const u8,
    body: CreateFolderBody,
};

pub const FolderCreateOutput = struct {
    folder: folders_store.FolderRow,
};

fn useCase(
    allocator: std.mem.Allocator,
    db: *pabrikcore.database.Db,
    input: FolderCreateInput,
) folders_store.CreateFolderError!FolderCreateOutput {
    if (input.workspace_id.len == 0) return error.WorkspaceIdRequired;
    return .{ .folder = try folders_store.createFolder(allocator, db, .{
        .workspace_id = input.workspace_id,
        .name = input.body.name,
        .parent_id = input.body.parent_id,
    }) };
}

pub fn documentFoldersCreateHandler(
    ctx: gserverz.HttpContext,
    req: gserverz.HttpRequest,
    res: gserverz.HttpResponse,
) !gserverz.HttpResponse {
    const allocator = ctx.allocator;

    const di = try pabrikcore.getSingleton();
    const sqlite_db = di.db;

    var body = CreateFolderBody{};
    if (req.body.len > 0) {
        body = std.json.parseFromSliceLeaky(CreateFolderBody, allocator, req.body, .{}) catch {
            return res.jsonResponse(.{
                .status_code = 400,
                .data = try http_response.makeErrorResponse(allocator, .{ .@"error" = "Invalid JSON body" }),
            });
        };
    }

    const output = useCase(allocator, sqlite_db, .{
        .workspace_id = req.params.get("workspace_id") orelse "",
        .body = body,
    }) catch |err| {
        const status: u16 = switch (err) {
            error.WorkspaceIdRequired, error.NameRequired => 400,
            error.ParentNotFound => 404,
            error.TooDeep => 409,
            error.InsertFailed, error.RowNotFoundAfterInsert, error.QueryFailed, error.OutOfMemory => 500,
        };
        const message: []const u8 = switch (err) {
            error.WorkspaceIdRequired => "workspace_id required",
            error.NameRequired => "folder name is required",
            error.ParentNotFound => "parent folder not found in this workspace",
            error.TooDeep => "folders nest at most 5 levels deep",
            error.InsertFailed => "DB error",
            error.RowNotFoundAfterInsert => "row missing after insert (DB inconsistency)",
            error.QueryFailed => "DB error",
            error.OutOfMemory => "Out of memory",
        };
        return res.jsonResponse(.{
            .status_code = status,
            .data = try http_response.makeErrorResponse(allocator, .{ .@"error" = message }),
        });
    };
    defer folders_store.freeFolderRow(allocator, output.folder);

    const data = try std.json.Stringify.valueAlloc(allocator, .{
        .folder = http_response.makeFolderResponse(output.folder),
    }, .{});
    return res.jsonResponse(.{ .status_code = 201, .data = data });
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

test "useCase: a folder is created at the root and reads back" {
    const alloc = testing.allocator;
    var ctx = try setupDb();
    defer ctx.threaded.deinit();
    defer ctx.db.deinit();

    const output = try useCase(alloc, &ctx.db, .{
        .workspace_id = "ws_1",
        .body = .{ .name = "  Split bill  " },
    });
    defer folders_store.freeFolderRow(alloc, output.folder);

    try testing.expectEqualStrings("Split bill", output.folder.name);
    try testing.expectEqual(@as(?[]const u8, null), output.folder.parent_id);

    const listed = try folders_store.listFolders(alloc, &ctx.db, "ws_1");
    defer folders_store.freeFolderRows(alloc, listed);
    try testing.expectEqual(@as(usize, 1), listed.len);
}

test "useCase: a blank name is refused" {
    const alloc = testing.allocator;
    var ctx = try setupDb();
    defer ctx.threaded.deinit();
    defer ctx.db.deinit();

    try testing.expectError(
        error.NameRequired,
        useCase(alloc, &ctx.db, .{ .workspace_id = "ws_1", .body = .{ .name = "   " } }),
    );
}

test "useCase: a parent from another workspace is refused" {
    const alloc = testing.allocator;
    var ctx = try setupDb();
    defer ctx.threaded.deinit();
    defer ctx.db.deinit();

    const theirs = try folders_store.createFolder(alloc, &ctx.db, .{ .workspace_id = "ws_2", .name = "Theirs" });
    defer folders_store.freeFolderRow(alloc, theirs);

    try testing.expectError(
        error.ParentNotFound,
        useCase(alloc, &ctx.db, .{
            .workspace_id = "ws_1",
            .body = .{ .name = "Mine", .parent_id = theirs.id },
        }),
    );
}

test "useCase: an empty workspace_id is refused before any write" {
    const alloc = testing.allocator;
    var ctx = try setupDb();
    defer ctx.threaded.deinit();
    defer ctx.db.deinit();

    try testing.expectError(
        error.WorkspaceIdRequired,
        useCase(alloc, &ctx.db, .{ .workspace_id = "", .body = .{ .name = "x" } }),
    );
}
