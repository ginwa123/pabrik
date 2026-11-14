//! `pabrik headless workspace-items …` — the project-row backend with no
//! server and no port. `set-icon` writes through `updateWorkspaceItemIcon` and
//! re-reads through `getWorkspaceItem`, so stdout is the persisted state.

const std = @import("std");
const pabrikcore = @import("pabrikcore");

const args = @import("args.zig");
const boot_mod = @import("boot.zig");

const workspace_items = pabrikcore.workspace_items;
const database = pabrikcore.database;
const workspace_items_delete = pabrikcore.http_handlers.workspace_items_delete;

/// One project row, as the CLI prints it. Deliberately a subset of the HTTP
/// wire shape: a caller scripting against this needs the identity and the
/// glyph, not the timestamps.
const ItemDto = struct {
    id: []const u8,
    workspace_id: []const u8,
    item_type: []const u8,
    name: ?[]const u8,
    icon: ?[]const u8,
};

const ListDto = struct {
    workspace_id: []const u8,
    items: []const ItemDto,
    count: usize,
};

fn itemDto(row: workspace_items.WorkspaceItemInfo) ItemDto {
    return .{
        .id = row.id,
        .workspace_id = row.workspace_id,
        .item_type = row.item_type,
        .name = row.name,
        .icon = row.icon,
    };
}

/// Run one op and return the JSON object to print. Caller frees the slice.
pub fn run(
    allocator: std.mem.Allocator,
    backend: *boot_mod.Backend,
    a: args.WorkspaceItemsArgs,
) ![]u8 {
    return runWithDb(allocator, backend.io, backend.ctx.db, a);
}

/// The op table, over a plain `*Db` so a test can drive it against an
/// in-memory database without booting a backend.
pub fn runWithDb(
    allocator: std.mem.Allocator,
    io: std.Io,
    db: *database.Db,
    a: args.WorkspaceItemsArgs,
) ![]u8 {
    switch (a.op) {
        .list => {
            const rows = try workspace_items.listWorkspaceItems(allocator, db, a.workspace_id);
            defer {
                for (rows) |row| row.deinit(allocator);
                allocator.free(rows);
            }

            const dtos = try allocator.alloc(ItemDto, rows.len);
            defer allocator.free(dtos);
            for (rows, 0..) |row, i| dtos[i] = itemDto(row);

            return std.json.Stringify.valueAlloc(allocator, ListDto{
                .workspace_id = a.workspace_id,
                .items = dtos,
                .count = rows.len,
            }, .{});
        },

        .set_icon => {
            // `--icon ""` is the "Reset to default" write: an empty value
            // clears the override rather than storing an empty name.
            const icon: ?[]const u8 = if (a.icon.len == 0) null else a.icon;
            try workspace_items.updateWorkspaceItemIcon(allocator, db, a.item_id, icon);

            // Read back through the getter, not the argument: this is what
            // makes the printed JSON evidence of persistence.
            const row = (try workspace_items.getWorkspaceItem(allocator, db, a.item_id)) orelse
                return error.WorkspaceItemNotFound;
            defer row.deinit(allocator);

            return std.json.Stringify.valueAlloc(allocator, itemDto(row), .{});
        },

        .delete => {
            const deleted = try workspace_items_delete.useCase(allocator, io, db, a.item_id);
            return std.json.Stringify.valueAlloc(allocator, .{ .id = deleted.id, .deleted = true }, .{});
        },
    }
}

// ─── Tests ──────────────────────────────────────────────────────────────

const testing = std.testing;
const test_db = pabrikcore.test_db;
const migration = @import("../migrations/migration.zig");

const TestCtx = struct {
    db: database.Db,
    threaded: std.Io.Threaded,
};

fn setupDb() !TestCtx {
    const alloc = testing.allocator;
    var threaded = std.Io.Threaded.init(alloc, .{});
    errdefer threaded.deinit();
    var db: database.Db = .{};
    errdefer db.deinit();
    try test_db.openMemory(&db, threaded.io());
    try db.exec(alloc,
        \\CREATE TABLE workspace_items (
        \\    id TEXT PRIMARY KEY,
        \\    workspace_id TEXT NOT NULL,
        \\    item_type TEXT NOT NULL,
        \\    name TEXT,
        \\    path TEXT,
        \\    position INTEGER NOT NULL DEFAULT 0,
        \\    created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
        \\    updated_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
        \\    is_default INTEGER NOT NULL DEFAULT 0
        \\)
    , &[_][]const u8{});
    try migration.Migration147AddWorkspaceItemIcon.up(&db, alloc);
    return .{ .db = db, .threaded = threaded };
}

fn seedItem(ctx: *TestCtx, id: []const u8, name: []const u8) !void {
    try ctx.db.exec(testing.allocator,
        \\INSERT INTO workspace_items (id, workspace_id, item_type, name)
        \\VALUES (?, 'ws_1', 'kanban', ?)
    , &[_][]const u8{ id, name });
}

fn parseJson(alloc: std.mem.Allocator, json: []const u8) !std.json.Parsed(std.json.Value) {
    return std.json.parseFromSlice(std.json.Value, alloc, json, .{});
}

test "headless workspace-items: set-icon persists the glyph and list reads it back" {
    const alloc = testing.allocator;
    var ctx = try setupDb();
    defer ctx.threaded.deinit();
    defer ctx.db.deinit();

    try seedItem(&ctx, "item_a", "Board");

    const set_json = try runWithDb(alloc, testing.io, &ctx.db, .{
        .op = .set_icon,
        .item_id = "item_a",
        .icon = "tree",
    });
    defer alloc.free(set_json);

    {
        const parsed = try parseJson(alloc, set_json);
        defer parsed.deinit();
        try testing.expectEqualStrings("tree", parsed.value.object.get("icon").?.string);
    }

    // A SECOND call, through the list path, is the read-back that proves the
    // write landed in the table rather than in the response builder.
    const list_json = try runWithDb(alloc, testing.io, &ctx.db, .{ .op = .list, .workspace_id = "ws_1" });
    defer alloc.free(list_json);

    const parsed = try parseJson(alloc, list_json);
    defer parsed.deinit();
    const items = parsed.value.object.get("items").?.array.items;
    try testing.expectEqual(@as(usize, 1), items.len);
    try testing.expectEqualStrings("tree", items[0].object.get("icon").?.string);
}

test "headless workspace-items: an empty --icon clears the override back to null" {
    const alloc = testing.allocator;
    var ctx = try setupDb();
    defer ctx.threaded.deinit();
    defer ctx.db.deinit();

    try seedItem(&ctx, "item_a", "Board");

    const set_json = try runWithDb(alloc, testing.io, &ctx.db, .{ .op = .set_icon, .item_id = "item_a", .icon = "box" });
    defer alloc.free(set_json);

    const reset_json = try runWithDb(alloc, testing.io, &ctx.db, .{ .op = .set_icon, .item_id = "item_a", .icon = "" });
    defer alloc.free(reset_json);

    const parsed = try parseJson(alloc, reset_json);
    defer parsed.deinit();
    // JSON null, not "" — the UI distinguishes "no override" from a name.
    try testing.expect(parsed.value.object.get("icon").? == .null);
}

test "headless workspace-items: a project with no override lists icon as null" {
    const alloc = testing.allocator;
    var ctx = try setupDb();
    defer ctx.threaded.deinit();
    defer ctx.db.deinit();

    try seedItem(&ctx, "item_a", "Board");

    const list_json = try runWithDb(alloc, testing.io, &ctx.db, .{ .op = .list, .workspace_id = "ws_1" });
    defer alloc.free(list_json);

    const parsed = try parseJson(alloc, list_json);
    defer parsed.deinit();
    const item = parsed.value.object.get("items").?.array.items[0];
    try testing.expect(item.object.get("icon").? == .null);
}

test "headless workspace-items: set-icon on a missing project is an error, not a silent success" {
    const alloc = testing.allocator;
    var ctx = try setupDb();
    defer ctx.threaded.deinit();
    defer ctx.db.deinit();

    try testing.expectError(
        error.WorkspaceItemNotFound,
        runWithDb(alloc, testing.io, &ctx.db, .{ .op = .set_icon, .item_id = "item_missing", .icon = "tree" }),
    );
}

fn seedDeletableItem(ctx: *TestCtx) !void {
    const alloc = testing.allocator;
    try seedItem(ctx, "item_a", "Board");
    try ctx.db.exec(alloc, "CREATE TABLE workspace_item_tasks (id TEXT PRIMARY KEY, name TEXT NOT NULL, workspace_item_id TEXT NOT NULL)", &.{});
    try ctx.db.exec(alloc, "CREATE TABLE kanban_columns (id TEXT PRIMARY KEY, workspace_item_id TEXT NOT NULL, name TEXT NOT NULL, position INTEGER NOT NULL)", &.{});
    try ctx.db.exec(alloc, "CREATE TABLE kanban (workspace_item_task_id TEXT PRIMARY KEY, kanban_column_id TEXT NOT NULL, kanban_position INTEGER NOT NULL DEFAULT 0)", &.{});
    try ctx.db.exec(alloc, "CREATE TABLE kanban_task_dependencies (task_id TEXT NOT NULL, depends_on_task_id TEXT NOT NULL, PRIMARY KEY (task_id, depends_on_task_id))", &.{});
    try ctx.db.exec(alloc, "INSERT INTO kanban_columns (id, workspace_item_id, name, position) VALUES ('col_a', 'item_a', 'todo', 0)", &.{});
    try ctx.db.exec(alloc, "INSERT INTO workspace_item_tasks (id, name, workspace_item_id) VALUES ('task_a', 'card', 'item_a')", &.{});
    try ctx.db.exec(alloc, "INSERT INTO kanban (workspace_item_task_id, kanban_column_id, kanban_position) VALUES ('task_a', 'col_a', 0)", &.{});
}

test "headless workspace-items: delete removes the project and prints what it deleted" {
    const alloc = testing.allocator;
    var ctx = try setupDb();
    defer ctx.threaded.deinit();
    defer ctx.db.deinit();

    try seedDeletableItem(&ctx);

    const json = try runWithDb(alloc, testing.io, &ctx.db, .{ .op = .delete, .item_id = "item_a" });
    defer alloc.free(json);

    {
        const parsed = try parseJson(alloc, json);
        defer parsed.deinit();
        try testing.expectEqualStrings("item_a", parsed.value.object.get("id").?.string);
        try testing.expectEqual(true, parsed.value.object.get("deleted").?.bool);
    }

    const list_json = try runWithDb(alloc, testing.io, &ctx.db, .{ .op = .list, .workspace_id = "ws_1" });
    defer alloc.free(list_json);

    const parsed = try parseJson(alloc, list_json);
    defer parsed.deinit();
    try testing.expectEqual(@as(usize, 0), parsed.value.object.get("items").?.array.items.len);
}

test "headless workspace-items: delete on a missing project reports it, and deletes nothing" {
    const alloc = testing.allocator;
    var ctx = try setupDb();
    defer ctx.threaded.deinit();
    defer ctx.db.deinit();

    try seedDeletableItem(&ctx);
    try seedItem(&ctx, "item_b", "Keeper");

    try testing.expectError(
        error.WorkspaceItemNotFound,
        runWithDb(alloc, testing.io, &ctx.db, .{ .op = .delete, .item_id = "item_missing" }),
    );

    const list_json = try runWithDb(alloc, testing.io, &ctx.db, .{ .op = .list, .workspace_id = "ws_1" });
    defer alloc.free(list_json);

    const parsed = try parseJson(alloc, list_json);
    defer parsed.deinit();
    try testing.expectEqual(@as(usize, 2), parsed.value.object.get("items").?.array.items.len);
}
