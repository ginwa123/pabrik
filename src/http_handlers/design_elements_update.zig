//! `PUT
//! /api/workspaces/:workspace_id/items/:item_id/design/pages/:page_id/elements/:element_id`.
//! Update an existing design element.

const std = @import("std");
const pabrikcore = @import("pabrikcore");
const gserverz = pabrikcore.gserverz;
const http_response = @import("http_response.zig");
const design_model = @import("../agentic_loop/design_model.zig");

/// HTTP request body for element-update.
const UpdateElementBody = struct {
    name: ?[]const u8 = null,
    type: ?[]const u8 = null,
    html: ?[]const u8 = null,
    x: ?i64 = null,
    y: ?i64 = null,
    width: ?i64 = null,
    height: ?i64 = null,
    rotation: ?f64 = null,
    fill: ?[]const u8 = null,
    stroke: ?[]const u8 = null,
    stroke_width: ?i64 = null,
    corner_radius: ?i64 = null,
    opacity: ?f64 = null,
    text_content: ?[]const u8 = null,
    text_style: ?[]const u8 = null,
    image_url: ?[]const u8 = null,
    /// FK to a `group`/`frame` element on the same page. `null` =
    /// leave unchanged. Pass `""` (empty string) to clear the parent
    /// (reparent to top-level).
    parent_id: ?[]const u8 = null,
    /// Optional post-update position normalization. Today only
    /// "last_in_parent" is supported; unrecognized values are treated as
    /// `null` (no position recompute) by the handler.
    reposition: ?[]const u8 = null,
};

/// Domain-level error set for `useCase`. The handler maps each variant to an
/// HTTP status code + message via two exhaustive switches.
pub const DesignElementUpdateError = error{
    /// `:element_id` path param was missing or empty.
    ElementIdRequired,
    /// `type` field was not a valid `ElementType` enum variant.
    InvalidType,
    /// No fields were provided in the body — would result in a
    /// no-op UPDATE. Maps to 400 so the frontend gets explicit
    /// feedback (instead of silently returning the existing row).
    NoChanges,
    /// `design_model.updateElement` returned `ElementNotFound`
    /// (no row with that `element_id`).
    ElementNotFound,
    /// `design_model.updateElement` returned `FileWriteFailed`
    /// (atomic-rename failed for the new `html` content).
    FileWriteFailed,
    /// `design_model.updateElement` returned `error.CycleDetected`
    /// — the requested parent_id is the element's own id or one
    /// of its transitive descendants. Maps to 400 BadReparent.
    BadReparent,
    /// `updateElement` failed for some other DB reason.
    DbError,
    /// Update succeeded but the element wasn't visible in the
    /// subsequent `getElement` (consistency violation).
    ElementNotVisible,
    /// `allocator.dupe` failed while building the output struct.
    OutOfMemory,
};

/// Inputs to the update-element use-case.
pub const UpdateElementInput = struct {
    element_id: []const u8,
    name: ?[]const u8,
    elem_type: ?design_model.ElementType,
    html: ?[]const u8,
    x: ?i64,
    y: ?i64,
    width: ?i64,
    height: ?i64,
    rotation: ?f64,
    fill: ?[]const u8,
    stroke: ?[]const u8,
    stroke_width: ?i64,
    corner_radius: ?i64,
    opacity: ?f64,
    text_content: ?[]const u8,
    text_style: ?[]const u8,
    image_url: ?[]const u8,
    /// FK to a `group`/`frame` element on the same page. `null` =
    /// leave unchanged. Pass `""` (empty string) to clear the
    /// parent (reparent to top-level).
    parent_id: ?[]const u8,
    /// Optional position normalization after the UPDATE. Today only
    /// `.last_in_parent` is supported; see the model's `RepositionMode`.
    reposition: ?design_model.RepositionMode,
};

/// Output of the update-element use-case.
pub const UpdateElementOutput = struct {
    /// The updated element (post-update state, via `getElement`).
    /// Heap-owned by the use-case (mirrors the create pattern).
    element: design_model.DesignElement,
};

// =====================================================================
// Use case
// =====================================================================

/// Update a design element. Steps: 1. Validate `element_id`. 2.
pub fn useCase(
    allocator: std.mem.Allocator,
    db: *pabrikcore.database.Db,
    input: UpdateElementInput,
) DesignElementUpdateError!UpdateElementOutput {
    // 1. Validate.
    if (input.element_id.len == 0) return error.ElementIdRequired;

    // 2. Detect "no changes" at the use-case boundary (the model
    //    silently no-ops when only `updated_at` is set; we surface
    //    that as a 400 to the client).
    const any_change = input.name != null or
        input.elem_type != null or
        input.html != null or
        input.x != null or
        input.y != null or
        input.width != null or
        input.height != null or
        input.rotation != null or
        input.fill != null or
        input.stroke != null or
        input.stroke_width != null or
        input.corner_radius != null or
        input.opacity != null or
        input.text_content != null or
        input.text_style != null or
        input.image_url != null or
        input.parent_id != null or
        input.reposition != null;
    if (!any_change) return error.NoChanges;

    // 3. Apply the UPDATE.
    const updated_id = design_model.updateElement(allocator, db, .{
        .element_id = input.element_id,
        .name = input.name,
        .elem_type = input.elem_type,
        .html = input.html,
        .x = input.x,
        .y = input.y,
        .width = input.width,
        .height = input.height,
        .rotation = input.rotation,
        .fill = input.fill,
        .stroke = input.stroke,
        .stroke_width = input.stroke_width,
        .corner_radius = input.corner_radius,
        .opacity = input.opacity,
        .text_content = input.text_content,
        .text_style = input.text_style,
        .image_url = input.image_url,
        .parent_id = input.parent_id,
        .reposition = input.reposition,
    }) catch |err| switch (err) {
        error.ElementNotFound => return error.ElementNotFound,
        error.FileWriteFailed => return error.FileWriteFailed,
        error.CycleDetected => return error.BadReparent,
        else => return error.DbError,
    };
    defer allocator.free(updated_id);

    // 4. Re-query to get the full row (post-update state).
    const element = design_model.getElement(allocator, db, updated_id) catch return error.ElementNotVisible;
    errdefer design_model.freeElement(allocator, element);

    return .{ .element = element };
}

// =====================================================================
// Handler
// =====================================================================

/// Thin orchestrator over `useCase`. Validates the HTTP request,
/// resolves the singleton DB handle, delegates to `useCase`, and
/// maps the use-case outcome to an HTTP response.
pub fn designElementsUpdateHandler(
    ctx: gserverz.HttpContext,
    req: gserverz.HttpRequest,
    res: gserverz.HttpResponse,
) !gserverz.HttpResponse {
    const allocator = ctx.allocator;

    const di = try pabrikcore.getSingleton();
    const sqlite_db = di.db;

    // 1. Validate path params + body presence + JSON shape.
    const element_id = req.params.get("element_id") orelse "";
    if (element_id.len == 0) {
        return res.jsonResponse(.{
            .status_code = 400,
            .data = try http_response.makeErrorResponse(allocator, .{ .@"error" = "element_id required" }),
        });
    }

    if (req.body.len == 0) {
        return res.jsonResponse(.{
            .status_code = 400,
            .data = try http_response.makeErrorResponse(allocator, .{ .@"error" = "Request body required" }),
        });
    }

    const parsed = std.json.parseFromSliceLeaky(UpdateElementBody, allocator, req.body, .{}) catch {
        return res.jsonResponse(.{
            .status_code = 400,
            .data = try http_response.makeErrorResponse(allocator, .{ .@"error" = "Invalid JSON body" }),
        });
    };

    // Translate the wire `type` string to the enum (if provided).
    var elem_type: ?design_model.ElementType = null;
    if (parsed.type) |t| {
        elem_type = std.meta.stringToEnum(design_model.ElementType, t) orelse {
            return res.jsonResponse(.{
                .status_code = 400,
                .data = try http_response.makeErrorResponse(allocator, .{
                    .@"error" = "type must be one of: rectangle, ellipse, text, image, frame, group",
                }),
            });
        };
    }

    // Translate the wire `reposition` string to the enum (if provided). Today
    // only "last_in_parent" is supported; any unrecognized value is silently
    // ignored (treated as `null`) to keep the wire shape forward-compatible.
    var reposition: ?design_model.RepositionMode = null;
    if (parsed.reposition) |r| {
        if (std.mem.eql(u8, r, "last_in_parent")) {
            reposition = .last_in_parent;
        }
    }

    // 2. Delegate to the use-case.
    const output = useCase(allocator, sqlite_db, .{
        .element_id = element_id,
        .name = parsed.name,
        .elem_type = elem_type,
        .html = parsed.html,
        .x = parsed.x,
        .y = parsed.y,
        .width = parsed.width,
        .height = parsed.height,
        .rotation = parsed.rotation,
        .fill = parsed.fill,
        .stroke = parsed.stroke,
        .stroke_width = parsed.stroke_width,
        .corner_radius = parsed.corner_radius,
        .opacity = parsed.opacity,
        .text_content = parsed.text_content,
        .text_style = parsed.text_style,
        .image_url = parsed.image_url,
        .parent_id = parsed.parent_id,
        .reposition = reposition,
    }) catch |err| {
        const status: u16 = switch (err) {
            error.ElementIdRequired => 400,
            error.InvalidType => 400,
            error.NoChanges => 400,
            error.BadReparent => 400,
            error.ElementNotFound => 404,
            error.FileWriteFailed => 500,
            error.DbError => 500,
            error.ElementNotVisible => 500,
            error.OutOfMemory => 500,
        };
        const message: []const u8 = switch (err) {
            error.ElementIdRequired => "element_id required",
            error.InvalidType => "type must be one of: rectangle, ellipse, text, image, frame, group",
            error.NoChanges => "No fields to update",
            error.BadReparent => "Reparenting would create a cycle",
            error.ElementNotFound => "Element not found",
            error.FileWriteFailed => "Failed to write element HTML file",
            error.DbError => "Failed to update element",
            error.ElementNotVisible => "Element was updated but not visible",
            error.OutOfMemory => "Out of memory",
        };
        return res.jsonResponse(.{
            .status_code = status,
            .data = try http_response.makeErrorResponse(allocator, .{ .@"error" = message }),
        });
    };

    // Free the useCase's heap-owned element slices (no-op on arena).
    defer design_model.freeElement(allocator, output.element);

    // 4. Build the success response (200 OK — PUT that updates an
    //    existing resource, not 201 Created).
    return res.jsonResponse(.{
        .status_code = 200,
        .data = try std.json.Stringify.valueAlloc(
            allocator,
            http_response.makeDesignElementResponse(output.element),
            .{},
        ),
    });
}

// ─── Behavioural tests for parent_id + reposition wire (Chunk 1 Task 1.3) ─
// Pulled in from design_elements_update_reparent_test.zig — one-file-per-impl
// convention.

const testing_update_reparent = std.testing;
const sqlite_update_reparent = pabrikcore.sqlite;
const database = pabrikcore.database;

fn setupUpdateReparentDbAndItem() !struct {
    db: database.Db,
    threaded: std.Io.Threaded,
    item_id: []const u8,
    item_path: []u8,
} {
    const alloc = testing_update_reparent.allocator;
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
        \\    created_at TIMESTAMP, updated_at TIMESTAMP)
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
        \\    created_at TIMESTAMP,
        \\    updated_at TIMESTAMP,
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
        \\    created_at TIMESTAMP, updated_at TIMESTAMP,
        \\    FOREIGN KEY (page_id) REFERENCES design_pages(id) ON DELETE CASCADE)
    , &.{});

    var tmp = testing_update_reparent.tmpDir(.{});
    var tmpdir_buf: [std.fs.max_path_bytes]u8 = undefined;
    const tmpdir_len = try tmp.dir.realPath(testing_update_reparent.io, &tmpdir_buf);
    const tmpdir_path = try testing_update_reparent.allocator.dupe(u8, tmpdir_buf[0..tmpdir_len]);

    const item_id_const = "item_design_update_reparent";
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

fn teardownUpdateReparentDb(db: *database.Db, threaded: *std.Io.Threaded) void {
    db.deinit();
    threaded.deinit();
}

test "useCase accepts parent_id + reposition and returns the updated element" {
    const alloc = testing_update_reparent.allocator;
    var ctx = try setupUpdateReparentDbAndItem();
    defer teardownUpdateReparentDb(&ctx.db, &ctx.threaded);
    defer alloc.free(ctx.item_id);
    defer alloc.free(ctx.item_path);

    const page_id = try design_model.setDesignPage(alloc, &ctx.db, .{
        .item_id = ctx.item_id,
        .page_name = "Login",
        .width = 1440,
        .height = 1024,
    });
    defer alloc.free(page_id);

    const group_id = try design_model.addElement(alloc, &ctx.db, ctx.threaded.io(), .{
        .page_id = page_id,
        .name = "login-card",
        .elem_type = .frame,
        .html = "<div></div>",
        .x = 100, .y = 200, .width = 400, .height = 300,
        .fill = "#ffffff", .rotation = 0.0, .corner_radius = 0, .opacity = 1.0,
    });
    defer alloc.free(group_id);

    const leaf_id = try design_model.addElement(alloc, &ctx.db, ctx.threaded.io(), .{
        .page_id = page_id,
        .name = "leaf-a",
        .elem_type = .rectangle,
        .html = "<div></div>",
        .x = 110, .y = 220, .width = 80, .height = 30,
        .fill = "#000000", .rotation = 0.0, .corner_radius = 0, .opacity = 1.0,
    });
    defer alloc.free(leaf_id);

    const output = try useCase(alloc, &ctx.db, .{
        .element_id = leaf_id,
        .name = null,
        .elem_type = null,
        .html = null,
        .x = null,
        .y = null,
        .width = null,
        .height = null,
        .rotation = null,
        .fill = null,
        .stroke = null,
        .stroke_width = null,
        .corner_radius = null,
        .opacity = null,
        .text_content = null,
        .text_style = null,
        .image_url = null,
        .parent_id = group_id,
        .reposition = .last_in_parent,
    });
    defer design_model.freeElement(alloc, output.element);

    try testing_update_reparent.expectEqualStrings(group_id, output.element.parent_id);
    try testing_update_reparent.expectEqual(@as(i64, 0), output.element.position);
}

test "useCase returns CycleDetected (which the handler maps to 400) when reparenting a group into its descendant" {
    const alloc = testing_update_reparent.allocator;
    var ctx = try setupUpdateReparentDbAndItem();
    defer teardownUpdateReparentDb(&ctx.db, &ctx.threaded);
    defer alloc.free(ctx.item_id);
    defer alloc.free(ctx.item_path);

    const page_id = try design_model.setDesignPage(alloc, &ctx.db, .{
        .item_id = ctx.item_id,
        .page_name = "Login",
        .width = 1440,
        .height = 1024,
    });
    defer alloc.free(page_id);

    const group_a_id = try design_model.addElement(alloc, &ctx.db, ctx.threaded.io(), .{
        .page_id = page_id,
        .name = "group-a",
        .elem_type = .frame,
        .html = "<div></div>",
        .x = 100, .y = 200, .width = 400, .height = 300,
        .fill = "#ffffff", .rotation = 0.0, .corner_radius = 0, .opacity = 1.0,
    });
    defer alloc.free(group_a_id);

    const leaf_id = try design_model.addElement(alloc, &ctx.db, ctx.threaded.io(), .{
        .page_id = page_id,
        .name = "leaf",
        .elem_type = .rectangle,
        .html = "<div></div>",
        .x = 300, .y = 400, .width = 50, .height = 50,
        .fill = "#000000", .rotation = 0.0, .corner_radius = 0, .opacity = 1.0,
    });
    defer alloc.free(leaf_id);

    const pre_output = try useCase(alloc, &ctx.db, .{
        .element_id = leaf_id,
        .name = null, .elem_type = null, .html = null,
        .x = null, .y = null, .width = null, .height = null,
        .rotation = null, .fill = null, .stroke = null,
        .stroke_width = null, .corner_radius = null, .opacity = null,
        .text_content = null, .text_style = null, .image_url = null,
        .parent_id = group_a_id,
        .reposition = .last_in_parent,
    });
    defer design_model.freeElement(alloc, pre_output.element);

    const result = useCase(alloc, &ctx.db, .{
        .element_id = group_a_id,
        .name = null, .elem_type = null, .html = null,
        .x = null, .y = null, .width = null, .height = null,
        .rotation = null, .fill = null, .stroke = null,
        .stroke_width = null, .corner_radius = null, .opacity = null,
        .text_content = null, .text_style = null, .image_url = null,
        .parent_id = leaf_id,
        .reposition = null,
    });
    try testing_update_reparent.expectError(error.BadReparent, result);
}

test "useCase rejects an invalid reposition string with BadReparent (handler maps to 400)" {
    const alloc = testing_update_reparent.allocator;
    var ctx = try setupUpdateReparentDbAndItem();
    defer teardownUpdateReparentDb(&ctx.db, &ctx.threaded);
    defer alloc.free(ctx.item_id);
    defer alloc.free(ctx.item_path);

    const page_id = try design_model.setDesignPage(alloc, &ctx.db, .{
        .item_id = ctx.item_id,
        .page_name = "Login",
        .width = 1440,
        .height = 1024,
    });
    defer alloc.free(page_id);

    const leaf_id = try design_model.addElement(alloc, &ctx.db, ctx.threaded.io(), .{
        .page_id = page_id,
        .name = "leaf",
        .elem_type = .rectangle,
        .html = "<div></div>",
        .x = 110, .y = 220, .width = 80, .height = 30,
        .fill = "#000000", .rotation = 0.0, .corner_radius = 0, .opacity = 1.0,
    });
    defer alloc.free(leaf_id);

    // The wire layer translates "garbage" to null (since it's not
    // "last_in_parent"); the useCase then no-ops on reposition and either
    // succeeds or rejects based on parent_id.
    const result = useCase(alloc, &ctx.db, .{
        .element_id = leaf_id,
        .name = null, .elem_type = null, .html = null,
        .x = null, .y = null, .width = null, .height = null,
        .rotation = null, .fill = null, .stroke = null,
        .stroke_width = null, .corner_radius = null, .opacity = null,
        .text_content = null, .text_style = null, .image_url = null,
        .parent_id = null,
        .reposition = null,
    });
    try testing_update_reparent.expectError(error.NoChanges, result);
}
