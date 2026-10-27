const std = @import("std");
const common = @import("common.zig");

const Backend = common.Backend;
const addColumnIfMissing = common.addColumnIfMissing;
const dropColumnIfExists = common.dropColumnIfExists;
const renameColumnIfExists = common.renameColumnIfExists;
const helpers = @import("helpers");

pub const Migration024CreateWorkspaces = struct {
    pub const version: u32 = 24;
    pub const name = "create_workspaces";

    pub fn up(db: *Backend, allocator: std.mem.Allocator) anyerror!void {
        try db.exec(allocator,
            \\CREATE TABLE IF NOT EXISTS workspaces (
            \\    id TEXT PRIMARY KEY
            \\)
        , &[_][]const u8{});
    }
};
