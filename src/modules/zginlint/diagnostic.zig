//! A finding, in the shape ESLint reports one: a rule id, a position, and
//! the numbers the rule was measuring against.

const std = @import("std");

pub const Diagnostic = struct {
    /// Rule that produced this diagnostic, e.g. `zginlint/max-comment-lines`.
    rule_id: []const u8,
    /// 1-based line the finding is reported at.
    line: u32,
    /// 1-based column. Every rule today reports the start of a line.
    column: u32 = 1,
    /// What the rule measured, and the ceiling it was measured against.
    lines_in_block: u32,
    max_lines: u32,
};

/// The one-line description of a diagnostic: what is wrong, and how far
/// past the ceiling it is.
pub fn message(allocator: std.mem.Allocator, diagnostic: Diagnostic) ![]u8 {
    return std.fmt.allocPrint(
        allocator,
        "Comment block has {d} lines; max is {d}",
        .{ diagnostic.lines_in_block, diagnostic.max_lines },
    );
}
