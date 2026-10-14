//! Data model for the `agent_memories` entity table. Cross-session,
//! cross-workspace note store backing the `save_memory` and `load_memory`
//! agent tools.

const std = @import("std");

pub const EntityId = []u8;

id: EntityId,
/// The note body. 1 KiB – 1 MiB (validated by the `save_memory` tool
/// handler). Empty content is rejected on INSERT (matches the
/// `error.InvalidContent` contract from `agent_memories.zig`).
content: []u8,
/// `||`-delimited tags string. Empty slice is the canonical "no
/// tags" sentinel.
tags: []u8 = &.{},
created_at: []u8,
updated_at: []u8,

const Self = @This();

pub const InitArgs = struct {
    id: []const u8,
    content: []const u8,
    tags: []const u8 = "",
    created_at: []const u8 = "",
    updated_at: []const u8 = "",
};

pub fn init(allocator: std.mem.Allocator, args: InitArgs) !Self {
    return .{
        .id = try allocator.dupe(u8, args.id),
        .content = try allocator.dupe(u8, args.content),
        .tags = try allocator.dupe(u8, args.tags),
        .created_at = try allocator.dupe(u8, args.created_at),
        .updated_at = try allocator.dupe(u8, args.updated_at),
    };
}

pub fn deinit(self: *Self, allocator: std.mem.Allocator) void {
    allocator.free(self.id);
    allocator.free(self.content);
    if (self.tags.len > 0) allocator.free(self.tags);
    allocator.free(self.created_at);
    allocator.free(self.updated_at);
}

pub fn clone(self: *const Self, allocator: std.mem.Allocator) !Self {
    return .init(allocator, .{
        .id = self.id,
        .content = self.content,
        .tags = self.tags,
        .created_at = self.created_at,
        .updated_at = self.updated_at,
    });
}

// ===== Tests merged from models_test.zig (2026-09-29 flatten) =====

// Sanity tests for the `src/models/` entity models.

const testing = std.testing;

test "agent_memory: init + deinit" {
    var m = try init(testing.allocator, .{
        .id = "mem_1",
        .content = "User prefers Anthropic Sonnet for code review.",
        .tags = "preferences||models",
        .created_at = "2026-08-15 12:00:00",
        .updated_at = "2026-08-15 12:00:00",
    });
    defer deinit(&m, testing.allocator);

    try testing.expectEqualStrings("mem_1", m.id);
    try testing.expectEqualStrings("User prefers Anthropic Sonnet for code review.", m.content);
    try testing.expectEqualStrings("preferences||models", m.tags);
}