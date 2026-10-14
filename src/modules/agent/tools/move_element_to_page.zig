//! LLM tool: `move_element_to_page` — relocates an existing design
//! element from one page to another page in the same design item.
//! When `apply_to_children = true` (the default), the move cascades to
//! every transitive descendant of the element via the backend's
//! recursive CTE in one SQL transaction — so the LLM can say "move
//! Group 2 to page 'Checkout'" and the whole subtree follows (Figma
//! parity).
//!
//! Plan: docs/superpowers/plans/2026-08-06-move-element-to-page.md
//! (Chunk 3, Task 3.1)

const std = @import("std");
const schemas = @import("schemas.zig");
const AgentTool = schemas.AgentTool;
const pabrikcore = @import("pabrikcore");
const sqlite = pabrikcore.sqlite;
const design_model = pabrikcore.ai_mod.design_model;
const helpers = @import("helpers");
const sanitizeControlChars = helpers.sanitize_control_chars;

/// Input shape for `move_element_to_page` tool.
///
/// All fields except `element_id` and `new_page_id` are optional.
/// - `apply_to_children` defaults to `true` — matches the user's
///   "move element parent will be move all child" mental model from
///   the `move_design_element` tool.
/// - `new_page_id` is REQUIRED (no default) — the tool errors out on
///   empty / missing values.
pub const MoveElementToPageInput = struct {
    /// The element id to move. Must exist on the active page.
    element_id: []const u8 = "",
    /// The destination page id. Both pages must live on the same
    /// design item (`workspace_item_id`); cross-design moves are
    /// rejected with `CrossDesign`.
    new_page_id: []const u8 = "",
    /// Default true. When false, only the root moves (descendants
    /// stay behind on the source page as top-level orphans).
    apply_to_children: bool = true,
};

/// Top-level tool definition for the LLM.
pub const move_element_to_page_tool_system_prompt =
    \\## Move Element To Page Tool — Behavior
    \\Use `move_element_to_page` to move an element (and optionally its descendants) to a different page in the same design item.
    \\- Provide `element_id` and `target_page_id`. Both must be on the same design item.
    \\
;

pub const move_element_to_page_tool = AgentTool{
    .type = "function",
    .function = .{
        .name = "move_element_to_page",
        .description =
        \\Relocate an existing design element to another page of the same design item. With `apply_to_children=true` (the default) every transitive descendant moves too (Figma parity: a moved `group` or `frame` keeps its subtree); with `false` only the root moves and its descendants stay on the source page as top-level orphans.
        \\
        \\`element_id` must reference an element on the active page; `new_page_id` must be a sibling page of the same design item — discover siblings via `get_design_context` (the `<pages count="N">` block). Both are required; the active page returns `SamePage`.
        \\
        \\On error: verify both ids are correctly prefixed; use `get_design_context` for a fresh `new_page_id`; refresh the active page on `ElementNotFound`.
        ,
        .parameters = .{
            .type = "object",
            .properties = &.{
                .{
                    .name = "element_id",
                    .type = "string",
                    .description = "The element id to move, from the `id` field of an element object in a `set_design_page`/`get_design_context` response.",
                },
                .{
                    .name = "new_page_id",
                    .type = "string",
                    .description = "The destination page id — the `id` field of a page object from `get_design_context`. Must be a sibling page of the same design item.",
                },
                .{
                    .name = "apply_to_children",
                    .type = "boolean",
                    .description = "Default true: every transitive descendant moves too. Pass false to move only the element (descendants stay on the source page as orphans).",
                },
            },
            .required = &.{ "element_id", "new_page_id" },
        },
        .system_prompt = move_element_to_page_tool_system_prompt,
    },
};

/// Error JSON object `{"error":...}` so the tool dispatcher can detect
/// it via the top-level `error` key.
pub fn errorJSON(allocator: std.mem.Allocator, error_msg: []const u8) ![]u8 {
    const clean = try sanitizeControlChars(allocator, error_msg);
    defer allocator.free(clean);
    return try std.json.Stringify.valueAlloc(allocator, .{ .@"error" = clean }, .{});
}

/// Same as `errorJSON` but TAKES OWNERSHIP of `error_msg` and frees it.
pub fn errorJSONOwned(allocator: std.mem.Allocator, error_msg: []u8) ![]u8 {
    defer allocator.free(error_msg);
    return try errorJSON(allocator, error_msg);
}

/// Validate `element_id` is non-empty and `new_page_id` is non-empty.
/// Returns null when both are valid, or an error JSON object on a
/// missing field.
fn validateInputShape(allocator: std.mem.Allocator, input: MoveElementToPageInput) !?[]u8 {
    if (input.element_id.len == 0) {
        return try errorJSON(allocator, "element_id is required (find it in the `id` field of an element object in a `set_design_page` or `get_design_context` response)");
    }
    if (input.new_page_id.len == 0) {
        return try errorJSON(allocator, "new_page_id is required (find it in the `id` field of a page object in `get_design_context`)");
    }
    if (std.mem.startsWith(u8, input.element_id, "page_")) {
        return try errorJSONOwned(allocator, try std.fmt.allocPrint(allocator,
            \\element_id '{s}' looks like a PAGE id (starts with 'page_'). Pass the ELEMENT id instead — find it in the `id` field of an element object in a `set_design_page` response.
        , .{input.element_id}));
    }
    if (std.mem.startsWith(u8, input.element_id, "item_")) {
        return try errorJSONOwned(allocator, try std.fmt.allocPrint(allocator,
            \\element_id '{s}' looks like an ITEM id (starts with 'item_'). Pass the ELEMENT id instead.
        , .{input.element_id}));
    }
    if (!std.mem.startsWith(u8, input.element_id, "elem_")) {
        return try errorJSONOwned(allocator, try std.fmt.allocPrint(allocator,
            \\element_id '{s}' has an unrecognized prefix (expected 'elem_'). move_element_to_page expects an element id from a previous set_design_page or get_design_context response.
        , .{input.element_id}));
    }
    if (!std.mem.startsWith(u8, input.new_page_id, "page_")) {
        return try errorJSONOwned(allocator, try std.fmt.allocPrint(allocator,
            \\new_page_id '{s}' has an unrecognized prefix (expected 'page_'). move_element_to_page expects a page id from a previous get_design_context response.
        , .{input.new_page_id}));
    }
    return null;
}

/// Execute the `move_element_to_page` tool. Returns a JSON string for
/// the LLM.
///
/// On success, the response shape is:
/// `{"moved":[{"id":...,"page_id":...,"name":...,"type":...}, ...]}`.
///
/// On error, the response is `{"error":...}`.
pub fn executeMoveElementToPageToString(
    allocator: std.mem.Allocator,
    db: *sqlite.SqliteBackend,
    active_page_id: []const u8,
    input: MoveElementToPageInput,
) ![]u8 {
    // 0. Input validation (shape only — DB validation runs after).
    if (try validateInputShape(allocator, input)) |e| return e;

    // 1. Delegate to the design-model layer. The cascade + auto-detach
    //    + SSE event all happen inside `moveElementToPage`.
    const updated = design_model.moveElementToPage(allocator, db, .{
        .source_page_id = active_page_id,
        .element_id = input.element_id,
        .target_page_id = input.new_page_id,
        .apply_to_children = input.apply_to_children,
    }) catch |err| {
        return switch (err) {
            error.SamePage => try errorJSON(allocator, "new_page_id must be a DIFFERENT page from the active page (you tried to move to the same page)"),
            error.ElementNotFound => try errorJSON(allocator, "element_id does not reference any element on the active page — call set_design_page to refresh"),
            error.PageNotFound => try errorJSON(allocator, "new_page_id does not reference any design page — call get_design_context to find the correct page id"),
            error.CrossDesign => try errorJSON(allocator, "new_page_id belongs to a different design item — cross-design moves are not supported"),
            error.DbError => try errorJSON(allocator, "DB: moveElementToPage failed (unexpected SQL error)"),
            error.OutOfMemory => try errorJSON(allocator, "Out of memory"),
            else => try errorJSONOwned(allocator, try std.fmt.allocPrint(allocator, "DB: moveElementToPage failed: {s}", .{@errorName(err)})),
        };
    };
    defer design_model.freeElements(allocator, updated);

    return try renderSuccessJSON(allocator, updated);
}

/// Render the success JSON response. Lists every moved element
/// (root + descendants) with their `page_id`, `name`, `type`.
/// Render the success JSON response. Lists every moved element
/// (root + descendants) with their `page_id`, `name`, `type`.
fn renderSuccessJSON(
    allocator: std.mem.Allocator,
    moved: []const design_model.DesignElement,
) ![]u8 {
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var out: std.ArrayList(MovedElementJSON) = .empty;
    for (moved) |e| {
        try out.append(a, .{
            .id = try sanitizeControlChars(a, e.id),
            .page_id = try sanitizeControlChars(a, e.page_id),
            .name = try sanitizeControlChars(a, e.name),
            .type = try sanitizeControlChars(a, e.elem_type),
        });
    }
    return try std.json.Stringify.valueAlloc(allocator, .{ .moved = out.items }, .{});
}

/// JSON row for one moved element (keys mirror the old `<element ... />`
/// attributes 1:1).
pub const MovedElementJSON = struct {
    id: []const u8,
    page_id: []const u8,
    name: []const u8,
    type: []const u8,
};

const move_element_to_page = @import("move_element_to_page.zig");
const testing = std.testing;

// =====================================================================
// Test fixtures
// =====================================================================

const TestCtx = struct {
    db: sqlite.SqliteBackend,
    threaded: std.Io.Threaded,
    item_id: []const u8,
    item_path: []u8,
};

fn setupDb() !TestCtx {
    const alloc = testing.allocator;
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

    var tmp = testing.tmpDir(.{});
    var tmpdir_buf: [std.fs.max_path_bytes]u8 = undefined;
    const tmpdir_len = try tmp.dir.realPath(testing.io, &tmpdir_buf);
    const tmpdir_path = try alloc.dupe(u8, tmpdir_buf[0..tmpdir_len]);
    defer alloc.free(tmpdir_path);

    const item_id_const = "item_move_to_page_tool";
    try db.exec(alloc, "INSERT INTO workspace_items (id, workspace_id, item_type, path) " ++
        "VALUES (?, 'ws_test', 'design', ?)", &.{ item_id_const, tmpdir_path });

    const item_id_slice = try alloc.dupe(u8, item_id_const);
    return .{
        .db = db,
        .threaded = threaded,
        .item_id = item_id_slice,
        .item_path = try alloc.dupe(u8, tmpdir_path),
    };
}

fn teardownDb(ctx: *TestCtx) void {
    ctx.db.deinit();
    ctx.threaded.deinit();
    testing.allocator.free(ctx.item_id);
    testing.allocator.free(ctx.item_path);
}

fn contains(haystack: []const u8, needle: []const u8) bool {
    return std.mem.indexOf(u8, haystack, needle) != null;
}

// =====================================================================
// Tests
// =====================================================================

test "move_element_to_page_tool has the expected LLM-facing schema (name, required fields)" {
    const tool = move_element_to_page.move_element_to_page_tool;

    try testing.expectEqualStrings("function", tool.type);
    try testing.expectEqualStrings("move_element_to_page", tool.function.name);

    // element_id + new_page_id are required.
    try testing.expectEqual(@as(usize, 2), tool.function.parameters.required.len);
    var saw_element_id = false;
    var saw_new_page_id = false;
    for (tool.function.parameters.required) |r| {
        if (std.mem.eql(u8, r, "element_id")) saw_element_id = true;
        if (std.mem.eql(u8, r, "new_page_id")) saw_new_page_id = true;
    }
    try testing.expect(saw_element_id);
    try testing.expect(saw_new_page_id);

    // All three declared properties exist.
    var saw_apply_to_children = false;
    for (tool.function.parameters.properties) |p| {
        if (std.mem.eql(u8, p.name, "apply_to_children")) saw_apply_to_children = true;
    }
    try testing.expect(saw_apply_to_children);
}

test "executeMoveElementToPageToString returns a structured success XML on happy path" {
    const alloc = testing.allocator;
    var ctx = try setupDb();
    defer teardownDb(&ctx);

    // Use the production helpers (matches `move_design_element_test.zig`).
    const source_page_id = try design_model.setDesignPage(alloc, &ctx.db, .{
        .item_id = ctx.item_id,
        .page_name = "source",
        .width = 1440,
        .height = 1024,
    });
    defer alloc.free(source_page_id);
    const target_page_id = try design_model.setDesignPage(alloc, &ctx.db, .{
        .item_id = ctx.item_id,
        .page_name = "target",
        .width = 1440,
        .height = 1024,
    });
    defer alloc.free(target_page_id);

    const elem_id = try design_model.addElement(alloc, &ctx.db, ctx.threaded.io(), .{
        .page_id = source_page_id,
        .name = "leaf",
        .elem_type = .rectangle,
        .html = "<div></div>",
        .x = 10,
        .y = 20,
        .width = 50,
        .height = 50,
        .fill = "#000000",
        .rotation = 0.0,
        .corner_radius = 0,
        .opacity = 1.0,
    });
    defer alloc.free(elem_id);

    const json = try move_element_to_page.executeMoveElementToPageToString(
        alloc,
        &ctx.db,
        source_page_id,
        .{ .element_id = elem_id, .new_page_id = target_page_id, .apply_to_children = true },
    );
    defer alloc.free(json);

    // Response shape: `{"moved":[{"id":...,"page_id":...,"name":...,"type":...}]}`.
    var parsed = try std.json.parseFromSlice(std.json.Value, alloc, json, .{});
    defer parsed.deinit();
    try testing.expect(parsed.value == .object);
    try testing.expect(parsed.value.object.get("error") == null);
    const moved = parsed.value.object.get("moved").?.array.items;
    try testing.expectEqual(@as(usize, 1), moved.len);
    const row = moved[0].object;
    try testing.expectEqualStrings(elem_id, row.get("id").?.string);
    try testing.expectEqualStrings(target_page_id, row.get("page_id").?.string);
    try testing.expectEqualStrings("leaf", row.get("name").?.string);
    try testing.expectEqualStrings("rectangle", row.get("type").?.string);
}

test "executeMoveElementToPageToString returns an error object on missing element_id" {
    const alloc = testing.allocator;
    const json = try move_element_to_page.executeMoveElementToPageToString(
        alloc,
        undefined, // DB never reached (input validation fails first)
        "page_unused",
        .{ .element_id = "", .new_page_id = "page_target", .apply_to_children = true },
    );
    defer alloc.free(json);

    var parsed = try std.json.parseFromSlice(std.json.Value, alloc, json, .{});
    defer parsed.deinit();
    const err_val = parsed.value.object.get("error") orelse return error.MissingErrorField;
    try testing.expect(contains(err_val.string, "element_id is required"));
}

test "executeMoveElementToPageToString rejects bad prefixes via an error object" {
    const alloc = testing.allocator;
    const json = try move_element_to_page.executeMoveElementToPageToString(
        alloc,
        undefined,
        "page_unused",
        .{ .element_id = "page_wrong_shape", .new_page_id = "page_target", .apply_to_children = true },
    );
    defer alloc.free(json);

    var parsed = try std.json.parseFromSlice(std.json.Value, alloc, json, .{});
    defer parsed.deinit();
    const err_val = parsed.value.object.get("error") orelse return error.MissingErrorField;
    try testing.expect(contains(err_val.string, "PAGE id"));
}
