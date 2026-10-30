const std = @import("std");
const testing = std.testing;
const harness = @import("harness.zig");
const Harness = harness.Harness;
const gpa = testing.allocator;
const io = testing.io;

fn listUrl(ws: []const u8) ![]u8 {
    return std.fmt.allocPrint(gpa, "/api/workspaces/{s}/documents", .{ws});
}

fn reorderUrl(ws: []const u8) ![]u8 {
    return std.fmt.allocPrint(gpa, "/api/workspaces/{s}/documents/reorder", .{ws});
}

fn createWorkspace(h: *Harness, name: []const u8) ![]u8 {
    const body = try std.json.Stringify.valueAlloc(gpa, .{ .name = name }, .{});
    defer gpa.free(body);
    var r = try h.http(io, .POST, "/api/workspaces", .{ .json_body = body, .expect = &.{201} });
    defer r.deinit();
    var doc = try r.json();
    defer doc.deinit();
    const id = doc.str("id") orelse {
        std.debug.print("workspace create returned no id: {s}\n", .{r.body});
        return error.TestUnexpectedResult;
    };
    return gpa.dupe(u8, id);
}

fn createDocument(h: *Harness, ws: []const u8, title: []const u8) ![]u8 {
    const path = try listUrl(ws);
    defer gpa.free(path);
    const body = try std.json.Stringify.valueAlloc(gpa, .{ .title = title }, .{});
    defer gpa.free(body);
    var r = try h.http(io, .POST, path, .{ .json_body = body, .expect = &.{201} });
    defer r.deinit();
    var doc = try r.json();
    defer doc.deinit();
    const obj = doc.object("document") orelse {
        std.debug.print("document create returned no `document`: {s}\n", .{r.body});
        return error.TestUnexpectedResult;
    };
    const id = switch (obj.get("id") orelse {
        std.debug.print("document create returned no id: {s}\n", .{r.body});
        return error.TestUnexpectedResult;
    }) {
        .string => |value| value,
        else => return error.TestUnexpectedResult,
    };
    return gpa.dupe(u8, id);
}

const Snapshot = struct {
    titles: []u8,
    ids: std.ArrayList([]u8) = .empty,
    positions: std.ArrayList(i64) = .empty,

    fn deinit(self: *Snapshot) void {
        gpa.free(self.titles);
        for (self.ids.items) |id| gpa.free(id);
        self.ids.deinit(gpa);
        self.positions.deinit(gpa);
    }

    fn idAt(self: *const Snapshot, index: usize) []const u8 {
        return self.ids.items[index];
    }
};

fn snapshot(h: *Harness, ws: []const u8) !Snapshot {
    const path = try listUrl(ws);
    defer gpa.free(path);
    var r = try h.http(io, .GET, path, .{ .expect = &.{200} });
    defer r.deinit();
    var doc = try r.json();
    defer doc.deinit();

    var out = Snapshot{ .titles = try gpa.dupe(u8, "") };
    errdefer out.deinit();
    const documents = doc.array("documents") orelse {
        std.debug.print("list returned no documents array: {s}\n", .{r.body});
        return error.TestUnexpectedResult;
    };
    var text = std.ArrayList(u8).empty;
    defer text.deinit(gpa);
    for (documents.items) |item| {
        const obj = switch (item) {
            .object => |o| o,
            else => return error.TestUnexpectedResult,
        };
        const title = switch (obj.get("title") orelse return error.TestUnexpectedResult) {
            .string => |s| s,
            else => return error.TestUnexpectedResult,
        };
        const id = switch (obj.get("id") orelse return error.TestUnexpectedResult) {
            .string => |s| s,
            else => return error.TestUnexpectedResult,
        };
        const position = switch (obj.get("position") orelse return error.TestUnexpectedResult) {
            .integer => |n| n,
            else => return error.TestUnexpectedResult,
        };
        if (out.positions.items.len > 0) try text.append(gpa, ',');
        try text.appendSlice(gpa, title);
        try text.append(gpa, '@');
        var buf: [24]u8 = undefined;
        try text.appendSlice(gpa, try std.fmt.bufPrint(&buf, "{d}", .{position}));
        try out.ids.append(gpa, try gpa.dupe(u8, id));
        try out.positions.append(gpa, position);
    }
    gpa.free(out.titles);
    out.titles = try text.toOwnedSlice(gpa);
    return out;
}

fn reorder(h: *Harness, ws: []const u8, ordered_ids: []const []const u8, expect: []const u16) ![]u8 {
    const path = try reorderUrl(ws);
    defer gpa.free(path);
    var body = std.ArrayList(u8).empty;
    defer body.deinit(gpa);
    try body.appendSlice(gpa, "{\"ordered_ids\":[");
    for (ordered_ids, 0..) |id, index| {
        if (index > 0) try body.append(gpa, ',');
        try body.append(gpa, '"');
        try body.appendSlice(gpa, id);
        try body.append(gpa, '"');
    }
    try body.appendSlice(gpa, "]}");

    var r = try h.http(io, .PATCH, path, .{ .json_body = body.items, .expect = expect });
    defer r.deinit();
    return gpa.dupe(u8, r.body);
}

test "documents_reorder_persists_the_new_order_across_a_fresh_list_read" {
    try harness.requirePabrikBin(io, gpa);
    var h = try Harness.boot(io, gpa, .{});
    defer h.deinit(io) catch |err| std.debug.print("teardown: {s}\n", .{@errorName(err)});

    const ws = try createWorkspace(&h, "reorder-persist-ws");
    defer gpa.free(ws);
    const alpha = try createDocument(&h, ws, "Alpha");
    defer gpa.free(alpha);
    const beta = try createDocument(&h, ws, "Beta");
    defer gpa.free(beta);
    const gamma = try createDocument(&h, ws, "Gamma");
    defer gpa.free(gamma);

    var before = try snapshot(&h, ws);
    defer before.deinit();
    try testing.expectEqualStrings("Gamma@-3,Beta@-2,Alpha@-1", before.titles);

    const want = [_][]const u8{ alpha, gamma, beta };
    const raw = try reorder(&h, ws, &want, &.{200});
    defer gpa.free(raw);

    var after = try snapshot(&h, ws);
    defer after.deinit();
    try testing.expectEqualStrings("Alpha@0,Gamma@1,Beta@2", after.titles);
    try testing.expectEqualStrings(alpha, after.idAt(0));
    try testing.expectEqualStrings(gamma, after.idAt(1));
    try testing.expectEqualStrings(beta, after.idAt(2));

    var again = try snapshot(&h, ws);
    defer again.deinit();
    try testing.expectEqualStrings(after.titles, again.titles);
}

test "documents_reorder_moves_the_last_document_to_the_top" {
    try harness.requirePabrikBin(io, gpa);
    var h = try Harness.boot(io, gpa, .{});
    defer h.deinit(io) catch |err| std.debug.print("teardown: {s}\n", .{@errorName(err)});

    const ws = try createWorkspace(&h, "reorder-top-ws");
    defer gpa.free(ws);
    const one = try createDocument(&h, ws, "One");
    defer gpa.free(one);
    const two = try createDocument(&h, ws, "Two");
    defer gpa.free(two);
    const three = try createDocument(&h, ws, "Three");
    defer gpa.free(three);

    var before = try snapshot(&h, ws);
    defer before.deinit();
    const dragged = before.idAt(before.ids.items.len - 1);
    const target = before.idAt(0);
    const rest = try gpa.dupe([]const u8, before.ids.items[1 .. before.ids.items.len - 1]);
    defer gpa.free(rest);

    var ordered = std.ArrayList([]const u8).empty;
    defer ordered.deinit(gpa);
    try ordered.append(gpa, dragged);
    try ordered.append(gpa, target);
    for (rest) |id| try ordered.append(gpa, id);

    const raw = try reorder(&h, ws, ordered.items, &.{200});
    defer gpa.free(raw);

    var after = try snapshot(&h, ws);
    defer after.deinit();
    try testing.expectEqualStrings("One@0,Three@1,Two@2", after.titles);
    try testing.expectEqualStrings(dragged, after.idAt(0));
}

test "documents_reorder_refuses_an_id_from_another_workspace_and_writes_nothing" {
    try harness.requirePabrikBin(io, gpa);
    var h = try Harness.boot(io, gpa, .{});
    defer h.deinit(io) catch |err| std.debug.print("teardown: {s}\n", .{@errorName(err)});

    const mine = try createWorkspace(&h, "reorder-mine-ws");
    defer gpa.free(mine);
    const theirs = try createWorkspace(&h, "reorder-theirs-ws");
    defer gpa.free(theirs);

    const mine_a = try createDocument(&h, mine, "MineA");
    defer gpa.free(mine_a);
    const mine_b = try createDocument(&h, mine, "MineB");
    defer gpa.free(mine_b);
    const foreign = try createDocument(&h, theirs, "Foreign");
    defer gpa.free(foreign);

    var before = try snapshot(&h, mine);
    defer before.deinit();

    const rejected = [_][]const u8{ foreign, mine_a };
    const raw = try reorder(&h, mine, &rejected, &.{404});
    defer gpa.free(raw);

    var after = try snapshot(&h, mine);
    defer after.deinit();
    try testing.expectEqualStrings(before.titles, after.titles);

    var their_list = try snapshot(&h, theirs);
    defer their_list.deinit();
    try testing.expectEqualStrings("Foreign@-1", their_list.titles);
}

test "documents_reorder_refuses_an_unknown_id_and_a_duplicate" {
    try harness.requirePabrikBin(io, gpa);
    var h = try Harness.boot(io, gpa, .{});
    defer h.deinit(io) catch |err| std.debug.print("teardown: {s}\n", .{@errorName(err)});

    const ws = try createWorkspace(&h, "reorder-guard-ws");
    defer gpa.free(ws);
    const a = try createDocument(&h, ws, "GuardA");
    defer gpa.free(a);
    const b = try createDocument(&h, ws, "GuardB");
    defer gpa.free(b);

    var before = try snapshot(&h, ws);
    defer before.deinit();

    const unknown = [_][]const u8{"doc_does_not_exist"};
    const unknown_raw = try reorder(&h, ws, &unknown, &.{404});
    defer gpa.free(unknown_raw);

    const duplicated = [_][]const u8{ a, a, b };
    const duplicate_raw = try reorder(&h, ws, &duplicated, &.{400});
    defer gpa.free(duplicate_raw);

    const empty: []const []const u8 = &.{};
    const empty_raw = try reorder(&h, ws, empty, &.{400});
    defer gpa.free(empty_raw);

    var after = try snapshot(&h, ws);
    defer after.deinit();
    try testing.expectEqualStrings(before.titles, after.titles);
}

test "documents_reorder_keeps_a_new_document_on_top_and_holds_a_long_list" {
    try harness.requirePabrikBin(io, gpa);
    var h = try Harness.boot(io, gpa, .{});
    defer h.deinit(io) catch |err| std.debug.print("teardown: {s}\n", .{@errorName(err)});

    const ws = try createWorkspace(&h, "reorder-long-ws");
    defer gpa.free(ws);

    var created = std.ArrayList([]u8).empty;
    defer {
        for (created.items) |id| gpa.free(id);
        created.deinit(gpa);
    }
    var index: usize = 0;
    while (index < 30) : (index += 1) {
        const title = try std.fmt.allocPrint(gpa, "Doc {d:0>2}", .{index});
        defer gpa.free(title);
        try created.append(gpa, try createDocument(&h, ws, title));
    }

    var before = try snapshot(&h, ws);
    defer before.deinit();
    try testing.expectEqual(@as(usize, 30), before.ids.items.len);

    var reversed = std.ArrayList([]const u8).empty;
    defer reversed.deinit(gpa);
    var cursor = before.ids.items.len;
    while (cursor > 0) {
        cursor -= 1;
        try reversed.append(gpa, before.idAt(cursor));
    }

    const first = try reorder(&h, ws, reversed.items, &.{200});
    defer gpa.free(first);

    var after = try snapshot(&h, ws);
    defer after.deinit();
    try testing.expectEqual(@as(usize, 30), after.positions.items.len);
    try testing.expect(std.mem.startsWith(u8, after.titles, "Doc 00@0,"));
    for (after.positions.items, 0..) |position, order| {
        try testing.expectEqual(@as(i64, @intCast(order)), position);
    }
    try testing.expectEqualStrings(before.idAt(0), after.idAt(29));

    var top_first = std.ArrayList([]const u8).empty;
    defer top_first.deinit(gpa);
    try top_first.append(gpa, before.idAt(0));
    for (reversed.items) |id| {
        if (!std.mem.eql(u8, id, before.idAt(0))) try top_first.append(gpa, id);
    }
    const second = try reorder(&h, ws, top_first.items, &.{200});
    defer gpa.free(second);

    var final = try snapshot(&h, ws);
    defer final.deinit();
    try testing.expectEqualStrings(before.idAt(0), final.idAt(0));

    const fresh = try createDocument(&h, ws, "Fresh");
    defer gpa.free(fresh);
    var with_fresh = try snapshot(&h, ws);
    defer with_fresh.deinit();
    try testing.expectEqualStrings(fresh, with_fresh.idAt(0));
    try testing.expectEqualStrings(before.idAt(0), with_fresh.idAt(1));
}
