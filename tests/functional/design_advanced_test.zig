// Functional tests for design advanced (Tier 1.4). Zig port of
// `tests/functional/design_advanced_test.py` (same test names, same order).

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
    return gpa.dupe(u8, doc.str("id") orelse {
        std.debug.print("design create response has no `id`\n", .{});
        return error.TestUnexpectedResult;
    });
}

fn createPage(h: *Harness, ws_id: []const u8, design_id: []const u8, name: []const u8, width: i64, height: i64) ![]u8 {
    const body = try std.fmt.allocPrint(
        gpa,
        "{{\"name\":{f},\"width\":{d},\"height\":{d}}}",
        .{ std.json.fmt(name, .{}), width, height },
    );
    defer gpa.free(body);
    const url = try std.fmt.allocPrint(gpa, "/api/workspaces/{s}/items/{s}/design/pages", .{ ws_id, design_id });
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

const ElementSpec = struct {
    name: []const u8,
    element_type: []const u8 = "rectangle",
    html: []const u8 = "<div>x</div>",
    fill: ?[]const u8 = null,
    image_url: ?[]const u8 = null,
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
    if (spec.image_url) |u| {
        try w.writeAll(",\"image_url\":");
        try std.json.Stringify.encodeJsonString(u, .{}, w);
    }
    if (spec.x) |v| try w.print(",\"x\":{d}", .{v});
    if (spec.y) |v| try w.print(",\"y\":{d}", .{v});
    if (spec.width) |v| try w.print(",\"width\":{d}", .{v});
    if (spec.height) |v| try w.print(",\"height\":{d}", .{v});
    try w.writeAll("}");
    return out.toOwnedSlice();
}

fn addElement(h: *Harness, ws_id: []const u8, design_id: []const u8, page_id: []const u8, spec: ElementSpec) ![]u8 {
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

fn elementsUrl(ws_id: []const u8, design_id: []const u8, page_id: []const u8, suffix: []const u8) ![]u8 {
    return std.fmt.allocPrint(
        gpa,
        "/api/workspaces/{s}/items/{s}/design/pages/{s}/elements{s}",
        .{ ws_id, design_id, page_id, suffix },
    );
}

fn pageUrl(ws_id: []const u8, design_id: []const u8, page_id: []const u8) ![]u8 {
    return std.fmt.allocPrint(
        gpa,
        "/api/workspaces/{s}/items/{s}/design/pages/{s}",
        .{ ws_id, design_id, page_id },
    );
}

fn elementUrl(ws_id: []const u8, design_id: []const u8, page_id: []const u8, eid: []const u8, suffix: []const u8) ![]u8 {
    return std.fmt.allocPrint(
        gpa,
        "/api/workspaces/{s}/items/{s}/design/pages/{s}/elements/{s}{s}",
        .{ ws_id, design_id, page_id, eid, suffix },
    );
}

/// `GET .../design/pages/:pid` → an OWNED document (alloc_always, so it
/// outlives the Response body buffer).
fn getPage(h: *Harness, ws_id: []const u8, design_id: []const u8, page_id: []const u8) !std.json.Parsed(std.json.Value) {
    const url = try pageUrl(ws_id, design_id, page_id);
    defer gpa.free(url);
    var r = try h.http(io, .GET, url, .{ .expect = &.{200} });
    defer r.deinit();
    return std.json.parseFromSlice(std.json.Value, gpa, r.body, .{ .allocate = .alloc_always });
}

fn pageElements(page: *const std.json.Parsed(std.json.Value)) []const std.json.Value {
    const obj = switch (page.value) {
        .object => |o| o,
        else => return &.{},
    };
    // GET /pages/:pid returns `{page: {...}, elements: [...]}`.
    const v = obj.get("elements") orelse return &.{};
    return switch (v) {
        .array => |a| a.items,
        else => &.{},
    };
}

fn objStr(v: std.json.Value, key: []const u8) ?[]const u8 {
    const o = switch (v) {
        .object => |oo| oo,
        else => return null,
    };
    const f = o.get(key) orelse return null;
    return switch (f) {
        .string => |s| s,
        else => null,
    };
}

fn objNum(v: std.json.Value, key: []const u8) ?f64 {
    const o = switch (v) {
        .object => |oo| oo,
        else => return null,
    };
    const f = o.get(key) orelse return null;
    return switch (f) {
        .integer => |i| @floatFromInt(i),
        .float => |x| x,
        else => null,
    };
}

fn objId(v: std.json.Value) ?[]const u8 {
    return objStr(v, "id");
}

fn arrOf(doc: *const harness.Json, key: []const u8) []const std.json.Value {
    const a = doc.array(key) orelse return &.{};
    return a.items;
}

const Setup = struct { ws: []u8, design: []u8, page: []u8, scratch: []u8 };

fn setup(h: *Harness, design_name: []const u8, page_name: []const u8) !Setup {
    const scratch = try harness.makeScratchDir(gpa);
    errdefer {
        harness.cleanupExtraDir(io, gpa, scratch);
        gpa.free(scratch);
    }
    const ws = try createWorkspace(h, "design-adv-ws");
    errdefer gpa.free(ws);
    const design = try createDesign(h, ws, design_name, scratch);
    errdefer gpa.free(design);
    const page = try createPage(h, ws, design, page_name, 1440, 1024);
    errdefer gpa.free(page);
    return .{ .ws = ws, .design = design, .page = page, .scratch = scratch };
}

fn freeSetup(s: *Setup) void {
    gpa.free(s.ws);
    gpa.free(s.design);
    gpa.free(s.page);
    harness.cleanupExtraDir(io, gpa, s.scratch);
    gpa.free(s.scratch);
}

// ============================================================================
// Test 1: group 2 children creates parent at union bbox
// ============================================================================

test "group_two_elements_creates_parent_at_union_bbox" {
    try harness.requirePabrikBin(io, gpa);
    var h = try boot();
    defer h.deinit(io) catch |err| {
        std.debug.print("teardown: {s}\n", .{@errorName(err)});
    };
    var s = try setup(&h, "group-test", "GroupPage");
    defer freeSetup(&s);

    const e1 = try addElement(&h, s.ws, s.design, s.page, .{ .name = "e1", .x = 10, .y = 20, .width = 100, .height = 50 });
    defer gpa.free(e1);
    const e2 = try addElement(&h, s.ws, s.design, s.page, .{ .name = "e2", .x = 300, .y = 200, .width = 80, .height = 80 });
    defer gpa.free(e2);

    const url = try elementsUrl(s.ws, s.design, s.page, "/group");
    defer gpa.free(url);
    const body = try std.fmt.allocPrint(gpa, "{{\"child_ids\":[{f},{f}],\"name\":\"G\"}}", .{ std.json.fmt(e1, .{}), std.json.fmt(e2, .{}) });
    defer gpa.free(body);
    var r = try h.http(io, .POST, url, .{ .json_body = body, .expect = &.{201} });
    defer r.deinit();
    var doc = try r.json();
    defer doc.deinit();
    const parent = doc.get("parent") orelse {
        std.debug.print("group response missing 'parent'\n", .{});
        return error.TestUnexpectedResult;
    };
    try testing.expectEqualStrings("group", objStr(parent, "type") orelse "");
    try testing.expectEqual(@as(f64, 10), objNum(parent, "x") orelse -1);
    try testing.expectEqual(@as(f64, 20), objNum(parent, "y") orelse -1);
    try testing.expectEqual(@as(f64, 370), objNum(parent, "width") orelse -1);
    try testing.expectEqual(@as(f64, 260), objNum(parent, "height") orelse -1);
    const children = arrOf(&doc, "children");
    try testing.expectEqual(@as(usize, 2), children.len);
}

// ============================================================================
// Test 2: group z-index sits BELOW children
// ============================================================================

test "group_parent_z_index_below_children" {
    try harness.requirePabrikBin(io, gpa);
    var h = try boot();
    defer h.deinit(io) catch |err| {
        std.debug.print("teardown: {s}\n", .{@errorName(err)});
    };
    var s = try setup(&h, "zidx-test", "ZPage");
    defer freeSetup(&s);

    const e1 = try addElement(&h, s.ws, s.design, s.page, .{ .name = "e1" });
    defer gpa.free(e1);
    const e2 = try addElement(&h, s.ws, s.design, s.page, .{ .name = "e2" });
    defer gpa.free(e2);

    const url = try elementsUrl(s.ws, s.design, s.page, "/group");
    defer gpa.free(url);
    const body = try std.fmt.allocPrint(gpa, "{{\"child_ids\":[{f},{f}],\"name\":\"G\"}}", .{ std.json.fmt(e1, .{}), std.json.fmt(e2, .{}) });
    defer gpa.free(body);
    var r = try h.http(io, .POST, url, .{ .json_body = body, .expect = &.{201} });
    defer r.deinit();
    var doc = try r.json();
    defer doc.deinit();
    const parent = doc.get("parent") orelse return error.TestUnexpectedResult;
    const z = objNum(parent, "z_index") orelse {
        std.debug.print("group parent has no z_index\n", .{});
        return error.TestUnexpectedResult;
    };
    if (!(z < 0)) {
        std.debug.print("group z_index should be < 0, got {d}\n", .{z});
        return error.TestUnexpectedResult;
    }
}

// ============================================================================
// Test 3: type=frame creates a clipping container
// ============================================================================

test "group_type_frame_creates_clipping_container" {
    try harness.requirePabrikBin(io, gpa);
    var h = try boot();
    defer h.deinit(io) catch |err| {
        std.debug.print("teardown: {s}\n", .{@errorName(err)});
    };
    var s = try setup(&h, "frame-test", "FramePage");
    defer freeSetup(&s);

    const e1 = try addElement(&h, s.ws, s.design, s.page, .{ .name = "e1" });
    defer gpa.free(e1);
    const e2 = try addElement(&h, s.ws, s.design, s.page, .{ .name = "e2" });
    defer gpa.free(e2);

    const url = try elementsUrl(s.ws, s.design, s.page, "/group");
    defer gpa.free(url);
    const body = try std.fmt.allocPrint(gpa, "{{\"child_ids\":[{f},{f}],\"name\":\"F\",\"type\":\"frame\"}}", .{ std.json.fmt(e1, .{}), std.json.fmt(e2, .{}) });
    defer gpa.free(body);
    var r = try h.http(io, .POST, url, .{ .json_body = body, .expect = &.{201} });
    defer r.deinit();
    var doc = try r.json();
    defer doc.deinit();
    const parent = doc.get("parent") orelse return error.TestUnexpectedResult;
    try testing.expectEqualStrings("frame", objStr(parent, "type") orelse "");
}

// ============================================================================
// Test 4: group rejects single child
// ============================================================================

test "group_rejects_single_child" {
    try harness.requirePabrikBin(io, gpa);
    var h = try boot();
    defer h.deinit(io) catch |err| {
        std.debug.print("teardown: {s}\n", .{@errorName(err)});
    };
    var s = try setup(&h, "single-child", "Page");
    defer freeSetup(&s);

    const e1 = try addElement(&h, s.ws, s.design, s.page, .{ .name = "only" });
    defer gpa.free(e1);

    const url = try elementsUrl(s.ws, s.design, s.page, "/group");
    defer gpa.free(url);
    const body = try std.fmt.allocPrint(gpa, "{{\"child_ids\":[{f}],\"name\":\"G\"}}", .{std.json.fmt(e1, .{})});
    defer gpa.free(body);
    var r = try h.http(io, .POST, url, .{ .json_body = body, .expect = &.{400} });
    defer r.deinit();
    var doc = try r.json();
    defer doc.deinit();
    const msg = doc.str("error") orelse {
        std.debug.print("400 response has no `error` key\n", .{});
        return error.TestUnexpectedResult;
    };
    var lower_buf: [512]u8 = undefined;
    const n: usize = @min(msg.len, lower_buf.len);
    for (msg[0..n], 0..) |c, i| lower_buf[i] = std.ascii.toLower(c);
    const lower = lower_buf[0..n];
    if (std.mem.indexOf(u8, lower, "at least") == null and std.mem.indexOf(u8, lower, "two") == null and std.mem.indexOf(u8, msg, "TooFew") == null) {
        std.debug.print("unexpected error message: {s}\n", .{msg});
        return error.TestUnexpectedResult;
    }
}

// ============================================================================
// Test 5: group rejects already-parented child
// ============================================================================

test "group_rejects_already_parented_child" {
    try harness.requirePabrikBin(io, gpa);
    var h = try boot();
    defer h.deinit(io) catch |err| {
        std.debug.print("teardown: {s}\n", .{@errorName(err)});
    };
    var s = try setup(&h, "reparent", "Page");
    defer freeSetup(&s);

    const c1 = try addElement(&h, s.ws, s.design, s.page, .{ .name = "c1" });
    defer gpa.free(c1);
    const c2 = try addElement(&h, s.ws, s.design, s.page, .{ .name = "c2" });
    defer gpa.free(c2);
    const c3 = try addElement(&h, s.ws, s.design, s.page, .{ .name = "c3" });
    defer gpa.free(c3);

    const url = try elementsUrl(s.ws, s.design, s.page, "/group");
    defer gpa.free(url);
    {
        const body = try std.fmt.allocPrint(gpa, "{{\"child_ids\":[{f},{f}],\"name\":\"outer\"}}", .{ std.json.fmt(c1, .{}), std.json.fmt(c2, .{}) });
        defer gpa.free(body);
        var r = try h.http(io, .POST, url, .{ .json_body = body, .expect = &.{201} });
        defer r.deinit();
        var doc = try r.json();
        defer doc.deinit();
    }
    {
        const body = try std.fmt.allocPrint(gpa, "{{\"child_ids\":[{f},{f}],\"name\":\"nested\"}}", .{ std.json.fmt(c1, .{}), std.json.fmt(c3, .{}) });
        defer gpa.free(body);
        var r = try h.http(io, .POST, url, .{ .json_body = body, .expect = &.{409} });
        defer r.deinit();
        var doc = try r.json();
        defer doc.deinit();
        if (doc.get("error") == null) {
            std.debug.print("409 response has no `error` key\n", .{});
            return error.TestUnexpectedResult;
        }
    }
}

// ============================================================================
// Test 6: ungroup removes parent + resets children to top-level
// ============================================================================

test "ungroup_removes_parent_and_resets_children" {
    try harness.requirePabrikBin(io, gpa);
    var h = try boot();
    defer h.deinit(io) catch |err| {
        std.debug.print("teardown: {s}\n", .{@errorName(err)});
    };
    var s = try setup(&h, "ungroup", "Page");
    defer freeSetup(&s);

    const c1 = try addElement(&h, s.ws, s.design, s.page, .{ .name = "c1" });
    defer gpa.free(c1);
    const c2 = try addElement(&h, s.ws, s.design, s.page, .{ .name = "c2" });
    defer gpa.free(c2);

    const group_url = try elementsUrl(s.ws, s.design, s.page, "/group");
    defer gpa.free(group_url);
    const group_body = try std.fmt.allocPrint(gpa, "{{\"child_ids\":[{f},{f}],\"name\":\"G\"}}", .{ std.json.fmt(c1, .{}), std.json.fmt(c2, .{}) });
    defer gpa.free(group_body);
    var gr = try h.http(io, .POST, group_url, .{ .json_body = group_body, .expect = &.{201} });
    defer gr.deinit();
    var gdoc = try gr.json();
    defer gdoc.deinit();
    const parent = gdoc.get("parent") orelse return error.TestUnexpectedResult;
    const group_id = try gpa.dupe(u8, objStr(parent, "id") orelse return error.TestUnexpectedResult);
    defer gpa.free(group_id);

    const ungroup_url = try elementsUrl(s.ws, s.design, s.page, "/ungroup");
    defer gpa.free(ungroup_url);
    const ungroup_body = try std.fmt.allocPrint(gpa, "{{\"element_id\":{f}}}", .{std.json.fmt(group_id, .{})});
    defer gpa.free(ungroup_body);
    var ur = try h.http(io, .POST, ungroup_url, .{ .json_body = ungroup_body, .expect = &.{200} });
    defer ur.deinit();
    var udoc = try ur.json();
    defer udoc.deinit();
    const orphaned = arrOf(&udoc, "orphaned");
    try testing.expectEqual(@as(usize, 2), orphaned.len);
    for (orphaned) |o| {
        const pid = objStr(o, "parent_id");
        if (pid != null and pid.?.len != 0) {
            std.debug.print("orphaned child should have empty parent_id, got {s}\n", .{pid.?});
            return error.TestUnexpectedResult;
        }
    }

    var page = try getPage(&h, s.ws, s.design, s.page);
    defer page.deinit();
    const elements = pageElements(&page);
    for (elements) |e| {
        if (objId(e)) |id| {
            if (std.mem.eql(u8, id, group_id)) {
                std.debug.print("group {s} should be gone after ungroup\n", .{group_id});
                return error.TestUnexpectedResult;
            }
        }
    }
    var found_c1 = false;
    var found_c2 = false;
    for (elements) |e| {
        const id = objId(e) orelse continue;
        if (std.mem.eql(u8, id, c1)) found_c1 = true;
        if (std.mem.eql(u8, id, c2)) found_c2 = true;
    }
    if (!found_c1 or !found_c2) return error.TestUnexpectedResult;
}

// ============================================================================
// Test 7: reorder changes the z-order on the page
// ============================================================================

test "reorder_elements_within_page" {
    try harness.requirePabrikBin(io, gpa);
    var h = try boot();
    defer h.deinit(io) catch |err| {
        std.debug.print("teardown: {s}\n", .{@errorName(err)});
    };
    var s = try setup(&h, "reorder", "Page");
    defer freeSetup(&s);

    const a = try addElement(&h, s.ws, s.design, s.page, .{ .name = "a" });
    defer gpa.free(a);
    const b = try addElement(&h, s.ws, s.design, s.page, .{ .name = "b" });
    defer gpa.free(b);
    const c = try addElement(&h, s.ws, s.design, s.page, .{ .name = "c" });
    defer gpa.free(c);

    const url = try elementsUrl(s.ws, s.design, s.page, "/reorder");
    defer gpa.free(url);
    const body = try std.fmt.allocPrint(gpa, "{{\"mode\":\"bring_to_front\",\"element_ids\":[{f}]}}", .{std.json.fmt(a, .{})});
    defer gpa.free(body);
    var r = try h.http(io, .POST, url, .{ .json_body = body, .expect = &.{200} });
    defer r.deinit();
    var doc = try r.json();
    defer doc.deinit();
    try testing.expectEqual(@as(usize, 3), arrOf(&doc, "reordered").len);

    var page = try getPage(&h, s.ws, s.design, s.page);
    defer page.deinit();
    const elements = pageElements(&page);
    var top_id: ?[]const u8 = null;
    var top_z: f64 = -1e18;
    for (elements) |e| {
        const z = objNum(e, "z_index") orelse 0;
        if (top_id == null or z > top_z) {
            top_z = z;
            top_id = objId(e);
        }
    }
    try testing.expectEqualStrings(a, top_id orelse "");
}

// ============================================================================
// Test 8: reparent-batch moves 5 children to a new parent in one call
// ============================================================================

test "reparent_batch_moves_multiple_at_once" {
    try harness.requirePabrikBin(io, gpa);
    var h = try boot();
    defer h.deinit(io) catch |err| {
        std.debug.print("teardown: {s}\n", .{@errorName(err)});
    };
    var s = try setup(&h, "reparent-batch", "Page");
    defer freeSetup(&s);

    const dest = try addElement(&h, s.ws, s.design, s.page, .{ .name = "dest", .element_type = "group" });
    defer gpa.free(dest);
    {
        const d1 = try addElement(&h, s.ws, s.design, s.page, .{ .name = "dest-child-1" });
        defer gpa.free(d1);
        const d2 = try addElement(&h, s.ws, s.design, s.page, .{ .name = "dest-child-2" });
        defer gpa.free(d2);
    }
    var src_ids: [5][]u8 = undefined;
    for (&src_ids, 0..) |*slot, i| {
        const nm = try std.fmt.allocPrint(gpa, "src-{d}", .{i});
        defer gpa.free(nm);
        slot.* = try addElement(&h, s.ws, s.design, s.page, .{ .name = nm });
    }
    defer for (src_ids) |id| gpa.free(id);

    var ids_out: std.Io.Writer.Allocating = .init(gpa);
    defer ids_out.deinit();
    const ids_w = &ids_out.writer;
    try ids_w.writeAll("[");
    for (src_ids, 0..) |id, i| {
        if (i > 0) try ids_w.writeAll(",");
        try std.json.Stringify.encodeJsonString(id, .{}, ids_w);
    }
    try ids_w.writeAll("]");
    const ids_json = ids_out.written();
    const body = try std.fmt.allocPrint(gpa, "{{\"element_ids\":{s},\"new_parent_id\":{f},\"reposition\":\"last_in_parent\"}}", .{ ids_json, std.json.fmt(dest, .{}) });
    defer gpa.free(body);
    const url = try elementsUrl(s.ws, s.design, s.page, "/reparent-batch");
    defer gpa.free(url);
    var r = try h.http(io, .POST, url, .{ .json_body = body, .expect = &.{200} });
    defer r.deinit();
    var doc = try r.json();
    defer doc.deinit();
    const updated = arrOf(&doc, "updated");
    try testing.expectEqual(@as(usize, 5), updated.len);
    for (updated) |u| {
        try testing.expectEqualStrings(dest, objStr(u, "parent_id") orelse "");
    }
}

// ============================================================================
// Test 9: translate moves an element by the delta
// ============================================================================

test "translate_moves_element_by_delta" {
    try harness.requirePabrikBin(io, gpa);
    var h = try boot();
    defer h.deinit(io) catch |err| {
        std.debug.print("teardown: {s}\n", .{@errorName(err)});
    };
    var s = try setup(&h, "translate", "Page");
    defer freeSetup(&s);

    const eid = try addElement(&h, s.ws, s.design, s.page, .{ .name = "e", .x = 100, .y = 200, .width = 50, .height = 50 });
    defer gpa.free(eid);

    const url = try elementUrl(s.ws, s.design, s.page, eid, "/translate");
    defer gpa.free(url);
    var r = try h.http(io, .POST, url, .{ .json_body = "{\"dx\":50,\"dy\":30}", .expect = &.{200} });
    defer r.deinit();
    var doc = try r.json();
    defer doc.deinit();
    const updated = arrOf(&doc, "updated");
    try testing.expectEqual(@as(usize, 1), updated.len);
    try testing.expectEqual(@as(f64, 150), objNum(updated[0], "x") orelse -1);
    try testing.expectEqual(@as(f64, 230), objNum(updated[0], "y") orelse -1);
    try testing.expectEqual(@as(f64, 50), objNum(updated[0], "width") orelse -1);
    try testing.expectEqual(@as(f64, 50), objNum(updated[0], "height") orelse -1);
}

// ============================================================================
// Test 10: translate cascades to children on a group
// ============================================================================

test "translate_cascades_to_children_on_group" {
    try harness.requirePabrikBin(io, gpa);
    var h = try boot();
    defer h.deinit(io) catch |err| {
        std.debug.print("teardown: {s}\n", .{@errorName(err)});
    };
    var s = try setup(&h, "cascade", "Page");
    defer freeSetup(&s);

    const c1 = try addElement(&h, s.ws, s.design, s.page, .{ .name = "c1", .x = 10, .y = 20 });
    defer gpa.free(c1);
    const c2 = try addElement(&h, s.ws, s.design, s.page, .{ .name = "c2", .x = 60, .y = 70 });
    defer gpa.free(c2);

    const group_url = try elementsUrl(s.ws, s.design, s.page, "/group");
    defer gpa.free(group_url);
    const group_body = try std.fmt.allocPrint(gpa, "{{\"child_ids\":[{f},{f}],\"name\":\"G\"}}", .{ std.json.fmt(c1, .{}), std.json.fmt(c2, .{}) });
    defer gpa.free(group_body);
    var gr = try h.http(io, .POST, group_url, .{ .json_body = group_body, .expect = &.{201} });
    defer gr.deinit();
    var gdoc = try gr.json();
    defer gdoc.deinit();
    const gid = try gpa.dupe(u8, objStr(gdoc.get("parent") orelse return error.TestUnexpectedResult, "id") orelse return error.TestUnexpectedResult);
    defer gpa.free(gid);

    const url = try elementUrl(s.ws, s.design, s.page, gid, "/translate");
    defer gpa.free(url);
    var r = try h.http(io, .POST, url, .{ .json_body = "{\"dx\":10,\"dy\":20}", .expect = &.{200} });
    defer r.deinit();
    var doc = try r.json();
    defer doc.deinit();
    const updated = arrOf(&doc, "updated");
    try testing.expectEqual(@as(usize, 3), updated.len);
    var c1v: ?std.json.Value = null;
    var c2v: ?std.json.Value = null;
    for (updated) |u| {
        const id = objId(u) orelse continue;
        if (std.mem.eql(u8, id, c1)) c1v = u;
        if (std.mem.eql(u8, id, c2)) c2v = u;
    }
    try testing.expectEqual(@as(f64, 20), objNum(c1v orelse return error.TestUnexpectedResult, "x") orelse -1);
    try testing.expectEqual(@as(f64, 40), objNum(c1v.?, "y") orelse -1);
    try testing.expectEqual(@as(f64, 70), objNum(c2v orelse return error.TestUnexpectedResult, "x") orelse -1);
    try testing.expectEqual(@as(f64, 90), objNum(c2v.?, "y") orelse -1);
}

// ============================================================================
// Test 11: resize changes w/h only; x/y untouched
// ============================================================================

test "resize_changes_width_height_only" {
    try harness.requirePabrikBin(io, gpa);
    var h = try boot();
    defer h.deinit(io) catch |err| {
        std.debug.print("teardown: {s}\n", .{@errorName(err)});
    };
    var s = try setup(&h, "resize", "Page");
    defer freeSetup(&s);

    const eid = try addElement(&h, s.ws, s.design, s.page, .{ .name = "e", .x = 100, .y = 200, .width = 50, .height = 50 });
    defer gpa.free(eid);

    const url = try elementUrl(s.ws, s.design, s.page, eid, "/resize");
    defer gpa.free(url);
    var r = try h.http(io, .POST, url, .{ .json_body = "{\"width\":300,\"height\":150}", .expect = &.{200} });
    defer r.deinit();
    var doc = try r.json();
    defer doc.deinit();
    try testing.expectEqual(@as(f64, 300), doc.number("width") orelse -1);
    try testing.expectEqual(@as(f64, 150), doc.number("height") orelse -1);
    try testing.expectEqual(@as(f64, 100), doc.number("x") orelse -1);
    try testing.expectEqual(@as(f64, 200), doc.number("y") orelse -1);
}

// ============================================================================
// Test 12: geometry-batch updates N elements in one request
// ============================================================================

test "geometry_batch_patches_n_elements_in_one_request" {
    try harness.requirePabrikBin(io, gpa);
    var h = try boot();
    defer h.deinit(io) catch |err| {
        std.debug.print("teardown: {s}\n", .{@errorName(err)});
    };
    var s = try setup(&h, "geom-batch", "Page");
    defer freeSetup(&s);

    var ids: [12][]u8 = undefined;
    for (&ids, 0..) |*slot, i| {
        const nm = try std.fmt.allocPrint(gpa, "e{d}", .{i});
        defer gpa.free(nm);
        slot.* = try addElement(&h, s.ws, s.design, s.page, .{ .name = nm, .x = 0, .y = 0, .width = 10, .height = 10 });
    }
    defer for (ids) |id| gpa.free(id);

    var ub: std.Io.Writer.Allocating = .init(gpa);
    defer ub.deinit();
    const uw = &ub.writer;
    try uw.writeAll("{\"updates\":[");
    for (ids, 0..) |id, i| {
        if (i > 0) try uw.writeAll(",");
        try uw.print("{{\"element_id\":", .{});
        try std.json.Stringify.encodeJsonString(id, .{}, uw);
        try uw.print(",\"x\":{d},\"y\":{d}}}", .{ 100 + i, 200 + i });
    }
    try uw.writeAll("]}");
    const body = try gpa.dupe(u8, ub.written());
    defer gpa.free(body);
    const url = try elementsUrl(s.ws, s.design, s.page, "/geometry-batch");
    defer gpa.free(url);
    var r = try h.http(io, .POST, url, .{ .json_body = body, .expect = &.{200} });
    defer r.deinit();
    var doc = try r.json();
    defer doc.deinit();
    const updated = arrOf(&doc, "updated");
    try testing.expectEqual(@as(usize, 12), updated.len);
    for (updated, 0..) |u, i| {
        try testing.expectEqual(@as(f64, @floatFromInt(100 + i)), objNum(u, "x") orelse -1);
        try testing.expectEqual(@as(f64, @floatFromInt(200 + i)), objNum(u, "y") orelse -1);
    }
}

// ============================================================================
// Test 13: move-batch translates many at once
// ============================================================================

test "move_batch_translates_many_at_once" {
    try harness.requirePabrikBin(io, gpa);
    var h = try boot();
    defer h.deinit(io) catch |err| {
        std.debug.print("teardown: {s}\n", .{@errorName(err)});
    };
    var s = try setup(&h, "move-batch", "Page");
    defer freeSetup(&s);

    const N = 12;
    var ids: [N][]u8 = undefined;
    for (&ids, 0..) |*slot, i| {
        const nm = try std.fmt.allocPrint(gpa, "m{d}", .{i});
        defer gpa.free(nm);
        slot.* = try addElement(&h, s.ws, s.design, s.page, .{ .name = nm, .x = 0, .y = 0, .width = 10, .height = 10 });
    }
    defer for (ids) |id| gpa.free(id);

    var ib: std.Io.Writer.Allocating = .init(gpa);
    defer ib.deinit();
    const iw = &ib.writer;
    try iw.writeAll("{\"items\":[");
    for (ids, 0..) |id, i| {
        if (i > 0) try iw.writeAll(",");
        try iw.writeAll("{\"element_id\":");
        try std.json.Stringify.encodeJsonString(id, .{}, iw);
        try iw.print(",\"dx\":{d},\"dy\":{d}}}", .{ (i + 1) * 10, (i + 1) * 5 });
    }
    try iw.writeAll("]}");
    const body = try gpa.dupe(u8, ib.written());
    defer gpa.free(body);
    const url = try elementsUrl(s.ws, s.design, s.page, "/move-batch");
    defer gpa.free(url);
    var r = try h.http(io, .POST, url, .{ .json_body = body, .expect = &.{200} });
    defer r.deinit();
    var doc = try r.json();
    defer doc.deinit();
    const updated = arrOf(&doc, "updated");
    try testing.expectEqual(@as(usize, N), updated.len);
    for (ids, 0..) |id, i| {
        var found: ?std.json.Value = null;
        for (updated) |u| {
            const uid = objId(u) orelse continue;
            if (std.mem.eql(u8, uid, id)) found = u;
        }
        const v = found orelse {
            std.debug.print("element {s} missing from move-batch response\n", .{id});
            return error.TestUnexpectedResult;
        };
        try testing.expectEqual(@as(f64, @floatFromInt((i + 1) * 10)), objNum(v, "x") orelse -1);
        try testing.expectEqual(@as(f64, @floatFromInt((i + 1) * 5)), objNum(v, "y") orelse -1);
    }
}

// ============================================================================
// Test 14: move-to-page cross-page relocate
// ============================================================================

test "move_element_to_page_cross_page" {
    try harness.requirePabrikBin(io, gpa);
    var h = try boot();
    defer h.deinit(io) catch |err| {
        std.debug.print("teardown: {s}\n", .{@errorName(err)});
    };
    var s = try setup(&h, "move-page", "Source");
    defer freeSetup(&s);
    const tgt = try createPage(&h, s.ws, s.design, "Target", 1440, 1024);
    defer gpa.free(tgt);

    const eid = try addElement(&h, s.ws, s.design, s.page, .{ .name = "e", .x = 0, .y = 0, .width = 50, .height = 50 });
    defer gpa.free(eid);

    const url = try elementUrl(s.ws, s.design, s.page, eid, "/move-to-page");
    defer gpa.free(url);
    const body = try std.fmt.allocPrint(gpa, "{{\"new_page_id\":{f}}}", .{std.json.fmt(tgt, .{})});
    defer gpa.free(body);
    var r = try h.http(io, .POST, url, .{ .json_body = body, .expect = &.{200} });
    defer r.deinit();
    var doc = try r.json();
    defer doc.deinit();
    const updated = arrOf(&doc, "updated");
    try testing.expectEqual(@as(usize, 1), updated.len);
    try testing.expectEqualStrings(tgt, objStr(updated[0], "page_id") orelse "");
}

// ============================================================================
// Test 15: PATCH page updates width + height
// ============================================================================

test "patch_page_updates_width_height" {
    try harness.requirePabrikBin(io, gpa);
    var h = try boot();
    defer h.deinit(io) catch |err| {
        std.debug.print("teardown: {s}\n", .{@errorName(err)});
    };
    var s = try setup(&h, "patch-page", "PatchPage");
    defer freeSetup(&s);

    const url = try pageUrl(s.ws, s.design, s.page);
    defer gpa.free(url);
    var r = try h.http(io, .PATCH, url, .{ .json_body = "{\"width\":1920,\"height\":1080}", .expect = &.{200} });
    defer r.deinit();
    var doc = try r.json();
    defer doc.deinit();
    try testing.expectEqual(@as(f64, 1920), doc.number("width") orelse -1);
    try testing.expectEqual(@as(f64, 1080), doc.number("height") orelse -1);

    var page = try getPage(&h, s.ws, s.design, s.page);
    defer page.deinit();
    const inner = switch (page.value) {
        .object => |o| o.get("page") orelse page.value,
        else => return error.TestUnexpectedResult,
    };
    try testing.expectEqual(@as(f64, 1920), objNum(inner, "width") orelse -1);
    try testing.expectEqual(@as(f64, 1080), objNum(inner, "height") orelse -1);
}

// ============================================================================
// Test 16: PATCH page rejects out-of-range dimensions
// ============================================================================

test "patch_page_rejects_out_of_range_dimensions" {
    try harness.requirePabrikBin(io, gpa);
    var h = try boot();
    defer h.deinit(io) catch |err| {
        std.debug.print("teardown: {s}\n", .{@errorName(err)});
    };
    var s = try setup(&h, "patch-bad", "BadPage");
    defer freeSetup(&s);

    const url = try pageUrl(s.ws, s.design, s.page);
    defer gpa.free(url);
    {
        var r = try h.http(io, .PATCH, url, .{ .json_body = "{\"width\":100,\"height\":1024}", .expect = &.{400} });
        defer r.deinit();
        var doc = try r.json();
        defer doc.deinit();
        const msg = doc.str("error") orelse return error.TestUnexpectedResult;
        var lower_buf: [512]u8 = undefined;
        const n: usize = @min(msg.len, lower_buf.len);
        for (msg[0..n], 0..) |c, i| lower_buf[i] = std.ascii.toLower(c);
        const lower = lower_buf[0..n];
        if (std.mem.indexOf(u8, lower, "width") == null and std.mem.indexOf(u8, lower, "range") == null and std.mem.indexOf(u8, lower, "between") == null) {
            std.debug.print("unexpected width error: {s}\n", .{msg});
            return error.TestUnexpectedResult;
        }
    }
    {
        var r = try h.http(io, .PATCH, url, .{ .json_body = "{\"width\":1440,\"height\":10000}", .expect = &.{400} });
        defer r.deinit();
        var doc = try r.json();
        defer doc.deinit();
        const msg = doc.str("error") orelse return error.TestUnexpectedResult;
        var lower_buf: [512]u8 = undefined;
        const n: usize = @min(msg.len, lower_buf.len);
        for (msg[0..n], 0..) |c, i| lower_buf[i] = std.ascii.toLower(c);
        if (std.mem.indexOf(u8, lower_buf[0..n], "height") == null) {
            std.debug.print("unexpected height error: {s}\n", .{msg});
            return error.TestUnexpectedResult;
        }
    }
}

// ============================================================================
// Test 17: PATCH element html atomically rewrites the file
// ============================================================================

test "patch_element_html_atomically_rewrites_file" {
    try harness.requirePabrikBin(io, gpa);
    var h = try boot();
    defer h.deinit(io) catch |err| {
        std.debug.print("teardown: {s}\n", .{@errorName(err)});
    };
    var s = try setup(&h, "patch-html", "Page");
    defer freeSetup(&s);

    const eid = try addElement(&h, s.ws, s.design, s.page, .{ .name = "e", .html = "<div>original</div>" });
    defer gpa.free(eid);

    const new_html = "<div>updated content with more text</div>";
    const url = try elementUrl(s.ws, s.design, s.page, eid, "/html");
    defer gpa.free(url);
    const body = try std.fmt.allocPrint(gpa, "{{\"html\":{f}}}", .{std.json.fmt(new_html, .{})});
    defer gpa.free(body);
    {
        var r = try h.http(io, .PATCH, url, .{ .json_body = body, .expect = &.{200} });
        defer r.deinit();
        var doc = try r.json();
        defer doc.deinit();
    }
    {
        var r = try h.http(io, .GET, url, .{ .expect = &.{200} });
        defer r.deinit();
        var doc = try r.json();
        defer doc.deinit();
        try testing.expectEqualStrings(new_html, doc.str("html") orelse "");
    }
}

// ============================================================================
// Test 18: image_url data-URI round-trips on create
// ============================================================================

test "image_url_data_uri_round_trips" {
    try harness.requirePabrikBin(io, gpa);
    var h = try boot();
    defer h.deinit(io) catch |err| {
        std.debug.print("teardown: {s}\n", .{@errorName(err)});
    };
    var s = try setup(&h, "img", "Page");
    defer freeSetup(&s);

    const data_uri = "data:image/png;base64,iVBORw0KGgoAAAANSUhEUgAAAAEAAAABAQMAAAAl21bKAAAAA1BMVEX///+nxBvIAAAAC0lEQVQI12NgAAIAAAUAAeImBZsAAAAASUVORK5CYII=";
    const eid = try addElement(&h, s.ws, s.design, s.page, .{
        .name = "img-1",
        .element_type = "image",
        .html = "<img src=\"placeholder\">",
        .image_url = data_uri,
    });
    defer gpa.free(eid);
    if (!std.mem.startsWith(u8, eid, "elem_")) {
        std.debug.print("expected elem_ id, got {s}\n", .{eid});
        return error.TestUnexpectedResult;
    }

    var page = try getPage(&h, s.ws, s.design, s.page);
    defer page.deinit();
    const elements = pageElements(&page);
    var found: ?std.json.Value = null;
    for (elements) |e| {
        const id = objId(e) orelse continue;
        if (std.mem.eql(u8, id, eid)) found = e;
    }
    const v = found orelse {
        std.debug.print("created element {s} missing from page\n", .{eid});
        return error.TestUnexpectedResult;
    };
    if (objStr(v, "image_url")) |got| {
        // Mirror Python's `if found.get("image_url"):` truthiness: an empty
        // wire value skips rather than fails (the server may omit/blank it;
        // only a PRESENT value must round-trip verbatim).
        if (got.len == 0) return;
        try testing.expectEqualStrings(data_uri, got);
    }
}
