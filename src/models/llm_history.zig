//! Data model for the `llm_history` entity table. One row per chat message in
//! a session.

const std = @import("std");

pub const EntityId = []u8;

id: EntityId,
session_id: []u8,
model: []u8,
response_content: ?[]u8 = null,
tool_calls_json: ?[]u8 = null,
finish_reason: ?[]u8 = null,
/// Raw JSON of the OpenAI/Anthropic usage object. The flat
/// `prompt_tokens` / `completion_tokens` / `total_tokens` columns
/// are derived from this for indexed SUM() queries.
usage_json: ?[]u8 = null,
created_at: []u8,
/// One of `"user"` | `"assistant"` | `"tool"` | `"system"` |
/// `"unknown"`. The DB column has no CHECK constraint.
role: []u8,
reasoning_content: ?[]u8 = null,
is_feed_to_llm: bool = true,
/// Default `"Agent"`. Sub-agent names like `"code-reviewer"` etc.
/// are stored verbatim.
agent: []u8 = &.{},
loop_index: i64 = 0,
temperature: f64 = 0.2,
is_thinking: bool = false,
parent_session_id: ?[]u8 = null,
parent_id: ?[]u8 = null,
prompt_tokens: i64 = 0,
completion_tokens: i64 = 0,
total_tokens: i64 = 0,
is_input: bool = false,
is_output: bool = false,
tool_name: ?[]u8 = null,
diffview_before: ?[]u8 = null,
diffview_after: ?[]u8 = null,
image_url: ?[]u8 = null,
tool_call_id: ?[]u8 = null,
/// ISO-8601 mirror of `created_at`. Populated by Migration 071 to
/// avoid client-side `new Date(...)` parsing of the SQLite
/// DATETIME string.
created_iso: ?[]u8 = null,
/// Migration 071 — `true` while the streaming response for this
/// row is still in flight.
is_loading: bool = false,
/// Migration 071 — Anthropic cache-write tokens. Charge at ~1.25×
/// input rate.
cache_creation_input_tokens: i64 = 0,
/// Migration 071 — Anthropic cache-read tokens. Charge at ~0.1×
/// input rate.
cache_read_input_tokens: i64 = 0,

const Self = @This();

pub const InitArgs = struct {
    id: []const u8,
    session_id: []const u8,
    model: []const u8,
    response_content: ?[]const u8 = null,
    tool_calls_json: ?[]const u8 = null,
    finish_reason: ?[]const u8 = null,
    usage_json: ?[]const u8 = null,
    created_at: []const u8 = "",
    role: []const u8 = "assistant",
    reasoning_content: ?[]const u8 = null,
    is_feed_to_llm: bool = true,
    agent: []const u8 = "Agent",
    loop_index: i64 = 0,
    temperature: f64 = 0.2,
    is_thinking: bool = false,
    parent_session_id: ?[]const u8 = null,
    parent_id: ?[]const u8 = null,
    prompt_tokens: i64 = 0,
    completion_tokens: i64 = 0,
    total_tokens: i64 = 0,
    is_input: bool = false,
    is_output: bool = false,
    tool_name: ?[]const u8 = null,
    diffview_before: ?[]const u8 = null,
    diffview_after: ?[]const u8 = null,
    image_url: ?[]const u8 = null,
    tool_call_id: ?[]const u8 = null,
    created_iso: ?[]const u8 = null,
    is_loading: bool = false,
    cache_creation_input_tokens: i64 = 0,
    cache_read_input_tokens: i64 = 0,
};

pub fn init(allocator: std.mem.Allocator, args: InitArgs) !Self {
    return .{
        .id = try allocator.dupe(u8, args.id),
        .session_id = try allocator.dupe(u8, args.session_id),
        .model = try allocator.dupe(u8, args.model),
        .response_content = if (args.response_content) |rc|
            try allocator.dupe(u8, rc)
        else
            null,
        .tool_calls_json = if (args.tool_calls_json) |tcj|
            try allocator.dupe(u8, tcj)
        else
            null,
        .finish_reason = if (args.finish_reason) |fr|
            try allocator.dupe(u8, fr)
        else
            null,
        .usage_json = if (args.usage_json) |uj| try allocator.dupe(u8, uj) else null,
        .created_at = try allocator.dupe(u8, args.created_at),
        .role = try allocator.dupe(u8, args.role),
        .reasoning_content = if (args.reasoning_content) |rc|
            try allocator.dupe(u8, rc)
        else
            null,
        .is_feed_to_llm = args.is_feed_to_llm,
        .agent = try allocator.dupe(u8, args.agent),
        .loop_index = args.loop_index,
        .temperature = args.temperature,
        .is_thinking = args.is_thinking,
        .parent_session_id = if (args.parent_session_id) |psi|
            try allocator.dupe(u8, psi)
        else
            null,
        .parent_id = if (args.parent_id) |pi| try allocator.dupe(u8, pi) else null,
        .prompt_tokens = args.prompt_tokens,
        .completion_tokens = args.completion_tokens,
        .total_tokens = args.total_tokens,
        .is_input = args.is_input,
        .is_output = args.is_output,
        .tool_name = if (args.tool_name) |tn| try allocator.dupe(u8, tn) else null,
        .diffview_before = if (args.diffview_before) |dv|
            try allocator.dupe(u8, dv)
        else
            null,
        .diffview_after = if (args.diffview_after) |da|
            try allocator.dupe(u8, da)
        else
            null,
        .image_url = if (args.image_url) |iu| try allocator.dupe(u8, iu) else null,
        .tool_call_id = if (args.tool_call_id) |tci|
            try allocator.dupe(u8, tci)
        else
            null,
        .created_iso = if (args.created_iso) |ci| try allocator.dupe(u8, ci) else null,
        .is_loading = args.is_loading,
        .cache_creation_input_tokens = args.cache_creation_input_tokens,
        .cache_read_input_tokens = args.cache_read_input_tokens,
    };
}

pub fn deinit(self: *Self, allocator: std.mem.Allocator) void {
    allocator.free(self.id);
    allocator.free(self.session_id);
    allocator.free(self.model);
    if (self.response_content) |rc| allocator.free(rc);
    if (self.tool_calls_json) |tcj| allocator.free(tcj);
    if (self.finish_reason) |fr| allocator.free(fr);
    if (self.usage_json) |uj| allocator.free(uj);
    allocator.free(self.created_at);
    allocator.free(self.role);
    if (self.reasoning_content) |rc| allocator.free(rc);
    if (self.agent.len > 0) allocator.free(self.agent);
    if (self.parent_session_id) |psi| allocator.free(psi);
    if (self.parent_id) |pi| allocator.free(pi);
    if (self.tool_name) |tn| allocator.free(tn);
    if (self.diffview_before) |dv| allocator.free(dv);
    if (self.diffview_after) |da| allocator.free(da);
    if (self.image_url) |iu| allocator.free(iu);
    if (self.tool_call_id) |tci| allocator.free(tci);
    if (self.created_iso) |ci| allocator.free(ci);
}

pub fn clone(self: *const Self, allocator: std.mem.Allocator) !Self {
    return .init(allocator, .{
        .id = self.id,
        .session_id = self.session_id,
        .model = self.model,
        .response_content = if (self.response_content) |rc| rc else null,
        .tool_calls_json = if (self.tool_calls_json) |tcj| tcj else null,
        .finish_reason = if (self.finish_reason) |fr| fr else null,
        .usage_json = if (self.usage_json) |uj| uj else null,
        .created_at = self.created_at,
        .role = self.role,
        .reasoning_content = if (self.reasoning_content) |rc| rc else null,
        .is_feed_to_llm = self.is_feed_to_llm,
        .agent = self.agent,
        .loop_index = self.loop_index,
        .temperature = self.temperature,
        .is_thinking = self.is_thinking,
        .parent_session_id = if (self.parent_session_id) |psi| psi else null,
        .parent_id = if (self.parent_id) |pi| pi else null,
        .prompt_tokens = self.prompt_tokens,
        .completion_tokens = self.completion_tokens,
        .total_tokens = self.total_tokens,
        .is_input = self.is_input,
        .is_output = self.is_output,
        .tool_name = if (self.tool_name) |tn| tn else null,
        .diffview_before = if (self.diffview_before) |dv| dv else null,
        .diffview_after = if (self.diffview_after) |da| da else null,
        .image_url = if (self.image_url) |iu| iu else null,
        .tool_call_id = if (self.tool_call_id) |tci| tci else null,
        .created_iso = if (self.created_iso) |ci| ci else null,
        .is_loading = self.is_loading,
        .cache_creation_input_tokens = self.cache_creation_input_tokens,
        .cache_read_input_tokens = self.cache_read_input_tokens,
    });
}

// ===== Tests merged from models_test.zig (2026-09-29 flatten) =====

// Sanity tests for the `src/models/` entity models.

const testing = std.testing;

test "llm_history: init + deinit with cache tokens" {
    var h = try init(testing.allocator, .{
        .id = "msg_1",
        .session_id = "session_1",
        .model = "claude-sonnet-4-5",
        .role = "assistant",
        .prompt_tokens = 100,
        .completion_tokens = 50,
        .total_tokens = 150,
        .cache_creation_input_tokens = 200,
        .cache_read_input_tokens = 1000,
        .is_thinking = true,
        .temperature = 0.7,
    });
    defer deinit(&h, testing.allocator);

    try testing.expectEqualStrings("claude-sonnet-4-5", h.model);
    try testing.expectEqualStrings("assistant", h.role);
    try testing.expect(h.is_thinking);
    try testing.expectEqual(@as(i64, 100), h.prompt_tokens);
    try testing.expectEqual(@as(i64, 200), h.cache_creation_input_tokens);
    try testing.expectEqual(@as(i64, 1000), h.cache_read_input_tokens);
    try testing.expectApproxEqAbs(@as(f64, 0.7), h.temperature, 0.0001);
}