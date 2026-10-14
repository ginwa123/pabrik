//! The comment lexer every zginlint rule reads: which lines are comments.
//! A comment line carries comment content and no code byte, so a blank line
//! or a code line ends a block; markers inside literals are text.

const std = @import("std");

/// A run of consecutive comment lines.
pub const Block = struct {
    /// 1-based line number of the block's first line.
    first_line: u32,
    /// How many comment lines the block spans.
    line_count: u32,
};

/// The comment-line numbers of `source`, ascending and unique.
pub fn commentLines(allocator: std.mem.Allocator, source: []const u8) ![]u32 {
    var lines: std.ArrayList(u32) = .empty;
    errdefer lines.deinit(allocator);
    try collect(allocator, source, &lines);
    return lines.toOwnedSlice(allocator);
}

/// Group ascending comment-line numbers into blocks.
pub fn blocksFromLines(allocator: std.mem.Allocator, lines: []const u32) ![]Block {
    var blocks: std.ArrayList(Block) = .empty;
    errdefer blocks.deinit(allocator);
    for (lines, 0..) |line, index| {
        const continues = index > 0 and lines[index - 1] + 1 == line;
        if (continues) {
            blocks.items[blocks.items.len - 1].line_count += 1;
        } else {
            try blocks.append(allocator, .{ .first_line = line, .line_count = 1 });
        }
    }
    return blocks.toOwnedSlice(allocator);
}

/// Both steps, for a rule that only wants the blocks.
pub fn commentBlocks(allocator: std.mem.Allocator, source: []const u8) ![]Block {
    const lines = try commentLines(allocator, source);
    defer allocator.free(lines);
    return blocksFromLines(allocator, lines);
}

/// The scanner's position: one line of state at a time, so the whole
/// classification is a single pass over the bytes.
const Scanner = struct {
    line: u32 = 1,
    block_depth: u32 = 0,
    has_comment: bool = false,
    has_code: bool = false,
    /// Only whitespace has been seen on this line so far.
    at_line_start: bool = true,

    fn flushCommentLine(self: *const Scanner, allocator: std.mem.Allocator, out: *std.ArrayList(u32)) !void {
        if (self.has_comment and !self.has_code) try out.append(allocator, self.line);
    }

    fn endLine(self: *Scanner) void {
        self.line += 1;
        self.has_comment = false;
        self.has_code = false;
        self.at_line_start = true;
    }

    /// A byte inside a block comment is comment content, even if it is the
    /// nested opener or the closer.
    fn scanInsideBlock(self: *Scanner, source: []const u8, index: usize) usize {
        self.has_comment = true;
        self.at_line_start = false;
        if (matches(source, index, "/*")) {
            self.block_depth += 1;
            return index + 2;
        }
        if (matches(source, index, "*/")) {
            self.block_depth -= 1;
            return index + 2;
        }
        return index + 1;
    }

    fn scanInCode(self: *Scanner, source: []const u8, index: usize) usize {
        const byte = source[index];
        if (self.at_line_start) {
            if (byte == ' ' or byte == '\t' or byte == '\r') return index + 1;
            self.at_line_start = false;
            // A multi-line string literal is a run of lines fenced with a
            // backslash pair, and everything after the fence is text.
            if (byte == '\\' and at(source, index + 1, '\\')) {
                self.has_code = true;
                return lineEnd(source, index);
            }
        }
        switch (byte) {
            '"', '\'' => {
                self.has_code = true;
                return skipQuoted(source, index);
            },
            '/' => {
                if (matches(source, index, "//")) {
                    self.has_comment = true;
                    return lineEnd(source, index);
                }
                if (matches(source, index, "/*")) {
                    self.has_comment = true;
                    self.block_depth = 1;
                    return index + 2;
                }
                self.has_code = true;
                return index + 1;
            },
            else => {
                self.has_code = true;
                return index + 1;
            },
        }
    }
};

fn collect(allocator: std.mem.Allocator, source: []const u8, out: *std.ArrayList(u32)) !void {
    var scanner: Scanner = .{};
    var index: usize = 0;
    while (index < source.len) {
        if (source[index] == '\n') {
            try scanner.flushCommentLine(allocator, out);
            scanner.endLine();
            index += 1;
            continue;
        }
        index = if (scanner.block_depth > 0)
            scanner.scanInsideBlock(source, index)
        else
            scanner.scanInCode(source, index);
    }
    try scanner.flushCommentLine(allocator, out);
}

fn at(source: []const u8, index: usize, byte: u8) bool {
    return index < source.len and source[index] == byte;
}

fn matches(source: []const u8, index: usize, needle: []const u8) bool {
    return index + needle.len <= source.len and std.mem.eql(u8, source[index..][0..needle.len], needle);
}

/// Index of the newline that ends the line, or EOF. A `//` comment runs to
/// there, so nothing after it on the line can be code.
fn lineEnd(source: []const u8, index: usize) usize {
    return std.mem.indexOfScalarPos(u8, source, index, '\n') orelse source.len;
}

/// Index just past a string or char literal opened at `index`. A literal
/// cannot span a line break, so an unterminated one stops at the newline.
fn skipQuoted(source: []const u8, index: usize) usize {
    const quote = source[index];
    var cursor = index + 1;
    while (cursor < source.len) : (cursor += 1) {
        switch (source[cursor]) {
            '\\' => cursor += 1,
            '\n' => return cursor,
            else => if (source[cursor] == quote) return cursor + 1,
        }
    }
    return source.len;
}

const testing = std.testing;

fn expectBlocks(expected: []const Block, source: []const u8) !void {
    const blocks = try commentBlocks(testing.allocator, source);
    defer testing.allocator.free(blocks);
    try testing.expectEqual(expected.len, blocks.len);
    for (expected, blocks) |want, got| {
        try testing.expectEqual(want.first_line, got.first_line);
        try testing.expectEqual(want.line_count, got.line_count);
    }
}

test "comment_scan: three line-comment lines are one block of three" {
    try expectBlocks(&.{.{ .first_line = 1, .line_count = 3 }}, "// one\n// two\n// three\nconst x = 1;\n");
}

test "comment_scan: a blank line splits one run into two blocks" {
    try expectBlocks(&.{
        .{ .first_line = 1, .line_count = 2 },
        .{ .first_line = 4, .line_count = 2 },
    }, "// one\n// two\n\n// three\n// four\n");
}

test "comment_scan: a code line splits a run" {
    try expectBlocks(&.{
        .{ .first_line = 1, .line_count = 2 },
        .{ .first_line = 4, .line_count = 1 },
    }, "// one\n// two\nconst x = 1;\n// three\n");
}

test "comment_scan: a trailing comment is not a comment line and starts no run" {
    try expectBlocks(&.{.{ .first_line = 2, .line_count = 1 }}, "const x = 1; // trailing\n// own line\n");
}

test "comment_scan: a comment marker inside a string literal is text" {
    try expectBlocks(
        &.{.{ .first_line = 3, .line_count = 1 }},
        "const url = \"https://x/y\";\nconst y = 1;\n// own line\n",
    );
}

test "comment_scan: a multi-line string is text, fence and all" {
    const fence = [2]u8{ 92, 92 };
    const source = "const s =\n    " ++ fence ++ "// not a comment\n" ++
        "    " ++ fence ++ "/* not one either\n" ++
        ";\n// own line\n";
    try expectBlocks(&.{.{ .first_line = 5, .line_count = 1 }}, source);
}

test "comment_scan: a char literal holding a slash is text" {
    try expectBlocks(
        &.{.{ .first_line = 3, .line_count = 1 }},
        "const pair = \"//\";\nconst slash = '/';\n// own line\n",
    );
}

test "comment_scan: a block comment spans its lines as one block" {
    try expectBlocks(&.{.{ .first_line = 2, .line_count = 3 }}, "const x = 1;\n/* one\n two\n */\n");
}

test "comment_scan: nested block comments count to the outer close" {
    try expectBlocks(&.{.{ .first_line = 1, .line_count = 4 }}, "/* one\n /* nested */\n*/\n// after\n");
}

test "comment_scan: code after a closed block comment keeps the line out of the block" {
    try expectBlocks(&.{
        .{ .first_line = 1, .line_count = 1 },
        .{ .first_line = 3, .line_count = 1 },
    }, "// one\n/* two */ const x = 1;\n// three\n");
}

test "comment_scan: doc comments count like any other comment line" {
    try expectBlocks(&.{.{ .first_line = 1, .line_count = 2 }}, "//! file header\n/// doc for x\n");
}

test "comment_scan: an unterminated block comment reaches the end of the file" {
    try expectBlocks(&.{.{ .first_line = 1, .line_count = 3 }}, "/* one\n two\n three");
}

test "comment_scan: a run at the end of a file without a trailing newline is counted" {
    try expectBlocks(&.{.{ .first_line = 1, .line_count = 2 }}, "// one\n// two");
}

test "comment_scan: CRLF line endings do not join or split a run" {
    try expectBlocks(&.{.{ .first_line = 1, .line_count = 3 }}, "// one\r\n// two\r\n// three\r\n");
}

test "comment_scan: an empty source has no blocks" {
    try expectBlocks(&.{}, "");
}

test "comment_scan: a division operator is code, not a comment" {
    try expectBlocks(&.{.{ .first_line = 2, .line_count = 1 }}, "const half = total / 2;\n// one\n");
}
