const std = @import("std");
const common = @import("common.zig");

const Backend = common.Backend;
const addColumnIfMissing = common.addColumnIfMissing;
const dropColumnIfExists = common.dropColumnIfExists;
const renameColumnIfExists = common.renameColumnIfExists;
const helpers = @import("helpers");

/// Migration 063 — per-session opt-in for unattended long-running mode. ##
/// Why this migration exists Today, when `workflow.zig`'s LLM call fails 10
/// times in a row, the workflow returns `error.TooManyRetries` (see
pub const Migration063AddSessionAutoRetry = struct {
    pub const version: u32 = 63;
    pub const name = "add_session_auto_retry_until_stop";

    pub fn up(db: *Backend, allocator: std.mem.Allocator) anyerror!void {
        // Boolean opt-in flag, default off.
        try addColumnIfMissing(
            .{ .db = db },
            allocator,
            "sessions",
            "is_auto_retry_until_stop",
            "is_auto_retry_until_stop INTEGER NOT NULL DEFAULT 0",
        );
        // Cache column — nullable; stays NULL until workflow.zig writes
        // the first value (see workflow.zig's new
        // `updateSessionLastFinishReason` call site, Chunk 2 Task 2.1).
        try addColumnIfMissing(
            .{ .db = db },
            allocator,
            "sessions",
            "last_finish_reason",
            "last_finish_reason TEXT",
        );
    }
};
