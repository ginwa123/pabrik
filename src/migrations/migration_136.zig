const std = @import("std");
const common = @import("common.zig");

const Backend = common.Backend;
const dialect = common.dialect;

/// Migration 136 - the foreign keys postgres never declared: its `CREATE TABLE`
/// carries a no-op check instead (`dialect.foreignKey`), because a child can be
/// created before its parent; migration 129 removed the rows that would fail.
pub const Migration136EnforceForeignKeys = struct {
    pub const version: u32 = 136;
    pub const name = "enforce_foreign_keys";

    const ForeignKey = struct {
        table: []const u8,
        column: []const u8,
        parent: []const u8,
    };

    const foreign_keys = [_]ForeignKey{
        .{ .table = "agent_configs", .column = "workspace_item_id", .parent = "workspace_items" },
        .{ .table = "agent_config_knowledge", .column = "config_id", .parent = "agent_configs" },
        .{ .table = "agent_config_system_prompt", .column = "config_id", .parent = "agent_configs" },
        .{ .table = "agent_config_tools", .column = "config_id", .parent = "agent_configs" },
        .{ .table = "kanban_columns", .column = "workspace_item_id", .parent = "workspace_items" },
        .{ .table = "workspace_routines", .column = "workspace_item_id", .parent = "workspace_items" },
        .{ .table = "design_pages", .column = "workspace_item_id", .parent = "workspace_items" },
        .{ .table = "design_page_elements", .column = "page_id", .parent = "design_pages" },
        .{ .table = "skills", .column = "workspace_id", .parent = "workspaces" },
        .{ .table = "skill_assets", .column = "skill_id", .parent = "skills" },
        .{ .table = "skill_metadata", .column = "skill_id", .parent = "skills" },
        .{ .table = "documents", .column = "workspace_id", .parent = "workspaces" },
        .{ .table = "workspace_secrets", .column = "workspace_id", .parent = "workspaces" },
        .{ .table = "workspace_settings", .column = "workspace_id", .parent = "workspaces" },
        .{ .table = "auth_sessions", .column = "user_id", .parent = "users" },
    };

    pub fn up(db: *Backend, allocator: std.mem.Allocator) anyerror!void {
        if (!dialect.is_postgres) return;

        for (foreign_keys) |fk| {
            const ddl = try std.fmt.allocPrint(
                allocator,
                "ALTER TABLE {s} ADD CONSTRAINT {s}_{s}_fkey FOREIGN KEY ({s}) REFERENCES {s}(id) ON DELETE CASCADE",
                .{ fk.table, fk.table, fk.column, fk.column, fk.parent },
            );
            defer allocator.free(ddl);
            try db.exec(allocator, ddl, &[_][]const u8{});
        }
    }
};

const testing = std.testing;
const test_db = @import("pabrikcore").test_db;
const migration = @import("migration.zig");

fn setupMigrated() !struct { db: Backend, threaded: std.Io.Threaded } {
    const alloc = testing.allocator;
    var threaded = std.Io.Threaded.init(alloc, .{});
    errdefer threaded.deinit();
    var db: Backend = .{};
    errdefer db.deinit();
    try test_db.openMemory(&db, threaded.io());

    var manager = common.MigrationManager.init(alloc, &db);
    defer manager.deinit();
    try migration.registerAllMigrations(&manager);
    try manager.runMigrations();

    return .{ .db = db, .threaded = threaded };
}

test "a migrated database rejects a row whose parent does not exist" {
    const alloc = testing.allocator;
    var ctx = try setupMigrated();
    defer ctx.threaded.deinit();
    defer ctx.db.deinit();

    try testing.expectError(
        error.ExecuteFailed,
        ctx.db.exec(alloc, "INSERT INTO workspace_settings (owner, workspace_id) VALUES ('', 'ws_absent')", &[_][]const u8{}),
    );

    try ctx.db.exec(alloc, "INSERT INTO workspaces (id) VALUES ('ws_absent')", &[_][]const u8{});
    try ctx.db.exec(alloc, "INSERT INTO workspace_settings (owner, workspace_id) VALUES ('', 'ws_absent')", &[_][]const u8{});
}

test "every constraint this migration adds names a table and column the chain still has" {
    const alloc = testing.allocator;
    var ctx = try setupMigrated();
    defer ctx.threaded.deinit();
    defer ctx.db.deinit();

    for (Migration136EnforceForeignKeys.foreign_keys) |fk| {
        const child_has_column = try dialect.columnExists(.{ .db = &ctx.db }, alloc, fk.table, fk.column);
        const parent_has_id = try dialect.columnExists(.{ .db = &ctx.db }, alloc, fk.parent, "id");
        if (!child_has_column or !parent_has_id) {
            std.debug.print(
                "foreign key on {s}.{s} -> {s}.id does not survive the chain: table={} parent={}\n",
                .{ fk.table, fk.column, fk.parent, child_has_column, parent_has_id },
            );
            return error.ForeignKeyIsStale;
        }
    }
}
