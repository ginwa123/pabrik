const std = @import("std");

pub const LLMModels = struct {
    name: []const u8,
    description: []const u8,
    token_count: u32,
};

pub const MINIMAX_2_7 = LLMModels{
    .name = "MiniMax-M2.7",
    .description = "Minimax-M2.7 is a large language model trained by Anthropic. It is a variant of the MiniMax model, which is a transformer-based language model. It is trained on a diverse range of text sources, including books, articles, and websites.",
    .token_count = 200000,
};

pub const MINIMAX_3 = LLMModels{
    .name = "MiniMax-M3",
    .description = "Minimax-M3 is a large language model trained by Anthropic. It is a variant of the MiniMax model, which is a transformer-based language model. It is trained on a diverse range of text sources, including books, articles, and websites.",
    .token_count = 500000,
};

/// Claude Sonnet alias for Claude Code CLI profiles
/// (`url_style="claude-code"`, `--model sonnet`). 200k context.
pub const CLAUDE_SONNET = LLMModels{
    .name = "sonnet",
    .description = "Claude Sonnet via the Claude Code CLI (subscription auth, no API key). Balanced speed and quality for everyday coding.",
    .token_count = 200000,
};

/// Claude Opus alias for Claude Code CLI profiles. 200k context.
pub const CLAUDE_OPUS = LLMModels{
    .name = "opus",
    .description = "Claude Opus via the Claude Code CLI (subscription auth, no API key). Strongest reasoning for hard tasks.",
    .token_count = 200000,
};

/// Claude Sonnet 4.5 full model id (Anthropic API + CLI `--model`).
pub const CLAUDE_SONNET_4_5 = LLMModels{
    .name = "claude-sonnet-4-5-20250929",
    .description = "Claude Sonnet 4.5 — best for coding agents on real-world tasks.",
    .token_count = 200000,
};

/// Get model token count by model name string
pub fn getModelTokenCount(model_name: []const u8) u32 {
    if (std.mem.eql(u8, model_name, MINIMAX_2_7.name)) {
        return MINIMAX_2_7.token_count;
    }

    if (std.mem.eql(u8, model_name, MINIMAX_3.name)) {
        return MINIMAX_3.token_count;
    }

    if (std.mem.eql(u8, model_name, CLAUDE_SONNET.name)) {
        return CLAUDE_SONNET.token_count;
    }

    if (std.mem.eql(u8, model_name, CLAUDE_OPUS.name)) {
        return CLAUDE_OPUS.token_count;
    }

    if (std.mem.eql(u8, model_name, CLAUDE_SONNET_4_5.name)) {
        return CLAUDE_SONNET_4_5.token_count;
    }
    // Default fallback (e.g., 128k tokens)
    return 200000;
}

pub fn isDoCompact(token_count: u32, max_capicity_token: u32) bool {
    // auto compact 80% of tokens
    const threshold = max_capicity_token * 8 / 10; // 80%
    return token_count >= threshold;
}

/// Resolve the effective max-context-window in tokens for `model_name`,
/// honoring an optional config override.
pub fn resolveMaxCapacity(model_name: []const u8, override_capacity: ?u32) u32 {
    return override_capacity orelse getModelTokenCount(model_name);
}

/// Decide whether `token_count` should trigger compaction given a
/// `max_capacity` (in tokens) and a `threshold_percent` (0-100). Equivalent
/// to `token_count >= max_capacity * threshold_percent / 100`.
pub fn shouldCompact(token_count: u32, max_capacity: u32, threshold_percent: ?u8) bool {
    const pct: u32 = threshold_percent orelse 80;
    const threshold = max_capacity * pct / 100;
    return token_count >= threshold;
}

// ===== Tests merged from LLMModels_test.zig (2026-09-29 flatten) =====
const expect = std.testing.expect;
const expectEqual = std.testing.expectEqual;

// ============================================================================
// get_model_token_count Tests
// ============================================================================

test "get_model_token_count returns correct token count for MINIMAX_2_7" {
    const result = getModelTokenCount(MINIMAX_2_7.name);
    try expectEqual(@as(u32, 200000), result);
}

test "get_model_token_count returns fallback for unknown model" {
    const result = getModelTokenCount("Unknown-Model");
    try expectEqual(@as(u32, 200000), result);
}

test "get_model_token_count returns fallback for empty string" {
    const result = getModelTokenCount("");
    try expectEqual(@as(u32, 200000), result);
}

test "get_model_token_count returns fallback for partial match" {
    // Partial name should not match
    const result = getModelTokenCount("MiniMax");
    try expectEqual(@as(u32, 200000), result);
}

test "get_model_token_count returns fallback for case-sensitive mismatch" {
    // Model name comparison is case-sensitive
    const result = getModelTokenCount("minimax-m2.7");
    try expectEqual(@as(u32, 200000), result);
}

// ============================================================================
// is_do_compact Tests
// ============================================================================

test "is_do_compact returns false when below 80% threshold" {
    // 50% of capacity
    try expect(!isDoCompact(50, 100));
}

test "is_do_compact returns false when just below 80% threshold" {
    // 79% of capacity
    try expect(!isDoCompact(79, 100));
}

test "is_do_compact returns true at exactly 80% threshold" {
    // Exactly 80% of capacity
    try expect(isDoCompact(80, 100));
}

test "is_do_compact returns true above 80% threshold" {
    // 81% of capacity
    try expect(isDoCompact(81, 100));
}

test "is_do_compact returns true at 100% capacity" {
    try expect(isDoCompact(100, 100));
}

test "is_do_compact returns false at 0 tokens" {
    try expect(!isDoCompact(0, 100));
}

test "is_do_compact with real-world token values" {
    // Simulating MINIMAX-M2.7 with 200k context (80% threshold = 160k)
    const max_capacity = 200000;

    // 250k message exceeds 80% threshold (160k) → should compact
    const large_message = 250000;
    try expect(isDoCompact(large_message, max_capacity));
}

test "is_do_compact with 200k model values" {
    const max_capacity = 200000;
    // Just below threshold (79%)
    try expect(!isDoCompact(157999, max_capacity));
    // At threshold (80%)
    try expect(isDoCompact(160000, max_capacity));
}

test "is_do_compact threshold calculation is integer-accurate" {
    // Test with values that could cause integer division issues
    const max_capacity: u32 = 3;
    // 3 * 8 / 10 = 2 (integer division)
    try expect(!isDoCompact(1, max_capacity)); // Below threshold
    try expect(isDoCompact(2, max_capacity)); // At threshold
    try expect(isDoCompact(3, max_capacity)); // Above threshold
}

// ============================================================================
// resolve_max_capacity Tests
// ============================================================================

test "resolve_max_capacity returns override when set" {
    try expectEqual(@as(u32, 128000), resolveMaxCapacity("MiniMax-M3", 128000));
    try expectEqual(@as(u32, 128000), resolveMaxCapacity("Unknown", 128000));
}

test "resolve_max_capacity falls back to getModelTokenCount when override is null" {
    try expectEqual(@as(u32, 500000), resolveMaxCapacity("MiniMax-M3", null));
    try expectEqual(@as(u32, 200000), resolveMaxCapacity("MiniMax-M2.7", null));
    try expectEqual(@as(u32, 200000), resolveMaxCapacity("Unknown", null));
}

// ============================================================================
// should_compact Tests
// ============================================================================

test "should_compact with custom threshold_percent" {
    // 50% of 200k = 100k threshold
    try expect(!shouldCompact(99_999, 200_000, 50));
    try expect(shouldCompact(100_000, 200_000, 50));
    try expect(shouldCompact(200_000, 200_000, 50));
}

test "should_compact with null threshold_percent defaults to 80%" {
    try expect(!shouldCompact(159_999, 200_000, null));
    try expect(shouldCompact(160_000, 200_000, null));
    try expect(shouldCompact(250_000, 200_000, null));
}

test "should_compact with threshold_percent=0 never triggers" {
    // 0% threshold = never compact (token_count >= 0 always, but *0/100 = 0)
    try expect(shouldCompact(0, 200_000, 0));
    try expect(shouldCompact(1, 200_000, 0));
    try expect(shouldCompact(1_000_000, 200_000, 0));
}

test "should_compact with threshold_percent=100 always triggers (unless token_count is 0)" {
    // 100% threshold = token_count >= max_capacity
    try expect(!shouldCompact(99, 100, 100));
    try expect(shouldCompact(100, 100, 100));
    try expect(shouldCompact(101, 100, 100));
}
