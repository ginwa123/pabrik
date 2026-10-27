const std = @import("std");
const common = @import("common.zig");

const Backend = common.Backend;
const addColumnIfMissing = common.addColumnIfMissing;
const dropColumnIfExists = common.dropColumnIfExists;
const renameColumnIfExists = common.renameColumnIfExists;
const helpers = @import("helpers");

pub const Migration048AddChatListIndex = struct {
    pub const version: u32 = 48;
    pub const name = "add_chat_list_index";

    pub fn up(db: *Backend, allocator: std.mem.Allocator) anyerror!void {
        // Hot read path: getSessionList (llm_history.zig:115) does GROUP BY
        // session_id ORDER BY MAX(created_at) DESC LIMIT/OFFSET with no
        // WHERE.
        try db.exec(allocator,
            "CREATE INDEX IF NOT EXISTS idx_llm_history_created_session " ++
            "ON llm_history(created_at DESC, session_id)",
            &[_][]const u8{});

        // ANALYZE so the query planner sees the new index on
        // pre-existing databases.
        try db.exec(allocator, "ANALYZE", &[_][]const u8{});
    }
};
