const std = @import("std");
const schemas = @import("schemas.zig");
const AgentTool = schemas.AgentTool;

pub const DelegateAgentInput = struct {
    agent_name: []const u8 = "",
    message: []const u8 = "",
};

pub const delegate_agent_tool_system_prompt =
    \\## Delegate Agent Tool — Behavior
    \\Use `delegate_agent` to hand the turn to another agent in THIS chat.
    \\- `agent_name` is any agent the workspace configures — a roster member, or the chat's own agent. Call `list_agents` to see them. A chat with no roster still has its own agent, so delegation works there too.
    \\- `message` is what you are asking that agent. Write it as a complete request: the other agent does not see your reasoning, only this message and the chat history.
    \\- The turn changes hands: you stop speaking, the named agent answers next in the same chat, and the human sees its reply. You do not get a reply back inside this turn.
    \\- Use it when the job belongs to another agent's expertise or persona, not to dodge work you can do yourself.
    \\
;

pub const delegate_agent_tool = AgentTool{
    .type = "function",
    .function = .{
        .name = "delegate_agent",
        .description =
        \\Hand the turn to another agent in this chat. The named agent answers next, in the same session, and the human sees its reply. Use it when the job belongs to another agent's expertise or persona. Any configured agent can be addressed, including the chat's own agent; a roster is not required.
        ,
        .parameters = .{
            .type = "object",
            .properties = &.{
                .{
                    .name = "agent_name",
                    .type = "string",
                    .description = "The agent to hand the turn to. Any agent the workspace configures (see list_agents), including the chat's own agent.",
                },
                .{
                    .name = "message",
                    .type = "string",
                    .description = "What you are asking that agent. Self-contained: the other agent sees this message and the chat history, not your reasoning.",
                },
            },
            .required = &.{ "agent_name", "message" },
        },
        .system_prompt = delegate_agent_tool_system_prompt,
    },
};

const pabrikcore = @import("pabrikcore");
const tools = @import("../loop/tools.zig");
const session_group = @import("../loop/session_group.zig");
const database = pabrikcore.database;
const agent = pabrikcore.agent;
const ToolExecContext = tools.ToolExecContext;
const ToolExecResult = tools.ToolExecResult;
const wrapToolOutput = tools.wrapToolOutput;
const error_explain = @import("tools_error_explain.zig");

const DelegateOutcome = struct {
    ok: bool,
    json: []u8,
};

fn errorJson(allocator: std.mem.Allocator, message: []const u8) ![]u8 {
    return try std.json.Stringify.valueAlloc(allocator, .{ .@"error" = message }, .{});
}

/// Record the delegation and answer with the payload the caller sees. A
/// refusal is a payload with an `error` field, not a Zig error: the model
/// reads it and can retry with a name that exists.
pub fn delegateToAgent(
    allocator: std.mem.Allocator,
    db: *database.Db,
    session_id: []const u8,
    agent_name: []const u8,
    message: []const u8,
) !DelegateOutcome {
    const wanted = std.mem.trim(u8, agent_name, " \t\r\n");
    const text = std.mem.trim(u8, message, " \t\r\n");

    if (wanted.len == 0) {
        return .{ .ok = false, .json = try errorJson(allocator, "agent_name is required: name the agent that should answer.") };
    }
    if (text.len == 0) {
        return .{ .ok = false, .json = try errorJson(allocator, "message is required: say what you are asking that agent.") };
    }

    const members = try session_group.listMembers(allocator, db, session_id);
    defer session_group.freeMembers(allocator, members);

    // The roster is not a gate: a chat with no members still has its own agent,
    // and the caller may address any agent by name. The roster only supplies the
    // spelling when it has one.
    var target: ?[]const u8 = null;
    for (members) |m| {
        if (std.ascii.eqlIgnoreCase(m.name, wanted)) {
            target = m.name;
            break;
        }
    }
    const name = target orelse wanted;

    const lead = try session_group.groupLead(allocator, db, session_id);
    defer if (lead) |l| allocator.free(l);
    if (lead == null and members.len > 0) {
        try session_group.setLead(allocator, db, session_id, members[0].name);
    }

    try session_group.setPendingDelegate(allocator, db, session_id, name);

    const json = try std.json.Stringify.valueAlloc(allocator, .{
        .delegated_to = name,
        .message = text,
        .note = "The turn is now theirs. Stop speaking: do not answer for them.",
    }, .{});
    return .{ .ok = true, .json = json };
}

pub fn execDelegateAgent(ctx: ToolExecContext, tc: agent.ToolCall) !ToolExecResult {
    const parsed = std.json.parseFromSlice(
        DelegateAgentInput,
        ctx.allocator,
        tc.function.arguments,
        .{ .allocate = .alloc_always, .ignore_unknown_fields = true },
    ) catch |err| {
        const err_msg = try error_explain.explain(ctx.allocator, err, null);
        defer ctx.allocator.free(err_msg);
        const output = try wrapToolOutput(ctx.allocator, "delegate_agent", tc.function.arguments, false, err_msg, "");
        return ToolExecResult{ .output = output, .output_allocated = true };
    };
    defer parsed.deinit();

    const outcome = delegateToAgent(
        ctx.allocator,
        ctx.db,
        ctx.session_id,
        parsed.value.agent_name,
        parsed.value.message,
    ) catch |err| {
        const err_msg = try error_explain.explain(ctx.allocator, err, null);
        defer ctx.allocator.free(err_msg);
        const output = try wrapToolOutput(ctx.allocator, "delegate_agent", tc.function.arguments, false, err_msg, "");
        return ToolExecResult{ .output = output, .output_allocated = true };
    };
    defer ctx.allocator.free(outcome.json);

    const output = if (outcome.ok)
        try wrapToolOutput(ctx.allocator, "delegate_agent", tc.function.arguments, true, null, outcome.json)
    else
        try wrapToolOutput(ctx.allocator, "delegate_agent", tc.function.arguments, false, outcome.json, "");
    return ToolExecResult{ .output = output, .output_allocated = true };
}

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
    try db.exec(alloc,
        \\CREATE TABLE sessions (
        \\    id TEXT PRIMARY KEY,
        \\    name TEXT NOT NULL DEFAULT '',
        \\    status TEXT NOT NULL DEFAULT 'active',
        \\    group_lead TEXT,
        \\    pending_delegate TEXT
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
    return .{ .db = db, .threaded = threaded };
}

fn seedRoster(ctx: *TestCtx) !void {
    try ctx.db.exec(testing.allocator, "INSERT INTO sessions (id, name, group_lead) VALUES ('s_1', 'room', 'BEAM')", &.{});
    try session_group.addMember(testing.allocator, &ctx.db, "s_1", "BEAM", .lead, 0);
    try session_group.addMember(testing.allocator, &ctx.db, "s_1", "deepseek auto", .worker, 1);
}

fn pendingOf(ctx: *TestCtx) !?[]const u8 {
    return try session_group.takePendingDelegate(testing.allocator, &ctx.db, "s_1");
}

test "delegating to a roster member hands the next turn to that agent" {
    var ctx = try setupDb();
    defer ctx.db.deinit();
    defer ctx.threaded.deinit();
    try seedRoster(&ctx);

    const outcome = try delegateToAgent(testing.allocator, &ctx.db, "s_1", "deepseek auto", "What is the retry policy?");
    defer testing.allocator.free(outcome.json);
    try testing.expect(outcome.ok);

    const pending = (try pendingOf(&ctx)).?;
    defer testing.allocator.free(pending);
    try testing.expectEqualStrings("deepseek auto", pending);
}

test "the delegation payload names the agent and carries the message" {
    var ctx = try setupDb();
    defer ctx.db.deinit();
    defer ctx.threaded.deinit();
    try seedRoster(&ctx);

    const outcome = try delegateToAgent(testing.allocator, &ctx.db, "s_1", "deepseek auto", "What is the retry policy?");
    defer testing.allocator.free(outcome.json);

    const parsed = try std.json.parseFromSlice(std.json.Value, testing.allocator, outcome.json, .{});
    defer parsed.deinit();
    try testing.expectEqualStrings("deepseek auto", parsed.value.object.get("delegated_to").?.string);
    try testing.expectEqualStrings("What is the retry policy?", parsed.value.object.get("message").?.string);
}

test "a name outside the roster is still honoured" {
    var ctx = try setupDb();
    defer ctx.db.deinit();
    defer ctx.threaded.deinit();
    try seedRoster(&ctx);

    const outcome = try delegateToAgent(testing.allocator, &ctx.db, "s_1", "ghost", "hello?");
    defer testing.allocator.free(outcome.json);
    try testing.expect(outcome.ok);

    const pending = (try pendingOf(&ctx)).?;
    defer testing.allocator.free(pending);
    try testing.expectEqualStrings("ghost", pending);
}

test "a chat with no roster still delegates" {
    var ctx = try setupDb();
    defer ctx.db.deinit();
    defer ctx.threaded.deinit();
    try ctx.db.exec(testing.allocator, "INSERT INTO sessions (id, name) VALUES ('s_1', 'plain')", &.{});

    const outcome = try delegateToAgent(testing.allocator, &ctx.db, "s_1", "deepseek auto", "hello?");
    defer testing.allocator.free(outcome.json);
    try testing.expect(outcome.ok);

    const pending = (try pendingOf(&ctx)).?;
    defer testing.allocator.free(pending);
    try testing.expectEqualStrings("deepseek auto", pending);
}

test "an empty message is refused" {
    var ctx = try setupDb();
    defer ctx.db.deinit();
    defer ctx.threaded.deinit();
    try seedRoster(&ctx);

    const outcome = try delegateToAgent(testing.allocator, &ctx.db, "s_1", "deepseek auto", "   ");
    defer testing.allocator.free(outcome.json);
    try testing.expect(!outcome.ok);
    try testing.expect((try pendingOf(&ctx)) == null);
}

test "an empty agent name is refused" {
    var ctx = try setupDb();
    defer ctx.db.deinit();
    defer ctx.threaded.deinit();
    try seedRoster(&ctx);

    const outcome = try delegateToAgent(testing.allocator, &ctx.db, "s_1", "", "hello?");
    defer testing.allocator.free(outcome.json);
    try testing.expect(!outcome.ok);
}

test "the roster's spelling wins over the caller's casing" {
    var ctx = try setupDb();
    defer ctx.db.deinit();
    defer ctx.threaded.deinit();
    try seedRoster(&ctx);

    const outcome = try delegateToAgent(testing.allocator, &ctx.db, "s_1", "DEEPSEEK AUTO", "hello?");
    defer testing.allocator.free(outcome.json);
    try testing.expect(outcome.ok);

    const pending = (try pendingOf(&ctx)).?;
    defer testing.allocator.free(pending);
    try testing.expectEqualStrings("deepseek auto", pending);
}

test "a roster with no lead gets one so the delegation can route" {
    var ctx = try setupDb();
    defer ctx.db.deinit();
    defer ctx.threaded.deinit();
    try ctx.db.exec(testing.allocator, "INSERT INTO sessions (id, name) VALUES ('s_1', 'room')", &.{});
    try session_group.addMember(testing.allocator, &ctx.db, "s_1", "BEAM", .worker, 0);
    try session_group.addMember(testing.allocator, &ctx.db, "s_1", "deepseek auto", .worker, 1);

    const outcome = try delegateToAgent(testing.allocator, &ctx.db, "s_1", "deepseek auto", "hello?");
    defer testing.allocator.free(outcome.json);
    try testing.expect(outcome.ok);

    const lead = (try session_group.groupLead(testing.allocator, &ctx.db, "s_1")).?;
    defer testing.allocator.free(lead);
    try testing.expectEqualStrings("BEAM", lead);
}

test "a delegation survives until the turn that consumes it" {
    var ctx = try setupDb();
    defer ctx.db.deinit();
    defer ctx.threaded.deinit();
    try seedRoster(&ctx);

    const outcome = try delegateToAgent(testing.allocator, &ctx.db, "s_1", "deepseek auto", "hello?");
    defer testing.allocator.free(outcome.json);

    const first = (try pendingOf(&ctx)).?;
    defer testing.allocator.free(first);
    try testing.expectEqualStrings("deepseek auto", first);
    try testing.expect((try pendingOf(&ctx)) == null);
}
