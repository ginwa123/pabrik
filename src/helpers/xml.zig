const std = @import("std");

pub fn decodeXmlEntities(allocator: std.mem.Allocator, s: []const u8) ![]const u8 {
    var result = std.ArrayList(u8).empty;
    errdefer result.deinit(allocator);

    var i: usize = 0;
    while (i < s.len) {
        if (s[i] == '&') {
            if (std.mem.startsWith(u8, s[i..], "&amp;")) {
                try result.append(allocator, '&');
                i += 5;
            } else if (std.mem.startsWith(u8, s[i..], "&lt;")) {
                try result.append(allocator, '<');
                i += 4;
            } else if (std.mem.startsWith(u8, s[i..], "&gt;")) {
                try result.append(allocator, '>');
                i += 4;
            } else if (std.mem.startsWith(u8, s[i..], "&quot;")) {
                try result.append(allocator, '"');
                i += 6;
            } else if (std.mem.startsWith(u8, s[i..], "&apos;")) {
                try result.append(allocator, '\'');
                i += 6;
            } else {
                try result.append(allocator, s[i]);
                i += 1;
            }
        } else {
            try result.append(allocator, s[i]);
            i += 1;
        }
    }

    return result.toOwnedSlice(allocator);
}

pub fn extractTag(xml: []const u8, tag: []const u8, allocator: std.mem.Allocator) ?[]const u8 {
    const start_tag = std.fmt.allocPrint(allocator, "<{s}>", .{tag}) catch return null;
    defer allocator.free(start_tag);
    const end_tag = std.fmt.allocPrint(allocator, "</{s}>", .{tag}) catch return null;
    defer allocator.free(end_tag);

    const start_idx = std.mem.indexOf(u8, xml, start_tag) orelse return null;
    const content_start = start_idx + start_tag.len;
    const end_idx = std.mem.indexOf(u8, xml[content_start..], end_tag) orelse return null;

    return xml[content_start .. content_start + end_idx];
}

// Thinking tags used by LLM models (e.g., Claude, DeepSeek) <think> = <think> (7 bytes) = </think> (8 bytes)
const THINK_OPEN: []const u8 = &[_]u8{ '<', 't', 'h', 'i', 'n', 'k', '>' };
const THINK_CLOSE: []const u8 = &[_]u8{ '<', '/', 't', 'h', 'i', 'n', 'k', '>' };

pub fn stripThinkingTags(content: []const u8, allocator: std.mem.Allocator) ![]const u8 {
    if (std.mem.indexOf(u8, content, THINK_OPEN)) |think_start| {
        const think_end = std.mem.indexOf(u8, content, THINK_CLOSE) orelse return try allocator.dupe(u8, content);
        const before = content[0..think_start];
        const after = content[think_end + THINK_CLOSE.len ..];
        const result = try allocator.alloc(u8, before.len + after.len);
        @memcpy(result[0..before.len], before);
        @memcpy(result[before.len..], after);
        return result;
    }
    return try allocator.dupe(u8, content);
}
