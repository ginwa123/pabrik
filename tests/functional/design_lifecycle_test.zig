// Functional tests for design mode lifecycle. Zig port of
// `tests/functional/design_lifecycle_test.py` (same test names, same order).

const std = @import("std");
const testing = std.testing;
const harness = @import("harness.zig");
const Harness = harness.Harness;
const gpa = testing.allocator;
const io = testing.io;

// ============================================================================
// Helpers — HTTP
// ============================================================================

fn boot() !Harness {
    return Harness.boot(io, gpa, .{});
}

fn createWorkspace(h: *Harness, name: []const u8) ![]u8 {
    const body = try std.fmt.allocPrint(gpa, "{{\"name\":{f}}}", .{std.json.fmt(name, .{})});
    defer gpa.free(body);
    var r = try h.http(io, .POST, "/api/workspaces", .{ .json_body = body, .expect = &.{201} });
    defer r.deinit();
    var doc = try r.json();
    defer doc.deinit();
    return gpa.dupe(u8, doc.str("id") orelse {
        std.debug.print("POST /api/workspaces returned no `id`\n", .{});
        return error.TestUnexpectedResult;
    });
}

/// `POST .../items/design` → the new design item's id (owned).
fn createDesign(h: *Harness, ws_id: []const u8, name: []const u8, path: []const u8) ![]u8 {
    const body = try std.fmt.allocPrint(
        gpa,
        "{{\"name\":{f},\"path\":{f}}}",
        .{ std.json.fmt(name, .{}), std.json.fmt(path, .{}) },
    );
    defer gpa.free(body);
    const url = try std.fmt.allocPrint(gpa, "/api/workspaces/{s}/items/design", .{ws_id});
    defer gpa.free(url);

    var r = try h.http(io, .POST, url, .{ .json_body = body, .expect = &.{201} });
    defer r.deinit();
    var doc = try r.json();
    defer doc.deinit();
    const item_type = doc.str("item_type") orelse {
        std.debug.print("design create response has no `item_type`\n", .{});
        return error.TestUnexpectedResult;
    };
    if (!std.mem.eql(u8, item_type, "design")) {
        std.debug.print("expected item_type=design, got \"{s}\"\n", .{item_type});
        return error.TestUnexpectedResult;
    }
    return gpa.dupe(u8, doc.str("id") orelse {
        std.debug.print("design create response has no `id`\n", .{});
        return error.TestUnexpectedResult;
    });
}

fn createPage(
    h: *Harness,
    ws_id: []const u8,
    design_id: []const u8,
    name: []const u8,
    width: i64,
    height: i64,
) ![]u8 {
    const body = try std.fmt.allocPrint(
        gpa,
        "{{\"name\":{f},\"width\":{d},\"height\":{d}}}",
        .{ std.json.fmt(name, .{}), width, height },
    );
    defer gpa.free(body);
    const url = try std.fmt.allocPrint(
        gpa,
        "/api/workspaces/{s}/items/{s}/design/pages",
        .{ ws_id, design_id },
    );
    defer gpa.free(url);

    var r = try h.http(io, .POST, url, .{ .json_body = body, .expect = &.{201} });
    defer r.deinit();
    var doc = try r.json();
    defer doc.deinit();
    return gpa.dupe(u8, doc.str("id") orelse {
        std.debug.print("design page create response has no `id`\n", .{});
        return error.TestUnexpectedResult;
    });
}

/// The body for `POST .../elements`.
const ElementSpec = struct {
    name: []const u8,
    element_type: []const u8,
    html: []const u8,
    /// null → the `#000000` default the Python `_add_element` injected.
    fill: ?[]const u8 = null,
    x: ?i64 = null,
    y: ?i64 = null,
    width: ?i64 = null,
    height: ?i64 = null,
};

fn elementBody(spec: ElementSpec) ![]u8 {
    var out: std.Io.Writer.Allocating = .init(gpa);
    errdefer out.deinit();
    const w = &out.writer;

    try w.writeAll("{\"name\":");
    try std.json.Stringify.encodeJsonString(spec.name, .{}, w);
    try w.writeAll(",\"type\":");
    try std.json.Stringify.encodeJsonString(spec.element_type, .{}, w);
    try w.writeAll(",\"html\":");
    try std.json.Stringify.encodeJsonString(spec.html, .{}, w);
    try w.writeAll(",\"fill\":");
    try std.json.Stringify.encodeJsonString(spec.fill orelse "#000000", .{}, w);
    if (spec.x) |v| try w.print(",\"x\":{d}", .{v});
    if (spec.y) |v| try w.print(",\"y\":{d}", .{v});
    if (spec.width) |v| try w.print(",\"width\":{d}", .{v});
    if (spec.height) |v| try w.print(",\"height\":{d}", .{v});
    try w.writeAll("}");
    return out.toOwnedSlice();
}

/// `POST .../elements` → the new element's id (owned).
fn addElement(
    h: *Harness,
    ws_id: []const u8,
    design_id: []const u8,
    page_id: []const u8,
    spec: ElementSpec,
) ![]u8 {
    const body = try elementBody(spec);
    defer gpa.free(body);
    const url = try std.fmt.allocPrint(
        gpa,
        "/api/workspaces/{s}/items/{s}/design/pages/{s}/elements",
        .{ ws_id, design_id, page_id },
    );
    defer gpa.free(url);

    var r = try h.http(io, .POST, url, .{ .json_body = body, .expect = &.{201} });
    defer r.deinit();
    var doc = try r.json();
    defer doc.deinit();
    return gpa.dupe(u8, doc.str("id") orelse {
        std.debug.print("element create response has no `id`\n", .{});
        return error.TestUnexpectedResult;
    });
}

/// `GET .../elements/:eid/html` → the stored HTML body (owned).
fn getElementHtml(
    h: *Harness,
    ws_id: []const u8,
    design_id: []const u8,
    page_id: []const u8,
    element_id: []const u8,
) ![]u8 {
    const url = try std.fmt.allocPrint(
        gpa,
        "/api/workspaces/{s}/items/{s}/design/pages/{s}/elements/{s}/html",
        .{ ws_id, design_id, page_id, element_id },
    );
    defer gpa.free(url);

    var r = try h.http(io, .GET, url, .{ .expect = &.{200} });
    defer r.deinit();
    var doc = try r.json();
    defer doc.deinit();
    return gpa.dupe(u8, doc.str("html") orelse {
        std.debug.print("GET .../html response has no `html` string\n", .{});
        return error.TestUnexpectedResult;
    });
}

/// `GET .../design/pages/:pid` → an OWNED document. `.alloc_always`, because
/// the caller navigates it long after the `Response` body buffer is gone — a
/// `harness.Json` borrows and cannot cross that boundary.
fn getPage(h: *Harness, ws_id: []const u8, design_id: []const u8, page_id: []const u8) !std.json.Parsed(std.json.Value) {
    const url = try std.fmt.allocPrint(
        gpa,
        "/api/workspaces/{s}/items/{s}/design/pages/{s}",
        .{ ws_id, design_id, page_id },
    );
    defer gpa.free(url);
    var r = try h.http(io, .GET, url, .{ .expect = &.{200} });
    defer r.deinit();
    return std.json.parseFromSlice(std.json.Value, gpa, r.body, .{ .allocate = .alloc_always });
}

/// The `elements` array of a fetched page.
fn pageElements(page: *const std.json.Parsed(std.json.Value)) []const std.json.Value {
    const obj = switch (page.value) {
        .object => |o| o,
        else => return &.{},
    };
    const v = obj.get("elements") orelse return &.{};
    return switch (v) {
        .array => |a| a.items,
        else => &.{},
    };
}

fn objectId(v: std.json.Value) ?[]const u8 {
    const o = switch (v) {
        .object => |oo| oo,
        else => return null,
    };
    return switch (o.get("id") orelse std.json.Value{ .null = {} }) {
        .string => |s| s,
        else => null,
    };
}

// ============================================================================
// Helpers — filesystem
// ============================================================================

/// `<item_path>/.pabrik/design/<page_name>` — the directory a page's
/// element HTML files live in.
fn pageDir(item_path: []const u8, page_name: []const u8) ![]u8 {
    return harness.harnessPath(gpa, item_path, &.{ ".pabrik", "design", page_name });
}

fn dirExists(path: []const u8) bool {
    var d = std.Io.Dir.cwd().openDir(io, path, .{}) catch return false;
    d.close(io);
    return true;
}

/// The `*.html` files directly inside `dir`, as owned absolute paths, sorted
/// by name (directory order is not defined, and the Python assertions index
/// `candidates[0]`).
fn listHtmlFiles(dir: []const u8) ![][]const u8 {
    var out: std.ArrayList([]const u8) = .empty;
    errdefer {
        for (out.items) |p| gpa.free(p);
        out.deinit(gpa);
    }
    var d = std.Io.Dir.cwd().openDir(io, dir, .{ .iterate = true }) catch |err| switch (err) {
        error.FileNotFound => return out.toOwnedSlice(gpa),
        else => return err,
    };
    defer d.close(io);

    var it = d.iterate();
    while (try it.next(io)) |entry| {
        if (!std.mem.endsWith(u8, entry.name, ".html")) continue;
        try out.append(gpa, try std.fs.path.join(gpa, &.{ dir, entry.name }));
    }
    // Deterministic order: sort by the basename, which is unique per dir.
    var i: usize = 1;
    while (i < out.items.len) : (i += 1) {
        var j = i;
        while (j > 0 and std.mem.order(u8, std.fs.path.basename(out.items[j - 1]), std.fs.path.basename(out.items[j])) == .gt) : (j -= 1) {
            std.mem.swap([]const u8, &out.items[j - 1], &out.items[j]);
        }
    }
    return out.toOwnedSlice(gpa);
}

fn freePaths(paths: [][]const u8) void {
    for (paths) |p| gpa.free(p);
    gpa.free(paths);
}

fn readTextFile(path: []const u8) ![]u8 {
    return std.Io.Dir.cwd().readFileAlloc(io, path, gpa, .limited(1 << 20));
}

// ============================================================================
// Test 1: design item create requires path
// ============================================================================

// POST /items/design without a path returns 400 with an `error` key.
test "create_design_item_requires_path" {
    try harness.requirePabrikBin(io, gpa);
    var h = try boot();
    defer h.deinit(io) catch |err| {
        std.debug.print("teardown: {s}\n", .{@errorName(err)});
    };

    const ws_id = try createWorkspace(&h, "design-ws");
    defer gpa.free(ws_id);
    const url = try std.fmt.allocPrint(gpa, "/api/workspaces/{s}/items/design", .{ws_id});
    defer gpa.free(url);

    var r = try h.http(io, .POST, url, .{
        .json_body = "{\"name\":\"no-path\"}",
        .expect = &.{400},
    });
    defer r.deinit();
    var doc = try r.json();
    defer doc.deinit();
    if (doc.get("error") == null) {
        std.debug.print("400 response has no `error` key\n", .{});
        return error.TestUnexpectedResult;
    }
}

// ============================================================================
// Test 2: create page with 3 elements
// ============================================================================

// Create page + 3 elements; get-page returns 3 elements with those ids.
test "create_page_with_three_elements" {
    try harness.requirePabrikBin(io, gpa);
    var h = try boot();
    defer h.deinit(io) catch |err| {
        std.debug.print("teardown: {s}\n", .{@errorName(err)});
    };

    const scratch = try harness.makeScratchDir(gpa);
    defer gpa.free(scratch);
    defer harness.cleanupExtraDir(io, gpa, scratch);

    const ws_id = try createWorkspace(&h, "design-ws");
    defer gpa.free(ws_id);
    const design_id = try createDesign(&h, ws_id, "design-1", scratch);
    defer gpa.free(design_id);
    const page_id = try createPage(&h, ws_id, design_id, "Login", 1440, 1024);
    defer gpa.free(page_id);

    const e1 = try addElement(&h, ws_id, design_id, page_id, .{
        .name = "rect",
        .element_type = "rectangle",
        .html = "<div>R</div>",
        .x = 10,
        .y = 20,
        .width = 100,
        .height = 50,
        .fill = "#3b82f6",
    });
    defer gpa.free(e1);
    const e2 = try addElement(&h, ws_id, design_id, page_id, .{
        .name = "text",
        .element_type = "text",
        .html = "<p>Hello</p>",
        .x = 10,
        .y = 80,
        .width = 200,
        .height = 30,
        .fill = "#000000",
    });
    defer gpa.free(e2);
    const e3 = try addElement(&h, ws_id, design_id, page_id, .{
        .name = "ellipse",
        .element_type = "ellipse",
        .html = "<div>E</div>",
        .x = 300,
        .y = 200,
        .width = 80,
        .height = 80,
        .fill = "#22c55e",
    });
    defer gpa.free(e3);

    var page = try getPage(&h, ws_id, design_id, page_id);
    defer page.deinit();
    const elements = pageElements(&page);
    if (elements.len != 3) {
        std.debug.print("expected 3 elements, got {d}\n", .{elements.len});
        return error.TestUnexpectedResult;
    }
    for ([_][]const u8{ e1, e2, e3 }) |want| {
        var found = false;
        for (elements) |e| {
            const id = objectId(e) orelse continue;
            if (std.mem.eql(u8, id, want)) found = true;
        }
        if (!found) {
            std.debug.print("element {s} missing from get-page\n", .{want});
            return error.TestUnexpectedResult;
        }
    }
}

// ============================================================================
// Test 3: element HTML file is written to disk
// ============================================================================

// POST /elements writes the HTML to <path>/.pabrik/design/<page>/<elem>.html.
test "element_html_file_written_to_disk" {
    try harness.requirePabrikBin(io, gpa);
    var h = try boot();
    defer h.deinit(io) catch |err| {
        std.debug.print("teardown: {s}\n", .{@errorName(err)});
    };

    const scratch = try harness.makeScratchDir(gpa);
    defer gpa.free(scratch);
    defer harness.cleanupExtraDir(io, gpa, scratch);

    const ws_id = try createWorkspace(&h, "design-ws");
    defer gpa.free(ws_id);
    const design_id = try createDesign(&h, ws_id, "disk-test", scratch);
    defer gpa.free(design_id);
    const page_id = try createPage(&h, ws_id, design_id, "Disk", 1440, 1024);
    defer gpa.free(page_id);

    const html = "<div class='hero' style='background: #3b82f6'>Hello, design!</div>";
    const elem_id = try addElement(&h, ws_id, design_id, page_id, .{
        .name = "hero",
        .element_type = "rectangle",
        .html = html,
    });
    defer gpa.free(elem_id);

    const dir = try pageDir(scratch, "Disk");
    defer gpa.free(dir);
    const candidates = try listHtmlFiles(dir);
    defer freePaths(candidates);
    if (candidates.len < 1) {
        std.debug.print("no .html files found in {s}/\n", .{dir});
        return error.TestUnexpectedResult;
    }

    const file_content = try readTextFile(candidates[0]);
    defer gpa.free(file_content);
    if (!std.mem.eql(u8, file_content, html)) {
        std.debug.print("file content mismatch: expected {s}, got {s}\n", .{ html, file_content });
        return error.TestUnexpectedResult;
    }
}

// ============================================================================
// Test 4: update HTML atomically rewrites the file
// ============================================================================

// PUT /elements/:eid with new html rewrites the on-disk file in place.
test "update_html_atomically_rewrites_file" {
    try harness.requirePabrikBin(io, gpa);
    var h = try boot();
    defer h.deinit(io) catch |err| {
        std.debug.print("teardown: {s}\n", .{@errorName(err)});
    };

    const scratch = try harness.makeScratchDir(gpa);
    defer gpa.free(scratch);
    defer harness.cleanupExtraDir(io, gpa, scratch);

    const ws_id = try createWorkspace(&h, "design-ws");
    defer gpa.free(ws_id);
    const design_id = try createDesign(&h, ws_id, "rewrite-test", scratch);
    defer gpa.free(design_id);
    const page_id = try createPage(&h, ws_id, design_id, "Page", 1440, 1024);
    defer gpa.free(page_id);

    const initial_html = "<div>original</div>";
    const elem_id = try addElement(&h, ws_id, design_id, page_id, .{
        .name = "elem",
        .element_type = "rectangle",
        .html = initial_html,
    });
    defer gpa.free(elem_id);

    const dir = try pageDir(scratch, "Page");
    defer gpa.free(dir);
    {
        const files = try listHtmlFiles(dir);
        defer freePaths(files);
        if (files.len != 1) {
            std.debug.print("expected exactly 1 html file, got {d}\n", .{files.len});
            return error.TestUnexpectedResult;
        }
        const before = try readTextFile(files[0]);
        defer gpa.free(before);
        if (!std.mem.eql(u8, before, initial_html)) {
            std.debug.print("initial file content mismatch: {s}\n", .{before});
            return error.TestUnexpectedResult;
        }
    }

    // Update the HTML via PUT /elements/:eid.
    const new_html = "<div>updated content with more text</div>";
    const update_url = try std.fmt.allocPrint(
        gpa,
        "/api/workspaces/{s}/items/{s}/design/pages/{s}/elements/{s}",
        .{ ws_id, design_id, page_id, elem_id },
    );
    defer gpa.free(update_url);
    const body = try std.fmt.allocPrint(gpa, "{{\"html\":{f}}}", .{std.json.fmt(new_html, .{})});
    defer gpa.free(body);
    {
        var r = try h.http(io, .PUT, update_url, .{ .json_body = body, .expect = &.{200} });
        r.deinit();
    }

    // The file is now the new content — an atomic rewrite leaves no
    // leftover second file.
    const files_after = try listHtmlFiles(dir);
    defer freePaths(files_after);
    if (files_after.len != 1) {
        std.debug.print("expected 1 file after rewrite, got {d}\n", .{files_after.len});
        return error.TestUnexpectedResult;
    }
    const after = try readTextFile(files_after[0]);
    defer gpa.free(after);
    if (!std.mem.eql(u8, after, new_html)) {
        std.debug.print("file not atomically rewritten: {s}\n", .{after});
        return error.TestUnexpectedResult;
    }
}

// ============================================================================
// Test 5: geometry PATCH does not touch the HTML file
// ============================================================================

// PATCH /geometry only updates x/y/width/height; the HTML file is byte-equal
// afterwards.
test "geometry_patch_does_not_touch_html" {
    try harness.requirePabrikBin(io, gpa);
    var h = try boot();
    defer h.deinit(io) catch |err| {
        std.debug.print("teardown: {s}\n", .{@errorName(err)});
    };

    const scratch = try harness.makeScratchDir(gpa);
    defer gpa.free(scratch);
    defer harness.cleanupExtraDir(io, gpa, scratch);

    const ws_id = try createWorkspace(&h, "design-ws");
    defer gpa.free(ws_id);
    const design_id = try createDesign(&h, ws_id, "geom-test", scratch);
    defer gpa.free(design_id);
    const page_id = try createPage(&h, ws_id, design_id, "Geom", 1440, 1024);
    defer gpa.free(page_id);

    const html = "<div class='card' data-id='42'>preserved</div>";
    const elem_id = try addElement(&h, ws_id, design_id, page_id, .{
        .name = "card",
        .element_type = "rectangle",
        .html = html,
    });
    defer gpa.free(elem_id);

    const dir = try pageDir(scratch, "Geom");
    defer gpa.free(dir);
    const files = try listHtmlFiles(dir);
    defer freePaths(files);
    if (files.len != 1) {
        std.debug.print("expected exactly 1 html file, got {d}\n", .{files.len});
        return error.TestUnexpectedResult;
    }
    const file_path = files[0];
    const content_before = try readTextFile(file_path);
    defer gpa.free(content_before);

    // PATCH geometry (move + resize).
    const geom_url = try std.fmt.allocPrint(
        gpa,
        "/api/workspaces/{s}/items/{s}/design/pages/{s}/elements/{s}/geometry",
        .{ ws_id, design_id, page_id, elem_id },
    );
    defer gpa.free(geom_url);
    {
        var r = try h.http(io, .PATCH, geom_url, .{
            .json_body = "{\"x\":999,\"y\":888,\"width\":1234,\"height\":567}",
            .expect = &.{200},
        });
        r.deinit();
    }

    const content_after = try readTextFile(file_path);
    defer gpa.free(content_after);
    if (!std.mem.eql(u8, content_after, content_before)) {
        std.debug.print(
            "geometry PATCH must not modify the HTML file: before={s} after={s}\n",
            .{ content_before, content_after },
        );
        return error.TestUnexpectedResult;
    }
}

// ============================================================================
// Test 6: delete element removes the HTML file
// ============================================================================

// DELETE /elements/:eid removes the on-disk HTML file.
test "delete_element_removes_html_file" {
    try harness.requirePabrikBin(io, gpa);
    var h = try boot();
    defer h.deinit(io) catch |err| {
        std.debug.print("teardown: {s}\n", .{@errorName(err)});
    };

    const scratch = try harness.makeScratchDir(gpa);
    defer gpa.free(scratch);
    defer harness.cleanupExtraDir(io, gpa, scratch);

    const ws_id = try createWorkspace(&h, "design-ws");
    defer gpa.free(ws_id);
    const design_id = try createDesign(&h, ws_id, "delete-test", scratch);
    defer gpa.free(design_id);
    const page_id = try createPage(&h, ws_id, design_id, "Page", 1440, 1024);
    defer gpa.free(page_id);

    const elem_id = try addElement(&h, ws_id, design_id, page_id, .{
        .name = "doomed",
        .element_type = "rectangle",
        .html = "<div>x</div>",
    });
    defer gpa.free(elem_id);

    const dir = try pageDir(scratch, "Page");
    defer gpa.free(dir);
    {
        const files = try listHtmlFiles(dir);
        defer freePaths(files);
        if (files.len != 1) {
            std.debug.print("expected exactly 1 html file, got {d}\n", .{files.len});
            return error.TestUnexpectedResult;
        }
    }

    const del_url = try std.fmt.allocPrint(
        gpa,
        "/api/workspaces/{s}/items/{s}/design/pages/{s}/elements/{s}",
        .{ ws_id, design_id, page_id, elem_id },
    );
    defer gpa.free(del_url);
    {
        var r = try h.http(io, .DELETE, del_url, .{ .expect = &.{200} });
        r.deinit();
    }

    const files_after = try listHtmlFiles(dir);
    defer freePaths(files_after);
    if (files_after.len != 0) {
        std.debug.print("HTML file not removed after element delete: {d} left\n", .{files_after.len});
        return error.TestUnexpectedResult;
    }
}

// ============================================================================
// Test 7: delete page removes the entire directory
// ============================================================================

// DELETE /pages/:pid removes <page_dir>/ and all its contents.
test "delete_page_removes_entire_directory" {
    try harness.requirePabrikBin(io, gpa);
    var h = try boot();
    defer h.deinit(io) catch |err| {
        std.debug.print("teardown: {s}\n", .{@errorName(err)});
    };

    const scratch = try harness.makeScratchDir(gpa);
    defer gpa.free(scratch);
    defer harness.cleanupExtraDir(io, gpa, scratch);

    const ws_id = try createWorkspace(&h, "design-ws");
    defer gpa.free(ws_id);
    const design_id = try createDesign(&h, ws_id, "page-del-test", scratch);
    defer gpa.free(design_id);
    const page_id = try createPage(&h, ws_id, design_id, "DoomedPage", 1440, 1024);
    defer gpa.free(page_id);

    // Add 2 elements.
    {
        const a = try addElement(&h, ws_id, design_id, page_id, .{
            .name = "a",
            .element_type = "rectangle",
            .html = "<div>A</div>",
        });
        defer gpa.free(a);
    }
    {
        const b = try addElement(&h, ws_id, design_id, page_id, .{
            .name = "b",
            .element_type = "rectangle",
            .html = "<div>B</div>",
        });
        defer gpa.free(b);
    }

    const dir = try pageDir(scratch, "DoomedPage");
    defer gpa.free(dir);
    if (!dirExists(dir)) {
        std.debug.print("page directory {s} does not exist before delete\n", .{dir});
        return error.TestUnexpectedResult;
    }
    {
        const files = try listHtmlFiles(dir);
        defer freePaths(files);
        if (files.len != 2) {
            std.debug.print("expected 2 html files before delete, got {d}\n", .{files.len});
            return error.TestUnexpectedResult;
        }
    }

    const del_url = try std.fmt.allocPrint(
        gpa,
        "/api/workspaces/{s}/items/{s}/design/pages/{s}",
        .{ ws_id, design_id, page_id },
    );
    defer gpa.free(del_url);
    {
        var r = try h.http(io, .DELETE, del_url, .{ .expect = &.{200} });
        r.deinit();
    }

    if (dirExists(dir)) {
        std.debug.print("page directory {s} not removed after page delete\n", .{dir});
        return error.TestUnexpectedResult;
    }
}

// ============================================================================
// Test 8: get html returns stored content
// ============================================================================

// GET /html returns the body byte-equal to what was POSTed, across five
// shapes of HTML (simple, newlines, double quotes, unicode, backslashes).
test "get_html_returns_stored_content" {
    try harness.requirePabrikBin(io, gpa);
    var h = try boot();
    defer h.deinit(io) catch |err| {
        std.debug.print("teardown: {s}\n", .{@errorName(err)});
    };

    const scratch = try harness.makeScratchDir(gpa);
    defer gpa.free(scratch);
    defer harness.cleanupExtraDir(io, gpa, scratch);

    const ws_id = try createWorkspace(&h, "design-ws");
    defer gpa.free(ws_id);
    const design_id = try createDesign(&h, ws_id, "html-test", scratch);
    defer gpa.free(design_id);
    const page_id = try createPage(&h, ws_id, design_id, "Page", 1440, 1024);
    defer gpa.free(page_id);

    const HtmlCase = struct { name: []const u8, html: []const u8 };
    const html_cases = [_]HtmlCase{
        .{ .name = "simple", .html = "<p>hello</p>" },
        .{ .name = "with-newlines", .html = "line1\nline2\nline3" },
        .{ .name = "with-quotes", .html = "<div class=\"foo\" data-x=\"42\">\"quoted\"</div>" },
        .{ .name = "with-unicode", .html = "<p>こんにちは 🌍 αβγ</p>" },
        .{ .name = "with-backslashes", .html = "<div>path = C:\\Users\\foo</div>" },
    };
    for (html_cases) |c| {
        const elem_id = try addElement(&h, ws_id, design_id, page_id, .{
            .name = c.name,
            .element_type = "rectangle",
            .html = c.html,
        });
        defer gpa.free(elem_id);
        const fetched = try getElementHtml(&h, ws_id, design_id, page_id, elem_id);
        defer gpa.free(fetched);
        if (!std.mem.eql(u8, fetched, c.html)) {
            const sent = harness.debugString(gpa, c.html) catch "";
            defer if (sent.len > 0) gpa.free(sent);
            const got = harness.debugString(gpa, fetched) catch "";
            defer if (got.len > 0) gpa.free(got);
            std.debug.print("HTML round-trip mismatch for {s}: sent {s}, got {s}\n", .{ c.name, sent, got });
            return error.TestUnexpectedResult;
        }
    }
}

// ============================================================================
// Test 9: design pages list groups by item
// ============================================================================

// 2 design items × 2 pages each; each item's list returns only its own 2.
test "design_pages_list_groups_by_item" {
    try harness.requirePabrikBin(io, gpa);
    var h = try boot();
    defer h.deinit(io) catch |err| {
        std.debug.print("teardown: {s}\n", .{@errorName(err)});
    };

    const scratch = try harness.makeScratchDir(gpa);
    defer gpa.free(scratch);
    defer harness.cleanupExtraDir(io, gpa, scratch);
    const path_a = try harness.harnessPath(gpa, scratch, &.{"a"});
    defer gpa.free(path_a);
    const path_b = try harness.harnessPath(gpa, scratch, &.{"b"});
    defer gpa.free(path_b);

    const ws_id = try createWorkspace(&h, "design-ws");
    defer gpa.free(ws_id);
    const design_a = try createDesign(&h, ws_id, "design-a", path_a);
    defer gpa.free(design_a);
    const design_b = try createDesign(&h, ws_id, "design-b", path_b);
    defer gpa.free(design_b);

    // 2 pages on each.
    const p_a1 = try createPage(&h, ws_id, design_a, "A1", 1440, 1024);
    defer gpa.free(p_a1);
    const p_a2 = try createPage(&h, ws_id, design_a, "A2", 1440, 1024);
    defer gpa.free(p_a2);
    const p_b1 = try createPage(&h, ws_id, design_b, "B1", 1440, 1024);
    defer gpa.free(p_b1);
    const p_b2 = try createPage(&h, ws_id, design_b, "B2", 1440, 1024);
    defer gpa.free(p_b2);

    const a_pages = try listPageIds(&h, ws_id, design_a);
    defer freeIds(a_pages);
    try expectExactly(a_pages, &.{ p_a1, p_a2 }, "design_a page list");

    const b_pages = try listPageIds(&h, ws_id, design_b);
    defer freeIds(b_pages);
    try expectExactly(b_pages, &.{ p_b1, p_b2 }, "design_b page list");

    // No cross-leakage.
    for (a_pages) |pid| {
        for (b_pages) |qid| {
            if (std.mem.eql(u8, pid, qid)) {
                std.debug.print("page lists overlap on {s}\n", .{pid});
                return error.TestUnexpectedResult;
            }
        }
    }
}

/// `GET .../design/pages` → the page ids (owned, wire order).
fn listPageIds(h: *Harness, ws_id: []const u8, design_id: []const u8) ![][]const u8 {
    const url = try std.fmt.allocPrint(
        gpa,
        "/api/workspaces/{s}/items/{s}/design/pages",
        .{ ws_id, design_id },
    );
    defer gpa.free(url);
    var r = try h.http(io, .GET, url, .{ .expect = &.{200} });
    defer r.deinit();
    var doc = try r.json();
    defer doc.deinit();
    const arr = doc.array("pages") orelse {
        std.debug.print("design pages list has no `pages` array\n", .{});
        return error.TestUnexpectedResult;
    };
    var out: std.ArrayList([]const u8) = .empty;
    errdefer {
        for (out.items) |s| gpa.free(s);
        out.deinit(gpa);
    }
    for (arr.items) |item| {
        const id = objectId(item) orelse {
            std.debug.print("design page entry has no string `id`\n", .{});
            return error.TestUnexpectedResult;
        };
        try out.append(gpa, try gpa.dupe(u8, id));
    }
    return out.toOwnedSlice(gpa);
}

fn freeIds(ids: [][]const u8) void {
    for (ids) |s| gpa.free(s);
    gpa.free(ids);
}

/// Assert `got` is a permutation of `want` with no duplicates and no
/// extras — Python's `assert ids == {a, b}` (a SET comparison).
fn expectExactly(got: [][]const u8, want: []const []const u8, what: []const u8) !void {
    if (got.len != want.len) {
        std.debug.print("{s}: expected {d} pages, got {d}\n", .{ what, want.len, got.len });
        return error.TestUnexpectedResult;
    }
    for (want) |w| {
        var found = false;
        for (got) |g| {
            if (std.mem.eql(u8, g, w)) found = true;
        }
        if (!found) {
            std.debug.print("{s}: missing page {s}\n", .{ what, w });
            return error.TestUnexpectedResult;
        }
    }
    // No duplicates: a set of 2 cannot contain the same id twice.
    for (got, 0..) |g, i| {
        for (got[i + 1 ..]) |other| {
            if (std.mem.eql(u8, g, other)) {
                std.debug.print("{s}: duplicate page {s}\n", .{ what, g });
                return error.TestUnexpectedResult;
            }
        }
    }
}

// ============================================================================
// Test 10: geometry throttle handles 60 patches per second
// ============================================================================

// Fire 60 PATCH /geometry calls in <5s; all return 200, and the final
// position matches the last call.
test "geometry_throttle_handles_60_patches" {
    try harness.requirePabrikBin(io, gpa);
    var h = try boot();
    defer h.deinit(io) catch |err| {
        std.debug.print("teardown: {s}\n", .{@errorName(err)});
    };

    const scratch = try harness.makeScratchDir(gpa);
    defer gpa.free(scratch);
    defer harness.cleanupExtraDir(io, gpa, scratch);

    const ws_id = try createWorkspace(&h, "design-ws");
    defer gpa.free(ws_id);
    const design_id = try createDesign(&h, ws_id, "geom-throttle", scratch);
    defer gpa.free(design_id);
    const page_id = try createPage(&h, ws_id, design_id, "Page", 1440, 1024);
    defer gpa.free(page_id);
    const elem_id = try addElement(&h, ws_id, design_id, page_id, .{
        .name = "drag",
        .element_type = "rectangle",
        .html = "<div/>",
    });
    defer gpa.free(elem_id);

    const geom_url = try std.fmt.allocPrint(
        gpa,
        "/api/workspaces/{s}/items/{s}/design/pages/{s}/elements/{s}/geometry",
        .{ ws_id, design_id, page_id, elem_id },
    );
    defer gpa.free(geom_url);

    const start_ms = std.Io.Timestamp.now(io, .awake).toMilliseconds();
    var final_x: i64 = 0;
    for (0..60) |i| {
        const x: i64 = @intCast(i * 10);
        const y: i64 = @intCast(i * 5);
        const body = try std.fmt.allocPrint(gpa, "{{\"x\":{d},\"y\":{d}}}", .{ x, y });
        defer gpa.free(body);
        var r = try h.http(io, .PATCH, geom_url, .{ .json_body = body, .expect = &.{200} });
        r.deinit();
        final_x = x;
    }
    const elapsed_ms = std.Io.Timestamp.now(io, .awake).toMilliseconds() - start_ms;

    if (elapsed_ms >= 5000) {
        std.debug.print("60 PATCHes took {d}ms (>5000ms budget)\n", .{elapsed_ms});
        return error.TestUnexpectedResult;
    }

    // Read back the element and verify the final x.
    var page = try getPage(&h, ws_id, design_id, page_id);
    defer page.deinit();
    const elements = pageElements(&page);
    var drag: ?std.json.ObjectMap = null;
    for (elements) |e| {
        const id = objectId(e) orelse continue;
        if (!std.mem.eql(u8, id, elem_id)) continue;
        drag = switch (e) {
            .object => |o| o,
            else => null,
        };
    }
    const drag_obj = drag orelse {
        std.debug.print("dragged element missing from the page after 60 PATCHes\n", .{});
        return error.TestUnexpectedResult;
    };
    const got_x = switch (drag_obj.get("x") orelse std.json.Value{ .null = {} }) {
        .integer => |v| v,
        else => {
            std.debug.print("element `x` is not an integer\n", .{});
            return error.TestUnexpectedResult;
        },
    };
    if (got_x != final_x) {
        std.debug.print("final x should be {d}, got {d}\n", .{ final_x, got_x });
        return error.TestUnexpectedResult;
    }
}

// Body-analysis barrier. An unreferenced helper is never type-checked, so
// a stdlib rename inside one stays invisible until a caller appears.
comptime {
    _ = boot;
    _ = createWorkspace;
    _ = createDesign;
    _ = createPage;
    _ = elementBody;
    _ = addElement;
    _ = getElementHtml;
    _ = getPage;
    _ = pageElements;
    _ = objectId;
    _ = pageDir;
    _ = dirExists;
    _ = listHtmlFiles;
    _ = freePaths;
    _ = readTextFile;
    _ = listPageIds;
    _ = freeIds;
    _ = expectExactly;
    _ = Harness.boot;
}
