const std = @import("std");
const config_mod = @import("../modules/config/Config.zig");

pub const Backend = config_mod.LlmConfig.Backend;

pub const DEFAULT_BINARY: []const u8 = "opencode";

pub fn isOpencodeBackend(backend: []const u8) bool {
    return std.mem.eql(u8, backend, Backend.opencode);
}

pub fn isKnownBackend(backend: []const u8) bool {
    return backend.len == 0 or
        std.mem.eql(u8, backend, Backend.http) or
        std.mem.eql(u8, backend, Backend.claude_code) or
        isOpencodeBackend(backend);
}

pub fn validateOpencodeAgent(model: []const u8) error{MissingModel}!void {
    if (model.len == 0) return error.MissingModel;
}

pub fn resolveBinaryPath(configured: []const u8) []const u8 {
    if (configured.len == 0) return DEFAULT_BINARY;
    return configured;
}

pub const RunOptions = struct {
    model: []const u8 = "",
    agent: []const u8 = "",
    auto_approve: bool = true,
    json_format: bool = true,
    show_thinking: bool = false,
};

pub fn buildRunArgs(
    allocator: std.mem.Allocator,
    binary: []const u8,
    opts: RunOptions,
) ![][]const u8 {
    var list = std.ArrayList([]const u8).empty;
    errdefer {
        for (list.items) |s| allocator.free(s);
        list.deinit(allocator);
    }

    try list.append(allocator, try allocator.dupe(u8, binary));
    try list.append(allocator, try allocator.dupe(u8, "run"));

    if (opts.model.len > 0) {
        try list.append(allocator, try allocator.dupe(u8, "--model"));
        try list.append(allocator, try allocator.dupe(u8, opts.model));
    }
    if (opts.agent.len > 0) {
        try list.append(allocator, try allocator.dupe(u8, "--agent"));
        try list.append(allocator, try allocator.dupe(u8, opts.agent));
    }
    if (opts.auto_approve) {
        try list.append(allocator, try allocator.dupe(u8, "--auto"));
    }
    if (opts.show_thinking) {
        try list.append(allocator, try allocator.dupe(u8, "--thinking"));
    }
    if (opts.json_format) {
        try list.append(allocator, try allocator.dupe(u8, "--format"));
        try list.append(allocator, try allocator.dupe(u8, "json"));
    }

    return list.toOwnedSlice(allocator);
}

pub fn buildModelsListArgs(allocator: std.mem.Allocator, binary: []const u8) ![][]const u8 {
    const args = try allocator.alloc([]const u8, 2);
    errdefer allocator.free(args);
    args[0] = try allocator.dupe(u8, binary);
    errdefer allocator.free(args[0]);
    args[1] = try allocator.dupe(u8, "models");
    return args;
}

pub fn freeArgs(allocator: std.mem.Allocator, args: [][]const u8) void {
    for (args) |s| allocator.free(s);
    allocator.free(args);
}

pub const PromptMessage = struct {
    role: []const u8,
    content: []const u8,
};

fn labelFor(role: []const u8) ?[]const u8 {
    if (std.mem.eql(u8, role, "system")) return null;
    if (std.mem.eql(u8, role, "user")) return "User";
    if (std.mem.eql(u8, role, "assistant")) return "Assistant";
    if (std.mem.eql(u8, role, "tool")) return "Tool";
    return null;
}

pub fn buildPrompt(allocator: std.mem.Allocator, messages: []const PromptMessage) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);

    var wrote_preamble = false;
    for (messages) |m| {
        if (labelFor(m.role) != null) continue;
        const text = std.mem.trim(u8, m.content, " \t\r\n");
        if (text.len == 0) continue;
        if (wrote_preamble) try out.appendSlice(allocator, "\n\n");
        try out.appendSlice(allocator, text);
        wrote_preamble = true;
    }

    var wrote_turn = false;
    for (messages) |m| {
        const label = labelFor(m.role) orelse continue;
        const text = std.mem.trim(u8, m.content, " \t\r\n");
        if (text.len == 0) continue;
        if (!wrote_turn) {
            if (out.items.len > 0) try out.appendSlice(allocator, "\n\n");
            try out.appendSlice(allocator, "# Conversation\n\n");
            wrote_turn = true;
        } else {
            try out.appendSlice(allocator, "\n\n");
        }
        try out.appendSlice(allocator, label);
        try out.appendSlice(allocator, ": ");
        try out.appendSlice(allocator, text);
    }

    return out.toOwnedSlice(allocator);
}

pub const StepFinish = struct {
    reason: []const u8 = "",
    input_tokens: usize = 0,
    output_tokens: usize = 0,
    reasoning_tokens: usize = 0,
    cache_read_tokens: usize = 0,
};

pub const Failure = struct {
    kind: []const u8 = "",
    message: []const u8 = "",
};

pub const ToolUse = struct {
    name: []const u8 = "",
    input: []const u8 = "",
    output: []const u8 = "",
    status: []const u8 = "",
    error_message: []const u8 = "",
};

pub const Event = union(enum) {
    text: []const u8,
    reasoning: []const u8,
    tool_use: ToolUse,
    step_finish: StepFinish,
    failure: Failure,
    other,
};

fn strField(obj: std.json.ObjectMap, key: []const u8) ?[]const u8 {
    const v = obj.get(key) orelse return null;
    return switch (v) {
        .string => |s| s,
        else => null,
    };
}

fn intField(obj: std.json.ObjectMap, key: []const u8) usize {
    const v = obj.get(key) orelse return 0;
    return switch (v) {
        .integer => |i| if (i > 0) @intCast(i) else 0,
        .float => |f| if (f > 0) @intFromFloat(f) else 0,
        else => 0,
    };
}

fn objectField(obj: std.json.ObjectMap, key: []const u8) ?std.json.ObjectMap {
    const v = obj.get(key) orelse return null;
    return switch (v) {
        .object => |o| o,
        else => null,
    };
}

pub fn parseEventLine(parsed_value: std.json.Value) Event {
    if (parsed_value != .object) return .other;
    const root = parsed_value.object;
    const kind = strField(root, "type") orelse return .other;

    if (std.mem.eql(u8, kind, "text")) {
        const part = objectField(root, "part") orelse return .other;
        const text = strField(part, "text") orelse return .other;
        if (text.len == 0) return .other;
        return .{ .text = text };
    }

    if (std.mem.eql(u8, kind, "reasoning")) {
        const part = objectField(root, "part") orelse return .other;
        const text = strField(part, "text") orelse return .other;
        if (text.len == 0) return .other;
        return .{ .reasoning = text };
    }

    if (std.mem.eql(u8, kind, "tool_use")) {
        const part = objectField(root, "part") orelse return .other;
        var tool: ToolUse = .{
            .name = strField(part, "tool") orelse strField(part, "title") orelse "tool",
        };
        if (objectField(part, "state")) |state| {
            tool.status = strField(state, "status") orelse "";
            tool.output = strField(state, "output") orelse "";
            if (objectField(state, "error")) |failure| {
                tool.error_message = strField(failure, "message") orelse "";
            }
            if (objectField(state, "metadata")) |meta| {
                tool.input = strField(meta, "rawInput") orelse "";
            }
        }
        return .{ .tool_use = tool };
    }

    if (std.mem.eql(u8, kind, "step_finish")) {
        const part = objectField(root, "part") orelse return .other;
        var finish: StepFinish = .{ .reason = strField(part, "reason") orelse "" };
        if (objectField(part, "tokens")) |tokens| {
            finish.input_tokens = intField(tokens, "input");
            finish.output_tokens = intField(tokens, "output");
            finish.reasoning_tokens = intField(tokens, "reasoning");
            if (objectField(tokens, "cache")) |cache| {
                finish.cache_read_tokens = intField(cache, "read");
            }
        }
        return .{ .step_finish = finish };
    }

    if (std.mem.eql(u8, kind, "error")) {
        if (objectField(root, "error")) |err_obj| {
            return .{ .failure = .{
                .kind = strField(err_obj, "type") orelse "",
                .message = strField(err_obj, "message") orelse "",
            } };
        }
        return .{ .failure = .{ .message = strField(root, "message") orelse "" } };
    }

    return .other;
}

pub const ModelRef = struct {
    provider: []const u8,
    model: []const u8,
};

pub fn parseModelsList(allocator: std.mem.Allocator, stdout: []const u8) ![]ModelRef {
    var list = std.ArrayList(ModelRef).empty;
    errdefer {
        for (list.items) |ref| {
            allocator.free(ref.provider);
            allocator.free(ref.model);
        }
        list.deinit(allocator);
    }

    var lines = std.mem.splitScalar(u8, stdout, '\n');
    while (lines.next()) |raw| {
        const line = std.mem.trim(u8, raw, " \t\r");
        if (line.len == 0) continue;
        const slash = std.mem.indexOfScalar(u8, line, '/') orelse continue;
        if (slash == 0 or slash + 1 >= line.len) continue;
        try list.append(allocator, .{
            .provider = try allocator.dupe(u8, line[0..slash]),
            .model = try allocator.dupe(u8, line[slash + 1 ..]),
        });
    }
    return list.toOwnedSlice(allocator);
}

pub fn freeModelsList(allocator: std.mem.Allocator, refs: []ModelRef) void {
    for (refs) |ref| {
        allocator.free(ref.provider);
        allocator.free(ref.model);
    }
    if (refs.len > 0) allocator.free(refs);
}

pub fn isFreeModelId(model_id: []const u8) bool {
    if (std.ascii.indexOfIgnoreCase(model_id, "free") != null) return true;
    return std.ascii.indexOfIgnoreCase(model_id, "contributor") != null;
}

pub fn isFreeFromCost(cost_input: ?f64, cost_output: ?f64) ?bool {
    const input = cost_input orelse return null;
    const output = cost_output orelse return null;
    return input == 0 and output == 0;
}

pub fn freeRank(is_free: bool) u8 {
    return if (is_free) 0 else 1;
}

pub fn describeRunFailure(
    allocator: std.mem.Allocator,
    binary: []const u8,
    model: []const u8,
    detail: []const u8,
) ![]u8 {
    const trimmed = std.mem.trim(u8, detail, " \t\r\n");
    return std.fmt.allocPrint(
        allocator,
        "`{s} run --model {s}` failed: {s}",
        .{ binary, model, if (trimmed.len > 0) trimmed else "the CLI exited non-zero and printed nothing" },
    );
}

pub fn describeMissingBinary(
    allocator: std.mem.Allocator,
    binary: []const u8,
) ![]u8 {
    return std.fmt.allocPrint(
        allocator,
        "'{s}' was not found or could not be executed. Install the OpenCode CLI and run `opencode login`, or point the agent at an absolute binary path.",
        .{binary},
    );
}

pub fn describeEmptyReply(
    allocator: std.mem.Allocator,
    model: []const u8,
) ![]u8 {
    return std.fmt.allocPrint(
        allocator,
        "`opencode run --model {s}` finished without producing any text.",
        .{model},
    );
}

const testing = std.testing;

test "isOpencodeBackend matches only the canonical value" {
    try testing.expect(isOpencodeBackend("opencode"));
    try testing.expect(!isOpencodeBackend("http"));
    try testing.expect(!isOpencodeBackend(""));
    try testing.expect(!isOpencodeBackend("Opencode"));
    try testing.expect(!isOpencodeBackend("openai"));
}

test "isKnownBackend accepts unset, http, claude-code and opencode" {
    try testing.expect(isKnownBackend(""));
    try testing.expect(isKnownBackend("http"));
    try testing.expect(isKnownBackend("claude-code"));
    try testing.expect(isKnownBackend("opencode"));
    try testing.expect(!isKnownBackend("codex"));
}

test "validateOpencodeAgent requires model only" {
    try validateOpencodeAgent("opencode/beam-free");
    try validateOpencodeAgent("opencode-go/deepseek-v4.1-flash");
    try testing.expectError(error.MissingModel, validateOpencodeAgent(""));
}

test "resolveBinaryPath defaults to opencode on PATH" {
    try testing.expectEqualStrings("opencode", resolveBinaryPath(""));
    try testing.expectEqualStrings("/usr/bin/opencode", resolveBinaryPath("/usr/bin/opencode"));
}

test "buildRunArgs carries model, agent, auto and json format" {
    const alloc = testing.allocator;
    const args = try buildRunArgs(alloc, "opencode", .{ .model = "opencode/beam-free", .agent = "build" });
    defer freeArgs(alloc, args);
    try testing.expectEqual(@as(usize, 9), args.len);
    try testing.expectEqualStrings("opencode", args[0]);
    try testing.expectEqualStrings("run", args[1]);
    try testing.expectEqualStrings("--model", args[2]);
    try testing.expectEqualStrings("opencode/beam-free", args[3]);
    try testing.expectEqualStrings("--agent", args[4]);
    try testing.expectEqualStrings("build", args[5]);
    try testing.expectEqualStrings("--auto", args[6]);
    try testing.expectEqualStrings("--format", args[7]);
    try testing.expectEqualStrings("json", args[8]);
}

test "buildModelsListArgs asks the CLI for its own model list" {
    const alloc = testing.allocator;
    const args = try buildModelsListArgs(alloc, "opencode");
    defer freeArgs(alloc, args);
    try testing.expectEqual(@as(usize, 2), args.len);
    try testing.expectEqualStrings("opencode", args[0]);
    try testing.expectEqualStrings("models", args[1]);
}

test "buildRunArgs never carries the prompt on the command line" {
    const alloc = testing.allocator;
    const args = try buildRunArgs(alloc, "opencode", .{ .model = "opencode/beam-free" });
    defer freeArgs(alloc, args);
    for (args) |a| {
        try testing.expect(std.mem.indexOf(u8, a, "hello") == null);
    }
}

test "buildRunArgs asks for the CLI's thinking blocks only when told to" {
    const alloc = testing.allocator;
    const quiet = try buildRunArgs(alloc, "opencode", .{ .model = "opencode/beam-free" });
    defer freeArgs(alloc, quiet);
    for (quiet) |arg| try testing.expect(!std.mem.eql(u8, arg, "--thinking"));

    const thinking = try buildRunArgs(alloc, "opencode", .{ .model = "opencode/beam-free", .show_thinking = true });
    defer freeArgs(alloc, thinking);
    var found = false;
    for (thinking) |arg| {
        if (std.mem.eql(u8, arg, "--thinking")) found = true;
    }
    try testing.expect(found);
}

test "buildRunArgs honours an explicit auto-off and non-json run" {
    const alloc = testing.allocator;
    const args = try buildRunArgs(alloc, "opencode", .{ .auto_approve = false, .json_format = false });
    defer freeArgs(alloc, args);
    try testing.expectEqual(@as(usize, 2), args.len);
}

test "buildPrompt puts system text first and labels every turn" {
    const alloc = testing.allocator;
    const prompt = try buildPrompt(alloc, &.{
        .{ .role = "system", .content = "You are Pabrik." },
        .{ .role = "user", .content = "hello" },
        .{ .role = "assistant", .content = "hi there" },
        .{ .role = "user", .content = "what now?" },
    });
    defer alloc.free(prompt);

    try testing.expect(std.mem.startsWith(u8, prompt, "You are Pabrik."));
    const system_at = std.mem.indexOf(u8, prompt, "You are Pabrik.").?;
    const first_user = std.mem.indexOf(u8, prompt, "User: hello").?;
    const assistant_at = std.mem.indexOf(u8, prompt, "Assistant: hi there").?;
    const last_user = std.mem.indexOf(u8, prompt, "User: what now?").?;
    try testing.expect(system_at < first_user);
    try testing.expect(first_user < assistant_at);
    try testing.expect(assistant_at < last_user);
}

test "buildPrompt skips empty messages and keeps tool results" {
    const alloc = testing.allocator;
    const prompt = try buildPrompt(alloc, &.{
        .{ .role = "user", .content = "run it" },
        .{ .role = "assistant", .content = "   " },
        .{ .role = "tool", .content = "exit 0" },
    });
    defer alloc.free(prompt);

    try testing.expect(std.mem.indexOf(u8, prompt, "User: run it") != null);
    try testing.expect(std.mem.indexOf(u8, prompt, "Tool: exit 0") != null);
    try testing.expect(std.mem.indexOf(u8, prompt, "Assistant:") == null);
}

test "buildPrompt with an empty conversation is empty" {
    const alloc = testing.allocator;
    const prompt = try buildPrompt(alloc, &.{});
    defer alloc.free(prompt);
    try testing.expectEqual(@as(usize, 0), prompt.len);
}

test "parseEventLine reads the text part of a text event" {
    const alloc = testing.allocator;
    var doc = try std.json.parseFromSlice(std.json.Value, alloc,
        \\{"type":"text","part":{"type":"text","text":"PONG"}}
    , .{});
    defer doc.deinit();
    const ev = parseEventLine(doc.value);
    try testing.expect(ev == .text);
    try testing.expectEqualStrings("PONG", ev.text);
}

test "parseEventLine reads usage and stop reason from step_finish" {
    const alloc = testing.allocator;
    var doc = try std.json.parseFromSlice(std.json.Value, alloc,
        \\{"type":"step_finish","part":{"type":"step-finish","reason":"stop","cost":0,"tokens":{"input":70,"output":26,"reasoning":41,"cache":{"read":4224,"write":0}}}}
    , .{});
    defer doc.deinit();
    const ev = parseEventLine(doc.value);
    try testing.expect(ev == .step_finish);
    try testing.expectEqualStrings("stop", ev.step_finish.reason);
    try testing.expectEqual(@as(usize, 70), ev.step_finish.input_tokens);
    try testing.expectEqual(@as(usize, 26), ev.step_finish.output_tokens);
    try testing.expectEqual(@as(usize, 41), ev.step_finish.reasoning_tokens);
    try testing.expectEqual(@as(usize, 4224), ev.step_finish.cache_read_tokens);
}

test "parseEventLine reads the whole step a tool_use event ran" {
    const alloc = testing.allocator;
    const raw =
        \\{"type":"tool_use","part":{"type":"tool","id":"call-1","tool":"glob","state":{"status":"completed","output":"/tmp/a.txt","input":{"path":"/tmp"},"metadata":{"rawInput":"{\"path\":\"/tmp\"}"}}}}
    ;
    var doc = try std.json.parseFromSlice(std.json.Value, alloc, raw, .{});
    defer doc.deinit();
    const ev = parseEventLine(doc.value);
    try testing.expect(ev == .tool_use);
    try testing.expectEqualStrings("glob", ev.tool_use.name);
    try testing.expectEqualStrings("completed", ev.tool_use.status);
    try testing.expectEqualStrings("/tmp/a.txt", ev.tool_use.output);
    try testing.expect(std.mem.indexOf(u8, ev.tool_use.input, "/tmp") != null);
}

test "parseEventLine keeps the error of a tool_use that failed" {
    const alloc = testing.allocator;
    var doc = try std.json.parseFromSlice(std.json.Value, alloc,
        \\{"type":"tool_use","part":{"type":"tool","tool":"bash","state":{"status":"error","error":{"message":"exit 127"}}}}
    , .{});
    defer doc.deinit();
    const ev = parseEventLine(doc.value);
    try testing.expect(ev == .tool_use);
    try testing.expectEqualStrings("bash", ev.tool_use.name);
    try testing.expectEqualStrings("error", ev.tool_use.status);
    try testing.expectEqualStrings("exit 127", ev.tool_use.error_message);
}

test "parseEventLine reads the reasoning text of a thinking block" {
    const alloc = testing.allocator;
    var doc = try std.json.parseFromSlice(std.json.Value, alloc,
        \\{"type":"reasoning","part":{"type":"reasoning","text":"The user wants the file list.","metadata":{}}}
    , .{});
    defer doc.deinit();
    const ev = parseEventLine(doc.value);
    try testing.expect(ev == .reasoning);
    try testing.expectEqualStrings("The user wants the file list.", ev.reasoning);
}

test "parseEventLine surfaces the provider failure of an error event" {
    const alloc = testing.allocator;
    var doc = try std.json.parseFromSlice(std.json.Value, alloc,
        \\{"type":"error","error":{"type":"provider.no-route","message":"Model unavailable: opencode/nope"}}
    , .{});
    defer doc.deinit();
    const ev = parseEventLine(doc.value);
    try testing.expect(ev == .failure);
    try testing.expectEqualStrings("provider.no-route", ev.failure.kind);
    try testing.expectEqualStrings("Model unavailable: opencode/nope", ev.failure.message);
}

test "parseEventLine ignores lifecycle and malformed events" {
    const alloc = testing.allocator;
    const cases = [_][]const u8{
        \\{"type":"step_start","part":{"type":"step-start"}}
        ,
        \\{"type":"text","part":{}}
        ,
        \\{"type":"text","part":{"text":""}}
        ,
        \\{"nope":1}
        ,
        \\[1,2]
        ,
    };
    for (cases) |raw| {
        var doc = try std.json.parseFromSlice(std.json.Value, alloc, raw, .{});
        defer doc.deinit();
        try testing.expect(parseEventLine(doc.value) == .other);
    }
}

test "parseModelsList splits provider from model and drops junk lines" {
    const alloc = testing.allocator;
    const refs = try parseModelsList(alloc,
        \\opencode/beam-free
        \\opencode-go/iceman-contributor-free
        \\
        \\ not-a-model 
        \\weird/
        \\/noname
    );
    defer freeModelsList(alloc, refs);

    try testing.expectEqual(@as(usize, 2), refs.len);
    try testing.expectEqualStrings("opencode", refs[0].provider);
    try testing.expectEqualStrings("beam-free", refs[0].model);
    try testing.expectEqualStrings("opencode-go", refs[1].provider);
    try testing.expectEqualStrings("iceman-contributor-free", refs[1].model);
}

test "parseModelsList owns its strings, so the CLI output buffer may be released" {
    const alloc = testing.allocator;
    const stdout = try alloc.dupe(u8, "opencode/beam-free\nopencode-go/kimi-k3\n");
    const refs = try parseModelsList(alloc, stdout);
    defer freeModelsList(alloc, refs);

    @memset(stdout, 0xAA);
    alloc.free(stdout);

    try testing.expectEqualStrings("opencode", refs[0].provider);
    try testing.expectEqualStrings("beam-free", refs[0].model);
    try testing.expectEqualStrings("opencode-go", refs[1].provider);
    try testing.expectEqualStrings("kimi-k3", refs[1].model);
}

test "isFreeModelId treats free and contributor models as free" {
    try testing.expect(isFreeModelId("beam-free"));
    try testing.expect(isFreeModelId("iceman-contributor-free"));
    try testing.expect(isFreeModelId("muse-spark-1.3-contributor"));
    try testing.expect(isFreeModelId("GLM-5-FREE"));
    try testing.expect(!isFreeModelId("claude-opus-4-7"));
}

test "isFreeFromCost needs both sides priced at zero" {
    try testing.expectEqual(true, isFreeFromCost(0, 0).?);
    try testing.expectEqual(false, isFreeFromCost(0, 4.4).?);
    try testing.expectEqual(false, isFreeFromCost(1.4, 0).?);
    try testing.expect(isFreeFromCost(null, 0) == null);
}

test "freeRank sorts free models before paid ones" {
    try testing.expect(freeRank(true) < freeRank(false));
}

test "describeMissingBinary names the binary and the login step" {
    const alloc = testing.allocator;
    const msg = try describeMissingBinary(alloc, "opencode");
    defer alloc.free(msg);
    try testing.expect(std.mem.indexOf(u8, msg, "opencode") != null);
    try testing.expect(std.mem.indexOf(u8, msg, "not found") != null);
    try testing.expect(std.mem.indexOf(u8, msg, "opencode login") != null);
}

test "describeRunFailure carries the model and the CLI's own words" {
    const alloc = testing.allocator;
    const msg = try describeRunFailure(alloc, "opencode", "opencode/beam-free", "provider.no-route: boom");
    defer alloc.free(msg);
    try testing.expect(std.mem.indexOf(u8, msg, "opencode/beam-free") != null);
    try testing.expect(std.mem.indexOf(u8, msg, "provider.no-route: boom") != null);
}
