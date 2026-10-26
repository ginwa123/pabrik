//! LLM tool: `update_element` — partial-update an existing element on a
//! design page.

const std = @import("std");
const schemas = @import("schemas.zig");
const AgentTool = schemas.AgentTool;
const pabrikcore = @import("pabrikcore");
const sqlite = pabrikcore.sqlite;
const design_model = pabrikcore.ai_mod.design_model;
const helpers = @import("helpers");
const sanitizeControlChars = helpers.sanitize_control_chars;

/// Input structure for `update_element` tool. ALL fields except `element_id`
/// are optional.
pub const UpdateElementInput = struct {
    /// The element id (NOT the page_id). The LLM discovers element
    /// ids via `set_design_page` (the response includes the element
    /// ids in each element object's `id` field).
    element_id: []const u8 = "",
    /// New name (optional). Must be unique within the page if changed.
    name: ?[]const u8 = null,
    /// New element type (optional). One of: rectangle, ellipse, text,
    /// image, frame, group. Null = no change.
    type: ?[]const u8 = null,
    /// New HTML body (optional). When set, the on-disk file at
    /// `file_path` is rewritten atomically. If the file doesn't
    /// exist (orphan), it's recreated.
    html: ?[]const u8 = null,
    /// New X position (optional).
    x: ?i64 = null,
    /// New Y position (optional).
    y: ?i64 = null,
    /// New width (optional).
    width: ?i64 = null,
    /// New height (optional).
    height: ?i64 = null,
    /// New rotation in degrees (optional).
    rotation: ?f64 = null,
    /// New fill color (optional). Empty string means "use default"
    /// (no fill) — same as add_element's behavior.
    fill: ?[]const u8 = null,
    /// New stroke color (optional).
    stroke: ?[]const u8 = null,
    /// New stroke width in pixels (optional).
    stroke_width: ?i64 = null,
    /// New corner radius in pixels (optional, rectangle only).
    corner_radius: ?i64 = null,
    /// New opacity 0.0–1.0 (optional).
    opacity: ?f64 = null,
    /// New text content (optional, for type='text').
    text_content: ?[]const u8 = null,
    /// New text style JSON (optional, for type='text').
    text_style: ?[]const u8 = null,
    /// New image URL (optional, for type='image').
    image_url: ?[]const u8 = null,
};

/// Top-level tool definition for the LLM. The description emphasizes that ALL
/// fields except `element_id` are optional, and that `set_design_page` is the
/// way to discover element ids (no separate list tool exists).
pub const update_design_element_tool_system_prompt =
    \\## Update Design Element Tool — Behavior
    \\Use `update_element` to partially update an existing design element.
    \\- Only the fields you provide change; others stay. Use for moving, resizing, or restyling.
    \\- Discover `element_id` via `set_design_page` or `get_design_context`.
    \\
;

pub const update_design_element_tool = AgentTool{
    .type = "function",
    .function = .{
        .name = "update_element",
        .description =
        \\Partially update one element on a design page. ALL fields except `element_id` are OPTIONAL: only the fields you provide change.
        \\
        \\Use it to move or resize (`x`, `y`, `width`, `height`), restyle (`fill`, `stroke`, `rotation`, `opacity`, `corner_radius`), change `type`, or rewrite `html` (written atomically to `file_path`; an orphan file is recreated).
        \\
        \\`fill: ""` means "no fill", as in `add_element`. Returns the updated element (html body omitted).
        \\
        \\On error: re-read `element_id` via `set_design_page`; a changed `name` must be unique within the page.
        ,
        .parameters = .{
            .type = "object",
            .properties = &.{
                .{
                    .name = "element_id",
                    .type = "string",
                    .description = "The element id (NOT the page_id), from an element object's `id` field in a previous `set_design_page` response.",
                },
                .{
                    .name = "name",
                    .type = "string",
                    .description = "Name (optional). Must be unique within the page.",
                },
                .{
                    .name = "type",
                    .type = "string",
                    .description = "Element type (optional): rectangle, ellipse, text, image, frame, group.",
                },
                .{
                    .name = "html",
                    .type = "string",
                    .description = "HTML body (optional). Rewrites `file_path` atomically; orphan files are recreated.",
                },
                .{
                    .name = "x",
                    .type = "integer",
                    .description = "X position in CSS pixels (optional).",
                },
                .{
                    .name = "y",
                    .type = "integer",
                    .description = "Y position in CSS pixels (optional).",
                },
                .{
                    .name = "width",
                    .type = "integer",
                    .description = "Width in CSS pixels (optional).",
                },
                .{
                    .name = "height",
                    .type = "integer",
                    .description = "Height in CSS pixels (optional).",
                },
                .{
                    .name = "rotation",
                    .type = "number",
                    .description = "Rotation in degrees (optional).",
                },
                .{
                    .name = "fill",
                    .type = "string",
                    .description = "Fill color (optional). `\"\"` = no fill.",
                },
                .{
                    .name = "stroke",
                    .type = "string",
                    .description = "Stroke color (optional).",
                },
                .{
                    .name = "stroke_width",
                    .type = "integer",
                    .description = "Stroke width in pixels (optional).",
                },
                .{
                    .name = "corner_radius",
                    .type = "integer",
                    .description = "Corner radius in pixels (optional, rectangle only).",
                },
                .{
                    .name = "opacity",
                    .type = "number",
                    .description = "Opacity 0.0–1.0 (optional).",
                },
                .{
                    .name = "text_content",
                    .type = "string",
                    .description = "Text content (optional, for type='text').",
                },
                .{
                    .name = "text_style",
                    .type = "string",
                    .description = "Text style as JSON (optional).",
                },
                .{
                    .name = "image_url",
                    .type = "string",
                    .description = "Image URL (optional, for type='image').",
                },
            },
            .required = &.{"element_id"},
        },
        .system_prompt = update_design_element_tool_system_prompt,
    },
};

/// Generate an error JSON object (replaces the old per-tool XML escape +
/// error envelope helpers).
/// Generate an error JSON object `{"error":...}` for the tool dispatcher.
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

/// Canonical element JSON object (keys mirror the old `<element ... />`
/// attributes 1:1; attributes omitted-when-empty become explicit nulls).
pub const ElementJSON = struct {
    id: []const u8,
    page_id: []const u8,
    name: []const u8,
    type: []const u8,
    x: i64,
    y: i64,
    width: i64,
    height: i64,
    rotation: f64,
    opacity: f64,
    corner_radius: i64,
    fill: ?[]const u8,
    stroke: ?[]const u8,
    text_content: ?[]const u8,
    text_style: ?[]const u8,
    image_url: ?[]const u8,
    file_path: ?[]const u8,
    created_at: []const u8,
    updated_at: []const u8,
};

/// Render the canonical element JSON response shape.
pub fn elementToJSON(
    allocator: std.mem.Allocator,
    elem: design_model.DesignElement,
) ![]u8 {
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const a = arena.allocator();
    return try std.json.Stringify.valueAlloc(allocator, ElementJSON{
        .id = try sanitizeControlChars(a, elem.id),
        .page_id = try sanitizeControlChars(a, elem.page_id),
        .name = try sanitizeControlChars(a, elem.name),
        .type = try sanitizeControlChars(a, elem.elem_type),
        .x = elem.x,
        .y = elem.y,
        .width = elem.width,
        .height = elem.height,
        .rotation = elem.rotation,
        .opacity = elem.opacity,
        .corner_radius = elem.corner_radius,
        .fill = try optClean(a, elem.fill),
        .stroke = try optClean(a, elem.stroke),
        .text_content = try optClean(a, elem.text_content),
        .text_style = try optClean(a, elem.text_style),
        .image_url = try optClean(a, elem.image_url),
        .file_path = try optClean(a, elem.file_path),
        .created_at = try sanitizeControlChars(a, elem.created_at),
        .updated_at = try sanitizeControlChars(a, elem.updated_at),
    }, .{});
}

/// Clean an optional free-text field: empty becomes null, otherwise the
/// control-char-sanitized copy owned by the caller's arena.
fn optClean(allocator: std.mem.Allocator, s: []const u8) !?[]u8 {
    if (s.len == 0) return null;
    return try sanitizeControlChars(allocator, s);
}

/// Parse the optional `type` string into an `ElementType` enum.
/// Returns null when the string is null (no change), or an error JSON object
/// when the string is non-null but not one of the 6 valid types.
fn parseOptionalElementType(_: std.mem.Allocator, type_str: ?[]const u8) !?design_model.ElementType {
    const t = type_str orelse return null;
    if (std.mem.eql(u8, t, "rectangle")) return .rectangle;
    if (std.mem.eql(u8, t, "ellipse")) return .ellipse;
    if (std.mem.eql(u8, t, "text")) return .text;
    if (std.mem.eql(u8, t, "image")) return .image;
    if (std.mem.eql(u8, t, "frame")) return .frame;
    if (std.mem.eql(u8, t, "group")) return .group;
    return error.BadTypeString;
}

/// Validate `element_id` is non-empty and has the right `elem_`
/// prefix. Returns null when shape is correct, or an error JSON object on
/// mismatch.
fn validateElementIdShape(allocator: std.mem.Allocator, element_id: []const u8) !?[]u8 {
    if (element_id.len == 0) {
        return try errorJSON(allocator, "element_id is required (find it in the `id` field of an element object in a previous set_design_page response)");
    }
    if (std.mem.startsWith(u8, element_id, "item_")) {
        return try errorJSONOwned(allocator, try std.fmt.allocPrint(allocator,
            \\element_id '{s}' looks like an ITEM id (starts with 'item_'). Pass the ELEMENT id instead — find it in the `id` field of an element object in a `set_design_page` response.
        , .{element_id}));
    }
    if (std.mem.startsWith(u8, element_id, "page_")) {
        return try errorJSONOwned(allocator, try std.fmt.allocPrint(allocator,
            \\element_id '{s}' looks like a PAGE id (starts with 'page_'). Pass the ELEMENT id instead.
        , .{element_id}));
    }
    if (!std.mem.startsWith(u8, element_id, "elem_")) {
        return try errorJSONOwned(allocator, try std.fmt.allocPrint(allocator,
            \\element_id '{s}' has an unrecognized prefix (expected 'elem_'). update_element expects an element_id from a previous set_design_page response, not a free-form string.
        , .{element_id}));
    }
    return null;
}

/// Execute the `update_element` tool. Returns a JSON string for the LLM.
pub fn executeUpdateElementToString(
    allocator: std.mem.Allocator,
    db: *sqlite.SqliteBackend,
    input: UpdateElementInput,
) ![]u8 {
    // 0. Input validation (shape only — DB validation runs after).
    if (try validateElementIdShape(allocator, input.element_id)) |e| return e;

    // 1. Parse the optional type string. parseOptionalElementType returns:
    // null → "no change" (string was null) enum value → parsed successfully
    // error.BadTypeString → malformed string (not one of the 6)
    const parsed_type = parseOptionalElementType(allocator, input.type) catch |err| {
        if (err == error.BadTypeString) {
            return try errorJSON(allocator, "type must be one of: rectangle, ellipse, text, image, frame, group");
        }
        return try errorJSONOwned(allocator, try std.fmt.allocPrint(allocator, "DB: parseOptionalElementType failed: {s}", .{@errorName(err)}));
    };

    // 2. Apply the same fill workaround as add_element: empty fill
    //    string would bind as NULL and violate the v6 NOT NULL
    //    constraint on the `fill` column. Substitute "transparent".
    const fill_for_db: ?[]const u8 = if (input.fill) |f| blk: {
        break :blk if (f.len == 0) @as([]const u8, "transparent") else f;
    } else null;

    // 3. Call updateElement. Returns the element_id on success;
    //    returns ElementNotFound if no such row exists.
    const element_id = design_model.updateElement(allocator, db, .{
        .element_id = input.element_id,
        .name = input.name,
        .elem_type = parsed_type,
        .html = input.html,
        .x = input.x,
        .y = input.y,
        .width = input.width,
        .height = input.height,
        .rotation = input.rotation,
        .fill = fill_for_db,
        .stroke = input.stroke,
        .stroke_width = input.stroke_width,
        .corner_radius = input.corner_radius,
        .opacity = input.opacity,
        .text_content = input.text_content,
        .text_style = input.text_style,
        .image_url = input.image_url,
    }) catch |err| switch (err) {
        error.ElementNotFound => return try errorJSON(allocator, "element_id does not match any design element — call set_design_page first"),
        error.FileWriteFailed => return try errorJSON(allocator, "could not write the HTML file to disk (permission denied or out of space)"),
        else => return try errorJSONOwned(allocator, try std.fmt.allocPrint(allocator, "DB: updateElement failed: {s}", .{@errorName(err)})),
    };
    defer allocator.free(element_id);

    // 4. Re-fetch the full element via getElement so the LLM gets
    //    the canonical state (with file_path, timestamps, etc.).
    const elem = design_model.getElement(allocator, db, element_id) catch |err| {
        return try errorJSONOwned(allocator, try std.fmt.allocPrint(allocator, "DB: getElement failed: {s}", .{@errorName(err)}));
    };
    defer design_model.freeElement(allocator, elem);

    return try elementToJSON(allocator, elem);
}

const testing = std.testing;
fn expectJSONFloat(v: std.json.Value, want: f64) !void {
    const got: f64 = switch (v) {
        .float => |f| f,
        .integer => |i| @floatFromInt(i),
        else => return error.NotANumber,
    };
    try testing.expectApproxEqAbs(want, got, 1e-9);
}

fn expectJSONError(alloc: std.mem.Allocator, str: []const u8, needle: []const u8) !void {
    var parsed = try std.json.parseFromSlice(std.json.Value, alloc, str, .{});
    defer parsed.deinit();
    try testing.expect(parsed.value == .object);
    const err_val = parsed.value.object.get("error") orelse return error.MissingErrorField;
    try testing.expect(err_val == .string);
    try testing.expect(contains(err_val.string, needle));
}

fn expectNoJSONError(alloc: std.mem.Allocator, str: []const u8) !std.json.Parsed(std.json.Value) {
    var parsed = try std.json.parseFromSlice(std.json.Value, alloc, str, .{});
    errdefer parsed.deinit();
    try testing.expect(parsed.value == .object);
    try testing.expect(parsed.value.object.get("error") == null);
    return parsed;
}

fn contains(haystack: []const u8, needle: []const u8) bool {
    return std.mem.indexOf(u8, haystack, needle) != null;
}

// ─── JSON serialization ──────────────────────────────────────────────────

test "errorJSON on missing field returns an error object" {
    const alloc = testing.allocator;
    const json = try errorJSON(alloc, "element_id is required");
    defer alloc.free(json);
    try expectJSONError(alloc, json, "element_id is required");
}

// ─── DB integration behavioral tests (in-memory SQLite) ────────────────

/// Set up an in-memory SQLite with the v6 design schema + one page +
/// one rectangle element named "card". Returns the DB handle + the
/// element_id so tests can call update_element on it.
fn setupDbWithElement() !struct {
    db: sqlite.SqliteBackend,
    threaded: std.Io.Threaded,
    item_id: []u8,
    page_id: []u8,
    element_id: []u8,
} {
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
    const tmpdir_path: []const u8 = tmpdir_buf[0..tmpdir_len];

    const item_id_str = "item_design_1";
    try db.exec(alloc, "INSERT INTO workspace_items (id, workspace_id, item_type, name, path) " ++
        "VALUES (?, 'ws_test', 'design', 'Test Design', ?)", &.{ item_id_str, tmpdir_path });

    const page_id_str = "page_test_1";
    try db.exec(alloc, "INSERT INTO design_pages (id, workspace_item_id, name, width, height, position) " ++
        "VALUES (?, ?, 'Login', 1440, 1024, 0)", &.{ page_id_str, item_id_str });

    const element_id_str = "elem_test_1";
    try db.exec(alloc, "INSERT INTO design_page_elements (id, page_id, name, file_path, x, y, width, height, type, fill) " ++
        "VALUES (?, ?, 'card', '/tmp/card.html', 100, 200, 300, 150, 'rectangle', '#ffffff')", &.{ element_id_str, page_id_str });

    return .{
        .db = db,
        .threaded = threaded,
        .item_id = try alloc.dupe(u8, item_id_str),
        .page_id = try alloc.dupe(u8, page_id_str),
        .element_id = try alloc.dupe(u8, element_id_str),
    };
}

test "executeUpdateElementToString updates x and y only" {
    const alloc = testing.allocator;
    var s = try setupDbWithElement();
    defer s.threaded.deinit();
    defer s.db.deinit();
    defer alloc.free(s.item_id);
    defer alloc.free(s.page_id);
    defer alloc.free(s.element_id);

    const input = UpdateElementInput{
        .element_id = s.element_id,
        .x = 250,
        .y = 350,
    };
    const json = try executeUpdateElementToString(alloc, &s.db, input);
    defer alloc.free(json);

    var parsed = try expectNoJSONError(alloc, json);
    defer parsed.deinit();
    const obj = parsed.value.object;
    try testing.expectEqualStrings("elem_test_1", obj.get("id").?.string);
    try testing.expectEqual(@as(i64, 250), obj.get("x").?.integer);
    try testing.expectEqual(@as(i64, 350), obj.get("y").?.integer);
    // Other fields stay unchanged.
    try testing.expectEqual(@as(i64, 300), obj.get("width").?.integer);
    try testing.expectEqual(@as(i64, 150), obj.get("height").?.integer);
    try testing.expectEqualStrings("card", obj.get("name").?.string);
    try testing.expectEqualStrings("rectangle", obj.get("type").?.string);
    try testing.expectEqualStrings("#ffffff", obj.get("fill").?.string);
}

test "executeUpdateElementToString updates fill" {
    const alloc = testing.allocator;
    var s = try setupDbWithElement();
    defer s.threaded.deinit();
    defer s.db.deinit();
    defer alloc.free(s.item_id);
    defer alloc.free(s.page_id);
    defer alloc.free(s.element_id);

    const input = UpdateElementInput{
        .element_id = s.element_id,
        .fill = "#22c55e",
    };
    const json = try executeUpdateElementToString(alloc, &s.db, input);
    defer alloc.free(json);

    var parsed = try expectNoJSONError(alloc, json);
    defer parsed.deinit();
    try testing.expectEqualStrings("#22c55e", parsed.value.object.get("fill").?.string);
}

test "executeUpdateElementToString updates name" {
    const alloc = testing.allocator;
    var s = try setupDbWithElement();
    defer s.threaded.deinit();
    defer s.db.deinit();
    defer alloc.free(s.item_id);
    defer alloc.free(s.page_id);
    defer alloc.free(s.element_id);

    const input = UpdateElementInput{
        .element_id = s.element_id,
        .name = "primary-card",
    };
    const json = try executeUpdateElementToString(alloc, &s.db, input);
    defer alloc.free(json);

    var parsed = try expectNoJSONError(alloc, json);
    defer parsed.deinit();
    try testing.expectEqualStrings("primary-card", parsed.value.object.get("name").?.string);
}

test "executeUpdateElementToString updates type" {
    const alloc = testing.allocator;
    var s = try setupDbWithElement();
    defer s.threaded.deinit();
    defer s.db.deinit();
    defer alloc.free(s.item_id);
    defer alloc.free(s.page_id);
    defer alloc.free(s.element_id);

    const input = UpdateElementInput{
        .element_id = s.element_id,
        .type = "ellipse",
    };
    const json = try executeUpdateElementToString(alloc, &s.db, input);
    defer alloc.free(json);

    var parsed = try expectNoJSONError(alloc, json);
    defer parsed.deinit();
    try testing.expectEqualStrings("ellipse", parsed.value.object.get("type").?.string);
}

test "executeUpdateElementToString returns error JSON on invalid type" {
    const alloc = testing.allocator;
    var s = try setupDbWithElement();
    defer s.threaded.deinit();
    defer s.db.deinit();
    defer alloc.free(s.item_id);
    defer alloc.free(s.page_id);
    defer alloc.free(s.element_id);

    const input = UpdateElementInput{
        .element_id = s.element_id,
        .type = "hexagon",
    };
    const json = try executeUpdateElementToString(alloc, &s.db, input);
    defer alloc.free(json);
    try expectJSONError(alloc, json, "type must be one of");
}

test "executeUpdateElementToString returns error JSON when element_id is empty" {
    const alloc = testing.allocator;
    var s = try setupDbWithElement();
    defer s.threaded.deinit();
    defer s.db.deinit();
    defer alloc.free(s.item_id);
    defer alloc.free(s.page_id);
    defer alloc.free(s.element_id);

    const input = UpdateElementInput{
        .element_id = "",
        .x = 100,
    };
    const json = try executeUpdateElementToString(alloc, &s.db, input);
    defer alloc.free(json);
    try expectJSONError(alloc, json, "element_id");
}

test "executeUpdateElementToString returns error JSON when element_id has wrong prefix" {
    const alloc = testing.allocator;
    var s = try setupDbWithElement();
    defer s.threaded.deinit();
    defer s.db.deinit();
    defer alloc.free(s.item_id);
    defer alloc.free(s.page_id);
    defer alloc.free(s.element_id);

    const input = UpdateElementInput{
        .element_id = "page_1782442554112",
        .x = 100,
    };
    const json = try executeUpdateElementToString(alloc, &s.db, input);
    defer alloc.free(json);
    try expectJSONError(alloc, json, "page_");
}

test "executeUpdateElementToString returns ElementNotFound error when element_id doesn't exist" {
    const alloc = testing.allocator;
    var s = try setupDbWithElement();
    defer s.threaded.deinit();
    defer s.db.deinit();
    defer alloc.free(s.item_id);
    defer alloc.free(s.page_id);
    defer alloc.free(s.element_id);

    const input = UpdateElementInput{
        .element_id = "elem_does_not_exist",
        .x = 100,
    };
    const json = try executeUpdateElementToString(alloc, &s.db, input);
    defer alloc.free(json);
    try expectJSONError(alloc, json, "element_id");
}

test "executeUpdateElementToString with only element_id is a no-op success" {
    // All fields null except element_id → updateElement short-circuits
    // (no SET clauses), but still succeeds and returns the current state.
    const alloc = testing.allocator;
    var s = try setupDbWithElement();
    defer s.threaded.deinit();
    defer s.db.deinit();
    defer alloc.free(s.item_id);
    defer alloc.free(s.page_id);
    defer alloc.free(s.element_id);

    const input = UpdateElementInput{
        .element_id = s.element_id,
    };
    const json = try executeUpdateElementToString(alloc, &s.db, input);
    defer alloc.free(json);
    var parsed = try expectNoJSONError(alloc, json);
    defer parsed.deinit();
    const obj = parsed.value.object;
    try testing.expectEqualStrings("elem_test_1", obj.get("id").?.string);
    // The state is unchanged.
    try testing.expectEqual(@as(i64, 100), obj.get("x").?.integer);
    try testing.expectEqual(@as(i64, 200), obj.get("y").?.integer);
    try testing.expectEqual(@as(i64, 300), obj.get("width").?.integer);
}

test "executeUpdateElementToString updates rotation and opacity" {
    const alloc = testing.allocator;
    var s = try setupDbWithElement();
    defer s.threaded.deinit();
    defer s.db.deinit();
    defer alloc.free(s.item_id);
    defer alloc.free(s.page_id);
    defer alloc.free(s.element_id);

    const input = UpdateElementInput{
        .element_id = s.element_id,
        .rotation = 45.0,
        .opacity = 0.7,
    };
    const json = try executeUpdateElementToString(alloc, &s.db, input);
    defer alloc.free(json);
    var parsed = try expectNoJSONError(alloc, json);
    defer parsed.deinit();
    try expectJSONFloat(parsed.value.object.get("rotation").?, 45.0);
    try expectJSONFloat(parsed.value.object.get("opacity").?, 0.7);
}

// Exec adapter — merged from `update_design_element.zig` (2026-10-14, task_1791993404141_2).
// The tool definition above and its executor below live in ONE file.

const exec_pabrikcore = @import("pabrikcore");
const tools = @import("../../../agentic_loop/tools.zig");
const ToolExecContext = tools.ToolExecContext;
const ToolExecResult = tools.ToolExecResult;
const agent = exec_pabrikcore.agent;
const wrapToolOutput = tools.wrapToolOutput;
const error_explain = @import("tools_error_explain.zig");
pub fn execUpdateElement(ctx: ToolExecContext, tc: agent.ToolCall) !ToolExecResult {
    const parsed = std.json.parseFromSlice(
        UpdateElementInput,
        ctx.allocator,
        tc.function.arguments,
        .{ .allocate = .alloc_always, .ignore_unknown_fields = true },
    ) catch |err| {
        const err_msg = try error_explain.explain(ctx.allocator, err, null);
        defer ctx.allocator.free(err_msg);
        const output = try wrapToolOutput(ctx.allocator, "update_element", tc.function.arguments, false, err_msg, "");
        return ToolExecResult{ .output = output, .output_allocated = true };
    };
    defer parsed.deinit();

    // updateElement doesn't need Io (no mkdir-p required). It uses the
    // existing file_path and rewrites in place. If the file is missing
    // (orphan), it internally looks up the path via JOIN and rebuilds it.
    const inner = executeUpdateElementToString(
        ctx.allocator,
        ctx.db,
        parsed.value,
    ) catch |err| {
        const err_msg = try error_explain.explain(ctx.allocator, err, null);
        defer ctx.allocator.free(err_msg);
        const output = try wrapToolOutput(ctx.allocator, "update_element", tc.function.arguments, false, err_msg, "");
        return ToolExecResult{ .output = output, .output_allocated = true };
    };
    defer ctx.allocator.free(inner);

    // Detect {{"error":...}} and surface it as a tool failure (so the
    // LLM sees `success=false` rather than a successful wrapper around
    // an error body).
    const json_err_msg: ?[]u8 = blk: {
        const inner_parsed = std.json.parseFromSlice(std.json.Value, ctx.allocator, inner, .{}) catch break :blk null;
        defer inner_parsed.deinit();
        if (inner_parsed.value != .object) break :blk null;
        const e = inner_parsed.value.object.get("error") orelse break :blk null;
        if (e != .string) break :blk null;
        break :blk try ctx.allocator.dupe(u8, e.string);
    };
    if (json_err_msg) |err_msg| {
        defer ctx.allocator.free(err_msg);
        const output = try wrapToolOutput(ctx.allocator, "update_element", tc.function.arguments, false, err_msg, inner);
        return ToolExecResult{ .output = output, .output_allocated = true };
    }

    const output = try wrapToolOutput(ctx.allocator, "update_element", tc.function.arguments, true, null, inner);
    return ToolExecResult{ .output = output, .output_allocated = true };
}

