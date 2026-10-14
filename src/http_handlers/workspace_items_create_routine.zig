//! `POST /api/workspaces/:workspace_id/items/routine`.

const std = @import("std");
const pabrikcore = @import("pabrikcore");
const gserverz = pabrikcore.gserverz;
const http_response = @import("http_response.zig");
const helpers = @import("helpers");
const cron = @import("../ai_workflow/tui/routines/cron.zig");
const fire = @import("../ai_workflow/tui/routines/fire.zig");

/// Request body for the routine-item create endpoint. `name` + `path`
/// required; the rest optional.
const CreateRoutineBody = struct {
    name: []const u8,
    path: []const u8,
    description: []const u8 = "",
    instruction: []const u8 = "",
    schedule: []const u8 = "",
    enabled: bool = true,
};

/// Response item — mirrors `CreateAgentItemResponse` with
/// `item_type = "routine"`.
pub const CreateRoutineItemResponse = struct {
    id: []const u8,
    workspace_id: []const u8,
    item_type: []const u8, // always "routine"
    name: []const u8,
    path: ?[]const u8 = null,
    position: i64,
};

/// Response routine row. Mirrors `src/models/workspace_routine.zig`.
pub const CreateRoutineRoutineResponse = struct {
    id: []const u8,
    workspace_item_id: []const u8,
    description: []const u8,
    instruction: []const u8,
    schedule: []const u8,
    enabled: bool,
    next_run_at: []const u8, // "" = manual-run only
    created_at: []const u8,
    updated_at: []const u8,
};

/// Wire envelope: `{item, routine}`.
pub const CreateRoutineResponseFull = struct {
    item: CreateRoutineItemResponse,
    routine: CreateRoutineRoutineResponse,
};

pub const WorkspaceItemsCreateRoutineError = error{
    WorkspaceIdRequired,
    MissingBody,
    InvalidJson,
    NameRequired,
    PathRequired,
    EmptyName,
    InvalidSchedule,
    FailedToComputeNextFireTime,
    OutOfMemory,
    DatabaseError,
};

pub const WorkspaceItemsCreateRoutineInput = struct {
    workspace_id: []const u8,
    body: CreateRoutineBody,
};

pub const WorkspaceItemsCreateRoutineResult = []const u8; // pre-serialized JSON

// =====================================================================
// Use case
// =====================================================================

fn useCase(
    allocator: std.mem.Allocator,
    db: *pabrikcore.sqlite.SqliteBackend,
    input: WorkspaceItemsCreateRoutineInput,
) WorkspaceItemsCreateRoutineError!WorkspaceItemsCreateRoutineResult {
    if (input.workspace_id.len == 0) return error.WorkspaceIdRequired;

    const trimmed_name = std.mem.trim(u8, input.body.name, " \t\n\r");
    if (trimmed_name.len == 0) return error.EmptyName;
    if (input.body.path.len == 0) return error.PathRequired;

    // Validate the cron expression when one is given. Empty schedule =
    // manual-run only (no validation, next_run_at stays NULL).
    const trimmed_schedule = std.mem.trim(u8, input.body.schedule, " \t\n\r");
    if (trimmed_schedule.len > 0) {
        cron.validate(trimmed_schedule) catch return error.InvalidSchedule;
    }

    // Compute next_run_at when scheduled + enabled. Empty schedule or
    // disabled → NULL (bound as "" — SqliteBackend.exec binds empty
    // slices as SQL NULL).
    var next_run_at: []const u8 = "";
    // Owned only when computed; freed below after the INSERT dupes it
    // via bind (exec copies bind values during the call).
    var next_run_at_owned: ?[]u8 = null;
    defer if (next_run_at_owned) |b| allocator.free(b);
    if (trimmed_schedule.len > 0 and input.body.enabled) {
        const now_ns = helpers.unixTimestampNanos();
        const next_ns = cron.nextFireTime(trimmed_schedule, now_ns) catch return error.FailedToComputeNextFireTime;
        next_run_at_owned = fire.formatSqliteDatetime(allocator, next_ns) catch return error.OutOfMemory;
        next_run_at = next_run_at_owned.?;
    }

    const timestamp_ns = helpers.unixTimestampNanos();
    const item_id = try std.fmt.allocPrint(allocator, "item_{d}", .{timestamp_ns});
    errdefer allocator.free(item_id);

    // tx so the 3 INSERTs are atomic (same rationale as the
    // agent create — a crash mid-flow must not leave a
    // workspace_items row without its routine siblings).
    var tx = db.begin() catch return error.DatabaseError;
    defer tx.commitOrRollback() catch {};
    errdefer tx.rollback() catch {};

    tx.exec(allocator,
        "INSERT INTO workspace_items (id, workspace_id, item_type, name, path, position, created_at, updated_at) VALUES (?, ?, 'routine', ?, NULLIF(?, ''), COALESCE((SELECT MAX(position) FROM workspace_items WHERE workspace_id = ?), -1) + 1, datetime('now'), datetime('now'))",
        &.{ item_id, input.workspace_id, trimmed_name, input.body.path, input.workspace_id },
    ) catch return error.DatabaseError;

    // COALESCE(NULLIF(?, ''), '') guards the NOT NULL DEFAULT '' columns:
    // SqliteBackend.exec binds empty slices as SQL NULL, which would violate
    // the constraint (see memory `sqlite-backend-empty-slice-binds-as-null`).
    const enabled_str: []const u8 = if (input.body.enabled) "1" else "0";
    tx.exec(allocator,
        \\INSERT INTO workspace_routines (id, workspace_item_id, description, instruction, schedule, enabled, next_run_at)
        \\VALUES (?, ?, COALESCE(NULLIF(?, ''), ''), COALESCE(NULLIF(?, ''), ''), COALESCE(NULLIF(?, ''), ''), ?, ?)
    ,
        &.{ item_id, item_id, input.body.description, input.body.instruction, trimmed_schedule, enabled_str, next_run_at },
    ) catch return error.DatabaseError;

    // Seed the agent_routines config row so the RoutineView Agent tab works
    // immediately (mirrors the agent_kanbans seed in
    // workspace_items_create_kanban.zig).
    tx.exec(allocator,
        "INSERT OR IGNORE INTO agent_routines (id, workspace_item_id) VALUES (?, ?)",
        &.{ item_id, item_id },
    ) catch return error.DatabaseError;

    tx.commit() catch return error.DatabaseError;

    const position = readInsertedPosition(allocator, db, item_id);

    const json = try std.json.Stringify.valueAlloc(allocator, CreateRoutineResponseFull{
        .item = .{
            .id = item_id,
            .workspace_id = input.workspace_id,
            .item_type = "routine",
            .name = trimmed_name,
            .path = input.body.path,
            .position = position,
        },
        .routine = .{
            .id = item_id,
            .workspace_item_id = item_id,
            .description = input.body.description,
            .instruction = input.body.instruction,
            .schedule = trimmed_schedule,
            .enabled = input.body.enabled,
            .next_run_at = next_run_at,
            .created_at = "",
            .updated_at = "",
        },
    }, .{});
    allocator.free(item_id);
    return json;
}

/// Re-read the `position` of a freshly-INSERTed workspace_item
/// (mirrors `workspace_items_create_agent.zig::readInsertedPosition`).
fn readInsertedPosition(
    allocator: std.mem.Allocator,
    db: *pabrikcore.sqlite.SqliteBackend,
    item_id: []const u8,
) i64 {
    var q = db.query(allocator,
        "SELECT position FROM workspace_items WHERE id = ?",
        &.{item_id},
    ) catch return 0;
    defer q.deinit();
    if (q.next() catch null) |row| {
        defer row.deinit(allocator);
        return std.fmt.parseInt(i64, row.values[0], 10) catch 0;
    }
    return 0;
}

// =====================================================================
// Handler
// =====================================================================

pub fn workspaceItemsCreateRoutineHandler(
    ctx: gserverz.HttpContext,
    req: gserverz.HttpRequest,
    res: gserverz.HttpResponse,
) !gserverz.HttpResponse {
    const allocator = ctx.allocator;

    const di = try pabrikcore.getSingleton();
    const sqlite_db = di.db;

    const workspace_id = req.params.get("workspace_id") orelse "";
    if (workspace_id.len == 0) {
        return res.jsonResponse(.{
            .status_code = 400,
            .data = try http_response.makeErrorResponse(allocator, .{ .@"error" = "workspace_id required" }),
        });
    }

    if (req.body.len == 0) {
        return res.jsonResponse(.{
            .status_code = 400,
            .data = try http_response.makeErrorResponse(allocator, .{ .@"error" = "Request body required" }),
        });
    }

    const parsed = std.json.parseFromSliceLeaky(CreateRoutineBody, allocator, req.body, .{}) catch {
        return res.jsonResponse(.{
            .status_code = 400,
            .data = try http_response.makeErrorResponse(allocator, .{ .@"error" = "Invalid JSON body" }),
        });
    };

    if (parsed.name.len == 0) {
        return res.jsonResponse(.{
            .status_code = 400,
            .data = try http_response.makeErrorResponse(allocator, .{ .@"error" = "name is required" }),
        });
    }
    if (std.mem.trim(u8, parsed.name, " \t\n\r").len == 0) {
        return res.jsonResponse(.{
            .status_code = 400,
            .data = try http_response.makeErrorResponse(allocator, .{ .@"error" = "name is required" }),
        });
    }
    if (parsed.path.len == 0) {
        return res.jsonResponse(.{
            .status_code = 400,
            .data = try http_response.makeErrorResponse(allocator, .{ .@"error" = "path is required" }),
        });
    }

    const data = useCase(allocator, sqlite_db, .{
        .workspace_id = workspace_id,
        .body = parsed,
    }) catch |err| {
        const status: u16 = switch (err) {
            error.WorkspaceIdRequired, error.MissingBody, error.InvalidJson,
            error.NameRequired, error.PathRequired, error.EmptyName,
            error.InvalidSchedule => 400,
            error.FailedToComputeNextFireTime, error.DatabaseError,
            error.OutOfMemory => 500,
        };
        const message: []const u8 = switch (err) {
            error.WorkspaceIdRequired => "workspace_id required",
            error.MissingBody => "Request body required",
            error.InvalidJson => "Invalid JSON body",
            error.NameRequired, error.EmptyName => "name is required",
            error.PathRequired => "path is required",
            error.InvalidSchedule => "schedule is not a valid cron expression",
            error.FailedToComputeNextFireTime => "failed to compute next fire time",
            error.DatabaseError => "Failed to create routine item",
            error.OutOfMemory => "Out of memory",
        };
        return res.jsonResponse(.{
            .status_code = status,
            .data = try http_response.makeErrorResponse(allocator, .{ .@"error" = message }),
        });
    };

    return res.jsonResponse(.{
        .status_code = 201,
        .data = data,
    });
}

// ─── Tests ──────────────────────────────────────────────────────────────

const sqlite = @import("pabrikcore").sqlite;
const testing = std.testing;
const Migration084ReplaceRoutinesWithWorkspaceRoutines = @import("../migrations/migration.zig").Migration084ReplaceRoutinesWithWorkspaceRoutines;
const Migration087CreateAgentRoutines = @import("../migrations/migration.zig").Migration087CreateAgentRoutines;

const TestCtx = struct {
    db: sqlite.SqliteBackend,
    threaded: std.Io.Threaded,
};

fn setupDb() !TestCtx {
    var threaded = std.Io.Threaded.init(testing.allocator, .{});
    errdefer threaded.deinit();
    const io = threaded.io();
    var db: sqlite.SqliteBackend = .{};
    errdefer db.deinit();
    try db.init(io, ":memory:");

    try db.exec(testing.allocator,
        "CREATE TABLE workspace_items (id TEXT PRIMARY KEY, workspace_id TEXT, item_type TEXT NOT NULL, name TEXT, path TEXT, position INTEGER, created_at DATETIME DEFAULT CURRENT_TIMESTAMP, updated_at DATETIME DEFAULT CURRENT_TIMESTAMP)",
        &[_][]const u8{},
    );
    try db.exec(testing.allocator,
        "CREATE TABLE workspace_item_tasks (id TEXT PRIMARY KEY, task_type TEXT NOT NULL DEFAULT 'standard')",
        &[_][]const u8{},
    );
    try Migration084ReplaceRoutinesWithWorkspaceRoutines.up(&db, testing.allocator);
    try Migration087CreateAgentRoutines.up(&db, testing.allocator);
    return .{ .db = db, .threaded = threaded };
}

test "create routine: happy path inserts item + routine with next_run_at" {
    const alloc = testing.allocator;
    var ctx = try setupDb();
    defer ctx.threaded.deinit();
    defer ctx.db.deinit();

    const json = try useCase(alloc, &ctx.db, .{
        .workspace_id = "ws_1",
        .body = .{ .name = "Nightly", .path = "/tmp/x", .instruction = "do things", .schedule = "0 9 * * *" },
    });
    defer alloc.free(json);

    // Item row exists with item_type='routine'.
    {
        var q = try ctx.db.query(alloc, "SELECT item_type, name FROM workspace_items", &.{});
        defer q.deinit();
        const row = (try q.next()) orelse return error.RowMissing;
        defer row.deinit(alloc);
        try testing.expectEqualStrings("routine", row.values[0]);
        try testing.expectEqualStrings("Nightly", row.values[1]);
    }
    // Routine row carries instruction + schedule + computed next_run_at.
    {
        var q = try ctx.db.query(alloc, "SELECT instruction, schedule, enabled, next_run_at FROM workspace_routines", &.{});
        defer q.deinit();
        const row = (try q.next()) orelse return error.RowMissing;
        defer row.deinit(alloc);
        try testing.expectEqualStrings("do things", row.values[0]);
        try testing.expectEqualStrings("0 9 * * *", row.values[1]);
        try testing.expectEqualStrings("1", row.values[2]);
        try testing.expect(row.values[3].len > 0);
    }
    // Agent-config row seeded in-txn (Migration 087) with no default tools.
    {
        var q = try ctx.db.query(alloc, "SELECT COUNT(*) FROM agent_routines", &.{});
        defer q.deinit();
        const row = (try q.next()) orelse return error.RowMissing;
        defer row.deinit(alloc);
        try testing.expectEqualStrings("1", row.values[0]);
    }
    {
        var q = try ctx.db.query(alloc, "SELECT COUNT(*) FROM agent_routine_tools", &.{});
        defer q.deinit();
        const row = (try q.next()) orelse return error.RowMissing;
        defer row.deinit(alloc);
        try testing.expectEqualStrings("0", row.values[0]);
    }
}

test "create routine: invalid schedule returns InvalidSchedule" {
    const alloc = testing.allocator;
    var ctx = try setupDb();
    defer ctx.threaded.deinit();
    defer ctx.db.deinit();

    try testing.expectError(
        error.InvalidSchedule,
        useCase(alloc, &ctx.db, .{
            .workspace_id = "ws_1",
            .body = .{ .name = "Bad", .path = "/tmp/x", .schedule = "not a cron" },
        }),
    );
}

test "create routine: empty schedule stores NULL next_run_at" {
    const alloc = testing.allocator;
    var ctx = try setupDb();
    defer ctx.threaded.deinit();
    defer ctx.db.deinit();

    const json = try useCase(alloc, &ctx.db, .{
        .workspace_id = "ws_1",
        .body = .{ .name = "Manual", .path = "/tmp/x" },
    });
    defer alloc.free(json);

    var q = try ctx.db.query(alloc, "SELECT next_run_at FROM workspace_routines", &.{});
    defer q.deinit();
    const row = (try q.next()) orelse return error.RowMissing;
    defer row.deinit(alloc);
    // NULL arrives as "" in the Row API.
    try testing.expectEqualStrings("", row.values[0]);
}

test "create routine: empty name returns EmptyName" {
    const alloc = testing.allocator;
    var ctx = try setupDb();
    defer ctx.threaded.deinit();
    defer ctx.db.deinit();

    try testing.expectError(
        error.EmptyName,
        useCase(alloc, &ctx.db, .{
            .workspace_id = "ws_1",
            .body = .{ .name = "   ", .path = "/tmp/x" },
        }),
    );
}
