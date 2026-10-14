//! Data model for the `workspaces` entity table. One row per workspace.

const std = @import("std");

pub const EntityId = []u8;

id: EntityId,
name: []u8,
created_at: ?[]u8 = null,
updated_at: ?[]u8 = null,
/// Drag-and-drop sort key (Migration 022). Higher = higher in the
/// sidebar. Scoped globally (no parent scope).
position: i64 = 0,

const Self = @This();

pub const InitArgs = struct {
    id: []const u8,
    name: []const u8,
    created_at: ?[]const u8 = null,
    updated_at: ?[]const u8 = null,
    position: i64 = 0,
};

pub fn init(allocator: std.mem.Allocator, args: InitArgs) !Self {
    return .{
        .id = try allocator.dupe(u8, args.id),
        .name = try allocator.dupe(u8, args.name),
        .created_at = if (args.created_at) |ca| try allocator.dupe(u8, ca) else null,
        .updated_at = if (args.updated_at) |ua| try allocator.dupe(u8, ua) else null,
        .position = args.position,
    };
}

pub fn deinit(self: *Self, allocator: std.mem.Allocator) void {
    allocator.free(self.id);
    if (self.name.len > 0) allocator.free(self.name);
    if (self.created_at) |ca| allocator.free(ca);
    if (self.updated_at) |ua| allocator.free(ua);
}

/// Deep-copy constructor. Useful for callers that need an owned copy
/// of an existing instance (e.g. a row pulled from a query result).
pub fn clone(self: *const Self, allocator: std.mem.Allocator) !Self {
    return .init(allocator, .{
        .id = self.id,
        .name = self.name,
        .created_at = if (self.created_at) |ca| ca else null,
        .updated_at = if (self.updated_at) |ua| ua else null,
        .position = self.position,
    });
}

// ===== Tests merged from models_test.zig (2026-09-29 flatten) =====

// Sanity tests for the `src/models/` entity models.

const testing = std.testing;

test "workspace: init + deinit + field access" {
    var w = try init(testing.allocator, .{
        .id = "ws_1",
        .name = "My Workspace",
        .position = 5,
    });
    defer deinit(&w, testing.allocator);

    // External callers can read fields directly (file-level struct).
    try testing.expectEqualStrings("ws_1", w.id);
    try testing.expectEqualStrings("My Workspace", w.name);
    try testing.expectEqual(@as(i64, 5), w.position);
    try testing.expect(w.created_at == null);
    try testing.expect(w.updated_at == null);
}

test "workspace: clone produces independent copy" {
    var original = try init(testing.allocator, .{
        .id = "ws_1",
        .name = "Original",
    });
    defer deinit(&original, testing.allocator);

    var copy = try clone(&original, testing.allocator);
    defer deinit(&copy, testing.allocator);

    try testing.expectEqualStrings("ws_1", copy.id);
    try testing.expectEqualStrings("Original", copy.name);
    // Deep copy — different backing allocations.
    try testing.expect(original.id.ptr != copy.id.ptr);
    try testing.expect(original.name.ptr != copy.name.ptr);
}

test "every model: clone is deep copy with distinct pointers" {
    var w = try init(testing.allocator, .{
        .id = "ws_1",
        .name = "Original",
        .position = 1,
    });
    defer deinit(&w, testing.allocator);

    var copy = try clone(&w, testing.allocator);
    defer deinit(&copy, testing.allocator);

    // Strings point to different heap allocations.
    try testing.expect(w.id.ptr != copy.id.ptr);
    try testing.expect(w.name.ptr != copy.name.ptr);
    // But have equal contents.
    try testing.expectEqualStrings(w.id, copy.id);
    try testing.expectEqualStrings(w.name, copy.name);
}