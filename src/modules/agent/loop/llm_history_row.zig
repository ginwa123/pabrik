const std = @import("std");
const testing = std.testing;


pub const LLMHistory = struct {
    id: []const u8,
    session_id: []const u8,
    model: []const u8,
    created_at: []const u8,
    response_content: []const u8,
    finish_reason: []const u8,
    role: []const u8,
    reasoning_content: ?[]const u8 = null,
    reasoning_id: ?[]const u8 = null,
    reasoning_encrypted_content: ?[]const u8 = null,
    agent: []const u8 = "Agent",
    session_name: []const u8 = "",
    loop_index: u32 = 0,
    tool_name: []const u8 = "",
    parent_session_id: ?[]const u8 = null,
    parent_id: ?[]const u8 = null,
    temperature: f32 = 0.2,
    is_thinking: bool = false,
    prompt_tokens: u32 = 0,
    completion_tokens: u32 = 0,
    total_tokens: u32 = 0,
    /// Anthropic-only: cache WRITE tokens (cache_creation_input_tokens).
    /// Billed at ~1.25x input rate. 0 for OpenAI rows.
    cache_creation_input_tokens: u32 = 0,
    /// Anthropic-only: cache READ tokens (cache_read_input_tokens).
    cache_read_input_tokens: u32 = 0,
    is_input: bool = false,
    is_output: bool = false,
    diffview_before: ?[]const u8 = null,
    diffview_after: ?[]const u8 = null,
    image_urls: ?[][]const u8 = null,
    video_urls: ?[][]const u8 = null,
    /// The chat's file attachments, as the JSON payload the model path
    /// reads (name, mime, bytes, and the text or the base64).
    file_attachments: ?[]const u8 = null,
    /// The same attachments as metadata only (name, mime, bytes) — what the
    /// read path emits, so the bytes never cross the wire twice.
    file_attachments_meta: ?[]const u8 = null,
    tool_call_id: ?[]const u8 = null,
    tool_calls_json: []const u8,
    is_feed_to_llm: bool = true,

    pub fn deinit(self: *LLMHistory, allocator: std.mem.Allocator) void {
        allocator.free(self.id);
        allocator.free(self.session_id);
        allocator.free(self.model);
        allocator.free(self.created_at);
        allocator.free(self.response_content);
        allocator.free(self.finish_reason);
        allocator.free(self.role);
        allocator.free(self.tool_calls_json);
        if (self.reasoning_content) |rc| allocator.free(rc);
        if (self.reasoning_id) |rid| allocator.free(rid);
        if (self.reasoning_encrypted_content) |rec| allocator.free(rec);
        allocator.free(self.agent);
        allocator.free(self.session_name);
        allocator.free(self.tool_name);
        if (self.parent_session_id) |psi| allocator.free(psi);
        if (self.diffview_before) |dw| allocator.free(dw);
        if (self.diffview_after) |da| allocator.free(da);
        if (self.image_urls) |iums| {
            for (iums) |img| allocator.free(img);
            allocator.free(iums);
        }
        if (self.video_urls) |vums| {
            for (vums) |vid| allocator.free(vid);
            allocator.free(vums);
        }
        if (self.file_attachments) |fa| allocator.free(fa);
        if (self.file_attachments_meta) |fam| allocator.free(fam);
        if (self.tool_call_id) |tci| allocator.free(tci);
        if (self.parent_id) |pi| allocator.free(pi);
    }
};

// ─── Tests ──────────────────────────────────────────────────────────────────

test "LLMHistory default fields are safe to read without explicit init" {
    const h = LLMHistory{
        .id = "id",
        .session_id = "sid",
        .model = "model",
        .created_at = "2025-01-01",
        .response_content = "",
        .finish_reason = "stop",
        .role = "assistant",
        .tool_calls_json = "",
    };
    try testing.expectEqualStrings("Agent", h.agent);
    try testing.expectEqualStrings("", h.session_name);
    try testing.expectEqualStrings("", h.tool_name);
    try testing.expectEqual(@as(u32, 0), h.loop_index);
    try testing.expectEqual(@as(f32, 0.2), h.temperature);
    try testing.expect(!h.is_thinking);
    try testing.expectEqual(@as(u32, 0), h.prompt_tokens);
    try testing.expectEqual(@as(u32, 0), h.completion_tokens);
    try testing.expectEqual(@as(u32, 0), h.total_tokens);
    try testing.expectEqual(@as(u32, 0), h.cache_creation_input_tokens);
    try testing.expectEqual(@as(u32, 0), h.cache_read_input_tokens);
    try testing.expect(!h.is_input);
    try testing.expect(!h.is_output);
    try testing.expect(h.reasoning_content == null);
    try testing.expect(h.parent_session_id == null);
    try testing.expect(h.parent_id == null);
    try testing.expect(h.diffview_before == null);
    try testing.expect(h.diffview_after == null);
    try testing.expect(h.image_urls == null);
    try testing.expect(h.tool_call_id == null);
    try testing.expect(h.is_feed_to_llm);
}

test "LLMHistory.deinit frees every owned slice on a minimal-init history" {
    // Every owned slice field is filled with a separate heap allocation so
    // the testing allocator's canary catches any leak OR double-free.
    var h = LLMHistory{
        .id = try testing.allocator.dupe(u8, "h_id"),
        .session_id = try testing.allocator.dupe(u8, "h_sid"),
        .model = try testing.allocator.dupe(u8, "h_model"),
        .created_at = try testing.allocator.dupe(u8, "2025-01-01"),
        .response_content = try testing.allocator.dupe(u8, "hi"),
        .finish_reason = try testing.allocator.dupe(u8, "stop"),
        .role = try testing.allocator.dupe(u8, "assistant"),
        .tool_calls_json = try testing.allocator.dupe(u8, "[]"),
        .agent = try testing.allocator.dupe(u8, "Agent"),
        .session_name = try testing.allocator.dupe(u8, "sn"),
        .tool_name = try testing.allocator.dupe(u8, "tn"),
        .reasoning_content = try testing.allocator.dupe(u8, "r"),
        .parent_session_id = try testing.allocator.dupe(u8, "psi"),
        .parent_id = try testing.allocator.dupe(u8, "pi"),
        .diffview_before = try testing.allocator.dupe(u8, "before"),
        .diffview_after = try testing.allocator.dupe(u8, "after"),
        .image_urls = blk: {
            const urls = try testing.allocator.alloc([]const u8, 2);
            urls[0] = try testing.allocator.dupe(u8, "url1");
            urls[1] = try testing.allocator.dupe(u8, "url2");
            break :blk urls;
        },
        .tool_call_id = try testing.allocator.dupe(u8, "tci"),
    };
    h.deinit(testing.allocator);
    // No leak, no double-free — the testing allocator would have raised a
    // panic in either case at the end of the test scope.
}

test "LLMHistory.deinit skips nullable fields when they are null" {
    // NOTE: `.agent`, `.session_name`, `.tool_name` have non-null defaults
    // ("Agent", "", "") that are string literals, not heap allocations.
    var h = LLMHistory{
        .id = try testing.allocator.dupe(u8, "x"),
        .session_id = try testing.allocator.dupe(u8, "y"),
        .model = try testing.allocator.dupe(u8, "z"),
        .created_at = try testing.allocator.dupe(u8, "t"),
        .response_content = try testing.allocator.dupe(u8, ""),
        .finish_reason = try testing.allocator.dupe(u8, ""),
        .role = try testing.allocator.dupe(u8, ""),
        .tool_calls_json = try testing.allocator.dupe(u8, ""),
        // Heap-own the three non-null string fields so deinit doesn't
        // try to free string-literal defaults.
        .agent = try testing.allocator.dupe(u8, "Agent"),
        .session_name = try testing.allocator.dupe(u8, ""),
        .tool_name = try testing.allocator.dupe(u8, ""),
        // All optional fields left at their default `null` / `false` / `0`.
    };
    h.deinit(testing.allocator);
}

test "LLMHistory.deinit handles empty image_urls array (no element frees)" {
    // Heap-own `.agent`, `.session_name`, `.tool_name` — see the note on
    // the "skips nullable fields" test above for why this is required.
    var h = LLMHistory{
        .id = try testing.allocator.dupe(u8, "i"),
        .session_id = try testing.allocator.dupe(u8, "s"),
        .model = try testing.allocator.dupe(u8, "m"),
        .created_at = try testing.allocator.dupe(u8, "c"),
        .response_content = try testing.allocator.dupe(u8, "rc"),
        .finish_reason = try testing.allocator.dupe(u8, "fr"),
        .role = try testing.allocator.dupe(u8, "r"),
        .tool_calls_json = try testing.allocator.dupe(u8, "[]"),
        .agent = try testing.allocator.dupe(u8, "Agent"),
        .session_name = try testing.allocator.dupe(u8, ""),
        .tool_name = try testing.allocator.dupe(u8, ""),
        // Empty image_urls slice — the deinit loop iterates 0 times.
        .image_urls = &.{},
    };
    h.deinit(testing.allocator);
}
