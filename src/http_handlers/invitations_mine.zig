//! `GET /api/invitations` — the caller's own inbox: every workspace waiting on
//! an answer from this account. Not workspace-scoped, so it needs no gate: the
//! rows are chosen by the resolved caller's id and nothing else.

const std = @import("std");
const pabrikcore = @import("pabrikcore");
const test_db = pabrikcore.test_db;
const gserverz = pabrikcore.gserverz;
const http_response = @import("http_response.zig");
const gate = @import("workspace_members_gate.zig");
const store = @import("../agentic_loop/workspace_invitations_store.zig");

pub const InvitationsMineError = error{
    QueryFailed,
    OutOfMemory,
};

pub const InvitationsMineOutput = struct {
    /// Owned; the caller frees it with `store.freeInvitationRows`.
    invitations: []store.InvitationRow,
};

fn useCase(
    allocator: std.mem.Allocator,
    db: *pabrikcore.database.Db,
    auth_enabled: bool,
    headers: anytype,
) InvitationsMineError!InvitationsMineOutput {
    const caller = gate.callerFor(allocator, db, auth_enabled, headers) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return error.QueryFailed,
    };
    defer allocator.free(caller);

    const rows = store.listForInvitee(allocator, db, caller) catch |err| switch (err) {
        error.QueryFailed => return error.QueryFailed,
        error.OutOfMemory => return error.OutOfMemory,
        // A caller id is always present here, and this path answers nothing.
        else => unreachable,
    };
    return .{ .invitations = rows };
}

fn statusFor(err: InvitationsMineError) u16 {
    return switch (err) {
        error.QueryFailed, error.OutOfMemory => 500,
    };
}

pub fn invitationsMineHandler(
    ctx: gserverz.HttpContext,
    req: gserverz.HttpRequest,
    res: gserverz.HttpResponse,
) !gserverz.HttpResponse {
    const allocator = ctx.allocator;

    const di = try pabrikcore.getSingleton();

    const output = useCase(allocator, di.db, di.auth_enabled, req.headers) catch |err| {
        const message: []const u8 = switch (err) {
            error.QueryFailed => "DB error",
            error.OutOfMemory => "Out of memory",
        };
        return res.jsonResponse(.{
            .status_code = statusFor(err),
            .data = try http_response.makeErrorResponse(allocator, .{ .@"error" = message }),
        });
    };
    defer store.freeInvitationRows(allocator, output.invitations);

    const data = try http_response.makeWorkspaceInvitationListResponse(allocator, output.invitations);
    return res.jsonResponse(.{ .status_code = 200, .data = data });
}

// ─── Tests ──────────────────────────────────────────────────────────────

const testing = std.testing;
const database = pabrikcore.database;

const TestCtx = struct {
    db: database.Db,
    threaded: std.Io.Threaded,
};

fn setupDb() !TestCtx {
    const alloc = testing.allocator;
    var threaded = std.Io.Threaded.init(alloc, .{});
    errdefer threaded.deinit();
    var db: database.Db = .{};
    errdefer db.deinit();
    try test_db.openMemory(&db, threaded.io());

    try db.exec(alloc,
        \\CREATE TABLE workspaces (id TEXT PRIMARY KEY, name TEXT NOT NULL, user_id TEXT)
    , &.{});
    try db.exec(alloc,
        \\CREATE TABLE users (
        \\  id TEXT PRIMARY KEY, email TEXT NOT NULL, name TEXT NOT NULL DEFAULT '',
        \\  is_active INTEGER NOT NULL DEFAULT 1
        \\)
    , &.{});
    try db.exec(alloc,
        \\CREATE TABLE workspace_members (
        \\  workspace_id TEXT NOT NULL, user_id TEXT NOT NULL, role TEXT NOT NULL DEFAULT 'viewer',
        \\  joined_at TIMESTAMP, invited_by TEXT, PRIMARY KEY (workspace_id, user_id)
        \\)
    , &.{});
    try db.exec(alloc,
        \\CREATE TABLE workspace_invitations (
        \\  id TEXT PRIMARY KEY, workspace_id TEXT NOT NULL, invitee_user_id TEXT NOT NULL,
        \\  role TEXT NOT NULL DEFAULT 'viewer', invited_by TEXT NOT NULL DEFAULT '',
        \\  created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP
        \\)
    , &.{});
    try db.exec(alloc, "INSERT INTO workspaces (id, name) VALUES ('ws_1', 'Acme'), ('ws_2', 'Beta')", &.{});
    try db.exec(alloc,
        \\INSERT INTO users (id, email, name) VALUES ('user_ben', 'ben@example.com', 'Ben')
    , &.{});
    try db.exec(alloc,
        \\INSERT INTO workspace_invitations (id, workspace_id, invitee_user_id, role, invited_by) VALUES
        \\  ('inv_1', 'ws_1', 'user_ben', 'editor', 'user_amy'),
        \\  ('inv_2', 'ws_2', 'user_ben', 'viewer', 'user_cid')
    , &.{});
    return .{ .db = db, .threaded = threaded };
}

/// Under `--auth` off the caller is the installation owner, whose inbox is
/// empty — the invitee here only exists as a row in `users`.
const NoCookie = struct {
    pub fn get(_: @This(), _: []const u8) ?[]const u8 {
        return null;
    }
};

test "useCase answers the installation owner with an empty inbox, not somebody else's" {
    const alloc = testing.allocator;
    var ctx = try setupDb();
    defer ctx.threaded.deinit();
    defer ctx.db.deinit();

    const out = try useCase(alloc, &ctx.db, false, NoCookie{});
    defer store.freeInvitationRows(alloc, out.invitations);

    // `user_system` holds no invitation, so the list is empty rather than
    // every invitation in the database.
    try testing.expectEqual(@as(usize, 0), out.invitations.len);
}

test "useCase keys the inbox on the resolved caller, not on a query parameter" {
    const alloc = testing.allocator;
    var ctx = try setupDb();
    defer ctx.threaded.deinit();
    defer ctx.db.deinit();

    // The store answers for an id; the handler can only ever pass the id it
    // resolved from the cookie, which is what keeps one user out of another's
    // inbox.
    const rows = try store.listForInvitee(alloc, &ctx.db, "user_ben");
    defer store.freeInvitationRows(alloc, rows);
    try testing.expectEqual(@as(usize, 2), rows.len);

    const nowhere = try store.listForInvitee(alloc, &ctx.db, "user_system");
    defer store.freeInvitationRows(alloc, nowhere);
    try testing.expectEqual(@as(usize, 0), nowhere.len);
}

test "the inbox body carries the workspace NAME so the row reads without a second lookup" {
    const alloc = testing.allocator;
    var ctx = try setupDb();
    defer ctx.threaded.deinit();
    defer ctx.db.deinit();

    const rows = try store.listForInvitee(alloc, &ctx.db, "user_ben");
    defer store.freeInvitationRows(alloc, rows);

    const json = try http_response.makeWorkspaceInvitationListResponse(alloc, rows);
    defer alloc.free(json);

    try testing.expect(std.mem.indexOf(u8, json, "\"count\":2") != null);
    try testing.expect(std.mem.indexOf(u8, json, "Acme") != null);
    try testing.expect(std.mem.indexOf(u8, json, "Beta") != null);
}
