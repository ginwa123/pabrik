const std = @import("std");
const json = std.json;
const mcp_types = @import("mcp_types.zig");
const mcp_transport = @import("mcp_transport.zig");

/// MCP Server error types
pub const McpError = error{
    ParseError,
    InvalidRequest,
    MethodNotFound,
    InvalidParams,
    InternalError,
};

/// Tool executor function type
pub const ToolExecutor = fn (
    allocator: std.mem.Allocator,
    name: []const u8,
    arguments: ?std.json.Value,
) anyerror!std.json.Value;

// ============ JSON Response Types with jsonStringify ============

/// Initialize result response
const InitializeResult = struct {
    protocolVersion: []const u8,
    capabilities: InitializeCapabilities,
    serverInfo: ServerInfo,

    const InitializeCapabilities = struct {
        tools: ?ToolsCapability = null,
        resources: ?ResourcesCapability = null,
    };

    const ToolsCapability = struct {
        listChanged: bool = false,
    };

    const ResourcesCapability = struct {
        subscribe: bool = false,
        listChanged: bool = false,
    };

    const ServerInfo = struct {
        name: []const u8,
        version: []const u8,
    };

    pub fn jsonStringify(self: @This(), jws: anytype) !void {
        try jws.beginObject();
        try jws.objectField("protocolVersion");
        try jws.write(self.protocolVersion);
        try jws.objectField("capabilities");
        try jws.write(self.capabilities);
        try jws.objectField("serverInfo");
        try jws.write(self.serverInfo);
        try jws.endObject();
    }
};

/// List tools response
const ListToolsResult = struct {
    tools: []const mcp_types.McpTool,

    pub fn jsonStringify(self: @This(), jws: anytype) !void {
        try jws.beginObject();
        try jws.objectField("tools");
        try jws.write(self.tools);
        try jws.endObject();
    }
};

/// List resources response
const ListResourcesResult = struct {
    resources: []const mcp_types.Resource,

    pub fn jsonStringify(self: @This(), jws: anytype) !void {
        try jws.beginObject();
        try jws.objectField("resources");
        try jws.write(self.resources);
        try jws.endObject();
    }
};

/// Read resource result
const ReadResourceResult = struct {
    contents: []const mcp_types.ResourceContents,

    pub fn jsonStringify(self: @This(), jws: anytype) !void {
        try jws.beginObject();
        try jws.objectField("contents");
        try jws.write(self.contents);
        try jws.endObject();
    }
};

/// Call tool result
const CallToolResult = struct {
    content: []const ContentBlock,
    isError: bool = false,

    const ContentBlock = struct {
        type: []const u8,
        text: ?[]const u8 = null,

        pub fn jsonStringify(self: @This(), jws: anytype) !void {
            try jws.beginObject();
            try jws.objectField("type");
            try jws.write(self.type);
            if (self.text) |t| {
                try jws.objectField("text");
                try jws.write(t);
            }
            try jws.endObject();
        }
    };

    pub fn jsonStringify(self: @This(), jws: anytype) !void {
        try jws.beginObject();
        try jws.objectField("content");
        try jws.write(self.content);
        try jws.objectField("isError");
        try jws.write(self.isError);
        try jws.endObject();
    }
};

/// JSON-RPC response
const JsonRpcResponse = struct {
    jsonrpc: []const u8 = "2.0",
    id: ?json.Value,
    result: ?json.Value = null,

    pub fn jsonStringify(self: @This(), jws: anytype) !void {
        try jws.beginObject();
        try jws.objectField("jsonrpc");
        try jws.write(self.jsonrpc);
        if (self.id) |i| {
            try jws.objectField("id");
            try jws.write(i);
        }
        if (self.result) |r| {
            try jws.objectField("result");
            try jws.write(r);
        }
        try jws.endObject();
    }
};

/// JSON-RPC error response
const JsonRpcErrorResponse = struct {
    jsonrpc: []const u8 = "2.0",
    @"error": JsonRpcError,
    id: ?json.Value = null,

    const JsonRpcError = struct {
        code: i32,
        message: []const u8,

        pub fn jsonStringify(self: @This(), jws: anytype) !void {
            try jws.beginObject();
            try jws.objectField("code");
            try jws.write(self.code);
            try jws.objectField("message");
            try jws.write(self.message);
            try jws.endObject();
        }
    };

    pub fn jsonStringify(self: @This(), jws: anytype) !void {
        try jws.beginObject();
        try jws.objectField("jsonrpc");
        try jws.write(self.jsonrpc);
        try jws.objectField("error");
        try jws.write(self.@"error");
        if (self.id) |i| {
            try jws.objectField("id");
            try jws.write(i);
        }
        try jws.endObject();
    }
};

// ============ MCP Server Implementation ============

/// MCP Server
pub const McpServer = struct {
    allocator: std.mem.Allocator,
    transport: mcp_transport.McpTransport,
    protocolVersion: []const u8 = "2024-11-05",
    capabilities: mcp_types.ServerCapabilities,
    toolExecutor: ?ToolExecutor = null,
    tools: std.StringHashMap(mcp_types.McpTool),

    const Self = @This();

    pub fn init(allocator: std.mem.Allocator) Self {
        return .{
            .allocator = allocator,
            .transport = mcp_transport.McpTransport.init(allocator),
            .capabilities = .{
                .tools = .{ .listChanged = false },
                .resources = null,
            },
            .tools = std.StringHashMap(mcp_types.McpTool).init(allocator),
        };
    }

    pub fn deinit(self: *Self) void {
        self.tools.deinit();
    }

    /// Register a tool with the server
    pub fn register_tool(self: *Self, tool: mcp_types.McpTool) !void {
        try self.tools.put(tool.name, tool);
    }

    /// Set tool executor function
    pub fn set_tool_executor(self: *Self, executor: ToolExecutor) void {
        self.toolExecutor = executor;
    }

    /// Run the server - handles incoming requests
    pub fn run(self: *Self) !void {
        while (true) {
            const message = self.transport.read_message() catch |e| {
                if (e == error.EndOfStream) {
                    break;
                }
                std.debug.print("MCP transport error: {}\n", .{e});
                continue;
            };
            defer self.allocator.free(message);

            // Parse and handle the request
            self.handle_message(message) catch |e| {
                std.debug.print("MCP handle error: {}\n", .{e});
            };
        }
    }

    /// Handle a single JSON-RPC message
    fn handle_message(self: *Self, message: []const u8) !void {
        // Parse JSON-RPC request
        var parser = json.Parser.init(self.allocator, .{
            .allow_trailing_comma = true,
        });
        defer parser.deinit();

        const json_value = parser.parse(message) catch {
            return self.send_error(null, .ParseError, "Invalid JSON");
        };
        defer json_value.deinit();

        const obj = json_value.object orelse {
            return self.send_error(null, .InvalidRequest, "Expected object");
        };

        const method_field = obj.get("method") orelse {
            return self.send_error(null, .InvalidRequest, "Missing method");
        };

        const method_str = method_field.string;
        const id = obj.get("id");

        // Handle methods
        if (std.mem.eql(u8, method_str, "initialize")) {
            try self.handle_initialize(id, obj.get("params"));
        } else if (std.mem.eql(u8, method_str, "initialized")) {
            // Notification: client confirms initialization complete, no response
        } else if (std.mem.eql(u8, method_str, "ping")) {
            try self.handle_ping(id);
        } else if (std.mem.eql(u8, method_str, "tools/list")) {
            try self.handle_tools_list(id);
        } else if (std.mem.eql(u8, method_str, "tools/call")) {
            try self.handle_tools_call(id, obj.get("params"));
        } else if (std.mem.eql(u8, method_str, "resources/list")) {
            try self.handle_resources_list(id);
        } else if (std.mem.eql(u8, method_str, "resources/read")) {
            try self.handle_resources_read(id, obj.get("params"));
        } else if (std.mem.eql(u8, method_str, "resources/subscribe")) {
            try self.handle_resources_subscribe(id, obj.get("params"));
        } else if (std.mem.eql(u8, method_str, "resources/unsubscribe")) {
            try self.handle_resources_unsubscribe(id, obj.get("params"));
        } else if (std.mem.eql(u8, method_str, "prompts/list")) {
            try self.handle_prompts_list(id);
        } else if (std.mem.eql(u8, method_str, "prompts/get")) {
            try self.handle_prompts_get(id, obj.get("params"));
        } else if (std.mem.eql(u8, method_str, "completion/complete")) {
            try self.handle_completion_complete(id, obj.get("params"));
        } else if (std.mem.eql(u8, method_str, "logging/setLevel")) {
            try self.handle_logging_set_level(id, obj.get("params"));
        } else if (std.mem.startsWith(u8, method_str, "notifications/")) {
            // Notifications don't get responses
        } else {
            return self.send_error(id, .MethodNotFound, "Unknown method");
        }
    }

    fn handle_initialize(self: *Self, id: ?json.Value, params: ?json.Value) !void {
        // Parse capabilities if provided
        if (params) |p| {
            if (p.object) |params_obj| {
                if (params_obj.get("capabilities")) |caps| {
                    _ = caps;
                }
                if (params_obj.get("clientInfo")) |ci| {
                    _ = ci;
                }
            }
        }

        // Build response using struct with jsonStringify
        const result = InitializeResult{
            .protocolVersion = self.protocolVersion,
            .capabilities = .{
                .tools = .{ .listChanged = false },
                .resources = null,
                .prompts = .{ .listChanged = false },
                .completions = .{},
                .logging = .{},
            },
            .serverInfo = .{
                .name = "pabrikcore-mcp",
                .version = "0.0.1",
            },
        };

        try self.send_response(id, result);
    }

    fn handle_tools_list(self: *Self, id: ?json.Value) !void {
        // Collect tools into a slice
        var tools_list = std.ArrayList(mcp_types.McpTool).init(self.allocator);
        defer tools_list.deinit();

        var iter = self.tools.iterator();
        while (iter.next()) |entry| {
            try tools_list.append(entry.value_ptr.*);
        }

        const result = ListToolsResult{
            .tools = try tools_list.toOwnedSlice(),
        };
        errdefer self.allocator.free(result.tools);

        try self.send_response(id, result);
    }

    fn handle_tools_call(self: *Self, id: ?json.Value, params: ?json.Value) !void {
        if (params == null or self.toolExecutor == null) {
            return self.send_error(id, .InvalidParams, "Missing params or executor");
        }

        const params_obj = params.?.object orelse {
            return self.send_error(id, .InvalidParams, "Expected object params");
        };

        const name_field = params_obj.get("name") orelse {
            return self.send_error(id, .InvalidParams, "Missing tool name");
        };
        const arguments = params_obj.get("arguments");

        // Call the tool
        const tool_result = try self.toolExecutor.?(self.allocator, name_field.string, arguments);

        // Build response - convert JSON value to string for content
        var content_text: []u8 = undefined;
        {
            var aw: std.io.Writer.Allocating = .init(self.allocator);
            try aw.writer.print("{f}", .{std.json.fmt(tool_result, .{})});
            content_text = try aw.toOwnedSlice();
        }
        errdefer self.allocator.free(content_text);

        const content_block = CallToolResult.ContentBlock{
            .type = "text",
            .text = content_text,
        };

        const result = CallToolResult{
            .content = &.{content_block},
            .isError = false,
        };

        try self.send_response(id, result);
    }

    fn handle_resources_list(self: *Self, id: ?json.Value) !void {
        const result = ListResourcesResult{
            .resources = &.{},
        };
        try self.send_response(id, result);
    }

    fn handle_resources_read(self: *Self, id: ?json.Value, params: ?json.Value) !void {
        _ = params;
        const result = ReadResourceResult{
            .contents = &.{},
        };
        try self.send_response(id, result);
    }

    fn handle_ping(self: *Self, id: ?json.Value) !void {
        // Ping returns an empty result object
        const EmptyResult = struct {};
        try self.send_response(id, EmptyResult{});
    }

    fn handle_resources_subscribe(self: *Self, id: ?json.Value, params: ?json.Value) !void {
        _ = params;
        // Acknowledge subscription (actual subscription tracking not implemented)
        const EmptyResult = struct {};
        try self.send_response(id, EmptyResult{});
    }

    fn handle_resources_unsubscribe(self: *Self, id: ?json.Value, params: ?json.Value) !void {
        _ = params;
        // Acknowledge unsubscription (actual subscription tracking not implemented)
        const EmptyResult = struct {};
        try self.send_response(id, EmptyResult{});
    }

    fn handle_prompts_list(self: *Self, id: ?json.Value) !void {
        const ListPromptsResult = struct {
            prompts: []const mcp_types.Prompt,

            pub fn jsonStringify(s: @This(), jws: anytype) !void {
                try jws.beginObject();
                try jws.objectField("prompts");
                try jws.write(s.prompts);
                try jws.endObject();
            }
        };
        const result = ListPromptsResult{
            .prompts = &.{},
        };
        try self.send_response(id, result);
    }

    fn handle_prompts_get(self: *Self, id: ?json.Value, params: ?json.Value) !void {
        _ = params;
        // Prompts not yet implemented - return empty result for now
        const GetPromptResult = struct {
            description: ?[]const u8 = null,
            messages: []const struct {} = &.{},

            pub fn jsonStringify(s: @This(), jws: anytype) !void {
                try jws.beginObject();
                if (s.description) |d| {
                    try jws.objectField("description");
                    try jws.write(d);
                }
                try jws.objectField("messages");
                try jws.write(s.messages);
                try jws.endObject();
            }
        };
        const result = GetPromptResult{};
        try self.send_response(id, result);
    }

    fn handle_completion_complete(self: *Self, id: ?json.Value, params: ?json.Value) !void {
        _ = params;
        const CompleteResult = struct {
            completion: struct {
                values: []const []const u8,
                total: ?i32 = null,
                hasMore: ?bool = null,

                pub fn jsonStringify(s: @This(), jws: anytype) !void {
                    try jws.beginObject();
                    try jws.objectField("values");
                    try jws.write(s.values);
                    if (s.total) |t| {
                        try jws.objectField("total");
                        try jws.write(t);
                    }
                    if (s.hasMore) |h| {
                        try jws.objectField("hasMore");
                        try jws.write(h);
                    }
                    try jws.endObject();
                }
            },

            pub fn jsonStringify(s: @This(), jws: anytype) !void {
                try jws.beginObject();
                try jws.objectField("completion");
                try jws.write(s.completion);
                try jws.endObject();
            }
        };
        const result = CompleteResult{
            .completion = .{
                .values = &.{},
                .total = 0,
                .hasMore = false,
            },
        };
        try self.send_response(id, result);
    }

    fn handle_logging_set_level(self: *Self, id: ?json.Value, params: ?json.Value) !void {
        _ = params;
        // Log level stored but not yet used (logging infrastructure not implemented)
        const EmptyResult = struct {};
        try self.send_response(id, EmptyResult{});
    }

    fn send_response(self: *Self, id: ?json.Value, result: anytype) !void {
        // Use arena for JSON construction
        var arena = std.heap.ArenaAllocator.init(self.allocator);
        defer arena.deinit();
        const arena_alloc = arena.allocator();

        const response = JsonRpcResponse{
            .id = id,
            .result = result,
        };

        var aw: std.io.Writer.Allocating = .init(arena_alloc);
        try aw.writer.print("{f}", .{std.json.fmt(response, .{})});
        const message = try aw.toOwnedSlice();
        errdefer arena_alloc.free(message);

        try self.transport.write_message(try self.allocator.dupe(u8, message));
    }

    fn send_error(self: *Self, id: ?json.Value, code: mcp_types.ErrorCode, message: []const u8) !void {
        // Use arena for JSON construction
        var arena = std.heap.ArenaAllocator.init(self.allocator);
        defer arena.deinit();
        const arena_alloc = arena.allocator();

        const error_resp = JsonRpcErrorResponse{
            .@"error" = .{
                .code = @intFromEnum(code),
                .message = message,
            },
            .id = id,
        };

        var aw: std.io.Writer.Allocating = .init(arena_alloc);
        try aw.writer.print("{f}", .{std.json.fmt(error_resp, .{})});
        const json_str = try aw.toOwnedSlice();
        errdefer arena_alloc.free(json_str);

        try self.transport.write_message(try self.allocator.dupe(u8, json_str));
    }
};

// The McpServer tests that used to live in mcp_server_test.zig are now inline at the bottom of this file (2026-09-29 flatten).

// ===== Tests merged from mcp_server_test.zig (2026-09-29 flatten) =====
const testing = std.testing;

// Note: McpServer cannot be directly instantiated in tests because it contains a function pointer field (toolExecutor) which requires comptime.

// ============ Error Code Tests ============

test "McpError error codes match spec" {
    // Verify error codes match JSON-RPC 2.0 and MCP spec
    try testing.expectEqual(@as(i32, -32700), @intFromEnum(mcp_types.ErrorCode.ParseError));
    try testing.expectEqual(@as(i32, -32600), @intFromEnum(mcp_types.ErrorCode.InvalidRequest));
    try testing.expectEqual(@as(i32, -32601), @intFromEnum(mcp_types.ErrorCode.MethodNotFound));
    try testing.expectEqual(@as(i32, -32602), @intFromEnum(mcp_types.ErrorCode.InvalidParams));
    try testing.expectEqual(@as(i32, -32603), @intFromEnum(mcp_types.ErrorCode.InternalError));
    try testing.expectEqual(@as(i32, -32000), @intFromEnum(mcp_types.ErrorCode.ServerError));
}

// ============ Tool Definition Tests ============

test "McpTool structure is valid" {
    const tool = mcp_types.McpTool{
        .name = "test_tool",
        .description = "A test tool description",
        .inputSchema = .{
            .type = "object",
            .properties = .{ .null = {} },
            .required = &.{ "param1", "param2" },
        },
    };

    try testing.expectEqualStrings("test_tool", tool.name);
    try testing.expectEqualStrings("A test tool description", tool.description);
    try testing.expectEqualStrings("object", tool.inputSchema.type);
    try testing.expect(tool.inputSchema.required != null);
    try testing.expectEqual(@as(usize, 2), tool.inputSchema.required.?.len);
}

test "McpTool with null required fields" {
    const tool = mcp_types.McpTool{
        .name = "simple_tool",
        .description = "Simple tool",
        .inputSchema = .{
            .type = "object",
            .properties = .{ .null = {} },
            .required = null,
        },
    };

    try testing.expectEqualStrings("simple_tool", tool.name);
    try testing.expect(tool.inputSchema.required == null);
}

// ============ Server Capabilities Tests ============

test "ServerCapabilities default values" {
    const caps = mcp_types.ServerCapabilities{
        .tools = .{ .listChanged = false },
        .resources = null,
    };

    try testing.expect(caps.tools != null);
    try testing.expect(caps.tools.?.listChanged == false);
    try testing.expect(caps.resources == null);
}

test "ServerCapabilities with resources" {
    const caps = mcp_types.ServerCapabilities{
        .tools = .{ .listChanged = true },
        .resources = .{ .subscribe = true, .listChanged = true },
    };

    try testing.expect(caps.tools.?.listChanged == true);
    try testing.expect(caps.resources != null);
    try testing.expect(caps.resources.?.subscribe == true);
    try testing.expect(caps.resources.?.listChanged == true);
}

// ============ Resource Tests ============

test "Resource structure" {
    const resource = mcp_types.Resource{
        .uri = "file:///test.txt",
        .name = "test.txt",
        .description = "A test file",
        .mimeType = "text/plain",
    };

    try testing.expectEqualStrings("file:///test.txt", resource.uri);
    try testing.expectEqualStrings("test.txt", resource.name);
    try testing.expectEqualStrings("A test file", resource.description.?);
    try testing.expectEqualStrings("text/plain", resource.mimeType.?);
}

test "Resource with optional fields null" {
    const resource = mcp_types.Resource{
        .uri = "file:///test.txt",
        .name = "test.txt",
        .description = null,
        .mimeType = null,
    };

    try testing.expect(resource.description == null);
    try testing.expect(resource.mimeType == null);
}

// ============ Prompt Tests ============

test "Prompt structure" {
    const prompt = mcp_types.Prompt{
        .name = "test_prompt",
        .description = "A test prompt",
        .arguments = &.{.{
            .name = "arg1",
            .description = "First argument",
            .required = true,
        }},
    };

    try testing.expectEqualStrings("test_prompt", prompt.name);
    try testing.expectEqualStrings("A test prompt", prompt.description.?);
    try testing.expect(prompt.arguments != null);
    try testing.expectEqual(@as(usize, 1), prompt.arguments.?.len);
}

// ============ Content Block Tests ============

test "ContentBlock text type" {
    const block = mcp_types.ContentBlock{
        .type = "text",
        .text = "Hello world",
        .resource = null,
    };

    try testing.expectEqualStrings("text", block.type);
    try testing.expectEqualStrings("Hello world", block.text.?);
    try testing.expect(block.resource == null);
}

test "ContentBlock with resource" {
    const resource_content = mcp_types.ResourceContents{
        .uri = "file:///test.txt",
        .mimeType = "text/plain",
        .text = "File content",
        .blob = null,
    };

    const block = mcp_types.ContentBlock{
        .type = "resource",
        .text = null,
        .resource = resource_content,
    };

    try testing.expectEqualStrings("resource", block.type);
    try testing.expect(block.text == null);
    try testing.expect(block.resource != null);
    try testing.expectEqualStrings("file:///test.txt", block.resource.?.uri);
}

// ============ Completion Tests ============

test "CompleteParams structure" {
    const params = mcp_types.CompleteParams{
        .ref = .{ .type = "resource" },
        .argument = .{
            .name = "uri",
            .value = "file:///",
        },
    };

    try testing.expectEqualStrings("resource", params.ref.type);
    try testing.expectEqualStrings("uri", params.argument.name);
    try testing.expectEqualStrings("file:///", params.argument.value);
}

test "Completion result structure" {
    const completion = mcp_types.Completion{
        .values = &.{ "option1", "option2", "option3" },
        .total = 3,
        .hasMore = false,
    };

    try testing.expectEqual(@as(usize, 3), completion.values.len);
    try testing.expectEqual(@as(i32, 3), completion.total.?);
    try testing.expect(completion.hasMore.? == false);
}

// ============ Initialize Params Tests ============

test "InitializeParams with client info" {
    const params = mcp_types.InitializeParams{
        .protocolVersion = "2024-11-05",
        .capabilities = .{},
        .clientInfo = .{
            .name = "test-client",
            .version = "1.0.0",
        },
    };

    try testing.expectEqualStrings("2024-11-05", params.protocolVersion.?);
    try testing.expectEqualStrings("test-client", params.clientInfo.?.name);
    try testing.expectEqualStrings("1.0.0", params.clientInfo.?.version);
}

// ============ CallToolParams Tests ============

test "CallToolParams structure" {
    const params = mcp_types.CallToolParams{
        .name = "test_tool",
        .arguments = null,
    };

    try testing.expectEqualStrings("test_tool", params.name);
    try testing.expect(params.arguments == null);
}

// ============ ReadResourceParams Tests ============

test "ReadResourceParams structure" {
    const params = mcp_types.ReadResourceParams{
        .uri = "file:///test.txt",
    };

    try testing.expectEqualStrings("file:///test.txt", params.uri);
}

// ============ SetLevelParams Tests ============

test "SetLevelParams structure" {
    const params = mcp_types.SetLevelParams{
        .level = "info",
    };

    try testing.expectEqualStrings("info", params.level);
}

// ============ ResourceContents Tests ============

test "ResourceContents with text" {
    const contents = mcp_types.ResourceContents{
        .uri = "file:///test.txt",
        .mimeType = "text/plain",
        .text = "File content here",
        .blob = null,
    };

    try testing.expectEqualStrings("file:///test.txt", contents.uri);
    try testing.expectEqualStrings("text/plain", contents.mimeType.?);
    try testing.expectEqualStrings("File content here", contents.text.?);
    try testing.expect(contents.blob == null);
}

test "ResourceContents with blob" {
    const blob_data = "binary data";
    const contents = mcp_types.ResourceContents{
        .uri = "file:///test.bin",
        .mimeType = "application/octet-stream",
        .text = null,
        .blob = blob_data,
    };

    try testing.expectEqualStrings("file:///test.bin", contents.uri);
    try testing.expect(contents.text == null);
    try testing.expect(contents.blob != null);
}

// ============ PromptMessage Tests ============

test "PromptMessage text content" {
    const message = mcp_types.PromptMessage{
        .role = "user",
        .content = .{ .text = "Hello" },
    };

    try testing.expectEqualStrings("user", message.role);
}

test "PromptMessage image content" {
    const image = mcp_types.ImageContent{
        .data = "base64data",
        .mimeType = "image/png",
    };
    const message = mcp_types.PromptMessage{
        .role = "assistant",
        .content = .{ .image = image },
    };

    try testing.expectEqualStrings("assistant", message.role);
}

// ============ GetPromptParams Tests ============

test "GetPromptParams structure" {
    const params = mcp_types.GetPromptParams{
        .name = "test_prompt",
        .arguments = null,
    };

    try testing.expectEqualStrings("test_prompt", params.name);
    try testing.expect(params.arguments == null);
}

// ============ PromptArgument Tests ============

test "PromptArgument structure" {
    const arg = mcp_types.PromptArgument{
        .name = "input",
        .description = "User input",
        .required = true,
    };

    try testing.expectEqualStrings("input", arg.name);
    try testing.expectEqualStrings("User input", arg.description.?);
    try testing.expect(arg.required.? == true);
}

// ============ ImageContent Tests ============

test "ImageContent structure" {
    const image = mcp_types.ImageContent{
        .data = "base64encodeddata",
        .mimeType = "image/jpeg",
    };

    try testing.expectEqualStrings("base64encodeddata", image.data);
    try testing.expectEqualStrings("image/jpeg", image.mimeType);
}

// ============ CompletionReference Tests ============

test "CompletionReference type variant" {
    const ref = mcp_types.CompletionReference{ .type = "resource" };
    try testing.expectEqualStrings("resource", ref.type);
}

test "CompletionReference name variant" {
    const ref = mcp_types.CompletionReference{ .name = "my_resource" };
    try testing.expectEqualStrings("my_resource", ref.name);
}

// ============ CompletionArgument Tests ============

test "CompletionArgument structure" {
    const arg = mcp_types.CompletionArgument{
        .name = "prefix",
        .value = "test",
    };

    try testing.expectEqualStrings("prefix", arg.name);
    try testing.expectEqualStrings("test", arg.value);
}

// ============ ListPromptsResult Tests ============

test "ListPromptsResult empty" {
    const result = mcp_types.ListPromptsResult{
        .prompts = &.{},
    };

    try testing.expectEqual(@as(usize, 0), result.prompts.len);
}

test "ListPromptsResult with prompts" {
    const prompts = [_]mcp_types.Prompt{
        .{ .name = "prompt1", .description = "First", .arguments = null },
        .{ .name = "prompt2", .description = "Second", .arguments = null },
    };
    const result = mcp_types.ListPromptsResult{
        .prompts = &prompts,
    };

    try testing.expectEqual(@as(usize, 2), result.prompts.len);
}

// ============ ListToolsResult Tests ============

test "ListToolsResult empty" {
    const result = mcp_types.ListToolsResult{
        .tools = &.{},
    };

    try testing.expectEqual(@as(usize, 0), result.tools.len);
}

test "ListToolsResult with tools" {
    const tools = [_]mcp_types.McpTool{
        .{
            .name = "tool1",
            .description = "First tool",
            .inputSchema = .{ .type = "object", .properties = .{ .null = {} }, .required = null },
        },
        .{
            .name = "tool2",
            .description = "Second tool",
            .inputSchema = .{ .type = "object", .properties = .{ .null = {} }, .required = null },
        },
    };
    const result = mcp_types.ListToolsResult{
        .tools = &tools,
    };

    try testing.expectEqual(@as(usize, 2), result.tools.len);
}

// ============ CallToolResult Tests ============

test "CallToolResult success" {
    const content = [_]mcp_types.ContentBlock{
        .{ .type = "text", .text = "Result", .resource = null },
    };
    const result = mcp_types.CallToolResult{
        .content = &content,
        .isError = false,
    };

    try testing.expect(result.isError == false);
    try testing.expectEqual(@as(usize, 1), result.content.len);
}

test "CallToolResult error" {
    const content = [_]mcp_types.ContentBlock{
        .{ .type = "text", .text = "Error occurred", .resource = null },
    };
    const result = mcp_types.CallToolResult{
        .content = &content,
        .isError = true,
    };

    try testing.expect(result.isError == true);
}

// ============ ListResourcesResult Tests ============

test "ListResourcesResult empty" {
    const result = mcp_types.ListResourcesResult{
        .resources = &.{},
    };

    try testing.expectEqual(@as(usize, 0), result.resources.len);
}

test "ListResourcesResult with resources" {
    const resources = [_]mcp_types.Resource{
        .{ .uri = "file:///a.txt", .name = "a.txt", .description = null, .mimeType = null },
        .{ .uri = "file:///b.txt", .name = "b.txt", .description = null, .mimeType = null },
    };
    const result = mcp_types.ListResourcesResult{
        .resources = &resources,
    };

    try testing.expectEqual(@as(usize, 2), result.resources.len);
}

// ============ ReadResourceResult Tests ============

test "ReadResourceResult empty" {
    const result = mcp_types.ReadResourceResult{
        .contents = &.{},
    };

    try testing.expectEqual(@as(usize, 0), result.contents.len);
}

test "ReadResourceResult with contents" {
    const contents = [_]mcp_types.ResourceContents{
        .{ .uri = "file:///test.txt", .mimeType = "text/plain", .text = "Content", .blob = null },
    };
    const result = mcp_types.ReadResourceResult{
        .contents = &contents,
    };

    try testing.expectEqual(@as(usize, 1), result.contents.len);
}

// ============ CompleteResult Tests ============

test "CompleteResult structure" {
    const completion = mcp_types.Completion{
        .values = &.{ "opt1", "opt2" },
        .total = 2,
        .hasMore = false,
    };
    const result = mcp_types.CompleteResult{
        .completion = completion,
    };

    try testing.expectEqual(@as(usize, 2), result.completion.values.len);
}

// ============ GetPromptResult Tests ============

test "GetPromptResult structure" {
    const messages = [_]mcp_types.PromptMessage{};
    const result = mcp_types.GetPromptResult{
        .description = "Test description",
        .messages = &messages,
    };

    try testing.expectEqualStrings("Test description", result.description.?);
    try testing.expectEqual(@as(usize, 0), result.messages.len);
}

// ============ ToolsCapability Tests ============

test "ToolsCapability default" {
    const cap = mcp_types.ToolsCapability{ .listChanged = false };
    try testing.expect(cap.listChanged == false);
}

test "ToolsCapability with listChanged true" {
    const cap = mcp_types.ToolsCapability{ .listChanged = true };
    try testing.expect(cap.listChanged == true);
}

// ============ ResourcesCapability Tests ============

test "ResourcesCapability default" {
    const cap = mcp_types.ResourcesCapability{ .subscribe = false, .listChanged = false };
    try testing.expect(cap.subscribe == false);
    try testing.expect(cap.listChanged == false);
}

test "ResourcesCapability with all features" {
    const cap = mcp_types.ResourcesCapability{ .subscribe = true, .listChanged = true };
    try testing.expect(cap.subscribe == true);
    try testing.expect(cap.listChanged == true);
}

// ============ PromptsCapability Tests ============

test "PromptsCapability default" {
    const cap = mcp_types.PromptsCapability{ .listChanged = false };
    try testing.expect(cap.listChanged == false);
}

test "PromptsCapability with listChanged" {
    const cap = mcp_types.PromptsCapability{ .listChanged = true };
    try testing.expect(cap.listChanged == true);
}

// ============ CompletionsCapability Tests ============

test "CompletionsCapability exists" {
    const cap = mcp_types.CompletionsCapability{};
    _ = cap; // Just verify it compiles
}

// ============ LoggingCapability Tests ============

test "LoggingCapability exists" {
    const cap = mcp_types.LoggingCapability{};
    _ = cap; // Just verify it compiles
}

// ============ InitializeCapabilities Tests ============

test "InitializeCapabilities exists" {
    const caps = mcp_types.InitializeCapabilities{};
    _ = caps; // Just verify it compiles
}

// ============ ClientInfo Tests ============

test "ClientInfo structure" {
    const info = mcp_types.ClientInfo{
        .name = "test-client",
        .version = "1.0.0",
    };

    try testing.expectEqualStrings("test-client", info.name);
    try testing.expectEqualStrings("1.0.0", info.version);
}

// ============ JsonRpcRequest Tests ============

test "JsonRpcRequest default values" {
    const req = mcp_types.JsonRpcRequest{
        .method = "test",
    };

    try testing.expectEqualStrings("2.0", req.jsonrpc);
    try testing.expect(req.id == null);
    try testing.expect(req.params == null);
}

test "JsonRpcRequest with all fields" {
    const req = mcp_types.JsonRpcRequest{
        .jsonrpc = "2.0",
        .id = "123",
        .method = "tools/list",
        .params = "{}",
    };

    try testing.expectEqualStrings("2.0", req.jsonrpc);
    try testing.expectEqualStrings("123", req.id.?);
    try testing.expectEqualStrings("tools/list", req.method);
    try testing.expectEqualStrings("{}", req.params.?);
}

// ============ JsonRpcResponse Tests ============

test "JsonRpcResponse default values" {
    const resp = mcp_types.JsonRpcResponse{
        .id = null,
    };

    try testing.expectEqualStrings("2.0", resp.jsonrpc);
    try testing.expect(resp.id == null);
    try testing.expect(resp.result == null);
    try testing.expect(resp.@"error" == null);
}

// ============ JsonRpcError Tests ============

test "JsonRpcError structure" {
    const err = mcp_types.JsonRpcError{
        .code = -32600,
        .message = "Invalid Request",
        .data = null,
    };

    try testing.expectEqual(@as(i32, -32600), err.code);
    try testing.expectEqualStrings("Invalid Request", err.message);
    try testing.expect(err.data == null);
}

test "JsonRpcError with data" {
    const err = mcp_types.JsonRpcError{
        .code = -32602,
        .message = "Invalid params",
        .data = "Additional info",
    };

    try testing.expectEqualStrings("Additional info", err.data.?);
}
