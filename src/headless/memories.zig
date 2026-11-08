const std = @import("std");
const pabrikcore = @import("pabrikcore");

const args = @import("args.zig");
const boot_mod = @import("boot.zig");

const handler = pabrikcore.http_handlers.workspace_memories;

pub fn run(
    allocator: std.mem.Allocator,
    backend: *boot_mod.Backend,
    a: args.MemoriesArgs,
) handler.WorkspaceMemoriesError![]const u8 {
    return runWithDb(allocator, backend.ctx.db, a);
}

pub fn runWithDb(
    allocator: std.mem.Allocator,
    db: *pabrikcore.database.Db,
    a: args.MemoriesArgs,
) handler.WorkspaceMemoriesError![]const u8 {
    return switch (a.op) {
        .list => handler.listUseCase(
            allocator,
            db,
            a.workspace_id,
            a.query,
            handler.parseLimit(a.limit),
            handler.parseOffset(a.offset),
        ),
        .get => handler.getUseCase(allocator, db, a.workspace_id, a.id),
        .save => blk: {
            var tags: std.ArrayList([]const u8) = .empty;
            defer tags.deinit(allocator);
            var it = std.mem.splitScalar(u8, a.tags, ',');
            while (it.next()) |raw| {
                const tag = std.mem.trim(u8, raw, &std.ascii.whitespace);
                if (tag.len == 0) continue;
                tags.append(allocator, tag) catch return error.OutOfMemory;
            }
            break :blk handler.createUseCase(allocator, db, a.workspace_id, a.content, tags.items);
        },
        .delete => handler.deleteUseCase(allocator, db, a.workspace_id, a.id),
    };
}

const testing = std.testing;
const test_db = pabrikcore.test_db;

const TestCtx = struct {
    db: pabrikcore.database.Db,
    threaded: std.Io.Threaded,
};

fn setupDb() !TestCtx {
    const alloc = testing.allocator;
    var threaded = std.Io.Threaded.init(alloc, .{});
    errdefer threaded.deinit();
    var db: pabrikcore.database.Db = .{};
    errdefer db.deinit();
    try test_db.openMemory(&db, threaded.io());

    const migration = pabrikcore.migrations_mod.migration;
    var manager = migration.MigrationManager.init(alloc, &db);
    defer manager.deinit();
    try migration.registerAllMigrations(&manager);
    try manager.runMigrations();

    return .{ .db = db, .threaded = threaded };
}

fn teardown(ctx: *TestCtx) void {
    ctx.db.deinit();
    ctx.threaded.deinit();
}

fn parse(allocator: std.mem.Allocator, json: []const u8) !std.json.Parsed(std.json.Value) {
    return std.json.parseFromSlice(std.json.Value, allocator, json, .{});
}

test "save then list: the note the CLI wrote is the note the CLI reads back" {
    var ctx = try setupDb();
    defer teardown(&ctx);

    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const saved = try parse(testing.allocator, try runWithDb(a, &ctx.db, .{
        .op = .save,
        .workspace_id = "ws_a",
        .content = "the release branch is cut on fridays",
        .tags = "ops, release",
    }));
    defer saved.deinit();
    const id = saved.value.object.get("memory").?.object.get("id").?.string;

    const listed = try parse(testing.allocator, try runWithDb(a, &ctx.db, .{
        .op = .list,
        .workspace_id = "ws_a",
    }));
    defer listed.deinit();

    const memories = listed.value.object.get("memories").?.array;
    try testing.expectEqual(@as(usize, 1), memories.items.len);
    try testing.expectEqualStrings(id, memories.items[0].object.get("id").?.string);
    try testing.expectEqualStrings("the release branch is cut on fridays", memories.items[0].object.get("content").?.string);

    const tags = memories.items[0].object.get("tags").?.array;
    try testing.expectEqual(@as(usize, 2), tags.items.len);
    try testing.expectEqualStrings("ops", tags.items[0].string);
    try testing.expectEqualStrings("release", tags.items[1].string);
}

test "get: a memory from another workspace reads as null" {
    var ctx = try setupDb();
    defer teardown(&ctx);

    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const saved = try parse(testing.allocator, try runWithDb(a, &ctx.db, .{
        .op = .save,
        .workspace_id = "ws_a",
        .content = "only ws_a may read this",
    }));
    defer saved.deinit();
    const id = saved.value.object.get("memory").?.object.get("id").?.string;

    const own = try parse(testing.allocator, try runWithDb(a, &ctx.db, .{ .op = .get, .workspace_id = "ws_a", .id = id }));
    defer own.deinit();
    try testing.expectEqualStrings("only ws_a may read this", own.value.object.get("memory").?.object.get("content").?.string);

    const stolen = try parse(testing.allocator, try runWithDb(a, &ctx.db, .{ .op = .get, .workspace_id = "ws_b", .id = id }));
    defer stolen.deinit();
    try testing.expectEqual(std.json.Value.null, stolen.value.object.get("memory").?);
}

test "delete: the note is gone from the next list" {
    var ctx = try setupDb();
    defer teardown(&ctx);

    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const saved = try parse(testing.allocator, try runWithDb(a, &ctx.db, .{
        .op = .save,
        .workspace_id = "ws_a",
        .content = "temporary note",
    }));
    defer saved.deinit();
    const id = saved.value.object.get("memory").?.object.get("id").?.string;

    const deleted = try parse(testing.allocator, try runWithDb(a, &ctx.db, .{ .op = .delete, .workspace_id = "ws_a", .id = id }));
    defer deleted.deinit();
    try testing.expect(deleted.value.object.get("success").?.bool);

    const listed = try parse(testing.allocator, try runWithDb(a, &ctx.db, .{ .op = .list, .workspace_id = "ws_a" }));
    defer listed.deinit();
    try testing.expectEqual(@as(usize, 0), listed.value.object.get("memories").?.array.items.len);
}

test "delete: a note from another workspace is refused" {
    var ctx = try setupDb();
    defer teardown(&ctx);

    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const saved = try parse(testing.allocator, try runWithDb(a, &ctx.db, .{
        .op = .save,
        .workspace_id = "ws_a",
        .content = "not yours to delete",
    }));
    defer saved.deinit();
    const id = saved.value.object.get("memory").?.object.get("id").?.string;

    try testing.expectError(
        error.NotFound,
        runWithDb(a, &ctx.db, .{ .op = .delete, .workspace_id = "ws_b", .id = id }),
    );
}

test "save: an empty body is refused instead of stored" {
    var ctx = try setupDb();
    defer teardown(&ctx);

    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();

    try testing.expectError(
        error.InvalidContent,
        runWithDb(arena.allocator(), &ctx.db, .{ .op = .save, .workspace_id = "ws_a", .content = "" }),
    );
}

test "list: --limit and --offset page the same way the HTTP endpoint does" {
    var ctx = try setupDb();
    defer teardown(&ctx);

    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    for (0..3) |i| {
        const content = try std.fmt.allocPrint(a, "note {d}", .{i});
        _ = try runWithDb(a, &ctx.db, .{ .op = .save, .workspace_id = "ws_a", .content = content });
    }

    const page = try parse(testing.allocator, try runWithDb(a, &ctx.db, .{
        .op = .list,
        .workspace_id = "ws_a",
        .limit = "2",
        .offset = "2",
    }));
    defer page.deinit();

    try testing.expectEqual(@as(usize, 1), page.value.object.get("memories").?.array.items.len);
    try testing.expectEqual(@as(i64, 3), page.value.object.get("total_count").?.integer);
}
