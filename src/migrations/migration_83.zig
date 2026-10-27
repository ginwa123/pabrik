const std = @import("std");
const common = @import("common.zig");

const Backend = common.Backend;
const addColumnIfMissing = common.addColumnIfMissing;
const dropColumnIfExists = common.dropColumnIfExists;
const renameColumnIfExists = common.renameColumnIfExists;
const helpers = @import("helpers");

pub const Migration083AddReasoningIdAndEncryptedContent = struct {
    pub const version: u32 = 83;
    pub const name = "add_reasoning_id_and_encrypted_content";

    pub fn up(db: *Backend, allocator: std.mem.Allocator) anyerror!void {
        try addColumnIfMissing(
            .{ .db = db },
            allocator,
            "llm_history",
            "reasoning_id",
            "reasoning_id TEXT",
        );
        try addColumnIfMissing(
            .{ .db = db },
            allocator,
            "llm_history",
            "reasoning_encrypted_content",
            "reasoning_encrypted_content TEXT",
        );
    }
};
