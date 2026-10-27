const std = @import("std");
const common = @import("common.zig");

const Backend = common.Backend;
const addColumnIfMissing = common.addColumnIfMissing;
const dropColumnIfExists = common.dropColumnIfExists;
const renameColumnIfExists = common.renameColumnIfExists;
const helpers = @import("helpers");

pub const Migration020AddWorkerExtraFields = struct {
    pub const version: u32 = 20;
    pub const name = "add_worker_extra_fields";

    pub fn up(db: *Backend, allocator: std.mem.Allocator) anyerror!void {
        // These columns are already part of migration 019's CREATE TABLE (the
        // canonical `worker` schema), so fresh-DB users would crash with
        // "duplicate column name" if we ran the ADD COLUMN unconditionally.
        try addColumnIfMissing(.{ .db = db }, allocator, "worker", "working_directory", "working_directory TEXT");
        try addColumnIfMissing(.{ .db = db }, allocator, "worker", "last_activity", "last_activity INTEGER DEFAULT (strftime('%s', 'now'))");
        try addColumnIfMissing(.{ .db = db }, allocator, "worker", "last_activity_description", "last_activity_description TEXT");
    }
};
