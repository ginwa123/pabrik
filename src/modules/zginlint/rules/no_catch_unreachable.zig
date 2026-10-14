//! `zginlint/no-catch-unreachable`: the banned error-handling pair, the same
//! rule as `scripts/lint-no-catch-unreachable.sh`. The scan is over raw
//! bytes, so a commented-out site counts — CODING_STANDARDS.md §1 asks for it.

const std = @import("std");
const rule = @import("../rule.zig");

pub const id = "zginlint/no-catch-unreachable";

/// The banned pair, concatenated so this source carries no literal copy of
/// what it rejects (the scan is over raw bytes, including this file).
const banned = "catch" ++ " " ++ "unreachable";

/// The message, with a hole for the space, for the same reason as `banned`.
const message_fmt = "`catch{s}unreachable` is banned; write `catch @panic(\"<what failed>\")` — see CODING_STANDARDS.md §1";

pub const declaration = rule.Rule{
    .id = id,
    .fingerprint = fingerprint,
    .check = check,
};

pub fn fingerprint(allocator: std.mem.Allocator, options: rule.Options) ![]u8 {
    _ = options;
    return allocator.dupe(u8, rule.no_options);
}

/// Append one diagnostic per site, at the `catch` that starts it.
pub fn check(
    allocator: std.mem.Allocator,
    source: []const u8,
    options: rule.Options,
    out: *std.ArrayList(rule.Diagnostic),
) anyerror!void {
    _ = options;
    var search_from: usize = 0;
    while (std.mem.indexOfPos(u8, source, search_from, "catch")) |found| {
        search_from = found + "catch".len;
        const gap = whitespaceAfter(source, search_from);
        // The pair is `catch`, one or more whitespace bytes, the word.
        if (gap == search_from) continue;
        if (!std.mem.startsWith(u8, source[gap..], "unreachable")) continue;
        const after = gap + "unreachable".len;
        if (after < source.len and isWordByte(source[after])) continue;

        const position = positionOf(source, found);
        const message = try std.fmt.allocPrint(allocator, message_fmt, .{" "});
        errdefer allocator.free(message);
        try out.append(allocator, .{
            .rule_id = id,
            .line = position.line,
            .column = position.column,
            .message = message,
        });
    }
}

const Position = struct { line: u32, column: u32 };

fn positionOf(source: []const u8, index: usize) Position {
    var line: u32 = 1;
    var line_start: usize = 0;
    for (source[0..index], 0..) |byte, position| {
        if (byte != '\n') continue;
        line += 1;
        line_start = position + 1;
    }
    return .{ .line = line, .column = @intCast(index - line_start + 1) };
}

/// The index of the first byte after the whitespace run starting at
/// `index`. Equal to `index` when there is no whitespace there.
fn whitespaceAfter(source: []const u8, index: usize) usize {
    var cursor = index;
    while (cursor < source.len and std.ascii.isWhitespace(source[cursor])) cursor += 1;
    return cursor;
}

/// The `\b` the ripgrep lint has after the word, without a regex engine.
fn isWordByte(byte: u8) bool {
    return std.ascii.isAlphanumeric(byte) or byte == '_';
}

const testing = std.testing;

/// A source holding one site, built so this test file carries no literal
/// copy of the pair (which would itself be a finding).
fn sourceWithSite(allocator: std.mem.Allocator, separator: []const u8) ![]u8 {
    return std.fmt.allocPrint(allocator, "const x = g() catch{s}unreachable;\n", .{separator});
}

fn checkOwned(source: []const u8) !std.ArrayList(rule.Diagnostic) {
    var found: std.ArrayList(rule.Diagnostic) = .empty;
    errdefer {
        for (found.items) |*item| item.deinit(testing.allocator);
        found.deinit(testing.allocator);
    }
    try check(testing.allocator, source, .{}, &found);
    return found;
}

fn deinitFound(found: *std.ArrayList(rule.Diagnostic)) void {
    for (found.items) |*item| item.deinit(testing.allocator);
    found.deinit(testing.allocator);
}

test "no-catch-unreachable: the site is reported at the catch" {
    const source = try sourceWithSite(testing.allocator, " ");
    defer testing.allocator.free(source);
    var found = try checkOwned(source);
    defer deinitFound(&found);

    try testing.expectEqual(@as(usize, 1), found.items.len);
    try testing.expectEqual(@as(u32, 1), found.items[0].line);
    try testing.expectEqual(@as(u32, 15), found.items[0].column);
    try testing.expectEqualStrings("zginlint/no-catch-unreachable", found.items[0].rule_id);
    try testing.expect(std.mem.indexOf(u8, found.items[0].message, "§1") != null);
}

test "no-catch-unreachable: a tab between the words is reported" {
    const source = try sourceWithSite(testing.allocator, "\t");
    defer testing.allocator.free(source);
    var found = try checkOwned(source);
    defer deinitFound(&found);
    try testing.expectEqual(@as(usize, 1), found.items.len);
}

test "no-catch-unreachable: a newline between the words is reported at the catch" {
    const source = try std.fmt.allocPrint(testing.allocator, "const x = g() catch\n        {s};\n", .{banned[6..]});
    defer testing.allocator.free(source);
    var found = try checkOwned(source);
    defer deinitFound(&found);
    try testing.expectEqual(@as(usize, 1), found.items.len);
    try testing.expectEqual(@as(u32, 1), found.items[0].line);
}

test "no-catch-unreachable: a longer word is not the ban" {
    const source = "const x = g() catch unreachableThing;\n";
    var found = try checkOwned(source);
    defer deinitFound(&found);
    try testing.expectEqual(@as(usize, 0), found.items.len);
}

test "no-catch-unreachable: the sanctioned panic form is not reported" {
    const source = "const x = g() catch @panic(\"g failed\");\nconst y = switch (z) { 0 => 1, else => unreachable };\n";
    var found = try checkOwned(source);
    defer deinitFound(&found);
    try testing.expectEqual(@as(usize, 0), found.items.len);
}

test "no-catch-unreachable: catch without the pair is not reported" {
    const source = "const x = g() catch |err| return err;\nconst y = a catch b;\n";
    var found = try checkOwned(source);
    defer deinitFound(&found);
    try testing.expectEqual(@as(usize, 0), found.items.len);
}

test "no-catch-unreachable: a commented-out site is reported" {
    const source = try std.fmt.allocPrint(testing.allocator, "// the old code did g() catch{s}unreachable;\n", .{" "});
    defer testing.allocator.free(source);
    var found = try checkOwned(source);
    defer deinitFound(&found);
    try testing.expectEqual(@as(usize, 1), found.items.len);
    try testing.expectEqual(@as(u32, 1), found.items[0].line);
}

test "no-catch-unreachable: two sites are two findings, in source order" {
    const first = try sourceWithSite(testing.allocator, " ");
    defer testing.allocator.free(first);
    const second = try std.fmt.allocPrint(testing.allocator, "{s}const y = h() catch\t{s};\n", .{ first, banned[6..] });
    defer testing.allocator.free(second);

    var found = try checkOwned(second);
    defer deinitFound(&found);
    try testing.expectEqual(@as(usize, 2), found.items.len);
    try testing.expectEqual(@as(u32, 1), found.items[0].line);
    try testing.expectEqual(@as(u32, 2), found.items[1].line);
}

test "no-catch-unreachable: a truncation at the end of the file is not a site" {
    const source = "const x = g() catch";
    var found = try checkOwned(source);
    defer deinitFound(&found);
    try testing.expectEqual(@as(usize, 0), found.items.len);
}

test "no-catch-unreachable: the banned token is what the rule reports" {
    const source = try std.fmt.allocPrint(testing.allocator, "const x = {s};\n", .{banned});
    defer testing.allocator.free(source);
    var found = try checkOwned(source);
    defer deinitFound(&found);

    try testing.expectEqual(@as(usize, 1), found.items.len);
    try testing.expectEqual(@as(u32, 11), found.items[0].column);
}

test "no-catch-unreachable: the fingerprint is the no-options marker" {
    const text = try fingerprint(testing.allocator, .{});
    defer testing.allocator.free(text);
    try testing.expectEqualStrings(rule.no_options, text);
}
