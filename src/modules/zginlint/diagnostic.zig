//! A finding, in the shape ESLint reports one: a rule id, a position, and
//! the message the rule wrote.

const std = @import("std");

pub const Diagnostic = struct {
    /// Rule that produced this diagnostic, e.g. `zginlint/max-comment-lines`.
    rule_id: []const u8,
    /// 1-based line the finding is reported at.
    line: u32,
    /// 1-based column, unless the rule only knows the line.
    column: u32 = 1,
    /// One line, owned by whichever list carries this diagnostic.
    message: []const u8,

    pub fn deinit(self: *Diagnostic, allocator: std.mem.Allocator) void {
        allocator.free(self.message);
        self.* = .{ .rule_id = &.{}, .line = 0, .message = &.{} };
    }
};

/// Free a diagnostics slice and every message inside it.
pub fn deinitAll(allocator: std.mem.Allocator, diagnostics: []Diagnostic) void {
    for (diagnostics) |*item| item.deinit(allocator);
    allocator.free(diagnostics);
}

const testing = std.testing;

test "diagnostic: deinit frees the message it owns" {
    const message = try testing.allocator.dupe(u8, "a message");
    var item: Diagnostic = .{ .rule_id = "zginlint/x", .line = 4, .message = message };
    item.deinit(testing.allocator);
    try testing.expectEqual(@as(u32, 0), item.line);
}

test "diagnostic: deinitAll frees a whole slice" {
    const diagnostics = try testing.allocator.alloc(Diagnostic, 2);
    diagnostics[0] = .{ .rule_id = "zginlint/x", .line = 1, .message = try testing.allocator.dupe(u8, "one") };
    diagnostics[1] = .{ .rule_id = "zginlint/y", .line = 2, .message = try testing.allocator.dupe(u8, "two") };
    deinitAll(testing.allocator, diagnostics);
}
