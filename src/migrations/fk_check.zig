//! `PRAGMA foreign_key_check` over a freshly migrated database: the
//! hand-written cascades are gone because the schema declares them, and that
//! trade only holds while no child row outlives its parent.

const std = @import("std");
const common = @import("common.zig");

const Backend = common.Backend;
const dialect = common.dialect;
const migration = @import("migration.zig");
const test_db = @import("pabrikcore").test_db;

/// One row per child row whose parent is missing (or whose key does not
/// match). Postgres enforces at write time and has no such pragma, so it can
/// hold no orphan and always reports zero.
pub fn violationCount(allocator: std.mem.Allocator, db: *Backend) !usize {
    if (dialect.is_postgres) return 0;

    var rows = try db.query(allocator, "PRAGMA foreign_key_check", &.{});
    defer rows.deinit();

    var count: usize = 0;
    while (try rows.next()) |row| {
        defer row.deinit(allocator);
        count += 1;
    }
    return count;
}

const SeedRow = struct {
    table: []const u8,
    sql: []const u8,
};

/// One row per parent/child pair the retired cascade code used to delete by
/// hand: workspace → secrets/settings/skills, skills → assets/metadata,
/// item → design page → element, item → column → card.
const seed_rows = [_]SeedRow{
    .{ .table = "workspaces", .sql = "INSERT INTO workspaces (id) VALUES ('ws_fk')" },
    .{ .table = "workspace_settings", .sql = "INSERT INTO workspace_settings (owner, workspace_id) VALUES ('', 'ws_fk')" },
    .{ .table = "workspace_secrets", .sql = "INSERT INTO workspace_secrets (id, workspace_id, name, value) VALUES ('sec_fk', 'ws_fk', 'TOKEN', 'v')" },
    .{ .table = "workspace_items", .sql = "INSERT INTO workspace_items (id, workspace_id, item_type) VALUES ('wi_fk', 'ws_fk', 'kanban')" },
    .{ .table = "skills", .sql = "INSERT INTO skills (id, workspace_id, name) VALUES ('skill_fk', 'ws_fk', 'pdf')" },
    .{ .table = "skill_assets", .sql = "INSERT INTO skill_assets (id, skill_id, rel_path) VALUES ('asset_fk', 'skill_fk', 'scripts/convert.py')" },
    .{ .table = "skill_metadata", .sql = "INSERT INTO skill_metadata (id, skill_id, key, value) VALUES ('meta_fk', 'skill_fk', 'origin', 'ECC')" },
    .{ .table = "kanban_columns", .sql = "INSERT INTO kanban_columns (id, workspace_item_id, name, position) VALUES ('col_fk', 'wi_fk', 'todo', 0)" },
    .{ .table = "workspace_item_tasks", .sql = "INSERT INTO workspace_item_tasks (id, name, workspace_item_id) VALUES ('task_fk', 'a task', 'wi_fk')" },
    .{ .table = "kanban", .sql = "INSERT INTO kanban (workspace_item_task_id, kanban_column_id, kanban_position) VALUES ('task_fk', 'col_fk', 0)" },
    .{ .table = "design_pages", .sql = "INSERT INTO design_pages (id, workspace_item_id, name) VALUES ('page_fk', 'wi_fk', 'Home')" },
    .{ .table = "design_page_elements", .sql = "INSERT INTO design_page_elements (id, page_id) VALUES ('elem_fk', 'page_fk')" },
};

fn seed(allocator: std.mem.Allocator, db: *Backend) !void {
    for (seed_rows) |row| {
        db.exec(allocator, row.sql, &.{}) catch {
            std.debug.print("foreign key check: cannot seed `{s}`\n", .{row.table});
            return error.SeedFailed;
        };
    }
}

fn openMigrated(allocator: std.mem.Allocator) !struct { db: Backend, threaded: std.Io.Threaded } {
    var threaded = std.Io.Threaded.init(allocator, .{});
    errdefer threaded.deinit();
    var db: Backend = .{};
    errdefer db.deinit();
    try test_db.openMemory(&db, threaded.io());

    var manager = common.MigrationManager.init(allocator, &db);
    defer manager.deinit();
    try migration.registerAllMigrations(&manager);
    try manager.runMigrations();

    return .{ .db = db, .threaded = threaded };
}

fn countRows(allocator: std.mem.Allocator, db: *Backend, sql: []const u8) !usize {
    var q = try db.query(allocator, sql, &.{});
    defer q.deinit();
    const row = (try q.next()) orelse return error.RowMissing;
    defer row.deinit(allocator);
    return std.fmt.parseInt(usize, row.values[0], 10) catch error.NotAnInteger;
}

test "foreign key check: a freshly migrated database seeded end to end has no orphan row" {
    if (dialect.is_postgres) return error.SkipZigTest;
    const alloc = std.testing.allocator;
    var ctx = try openMigrated(alloc);
    defer ctx.threaded.deinit();
    defer ctx.db.deinit();

    try seed(alloc, &ctx.db);

    try std.testing.expectEqual(@as(usize, 0), try violationCount(alloc, &ctx.db));
}

test "foreign key check: the parent DELETEs the code issues alone clear every child on the migrated schema" {
    if (dialect.is_postgres) return error.SkipZigTest;
    const alloc = std.testing.allocator;
    var ctx = try openMigrated(alloc);
    defer ctx.threaded.deinit();
    defer ctx.db.deinit();

    try seed(alloc, &ctx.db);

    try ctx.db.exec(alloc, "DELETE FROM kanban_columns WHERE id = 'col_fk'", &.{});
    try ctx.db.exec(alloc, "DELETE FROM design_pages WHERE id = 'page_fk'", &.{});
    try ctx.db.exec(alloc, "DELETE FROM skills WHERE id = 'skill_fk'", &.{});
    try ctx.db.exec(alloc, "DELETE FROM workspaces WHERE id = 'ws_fk'", &.{});

    try std.testing.expectEqual(@as(usize, 0), try violationCount(alloc, &ctx.db));
    try std.testing.expectEqual(@as(usize, 0), try countRows(alloc, &ctx.db, "SELECT COUNT(*) FROM kanban"));
    try std.testing.expectEqual(@as(usize, 0), try countRows(alloc, &ctx.db, "SELECT COUNT(*) FROM design_page_elements"));
    try std.testing.expectEqual(@as(usize, 0), try countRows(alloc, &ctx.db, "SELECT COUNT(*) FROM skill_assets"));
    try std.testing.expectEqual(@as(usize, 0), try countRows(alloc, &ctx.db, "SELECT COUNT(*) FROM skill_metadata"));
    try std.testing.expectEqual(@as(usize, 0), try countRows(alloc, &ctx.db, "SELECT COUNT(*) FROM workspace_secrets"));
    try std.testing.expectEqual(@as(usize, 0), try countRows(alloc, &ctx.db, "SELECT COUNT(*) FROM workspace_settings"));
}

test "foreign key check: reports a child row whose parent was never written" {
    if (dialect.is_postgres) return error.SkipZigTest;
    const alloc = std.testing.allocator;
    var threaded = std.Io.Threaded.init(alloc, .{});
    defer threaded.deinit();
    var db: Backend = .{};
    defer db.deinit();
    try test_db.openMemory(&db, threaded.io());

    try db.exec(alloc,
        \\CREATE TABLE fk_parent (id TEXT PRIMARY KEY)
    , &.{});
    try db.exec(alloc,
        \\CREATE TABLE fk_child (
        \\    id TEXT PRIMARY KEY,
        \\    parent_id TEXT NOT NULL,
        \\    FOREIGN KEY (parent_id) REFERENCES fk_parent(id) ON DELETE CASCADE)
    , &.{});
    try db.exec(alloc, "INSERT INTO fk_child (id, parent_id) VALUES ('c_orphan', 'p_missing')", &.{});

    try std.testing.expectEqual(@as(usize, 1), try violationCount(alloc, &db));

    try db.exec(alloc, "INSERT INTO fk_parent (id) VALUES ('p_missing')", &.{});

    try std.testing.expectEqual(@as(usize, 0), try violationCount(alloc, &db));
}
