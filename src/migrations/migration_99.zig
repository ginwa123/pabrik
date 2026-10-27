const std = @import("std");
const common = @import("common.zig");

const Backend = common.Backend;
const addColumnIfMissing = common.addColumnIfMissing;
const dropColumnIfExists = common.dropColumnIfExists;
const renameColumnIfExists = common.renameColumnIfExists;
const helpers = @import("helpers");
const dialect = common.dialect;

pub const Migration099RenameListSkillsTool = struct {
    pub const version: u32 = 99;
    pub const name = "rename_list_skills_tool";

    /// True when `name` is a table in this database.
    fn tableExists(allocator: std.mem.Allocator, db: *Backend, table: []const u8) !bool {
        return dialect.tableExists(.{ .db = db }, allocator, table);
    }

    fn renameIn(allocator: std.mem.Allocator, db: *Backend, table: []const u8, owner_col: []const u8) !void {
        if (!try tableExists(allocator, db, table)) return;

        // A plain `UPDATE ...
        const sql = try std.fmt.allocPrint(
            allocator,
            \\{s} INTO {s} (id, {s}, tool_name, enabled, created_at)
            \\SELECT id || '_m099', {s}, 'search_skills', enabled, created_at
            \\FROM {s} WHERE tool_name = 'list_skills'{s}
        , .{ dialect.insert_ignore_prefix, table, owner_col, owner_col, table, dialect.conflict_ignore });
        defer allocator.free(sql);
        try db.exec(allocator, sql, &[_][]const u8{});

        const del = try std.fmt.allocPrint(
            allocator,
            "DELETE FROM {s} WHERE tool_name = 'list_skills'",
            .{table},
        );
        defer allocator.free(del);
        try db.exec(allocator, del, &[_][]const u8{});
    }

    pub fn up(db: *Backend, allocator: std.mem.Allocator) anyerror!void {
        // Three allowlist tables, one per item type — agents and routines are
        // separate tables even though both are read the same way.
        try renameIn(allocator, db, "agent_tools", "agent_id");
        try renameIn(allocator, db, "agent_kanban_tools", "kanban_id");
        try renameIn(allocator, db, "agent_routine_tools", "routine_id");

        if (!try tableExists(allocator, db, "users")) return;

        // Quoted JSON token only — `"list_skills"` → `"search_skills"`.
        // `LIKE '%"list_skills"%'` keeps the WHERE off rows that do not
        // mention the tool at all.
        try db.exec(allocator,
            \\UPDATE users SET config_json = REPLACE(config_json, '"list_skills"', '"search_skills"')
            \\WHERE config_json LIKE '%"list_skills"%'
        , &[_][]const u8{});
    }
};
