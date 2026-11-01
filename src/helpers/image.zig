const std = @import("std");

/// The raster formats every chat provider accepts as an `image_url` part.
/// Recognised by magic bytes, never by file extension: a `.jpg` that is
/// really a PNG must be described as the PNG it is or the provider rejects it.
pub fn sniffImageMime(bytes: []const u8) ?[]const u8 {
    if (std.mem.startsWith(u8, bytes, "\x89PNG\r\n\x1a\n")) return "image/png";
    if (std.mem.startsWith(u8, bytes, "\xFF\xD8\xFF")) return "image/jpeg";
    if (std.mem.startsWith(u8, bytes, "GIF87a") or std.mem.startsWith(u8, bytes, "GIF89a")) return "image/gif";
    if (bytes.len >= 12 and std.mem.startsWith(u8, bytes, "RIFF") and std.mem.eql(u8, bytes[8..12], "WEBP")) return "image/webp";
    return null;
}

/// A NUL byte in the head of a file is what makes it unreadable as text.
/// Only NUL counts: a lone invalid byte is a Latin-1 line in a source file,
/// not a binary.
pub fn looksBinary(bytes: []const u8) bool {
    const head = bytes[0..@min(bytes.len, 8192)];
    return std.mem.indexOfScalar(u8, head, 0) != null;
}

/// The largest image `read_file` will inline as a data URL: the same 10 MB the
/// upload validators use, so one read can never exceed what a chat attachment
/// can carry.
pub const max_inline_bytes: usize = 10 * 1024 * 1024;

/// `data:<mime>;base64,<payload>` — the only shape the providers accept and
/// the only shape `validateImageUrls` lets through.
pub fn toDataUrl(allocator: std.mem.Allocator, mime: []const u8, bytes: []const u8) ![]u8 {
    const prefix_len = "data:".len + mime.len + ";base64,".len;
    const url = try allocator.alloc(u8, prefix_len + std.base64.standard.Encoder.calcSize(bytes.len));
    errdefer allocator.free(url);
    @memcpy(url[0..5], "data:");
    @memcpy(url[5 .. 5 + mime.len], mime);
    @memcpy(url[5 + mime.len .. prefix_len], ";base64,");
    _ = std.base64.standard.Encoder.encode(url[prefix_len..], bytes);
    return url;
}

/// Extract all base64 image URLs from a message
/// Looks for patterns like: data:image/png;base64,... or data:image/jpeg;base64,...
/// Returns an array of all data URLs found (can be empty)
pub fn extractBase64ImageUrls(message: []const u8, allocator: std.mem.Allocator) ![][]const u8 {
    const prefix = "data:image/";
    const base64_marker = ";base64,";
    
    var results = std.ArrayList([]const u8).empty;
    errdefer {
        for (results.items) |item| allocator.free(item);
        results.deinit(allocator);
    }
    
    var search_start: usize = 0;
    
    while (true) {
        // Find the next prefix starting from search_start
        const prefix_idx = std.mem.indexOf(u8, message[search_start..], prefix) orelse break;
        const data_start = search_start + prefix_idx;
        
        // Find the base64 marker after the prefix
        const base64_idx = std.mem.indexOf(u8, message[data_start..], base64_marker) orelse break;
        const marker_start = data_start + base64_idx;
        
        // Find the end of the data URL
        const data_start_pos = marker_start + base64_marker.len;
        const remaining = message[data_start_pos..];
        
        // Find end of base64 data
        // Valid base64 chars: A-Z, a-z, 0-9, +, /, = 
        // Stop when we hit whitespace, punctuation, OR another data:image/ pattern
        var end_idx: usize = remaining.len;
        for (remaining, 0..) |byte, i| {
            // Check if byte is a valid base64 character
            // Valid: A-Z (65-90), a-z (97-122), 0-9 (48-57), + (43), / (47), = (61)
            const is_base64_char = (byte >= 'A' and byte <= 'Z') or
                                  (byte >= 'a' and byte <= 'z') or
                                  (byte >= '0' and byte <= '9') or
                                  byte == '+' or byte == '/' or byte == '=';
            
            // Stop at whitespace (space, tab, newline, carriage return)
            if (byte == ' ' or byte == '\t' or byte == '\n' or byte == '\r') {
                end_idx = i;
                break;
            }
            
            // Stop if byte is not a valid base64 character (could be punctuation or control char)
            if (!is_base64_char) {
                end_idx = i;
                break;
            }
            
            // Stop at common punctuation that terminates URLs
            if (byte == '.' or byte == ',' or byte == '"' or byte == '\'' or
                byte == ')' or byte == ']' or byte == '}' or byte == '>' or
                byte == ':' or byte == ';') {
                end_idx = i;
                break;
            }
            // Stop if next chars start another image pattern
            if (i + prefix.len <= remaining.len) {
                const possible_prefix = remaining[i..];
                if (std.mem.startsWith(u8, possible_prefix, prefix)) {
                    end_idx = i;
                    break;
                }
            }
        }
        
        // Extract the full data URL and store a copy
        const full_url = message[data_start..data_start_pos + end_idx];
        const url_copy = try allocator.dupe(u8, full_url);
        errdefer allocator.free(url_copy);
        
        try results.append(allocator, url_copy);
        
        // Move search position past this image for next iteration
        search_start = data_start_pos + end_idx;
    }
    
    return try results.toOwnedSlice(allocator);
}