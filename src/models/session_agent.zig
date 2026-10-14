//! Data model for the `session_agents` entity table. Maps each session to the
//! sub-agent name it currently runs (one row per session; PRIMARY KEY on
//! session_id).

const std = @import("std");

pub const EntityId = []u8;

session_id: EntityId,
/// Default is `"Agent"`. Custom sub-agent names like
/// `"code-reviewer"`, `"frontend-engineer"`, etc. are stored
/// verbatim.
agent_name: []u8,
/// Unix-seconds timestamp of the last sub-agent swap.
updated_at: i64 = 0,

const Self = @This();

pub const InitArgs = struct {
    session_id: []const u8,
    agent_name: []const u8,
    updated_at: i64 = 0,
};

pub fn init(allocator: std.mem.Allocator, args: InitArgs) !Self {
    return .{
        .session_id = try allocator.dupe(u8, args.session_id),
        .agent_name = try allocator.dupe(u8, args.agent_name),
        .updated_at = args.updated_at,
    };
}

pub fn deinit(self: *Self, allocator: std.mem.Allocator) void {
    allocator.free(self.session_id);
    allocator.free(self.agent_name);
}

pub fn clone(self: *const Self, allocator: std.mem.Allocator) !Self {
    return .init(allocator, .{
        .session_id = self.session_id,
        .agent_name = self.agent_name,
        .updated_at = self.updated_at,
    });
}

// ===== Tests merged from models_test.zig (2026-09-29 flatten) =====

// Sanity tests for the `src/models/` entity models.

const testing = std.testing;

test "session_agent: init + deinit" {
    var a = try init(testing.allocator, .{
        .session_id = "session_1",
        .agent_name = "code-reviewer",
        .updated_at = 1786000000,
    });
    defer deinit(&a, testing.allocator);

    try testing.expectEqualStrings("session_1", a.session_id);
    try testing.expectEqualStrings("code-reviewer", a.agent_name);
    try testing.expectEqual(@as(i64, 1786000000), a.updated_at);
}