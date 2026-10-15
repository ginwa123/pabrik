//! Data model for the `workspace_items` entity table. Each row is a project
//! belonging to one `workspaces.id`.

const std = @import("std");

pub const EntityId = []u8;

id: EntityId,
workspace_id: []u8,
/// One of `"kanban"` | `"design"` | `"folder"` | `"agent"` | `"routine"`.
item_type: []u8,
created_at: ?[]u8 = null,
updated_at: ?[]u8 = null,
name: ?[]u8 = null,
/// Absolute filesystem path the workspace item points at. NULL for legacy
/// rows and for items created before Migration 025.
path: ?[]u8 = null,
/// Drag-and-drop sort key (Migration 045). Higher = higher in the
/// workspace's item list.
position: i64 = 0,
/// Migration 094 — 1 when this item is the workspace's default project.
/// The partial unique index on (workspace_id) WHERE is_default = 1 is
/// what guarantees a workspace can never have two.
is_default: i64 = 0,

const Self = @This();

pub const InitArgs = struct {
    id: []const u8,
    workspace_id: []const u8,
    item_type: []const u8,
    created_at: ?[]const u8 = null,
    updated_at: ?[]const u8 = null,
    name: ?[]const u8 = null,
    path: ?[]const u8 = null,
    position: i64 = 0,
    is_default: i64 = 0,
};

pub fn init(allocator: std.mem.Allocator, args: InitArgs) !Self {
    return .{
        .id = try allocator.dupe(u8, args.id),
        .workspace_id = try allocator.dupe(u8, args.workspace_id),
        .item_type = try allocator.dupe(u8, args.item_type),
        .created_at = if (args.created_at) |ca| try allocator.dupe(u8, ca) else null,
        .updated_at = if (args.updated_at) |ua| try allocator.dupe(u8, ua) else null,
        .name = if (args.name) |n| try allocator.dupe(u8, n) else null,
        .path = if (args.path) |p| try allocator.dupe(u8, p) else null,
        .position = args.position,
        .is_default = args.is_default,
    };
}

pub fn deinit(self: *Self, allocator: std.mem.Allocator) void {
    allocator.free(self.id);
    allocator.free(self.workspace_id);
    allocator.free(self.item_type);
    if (self.created_at) |ca| allocator.free(ca);
    if (self.updated_at) |ua| allocator.free(ua);
    if (self.name) |n| allocator.free(n);
    if (self.path) |p| allocator.free(p);
}

pub fn clone(self: *const Self, allocator: std.mem.Allocator) !Self {
    return .init(allocator, .{
        .id = self.id,
        .workspace_id = self.workspace_id,
        .item_type = self.item_type,
        .created_at = if (self.created_at) |ca| ca else null,
        .updated_at = if (self.updated_at) |ua| ua else null,
        .name = if (self.name) |n| n else null,
        .path = if (self.path) |p| p else null,
        .position = self.position,
        .is_default = self.is_default,
    });
}

// ===== Tests merged from models_test.zig (2026-09-29 flatten) =====

// Sanity tests for the `src/models/` entity models.

const testing = std.testing;

test "workspace_item: init + deinit with all fields" {
    var w = try init(testing.allocator, .{
        .id = "item_1",
        .workspace_id = "ws_1",
        .item_type = "kanban",
        .name = "Sprint Board",
        .path = "/tmp/board",
        .position = 3,
    });
    defer deinit(&w, testing.allocator);

    try testing.expectEqualStrings("item_1", w.id);
    try testing.expectEqualStrings("kanban", w.item_type);
    try testing.expectEqualStrings("Sprint Board", w.name.?);
    try testing.expectEqualStrings("/tmp/board", w.path.?);
}