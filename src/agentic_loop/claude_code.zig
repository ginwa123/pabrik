//! Claude Code agent backend — Phase 1 (configuration + detection).

const std = @import("std");
const config_mod = @import("../modules/config/Config.zig");

/// Canonical `backend` values, re-exported from the config layer so there is
/// one definition. `Config.zig` owns the names because it owns the parser.
pub const Backend = config_mod.LlmConfig.Backend;

/// Default binary name, resolved through `PATH`.
pub const DEFAULT_BINARY: []const u8 = "claude";

/// True when `backend` selects the Claude Code CLI.
pub fn isClaudeCodeBackend(backend: []const u8) bool {
    return std.mem.eql(u8, backend, Backend.claude_code);
}

/// True when `backend` is one this build understands. An empty value means
/// "unset", which the cascade resolves to `http`.
pub fn isKnownBackend(backend: []const u8) bool {
    return backend.len == 0 or
        std.mem.eql(u8, backend, Backend.http) or
        isClaudeCodeBackend(backend);
}

/// Validation for a Claude Code profile. Unlike HTTP profiles, `base_url` and
/// `api_key` are NOT required — auth comes from `claude login`, not from
/// config. Only `model` must be non-empty (it becomes the CLI's `--model`).
pub fn validateClaudeCodeProfile(model: []const u8) error{MissingModel}!void {
    if (model.len == 0) return error.MissingModel;
}

/// Resolve the `claude` binary to execute. * Empty `configured` →
/// `DEFAULT_BINARY` (`"claude"`, via `PATH`). * Otherwise the configured
/// value verbatim (absolute path or alias).
pub fn resolveBinaryPath(configured: []const u8) []const u8 {
    if (configured.len == 0) return DEFAULT_BINARY;
    return configured;
}

/// Options for `buildPrintArgs`.
pub const PrintOptions = struct {
    /// Model/alias passed as `--model`. Empty = omit (CLI default).
    model: []const u8 = "",
    /// Working directory passed as `--add-dir` so the CLI's file tools stay
    /// scoped to the session cwd. Empty = omit.
    workdir: []const u8 = "",
    /// Maximum agentic turns (`--max-turns`). Null = omit (CLI default).
    max_turns: ?u32 = null,
    /// When true, emit `--verbose --output-format stream-json` (the shape
    /// `parseResultLine` understands). Always true in production; exposed so
    /// tests can assert the non-streaming shape.
    stream_json: bool = true,
};

/// Build argv for a non-interactive Claude Code run: `claude -p <prompt>
/// [--model m] [--add-dir dir] [--max-turns n] [--verbose --output-format
/// stream-json]`.
pub fn buildPrintArgs(
    allocator: std.mem.Allocator,
    binary: []const u8,
    prompt: []const u8,
    opts: PrintOptions,
) ![][]const u8 {
    var list = std.ArrayList([]const u8).empty;
    errdefer {
        for (list.items) |s| allocator.free(s);
        list.deinit(allocator);
    }

    try list.append(allocator, try allocator.dupe(u8, binary));
    try list.append(allocator, try allocator.dupe(u8, "-p"));
    try list.append(allocator, try allocator.dupe(u8, prompt));

    if (opts.model.len > 0) {
        try list.append(allocator, try allocator.dupe(u8, "--model"));
        try list.append(allocator, try allocator.dupe(u8, opts.model));
    }
    if (opts.workdir.len > 0) {
        try list.append(allocator, try allocator.dupe(u8, "--add-dir"));
        try list.append(allocator, try allocator.dupe(u8, opts.workdir));
    }
    if (opts.max_turns) |n| {
        try list.append(allocator, try allocator.dupe(u8, "--max-turns"));
        try list.append(allocator, try std.fmt.allocPrint(allocator, "{d}", .{n}));
    }
    if (opts.stream_json) {
        try list.append(allocator, try allocator.dupe(u8, "--verbose"));
        try list.append(allocator, try allocator.dupe(u8, "--output-format"));
        try list.append(allocator, try allocator.dupe(u8, "stream-json"));
    }

    return list.toOwnedSlice(allocator);
}

/// Free an argv slice built by `buildPrintArgs`.
pub fn freeArgs(allocator: std.mem.Allocator, args: [][]const u8) void {
    for (args) |s| allocator.free(s);
    allocator.free(args);
}

/// One environment variable to set on the CLI child process.
pub const EnvVar = struct {
    name: []const u8,
    value: []const u8,
};

/// Build the environment overlay for one Claude Code run.
pub fn buildEnvOverlay(
    allocator: std.mem.Allocator,
    config_dir: ?[]const u8,
) ![]EnvVar {
    const dir = config_dir orelse return &.{};
    if (dir.len == 0) return &.{};

    const vars = try allocator.alloc(EnvVar, 1);
    errdefer allocator.free(vars);
    vars[0] = .{
        .name = try allocator.dupe(u8, "CLAUDE_CONFIG_DIR"),
        .value = try allocator.dupe(u8, dir),
    };
    return vars;
}

/// Free an overlay built by `buildEnvOverlay`.
pub fn freeEnvOverlay(allocator: std.mem.Allocator, vars: []EnvVar) void {
    for (vars) |v| {
        allocator.free(v.name);
        allocator.free(v.value);
    }
    if (vars.len > 0) allocator.free(vars);
}

/// argv for the health probe: `<binary> --version`.
pub fn buildVersionProbeArgs(allocator: std.mem.Allocator, binary: []const u8) ![][]const u8 {
    const args = try allocator.alloc([]const u8, 2);
    errdefer allocator.free(args);
    args[0] = try allocator.dupe(u8, binary);
    errdefer allocator.free(args[0]);
    args[1] = try allocator.dupe(u8, "--version");
    return args;
}

/// Render the result of a `claude --version` probe as one human line.
pub fn describeVersionProbe(
    allocator: std.mem.Allocator,
    binary: []const u8,
    spawn_failed: bool,
    exited_zero: bool,
    stdout: []const u8,
    stderr: []const u8,
) ![]u8 {
    if (spawn_failed) {
        return std.fmt.allocPrint(
            allocator,
            "'{s}' was not found or could not be executed. Install the Claude Code CLI and run `claude login`, or point the profile at an absolute binary path.",
            .{binary},
        );
    }
    const out = std.mem.trim(u8, stdout, " \t\r\n");
    const err = std.mem.trim(u8, stderr, " \t\r\n");
    if (!exited_zero) {
        return std.fmt.allocPrint(
            allocator,
            "`{s} --version` exited non-zero: {s}",
            .{ binary, if (err.len > 0) err else "(no stderr)" },
        );
    }
    return std.fmt.allocPrint(
        allocator,
        "Claude Code CLI is available: {s}. Auth comes from `claude login` (no API key in config).",
        .{if (out.len > 0) out else "version unknown"},
    );
}

/// Result extracted from one `stream-json` output line.
pub const ParsedLine = struct {
    /// Raw `type` field (e.g. `"result"`, `"assistant"`, `"system"`).
    /// Empty when the line has no string `type`.
    line_type: []const u8,
    /// For `type == "result"`: the `result` text (borrowed from the parsed
    /// JSON value — valid while `parsed` lives) or the `subtype` fallback.
    /// Empty otherwise.
    result_text: []const u8 = "",
    /// True iff this line is the terminal `type == "result"` message.
    is_result: bool = false,
};

/// Parse one `claude -p --output-format stream-json` output line. Returns
/// `.is_result == true` only for the terminal
/// `{"type":"result","result":"..."}` message.
pub fn parseResultLine(
    parsed_value: std.json.Value,
) ParsedLine {
    if (parsed_value != .object) return .{ .line_type = "" };
    const obj = parsed_value.object;
    const t = switch (obj.get("type") orelse std.json.Value{ .null = {} }) {
        .string => |s| s,
        else => return .{ .line_type = "" },
    };
    if (!std.mem.eql(u8, t, "result")) return .{ .line_type = t };
    const text: []const u8 = switch (obj.get("result") orelse std.json.Value{ .null = {} }) {
        .string => |s| s,
        else => switch (obj.get("subtype") orelse std.json.Value{ .null = {} }) {
            .string => |s| s,
            else => "",
        },
    };
    return .{ .line_type = t, .result_text = text, .is_result = true };
}

/// Actionable error text surfaced when a Claude Code profile reaches the
/// workflow before Phase 2 execution wiring lands.
pub fn notWiredMessage(
    allocator: std.mem.Allocator,
    model: []const u8,
) ![]u8 {
    return std.fmt.allocPrint(
        allocator,
        "profile uses backend=\"claude-code\" (model=\"{s}\") but CLI execution is not wired yet (Phase 1: configuration only). " ++
            "Install the CLI (https://docs.anthropic.com/en/docs/claude-code) and run `claude login`, " ++
            "or set the profile's backend back to \"http\".",
        .{model},
    );
}

// ─── Behaviour tests ─────────────────────────────────────────────
// These call the module's functions and assert return values — never source
// text (see AGENTS.md "Tests — Assert Behaviour").

const testing = std.testing;

test "isClaudeCodeBackend matches only the canonical value" {
    try testing.expect(isClaudeCodeBackend("claude-code"));
    try testing.expect(!isClaudeCodeBackend("http"));
    try testing.expect(!isClaudeCodeBackend(""));
    try testing.expect(!isClaudeCodeBackend("Claude-Code"));
    // A url_style value must never read as a backend.
    try testing.expect(!isClaudeCodeBackend("anthropic"));
}

test "isKnownBackend accepts unset, http and claude-code" {
    try testing.expect(isKnownBackend(""));
    try testing.expect(isKnownBackend("http"));
    try testing.expect(isKnownBackend("claude-code"));
    try testing.expect(!isKnownBackend("codex"));
    try testing.expect(!isKnownBackend("weird"));
}

test "validateClaudeCodeProfile requires model only" {
    try validateClaudeCodeProfile("sonnet");
    try validateClaudeCodeProfile("claude-sonnet-4-5-20250929");
    try testing.expectError(error.MissingModel, validateClaudeCodeProfile(""));
}

test "resolveBinaryPath defaults to claude on PATH" {
    try testing.expectEqualStrings("claude", resolveBinaryPath(""));
    try testing.expectEqualStrings("/usr/local/bin/claude", resolveBinaryPath("/usr/local/bin/claude"));
}

test "buildPrintArgs emits prompt plus stream-json flags" {
    const alloc = testing.allocator;
    const args = try buildPrintArgs(alloc, "claude", "hello", .{ .model = "sonnet" });
    defer freeArgs(alloc, args);
    try testing.expectEqual(@as(usize, 8), args.len);
    try testing.expectEqualStrings("claude", args[0]);
    try testing.expectEqualStrings("-p", args[1]);
    try testing.expectEqualStrings("hello", args[2]);
    try testing.expectEqualStrings("--model", args[3]);
    try testing.expectEqualStrings("sonnet", args[4]);
    try testing.expectEqualStrings("--verbose", args[5]);
    try testing.expectEqualStrings("--output-format", args[6]);
    try testing.expectEqualStrings("stream-json", args[7]);
}

test "buildPrintArgs omits optional flags when unset" {
    const alloc = testing.allocator;
    const args = try buildPrintArgs(alloc, "claude", "hi", .{});
    defer freeArgs(alloc, args);
    try testing.expectEqual(@as(usize, 6), args.len);
    try testing.expectEqualStrings("claude", args[0]);
    try testing.expectEqualStrings("-p", args[1]);
    try testing.expectEqualStrings("hi", args[2]);
}

test "buildPrintArgs includes workdir and max-turns when set" {
    const alloc = testing.allocator;
    const args = try buildPrintArgs(alloc, "claude", "hi", .{ .workdir = "/tmp/w", .max_turns = 5 });
    defer freeArgs(alloc, args);
    // claude -p hi --add-dir /tmp/w --max-turns 5 --verbose --output-format stream-json
    try testing.expectEqual(@as(usize, 10), args.len);
    try testing.expectEqualStrings("--add-dir", args[3]);
    try testing.expectEqualStrings("/tmp/w", args[4]);
    try testing.expectEqualStrings("--max-turns", args[5]);
    try testing.expectEqualStrings("5", args[6]);
}

test "buildPrintArgs never puts the prompt in a shell-interpreted position" {
    // The prompt travels as a single argv element, so shell metacharacters
    // in a user message stay literal.
    const alloc = testing.allocator;
    const args = try buildPrintArgs(alloc, "claude", "rm -rf /; echo $(whoami)", .{});
    defer freeArgs(alloc, args);
    try testing.expectEqualStrings("rm -rf /; echo $(whoami)", args[2]);
}

test "buildEnvOverlay sets CLAUDE_CONFIG_DIR for a configured dir" {
    const alloc = testing.allocator;
    const vars = try buildEnvOverlay(alloc, "/home/u/.claude-work");
    defer freeEnvOverlay(alloc, vars);
    try testing.expectEqual(@as(usize, 1), vars.len);
    try testing.expectEqualStrings("CLAUDE_CONFIG_DIR", vars[0].name);
    try testing.expectEqualStrings("/home/u/.claude-work", vars[0].value);
}

test "buildEnvOverlay is empty for null and empty config_dir" {
    const alloc = testing.allocator;
    const none = try buildEnvOverlay(alloc, null);
    defer freeEnvOverlay(alloc, none);
    try testing.expectEqual(@as(usize, 0), none.len);

    const empty = try buildEnvOverlay(alloc, "");
    defer freeEnvOverlay(alloc, empty);
    try testing.expectEqual(@as(usize, 0), empty.len);
}

test "buildVersionProbeArgs is binary plus --version" {
    const alloc = testing.allocator;
    const args = try buildVersionProbeArgs(alloc, "claude");
    defer freeArgs(alloc, args);
    try testing.expectEqual(@as(usize, 2), args.len);
    try testing.expectEqualStrings("claude", args[0]);
    try testing.expectEqualStrings("--version", args[1]);
}

test "describeVersionProbe reports a successful probe with its version" {
    const alloc = testing.allocator;
    const msg = try describeVersionProbe(alloc, "claude", false, true, "1.2.3 (Claude Code)\n", "");
    defer alloc.free(msg);
    try testing.expect(std.mem.indexOf(u8, msg, "1.2.3") != null);
    try testing.expect(std.mem.indexOf(u8, msg, "claude login") != null);
}

test "describeVersionProbe explains a missing binary" {
    const alloc = testing.allocator;
    const msg = try describeVersionProbe(alloc, "claude", true, false, "", "");
    defer alloc.free(msg);
    try testing.expect(std.mem.indexOf(u8, msg, "not found") != null);
    try testing.expect(std.mem.indexOf(u8, msg, "claude login") != null);
}

test "describeVersionProbe surfaces stderr on a non-zero exit" {
    const alloc = testing.allocator;
    const msg = try describeVersionProbe(alloc, "claude", false, false, "", "boom");
    defer alloc.free(msg);
    try testing.expect(std.mem.indexOf(u8, msg, "non-zero") != null);
    try testing.expect(std.mem.indexOf(u8, msg, "boom") != null);
}

test "parseResultLine extracts the terminal result text" {
    const alloc = testing.allocator;
    const doc = try std.json.parseFromSlice(std.json.Value, alloc, "{\"type\":\"result\",\"result\":\"done!\"}", .{});
    defer doc.deinit();
    const p = parseResultLine(doc.value);
    try testing.expect(p.is_result);
    try testing.expectEqualStrings("result", p.line_type);
    try testing.expectEqualStrings("done!", p.result_text);
}

test "parseResultLine ignores non-result lines and bad json shapes" {
    const alloc = testing.allocator;
    const doc = try std.json.parseFromSlice(std.json.Value, alloc, "{\"type\":\"assistant\",\"message\":{}}", .{});
    defer doc.deinit();
    const p = parseResultLine(doc.value);
    try testing.expect(!p.is_result);
    try testing.expectEqualStrings("assistant", p.line_type);

    const arr = try std.json.parseFromSlice(std.json.Value, alloc, "[1,2]", .{});
    defer arr.deinit();
    const q = parseResultLine(arr.value);
    try testing.expect(!q.is_result);
}

test "notWiredMessage names the backend, the model and the remediation" {
    const alloc = testing.allocator;
    const msg = try notWiredMessage(alloc, "sonnet");
    defer alloc.free(msg);
    try testing.expect(std.mem.indexOf(u8, msg, "backend=\"claude-code\"") != null);
    try testing.expect(std.mem.indexOf(u8, msg, "sonnet") != null);
    try testing.expect(std.mem.indexOf(u8, msg, "claude login") != null);
}
