//! Data model for the `agent_tools` entity table. One row per tool explicitly
//! enabled on an Agent.

const std = @import("std");

pub const EntityId = []u8;

id: EntityId,
/// FK to `agents.id`. The agent this tool row belongs to.
agent_id: EntityId,
/// Canonical tool name (e.g. "bash", "read_file"). Must match an entry
/// in `tools_equipped.UNIFIED_TOOL_REGISTRY()` — the handler validates
/// this on INSERT (400 if unknown).
tool_name: []u8,
/// 1 = enabled, 0 = disabled. v1 always sends 1; the column exists for
/// future "temporarily disable without removing" UX (spec D10).
enabled: u8 = 1,
created_at: ?[]u8 = null,

const Self = @This();

pub const InitArgs = struct {
    id: []const u8,
    agent_id: []const u8,
    tool_name: []const u8,
    enabled: u8 = 1,
    created_at: ?[]const u8 = null,
};

pub fn init(allocator: std.mem.Allocator, args: InitArgs) !Self {
    return .{
        .id = try allocator.dupe(u8, args.id),
        .agent_id = try allocator.dupe(u8, args.agent_id),
        .tool_name = try allocator.dupe(u8, args.tool_name),
        .enabled = args.enabled,
        .created_at = if (args.created_at) |ca| try allocator.dupe(u8, ca) else null,
    };
}

pub fn deinit(self: *Self, allocator: std.mem.Allocator) void {
    allocator.free(self.id);
    allocator.free(self.agent_id);
    allocator.free(self.tool_name);
    if (self.created_at) |ca| allocator.free(ca);
}

/// Deep-copy constructor.
pub fn clone(self: *const Self, allocator: std.mem.Allocator) !Self {
    return .init(allocator, .{
        .id = self.id,
        .agent_id = self.agent_id,
        .tool_name = self.tool_name,
        .enabled = self.enabled,
        .created_at = if (self.created_at) |ca| ca else null,
    });
}