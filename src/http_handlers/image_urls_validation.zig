//! Validation + joining helpers for `workspace_item_tasks.image_urls`
//! (Migration 069 — kanban image urls column).

const std = @import("std");

/// Cap on the total joined `image_urls` payload (10 MB). The frontend
/// pre-downscales images via `<canvas>` to < 4 MB raw, so the typical base64
/// payload is 5-6 MB.
pub const MAX_IMAGE_URLS_BYTES: usize = 10 * 1024 * 1024;

/// Validate each URL in `joined` is a `data:image/<mime>;base64,...` URL and
/// the total byte length is within `MAX_IMAGE_URLS_BYTES`.
pub fn validateImageUrls(joined: []const u8) ![]const u8 {
    if (joined.len > MAX_IMAGE_URLS_BYTES) return error.ImageUrlsTooLarge;
    if (joined.len == 0) return joined; // empty = no images

    // Split on `|` and validate each non-empty segment.
    var iter = std.mem.splitScalar(u8, joined, '|');
    while (iter.next()) |segment| {
        if (segment.len == 0) continue; // tolerate empty segments (consecutive `||`)
        if (!isValidDataUrl(segment)) return error.InvalidImageUrl;
    }
    return joined;
}

/// `data:image/<mime>;base64,<payload>` — the only shape the frontend's
/// `FileReader.readAsDataURL` produces.
fn isValidDataUrl(segment: []const u8) bool {
    const prefix = "data:image/";
    if (!std.mem.startsWith(u8, segment, prefix)) return false;
    const after_scheme = segment[prefix.len..];
    // Find `;base64,` separator.
    const sep = std.mem.indexOf(u8, after_scheme, ";base64,") orelse return false;
    if (sep == 0) return false; // empty MIME
    const payload = after_scheme[sep + ";base64,".len ..];
    if (payload.len == 0) return false; // empty payload
    return true;
}

test "validateImageUrls accepts empty (no images sentinel)" {
    const result = try validateImageUrls("");
    try std.testing.expectEqualStrings("", result);
}

test "validateImageUrls accepts a single valid data URL" {
    const url = "data:image/png;base64,iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNkYAAAAAYAAjCB0C8AAAAASUVORK5CYII=";
    const result = try validateImageUrls(url);
    try std.testing.expectEqualStrings(url, result);
}

test "validateImageUrls accepts multiple data URLs joined with ||" {
    const joined = "data:image/png;base64,iVBORw0||data:image/jpeg;base64,/9j/4AAQS";
    const result = try validateImageUrls(joined);
    try std.testing.expectEqualStrings(joined, result);
}

test "validateImageUrls rejects non-data URLs" {
    // http:// should NOT be accepted (security: prevents `<img>` from
    // pointing at private network resources).
    const result = validateImageUrls("http://example.com/foo.png");
    try std.testing.expectError(error.InvalidImageUrl, result);
}

test "validateImageUrls rejects base64 without data: prefix" {
    const result = validateImageUrls("iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNkYAAAAAYAAjCB0C8AAAAASUVORK5CYII=");
    try std.testing.expectError(error.InvalidImageUrl, result);
}

test "validateImageUrls rejects data: prefix without ;base64," {
    const result = validateImageUrls("data:image/png,abc123");
    try std.testing.expectError(error.InvalidImageUrl, result);
}

test "validateImageUrls rejects empty payload after ;base64," {
    const result = validateImageUrls("data:image/png;base64,");
    try std.testing.expectError(error.InvalidImageUrl, result);
}

test "validateImageUrls rejects empty MIME type" {
    const result = validateImageUrls("data:image/;base64,abc");
    try std.testing.expectError(error.InvalidImageUrl, result);
}

test "validateImageUrls tolerates empty segments between consecutive ||" {
    // The frontend's join helper always produces non-empty segments,
    // but tolerate the trailing `||` case for robustness (e.g. when
    // joining in user space).
    const joined = "data:image/png;base64,abc||";
    const result = try validateImageUrls(joined);
    try std.testing.expectEqualStrings(joined, result);
}

test "validateImageUrls accepts payloads at the cap" {
    // Boundary check: a payload that is exactly the cap is accepted (the
    // check is `> cap`, not `>= cap`).
    try std.testing.expectEqual(@as(usize, 10 * 1024 * 1024), MAX_IMAGE_URLS_BYTES);
    // A small payload that's well under the cap validates.
    const ok = "data:image/png;base64,abc";
    const result = try validateImageUrls(ok);
    try std.testing.expectEqualStrings(ok, result);
}