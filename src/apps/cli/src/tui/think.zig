//! Strip `<think>...</think>` blocks from assistant content. Mirrors
//! `src/apps/desktop/src/helpers/stripTags.ts:5-80` — pure functions on
//! borrowed input.

const std = @import("std");
const testing = std.testing;

/// Return an owned slice (caller frees via `allocator.free`) with
/// every `<think>...</think>` block removed.
pub fn stripThinkingTags(allocator: std.mem.Allocator, content: []const u8) ![]u8 {
    // Fast path — no tags at all. Return a dupe of the trimmed input.
    if (std.mem.indexOf(u8, content, "<think>") == null) {
        const trimmed = std.mem.trim(u8, content, &std.ascii.whitespace);
        return allocator.dupe(u8, trimmed);
    }

    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(allocator);
    try out.ensureTotalCapacity(allocator, content.len);

    var cursor: usize = 0;
    while (cursor < content.len) {
        if (std.mem.startsWith(u8, content[cursor..], "<think>")) {
            const after_open = cursor + "<think>".len;
            const close_at = std.mem.indexOf(u8, content[after_open..], "</think>") orelse {
                // Unclosed think block — copy the rest verbatim and
                // stop. Avoids spinning if the LLM emits a partial
                // stream during a poll mid-write.
                try out.appendSlice(allocator, content[cursor..]);
                break;
            };
            cursor = after_open + close_at + "</think>".len;
            continue;
        }
        try out.append(allocator, content[cursor]);
        cursor += 1;
    }
    const trimmed = std.mem.trim(u8, out.items, &std.ascii.whitespace);
    return allocator.dupe(u8, trimmed);
}

/// True when `content` contains only `<think>...</think>` blocks
/// (possibly multiple, possibly with surrounding whitespace) and no
/// visible text remains after stripping.
pub fn isThinkingOnly(allocator: std.mem.Allocator, content: []const u8) !bool {
    const stripped = try stripThinkingTags(allocator, content);
    defer allocator.free(stripped);
    return stripped.len == 0;
}

/// Remove `<plain>`, `<markdown>`, `<html>` (and matching closing tags) while
/// keeping the inner content. Mirrors the Vue frontend's `stripTags.ts:28-36`
/// unwrap behaviour.
pub fn unwrapContentWrappers(allocator: std.mem.Allocator, content: []const u8) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(allocator);
    try out.ensureTotalCapacity(allocator, content.len);

    var cursor: usize = 0;
    while (cursor < content.len) {
        if (stripOneWrapper(content[cursor..])) |skip| {
            cursor += skip;
            continue;
        }
        try out.append(allocator, content[cursor]);
        cursor += 1;
    }
    return allocator.dupe(u8, out.items);
}

/// Returns the byte length to skip if `content` starts with one of
/// the six known content-wrapper tags, else null.
fn stripOneWrapper(content: []const u8) ?usize {
    inline for (.{ "<plain>", "</plain>", "<markdown>", "</markdown>", "<html>", "</html>" }) |tag| {
        if (std.mem.startsWith(u8, content, tag)) return tag.len;
    }
    return null;
}

// ----------------------------------------------------------------------------
// Tests
// ----------------------------------------------------------------------------

test "stripThinkingTags: removes single think block" {
    const got = try stripThinkingTags(testing.allocator, "<think>hidden</think>visible");
    defer testing.allocator.free(got);
    try testing.expectEqualStrings("visible", got);
}

test "stripThinkingTags: returns content unchanged when no tags" {
    const got = try stripThinkingTags(testing.allocator, "plain assistant text");
    defer testing.allocator.free(got);
    try testing.expectEqualStrings("plain assistant text", got);
}

test "stripThinkingTags: handles leading think + trailing text" {
    const got = try stripThinkingTags(testing.allocator, "<think>plan</think>the answer is 42");
    defer testing.allocator.free(got);
    try testing.expectEqualStrings("the answer is 42", got);
}

test "stripThinkingTags: removes multiple think blocks" {
    const got = try stripThinkingTags(testing.allocator, "<think>a</think>x<think>b</think>y");
    defer testing.allocator.free(got);
    try testing.expectEqualStrings("xy", got);
}

test "stripThinkingTags: handles text before and after a think block" {
    const got = try stripThinkingTags(testing.allocator, "pre<think>mid</think>post");
    defer testing.allocator.free(got);
    try testing.expectEqualStrings("prepost", got);
}

test "stripThinkingTags: trims surrounding whitespace" {
    const got = try stripThinkingTags(testing.allocator, "  <think>plan</think>answer   ");
    defer testing.allocator.free(got);
    try testing.expectEqualStrings("answer", got);
}

test "stripThinkingTags: handles unclosed think block gracefully" {
    // No closing tag — strip everything up to but not including the
    // unclosed opener, leaving the rest of the content intact.
    const got = try stripThinkingTags(testing.allocator, "pre<think>never closes");
    defer testing.allocator.free(got);
    try testing.expectEqualStrings("pre<think>never closes", got);
}

test "isThinkingOnly: true when only think block present" {
    try testing.expect(try isThinkingOnly(testing.allocator, "<think>plan</think>"));
}

test "isThinkingOnly: true when multiple think blocks only" {
    try testing.expect(try isThinkingOnly(testing.allocator, "<think>a</think><think>b</think>"));
}

test "isThinkingOnly: true for whitespace + think blocks" {
    try testing.expect(try isThinkingOnly(testing.allocator, " <think>plan</think>  "));
}

test "isThinkingOnly: false when visible text remains" {
    try testing.expect(!(try isThinkingOnly(testing.allocator, "<think>plan</think>answer")));
}

test "isThinkingOnly: false when no tags" {
    try testing.expect(!(try isThinkingOnly(testing.allocator, "plain")));
}

// ----------------------------------------------------------------------------
// unwrapContentWrappers — strip `<plain>`, `<markdown>`, `<html>` content
// tags (matches the Vue frontend's stripTags.ts:28-36 behaviour).

test "unwrapContentWrappers: unwraps <plain>" {
    const got = try unwrapContentWrappers(testing.allocator, "<plain>hello</plain>");
    defer testing.allocator.free(got);
    try testing.expectEqualStrings("hello", got);
}

test "unwrapContentWrappers: unwraps <markdown>" {
    const got = try unwrapContentWrappers(testing.allocator, "<markdown>**x**</markdown>");
    defer testing.allocator.free(got);
    try testing.expectEqualStrings("**x**", got);
}

test "unwrapContentWrappers: unwraps <html>" {
    const got = try unwrapContentWrappers(testing.allocator, "<html><p>x</p></html>");
    defer testing.allocator.free(got);
    try testing.expectEqualStrings("<p>x</p>", got);
}

test "unwrapContentWrappers: unwraps closing tags too" {
    const got = try unwrapContentWrappers(testing.allocator, "</plain>tail");
    defer testing.allocator.free(got);
    try testing.expectEqualStrings("tail", got);
}

test "unwrapContentWrappers: leaves content untouched when no wrappers" {
    const got = try unwrapContentWrappers(testing.allocator, "plain text");
    defer testing.allocator.free(got);
    try testing.expectEqualStrings("plain text", got);
}

test "unwrapContentWrappers: handles nested wrappers (inner stripped first)" {
    const got = try unwrapContentWrappers(testing.allocator, "<plain><html>x</html></plain>");
    defer testing.allocator.free(got);
    try testing.expectEqualStrings("x", got);
}

test "unwrapContentWrappers: empty content → empty result" {
    const got = try unwrapContentWrappers(testing.allocator, "");
    defer testing.allocator.free(got);
    try testing.expectEqualStrings("", got);
}

test "unwrapContentWrappers: only open tag, no close" {
    // Malformed: open without close. We strip the open tag but keep
    // the rest of the content verbatim — better than losing data.
    const got = try unwrapContentWrappers(testing.allocator, "<plain>never closes");
    defer testing.allocator.free(got);
    try testing.expectEqualStrings("never closes", got);
}