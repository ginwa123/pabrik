//! The options every rule is read with: one struct, not one per rule, so
//! adding a rule adds a field here while the CLI keeps a flat flag set.

const std = @import("std");

pub const Options = struct {
    /// Ceiling on the lines one comment block may span.
    max_comment_lines: u32 = 3,
};

/// The defaults, for a caller that has no flags to apply.
pub const defaults: Options = .{};

test "options: the comment-block ceiling defaults to three" {
    const testing = std.testing;
    try testing.expectEqual(@as(u32, 3), defaults.max_comment_lines);
}
