//! GET /test/system-prompt/:session_id Returns ONLY the system prompt that
//! would be sent to the LLM for the given session, rendered through the same
//! `buildMessages` pipeline the production workflow uses

const std = @import("std");
const pabrikcore = @import("pabrikcore");
const gserverz = pabrikcore.gserverz;
const http_response = @import("http_response.zig");
const llm_history = pabrikcore.llm_history;
const agent = pabrikcore.agent;
const tool_models = pabrikcore.tool_models;

const buildMessages = @import("../agentic_loop/prompts_build_messages_for_agent_prompt.zig").buildMessages;

const agentic_loop = @import("../agentic_loop/workflow.zig");
const Backend = pabrikcore.database.Db;

/// JSON response struct. `size_bytes` is the byte length of the rendered
/// `system_prompt` so callers can sanity-check they got a non-empty prompt
/// without re-counting bytes on the client.
const SystemPromptResponse = struct {
    session_id: []const u8,
    system_prompt: []const u8,
    size_bytes: u32,
};

pub fn systemPromptGetHandler(
    ctx: gserverz.HttpContext,
    req: gserverz.HttpRequest,
    res: gserverz.HttpResponse,
) !gserverz.HttpResponse {
    const allocator = ctx.allocator;

    const session_id = req.params.get("session_id") orelse "";
    if (session_id.len == 0) {
        return res.jsonResponse(.{
            .status_code = 400,
            .data = try http_response.makeErrorResponse(allocator, .{ .@"error" = "Missing session_id" }),
        });
    }

    const di = try pabrikcore.getSingleton();
    const sqlite_db = di.db;
    const io = di.io;

    // Recover the working directory from the session row. A missing row
    // is a 404 — we cannot build a meaningful system prompt without a cwd
    // (the memory loader + workspace context both depend on it).
    const cwd = blk: {
        const session_row_opt = llm_history.get_session(allocator, sqlite_db, session_id) catch null;
        if (session_row_opt) |session| {
            if (session.cwd.len > 0) {
                break :blk try allocator.dupe(u8, session.cwd);
            }
        }
        break :blk null;
    };
    if (cwd == null) {
        return res.jsonResponse(.{
            .status_code = 404,
            .data = try http_response.makeErrorResponse(allocator, .{ .@"error" = "Session not found" }),
        });
    }
    const cwd_str: []const u8 = cwd.?;

    // Load the DB-stored message history (same shape `workflow.zig` uses
    // before calling buildMessages).
    const db_messages = agentic_loop.getLLMHistories(*Backend, .{
        .allocator = allocator,
        .db = sqlite_db,
        .session_id = session_id,
    }) catch {
        return res.jsonResponse(.{
            .status_code = 500,
            .data = try http_response.makeErrorResponse(allocator, .{ .@"error" = "getMessages failed" }),
        });
    };

    // Mirrors workflow.zig:509's call shape: empty parent_session_id, empty
    // inherited_context, empty activeAgentContent (which falls back to
    // BuildDynamicAgentContent — the main-agent flow's source of truth via
    const merged_tools: []tool_models.AgentTool = &.{};
    const messages = buildMessages(
        allocator,
        io,
        sqlite_db,
        cwd_str,
        session_id,
        "",
        db_messages,
        merged_tools,
        "",
        "",
    ) catch {
        return res.jsonResponse(.{
            .status_code = 500,
            .data = try http_response.makeErrorResponse(allocator, .{ .@"error" = "buildMessages failed" }),
        });
    };
    defer {
        for (messages) |*msg| msg.deinit(allocator);
        allocator.free(messages);
    }

    // buildMessages always emits messages[0] as the system message (see
    // prompts_build_messages_for_agent_prompt.zig:131). Defensive: also check
    // the role so we never silently leak a different role's content.
    if (messages.len == 0 or messages[0].role != .system) {
        return res.jsonResponse(.{
            .status_code = 500,
            .data = try http_response.makeErrorResponse(allocator, .{ .@"error" = "buildMessages returned no system message" }),
        });
    }

    const system_prompt = messages[0].content orelse "";

    const response = SystemPromptResponse{
        .session_id = session_id,
        .system_prompt = system_prompt,
        .size_bytes = @intCast(system_prompt.len),
    };
    const json_str = try std.json.Stringify.valueAlloc(allocator, response, .{});

    return res.jsonResponse(.{ .status_code = 200, .data = json_str });
}
