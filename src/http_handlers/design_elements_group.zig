//! `POST
//! /api/workspaces/:workspace_id/items/:item_id/design/pages/:page_id/elements/group`.

const std = @import("std");
const pabrikcore = @import("pabrikcore");
const gserverz = pabrikcore.gserverz;
const http_response = @import("http_response.zig");
const design_model = @import("../agentic_loop/design_model.zig");

/// HTTP request body for the group-elements endpoint. `child_ids` must
/// contain at least 2 element ids (a single-element group is not meaningful).
const GroupElementsBody = struct {
    child_ids: []const []const u8 = &.{},
    name: ?[]const u8 = null,
    type: ?[]const u8 = null,
};

/// Domain-level error set for `useCase`. The handler maps each
/// variant to an HTTP status code + message via two exhaustive
/// switches (one for status, one for the user-facing message).
pub const DesignElementsGroupError = error{
    /// `:page_id` path param was missing or empty.
    PageIdRequired,
    /// `child_ids.len < 2` — single-element group is not useful.
    TooFewChildren,
    /// `name` was empty (after default fallback).
    BadName,
    /// `type` field was not a valid `ElementType` enum variant.
    InvalidType,
    /// `design_model.groupElements` returned `PageNotFound`.
    PageNotFound,
    /// `design_model.groupElements` returned `BadChildId` (a child
    /// id didn't resolve to a row).
    BadChildId,
    /// `design_model.groupElements` returned `ItemPathMissing`.
    ItemPathMissing,
    /// `design_model.groupElements` returned
    /// `ChildAcrossDifferentPages`.
    ChildAcrossDifferentPages,
    /// `design_model.groupElements` returned `ChildAlreadyParented`.
    ChildAlreadyParented,
    /// `design_model.groupElements` returned `FileWriteFailed`
    /// (atomic-write of the group HTML failed).
    FileWriteFailed,
    /// `groupElements` failed for some other DB reason.
    DbError,
    /// Insert succeeded but the new element wasn't visible in the
    /// subsequent `getElement` (consistency violation).
    ParentNotVisible,
    /// `allocator.dupe` failed while building the output struct.
    OutOfMemory,
};

/// Inputs to the group-elements use-case.
pub const GroupElementsInput = struct {
    page_id: []const u8,
    workspace_id: []const u8,
    child_ids: []const []const u8,
    name: []const u8,
    elem_type: design_model.ElementType,
};

/// Output of the group-elements use-case.
pub const GroupElementsOutput = struct {
    /// The newly-created parent element.
    parent: design_model.DesignElement,
    /// The re-fetched children (post-reparent). Heap-owned by the
    /// use-case — `freeElement(allocator, ...)` per child on cleanup.
    children: []design_model.DesignElement,
};

// =====================================================================
// Use case
// =====================================================================

/// Group 2+ elements into a new parent.
pub fn useCase(
    allocator: std.mem.Allocator,
    db: *pabrikcore.database.Db,
    input: GroupElementsInput,
) DesignElementsGroupError!GroupElementsOutput {
    if (input.page_id.len == 0) return error.PageIdRequired;
    if (input.name.len == 0) return error.BadName;

    // Figma convention: a single-element group is not meaningful.
    if (input.child_ids.len < 2) return error.TooFewChildren;

    // Delegate to the model. The model owns the transaction + on-disk
    // HTML + SSE emit; we just translate the error set.
    const new_id = design_model.groupElements(allocator, db, .{
        .page_id = input.page_id,
        .child_ids = input.child_ids,
        .parent_name = input.name,
        .parent_type = input.elem_type,
    }) catch |err| switch (err) {
        error.PageNotFound => return error.PageNotFound,
        error.BadChildId => return error.BadChildId,
        error.ItemPathMissing => return error.ItemPathMissing,
        error.ChildAcrossDifferentPages => return error.ChildAcrossDifferentPages,
        error.ChildAlreadyParented => return error.ChildAlreadyParented,
        error.FileWriteFailed => return error.FileWriteFailed,
        else => return error.DbError,
    };
    defer allocator.free(new_id);

    // Re-fetch the new parent + each reparented child for the
    // response. Free-then-build (errdefer) pattern: if any
    // `getElement` fails, free the parts we already have.
    const parent = design_model.getElement(allocator, db, new_id) catch return error.ParentNotVisible;
    errdefer design_model.freeElement(allocator, parent);

    // Build the children array via repeated getElement calls.
    var children: std.ArrayList(design_model.DesignElement) = .empty;
    errdefer {
        for (children.items) |c| design_model.freeElement(allocator, c);
        children.deinit(allocator);
    }
    for (input.child_ids) |cid| {
        const child = design_model.getElement(allocator, db, cid) catch return error.DbError;
        try children.append(allocator, child);
    }

    return .{
        .parent = parent,
        .children = try children.toOwnedSlice(allocator),
    };
}

// =====================================================================
// Handler
// =====================================================================

/// Thin orchestrator over `useCase`. Validates the HTTP request,
/// resolves the singleton DB handle, delegates to `useCase`, and
/// maps the use-case outcome to an HTTP response.
pub fn designElementsGroupHandler(
    ctx: gserverz.HttpContext,
    req: gserverz.HttpRequest,
    res: gserverz.HttpResponse,
) !gserverz.HttpResponse {
    const allocator = ctx.allocator;

    const di = try pabrikcore.getSingleton();
    const sqlite_db = di.db;

    // 1. Validate path params + body presence + JSON shape.
    const page_id = req.params.get("page_id") orelse "";
    if (page_id.len == 0) {
        return res.jsonResponse(.{
            .status_code = 400,
            .data = try http_response.makeErrorResponse(allocator, .{ .@"error" = "page_id required" }),
        });
    }

    const ws_id = req.params.get("workspace_id") orelse "";

    if (req.body.len == 0) {
        return res.jsonResponse(.{
            .status_code = 400,
            .data = try http_response.makeErrorResponse(allocator, .{ .@"error" = "Request body required" }),
        });
    }

    const parsed = std.json.parseFromSliceLeaky(GroupElementsBody, allocator, req.body, .{}) catch {
        return res.jsonResponse(.{
            .status_code = 400,
            .data = try http_response.makeErrorResponse(allocator, .{ .@"error" = "Invalid JSON body" }),
        });
    };

    // 2. Validate child_ids length (Figma convention: 2+ required).
    if (parsed.child_ids.len < 2) {
        return res.jsonResponse(.{
            .status_code = 400,
            .data = try http_response.makeErrorResponse(allocator, .{
                .@"error" = "Select at least 2 elements to group",
            }),
        });
    }

    // 3. Apply defaults (Figma convention: "Group" + non-clipping).
    const name = parsed.name orelse "Group";
    const type_str = parsed.type orelse "group";

    // 4. Translate the wire `type` string to the ElementType enum.
    //    `std.meta.stringToEnum` returns `?T` — null on no match.
    const elem_type = std.meta.stringToEnum(design_model.ElementType, type_str) orelse {
        return res.jsonResponse(.{
            .status_code = 400,
            .data = try http_response.makeErrorResponse(allocator, .{
                .@"error" = "type must be one of: group, frame",
            }),
        });
    };
    // Reject .rectangle / .ellipse / .text / .image — the `/group`
    // endpoint is specifically for parent containers.
    if (elem_type != .group and elem_type != .frame) {
        return res.jsonResponse(.{
            .status_code = 400,
            .data = try http_response.makeErrorResponse(allocator, .{
                .@"error" = "type must be one of: group, frame",
            }),
        });
    }

    // 5. Delegate to the use-case.
    const output = useCase(allocator, sqlite_db, .{
        .page_id = page_id,
        .workspace_id = ws_id,
        .child_ids = parsed.child_ids,
        .name = name,
        .elem_type = elem_type,
    }) catch |err| {
        const status: u16 = switch (err) {
            error.PageIdRequired => 400,
            error.BadName => 400,
            error.TooFewChildren => 400,
            error.InvalidType => 400,
            error.BadChildId => 400,
            error.ChildAcrossDifferentPages => 400,
            error.ItemPathMissing => 400,
            error.PageNotFound => 404,
            error.ChildAlreadyParented => 409,
            error.FileWriteFailed => 500,
            error.DbError => 500,
            error.ParentNotVisible => 500,
            error.OutOfMemory => 500,
        };
        const message: []const u8 = switch (err) {
            error.PageIdRequired => "page_id required",
            error.BadName => "name is required",
            error.TooFewChildren => "Select at least 2 elements to group",
            error.InvalidType => "type must be one of: group, frame",
            error.BadChildId => "One or more child_ids is invalid",
            error.ChildAcrossDifferentPages => "All children must be on the same page",
            error.ItemPathMissing => "design item must have a path",
            error.PageNotFound => "Page not found",
            error.ChildAlreadyParented => "One or more children is already parented",
            error.FileWriteFailed => "Failed to write group HTML file",
            error.DbError => "Failed to group elements",
            error.ParentNotVisible => "Group was created but not visible",
            error.OutOfMemory => "Out of memory",
        };
        return res.jsonResponse(.{
            .status_code = status,
            .data = try http_response.makeErrorResponse(allocator, .{ .@"error" = message }),
        });
    };

    // Free the useCase's heap-owned slices (no-op on arena).
    defer {
        design_model.freeElement(allocator, output.parent);
        for (output.children) |c| design_model.freeElement(allocator, c);
        allocator.free(output.children);
    }

    // 6. Build the success response (201 Created) with
    //    `{parent, children}` envelope.
    const Response = struct {
        parent: http_response.DesignElementResponse,
        children: []const http_response.DesignElementResponse,
    };
    const mapped = try allocator.alloc(http_response.DesignElementResponse, output.children.len);
    defer allocator.free(mapped);
    for (output.children, 0..) |c, i| mapped[i] = http_response.makeDesignElementResponse(c);

    return res.jsonResponse(.{
        .status_code = 201,
        .data = try std.json.Stringify.valueAlloc(
            allocator,
            Response{
                .parent = http_response.makeDesignElementResponse(output.parent),
                .children = mapped,
            },
            .{},
        ),
    });
}

// ===== Tests merged from design_elements_group_test.zig (2026-09-11 flatten)
// ===== Behavioural unit tests for the `POST .../elements/group` HTTP handler
// (2026-07-28-grouped-layers Chunk 3).

const testing = std.testing;
const design_elements_group = @This();
const sqlite = pabrikcore.sqlite;
const database = pabrikcore.database;

// ─── Test fixtures (mirrors `design_model_group_test.zig`) ─────────────────

/// Open a fresh in-memory sqlite DB with the minimum tables needed for
/// the design SQL, plus a workspace_item with a tmpdir-backed path so
/// `design_model.groupElements` can write the new group's HTML file.
const TestCtx = struct {
    db: database.Db,
    threaded: std.Io.Threaded,
    item_id: []const u8,
    item_path: []u8,
};

fn setupDbAndItem() !TestCtx {
    const alloc = testing.allocator;
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

    var tmp = testing.tmpDir(.{});
    var tmpdir_buf: [std.fs.max_path_bytes]u8 = undefined;
    const tmpdir_len = try tmp.dir.realPath(testing.io, &tmpdir_buf);
    const tmpdir_path = try testing.allocator.dupe(u8, tmpdir_buf[0..tmpdir_len]);

    const item_id_const = "item_test";
    try db.exec(alloc,
        "INSERT INTO workspace_items (id, workspace_id, item_type, path) " ++
            "VALUES (?, 'ws_test', 'design', ?)",
        &.{ item_id_const, tmpdir_path });

    const item_id_slice = try alloc.dupe(u8, item_id_const);
    return .{
        .db = db,
        .threaded = threaded,
        .item_id = item_id_slice,
        .item_path = tmpdir_path,
    };
}

/// Insert one design element with explicit (x, y, width, height).
/// Returns the generated id (heap-owned; caller frees).
fn insertChild(
    alloc: std.mem.Allocator,
    db: *database.Db,
    page_id: []const u8,
    name: []const u8,
    x: i64,
    y: i64,
    w: i64,
    h: i64,
) ![]u8 {
    // db.exec binds only TEXT — stringify the integer columns.
    const x_str = try std.fmt.allocPrint(alloc, "{d}", .{x});
    defer alloc.free(x_str);
    const y_str = try std.fmt.allocPrint(alloc, "{d}", .{y});
    defer alloc.free(y_str);
    const w_str = try std.fmt.allocPrint(alloc, "{d}", .{w});
    defer alloc.free(w_str);
    const h_str = try std.fmt.allocPrint(alloc, "{d}", .{h});
    defer alloc.free(h_str);
    try db.exec(alloc,
        \\INSERT INTO design_page_elements
        \\   (id, page_id, name, file_path, x, y, width, height, z_index, position,
        \\    type, rotation, fill, stroke, stroke_width, corner_radius, opacity,
        \\    text_content, text_style, image_url, parent_id,
        \\    created_at, updated_at)
        \\VALUES
        \\   (?, ?, ?, '', ?, ?, ?, ?, 0, 0,
        \\    'rectangle', 0.0, '#ffffff', '', 0, 0, 1.0,
        \\    '', '', '', NULL, datetime('now'), datetime('now'))
    , &.{ name, page_id, name, x_str, y_str, w_str, h_str });
    return alloc.dupe(u8, name);
}

// ─── useCase validation: child_ids.length >= 2 ────────────────────────────

test "useCase rejects empty child_ids with TooFewChildren" {
    // The validation runs BEFORE any DB access, so we pass `undefined` for
    // the db pointer.
    const result = design_elements_group.useCase(testing.allocator, undefined, .{
        .page_id = "page_test",
        .workspace_id = "ws_test",
        .child_ids = &.{},
        .name = "My Group",
        .elem_type = .group,
    });
    try testing.expectError(error.TooFewChildren, result);
}

test "useCase rejects single-element child_ids with TooFewChildren" {
    const result = design_elements_group.useCase(testing.allocator, undefined, .{
        .page_id = "page_test",
        .workspace_id = "ws_test",
        .child_ids = &.{"elem_1"},
        .name = "My Group",
        .elem_type = .group,
    });
    try testing.expectError(error.TooFewChildren, result);
}

// ─── useCase delegation: success path (delegates to design_model) ──────────

test "useCase delegates to design_model.groupElements and returns parent + children" {
    const alloc = testing.allocator;
    var ctx = try setupDbAndItem();
    defer ctx.db.deinit();
    defer ctx.threaded.deinit();
    defer alloc.free(ctx.item_id);
    defer alloc.free(ctx.item_path);

    const page_id = try design_model.setDesignPage(alloc, &ctx.db, .{
        .item_id = ctx.item_id,
        .page_name = "Home",
        .width = 1440,
        .height = 1024,
    });
    defer alloc.free(page_id);

    const child_a = try insertChild(alloc, &ctx.db, page_id, "elem_a", 0, 0, 100, 50);
    defer alloc.free(child_a);
    const child_b = try insertChild(alloc, &ctx.db, page_id, "elem_b", 50, 100, 100, 50);
    defer alloc.free(child_b);

    const output = try design_elements_group.useCase(alloc, &ctx.db, .{
        .page_id = page_id,
        .workspace_id = "ws_test",
        .child_ids = &.{ child_a, child_b },
        .name = "My Group",
        .elem_type = .group,
    });
    defer {
        design_model.freeElement(alloc, output.parent);
        for (output.children) |c| design_model.freeElement(alloc, c);
        alloc.free(output.children);
    }

    // The parent is the new top-level group at the union bbox.
    try testing.expectEqualStrings("My Group", output.parent.name);
    try testing.expectEqualStrings("group", output.parent.elem_type);
    try testing.expectEqualStrings("", output.parent.parent_id); // top-level

    // Children are returned with parent_id set to the new parent's id.
    try testing.expectEqual(@as(usize, 2), output.children.len);
    for (output.children) |c| {
        try testing.expectEqualStrings(output.parent.id, c.parent_id);
    }
}

// ─── useCase error translation: PageNotFound → 404 at handler ─────────────

test "useCase returns PageNotFound when page_id does not exist" {
    const alloc = testing.allocator;
    var ctx = try setupDbAndItem();
    defer ctx.db.deinit();
    defer ctx.threaded.deinit();
    defer alloc.free(ctx.item_id);
    defer alloc.free(ctx.item_path);

    // No page seeded — the page_id is unknown.
    const result = design_elements_group.useCase(alloc, &ctx.db, .{
        .page_id = "page_does_not_exist",
        .workspace_id = "ws_test",
        .child_ids = &.{ "elem_a", "elem_b" },
        .name = "My Group",
        .elem_type = .group,
    });
    try testing.expectError(error.PageNotFound, result);
}

// ─── useCase error translation: BadChildId → 400 at handler ───────────────

test "useCase returns BadChildId when a child_id does not exist" {
    const alloc = testing.allocator;
    var ctx = try setupDbAndItem();
    defer ctx.db.deinit();
    defer ctx.threaded.deinit();
    defer alloc.free(ctx.item_id);
    defer alloc.free(ctx.item_path);

    const page_id = try design_model.setDesignPage(alloc, &ctx.db, .{
        .item_id = ctx.item_id,
        .page_name = "Home",
        .width = 1440,
        .height = 1024,
    });
    defer alloc.free(page_id);

    const child_a = try insertChild(alloc, &ctx.db, page_id, "elem_a", 0, 0, 100, 50);
    defer alloc.free(child_a);

    // elem_b does not exist; the model's SELECT returns 1 row but
    // input.child_ids.len == 2, triggering BadChildId.
    const result = design_elements_group.useCase(alloc, &ctx.db, .{
        .page_id = page_id,
        .workspace_id = "ws_test",
        .child_ids = &.{ child_a, "elem_b_does_not_exist" },
        .name = "My Group",
        .elem_type = .group,
    });
    try testing.expectError(error.BadChildId, result);
}

// ─── useCase error translation: ChildAlreadyParented → 409 at handler ──────

test "useCase returns ChildAlreadyParented when children already have a parent" {
    const alloc = testing.allocator;
    var ctx = try setupDbAndItem();
    defer ctx.db.deinit();
    defer ctx.threaded.deinit();
    defer alloc.free(ctx.item_id);
    defer alloc.free(ctx.item_path);

    const page_id = try design_model.setDesignPage(alloc, &ctx.db, .{
        .item_id = ctx.item_id,
        .page_name = "Home",
        .width = 1440,
        .height = 1024,
    });
    defer alloc.free(page_id);

    const child_a = try insertChild(alloc, &ctx.db, page_id, "elem_a", 0, 0, 100, 50);
    defer alloc.free(child_a);
    const child_b = try insertChild(alloc, &ctx.db, page_id, "elem_b", 50, 100, 100, 50);
    defer alloc.free(child_b);

    // First call: succeeds and reparents child_a + child_b.
    {
        const output = try design_elements_group.useCase(alloc, &ctx.db, .{
            .page_id = page_id,
            .workspace_id = "ws_test",
            .child_ids = &.{ child_a, child_b },
            .name = "First Group",
            .elem_type = .group,
        });
        design_model.freeElement(alloc, output.parent);
        for (output.children) |c| design_model.freeElement(alloc, c);
        alloc.free(output.children);
    }

    // Second call with the same children: model rejects because
    // both children already have a parent_id != NULL.
    const result = design_elements_group.useCase(alloc, &ctx.db, .{
        .page_id = page_id,
        .workspace_id = "ws_test",
        .child_ids = &.{ child_a, child_b },
        .name = "Second Group",
        .elem_type = .group,
    });
    try testing.expectError(error.ChildAlreadyParented, result);
}
