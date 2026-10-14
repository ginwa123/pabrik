//! `zginlint/max-comment-lines`: a comment block may not exceed N lines.
//! A block is a run of consecutive comment lines, and the finding is reported
//! at the block's first line.

const std = @import("std");
const comment_scan = @import("../comment_scan.zig");
const diagnostic = @import("../diagnostic.zig");

pub const id = "zginlint/max-comment-lines";

/// Three lines, in the shape of ESLint's `max-len`: one number, one rule.
pub const default_max_lines: u32 = 3;

pub const Options = struct {
    max_lines: u32 = default_max_lines,
};

/// Append one diagnostic per comment block longer than `options.max_lines`.
pub fn check(
    allocator: std.mem.Allocator,
    source: []const u8,
    options: Options,
    out: *std.ArrayList(diagnostic.Diagnostic),
) !void {
    const blocks = try comment_scan.commentBlocks(allocator, source);
    defer allocator.free(blocks);
    for (blocks) |block| {
        if (block.line_count <= options.max_lines) continue;
        try out.append(allocator, .{
            .rule_id = id,
            .line = block.first_line,
            .lines_in_block = block.line_count,
            .max_lines = options.max_lines,
        });
    }
}

const testing = std.testing;

fn expectReportedLines(expected: []const u32, source: []const u8) !void {
    var found: std.ArrayList(diagnostic.Diagnostic) = .empty;
    defer found.deinit(testing.allocator);
    try check(testing.allocator, source, .{}, &found);
    try testing.expectEqual(expected.len, found.items.len);
    for (expected, found.items) |line, got| try testing.expectEqual(line, got.line);
}

test "max-comment-lines: a four-line block is reported at its first line" {
    try expectReportedLines(&.{3}, "const x = 1;\n\n// one\n// two\n// three\n// four\n");
}

test "max-comment-lines: a three-line block is allowed" {
    try expectReportedLines(&.{}, "// one\n// two\n// three\nconst x = 1;\n");
}

test "max-comment-lines: every block over the ceiling is reported" {
    try expectReportedLines(&.{ 1, 6 }, "// a\n// b\n// c\n// d\n\n// e\n// f\n// g\n// h\n");
}

test "max-comment-lines: a long block comment is one finding, not one per line" {
    try expectReportedLines(&.{2}, "const x = 1;\n/* one\n two\n three\n four\n*/\n");
}

test "max-comment-lines: the ceiling is configurable" {
    var found: std.ArrayList(diagnostic.Diagnostic) = .empty;
    defer found.deinit(testing.allocator);
    try check(testing.allocator, "// one\n// two\n", .{ .max_lines = 1 }, &found);
    try testing.expectEqual(@as(usize, 1), found.items.len);
    try testing.expectEqual(@as(u32, 2), found.items[0].lines_in_block);
    try testing.expectEqual(@as(u32, 1), found.items[0].max_lines);
}

test "max-comment-lines: a trailing comment after code is not a block" {
    try expectReportedLines(&.{}, "const x = 1; // one\nconst y = 2; // two\nconst z = 3; // three\nconst w = 4; // four\n");
}

test "max-comment-lines: a multi-line string literal is not a comment block" {
    const fence = [2]u8{ 92, 92 };
    const source = "const s =\n    " ++ fence ++ "one\n    " ++ fence ++ "two\n" ++
        "    " ++ fence ++ "three\n    " ++ fence ++ "four\n;\n";
    try expectReportedLines(&.{}, source);
}

test "max-comment-lines: a diagnostic names its rule" {
    var found: std.ArrayList(diagnostic.Diagnostic) = .empty;
    defer found.deinit(testing.allocator);
    try check(testing.allocator, "// one\n// two\n// three\n// four\n", .{}, &found);
    try testing.expectEqualStrings("zginlint/max-comment-lines", found.items[0].rule_id);
    try testing.expectEqual(@as(u32, 1), found.items[0].column);
}
