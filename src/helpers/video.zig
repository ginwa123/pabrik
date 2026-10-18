const std = @import("std");

/// Extract all base64 video URLs from a message Looks for patterns like:
/// data:video/mp4;base64,... or data:video/webm;base64,...
pub fn extractBase64VideoUrls(message: []const u8, allocator: std.mem.Allocator) ![][]const u8 {
    const prefix = "data:video/";
    const base64_marker = ";base64,";

    var results = std.ArrayList([]const u8).empty;
    errdefer {
        for (results.items) |item| allocator.free(item);
        results.deinit(allocator);
    }

    var search_start: usize = 0;

    while (true) {
        const prefix_idx = std.mem.indexOf(u8, message[search_start..], prefix) orelse break;
        const data_start = search_start + prefix_idx;

        const base64_idx = std.mem.indexOf(u8, message[data_start..], base64_marker) orelse break;
        const marker_start = data_start + base64_idx;

        const data_start_pos = marker_start + base64_marker.len;
        const remaining = message[data_start_pos..];

        var end_idx: usize = remaining.len;
        for (remaining, 0..) |byte, i| {
            const is_base64_char = (byte >= 'A' and byte <= 'Z') or
                (byte >= 'a' and byte <= 'z') or
                (byte >= '0' and byte <= '9') or
                byte == '+' or byte == '/' or byte == '=';
            if (byte == ' ' or byte == '\t' or byte == '\n' or byte == '\r') {
                end_idx = i;
                break;
            }
            if (!is_base64_char) {
                end_idx = i;
                break;
            }
            if (byte == '.' or byte == ',' or byte == '"' or byte == '\'' or
                byte == ')' or byte == ']' or byte == '}' or byte == '>' or
                byte == ':' or byte == ';')
            {
                end_idx = i;
                break;
            }
            if (i + prefix.len <= remaining.len) {
                const possible_prefix = remaining[i..];
                if (std.mem.startsWith(u8, possible_prefix, prefix)) {
                    end_idx = i;
                    break;
                }
            }
        }

        const full_url = message[data_start..data_start_pos + end_idx];
        const url_copy = try allocator.dupe(u8, full_url);
        errdefer allocator.free(url_copy);

        try results.append(allocator, url_copy);
        search_start = data_start_pos + end_idx;
    }

    return try results.toOwnedSlice(allocator);
}

test "extractBase64VideoUrls finds mp4 url" {
    const alloc = std.testing.allocator;
    const msg = "see this data:video/mp4;base64,AAAAIGZ0eXBpc29t end";
    const urls = try extractBase64VideoUrls(msg, alloc);
    defer {
        for (urls) |u| alloc.free(u);
        alloc.free(urls);
    }
    try std.testing.expectEqual(@as(usize, 1), urls.len);
    try std.testing.expect(std.mem.startsWith(u8, urls[0], "data:video/mp4;base64,"));
}

test "extractBase64VideoUrls returns empty when no video" {
    const alloc = std.testing.allocator;
    const urls = try extractBase64VideoUrls("hello world", alloc);
    defer alloc.free(urls);
    try std.testing.expectEqual(@as(usize, 0), urls.len);
}
