const std = @import("std");

pub const Pattern = struct {
    method: []const u8,
    path: []const u8,
};

pub const unmatched = "unmatched";

const method_slots = [_][]const u8{ "GET", "HEAD", "POST", "PUT", "PATCH", "DELETE", "OPTIONS" };

fn slotFor(method: []const u8) ?usize {
    for (method_slots, 0..) |candidate, index| {
        if (std.mem.eql(u8, candidate, method)) return index;
    }
    return null;
}

const Node = struct {
    literals: std.StringHashMapUnmanaged(u32) = .empty,
    param: ?u32 = null,
    templates: [method_slots.len]?[]const u8 = [_]?[]const u8{null} ** method_slots.len,
};

pub const RouteIndex = struct {
    allocator: std.mem.Allocator,
    nodes: std.ArrayListUnmanaged(Node) = .empty,

    pub fn init(allocator: std.mem.Allocator, patterns: []const Pattern) !RouteIndex {
        var self: RouteIndex = .{ .allocator = allocator };
        errdefer self.deinit();
        try self.nodes.append(allocator, .{});
        for (patterns) |pattern| {
            const slot = slotFor(pattern.method) orelse continue;
            var node_index: u32 = 0;
            var segments = std.mem.splitScalar(u8, pattern.path, '/');
            while (segments.next()) |segment| {
                node_index = try self.child(node_index, segment, isParam(segment));
            }
            self.nodes.items[node_index].templates[slot] = pattern.path;
        }
        return self;
    }

    pub fn deinit(self: *RouteIndex) void {
        for (self.nodes.items) |*node| {
            var literals = node.literals.keyIterator();
            while (literals.next()) |literal| self.allocator.free(literal.*);
            node.literals.deinit(self.allocator);
        }
        self.nodes.deinit(self.allocator);
    }

    pub fn resolve(self: *const RouteIndex, method: []const u8, path: []const u8) []const u8 {
        const slot = slotFor(method) orelse return unmatched;
        var node_index: u32 = 0;
        var segments = std.mem.splitScalar(u8, path, '/');
        while (segments.next()) |segment| {
            const node = &self.nodes.items[node_index];
            if (node.literals.get(segment)) |literal_child| {
                node_index = literal_child;
            } else if (node.param) |param_child| {
                node_index = param_child;
            } else return unmatched;
        }
        return self.nodes.items[node_index].templates[slot] orelse unmatched;
    }

    fn child(self: *RouteIndex, parent: u32, segment: []const u8, param: bool) !u32 {
        if (param) {
            if (self.nodes.items[parent].param) |existing| return existing;
            const created = try self.addNode();
            self.nodes.items[parent].param = created;
            return created;
        }
        if (self.nodes.items[parent].literals.get(segment)) |existing| return existing;
        const owned = try self.allocator.dupe(u8, segment);
        errdefer self.allocator.free(owned);
        const created = try self.addNode();
        try self.nodes.items[parent].literals.put(self.allocator, owned, created);
        return created;
    }

    fn addNode(self: *RouteIndex) !u32 {
        const index: u32 = @intCast(self.nodes.items.len);
        try self.nodes.append(self.allocator, .{});
        return index;
    }
};

fn isParam(segment: []const u8) bool {
    return segment.len > 0 and segment[0] == ':';
}

test "resolve replaces id segments with the template that claims them" {
    var index = try RouteIndex.init(std.testing.allocator, &.{
        .{ .method = "GET", .path = "/api/workspaces/:workspace_id/items/:item_id/tasks" },
        .{ .method = "GET", .path = "/api/workspaces/:workspace_id/items/:item_id/tasks/:task_id" },
    });
    defer index.deinit();

    try std.testing.expectEqualStrings(
        "/api/workspaces/:workspace_id/items/:item_id/tasks/:task_id",
        index.resolve("GET", "/api/workspaces/ws_1/items/item_9/tasks/task_7"),
    );
    try std.testing.expectEqualStrings(
        "/api/workspaces/:workspace_id/items/:item_id/tasks",
        index.resolve("GET", "/api/workspaces/ws_1/items/item_9/tasks"),
    );
}

test "resolve prefers a literal segment over a param sibling" {
    var index = try RouteIndex.init(std.testing.allocator, &.{
        .{ .method = "GET", .path = "/api/session/:session_id" },
        .{ .method = "GET", .path = "/api/session/usage" },
    });
    defer index.deinit();

    try std.testing.expectEqualStrings("/api/session/usage", index.resolve("GET", "/api/session/usage"));
    try std.testing.expectEqualStrings("/api/session/:session_id", index.resolve("GET", "/api/session/sess_1"));
}

test "resolve keeps one template per method on a shared path shape" {
    var index = try RouteIndex.init(std.testing.allocator, &.{
        .{ .method = "GET", .path = "/api/session/:session_id" },
        .{ .method = "POST", .path = "/api/session/:session" },
    });
    defer index.deinit();

    try std.testing.expectEqualStrings("/api/session/:session_id", index.resolve("GET", "/api/session/sess_1"));
    try std.testing.expectEqualStrings("/api/session/:session", index.resolve("POST", "/api/session/sess_1"));
}

test "resolve reports unmatched for an unknown path, method or depth" {
    var index = try RouteIndex.init(std.testing.allocator, &.{
        .{ .method = "GET", .path = "/api/session/:session_id/messages" },
    });
    defer index.deinit();

    try std.testing.expectEqualStrings(unmatched, index.resolve("GET", "/api/nope"));
    try std.testing.expectEqualStrings(unmatched, index.resolve("GET", "/api/session/sess_1/messages/extra"));
    try std.testing.expectEqualStrings(unmatched, index.resolve("DELETE", "/api/session/sess_1/messages"));
    try std.testing.expectEqualStrings(unmatched, index.resolve("BREW", "/api/session/sess_1/messages"));
}

test "resolve treats a trailing slash as another segment, which no route claims" {
    var index = try RouteIndex.init(std.testing.allocator, &.{
        .{ .method = "GET", .path = "/api/session/:session_id" },
    });
    defer index.deinit();

    try std.testing.expectEqualStrings(unmatched, index.resolve("GET", "/api/session/sess_1/"));
    try std.testing.expectEqualStrings("/api/session/:session_id", index.resolve("GET", "/api/session/sess_1"));
}

test "resolve lets an empty segment match a param, as the router does" {
    var index = try RouteIndex.init(std.testing.allocator, &.{
        .{ .method = "GET", .path = "/api/session/:session_id/usage" },
    });
    defer index.deinit();

    try std.testing.expectEqualStrings(
        "/api/session/:session_id/usage",
        index.resolve("GET", "/api/session//usage"),
    );
}
