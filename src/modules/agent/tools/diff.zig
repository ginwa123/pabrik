const std = @import("std");
const Allocator = std.mem.Allocator;

// ── Types ─────────────────────────────────────────────────────────────────────

pub const Kind = enum { eq, insert, delete };

pub const Chunk = struct {
    kind: Kind,
    text: []const u8, // slice into the original before/after strings
};

pub const DiffResult = struct {
    chunks: []Chunk,

    pub fn deinit(self: DiffResult, allocator: Allocator) void {
        allocator.free(self.chunks);
    }
};

// ── LCS diff
// ────────────────────────────────────────────────────────────────── Works on
// any granularity: pass raw bytes, or split into lines first.

pub fn diff(allocator: Allocator, before: []const u8, after: []const u8) !DiffResult {
    const n = before.len;
    const m = after.len;

    // Build LCS length table: dp[i][j] = LCS length of before[0..i] vs after[0..j]
    // We use a flat array of (n+1)*(m+1) u32s.
    const dp = try allocator.alloc(u32, (n + 1) * (m + 1));
    defer allocator.free(dp);
    @memset(dp, 0);

    for (1..n + 1) |i| {
        for (1..m + 1) |j| {
            dp[i * (m + 1) + j] = if (before[i - 1] == after[j - 1])
                dp[(i - 1) * (m + 1) + (j - 1)] + 1
            else
                @max(dp[(i - 1) * (m + 1) + j], dp[i * (m + 1) + (j - 1)]);
        }
    }

    // Backtrack to collect chunks
    var chunks = std.ArrayList(Chunk).empty;
    errdefer chunks.deinit(allocator);

    var i: usize = n;
    var j: usize = m;

    // We'll accumulate runs of the same kind into single chunks
    var buf_kind: ?Kind = null;
    var buf_start_b: usize = 0; // start index in `before`
    var buf_start_a: usize = 0; // start index in `after`
    var buf_end_b: usize = 0;
    var buf_end_a: usize = 0;

    // Collect ops in reverse, then reverse the list
    while (i > 0 or j > 0) {
        const kind: Kind = blk: {
            if (i > 0 and j > 0 and before[i - 1] == after[j - 1]) {
                i -= 1; j -= 1;
                break :blk .eq;
            } else if (j > 0 and (i == 0 or dp[i * (m + 1) + (j - 1)] >= dp[(i - 1) * (m + 1) + j])) {
                j -= 1;
                break :blk .insert;
            } else {
                i -= 1;
                break :blk .delete;
            }
        };

        // Extend or flush the current run
        if (buf_kind == kind) {
            // extend backwards
            if (kind == .eq or kind == .delete) buf_start_b = i;
            if (kind == .eq or kind == .insert) buf_start_a = j;
        } else {
            if (buf_kind) |k| {
                try chunks.append(allocator, .{
                    .kind = k,
                    .text = switch (k) {
                        .eq, .delete => before[buf_start_b..buf_end_b],
                        .insert      => after[buf_start_a..buf_end_a],
                    },
                });
            }
            buf_kind = kind;
            buf_start_b = i;
            buf_end_b   = if (kind == .eq or kind == .delete) i + 1 else i;
            buf_start_a = j;
            buf_end_a   = if (kind == .eq or kind == .insert) j + 1 else j;
        }
    }

    // Flush last run
    if (buf_kind) |k| {
        try chunks.append(allocator, .{
            .kind = k,
            .text = switch (k) {
                .eq, .delete => before[buf_start_b..buf_end_b],
                .insert      => after[buf_start_a..buf_end_a],
            },
        });
    }

    // Reverse (we built it backwards)
    const slice = try chunks.toOwnedSlice(allocator);
    std.mem.reverse(Chunk, slice);
    return .{ .chunks = slice };
}

// ── Line-level wrapper
// ──────────────────────────────────────────────────────── If you want
// line-level granularity (like git diff), use this instead.

pub const LineDiff = struct {
    chunks: []LineChunk,
    pub fn deinit(self: LineDiff, allocator: Allocator) void {
        allocator.free(self.chunks);
    }
};

pub const LineChunk = struct {
    kind: Kind,
    lines: []const []const u8,
};

pub fn diffLines(
    allocator: Allocator,
    before_lines: []const []const u8,
    after_lines: []const []const u8,
) !LineDiff {
    const n = before_lines.len;
    const m = after_lines.len;

    const dp = try allocator.alloc(u32, (n + 1) * (m + 1));
    defer allocator.free(dp);
    @memset(dp, 0);

    for (1..n + 1) |i| {
        for (1..m + 1) |j| {
            dp[i * (m + 1) + j] = if (std.mem.eql(u8, before_lines[i - 1], after_lines[j - 1]))
                dp[(i - 1) * (m + 1) + (j - 1)] + 1
            else
                @max(dp[(i - 1) * (m + 1) + j], dp[i * (m + 1) + (j - 1)]);
        }
    }

    var ops = std.ArrayList(struct { kind: Kind, bi: usize, ai: usize }).empty;
    defer ops.deinit(allocator);

    var i: usize = n;
    var j: usize = m;
    while (i > 0 or j > 0) {
        if (i > 0 and j > 0 and std.mem.eql(u8, before_lines[i - 1], after_lines[j - 1])) {
            i -= 1; j -= 1;
            try ops.append(allocator, .{ .kind = .eq, .bi = i, .ai = j });
        } else if (j > 0 and (i == 0 or dp[i * (m + 1) + (j - 1)] >= dp[(i - 1) * (m + 1) + j])) {
            j -= 1;
            try ops.append(allocator, .{ .kind = .insert, .bi = i, .ai = j });
        } else {
            i -= 1;
            try ops.append(allocator, .{ .kind = .delete, .bi = i, .ai = j });
        }
    }
    std.mem.reverse(@TypeOf(ops.items[0]), ops.items);

    // Group consecutive same-kind ops into LineChunks
    var chunks = std.ArrayList(LineChunk).empty;
    errdefer chunks.deinit(allocator);

    var idx: usize = 0;
    while (idx < ops.items.len) {
        const kind = ops.items[idx].kind;
        const start = idx;
        while (idx < ops.items.len and ops.items[idx].kind == kind) idx += 1;

        // Collect the line slice for this chunk
        const lines = switch (kind) {
            .eq, .delete => before_lines[ops.items[start].bi..ops.items[idx - 1].bi + 1],
            .insert      => after_lines[ops.items[start].ai..ops.items[idx - 1].ai + 1],
        };
        try chunks.append(allocator, .{ .kind = kind, .lines = lines });
    }

    return .{ .chunks = try chunks.toOwnedSlice(allocator) };
}

// ── Helpers ───────────────────────────────────────────────────────────────────

/// Split on line boundaries, dropping the `CR` of a CRLF pair. A
/// Windows-authored file arrives here as `one\r\ntwo\r\n`, and splitting on
/// `\n` alone leaves every line ending in a stray `\r`.
pub fn splitLines(allocator: Allocator, text: []const u8) ![][]const u8 {
    var list = std.ArrayList([]const u8).empty;
    var it = std.mem.splitScalar(u8, text, '\n');
    while (it.next()) |line| {
        const without_cr = if (line.len > 0 and line[line.len - 1] == '\r') line[0 .. line.len - 1] else line;
        try list.append(allocator, without_cr);
    }
    if (list.items.len > 0 and list.getLast().len == 0) _ = list.pop();
    return try list.toOwnedSlice(allocator);
}

// ── Formatters ────────────────────────────────────────────────────────────────

/// Format diff as ANSI-colored text (for terminal display)
pub fn formatAnsi(allocator: Allocator, result: DiffResult) ![]const u8 {
    var out = std.ArrayList(u8).empty;
    errdefer out.deinit(allocator);

    for (result.chunks) |c| {
        const prefix: u8 = switch (c.kind) { .eq => ' ', .insert => '+', .delete => '-' };
        const color = switch (c.kind) {
            .eq     => "\x1b[0m",
            .insert => "\x1b[32m",
            .delete => "\x1b[31m",
        };
        try out.appendSlice(allocator, color);
        try out.append(allocator, prefix);
        try out.append(allocator, ' ');
        try out.appendSlice(allocator, c.text);
        try out.appendSlice(allocator, "\x1b[0m");
    }

    return try out.toOwnedSlice(allocator);
}

/// Format line-level diff as ANSI-colored split view (vimdiff style)
/// Left = before, Right = after - lines aligned side by side
pub fn formatLinesAnsi(allocator: Allocator, result: LineDiff) ![]const u8 {
    var out = std.ArrayList(u8).empty;
    errdefer out.deinit(allocator);

    // ANSI codes
    const red = "\x1b[31m";
    const green = "\x1b[32m";
    const reset = "\x1b[0m";
    const dim = "\x1b[2m";

    // Track line numbers for both sides
    var before_line_num: usize = 1;
    var after_line_num: usize = 1;

    for (result.chunks) |c| {
        switch (c.kind) {
            .eq => {
                for (c.lines) |line| {
                    // Format: "    N  │  N    line content"
                    const left_num = std.fmt.allocPrint(allocator, "{d:>4}  ", .{before_line_num}) catch "";
                    defer allocator.free(left_num);
                    const right_num = std.fmt.allocPrint(allocator, "  {d:<4}", .{after_line_num}) catch "";
                    defer allocator.free(right_num);

                    try out.appendSlice(allocator, dim);
                    try out.appendSlice(allocator, left_num);
                    try out.appendSlice(allocator, "│");
                    try out.appendSlice(allocator, right_num);
                    try out.appendSlice(allocator, reset);
                    try out.appendSlice(allocator, " ");
                    try out.appendSlice(allocator, line);
                    try out.append(allocator, '\n');

                    before_line_num += 1;
                    after_line_num += 1;
                }
            },
            .delete => {
                for (c.lines) |line| {
                    const left_num = std.fmt.allocPrint(allocator, "{d:>4}  ", .{before_line_num}) catch "";
                    defer allocator.free(left_num);

                    try out.appendSlice(allocator, red);
                    try out.appendSlice(allocator, left_num);
                    try out.appendSlice(allocator, "│");
                    try out.appendSlice(allocator, dim);
                    try out.appendSlice(allocator, "     ");
                    try out.appendSlice(allocator, reset);
                    try out.appendSlice(allocator, " ");
                    try out.appendSlice(allocator, line);
                    try out.appendSlice(allocator, reset);
                    try out.append(allocator, '\n');

                    before_line_num += 1;
                }
            },
            .insert => {
                for (c.lines) |line| {
                    const right_num = std.fmt.allocPrint(allocator, "  {d:<4}", .{after_line_num}) catch "";
                    defer allocator.free(right_num);

                    try out.appendSlice(allocator, dim);
                    try out.appendSlice(allocator, "    ");
                    try out.appendSlice(allocator, "│");
                    try out.appendSlice(allocator, green);
                    try out.appendSlice(allocator, right_num);
                    try out.appendSlice(allocator, reset);
                    try out.appendSlice(allocator, " ");
                    try out.appendSlice(allocator, line);
                    try out.appendSlice(allocator, reset);
                    try out.append(allocator, '\n');

                    after_line_num += 1;
                }
            },
        }
    }

    return try out.toOwnedSlice(allocator);
}

/// Format diff as plain text (no ANSI colors)
pub fn formatPlain(allocator: Allocator, result: DiffResult) ![]const u8 {
    var out = std.ArrayList(u8).empty;
    errdefer out.deinit(allocator);

    for (result.chunks) |c| {
        const prefix: u8 = switch (c.kind) { .eq => ' ', .insert => '+', .delete => '-' };
        try out.append(allocator, prefix);
        try out.append(allocator, ' ');
        try out.appendSlice(allocator, c.text);
    }

    return try out.toOwnedSlice(allocator);
}

/// Format line-level diff as plain text (no ANSI colors)
pub fn formatLinesPlain(allocator: Allocator, result: LineDiff) ![]const u8 {
    var out = std.ArrayList(u8).empty;
    errdefer out.deinit(allocator);

    for (result.chunks) |c| {
        const prefix: u8 = switch (c.kind) { .eq => ' ', .insert => '+', .delete => '-' };
        for (c.lines) |line| {
            try out.append(allocator, prefix);
            try out.append(allocator, ' ');
            try out.appendSlice(allocator, line);
            try out.append(allocator, '\n');
        }
    }

    return try out.toOwnedSlice(allocator);
}

test "diff - no change" {
    const r = try diff(std.testing.allocator, "hello", "hello");
    defer r.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 1), r.chunks.len);
    try std.testing.expect(r.chunks[0].kind == .eq);
    try std.testing.expectEqualStrings("hello", r.chunks[0].text);
}

test "diff - pure insert" {
    const r = try diff(std.testing.allocator, "", "hi");
    defer r.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 1), r.chunks.len);
    try std.testing.expect(r.chunks[0].kind == .insert);
    try std.testing.expectEqualStrings("hi", r.chunks[0].text);
}

test "diff - pure delete" {
    const r = try diff(std.testing.allocator, "bye", "");
    defer r.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 1), r.chunks.len);
    try std.testing.expect(r.chunks[0].kind == .delete);
    try std.testing.expectEqualStrings("bye", r.chunks[0].text);
}

test "diff - mixed" {
    // "cat" → "car": eq "ca", delete "t", insert "r"
    const r = try diff(std.testing.allocator, "cat", "car");
    defer r.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 3), r.chunks.len);
    try std.testing.expect(r.chunks[0].kind == .eq);
    try std.testing.expectEqualStrings("ca", r.chunks[0].text);
    try std.testing.expect(r.chunks[1].kind == .delete);
    try std.testing.expectEqualStrings("t", r.chunks[1].text);
    try std.testing.expect(r.chunks[2].kind == .insert);
    try std.testing.expectEqualStrings("r", r.chunks[2].text);
}

test "diff - single char change" {
    // "a" → "b": delete "a", insert "b"
    const r = try diff(std.testing.allocator, "a", "b");
    defer r.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 2), r.chunks.len);
    try std.testing.expect(r.chunks[0].kind == .delete);
    try std.testing.expectEqualStrings("a", r.chunks[0].text);
    try std.testing.expect(r.chunks[1].kind == .insert);
    try std.testing.expectEqualStrings("b", r.chunks[1].text);
}

test "diff - empty both" {
    const r = try diff(std.testing.allocator, "", "");
    defer r.deinit(std.testing.allocator);
    // Empty strings produce zero chunks
    try std.testing.expectEqual(@as(usize, 0), r.chunks.len);
}

test "splitLines - basic" {
    const lines = try splitLines(std.testing.allocator, "line1\nline2\nline3\n");
    defer std.testing.allocator.free(lines);
    try std.testing.expectEqual(@as(usize, 3), lines.len);
    try std.testing.expectEqualStrings("line1", lines[0]);
    try std.testing.expectEqualStrings("line2", lines[1]);
    try std.testing.expectEqualStrings("line3", lines[2]);
}

test "splitLines - no trailing newline" {
    const lines = try splitLines(std.testing.allocator, "line1\nline2");
    defer std.testing.allocator.free(lines);
    try std.testing.expectEqual(@as(usize, 2), lines.len);
    try std.testing.expectEqualStrings("line1", lines[0]);
    try std.testing.expectEqualStrings("line2", lines[1]);
}

test "splitLines - empty last line" {
    const lines = try splitLines(std.testing.allocator, "line1\nline2\n");
    defer std.testing.allocator.free(lines);
    try std.testing.expectEqual(@as(usize, 2), lines.len);
}

test "splitLines - single line no newline" {
    const lines = try splitLines(std.testing.allocator, "single line");
    defer std.testing.allocator.free(lines);
    try std.testing.expectEqual(@as(usize, 1), lines.len);
    try std.testing.expectEqualStrings("single line", lines[0]);
}

test "line diff - no change" {
    const bl = try splitLines(std.testing.allocator, "line1\nline2\n");
    defer std.testing.allocator.free(bl);
    const al = try splitLines(std.testing.allocator, "line1\nline2\n");
    defer std.testing.allocator.free(al);

    const r = try diffLines(std.testing.allocator, bl, al);
    defer r.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 1), r.chunks.len);
    try std.testing.expect(r.chunks[0].kind == .eq);
}

test "line diff - add line" {
    const bl = try splitLines(std.testing.allocator, "line1\nline2\n");
    defer std.testing.allocator.free(bl);
    const al = try splitLines(std.testing.allocator, "line1\nline2\nline3\n");
    defer std.testing.allocator.free(al);

    const r = try diffLines(std.testing.allocator, bl, al);
    defer r.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 2), r.chunks.len);
    try std.testing.expect(r.chunks[0].kind == .eq);
    try std.testing.expect(r.chunks[1].kind == .insert);
}

test "line diff - delete line" {
    const bl = try splitLines(std.testing.allocator, "line1\nline2\nline3\n");
    defer std.testing.allocator.free(bl);
    const al = try splitLines(std.testing.allocator, "line1\nline2\n");
    defer std.testing.allocator.free(al);

    const r = try diffLines(std.testing.allocator, bl, al);
    defer r.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 2), r.chunks.len);
    try std.testing.expect(r.chunks[0].kind == .eq);
    try std.testing.expect(r.chunks[1].kind == .delete);
}

test "line diff - modify line" {
    const bl = try splitLines(std.testing.allocator, "line1\nOLD\nline3\n");
    defer std.testing.allocator.free(bl);
    const al = try splitLines(std.testing.allocator, "line1\nNEW\nline3\n");
    defer std.testing.allocator.free(al);

    const r = try diffLines(std.testing.allocator, bl, al);
    defer r.deinit(std.testing.allocator);
    
    // Should have at least 2 chunks (delete + insert for the modified line)
    try std.testing.expect(r.chunks.len >= 2);
    
    // First chunk should be equal (line1)
    try std.testing.expect(r.chunks[0].kind == .eq);
    // Last chunk should be equal (line3)
    try std.testing.expect(r.chunks[r.chunks.len - 1].kind == .eq);
}

test "formatLinesAnsi - generates output" {
    const bl = try splitLines(std.testing.allocator, "line1\nline2\n");
    defer std.testing.allocator.free(bl);
    const al = try splitLines(std.testing.allocator, "line1\nmodified\n");
    defer std.testing.allocator.free(al);

    const r = try diffLines(std.testing.allocator, bl, al);
    defer r.deinit(std.testing.allocator);

    const output = try formatLinesAnsi(std.testing.allocator, r);
    defer std.testing.allocator.free(output);

    // Check that output contains expected content
    try std.testing.expect(std.mem.indexOf(u8, output, "line1") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "modified") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "│") != null); // divider
}

test "line diff - multiline change" {
    // Test a more complex scenario with multiple line changes
    const bl = try splitLines(std.testing.allocator, "fn old() void { }\n");
    defer std.testing.allocator.free(bl);
    const al = try splitLines(std.testing.allocator, "fn new() void { }\n");
    defer std.testing.allocator.free(al);

    const r = try diffLines(std.testing.allocator, bl, al);
    defer r.deinit(std.testing.allocator);
    
    // Should have at least 2 chunks (delete + insert)
    try std.testing.expect(r.chunks.len >= 2);
    
    // First chunk should be delete, second should be insert
    try std.testing.expect(r.chunks[0].kind == .delete);
    try std.testing.expect(r.chunks[1].kind == .insert);
}

// ── CRLF contract ─────────────────────────────────────────────────────────
// Windows-authored files are CRLF, and every consumer of these lines (the
// ANSI renderer, the hunk headers, the frontend's diff card) treats a
test "splitLines - drops the CR of a CRLF pair" {
    const lines = try splitLines(std.testing.allocator, "one\r\ntwo\r\nthree\r\n");
    defer std.testing.allocator.free(lines);
    try std.testing.expectEqual(@as(usize, 3), lines.len);
    try std.testing.expectEqualStrings("one", lines[0]);
    try std.testing.expectEqualStrings("two", lines[1]);
    try std.testing.expectEqualStrings("three", lines[2]);
}

test "splitLines - CRLF with no trailing newline" {
    const lines = try splitLines(std.testing.allocator, "one\r\ntwo");
    defer std.testing.allocator.free(lines);
    try std.testing.expectEqual(@as(usize, 2), lines.len);
    try std.testing.expectEqualStrings("one", lines[0]);
    try std.testing.expectEqualStrings("two", lines[1]);
}

// The property that actually matters: line-splitting is the ONLY difference
// between the two, so once `\r` is gone a CRLF file must diff exactly like
// its LF twin.
test "splitLines - a CRLF file produces a byte-identical diff to its LF twin" {
    const Alloc = std.testing.allocator;
    const lf_before = try splitLines(Alloc, "a\nb\nc\n");
    defer Alloc.free(lf_before);
    const lf_after = try splitLines(Alloc, "a\nB\nc\n");
    defer Alloc.free(lf_after);
    const crlf_before = try splitLines(Alloc, "a\r\nb\r\nc\r\n");
    defer Alloc.free(crlf_before);
    const crlf_after = try splitLines(Alloc, "a\r\nB\r\nc\r\n");
    defer Alloc.free(crlf_after);

    const lf = try diffLines(Alloc, lf_before, lf_after);
    defer lf.deinit(Alloc);
    const crlf = try diffLines(Alloc, crlf_before, crlf_after);
    defer crlf.deinit(Alloc);

    // Same shape, and the context lines actually MATCH. Before the fix each
    // CRLF line carried a trailing `\r`, so nothing compared equal and the
    // whole file came back as delete+insert.
    try std.testing.expectEqual(lf.chunks.len, crlf.chunks.len);
    var eq_lines: usize = 0;
    for (lf.chunks, crlf.chunks) |a, b| {
        try std.testing.expectEqual(a.kind, b.kind);
        try std.testing.expectEqual(a.lines.len, b.lines.len);
        for (a.lines, b.lines) |la, lb| try std.testing.expectEqualStrings(la, lb);
        if (a.kind == .eq) eq_lines += a.lines.len;
    }
    try std.testing.expectEqual(@as(usize, 2), eq_lines);
}

test "splitLines - LF input is unchanged and a bare CR survives" {
    const lf = try splitLines(std.testing.allocator, "one\ntwo\n");
    defer std.testing.allocator.free(lf);
    try std.testing.expectEqualStrings("one", lf[0]);
    try std.testing.expectEqualStrings("two", lf[1]);

    // A bare CR is a Mac Classic line ending, not a CRLF artefact.
    const bare = try splitLines(std.testing.allocator, "one\rtwo\n");
    defer std.testing.allocator.free(bare);
    try std.testing.expectEqualStrings("one\rtwo", bare[0]);
}
