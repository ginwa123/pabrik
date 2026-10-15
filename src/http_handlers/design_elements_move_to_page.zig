//! `POST
//! /api/workspaces/:workspace_id/items/:item_id/design/pages/:page_id/elements/:element_id/move-to-page`.
//! Cross-page element relocate.

const std = @import("std");
const pabrikcore = @import("pabrikcore");
const sqlite = pabrikcore.sqlite;
const gserverz = pabrikcore.gserverz;
const design_model = @import("../agentic_loop/design_model.zig");
const http_response = @import("http_response.zig");

// =====================================================================
// Wire types
// =====================================================================

/// Request body. `new_page_id` is required; `apply_to_children` defaults
/// to `true`.
const MoveToPageBody = struct {
    new_page_id: []const u8 = "",
    apply_to_children: ?bool = null,
};

// =====================================================================
// Domain-level error set
// =====================================================================

pub const DesignElementsMoveToPageError = error{
    /// `:element_id` path param is empty.
    /// Maps to 400.
    BadElementId,
    /// `new_page_id` is empty in the body.
    /// Maps to 400.
    BadNewPageId,
    /// `source_page_id` and `new_page_id` are equal — no-op.
    /// Maps to 400.
    SamePage,
    /// The element doesn't exist on the source page (or `page_id`
    /// itself doesn't resolve). Maps to 404.
    ElementNotFound,
    /// The `new_page_id` doesn't match any row in `design_pages`.
    /// Maps to 404.
    PageNotFound,
    /// The target page exists but lives on a different design item.
    /// Maps to 400.
    CrossDesign,
    /// Generic DB failure. Maps to 500.
    DbError,
    OutOfMemory,
};

// =====================================================================
// Use case
// =====================================================================

pub const UseCaseInput = struct {
    source_page_id: []const u8,
    element_id: []const u8,
    new_page_id: []const u8,
    apply_to_children: bool = true,
};

pub const MoveToPageOutput = struct {
    updated: []design_model.DesignElement,
};

pub fn useCase(
    allocator: std.mem.Allocator,
    db: *sqlite.SqliteBackend,
    input: UseCaseInput,
) DesignElementsMoveToPageError!MoveToPageOutput {
    const updated = design_model.moveElementToPage(allocator, db, .{
        .source_page_id = input.source_page_id,
        .element_id = input.element_id,
        .target_page_id = input.new_page_id,
        .apply_to_children = input.apply_to_children,
    }) catch |err| switch (err) {
        error.SamePage => return error.SamePage,
        error.ElementNotFound => return error.ElementNotFound,
        error.PageNotFound => return error.PageNotFound,
        error.CrossDesign => return error.CrossDesign,
        else => return error.DbError,
    };

    return .{ .updated = updated };
}

// =====================================================================
// HTTP handler
// =====================================================================

pub fn designElementsMoveToPageHandler(
    ctx: gserverz.HttpContext,
    req: gserverz.HttpRequest,
    res: gserverz.HttpResponse,
) !gserverz.HttpResponse {
    const allocator = ctx.allocator;

    const di = try pabrikcore.getSingleton();
    const sqlite_db = di.db;

    // 1. Path-param validation.
    const page_id = req.params.get("page_id") orelse "";
    if (page_id.len == 0) {
        return res.jsonResponse(.{
            .status_code = 400,
            .data = try makeErrorJson(allocator, "page_id required"),
        });
    }
    const element_id = req.params.get("element_id") orelse "";
    if (element_id.len == 0) {
        return res.jsonResponse(.{
            .status_code = 400,
            .data = try makeErrorJson(allocator, "element_id required"),
        });
    }

    // 2. Body presence + JSON shape.
    if (req.body.len == 0) {
        return res.jsonResponse(.{
            .status_code = 400,
            .data = try makeErrorJson(allocator, "Request body required"),
        });
    }

    const parsed = std.json.parseFromSliceLeaky(
        MoveToPageBody,
        allocator,
        req.body,
        .{},
    ) catch {
        return res.jsonResponse(.{
            .status_code = 400,
            .data = try makeErrorJson(allocator, "Invalid JSON body"),
        });
    };

    // 3. Validate body fields.
    if (parsed.new_page_id.len == 0) {
        return res.jsonResponse(.{
            .status_code = 400,
            .data = try makeErrorJson(allocator, "new_page_id is required"),
        });
    }
    const apply_to_children = parsed.apply_to_children orelse true;

    // 4. Delegate to the use-case.
    const output = useCase(allocator, sqlite_db, .{
        .source_page_id = page_id,
        .element_id = element_id,
        .new_page_id = parsed.new_page_id,
        .apply_to_children = apply_to_children,
    }) catch |err| {
        const status: u16 = switch (err) {
            error.BadElementId => 400,
            error.BadNewPageId => 400,
            error.SamePage => 400,
            error.CrossDesign => 400,
            error.ElementNotFound => 404,
            error.PageNotFound => 404,
            error.DbError => 500,
            error.OutOfMemory => 500,
        };
        const message: []const u8 = switch (err) {
            error.BadElementId => "element_id is required",
            error.BadNewPageId => "new_page_id is required",
            error.SamePage => "source_page_id and new_page_id must be different",
            error.CrossDesign => "new_page_id belongs to a different design item",
            error.ElementNotFound => "Element not found on source page",
            error.PageNotFound => "Target page not found",
            error.DbError => "Failed to move element to page",
            error.OutOfMemory => "Out of memory",
        };
        return res.jsonResponse(.{
            .status_code = status,
            .data = try makeErrorJson(allocator, message),
        });
    };

    // 5. Build the success response (200 OK). Map each updated row
    //    through `makeDesignElementResponse` so the wire shape matches
    //    the rest of the design API (`type`, not `elem_type`).
    defer design_model.freeElements(allocator, output.updated);

    const mapped = try allocator.alloc(http_response.DesignElementResponse, output.updated.len);
    defer allocator.free(mapped);
    for (output.updated, 0..) |e, i| mapped[i] = http_response.makeDesignElementResponse(e);

    const Wrapper = struct {
        updated: []const http_response.DesignElementResponse,
    };
    return res.jsonResponse(.{
        .status_code = 200,
        .data = try std.json.Stringify.valueAlloc(
            allocator,
            Wrapper{ .updated = mapped },
            .{},
        ),
    });
}

/// Mirrors `design_elements_move_batch.zig::makeErrorJson`. Local
/// definition keeps the handler readable.
fn makeErrorJson(allocator: std.mem.Allocator, message: []const u8) ![]u8 {
    return try std.json.Stringify.valueAlloc(
        allocator,
        struct { @"error": []const u8 }{ .@"error" = message },
        .{},
    );
}

// ─── Behavioural tests for the move-to-page use-case (Chunk 2) ─── Inline
// tests per the project rule (see AGENTS.md /
// `pabrik-agentic-loop-inline-tests-required.md`).

const testing_handler = std.testing;

/// Insert one design element with x/y/width/height and an optional
/// parent_id. Mirrors `insertHandlerMoveBatchElement` from the
/// move-batch handler.
fn insertHandlerMoveToPageElement(
    alloc: std.mem.Allocator,
    db: *sqlite.SqliteBackend,
    id: []const u8,
    page_id: []const u8,
    name: []const u8,
    x: i64,
    y: i64,
    width: i64,
    height: i64,
    parent_id: []const u8,
) !void {
    const x_str = try std.fmt.allocPrint(alloc, "{d}", .{x});
    defer alloc.free(x_str);
    const y_str = try std.fmt.allocPrint(alloc, "{d}", .{y});
    defer alloc.free(y_str);
    const w_str = try std.fmt.allocPrint(alloc, "{d}", .{width});
    defer alloc.free(w_str);
    const h_str = try std.fmt.allocPrint(alloc, "{d}", .{height});
    defer alloc.free(h_str);

    const parent_to_bind: []const u8 = if (parent_id.len == 0) "" else parent_id;

    try db.exec(alloc,
        \\INSERT INTO design_page_elements (
        \\    id, page_id, name, file_path, x, y, width, height,
        \\    z_index, position, type, rotation,
        \\    fill, stroke, stroke_width, corner_radius, opacity,
        \\    text_content, text_style, image_url, parent_id,
        \\    created_at, updated_at
        \\) VALUES (
        \\    ?, ?, ?, '', ?, ?, ?, ?,
        \\    0, 0, 'rectangle', 0,
        \\    '', '', 0, 0, 1.0,
        \\    '', '', '', ?,
        \\    datetime('now'), datetime('now')
        \\)
    , &.{ id, page_id, name, x_str, y_str, w_str, h_str, parent_to_bind });
}

const HandlerTestCtx = struct {
    db: sqlite.SqliteBackend,
    threaded: std.Io.Threaded,
    item_id: []const u8,
    item_path: []u8,
};

fn setupHandlerMoveToPageDb() !HandlerTestCtx {
    const alloc = testing_handler.allocator;
    var threaded = std.Io.Threaded.init(alloc, .{});
    errdefer threaded.deinit();
    const io = threaded.io();

    var db: sqlite.SqliteBackend = .{};
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

    var tmp = testing_handler.tmpDir(.{});
    var tmpdir_buf: [std.fs.max_path_bytes]u8 = undefined;
    const tmpdir_len = try tmp.dir.realPath(testing_handler.io, &tmpdir_buf);
    const tmpdir_path = try testing_handler.allocator.dupe(u8, tmpdir_buf[0..tmpdir_len]);

    const item_id_const = "item_move_to_page_handler";
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

fn teardownHandlerMoveToPageDb(ctx: *HandlerTestCtx) void {
    ctx.db.deinit();
    ctx.threaded.deinit();
}

test "useCase moves a leaf to another page (happy path, 200 contract)" {
    const alloc = testing_handler.allocator;
    var ctx = try setupHandlerMoveToPageDb();
    defer teardownHandlerMoveToPageDb(&ctx);
    defer alloc.free(ctx.item_id);
    defer alloc.free(ctx.item_path);

    const source_page_id = try design_model.setDesignPage(alloc, &ctx.db, .{
        .item_id = ctx.item_id,
        .page_name = "Source",
        .width = 1440,
        .height = 1024,
    });
    defer alloc.free(source_page_id);
    const target_page_id = try design_model.setDesignPage(alloc, &ctx.db, .{
        .item_id = ctx.item_id,
        .page_name = "Target",
        .width = 1440,
        .height = 1024,
    });
    defer alloc.free(target_page_id);

    try insertHandlerMoveToPageElement(alloc, &ctx.db, "elem_leaf", source_page_id, "leaf", 10, 20, 100, 50, "");

    const output = try useCase(alloc, &ctx.db, .{
        .source_page_id = source_page_id,
        .element_id = "elem_leaf",
        .new_page_id = target_page_id,
        .apply_to_children = true,
    });
    defer design_model.freeElements(alloc, output.updated);

    try testing_handler.expectEqual(@as(usize, 1), output.updated.len);
    try testing_handler.expectEqualStrings("elem_leaf", output.updated[0].id);
    try testing_handler.expectEqualStrings(target_page_id, output.updated[0].page_id);
}

test "useCase rejects SamePage (source == target, 400 contract)" {
    const alloc = testing_handler.allocator;
    var ctx = try setupHandlerMoveToPageDb();
    defer teardownHandlerMoveToPageDb(&ctx);
    defer alloc.free(ctx.item_id);
    defer alloc.free(ctx.item_path);

    const page_id = try design_model.setDesignPage(alloc, &ctx.db, .{
        .item_id = ctx.item_id,
        .page_name = "Single",
        .width = 1440,
        .height = 1024,
    });
    defer alloc.free(page_id);
    try insertHandlerMoveToPageElement(alloc, &ctx.db, "elem_x", page_id, "x", 0, 0, 50, 50, "");

    const result = useCase(alloc, &ctx.db, .{
        .source_page_id = page_id,
        .element_id = "elem_x",
        .new_page_id = page_id, // same as source!
        .apply_to_children = true,
    });
    try testing_handler.expectError(error.SamePage, result);
}

test "useCase rejects ElementNotFound (element missing on source page, 404 contract)" {
    const alloc = testing_handler.allocator;
    var ctx = try setupHandlerMoveToPageDb();
    defer teardownHandlerMoveToPageDb(&ctx);
    defer alloc.free(ctx.item_id);
    defer alloc.free(ctx.item_path);

    const source_page_id = try design_model.setDesignPage(alloc, &ctx.db, .{
        .item_id = ctx.item_id,
        .page_name = "S",
        .width = 1440,
        .height = 1024,
    });
    defer alloc.free(source_page_id);
    const target_page_id = try design_model.setDesignPage(alloc, &ctx.db, .{
        .item_id = ctx.item_id,
        .page_name = "T",
        .width = 1440,
        .height = 1024,
    });
    defer alloc.free(target_page_id);

    const result = useCase(alloc, &ctx.db, .{
        .source_page_id = source_page_id,
        .element_id = "elem_does_not_exist",
        .new_page_id = target_page_id,
        .apply_to_children = true,
    });
    try testing_handler.expectError(error.ElementNotFound, result);
}

test "useCase rejects PageNotFound (target page missing, 404 contract)" {
    const alloc = testing_handler.allocator;
    var ctx = try setupHandlerMoveToPageDb();
    defer teardownHandlerMoveToPageDb(&ctx);
    defer alloc.free(ctx.item_id);
    defer alloc.free(ctx.item_path);

    const source_page_id = try design_model.setDesignPage(alloc, &ctx.db, .{
        .item_id = ctx.item_id,
        .page_name = "S",
        .width = 1440,
        .height = 1024,
    });
    defer alloc.free(source_page_id);
    try insertHandlerMoveToPageElement(alloc, &ctx.db, "elem_l", source_page_id, "l", 0, 0, 50, 50, "");

    const result = useCase(alloc, &ctx.db, .{
        .source_page_id = source_page_id,
        .element_id = "elem_l",
        .new_page_id = "page_nonexistent",
        .apply_to_children = true,
    });
    try testing_handler.expectError(error.PageNotFound, result);
}

test "useCase rejects CrossDesign (target on different design item, 400 contract)" {
    const alloc = testing_handler.allocator;
    var ctx = try setupHandlerMoveToPageDb();
    defer teardownHandlerMoveToPageDb(&ctx);
    defer alloc.free(ctx.item_id);
    defer alloc.free(ctx.item_path);

    const source_page_id = try design_model.setDesignPage(alloc, &ctx.db, .{
        .item_id = ctx.item_id,
        .page_name = "S",
        .width = 1440,
        .height = 1024,
    });
    defer alloc.free(source_page_id);

    // Insert a SECOND design item + page on it.
    var tmp2 = testing_handler.tmpDir(.{});
    var tmp2_buf: [std.fs.max_path_bytes]u8 = undefined;
    const tmp2_len = try tmp2.dir.realPath(testing_handler.io, &tmp2_buf);
    const tmp2_path = try testing_handler.allocator.dupe(u8, tmp2_buf[0..tmp2_len]);
    defer alloc.free(tmp2_path);
    try ctx.db.exec(alloc,
        "INSERT INTO workspace_items (id, workspace_id, item_type, path) " ++
        "VALUES ('item_other', 'ws_test', 'design', ?)",
        &.{tmp2_path});
    const item_other_slice = try alloc.dupe(u8, "item_other");
    defer alloc.free(item_other_slice);
    const other_page_id = try design_model.setDesignPage(alloc, &ctx.db, .{
        .item_id = item_other_slice,
        .page_name = "Other",
        .width = 1440,
        .height = 1024,
    });
    defer alloc.free(other_page_id);

    try insertHandlerMoveToPageElement(alloc, &ctx.db, "elem_l", source_page_id, "l", 0, 0, 50, 50, "");

    const result = useCase(alloc, &ctx.db, .{
        .source_page_id = source_page_id,
        .element_id = "elem_l",
        .new_page_id = other_page_id, // different design item!
        .apply_to_children = true,
    });
    try testing_handler.expectError(error.CrossDesign, result);
}

test "useCase with apply_to_children=false moves only the root (cascade disabled)" {
    const alloc = testing_handler.allocator;
    var ctx = try setupHandlerMoveToPageDb();
    defer teardownHandlerMoveToPageDb(&ctx);
    defer alloc.free(ctx.item_id);
    defer alloc.free(ctx.item_path);

    const source_page_id = try design_model.setDesignPage(alloc, &ctx.db, .{
        .item_id = ctx.item_id,
        .page_name = "S",
        .width = 1440,
        .height = 1024,
    });
    defer alloc.free(source_page_id);
    const target_page_id = try design_model.setDesignPage(alloc, &ctx.db, .{
        .item_id = ctx.item_id,
        .page_name = "T",
        .width = 1440,
        .height = 1024,
    });
    defer alloc.free(target_page_id);

    // Group with 2 children on the source page.
    try insertHandlerMoveToPageElement(alloc, &ctx.db, "elem_g", source_page_id, "g", 0, 0, 200, 150, "");
    try insertHandlerMoveToPageElement(alloc, &ctx.db, "elem_c1", source_page_id, "c1", 10, 10, 50, 50, "elem_g");
    try insertHandlerMoveToPageElement(alloc, &ctx.db, "elem_c2", source_page_id, "c2", 100, 100, 50, 50, "elem_g");

    const output = try useCase(alloc, &ctx.db, .{
        .source_page_id = source_page_id,
        .element_id = "elem_g",
        .new_page_id = target_page_id,
        .apply_to_children = false, // ← key difference
    });
    defer design_model.freeElements(alloc, output.updated);

    // Only the root moves; children stay on the source page.
    try testing_handler.expectEqual(@as(usize, 1), output.updated.len);
    try testing_handler.expectEqualStrings("elem_g", output.updated[0].id);
    try testing_handler.expectEqualStrings(target_page_id, output.updated[0].page_id);

    // Confirm children are still on the source page via a fresh read.
    var c1_pid_q = try ctx.db.query(alloc,
        "SELECT page_id FROM design_page_elements WHERE id = ?",
        &.{"elem_c1"});
    defer c1_pid_q.deinit();
    const c1_row = (try c1_pid_q.next()) orelse unreachable;
    defer c1_row.deinit(alloc);
    try testing_handler.expectEqualStrings(source_page_id, c1_row.values[0]);

    var c2_pid_q = try ctx.db.query(alloc,
        "SELECT page_id FROM design_page_elements WHERE id = ?",
        &.{"elem_c2"});
    defer c2_pid_q.deinit();
    const c2_row = (try c2_pid_q.next()) orelse unreachable;
    defer c2_row.deinit(alloc);
    try testing_handler.expectEqualStrings(source_page_id, c2_row.values[0]);
}

