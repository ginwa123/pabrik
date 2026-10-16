//! Kanban task dependencies (`depends_on`): one row per edge. A dependency is
//! COMPLETE when its card sits in a column flagged `is_done`; unassigned counts
//! as incomplete. The move gate lives in `kanban_model.moveTaskChecked`.

const std = @import("std");
const pabrikcore = @import("pabrikcore");
const sqlite = pabrikcore.sqlite;

/// Hard cap on the number of dependencies a single task may declare. Keeps the
/// dependency list payload and the cycle walk bounded.
pub const max_dependencies: usize = 32;

/// One resolved dependency edge.
pub const Edge = struct {
    /// The task that owns the dependency — the one that waits.
    task_id: []u8,
    /// The task that must complete first.
    depends_on_task_id: []u8,
    /// The dependency's name ('' when the row is gone).
    name: []u8,
    /// The dependency's current column ('' when it is unassigned).
    column_id: []u8,
    /// The dependency's current column name ('' when it is unassigned).
    column_name: []u8,
    /// True when the dependency sits in a column flagged `is_done`.
    is_done: bool,
};

pub fn freeEdges(allocator: std.mem.Allocator, edges: []Edge) void {
    for (edges) |e| {
        allocator.free(e.task_id);
        allocator.free(e.depends_on_task_id);
        allocator.free(e.name);
        allocator.free(e.column_id);
        allocator.free(e.column_name);
    }
    allocator.free(edges);
}

/// True when at least one edge points at a dependency that has not completed.
pub fn anyIncomplete(edges: []const Edge) bool {
    for (edges) |e| {
        if (!e.is_done) return true;
    }
    return false;
}

// =====================================================================
// Reads
// =====================================================================

/// `dep` is the DEPENDENCY (the task that must finish first), NOT the owner:
/// every column after the two ids describes it. LEFT JOINs so a dangling edge
/// still reports its id.
const edge_select =
    "SELECT d.task_id, d.depends_on_task_id, " ++
    "COALESCE(dep.name, ''), COALESCE(k.kanban_column_id, ''), " ++
    "COALESCE(c.name, ''), COALESCE(c.is_done, 0)";
const edge_joins =
    " FROM kanban_task_dependencies d " ++
    "LEFT JOIN workspace_item_tasks dep ON dep.id = d.depends_on_task_id " ++
    "LEFT JOIN kanban k ON k.workspace_item_task_id = d.depends_on_task_id " ++
    "LEFT JOIN kanban_columns c ON c.id = k.kanban_column_id";

const edge_sql_for_task = edge_select ++ edge_joins ++
    " WHERE d.task_id = ? ORDER BY d.depends_on_task_id";
// The board filter goes through the OWNER (`o`); `validate` only ever admits an
// edge inside one board, so the dependency's own item is never consulted.
const edge_sql_for_item = edge_select ++
    " FROM kanban_task_dependencies d " ++
    "JOIN workspace_item_tasks o ON o.id = d.task_id " ++
    "LEFT JOIN workspace_item_tasks dep ON dep.id = d.depends_on_task_id " ++
    "LEFT JOIN kanban k ON k.workspace_item_task_id = d.depends_on_task_id " ++
    "LEFT JOIN kanban_columns c ON c.id = k.kanban_column_id " ++
    "WHERE o.workspace_item_id = ? ORDER BY d.task_id, d.depends_on_task_id";

/// Every dependency edge owned by `task_id`. Caller frees with `freeEdges`.
pub fn listEdgesForTask(
    allocator: std.mem.Allocator,
    db: *sqlite.SqliteBackend,
    task_id: []const u8,
) ![]Edge {
    return readEdges(allocator, db, edge_sql_for_task, task_id);
}

/// Every dependency edge of every task under `item_id`, ordered by owner.
/// One query serves a whole board listing. Caller frees with `freeEdges`.
pub fn listEdgesForItem(
    allocator: std.mem.Allocator,
    db: *sqlite.SqliteBackend,
    item_id: []const u8,
) ![]Edge {
    return readEdges(allocator, db, edge_sql_for_item, item_id);
}

fn readEdges(
    allocator: std.mem.Allocator,
    db: *sqlite.SqliteBackend,
    comptime sql: []const u8,
    key: []const u8,
) ![]Edge {
    var q = try db.query(allocator, sql, &.{key});
    defer q.deinit();

    var rows = std.ArrayList(Edge).empty;
    errdefer {
        for (rows.items) |e| {
            allocator.free(e.task_id);
            allocator.free(e.depends_on_task_id);
            allocator.free(e.name);
            allocator.free(e.column_id);
            allocator.free(e.column_name);
        }
        rows.deinit(allocator);
    }

    while (try q.next()) |row| {
        defer row.deinit(allocator);
        try rows.append(allocator, .{
            .task_id = try allocator.dupe(u8, row.values[0]),
            .depends_on_task_id = try allocator.dupe(u8, row.values[1]),
            .name = try allocator.dupe(u8, row.values[2]),
            .column_id = try allocator.dupe(u8, row.values[3]),
            .column_name = try allocator.dupe(u8, row.values[4]),
            // COALESCE makes this never-NULL, and a non-"0" value is true —
            // a row written before the column existed must not read as
            // "not done" for a column the user marked done.
            .is_done = !std.mem.eql(u8, row.values[5], "0"),
        });
    }
    return rows.toOwnedSlice(allocator);
}

// =====================================================================
// Writes
// =====================================================================

/// Replace the task's dependency set with `ids`. `ids` must already be
/// normalized and validated (see `validateAndReplace`).
pub fn replace(
    allocator: std.mem.Allocator,
    db: *sqlite.SqliteBackend,
    task_id: []const u8,
    ids: []const []const u8,
) !void {
    var tx = try db.begin();
    defer tx.commitOrRollback() catch {};
    errdefer tx.rollback() catch {};

    try tx.exec(allocator, "DELETE FROM kanban_task_dependencies WHERE task_id = ?", &.{task_id});
    for (ids) |id| {
        try tx.exec(allocator,
            \\INSERT OR IGNORE INTO kanban_task_dependencies (task_id, depends_on_task_id)
            \\VALUES (?, ?)
        , &.{ task_id, id });
    }
}

/// Drop every edge that mentions `task_id`, in both directions. Called when a
/// task is deleted so a dangling edge cannot freeze another card forever.
pub fn deleteForTask(
    allocator: std.mem.Allocator,
    db: *sqlite.SqliteBackend,
    task_id: []const u8,
) !void {
    try db.exec(allocator, "DELETE FROM kanban_task_dependencies WHERE task_id = ? OR depends_on_task_id = ?", &.{ task_id, task_id });
}

// =====================================================================
// Validation
// =====================================================================

pub const ValidationError = error{
    SelfDependency,
    DependencyNotInItem,
    DependencyCycle,
    TooManyDependencies,
    OutOfMemory,
    QueryFailed,
};

/// Dedupe the ids (order preserved), drop empties, and reject what needs no DB:
/// a self-dependency and the cap. The result borrows from `ids` — only the outer
/// slice is owned.
pub fn normalizeIds(
    allocator: std.mem.Allocator,
    task_id: []const u8,
    ids: []const []const u8,
) ValidationError![][]const u8 {
    var seen = std.StringHashMapUnmanaged(void){};
    defer seen.deinit(allocator);

    var out: std.ArrayList([]const u8) = .empty;
    errdefer out.deinit(allocator);

    for (ids) |raw| {
        const id = std.mem.trim(u8, raw, " \t\r\n");
        if (id.len == 0) continue;
        if (std.mem.eql(u8, id, task_id)) return error.SelfDependency;

        const gop = try seen.getOrPut(allocator, id);
        if (gop.found_existing) continue;

        if (out.items.len >= max_dependencies) return error.TooManyDependencies;
        try out.append(allocator, id);
    }
    return out.toOwnedSlice(allocator);
}

/// True when adding `task_id -> new_deps` would close a cycle: walking
/// dependency edges out of any new dependency reaches `task_id` again. Pure —
/// `edges` and `new_deps` are only borrowed.
pub fn hasCycle(
    allocator: std.mem.Allocator,
    edges: []const Edge,
    task_id: []const u8,
    new_deps: []const []const u8,
) std.mem.Allocator.Error!bool {
    var visited = std.StringHashMapUnmanaged(void){};
    defer visited.deinit(allocator);

    var queue: std.ArrayList([]const u8) = .empty;
    defer queue.deinit(allocator);

    for (new_deps) |d| {
        if (std.mem.eql(u8, d, task_id)) return true;
        try queue.append(allocator, d);
    }

    while (queue.items.len > 0) {
        const cur = queue.orderedRemove(0);
        const gop = try visited.getOrPut(allocator, cur);
        if (gop.found_existing) continue;

        for (edges) |e| {
            if (!std.mem.eql(u8, e.task_id, cur)) continue;
            if (std.mem.eql(u8, e.depends_on_task_id, task_id)) return true;
            try queue.append(allocator, e.depends_on_task_id);
        }
    }
    return false;
}

/// Validate a proposed dependency set against its board: every id must be a
/// task of `item_id`, and the resulting graph must stay acyclic.
pub fn validate(
    allocator: std.mem.Allocator,
    db: *sqlite.SqliteBackend,
    item_id: []const u8,
    task_id: []const u8,
    ids: []const []const u8,
) ValidationError!void {
    if (ids.len == 0) return;

    for (ids) |id| {
        var q = db.query(allocator, "SELECT COUNT(*) FROM workspace_item_tasks WHERE id = ? AND workspace_item_id = ?", &.{ id, item_id }) catch return error.QueryFailed;
        defer q.deinit();
        const row = (q.next() catch return error.QueryFailed) orelse return error.QueryFailed;
        defer row.deinit(allocator);
        if (!std.mem.eql(u8, row.values[0], "1")) return error.DependencyNotInItem;
    }

    // A cycle is a property of the WHOLE board, not of this task alone, so the
    // walk starts from the item's current graph.
    const edges = listEdgesForItem(allocator, db, item_id) catch return error.QueryFailed;
    defer freeEdges(allocator, edges);

    const cyclic = hasCycle(allocator, edges, task_id, ids) catch return error.OutOfMemory;
    if (cyclic) return error.DependencyCycle;
}

/// Normalize -> validate -> replace, in that order. The single entry point the
/// HTTP handlers use.
pub fn validateAndReplace(
    allocator: std.mem.Allocator,
    db: *sqlite.SqliteBackend,
    item_id: []const u8,
    task_id: []const u8,
    raw_ids: []const []const u8,
) ValidationError!void {
    const ids = try normalizeIds(allocator, task_id, raw_ids);
    defer allocator.free(ids);

    try validate(allocator, db, item_id, task_id, ids);
    replace(allocator, db, task_id, ids) catch return error.QueryFailed;
}

// =====================================================================
// Tests
// =====================================================================

const testing = std.testing;

const TestDb = struct {
    db: sqlite.SqliteBackend,
    threaded: std.Io.Threaded,

    fn deinit(self: *TestDb) void {
        self.db.deinit();
        self.threaded.deinit();
    }
};

/// In-memory DB carrying only the tables the dependency code touches.
fn setupDb() !TestDb {
    const alloc = testing.allocator;
    var threaded = std.Io.Threaded.init(alloc, .{});
    errdefer threaded.deinit();

    var db: sqlite.SqliteBackend = .{};
    errdefer db.deinit();
    try db.init(threaded.io(), ":memory:");

    try db.exec(alloc,
        \\CREATE TABLE kanban_columns (
        \\    id TEXT PRIMARY KEY, workspace_item_id TEXT, name TEXT, description TEXT NOT NULL DEFAULT '',
        \\    position INTEGER, is_done INTEGER NOT NULL DEFAULT 0,
        \\    created_at DATETIME DEFAULT CURRENT_TIMESTAMP)
    , &.{});
    try db.exec(alloc,
        \\CREATE TABLE workspace_item_tasks (
        \\    id TEXT PRIMARY KEY, name TEXT, workspace_item_id TEXT)
    , &.{});
    try db.exec(alloc,
        \\CREATE TABLE kanban (
        \\    workspace_item_task_id TEXT PRIMARY KEY, kanban_column_id TEXT NOT NULL,
        \\    kanban_position INTEGER NOT NULL DEFAULT 0)
    , &.{});
    try db.exec(alloc,
        \\CREATE TABLE kanban_task_dependencies (
        \\    task_id TEXT NOT NULL, depends_on_task_id TEXT NOT NULL,
        \\    created_at DATETIME DEFAULT CURRENT_TIMESTAMP,
        \\    PRIMARY KEY (task_id, depends_on_task_id))
    , &.{});

    return .{ .db = db, .threaded = threaded };
}

/// t1 (owner) waits for t2; t3 is unrelated. c1 = in progress, c2 = done.
fn seedBoard(db: *sqlite.SqliteBackend) !void {
    const alloc = testing.allocator;
    try db.exec(alloc, "INSERT INTO kanban_columns (id, workspace_item_id, name, position, is_done) VALUES ('c1', 'item_1', 'in progress', 0, 0)", &.{});
    try db.exec(alloc, "INSERT INTO kanban_columns (id, workspace_item_id, name, position, is_done) VALUES ('c2', 'item_1', 'done', 1, 1)", &.{});
    try db.exec(alloc, "INSERT INTO workspace_item_tasks (id, name, workspace_item_id) VALUES ('t1', 'Ship it', 'item_1')", &.{});
    try db.exec(alloc, "INSERT INTO workspace_item_tasks (id, name, workspace_item_id) VALUES ('t2', 'Fix login', 'item_1')", &.{});
    try db.exec(alloc, "INSERT INTO workspace_item_tasks (id, name, workspace_item_id) VALUES ('t3', 'Other board task', 'item_2')", &.{});
    try db.exec(alloc, "INSERT INTO kanban (workspace_item_task_id, kanban_column_id, kanban_position) VALUES ('t1', 'c1', 0)", &.{});
    try db.exec(alloc, "INSERT INTO kanban (workspace_item_task_id, kanban_column_id, kanban_position) VALUES ('t2', 'c1', 1)", &.{});
}

fn edge(task_id: []const u8, dep: []const u8) Edge {
    return .{
        .task_id = @constCast(task_id),
        .depends_on_task_id = @constCast(dep),
        .name = @constCast(""),
        .column_id = @constCast(""),
        .column_name = @constCast(""),
        .is_done = false,
    };
}

test "kanban_deps: normalizeIds drops duplicates and blanks, keeping the first order" {
    const alloc = testing.allocator;

    const ids = try normalizeIds(alloc, "t1", &.{ " t2 ", "t3", "t2", "" });
    defer alloc.free(ids);
    try testing.expectEqual(@as(usize, 2), ids.len);
    try testing.expectEqualStrings("t2", ids[0]);
    try testing.expectEqualStrings("t3", ids[1]);
}

test "kanban_deps: normalizeIds rejects a task that depends on itself" {
    try testing.expectError(
        error.SelfDependency,
        normalizeIds(testing.allocator, "t1", &.{"t1"}),
    );
}

test "kanban_deps: normalizeIds rejects more than the 32 dependency cap" {
    const alloc = testing.allocator;
    var raw: [max_dependencies + 1][]const u8 = undefined;
    var buf: [max_dependencies + 1][8]u8 = undefined;
    for (&raw, 0..) |*slot, i| {
        slot.* = try std.fmt.bufPrint(&buf[i], "d_{d}", .{i});
    }

    // Exactly the cap is fine.
    const ok = try normalizeIds(alloc, "t1", raw[0..max_dependencies]);
    defer alloc.free(ok);
    try testing.expectEqual(max_dependencies, ok.len);

    // One more is not.
    try testing.expectError(error.TooManyDependencies, normalizeIds(alloc, "t1", &raw));
}

test "kanban_deps: hasCycle accepts an edge that follows the existing chain" {
    // a -> b -> c, so a -> c adds nothing new.
    const chain = [_]Edge{ edge("a", "b"), edge("b", "c") };

    try testing.expect(!try hasCycle(testing.allocator, &chain, "a", &.{"c"}));
}

test "kanban_deps: hasCycle rejects a two-task cycle" {
    // b already waits for a; making a wait for b would freeze both cards.
    const back = [_]Edge{edge("b", "a")};

    try testing.expect(try hasCycle(testing.allocator, &back, "a", &.{"b"}));
}

test "kanban_deps: hasCycle follows edges transitively" {
    // a -> b -> c -> a: b -> c is a cycle even though they are not neighbours.
    const long = [_]Edge{ edge("a", "b"), edge("b", "c"), edge("c", "a") };

    try testing.expect(try hasCycle(testing.allocator, &long, "b", &.{"c"}));
}

test "kanban_deps: hasCycle accepts two tasks that share one dependency" {
    // Both b and c wait for d - a diamond, not a cycle.
    const diamond = [_]Edge{ edge("b", "d"), edge("c", "d") };

    try testing.expect(!try hasCycle(testing.allocator, &diamond, "a", &.{ "b", "c" }));
}

test "kanban_deps: hasCycle treats depending on yourself as a cycle" {
    const chain = [_]Edge{ edge("a", "b"), edge("b", "c") };

    try testing.expect(try hasCycle(testing.allocator, &chain, "a", &.{"a"}));
}

test "kanban_deps: replace then listEdgesForTask reads the edge back with its column" {
    const alloc = testing.allocator;
    var s = try setupDb();
    defer s.deinit();
    try seedBoard(&s.db);

    try replace(alloc, &s.db, "t1", &.{"t2"});

    const edges = try listEdgesForTask(alloc, &s.db, "t1");
    defer freeEdges(alloc, edges);

    try testing.expectEqual(@as(usize, 1), edges.len);
    try testing.expectEqualStrings("t1", edges[0].task_id);
    try testing.expectEqualStrings("t2", edges[0].depends_on_task_id);
    try testing.expectEqualStrings("Fix login", edges[0].name);
    try testing.expectEqualStrings("c1", edges[0].column_id);
    try testing.expectEqualStrings("in progress", edges[0].column_name);
    try testing.expect(!edges[0].is_done);
    try testing.expect(anyIncomplete(edges));
}

test "kanban_deps: a dependency in an is_done column counts as complete" {
    const alloc = testing.allocator;
    var s = try setupDb();
    defer s.deinit();
    try seedBoard(&s.db);
    try replace(alloc, &s.db, "t1", &.{"t2"});
    try s.db.exec(alloc, "UPDATE kanban SET kanban_column_id = 'c2' WHERE workspace_item_task_id = 't2'", &.{});

    const edges = try listEdgesForTask(alloc, &s.db, "t1");
    defer freeEdges(alloc, edges);

    try testing.expect(edges[0].is_done);
    try testing.expect(!anyIncomplete(edges));
}

test "kanban_deps: an unassigned dependency counts as incomplete" {
    const alloc = testing.allocator;
    var s = try setupDb();
    defer s.deinit();
    try seedBoard(&s.db);
    try replace(alloc, &s.db, "t1", &.{"t2"});
    try s.db.exec(alloc, "DELETE FROM kanban WHERE workspace_item_task_id = 't2'", &.{});

    const edges = try listEdgesForTask(alloc, &s.db, "t1");
    defer freeEdges(alloc, edges);

    try testing.expectEqualStrings("", edges[0].column_id);
    try testing.expect(!edges[0].is_done);
    try testing.expect(anyIncomplete(edges));
}

test "kanban_deps: listEdgesForItem spans every task of one board only" {
    const alloc = testing.allocator;
    var s = try setupDb();
    defer s.deinit();
    try seedBoard(&s.db);

    try replace(alloc, &s.db, "t1", &.{"t2"});
    try replace(alloc, &s.db, "t2", &.{"t1"});

    const item_edges = try listEdgesForItem(alloc, &s.db, "item_1");
    defer freeEdges(alloc, item_edges);
    try testing.expectEqual(@as(usize, 2), item_edges.len);
    try testing.expectEqualStrings("t1", item_edges[0].task_id);
    try testing.expectEqualStrings("t2", item_edges[1].task_id);
}

test "kanban_deps: validate rejects a dependency that is not a task of the item" {
    const alloc = testing.allocator;
    var s = try setupDb();
    defer s.deinit();
    try seedBoard(&s.db);

    try testing.expectError(
        error.DependencyNotInItem,
        validate(alloc, &s.db, "item_1", "t1", &.{"t3"}),
    );
    try validate(alloc, &s.db, "item_1", "t1", &.{"t2"});
}

test "kanban_deps: validateAndReplace rejects a cycle and keeps the old edges" {
    const alloc = testing.allocator;
    var s = try setupDb();
    defer s.deinit();
    try seedBoard(&s.db);

    // t2 waits for t1; making t1 wait for t2 would freeze both cards.
    try replace(alloc, &s.db, "t2", &.{"t1"});
    try s.db.exec(alloc, "INSERT INTO workspace_item_tasks (id, name, workspace_item_id) VALUES ('t4', 'Four', 'item_1')", &.{});

    try testing.expectError(
        error.DependencyCycle,
        validateAndReplace(alloc, &s.db, "item_1", "t1", &.{"t2"}),
    );

    const edges = try listEdgesForTask(alloc, &s.db, "t1");
    defer freeEdges(alloc, edges);
    try testing.expectEqual(@as(usize, 0), edges.len);
}

test "kanban_deps: deleteForTask drops the edge in both directions" {
    const alloc = testing.allocator;
    var s = try setupDb();
    defer s.deinit();
    try seedBoard(&s.db);

    try replace(alloc, &s.db, "t1", &.{"t2"});
    try deleteForTask(alloc, &s.db, "t2");

    const own = try listEdgesForTask(alloc, &s.db, "t1");
    defer freeEdges(alloc, own);
    try testing.expectEqual(@as(usize, 0), own.len);

    const back = try listEdgesForTask(alloc, &s.db, "t2");
    defer freeEdges(alloc, back);
    try testing.expectEqual(@as(usize, 0), back.len);
}
