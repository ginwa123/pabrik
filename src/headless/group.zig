//! `pabrik headless group` — drive a multi-agent session with no server.
//! The writes are the rows the loop reads and `next` asks the loop's own
//! router, so the answer is the decision the next turn will take.

const std = @import("std");
const pabrikcore = @import("pabrikcore");
const boot_mod = @import("boot.zig");
const args = @import("args.zig");

const database = pabrikcore.database;
const session_group = pabrikcore.session_group;
const http_handlers = pabrikcore.http_handlers;

pub fn run(
    allocator: std.mem.Allocator,
    backend: *boot_mod.Backend,
    a: args.GroupArgs,
) ![]u8 {
    return runWithDb(allocator, backend.ctx.db, a);
}

pub fn runWithDb(
    allocator: std.mem.Allocator,
    db: *database.Db,
    a: args.GroupArgs,
) ![]u8 {
    switch (a.op) {
        .create => {
            const session_id = try session_group.createGroupSession(allocator, db, "Agents group", "");
            defer allocator.free(session_id);
            return roster(allocator, db, .join, session_id, a.agent, a.role);
        },
        .join => return roster(allocator, db, .join, a.session_id, a.agent, a.role),
        .leave => return roster(allocator, db, .leave, a.session_id, a.agent, ""),
        .lead => return roster(allocator, db, .lead, a.session_id, a.agent, ""),
        .members => return roster(allocator, db, .members, a.session_id, "", ""),
        .next => return next(allocator, db, a),
    }
}

/// The roster the HTTP endpoints answer with. Every op but `next` runs the
/// same useCase the matching `/api/llm/session/:id/group...` handler runs, so
/// the CLI and the app cannot drift.
fn roster(
    allocator: std.mem.Allocator,
    db: *database.Db,
    op: args.GroupOp,
    session_id: []const u8,
    agent: []const u8,
    role: []const u8,
) ![]u8 {
    const outcome = switch (op) {
        .join => http_handlers.sessionGroupAddMemberUseCase(allocator, db, session_id, agent, role),
        .leave => http_handlers.sessionGroupRemoveMemberUseCase(allocator, db, session_id, agent),
        .lead => http_handlers.sessionGroupSetLeadUseCase(allocator, db, session_id, agent),
        else => http_handlers.sessionGroupRosterUseCase(allocator, db, session_id),
    };

    const resolved = outcome catch |err| return err;
    defer http_handlers.sessionGroupFreeRoster(allocator, resolved);
    return http_handlers.sessionGroupEncodeRoster(allocator, resolved);
}

fn next(allocator: std.mem.Allocator, db: *database.Db, a: args.GroupArgs) ![]u8 {
    const budget = if (a.budget == 0) session_group.default_hop_budget else a.budget;

    var buf: std.ArrayList(u8) = .empty;
    errdefer buf.deinit(allocator);

    const decided = try session_group.nextSpeaker(allocator, db, a.session_id, budget);

    try buf.appendSlice(allocator, "{\"session_id\":");
    try appendJsonString(allocator, &buf, a.session_id);
    try buf.appendSlice(allocator, ",\"group\":");
    try buf.appendSlice(allocator, if (decided != null) "true" else "false");

    if (decided) |speaker| {
        var resolved = speaker;
        defer resolved.deinit(allocator);

        const budget_text = try std.fmt.allocPrint(allocator, "{d}", .{budget});
        defer allocator.free(budget_text);
        const hops_text = try std.fmt.allocPrint(allocator, "{d}", .{resolved.hops});
        defer allocator.free(hops_text);

        try buf.appendSlice(allocator, ",\"lead\":");
        try appendJsonString(allocator, &buf, resolved.lead);
        try buf.appendSlice(allocator, ",\"hops\":");
        try buf.appendSlice(allocator, hops_text);
        try buf.appendSlice(allocator, ",\"budget\":");
        try buf.appendSlice(allocator, budget_text);

        switch (resolved.decision) {
            .speak => |name| {
                try buf.appendSlice(allocator, ",\"action\":\"speak\",\"agent\":");
                try appendJsonString(allocator, &buf, name);
            },
            .close => |reason| {
                try buf.appendSlice(allocator, ",\"action\":\"close\",\"reason\":");
                try appendJsonString(allocator, &buf, @tagName(reason));
            },
        }
    }
    try buf.appendSlice(allocator, "}");
    return buf.toOwnedSlice(allocator);
}

pub fn appendJsonString(allocator: std.mem.Allocator, buf: *std.ArrayList(u8), value: []const u8) !void {
    try buf.append(allocator, '"');
    for (value) |c| {
        switch (c) {
            '"' => try buf.appendSlice(allocator, "\\\""),
            '\\' => try buf.appendSlice(allocator, "\\\\"),
            '\n' => try buf.appendSlice(allocator, "\\n"),
            '\r' => try buf.appendSlice(allocator, "\\r"),
            '\t' => try buf.appendSlice(allocator, "\\t"),
            else => try buf.append(allocator, c),
        }
    }
    try buf.append(allocator, '"');
}

// ─── Tests ─────────────────────────────────────────────────────────────────

const testing = std.testing;
const test_db = pabrikcore.test_db;

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
    try db.exec(alloc, "CREATE TABLE sessions (id TEXT PRIMARY KEY, name TEXT NOT NULL DEFAULT '', status TEXT NOT NULL DEFAULT 'active', group_lead TEXT)", &.{});
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
    try db.exec(alloc, "INSERT INTO sessions (id, name) VALUES ('s_1', 'room')", &.{});
    return .{ .db = db, .threaded = threaded };
}

fn join(ctx: *TestCtx, agent: []const u8, role: []const u8, position: u32) ![]u8 {
    return runWithDb(testing.allocator, &ctx.db, .{
        .op = .join,
        .session_id = "s_1",
        .agent = agent,
        .role = role,
        .position = position,
    });
}

test "group join prints the roster the loop will read" {
    var ctx = try setupDb();
    defer ctx.db.deinit();
    defer ctx.threaded.deinit();

    const json = try join(&ctx, "Engineer", "lead", 0);
    defer testing.allocator.free(json);
    try testing.expectEqualStrings(
        "{\"session_id\":\"s_1\",\"group\":true,\"lead\":\"Engineer\",\"members\":[{\"name\":\"Engineer\",\"role\":\"lead\"}]}",
        json,
    );
}

test "group join keeps the order the members joined in" {
    var ctx = try setupDb();
    defer ctx.db.deinit();
    defer ctx.threaded.deinit();

    const first = try join(&ctx, "Engineer", "lead", 0);
    testing.allocator.free(first);
    const second = try join(&ctx, "Security Engineerr", "worker", 1);
    testing.allocator.free(second);
    const third = try join(&ctx, "Android Engineer", "worker", 2);
    defer testing.allocator.free(third);

    try testing.expect(std.mem.indexOf(u8, third, "\"name\":\"Engineer\",\"role\":\"lead\"]") == null);
    try testing.expect(std.mem.indexOf(u8, third, "\"Engineer\",\"role\":\"lead\"},{\"name\":\"Security Engineerr\"") != null);
    try testing.expect(std.mem.indexOf(u8, third, "{\"name\":\"Android Engineer\",\"role\":\"worker\"}") != null);
}

test "group join with the lead role names the group lead" {
    var ctx = try setupDb();
    defer ctx.db.deinit();
    defer ctx.threaded.deinit();

    const json = try join(&ctx, "Engineer", "lead", 0);
    defer testing.allocator.free(json);

    try testing.expect(std.mem.indexOf(u8, json, "\"group\":true") != null);
    try testing.expect(std.mem.indexOf(u8, json, "\"lead\":\"Engineer\"") != null);
}

test "a session with no members is not a group and has no next speaker" {
    var ctx = try setupDb();
    defer ctx.db.deinit();
    defer ctx.threaded.deinit();

    const json = try runWithDb(testing.allocator, &ctx.db, .{ .op = .next, .session_id = "s_1" });
    defer testing.allocator.free(json);

    try testing.expect(std.mem.indexOf(u8, json, "\"group\":false") != null);
    try testing.expect(std.mem.indexOf(u8, json, "action") == null);
}

test "group next names the agent the router picked and the hops it counted" {
    var ctx = try setupDb();
    defer ctx.db.deinit();
    defer ctx.threaded.deinit();

    const joined = try join(&ctx, "Engineer", "lead", 0);
    testing.allocator.free(joined);
    const joined2 = try join(&ctx, "Security Engineerr", "worker", 1);
    testing.allocator.free(joined2);

    try ctx.db.exec(testing.allocator,
        \\INSERT INTO llm_history (id, session_id, role, agent, response_content, created_at_nano)
        \\VALUES ('h1', 's_1', 'user', 'Engineer', 'audit it', 1),
        \\       ('h2', 's_1', 'assistant', 'Engineer', 'over to @security-engineerr', 2)
    , &.{});

    const json = try runWithDb(testing.allocator, &ctx.db, .{ .op = .next, .session_id = "s_1" });
    defer testing.allocator.free(json);

    try testing.expect(std.mem.indexOf(u8, json, "\"action\":\"speak\"") != null);
    try testing.expect(std.mem.indexOf(u8, json, "\"agent\":\"Security Engineerr\"") != null);
    try testing.expect(std.mem.indexOf(u8, json, "\"hops\":1") != null);
    try testing.expect(std.mem.indexOf(u8, json, "\"budget\":8") != null);
}

test "group next closes the turn when the budget is spent" {
    var ctx = try setupDb();
    defer ctx.db.deinit();
    defer ctx.threaded.deinit();

    const joined = try join(&ctx, "Engineer", "lead", 0);
    testing.allocator.free(joined);
    const joined2 = try join(&ctx, "Security Engineerr", "worker", 1);
    testing.allocator.free(joined2);

    try ctx.db.exec(testing.allocator,
        \\INSERT INTO llm_history (id, session_id, role, agent, response_content, created_at_nano)
        \\VALUES ('h1', 's_1', 'user', 'Engineer', 'audit it', 1),
        \\       ('h2', 's_1', 'assistant', 'Engineer', 'over to @security-engineerr', 2),
        \\       ('h3', 's_1', 'assistant', 'Security Engineerr', 'back to @engineer', 3)
    , &.{});

    const json = try runWithDb(testing.allocator, &ctx.db, .{ .op = .next, .session_id = "s_1", .budget = 2 });
    defer testing.allocator.free(json);

    try testing.expect(std.mem.indexOf(u8, json, "\"action\":\"close\"") != null);
    try testing.expect(std.mem.indexOf(u8, json, "\"reason\":\"hop_budget\"") != null);
}

test "group leave takes one member out and leaves the roster readable" {
    var ctx = try setupDb();
    defer ctx.db.deinit();
    defer ctx.threaded.deinit();

    const joined = try join(&ctx, "Engineer", "lead", 0);
    testing.allocator.free(joined);
    const joined2 = try join(&ctx, "Android Engineer", "worker", 1);
    testing.allocator.free(joined2);

    const json = try runWithDb(testing.allocator, &ctx.db, .{
        .op = .leave,
        .session_id = "s_1",
        .agent = "Android Engineer",
    });
    defer testing.allocator.free(json);

    try testing.expect(std.mem.indexOf(u8, json, "Android Engineer") == null);
    try testing.expect(std.mem.indexOf(u8, json, "\"Engineer\",\"role\":\"lead\"") != null);
}

test "group lead hands the turn to a different member" {
    var ctx = try setupDb();
    defer ctx.db.deinit();
    defer ctx.threaded.deinit();

    const joined = try join(&ctx, "Engineer", "worker", 0);
    testing.allocator.free(joined);
    const joined2 = try join(&ctx, "Security Engineerr", "worker", 1);
    testing.allocator.free(joined2);

    const json = try runWithDb(testing.allocator, &ctx.db, .{
        .op = .lead,
        .session_id = "s_1",
        .agent = "Security Engineerr",
    });
    defer testing.allocator.free(json);

    try testing.expect(std.mem.indexOf(u8, json, "\"lead\":\"Security Engineerr\"") != null);

    const decided = try runWithDb(testing.allocator, &ctx.db, .{ .op = .next, .session_id = "s_1" });
    defer testing.allocator.free(decided);
    try testing.expect(std.mem.indexOf(u8, decided, "\"agent\":\"Security Engineerr\"") != null);
}
