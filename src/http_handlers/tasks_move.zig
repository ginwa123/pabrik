//! `PATCH /api/workspaces/:workspace_id/items/:item_id/tasks/:task_id/move`.
//! Migration 111 gates it: a task waiting on an unfinished dependency may not
//! change column (409 + blockers) unless the body sets `force`.

const std = @import("std");
const pabrikcore = @import("pabrikcore");
const gserverz = pabrikcore.gserverz;
const http_response = @import("http_response.zig");
const kanban_model = @import("../agentic_loop/kanban_model.zig");
const kanban_deps = pabrikcore.ai_mod.kanban_deps;
const on_event_sent_kanban = pabrikcore.ai_mod.on_event_sent_kanban;

/// Request body for task-move.
const MoveTaskBody = struct {
    column_id: []const u8,
    position: i64,
    /// Skip the dependency gate. Defaults to false so an older client (and the
    /// agent's first attempt) always takes the safe path.
    force: bool = false,
};

/// Response shape for a task-move that went through.
const MoveTaskResponse = struct {
    success: bool = true,
    task_id: []const u8,
    column_id: []const u8,
    position: i64,
};

/// 409 body: the move was refused, and here is what is in the way.
pub const BlockersResponse = struct {
    @"error": []const u8 = "Task is blocked by incomplete dependency tasks",
    blockers: []const http_response.TaskDependencyBlocker,
};

pub const TasksMoveError = error{
    ItemIdRequired,
    TaskIdRequired,
    MissingBody,
    InvalidJson,
    ColumnIdRequired,
    MoveFailed,
    /// `std.json.Stringify.valueAlloc` can fail with `OutOfMemory`.
    /// Unreachable on the per-request arena, but the type system
    /// requires the variant.
    OutOfMemory,
};

pub const TasksMoveInput = struct {
    item_id: []const u8,
    workspace_id: []const u8,
    task_id: []const u8,
    body: MoveTaskBody,
};

/// The two ways a move can end, both PRE-SERIALIZED JSON. `blocked` carries a
/// string, not a struct of slices: the edge list it borrows from is freed before
/// `useCase` returns.
pub const TasksMoveResult = union(enum) {
    moved: []const u8,
    blocked: []const u8,
};

// =====================================================================
// Use case
// =====================================================================

fn useCase(
    allocator: std.mem.Allocator,
    db: *pabrikcore.sqlite.SqliteBackend,
    input: TasksMoveInput,
) TasksMoveError!TasksMoveResult {
    if (input.item_id.len == 0) return error.ItemIdRequired;
    if (input.task_id.len == 0) return error.TaskIdRequired;
    if (input.body.column_id.len == 0) return error.ColumnIdRequired;

    kanban_model.moveTaskChecked(
        allocator,
        db,
        input.item_id,
        input.task_id,
        input.body.column_id,
        input.body.position,
        input.body.force,
    ) catch |err| switch (err) {
        error.BlockedByDependencies => {
            // Re-read instead of trusting the gate's verdict: the dependency may
            // have completed in between, and a 409 must never list no blockers.
            const blocked = kanban_model.incompleteDependencies(
                allocator,
                db,
                input.task_id,
            ) catch return error.MoveFailed;
            // Freed through `kanban_model.deps` — the same module copy that
            // produced the slice.
            defer kanban_model.deps.freeEdges(allocator, blocked);

            const fields = http_response.makeTaskDependencyFields(
                allocator,
                blocked,
                input.task_id,
            ) catch return error.OutOfMemory;
            defer {
                allocator.free(fields.depends_on);
                allocator.free(fields.blocked_by);
            }

            return .{ .blocked = try std.json.Stringify.valueAlloc(
                allocator,
                BlockersResponse{ .blockers = fields.blocked_by },
                .{},
            ) };
        },
        else => return error.MoveFailed,
    };

    // Emit SSE event so other connected clients refresh their kanban view.
    // action="moved" matches the frontend's `KanbanTaskEvent` union variant.
    on_event_sent_kanban.onEventSendKanbanTask(allocator, .{
        .action = "moved",
        .workspace_id = input.workspace_id,
        .item_id = input.item_id,
        .task_id = input.task_id,
        .new_column_id = input.body.column_id,
        .new_position = input.body.position,
    }) catch |err| {
        std.log.warn(
            "tasks_move: SSE emit failed (non-fatal): {s}",
            .{@errorName(err)},
        );
    };

    // Chunk 5 of kanban-task-notification-icon: dragging a card to another
    // column is the most visible "human touch" — stamp last_human_touched_at
    // so the kanban card flips from the orange "awaiting review" dot to the
    pabrikcore.ai_mod.llm_history.updateTaskLastHumanTouchedAt(
        allocator,
        db,
        input.task_id,
        null,
    ) catch |err| {
        std.log.warn(
            "tasks_move: stamp last_human_touched_at failed (non-fatal): {s}",
            .{@errorName(err)},
        );
    };

    return .{ .moved = try std.json.Stringify.valueAlloc(allocator, MoveTaskResponse{
        .task_id = input.task_id,
        .column_id = input.body.column_id,
        .position = input.body.position,
    }, .{}) };
}

// =====================================================================
// Handler
// =====================================================================

pub fn tasksMoveHandler(
    ctx: gserverz.HttpContext,
    req: gserverz.HttpRequest,
    res: gserverz.HttpResponse,
) !gserverz.HttpResponse {
    const allocator = ctx.allocator;

    const di = try pabrikcore.getSingleton();
    const sqlite_db = di.db;

    const item_id = req.params.get("item_id") orelse "";
    if (item_id.len == 0) {
        return res.jsonResponse(.{
            .status_code = 400,
            .data = try http_response.makeErrorResponse(allocator, .{ .@"error" = "item_id required" }),
        });
    }
    // workspace_id is required for the SSE payload (the frontend
    // filters events for the active workspace). Empty is fine —
    // the SSE event will still be emitted with workspace_id="".
    const ws_id = req.params.get("workspace_id") orelse "";
    const task_id = req.params.get("task_id") orelse "";
    if (task_id.len == 0) {
        return res.jsonResponse(.{
            .status_code = 400,
            .data = try http_response.makeErrorResponse(allocator, .{ .@"error" = "task_id required" }),
        });
    }

    if (req.body.len == 0) {
        return res.jsonResponse(.{
            .status_code = 400,
            .data = try http_response.makeErrorResponse(allocator, .{ .@"error" = "Request body required" }),
        });
    }

    const parsed = std.json.parseFromSliceLeaky(MoveTaskBody, allocator, req.body, .{ .ignore_unknown_fields = true }) catch {
        return res.jsonResponse(.{
            .status_code = 400,
            .data = try http_response.makeErrorResponse(allocator, .{ .@"error" = "Invalid JSON body" }),
        });
    };

    const outcome = useCase(allocator, sqlite_db, .{
        .item_id = item_id,
        .workspace_id = ws_id,
        .task_id = task_id,
        .body = parsed,
    }) catch |err| {
        const status: u16 = switch (err) {
            error.ItemIdRequired => 400,
            error.TaskIdRequired => 400,
            error.MissingBody => 400,
            error.InvalidJson => 400,
            error.ColumnIdRequired => 400,
            error.MoveFailed => 500,
            error.OutOfMemory => 500,
        };
        const message: []const u8 = switch (err) {
            error.ItemIdRequired => "item_id required",
            error.TaskIdRequired => "task_id required",
            error.MissingBody => "Request body required",
            error.InvalidJson => "Invalid JSON body",
            error.ColumnIdRequired => "column_id is required",
            error.MoveFailed => "Failed to move task",
            error.OutOfMemory => "Out of memory",
        };
        return res.jsonResponse(.{
            .status_code = status,
            .data = try http_response.makeErrorResponse(allocator, .{ .@"error" = message }),
        });
    };

    return switch (outcome) {
        .moved => |json| res.jsonResponse(.{ .status_code = 200, .data = json }),
        .blocked => |json| res.jsonResponse(.{ .status_code = 409, .data = json }),
    };
}

// =====================================================================
// Tests
// =====================================================================

const testing = std.testing;

/// `useCase` hands back an owned JSON string on BOTH arms; the test allocator
/// fails the suite on a leak, so every caller releases it.
fn freeOutcome(allocator: std.mem.Allocator, outcome: TasksMoveResult) void {
    switch (outcome) {
        .moved => |json| allocator.free(json),
        .blocked => |json| allocator.free(json),
    }
}

/// In-memory DB: three columns (only `c3` completes a task), two tasks, and
/// `t1` waiting for `t2`.
fn setupDb() !struct { db: pabrikcore.sqlite.SqliteBackend, threaded: std.Io.Threaded } {
    const alloc = testing.allocator;
    var threaded = std.Io.Threaded.init(alloc, .{});
    errdefer threaded.deinit();

    var db: pabrikcore.sqlite.SqliteBackend = .{};
    errdefer db.deinit();
    try db.init(threaded.io(), ":memory:");

    try db.exec(alloc,
        \\CREATE TABLE kanban_columns (
        \\    id TEXT PRIMARY KEY, workspace_item_id TEXT, name TEXT,
        \\    description TEXT NOT NULL DEFAULT '', position INTEGER,
        \\    is_done INTEGER NOT NULL DEFAULT 0,
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

    try db.exec(alloc, "INSERT INTO kanban_columns (id, workspace_item_id, name, position, is_done) VALUES ('c1', 'item_1', 'todo', 0, 0), ('c2', 'item_1', 'in progress', 1, 0), ('c3', 'item_1', 'done', 2, 1)", &.{});
    try db.exec(alloc, "INSERT INTO workspace_item_tasks (id, name, workspace_item_id) VALUES ('t1', 'Ship it', 'item_1'), ('t2', 'Fix login', 'item_1')", &.{});
    try db.exec(alloc, "INSERT INTO kanban (workspace_item_task_id, kanban_column_id, kanban_position) VALUES ('t1', 'c2', 0), ('t2', 'c1', 0)", &.{});
    try db.exec(alloc, "INSERT INTO kanban_task_dependencies (task_id, depends_on_task_id) VALUES ('t1', 't2')", &.{});

    return .{ .db = db, .threaded = threaded };
}

test "tasks_move useCase moves a task into a column no blocker guards" {
    const alloc = testing.allocator;
    var s = try setupDb();
    defer s.threaded.deinit();
    defer s.db.deinit();

    // t1 is blocked, but a same-column reorder is not a column change.
    const outcome = try useCase(alloc, &s.db, .{
        .item_id = "item_1",
        .workspace_id = "ws_1",
        .task_id = "t1",
        .body = .{ .column_id = "c2", .position = 0 },
    });
    // Both arms are owned JSON — the test allocator counts a leaked response.
    defer freeOutcome(alloc, outcome);

    try testing.expect(std.mem.indexOf(u8, outcome.moved, "\"success\":true") != null);
}

test "tasks_move useCase answers a blocked move with the blockers" {
    const alloc = testing.allocator;
    var s = try setupDb();
    defer s.threaded.deinit();
    defer s.db.deinit();

    const outcome = try useCase(alloc, &s.db, .{
        .item_id = "item_1",
        .workspace_id = "ws_1",
        .task_id = "t1",
        .body = .{ .column_id = "c3", .position = 0 },
    });
    defer freeOutcome(alloc, outcome);

    switch (outcome) {
        .moved => return error.ExpectedBlockedMove,
        .blocked => |json| {
            try testing.expect(std.mem.indexOf(u8, json, "\"error\":\"Task is blocked by incomplete dependency tasks\"") != null);
            try testing.expect(std.mem.indexOf(u8, json, "\"task_id\":\"t2\"") != null);
            try testing.expect(std.mem.indexOf(u8, json, "\"name\":\"Fix login\"") != null);
            try testing.expect(std.mem.indexOf(u8, json, "\"column_id\":\"c1\"") != null);
            try testing.expect(std.mem.indexOf(u8, json, "\"column_name\":\"todo\"") != null);
        },
    }

    // The card did NOT move.
    var q = try s.db.query(alloc, "SELECT kanban_column_id FROM kanban WHERE workspace_item_task_id = 't1'", &.{});
    defer q.deinit();
    const row = (try q.next()) orelse return error.NoAssignment;
    defer row.deinit(alloc);
    try testing.expectEqualStrings("c2", row.values[0]);
}

test "tasks_move useCase force=true lets the human overrule the gate" {
    const alloc = testing.allocator;
    var s = try setupDb();
    defer s.threaded.deinit();
    defer s.db.deinit();

    const outcome = try useCase(alloc, &s.db, .{
        .item_id = "item_1",
        .workspace_id = "ws_1",
        .task_id = "t1",
        .body = .{ .column_id = "c3", .position = 0, .force = true },
    });
    defer freeOutcome(alloc, outcome);

    try testing.expect(std.mem.indexOf(u8, outcome.moved, "\"success\":true") != null);

    var q = try s.db.query(alloc, "SELECT kanban_column_id FROM kanban WHERE workspace_item_task_id = 't1'", &.{});
    defer q.deinit();
    const row = (try q.next()) orelse return error.NoAssignment;
    defer row.deinit(alloc);
    try testing.expectEqualStrings("c3", row.values[0]);
}

test "tasks_move useCase moves freely once the dependency completed" {
    const alloc = testing.allocator;
    var s = try setupDb();
    defer s.threaded.deinit();
    defer s.db.deinit();

    // The dependency reaches the is_done column.
    try s.db.exec(alloc, "UPDATE kanban SET kanban_column_id = 'c3' WHERE workspace_item_task_id = 't2'", &.{});

    const outcome = try useCase(alloc, &s.db, .{
        .item_id = "item_1",
        .workspace_id = "ws_1",
        .task_id = "t1",
        .body = .{ .column_id = "c1", .position = 0 },
    });
    defer freeOutcome(alloc, outcome);

    try testing.expect(std.mem.indexOf(u8, outcome.moved, "\"success\":true") != null);
}
