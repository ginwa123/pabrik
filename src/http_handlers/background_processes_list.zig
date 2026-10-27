//! `GET /api/llm/session/:session_id/background_processes` — list all
//! background processes (`command background=true` rows) for a session.

const std = @import("std");
const http_response = @import("http_response.zig");
const pabrikcore = @import("pabrikcore");
const gserverz = pabrikcore.gserverz;
const process_status = @import("helpers").process_status;

pub const BackgroundProcessesListError = error{
    MissingSessionId,
    QueryFailed,
    /// `allocator.dupe` returned no memory. In production the per-request
    /// arena makes this unreachable but the type system requires the variant
    /// so `try allocator.dupe` propagates a typed error.
    OutOfMemory,
};

pub const BackgroundProcessEntry = struct {
    pid: u32,
    command: []const u8,
    log_path: []const u8,
    started_at: i64,
    status: []const u8,
    running: bool,
};

pub const BackgroundProcessesListResponse = struct {
    processes: []BackgroundProcessEntry,
    count: usize,
};

pub const BackgroundProcessesListResult = []const u8; // pre-serialized JSON

// =====================================================================
// Use case
// =====================================================================

pub fn useCase(
    allocator: std.mem.Allocator,
    db: *pabrikcore.database.Db,
    session_id: []const u8,
) BackgroundProcessesListError!BackgroundProcessesListResult {
    if (session_id.len == 0) return error.MissingSessionId;

    var rows = db.query(
        allocator,
        "SELECT pid, command, log_path, started_at, status FROM session_background_process WHERE session_id = ? ORDER BY started_at ASC",
        &.{session_id},
    ) catch return error.QueryFailed;
    defer rows.deinit();

    var processes = std.ArrayList(BackgroundProcessEntry).empty;
    errdefer processes.deinit(allocator);

    while (true) {
        const row_opt = rows.next() catch return error.QueryFailed;
        const row = row_opt orelse break;
        defer row.deinit(allocator);

        const pid = std.fmt.parseInt(u32, row.values[0], 10) catch continue;
        const started_at = std.fmt.parseInt(i64, row.values[3], 10) catch continue;

        // Live-ness is the OS truth, not the status column. PIDs above
        // i32 range can never be alive (and @intCast would panic), so
        // short-circuit them to false.
        const running: bool = if (pid > std.math.maxInt(i32))
            false
        else
            process_status.isProcessRunning(@intCast(pid));

        try processes.append(allocator, .{
            .pid = pid,
            .command = try allocator.dupe(u8, row.values[1]),
            .log_path = try allocator.dupe(u8, row.values[2]),
            .started_at = started_at,
            .status = try allocator.dupe(u8, row.values[4]),
            .running = running,
        });
    }

    const owned = try processes.toOwnedSlice(allocator);
    // The JSON body deep-copies every slice, so the duped intermediates are
    // freed here — they must NOT outlive the call (under testing.allocator
    // they would report as leaks; under the per-request arena the frees are
    defer {
        for (owned) |p| {
            allocator.free(p.command);
            allocator.free(p.log_path);
            allocator.free(p.status);
        }
        allocator.free(owned);
    }
    const response = BackgroundProcessesListResponse{
        .processes = owned,
        .count = owned.len,
    };
    return try std.json.Stringify.valueAlloc(allocator, response, .{});
}

// =====================================================================
// Handler
// =====================================================================

pub fn backgroundProcessesListHandler(
    ctx: gserverz.HttpContext,
    req: gserverz.HttpRequest,
    res: gserverz.HttpResponse,
) !gserverz.HttpResponse {
    const allocator = ctx.allocator;

    const session_id = req.params.get("session_id") orelse {
        return res.jsonResponse(.{
            .status_code = 400,
            .data = try http_response.makeErrorResponse(allocator, .{ .@"error" = "Missing session_id" }),
        });
    };
    if (session_id.len == 0) {
        return res.jsonResponse(.{
            .status_code = 400,
            .data = try http_response.makeErrorResponse(allocator, .{ .@"error" = "Missing session_id" }),
        });
    }

    const di = pabrikcore.getSingleton() catch {
        return res.jsonResponse(.{
            .status_code = 500,
            .data = try http_response.makeErrorResponse(allocator, .{ .@"error" = "Server not initialized" }),
        });
    };

    const json_str = useCase(allocator, di.db, session_id) catch |err| {
        const status: u16 = switch (err) {
            error.MissingSessionId => 400,
            error.QueryFailed => 500,
            error.OutOfMemory => 500,
        };
        const message: []const u8 = switch (err) {
            error.MissingSessionId => "Missing session_id",
            error.QueryFailed => "Database query failed",
            error.OutOfMemory => "Out of memory",
        };
        return res.jsonResponse(.{
            .status_code = status,
            .data = try http_response.makeErrorResponse(allocator, .{ .@"error" = message }),
        });
    };

    return res.jsonResponse(.{ .status_code = 200, .data = json_str });
}

// =====================================================================
// Inline tests (project convention — useCase directly against an in-memory DB
// walked through ALL migrations, never hand-rolled CREATE TABLE bodies).

const testing = std.testing;
const migration = @import("../migrations/migration.zig");

const TestCtx = struct {
    db: pabrikcore.database.Db,
    threaded: std.Io.Threaded,
};

fn setupDb() !TestCtx {
    var threaded = std.Io.Threaded.init(testing.allocator, .{});
    errdefer threaded.deinit();
    const io = threaded.io();

    var db: pabrikcore.database.Db = .{};
    errdefer db.deinit();
    try db.init(io, ":memory:");

    var manager = migration.MigrationManager.init(testing.allocator, &db);
    defer manager.deinit();
    try migration.registerAllMigrations(&manager);
    try manager.runMigrations();

    return .{ .db = db, .threaded = threaded };
}

fn teardownDb(ctx: *TestCtx) void {
    ctx.db.deinit();
    ctx.threaded.deinit();
}

fn insertBgRow(
    db: *pabrikcore.database.Db,
    session_id: []const u8,
    pid: u32,
    command: []const u8,
    log_path: []const u8,
    started_at: i64,
    status: []const u8,
) !void {
    const alloc = testing.allocator;
    const pid_str = try std.fmt.allocPrint(alloc, "{d}", .{pid});
    defer alloc.free(pid_str);
    const started_at_str = try std.fmt.allocPrint(alloc, "{d}", .{started_at});
    defer alloc.free(started_at_str);
    try db.exec(alloc,
        \\INSERT INTO session_background_process (session_id, pid, command, log_path, started_at, status)
        \\VALUES (?, ?, ?, ?, ?, ?)
    , &.{ session_id, pid_str, command, log_path, started_at_str, status });
}

test "useCase returns empty list with count 0 for a session with no rows" {
    var ctx = try setupDb();
    defer teardownDb(&ctx);

    const json = try useCase(testing.allocator, &ctx.db, "sess_empty_001");
    defer testing.allocator.free(json);

    const parsed = try std.json.parseFromSlice(BackgroundProcessesListResponse, testing.allocator, json, .{});
    defer parsed.deinit();
    try testing.expectEqual(@as(usize, 0), parsed.value.count);
    try testing.expectEqual(@as(usize, 0), parsed.value.processes.len);
}

test "useCase rejects an empty session_id" {
    var ctx = try setupDb();
    defer teardownDb(&ctx);

    const result = useCase(testing.allocator, &ctx.db, "");
    try testing.expectError(error.MissingSessionId, result);
}

test "useCase returns rows with live running=false for a dead PID" {
    var ctx = try setupDb();
    defer teardownDb(&ctx);

    // 999999999 exceeds Linux's max PID so kill(pid, 0) -> ESRCH ->
    // isProcessRunning == false (same precedent as
    // background_command_completion_test.py's DEAD_PID).
    try insertBgRow(&ctx.db, "sess_dead_001", 999999999, "sleep 10", "/tmp/bg-dead.log", 1700000000, "running");

    const json = try useCase(testing.allocator, &ctx.db, "sess_dead_001");
    defer testing.allocator.free(json);

    const parsed = try std.json.parseFromSlice(BackgroundProcessesListResponse, testing.allocator, json, .{});
    defer parsed.deinit();
    try testing.expectEqual(@as(usize, 1), parsed.value.count);
    const p = parsed.value.processes[0];
    try testing.expectEqual(@as(u32, 999999999), p.pid);
    try testing.expectEqualStrings("sleep 10", p.command);
    try testing.expectEqualStrings("/tmp/bg-dead.log", p.log_path);
    try testing.expectEqual(@as(i64, 1700000000), p.started_at);
    try testing.expectEqualStrings("running", p.status);
    try testing.expectEqual(false, p.running);
}

test "useCase reports running=true for the current process PID" {
    var ctx = try setupDb();
    defer teardownDb(&ctx);

    const self_pid: u32 = @intCast(process_status.getCurrentProcessIdInt());
    try insertBgRow(&ctx.db, "sess_self_001", self_pid, "test-proc", "/tmp/bg-self.log", 1700000001, "running");

    const json = try useCase(testing.allocator, &ctx.db, "sess_self_001");
    defer testing.allocator.free(json);

    const parsed = try std.json.parseFromSlice(BackgroundProcessesListResponse, testing.allocator, json, .{});
    defer parsed.deinit();
    try testing.expectEqual(@as(usize, 1), parsed.value.count);
    try testing.expectEqual(true, parsed.value.processes[0].running);
}

test "useCase does not trust the status column (stale running row for dead PID)" {
    var ctx = try setupDb();
    defer teardownDb(&ctx);

    // Row claims 'completed' but the PID is alive (self) -> running=true.
    const self_pid: u32 = @intCast(process_status.getCurrentProcessIdInt());
    try insertBgRow(&ctx.db, "sess_stale_001", self_pid, "stale-cmd", "/tmp/bg-stale.log", 1700000002, "completed");

    const json = try useCase(testing.allocator, &ctx.db, "sess_stale_001");
    defer testing.allocator.free(json);

    const parsed = try std.json.parseFromSlice(BackgroundProcessesListResponse, testing.allocator, json, .{});
    defer parsed.deinit();
    try testing.expectEqualStrings("completed", parsed.value.processes[0].status);
    try testing.expectEqual(true, parsed.value.processes[0].running);
}

test "useCase scopes rows to the requesting session" {
    var ctx = try setupDb();
    defer teardownDb(&ctx);

    try insertBgRow(&ctx.db, "sess_a_001", 999999998, "cmd-a", "/tmp/bg-a.log", 1700000003, "running");
    try insertBgRow(&ctx.db, "sess_b_001", 999999999, "cmd-b", "/tmp/bg-b.log", 1700000004, "running");

    const json = try useCase(testing.allocator, &ctx.db, "sess_a_001");
    defer testing.allocator.free(json);

    const parsed = try std.json.parseFromSlice(BackgroundProcessesListResponse, testing.allocator, json, .{});
    defer parsed.deinit();
    try testing.expectEqual(@as(usize, 1), parsed.value.count);
    try testing.expectEqualStrings("cmd-a", parsed.value.processes[0].command);
}
