//! `PATCH /api/workspaces/:workspace_id/items/:item_id/routine`. Body:
//! `{description?, instruction?, schedule?, enabled?}` — all optional (absent
//! = keep existing).

const std = @import("std");
const pabrikcore = @import("pabrikcore");
const test_db = pabrikcore.test_db;
const gserverz = pabrikcore.gserverz;
const http_response = @import("http_response.zig");
const helpers = @import("helpers");
const cron = @import("../ai_workflow/tui/routines/cron.zig");
const fire = @import("../ai_workflow/tui/routines/fire.zig");
const get_mod = @import("workspace_routines_get.zig");

/// PATCH body — every field optional. `null` = field absent (keep
/// existing); a present-but-empty `schedule` clears auto-fire.
const UpdateRoutineBody = struct {
    description: ?[]const u8 = null,
    instruction: ?[]const u8 = null,
    schedule: ?[]const u8 = null,
    enabled: ?bool = null,
};

pub const RoutineUpdateError = error{
    IdsRequired,
    LookupFailed,
    ItemNotFound,
    NotARoutine,
    NotConfigured,
    InvalidSchedule,
    FailedToComputeNextFireTime,
    UpdateFailed,
    RefetchFailed,
    RowVanished,
    OutOfMemory,
};

pub const RoutineUpdateInput = struct {
    workspace_id: []const u8,
    item_id: []const u8,
    body: UpdateRoutineBody,
};

pub const RoutineUpdateOutput = struct {
    routine: get_mod.RoutineRow,
};

// =====================================================================
// Use case
// =====================================================================

fn useCase(
    allocator: std.mem.Allocator,
    db: *pabrikcore.database.Db,
    input: RoutineUpdateInput,
) RoutineUpdateError!RoutineUpdateOutput {
    if (input.workspace_id.len == 0 or input.item_id.len == 0) {
        return error.IdsRequired;
    }

    var q = db.query(allocator,
        "SELECT item_type FROM workspace_items WHERE id = ?",
        &[_][]const u8{input.item_id},
    ) catch return error.LookupFailed;
    defer q.deinit();
    const row = (q.next() catch null) orelse return error.ItemNotFound;
    defer row.deinit(allocator);
    if (!std.mem.eql(u8, row.values[0], "routine")) return error.NotARoutine;

    // Load existing values so absent fields keep their current state
    // (effective_* pattern from the deleted task_update routine branch).
    var qr = db.query(allocator,
        "SELECT description, instruction, schedule, enabled FROM workspace_routines WHERE id = ?",
        &[_][]const u8{input.item_id},
    ) catch return error.LookupFailed;
    defer qr.deinit();
    const erow = (qr.next() catch null) orelse return error.NotConfigured;
    defer erow.deinit(allocator);

    const existing_description = try allocator.dupe(u8, erow.values[0]);
    defer allocator.free(existing_description);
    const existing_instruction = try allocator.dupe(u8, erow.values[1]);
    defer allocator.free(existing_instruction);
    const existing_schedule = try allocator.dupe(u8, erow.values[2]);
    defer allocator.free(existing_schedule);
    const existing_enabled_int = std.fmt.parseInt(i64, erow.values[3], 10) catch 0;
    const existing_enabled = existing_enabled_int == 1;

    const effective_description = input.body.description orelse existing_description;
    const effective_instruction = input.body.instruction orelse existing_instruction;
    const effective_schedule = std.mem.trim(u8, input.body.schedule orelse existing_schedule, " \t\n\r");
    const effective_enabled = input.body.enabled orelse existing_enabled;

    if (effective_schedule.len > 0) {
        cron.validate(effective_schedule) catch return error.InvalidSchedule;
    }

    // Recompute next_run_at from the EFFECTIVE schedule/enabled so a
    // schedule edit, a clear (`""`), or a disable all land correctly.
    var next_run_at: []const u8 = "";
    var next_run_at_owned: ?[]u8 = null;
    defer if (next_run_at_owned) |b| allocator.free(b);
    if (effective_schedule.len > 0 and effective_enabled) {
        const now_ns = helpers.unixTimestampNanos();
        const next_ns = cron.nextFireTime(effective_schedule, now_ns) catch return error.FailedToComputeNextFireTime;
        next_run_at_owned = fire.formatSqliteDatetime(allocator, next_ns) catch return error.OutOfMemory;
        next_run_at = next_run_at_owned.?;
    }

    const enabled_str: []const u8 = if (effective_enabled) "1" else "0";
    db.exec(allocator,
        \\UPDATE workspace_routines
        \\   SET description = COALESCE(NULLIF(?, ''), ''),
        \\       instruction = COALESCE(NULLIF(?, ''), ''),
        \\       schedule = COALESCE(NULLIF(?, ''), ''),
        \\       enabled = ?,
        \\       next_run_at = ?,
        \\       updated_at = datetime('now')
        \\ WHERE id = ?
    ,
        &.{ effective_description, effective_instruction, effective_schedule, enabled_str, next_run_at, input.item_id },
    ) catch return error.UpdateFailed;

    // Refetch via the GET use-case's row shape. The GET module's
    // useCase is private, so re-run the same SELECT here.
    var q2 = db.query(allocator,
        \\SELECT id, workspace_item_id, description, instruction, schedule, enabled,
        \\       COALESCE(CAST(last_run_at AS TEXT), ''), COALESCE(CAST(next_run_at AS TEXT), ''),
        \\       last_status, COALESCE(CAST(last_error AS TEXT), ''),
        \\       COALESCE(CAST(created_at AS TEXT), ''), COALESCE(CAST(updated_at AS TEXT), '')
        \\FROM workspace_routines WHERE id = ?
    , &[_][]const u8{input.item_id}) catch return error.RefetchFailed;
    defer q2.deinit();
    const urow = (q2.next() catch null) orelse return error.RowVanished;
    defer urow.deinit(allocator);

    const enabled_int = std.fmt.parseInt(i64, urow.values[5], 10) catch 0;
    return .{ .routine = .{
        .id = try allocator.dupe(u8, urow.values[0]),
        .workspace_item_id = try allocator.dupe(u8, urow.values[1]),
        .description = try allocator.dupe(u8, urow.values[2]),
        .instruction = try allocator.dupe(u8, urow.values[3]),
        .schedule = try allocator.dupe(u8, urow.values[4]),
        .enabled = enabled_int == 1,
        .last_run_at = try allocator.dupe(u8, urow.values[6]),
        .next_run_at = try allocator.dupe(u8, urow.values[7]),
        .last_status = try allocator.dupe(u8, urow.values[8]),
        .last_error = try allocator.dupe(u8, urow.values[9]),
        .created_at = try allocator.dupe(u8, urow.values[10]),
        .updated_at = try allocator.dupe(u8, urow.values[11]),
    } };
}

// =====================================================================
// Handler
// =====================================================================

pub fn workspaceRoutinesUpdateHandler(
    ctx: gserverz.HttpContext,
    req: gserverz.HttpRequest,
    res: gserverz.HttpResponse,
) !gserverz.HttpResponse {
    const allocator = ctx.allocator;

    const di = try pabrikcore.getSingleton();
    const sqlite_db = di.db;

    const workspace_id = req.params.get("workspace_id") orelse "";
    const item_id = req.params.get("item_id") orelse "";

    if (req.body.len == 0) {
        return res.jsonResponse(.{
            .status_code = 400,
            .data = try http_response.makeErrorResponse(allocator, .{ .@"error" = "Request body required" }),
        });
    }
    const parsed = std.json.parseFromSliceLeaky(UpdateRoutineBody, allocator, req.body, .{}) catch {
        return res.jsonResponse(.{
            .status_code = 400,
            .data = try http_response.makeErrorResponse(allocator, .{ .@"error" = "Invalid JSON body" }),
        });
    };

    const output = useCase(allocator, sqlite_db, .{
        .workspace_id = workspace_id,
        .item_id = item_id,
        .body = parsed,
    }) catch |err| {
        const status: u16 = switch (err) {
            error.IdsRequired, error.NotARoutine, error.InvalidSchedule => 400,
            error.ItemNotFound, error.NotConfigured => 404,
            error.LookupFailed, error.UpdateFailed, error.RefetchFailed,
            error.RowVanished, error.FailedToComputeNextFireTime,
            error.OutOfMemory => 500,
        };
        const message: []const u8 = switch (err) {
            error.IdsRequired => "workspace_id and item_id required",
            error.LookupFailed => "DB lookup failed",
            error.ItemNotFound => "workspace_item not found",
            error.NotARoutine => "workspace_item is not a routine",
            error.NotConfigured => "routine not configured",
            error.InvalidSchedule => "schedule is not a valid cron expression",
            error.FailedToComputeNextFireTime => "failed to compute next fire time",
            error.UpdateFailed => "failed to update routine",
            error.RefetchFailed => "failed to refetch routine",
            error.RowVanished => "routine vanished after update",
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
    return .{ .db = db, .threaded = threaded };
}

fn freeOutput(allocator: std.mem.Allocator, output: RoutineUpdateOutput) void {
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

test "update routine: instruction patch keeps schedule" {
    const alloc = testing.allocator;
    var ctx = try setupDb();
    defer ctx.threaded.deinit();
    defer ctx.db.deinit();

    const output = try useCase(alloc, &ctx.db, .{
        .workspace_id = "ws_1",
        .item_id = "ws_item_1",
        .body = .{ .instruction = "do other things" },
    });
    defer freeOutput(alloc, output);

    try testing.expectEqualStrings("do other things", output.routine.instruction);
    try testing.expectEqualStrings("0 9 * * *", output.routine.schedule);
    try testing.expect(output.routine.next_run_at.len > 0);
}

test "update routine: schedule change recomputes next_run_at" {
    const alloc = testing.allocator;
    var ctx = try setupDb();
    defer ctx.threaded.deinit();
    defer ctx.db.deinit();

    const output = try useCase(alloc, &ctx.db, .{
        .workspace_id = "ws_1",
        .item_id = "ws_item_1",
        .body = .{ .schedule = "*/5 * * * *" },
    });
    defer freeOutput(alloc, output);

    try testing.expectEqualStrings("*/5 * * * *", output.routine.schedule);
    try testing.expect(output.routine.next_run_at.len > 0);
}

test "update routine: clearing schedule nulls next_run_at" {
    const alloc = testing.allocator;
    var ctx = try setupDb();
    defer ctx.threaded.deinit();
    defer ctx.db.deinit();

    const output = try useCase(alloc, &ctx.db, .{
        .workspace_id = "ws_1",
        .item_id = "ws_item_1",
        .body = .{ .schedule = "" },
    });
    defer freeOutput(alloc, output);

    try testing.expectEqualStrings("", output.routine.schedule);
    try testing.expectEqualStrings("", output.routine.next_run_at);
}

test "update routine: disable nulls next_run_at" {
    const alloc = testing.allocator;
    var ctx = try setupDb();
    defer ctx.threaded.deinit();
    defer ctx.db.deinit();

    const output = try useCase(alloc, &ctx.db, .{
        .workspace_id = "ws_1",
        .item_id = "ws_item_1",
        .body = .{ .enabled = false },
    });
    defer freeOutput(alloc, output);

    try testing.expect(!output.routine.enabled);
    try testing.expectEqualStrings("", output.routine.next_run_at);
}

test "update routine: invalid schedule returns InvalidSchedule" {
    const alloc = testing.allocator;
    var ctx = try setupDb();
    defer ctx.threaded.deinit();
    defer ctx.db.deinit();

    try testing.expectError(
        error.InvalidSchedule,
        useCase(alloc, &ctx.db, .{
            .workspace_id = "ws_1",
            .item_id = "ws_item_1",
            .body = .{ .schedule = "bogus" },
        }),
    );
}
