//! `pabrik headless mcp-add` — register an MCP server through the SAME
//! `execAddMcpServer` path the agent tool uses, with no server and no port.

const std = @import("std");
const pabrikcore = @import("pabrikcore");

const args = @import("args.zig");
const boot_mod = @import("boot.zig");

pub fn addServer(
    allocator: std.mem.Allocator,
    backend: *boot_mod.Backend,
    a: args.McpAddArgs,
) ![]u8 {
    var temperature: f32 = 0;
    var thinking = false;

    const ctx = pabrikcore.agent_loop_tools.ToolExecContext{
        .allocator = allocator,
        .io = backend.io,
        .db = backend.ctx.db,
        .logger = backend.logger,
        .session_id = a.session_id,
        .model = "",
        .cwd = "",
        .api_key = "",
        .base_url = "",
        .config = backend.llm_config_ptr,
        .agent_temperature = &temperature,
        .is_thinking = &thinking,
        .environment = backend.environment,
    };

    const arguments = try std.json.Stringify.valueAlloc(allocator, .{
        .name = a.name,
        .transport = a.transport,
        .command = a.command,
        .args = a.args,
        .url = a.url,
    }, .{});
    defer allocator.free(arguments);

    const tc = pabrikcore.agent.ToolCall{
        .id = "headless-mcp-add",
        .function = .{ .name = "add_mcp_server", .arguments = arguments },
    };

    const result = try pabrikcore.add_mcp_server.execAddMcpServer(ctx, tc);
    if (result.output_allocated) return @constCast(result.output);
    return allocator.dupe(u8, result.output);
}
