//! Bulk endpoint `POST .../kanban/columns/:column_id/stop_all_agents`. Stops
//! agents on every running task in a kanban column, including tasks not yet
//! loaded by frontend pagination.

const std = @import("std");
const pabrikcore = @import("pabrikcore");
const gserverz = pabrikcore.gserverz;
const sqlite = pabrikcore.sqlite;
const database = pabrikcore.database;
const http_response = @import("http_response.zig");

// =====================================================================
// Domain types
// =====================================================================

/// Per-task outcome inside a bulk stop.
pub const PerTaskResult = enum {
    stopped,
    skipped,
    failed,
};

/// Injectable per-task stopper. Production checks `isTaskRunning` then
/// calls `cancelSession`; tests supply a fake with the same split.
pub const TaskStopper = struct {
    ptr: ?*anyopaque,
    run: *const fn (?*anyopaque, []const u8) PerTaskResult,
};

/// Bulk outcome: owned id lists. Caller owns every string + slice;
/// release with `deinit`.
pub const StopAllAgentsOutcome = struct {
    stopped: [][]u8,
    skipped: [][]u8,
    failed: [][]u8,

    pub fn deinit(self: *StopAllAgentsOutcome, allocator: std.mem.Allocator) void {
        for (self.stopped) |id| allocator.free(id);
        allocator.free(self.stopped);
        for (self.skipped) |id| allocator.free(id);
        allocator.free(self.skipped);
        for (self.failed) |id| allocator.free(id);
        allocator.free(self.failed);
        self.stopped = &[_][]u8{};
        self.skipped = &[_][]u8{};
        self.failed = &[_][]u8{};
    }
};

// =====================================================================
// Injectable core (behavioural-test seam)
// =====================================================================

/// List every task id in `column_id`, then run `stopper` per id.
pub fn stopAllAgentsWithStopper(
    allocator: std.mem.Allocator,
    db: *database.Db,
    column_id: []const u8,
    stopper: TaskStopper,
) !StopAllAgentsOutcome {
    if (column_id.len == 0) return error.EmptyColumnId;

    // 1. Column must exist (else the frontend shows "column deleted?").
    {
        var rows = try db.query(
            allocator,
            "SELECT 1 FROM kanban_columns WHERE id = ? LIMIT 1",
            &.{column_id},
        );
        defer rows.deinit();
        if (try rows.next()) |row| {
            row.deinit(allocator);
        } else {
            return error.ColumnNotFound;
        }
    }

    // 2. Server-side id list (pagination-agnostic): the kanban join
    //    table holds the 1:1 task-to-column placement post-Migration-072.
    var ids = std.ArrayList([]u8).empty;
    errdefer {
        for (ids.items) |id| allocator.free(id);
        ids.deinit(allocator);
    }
    {
        var q = try db.query(
            allocator,
            "SELECT workspace_item_task_id FROM kanban WHERE kanban_column_id = ? ORDER BY kanban_position ASC",
            &.{column_id},
        );
        defer q.deinit();
        while (try q.next()) |row| {
            defer row.deinit(allocator);
            const id = try allocator.dupe(u8, row.values[0]);
            errdefer allocator.free(id);
            try ids.append(allocator, id);
        }
    }

    // 3. Sequential per-id loop. One failure never aborts the rest.
    var stopped = std.ArrayList([]u8).empty;
    errdefer {
        for (stopped.items) |id| allocator.free(id);
        stopped.deinit(allocator);
    }
    var skipped = std.ArrayList([]u8).empty;
    errdefer {
        for (skipped.items) |id| allocator.free(id);
        skipped.deinit(allocator);
    }
    var failed = std.ArrayList([]u8).empty;
    errdefer {
        for (failed.items) |id| allocator.free(id);
        failed.deinit(allocator);
    }

    for (ids.items) |id| {
        switch (stopper.run(stopper.ptr, id)) {
            .stopped => try stopped.append(allocator, id),
            .skipped => try skipped.append(allocator, id),
            .failed => try failed.append(allocator, id),
        }
    }
    // Ownership of every id slice moves into the three outcome lists;
    // release only the staging container (not its elements).
    ids.deinit(allocator);

    return .{
        .stopped = try stopped.toOwnedSlice(allocator),
        .skipped = try skipped.toOwnedSlice(allocator),
        .failed = try failed.toOwnedSlice(allocator),
    };
}

// =====================================================================
// Live binding (mirrors run_all_agents.zig liveRun)
// =====================================================================

const LiveCtx = struct {
    allocator: std.mem.Allocator,
    db: *database.Db,
};

fn liveStop(ptr: ?*anyopaque, task_id: []const u8) PerTaskResult {
    const c: *LiveCtx = @ptrCast(@alignCast(ptr.?));
    // Idle tasks (no worker row) are skipped — cancelling them would be
    // a no-op UPDATE matching 0 rows, but the summary must tell the
    // user "nothing was running" vs "we stopped N agents".
    if (!pabrikcore.ai_mod.llm_history.isTaskRunning(c.allocator, c.db, task_id)) return .skipped;
    pabrikcore.ai_mod.llm_history.cancelSession(c.allocator, c.db, task_id) catch return .failed;
    return .stopped;
}

/// Production use-case: check `isTaskRunning` per id (idle ⇒ skipped),
/// then `cancelSession` (running ⇒ stopped, error ⇒ failed).
pub fn stopAllAgentsUseCase(
    allocator: std.mem.Allocator,
    db: *database.Db,
    column_id: []const u8,
) !StopAllAgentsOutcome {
    var live = LiveCtx{ .allocator = allocator, .db = db };
    const stopper: TaskStopper = .{ .ptr = &live, .run = liveStop };
    return stopAllAgentsWithStopper(allocator, db, column_id, stopper);
}

// =====================================================================
// Handler
// =====================================================================

/// `POST
/// /api/workspaces/:workspace_id/items/:item_id/kanban/columns/:column_id/stop_all_agents`.
pub fn stopAllAgentsHandler(
    ctx: gserverz.HttpContext,
    req: gserverz.HttpRequest,
    res: gserverz.HttpResponse,
) !gserverz.HttpResponse {
    const allocator = ctx.allocator;

    // 1. Validate `:column_id` path parameter (empty-slice-as-NULL rule:
    //    "" must never reach a WHERE binding).
    const column_id = req.params.get("column_id") orelse "";
    if (column_id.len == 0) {
        return res.jsonResponse(.{
            .status_code = 400,
            .data = try http_response.makeErrorResponse(allocator, .{ .@"error" = "column_id required" }),
        });
    }

    // 2. Resolve the `App` singleton (carries the DB handle).
    const di = pabrikcore.getSingleton() catch {
        return res.jsonResponse(.{
            .status_code = 500,
            .data = try http_response.makeErrorResponse(allocator, .{ .@"error" = "singleton not initialized" }),
        });
    };
    const sqlite_db = di.db;

    // 3. Apply the use-case.
    const outcome = stopAllAgentsUseCase(allocator, sqlite_db, column_id) catch |err| {
        if (err == error.ColumnNotFound) {
            return res.jsonResponse(.{
                .status_code = 404,
                .data = try http_response.makeErrorResponse(allocator, .{ .@"error" = "column not found" }),
            });
        }
        if (err == error.EmptyColumnId) {
            return res.jsonResponse(.{
                .status_code = 400,
                .data = try http_response.makeErrorResponse(allocator, .{ .@"error" = "column_id required" }),
            });
        }
        std.log.err("stop_all_agents: useCase failed: {s}", .{@errorName(err)});
        return res.jsonResponse(.{
            .status_code = 500,
            .data = try http_response.makeErrorResponse(allocator, .{ .@"error" = "stop_all_agents use-case failed" }),
        });
    };
    // Note: outcome slices are arena-allocated on the success path; the
    // per-request arena frees them (no deinit here). The ColumnNotFound
    // branch above maps unknown columns to 404.

    // 4. Success envelope with the three id lists the frontend summary
    //    banner needs: "stopped", "skipped", "failed".
    const stopped_json = try std.json.Stringify.valueAlloc(allocator, outcome.stopped, .{});
    const skipped_json = try std.json.Stringify.valueAlloc(allocator, outcome.skipped, .{});
    const failed_json = try std.json.Stringify.valueAlloc(allocator, outcome.failed, .{});
    return res.jsonResponse(.{
        .status_code = 200,
        .data = try std.fmt.allocPrint(
            allocator,
            "{{\"success\":true,\"column_id\":\"{s}\",\"stopped\":{s},\"skipped\":{s},\"failed\":{s}}}",
            .{ column_id, stopped_json, skipped_json, failed_json },
        ),
    });
}

// =====================================================================
// Inline behavioural tests.

const testing = std.testing;

// =====================================================================
// Behavioural harness: bare in-memory DB + fake stopper
// =====================================================================

const TestDb = struct {
    db: database.Db,
    threaded: std.Io.Threaded,

    fn deinit(self: *TestDb) void {
        self.db.deinit();
        self.threaded.deinit();
    }
};

fn setupDb() !TestDb {
    const alloc = testing.allocator;
    var threaded = std.Io.Threaded.init(alloc, .{});
    errdefer threaded.deinit();
    const io = threaded.io();

    var db: database.Db = .{};
    errdefer db.deinit();
    try db.init(io, ":memory:");

    return .{ .db = db, .threaded = threaded };
}

/// Post-Migration-072 minimal schema: the kanban join table holds the 1:1
/// task-to-board placement.
fn setupColumnSchema(ctx: *TestDb) !void {
    const alloc = testing.allocator;
    try ctx.db.exec(alloc,
        \\CREATE TABLE kanban_columns (
        \\    id TEXT PRIMARY KEY, workspace_item_id TEXT, name TEXT,
        \\    position INTEGER, is_done INTEGER NOT NULL DEFAULT 0, created_at DATETIME DEFAULT CURRENT_TIMESTAMP)
    , &.{});
    try ctx.db.exec(alloc,
        \\CREATE TABLE workspace_item_tasks (
        \\    id TEXT PRIMARY KEY, name TEXT, workspace_item_id TEXT)
    , &.{});
    try ctx.db.exec(alloc,
        \\CREATE TABLE kanban (
        \\    workspace_item_task_id TEXT PRIMARY KEY, kanban_column_id TEXT NOT NULL,
        \\    kanban_position INTEGER NOT NULL DEFAULT 0)
    , &.{});
    try ctx.db.exec(alloc,
        \\CREATE TABLE worker (
        \\    id TEXT PRIMARY KEY, session_id TEXT NOT NULL, cancelled INTEGER NOT NULL DEFAULT 0)
    , &.{});
}

/// Seed one column (c1) with three tasks (A idle, B running, C running).
/// B + C get `worker` rows so the real `isTaskRunning` guard fires.
fn seedThreeTaskColumn(ctx: *TestDb) !void {
    const alloc = testing.allocator;
    try ctx.db.exec(alloc, "INSERT INTO kanban_columns (id, workspace_item_id, name, position) VALUES ('c1', 'item_1', 'todo', 0)", &.{});
    try ctx.db.exec(alloc, "INSERT INTO workspace_item_tasks (id, name, workspace_item_id) VALUES " ++
        "('task-A', 'A', 'item_1'), ('task-B', 'B', 'item_1'), ('task-C', 'C', 'item_1')", &.{});
    try ctx.db.exec(alloc, "INSERT INTO kanban (workspace_item_task_id, kanban_column_id, kanban_position) VALUES " ++
        "('task-A', 'c1', 0), ('task-B', 'c1', 1), ('task-C', 'c1', 2)", &.{});
    try ctx.db.exec(alloc, "INSERT INTO worker (id, session_id, cancelled) VALUES ('task-B', 'task-B', 0), ('task-C', 'task-C', 0)", &.{});
}

/// Fake per-task stopper with production guard semantics: idle (no
/// worker row) ⇒ skipped, scripted fail-list ⇒ failed, otherwise ⇒
/// stopped. Never touches the real `cancelled` flag.
const FakeCtx = struct {
    db: *database.Db,
    fail_ids: []const []const u8 = &.{},
};

fn fakeRun(ptr: ?*anyopaque, task_id: []const u8) PerTaskResult {
    const c: *FakeCtx = @ptrCast(@alignCast(ptr.?));
    for (c.fail_ids) |f| {
        if (std.mem.eql(u8, f, task_id)) return .failed;
    }
    if (!pabrikcore.ai_mod.llm_history.isTaskRunning(testing.allocator, c.db, task_id)) return .skipped;
    return .stopped;
}

fn fakeStopper(ctx: *FakeCtx) TaskStopper {
    return .{ .ptr = ctx, .run = fakeRun };
}

fn containsId(ids: []const []u8, want: []const u8) bool {
    for (ids) |id| {
        if (std.mem.eql(u8, id, want)) return true;
    }
    return false;
}

// ─── Behavioural 1: empty column_id is rejected before any DB work ───

test "stopAllAgents rejects empty column_id" {
    var ctx = try setupDb();
    defer ctx.deinit();
    var fake = FakeCtx{ .db = &ctx.db };

    // Empty-slice-as-NULL rule: "" must never reach a `WHERE id = ?`
    // binding (Backend binds "" as SQL NULL). The use-case
    // validates first and returns EmptyColumnId.
    const result = stopAllAgentsWithStopper(
        testing.allocator,
        &ctx.db,
        "",
        fakeStopper(&fake),
    );
    try testing.expectError(error.EmptyColumnId, result);
}

// ─── Behavioural 2: unknown column maps to column_not_found (→ 404) ──

test "stopAllAgents maps unknown column to column_not_found" {
    var ctx = try setupDb();
    defer ctx.deinit();
    try setupColumnSchema(&ctx);
    var fake = FakeCtx{ .db = &ctx.db };

    const result = stopAllAgentsWithStopper(
        testing.allocator,
        &ctx.db,
        "col_does_not_exist",
        fakeStopper(&fake),
    );
    try testing.expectError(error.ColumnNotFound, result);
}

// ─── Behavioural 3: [idle-A, running-B, running-C] → stopped [B,C] ───

test "stopAllAgents stops running tasks and skips idle ones" {
    const alloc = testing.allocator;
    var ctx = try setupDb();
    defer ctx.deinit();
    try setupColumnSchema(&ctx);
    try seedThreeTaskColumn(&ctx);
    var fake = FakeCtx{ .db = &ctx.db };

    var outcome = try stopAllAgentsWithStopper(
        alloc,
        &ctx.db,
        "c1",
        fakeStopper(&fake),
    );
    defer outcome.deinit(alloc);

    try testing.expectEqual(@as(usize, 2), outcome.stopped.len);
    try testing.expect(containsId(outcome.stopped, "task-B"));
    try testing.expect(containsId(outcome.stopped, "task-C"));

    try testing.expectEqual(@as(usize, 1), outcome.skipped.len);
    try testing.expect(containsId(outcome.skipped, "task-A"));

    try testing.expectEqual(@as(usize, 0), outcome.failed.len);
}

// ─── Behavioural 4: single-task failure never aborts the bulk run ────

test "stopAllAgents collects single-task failures instead of throwing" {
    const alloc = testing.allocator;
    var ctx = try setupDb();
    defer ctx.deinit();
    try setupColumnSchema(&ctx);
    try seedThreeTaskColumn(&ctx);
    // task-C's stopper blows up (e.g. cancelSession DB error in
    // production); B must still stop and A must still skip.
    const fail_ids: []const []const u8 = &.{"task-C"};
    var fake = FakeCtx{ .db = &ctx.db, .fail_ids = fail_ids };

    var outcome = try stopAllAgentsWithStopper(
        alloc,
        &ctx.db,
        "c1",
        fakeStopper(&fake),
    );
    defer outcome.deinit(alloc);

    try testing.expectEqual(@as(usize, 1), outcome.stopped.len);
    try testing.expect(containsId(outcome.stopped, "task-B"));

    try testing.expectEqual(@as(usize, 1), outcome.skipped.len);
    try testing.expect(containsId(outcome.skipped, "task-A"));

    try testing.expectEqual(@as(usize, 1), outcome.failed.len);
    try testing.expect(containsId(outcome.failed, "task-C"));
}

// ─── Behavioural 5: live use-case flips the cancelled flag ───────────

test "stopAllAgents live use-case cancels running workers" {
    const alloc = testing.allocator;
    var ctx = try setupDb();
    defer ctx.deinit();
    try setupColumnSchema(&ctx);
    try seedThreeTaskColumn(&ctx);

    var outcome = try stopAllAgentsUseCase(alloc, &ctx.db, "c1");
    defer outcome.deinit(alloc);

    try testing.expectEqual(@as(usize, 2), outcome.stopped.len);
    try testing.expectEqual(@as(usize, 1), outcome.skipped.len);
    try testing.expect(containsId(outcome.skipped, "task-A"));
    try testing.expectEqual(@as(usize, 0), outcome.failed.len);

    // The live path really flipped `cancelled = 1` on both workers.
    {
        var rows = try ctx.db.query(alloc, "SELECT cancelled FROM worker WHERE session_id = ?", &.{"task-B"});
        defer rows.deinit();
        const row = (try rows.next()).?;
        defer row.deinit(alloc);
        try testing.expectEqualStrings("1", row.values[0]);
    }
    {
        var rows = try ctx.db.query(alloc, "SELECT cancelled FROM worker WHERE session_id = ?", &.{"task-C"});
        defer rows.deinit();
        const row = (try rows.next()).?;
        defer row.deinit(alloc);
        try testing.expectEqualStrings("1", row.values[0]);
    }
}
