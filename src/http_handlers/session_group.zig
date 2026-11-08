//! The roster of a multi-agent chat: `GET|POST|DELETE /api/llm/session/:id/group...`.
//! A session is a group when `sessions.group_lead` names somebody; the loop then
//! takes each turn's speaker from `session_group_members`.

const std = @import("std");
const http_response = @import("http_response.zig");
const pabrikcore = @import("pabrikcore");
const gserverz = pabrikcore.gserverz;
const database = pabrikcore.database;
const session_group = pabrikcore.session_group;
const test_db = pabrikcore.test_db;

const testing = std.testing;

pub const Roster = struct {
    session_id: []const u8,
    group: bool,
    lead: []const u8,
    members: []session_group.Member,
};

pub const GroupError = error{
    SessionIdRequired,
    AgentRequired,
    NotAMember,
    OutOfMemory,
};

/// The roster as the wire carries it. `lead` and `members` are owned; free
/// them with `freeRoster`. `session_id` points into the caller's memory.
pub fn rosterUseCase(
    allocator: std.mem.Allocator,
    db: *database.Db,
    session_id: []const u8,
) GroupError!Roster {
    if (session_id.len == 0) return error.SessionIdRequired;

    const members = session_group.listMembers(allocator, db, session_id) catch return error.OutOfMemory;
    errdefer session_group.freeMembers(allocator, members);

    const lead = (session_group.groupLead(allocator, db, session_id) catch return error.OutOfMemory) orelse "";
    defer allocator.free(lead);

    return .{
        .session_id = session_id,
        .group = lead.len > 0,
        .lead = try allocator.dupe(u8, lead),
        .members = members,
    };
}

pub fn freeRoster(allocator: std.mem.Allocator, roster: Roster) void {
    allocator.free(roster.lead);
    session_group.freeMembers(allocator, roster.members);
}

/// Add an agent to the roster, or move one that is already there. The first
/// member to join leads the room, so a roster assembled one join at a time
/// still has somebody to speak first.
pub fn addMemberUseCase(
    allocator: std.mem.Allocator,
    db: *database.Db,
    session_id: []const u8,
    agent_name: []const u8,
    role_text: []const u8,
) GroupError!Roster {
    if (session_id.len == 0) return error.SessionIdRequired;
    if (agent_name.len == 0) return error.AgentRequired;

    session_group.addMember(allocator, db, session_id, agent_name, session_group.Role.fromText(role_text), null) catch
        return error.OutOfMemory;
    session_group.setLeadIfUnset(allocator, db, session_id, agent_name, role_text) catch
        return error.OutOfMemory;

    return rosterUseCase(allocator, db, session_id);
}

/// Take an agent out. The last member leaving clears the lead, so the session
/// stops being a group instead of routing to an empty room.
pub fn removeMemberUseCase(
    allocator: std.mem.Allocator,
    db: *database.Db,
    session_id: []const u8,
    agent_name: []const u8,
) GroupError!Roster {
    if (session_id.len == 0) return error.SessionIdRequired;
    if (agent_name.len == 0) return error.AgentRequired;

    session_group.removeMember(allocator, db, session_id, agent_name) catch return error.OutOfMemory;

    const remaining = session_group.listMembers(allocator, db, session_id) catch return error.OutOfMemory;
    defer session_group.freeMembers(allocator, remaining);

    const current_lead_owned = session_group.groupLead(allocator, db, session_id) catch return error.OutOfMemory;
    defer if (current_lead_owned) |l| allocator.free(l);
    const current_lead: []const u8 = current_lead_owned orelse "";

    const lead_still_here = blk: {
        for (remaining) |m| {
            if (std.mem.eql(u8, m.name, current_lead)) break :blk true;
        }
        break :blk false;
    };
    const next_lead: []const u8 = if (lead_still_here)
        current_lead
    else if (remaining.len == 0)
        ""
    else
        remaining[0].name;

    session_group.setLead(allocator, db, session_id, next_lead) catch return error.OutOfMemory;

    return rosterUseCase(allocator, db, session_id);
}

/// Hand the room to a member. Only a member can lead it.
pub fn setLeadUseCase(
    allocator: std.mem.Allocator,
    db: *database.Db,
    session_id: []const u8,
    agent_name: []const u8,
) GroupError!Roster {
    if (session_id.len == 0) return error.SessionIdRequired;
    if (agent_name.len == 0) return error.AgentRequired;

    const members = session_group.listMembers(allocator, db, session_id) catch return error.OutOfMemory;
    defer session_group.freeMembers(allocator, members);

    var is_member = false;
    for (members) |m| {
        if (std.mem.eql(u8, m.name, agent_name)) is_member = true;
    }
    if (!is_member) return error.NotAMember;

    session_group.setLead(allocator, db, session_id, agent_name) catch return error.OutOfMemory;

    return rosterUseCase(allocator, db, session_id);
}

pub fn encodeRoster(allocator: std.mem.Allocator, roster: Roster) ![]u8 {
    return try std.json.Stringify.valueAlloc(allocator, roster, .{});
}

fn statusFor(err: GroupError) u16 {
    return switch (err) {
        error.SessionIdRequired, error.AgentRequired, error.NotAMember => 400,
        error.OutOfMemory => 500,
    };
}

fn messageFor(err: GroupError) []const u8 {
    return switch (err) {
        error.SessionIdRequired => "session_id required",
        error.AgentRequired => "agent required",
        error.NotAMember => "agent is not a member of this chat",
        error.OutOfMemory => "Out of memory",
    };
}

fn respondRoster(
    allocator: std.mem.Allocator,
    res: gserverz.HttpResponse,
    outcome: GroupError!Roster,
) !gserverz.HttpResponse {
    const roster = outcome catch |err| {
        return res.jsonResponse(.{
            .status_code = statusFor(err),
            .data = try http_response.makeErrorResponse(allocator, .{ .@"error" = messageFor(err) }),
        });
    };
    defer freeRoster(allocator, roster);

    return res.jsonResponse(.{
        .status_code = 200,
        .data = try encodeRoster(allocator, roster),
    });
}

fn sessionIdOf(req: gserverz.HttpRequest) []const u8 {
    return req.params.get("session_id") orelse req.params.get("sessionId") orelse req.params.get("id") orelse "";
}

const MemberBody = struct {
    agent: []const u8 = "",
    role: []const u8 = "",
};

fn parseMemberBody(allocator: std.mem.Allocator, body: []const u8) ?MemberBody {
    if (body.len == 0) return null;
    return std.json.parseFromSliceLeaky(MemberBody, allocator, body, .{ .ignore_unknown_fields = true }) catch null;
}

pub fn sessionGroupGetHandler(
    ctx: gserverz.HttpContext,
    req: gserverz.HttpRequest,
    res: gserverz.HttpResponse,
) !gserverz.HttpResponse {
    const allocator = ctx.allocator;
    const di = try pabrikcore.getSingleton();
    return respondRoster(allocator, res, rosterUseCase(allocator, di.db, sessionIdOf(req)));
}

pub fn sessionGroupMemberAddHandler(
    ctx: gserverz.HttpContext,
    req: gserverz.HttpRequest,
    res: gserverz.HttpResponse,
) !gserverz.HttpResponse {
    const allocator = ctx.allocator;
    const di = try pabrikcore.getSingleton();

    const body = parseMemberBody(allocator, req.body) orelse {
        return res.jsonResponse(.{
            .status_code = 400,
            .data = try http_response.makeErrorResponse(allocator, .{ .@"error" = "Invalid JSON" }),
        });
    };

    return respondRoster(allocator, res, addMemberUseCase(allocator, di.db, sessionIdOf(req), body.agent, body.role));
}

pub fn sessionGroupMemberRemoveHandler(
    ctx: gserverz.HttpContext,
    req: gserverz.HttpRequest,
    res: gserverz.HttpResponse,
) !gserverz.HttpResponse {
    const allocator = ctx.allocator;
    const di = try pabrikcore.getSingleton();

    const agent_name = req.params.get("agent") orelse "";
    return respondRoster(allocator, res, removeMemberUseCase(allocator, di.db, sessionIdOf(req), agent_name));
}

pub fn sessionGroupLeadHandler(
    ctx: gserverz.HttpContext,
    req: gserverz.HttpRequest,
    res: gserverz.HttpResponse,
) !gserverz.HttpResponse {
    const allocator = ctx.allocator;
    const di = try pabrikcore.getSingleton();

    const body = parseMemberBody(allocator, req.body) orelse {
        return res.jsonResponse(.{
            .status_code = 400,
            .data = try http_response.makeErrorResponse(allocator, .{ .@"error" = "Invalid JSON" }),
        });
    };

    return respondRoster(allocator, res, setLeadUseCase(allocator, di.db, sessionIdOf(req), body.agent));
}

// ─── Tests ─────────────────────────────────────────────────────────────────

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
        \\CREATE TABLE sessions (
        \\    id TEXT PRIMARY KEY,
        \\    name TEXT NOT NULL DEFAULT '',
        \\    status TEXT NOT NULL DEFAULT 'active',
        \\    cwd TEXT NOT NULL DEFAULT '',
        \\    created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
        \\    updated_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
        \\    selected_profile_model TEXT NOT NULL DEFAULT '',
        \\    git_worktree_cwd TEXT NOT NULL DEFAULT '',
        \\    is_auto_retry_until_stop TEXT NOT NULL DEFAULT '0',
        \\    last_finish_reason TEXT NOT NULL DEFAULT '',
        \\    pr_url TEXT NOT NULL DEFAULT '',
        \\    pr_provider TEXT NOT NULL DEFAULT '',
        \\    sub_agent_name TEXT NOT NULL DEFAULT '',
        \\    parent_session_id TEXT NOT NULL DEFAULT '',
        \\    group_lead TEXT
        \\)
    , &.{});
    try db.exec(alloc,
        \\CREATE TABLE session_group_members (
        \\    session_id TEXT NOT NULL,
        \\    agent_name TEXT NOT NULL,
        \\    role TEXT NOT NULL DEFAULT 'worker',
        \\    position INTEGER NOT NULL DEFAULT 0,
        \\    created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
        \\    PRIMARY KEY (session_id, agent_name)
        \\)
    , &.{});
    try db.exec(alloc, "INSERT INTO sessions (id, name) VALUES ('s_1', 'room')", &.{});
    return .{ .db = db, .threaded = threaded };
}

test "a session with no members is not a group" {
    var ctx = try setupDb();
    defer ctx.db.deinit();
    defer ctx.threaded.deinit();

    const roster = try rosterUseCase(testing.allocator, &ctx.db, "s_1");
    defer freeRoster(testing.allocator, roster);

    try testing.expect(!roster.group);
    try testing.expectEqualStrings("", roster.lead);
    try testing.expectEqual(@as(usize, 0), roster.members.len);
}

test "the first agent to join leads the room" {
    var ctx = try setupDb();
    defer ctx.db.deinit();
    defer ctx.threaded.deinit();

    const roster = try addMemberUseCase(testing.allocator, &ctx.db, "s_1", "BEAM", "");
    defer freeRoster(testing.allocator, roster);

    try testing.expect(roster.group);
    try testing.expectEqualStrings("BEAM", roster.lead);
    try testing.expectEqual(@as(usize, 1), roster.members.len);
}

test "a second agent joins as a worker and leaves the lead alone" {
    var ctx = try setupDb();
    defer ctx.db.deinit();
    defer ctx.threaded.deinit();

    const first = try addMemberUseCase(testing.allocator, &ctx.db, "s_1", "BEAM", "");
    freeRoster(testing.allocator, first);

    const roster = try addMemberUseCase(testing.allocator, &ctx.db, "s_1", "deepseek auto", "");
    defer freeRoster(testing.allocator, roster);

    try testing.expectEqualStrings("BEAM", roster.lead);
    try testing.expectEqual(@as(usize, 2), roster.members.len);
    try testing.expectEqualStrings("deepseek auto", roster.members[1].name);
    try testing.expectEqual(session_group.Role.worker, roster.members[1].role);
}

test "an agent that joins as lead takes the room" {
    var ctx = try setupDb();
    defer ctx.db.deinit();
    defer ctx.threaded.deinit();

    const first = try addMemberUseCase(testing.allocator, &ctx.db, "s_1", "BEAM", "");
    freeRoster(testing.allocator, first);

    const roster = try addMemberUseCase(testing.allocator, &ctx.db, "s_1", "deepseek auto", "lead");
    defer freeRoster(testing.allocator, roster);

    try testing.expectEqualStrings("deepseek auto", roster.lead);
}

test "removing a member leaves the rest of the roster" {
    var ctx = try setupDb();
    defer ctx.db.deinit();
    defer ctx.threaded.deinit();

    const first = try addMemberUseCase(testing.allocator, &ctx.db, "s_1", "BEAM", "");
    freeRoster(testing.allocator, first);
    const second = try addMemberUseCase(testing.allocator, &ctx.db, "s_1", "deepseek auto", "");
    freeRoster(testing.allocator, second);

    const roster = try removeMemberUseCase(testing.allocator, &ctx.db, "s_1", "deepseek auto");
    defer freeRoster(testing.allocator, roster);

    try testing.expectEqual(@as(usize, 1), roster.members.len);
    try testing.expectEqualStrings("BEAM", roster.members[0].name);
}

test "the last member leaving stops the session being a group" {
    var ctx = try setupDb();
    defer ctx.db.deinit();
    defer ctx.threaded.deinit();

    const first = try addMemberUseCase(testing.allocator, &ctx.db, "s_1", "BEAM", "");
    freeRoster(testing.allocator, first);

    const roster = try removeMemberUseCase(testing.allocator, &ctx.db, "s_1", "BEAM");
    defer freeRoster(testing.allocator, roster);

    try testing.expect(!roster.group);
    try testing.expectEqualStrings("", roster.lead);
}

test "the lead can be handed to another member" {
    var ctx = try setupDb();
    defer ctx.db.deinit();
    defer ctx.threaded.deinit();

    const first = try addMemberUseCase(testing.allocator, &ctx.db, "s_1", "BEAM", "");
    freeRoster(testing.allocator, first);
    const second = try addMemberUseCase(testing.allocator, &ctx.db, "s_1", "deepseek auto", "");
    freeRoster(testing.allocator, second);

    const roster = try setLeadUseCase(testing.allocator, &ctx.db, "s_1", "deepseek auto");
    defer freeRoster(testing.allocator, roster);

    try testing.expectEqualStrings("deepseek auto", roster.lead);
}

test "an agent outside the roster cannot lead it" {
    var ctx = try setupDb();
    defer ctx.db.deinit();
    defer ctx.threaded.deinit();

    const first = try addMemberUseCase(testing.allocator, &ctx.db, "s_1", "BEAM", "");
    freeRoster(testing.allocator, first);

    try testing.expectError(error.NotAMember, setLeadUseCase(testing.allocator, &ctx.db, "s_1", "deepseek auto"));
}

test "a chat with no session row yet has an empty roster, not an error" {
    var ctx = try setupDb();
    defer ctx.db.deinit();
    defer ctx.threaded.deinit();

    const roster = try rosterUseCase(testing.allocator, &ctx.db, "task_without_a_session");
    defer freeRoster(testing.allocator, roster);

    try testing.expect(!roster.group);
    try testing.expectEqualStrings("", roster.lead);
    try testing.expectEqual(@as(usize, 0), roster.members.len);
}

test "a chat with no session row yet can still be joined" {
    var ctx = try setupDb();
    defer ctx.db.deinit();
    defer ctx.threaded.deinit();

    const roster = try addMemberUseCase(testing.allocator, &ctx.db, "task_without_a_session", "BEAM", "");
    defer freeRoster(testing.allocator, roster);

    try testing.expect(roster.group);
    try testing.expectEqualStrings("BEAM", roster.lead);
    try testing.expectEqual(@as(usize, 1), roster.members.len);
    try testing.expectEqual(session_group.Role.lead, roster.members[0].role);
}

test "an empty agent name is rejected" {
    var ctx = try setupDb();
    defer ctx.db.deinit();
    defer ctx.threaded.deinit();

    try testing.expectError(error.AgentRequired, addMemberUseCase(testing.allocator, &ctx.db, "s_1", "", ""));
}

test "the roster encodes to the wire shape the app reads" {
    var ctx = try setupDb();
    defer ctx.db.deinit();
    defer ctx.threaded.deinit();

    const first = try addMemberUseCase(testing.allocator, &ctx.db, "s_1", "BEAM", "");
    freeRoster(testing.allocator, first);
    const roster = try addMemberUseCase(testing.allocator, &ctx.db, "s_1", "deepseek auto", "");
    defer freeRoster(testing.allocator, roster);

    const json = try encodeRoster(testing.allocator, roster);
    defer testing.allocator.free(json);

    try testing.expectEqualStrings(
        "{\"session_id\":\"s_1\",\"group\":true,\"lead\":\"BEAM\",\"members\":[{\"name\":\"BEAM\",\"role\":\"lead\"},{\"name\":\"deepseek auto\",\"role\":\"worker\"}]}",
        json,
    );
}

test "a member that joins after the lead was chosen carries the lead role" {
    var ctx = try setupDb();
    defer ctx.db.deinit();
    defer ctx.threaded.deinit();

    const first = try addMemberUseCase(testing.allocator, &ctx.db, "s_1", "BEAM", "");
    freeRoster(testing.allocator, first);
    try ctx.db.exec(testing.allocator, "UPDATE sessions SET group_lead = 'deepseek auto' WHERE id = 's_1'", &.{});

    const roster = try addMemberUseCase(testing.allocator, &ctx.db, "s_1", "deepseek auto", "");
    defer freeRoster(testing.allocator, roster);

    try testing.expectEqualStrings("deepseek auto", roster.lead);
    try testing.expectEqual(session_group.Role.lead, roster.members[1].role);
    try testing.expectEqual(session_group.Role.worker, roster.members[0].role);
}

test "removing the lead hands the room to the first remaining member" {
    var ctx = try setupDb();
    defer ctx.db.deinit();
    defer ctx.threaded.deinit();

    const first = try addMemberUseCase(testing.allocator, &ctx.db, "s_1", "BEAM", "");
    freeRoster(testing.allocator, first);
    const second = try addMemberUseCase(testing.allocator, &ctx.db, "s_1", "deepseek auto", "");
    freeRoster(testing.allocator, second);

    const roster = try removeMemberUseCase(testing.allocator, &ctx.db, "s_1", "BEAM");
    defer freeRoster(testing.allocator, roster);

    try testing.expect(roster.group);
    try testing.expectEqualStrings("deepseek auto", roster.lead);
    try testing.expectEqual(session_group.Role.lead, roster.members[0].role);
}

test "removing a worker leaves the lead where it was" {
    var ctx = try setupDb();
    defer ctx.db.deinit();
    defer ctx.threaded.deinit();

    const first = try addMemberUseCase(testing.allocator, &ctx.db, "s_1", "BEAM", "");
    freeRoster(testing.allocator, first);
    const second = try addMemberUseCase(testing.allocator, &ctx.db, "s_1", "deepseek auto", "");
    freeRoster(testing.allocator, second);

    const roster = try removeMemberUseCase(testing.allocator, &ctx.db, "s_1", "deepseek auto");
    defer freeRoster(testing.allocator, roster);

    try testing.expectEqualStrings("BEAM", roster.lead);
    try testing.expectEqual(session_group.Role.lead, roster.members[0].role);
}
