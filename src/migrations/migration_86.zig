const std = @import("std");
const common = @import("common.zig");

const SqliteBackend = common.SqliteBackend;
const addColumnIfMissing = common.addColumnIfMissing;
const dropColumnIfExists = common.dropColumnIfExists;
const renameColumnIfExists = common.renameColumnIfExists;
const helpers = @import("helpers");

pub const Migration086AddSessionPrUrl = struct {
    pub const version: u32 = 86;
    pub const name = "add_session_pr_url";

    pub fn up(db: *SqliteBackend, allocator: std.mem.Allocator) anyerror!void {
        // Attached-PR binding for the ChatView right panel (set_pull_request
        // agent tool). pr_url holds the normalized PR/MR URL ("" = unset);
        // pr_provider holds the effective provider resolved at write time
        try addColumnIfMissing(.{ .db = db }, allocator, "sessions", "pr_url", "pr_url TEXT");
        try addColumnIfMissing(.{ .db = db }, allocator, "sessions", "pr_provider", "pr_provider TEXT");
    }
};
