//! `GET /api/agent-profiles/:name/in-use` — the running sessions pinned to a
//! profile, so Settings can refuse to rename an agent out from under a worker
//! (which would leave `selected_profile_model` pointing at a missing name).

const std = @import("std");
const pabrikcore = @import("pabrikcore");
const gserverz = pabrikcore.gserverz;
const http_response = @import("http_response.zig");

pub const InUseError = error{
    NameRequired,
    OutOfMemory,
};

/// One running session bound to the profile.
pub const InUseSession = struct {
    id: []const u8,
    /// True when the session is a spawned sub-agent (matched on
    /// `sessions.sub_agent_name` rather than the picker's profile).
    sub_agent: bool,
};

pub const InUseOutput = struct {
    name: []const u8,
    running: usize,
    sessions: []const InUseSession,
};

/// Sessions bound to `name` that have a live row in the `worker` table.
/// A missing `worker`/`sessions` table reads as "nothing running" — the guard
/// is advisory, so a schema surprise must not block an edit.
fn useCase(
    allocator: std.mem.Allocator,
    db: *pabrikcore.sqlite.SqliteBackend,
    name: []const u8,
) InUseError!InUseOutput {
    if (name.len == 0) return error.NameRequired;

    var q = db.query(
        allocator,
        \\SELECT s.id, COALESCE(s.sub_agent_name, '')
        \\FROM worker w
        \\JOIN sessions s ON (s.id = w.id OR s.id = w.session_id)
        \\WHERE s.selected_profile_model = ? OR s.sub_agent_name = ?
        \\ORDER BY s.id
    ,
        &.{ name, name },
    ) catch return .{ .name = name, .running = 0, .sessions = &.{} };
    defer q.deinit();

    var list: std.ArrayList(InUseSession) = .empty;
    errdefer {
        for (list.items) |s| allocator.free(s.id);
        list.deinit(allocator);
    }
    while (q.next() catch null) |row| {
        defer row.deinit(allocator);
        const id = allocator.dupe(u8, row.values[0]) catch return error.OutOfMemory;
        errdefer allocator.free(id);
        list.append(allocator, .{
            .id = id,
            .sub_agent = row.values[1].len > 0,
        }) catch return error.OutOfMemory;
    }

    const owned = list.toOwnedSlice(allocator) catch return error.OutOfMemory;
    return .{ .name = name, .running = owned.len, .sessions = owned };
}

pub fn agentProfileInUseHandler(
    ctx: gserverz.HttpContext,
    req: gserverz.HttpRequest,
    res: gserverz.HttpResponse,
) !gserverz.HttpResponse {
    const allocator = ctx.allocator;

    const di = try pabrikcore.getSingleton();
    const sqlite_db = di.db;

    const name = req.params.get("name") orelse "";
    const output = useCase(allocator, sqlite_db, name) catch |err| {
        const status: u16 = switch (err) {
            error.NameRequired => 400,
            error.OutOfMemory => 500,
        };
        const message: []const u8 = switch (err) {
            error.NameRequired => "name required",
            error.OutOfMemory => "Out of memory",
        };
        return res.jsonResponse(.{
            .status_code = status,
            .data = try http_response.makeErrorResponse(allocator, .{ .@"error" = message }),
        });
    };

    const data = try std.json.Stringify.valueAlloc(allocator, .{
        .name = output.name,
        .running = output.running,
        .sessions = output.sessions,
    }, .{});
    return res.jsonResponse(.{ .status_code = 200, .data = data });
}

// ─── Tests ──────────────────────────────────────────────────────────────

const sqlite = @import("pabrikcore").sqlite;
const testing = std.testing;

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
        \\CREATE TABLE sessions (
        \\    id TEXT PRIMARY KEY, cwd TEXT, selected_profile_model TEXT,
        \\    sub_agent_name TEXT, parent_session_id TEXT)
    , &.{});
    try db.exec(testing.allocator,
        \\CREATE TABLE worker (
        \\    id TEXT PRIMARY KEY, session_id TEXT, cancelled INTEGER DEFAULT 0)
    , &.{});
    return .{ .db = db, .threaded = threaded };
}

fn addSession(ctx: *TestCtx, id: []const u8, profile: []const u8, sub_agent: []const u8) !void {
    try ctx.db.exec(
        testing.allocator,
        "INSERT INTO sessions (id, cwd, selected_profile_model, sub_agent_name) VALUES (?, '/repo', ?, ?)",
        &.{ id, profile, sub_agent },
    );
}

fn addWorker(ctx: *TestCtx, id: []const u8, session_id: []const u8) !void {
    try ctx.db.exec(
        testing.allocator,
        "INSERT INTO worker (id, session_id) VALUES (?, ?)",
        &.{ id, session_id },
    );
}

test "in-use: a running session pinned to the profile is reported" {
    var ctx = try setupDb();
    defer ctx.db.deinit();
    defer ctx.threaded.deinit();

    try addSession(&ctx, "s1", "work", "");
    try addWorker(&ctx, "s1", "s1");

    const out = try useCase(testing.allocator, &ctx.db, "work");
    defer {
        for (out.sessions) |s| testing.allocator.free(s.id);
        testing.allocator.free(out.sessions);
    }

    try testing.expectEqual(@as(usize, 1), out.running);
    try testing.expectEqualStrings("s1", out.sessions[0].id);
    try testing.expect(!out.sessions[0].sub_agent);
}

test "in-use: an idle session does not block" {
    var ctx = try setupDb();
    defer ctx.db.deinit();
    defer ctx.threaded.deinit();

    try addSession(&ctx, "s1", "work", "");

    const out = try useCase(testing.allocator, &ctx.db, "work");
    defer testing.allocator.free(out.sessions);

    try testing.expectEqual(@as(usize, 0), out.running);
}

test "in-use: a running sub-agent counts for the profile it was spawned as" {
    var ctx = try setupDb();
    defer ctx.db.deinit();
    defer ctx.threaded.deinit();

    try addSession(&ctx, "child", "", "work");
    try addWorker(&ctx, "child", "child");

    const out = try useCase(testing.allocator, &ctx.db, "work");
    defer {
        for (out.sessions) |s| testing.allocator.free(s.id);
        testing.allocator.free(out.sessions);
    }

    try testing.expectEqual(@as(usize, 1), out.running);
    try testing.expect(out.sessions[0].sub_agent);
}

test "in-use: a renamed-away profile reports nothing" {
    var ctx = try setupDb();
    defer ctx.db.deinit();
    defer ctx.threaded.deinit();

    try addSession(&ctx, "s1", "day job", "");
    try addWorker(&ctx, "s1", "s1");

    const out = try useCase(testing.allocator, &ctx.db, "work");
    defer testing.allocator.free(out.sessions);

    try testing.expectEqual(@as(usize, 0), out.running);
}

test "in-use: an empty name is a client error" {
    var ctx = try setupDb();
    defer ctx.db.deinit();
    defer ctx.threaded.deinit();

    try testing.expectError(error.NameRequired, useCase(testing.allocator, &ctx.db, ""));
}
