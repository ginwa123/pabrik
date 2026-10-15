//! Tag input validation for the kanban task tags feature.

const std = @import("std");

pub const TagValidationError = error{
    InvalidTags,
};

/// Validate and normalize a tag input from the wire. Caller passes `raw:
/// ?[]const u8` from the parsed request body.
pub fn validateAndNormalizeTags(allocator: std.mem.Allocator, raw: ?[]const u8) (TagValidationError || std.mem.Allocator.Error)![]u8 {
    // null or empty string → "no tags" sentinel.
    if (raw == null or raw.?.len == 0) {
        return allocator.dupe(u8, "");
    }

    // Parse the JSON-encoded array.
    var parsed = std.json.parseFromSlice(std.json.Value, allocator, raw.?, .{}) catch {
        return TagValidationError.InvalidTags;
    };
    defer parsed.deinit();

    if (parsed.value != .array) return TagValidationError.InvalidTags;
    const arr = parsed.value.array;

    // Empty array → "no tags" sentinel (matches the "no tags
    // supplied" semantics of null/empty).
    if (arr.items.len == 0) {
        return allocator.dupe(u8, "");
    }

    // Set of lowercase tags seen so far (for case-insensitive dedupe).
    var seen = std.StringHashMapUnmanaged(void){};
    defer seen.deinit(allocator);

    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);

    try out.append(allocator, '[');

    for (arr.items, 0..) |item, i| {
        if (item != .string) return TagValidationError.InvalidTags;

        // Strip leading/trailing whitespace (the chip input may
        // submit tags with spaces if the user pastes them).
        const tag = std.mem.trim(u8, item.string, " \t\n\r");

        // Reject empty tags after trim.
        if (tag.len == 0) return TagValidationError.InvalidTags;

        // Reject tags over 50 chars (GitHub label convention).
        if (tag.len > 50) return TagValidationError.InvalidTags;

        // Reject forbidden chars (only [a-zA-Z0-9_-] allowed).
        for (tag) |c| {
            const ok = (c >= 'a' and c <= 'z') or (c >= 'A' and c <= 'Z') or
                (c >= '0' and c <= '9') or c == '_' or c == '-';
            if (!ok) return TagValidationError.InvalidTags;
        }

        // Build the lowercase key for case-insensitive dedupe.
        // Allocate a fresh buffer for the lowercased form so we
        // don't mutate the (borrowed) tag string.
        var lower_buf: [50]u8 = undefined;
        if (tag.len > lower_buf.len) return TagValidationError.InvalidTags; // safety belt
        for (tag, 0..) |c, idx| {
            lower_buf[idx] = std.ascii.toLower(c);
        }
        const lower_slice = lower_buf[0..tag.len];

        // Duplicate check via the hashmap. `getOrPut` returns
        // `found_existing = true` if the key already exists.
        const gop = seen.getOrPut(allocator, lower_slice) catch return TagValidationError.InvalidTags;
        if (gop.found_existing) {
            // Duplicate tag — skip this entry. Don't append to output.
            continue;
        }

        // First occurrence (case-insensitive) wins for casing.
        if (i > 0 and out.items.len > 1) {
            // Comma separator between tags.
            try out.append(allocator, ',');
        }
        try out.append(allocator, '"');
        try out.appendSlice(allocator, tag);
        try out.append(allocator, '"');
    }

    try out.append(allocator, ']');
    return out.toOwnedSlice(allocator);
}

// =====================================================================
// Tests
// =====================================================================

const testing = std.testing;

test "validateAndNormalizeTags: null returns empty string" {
    const result = try validateAndNormalizeTags(testing.allocator, null);
    defer testing.allocator.free(result);
    try testing.expectEqualStrings("", result);
}

test "validateAndNormalizeTags: empty string returns empty string" {
    const result = try validateAndNormalizeTags(testing.allocator, "");
    defer testing.allocator.free(result);
    try testing.expectEqualStrings("", result);
}

test "validateAndNormalizeTags: empty JSON array returns empty string" {
    const result = try validateAndNormalizeTags(testing.allocator, "[]");
    defer testing.allocator.free(result);
    try testing.expectEqualStrings("", result);
}

test "validateAndNormalizeTags: simple array normalizes correctly" {
    const result = try validateAndNormalizeTags(testing.allocator, "[\"bug\",\"urgent\"]");
    defer testing.allocator.free(result);
    try testing.expectEqualStrings("[\"bug\",\"urgent\"]", result);
}

test "validateAndNormalizeTags: dedupe case-insensitively preserves first casing" {
    const result = try validateAndNormalizeTags(testing.allocator, "[\"Bug\",\"bug\",\"BUG\"]");
    defer testing.allocator.free(result);
    try testing.expectEqualStrings("[\"Bug\"]", result);
}

test "validateAndNormalizeTags: rejects non-array JSON" {
    try testing.expectError(TagValidationError.InvalidTags, validateAndNormalizeTags(testing.allocator, "{\"a\":1}"));
    try testing.expectError(TagValidationError.InvalidTags, validateAndNormalizeTags(testing.allocator, "\"string\""));
    try testing.expectError(TagValidationError.InvalidTags, validateAndNormalizeTags(testing.allocator, "42"));
}

test "validateAndNormalizeTags: rejects array of non-strings" {
    try testing.expectError(TagValidationError.InvalidTags, validateAndNormalizeTags(testing.allocator, "[1,2,3]"));
    try testing.expectError(TagValidationError.InvalidTags, validateAndNormalizeTags(testing.allocator, "[null]"));
    try testing.expectError(TagValidationError.InvalidTags, validateAndNormalizeTags(testing.allocator, "[{\"a\":1}]"));
}

test "validateAndNormalizeTags: rejects invalid JSON" {
    try testing.expectError(TagValidationError.InvalidTags, validateAndNormalizeTags(testing.allocator, "not json"));
    try testing.expectError(TagValidationError.InvalidTags, validateAndNormalizeTags(testing.allocator, "["));
    try testing.expectError(TagValidationError.InvalidTags, validateAndNormalizeTags(testing.allocator, "[,]"));
}

test "validateAndNormalizeTags: rejects empty tag after trim" {
    try testing.expectError(TagValidationError.InvalidTags, validateAndNormalizeTags(testing.allocator, "[\"\"]"));
    try testing.expectError(TagValidationError.InvalidTags, validateAndNormalizeTags(testing.allocator, "[\"   \"]"));
    try testing.expectError(TagValidationError.InvalidTags, validateAndNormalizeTags(testing.allocator, "[\"\\t\"]"));
}

test "validateAndNormalizeTags: rejects tag with forbidden chars" {
    try testing.expectError(TagValidationError.InvalidTags, validateAndNormalizeTags(testing.allocator, "[\"with space\"]"));
    try testing.expectError(TagValidationError.InvalidTags, validateAndNormalizeTags(testing.allocator, "[\"with,comma\"]"));
    try testing.expectError(TagValidationError.InvalidTags, validateAndNormalizeTags(testing.allocator, "[\"with/slash\"]"));
    try testing.expectError(TagValidationError.InvalidTags, validateAndNormalizeTags(testing.allocator, "[\"with.dot\"]"));
    try testing.expectError(TagValidationError.InvalidTags, validateAndNormalizeTags(testing.allocator, "[\"with@at\"]"));
    try testing.expectError(TagValidationError.InvalidTags, validateAndNormalizeTags(testing.allocator, "[\"unicode-é\"]"));
}

test "validateAndNormalizeTags: rejects tag > 50 chars" {
    // Build a 51-char tag and wrap it as a JSON-encoded array. Use
    // std.mem.concat (returns []const u8, sentinel-free) so the resulting
    // buffer can be passed straight through to the validator.
    const too_long = "a" ** 51;
    const json = try std.mem.concat(testing.allocator, u8, &.{ "[\"", too_long[0..51], "\"]" });
    defer testing.allocator.free(json);
    try testing.expectError(TagValidationError.InvalidTags, validateAndNormalizeTags(testing.allocator, json));
}

test "validateAndNormalizeTags: accepts tag at exactly 50 chars" {
    const exactly_50 = "a" ** 50;
    const json = try std.mem.concat(testing.allocator, u8, &.{ "[\"", exactly_50[0..50], "\"]" });
    defer testing.allocator.free(json);
    const result = try validateAndNormalizeTags(testing.allocator, json);
    defer testing.allocator.free(result);
    try testing.expectEqualStrings(json, result);
}

test "validateAndNormalizeTags: accepts all allowed chars" {
    const result = try validateAndNormalizeTags(testing.allocator, "[\"abcXYZ-_\", \"123\", \"a-b_c-1\"]");
    defer testing.allocator.free(result);
    try testing.expectEqualStrings("[\"abcXYZ-_\",\"123\",\"a-b_c-1\"]", result);
}

test "validateAndNormalizeTags: trims whitespace from tags" {
    // The chip input may submit a tag with leading/trailing whitespace
    // if the user pasted it. Trim is safe (current char whitelist
    // doesn't include space).
    const result = try validateAndNormalizeTags(testing.allocator, "[\"  bug  \"]");
    defer testing.allocator.free(result);
    try testing.expectEqualStrings("[\"bug\"]", result);
}

test "validateAndNormalizeTags: dedupe preserves first occurrence (case-insensitive)" {
    // The frontend may send a list with case variations. The first
    // occurrence (by array order) wins for casing; later duplicates
    // are dropped silently.
    const result = try validateAndNormalizeTags(testing.allocator, "[\"a\",\"A\",\"a\"]");
    defer testing.allocator.free(result);
    try testing.expectEqualStrings("[\"a\"]", result);
}
