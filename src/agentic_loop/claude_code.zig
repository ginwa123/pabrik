//! Claude Code agent backend — Phase 1 (configuration + detection).
//!
//! Pabrik's profiles have always been HTTP-only (`url_style` of
//! `openai` | `openai-response` | `anthropic`, talking to `base_url`
//! with `api_key`). Claude Code is different: it is a local `claude`
//! CLI authenticated via the user's subscription (`claude login`,
//! credentials in `~/.claude/`), not via an API key, and it owns its
//! own agentic loop (file edits, bash, etc.).
//!
//! Phase 1 models that backend as a fourth `url_style` value,
//! `"claude-code"`, so the whole existing cascade
//! (`resolveEffectiveProfile`, per-session overlays, sub-agent
//! inheritance) keeps working unchanged. HTTP-only fields
//! (`base_url`, `api_key`) are ignored for this style — a profile
//! needs only `model` (e.g. `sonnet`, `opus`, or a full
//! `claude-sonnet-4-5-...` id).
//!
//! What this module owns:
//!   * the canonical style string + predicate (`isClaudeCodeStyle`),
//!   * profile validation for the style (`validateClaudeCodeProfile`),
//!   * `claude` binary discovery (`resolveBinaryPath`),
//!   * `claude -p` argv construction (`buildPrintArgs`),
//!   * minimal `stream-json` line parsing (`parseResultLine`),
//!     so the future execution wiring has one owner.
//!
//! What it does NOT do yet: execute the CLI or stream its output
//! into the workflow. `workflow.zig` gates on this style and fails
//! fast with an actionable message until that wiring lands (Phase 2).

const std = @import("std");

/// Canonical `url_style` value for the Claude Code CLI backend.
/// Stored verbatim in `config.json` profiles alongside the three
/// HTTP styles.
pub const STYLE: []const u8 = "claude-code";

/// Default binary name resolved via `PATH`. Users with a custom
/// install set an absolute path instead (see `resolveBinaryPath`).
pub const DEFAULT_BINARY: []const u8 = "claude";

/// True when `url_style` selects the Claude Code CLI backend.
pub fn isClaudeCodeStyle(url_style: []const u8) bool {
    return std.mem.eql(u8, url_style, STYLE);
}

/// True when `url_style` is any value the backend understands
/// (the three HTTP styles plus Claude Code).
pub fn isKnownStyle(url_style: []const u8) bool {
    return std.mem.eql(u8, url_style, "openai") or
        std.mem.eql(u8, url_style, "openai-response") or
        std.mem.eql(u8, url_style, "anthropic") or
        isClaudeCodeStyle(url_style);
}

/// Validation for a Claude Code profile.
///
/// Unlike HTTP profiles, `base_url` and `api_key` are NOT required —
/// auth comes from `claude login`, not from config. Only `model`
/// must be non-empty (it selects the Claude model/alias the CLI
/// passes via `--model`).
pub fn validateClaudeCodeProfile(model: []const u8) error{MissingModel}!void {
    if (model.len == 0) return error.MissingModel;
}

/// Resolve the `claude` binary to execute.
///
/// * Empty `configured` → `DEFAULT_BINARY` (`"claude"`, via `PATH`).
/// * Otherwise the configured value verbatim (absolute path or alias).
/// The returned slice borrows from `configured` when set, else is the
/// `DEFAULT_BINARY` constant — never free it.
pub fn resolveBinaryPath(configured: []const u8) []const u8 {
    if (configured.len == 0) return DEFAULT_BINARY;
    return configured;
}

/// Options for `buildPrintArgs`.
pub const PrintOptions = struct {
    /// Model/alias passed as `--model`. Empty = omit (CLI default).
    model: []const u8 = "",
    /// Working directory passed as `--add-dir` so the CLI's file tools
    /// stay scoped to the session cwd. Empty = omit.
    workdir: []const u8 = "",
    /// Maximum agentic turns (`--max-turns`). Null = omit (CLI default).
    max_turns: ?u32 = null,
    /// When true, emit `--verbose --output-format stream-json` (the
    /// streaming shape `parseResultLine` understands). Always true in
    /// production; exposed so tests can assert the non-verbose shape.
    stream_json: bool = true,
};

/// Build argv for a non-interactive Claude Code run:
/// `claude -p <prompt> [--model m] [--add-dir dir] [--max-turns n]
/// [--verbose --output-format stream-json]`.
///
/// The caller owns the returned slice (each entry is duped; free with
/// `freeArgs`). `prompt` is passed as the `-p` value — the CLI reads
/// the turn prompt from argv, not stdin.
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

/// Result extracted from one `stream-json` output line.
pub const ParsedLine = struct {
    /// Raw `type` field (e.g. `"result"`, `"assistant"`, `"system"`).
    /// Empty when the line has no string `type`.
    line_type: []const u8,
    /// For `type == "result"`: the `result` text (borrowed from the
    /// parsed JSON value — valid while `parsed` lives) or `subtype`
    /// fallback. Empty otherwise.
    result_text: []const u8 = "",
    /// True iff this line is the terminal `type == "result"` message.
    is_result: bool = false,
};

/// Parse one `claude -p --output-format stream-json` output line.
///
/// Returns `.is_result == true` only for the terminal
/// `{"type":"result","result":"..."}` message. All other line types
/// (assistant deltas, system init, tool uses) parse to
/// `.is_result == false` so the caller can ignore-or-forward them.
/// Invalid JSON parses to a benign non-result (never an error) —
/// stdout interleaves human-readable logs the parser must skip.
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

/// Actionable error text surfaced when a Claude Code profile reaches
/// the workflow before Phase 2 execution wiring lands. Kept here (not
/// inlined at the call site) so the message has one owner and tests
/// pin its wording without importing the workflow.
pub fn notWiredMessage(
    allocator: std.mem.Allocator,
    model: []const u8,
) ![]u8 {
    return std.fmt.allocPrint(
        allocator,
        "profile uses url_style=\"claude-code\" (model=\"{s}\") but CLI execution is not wired yet (Phase 1: configuration only). " ++
            "Install the CLI (https://docs.anthropic.com/en/docs/claude-code) and run `claude login`, " ++
            "or switch the profile back to an HTTP url_style (openai|openai-response|anthropic).",
        .{model},
    );
}

// ─── Behaviour tests ─────────────────────────────────────────────
// These call the module's functions and assert return values — never
// source text (see AGENTS.md "Tests — Assert Behaviour").

const testing = std.testing;

test "isClaudeCodeStyle matches only the canonical style" {
    try testing.expect(isClaudeCodeStyle("claude-code"));
    try testing.expect(!isClaudeCodeStyle("openai"));
    try testing.expect(!isClaudeCodeStyle("openai-response"));
    try testing.expect(!isClaudeCodeStyle("anthropic"));
    try testing.expect(!isClaudeCodeStyle(""));
    try testing.expect(!isClaudeCodeStyle("Claude-Code"));
}

test "isKnownStyle accepts the three HTTP styles plus claude-code" {
    try testing.expect(isKnownStyle("openai"));
    try testing.expect(isKnownStyle("openai-response"));
    try testing.expect(isKnownStyle("anthropic"));
    try testing.expect(isKnownStyle("claude-code"));
    try testing.expect(!isKnownStyle("weird"));
    try testing.expect(!isKnownStyle(""));
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

test "notWiredMessage names the model and the remediation" {
    const alloc = testing.allocator;
    const msg = try notWiredMessage(alloc, "sonnet");
    defer alloc.free(msg);
    try testing.expect(std.mem.indexOf(u8, msg, "claude-code") != null);
    try testing.expect(std.mem.indexOf(u8, msg, "sonnet") != null);
    try testing.expect(std.mem.indexOf(u8, msg, "claude login") != null);
}
