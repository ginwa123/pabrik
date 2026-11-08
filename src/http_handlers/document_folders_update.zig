//! `PATCH …/document-folders/:folder_id`. `parent_id` presence separates the two
//! operations: absent renames, `null` moves to the root, a string nests. A cycle
//! or a sixth level is a 409 and writes nothing.

const std = @import("std");
const pabrikcore = @import("pabrikcore");
const test_db = pabrikcore.test_db;
const gserverz = pabrikcore.gserverz;
const http_response = @import("http_response.zig");
const folders_store = @import("../modules/agent/loop/document_folders_store.zig");
const document_events = @import("../modules/agent/loop/document_events.zig");

const UpdateFolderBody = struct {
    name: ?[]const u8 = null,
    parent_id: ?[]const u8 = null,
    move_parent: bool = false,
};

fn optionalString(
    obj: std.json.ObjectMap,
    key: []const u8,
) error{InvalidField}!?[]const u8 {
    const value = obj.get(key) orelse return null;
    return switch (value) {
        .string => |s| s,
        .null => null,
        else => error.InvalidField,
    };
}

pub const FolderUpdateInput = struct {
    workspace_id: []const u8,
    folder_id: []const u8,
    body: UpdateFolderBody,
};

pub const FolderUpdateOutput = struct {
    folder: folders_store.FolderRow,
};

fn useCase(
    allocator: std.mem.Allocator,
    db: *pabrikcore.database.Db,
    input: FolderUpdateInput,
) folders_store.UpdateFolderError!FolderUpdateOutput {
    if (input.workspace_id.len == 0 or input.folder_id.len == 0) return error.IdsRequired;
    return .{ .folder = try folders_store.updateFolder(allocator, db, input.workspace_id, input.folder_id, .{
        .name = input.body.name,
        .parent_id = input.body.parent_id,
        .move_parent = input.body.move_parent,
    }) };
}

pub fn documentFoldersUpdateHandler(
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

    const parsed = std.json.parseFromSliceLeaky(std.json.Value, allocator, req.body, .{}) catch {
        return res.jsonResponse(.{
            .status_code = 400,
            .data = try http_response.makeErrorResponse(allocator, .{ .@"error" = "Invalid JSON body" }),
        });
    };
    const obj = switch (parsed) {
        .object => |o| o,
        else => return res.jsonResponse(.{
            .status_code = 400,
            .data = try http_response.makeErrorResponse(allocator, .{ .@"error" = "JSON body must be an object" }),
        }),
    };

    const body = UpdateFolderBody{
        .name = optionalString(obj, "name") catch {
            return res.jsonResponse(.{
                .status_code = 400,
                .data = try http_response.makeErrorResponse(allocator, .{ .@"error" = "name must be a string or null" }),
            });
        },
        .parent_id = optionalString(obj, "parent_id") catch {
            return res.jsonResponse(.{
                .status_code = 400,
                .data = try http_response.makeErrorResponse(allocator, .{ .@"error" = "parent_id must be a string or null" }),
            });
        },
        .move_parent = obj.get("parent_id") != null,
    };

    const output = useCase(allocator, sqlite_db, .{
        .workspace_id = req.params.get("workspace_id") orelse "",
        .folder_id = req.params.get("folder_id") orelse "",
        .body = body,
    }) catch |err| {
        const status: u16 = switch (err) {
            error.IdsRequired, error.NameRequired => 400,
            error.NotFound, error.NotFoundOrEmptyName, error.ParentNotFound => 404,
            error.CycleRefused, error.TooDeep => 409,
            error.UpdateFailed, error.QueryFailed, error.OutOfMemory => 500,
        };
        const message: []const u8 = switch (err) {
            error.IdsRequired => "workspace_id and folder_id required",
            error.NameRequired => "folder name is required",
            error.NotFound, error.NotFoundOrEmptyName => "folder not found in this workspace",
            error.ParentNotFound => "parent folder not found in this workspace",
            error.CycleRefused => "a folder cannot be moved inside itself",
            error.TooDeep => "folders nest at most 5 levels deep",
            error.UpdateFailed => "DB error",
            error.QueryFailed => "DB error",
            error.OutOfMemory => "Out of memory",
        };
        return res.jsonResponse(.{
            .status_code = status,
            .data = try http_response.makeErrorResponse(allocator, .{ .@"error" = message }),
        });
    };
    defer folders_store.freeFolderRow(allocator, output.folder);

    // Every window showing this workspace refetches; the payload only names
    // what moved, because the list read is the source of truth.
    document_events.emitDocumentsChanged(
        allocator,
        di.event_bus,
        output.folder.workspace_id,
        output.folder.id,
        output.folder.name,
    );

    const data = try std.json.Stringify.valueAlloc(allocator, .{
        .folder = http_response.makeFolderResponse(output.folder),
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
    try migration.Migration143AddDocumentContentKey.up(&db, testing.allocator);
    return .{ .db = db, .threaded = threaded };
}

test "useCase: renaming a folder keeps it where it was" {
    const alloc = testing.allocator;
    var ctx = try setupDb();
    defer ctx.threaded.deinit();
    defer ctx.db.deinit();

    const parent = try folders_store.createFolder(alloc, &ctx.db, .{ .workspace_id = "ws_1", .name = "Parent" });
    defer folders_store.freeFolderRow(alloc, parent);
    const child = try folders_store.createFolder(alloc, &ctx.db, .{ .workspace_id = "ws_1", .name = "Child", .parent_id = parent.id });
    defer folders_store.freeFolderRow(alloc, child);

    const output = try useCase(alloc, &ctx.db, .{
        .workspace_id = "ws_1",
        .folder_id = child.id,
        .body = .{ .name = "Renamed" },
    });
    defer folders_store.freeFolderRow(alloc, output.folder);

    try testing.expectEqualStrings("Renamed", output.folder.name);
    try testing.expect(output.folder.parent_id != null);
}

test "useCase: a move to the root clears the parent" {
    const alloc = testing.allocator;
    var ctx = try setupDb();
    defer ctx.threaded.deinit();
    defer ctx.db.deinit();

    const parent = try folders_store.createFolder(alloc, &ctx.db, .{ .workspace_id = "ws_1", .name = "Parent" });
    defer folders_store.freeFolderRow(alloc, parent);
    const child = try folders_store.createFolder(alloc, &ctx.db, .{ .workspace_id = "ws_1", .name = "Child", .parent_id = parent.id });
    defer folders_store.freeFolderRow(alloc, child);

    const output = try useCase(alloc, &ctx.db, .{
        .workspace_id = "ws_1",
        .folder_id = child.id,
        .body = .{ .move_parent = true },
    });
    defer folders_store.freeFolderRow(alloc, output.folder);

    try testing.expectEqual(@as(?[]const u8, null), output.folder.parent_id);
}

test "useCase: moving a folder inside its own child is refused" {
    const alloc = testing.allocator;
    var ctx = try setupDb();
    defer ctx.threaded.deinit();
    defer ctx.db.deinit();

    const root = try folders_store.createFolder(alloc, &ctx.db, .{ .workspace_id = "ws_1", .name = "Root" });
    defer folders_store.freeFolderRow(alloc, root);
    const child = try folders_store.createFolder(alloc, &ctx.db, .{ .workspace_id = "ws_1", .name = "Child", .parent_id = root.id });
    defer folders_store.freeFolderRow(alloc, child);

    try testing.expectError(
        error.CycleRefused,
        useCase(alloc, &ctx.db, .{
            .workspace_id = "ws_1",
            .folder_id = root.id,
            .body = .{ .parent_id = child.id, .move_parent = true },
        }),
    );
}

test "useCase: another workspace's folder is not found" {
    const alloc = testing.allocator;
    var ctx = try setupDb();
    defer ctx.threaded.deinit();
    defer ctx.db.deinit();

    const theirs = try folders_store.createFolder(alloc, &ctx.db, .{ .workspace_id = "ws_2", .name = "Theirs" });
    defer folders_store.freeFolderRow(alloc, theirs);

    try testing.expectError(
        error.NotFound,
        useCase(alloc, &ctx.db, .{
            .workspace_id = "ws_1",
            .folder_id = theirs.id,
            .body = .{ .name = "Hijacked" },
        }),
    );
}
