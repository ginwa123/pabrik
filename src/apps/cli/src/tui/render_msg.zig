//! Render a single backend message into 0..N styled `Line`s for the viewport.
//! Pure function — no state, no side effects.

const std = @import("std");
const testing = std.testing;

const tui = @import("root.zig");
const Line = tui.widgets.Line;
const Style = tui.frame.Style;
const Color = tui.color.Color;

const think = @import("think.zig");
const tool_envelope = @import("tool_envelope.zig");

/// Trimmed view of a `SessionMessage` (TUI doesn't depend on the
/// backend wire types directly — populated by `App.onMessages`).
pub const MessageView = struct {
    role: []const u8,
    content: []const u8,
    tool_name: []const u8,
    reasoning_content: []const u8,
};

/// Render a message into 1+ `Line`s. Caller owns each `Line.text`
/// and the returned slice itself.
pub fn renderMessage(allocator: std.mem.Allocator, msg: MessageView) ![]Line {
    if (std.mem.eql(u8, msg.role, "user")) {
        const text = try std.fmt.allocPrint(allocator, "> {s}", .{msg.content});
        const lines = try allocator.dupe(Line, &[_]Line{.{
            .text = text,
            .style = .{ .fg = .green, .bold = true },
        }});
        return lines;
    }

    if (std.mem.eql(u8, msg.role, "assistant")) {
        if (try think.isThinkingOnly(allocator, msg.content)) {
            const text = try allocator.dupe(u8, "… thinking …");
            const lines = try allocator.dupe(Line, &[_]Line{.{
                .text = text,
                .style = .{ .fg = .brightBlack },
            }});
            return lines;
        }
        const stripped = try think.stripThinkingTags(allocator, msg.content);
        defer allocator.free(stripped);
        const unwrapped = try think.unwrapContentWrappers(allocator, stripped);
        defer allocator.free(unwrapped);
        // Split on newlines into multiple Lines so paragraphs/bullets
        // are preserved. Each line is stripped of markdown syntax for
        // TUI readability (desktop renders markdown via marked.parse).
        var out: std.ArrayList(Line) = .empty;
        defer out.deinit(allocator);
        var it = std.mem.splitScalar(u8, unwrapped, '\n');
        while (it.next()) |raw_line| {
            // Strip markdown syntax for TUI display
            const cleaned = try stripMarkdown(allocator, raw_line);
            defer allocator.free(cleaned);
            const trimmed = std.mem.trim(u8, cleaned, &std.ascii.whitespace);
            // Preserve empty lines as blank Lines (paragraph spacing)
            // but trim trailing whitespace. For non-empty, use cleaned
            // trimmed version.
            const text = if (trimmed.len == 0)
                try allocator.dupe(u8, "")
            else
                try allocator.dupe(u8, trimmed);
            try out.append(allocator, .{ .text = text, .style = .{} });
        }
        // Ensure at least one line
        if (out.items.len == 0) {
            const text = try allocator.dupe(u8, "");
            try out.append(allocator, .{ .text = text, .style = .{} });
        }
        return out.toOwnedSlice(allocator);
    }

    if (std.mem.eql(u8, msg.role, "tool")) {
        if (tool_envelope.tryParseToolEnvelope(allocator, msg.content)) |env| {
            defer env.deinit(allocator);
            const primary = try tool_envelope.toolEnvelopePrimary(allocator, env);
            defer allocator.free(primary);
            const badge = if (env.success) "✓" else "✗";
            // Header shape adapts to whether the primary field is
            // known. Empty primary → `▶ name  ✓` (no duplicated
            // name — the round-2 fix).
            const text = if (primary.len == 0)
                try std.fmt.allocPrint(allocator, "▶ {s}  {s}", .{ env.name, badge })
            else
                try std.fmt.allocPrint(allocator, "▶ {s}  {s}  {s}", .{ env.name, primary, badge });
            const lines = try allocator.dupe(Line, &[_]Line{.{
                .text = text,
                .style = .{ .fg = if (env.success) .magenta else .red },
            }});
            return lines;
        }
        // Legacy / malformed envelope — raw content as dim.
        const text = try allocator.dupe(u8, msg.content);
        const lines = try allocator.dupe(Line, &[_]Line{.{
            .text = text,
            .style = .{ .fg = .brightBlack },
        }});
        return lines;
    }

    // Unknown role — render raw dim.
    const text = try allocator.dupe(u8, msg.content);
    const lines = try allocator.dupe(Line, &[_]Line{.{
        .text = text,
        .style = .{ .fg = .brightBlack },
    }});
    return lines;
}

/// Strip markdown syntax for TUI plain-text display.
/// Removes **, __, `, #, >, and normalizes bullet markers.
/// Keeps the inner text content.
fn stripMarkdown(allocator: std.mem.Allocator, input: []const u8) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(allocator);
    try out.ensureTotalCapacity(allocator, input.len);

    var i: usize = 0;
    // Strip leading markdown markers: #, >, -, *, and whitespace
    // e.g. "## Heading" -> "Heading", "> quote" -> "quote", "- bullet" -> "• bullet"
    var start: usize = 0;
    // Handle heading markers: leading #'s + space
    while (start < input.len and input[start] == '#') start += 1;
    if (start > 0 and start < input.len and input[start] == ' ') start += 1;
    // Handle blockquote marker
    if (start < input.len and input[start] == '>') {
        start += 1;
        if (start < input.len and input[start] == ' ') start += 1;
    }
    // Handle bullet markers: "- ", "* ", "• "
    var is_bullet = false;
    if (start < input.len and (input[start] == '-' or input[start] == '*') and start + 1 < input.len and input[start + 1] == ' ') {
        is_bullet = true;
        start += 2;
    }
    if (is_bullet) {
        try out.appendSlice(allocator, "• ");
    }
    i = start;

    while (i < input.len) {
        // Skip ** and __ (bold)
        if (i + 1 < input.len and ((input[i] == '*' and input[i + 1] == '*') or (input[i] == '_' and input[i + 1] == '_'))) {
            i += 2;
            continue;
        }
        // Skip single ` (inline code)
        if (input[i] == '`') {
            i += 1;
            continue;
        }
        try out.append(allocator, input[i]);
        i += 1;
    }
    return out.toOwnedSlice(allocator);
}

// ----------------------------------------------------------------------------
// Tests (RED — impl added below after tests fail)
// ----------------------------------------------------------------------------

fn freeLines(allocator: std.mem.Allocator, lines: []Line) void {
    for (lines) |l| allocator.free(l.text);
    allocator.free(lines);
}

test "renderMessage: user role yields bold green prompt line" {
    const lines = try renderMessage(testing.allocator, .{
        .role = "user",
        .content = "hello",
        .tool_name = "",
        .reasoning_content = "",
    });
    defer freeLines(testing.allocator, lines);
    try testing.expectEqual(@as(usize, 1), lines.len);
    try testing.expectEqualStrings("> hello", lines[0].text);
    try testing.expect(lines[0].style.bold);
    try testing.expectEqual(@as(?Color, .green), lines[0].style.fg);
}

test "renderMessage: assistant with think block strips it" {
    const lines = try renderMessage(testing.allocator, .{
        .role = "assistant",
        .content = "<think>plan</think>the answer is 42",
        .tool_name = "",
        .reasoning_content = "",
    });
    defer freeLines(testing.allocator, lines);
    try testing.expectEqual(@as(usize, 1), lines.len);
    try testing.expectEqualStrings("the answer is 42", lines[0].text);
}

test "renderMessage: assistant thinking-only yields dim chip" {
    const lines = try renderMessage(testing.allocator, .{
        .role = "assistant",
        .content = "<think>just thinking</think>",
        .tool_name = "",
        .reasoning_content = "",
    });
    defer freeLines(testing.allocator, lines);
    try testing.expectEqualStrings("… thinking …", lines[0].text);
    try testing.expectEqual(@as(?Color, .brightBlack), lines[0].style.fg);
}

test "renderMessage: tool with valid envelope yields card header" {
    const content =
        "<tool><name>read_file</name><parameters></parameters><success>true</success><data><path>/foo.txt</path><content>x</content></data></tool>";
    const lines = try renderMessage(testing.allocator, .{
        .role = "tool",
        .content = content,
        .tool_name = "read_file",
        .reasoning_content = "",
    });
    defer freeLines(testing.allocator, lines);
    try testing.expectEqualStrings("▶ read_file  /foo.txt  ✓", lines[0].text);
    try testing.expectEqual(@as(?Color, .magenta), lines[0].style.fg);
}

test "renderMessage: tool with error envelope yields ✗ card line" {
    const content =
        "<tool><name>bash</name><parameters></parameters><success>false</success><error>boom</error></tool>";
    const lines = try renderMessage(testing.allocator, .{
        .role = "tool",
        .content = content,
        .tool_name = "bash",
        .reasoning_content = "",
    });
    defer freeLines(testing.allocator, lines);
    try testing.expect(std.mem.indexOf(u8, lines[0].text, "✗") != null);
    try testing.expectEqual(@as(?Color, .red), lines[0].style.fg);
}

test "renderMessage: tool with malformed content falls back to raw dim" {
    const lines = try renderMessage(testing.allocator, .{
        .role = "tool",
        .content = "some plain legacy output",
        .tool_name = "old_tool",
        .reasoning_content = "",
    });
    defer freeLines(testing.allocator, lines);
    try testing.expectEqualStrings("some plain legacy output", lines[0].text);
    try testing.expectEqual(@as(?Color, .brightBlack), lines[0].style.fg);
}

test "renderMessage: tool with no primary field renders bare name + badge" {
    // load_memory data is <results>...</results> — outside the
    // whitelist. toolEnvelopePrimary returns "" — header should
    // render as `▶ load_memory  ✓` (no duplicated name).
    const content =
        "<tool><name>load_memory</name><parameters></parameters><success>true</success><data><results>x</results></data></tool>";
    const lines = try renderMessage(testing.allocator, .{
        .role = "tool",
        .content = content,
        .tool_name = "load_memory",
        .reasoning_content = "",
    });
    defer freeLines(testing.allocator, lines);
    try testing.expectEqualStrings("▶ load_memory  ✓", lines[0].text);
    try testing.expectEqual(@as(?Color, .magenta), lines[0].style.fg);
}

test "renderMessage: assistant strips <plain> wrapper" {
    const lines = try renderMessage(testing.allocator, .{
        .role = "assistant",
        .content = "<plain>saya bisa bantu</plain>",
        .tool_name = "",
        .reasoning_content = "",
    });
    defer freeLines(testing.allocator, lines);
    try testing.expectEqualStrings("saya bisa bantu", lines[0].text);
}

test "renderMessage: assistant strips think AND <plain>" {
    const lines = try renderMessage(testing.allocator, .{
        .role = "assistant",
        .content = "<think>plan</think><plain>the visible answer</plain>",
        .tool_name = "",
        .reasoning_content = "",
    });
    defer freeLines(testing.allocator, lines);
    try testing.expectEqualStrings("the visible answer", lines[0].text);
}

test "renderMessage: unknown role renders raw dim" {
    const lines = try renderMessage(testing.allocator, .{
        .role = "system",
        .content = "system prompt text",
        .tool_name = "",
        .reasoning_content = "",
    });
    defer freeLines(testing.allocator, lines);
    try testing.expectEqualStrings("system prompt text", lines[0].text);
    try testing.expectEqual(@as(?Color, .brightBlack), lines[0].style.fg);
}

test "renderMessage: assistant multiline preserves paragraphs" {
    const lines = try renderMessage(testing.allocator, .{
        .role = "assistant",
        .content = "line1\nline2\nline3",
        .tool_name = "",
        .reasoning_content = "",
    });
    defer freeLines(testing.allocator, lines);
    try testing.expectEqual(@as(usize, 3), lines.len);
    try testing.expectEqualStrings("line1", lines[0].text);
    try testing.expectEqualStrings("line2", lines[1].text);
    try testing.expectEqualStrings("line3", lines[2].text);
}

test "renderMessage: assistant with blank line preserves empty line" {
    const lines = try renderMessage(testing.allocator, .{
        .role = "assistant",
        .content = "para1\n\npara2",
        .tool_name = "",
        .reasoning_content = "",
    });
    defer freeLines(testing.allocator, lines);
    try testing.expectEqual(@as(usize, 3), lines.len);
    try testing.expectEqualStrings("para1", lines[0].text);
    try testing.expectEqualStrings("", lines[1].text);
    try testing.expectEqualStrings("para2", lines[2].text);
}

test "renderMessage: assistant strips markdown bold" {
    const lines = try renderMessage(testing.allocator, .{
        .role = "assistant",
        .content = "Hello **world** and __bold__ text",
        .tool_name = "",
        .reasoning_content = "",
    });
    defer freeLines(testing.allocator, lines);
    try testing.expectEqual(@as(usize, 1), lines.len);
    try testing.expectEqualStrings("Hello world and bold text", lines[0].text);
}

test "renderMessage: assistant strips inline code backticks" {
    const lines = try renderMessage(testing.allocator, .{
        .role = "assistant",
        .content = "Use `app.go` and `main.go`",
        .tool_name = "",
        .reasoning_content = "",
    });
    defer freeLines(testing.allocator, lines);
    try testing.expectEqualStrings("Use app.go and main.go", lines[0].text);
}

test "renderMessage: assistant handles bullet list" {
    const lines = try renderMessage(testing.allocator, .{
        .role = "assistant",
        .content = "- item one\n- item two\n- item three",
        .tool_name = "",
        .reasoning_content = "",
    });
    defer freeLines(testing.allocator, lines);
    try testing.expectEqual(@as(usize, 3), lines.len);
    try testing.expectEqualStrings("• item one", lines[0].text);
    try testing.expectEqualStrings("• item two", lines[1].text);
    try testing.expectEqualStrings("• item three", lines[2].text);
}

test "renderMessage: assistant strips heading markers" {
    const lines = try renderMessage(testing.allocator, .{
        .role = "assistant",
        .content = "## Heading\n### Subheading\nNormal text",
        .tool_name = "",
        .reasoning_content = "",
    });
    defer freeLines(testing.allocator, lines);
    try testing.expectEqual(@as(usize, 3), lines.len);
    try testing.expectEqualStrings("Heading", lines[0].text);
    try testing.expectEqualStrings("Subheading", lines[1].text);
    try testing.expectEqualStrings("Normal text", lines[2].text);
}

test "renderMessage: assistant handles real-world markdown from screenshot" {
    const content = "Hai! Project **iblsql** adalah **aplikasi desktop**\n\nStack:\n- **Backend:** Go 1.25\n- **Frontend:** React";
    const lines = try renderMessage(testing.allocator, .{
        .role = "assistant",
        .content = content,
        .tool_name = "",
        .reasoning_content = "",
    });
    defer freeLines(testing.allocator, lines);
    try testing.expectEqual(@as(usize, 5), lines.len);
    try testing.expectEqualStrings("Hai! Project iblsql adalah aplikasi desktop", lines[0].text);
    try testing.expectEqualStrings("", lines[1].text);
    try testing.expectEqualStrings("Stack:", lines[2].text);
    try testing.expectEqualStrings("• Backend: Go 1.25", lines[3].text);
    try testing.expectEqualStrings("• Frontend: React", lines[4].text);
}

test "stripMarkdown: removes bold and code markers" {
    const got = try stripMarkdown(testing.allocator, "**bold** and `code`");
    defer testing.allocator.free(got);
    try testing.expectEqualStrings("bold and code", got);
}

test "stripMarkdown: handles bullet conversion" {
    const got = try stripMarkdown(testing.allocator, "- bullet item");
    defer testing.allocator.free(got);
    try testing.expectEqualStrings("• bullet item", got);
}

test "stripMarkdown: handles heading" {
    const got = try stripMarkdown(testing.allocator, "## My Heading");
    defer testing.allocator.free(got);
    try testing.expectEqualStrings("My Heading", got);
}
