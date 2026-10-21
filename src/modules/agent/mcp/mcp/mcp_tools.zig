const std = @import("std");
const json = std.json;
const mcp_types = @import("mcp_types.zig");
const mcp_server = @import("mcp_server.zig");
const schemas = @import("../../tools/schemas.zig");
const AgentTool = schemas.AgentTool;

pub const ToolAdapter = struct {
    allocator: std.mem.Allocator,
    tools: std.StringHashMap(AgentTool),

    const Self = @This();

    pub fn init(allocator: std.mem.Allocator) Self {
        return .{
            .allocator = allocator,
            .tools = std.StringHashMap(AgentTool).init(allocator),
        };
    }

    pub fn deinit(self: *Self) void {
        self.tools.deinit();
    }

    pub fn register_agent_tool(self: *Self, tool: AgentTool) !void {
        try self.tools.put(tool.function.name, tool);
    }

    /// Convert AgentTool to McpTool
    pub fn to_mcp_tool(self: *Self, agent_tool: AgentTool) !mcp_types.McpTool {
        var props_buf = std.ArrayList(u8).init(self.allocator);
        defer props_buf.deinit();

        try props_buf.appendSlice("{\"type\":\"object\",\"properties\":{");

        const props = agent_tool.function.parameters.properties;
        var first = true;
        for (props) |prop| {
            if (!first) try props_buf.append(',');
            first = false;

            try props_buf.append('"');
            try props_buf.appendSlice(prop.name);
            try props_buf.appendSlice("\":{\"type\":\"");
            try props_buf.appendSlice(prop.type);
            try props_buf.appendSlice("\",\"description\":\"");
            try props_buf.appendSlice(prop.description);
            try props_buf.append('"');
        }

        try props_buf.appendSlice("}}");

        return .{
            .name = agent_tool.function.name,
            .description = agent_tool.function.description,
            .inputSchema = .{
                .type = "object",
                .properties = .{},
                .required = agent_tool.function.parameters.required,
            },
        };
    }

    /// Create tool executor that calls registered agent tools
    pub fn create_executor(self: *Self) mcp_server.ToolExecutor {
        const adapter = self;
        return struct {
            fn exec(
                _: std.mem.Allocator,
                name: []const u8,
                arguments: ?json.Value,
            ) anyerror!json.Value {
                const tool = adapter.tools.get(name) orelse {
                    return error.ToolNotFound;
                };

                _ = arguments;
                _ = tool;

                return .{ .string = "not implemented" };
            }
        }.exec;
    }
};
