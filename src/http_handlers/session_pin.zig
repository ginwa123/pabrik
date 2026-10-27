//! `POST /api/llm/session/:session_id/pin`. Body: `{ "is_pinned": true |
//! false }`. Flips the `is_pinned` flag on the session row (Migration 104).

const std = @import("std");
const http_response = @import("http_response.zig");
const pabrikcore = @import("pabrikcore");
const test_db = pabrikcore.test_db;
const gserverz = pabrikcore.gserverz;

pub const SessionPinError = error{
    SessionIdRequired,
    BodyRequired,
    InvalidJson,
    IsPinnedRequired,
    IsPinnedMustBeBool,
    SessionNotFound,
    PinUpdateFailed,
    OutOfMemory,
};

pub const SessionPinInput = struct {
    session_id: []const u8,
    is_pinned: bool,
};

pub const SessionPinResult = struct {
    new_pos: i64,
};

fn useCase(
    allocator: std.mem.Allocator,
    input: SessionPinInput,
) SessionPinError!SessionPinResult {
    if (input.session_id.len == 0) return error.SessionIdRequired;

    const di = pabrikcore.getSingleton() catch return error.PinUpdateFailed;
    const new_pos = pabrikcore.llm_history.setSessionPinned(
        allocator,
        di.db,
        input.session_id,
        input.is_pinned,
    ) catch |err| {
        if (err == error.SessionNotFound) return error.SessionNotFound;
        return error.PinUpdateFailed;
    };

    return .{ .new_pos = new_pos };
}

pub fn sessionPinHandler(
    ctx: gserverz.HttpContext,
    req: gserverz.HttpRequest,
    res: gserverz.HttpResponse,
) !gserverz.HttpResponse {
    const allocator = ctx.allocator;

    const session_id = req.params.get("session_id") orelse req.params.get("sessionId") orelse req.params.get("id") orelse "";
    if (session_id.len == 0) {
        return res.jsonResponse(.{
            .status_code = 400,
            .data = try http_response.makeErrorResponse(allocator, .{ .@"error" = "session_id required" }),
        });
    }

    const body = req.body;
    if (body.len == 0) {
        return res.jsonResponse(.{
            .status_code = 400,
            .data = try http_response.makeErrorResponse(allocator, .{ .@"error" = "body required" }),
        });
    }

    const parsed = std.json.parseFromSliceLeaky(std.json.Value, allocator, body, .{}) catch {
        return res.jsonResponse(.{
            .status_code = 400,
            .data = try http_response.makeErrorResponse(allocator, .{ .@"error" = "Invalid JSON" }),
        });
    };

    const is_pinned_val = parsed.object.get("is_pinned") orelse {
        return res.jsonResponse(.{
            .status_code = 400,
            .data = try http_response.makeErrorResponse(allocator, .{ .@"error" = "is_pinned required" }),
        });
    };
    if (is_pinned_val != .bool) {
        return res.jsonResponse(.{
            .status_code = 400,
            .data = try http_response.makeErrorResponse(allocator, .{ .@"error" = "is_pinned must be a boolean" }),
        });
    }
    const is_pinned = is_pinned_val.bool;

    const outcome = useCase(allocator, .{
        .session_id = session_id,
        .is_pinned = is_pinned,
    }) catch |err| {
        const status: u16 = switch (err) {
            error.SessionIdRequired => 400,
            error.BodyRequired => 400,
            error.InvalidJson => 400,
            error.IsPinnedRequired => 400,
            error.IsPinnedMustBeBool => 400,
            error.SessionNotFound => 404,
            error.PinUpdateFailed => 500,
            error.OutOfMemory => 500,
        };
        const message: []const u8 = switch (err) {
            error.SessionIdRequired => "session_id required",
            error.BodyRequired => "body required",
            error.InvalidJson => "Invalid JSON",
            error.IsPinnedRequired => "is_pinned required",
            error.IsPinnedMustBeBool => "is_pinned must be a boolean",
            error.SessionNotFound => "Session not found",
            error.PinUpdateFailed => "Failed to update session pin",
            error.OutOfMemory => "Out of memory",
        };
        return res.jsonResponse(.{
            .status_code = status,
            .data = try http_response.makeErrorResponse(allocator, .{ .@"error" = message }),
        });
    };

    return res.jsonResponse(.{
        .status_code = 200,
        .data = try http_response.makeSessionPinResponse(allocator, session_id, is_pinned, outcome.new_pos),
    });
}

// =====================================================================
// Tests - pin/unpin round-trip through setSessionPinned + JSON shape
// =====================================================================

const testing = std.testing;

fn setupPinDb() !struct { db: pabrikcore.database.Db, threaded: std.Io.Threaded } {
    const alloc = testing.allocator;
    var threaded = std.Io.Threaded.init(alloc, .{});
    errdefer threaded.deinit();
    const io = threaded.io();
    var db: pabrikcore.database.Db = .{};
    errdefer db.deinit();
    try test_db.openMemory(&db, io);
    try db.exec(alloc,
        \\CREATE TABLE sessions (
        \\  id TEXT PRIMARY KEY,
        \\  name TEXT NOT NULL DEFAULT '',
        \\  status TEXT NOT NULL DEFAULT 'active',
        \\  cwd TEXT NOT NULL DEFAULT '',
        \\  created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
        \\  updated_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
        \\  is_pinned INTEGER NOT NULL DEFAULT 0,
        \\  pinned_position INTEGER NOT NULL DEFAULT 0
        \\)
    , &.{});
    try db.exec(alloc,
        \\CREATE TABLE workspace_item_tasks (
        \\  id TEXT PRIMARY KEY,
        \\  name TEXT NOT NULL,
        \\  workspace_item_id TEXT NOT NULL DEFAULT '',
        \\  is_pinned INTEGER NOT NULL DEFAULT 0,
        \\  pinned_position INTEGER NOT NULL DEFAULT 0,
        \\  updated_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP
        \\)
    , &.{});
    try db.exec(alloc, "INSERT INTO sessions (id, name) VALUES ('s1', 'One'), ('s2', 'Two')", &.{});
    try db.exec(alloc, "INSERT INTO workspace_item_tasks (id, name, workspace_item_id) VALUES ('s1', 'One', 'i1')", &.{});
    return .{ .db = db, .threaded = threaded };
}

test "setSessionPinned pins, orders by MAX+1, and syncs the linked task row" {
    var ctx = try setupPinDb();
    defer ctx.db.deinit();
    defer ctx.threaded.deinit();
    const alloc = testing.allocator;

    const p1 = try pabrikcore.llm_history.setSessionPinned(alloc, &ctx.db, "s1", true);
    try testing.expectEqual(@as(i64, 0), p1);
    const p2 = try pabrikcore.llm_history.setSessionPinned(alloc, &ctx.db, "s2", true);
    try testing.expectEqual(@as(i64, 1), p2);

    var q = try ctx.db.query(alloc, "SELECT is_pinned, pinned_position FROM sessions WHERE id = 's1'", &.{});
    defer q.deinit();
    const row = (try q.next()) orelse return error.MissingRow;
    defer row.deinit(alloc);
    try testing.expectEqualStrings("1", row.values[0]);
    try testing.expectEqualStrings("0", row.values[1]);

    // Linked task row synced.
    var tq = try ctx.db.query(alloc, "SELECT is_pinned FROM workspace_item_tasks WHERE id = 's1'", &.{});
    defer tq.deinit();
    const trow = (try tq.next()) orelse return error.MissingTaskRow;
    defer trow.deinit(alloc);
    try testing.expectEqualStrings("1", trow.values[0]);

    // Unpin resets.
    const p0 = try pabrikcore.llm_history.setSessionPinned(alloc, &ctx.db, "s1", false);
    try testing.expectEqual(@as(i64, 0), p0);
}

test "setSessionPinned 404s on unknown session" {
    var ctx = try setupPinDb();
    defer ctx.db.deinit();
    defer ctx.threaded.deinit();
    const alloc = testing.allocator;
    const err = pabrikcore.llm_history.setSessionPinned(alloc, &ctx.db, "nope", true) catch |e| e;
    try testing.expectEqual(error.SessionNotFound, err);
}

test "buildSessionListJson carries is_pinned + pinned_position to the wire" {
    const alloc = testing.allocator;
    var sess = pabrikcore.llm_history.SessionInfo{
        .session_id = try alloc.dupe(u8, "s1"),
        .session_name = try alloc.dupe(u8, "One"),
        .status = try alloc.dupe(u8, "active"),
        .cwd = try alloc.dupe(u8, ""),
        .created_at = try alloc.dupe(u8, ""),
        .updated_at = try alloc.dupe(u8, ""),
        .agent = try alloc.dupe(u8, "Agent"),
        .selected_profile_model = try alloc.dupe(u8, ""),
        .is_auto_retry_until_stop = try alloc.dupe(u8, "0"),
        .last_finish_reason = try alloc.dupe(u8, ""),
        .last_human_touched_at = try alloc.dupe(u8, ""),
        .git_worktree_cwd = try alloc.dupe(u8, ""),
        .git_branch = try alloc.dupe(u8, ""),
        .workspace_item_id = try alloc.dupe(u8, ""),
        .is_pinned = true,
        .pinned_position = 3,
    };
    defer sess.deinit(alloc);
    const json = try pabrikcore.llm_history.buildSessionListJson(alloc, &[_]pabrikcore.llm_history.SessionInfo{sess}, 1, false, null);
    defer alloc.free(json);
    try testing.expect(std.mem.indexOf(u8, json, "\"is_pinned\":true") != null);
    try testing.expect(std.mem.indexOf(u8, json, "\"pinned_position\":3") != null);
}
