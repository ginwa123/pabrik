//! LLM tool: `set_design_page` — idempotent create/update for a design canvas
//! page.

const std = @import("std");
const schemas = @import("schemas.zig");
const AgentTool = schemas.AgentTool;
const pabrikcore = @import("pabrikcore");
const sqlite = pabrikcore.sqlite;
const design_model = pabrikcore.ai_mod.design_model;
const helpers = @import("helpers");
const sanitizeControlChars = helpers.sanitize_control_chars;

/// Input structure for `set_design_page` tool. The agent passes `item_id`
/// from the active chat context (injected by the frontend via
/// `BuildDesignCanvasPrompt` into the system prompt).
pub const SetDesignPageInput = struct {
    /// The design workspace item id. From the chat's workspace context
    /// (system prompt's `## Workspace Context` section). Always starts
    /// with `item_` and has `item_type = 'design'`.
    item_id: []const u8 = "",
    /// Human-readable page name (e.g. "Login", "Dashboard", "Settings"). Must
    /// be unique within the design item.
    page_name: []const u8 = "",
    /// Page width in CSS pixels. Defaults to 1440 when null.
    width: ?i64 = null,
    /// Page height in CSS pixels. Defaults to 1024 when null.
    height: ?i64 = null,
};

/// Top-level tool definition for the LLM. The description tells the LLM: 1.
pub const set_design_page_tool_system_prompt =
    \\## Set Design Page Tool — Behavior
    \\Use `set_design_page` to create or update a design page (idempotent).
    \\- Returns page + elements (no HTML bodies). Use to ensure a page exists before adding elements.
    \\- Provide `page_id` or create a new page with `name`/`width`/`height`.
    \\
;

pub const set_design_page_tool = AgentTool{
    .type = "function",
    .function = .{
        .name = "set_design_page",
        .description =
        \\Create or update a design page. The call is idempotent: re-issuing the same (`item_id`, `page_name`) replaces that page's `width`/`height` in place (other clients see it via SSE). Every call returns the page WITH all its elements, so it also answers "what exists on this page?".
        \\
        \\`item_id` comes from the `## Workspace Context` section of the system prompt — the entry with `item_type='design'`, marked `*(this task)*` when active. Take the backtick-quoted id after `id: ` (e.g. `item_1782313125505579000`), never the human-readable name.
        \\
        \\`page_name` must be unique per design item and must NOT contain `/` or null bytes. Use clear names: `Login`, `Dashboard`, `Settings`.
        \\
        \\On error: re-check `item_id`; if the item has no path, the user must set one via the AddDesign dialog first — pages cannot be created for an unconfigured item.
        ,
        .parameters = .{
            .type = "object",
            .properties = &.{
                .{
                    .name = "item_id",
                    .type = "string",
                    .description = "The design workspace item id (NOT the name): the backtick-quoted id after `id: ` in the Workspace Context listing (e.g. `item_1782313125505579000`). It has `item_type='design'`.",
                },
                .{
                    .name = "page_name",
                    .type = "string",
                    .description = "Human-readable page name (e.g. 'Login', 'Dashboard'). Must be unique per design item; must NOT contain '/' or null bytes.",
                },
                .{
                    .name = "width",
                    .type = "integer",
                    .description = "Page width in CSS pixels. Optional; defaults to 1440.",
                },
                .{
                    .name = "height",
                    .type = "integer",
                    .description = "Page height in CSS pixels. Optional; defaults to 1024.",
                },
            },
            .required = &.{ "item_id", "page_name" },
        },
        .system_prompt = set_design_page_tool_system_prompt,
    },
};

/// Generate an error JSON object (replaces the old per-tool XML escape +
/// error envelope helpers).
pub fn errorJSON(allocator: std.mem.Allocator, error_msg: []const u8) ![]u8 {
    const clean = try sanitizeControlChars(allocator, error_msg);
    defer allocator.free(clean);
    return try std.json.Stringify.valueAlloc(allocator, .{ .@"error" = clean }, .{});
}

/// Same as `errorJSON` but TAKES OWNERSHIP of `error_msg` and frees it
/// on return. Used to avoid leaks when the caller's message is an
/// `allocPrint` result (can't `defer` across a `return`).
pub fn errorJSONOwned(allocator: std.mem.Allocator, error_msg: []u8) ![]u8 {
    defer allocator.free(error_msg);
    return try errorJSON(allocator, error_msg);
}

/// Detect the two known LLM id-confusion mistakes (task_id or column_id
/// passed where item_id was expected).
pub fn validateItemIdShape(allocator: std.mem.Allocator, item_id: []const u8) !?[]u8 {
    if (item_id.len == 0) {
        return try errorJSON(allocator, "item_id is required (pass the design item's id from the Workspace Context listing)");
    }
    // The DB-generated ids use these prefixes (see workspace_items_create.zig
    // for item_, workspace_item_tasks_create.zig for task_,
    // kanban_model.generateColumnId for col_, workspaces_create.zig for ws_).
    if (std.mem.startsWith(u8, item_id, "task_")) {
        return try errorJSONOwned(allocator, try std.fmt.allocPrint(allocator,
            \\item_id '{s}' looks like a TASK id (starts with 'task_'). Pass the DESIGN's item_id instead — find it next to the literal text `item_id: ` in the Workspace Context listing. The item_id always starts with 'item_'.
        , .{item_id}));
    }
    if (std.mem.startsWith(u8, item_id, "page_")) {
        return try errorJSONOwned(allocator, try std.fmt.allocPrint(allocator,
            \\item_id '{s}' looks like a PAGE id (starts with 'page_'). Pass the DESIGN's item_id instead — find it next to the literal text `item_id: ` in the Workspace Context listing. The item_id always starts with 'item_'.
        , .{item_id}));
    }
    if (std.mem.startsWith(u8, item_id, "elem_")) {
        return try errorJSONOwned(allocator, try std.fmt.allocPrint(allocator,
            \\item_id '{s}' looks like an ELEMENT id (starts with 'elem_'). Pass the DESIGN's item_id instead — find it next to the literal text `item_id: ` in the Workspace Context listing. The item_id always starts with 'item_'.
        , .{item_id}));
    }
    if (std.mem.startsWith(u8, item_id, "ws_")) {
        return try errorJSONOwned(allocator, try std.fmt.allocPrint(allocator,
            \\item_id '{s}' looks like a WORKSPACE id (starts with 'ws_'). You probably swapped workspace_id and item_id. The DESIGN's item_id starts with 'item_' — find it next to the literal text `item_id: ` in the Workspace Context listing.
        , .{item_id}));
    }
    if (!std.mem.startsWith(u8, item_id, "item_")) {
        return try errorJSONOwned(allocator, try std.fmt.allocPrint(allocator,
            \\item_id '{s}' has an unrecognized prefix (expected 'item_'). Workspace-scoped tools expect a design item_id from the Workspace Context listing, not a free-form string.
        , .{item_id}));
    }
    return null;
}

/// Execute the `set_design_page` tool. Returns a JSON string for the LLM.
pub fn executeSetDesignPageToString(
    allocator: std.mem.Allocator,
    db: *sqlite.SqliteBackend,
    input: SetDesignPageInput,
) ![]u8 {
    // 0. Detect the four known LLM id-confusion mistakes. Runs BEFORE
    //    the DB query so the LLM gets a fast, typed error instead of
    //    a silent failure.
    if (try validateItemIdShape(allocator, input.item_id)) |err_xml| {
        return err_xml;
    }

    // 1. Verify the page_name is non-empty and has no illegal characters.
    if (input.page_name.len == 0) {
        return try errorJSON(allocator, "page_name is required");
    }
    if (std.mem.indexOfScalar(u8, input.page_name, '/') != null) {
        return try errorJSON(allocator, "page_name must not contain '/' (it becomes a directory name)");
    }
    if (std.mem.indexOfScalar(u8, input.page_name, 0) != null) {
        return try errorJSON(allocator, "page_name must not contain null bytes");
    }

    // 2. Resolve width/height defaults (1440 × 1024 = v6 standard
    //    design viewport).
    const width = input.width orelse 1440;
    const height = input.height orelse 1024;

    // 3. Idempotent create/update. Returns the page_id of the
    //    existing-or-newly-created page. Errors are surfaced as
    //    structured {"error":...} responses.
    const page_id = design_model.setDesignPage(allocator, db, .{
        .item_id = input.item_id,
        .page_name = input.page_name,
        .width = width,
        .height = height,
    }) catch |err| switch (err) {
        error.ItemPathMissing => return try errorJSON(allocator, "design item has no path; set one via AddDesignDialog"),
        error.BadPageName => return try errorJSON(allocator, "page_name is invalid (empty or contains illegal characters)"),
        else => return try errorJSONOwned(allocator, try std.fmt.allocPrint(allocator, "DB: setDesignPage failed: {s}", .{@errorName(err)})),
    };
    defer allocator.free(page_id);

    // 4. Re-fetch the page + all elements via getPageWithElements
    //    (returns a bundled PageWithElements — single query for the
    //    page, single query for the elements).
    var bundle = design_model.getPageWithElements(allocator, db, page_id) catch |err| {
        return try errorJSONOwned(allocator, try std.fmt.allocPrint(allocator, "DB: getPageWithElements failed: {s}", .{@errorName(err)}));
    };
    defer bundle.deinit(allocator);

    // 5. Render the JSON. The element list omits `html` (the LLM
    //    doesn't need it) and emits the file_path so the LLM knows
    //    where the on-disk content lives.
    return try toJSON(allocator, bundle.page, bundle.elements);
}

/// Serialize a page + its elements to the LLM-facing JSON string. Element
/// shape (per design §6.2 response, keys mirror the old `<element ... />`
/// attributes 1:1; omitted-when-empty attributes become explicit nulls).
pub const PageElementJSON = struct {
    id: []const u8,
    name: []const u8,
    type: []const u8,
    x: i64,
    y: i64,
    width: i64,
    height: i64,
    rotation: f64,
    opacity: f64,
    fill: ?[]const u8,
    stroke: ?[]const u8,
    file_path: ?[]const u8,
    parent_id: ?[]const u8,
};

pub const PageJSON = struct {
    id: []const u8,
    name: []const u8,
    width: i64,
    height: i64,
    position: i64,
    elements: []PageElementJSON,
};

pub fn toJSON(
    allocator: std.mem.Allocator,
    page: design_model.DesignPage,
    elements: []const design_model.DesignElement,
) ![]u8 {
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var out: std.ArrayList(PageElementJSON) = .empty;
    for (elements) |e| {
        try out.append(a, .{
            .id = try sanitizeControlChars(a, e.id),
            .name = try sanitizeControlChars(a, e.name),
            .type = try sanitizeControlChars(a, e.elem_type),
            .x = e.x,
            .y = e.y,
            .width = e.width,
            .height = e.height,
            .rotation = e.rotation,
            .opacity = e.opacity,
            .fill = try optClean(a, e.fill),
            .stroke = try optClean(a, e.stroke),
            .file_path = try optClean(a, e.file_path),
            .parent_id = try optClean(a, e.parent_id),
        });
    }
    return try std.json.Stringify.valueAlloc(allocator, PageJSON{
        .id = try sanitizeControlChars(a, page.id),
        .name = try sanitizeControlChars(a, page.name),
        .width = page.width,
        .height = page.height,
        .position = page.position,
        .elements = out.items,
    }, .{});
}

/// Clean an optional free-text field: empty becomes null, otherwise the
/// control-char-sanitized copy owned by the caller's arena.
fn optClean(allocator: std.mem.Allocator, s: []const u8) !?[]u8 {
    if (s.len == 0) return null;
    return try sanitizeControlChars(allocator, s);
}

const testing = std.testing;
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

// ─── JSON serialization behavioral tests (no DB required) ────────────────

test "toJSON on page with no elements produces an empty elements array" {
    const alloc = testing.allocator;
    const page = design_model.DesignPage{
        .id = try alloc.dupe(u8, "page_abc"),
        .workspace_item_id = try alloc.dupe(u8, "item_test"),
        .name = try alloc.dupe(u8, "Login"),
        .workspace_item_task_id = try alloc.dupe(u8, "task_test"),
        .width = 1440,
        .height = 1024,
        .position = 0,
        .created_at = try alloc.dupe(u8, ""),
        .updated_at = try alloc.dupe(u8, ""),
    };
    defer {
        alloc.free(page.id);
        alloc.free(page.workspace_item_id);
        alloc.free(page.name);
        alloc.free(page.workspace_item_task_id);
        alloc.free(page.created_at);
        alloc.free(page.updated_at);
    }
    const json = try toJSON(alloc, page, &.{});
    defer alloc.free(json);
    var parsed = try expectNoJSONError(alloc, json);
    defer parsed.deinit();
    const obj = parsed.value.object;
    try testing.expectEqualStrings("page_abc", obj.get("id").?.string);
    try testing.expectEqualStrings("Login", obj.get("name").?.string);
    try testing.expectEqual(@as(i64, 1440), obj.get("width").?.integer);
    try testing.expectEqual(@as(i64, 1024), obj.get("height").?.integer);
    try testing.expectEqual(@as(i64, 0), obj.get("position").?.integer);
    // Empty elements slice becomes an empty array.
    try testing.expectEqual(@as(usize, 0), obj.get("elements").?.array.items.len);
}

test "toJSON renders element objects with v6 fields" {
    const alloc = testing.allocator;
    const page = design_model.DesignPage{
        .id = try alloc.dupe(u8, "page_abc"),
        .workspace_item_id = try alloc.dupe(u8, "item_test"),
        .name = try alloc.dupe(u8, "Login"),
        .workspace_item_task_id = try alloc.dupe(u8, "task_test"),
        .width = 1440,
        .height = 1024,
        .position = 0,
        .created_at = try alloc.dupe(u8, ""),
        .updated_at = try alloc.dupe(u8, ""),
    };
    defer {
        alloc.free(page.id);
        alloc.free(page.workspace_item_id);
        alloc.free(page.name);
        alloc.free(page.workspace_item_task_id);
        alloc.free(page.created_at);
        alloc.free(page.updated_at);
    }
    const elem = design_model.DesignElement{
        .id = try alloc.dupe(u8, "elem_xyz"),
        .page_id = try alloc.dupe(u8, "page_abc"),
        .name = try alloc.dupe(u8, "login-card"),
        .file_path = try alloc.dupe(u8, "/tmp/.pabrik/design/Login/login-card.html"),
        .x = 100,
        .y = 200,
        .width = 400,
        .height = 300,
        .z_index = 0,
        .position = 0,
        .elem_type = try alloc.dupe(u8, "rectangle"),
        .rotation = 0.0,
        .fill = try alloc.dupe(u8, "#ffffff"),
        .stroke = try alloc.dupe(u8, ""),
        .stroke_width = 0,
        .corner_radius = 0,
        .opacity = 1.0,
        .text_content = try alloc.dupe(u8, ""),
        .text_style = try alloc.dupe(u8, ""),
        .image_url = try alloc.dupe(u8, ""),
        .parent_id = try alloc.dupe(u8, ""),
        .created_at = try alloc.dupe(u8, ""),
        .updated_at = try alloc.dupe(u8, ""),
    };
    defer design_model.freeElement(alloc, elem);
    const elements = [_]design_model.DesignElement{elem};
    const json = try toJSON(alloc, page, &elements);
    defer alloc.free(json);
    var parsed = try expectNoJSONError(alloc, json);
    defer parsed.deinit();
    const obj = parsed.value.object;
    const els = obj.get("elements").?.array.items;
    try testing.expectEqual(@as(usize, 1), els.len);
    const el = els[0].object;
    try testing.expectEqualStrings("elem_xyz", el.get("id").?.string);
    try testing.expectEqualStrings("login-card", el.get("name").?.string);
    try testing.expectEqualStrings("rectangle", el.get("type").?.string);
    try testing.expectEqual(@as(i64, 100), el.get("x").?.integer);
    try testing.expectEqual(@as(i64, 200), el.get("y").?.integer);
    try testing.expectEqual(@as(i64, 400), el.get("width").?.integer);
    try testing.expectEqual(@as(i64, 300), el.get("height").?.integer);
    try testing.expectEqualStrings("#ffffff", el.get("fill").?.string);
    try testing.expect(el.get("file_path").? != .null);
    try testing.expect(el.get("parent_id").? == .null);
}

test "toJSON renders parent_id for a nested element" {
    const alloc = testing.allocator;
    const page = design_model.DesignPage{
        .id = try alloc.dupe(u8, "page_abc"),
        .workspace_item_id = try alloc.dupe(u8, "item_test"),
        .name = try alloc.dupe(u8, "Login"),
        .workspace_item_task_id = try alloc.dupe(u8, "task_test"),
        .width = 1440,
        .height = 1024,
        .position = 0,
        .created_at = try alloc.dupe(u8, ""),
        .updated_at = try alloc.dupe(u8, ""),
    };
    defer {
        alloc.free(page.id);
        alloc.free(page.workspace_item_id);
        alloc.free(page.name);
        alloc.free(page.workspace_item_task_id);
        alloc.free(page.created_at);
        alloc.free(page.updated_at);
    }
    // A child element parented under elem_parent_1.
    const elem = design_model.DesignElement{
        .id = try alloc.dupe(u8, "elem_child_1"),
        .page_id = try alloc.dupe(u8, "page_abc"),
        .name = try alloc.dupe(u8, "login-button"),
        .file_path = try alloc.dupe(u8, "/tmp/.pabrik/design/Login/login-button.html"),
        .x = 10,
        .y = 20,
        .width = 80,
        .height = 30,
        .z_index = 0,
        .position = 1,
        .elem_type = try alloc.dupe(u8, "rectangle"),
        .rotation = 0.0,
        .fill = try alloc.dupe(u8, "#000000"),
        .stroke = try alloc.dupe(u8, ""),
        .stroke_width = 0,
        .corner_radius = 0,
        .opacity = 1.0,
        .text_content = try alloc.dupe(u8, ""),
        .text_style = try alloc.dupe(u8, ""),
        .image_url = try alloc.dupe(u8, ""),
        .parent_id = try alloc.dupe(u8, "elem_parent_1"),
        .created_at = try alloc.dupe(u8, ""),
        .updated_at = try alloc.dupe(u8, ""),
    };
    defer design_model.freeElement(alloc, elem);
    const elements = [_]design_model.DesignElement{elem};
    const json = try toJSON(alloc, page, &elements);
    defer alloc.free(json);
    var parsed = try expectNoJSONError(alloc, json);
    defer parsed.deinit();
    const els = parsed.value.object.get("elements").?.array.items;
    try testing.expectEqual(@as(usize, 1), els.len);
    try testing.expectEqualStrings("elem_parent_1", els[0].object.get("parent_id").?.string);
}

test "errorJSON on missing field returns an error object" {
    const alloc = testing.allocator;
    const json = try errorJSON(alloc, "item_id is required");
    defer alloc.free(json);
    try expectJSONError(alloc, json, "item_id is required");
}

// ─── DB integration behavioral tests (in-memory SQLite) ────────────────

/// Set up an in-memory SQLite with the v6 design schema (workspace_items +
/// design_pages + design_page_elements with the 11 Migration 057 columns).
fn setupDb() !struct { db: sqlite.SqliteBackend, threaded: std.Io.Threaded, item_id: []u8, item_path: []u8 } {
    const alloc = testing.allocator;
    var threaded = std.Io.Threaded.init(alloc, .{});
    errdefer threaded.deinit();
    const io = threaded.io();
    var db: sqlite.SqliteBackend = .{};
    errdefer db.deinit();
    try db.init(io, ":memory:");

    // workspace_items.
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

    // design_pages (v6 schema).
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

    // design_page_elements (v6 schema).
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

    // Real tempdir for path (setDesignPage needs a non-empty path so
    // its `ItemPathMissing` early-return doesn't fire).
    var tmp = testing.tmpDir(.{});
    var tmpdir_buf: [std.fs.max_path_bytes]u8 = undefined;
    const tmpdir_len = try tmp.dir.realPath(testing.io, &tmpdir_buf);
    const tmpdir_path = try alloc.dupe(u8, tmpdir_buf[0..tmpdir_len]);

    const item_id_str = "item_design_1";
    try db.exec(alloc, "INSERT INTO workspace_items (id, workspace_id, item_type, name, path) " ++
        "VALUES (?, 'ws_test', 'design', 'Test Design', ?)", &.{ item_id_str, tmpdir_path });

    return .{
        .db = db,
        .threaded = threaded,
        .item_id = try alloc.dupe(u8, item_id_str),
        .item_path = tmpdir_path,
    };
}

test "executeSetDesignPageToString creates a page when none exists" {
    const alloc = testing.allocator;
    var s = try setupDb();
    defer s.threaded.deinit();
    defer s.db.deinit();
    defer alloc.free(s.item_id);
    defer alloc.free(s.item_path);

    const input = SetDesignPageInput{
        .item_id = s.item_id,
        .page_name = "Login",
    };
    const json = try executeSetDesignPageToString(alloc, &s.db, input);
    defer alloc.free(json);

    var parsed = try expectNoJSONError(alloc, json);
    defer parsed.deinit();
    const obj = parsed.value.object;
    try testing.expect(std.mem.startsWith(u8, obj.get("id").?.string, "page_"));
    try testing.expectEqualStrings("Login", obj.get("name").?.string);
    try testing.expectEqual(@as(i64, 1440), obj.get("width").?.integer);
    try testing.expectEqual(@as(i64, 1024), obj.get("height").?.integer);
}

test "executeSetDesignPageToString is idempotent on second call with same name" {
    const alloc = testing.allocator;
    var s = try setupDb();
    defer s.threaded.deinit();
    defer s.db.deinit();
    defer alloc.free(s.item_id);
    defer alloc.free(s.item_path);

    const input = SetDesignPageInput{
        .item_id = s.item_id,
        .page_name = "Login",
        .width = 800,
        .height = 600,
    };
    const json1 = try executeSetDesignPageToString(alloc, &s.db, input);
    defer alloc.free(json1);
    var parsed1 = try expectNoJSONError(alloc, json1);
    defer parsed1.deinit();
    try testing.expectEqual(@as(i64, 800), parsed1.value.object.get("width").?.integer);
    try testing.expectEqual(@as(i64, 600), parsed1.value.object.get("height").?.integer);

    // Second call with same name → must reuse the same page id (idempotent
    // upsert via setDesignPage), and pick up the new dimensions.
    const input2 = SetDesignPageInput{
        .item_id = s.item_id,
        .page_name = "Login",
        .width = 1920,
        .height = 1080,
    };
    const json2 = try executeSetDesignPageToString(alloc, &s.db, input2);
    defer alloc.free(json2);
    var parsed2 = try expectNoJSONError(alloc, json2);
    defer parsed2.deinit();
    try testing.expectEqual(@as(i64, 1920), parsed2.value.object.get("width").?.integer);
    try testing.expectEqual(@as(i64, 1080), parsed2.value.object.get("height").?.integer);

    // The page id should be the same between the two calls.
    const id1 = parsed1.value.object.get("id").?.string;
    const id2 = parsed2.value.object.get("id").?.string;
    try testing.expectEqualStrings(id1, id2);
}

test "executeSetDesignPageToString returns error JSON when item_id is empty" {
    const alloc = testing.allocator;
    var s = try setupDb();
    defer s.threaded.deinit();
    defer s.db.deinit();
    defer alloc.free(s.item_id);
    defer alloc.free(s.item_path);

    const input = SetDesignPageInput{
        .item_id = "",
        .page_name = "Login",
    };
    const json = try executeSetDesignPageToString(alloc, &s.db, input);
    defer alloc.free(json);
    try expectJSONError(alloc, json, "item_id");
}

test "executeSetDesignPageToString returns error JSON when item_id looks like a task_id" {
    const alloc = testing.allocator;
    var s = try setupDb();
    defer s.threaded.deinit();
    defer s.db.deinit();
    defer alloc.free(s.item_id);
    defer alloc.free(s.item_path);

    const input = SetDesignPageInput{
        .item_id = "task_1782442569739",
        .page_name = "Login",
    };
    const json = try executeSetDesignPageToString(alloc, &s.db, input);
    defer alloc.free(json);
    try expectJSONError(alloc, json, "task_");
    // Should mention the correct id source so the LLM self-corrects.
    var task_parsed = try std.json.parseFromSlice(std.json.Value, alloc, json, .{});
    defer task_parsed.deinit();
    try testing.expect(contains(task_parsed.value.object.get("error").?.string, "item_"));
}

test "executeSetDesignPageToString returns error JSON when item_id looks like a page_id" {
    const alloc = testing.allocator;
    var s = try setupDb();
    defer s.threaded.deinit();
    defer s.db.deinit();
    defer alloc.free(s.item_id);
    defer alloc.free(s.item_path);

    const input = SetDesignPageInput{
        .item_id = "page_1782442554112",
        .page_name = "Login",
    };
    const json = try executeSetDesignPageToString(alloc, &s.db, input);
    defer alloc.free(json);
    try expectJSONError(alloc, json, "page_");
}

test "executeSetDesignPageToString returns error JSON when item_id looks like an elem_id" {
    const alloc = testing.allocator;
    var s = try setupDb();
    defer s.threaded.deinit();
    defer s.db.deinit();
    defer alloc.free(s.item_id);
    defer alloc.free(s.item_path);

    const input = SetDesignPageInput{
        .item_id = "elem_1782442554112",
        .page_name = "Login",
    };
    const json = try executeSetDesignPageToString(alloc, &s.db, input);
    defer alloc.free(json);
    try expectJSONError(alloc, json, "elem_");
}

test "executeSetDesignPageToString returns error JSON when item_id looks like a workspace_id" {
    const alloc = testing.allocator;
    var s = try setupDb();
    defer s.threaded.deinit();
    defer s.db.deinit();
    defer alloc.free(s.item_id);
    defer alloc.free(s.item_path);

    const input = SetDesignPageInput{
        .item_id = "ws_test",
        .page_name = "Login",
    };
    const json = try executeSetDesignPageToString(alloc, &s.db, input);
    defer alloc.free(json);
    try expectJSONError(alloc, json, "WORKSPACE");
}

test "executeSetDesignPageToString returns error JSON when item_id has unrecognized prefix" {
    const alloc = testing.allocator;
    var s = try setupDb();
    defer s.threaded.deinit();
    defer s.db.deinit();
    defer alloc.free(s.item_id);
    defer alloc.free(s.item_path);

    const input = SetDesignPageInput{
        .item_id = "foo_123",
        .page_name = "Login",
    };
    const json = try executeSetDesignPageToString(alloc, &s.db, input);
    defer alloc.free(json);
    try expectJSONError(alloc, json, "unrecognized");
}

test "executeSetDesignPageToString returns error JSON when page_name is empty" {
    const alloc = testing.allocator;
    var s = try setupDb();
    defer s.threaded.deinit();
    defer s.db.deinit();
    defer alloc.free(s.item_id);
    defer alloc.free(s.item_path);

    const input = SetDesignPageInput{
        .item_id = s.item_id,
        .page_name = "",
    };
    const json = try executeSetDesignPageToString(alloc, &s.db, input);
    defer alloc.free(json);
    try expectJSONError(alloc, json, "page_name");
}

test "executeSetDesignPageToString returns error JSON when page_name contains '/'" {
    const alloc = testing.allocator;
    var s = try setupDb();
    defer s.threaded.deinit();
    defer s.db.deinit();
    defer alloc.free(s.item_id);
    defer alloc.free(s.item_path);

    const input = SetDesignPageInput{
        .item_id = s.item_id,
        .page_name = "Login/Foo",
    };
    const json = try executeSetDesignPageToString(alloc, &s.db, input);
    defer alloc.free(json);
    try expectJSONError(alloc, json, "/");
}

test "executeSetDesignPageToString returns ItemPathMissing error when item has no path" {
    const alloc = testing.allocator;
    var s = try setupDb();
    defer s.threaded.deinit();
    defer s.db.deinit();
    defer alloc.free(s.item_id);
    defer alloc.free(s.item_path);

    // Insert a second design item WITHOUT a path.
    try s.db.exec(alloc, "INSERT INTO workspace_items (id, workspace_id, item_type, name, path) " ++
        "VALUES ('item_no_path', 'ws_test', 'design', 'No path', '')", &.{});

    const input = SetDesignPageInput{
        .item_id = "item_no_path",
        .page_name = "Login",
    };
    const json = try executeSetDesignPageToString(alloc, &s.db, input);
    defer alloc.free(json);
    try expectJSONError(alloc, json, "no path");
    var nopath_parsed = try std.json.parseFromSlice(std.json.Value, alloc, json, .{});
    defer nopath_parsed.deinit();
    try testing.expect(contains(nopath_parsed.value.object.get("error").?.string, "AddDesignDialog"));
}

// Exec adapter — merged from `zig` (2026-10-14, task_1791993404141_2).
// The tool definition above and its executor below live in ONE file.

const exec_pabrikcore = @import("pabrikcore");
const tools = @import("../../../agentic_loop/tools.zig");
const ToolExecContext = tools.ToolExecContext;
const ToolExecResult = tools.ToolExecResult;
const agent = exec_pabrikcore.agent;
const wrapToolOutput = tools.wrapToolOutput;
const error_explain = @import("tools_error_explain.zig");
pub fn execSetDesignPage(ctx: ToolExecContext, tc: agent.ToolCall) !ToolExecResult {
    const parsed = std.json.parseFromSlice(
        SetDesignPageInput,
        ctx.allocator,
        tc.function.arguments,
        .{ .allocate = .alloc_always, .ignore_unknown_fields = true },
    ) catch |err| {
        const err_msg = try error_explain.explain(ctx.allocator, err, null);
        defer ctx.allocator.free(err_msg);
        const output = try wrapToolOutput(ctx.allocator, "set_design_page", tc.function.arguments, false, err_msg, "");
        return ToolExecResult{ .output = output, .output_allocated = true };
    };
    defer parsed.deinit();

    // executeSetDesignPageToString returns a JSON string. Errors are
    // encoded as {"error":...</error></page> so the LLM sees a
    // structured failure rather than a tool crash.
    const inner = executeSetDesignPageToString(
        ctx.allocator,
        ctx.db,
        parsed.value,
    ) catch |err| {
        const err_msg = try error_explain.explain(ctx.allocator, err, null);
        defer ctx.allocator.free(err_msg);
        const output = try wrapToolOutput(ctx.allocator, "set_design_page", tc.function.arguments, false, err_msg, "");
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
        const output = try wrapToolOutput(ctx.allocator, "set_design_page", tc.function.arguments, false, err_msg, inner);
        return ToolExecResult{ .output = output, .output_allocated = true };
    }

    const output = try wrapToolOutput(ctx.allocator, "set_design_page", tc.function.arguments, true, null, inner);
    return ToolExecResult{ .output = output, .output_allocated = true };
}

