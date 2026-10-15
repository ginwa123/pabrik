//! Data model for the `agent_knowledge` entity table. One row per markdown
//! knowledge file attached to an Agent.

const std = @import("std");

pub const EntityId = []u8;

id: EntityId,
/// FK to `agents.id`. The agent this knowledge file belongs to.
agent_id: EntityId,
/// Absolute path on disk to a markdown file. Validated by the handler
/// (`std.fs.path.isAbsolute`) on INSERT — relative paths return 400.
file_path: []u8,
/// Optional human-readable label. Empty slice is the canonical
/// "no label" sentinel.
label: []u8 = &.{},
/// Drag-reorder position (higher = higher in the list). Mirrors
/// Kanban's `kanban_columns.position` pattern.
position: i64 = 0,
created_at: ?[]u8 = null,
updated_at: ?[]u8 = null,

const Self = @This();

pub const InitArgs = struct {
    id: []const u8,
    agent_id: []const u8,
    file_path: []const u8,
    label: []const u8 = "",
    position: i64 = 0,
    created_at: ?[]const u8 = null,
    updated_at: ?[]const u8 = null,
};

pub fn init(allocator: std.mem.Allocator, args: InitArgs) !Self {
    return .{
        .id = try allocator.dupe(u8, args.id),
        .agent_id = try allocator.dupe(u8, args.agent_id),
        .file_path = try allocator.dupe(u8, args.file_path),
        .label = try allocator.dupe(u8, args.label),
        .position = args.position,
        .created_at = if (args.created_at) |ca| try allocator.dupe(u8, ca) else null,
        .updated_at = if (args.updated_at) |ua| try allocator.dupe(u8, ua) else null,
    };
}

pub fn deinit(self: *Self, allocator: std.mem.Allocator) void {
    allocator.free(self.id);
    allocator.free(self.agent_id);
    allocator.free(self.file_path);
    if (self.label.len > 0) allocator.free(self.label);
    if (self.created_at) |ca| allocator.free(ca);
    if (self.updated_at) |ua| allocator.free(ua);
}

/// Deep-copy constructor.
pub fn clone(self: *const Self, allocator: std.mem.Allocator) !Self {
    return .init(allocator, .{
        .id = self.id,
        .agent_id = self.agent_id,
        .file_path = self.file_path,
        .label = self.label,
        .position = self.position,
        .created_at = if (self.created_at) |ca| ca else null,
        .updated_at = if (self.updated_at) |ua| ua else null,
    });
}