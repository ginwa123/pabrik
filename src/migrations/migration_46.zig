const std = @import("std");
const common = @import("common.zig");

const Backend = common.Backend;
const addColumnIfMissing = common.addColumnIfMissing;
const dropColumnIfExists = common.dropColumnIfExists;
const renameColumnIfExists = common.renameColumnIfExists;
const helpers = @import("helpers");

pub const Migration046AddGitWorktreeCwdToSessions = struct {
    pub const version: u32 = 46;
    pub const name = "add_git_worktree_cwd_to_sessions";

    pub fn up(db: *Backend, allocator: std.mem.Allocator) anyerror!void {
        // Nullable: NULL means "no worktree bound".
        try db.exec(allocator,
            "ALTER TABLE sessions ADD COLUMN git_worktree_cwd TEXT",
            &[_][]const u8{});
    }
};
