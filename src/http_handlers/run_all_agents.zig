//! Bulk endpoint `POST .../kanban/columns/:column_id/run_all_agents`. Starts
//! agents on every idle task in a kanban column, including tasks not yet
//! loaded by frontend pagination.

const std = @import("std");
const pabrikcore = @import("pabrikcore");
const auth_common = @import("auth_common.zig");
const gserverz = pabrikcore.gserverz;
const sqlite = pabrikcore.sqlite;
const http_response = @import("http_response.zig");
const start_agent = @import("start_agent.zig");

// =====================================================================
// Domain types
// =====================================================================

/// Per-task outcome inside a bulk run.
pub const PerTaskResult = enum {
    started,
    skipped,
    failed,
};

/// Injectable per-task starter. Production wraps `startAgentUseCase`;
/// tests supply a fake that consults the real `isTaskRunning` guard.
pub const TaskStarter = struct {
    ptr: ?*anyopaque,
    run: *const fn (?*anyopaque, []const u8) PerTaskResult,
};

/// Bulk outcome: owned id lists. Caller owns every string + slice;
/// release with `deinit`.
pub const RunAllAgentsOutcome = struct {
    started: [][]u8,
    skipped: [][]u8,
    failed: [][]u8,

    pub fn deinit(self: *RunAllAgentsOutcome, allocator: std.mem.Allocator) void {
        for (self.started) |id| allocator.free(id);
        allocator.free(self.started);
        for (self.skipped) |id| allocator.free(id);
        allocator.free(self.skipped);
        for (self.failed) |id| allocator.free(id);
        allocator.free(self.failed);
        self.started = &[_][]u8{};
        self.skipped = &[_][]u8{};
        self.failed = &[_][]u8{};
    }
};

// =====================================================================
// Injectable core (behavioural-test seam)
// =====================================================================

/// List every task id in `column_id`, then run `starter` per id.
pub fn runAllAgentsWithStarter(
    allocator: std.mem.Allocator,
    db: *sqlite.SqliteBackend,
    column_id: []const u8,
    starter: TaskStarter,
) !RunAllAgentsOutcome {
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

    // 3. Sequential per-id loop (avoids thundering herd on
    //    emit_run_agent + sqlite worker writes). One failure never
    //    aborts the rest.
    var started = std.ArrayList([]u8).empty;
    errdefer {
        for (started.items) |id| allocator.free(id);
        started.deinit(allocator);
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
        switch (starter.run(starter.ptr, id)) {
            .started => try started.append(allocator, id),
            .skipped => try skipped.append(allocator, id),
            .failed => try failed.append(allocator, id),
        }
    }
    // Ownership of every id slice moves into the three outcome lists;
    // release only the staging container (not its elements).
    ids.deinit(allocator);

    return .{
        .started = try started.toOwnedSlice(allocator),
        .skipped = try skipped.toOwnedSlice(allocator),
        .failed = try failed.toOwnedSlice(allocator),
    };
}

// =====================================================================
// Live binding (Option C: reuse startAgentUseCase per id)
// =====================================================================

const LiveCtx = struct {
    allocator: std.mem.Allocator,
    db: *sqlite.SqliteBackend,
    di: *pabrikcore.App,
    owner: []const u8,
};

fn liveRun(ptr: ?*anyopaque, task_id: []const u8) PerTaskResult {
    const c: *LiveCtx = @ptrCast(@alignCast(ptr.?));
    const outcome = start_agent.startAgentUseCase(c.allocator, c.db, c.di, task_id, c.owner) catch return .failed;
    return switch (outcome) {
        .triggered => .started,
        .worker_already_running => .skipped,
        .task_not_found => .failed,
    };
}

/// Production use-case: reuse the single-task `startAgentUseCase` per id
/// (keeping its 404-via-getWorkspaceItemTask + 409-via-isTaskRunning guards —
/// never copy-pasted).
pub fn runAllAgentsUseCase(
    allocator: std.mem.Allocator,
    db: *sqlite.SqliteBackend,
    di: *pabrikcore.App,
    column_id: []const u8,
    owner: []const u8,
) !RunAllAgentsOutcome {
    var live = LiveCtx{ .allocator = allocator, .db = db, .di = di, .owner = owner };
    // Explicit reference keeps the reuse grep stable: startAgentUseCase
    const starter: TaskStarter = .{ .ptr = &live, .run = liveRun };
    return runAllAgentsWithStarter(allocator, db, column_id, starter);
}

// =====================================================================
// Handler
// =====================================================================

/// `POST
/// /api/workspaces/:workspace_id/items/:item_id/kanban/columns/:column_id/run_all_agents`.
pub fn runAllAgentsHandler(
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

    // 3. Apply the use-case (which reuses startAgentUseCase per task id).
    // Owner rides along so each started worker keeps its session row owned
    // under `--auth` (plan 2026-09-25).
    var owner_buf: [128]u8 = undefined;
    const owner: []const u8 = auth_common.resolveOwnerInto(&owner_buf, req.headers) orelse "";
    const outcome = runAllAgentsUseCase(allocator, sqlite_db, di, column_id, owner) catch |err| {
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
        std.log.err("run_all_agents: useCase failed: {s}", .{@errorName(err)});
        return res.jsonResponse(.{
            .status_code = 500,
            .data = try http_response.makeErrorResponse(allocator, .{ .@"error" = "run_all_agents use-case failed" }),
        });
    };
    // Note: outcome slices are arena-allocated on the success path; the
    // per-request arena frees them (no deinit here). The ColumnNotFound
    // branch above maps unknown columns to 404.

    // 4. Success envelope with the three id lists the frontend summary
    //    banner needs: "started", "skipped", "failed".
    const started_json = try std.json.Stringify.valueAlloc(allocator, outcome.started, .{});
    const skipped_json = try std.json.Stringify.valueAlloc(allocator, outcome.skipped, .{});
    const failed_json = try std.json.Stringify.valueAlloc(allocator, outcome.failed, .{});
    return res.jsonResponse(.{
        .status_code = 200,
        .data = try std.fmt.allocPrint(
            allocator,
            "{{\"success\":true,\"column_id\":\"{s}\",\"started\":{s},\"skipped\":{s},\"failed\":{s}}}",
            .{ column_id, started_json, skipped_json, failed_json },
        ),
    });
}

// =====================================================================
// Inline behavioural tests.

const testing = std.testing;

// =====================================================================
// Behavioural harness: bare in-memory DB + fake starter
// =====================================================================

const TestDb = struct {
    db: sqlite.SqliteBackend,
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

    var db: sqlite.SqliteBackend = .{};
    errdefer db.deinit();
    try db.init(io, ":memory:");

    return .{ .db = db, .threaded = threaded };
}

/// Post-Migration-072 minimal schema: the kanban join table holds the
/// 1:1 task-to-board placement (workspace_item_tasks has NO
/// kanban_column_id column). Mirrors the kanban_model.zig test setup.
fn setupColumnSchema(ctx: *TestDb) !void {
    const alloc = testing.allocator;
    try ctx.db.exec(alloc,
        \\CREATE TABLE kanban_columns (
        \\    id TEXT PRIMARY KEY, workspace_item_id TEXT, name TEXT,
        \\    position INTEGER, created_at DATETIME DEFAULT CURRENT_TIMESTAMP)
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
    // isTaskRunning only reads worker.session_id; the minimal schema
    // is enough (extra production columns are never referenced).
    try ctx.db.exec(alloc,
        \\CREATE TABLE worker (
        \\    id TEXT PRIMARY KEY, session_id TEXT NOT NULL)
    , &.{});
}

/// Seed one column (c1) with three tasks (A idle, B running, C idle).
/// B gets a `worker` row so the real `isTaskRunning` guard fires.
fn seedThreeTaskColumn(ctx: *TestDb) !void {
    const alloc = testing.allocator;
    try ctx.db.exec(alloc,
        "INSERT INTO kanban_columns (id, workspace_item_id, name, position) VALUES ('c1', 'item_1', 'todo', 0)",
        &.{});
    try ctx.db.exec(alloc,
        "INSERT INTO workspace_item_tasks (id, name, workspace_item_id) VALUES " ++
            "('task-A', 'A', 'item_1'), ('task-B', 'B', 'item_1'), ('task-C', 'C', 'item_1')",
        &.{});
    try ctx.db.exec(alloc,
        "INSERT INTO kanban (workspace_item_task_id, kanban_column_id, kanban_position) VALUES " ++
            "('task-A', 'c1', 0), ('task-B', 'c1', 1), ('task-C', 'c1', 2)",
        &.{});
    try ctx.db.exec(alloc,
        "INSERT INTO worker (id, session_id) VALUES ('w-B', 'task-B')",
        &.{});
}

/// Fake per-task starter with production guard semantics: consults the real
/// `isTaskRunning` (seeded `worker` row ⇒ skipped), honours a scripted
/// fail-list (⇒ failed), otherwise ⇒ started.
const FakeCtx = struct {
    db: *sqlite.SqliteBackend,
    fail_ids: []const []const u8 = &.{},
};

fn fakeRun(ptr: ?*anyopaque, task_id: []const u8) PerTaskResult {
    const c: *FakeCtx = @ptrCast(@alignCast(ptr.?));
    for (c.fail_ids) |f| {
        if (std.mem.eql(u8, f, task_id)) return .failed;
    }
    if (pabrikcore.ai_mod.llm_history.isTaskRunning(testing.allocator, c.db, task_id)) return .skipped;
    return .started;
}

fn fakeStarter(ctx: *FakeCtx) TaskStarter {
    return .{ .ptr = ctx, .run = fakeRun };
}

fn containsId(ids: []const []u8, want: []const u8) bool {
    for (ids) |id| {
        if (std.mem.eql(u8, id, want)) return true;
    }
    return false;
}

// ─── Behavioural 1: empty column_id is rejected before any DB work ───

test "runAllAgents rejects empty column_id" {
    var ctx = try setupDb();
    defer ctx.deinit();
    var fake = FakeCtx{ .db = &ctx.db };

    // Empty-slice-as-NULL rule: "" must never reach a `WHERE id = ?`
    // binding (SqliteBackend binds "" as SQL NULL). The use-case
    // validates first and returns EmptyColumnId.
    const result = runAllAgentsWithStarter(
        testing.allocator,
        &ctx.db,
        "",
        fakeStarter(&fake),
    );
    try testing.expectError(error.EmptyColumnId, result);
}

// ─── Behavioural 2: unknown column maps to column_not_found (→ 404) ──

test "runAllAgents maps unknown column to column_not_found" {
    var ctx = try setupDb();
    defer ctx.deinit();
    try setupColumnSchema(&ctx);
    var fake = FakeCtx{ .db = &ctx.db };

    const result = runAllAgentsWithStarter(
        testing.allocator,
        &ctx.db,
        "col_does_not_exist",
        fakeStarter(&fake),
    );
    try testing.expectError(error.ColumnNotFound, result);
}

// ─── Behavioural 3: [idle-A, running-B, idle-C] → started [A,C] ──────

test "runAllAgents starts idle tasks and skips running ones" {
    const alloc = testing.allocator;
    var ctx = try setupDb();
    defer ctx.deinit();
    try setupColumnSchema(&ctx);
    try seedThreeTaskColumn(&ctx);
    var fake = FakeCtx{ .db = &ctx.db };

    var outcome = try runAllAgentsWithStarter(
        alloc,
        &ctx.db,
        "c1",
        fakeStarter(&fake),
    );
    defer outcome.deinit(alloc);

    try testing.expectEqual(@as(usize, 2), outcome.started.len);
    try testing.expect(containsId(outcome.started, "task-A"));
    try testing.expect(containsId(outcome.started, "task-C"));

    try testing.expectEqual(@as(usize, 1), outcome.skipped.len);
    try testing.expect(containsId(outcome.skipped, "task-B"));

    try testing.expectEqual(@as(usize, 0), outcome.failed.len);
}

// ─── Behavioural 4: single-task failure never aborts the bulk run ────

test "runAllAgents collects single-task failures instead of throwing" {
    const alloc = testing.allocator;
    var ctx = try setupDb();
    defer ctx.deinit();
    try setupColumnSchema(&ctx);
    try seedThreeTaskColumn(&ctx);
    // task-C's starter blows up (e.g. emit_run_agent DB error in
    // production); A must still start and B must still skip.
    const fail_ids: []const []const u8 = &.{"task-C"};
    var fake = FakeCtx{ .db = &ctx.db, .fail_ids = fail_ids };

    var outcome = try runAllAgentsWithStarter(
        alloc,
        &ctx.db,
        "c1",
        fakeStarter(&fake),
    );
    defer outcome.deinit(alloc);

    try testing.expectEqual(@as(usize, 1), outcome.started.len);
    try testing.expect(containsId(outcome.started, "task-A"));

    try testing.expectEqual(@as(usize, 1), outcome.skipped.len);
    try testing.expect(containsId(outcome.skipped, "task-B"));

    try testing.expectEqual(@as(usize, 1), outcome.failed.len);
    try testing.expect(containsId(outcome.failed, "task-C"));
}
