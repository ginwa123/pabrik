//! `pabrik headless documents …` — the document-folder backend with no server
//! and no port. Every op goes through the same store the HTTP handlers use;
//! stdout gets exactly one JSON object and nothing else.

const std = @import("std");
const pabrikcore = @import("pabrikcore");

const args = @import("args.zig");
const boot_mod = @import("boot.zig");
const handle_tool = @import("../modules/agent/loop/handle_tool.zig");

const folders_store = pabrikcore.document_folders_store;
const documents_store = pabrikcore.documents_store;
const documents_export = pabrikcore.documents_export;
const workspace_scope = pabrikcore.workspace_scope;
const agent = pabrikcore.agent;
const document_tool = pabrikcore.document_tool;

const FolderDto = struct {
    id: []const u8,
    parent_id: ?[]const u8,
    name: []const u8,
    position: i64,
};

const DocumentDto = struct {
    id: []const u8,
    title: []const u8,
    format: []const u8,
    folder_id: ?[]const u8,
    position: i64,
};

const ListDto = struct {
    workspace_id: []const u8,
    folders: []FolderDto,
    documents: []DocumentDto,
    folder_count: usize,
    document_count: usize,
};

/// What a `backfill` run did. `moved` counts bodies written to the object
/// store; a second run reports `moved = 0`, which is the idempotency check.
const BackfillDto = struct {
    scanned: usize,
    moved: usize,
    skipped_empty: usize,
    failed: usize,
    dry_run: bool,
};

/// A `search` result: the matching rows, no folder tree.
const SearchDto = struct {
    workspace_id: []const u8,
    documents: []DocumentDto,
    count: usize,
};

fn folderDto(row: folders_store.FolderRow) FolderDto {
    return .{ .id = row.id, .parent_id = row.parent_id, .name = row.name, .position = row.position };
}

fn documentDto(row: documents_store.DocumentRow) DocumentDto {
    return .{
        .id = row.id,
        .title = row.title,
        .format = row.format,
        .folder_id = row.folder_id,
        .position = row.position,
    };
}

fn listJson(
    allocator: std.mem.Allocator,
    store: documents_store.Store,
    workspace_id: []const u8,
) ![]u8 {
    const folders = try folders_store.listFolders(allocator, store.db, workspace_id);
    defer folders_store.freeFolderRows(allocator, folders);
    const documents = try store.listDocuments(allocator, workspace_id);
    defer documents_store.freeDocumentRows(allocator, documents);

    const folder_dtos = try allocator.alloc(FolderDto, folders.len);
    defer allocator.free(folder_dtos);
    for (folders, 0..) |f, i| folder_dtos[i] = folderDto(f);

    const document_dtos = try allocator.alloc(DocumentDto, documents.len);
    defer allocator.free(document_dtos);
    for (documents, 0..) |d, i| document_dtos[i] = documentDto(d);

    return std.json.Stringify.valueAlloc(allocator, ListDto{
        .workspace_id = workspace_id,
        .folders = folder_dtos,
        .documents = document_dtos,
        .folder_count = folders.len,
        .document_count = documents.len,
    }, .{});
}

fn folderJson(allocator: std.mem.Allocator, folder: folders_store.FolderRow) ![]u8 {
    return std.json.Stringify.valueAlloc(allocator, folderDto(folder), .{});
}

/// The `{workspace_id, documents, count}` envelope, without the folder tree.
/// `search` returns matches, not a level of the tree.
fn documentsJson(
    allocator: std.mem.Allocator,
    workspace_id: []const u8,
    documents: []const documents_store.DocumentRow,
) ![]u8 {
    const document_dtos = try allocator.alloc(DocumentDto, documents.len);
    defer allocator.free(document_dtos);
    for (documents, 0..) |d, i| document_dtos[i] = documentDto(d);

    return std.json.Stringify.valueAlloc(allocator, SearchDto{
        .workspace_id = workspace_id,
        .documents = document_dtos,
        .count = documents.len,
    }, .{});
}

fn documentJson(allocator: std.mem.Allocator, document: documents_store.DocumentRow) ![]u8 {
    return std.json.Stringify.valueAlloc(allocator, documentDto(document), .{});
}

/// Run one op and return the JSON object to print. Caller frees the slice.
pub fn run(
    allocator: std.mem.Allocator,
    backend: *boot_mod.Backend,
    a: args.DocumentsArgs,
) ![]u8 {
    switch (a.op) {
        .doc_add, .doc_edit, .doc_delete, .doc_search => return runToolOp(allocator, backend, a),
        .doc_get => return documentBodyJson(allocator, backend, a),
        else => {},
    }
    return runWithDb(allocator, backend.io, .{
        .db = backend.ctx.db,
        .storage = backend.ctx.objectStore(),
    }, a);
}

/// The tool call the model would have made, dispatched through the SAME path
/// the agent loop uses — hooks, registry, `dispatchFromRegistry`. That is what
/// makes this a proof of the agent tool and not just of the store.
fn runToolOp(
    allocator: std.mem.Allocator,
    backend: *boot_mod.Backend,
    a: args.DocumentsArgs,
) ![]u8 {
    const action: []const u8 = switch (a.op) {
        .doc_add => "create",
        .doc_edit => "edit",
        .doc_delete => "delete",
        .doc_search => "search",
        else => unreachable,
    };
    const arguments = switch (a.op) {
        .doc_add => try std.json.Stringify.valueAlloc(allocator, .{
            .action = action,
            .title = a.title,
            .content = a.content,
        }, .{}),
        .doc_edit => try std.json.Stringify.valueAlloc(allocator, .{
            .action = action,
            .document_id = a.document_id.?,
            .content = a.content,
        }, .{}),
        .doc_delete => try std.json.Stringify.valueAlloc(allocator, .{
            .action = action,
            .document_id = a.document_id.?,
        }, .{}),
        .doc_search => try std.json.Stringify.valueAlloc(allocator, .{
            .action = action,
            .query = a.query,
            .limit = if (a.limit == 0) null else @as(i64, @intCast(a.limit)),
        }, .{ .emit_null_optional_fields = false }),
        else => unreachable,
    };
    defer allocator.free(arguments);

    var temperature: f32 = 0;
    var thinking: bool = false;
    const ctx = handle_tool.ToolContext{
        .allocator = allocator,
        .io = backend.io,
        .db = backend.ctx.db,
        .logger = backend.logger,
        .session_id = a.session,
        .model = "",
        .cwd = "",
        .api_key = "",
        .base_url = "",
        .config = backend.llm_config_ptr,
        .agent_temperature = &temperature,
        .is_thinking = &thinking,
        .environment = backend.environment,
    };

    const output = try handle_tool.runToolDirect(ctx, .{
        .id = "headless_documents",
        .type = "function",
        .function = .{ .name = document_tool.TOOL_NAME, .arguments = arguments },
    });
    defer allocator.free(output);

    if (try envelopeSucceeded(output)) return allocator.dupe(u8, output);
    return error.ToolRefused;
}

/// True when the tool envelope reports `success: true`. A refusal is a
/// non-zero exit, never a JSON object a caller could mistake for a write.
fn envelopeSucceeded(envelope: []const u8) !bool {
    const Wire = struct { success: bool = false };
    const parsed = std.json.parseFromSlice(Wire, std.heap.page_allocator, envelope, .{
        .ignore_unknown_fields = true,
    }) catch return false;
    defer parsed.deinit();
    return parsed.value.success;
}

/// One document, body included, read back through the store the HTTP GET
/// handler uses.
fn documentBodyJson(
    allocator: std.mem.Allocator,
    backend: *boot_mod.Backend,
    a: args.DocumentsArgs,
) ![]u8 {
    const workspace_id = (try workspace_scope.resolveWorkspaceId(
        allocator,
        backend.ctx.db,
        a.session,
    )) orelse return error.WorkspaceNotResolved;
    defer allocator.free(workspace_id);

    const store = documents_store.Store{
        .db = backend.ctx.db,
        .storage = backend.ctx.objectStore(),
    };
    const row = try store.getDocument(allocator, workspace_id, a.document_id.?);
    defer documents_store.freeDocumentRow(allocator, row);

    return std.json.Stringify.valueAlloc(allocator, .{
        .id = row.id,
        .workspace_id = row.workspace_id,
        .title = row.title,
        .content = row.content,
        .content_key = row.content_key orelse "",
        .content_bytes = row.content_bytes,
        .format = row.format,
        .updated_at = row.updated_at,
    }, .{});
}

/// `export`: write the document — or a zip of `--documents` — to a file and
/// report where it landed. The bytes come from `documents_export`, the same
/// module the HTTP endpoints answer with, so a CLI export and a browser
/// download are the same file.
fn exportJson(
    allocator: std.mem.Allocator,
    io: std.Io,
    store: documents_store.Store,
    a: args.DocumentsArgs,
) ![]u8 {
    if (a.document_id) |document_id| {
        const file = try documents_export.exportOne(allocator, store, a.workspace_id, document_id);
        defer {
            allocator.free(file.name);
            allocator.free(file.bytes);
        }
        const path = try writeExport(allocator, io, a.out, file.name, file.bytes);
        defer allocator.free(path);
        return std.json.Stringify.valueAlloc(allocator, .{
            .path = path,
            .filename = file.name,
            .mime = file.mime,
            .bytes = file.bytes.len,
            .count = @as(usize, 1),
        }, .{});
    }

    const ids = try parseIdList(allocator, a.documents);
    defer allocator.free(ids);

    const archive = try documents_export.exportMany(allocator, store, a.workspace_id, ids);
    defer allocator.free(archive.bytes);
    const path = try writeExport(allocator, io, a.out, archive.name, archive.bytes);
    defer allocator.free(path);
    return std.json.Stringify.valueAlloc(allocator, .{
        .path = path,
        .filename = archive.name,
        .mime = archive.mime,
        .bytes = archive.bytes.len,
        .count = archive.count,
    }, .{});
}

/// The `--documents` value split into ids. Blank entries are dropped, so a
/// trailing comma is not an id and an empty value is an empty list.
fn parseIdList(allocator: std.mem.Allocator, raw: []const u8) ![]const []const u8 {
    var ids: std.ArrayList([]const u8) = .empty;
    errdefer ids.deinit(allocator);

    var it = std.mem.splitScalar(u8, raw, ',');
    while (it.next()) |part| {
        const id = std.mem.trim(u8, part, " \t");
        if (id.len == 0) continue;
        try ids.append(allocator, id);
    }
    return ids.toOwnedSlice(allocator);
}

/// Write `bytes` to `out`, or to `default_name` in the current directory when
/// the caller named no path. Returns the path actually written, owned by the
/// caller.
fn writeExport(
    allocator: std.mem.Allocator,
    io: std.Io,
    out: ?[]const u8,
    default_name: []const u8,
    bytes: []const u8,
) ![]u8 {
    const path = out orelse default_name;
    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = path, .data = bytes });
    return allocator.dupe(u8, path);
}

/// The op table, over a plain `*Db` so a test can drive it against an
/// in-memory database without booting a backend.
pub fn runWithDb(
    allocator: std.mem.Allocator,
    io: std.Io,
    store: documents_store.Store,
    a: args.DocumentsArgs,
) ![]u8 {
    switch (a.op) {
        .list => return listJson(allocator, store, a.workspace_id),

        // These need the process singleton (the tool dispatch resolves the
        // object store from it), so they only run through `run`.
        .doc_add, .doc_edit, .doc_delete, .doc_search, .doc_get => return error.RequiresBackend,

        .export_file => return exportJson(allocator, io, store, a),

        .search => {
            const rows = try store.searchDocuments(allocator, a.workspace_id, a.query);
            defer documents_store.freeDocumentRows(allocator, rows);
            return documentsJson(allocator, a.workspace_id, rows);
        },

        .folder_create => {
            const row = try folders_store.createFolder(allocator, store.db, .{
                .workspace_id = a.workspace_id,
                .name = a.name,
                .parent_id = a.parent_id,
            });
            defer folders_store.freeFolderRow(allocator, row);
            return folderJson(allocator, row);
        },

        .folder_rename => {
            const row = try folders_store.updateFolder(allocator, store.db, a.workspace_id, a.folder_id.?, .{
                .name = a.name,
            });
            defer folders_store.freeFolderRow(allocator, row);
            return folderJson(allocator, row);
        },

        .folder_move => {
            const row = try folders_store.updateFolder(allocator, store.db, a.workspace_id, a.folder_id.?, .{
                .parent_id = a.parent_id,
                .move_parent = true,
            });
            defer folders_store.freeFolderRow(allocator, row);
            return folderJson(allocator, row);
        },

        .folder_delete => {
            const kept = try folders_store.deleteFolder(allocator, store.db, a.workspace_id, a.folder_id.?);
            return std.json.Stringify.valueAlloc(allocator, .{
                .id = a.folder_id.?,
                .success = true,
                .reparented_documents = kept,
            }, .{});
        },

        .doc_create => {
            const row = try store.createDocument(allocator, .{
                .workspace_id = a.workspace_id,
                .title = a.title,
                .content = a.content,
                .format = a.format,
                .folder_id = a.folder_id orelse a.parent_id,
            });
            defer documents_store.freeDocumentRow(allocator, row);
            return documentJson(allocator, row);
        },

        .doc_move => {
            const row = try store.updateDocument(
                allocator,
                a.workspace_id,
                a.document_id.?,
                .{ .folder_id = a.folder_id orelse a.parent_id, .move_folder = true },
            );
            defer documents_store.freeDocumentRow(allocator, row);
            return documentJson(allocator, row);
        },

        .backfill => {
            const report = try store.backfill(allocator, .{
                .workspace_id = if (a.workspace_id.len == 0) null else a.workspace_id,
                .limit = a.limit,
                .dry_run = a.dry_run,
            });
            return std.json.Stringify.valueAlloc(allocator, BackfillDto{
                .scanned = report.scanned,
                .moved = report.moved,
                .skipped_empty = report.skipped_empty,
                .failed = report.failed,
                .dry_run = a.dry_run,
            }, .{});
        },
    }
}

// ─── Tests ──────────────────────────────────────────────────────────────

const testing = std.testing;
const test_db = pabrikcore.test_db;
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
    return .{ .db = db, .threaded = threaded };
}

test "headless documents: folder-create then list returns the folder and the moved document" {
    const alloc = testing.allocator;
    var ctx = try setupDb();
    defer ctx.threaded.deinit();
    defer ctx.db.deinit();

    const folder_json = try runWithDb(alloc, ctx.threaded.io(), .{ .db = &ctx.db }, .{
        .op = .folder_create,
        .workspace_id = "ws_1",
        .name = "Split bill",
    });
    defer alloc.free(folder_json);

    const parsed = try std.json.parseFromSlice(std.json.Value, alloc, folder_json, .{});
    defer parsed.deinit();
    const folder_id = parsed.value.object.get("id").?.string;

    const doc_json = try runWithDb(alloc, ctx.threaded.io(), .{ .db = &ctx.db }, .{
        .op = .doc_create,
        .workspace_id = "ws_1",
        .title = "POST split-bill",
        .folder_id = folder_id,
    });
    defer alloc.free(doc_json);

    const list_json = try runWithDb(alloc, ctx.threaded.io(), .{ .db = &ctx.db }, .{ .op = .list, .workspace_id = "ws_1" });
    defer alloc.free(list_json);

    const list = try std.json.parseFromSlice(std.json.Value, alloc, list_json, .{});
    defer list.deinit();
    const obj = list.value.object;
    try testing.expectEqual(@as(i64, 1), obj.get("folder_count").?.integer);
    try testing.expectEqual(@as(i64, 1), obj.get("document_count").?.integer);
    try testing.expectEqualStrings(folder_id, obj.get("documents").?.array.items[0].object.get("folder_id").?.string);
}

test "headless documents: doc-move with no folder puts the document back at the root" {
    const alloc = testing.allocator;
    var ctx = try setupDb();
    defer ctx.threaded.deinit();
    defer ctx.db.deinit();

    const folder = try folders_store.createFolder(alloc, &ctx.db, .{ .workspace_id = "ws_1", .name = "F" });
    defer folders_store.freeFolderRow(alloc, folder);
    const doc = try documents_store.createDocument(alloc, &ctx.db, .{
        .workspace_id = "ws_1",
        .title = "Doc",
        .folder_id = folder.id,
    });
    defer documents_store.freeDocumentRow(alloc, doc);

    const moved_json = try runWithDb(alloc, ctx.threaded.io(), .{ .db = &ctx.db }, .{
        .op = .doc_move,
        .workspace_id = "ws_1",
        .document_id = doc.id,
    });
    defer alloc.free(moved_json);

    const parsed = try std.json.parseFromSlice(std.json.Value, alloc, moved_json, .{});
    defer parsed.deinit();
    try testing.expect(parsed.value.object.get("folder_id").? == .null);
}

test "headless documents: search returns only the matching documents" {
    const alloc = testing.allocator;
    var ctx = try setupDb();
    defer ctx.threaded.deinit();
    defer ctx.db.deinit();

    try ctx.db.exec(alloc,
        \\INSERT INTO documents (id, workspace_id, title, preview)
        \\VALUES ('doc_hit', 'ws_1', 'Release plan', 'ship the zephyrword turbine'),
        \\       ('doc_miss', 'ws_1', 'Notes', 'nothing relevant')
    , &[_][]const u8{});

    const json = try runWithDb(alloc, ctx.threaded.io(), .{ .db = &ctx.db }, .{
        .op = .search,
        .workspace_id = "ws_1",
        .query = "zephyrword",
    });
    defer alloc.free(json);

    const parsed = try std.json.parseFromSlice(std.json.Value, alloc, json, .{});
    defer parsed.deinit();

    const obj = parsed.value.object;
    try testing.expectEqual(@as(i64, 1), obj.get("count").?.integer);
    try testing.expectEqualStrings("doc_hit", obj.get("documents").?.array.items[0].object.get("id").?.string);
}

test "parseIdList: a comma list becomes one id per entry, trimmed" {
    const alloc = testing.allocator;
    const ids = try parseIdList(alloc, "doc_a, doc_b ,doc_c");
    defer alloc.free(ids);

    try testing.expectEqual(@as(usize, 3), ids.len);
    try testing.expectEqualStrings("doc_a", ids[0]);
    try testing.expectEqualStrings("doc_b", ids[1]);
    try testing.expectEqualStrings("doc_c", ids[2]);
}

test "parseIdList: a trailing comma is not an id" {
    const alloc = testing.allocator;
    const ids = try parseIdList(alloc, "doc_a,");
    defer alloc.free(ids);

    try testing.expectEqual(@as(usize, 1), ids.len);
    try testing.expectEqualStrings("doc_a", ids[0]);
}

test "parseIdList: an empty value is an empty list, not one blank id" {
    const alloc = testing.allocator;
    const ids = try parseIdList(alloc, "");
    defer alloc.free(ids);

    try testing.expectEqual(@as(usize, 0), ids.len);
}
