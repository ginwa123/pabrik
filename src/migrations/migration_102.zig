const std = @import("std");
const common = @import("common.zig");

const Backend = common.Backend;
const addColumnIfMissing = common.addColumnIfMissing;
const dropColumnIfExists = common.dropColumnIfExists;
const renameColumnIfExists = common.renameColumnIfExists;
const helpers = @import("helpers");
const dialect = common.dialect;

pub const Migration102CreateSkills = struct {
    pub const version: u32 = 102;
    pub const name = "create_skills";

    pub fn up(db: *Backend, allocator: std.mem.Allocator) anyerror!void {
        try db.exec(allocator,
            \\CREATE TABLE IF NOT EXISTS skills (
            \\    id TEXT PRIMARY KEY,
            \\    workspace_id TEXT NOT NULL,
            \\    name TEXT NOT NULL,
            \\    description TEXT NOT NULL DEFAULT '',
            \\    content TEXT NOT NULL DEFAULT '',
            \\    created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
            \\    updated_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
            \\    is_can_auto_improve INTEGER NOT NULL DEFAULT 1,
            \\    UNIQUE (workspace_id, name),
            ++ comptime dialect.foreignKey("FOREIGN KEY (workspace_id) REFERENCES workspaces(id) ON DELETE CASCADE") ++
            \\)
        , &[_][]const u8{});

        try db.exec(allocator,
            \\CREATE TABLE IF NOT EXISTS skill_assets (
            \\    id TEXT PRIMARY KEY,
            \\    skill_id TEXT NOT NULL,
            \\    rel_path TEXT NOT NULL,
            \\    content TEXT NOT NULL DEFAULT '',
            \\    created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
            \\    UNIQUE (skill_id, rel_path),
            ++ comptime dialect.foreignKey("FOREIGN KEY (skill_id) REFERENCES skills(id) ON DELETE CASCADE") ++
            \\)
        , &[_][]const u8{});
    }
};
