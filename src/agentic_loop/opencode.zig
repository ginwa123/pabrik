//! OpenCode v2 agent backend — Phase 1 (configuration + detection).

const std = @import("std");
const config_mod = @import("../modules/config/Config.zig");

/// Canonical `backend` values, re-exported from the config layer so there is
/// one definition. `Config.zig` owns the names because it owns the parser.
pub const Backend = config_mod.LlmConfig.Backend;

/// Default binary name, resolved through `PATH`.
pub const DEFAULT_BINARY: []const u8 = "opencode";

/// True when `backend` selects the OpenCode CLI.
pub fn isOpencodeBackend(backend: []const u8) bool {
    return std.mem.eql(u8, backend, Backend.opencode);
}

/// True when `backend` is one this build understands. An empty value means
/// "unset", which the cascade resolves to `http`.
pub fn isKnownBackend(backend: []const u8) bool {
    return backend.len == 0 or
        std.mem.eql(u8, backend, Backend.http) or
        std.mem.eql(u8, backend, Backend.claude_code) or
        isOpencodeBackend(backend);
}

/// Validation for an OpenCode profile. Unlike HTTP profiles, `base_url` and
/// `api_key` are NOT required — auth comes from `opencode` login state, not
/// from config.
pub fn validateOpencodeProfile(model: []const u8) error{MissingModel}!void {
    if (model.len == 0) return error.MissingModel;
}

/// Resolve the `opencode` binary to execute. * Empty `configured` →
/// `DEFAULT_BINARY` (`"opencode"`, via `PATH`). * Otherwise the configured
/// value verbatim (absolute path or alias).
pub fn resolveBinaryPath(configured: []const u8) []const u8 {
    if (configured.len == 0) return DEFAULT_BINARY;
    return configured;
}

/// Options for `buildPrintArgs`.
pub const PrintOptions = struct {
    /// Model passed as `--model`, in the CLI's `provider/model` form
    /// (e.g. `opencode-go/deepseek-flash`). Empty = omit (CLI default).
    model: []const u8 = "",
    /// Agent name passed as `--agent`. Empty = omit (CLI default agent).
    agent: []const u8 = "",
    /// When true, emit `--auto` — auto-approve permissions that are not
    /// explicitly denied. Required for a headless run: without it the CLI
    /// blocks on an interactive permission prompt that no one can answer.
    auto_approve: bool = true,
    /// When true, emit `--format json` (the machine-readable shape
    /// `parseResultLine` understands). Always true in production; exposed so
    /// tests can assert the human-readable shape.
    json_format: bool = true,
};

/// Build argv for a non-interactive OpenCode run: `opencode run [--model m]
/// [--agent a] [--auto] [--format json] <prompt>`.
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
    if (opts.json_format) {
        try list.append(allocator, try allocator.dupe(u8, "--format"));
        try list.append(allocator, try allocator.dupe(u8, "json"));
    }

    // The prompt is LAST: `opencode run [flags] [<message...>]` takes the
    // message as a trailing positional, so a leading prompt would be parsed
    // as a flag value.
    try list.append(allocator, try allocator.dupe(u8, prompt));

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

/// Build the environment overlay for one OpenCode run. OpenCode doesn't
/// require special environment variables for authentication like Claude Code
/// does with `CLAUDE_CONFIG_DIR`.
pub fn buildEnvOverlay(
    _: std.mem.Allocator,
    _: ?[]const u8,
) ![]EnvVar {
    return &.{};
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

/// Render the result of an `opencode --version` probe as one human line.
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
            "'{s}' was not found or could not be executed. Install the OpenCode CLI and run `opencode login`, or point the profile at an absolute binary path.",
            .{binary},
        );
    }
    const out = std.mem.trim(u8, stdout, " \\t\\r\\n");
    const err = std.mem.trim(u8, stderr, " \\t\\r\\n");
    if (!exited_zero) {
        return std.fmt.allocPrint(
            allocator,
            "`{s} --version` exited non-zero: {s}",
            .{ binary, if (err.len > 0) err else "(no stderr)" },
        );
    }
    return std.fmt.allocPrint(
        allocator,
        "OpenCode CLI is available: {s}. Auth comes from `opencode login` (no API key in config).",
        .{if (out.len > 0) out else "version unknown"},
    );
}

/// Result extracted from one `--format json` output line.
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

/// Parse one `opencode run --format json` output line. Returns `.is_result ==
/// true` only for the terminal `{"type":"result","result":"..."}` message.
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

/// Actionable error text surfaced when an OpenCode profile reaches the
/// workflow before Phase 2 execution wiring lands.
pub fn notWiredMessage(
    allocator: std.mem.Allocator,
    model: []const u8,
) ![]u8 {
    return std.fmt.allocPrint(
        allocator,
        "profile uses backend=\"opencode\" (model=\"{s}\") but CLI execution is not wired yet (Phase 1: configuration only). " ++
            "Install the CLI (https://docs.opencode.dev/) and run `opencode login`, " ++
            "or set the profile's backend back to \"http\".",
        .{model},
    );
}

// ─── Behaviour tests ─────────────────────────────────────────────
// These call the module's functions and assert return values — never source
// text (see AGENTS.md "Tests — Assert Behaviour").

const testing = std.testing;

test "isOpencodeBackend matches only the canonical value" {
    try testing.expect(isOpencodeBackend("opencode"));
    try testing.expect(!isOpencodeBackend("http"));
    try testing.expect(!isOpencodeBackend(""));
    try testing.expect(!isOpencodeBackend("Opencode"));
    // A url_style value must never read as a backend.
    try testing.expect(!isOpencodeBackend("openai"));
}

test "isKnownBackend accepts unset, http, claude-code and opencode" {
    try testing.expect(isKnownBackend(""));
    try testing.expect(isKnownBackend("http"));
    try testing.expect(isKnownBackend("claude-code"));
    try testing.expect(isKnownBackend("opencode"));
    try testing.expect(!isKnownBackend("codex"));
    try testing.expect(!isKnownBackend("weird"));
}

test "validateOpencodeProfile requires model only" {
    try validateOpencodeProfile("deepseek-flash");
    try validateOpencodeProfile("opencode-go/deepseek-flash");
    try testing.expectError(error.MissingModel, validateOpencodeProfile(""));
}

test "resolveBinaryPath defaults to opencode on PATH" {
    try testing.expectEqualStrings("opencode", resolveBinaryPath(""));
    try testing.expectEqualStrings("/usr/bin/opencode", resolveBinaryPath("/usr/bin/opencode"));
}

test "buildPrintArgs emits model, auto and json format with the prompt last" {
    const alloc = testing.allocator;
    const args = try buildPrintArgs(alloc, "opencode", "hello", .{ .model = "opencode-go/deepseek-flash" });
    defer freeArgs(alloc, args);
    // opencode run --model opencode-go/deepseek-flash --auto --format json hello
    try testing.expectEqual(@as(usize, 8), args.len);
    try testing.expectEqualStrings("opencode", args[0]);
    try testing.expectEqualStrings("run", args[1]);
    try testing.expectEqualStrings("--model", args[2]);
    try testing.expectEqualStrings("opencode-go/deepseek-flash", args[3]);
    try testing.expectEqualStrings("--auto", args[4]);
    try testing.expectEqualStrings("--format", args[5]);
    try testing.expectEqualStrings("json", args[6]);
    // The prompt is the trailing positional — a leading prompt would be
    // parsed as a flag value by `opencode run [flags] [<message...>]`.
    try testing.expectEqualStrings("hello", args[7]);
}

test "buildPrintArgs omits optional flags when unset" {
    const alloc = testing.allocator;
    const args = try buildPrintArgs(alloc, "opencode", "hi", .{});
    defer freeArgs(alloc, args);
    // opencode run --auto --format json hi
    try testing.expectEqual(@as(usize, 6), args.len);
    try testing.expectEqualStrings("opencode", args[0]);
    try testing.expectEqualStrings("run", args[1]);
    try testing.expectEqualStrings("--auto", args[2]);
    try testing.expectEqualStrings("--format", args[3]);
    try testing.expectEqualStrings("json", args[4]);
    try testing.expectEqualStrings("hi", args[5]);
}

test "buildPrintArgs omits --auto and --format when disabled" {
    const alloc = testing.allocator;
    const args = try buildPrintArgs(alloc, "opencode", "hi", .{ .auto_approve = false, .json_format = false });
    defer freeArgs(alloc, args);
    try testing.expectEqual(@as(usize, 3), args.len);
    try testing.expectEqualStrings("opencode", args[0]);
    try testing.expectEqualStrings("run", args[1]);
    try testing.expectEqualStrings("hi", args[2]);
}

test "buildPrintArgs includes --agent when set" {
    const alloc = testing.allocator;
    const args = try buildPrintArgs(alloc, "opencode", "hi", .{ .agent = "build" });
    defer freeArgs(alloc, args);
    // opencode run --agent build --auto --format json hi
    try testing.expectEqual(@as(usize, 8), args.len);
    try testing.expectEqualStrings("--agent", args[2]);
    try testing.expectEqualStrings("build", args[3]);
    try testing.expectEqualStrings("hi", args[7]);
}

test "buildPrintArgs never puts the prompt in a shell-interpreted position" {
    // The prompt travels as a single argv element, so shell metacharacters
    // in a user message stay literal.
    const alloc = testing.allocator;
    const args = try buildPrintArgs(alloc, "opencode", "rm -rf /; echo $(whoami)", .{});
    defer freeArgs(alloc, args);
    try testing.expectEqualStrings("rm -rf /; echo $(whoami)", args[args.len - 1]);
}

test "buildEnvOverlay is always empty" {
    const alloc = testing.allocator;
    const vars = try buildEnvOverlay(alloc, "/some/path");
    defer freeEnvOverlay(alloc, vars);
    try testing.expectEqual(@as(usize, 0), vars.len);

    const empty = try buildEnvOverlay(alloc, "");
    defer freeEnvOverlay(alloc, empty);
    try testing.expectEqual(@as(usize, 0), empty.len);

    const none = try buildEnvOverlay(alloc, null);
    defer freeEnvOverlay(alloc, none);
    try testing.expectEqual(@as(usize, 0), none.len);
}

test "buildVersionProbeArgs is binary plus --version" {
    const alloc = testing.allocator;
    const args = try buildVersionProbeArgs(alloc, "opencode");
    defer freeArgs(alloc, args);
    try testing.expectEqual(@as(usize, 2), args.len);
    try testing.expectEqualStrings("opencode", args[0]);
    try testing.expectEqualStrings("--version", args[1]);
}

test "describeVersionProbe reports a successful probe with its version" {
    const alloc = testing.allocator;
    const msg = try describeVersionProbe(alloc, "opencode", false, true, "2.0.18\\n", "");
    defer alloc.free(msg);
    try testing.expect(std.mem.indexOf(u8, msg, "2.0.18") != null);
    try testing.expect(std.mem.indexOf(u8, msg, "opencode login") != null);
}

test "describeVersionProbe explains a missing binary" {
    const alloc = testing.allocator;
    const msg = try describeVersionProbe(alloc, "opencode", true, false, "", "");
    defer alloc.free(msg);
    try testing.expect(std.mem.indexOf(u8, msg, "not found") != null);
    try testing.expect(std.mem.indexOf(u8, msg, "opencode login") != null);
}

test "describeVersionProbe surfaces stderr on a non-zero exit" {
    const alloc = testing.allocator;
    const msg = try describeVersionProbe(alloc, "opencode", false, false, "", "boom");
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
    const msg = try notWiredMessage(alloc, "deepseek-flash");
    defer alloc.free(msg);
    try testing.expect(std.mem.indexOf(u8, msg, "backend=\"opencode\"") != null);
    try testing.expect(std.mem.indexOf(u8, msg, "deepseek-flash") != null);
    try testing.expect(std.mem.indexOf(u8, msg, "opencode login") != null);
}
