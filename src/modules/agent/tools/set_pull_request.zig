const std = @import("std");
const schemas = @import("schemas.zig");
const ToolProperty = schemas.ToolProperty;
const ToolParameters = schemas.ToolParameters;
const AgentToolFunction = schemas.AgentToolFunction;
const AgentTool = schemas.AgentTool;
const pr_provider = @import("pr_provider.zig");
const PrProvider = pr_provider.PrProvider;

/// Input structure for set_pull_request tool (attach-only: binds an
/// EXISTING pull/merge-request URL to the session; it never creates one).
pub const SetPullRequestInput = struct {
    /// Normalized PR/MR URL, e.g. `https://github.com/acme/app/pull/42` or
    /// `https://gitlab.com/group/sub/repo/-/merge_requests/7`.
    pr_url: []const u8 = "",
    /// Optional provider override: "github" | "gitlab" | "generic". Empty
    /// (the default) = auto-detect from the URL.
    provider: []const u8 = "",
    /// Optional base ref for `generic`-provider diffs (e.g. "main").
    /// Ignored for github/gitlab (base comes from the forge). Falls
    /// back to auto-detect when empty.
    base: []const u8 = "",
    /// Optional head ref for `generic`-provider diffs (e.g. a branch
    /// name). Ignored for github/gitlab. Defaults to the current
    /// branch when empty.
    head: []const u8 = "",
    /// When true, unbind the session's PR (clears pr_url + pr_provider).
    /// All other fields are ignored when true.
    clear: bool = false,
    /// When true (default), confirm the PR exists via the provider CLI (`gh
    /// pr view` / `glab mr view`) before persisting.
    verify: bool = true,
    /// The session_id this PR is bound to. The LLM does NOT supply
    /// this — the exec wrapper injects `ctx.session_id` at call time.
    session_id: []const u8 = "",
};

pub const set_pull_request_tool_system_prompt =
    \\## Set Pull Request Tool — Behavior (MANDATORY when applicable)
    \\When the human asks to attach, link, or review a pull request /
    \\merge request for the current session, call `set_pull_request`
    \\with the PR URL. This binds the PR to the session so the chat's
    \\right panel shows the PR's file changes. The tool is attach-only:
    \\it never creates a PR (creation stays with `gh pr create` /
    \\`glab mr create` via bash, or the Create-PR dialog).
    \\
    \\- `pr_url` is required (unless `clear=true`). Paste the full URL.
    \\- Leave `provider` empty unless the forge is self-hosted and
    \\  auto-detection could misroute (e.g. GitHub Enterprise on a
    \\  custom domain → pass `provider="github"`).
    \\- For non-GitHub/non-GitLab forges the provider is `generic` and
    \\  the panel diffs `base...head` locally — pass both when the
    \\  defaults (auto-detected base, current branch) are wrong.
    \\- Pass `clear=true` to unbind before attaching a different PR.
    \\
;

pub const set_pull_request_tool = AgentTool{
    .type = "function",
    .function = .{
        .name = "set_pull_request",
        .description =
        \\Attach an existing pull/merge-request URL to the current session so the chat's right panel shows the PR's file changes. Works for GitHub (gh CLI), GitLab (glab CLI, incl. self-hosted), and generic forges (pure-git base...head diff, no CLI needed). Never creates a PR — only binds one. Pass clear=true to unbind the current PR.
        ,
        .parameters = .{
            .type = "object",
            .properties = &.{
                .{
                    .name = "pr_url",
                    .type = "string",
                    .description = "Full PR/MR URL, e.g. https://github.com/acme/app/pull/42. Required unless clear=true. Credentials and /files, /commits UI suffixes are stripped automatically.",
                },
                .{
                    .name = "provider",
                    .type = "string",
                    .description = "Optional override: \"github\", \"gitlab\", or \"generic\". Empty = auto-detect from the URL. Needed for self-hosted forges whose host does not reveal the provider.",
                },
                .{
                    .name = "base",
                    .type = "string",
                    .description = "Optional base ref for generic-provider diffs (e.g. \"main\"). Ignored for github/gitlab.",
                },
                .{
                    .name = "head",
                    .type = "string",
                    .description = "Optional head ref for generic-provider diffs. Ignored for github/gitlab. Defaults to the current branch.",
                },
                .{
                    .name = "clear",
                    .type = "boolean",
                    .description = "If true, unbind the session's PR (clears pr_url + pr_provider); all other fields are ignored. Default: false.",
                },
                .{
                    .name = "verify",
                    .type = "boolean",
                    .description = "If true (default), confirm the PR exists via gh/glab before persisting. A missing CLI degrades to persist-with-warning; not-found/auth failure is a hard error.",
                },
            },
            .required = &.{},
        },
        .system_prompt = set_pull_request_tool_system_prompt,
    },
};

// ─── JSON payloads ─────────────────────────────────────────────────────

const sanitize = @import("helpers").sanitize_control_chars;

/// Success payload for attach. `number` is null for generic.
/// `warning` is null when verification was clean. `base`/`head` echo
/// generic-mode refs for reference; null when empty.
pub fn successSetToJSON(
    allocator: std.mem.Allocator,
    session_id: []const u8,
    url: []const u8,
    provider: PrProvider,
    number: ?[]const u8,
    verified: bool,
    warning: ?[]const u8,
    base: []const u8,
    head: []const u8,
) ![]u8 {
    const clean_session = try sanitize(allocator, session_id);
    defer allocator.free(clean_session);
    const clean_url = try sanitize(allocator, url);
    defer allocator.free(clean_url);
    const clean_warning: ?[]u8 = if (warning) |w| try sanitize(allocator, w) else null;
    defer if (clean_warning) |w| allocator.free(w);
    return std.json.Stringify.valueAlloc(allocator, .{
        .session_id = clean_session,
        .attached = true,
        .url = clean_url,
        .provider = provider.toString(),
        .number = number,
        .verified = verified,
        .warning = clean_warning,
        .base = if (base.len > 0) @as(?[]const u8, base) else null,
        .head = if (head.len > 0) @as(?[]const u8, head) else null,
    }, .{});
}

pub fn successClearToJSON(allocator: std.mem.Allocator, session_id: []const u8) ![]u8 {
    const clean_session = try sanitize(allocator, session_id);
    defer allocator.free(clean_session);
    return std.json.Stringify.valueAlloc(allocator, .{
        .session_id = clean_session,
        .cleared = true,
    }, .{});
}

pub fn jsonError(allocator: std.mem.Allocator, msg: []const u8) ![]u8 {
    const clean = try sanitize(allocator, msg);
    defer allocator.free(clean);
    return std.json.Stringify.valueAlloc(allocator, .{ .@"error" = clean }, .{});
}

// ─── Validators (pure, no IO) ────────────────────────────────────────────

/// Validate the raw pr_url. Returns null on success, error text otherwise.
pub fn validatePrUrl(url: []const u8) ?[]const u8 {
    if (url.len == 0) return "pr_url cannot be empty";
    if (url.len > 2048) return "pr_url exceeds 2048 characters";
    if (std.mem.indexOfScalar(u8, url, 0) != null) return "pr_url contains null byte";
    const trimmed = std.mem.trim(u8, url, " \t\r\n");
    if (std.mem.indexOf(u8, trimmed, "://") == null) return "pr_url must be an absolute URL (missing scheme)";
    if (!(std.mem.startsWith(u8, trimmed, "http://") or std.mem.startsWith(u8, trimmed, "https://"))) return "pr_url must use http(s)";
    return null;
}

/// Validate the provider override ("" = auto-detect).
pub fn validateProviderOverride(provider: []const u8) ?[]const u8 {
    if (provider.len == 0) return null;
    if (PrProvider.fromString(provider) == null) return "provider must be \"github\", \"gitlab\", or \"generic\"";
    return null;
}

// ─── Verify (IO: provider CLI) ───────────────────────────────────────────

pub const VerifyOutcome = enum { verified, cli_missing, failed };

/// Confirm the PR exists via the provider CLI. `generic` has no CLI — always
/// `cli_missing` (persist with a "not verified" warning).
pub fn verifyPr(
    allocator: std.mem.Allocator,
    io: std.Io,
    provider: PrProvider,
    url: []const u8,
) !struct { outcome: VerifyOutcome, detail: []const u8 } {
    const argv: []const []const u8 = switch (provider) {
        .github => &.{ "gh", "pr", "view", url, "--json", "number,url" },
        .gitlab => &.{ "glab", "mr", "view", url },
        .generic => return .{ .outcome = .cli_missing, .detail = "" },
    };
    const res = std.process.run(allocator, io, .{ .argv = argv }) catch |err| {
        // Spawn failure = CLI not installed (or not on PATH).
        if (err == error.FileNotFound) return .{ .outcome = .cli_missing, .detail = "" };
        const d = try std.fmt.allocPrint(allocator, "verify spawn failed: {s}", .{@errorName(err)});
        return .{ .outcome = .failed, .detail = d };
    };
    defer {
        allocator.free(res.stdout);
        allocator.free(res.stderr);
    }
    if (res.term.exited == 0) return .{ .outcome = .verified, .detail = "" };
    const err_text = std.mem.trim(u8, res.stderr, " \t\r\n");
    const cap = @min(err_text.len, 512);
    const d = try allocator.dupe(u8, err_text[0..cap]);
    return .{ .outcome = .failed, .detail = d };
}

// ─── Execute ─────────────────────────────────────────────────────────────

/// Attach (or clear) the session's PR binding. Returns the inner
/// pull_request JSON string (owned). The exec wrapper persists
/// `url` + `provider` to the session on success.
pub fn executeSetPullRequestToJSON(
    allocator: std.mem.Allocator,
    io: std.Io,
    session_id: []const u8,
    input: SetPullRequestInput,
) ![]u8 {
    if (input.clear) {
        return try successClearToJSON(allocator, session_id);
    }
    if (validatePrUrl(input.pr_url)) |err| return try jsonError(allocator, err);
    if (validateProviderOverride(input.provider)) |err| return try jsonError(allocator, err);

    const normalized = try pr_provider.normalizePrUrl(allocator, input.pr_url);
    defer allocator.free(normalized);

    const provider: PrProvider = if (input.provider.len > 0)
        PrProvider.fromString(input.provider).?
    else
        pr_provider.detectProvider(normalized);

    var number: ?[]const u8 = null;
    if (provider != .generic) {
        const ref = pr_provider.parsePrRef(normalized, provider) orelse {
            const msg = try std.fmt.allocPrint(allocator, "pr_url does not look like a {s} pull/merge-request URL: {s}", .{ provider.toString(), normalized });
            defer allocator.free(msg);
            return try jsonError(allocator, msg);
        };
        number = ref.number;
    }

    var verified = false;
    var warning: ?[]const u8 = null;
    defer if (warning) |w| allocator.free(w);
    if (input.verify) {
        const v = try verifyPr(allocator, io, provider, normalized);
        switch (v.outcome) {
            .verified => verified = true,
            .cli_missing => {
                const cli = if (provider == .github) "gh" else "glab";
                warning = try std.fmt.allocPrint(allocator, "{s} CLI not found: PR persisted without verification (panel will report fetch errors)", .{cli});
            },
            .failed => {
                defer allocator.free(v.detail);
                const msg = try std.fmt.allocPrint(allocator, "PR verification failed: {s}", .{v.detail});
                defer allocator.free(msg);
                return try jsonError(allocator, msg);
            },
        }
    }

    return try successSetToJSON(allocator, session_id, normalized, provider, number, verified, warning, input.base, input.head);
}

// ─── Tests ───────────────────────────────────────────────────────────────

test "set_pull_request tool definition has correct name" {
    try std.testing.expectEqualStrings("set_pull_request", set_pull_request_tool.function.name);
}

test "validatePrUrl rejects empty, non-url, non-http" {
    try std.testing.expect(validatePrUrl("") != null);
    try std.testing.expect(validatePrUrl("not a url") != null);
    try std.testing.expect(validatePrUrl("ftp://host/x") != null);
    try std.testing.expect(validatePrUrl("https://github.com/a/b/pull/1") == null);
}

test "validateProviderOverride accepts empty + known, rejects unknown" {
    try std.testing.expect(validateProviderOverride("") == null);
    try std.testing.expect(validateProviderOverride("github") == null);
    try std.testing.expect(validateProviderOverride("gitlab") == null);
    try std.testing.expect(validateProviderOverride("generic") == null);
    try std.testing.expect(validateProviderOverride("bitbucket") != null);
}

fn parseTestJson(alloc: std.mem.Allocator, out: []const u8) !std.json.Parsed(std.json.Value) {
    return std.json.parseFromSlice(std.json.Value, alloc, out, .{});
}

test "execute clear returns cleared payload" {
    const alloc = std.testing.allocator;
    var threaded = std.Io.Threaded.init(alloc, .{});
    defer threaded.deinit();
    const io = threaded.io();
    const out = try executeSetPullRequestToJSON(alloc, io, "s1", .{ .clear = true });
    defer alloc.free(out);
    const parsed = try parseTestJson(alloc, out);
    defer parsed.deinit();
    const obj = parsed.value.object;
    try std.testing.expect(obj.get("cleared").?.bool);
    try std.testing.expectEqualStrings("s1", obj.get("session_id").?.string);
}

test "execute invalid url returns error payload" {
    const alloc = std.testing.allocator;
    var threaded = std.Io.Threaded.init(alloc, .{});
    defer threaded.deinit();
    const io = threaded.io();
    const out = try executeSetPullRequestToJSON(alloc, io, "s1", .{ .pr_url = "nope", .verify = false });
    defer alloc.free(out);
    const parsed = try parseTestJson(alloc, out);
    defer parsed.deinit();
    try std.testing.expect(parsed.value.object.get("error").? == .string);
}

test "execute github url without verify returns attach payload" {
    const alloc = std.testing.allocator;
    var threaded = std.Io.Threaded.init(alloc, .{});
    defer threaded.deinit();
    const io = threaded.io();
    const out = try executeSetPullRequestToJSON(alloc, io, "s9", .{ .pr_url = "https://github.com/acme/app/pull/42/files", .verify = false });
    defer alloc.free(out);
    const parsed = try parseTestJson(alloc, out);
    defer parsed.deinit();
    const obj = parsed.value.object;
    try std.testing.expect(obj.get("attached").?.bool);
    try std.testing.expectEqualStrings("https://github.com/acme/app/pull/42", obj.get("url").?.string);
    try std.testing.expectEqualStrings("github", obj.get("provider").?.string);
    try std.testing.expectEqualStrings("42", obj.get("number").?.string);
}

test "execute generic url without verify returns attach payload with null number" {
    const alloc = std.testing.allocator;
    var threaded = std.Io.Threaded.init(alloc, .{});
    defer threaded.deinit();
    const io = threaded.io();
    const out = try executeSetPullRequestToJSON(alloc, io, "s1", .{ .pr_url = "https://git.corp.example.com/a/b/changes/9", .verify = false });
    defer alloc.free(out);
    const parsed = try parseTestJson(alloc, out);
    defer parsed.deinit();
    const obj = parsed.value.object;
    try std.testing.expectEqualStrings("generic", obj.get("provider").?.string);
    try std.testing.expect(obj.get("number").? == .null);
}

// Exec adapter — merged from `set_pull_request.zig` (2026-10-14, task_1791993404141_2).
// The tool definition above and its executor below live in ONE file.

const pabrikcore = @import("pabrikcore");
const tools = @import("../../../agentic_loop/tools.zig");
const ToolExecContext = tools.ToolExecContext;
const ToolExecResult = tools.ToolExecResult;
const agent = pabrikcore.agent;
const llm_history = pabrikcore.llm_history;
const wrapToolOutput = tools.wrapToolOutput;
const error_explain = @import("../../../agentic_loop/tools_error_explain.zig");
fn payloadString(inner_parsed: ?std.json.Parsed(std.json.Value), field: []const u8) ?[]const u8 {
    const p = inner_parsed orelse return null;
    if (p.value != .object) return null;
    const v = p.value.object.get(field) orelse return null;
    if (v != .string) return null;
    if (v.string.len == 0) return null;
    return v.string;
}

pub fn execSetPullRequest(ctx: ToolExecContext, tc: agent.ToolCall) !ToolExecResult {
    const parsed = std.json.parseFromSlice(
        SetPullRequestInput,
        ctx.allocator,
        tc.function.arguments,
        .{ .allocate = .alloc_always, .ignore_unknown_fields = true },
    ) catch |err| {
        const err_msg = try error_explain.explain(ctx.allocator, err, null);
        defer ctx.allocator.free(err_msg);
        const output = try wrapToolOutput(ctx.allocator, "set_pull_request", tc.function.arguments, false, err_msg, "");
        return ToolExecResult{ .output = output, .output_allocated = true };
    };
    defer parsed.deinit();

    const inner = executeSetPullRequestToJSON(
        ctx.allocator,
        ctx.io,
        ctx.session_id,
        parsed.value,
    ) catch |err| {
        const err_msg = try error_explain.explain(ctx.allocator, err, null);
        defer ctx.allocator.free(err_msg);
        const output = try wrapToolOutput(ctx.allocator, "set_pull_request", tc.function.arguments, false, err_msg, "");
        return ToolExecResult{ .output = output, .output_allocated = true };
    };

    var inner_parsed: ?std.json.Parsed(std.json.Value) = std.json.parseFromSlice(std.json.Value, ctx.allocator, inner, .{}) catch null;
    defer if (inner_parsed) |*p| p.deinit();

    if (payloadString(inner_parsed, "error")) |err_msg| {
        const output = try wrapToolOutput(ctx.allocator, "set_pull_request", tc.function.arguments, false, err_msg, inner);
        return ToolExecResult{ .output = output, .output_allocated = true };
    }

    // SUCCESS: persist the attached PR binding so the session (and its right
    // panel) remembers it across tool calls.
    if (parsed.value.clear) {
        llm_history.updateSessionPrUrl(ctx.allocator, ctx.db, ctx.session_id, null, null) catch |err| {
            ctx.logger.errFmt("set_pull_request: failed to clear pr_url: {s}", .{@errorName(err)});
        };
    } else {
        const url = payloadString(inner_parsed, "url");
        const provider = payloadString(inner_parsed, "provider");
        llm_history.updateSessionPrUrl(ctx.allocator, ctx.db, ctx.session_id, url, provider) catch |err| {
            ctx.logger.errFmt("set_pull_request: failed to persist pr_url: {s}", .{@errorName(err)});
        };
    }

    const output = try wrapToolOutput(ctx.allocator, "set_pull_request", tc.function.arguments, true, null, inner);
    return ToolExecResult{ .output = output, .output_allocated = true };
}

