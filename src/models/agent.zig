//! Data model for the `agents` entity table.

const std = @import("std");

pub const EntityId = []u8;

id: EntityId,
/// The workspace_item this agent belongs to.
workspace_item_id: EntityId,
/// Free-form description.
description: []u8 = &.{},
created_at: ?[]u8 = null,
updated_at: ?[]u8 = null,

const Self = @This();

pub const InitArgs = struct {
    id: []const u8,
    workspace_item_id: []const u8,
    description: []const u8 = "",
    created_at: ?[]const u8 = null,
    updated_at: ?[]const u8 = null,
};

pub fn init(allocator: std.mem.Allocator, args: InitArgs) !Self {
    return .{
        .id = try allocator.dupe(u8, args.id),
        .workspace_item_id = try allocator.dupe(u8, args.workspace_item_id),
        .description = try allocator.dupe(u8, args.description),
        .created_at = if (args.created_at) |ca| try allocator.dupe(u8, ca) else null,
        .updated_at = if (args.updated_at) |ua| try allocator.dupe(u8, ua) else null,
    };
}

pub fn deinit(self: *Self, allocator: std.mem.Allocator) void {
    allocator.free(self.id);
    allocator.free(self.workspace_item_id);
    if (self.description.len > 0) allocator.free(self.description);
    if (self.created_at) |ca| allocator.free(ca);
    if (self.updated_at) |ua| allocator.free(ua);
}

/// Deep-copy constructor.
pub fn clone(self: *const Self, allocator: std.mem.Allocator) !Self {
    return .init(allocator, .{
        .id = self.id,
        .workspace_item_id = self.workspace_item_id,
        .description = self.description,
        .created_at = if (self.created_at) |ca| ca else null,
        .updated_at = if (self.updated_at) |ua| ua else null,
    });
}