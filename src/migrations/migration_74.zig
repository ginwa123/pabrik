const std = @import("std");
const common = @import("common.zig");

const Backend = common.Backend;
const addColumnIfMissing = common.addColumnIfMissing;
const dropColumnIfExists = common.dropColumnIfExists;
const renameColumnIfExists = common.renameColumnIfExists;
const helpers = @import("helpers");

/// Migration 074 — Add `cache_creation_input_tokens` + `cache_read_input_tokens` columns to `llm_history` so the Anthropic profile's cache breakdown survives from the SSE parser to the persistent row. OpenAI rows always carry 0. Idempotent via `addColumnIfMissing` (probes `pragma_table_info` first; matches the Migration 013/020 pattern). Task: task_1786640688092.
pub const Migration074AddLlmHistoryCacheTokenColumns = struct {
    pub const version: u32 = 74;
    pub const name = "add_llm_history_cache_token_columns";

    pub fn up(db: *Backend, allocator: std.mem.Allocator) anyerror!void {
        // Anthropic cache WRITE breakdown (billed at ~1.25x input rate). Default 0 for legacy rows + non-Anthropic profiles.
        try addColumnIfMissing(.{ .db = db }, allocator, "llm_history", "cache_creation_input_tokens", "cache_creation_input_tokens INTEGER DEFAULT 0");

        // Anthropic cache READ breakdown (billed at ~0.1x input rate, but still tokens the model processed -- folded into `prompt_tokens` + `total_tokens` by Agent.parse_anthropic_stream_chunk). Default 0 for legacy rows + non-Anthropic profiles.
        try addColumnIfMissing(.{ .db = db }, allocator, "llm_history", "cache_read_input_tokens", "cache_read_input_tokens INTEGER DEFAULT 0");
    }
};
