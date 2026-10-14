//! Pure helpers for parsing the per-profile / per-sub-agent `thinking` and
//! `reasoning_effort` string fields.

const std = @import("std");

/// Errors emitted by `parseThinkingString`.
pub const ThinkingModeError = error{InvalidThinkingMode};

/// Parses the per-profile / per-sub-agent `thinking` string field into a
/// typed `?bool`.
pub fn parseThinkingString(raw: []const u8) ThinkingModeError!?bool {
    // Tolerate a single leading/trailing space — defensive against
    // hand-edited config.json files.
    const trimmed: []const u8 = blk: {
        if (raw.len >= 1 and raw[0] == ' ') break :blk raw[1..];
        break :blk raw;
    };
    const s: []const u8 = blk: {
        if (trimmed.len >= 1 and trimmed[trimmed.len - 1] == ' ') break :blk trimmed[0 .. trimmed.len - 1];
        break :blk trimmed;
    };

    if (s.len == 0) return null;
    if (std.mem.eql(u8, s, "auto")) return null;
    if (std.mem.eql(u8, s, "on")) return true;
    if (std.mem.eql(u8, s, "off")) return false;
    // Legacy aliases — pre-2026-08-23 UI wrote boolean strings.
    if (std.mem.eql(u8, s, "true")) return true;
    if (std.mem.eql(u8, s, "false")) return false;
    return error.InvalidThinkingMode;
}

/// Errors emitted by `parseReasoningEffort`.
pub const ReasoningEffortError = error{InvalidReasoningEffort};

/// Parses the per-profile / per-sub-agent `reasoning_effort` string field
/// into the canonical 4-value set accepted by OpenAI-style reasoning APIs (o1
/// / o3 / GPT-5 / DeepSeek-R1): - `"low"` → `"low"` - `"medium"` → `"medium"`
pub fn parseReasoningEffort(raw: []const u8) ReasoningEffortError![]const u8 {
    if (raw.len == 0) return "auto";
    if (std.mem.eql(u8, raw, "low")) return "low";
    if (std.mem.eql(u8, raw, "medium")) return "medium";
    if (std.mem.eql(u8, raw, "high")) return "high";
    if (std.mem.eql(u8, raw, "auto")) return "auto";
    return error.InvalidReasoningEffort;
}

// ===== Tests merged from parse_thinking_test.zig (2026-09-29 flatten) =====
// Tests for parse_thinking.zig — pure helpers `parseThinkingString` and
// `parseReasoningEffort`.

const testing = std.testing;

test "parseThinkingString auto -> null (inherit)" {
    try testing.expectEqual(@as(?bool, null), try parseThinkingString("auto"));
}

test "parseThinkingString on -> true (extended reasoning enabled)" {
    try testing.expectEqual(@as(?bool, true), try parseThinkingString("on"));
}

test "parseThinkingString off -> false (extended reasoning disabled)" {
    try testing.expectEqual(@as(?bool, false), try parseThinkingString("off"));
}

test "parseThinkingString true -> true (legacy UI wrote boolean strings)" {
    try testing.expectEqual(@as(?bool, true), try parseThinkingString("true"));
}

test "parseThinkingString false -> false (legacy)" {
    try testing.expectEqual(@as(?bool, false), try parseThinkingString("false"));
}

test "parseThinkingString empty -> null (auto)" {
    try testing.expectEqual(@as(?bool, null), try parseThinkingString(""));
}

test "parseThinkingString garbage -> error.InvalidThinkingMode" {
    try testing.expectError(error.InvalidThinkingMode, parseThinkingString("maybe"));
}

test "parseThinkingString leading whitespace stripped" {
    // Defensive: tolerate one accidental leading space (frontend types
    // shouldn't carry whitespace, but a hand-edited config.json might).
    try testing.expectEqual(@as(?bool, true), try parseThinkingString(" on"));
    try testing.expectEqual(@as(?bool, false), try parseThinkingString("off "));
}

test "parseReasoningEffort low" {
    try testing.expectEqualStrings("low", try parseReasoningEffort("low"));
}

test "parseReasoningEffort medium" {
    try testing.expectEqualStrings("medium", try parseReasoningEffort("medium"));
}

test "parseReasoningEffort high" {
    try testing.expectEqualStrings("high", try parseReasoningEffort("high"));
}

test "parseReasoningEffort auto" {
    try testing.expectEqualStrings("auto", try parseReasoningEffort("auto"));
}

test "parseReasoningEffort empty -> auto" {
    try testing.expectEqualStrings("auto", try parseReasoningEffort(""));
}

test "parseReasoningEffort garbage -> error.InvalidReasoningEffort" {
    try testing.expectError(error.InvalidReasoningEffort, parseReasoningEffort("super"));
}

test "parseReasoningEffort is case-sensitive (Anthropic / OpenAI treat LOW/low the same but we do NOT silently lowercase)" {
    // The frontend always sends lowercase; we accept only lowercase.
    // Uppercase would surface as an error so the user notices a misconfig.
    try testing.expectError(error.InvalidReasoningEffort, parseReasoningEffort("LOW"));
}
