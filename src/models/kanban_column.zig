//! Data model for the `kanban_columns` entity table. One row per user-defined
//! kanban column (todo / in progress / done / etc.) under a kanban workspace
//! item. Schema: Migration 051 (`add_kanban` step that creates the table)

const std = @import("std");

pub const EntityId = []u8;

id: EntityId,
workspace_item_id: []u8,
name: []u8,
position: i64,
created_at: []u8,
/// Migration 053 — free-text description of the column's meaning.
/// Empty slice is the canonical "no description" sentinel.
description: []u8 = &.{},

const Self = @This();

pub const InitArgs = struct {
    id: []const u8,
    workspace_item_id: []const u8,
    name: []const u8,
    position: i64,
    created_at: []const u8 = "",
    description: []const u8 = "",
};

pub fn init(allocator: std.mem.Allocator, args: InitArgs) !Self {
    return .{
        .id = try allocator.dupe(u8, args.id),
        .workspace_item_id = try allocator.dupe(u8, args.workspace_item_id),
        .name = try allocator.dupe(u8, args.name),
        .position = args.position,
        .created_at = try allocator.dupe(u8, args.created_at),
        .description = try allocator.dupe(u8, args.description),
    };
}

pub fn deinit(self: *Self, allocator: std.mem.Allocator) void {
    allocator.free(self.id);
    allocator.free(self.workspace_item_id);
    allocator.free(self.name);
    allocator.free(self.created_at);
    if (self.description.len > 0) allocator.free(self.description);
}

pub fn clone(self: *const Self, allocator: std.mem.Allocator) !Self {
    return .init(allocator, .{
        .id = self.id,
        .workspace_item_id = self.workspace_item_id,
        .name = self.name,
        .position = self.position,
        .created_at = self.created_at,
        .description = self.description,
    });
}

// ===== Tests merged from models_test.zig (2026-09-29 flatten) =====

// Sanity tests for the `src/models/` entity models.

const testing = std.testing;

test "kanban_column: init + deinit" {
    var c = try init(testing.allocator, .{
        .id = "col_1",
        .workspace_item_id = "item_1",
        .name = "todo",
        .position = 0,
        .description = "Open work",
    });
    defer deinit(&c, testing.allocator);

    try testing.expectEqualStrings("col_1", c.id);
    try testing.expectEqualStrings("todo", c.name);
    try testing.expectEqualStrings("Open work", c.description);
}