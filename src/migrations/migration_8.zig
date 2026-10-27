const std = @import("std");
const common = @import("common.zig");

const Backend = common.Backend;
const addColumnIfMissing = common.addColumnIfMissing;
const dropColumnIfExists = common.dropColumnIfExists;
const renameColumnIfExists = common.renameColumnIfExists;
const helpers = @import("helpers");
const dialect = common.dialect;

pub const Migration008AddSessionSkills = struct {
    pub const version: u32 = 8;
    pub const name = "add_session_skills";

    pub fn up(db: *Backend, allocator: std.mem.Allocator) anyerror!void {
        const ddl = try std.fmt.allocPrint(
            allocator,
            "CREATE TABLE IF NOT EXISTS session_skills (session_id TEXT NOT NULL, skill_name TEXT NOT NULL, content TEXT NOT NULL, loaded_at {s}, PRIMARY KEY (session_id, skill_name))",
            .{dialect.epoch_default},
        );
        defer allocator.free(ddl);
        try db.exec(allocator, ddl, &[_][]const u8{});
        try db.exec(allocator, "CREATE INDEX IF NOT EXISTS idx_session_skills_session ON session_skills(session_id)", &[_][]const u8{});
    }
};
