const std = @import("std");
const common = @import("common.zig");

const Backend = common.Backend;

/// Migration 120 — grant `set_skill_metadata` beside `edit_skill` in every
/// existing allowlist: `DEFAULT_AGENT_TOOLS` only applies to a config with NO
/// rows, so a new tool name reaches an agent only via SQL.
pub const Migration120GrantSetSkillMetadata = struct {
    pub const version: u32 = 120;
    pub const name = "grant_set_skill_metadata";

    const TOOL = "set_skill_metadata";
    const SIBLING = "edit_skill";
    const TABLE = "agent_config_tools";

    fn tableExists(allocator: std.mem.Allocator, db: *Backend) !bool {
        var q = try db.query(
            allocator,
            "SELECT COUNT(*) FROM sqlite_master WHERE type='table' AND name=?",
            &[_][]const u8{TABLE},
        );
        defer q.deinit();
        const row = (try q.next()) orelse return false;
        defer row.deinit(allocator);
        return std.mem.eql(u8, row.values[0], "1");
    }

    pub fn up(db: *Backend, allocator: std.mem.Allocator) anyerror!void {
        if (!try tableExists(allocator, db)) return;

        // One statement, no cursor held across writes: the subquery is
        // evaluated first, and `INSERT OR IGNORE` makes a replay a no-op on
        // the UNIQUE (config_id, tool_name) key when it exists.
        try db.exec(allocator,
            \\INSERT OR IGNORE INTO agent_config_tools (id, config_id, tool_name, enabled, created_at)
            \\SELECT id || '_m120', config_id, 'set_skill_metadata', enabled, COALESCE(created_at, datetime('now'))
            \\FROM agent_config_tools WHERE tool_name = 'edit_skill'
        , &[_][]const u8{});
    }
};

const testing = std.testing;

const TestCtx = struct {
    db: Backend,
    threaded: std.Io.Threaded,
};

fn setupDb() !TestCtx {
    var threaded = std.Io.Threaded.init(testing.allocator, .{});
    errdefer threaded.deinit();
    var db: Backend = .{};
    errdefer db.deinit();
    try db.init(threaded.io(), ":memory:");
    try db.exec(testing.allocator,
        \\CREATE TABLE agent_config_tools (
        \\    id TEXT PRIMARY KEY,
        \\    config_id TEXT NOT NULL,
        \\    tool_name TEXT NOT NULL,
        \\    enabled INTEGER NOT NULL DEFAULT 1,
        \\    created_at DATETIME DEFAULT CURRENT_TIMESTAMP,
        \\    UNIQUE (config_id, tool_name)
        \\)
    , &[_][]const u8{});
    return .{ .db = db, .threaded = threaded };
}

fn grant(ctx: *TestCtx, id: []const u8, config_id: []const u8, tool_name: []const u8, enabled: []const u8) !void {
    try ctx.db.exec(testing.allocator,
        \\INSERT INTO agent_config_tools (id, config_id, tool_name, enabled) VALUES (?, ?, ?, ?)
    , &[_][]const u8{ id, config_id, tool_name, enabled });
}

fn countFor(ctx: *TestCtx, config_id: []const u8, tool_name: []const u8) !usize {
    const alloc = testing.allocator;
    var q = try ctx.db.query(
        alloc,
        "SELECT COUNT(*) FROM agent_config_tools WHERE config_id = ? AND tool_name = ?",
        &[_][]const u8{ config_id, tool_name },
    );
    defer q.deinit();
    const row = (try q.next()) orelse return error.NoRows;
    defer row.deinit(alloc);
    return std.fmt.parseInt(usize, row.values[0], 10) catch 0;
}

test "Migration120 grants set_skill_metadata beside edit_skill, enabled as its sibling is" {
    const alloc = testing.allocator;
    var ctx = try setupDb();
    defer ctx.db.deinit();
    defer ctx.threaded.deinit();

    try grant(&ctx, "t1", "cfg_live", "edit_skill", "1");
    try grant(&ctx, "t2", "cfg_live", "read_file", "1");
    // A config where the human unticked the edit tool entirely.
    try grant(&ctx, "t3", "cfg_trimmed", "read_file", "1");

    try Migration120GrantSetSkillMetadata.up(&ctx.db, alloc);

    // The sibling that can rewrite a skill body gains the key-level tool...
    try testing.expectEqual(@as(usize, 1), try countFor(&ctx, "cfg_live", "set_skill_metadata"));
    // ...and the config that never had `edit_skill` is left as the human set it.
    try testing.expectEqual(@as(usize, 0), try countFor(&ctx, "cfg_trimmed", "set_skill_metadata"));
    // Nothing was removed or added twice.
    try testing.expectEqual(@as(usize, 1), try countFor(&ctx, "cfg_live", "read_file"));
    try testing.expectEqual(@as(usize, 1), try countFor(&ctx, "cfg_live", "edit_skill"));
}

test "Migration120 inherits a disabled sibling instead of re-enabling the tool" {
    const alloc = testing.allocator;
    var ctx = try setupDb();
    defer ctx.db.deinit();
    defer ctx.threaded.deinit();

    try grant(&ctx, "t1", "cfg_off", "edit_skill", "0");

    try Migration120GrantSetSkillMetadata.up(&ctx.db, alloc);

    var q = try ctx.db.query(
        alloc,
        "SELECT enabled FROM agent_config_tools WHERE config_id = 'cfg_off' AND tool_name = 'set_skill_metadata'",
        &[_][]const u8{},
    );
    defer q.deinit();
    const row = (try q.next()) orelse return error.RowMissing;
    defer row.deinit(alloc);
    // `enabled` mirrors the sibling: a config that turned the edit half off
    // must not have the metadata half switched on underneath it.
    try testing.expectEqualStrings("0", row.values[0]);
}

test "Migration120 replaying adds no second row" {
    const alloc = testing.allocator;
    var ctx = try setupDb();
    defer ctx.db.deinit();
    defer ctx.threaded.deinit();

    try grant(&ctx, "t1", "cfg_live", "edit_skill", "1");

    try Migration120GrantSetSkillMetadata.up(&ctx.db, alloc);
    try Migration120GrantSetSkillMetadata.up(&ctx.db, alloc);

    try testing.expectEqual(@as(usize, 1), try countFor(&ctx, "cfg_live", "set_skill_metadata"));
}

test "Migration120 is a no-op on a database with no allowlist table" {
    const alloc = testing.allocator;
    var threaded = std.Io.Threaded.init(alloc, .{});
    defer threaded.deinit();
    var db: Backend = .{};
    defer db.deinit();
    try db.init(threaded.io(), ":memory:");

    // A fresh install before Migration 116 unified the per-item tables.
    try Migration120GrantSetSkillMetadata.up(&db, alloc);
}

test "Migration120 is registered in allMigrations" {
    for (@import("migration.zig").allMigrations) |m| {
        if (m.version == Migration120GrantSetSkillMetadata.version) return;
    }
    return error.Migration120NotRegistered;
}
