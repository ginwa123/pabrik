//! LLM tool: `get_design_context` — read-only inspection of a design canvas.
//! Pass EITHER `page_id` to get one page with its elements, OR
//! `workspace_item_id` to get ALL pages of the design item.

const std = @import("std");
const schemas = @import("schemas.zig");
const AgentTool = schemas.AgentTool;
const pabrikcore = @import("pabrikcore");
const sqlite = pabrikcore.sqlite;
const design_model = pabrikcore.ai_mod.design_model;
const helpers = @import("helpers");
const sanitizeControlChars = helpers.sanitize_control_chars;

/// Input structure for `get_design_context` tool.
pub const GetDesignContextInput = struct {
    page_id: ?[]const u8 = null,
    workspace_item_id: ?[]const u8 = null,
};

/// Top-level tool definition for the LLM.
pub const get_design_context_tool_system_prompt =
    \\## Get Design Context Tool — Behavior
    \\Use `get_design_context` to inspect design structure: pages + elements with geometry.
    \\- Pass `page_id` for one page or `workspace_item_id` for all pages. Use to discover `element_id`/`page_id` before editing.
    \\- HTML bodies are not included — read them via `read_file` if needed.
    \\
;

pub const get_design_context_tool = AgentTool{
    .type = "function",
    .function = .{
        .name = "get_design_context",
        .description =
        \\Inspect a design canvas (pages + elements). Pass EITHER `page_id` (one page, with its elements) OR `workspace_item_id` (all pages of the design item) — exactly one of the two.
        \\
        \\Element keys match the design DB row wire shape:
        \\
        \\{"pages":[{"id":...,"name":...,"width":...,"height":...,"position":...,
        \\"elements":[{"id":...,"page_id":...,"name":...,"type":...,
        \\"x":...,"y":...,"width":...,"height":...,"rotation":...,"fill":...,
        \\"stroke":...,"corner_radius":...,"opacity":...,"text_content":...,
        \\"image_url":...,"parent_id":...,"file_path":...,"z_index":...,
        \\"position":...,"created_at":...,"updated_at":...}]}]}
        \\
        \\HTML bodies are NOT included — read them with `read_file`. If the page has no elements yet, create them with `add_element` / `set_design_page` first.
        \\
        \\On error: `{"error":...}`.
        ,
        .parameters = .{
            .type = "object",
            .properties = &.{
                .{
                    .name = "page_id",
                    .type = "string",
                    .description = "ONE page with its elements. Mutually exclusive with `workspace_item_id`. Discover page ids from a `set_design_page` response.",
                },
                .{
                    .name = "workspace_item_id",
                    .type = "string",
                    .description = "ALL pages of a design item. Must come from the Workspace Context listing (item_type='design'). Mutually exclusive with `page_id`.",
                },
            },
            .required = &.{},
        },
        .system_prompt = get_design_context_tool_system_prompt,
    },
};

// ─── JSON helpers ────

fn errorJSON(allocator: std.mem.Allocator, error_msg: []const u8) ![]u8 {
    const clean = try sanitizeControlChars(allocator, error_msg);
    defer allocator.free(clean);
    return try std.json.Stringify.valueAlloc(allocator, .{ .@"error" = clean }, .{});
}

// ─── Execute ─────────────────────────────────────────────────────────────

/// Execute `get_design_context`.
pub fn executeGetDesignContextToString(
    allocator: std.mem.Allocator,
    db: *sqlite.SqliteBackend,
    input: GetDesignContextInput,
) ![]u8 {
    // 1. Validate exactly-one of the two ids.
    const page_id_present = input.page_id != null and input.page_id.?.len > 0;
    const item_id_present = input.workspace_item_id != null and input.workspace_item_id.?.len > 0;
    if (page_id_present == item_id_present) {
        return try errorJSON(
            allocator,
            "exactly one of `page_id` or `workspace_item_id` must be provided (use Workspace Context to find the design item_id)",
        );
    }

    // 2. Dispatch to the right inner function.
    if (page_id_present) {
        return try executeForPage(allocator, db, input.page_id.?);
    } else {
        return try executeForItem(allocator, db, input.workspace_item_id.?);
    }
}

fn executeForPage(
    allocator: std.mem.Allocator,
    db: *sqlite.SqliteBackend,
    page_id: []const u8,
) ![]u8 {
    var bundle = design_model.getPageWithElements(allocator, db, page_id) catch |err| {
        const msg = try std.fmt.allocPrint(
            allocator,
            "page_id '{s}' not found: {s}",
            .{ page_id, @errorName(err) },
        );
        defer allocator.free(msg);
        return try errorJSON(allocator, msg);
    };
    defer bundle.deinit(allocator);

    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const page = try contextPageJSON(a, bundle.page, bundle.elements);
    const pages = [_]ContextPageJSON{page};
    return try std.json.Stringify.valueAlloc(allocator, .{ .pages = pages }, .{});
}

fn executeForItem(
    allocator: std.mem.Allocator,
    db: *sqlite.SqliteBackend,
    item_id: []const u8,
) ![]u8 {
    const pages = design_model.listPagesWithElements(allocator, db, item_id) catch |err| {
        const msg = try std.fmt.allocPrint(
            allocator,
            "workspace_item_id '{s}' not found or DB error: {s}",
            .{ item_id, @errorName(err) },
        );
        defer allocator.free(msg);
        return try errorJSON(allocator, msg);
    };
    defer design_model.freePagesWithElements(allocator, pages);

    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var out: std.ArrayList(ContextPageJSON) = .empty;
    for (pages) |*page| {
        try out.append(a, try contextPageJSON(a, page.page, page.elements));
    }
    return try std.json.Stringify.valueAlloc(allocator, .{ .pages = out.items }, .{});
}

/// JSON page object (keys mirror the old `<page ...>` attributes 1:1;
/// repeated `<element>` children become the `elements` array).
pub const ContextPageJSON = struct {
    id: []const u8,
    name: []const u8,
    width: i64,
    height: i64,
    position: i64,
    elements: []ContextElementJSON,
};

/// JSON element object (keys mirror the old `<element ... />` attributes
/// 1:1; attributes rendered-when-empty become explicit nulls).
pub const ContextElementJSON = struct {
    id: []const u8,
    page_id: []const u8,
    name: []const u8,
    file_path: ?[]const u8,
    x: i64,
    y: i64,
    width: i64,
    height: i64,
    z_index: i64,
    position: i64,
    type: []const u8,
    rotation: f64,
    opacity: f64,
    fill: ?[]const u8,
    stroke: ?[]const u8,
    stroke_width: i64,
    corner_radius: i64,
    text_content: ?[]const u8,
    text_style: ?[]const u8,
    image_url: ?[]const u8,
    parent_id: ?[]const u8,
    created_at: ?[]const u8,
    updated_at: ?[]const u8,
};

fn contextPageJSON(
    allocator: std.mem.Allocator,
    page: design_model.DesignPage,
    elements: []const design_model.DesignElement,
) !ContextPageJSON {
    var out: std.ArrayList(ContextElementJSON) = .empty;
    for (elements) |e| {
        try out.append(allocator, try contextElementJSON(allocator, e));
    }
    return .{
        .id = try sanitizeControlChars(allocator, page.id),
        .name = try sanitizeControlChars(allocator, page.name),
        .width = page.width,
        .height = page.height,
        .position = page.position,
        .elements = out.items,
    };
}

fn contextElementJSON(
    allocator: std.mem.Allocator,
    e: design_model.DesignElement,
) !ContextElementJSON {
    return .{
        .id = try sanitizeControlChars(allocator, e.id),
        .page_id = try sanitizeControlChars(allocator, e.page_id),
        .name = try sanitizeControlChars(allocator, e.name),
        .file_path = try optClean(allocator, e.file_path),
        .x = e.x,
        .y = e.y,
        .width = e.width,
        .height = e.height,
        .z_index = e.z_index,
        .position = e.position,
        .type = try sanitizeControlChars(allocator, e.elem_type),
        .rotation = e.rotation,
        .opacity = e.opacity,
        .fill = try optClean(allocator, e.fill),
        .stroke = try optClean(allocator, e.stroke),
        .stroke_width = e.stroke_width,
        .corner_radius = e.corner_radius,
        .text_content = try optClean(allocator, e.text_content),
        .text_style = try optClean(allocator, e.text_style),
        .image_url = try optClean(allocator, e.image_url),
        .parent_id = try optClean(allocator, e.parent_id),
        .created_at = try optClean(allocator, e.created_at),
        .updated_at = try optClean(allocator, e.updated_at),
    };
}

/// Clean an optional free-text field: empty becomes null, otherwise the
/// control-char-sanitized copy owned by the caller's arena.
fn optClean(allocator: std.mem.Allocator, s: []const u8) !?[]u8 {
    if (s.len == 0) return null;
    return try sanitizeControlChars(allocator, s);
}

// ===== Tests merged from get_design_context_test.zig (2026-09-29 flatten)
// ===== NOT REGISTERED: no registrar imports this file, so these tests are
// not discovered by `zig build test`.

const testing = std.testing;
// ─── Helpers ─────────────────────────────────────────────────────────────

/// In-memory SQLite v6 schema setup.
const testing_ctx = std.testing;

fn setupCtx() !struct {
    db: sqlite.SqliteBackend,
    threaded: std.Io.Threaded,
    item_id: []const u8,
    item_path: []u8,
} {
    const alloc = testing_ctx.allocator;
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

    var tmp = testing_ctx.tmpDir(.{});
    var tmpdir_buf: [std.fs.max_path_bytes]u8 = undefined;
    const tmpdir_len = try tmp.dir.realPath(testing_ctx.io, &tmpdir_buf);
    const tmpdir_path = try testing_ctx.allocator.dupe(u8, tmpdir_buf[0..tmpdir_len]);

    const item_id_const = "item_design_ctx";
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

fn teardownCtx(db: *sqlite.SqliteBackend, threaded: *std.Io.Threaded) void {
    db.deinit();
    threaded.deinit();
}

/// Insert a raw element row directly into `design_page_elements` (bypasses
/// the on-disk HTML write of `addElement`). Used by tests that only need
/// the metadata.
fn insertElementRaw(
    alloc: std.mem.Allocator,
    db: *sqlite.SqliteBackend,
    page_id: []const u8,
    name: []const u8,
    elem_type: []const u8,
    x: i64, y: i64, width: i64, height: i64,
    fill: []const u8,
    parent_id: ?[]const u8,
) !void {
    const id = try std.fmt.allocPrint(alloc, "elem_{s}", .{name});
    defer alloc.free(id);
    const x_str = try std.fmt.allocPrint(alloc, "{d}", .{x});
    defer alloc.free(x_str);
    const y_str = try std.fmt.allocPrint(alloc, "{d}", .{y});
    defer alloc.free(y_str);
    const w_str = try std.fmt.allocPrint(alloc, "{d}", .{width});
    defer alloc.free(w_str);
    const h_str = try std.fmt.allocPrint(alloc, "{d}", .{height});
    defer alloc.free(h_str);

    try db.exec(alloc,
        \\INSERT INTO design_page_elements (
        \\    id, page_id, name, file_path, x, y, width, height,
        \\    z_index, position, type, rotation,
        \\    fill, stroke, stroke_width, corner_radius, opacity,
        \\    text_content, text_style, image_url, parent_id,
        \\    created_at, updated_at
        \\) VALUES (
        \\    ?, ?, ?, '', ?, ?, ?, ?,
        \\    0, 0, ?, 0,
        \\    ?, '', 0, 0, 1.0,
        \\    '', '', '', ?,
        \\    datetime('now'), datetime('now')
        \\)
    , &.{
        id, page_id, name,
        x_str, y_str, w_str, h_str,
        elem_type,
        fill,
        parent_id orelse "",
    });
}

// ─── Behavioural tests (REMOVED, 2026-09-29 flatten) ─────────────────────
// The former get_design_context_test.zig also carried 8 behavioural tests
// that built a v6-schema in-memory DB and asserted the tool's XML output
