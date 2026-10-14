const std = @import("std");
const schemas = @import("schemas.zig");
const ToolProperty = schemas.ToolProperty;
const ToolParameters = schemas.ToolParameters;
const AgentToolFunction = schemas.AgentToolFunction;
const AgentTool = schemas.AgentTool;
const pr_provider = @import("pr_provider.zig");
const PrProvider = pr_provider.PrProvider;
const pr_cli = @import("pr_cli.zig");
const run_captured = @import("helpers").run_captured;

/// Input structure for status_pull_request tool (read-only: reports the
/// state of a pull/merge request via the forge CLI; it never creates,
/// mutates, or (un)binds anything).
pub const StatusPullRequestInput = struct {
    /// Which PR/MR to report on.
    pr_url: []const u8 = "",
    /// Optional provider override: "github" | "gitlab" | "generic". Empty
    /// (the default) = auto-detect from the URL, falling back to the session
    /// binding's provider and then the worktree's origin remote.
    provider: []const u8 = "",
    /// The session_id whose PR binding is the default target. The LLM
    /// does NOT supply this — the exec wrapper injects `ctx.session_id`
    /// at call time.
    session_id: []const u8 = "",
};

pub const status_pull_request_tool_system_prompt =
    \\\\## Status Pull Request Tool — Behavior (MANDATORY when applicable)
    \\\\When the human asks for the state of the session's pull request /
    \\\\merge request (is it open, merged, mergeable, what are the checks),
    \\\\call `status_pull_request` with no arguments: it defaults to the
    \\\\session's bound PR (stored by `set_pull_request`) looked up from the
    \\\\session's worktree (bound by `set_git_worktree`). This tool is
    \\\\read-only — it never creates, mutates, or (un)binds a PR.
    \\\\
    \\\\- Pass `pr_url` only to inspect a DIFFERENT PR/MR than the bound one
    \\\\  (a full URL, a number/IID, or a branch name).
    \\\\- Leave `provider` empty unless the forge is self-hosted and
    \\\\  auto-detection could misroute (same rule as `set_pull_request`).
    \\\\- A `generic`-provider PR has no forge CLI, so status is unavailable
    \\\\  for it — the tool says so explicitly instead of guessing.
    \\\\
;

pub const status_pull_request_tool = AgentTool{
    .type = "function",
    .function = .{
        .name = "status_pull_request",
        .description =
        \\Report the live status of a pull/merge request via the forge CLI (gh for GitHub, glab for GitLab). Defaults to the session's bound PR (set_pull_request) looked up from the session's worktree (set_git_worktree), so call it with no arguments for the common case. Read-only: never creates, mutates, or (un)binds anything. Generic-provider forges have no CLI, so status is unavailable for them.
        ,
        .parameters = .{
            .type = "object",
            .properties = &.{
                .{
                    .name = "pr_url",
                    .type = "string",
                    .description = "Which PR/MR to report on: a full URL, a number/IID (e.g. \"42\"), or a branch name. Empty = the session's bound PR (set_pull_request).",
                },
                .{
                    .name = "provider",
                    .type = "string",
                    .description = "Optional override: \"github\", \"gitlab\", or \"generic\". Empty = auto-detect from the URL, then the session binding, then the worktree's origin remote.",
                },
            },
            .required = &.{},
        },
        .system_prompt = status_pull_request_tool_system_prompt,
    },
};

// ─── JSON payloads ─────────────────────────────────────────────────────

const sanitize = @import("helpers").sanitize_control_chars;

/// Success payload. Mirrors the HTTP `GitPrStatusResponse` wire shape so
/// the agent and the frontend panel read the same vocabulary.
pub fn statusToJSON(
    allocator: std.mem.Allocator,
    url: []const u8,
    provider: PrProvider,
    number: i64,
    title: []const u8,
    state: []const u8,
    status: []const u8,
    mergeable: []const u8,
    merge_state: []const u8,
    head_ref: []const u8,
    base_ref: []const u8,
    author: []const u8,
    additions: i64,
    deletions: i64,
    changed_files: i64,
    created_at: []const u8,
    updated_at: []const u8,
) ![]u8 {
    const clean_url = try sanitize(allocator, url);
    defer allocator.free(clean_url);
    const clean_title = try sanitize(allocator, title);
    defer allocator.free(clean_title);
    const clean_state = try sanitize(allocator, state);
    defer allocator.free(clean_state);
    const clean_status = try sanitize(allocator, status);
    defer allocator.free(clean_status);
    const clean_mergeable = try sanitize(allocator, mergeable);
    defer allocator.free(clean_mergeable);
    const clean_merge_state = try sanitize(allocator, merge_state);
    defer allocator.free(clean_merge_state);
    const clean_head = try sanitize(allocator, head_ref);
    defer allocator.free(clean_head);
    const clean_base = try sanitize(allocator, base_ref);
    defer allocator.free(clean_base);
    const clean_author = try sanitize(allocator, author);
    defer allocator.free(clean_author);
    const clean_created = try sanitize(allocator, created_at);
    defer allocator.free(clean_created);
    const clean_updated = try sanitize(allocator, updated_at);
    defer allocator.free(clean_updated);
    return std.json.Stringify.valueAlloc(allocator, .{
        .url = clean_url,
        .provider = provider.toString(),
        .number = number,
        .title = clean_title,
        .state = clean_state,
        .status = clean_status,
        .mergeable = clean_mergeable,
        .merge_state = clean_merge_state,
        .head_ref = clean_head,
        .base_ref = clean_base,
        .author = clean_author,
        .additions = additions,
        .deletions = deletions,
        .changed_files = changed_files,
        .created_at = clean_created,
        .updated_at = clean_updated,
    }, .{});
}

pub fn jsonError(allocator: std.mem.Allocator, msg: []const u8) ![]u8 {
    const clean = try sanitize(allocator, msg);
    defer allocator.free(clean);
    return std.json.Stringify.valueAlloc(allocator, .{ .@"error" = clean }, .{});
}

// ─── Validators (pure, no IO) ────────────────────────────────────────────

/// Validate the provider override ("" = auto-detect).
pub fn validateProviderOverride(provider: []const u8) ?[]const u8 {
    if (provider.len == 0) return null;
    if (PrProvider.fromString(provider) == null) return "provider must be \"github\", \"gitlab\", or \"generic\"";
    return null;
}

// ─── Status normalization (pure, no IO) ─────────────────────────────────

/// Normalize a forge state to the lowercase status the panel switches on.
/// GitHub says OPEN/CLOSED/MERGED; GitLab says opened/closed/merged/ locked.
pub fn normalizeStatusAlloc(allocator: std.mem.Allocator, state: []const u8) ![]u8 {
    if (std.ascii.eqlIgnoreCase(state, "OPEN") or std.ascii.eqlIgnoreCase(state, "OPENED")) return allocator.dupe(u8, "open");
    if (std.ascii.eqlIgnoreCase(state, "CLOSED")) return allocator.dupe(u8, "closed");
    if (std.ascii.eqlIgnoreCase(state, "MERGED")) return allocator.dupe(u8, "merged");
    if (std.ascii.eqlIgnoreCase(state, "LOCKED")) return allocator.dupe(u8, "locked");
    const out = try allocator.dupe(u8, state);
    for (out) |*c| c.* = std.ascii.toLower(c.*);
    return out;
}

// ─── Forge output shapes (pure parsing, no IO) ───────────────────────────

/// Raw shape of `gh pr view --json ...` output. All fields optional with
/// defaults so a future `gh` version adding/removing a key does not break
/// parsing.
const GhPrView = struct {
    number: i64 = 0,
    title: []const u8 = "",
    url: []const u8 = "",
    state: []const u8 = "",
    mergeable: []const u8 = "",
    mergeStateStatus: []const u8 = "",
    headRefName: []const u8 = "",
    baseRefName: []const u8 = "",
    createdAt: []const u8 = "",
    updatedAt: []const u8 = "",
    mergedAt: ?[]const u8 = null,
    closedAt: ?[]const u8 = null,
    author: struct {
        login: []const u8 = "",
    } = .{},
    additions: i64 = 0,
    deletions: i64 = 0,
    changedFiles: i64 = 0,
};

/// Build the success JSON from `gh pr view --json` stdout.
pub fn parseGithubStatus(allocator: std.mem.Allocator, provider: PrProvider, raw: []const u8) ![]u8 {
    const trimmed = std.mem.trim(u8, raw, " \n\r");
    // parseFromSliceLeaky borrows string slices from `trimmed`, which the
    // caller owns — but statusToJSON sanitizes (dupes) every string, so no
    // lifetime escapes this call.
    const leaked: GhPrView = std.json.parseFromSliceLeaky(GhPrView, allocator, trimmed, .{ .ignore_unknown_fields = true }) catch {
        return try jsonError(allocator, "could not parse the GitHub CLI response (unexpected gh output shape)");
    };
    const status = try normalizeStatusAlloc(allocator, leaked.state);
    defer allocator.free(status);
    return try statusToJSON(
        allocator,
        leaked.url,
        provider,
        leaked.number,
        leaked.title,
        leaked.state,
        status,
        leaked.mergeable,
        leaked.mergeStateStatus,
        leaked.headRefName,
        leaked.baseRefName,
        leaked.author.login,
        leaked.additions,
        leaked.deletions,
        leaked.changedFiles,
        leaked.createdAt,
        leaked.updatedAt,
    );
}

/// Raw shape of `glab mr view --output json` output.
const GlabMrView = struct {
    iid: i64 = 0,
    id: i64 = 0,
    title: []const u8 = "",
    web_url: []const u8 = "",
    url: []const u8 = "",
    state: []const u8 = "",
    source_branch: []const u8 = "",
    target_branch: []const u8 = "",
    detailed_merge_status: []const u8 = "",
    merge_status: []const u8 = "",
    created_at: []const u8 = "",
    updated_at: []const u8 = "",
    merged_at: ?[]const u8 = null,
    closed_at: ?[]const u8 = null,
    author: std.json.Value = .null,
    additions: std.json.Value = .null,
    deletions: std.json.Value = .null,
    changes_count: std.json.Value = .null,
};

fn firstNonEmpty(candidates: []const []const u8) []const u8 {
    for (candidates) |c| if (c.len > 0) return c;
    return "";
}

fn jsonInt(v: std.json.Value) ?i64 {
    return switch (v) {
        .integer => |i| i,
        .float => |f| if (f >= 0) @intFromFloat(f) else null,
        .string => |s| std.fmt.parseInt(i64, std.mem.trim(u8, s, " \t"), 10) catch null,
        else => null,
    };
}

fn glabAuthorName(v: std.json.Value) []const u8 {
    return switch (v) {
        .string => |s| s,
        .object => |o| blk: {
            if (o.get("username")) |u| {
                if (u == .string and u.string.len > 0) break :blk u.string;
            }
            if (o.get("name")) |n| {
                if (n == .string) break :blk n.string;
            }
            break :blk "";
        },
        else => "",
    };
}

/// Build the success JSON from `glab mr view --output json` stdout.
pub fn parseGitlabStatus(allocator: std.mem.Allocator, provider: PrProvider, raw: []const u8) ![]u8 {
    const trimmed = std.mem.trim(u8, raw, " \n\r");
    var parsed = std.json.parseFromSlice(GlabMrView, allocator, trimmed, .{ .ignore_unknown_fields = true }) catch {
        return try jsonError(allocator, "could not parse the GitLab CLI response (unexpected glab output shape)");
    };
    defer parsed.deinit();
    const mr = parsed.value;
    const url = firstNonEmpty(&.{ mr.web_url, mr.url });
    const detailed = mr.detailed_merge_status;
    const merge_status = mr.merge_status;
    const status = try normalizeStatusAlloc(allocator, mr.state);
    defer allocator.free(status);
    return try statusToJSON(
        allocator,
        url,
        provider,
        if (mr.iid != 0) mr.iid else mr.id,
        mr.title,
        mr.state,
        status,
        firstNonEmpty(&.{ detailed, merge_status }),
        firstNonEmpty(&.{ merge_status, detailed }),
        mr.source_branch,
        mr.target_branch,
        glabAuthorName(mr.author),
        jsonInt(mr.additions) orelse 0,
        jsonInt(mr.deletions) orelse 0,
        jsonInt(mr.changes_count) orelse 0,
        mr.created_at,
        mr.updated_at,
    );
}

// ─── CLI execution (IO) ───────────────────────────────────────────────────

pub const StatusError = error{ CliMissing, NoAssociatedPr, FetchFailed, NotARepository };

/// Max bytes of CLI stderr surfaced in the error payload. Forge failures
/// are usually one line (`HTTP 401: ...`), but auth hints can run a few
/// lines — 500 bytes keeps the real cause without dumping pages.
const MAX_FETCH_DETAIL: usize = 500;

/// Wall-clock budget for one PR/MR view invocation. The forge CLIs are
/// thin HTTP clients; anything slower is a hung network call or a
/// credential prompt nobody can answer.
const VIEW_TIMEOUT_MS: u32 = 20_000;

/// Per-stream capture cap. A `view` payload is a few hundred bytes;
/// anything past this is an error message we truncate anyway.
const VIEW_MAX_OUTPUT_BYTES: usize = 64 * 1024;

/// Whether a non-zero-exit stderr means "that PR/MR does not exist" rather
/// than "the lookup blew up".
fn isNotFoundStderr(stderr: []const u8, provider: PrProvider) bool {
    if (std.mem.indexOf(u8, stderr, "404") != null) return true;
    if (std.ascii.indexOfIgnoreCase(stderr, "not found") != null) return true;
    if (std.ascii.indexOfIgnoreCase(stderr, "could not find") != null) return true;
    if (std.ascii.indexOfIgnoreCase(stderr, "no open") != null) return true;
    return switch (provider) {
        .github => std.ascii.indexOfIgnoreCase(stderr, "no pull request") != null or
            std.ascii.indexOfIgnoreCase(stderr, "no pull requests found") != null,
        .gitlab => std.ascii.indexOfIgnoreCase(stderr, "no merge request") != null or
            std.ascii.indexOfIgnoreCase(stderr, "no merge requests found") != null or
            std.ascii.indexOfIgnoreCase(stderr, "no mr found") != null,
        .generic => false,
    };
}

/// Run the forge CLI's read-only view command in `worktree_path` and return
/// the raw stdout JSON (owned).
fn runStatusView(
    allocator: std.mem.Allocator,
    io: std.Io,
    provider: PrProvider,
    prog_override: ?[]const u8,
    worktree_path: []const u8,
    pr_arg: []const u8,
    fetch_detail: *?[]u8,
) StatusError![]u8 {
    const cli = pr_cli.cliFor(provider) orelse return error.FetchFailed;
    const prog = prog_override orelse cli.program;

    var argv_buf: [pr_cli.view_argv_max][]const u8 = undefined;
    const argv = pr_cli.viewArgv(&argv_buf, provider, prog, pr_arg) orelse return error.FetchFailed;

    var res = run_captured.run(allocator, io, argv, .{
        .cwd = worktree_path,
        .max_output_bytes = VIEW_MAX_OUTPUT_BYTES,
        .timeout_ms = VIEW_TIMEOUT_MS,
    }) catch |err| switch (err) {
        error.FileNotFound, error.AccessDenied, error.PermissionDenied, error.InvalidExe => return error.CliMissing,
        else => {
            const msg = std.fmt.allocPrint(allocator, "failed to run {s} {s} view ({s})", .{ cli.program, cli.noun, @errorName(err) }) catch "";
            defer if (msg.len > 0) allocator.free(msg);
            fetch_detail.* = allocator.dupe(u8, msg[0..@min(msg.len, MAX_FETCH_DETAIL)]) catch null;
            return error.FetchFailed;
        },
    };
    defer res.deinit(allocator);

    if (res.timed_out) {
        const msg = std.fmt.allocPrint(allocator, "{s} {s} view timed out after {d}s", .{ cli.program, cli.noun, VIEW_TIMEOUT_MS / 1000 }) catch "";
        defer if (msg.len > 0) allocator.free(msg);
        fetch_detail.* = allocator.dupe(u8, msg[0..@min(msg.len, MAX_FETCH_DETAIL)]) catch null;
        return error.FetchFailed;
    }

    switch (res.term) {
        .exited => |code| {
            if (code != 0) {
                const stderr_trimmed = std.mem.trim(u8, res.stderr, " \n\r");
                if (isNotFoundStderr(stderr_trimmed, provider)) return error.NoAssociatedPr;
                if (stderr_trimmed.len > 0) {
                    fetch_detail.* = allocator.dupe(u8, stderr_trimmed[0..@min(stderr_trimmed.len, MAX_FETCH_DETAIL)]) catch null;
                } else {
                    const msg = std.fmt.allocPrint(allocator, "{s} {s} view exited with code {d} (no stderr)", .{ cli.program, cli.noun, code }) catch "";
                    defer if (msg.len > 0) allocator.free(msg);
                    fetch_detail.* = allocator.dupe(u8, msg[0..@min(msg.len, MAX_FETCH_DETAIL)]) catch null;
                }
                return error.FetchFailed;
            }
        },
        else => {
            const msg = std.fmt.allocPrint(allocator, "{s} {s} view terminated by signal", .{ cli.program, cli.noun }) catch "";
            defer if (msg.len > 0) allocator.free(msg);
            fetch_detail.* = allocator.dupe(u8, msg[0..@min(msg.len, MAX_FETCH_DETAIL)]) catch null;
            return error.FetchFailed;
        },
    }
    return allocator.dupe(u8, res.stdout) catch return error.FetchFailed;
}

/// Report the live status of one PR/MR.
pub fn executeStatusPullRequestToJSON(
    allocator: std.mem.Allocator,
    io: std.Io,
    worktree_path: []const u8,
    pr_arg: []const u8,
    provider: PrProvider,
    prog_override: ?[]const u8,
) ![]u8 {
    if (provider == .generic) {
        return try jsonError(allocator, "the generic provider has no forge CLI, so PR/MR status cannot be resolved (diff base...head locally with git instead)");
    }
    if (worktree_path.len == 0) {
        return try jsonError(allocator, "no worktree path: bind one with set_git_worktree first");
    }

    // Normalize URL-shaped args (strip credentials + /files, /commits UI
    // suffixes) so a pasted browser URL works verbatim. Bare numbers /
    // IIDs / branch names pass through untouched.
    var owned_arg: ?[]u8 = null;
    defer if (owned_arg) |a| allocator.free(a);
    var effective_arg: []const u8 = pr_arg;
    if (pr_arg.len > 0 and std.mem.indexOf(u8, pr_arg, "://") != null) {
        owned_arg = pr_provider.normalizePrUrl(allocator, pr_arg) catch null;
        if (owned_arg) |a| effective_arg = a;
    }

    var fetch_detail: ?[]u8 = null;
    defer if (fetch_detail) |d| allocator.free(d);

    const raw = runStatusView(allocator, io, provider, prog_override, worktree_path, effective_arg, &fetch_detail) catch |err| {
        const cli = pr_cli.cliFor(provider).?;
        switch (err) {
            error.CliMissing => {
                const msg = try std.fmt.allocPrint(allocator, "{s} CLI not found: install {s} and authenticate ({s} auth login) to read {s} status", .{ cli.program, cli.program, cli.program, cli.label });
                defer allocator.free(msg);
                return try jsonError(allocator, msg);
            },
            error.NoAssociatedPr => {
                const msg = try std.fmt.allocPrint(allocator, "no {s} found for \"{s}\" (check the number/URL/branch and that the worktree is on the right branch)", .{ cli.label, effective_arg });
                defer allocator.free(msg);
                return try jsonError(allocator, msg);
            },
            error.FetchFailed, error.NotARepository => {
                if (fetch_detail) |d| {
                    const msg = try std.fmt.allocPrint(allocator, "{s} status lookup failed: {s}", .{ cli.short, d });
                    defer allocator.free(msg);
                    return try jsonError(allocator, msg);
                }
                const msg = try std.fmt.allocPrint(allocator, "{s} status lookup failed (check the worktree path, the PR reference, and {s} auth)", .{ cli.short, cli.program });
                defer allocator.free(msg);
                return try jsonError(allocator, msg);
            },
        }
    };
    defer allocator.free(raw);

    return switch (provider) {
        .github => try parseGithubStatus(allocator, provider, raw),
        .gitlab => try parseGitlabStatus(allocator, provider, raw),
        .generic => unreachable,
    };
}

// ─── Tests ───────────────────────────────────────────────────────────────

test "status_pull_request tool definition has correct name" {
    try std.testing.expectEqualStrings("status_pull_request", status_pull_request_tool.function.name);
}

test "status_pull_request validateProviderOverride accepts empty + known, rejects unknown" {
    try std.testing.expect(validateProviderOverride("") == null);
    try std.testing.expect(validateProviderOverride("github") == null);
    try std.testing.expect(validateProviderOverride("gitlab") == null);
    try std.testing.expect(validateProviderOverride("generic") == null);
    try std.testing.expect(validateProviderOverride("bitbucket") != null);
}

test "normalizeStatusAlloc maps both forges onto open/closed/merged/locked" {
    const alloc = std.testing.allocator;
    const cases = [_]struct { in: []const u8, out: []const u8 }{
        .{ .in = "OPEN", .out = "open" },
        .{ .in = "opened", .out = "open" },
        .{ .in = "CLOSED", .out = "closed" },
        .{ .in = "MERGED", .out = "merged" },
        .{ .in = "merged", .out = "merged" },
        .{ .in = "locked", .out = "locked" },
        .{ .in = "DRAFT", .out = "draft" },
    };
    for (cases) |c| {
        const got = try normalizeStatusAlloc(alloc, c.in);
        defer alloc.free(got);
        try std.testing.expectEqualStrings(c.out, got);
    }
}

fn parseTestJson(alloc: std.mem.Allocator, out: []const u8) !std.json.Parsed(std.json.Value) {
    return std.json.parseFromSlice(std.json.Value, alloc, out, .{});
}

test "parseGithubStatus maps a gh pr view payload onto the status shape" {
    const alloc = std.testing.allocator;
    const raw =
        \\{"number":42,"title":"Add thing","url":"https://github.com/acme/app/pull/42","state":"OPEN","mergeable":"MERGEABLE","mergeStateStatus":"CLEAN","headRefName":"feature-x","baseRefName":"main","createdAt":"2026-09-01T00:00:00Z","updatedAt":"2026-09-02T00:00:00Z","mergedAt":null,"closedAt":null,"author":{"login":"ginwa"},"additions":10,"deletions":2,"changedFiles":3}
    ;
    const out = try parseGithubStatus(alloc, .github, raw);
    defer alloc.free(out);
    const parsed = try parseTestJson(alloc, out);
    defer parsed.deinit();
    const obj = parsed.value.object;
    try std.testing.expectEqualStrings("https://github.com/acme/app/pull/42", obj.get("url").?.string);
    try std.testing.expectEqualStrings("github", obj.get("provider").?.string);
    try std.testing.expectEqual(@as(i64, 42), obj.get("number").?.integer);
    try std.testing.expectEqualStrings("OPEN", obj.get("state").?.string);
    try std.testing.expectEqualStrings("open", obj.get("status").?.string);
    try std.testing.expectEqualStrings("feature-x", obj.get("head_ref").?.string);
    try std.testing.expectEqualStrings("main", obj.get("base_ref").?.string);
    try std.testing.expectEqualStrings("ginwa", obj.get("author").?.string);
    try std.testing.expectEqual(@as(i64, 10), obj.get("additions").?.integer);
    try std.testing.expectEqual(@as(i64, 3), obj.get("changed_files").?.integer);
}

test "parseGithubStatus survives a merged PR with null timestamps" {
    const alloc = std.testing.allocator;
    const raw =
        \\{"number":7,"title":"Old","url":"https://github.com/acme/app/pull/7","state":"MERGED","mergeable":"UNKNOWN","mergeStateStatus":"UNKNOWN","headRefName":"b","baseRefName":"main","createdAt":"","updatedAt":"","mergedAt":"2026-09-03T00:00:00Z","closedAt":"2026-09-03T00:00:00Z","author":{"login":""},"additions":0,"deletions":0,"changedFiles":0}
    ;
    const out = try parseGithubStatus(alloc, .github, raw);
    defer alloc.free(out);
    const parsed = try parseTestJson(alloc, out);
    defer parsed.deinit();
    try std.testing.expectEqualStrings("merged", parsed.value.object.get("status").?.string);
}

test "parseGitlabStatus maps a glab mr view payload onto the status shape" {
    const alloc = std.testing.allocator;
    const raw =
        \\{"id":11463,"iid":7,"title":"Add GitLab support","web_url":"https://gitlab.com/g/s/r/-/merge_requests/7","state":"opened","source_branch":"feature-y","target_branch":"main","detailed_merge_status":"mergeable","merge_status":"can_be_merged","created_at":"2026-09-28T10:00:00.000Z","updated_at":"2026-09-29T11:30:00.000Z","merged_at":null,"closed_at":null,"author":{"username":"ginwa","name":"Ginwa"},"additions":12,"deletions":4,"changes_count":5}
    ;
    const out = try parseGitlabStatus(alloc, .gitlab, raw);
    defer alloc.free(out);
    const parsed = try parseTestJson(alloc, out);
    defer parsed.deinit();
    const obj = parsed.value.object;
    try std.testing.expectEqualStrings("https://gitlab.com/g/s/r/-/merge_requests/7", obj.get("url").?.string);
    try std.testing.expectEqualStrings("gitlab", obj.get("provider").?.string);
    try std.testing.expectEqual(@as(i64, 7), obj.get("number").?.integer);
    try std.testing.expectEqualStrings("opened", obj.get("state").?.string);
    try std.testing.expectEqualStrings("open", obj.get("status").?.string);
    try std.testing.expectEqualStrings("feature-y", obj.get("head_ref").?.string);
    try std.testing.expectEqualStrings("ginwa", obj.get("author").?.string);
    try std.testing.expectEqual(@as(i64, 5), obj.get("changed_files").?.integer);
}

test "parseGitlabStatus survives renames and string counters" {
    const alloc = std.testing.allocator;
    const raw =
        \\{"id":99,"title":"Renamed","url":"https://gitlab.com/g/r/-/merge_requests/99","state":"merged","source_branch":"b","target_branch":"main","merge_status":"can_be_merged","merged_at":"2026-09-29T00:00:00Z","author":"someone","additions":"10","deletions":"2","changes_count":"5"}
    ;
    const out = try parseGitlabStatus(alloc, .gitlab, raw);
    defer alloc.free(out);
    const parsed = try parseTestJson(alloc, out);
    defer parsed.deinit();
    const obj = parsed.value.object;
    try std.testing.expectEqual(@as(i64, 99), obj.get("number").?.integer);
    try std.testing.expectEqualStrings("merged", obj.get("status").?.string);
    try std.testing.expectEqualStrings("someone", obj.get("author").?.string);
    try std.testing.expectEqual(@as(i64, 10), obj.get("additions").?.integer);
}

test "execute generic provider answers without spawning a CLI" {
    const alloc = std.testing.allocator;
    var threaded = std.Io.Threaded.init(alloc, .{});
    defer threaded.deinit();
    const io = threaded.io();
    const out = try executeStatusPullRequestToJSON(alloc, io, "/tmp", "https://git.corp.example.com/a/b/changes/9", .generic, null);
    defer alloc.free(out);
    const parsed = try parseTestJson(alloc, out);
    defer parsed.deinit();
    const err_val = parsed.value.object.get("error") orelse return error.MissingError;
    try std.testing.expect(err_val == .string);
    try std.testing.expect(std.mem.indexOf(u8, err_val.string, "generic") != null);
}

test "execute empty worktree path answers without spawning a CLI" {
    const alloc = std.testing.allocator;
    var threaded = std.Io.Threaded.init(alloc, .{});
    defer threaded.deinit();
    const io = threaded.io();
    const out = try executeStatusPullRequestToJSON(alloc, io, "", "42", .github, null);
    defer alloc.free(out);
    const parsed = try parseTestJson(alloc, out);
    defer parsed.deinit();
    try std.testing.expect(parsed.value.object.get("error").? == .string);
}

test "execute missing CLI reports install guidance, not a stack trace" {
    const alloc = std.testing.allocator;
    var threaded = std.Io.Threaded.init(alloc, .{});
    defer threaded.deinit();
    const io = threaded.io();
    const out = try executeStatusPullRequestToJSON(alloc, io, "/tmp", "42", .github, "/nonexistent-binary-xyz-123");
    defer alloc.free(out);
    const parsed = try parseTestJson(alloc, out);
    defer parsed.deinit();
    const err_val = parsed.value.object.get("error") orelse return error.MissingError;
    try std.testing.expect(err_val == .string);
    try std.testing.expect(std.mem.indexOf(u8, err_val.string, "gh") != null);
}

// ─── Fixture-script run-path tests (POSIX only) ────────────────────────────
// These drive the REAL spawn path (runStatusView → fixture `gh`/`glab` →
// parse) so both forges are proven end to end without a CLI install, auth, or

const builtin_t = @import("builtin");

fn skipOnWindows() bool {
    return builtin_t.os.tag == .windows;
}

const Fixture = struct {
    tmp: std.testing.TmpDir,
    root: []u8,
    allocator: std.mem.Allocator,

    fn init(allocator: std.mem.Allocator) !Fixture {
        var tmp = std.testing.tmpDir(.{});
        errdefer tmp.cleanup();
        var buf: [std.fs.max_path_bytes]u8 = undefined;
        const root = try tmp.dir.realPath(std.testing.io, &buf);
        const owned = try allocator.dupe(u8, buf[0..root]);
        return .{ .tmp = tmp, .root = owned, .allocator = allocator };
    }

    fn deinit(self: *Fixture) void {
        self.tmp.cleanup();
        self.allocator.free(self.root);
    }

    fn writeExec(self: *Fixture, name: []const u8, script: []const u8) ![]u8 {
        try self.tmp.dir.writeFile(std.testing.io, .{
            .sub_path = name,
            .data = script,
        });
        if (builtin_t.os.tag != .windows) {
            try self.tmp.dir.setFilePermissions(std.testing.io, name, .executable_file, .{});
        }
        return std.fmt.allocPrint(self.allocator, "{s}/{s}", .{ self.root, name });
    }
};

fn scriptPrintingJson(allocator: std.mem.Allocator, payload: []const u8) ![]u8 {
    return std.fmt.allocPrint(allocator, "#!/bin/sh\nprintf '%s' '{s}'\n", .{payload});
}

fn scriptFailingWith(allocator: std.mem.Allocator, message: []const u8) ![]u8 {
    return std.fmt.allocPrint(allocator, "#!/bin/sh\nprintf '%s' '{s}' >&2\nexit 1\n", .{message});
}

const FIXTURE_OPEN_PR_JSON =
    \\{"number":584,"title":"SyncEngine Phase 2","url":"https://github.com/acme/app/pull/584","state":"OPEN","mergeable":"MERGEABLE","mergeStateStatus":"UNSTABLE","headRefName":"worktree/x","baseRefName":"main","createdAt":"2026-09-21T08:51:37Z","updatedAt":"2026-09-21T08:51:37Z","mergedAt":null,"closedAt":null,"author":{"login":"ginwa123"},"additions":286,"deletions":103,"changedFiles":4}
;

const FIXTURE_OPEN_MR_JSON =
    \\{"id":11463,"iid":7,"title":"Add GitLab support","web_url":"https://gitlab.com/acme/sub/app/-/merge_requests/7","state":"opened","source_branch":"worktree/gitlab-support","target_branch":"main","detailed_merge_status":"mergeable","merge_status":"can_be_merged","created_at":"2026-09-28T10:00:00.000Z","updated_at":"2026-09-29T11:30:00.000Z","merged_at":null,"closed_at":null,"author":{"username":"ginwa123","name":"Ginwa"},"additions":12,"deletions":4,"changes_count":"4"}
;

test "execute github run path reports open status through a fixture gh" {
    if (skipOnWindows()) return error.SkipZigTest;
    const alloc = std.testing.allocator;
    var threaded = std.Io.Threaded.init(alloc, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var fx = try Fixture.init(alloc);
    defer fx.deinit();
    const script = try scriptPrintingJson(alloc, FIXTURE_OPEN_PR_JSON);
    defer alloc.free(script);
    const prog = try fx.writeExec("gh", script);
    defer alloc.free(prog);

    const out = try executeStatusPullRequestToJSON(alloc, io, fx.root, "584", .github, prog);
    defer alloc.free(out);
    const parsed = try parseTestJson(alloc, out);
    defer parsed.deinit();
    const obj = parsed.value.object;
    try std.testing.expectEqualStrings("github", obj.get("provider").?.string);
    try std.testing.expectEqual(@as(i64, 584), obj.get("number").?.integer);
    try std.testing.expectEqualStrings("open", obj.get("status").?.string);
    try std.testing.expectEqualStrings("UNSTABLE", obj.get("merge_state").?.string);
    try std.testing.expectEqualStrings("worktree/x", obj.get("head_ref").?.string);
}

test "execute gitlab run path reports open status through a fixture glab" {
    if (skipOnWindows()) return error.SkipZigTest;
    const alloc = std.testing.allocator;
    var threaded = std.Io.Threaded.init(alloc, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var fx = try Fixture.init(alloc);
    defer fx.deinit();
    const script = try scriptPrintingJson(alloc, FIXTURE_OPEN_MR_JSON);
    defer alloc.free(script);
    const prog = try fx.writeExec("glab", script);
    defer alloc.free(prog);

    const out = try executeStatusPullRequestToJSON(alloc, io, fx.root, "https://gitlab.com/acme/sub/app/-/merge_requests/7", .gitlab, prog);
    defer alloc.free(out);
    const parsed = try parseTestJson(alloc, out);
    defer parsed.deinit();
    const obj = parsed.value.object;
    try std.testing.expectEqualStrings("gitlab", obj.get("provider").?.string);
    try std.testing.expectEqual(@as(i64, 7), obj.get("number").?.integer);
    try std.testing.expectEqualStrings("open", obj.get("status").?.string);
    try std.testing.expectEqualStrings("ginwa123", obj.get("author").?.string);
    try std.testing.expectEqual(@as(i64, 4), obj.get("changed_files").?.integer);
}

test "execute run path maps a not-found CLI stderr onto a no-pr error" {
    if (skipOnWindows()) return error.SkipZigTest;
    const alloc = std.testing.allocator;
    var threaded = std.Io.Threaded.init(alloc, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var fx = try Fixture.init(alloc);
    defer fx.deinit();
    const script = try scriptFailingWith(alloc, "no pull requests found for branch nope");
    defer alloc.free(script);
    const prog = try fx.writeExec("gh", script);
    defer alloc.free(prog);

    const out = try executeStatusPullRequestToJSON(alloc, io, fx.root, "nope", .github, prog);
    defer alloc.free(out);
    const parsed = try parseTestJson(alloc, out);
    defer parsed.deinit();
    const err_val = parsed.value.object.get("error") orelse return error.MissingError;
    try std.testing.expect(err_val == .string);
    try std.testing.expect(std.mem.indexOf(u8, err_val.string, "no pull request found") != null);
}

test "execute run path surfaces an auth-failure stderr instead of not-found" {
    if (skipOnWindows()) return error.SkipZigTest;
    const alloc = std.testing.allocator;
    var threaded = std.Io.Threaded.init(alloc, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var fx = try Fixture.init(alloc);
    defer fx.deinit();
    const script = try scriptFailingWith(alloc, "HTTP 401: Bad credentials (https://api.github.com/...)");
    defer alloc.free(script);
    const prog = try fx.writeExec("gh", script);
    defer alloc.free(prog);

    const out = try executeStatusPullRequestToJSON(alloc, io, fx.root, "42", .github, prog);
    defer alloc.free(out);
    const parsed = try parseTestJson(alloc, out);
    defer parsed.deinit();
    const err_val = parsed.value.object.get("error") orelse return error.MissingError;
    try std.testing.expect(err_val == .string);
    try std.testing.expect(std.mem.indexOf(u8, err_val.string, "401") != null);
    try std.testing.expect(std.mem.indexOf(u8, err_val.string, "no pull request found") == null);
}
