//! `llm_history.model` must never be empty.

const std = @import("std");

/// Written to `llm_history.model` when no model could be resolved.
/// Deliberately not a plausible model id — it must never be mistaken for a
/// provider/model that was actually used.
pub const UNKNOWN_MODEL: []const u8 = "unknown";

/// True when `model` cannot be persisted: absent, empty, or only
/// whitespace. Whitespace matters — an agent whose `model` is `"  "`
/// passes `len > 0` checks elsewhere but is equally unusable.
pub fn isEmpty(model: []const u8) bool {
    return std.mem.trim(u8, model, " \t\r\n").len == 0;
}

/// The single entry point every `llm_history.model` writer must use. Returns
/// `model` unchanged when it carries content, otherwise `UNKNOWN_MODEL`.
pub fn resolve(model: []const u8) []const u8 {
    return if (isEmpty(model)) UNKNOWN_MODEL else model;
}

// ─── Tests ──────────────────────────────────────────────────────────────────

const testing = std.testing;

test "resolve passes a real model through unchanged" {
    try testing.expectEqualStrings("space-bunny-free", resolve("space-bunny-free"));
    try testing.expectEqualStrings("MiniMax-M3", resolve("MiniMax-M3"));
}

test "resolve substitutes the sentinel for an empty model" {
    try testing.expectEqualStrings(UNKNOWN_MODEL, resolve(""));
}

test "resolve substitutes the sentinel for a whitespace-only model" {
    // `len > 0` is NOT sufficient — an agent can carry `"  "`.
    try testing.expectEqualStrings(UNKNOWN_MODEL, resolve(" "));
    try testing.expectEqualStrings(UNKNOWN_MODEL, resolve("\t\n"));
    try testing.expectEqualStrings(UNKNOWN_MODEL, resolve("   \r\n\t  "));
}

test "resolve preserves interior/leading whitespace on a non-blank model" {
    // Only a fully-blank model is replaced. A model id with a stray
    // leading space is still a model id; trimming here would silently
    // rewrite the user's configured value.
    try testing.expectEqualStrings(" gpt-4o", resolve(" gpt-4o"));
    try testing.expectEqualStrings("gpt 4o", resolve("gpt 4o"));
}

test "resolve never returns an empty slice for any input" {
    // The invariant the whole module exists to provide. Fuzzed over the
    // degenerate shapes the call sites actually produce.
    const inputs = [_][]const u8{ "", " ", "\n", "\t\r\n", "0", "a", UNKNOWN_MODEL, " ", "  a  " };
    for (inputs) |in| {
        try testing.expect(resolve(in).len > 0);
        try testing.expect(!isEmpty(resolve(in)));
    }
}

test "resolve is a no-op for a non-blank model, sentinel for a blank one" {
    // Asserted as two implications rather than one biconditional.
    const inputs = [_][]const u8{ "", " ", "\t\n", "   \r\n\t  ", "a", " gpt-4o", "gpt 4o", UNKNOWN_MODEL };
    for (inputs) |in| {
        if (isEmpty(in)) {
            try testing.expectEqualStrings(UNKNOWN_MODEL, resolve(in));
        } else {
            // A real value is returned verbatim — the guard never rewrites it.
            try testing.expectEqualStrings(in, resolve(in));
        }
    }
}

test "UNKNOWN_MODEL is not confusable with a real model id" {
    // The sentinel's job is to be visibly "not a model". If a future edit
    // made it look like a real provider id, the two failure modes would
    // silently merge.
    try testing.expect(!std.mem.eql(u8, UNKNOWN_MODEL, ""));
    try testing.expect(UNKNOWN_MODEL.len > 0);
    try testing.expectEqualStrings("unknown", UNKNOWN_MODEL);
}
