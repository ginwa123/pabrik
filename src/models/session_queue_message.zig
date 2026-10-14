//! Data model for the `session_queue_messages` entity table. Pending user
//! messages queued behind a running session.

const std = @import("std");

pub const EntityId = []u8;

id: EntityId,
session_id: []u8,
/// The queued message text. NULL when the queued item is an
/// image-only message (Migration 068 relaxed the NOT NULL
/// constraint for the `image_url`-only case).
message: ?[]u8 = null,
/// Data URL of an attached image (Migration 060).
image_url: ?[]u8 = null,
created_at: []u8,

const Self = @This();

pub const InitArgs = struct {
    id: []const u8,
    session_id: []const u8,
    message: ?[]const u8 = null,
    image_url: ?[]const u8 = null,
    created_at: []const u8 = "",
};

pub fn init(allocator: std.mem.Allocator, args: InitArgs) !Self {
    return .{
        .id = try allocator.dupe(u8, args.id),
        .session_id = try allocator.dupe(u8, args.session_id),
        .message = if (args.message) |m| try allocator.dupe(u8, m) else null,
        .image_url = if (args.image_url) |iu|
            try allocator.dupe(u8, iu)
        else
            null,
        .created_at = try allocator.dupe(u8, args.created_at),
    };
}

pub fn deinit(self: *Self, allocator: std.mem.Allocator) void {
    allocator.free(self.id);
    allocator.free(self.session_id);
    if (self.message) |m| allocator.free(m);
    if (self.image_url) |iu| allocator.free(iu);
    allocator.free(self.created_at);
}

pub fn clone(self: *const Self, allocator: std.mem.Allocator) !Self {
    return .init(allocator, .{
        .id = self.id,
        .session_id = self.session_id,
        .message = if (self.message) |m| m else null,
        .image_url = if (self.image_url) |iu| iu else null,
        .created_at = self.created_at,
    });
}

// ===== Tests merged from models_test.zig (2026-09-29 flatten) =====

// Sanity tests for the `src/models/` entity models.

const testing = std.testing;

test "session_queue_message: init + deinit with image-only" {
    var m = try init(testing.allocator, .{
        .id = "q_1",
        .session_id = "session_1",
        .image_url = "data:image/png;base64,abc",
    });
    defer deinit(&m, testing.allocator);

    try testing.expectEqualStrings("q_1", m.id);
    try testing.expect(m.message == null);
    try testing.expectEqualStrings("data:image/png;base64,abc", m.image_url.?);
}