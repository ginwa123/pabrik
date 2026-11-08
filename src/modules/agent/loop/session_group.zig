const std = @import("std");
const pabrikcore = @import("pabrikcore");
const test_db = pabrikcore.test_db;
const database = pabrikcore.database;
const router = @import("group_router.zig");
const helpers = @import("helpers");

const testing = std.testing;

pub const Member = router.Member;
pub const Role = router.Role;
pub const Decision = router.Decision;
pub const CloseReason = router.CloseReason;

/// How many agent turns one message from the human may trigger before the room
/// stops and waits for them. A new human message resets the count.
pub const default_hop_budget: u32 = 8;

/// The last thing said in the thread. `speaker` is empty when the newest row
/// is the human's, because then no agent has spoken yet.
pub const LastTurn = struct {
    speaker: []const u8,
    text: []const u8,
};

pub fn freeMembers(allocator: std.mem.Allocator, members: []Member) void {
    for (members) |m| allocator.free(m.name);
    allocator.free(members);
}

/// Create a session row that is a group from the first moment: no history yet,
/// so the first turn belongs to the lead. Caller frees the id.
pub fn createGroupSession(
    allocator: std.mem.Allocator,
    db: *database.Db,
    name: []const u8,
    lead: []const u8,
) ![]u8 {
    const id = try std.fmt.allocPrint(allocator, "grp_{d}", .{helpers.unixTimestampNanos()});
    errdefer allocator.free(id);

    try db.exec(allocator, "INSERT INTO sessions (id, name, status, group_lead) VALUES (?, ?, 'active', ?)", &.{ id, name, lead });
    return id;
}

/// Add a member, or move one that is already there. A null position appends,
/// which is what a join means: the roster keeps the order the agents arrived.
pub fn addMember(
    allocator: std.mem.Allocator,
    db: *database.Db,
    session_id: []const u8,
    agent_name: []const u8,
    role: Role,
    position: ?u32,
) !void {
    const slot = position orelse try nextPosition(allocator, db, session_id);
    const position_text = try std.fmt.allocPrint(allocator, "{d}", .{slot});
    defer allocator.free(position_text);

    try db.exec(allocator, "DELETE FROM session_group_members WHERE session_id = ? AND agent_name = ?", &.{ session_id, agent_name });
    try db.exec(allocator,
        \\INSERT INTO session_group_members (session_id, agent_name, role, position)
        \\VALUES (?, ?, ?, ?)
    , &.{ session_id, agent_name, role.toText(), position_text });
}

fn nextPosition(allocator: std.mem.Allocator, db: *database.Db, session_id: []const u8) !u32 {
    var row = try db.queryRow(
        allocator,
        "SELECT COALESCE(MAX(position), -1) + 1 FROM session_group_members WHERE session_id = ?",
        &.{session_id},
    );
    defer row.deinit(allocator);
    return std.fmt.parseInt(u32, row.values[0], 10) catch 0;
}

pub fn removeMember(
    allocator: std.mem.Allocator,
    db: *database.Db,
    session_id: []const u8,
    agent_name: []const u8,
) !void {
    try db.exec(allocator, "DELETE FROM session_group_members WHERE session_id = ? AND agent_name = ?", &.{ session_id, agent_name });
}

pub fn listMembers(allocator: std.mem.Allocator, db: *database.Db, session_id: []const u8) ![]Member {
    var rows = try db.query(allocator,
        \\SELECT COALESCE(CAST(agent_name AS TEXT), ''), COALESCE(CAST(role AS TEXT), 'worker')
        \\FROM session_group_members
        \\WHERE session_id = ?
        \\ORDER BY position ASC, agent_name ASC
    , &.{session_id});
    defer rows.deinit();

    var members: std.ArrayList(Member) = .empty;
    errdefer {
        for (members.items) |m| allocator.free(m.name);
        members.deinit(allocator);
    }

    while (try rows.next()) |row| {
        defer row.deinit(allocator);
        try members.append(allocator, .{
            .name = try allocator.dupe(u8, row.values[0]),
            .role = Role.fromText(row.values[1]),
        });
    }
    return members.toOwnedSlice(allocator);
}

/// An empty name clears the lead, which is how a session stops being a group.
/// The roster follows: exactly the named member carries the `lead` role, so
/// the roster the app draws and the lead the loop routes by never disagree.
pub fn setLead(allocator: std.mem.Allocator, db: *database.Db, session_id: []const u8, agent_name: []const u8) !void {
    try db.exec(allocator, "UPDATE sessions SET group_lead = ? WHERE id = ?", &.{ agent_name, session_id });
    try db.exec(allocator, "UPDATE session_group_members SET role = 'worker' WHERE session_id = ?", &.{session_id});
    if (agent_name.len > 0) {
        try db.exec(allocator, "UPDATE session_group_members SET role = 'lead' WHERE session_id = ? AND agent_name = ?", &.{ session_id, agent_name });
    }
}

/// A joining member leads the room when it says so, or when nobody leads yet.
/// The lead is re-applied either way, so a member that joins after the lead was
/// chosen still gets its role written.
pub fn setLeadIfUnset(
    allocator: std.mem.Allocator,
    db: *database.Db,
    session_id: []const u8,
    agent_name: []const u8,
    role_text: []const u8,
) !void {
    const current = try groupLead(allocator, db, session_id);
    defer if (current) |c| allocator.free(c);

    if (Role.fromText(role_text) == .lead or current == null) {
        try setLead(allocator, db, session_id, agent_name);
        return;
    }
    try setLead(allocator, db, session_id, current.?);
}

/// The identity a routed group turn runs under: the member's own name, then its
/// persona when it has one. Without it a member answers as whoever the
/// transcript last named. Caller frees the result.
pub fn speakerIdentity(allocator: std.mem.Allocator, speaker: []const u8, persona: []const u8) ![]u8 {
    if (persona.len == 0) {
        return try std.fmt.allocPrint(allocator, "You are {s}, one of the agents in this chat. Answer as {s}.", .{ speaker, speaker });
    }
    return try std.fmt.allocPrint(allocator, "You are {s}, one of the agents in this chat. Answer as {s}.\n\n{s}", .{ speaker, speaker, persona });
}

/// The persona a turn runs under: the sub-agent's own, else the routed group
/// member's identity, else the group persona. Caller frees the result.
pub fn turnPersona(
    allocator: std.mem.Allocator,
    sub_agent_persona: []const u8,
    group_speaker: []const u8,
    group_persona: []const u8,
) ![]u8 {
    if (sub_agent_persona.len > 0) return try allocator.dupe(u8, sub_agent_persona);
    if (group_speaker.len > 0) return try speakerIdentity(allocator, group_speaker, group_persona);
    return try allocator.dupe(u8, group_persona);
}

/// Null when the session is not a group. Caller frees a non-null result.
pub fn groupLead(allocator: std.mem.Allocator, db: *database.Db, session_id: []const u8) !?[]const u8 {
    var row = db.queryRow(
        allocator,
        "SELECT COALESCE(CAST(group_lead AS TEXT), '') FROM sessions WHERE id = ?",
        &.{session_id},
    ) catch |err| switch (err) {
        error.RowNotFound => return null,
        else => return err,
    };
    defer row.deinit(allocator);

    if (row.values[0].len == 0) return null;
    return try allocator.dupe(u8, row.values[0]);
}

/// How many agent turns the room has taken since the human last spoke. A
/// message from the human resets the count, so the budget bounds one
/// exchange, not the life of the thread.
pub fn hopsSinceHuman(allocator: std.mem.Allocator, db: *database.Db, session_id: []const u8) !u32 {
    var row = try db.queryRow(allocator,
        \\SELECT COUNT(*) FROM llm_history
        \\WHERE session_id = ?
        \\  AND COALESCE(CAST(role AS TEXT), '') = 'assistant'
        \\  AND created_at_nano > COALESCE((
        \\      SELECT MAX(created_at_nano) FROM llm_history
        \\      WHERE session_id = ? AND COALESCE(CAST(role AS TEXT), '') = 'user'
        \\  ), 0)
    , &.{ session_id, session_id });
    defer row.deinit(allocator);

    return std.fmt.parseInt(u32, row.values[0], 10) catch 0;
}

/// The newest row of the thread, as the router needs it. Caller frees both
/// fields of a non-null result.
pub fn lastTurn(allocator: std.mem.Allocator, db: *database.Db, session_id: []const u8) !?LastTurn {
    var row = db.queryRow(allocator,
        \\SELECT COALESCE(CAST(role AS TEXT), ''),
        \\       COALESCE(CAST(agent AS TEXT), ''),
        \\       COALESCE(CAST(response_content AS TEXT), '')
        \\FROM llm_history
        \\WHERE session_id = ?
        \\ORDER BY created_at_nano DESC
        \\LIMIT 1
    , &.{session_id}) catch |err| switch (err) {
        error.RowNotFound => return null,
        else => return err,
    };
    defer row.deinit(allocator);

    const is_agent_row = std.mem.eql(u8, row.values[0], "assistant");
    return .{
        .speaker = try allocator.dupe(u8, if (is_agent_row) row.values[1] else ""),
        .text = try allocator.dupe(u8, row.values[2]),
    };
}

pub const NextSpeaker = struct {
    decision: Decision,
    /// Owned by the caller; the decision's `speak` name points into it.
    members: []Member,
    lead: []const u8,
    hops: u32,

    pub fn deinit(self: *NextSpeaker, allocator: std.mem.Allocator) void {
        allocator.free(self.lead);
        freeMembers(allocator, self.members);
    }
};

/// The production decision the loop makes once per iteration: who speaks now.
/// Null when the session is not a group.
pub fn nextSpeaker(
    allocator: std.mem.Allocator,
    db: *database.Db,
    session_id: []const u8,
    hop_budget: u32,
) !?NextSpeaker {
    const lead = (try groupLead(allocator, db, session_id)) orelse return null;
    errdefer allocator.free(lead);

    const members = try listMembers(allocator, db, session_id);
    errdefer freeMembers(allocator, members);

    const hops = try hopsSinceHuman(allocator, db, session_id);

    const last = try lastTurn(allocator, db, session_id);
    defer if (last) |row| {
        allocator.free(row.speaker);
        allocator.free(row.text);
    };

    const speaker: []const u8 = if (last) |row| row.speaker else "";
    const text: []const u8 = if (last) |row| row.text else "";

    const decision = try router.decide(allocator, members, lead, .{
        .last_speaker = speaker,
        .last_text = text,
        .hops_so_far = hops,
        .hop_budget = hop_budget,
    });

    return .{ .decision = decision, .members = members, .lead = lead, .hops = hops };
}

// ─── Tests ──────────────────────────────────────────────────────────────────

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
    try db.exec(alloc,
        \\CREATE TABLE llm_history (
        \\    id TEXT PRIMARY KEY,
        \\    session_id TEXT NOT NULL,
        \\    role TEXT,
        \\    agent TEXT,
        \\    response_content TEXT,
        \\    created_at_nano INTEGER NOT NULL
        \\)
    , &.{});
    return .{ .db = db, .threaded = threaded };
}

fn insertRow(ctx: *TestCtx, id: []const u8, role: []const u8, agent: []const u8, text: []const u8, at: i64) !void {
    const stamp = try std.fmt.allocPrint(testing.allocator, "{d}", .{at});
    defer testing.allocator.free(stamp);
    try ctx.db.exec(testing.allocator,
        \\INSERT INTO llm_history (id, session_id, role, agent, response_content, created_at_nano)
        \\VALUES (?, 's_1', ?, ?, ?, ?)
    , &.{ id, role, agent, text, stamp });
}

fn seedRoster(ctx: *TestCtx) !void {
    try ctx.db.exec(testing.allocator, "INSERT INTO sessions (id, name, group_lead) VALUES ('s_1', 'room', 'Engineer')", &.{});
    try addMember(testing.allocator, &ctx.db, "s_1", "Engineer", .lead, 0);
    try addMember(testing.allocator, &ctx.db, "s_1", "Security Engineerr", .worker, 1);
    try addMember(testing.allocator, &ctx.db, "s_1", "Android Engineer", .worker, 2);
}

test "a session that is not a group has no next speaker" {
    var ctx = try setupDb();
    defer ctx.db.deinit();
    defer ctx.threaded.deinit();

    try ctx.db.exec(testing.allocator, "INSERT INTO sessions (id, name) VALUES ('s_1', 'plain')", &.{});

    try testing.expect((try nextSpeaker(testing.allocator, &ctx.db, "s_1", 8)) == null);
}

test "a group session with a human message speaks through its lead" {
    var ctx = try setupDb();
    defer ctx.db.deinit();
    defer ctx.threaded.deinit();
    try seedRoster(&ctx);
    try insertRow(&ctx, "h1", "user", "Engineer", "Add rate limiting.", 1);

    var next = (try nextSpeaker(testing.allocator, &ctx.db, "s_1", 8)).?;
    defer next.deinit(testing.allocator);

    try testing.expectEqualStrings("Engineer", next.decision.speak);
    try testing.expectEqual(@as(usize, 3), next.members.len);
}

test "a mention in the last agent row hands the turn to that agent" {
    var ctx = try setupDb();
    defer ctx.db.deinit();
    defer ctx.threaded.deinit();
    try seedRoster(&ctx);
    try insertRow(&ctx, "h1", "user", "Engineer", "Add rate limiting.", 1);
    try insertRow(&ctx, "h2", "assistant", "Engineer", "Audit it first, @Android Engineer.", 2);

    var next = (try nextSpeaker(testing.allocator, &ctx.db, "s_1", 8)).?;
    defer next.deinit(testing.allocator);

    try testing.expectEqualStrings("Android Engineer", next.decision.speak);
}

test "the roster comes back in the order it was added" {
    var ctx = try setupDb();
    defer ctx.db.deinit();
    defer ctx.threaded.deinit();
    try seedRoster(&ctx);

    const members = try listMembers(testing.allocator, &ctx.db, "s_1");
    defer freeMembers(testing.allocator, members);

    try testing.expectEqual(@as(usize, 3), members.len);
    try testing.expectEqualStrings("Engineer", members[0].name);
    try testing.expectEqual(Role.lead, members[0].role);
    try testing.expectEqualStrings("Security Engineerr", members[1].name);
    try testing.expectEqual(Role.worker, members[1].role);
}

test "adding the same agent twice replaces its row instead of duplicating it" {
    var ctx = try setupDb();
    defer ctx.db.deinit();
    defer ctx.threaded.deinit();
    try seedRoster(&ctx);

    try addMember(testing.allocator, &ctx.db, "s_1", "Engineer", .worker, 5);

    var row = try ctx.db.queryRow(testing.allocator, "SELECT COUNT(*) FROM session_group_members WHERE session_id = 's_1'", &.{});
    defer row.deinit(testing.allocator);
    try testing.expectEqualStrings("3", row.values[0]);

    var role = try ctx.db.queryRow(testing.allocator, "SELECT role FROM session_group_members WHERE agent_name = 'Engineer'", &.{});
    defer role.deinit(testing.allocator);
    try testing.expectEqualStrings("worker", role.values[0]);
}

test "a joining member lands at the end of the roster" {
    var ctx = try setupDb();
    defer ctx.db.deinit();
    defer ctx.threaded.deinit();
    try seedRoster(&ctx);

    try addMember(testing.allocator, &ctx.db, "s_1", "deepseek auto", .worker, null);

    const members = try listMembers(testing.allocator, &ctx.db, "s_1");
    defer freeMembers(testing.allocator, members);
    try testing.expectEqualStrings("deepseek auto", members[members.len - 1].name);
}

test "removing a member leaves the rest of the roster alone" {
    var ctx = try setupDb();
    defer ctx.db.deinit();
    defer ctx.threaded.deinit();
    try seedRoster(&ctx);

    try removeMember(testing.allocator, &ctx.db, "s_1", "Security Engineerr");

    const members = try listMembers(testing.allocator, &ctx.db, "s_1");
    defer freeMembers(testing.allocator, members);
    try testing.expectEqual(@as(usize, 2), members.len);
}

test "the hop count starts over when the human speaks again" {
    var ctx = try setupDb();
    defer ctx.db.deinit();
    defer ctx.threaded.deinit();
    try seedRoster(&ctx);

    try insertRow(&ctx, "h1", "user", "Engineer", "first", 1);
    try insertRow(&ctx, "h2", "assistant", "Engineer", "a", 2);
    try insertRow(&ctx, "h3", "assistant", "Security Engineerr", "b", 3);
    try testing.expectEqual(@as(u32, 2), try hopsSinceHuman(testing.allocator, &ctx.db, "s_1"));

    try insertRow(&ctx, "h4", "user", "Engineer", "second", 4);
    try testing.expectEqual(@as(u32, 0), try hopsSinceHuman(testing.allocator, &ctx.db, "s_1"));
}

test "a thread that has spent its hops closes instead of routing another turn" {
    var ctx = try setupDb();
    defer ctx.db.deinit();
    defer ctx.threaded.deinit();
    try seedRoster(&ctx);

    try insertRow(&ctx, "h1", "user", "Engineer", "go", 1);
    try insertRow(&ctx, "h2", "assistant", "Engineer", "@Security Engineerr take it", 2);
    try insertRow(&ctx, "h3", "assistant", "Security Engineerr", "done @Engineer", 3);

    var next = (try nextSpeaker(testing.allocator, &ctx.db, "s_1", 2)).?;
    defer next.deinit(testing.allocator);

    try testing.expectEqual(CloseReason.hop_budget, next.decision.close);
}

test "the group lead is null for a session that never joined a group" {
    var ctx = try setupDb();
    defer ctx.db.deinit();
    defer ctx.threaded.deinit();

    try ctx.db.exec(testing.allocator, "INSERT INTO sessions (id, name) VALUES ('s_1', 'plain')", &.{});

    try testing.expect((try groupLead(testing.allocator, &ctx.db, "s_1")) == null);
}

test "a routed member is told its own name when it has no persona" {
    const identity = try speakerIdentity(testing.allocator, "deepseek auto", "");
    defer testing.allocator.free(identity);

    try testing.expectEqualStrings(
        "You are deepseek auto, one of the agents in this chat. Answer as deepseek auto.",
        identity,
    );
}

test "a routed member keeps its persona under its own name" {
    const identity = try speakerIdentity(testing.allocator, "BEAM", "You are a strict code reviewer.");
    defer testing.allocator.free(identity);

    try testing.expectEqualStrings(
        "You are BEAM, one of the agents in this chat. Answer as BEAM.\n\nYou are a strict code reviewer.",
        identity,
    );
}

test "a sub-agent turn keeps its own persona and gains no group identity" {
    const persona = try turnPersona(testing.allocator, "You are a strict code reviewer.", "BEAM", "group persona");
    defer testing.allocator.free(persona);

    try testing.expectEqualStrings("You are a strict code reviewer.", persona);
}

test "a routed group turn runs under the member's identity" {
    const persona = try turnPersona(testing.allocator, "", "deepseek auto", "");
    defer testing.allocator.free(persona);

    try testing.expectEqualStrings(
        "You are deepseek auto, one of the agents in this chat. Answer as deepseek auto.",
        persona,
    );
}

test "a turn that is neither a sub-agent nor a group keeps the group persona" {
    const persona = try turnPersona(testing.allocator, "", "", "");
    defer testing.allocator.free(persona);

    try testing.expectEqualStrings("", persona);
}
