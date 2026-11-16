//! Data model for the `workspace_item_tasks` entity table.

const std = @import("std");

pub const EntityId = []u8;

id: EntityId,
name: []u8,
workspace_item_id: []u8,
created_at: []u8,
updated_at: []u8,
/// One of `"standard"` | `"memory"` | `"unknown"` (or any string the caller wrote).
task_type: []u8,
is_pinned: bool = false,
pinned_position: i64 = 0,
/// Migration 062 — free-form description.
description: []u8 = &.{},
/// Migration 046 — unix-ms timestamp of the last user-initiated edit.
last_human_touched_at: ?[]u8 = null,
/// Migration 067 — JSON-encode array string.
tags: []u8 = &.{},
/// Migration 069 — `||`-delimited base64 data URLs.
image_urls: []u8 = &.{},
/// Migration 070 — per-task cwd override.
cwd: []u8 = &.{},

const Self = @This();

pub const InitArgs = struct {
    id: []const u8,
    name: []const u8,
    workspace_item_id: []const u8,
    created_at: []const u8 = "",
    updated_at: []const u8 = "",
    task_type: []const u8 = "standard",
    is_pinned: bool = false,
    pinned_position: i64 = 0,
    description: []const u8 = "",
    last_human_touched_at: ?[]const u8 = null,
    tags: []const u8 = "",
    image_urls: []const u8 = "",
    cwd: []const u8 = "",
};

pub fn init(allocator: std.mem.Allocator, args: InitArgs) !Self {
    return .{
        .id = try allocator.dupe(u8, args.id),
        .name = try allocator.dupe(u8, args.name),
        .workspace_item_id = try allocator.dupe(u8, args.workspace_item_id),
        .created_at = try allocator.dupe(u8, args.created_at),
        .updated_at = try allocator.dupe(u8, args.updated_at),
        .task_type = try allocator.dupe(u8, args.task_type),
        .is_pinned = args.is_pinned,
        .pinned_position = args.pinned_position,
        .description = try allocator.dupe(u8, args.description),
        .last_human_touched_at = if (args.last_human_touched_at) |lht|
            try allocator.dupe(u8, lht)
        else
            null,
        .tags = try allocator.dupe(u8, args.tags),
        .image_urls = try allocator.dupe(u8, args.image_urls),
        .cwd = try allocator.dupe(u8, args.cwd),
    };
}

pub fn deinit(self: *Self, allocator: std.mem.Allocator) void {
    allocator.free(self.id);
    allocator.free(self.name);
    allocator.free(self.workspace_item_id);
    allocator.free(self.created_at);
    allocator.free(self.updated_at);
    allocator.free(self.task_type);
    if (self.description.len > 0) allocator.free(self.description);
    if (self.last_human_touched_at) |lht| allocator.free(lht);
    if (self.tags.len > 0) allocator.free(self.tags);
    if (self.image_urls.len > 0) allocator.free(self.image_urls);
    if (self.cwd.len > 0) allocator.free(self.cwd);
}

pub fn clone(self: *const Self, allocator: std.mem.Allocator) !Self {
    return .init(allocator, .{
        .id = self.id,
        .name = self.name,
        .workspace_item_id = self.workspace_item_id,
        .created_at = self.created_at,
        .updated_at = self.updated_at,
        .task_type = self.task_type,
        .is_pinned = self.is_pinned,
        .pinned_position = self.pinned_position,
        .description = self.description,
        .last_human_touched_at = if (self.last_human_touched_at) |lht| lht else null,
        .tags = self.tags,
        .image_urls = self.image_urls,
        .cwd = self.cwd,
    });
}

// ===== Tests merged from models_test.zig (2026-09-29 flatten) =====

// Sanity tests for the `src/models/` entity models.

const testing = std.testing;

test "workspace_item_task: init + deinit with all fields" {
    var t = try init(testing.allocator, .{
        .id = "task_1",
        .name = "Build feature",
        .workspace_item_id = "item_1",
        .description = "A task description",
        .tags = "[\"bug\",\"urgent\"]",
        .image_urls = "data:image/png;base64,abc",
        .cwd = "/home/me",
        .is_pinned = true,
        .pinned_position = 2,
    });
    defer deinit(&t, testing.allocator);

    try testing.expectEqualStrings("task_1", t.id);
    try testing.expect(t.is_pinned);
    try testing.expectEqual(@as(i64, 2), t.pinned_position);
    try testing.expectEqualStrings("A task description", t.description);
    try testing.expectEqualStrings("[\"bug\",\"urgent\"]", t.tags);
}