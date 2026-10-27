//! `GET /api/workspaces/:workspace_id/items/:item_id/routine`. Returns
//! `{routine}` for the routine bound to this workspace_item.

const std = @import("std");
const pabrikcore = @import("pabrikcore");
const test_db = pabrikcore.test_db;
const gserverz = pabrikcore.gserverz;
const http_response = @import("http_response.zig");

/// Wire shape for the routine row in the GET response. Mirrors
/// `src/models/workspace_routine.zig`.
pub const RoutineRow = struct {
    id: []const u8,
    workspace_item_id: []const u8,
    description: []const u8,
    instruction: []const u8,
    schedule: []const u8,
    enabled: bool,
    last_run_at: []const u8,
    next_run_at: []const u8,
    last_status: []const u8,
    last_error: []const u8,
    created_at: []const u8,
    updated_at: []const u8,
};

pub const RoutineGetError = error{
    IdsRequired,
    ItemNotFound,
    ItemNotRoutine,
    /// The item is a routine but has no `workspace_routines` row.
    NotConfigured,
    DatabaseError,
    OutOfMemory,
};

pub const RoutineGetInput = struct {
    workspace_id: []const u8,
    item_id: []const u8,
};

pub const RoutineGetOutput = struct {
    routine: RoutineRow,
};

// =====================================================================
// Use case
// =====================================================================

fn useCase(
    allocator: std.mem.Allocator,
    db: *pabrikcore.database.Db,
    input: RoutineGetInput,
) RoutineGetError!RoutineGetOutput {
    if (input.workspace_id.len == 0 or input.item_id.len == 0) {
        return error.IdsRequired;
    }

    var q = db.query(allocator,
        "SELECT item_type FROM workspace_items WHERE id = ?",
        &[_][]const u8{input.item_id},
    ) catch return error.DatabaseError;
    defer q.deinit();
    const row = (q.next() catch null) orelse return error.ItemNotFound;
    defer row.deinit(allocator);
    if (!std.mem.eql(u8, row.values[0], "routine")) return error.ItemNotRoutine;

    var qr = db.query(allocator,
        \\SELECT id, workspace_item_id, description, instruction, schedule, enabled,
        \\       IFNULL(last_run_at, ''), IFNULL(next_run_at, ''),
        \\       last_status, IFNULL(last_error, ''),
        \\       IFNULL(created_at, ''), IFNULL(updated_at, '')
        \\FROM workspace_routines WHERE id = ?
    , &[_][]const u8{input.item_id}) catch return error.DatabaseError;
    defer qr.deinit();
    const rrow = (qr.next() catch null) orelse return error.NotConfigured;
    defer rrow.deinit(allocator);

    const enabled_int = std.fmt.parseInt(i64, rrow.values[5], 10) catch 0;
    return .{ .routine = .{
        .id = try allocator.dupe(u8, rrow.values[0]),
        .workspace_item_id = try allocator.dupe(u8, rrow.values[1]),
        .description = try allocator.dupe(u8, rrow.values[2]),
        .instruction = try allocator.dupe(u8, rrow.values[3]),
        .schedule = try allocator.dupe(u8, rrow.values[4]),
        .enabled = enabled_int == 1,
        .last_run_at = try allocator.dupe(u8, rrow.values[6]),
        .next_run_at = try allocator.dupe(u8, rrow.values[7]),
        .last_status = try allocator.dupe(u8, rrow.values[8]),
        .last_error = try allocator.dupe(u8, rrow.values[9]),
        .created_at = try allocator.dupe(u8, rrow.values[10]),
        .updated_at = try allocator.dupe(u8, rrow.values[11]),
    } };
}

// =====================================================================
// Handler
// =====================================================================

pub fn workspaceRoutinesGetHandler(
    ctx: gserverz.HttpContext,
    req: gserverz.HttpRequest,
    res: gserverz.HttpResponse,
) !gserverz.HttpResponse {
    const allocator = ctx.allocator;

    const di = try pabrikcore.getSingleton();
    const sqlite_db = di.db;

    const workspace_id = req.params.get("workspace_id") orelse "";
    const item_id = req.params.get("item_id") orelse "";

    const output = useCase(allocator, sqlite_db, .{
        .workspace_id = workspace_id,
        .item_id = item_id,
    }) catch |err| {
        const status: u16 = switch (err) {
            error.IdsRequired, error.ItemNotRoutine => 400,
            error.ItemNotFound, error.NotConfigured => 404,
            error.DatabaseError, error.OutOfMemory => 500,
        };
        const message: []const u8 = switch (err) {
            error.IdsRequired => "workspace_id and item_id required",
            error.ItemNotFound => "workspace_item not found",
            error.ItemNotRoutine => "workspace_item is not a routine",
            error.NotConfigured => "routine not configured",
            error.DatabaseError => "DB error",
            error.OutOfMemory => "Out of memory",
        };
        return res.jsonResponse(.{
            .status_code = status,
            .data = try http_response.makeErrorResponse(allocator, .{ .@"error" = message }),
        });
    };

    const data = try std.json.Stringify.valueAlloc(allocator, .{
        .routine = output.routine,
    }, .{});
    return res.jsonResponse(.{ .status_code = 200, .data = data });
}

// ─── Tests ──────────────────────────────────────────────────────────────

const sqlite = @import("pabrikcore").sqlite;
const database = @import("pabrikcore").database;
const testing = std.testing;
const Migration084ReplaceRoutinesWithWorkspaceRoutines = @import("../migrations/migration.zig").Migration084ReplaceRoutinesWithWorkspaceRoutines;

const TestCtx = struct {
    db: database.Db,
    threaded: std.Io.Threaded,
};

fn setupDb() !TestCtx {
    var threaded = std.Io.Threaded.init(testing.allocator, .{});
    errdefer threaded.deinit();
    const io = threaded.io();
    var db: database.Db = .{};
    errdefer db.deinit();
    try test_db.openMemory(&db, io);

    try db.exec(testing.allocator,
        "CREATE TABLE workspace_items (id TEXT PRIMARY KEY, workspace_id TEXT, item_type TEXT NOT NULL, name TEXT, path TEXT, position INTEGER, created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP, updated_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP)",
        &[_][]const u8{},
    );
    try db.exec(testing.allocator,
        "CREATE TABLE workspace_item_tasks (id TEXT PRIMARY KEY, task_type TEXT NOT NULL DEFAULT 'standard')",
        &[_][]const u8{},
    );
    try Migration084ReplaceRoutinesWithWorkspaceRoutines.up(&db, testing.allocator);

    try db.exec(testing.allocator,
        "INSERT INTO workspace_items (id, workspace_id, item_type, name) VALUES ('ws_item_1', 'ws_1', 'routine', 'Nightly')",
        &[_][]const u8{},
    );
    try db.exec(testing.allocator,
        "INSERT INTO workspace_routines (id, workspace_item_id, instruction, schedule, next_run_at) VALUES ('ws_item_1', 'ws_item_1', 'do things', '0 9 * * *', '2026-01-02 09:00:00')",
        &[_][]const u8{},
    );
    try db.exec(testing.allocator,
        "INSERT INTO workspace_items (id, workspace_id, item_type, name) VALUES ('ws_item_agent', 'ws_1', 'agent', 'An agent')",
        &[_][]const u8{},
    );
    return .{ .db = db, .threaded = threaded };
}

fn freeOutput(allocator: std.mem.Allocator, output: RoutineGetOutput) void {
    allocator.free(output.routine.id);
    allocator.free(output.routine.workspace_item_id);
    allocator.free(output.routine.description);
    allocator.free(output.routine.instruction);
    allocator.free(output.routine.schedule);
    allocator.free(output.routine.last_run_at);
    allocator.free(output.routine.next_run_at);
    allocator.free(output.routine.last_status);
    allocator.free(output.routine.last_error);
    allocator.free(output.routine.created_at);
    allocator.free(output.routine.updated_at);
}

test "useCase: empty ids return IdsRequired" {
    const alloc = testing.allocator;
    var ctx = try setupDb();
    defer ctx.threaded.deinit();
    defer ctx.db.deinit();

    try testing.expectError(
        error.IdsRequired,
        useCase(alloc, &ctx.db, .{ .workspace_id = "", .item_id = "ws_item_1" }),
    );
}

test "useCase: missing item returns ItemNotFound" {
    const alloc = testing.allocator;
    var ctx = try setupDb();
    defer ctx.threaded.deinit();
    defer ctx.db.deinit();

    try testing.expectError(
        error.ItemNotFound,
        useCase(alloc, &ctx.db, .{ .workspace_id = "ws_1", .item_id = "nope" }),
    );
}

test "useCase: non-routine item returns ItemNotRoutine" {
    const alloc = testing.allocator;
    var ctx = try setupDb();
    defer ctx.threaded.deinit();
    defer ctx.db.deinit();

    try testing.expectError(
        error.ItemNotRoutine,
        useCase(alloc, &ctx.db, .{ .workspace_id = "ws_1", .item_id = "ws_item_agent" }),
    );
}

test "useCase: happy path returns routine row" {
    const alloc = testing.allocator;
    var ctx = try setupDb();
    defer ctx.threaded.deinit();
    defer ctx.db.deinit();

    const output = try useCase(alloc, &ctx.db, .{ .workspace_id = "ws_1", .item_id = "ws_item_1" });
    defer freeOutput(alloc, output);

    try testing.expectEqualStrings("ws_item_1", output.routine.id);
    try testing.expectEqualStrings("do things", output.routine.instruction);
    try testing.expectEqualStrings("0 9 * * *", output.routine.schedule);
    try testing.expect(output.routine.enabled);
    try testing.expectEqualStrings("2026-01-02 09:00:00", output.routine.next_run_at);
}
