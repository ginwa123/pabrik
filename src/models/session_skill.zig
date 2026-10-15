//! Data model for the `session_skills` entity table. Tracks which skills each
//! session has loaded.

const std = @import("std");

pub const EntityId = struct {
    session_id: []const u8,
    skill_name: []const u8,
};

session_id: []u8,
skill_name: []u8,
/// The verbatim SKILL.MD content as loaded at `loaded_at`. Used by
/// the compact-and-rehydrate flow to detect drift between the
/// on-disk skill file and what the agent has in context.
content: []u8,
/// Unix-seconds timestamp of the load event.
loaded_at: i64 = 0,

const Self = @This();

pub const InitArgs = struct {
    session_id: []const u8,
    skill_name: []const u8,
    content: []const u8,
    loaded_at: i64 = 0,
};

pub fn init(allocator: std.mem.Allocator, args: InitArgs) !Self {
    return .{
        .session_id = try allocator.dupe(u8, args.session_id),
        .skill_name = try allocator.dupe(u8, args.skill_name),
        .content = try allocator.dupe(u8, args.content),
        .loaded_at = args.loaded_at,
    };
}

pub fn deinit(self: *Self, allocator: std.mem.Allocator) void {
    allocator.free(self.session_id);
    allocator.free(self.skill_name);
    allocator.free(self.content);
}

pub fn clone(self: *const Self, allocator: std.mem.Allocator) !Self {
    return .init(allocator, .{
        .session_id = self.session_id,
        .skill_name = self.skill_name,
        .content = self.content,
        .loaded_at = self.loaded_at,
    });
}

// ===== Tests merged from models_test.zig (2026-09-29 flatten) =====

// Sanity tests for the `src/models/` entity models.

const testing = std.testing;

test "session_skill: init + deinit" {
    var s = try init(testing.allocator, .{
        .session_id = "session_1",
        .skill_name = "test-driven-development",
        .content = "# TDD\n\nWrite tests first.",
        .loaded_at = 1786000000,
    });
    defer deinit(&s, testing.allocator);

    try testing.expectEqualStrings("session_1", s.session_id);
    try testing.expectEqualStrings("test-driven-development", s.skill_name);
    try testing.expectEqualStrings("# TDD\n\nWrite tests first.", s.content);
    try testing.expectEqual(@as(i64, 1786000000), s.loaded_at);
}