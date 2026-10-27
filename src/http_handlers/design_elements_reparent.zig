//! `POST
//! /api/workspaces/:workspace_id/items/:item_id/design/pages/:page_id/elements/reparent-batch`.
//! Atomic N-element reparent.

const std = @import("std");
const pabrikcore = @import("pabrikcore");
const gserverz = pabrikcore.gserverz;
const http_response = @import("http_response.zig");
const design_model = @import("../agentic_loop/design_model.zig");

/// Request body shape.
const ReparentBatchBody = struct {
    element_ids: []const []const u8 = &.{},
    new_parent_id: ?[]const u8 = null,
    reposition: []const u8 = "",
};

/// Domain-level error set. The handler maps each variant to an
/// HTTP status code via two exhaustive switches below.
pub const DesignElementsReparentError = error{
    /// `:page_id` path param was missing or empty.
    PageIdRequired,
    /// `element_ids` was missing or empty.
    EmptyElementIds,
    /// `new_parent_id` was non-null but the target element doesn't
    /// exist, isn't on this page, or isn't a `group`/`frame`.
    BadNewParentId,
    /// One or more element_ids is missing from the DB.
    BadElementId,
    /// Any element_id is on a different page.
    CrossPageIds,
    /// The batch would close a cycle (atomic rejection — no writes).
    BadReparent,
    /// `design_model.reparentElements` returned `PageNotFound`.
    PageNotFound,
    /// `design_model.reparentElements` returned a DB error.
    DbError,
    /// `allocator.dupe` failed while building the output struct.
    OutOfMemory,
};

/// Translate the wire `reposition` string to the enum. Unknown
/// values silently map to `null` (no position recompute) for
/// forward compatibility.
fn repositionFromString(s: []const u8) ?design_model.RepositionMode {
    if (std.mem.eql(u8, s, "last_in_parent")) return .last_in_parent;
    return null;
}

/// Inputs to the reparent-batch use-case.
pub const ReparentBatchInput = struct {
    page_id: []const u8,
    element_ids: []const []const u8,
    /// null = top-level. The handler passes empty string or null;
    /// both map to "no parent".
    new_parent_id: ?[]const u8,
    reposition: ?design_model.RepositionMode,
};

/// Use case — thin wrapper over `design_model.reparentElements`
/// that maps the model's `anyerror` set to the handler's structured
/// `DesignElementsReparentError`.
pub fn useCase(
    allocator: std.mem.Allocator,
    db: *pabrikcore.database.Db,
    input: ReparentBatchInput,
) DesignElementsReparentError![]design_model.DesignElement {
    if (input.page_id.len == 0) return error.PageIdRequired;

    return design_model.reparentElements(allocator, db, .{
        .page_id = input.page_id,
        .element_ids = input.element_ids,
        .new_parent_id = input.new_parent_id,
        .reposition = input.reposition orelse .last_in_parent,
    }) catch |err| switch (err) {
        error.EmptyElementIds => return error.EmptyElementIds,
        error.BadElementId => return error.BadElementId,
        error.CrossPageIds => return error.CrossPageIds,
        error.CycleDetected => return error.BadReparent,
        error.BadNewParentId => return error.BadNewParentId,
        error.PageNotFound => return error.PageNotFound,
        else => return error.DbError,
    };
}

/// Thin orchestrator over `useCase`. Validates the HTTP request,
/// delegates, and maps the outcome to an HTTP response.
pub fn designElementsReparentBatchHandler(
    ctx: gserverz.HttpContext,
    req: gserverz.HttpRequest,
    res: gserverz.HttpResponse,
) !gserverz.HttpResponse {
    const allocator = ctx.allocator;

    const di = try pabrikcore.getSingleton();
    const sqlite_db = di.db;

    // 1. Validate path params + body presence.
    const page_id = req.params.get("page_id") orelse "";
    if (page_id.len == 0) {
        return res.jsonResponse(.{
            .status_code = 400,
            .data = try http_response.makeErrorResponse(allocator, .{ .@"error" = "page_id required" }),
        });
    }

    if (req.body.len == 0) {
        return res.jsonResponse(.{
            .status_code = 400,
            .data = try http_response.makeErrorResponse(allocator, .{ .@"error" = "Request body required" }),
        });
    }

    const parsed = std.json.parseFromSliceLeaky(ReparentBatchBody, allocator, req.body, .{}) catch {
        return res.jsonResponse(.{
            .status_code = 400,
            .data = try http_response.makeErrorResponse(allocator, .{ .@"error" = "Invalid JSON body" }),
        });
    };

    // Translate wire `new_parent_id: null` AND `""` to null
    // (SQL COALESCE convention: empty string IS top-level).
    const new_parent_id: ?[]const u8 = if (parsed.new_parent_id) |p|
        if (p.len == 0) null else p
    else
        null;

    // 2. Delegate to the use-case.
    const updated = useCase(allocator, sqlite_db, .{
        .page_id = page_id,
        .element_ids = parsed.element_ids,
        .new_parent_id = new_parent_id,
        .reposition = repositionFromString(parsed.reposition),
    }) catch |err| {
        const status: u16 = switch (err) {
            error.PageIdRequired => 400,
            error.EmptyElementIds => 400,
            error.BadElementId => 400,
            error.BadNewParentId => 400,
            error.BadReparent => 400,
            error.CrossPageIds => 409,
            error.PageNotFound => 404,
            error.DbError => 500,
            error.OutOfMemory => 500,
        };
        const message: []const u8 = switch (err) {
            error.PageIdRequired => "page_id required",
            error.EmptyElementIds => "element_ids must be non-empty",
            error.BadElementId => "One or more element_ids is invalid",
            error.BadNewParentId => "new_parent_id must reference an existing group or frame on this page",
            error.BadReparent => "Reparenting would create a cycle",
            error.CrossPageIds => "All element_ids must be on the same page",
            error.PageNotFound => "Page not found",
            error.DbError => "Failed to reparent elements",
            error.OutOfMemory => "Out of memory",
        };
        return res.jsonResponse(.{
            .status_code = status,
            .data = try http_response.makeErrorResponse(allocator, .{ .@"error" = message }),
        });
    };

    // 3. Free the useCase's heap-owned element slices.
    defer {
        for (updated) |e| design_model.freeElement(allocator, e);
        allocator.free(updated);
    }

    // 4. Build the success response (200 OK with { updated: [...] }).
    const mapped = try allocator.alloc(http_response.DesignElementResponse, updated.len);
    defer allocator.free(mapped);
    for (updated, 0..) |e, i| mapped[i] = http_response.makeDesignElementResponse(e);

    const Response = struct {
        updated: []const http_response.DesignElementResponse,
    };

    return res.jsonResponse(.{
        .status_code = 200,
        .data = try std.json.Stringify.valueAlloc(
            allocator,
            Response{ .updated = mapped },
            .{},
        ),
    });
}

// ─── Behavioural tests for `useCase` (Chunk 1b Tasks 1b.2 + 1b.3) ─────────
// Pulled in from design_elements_reparent_test.zig — one-file-per-impl
// convention.

const testing_reparent_handler = std.testing;
const sqlite_reparent_handler = pabrikcore.sqlite;
const database = pabrikcore.database;

fn setupReparentHandlerDbAndItem() !struct {
    db: database.Db,
    threaded: std.Io.Threaded,
    item_id: []const u8,
    item_path: []u8,
    page_id: []u8,
} {
    const alloc = testing_reparent_handler.allocator;
    var threaded = std.Io.Threaded.init(alloc, .{});
    errdefer threaded.deinit();
    const io = threaded.io();

    var db: database.Db = .{};
    errdefer db.deinit();
    try db.init(io, ":memory:");

    try db.exec(alloc,
        \\CREATE TABLE workspace_items (
        \\    id TEXT PRIMARY KEY, workspace_id TEXT NOT NULL,
        \\    item_type TEXT NOT NULL, name TEXT, path TEXT,
        \\    position INTEGER NOT NULL DEFAULT 0,
        \\    created_at DATETIME, updated_at DATETIME)
    , &.{});

    try db.exec(alloc,
        \\CREATE TABLE workspace_item_tasks (
        \\    id TEXT PRIMARY KEY, name TEXT NOT NULL,
        \\    workspace_item_id TEXT NOT NULL,
        \\    task_type TEXT NOT NULL DEFAULT 'standard',
        \\    description TEXT NOT NULL DEFAULT '')
    , &.{});

    try db.exec(alloc,
        \\CREATE TABLE design_pages (
        \\    id TEXT PRIMARY KEY,
        \\    workspace_item_id TEXT NOT NULL,
        \\    name TEXT NOT NULL DEFAULT '',
        \\    workspace_item_task_id TEXT,
        \\    width INTEGER NOT NULL DEFAULT 1440,
        \\    height INTEGER NOT NULL DEFAULT 1024,
        \\    x INTEGER NOT NULL DEFAULT 0,
        \\    y INTEGER NOT NULL DEFAULT 0,
        \\    position INTEGER NOT NULL DEFAULT 0,
        \\    created_at DATETIME,
        \\    updated_at DATETIME,
        \\    UNIQUE (workspace_item_id, name),
        \\    FOREIGN KEY (workspace_item_id) REFERENCES workspace_items(id) ON DELETE CASCADE)
    , &.{});

    try db.exec(alloc,
        \\CREATE TABLE design_page_elements (
        \\    id TEXT PRIMARY KEY, page_id TEXT NOT NULL, name TEXT NOT NULL DEFAULT '',
        \\    file_path TEXT NOT NULL DEFAULT '',
        \\    x INTEGER NOT NULL DEFAULT 0, y INTEGER NOT NULL DEFAULT 0,
        \\    width INTEGER NOT NULL DEFAULT 375, height INTEGER NOT NULL DEFAULT 667,
        \\    z_index INTEGER NOT NULL DEFAULT 0, position INTEGER NOT NULL DEFAULT 0,
        \\    type TEXT NOT NULL DEFAULT 'rectangle', rotation REAL NOT NULL DEFAULT 0,
        \\    fill TEXT NOT NULL DEFAULT '', stroke TEXT NOT NULL DEFAULT '',
        \\    stroke_width INTEGER NOT NULL DEFAULT 0,
        \\    corner_radius INTEGER NOT NULL DEFAULT 0, opacity REAL NOT NULL DEFAULT 1.0,
        \\    text_content TEXT NOT NULL DEFAULT '', text_style TEXT NOT NULL DEFAULT '',
        \\    image_url TEXT NOT NULL DEFAULT '', parent_id TEXT,
        \\    created_at DATETIME, updated_at DATETIME,
        \\    FOREIGN KEY (page_id) REFERENCES design_pages(id) ON DELETE CASCADE)
    , &.{});

    var tmp = testing_reparent_handler.tmpDir(.{});
    var tmpdir_buf: [std.fs.max_path_bytes]u8 = undefined;
    const tmpdir_len = try tmp.dir.realPath(testing_reparent_handler.io, &tmpdir_buf);
    const tmpdir_path = try testing_reparent_handler.allocator.dupe(u8, tmpdir_buf[0..tmpdir_len]);

    const item_id_const = "item_design_reparent_batch_handler";
    try db.exec(alloc,
        "INSERT INTO workspace_items (id, workspace_id, item_type, path) " ++
        "VALUES (?, 'ws_test', 'design', ?)",
        &.{ item_id_const, tmpdir_path });

    const item_id_slice = try alloc.dupe(u8, item_id_const);

    const page_id_alloc = try design_model.setDesignPage(alloc, &db, .{
        .item_id = item_id_slice,
        .page_name = "Login",
        .width = 1440,
        .height = 1024,
    });

    return .{
        .db = db,
        .threaded = threaded,
        .item_id = item_id_slice,
        .item_path = tmpdir_path,
        .page_id = page_id_alloc,
    };
}

fn teardownReparentHandlerDb(db: *database.Db, threaded: *std.Io.Threaded) void {
    db.deinit();
    threaded.deinit();
}

test "useCase reparent 3 elements into a group and returns updated rows in input order" {
    const alloc = testing_reparent_handler.allocator;
    var ctx = try setupReparentHandlerDbAndItem();
    defer teardownReparentHandlerDb(&ctx.db, &ctx.threaded);
    defer alloc.free(ctx.item_id);
    defer alloc.free(ctx.item_path);
    defer alloc.free(ctx.page_id);

    const group_id = try design_model.addElement(alloc, &ctx.db, ctx.threaded.io(), .{
        .page_id = ctx.page_id,
        .name = "group",
        .elem_type = .frame,
        .html = "<div></div>",
        .x = 100, .y = 200, .width = 400, .height = 300,
        .fill = "#ffffff", .rotation = 0.0, .corner_radius = 0, .opacity = 1.0,
    });
    defer alloc.free(group_id);

    const a_id = try design_model.addElement(alloc, &ctx.db, ctx.threaded.io(), .{
        .page_id = ctx.page_id,
        .name = "a",
        .elem_type = .rectangle,
        .html = "<div></div>",
        .x = 110, .y = 220, .width = 80, .height = 30,
        .fill = "#000000", .rotation = 0.0, .corner_radius = 0, .opacity = 1.0,
    });
    defer alloc.free(a_id);
    const b_id = try design_model.addElement(alloc, &ctx.db, ctx.threaded.io(), .{
        .page_id = ctx.page_id,
        .name = "b",
        .elem_type = .rectangle,
        .html = "<div></div>",
        .x = 200, .y = 220, .width = 80, .height = 30,
        .fill = "#000000", .rotation = 0.0, .corner_radius = 0, .opacity = 1.0,
    });
    defer alloc.free(b_id);
    const c_id = try design_model.addElement(alloc, &ctx.db, ctx.threaded.io(), .{
        .page_id = ctx.page_id,
        .name = "c",
        .elem_type = .rectangle,
        .html = "<div></div>",
        .x = 300, .y = 220, .width = 80, .height = 30,
        .fill = "#000000", .rotation = 0.0, .corner_radius = 0, .opacity = 1.0,
    });
    defer alloc.free(c_id);

    const ids = [_][]const u8{ a_id, b_id, c_id };
    const updated = try useCase(alloc, &ctx.db, .{
        .page_id = ctx.page_id,
        .element_ids = &ids,
        .new_parent_id = group_id,
        .reposition = .last_in_parent,
    });
    defer {
        for (updated) |e| design_model.freeElement(alloc, e);
        alloc.free(updated);
    }

    try testing_reparent_handler.expectEqual(@as(usize, 3), updated.len);
    try testing_reparent_handler.expectEqualStrings(a_id, updated[0].id);
    try testing_reparent_handler.expectEqualStrings(b_id, updated[1].id);
    try testing_reparent_handler.expectEqualStrings(c_id, updated[2].id);
}

test "useCase returns BadReparent when the batch contains a cycle" {
    const alloc = testing_reparent_handler.allocator;
    var ctx = try setupReparentHandlerDbAndItem();
    defer teardownReparentHandlerDb(&ctx.db, &ctx.threaded);
    defer alloc.free(ctx.item_id);
    defer alloc.free(ctx.item_path);
    defer alloc.free(ctx.page_id);

    try ctx.db.exec(alloc,
        \\INSERT INTO design_page_elements
        \\   (id, page_id, name, file_path, x, y, width, height, z_index, position,
        \\    type, rotation, fill, stroke, stroke_width, corner_radius, opacity,
        \\    text_content, text_style, image_url, parent_id,
        \\    created_at, updated_at)
        \\VALUES
        \\   ('g_a', ?, 'a', '', 0, 0, 100, 100, 0, 0,
        \\    'frame', 0.0, '', '', 0, 0, 1.0,
        \\    '', '', '', NULL, datetime('now'), datetime('now')),
        \\   ('g_b', ?, 'b', '', 0, 0, 100, 100, 0, 0,
        \\    'frame', 0.0, '', '', 0, 0, 1.0,
        \\    '', '', '', 'g_a', datetime('now'), datetime('now')),
        \\   ('g_c', ?, 'c', '', 0, 0, 100, 100, 0, 0,
        \\    'frame', 0.0, '', '', 0, 0, 1.0,
        \\    '', '', '', 'g_b', datetime('now'), datetime('now'))
    , &.{ctx.page_id, ctx.page_id, ctx.page_id});

    const ids = [_][]const u8{ "g_c", "g_a" };
    const result = useCase(alloc, &ctx.db, .{
        .page_id = ctx.page_id,
        .element_ids = &ids,
        .new_parent_id = "g_b",
        .reposition = .last_in_parent,
    });
    try testing_reparent_handler.expectError(error.BadReparent, result);
}

test "useCase returns EmptyElementIds for empty input" {
    const alloc = testing_reparent_handler.allocator;
    var ctx = try setupReparentHandlerDbAndItem();
    defer teardownReparentHandlerDb(&ctx.db, &ctx.threaded);
    defer alloc.free(ctx.item_id);
    defer alloc.free(ctx.item_path);
    defer alloc.free(ctx.page_id);

    const ids = [_][]const u8{};
    const result = useCase(alloc, &ctx.db, .{
        .page_id = ctx.page_id,
        .element_ids = &ids,
        .new_parent_id = null,
        .reposition = .last_in_parent,
    });
    try testing_reparent_handler.expectError(error.EmptyElementIds, result);
}

test "useCase returns CrossPageIds when any element is on a different page" {
    const alloc = testing_reparent_handler.allocator;
    var ctx = try setupReparentHandlerDbAndItem();
    defer teardownReparentHandlerDb(&ctx.db, &ctx.threaded);
    defer alloc.free(ctx.item_id);
    defer alloc.free(ctx.item_path);
    defer alloc.free(ctx.page_id);

    const page2_id = try design_model.setDesignPage(alloc, &ctx.db, .{
        .item_id = ctx.item_id,
        .page_name = "Second",
        .width = 1440,
        .height = 1024,
    });
    defer alloc.free(page2_id);

    const leaf1 = try design_model.addElement(alloc, &ctx.db, ctx.threaded.io(), .{
        .page_id = ctx.page_id,
        .name = "leaf1",
        .elem_type = .rectangle,
        .html = "<div></div>",
        .x = 0, .y = 0, .width = 50, .height = 50,
        .fill = "#000000", .rotation = 0.0, .corner_radius = 0, .opacity = 1.0,
    });
    defer alloc.free(leaf1);

    const leaf2 = try design_model.addElement(alloc, &ctx.db, ctx.threaded.io(), .{
        .page_id = page2_id,
        .name = "leaf2",
        .elem_type = .rectangle,
        .html = "<div></div>",
        .x = 0, .y = 0, .width = 50, .height = 50,
        .fill = "#000000", .rotation = 0.0, .corner_radius = 0, .opacity = 1.0,
    });
    defer alloc.free(leaf2);

    const group = try design_model.addElement(alloc, &ctx.db, ctx.threaded.io(), .{
        .page_id = ctx.page_id,
        .name = "group",
        .elem_type = .frame,
        .html = "<div></div>",
        .x = 100, .y = 100, .width = 100, .height = 100,
        .fill = "#ffffff", .rotation = 0.0, .corner_radius = 0, .opacity = 1.0,
    });
    defer alloc.free(group);

    const ids = [_][]const u8{ leaf1, leaf2 };
    const result = useCase(alloc, &ctx.db, .{
        .page_id = ctx.page_id,
        .element_ids = &ids,
        .new_parent_id = group,
        .reposition = .last_in_parent,
    });
    try testing_reparent_handler.expectError(error.CrossPageIds, result);
}

test "useCase returns BadNewParentId when the new parent is a leaf" {
    const alloc = testing_reparent_handler.allocator;
    var ctx = try setupReparentHandlerDbAndItem();
    defer teardownReparentHandlerDb(&ctx.db, &ctx.threaded);
    defer alloc.free(ctx.item_id);
    defer alloc.free(ctx.item_path);
    defer alloc.free(ctx.page_id);

    const a = try design_model.addElement(alloc, &ctx.db, ctx.threaded.io(), .{
        .page_id = ctx.page_id,
        .name = "a",
        .elem_type = .rectangle,
        .html = "<div></div>",
        .x = 0, .y = 0, .width = 50, .height = 50,
        .fill = "#000000", .rotation = 0.0, .corner_radius = 0, .opacity = 1.0,
    });
    defer alloc.free(a);
    const b = try design_model.addElement(alloc, &ctx.db, ctx.threaded.io(), .{
        .page_id = ctx.page_id,
        .name = "b",
        .elem_type = .rectangle,
        .html = "<div></div>",
        .x = 60, .y = 0, .width = 50, .height = 50,
        .fill = "#000000", .rotation = 0.0, .corner_radius = 0, .opacity = 1.0,
    });
    defer alloc.free(b);

    const ids = [_][]const u8{ a, b };
    const result = useCase(alloc, &ctx.db, .{
        .page_id = ctx.page_id,
        .element_ids = &ids,
        .new_parent_id = a,
        .reposition = .last_in_parent,
    });
    try testing_reparent_handler.expectError(error.BadNewParentId, result);
}

test "useCase returns PageNotFound when the page does not exist" {
    const alloc = testing_reparent_handler.allocator;
    var ctx = try setupReparentHandlerDbAndItem();
    defer teardownReparentHandlerDb(&ctx.db, &ctx.threaded);
    defer alloc.free(ctx.item_id);
    defer alloc.free(ctx.item_path);
    defer alloc.free(ctx.page_id);

    const ids = [_][]const u8{"elem_x"};
    const result = useCase(alloc, &ctx.db, .{
        .page_id = "page_nonexistent",
        .element_ids = &ids,
        .new_parent_id = null,
        .reposition = .last_in_parent,
    });
    try testing_reparent_handler.expectError(error.PageNotFound, result);
}

test "useCase returns BadElementId when an element id does not exist" {
    const alloc = testing_reparent_handler.allocator;
    var ctx = try setupReparentHandlerDbAndItem();
    defer teardownReparentHandlerDb(&ctx.db, &ctx.threaded);
    defer alloc.free(ctx.item_id);
    defer alloc.free(ctx.item_path);
    defer alloc.free(ctx.page_id);

    const a = try design_model.addElement(alloc, &ctx.db, ctx.threaded.io(), .{
        .page_id = ctx.page_id,
        .name = "a",
        .elem_type = .rectangle,
        .html = "<div></div>",
        .x = 0, .y = 0, .width = 50, .height = 50,
        .fill = "#000000", .rotation = 0.0, .corner_radius = 0, .opacity = 1.0,
    });
    defer alloc.free(a);

    const ids = [_][]const u8{ a, "elem_nonexistent" };
    const result = useCase(alloc, &ctx.db, .{
        .page_id = ctx.page_id,
        .element_ids = &ids,
        .new_parent_id = null,
        .reposition = .last_in_parent,
    });
    try testing_reparent_handler.expectError(error.BadElementId, result);
}