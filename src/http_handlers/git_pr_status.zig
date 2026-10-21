const std = @import("std");
const http_response = @import("http_response.zig");
const pabrik_core = @import("pabrikcore");
const gserverz = pabrik_core.gserverz;
const pr_provider = pabrik_core.pr_provider;
const pr_cli = pabrik_core.pr_cli;
const run_captured = @import("helpers").run_captured;
const workspace_fs = @import("../agentic_loop/workspace_fs.zig");
const runtime_mode = @import("../runtime_mode.zig");

/// The guest git budget, matching the host spawns this module replaced.
const git_timeout_ms: u32 = 20_000;
const git_output_bytes: usize = 256 * 1024;

/// Which git may answer about `path`, decided by the process's own database in
/// `--saas` and by nothing at all in local mode.
fn routeForPath(allocator: std.mem.Allocator, path: []const u8) workspace_fs.Route {
    const di = pabrik_core.getSingleton() catch null;
    return workspace_fs.routeForPath(allocator, if (di) |d| d.db else null, path);
}

/// Is `path` a work tree? In `--saas` the question goes to the workspace's VM,
/// and a VM that cannot answer says no — never "let the host's git look".
fn isGitRepository(
    allocator: std.mem.Allocator,
    io: std.Io,
    route: *workspace_fs.Route,
    path: []const u8,
) bool {
    if (route.guestFs()) |fs| {
        const exec = fs.runGit(path, &.{ "rev-parse", "--git-dir" }, git_timeout_ms, git_output_bytes) catch return false;
        defer exec.deinit(allocator);
        return !exec.timed_out and exec.code == 0;
    }
    if (route.* == .unavailable) return false;
    const check = std.process.run(allocator, io, .{ .argv = &.{ "git", "-C", path, "rev-parse", "--git-dir" } }) catch return false;
    defer {
        allocator.free(check.stdout);
        allocator.free(check.stderr);
    }
    return check.term.exited == 0;
}

/// Whether `path` is a work tree the forge may be asked about. Public so the
/// conversation endpoint shares this endpoint's gate.
pub fn isWorkTree(allocator: std.mem.Allocator, io: std.Io, path: []const u8) bool {
    var route = routeForPath(allocator, path);
    defer route.deinit();
    return isGitRepository(allocator, io, &route, path);
}

/// `git remote get-url origin` in `path`, from whichever side may answer.
fn remoteOriginUrl(
    allocator: std.mem.Allocator,
    io: std.Io,
    route: *workspace_fs.Route,
    path: []const u8,
) ?[]u8 {
    if (route.guestFs()) |fs| {
        const exec = fs.runGit(path, &.{ "remote", "get-url", "origin" }, git_timeout_ms, git_output_bytes) catch return null;
        defer exec.deinit(allocator);
        if (exec.timed_out or exec.code != 0) return null;
        return dupeTrimmed(allocator, exec.stdout);
    }
    if (route.* == .unavailable) return null;
    const res = std.process.run(allocator, io, .{
        .argv = &.{ "git", "-C", path, "remote", "get-url", "origin" },
    }) catch return null;
    defer {
        allocator.free(res.stdout);
        allocator.free(res.stderr);
    }
    if (res.term.exited != 0) return null;
    return dupeTrimmed(allocator, res.stdout);
}

fn dupeTrimmed(allocator: std.mem.Allocator, raw: []const u8) ?[]u8 {
    const url = std.mem.trim(u8, raw, " \n\r");
    if (url.len == 0) return null;
    return allocator.dupe(u8, url) catch null;
}

/// Fields requested from `gh pr view --json`. The list itself now lives
/// in `pr_cli` so the argv builder and its parser cannot drift; re-exported
/// here because the inline tests below and the CLI docs name this symbol.
pub const GH_JSON_FIELDS = pr_cli.GH_JSON_FIELDS;

const PrStatusError = error{ NotARepository, CliMissing, NoAssociatedPr, FetchFailed };

/// Raw shape of `gh pr view --json ...` output.
const GhPrView = struct {
    number: i64 = 0,
    title: []const u8 = "",
    url: []const u8 = "",
    state: []const u8 = "",
    mergeable: []const u8 = "",
    mergeStateStatus: []const u8 = "",
    headRefName: []const u8 = "",
    baseRefName: []const u8 = "",
    /// The commit the head branch points at. This is the `--match-head-commit`
    /// guard's input; without it a merge could land on a commit the user
    /// never saw.
    headRefOid: []const u8 = "",
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
    /// APPROVED | CHANGES_REQUESTED | REVIEW_REQUIRED, or "" when the forge
    /// has no verdict to give.
    reviewDecision: []const u8 = "",
    /// The CI rollup, one entry per check. Counted into the summary below.
    statusCheckRollup: []const GhRollupEntry = &.{},
};

/// One entry of `statusCheckRollup`. GitHub mixes two shapes in it: a check
/// run (conclusion) and a commit status (state), so both are read.
const GhRollupEntry = struct {
    name: []const u8 = "",
    status: []const u8 = "",
    conclusion: []const u8 = "",
    state: []const u8 = "",
};

/// The bucket a rollup entry falls into, using the same vocabulary as the
/// checks endpoint: pass | fail | pending | skipping | cancel.
pub fn rollupBucket(entry: GhRollupEntry) []const u8 {
    const conclusion = entry.conclusion;
    if (conclusion.len > 0) {
        if (std.ascii.eqlIgnoreCase(conclusion, "SUCCESS")) return "pass";
        if (std.ascii.eqlIgnoreCase(conclusion, "FAILURE") or
            std.ascii.eqlIgnoreCase(conclusion, "TIMED_OUT") or
            std.ascii.eqlIgnoreCase(conclusion, "ACTION_REQUIRED") or
            std.ascii.eqlIgnoreCase(conclusion, "STARTUP_FAILURE") or
            std.ascii.eqlIgnoreCase(conclusion, "STALE")) return "fail";
        if (std.ascii.eqlIgnoreCase(conclusion, "CANCELLED")) return "cancel";
        if (std.ascii.eqlIgnoreCase(conclusion, "SKIPPED") or
            std.ascii.eqlIgnoreCase(conclusion, "NEUTRAL")) return "skipping";
    }
    if (entry.state.len > 0) {
        if (std.ascii.eqlIgnoreCase(entry.state, "SUCCESS")) return "pass";
        if (std.ascii.eqlIgnoreCase(entry.state, "FAILURE") or
            std.ascii.eqlIgnoreCase(entry.state, "ERROR")) return "fail";
        if (std.ascii.eqlIgnoreCase(entry.state, "PENDING") or
            std.ascii.eqlIgnoreCase(entry.state, "EXPECTED")) return "pending";
    }
    if (std.ascii.eqlIgnoreCase(entry.status, "COMPLETED")) return "pass";
    if (std.ascii.eqlIgnoreCase(entry.status, "IN_PROGRESS") or
        std.ascii.eqlIgnoreCase(entry.status, "QUEUED") or
        std.ascii.eqlIgnoreCase(entry.status, "PENDING") or
        std.ascii.eqlIgnoreCase(entry.status, "WAITING")) return "pending";
    return "skipping";
}

/// Normalize a forge state to the lowercase status the CLI prints. GitHub
/// says OPEN/CLOSED/MERGED; GitLab says `opened`/`closed`/ `merged`/`locked`.
pub fn normalizeStatus(state: []const u8) []const u8 {
    if (std.ascii.eqlIgnoreCase(state, "OPEN") or std.ascii.eqlIgnoreCase(state, "OPENED")) return "open";
    if (std.ascii.eqlIgnoreCase(state, "CLOSED")) return "closed";
    if (std.ascii.eqlIgnoreCase(state, "MERGED")) return "merged";
    // GitLab's `locked` is an MR nobody may act on until it is unlocked;
    // it is not open, so do not let it read as one.
    if (std.ascii.eqlIgnoreCase(state, "LOCKED")) return "locked";
    return state;
}

/// `setFetchDetail` for a formatted message.
pub fn setFetchDetailFmt(
    allocator: std.mem.Allocator,
    slot: *?[]u8,
    comptime fmt: []const u8,
    args: anytype,
) void {
    var buf: [256]u8 = undefined;
    const msg = std.fmt.bufPrint(&buf, fmt, args) catch "the forge CLI call failed";
    setFetchDetail(allocator, slot, msg);
}

/// Max bytes of `gh` stderr (or context) surfaced in the HTTP 502 `error`
/// field.
const MAX_FETCH_DETAIL: usize = 500;

/// Store a trimmed + capped copy of `msg` into `slot` (best-effort; leaves
/// `slot` null on empty input or alloc failure so callers can fall back to
/// the generic hint).
pub fn setFetchDetail(allocator: std.mem.Allocator, slot: *?[]u8, msg: []const u8) void {
    const trimmed = std.mem.trim(u8, msg, " \n\r\t");
    if (trimmed.len == 0) return;
    const take = @min(trimmed.len, MAX_FETCH_DETAIL);
    slot.* = allocator.dupe(u8, trimmed[0..take]) catch null;
}

/// The forge CLIs to spawn. Injectable through `useCaseWithPrograms` so
/// the test suite can point them at fixture scripts instead of requiring
/// real, authenticated GitHub/GitLab CLIs on PATH.
pub const Programs = struct {
    gh: []const u8 = "gh",
    glab: []const u8 = "glab",

    fn forProvider(self: Programs, provider: pr_provider.PrProvider) []const u8 {
        return switch (provider) {
            .github => self.gh,
            .gitlab => self.glab,
            .generic => "",
        };
    }
};

/// Back-compat alias for the old single-program constant. Kept because
/// the inline tests and the CLI docs name it.
pub const GH_PROGRAM: []const u8 = "gh";

/// The `glab` binary. Same seam as `GH_PROGRAM`, GitLab side.
pub const GLAB_PROGRAM: []const u8 = "glab";

/// Wall-clock budget for one PR/MR view invocation.
pub const GH_TIMEOUT_MS: u32 = 20_000;

/// Per-stream capture cap. A `pr view` payload is a few hundred bytes
/// without the CI rollup, and a few kilobytes with it; anything past this
/// is an error message we truncate anyway.
const GH_MAX_OUTPUT_BYTES: usize = 256 * 1024;

/// Run `gh pr view` in `path` and return the raw stdout JSON (owned).
/// `pr_arg` is "" for "current branch's PR", otherwise a number, URL, or
/// branch name passed straight through to `gh`.
fn runView(
    allocator: std.mem.Allocator,
    io: std.Io,
    provider: pr_provider.PrProvider,
    prog: []const u8,
    path: []const u8,
    pr_arg: []const u8,
    timeout_ms: u32,
    fetch_detail: *?[]u8,
) ![]u8 {
    // `<gh> pr view [<pr>] --json <fields>` for GitHub, `<glab> mr view
    // [<mr>] --output json` for GitLab.
    var argv_buf: [pr_cli.view_argv_max][]const u8 = undefined;
    const argv = pr_cli.viewArgv(&argv_buf, provider, prog, pr_arg) orelse return error.CliMissing;
    return runForgeView(allocator, io, provider, path, argv, timeout_ms, fetch_detail);
}

/// Spawn one forge read and return its stdout. `argv` is the caller's, so
/// every forge read shares one timeout, one capture cap and one stderr
/// policy.
pub fn runForgeView(
    allocator: std.mem.Allocator,
    io: std.Io,
    provider: pr_provider.PrProvider,
    path: []const u8,
    argv: []const []const u8,
    timeout_ms: u32,
    fetch_detail: *?[]u8,
) ![]u8 {
    const cli = pr_cli.cliFor(provider) orelse return error.CliMissing;
    var res = run_captured.run(allocator, io, argv, .{
        .cwd = path,
        .max_output_bytes = GH_MAX_OUTPUT_BYTES,
        .timeout_ms = timeout_ms,
    }) catch |err| switch (err) {
        // The CLI not being on PATH is the overwhelmingly common spawn
        // failure (the repo gate above already proved `path` is a git
        // repo, so a FileNotFound here is the binary, not the directory).
        error.FileNotFound => return error.CliMissing,
        error.AccessDenied, error.PermissionDenied, error.InvalidExe => return error.CliMissing,
        else => {
            var buf: [128]u8 = undefined;
            setFetchDetail(allocator, fetch_detail, std.fmt.bufPrint(&buf, "failed to run {s} {s} view ({s})", .{ cli.program, cli.noun, @errorName(err) }) catch "failed to run the forge CLI");
            return error.FetchFailed;
        },
    };
    defer res.deinit(allocator);

    if (res.timed_out) {
        var buf: [128]u8 = undefined;
        setFetchDetail(allocator, fetch_detail, std.fmt.bufPrint(&buf, "{s} {s} view timed out after {d}s", .{ cli.program, cli.noun, timeout_ms / 1000 }) catch "forge CLI view timed out");
        return error.FetchFailed;
    }

    switch (res.term) {
        .exited => |code| {
            if (code != 0) {
                const stderr_trimmed = std.mem.trim(u8, res.stderr, " \n\r");
                const is_no_pr = isNotFoundStderr(stderr_trimmed, provider);
                // Surface the real CLI stderr (auth failures, bad numbers,
                // rate limits) instead of a generic hint. `is_no_pr` stays a
                // 404; everything else becomes a 502 carrying this detail.
                if (!is_no_pr) {
                    if (stderr_trimmed.len > 0) {
                        setFetchDetail(allocator, fetch_detail, stderr_trimmed);
                    } else {
                        var code_buf: [96]u8 = undefined;
                        const code_msg = std.fmt.bufPrint(&code_buf, "{s} {s} view exited with code {d} (no stderr)", .{ cli.program, cli.noun, code }) catch "forge CLI view failed (no stderr)";
                        setFetchDetail(allocator, fetch_detail, code_msg);
                    }
                }
                if (is_no_pr) return error.NoAssociatedPr;
                return error.FetchFailed;
            }
        },
        else => {
            var buf: [96]u8 = undefined;
            setFetchDetail(allocator, fetch_detail, std.fmt.bufPrint(&buf, "{s} {s} view terminated by signal", .{ cli.program, cli.noun }) catch "forge CLI view terminated by signal");
            return error.FetchFailed;
        },
    }
    return allocator.dupe(u8, res.stdout);
}

/// Whether a non-zero-exit stderr means "that PR/MR does not exist" (404)
/// rather than "the lookup blew up" (502).
fn isNotFoundStderr(stderr: []const u8, provider: pr_provider.PrProvider) bool {
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

/// `runView` bound to GitHub. Kept so the ~12 behavioural tests that
/// already exercise the `gh` path (deadlock, timeout, signal, fd leak)
/// keep testing that exact code unchanged.
fn runGhPrView(
    allocator: std.mem.Allocator,
    io: std.Io,
    prog: []const u8,
    path: []const u8,
    pr_arg: []const u8,
    timeout_ms: u32,
    fetch_detail: *?[]u8,
) ![]u8 {
    return runView(allocator, io, .github, prog, path, pr_arg, timeout_ms, fetch_detail);
}

/// `runView` bound to GitLab. New tests for the `glab` path go here.
fn runGlabMrView(
    allocator: std.mem.Allocator,
    io: std.Io,
    prog: []const u8,
    path: []const u8,
    mr_arg: []const u8,
    timeout_ms: u32,
    fetch_detail: *?[]u8,
) ![]u8 {
    return runView(allocator, io, .gitlab, prog, path, mr_arg, timeout_ms, fetch_detail);
}

fn useCase(
    allocator: std.mem.Allocator,
    io: std.Io,
    path: []const u8,
    pr_arg: []const u8,
    provider_override: ?[]const u8,
    fetch_detail: *?[]u8,
) !http_response.GitPrStatusResponse {
    return useCaseWithPrograms(allocator, io, .{}, path, pr_arg, provider_override, fetch_detail);
}

/// `useCase` with a single program injected for BOTH forges.
fn useCaseWith(
    allocator: std.mem.Allocator,
    io: std.Io,
    prog: []const u8,
    path: []const u8,
    pr_arg: []const u8,
    provider_override: ?[]const u8,
    fetch_detail: *?[]u8,
) !http_response.GitPrStatusResponse {
    return useCaseWithPrograms(allocator, io, .{ .gh = prog, .glab = prog }, path, pr_arg, provider_override, fetch_detail);
}

/// `useCase` with both forge binaries injectable so the inline tests can
/// drive the whole path against fixture scripts instead of real,
/// authenticated GitHub/GitLab CLIs.
pub fn useCaseWithPrograms(
    allocator: std.mem.Allocator,
    io: std.Io,
    programs: Programs,
    path: []const u8,
    pr_arg: []const u8,
    provider_override: ?[]const u8,
    fetch_detail: *?[]u8,
) !http_response.GitPrStatusResponse {
    // 1) Must be a git repo. Under `--saas` only the workspace's VM may say
    // so: a path no workspace owns, or a VM that is not answering, is not a
    // repository rather than an invitation to the host's git.
    var route = routeForPath(allocator, path);
    defer route.deinit();
    if (!isGitRepository(allocator, io, &route, path)) return error.NotARepository;

    // 2) Resolve which forge to ask. Precedence, most explicit first:
    // explicit `provider` param > a URL-shaped `pr` arg > the repository's
    // own `origin` remote.
    const provider = resolveProviderVia(allocator, io, &route, path, pr_arg, provider_override) catch |err| {
        switch (err) {
            error.UnknownProvider => setFetchDetail(allocator, fetch_detail, "unknown provider (expected github, gitlab, or generic)"),
            error.UnsupportedProvider => setFetchDetail(allocator, fetch_detail, "the generic provider has no forge CLI, so PR/MR status cannot be resolved (pass provider=github or provider=gitlab)"),
            else => |e| return e,
        }
        return error.FetchFailed;
    };

    const raw = runView(allocator, io, provider, programs.forProvider(provider), path, pr_arg, GH_TIMEOUT_MS, fetch_detail) catch |err| {
        // runView already stored the CLI stderr in fetch_detail.
        return err;
    };
    defer allocator.free(raw);

    const cli = pr_cli.cliFor(provider).?;
    const trimmed = std.mem.trim(u8, raw, " \n\r");
    // parseFromSliceLeaky BORROWS string slices from `raw` (no dupes), so
    // every string must be duped into the request arena before `raw` is freed
    // — otherwise the handler serializes freed memory (0xAA garbage in debug
    return switch (provider) {
        .github => try buildResponse(allocator, provider, trimmed, raw.len, cli, fetch_detail),
        .gitlab => try buildGlabResponse(allocator, provider, trimmed, raw.len, cli, fetch_detail),
        .generic => unreachable, // resolveProvider rejects it above
    };
}

/// Which forge to ask, or the reason we cannot ask one. Resolves its own
/// route, so the callers that only want the provider are unchanged.
pub fn resolveProvider(
    allocator: std.mem.Allocator,
    io: std.Io,
    path: []const u8,
    pr_arg: []const u8,
    provider_override: ?[]const u8,
) !pr_provider.PrProvider {
    var route = routeForPath(allocator, path);
    defer route.deinit();
    return resolveProviderVia(allocator, io, &route, path, pr_arg, provider_override);
}

/// `resolveProvider` for a caller that already resolved the route.
pub fn resolveProviderVia(
    allocator: std.mem.Allocator,
    io: std.Io,
    route: *workspace_fs.Route,
    path: []const u8,
    pr_arg: []const u8,
    provider_override: ?[]const u8,
) !pr_provider.PrProvider {
    if (provider_override) |o| {
        if (o.len > 0) {
            const p = pr_provider.PrProvider.fromString(o) orelse return error.UnknownProvider;
            // `generic` is a real provider for DIFFING (pure local refs,
            // see git_pr_diff.zig) but it has no forge CLI to ask for
            // status, so a status request naming it is unanswerable.
            if (!pr_cli.hasCli(p)) return error.UnsupportedProvider;
            return p;
        }
    }
    if (pr_arg.len > 0 and std.mem.indexOf(u8, pr_arg, "://") != null) {
        if (pr_provider.normalizePrUrl(allocator, pr_arg) catch null) |normalized| {
            defer allocator.free(normalized);
            const detected = pr_provider.detectProvider(normalized);
            // A GitLab MR URL must NOT silently fall through to `gh`.
            if (detected != .generic) return detected;
        }
    }
    if (detectProviderFromOrigin(allocator, io, route, path)) |p| return p;
    // No forge we can name: default to GitHub, which is what this
    // endpoint did before GitLab support existed.
    return .github;
}

/// `git -C <path> remote get-url origin` → provider, or null when there
/// is no origin, no remote, or git cannot be asked.
fn detectProviderFromOrigin(
    allocator: std.mem.Allocator,
    io: std.Io,
    route: *workspace_fs.Route,
    path: []const u8,
) ?pr_provider.PrProvider {
    const url = remoteOriginUrl(allocator, io, route, path) orelse return null;
    defer allocator.free(url);
    const p = pr_provider.detectProviderFromRemote(url);
    if (p == .generic) return null;
    return p;
}

/// Best-effort provider, used ONLY to choose the wording of an error message
/// ("no merge request found" vs "no pull request found").
fn handlerProvider(
    allocator: std.mem.Allocator,
    io: std.Io,
    path: []const u8,
    pr_arg: []const u8,
    provider_override: ?[]const u8,
) ?pr_provider.PrProvider {
    var route = routeForPath(allocator, path);
    defer route.deinit();
    const p = resolveProviderVia(allocator, io, &route, path, pr_arg, provider_override) catch return null;
    if (!pr_cli.hasCli(p)) return null;
    return p;
}

/// The wording to use for an error message about this request.
fn handlerCli(
    allocator: std.mem.Allocator,
    io: std.Io,
    path: []const u8,
    pr_arg: []const u8,
    provider_override: ?[]const u8,
) pr_cli.Cli {
    const p = handlerProvider(allocator, io, path, pr_arg, provider_override) orelse return pr_cli.GH_CLI;
    return pr_cli.cliFor(p) orelse pr_cli.GH_CLI;
}

/// Build the wire response from `gh pr view --json` stdout.
fn buildResponse(
    allocator: std.mem.Allocator,
    provider: pr_provider.PrProvider,
    trimmed: []const u8,
    raw_len: usize,
    cli: pr_cli.Cli,
    fetch_detail: *?[]u8,
) !http_response.GitPrStatusResponse {
    const parsed = std.json.parseFromSliceLeaky(GhPrView, allocator, trimmed, .{ .ignore_unknown_fields = true }) catch {
        setParseDetail(allocator, fetch_detail, cli, raw_len);
        return error.FetchFailed;
    };
    return http_response.GitPrStatusResponse{
        .provider = try allocator.dupe(u8, provider.toString()),
        .pr_url = try allocator.dupe(u8, parsed.url),
        .number = parsed.number,
        .title = try allocator.dupe(u8, parsed.title),
        .state = try allocator.dupe(u8, parsed.state),
        .status = try allocator.dupe(u8, normalizeStatus(parsed.state)),
        .mergeable = try allocator.dupe(u8, parsed.mergeable),
        .merge_state = try allocator.dupe(u8, parsed.mergeStateStatus),
        .head_sha = try allocator.dupe(u8, parsed.headRefOid),
        .head_ref = try allocator.dupe(u8, parsed.headRefName),
        .base_ref = try allocator.dupe(u8, parsed.baseRefName),
        .author = try allocator.dupe(u8, parsed.author.login),
        .created_at = try allocator.dupe(u8, parsed.createdAt),
        .updated_at = try allocator.dupe(u8, parsed.updatedAt),
        .merged_at = try allocator.dupe(u8, parsed.mergedAt orelse ""),
        .closed_at = try allocator.dupe(u8, parsed.closedAt orelse ""),
        .additions = parsed.additions,
        .deletions = parsed.deletions,
        .changed_files = parsed.changedFiles,
        .review_decision = try allocator.dupe(u8, parsed.reviewDecision),
        .checks = countRollup(parsed.statusCheckRollup),
    };
}

/// Count a CI rollup into the summary the panel reads. The buckets are the
/// checks endpoint's vocabulary, so one chip means the same thing in both
/// places.
fn countRollup(entries: []const GhRollupEntry) http_response.GitPrChecksSummary {
    var summary: http_response.GitPrChecksSummary = .{};
    for (entries) |entry| {
        summary.total += 1;
        const bucket = rollupBucket(entry);
        if (std.ascii.eqlIgnoreCase(bucket, "pass")) {
            summary.passed += 1;
        } else if (std.ascii.eqlIgnoreCase(bucket, "fail")) {
            summary.failed += 1;
        } else if (std.ascii.eqlIgnoreCase(bucket, "pending")) {
            summary.pending += 1;
        } else if (std.ascii.eqlIgnoreCase(bucket, "cancel")) {
            summary.cancelled += 1;
        } else {
            summary.skipped += 1;
        }
    }
    return summary;
}

/// Build the wire response from `glab mr view --output json` stdout. ## Why
/// this parser is alias-tolerant while the `gh` one is not `gh pr view
/// --json` takes an explicit field list, so its output shape is pinned by the
const GlabMrView = struct {
    iid: i64 = 0,
    id: i64 = 0,
    title: []const u8 = "",
    web_url: []const u8 = "",
    url: []const u8 = "",
    state: []const u8 = "",
    source_branch: []const u8 = "",
    target_branch: []const u8 = "",
    /// The head commit. GitLab calls it `sha` (not `headRefOid`); it is
    /// what `glab mr merge --sha` guards on.
    sha: []const u8 = "",
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

/// Build the wire response from `glab mr view --output json` stdout.
fn buildGlabResponse(
    allocator: std.mem.Allocator,
    provider: pr_provider.PrProvider,
    trimmed: []const u8,
    raw_len: usize,
    cli: pr_cli.Cli,
    fetch_detail: *?[]u8,
) !http_response.GitPrStatusResponse {
    // `parseFromSlice`, deliberately NOT the Leaky variant used by
    // `buildResponse`: GlabMrView holds `std.json.Value` counters, and a
    // Value duplicates its string/object into a parser-owned arena.
    var parsed = std.json.parseFromSlice(GlabMrView, allocator, trimmed, .{ .ignore_unknown_fields = true }) catch {
        setParseDetail(allocator, fetch_detail, cli, raw_len);
        return error.FetchFailed;
    };
    defer parsed.deinit();
    const mr = parsed.value;

    const url = firstNonEmpty(&.{ mr.web_url, mr.url });
    // GitLab's merge_status vocabulary (can_be_merged / cannot_be_merged) and
    // detailed_merge_status vocabulary (mergeable / conflicted) are different
    // axes; `detailed_merge_status` is the closer analogue of `gh`'s
    const detailed = mr.detailed_merge_status;
    const merge_status = mr.merge_status;
    return http_response.GitPrStatusResponse{
        .provider = try allocator.dupe(u8, provider.toString()),
        .pr_url = try allocator.dupe(u8, url),
        .number = if (mr.iid != 0) mr.iid else mr.id,
        .title = try allocator.dupe(u8, mr.title),
        .state = try allocator.dupe(u8, mr.state),
        .status = try allocator.dupe(u8, normalizeStatus(mr.state)),
        .mergeable = try allocator.dupe(u8, firstNonEmpty(&.{ detailed, merge_status })),
        .merge_state = try allocator.dupe(u8, firstNonEmpty(&.{ merge_status, detailed })),
        .head_sha = try allocator.dupe(u8, mr.sha),
        .head_ref = try allocator.dupe(u8, mr.source_branch),
        .base_ref = try allocator.dupe(u8, mr.target_branch),
        .author = try allocator.dupe(u8, glabAuthorName(mr.author)),
        .created_at = try allocator.dupe(u8, mr.created_at),
        .updated_at = try allocator.dupe(u8, mr.updated_at),
        .merged_at = try allocator.dupe(u8, mr.merged_at orelse ""),
        .closed_at = try allocator.dupe(u8, mr.closed_at orelse ""),
        .additions = jsonInt(mr.additions) orelse 0,
        .deletions = jsonInt(mr.deletions) orelse 0,
        .changed_files = jsonInt(mr.changes_count) orelse 0,
    };
}

/// The first non-empty candidate, or "" — the alias-chain reader used
/// for fields glab has renamed between releases. Returns a slice
/// borrowing from one of `candidates`.
pub fn firstNonEmpty(candidates: []const []const u8) []const u8 {
    for (candidates) |c| if (c.len > 0) return c;
    return "";
}

/// Read a count glab may report as a number OR as a numeric string.
fn jsonInt(v: std.json.Value) ?i64 {
    return switch (v) {
        .integer => |i| i,
        .float => |f| if (f >= 0) @intFromFloat(f) else null,
        .string => |s| std.fmt.parseInt(i64, std.mem.trim(u8, s, " \t"), 10) catch null,
        else => null,
    };
}

/// The display name for a glab `author`, which is an object with
/// `username`/`name` — but which some glab versions render as a bare
/// string. Returns "" rather than guessing.
pub fn glabAuthorName(v: std.json.Value) []const u8 {
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

/// "invalid JSON from <prog> <noun> view (N bytes stdout)" — names the
/// CLI that actually produced it, because the overwhelmingly common
/// cause is a version whose JSON flag we did not pass.
fn setParseDetail(allocator: std.mem.Allocator, fetch_detail: *?[]u8, cli: pr_cli.Cli, raw_len: usize) void {
    var buf: [256]u8 = undefined;
    const msg = std.fmt.bufPrint(&buf, "invalid JSON from {s} {s} view ({d} bytes stdout)", .{ cli.program, cli.noun, raw_len }) catch "invalid JSON from the forge CLI";
    setFetchDetail(allocator, fetch_detail, msg);
}

/// GET
/// /api/git/pr/status?path=<repo>[&pr=<number|url|branch>][&provider=github]
/// Returns the PR's open/merged/closed status via `gh pr view`.
pub fn gitPrStatusHandler(ctx: gserverz.HttpContext, req: gserverz.HttpRequest, res: gserverz.HttpResponse) !gserverz.HttpResponse {
    const allocator = ctx.allocator;
    const io = ctx.io;

    const query = req.query;
    const path_param = query.get("path") orelse {
        return res.jsonResponse(.{ .status_code = 400, .data = try http_response.makeGitStatusErrorResponse(allocator, "Missing path parameter") });
    };
    if (path_param.len == 0) {
        return res.jsonResponse(.{ .status_code = 400, .data = try http_response.makeGitStatusErrorResponse(allocator, "path cannot be empty") });
    }
    const pr_param = query.get("pr") orelse "";
    const provider_param = query.get("provider");
    if (provider_param) |pv| {
        if (pv.len > 0 and pr_provider.PrProvider.fromString(pv) == null) {
            return res.jsonResponse(.{ .status_code = 400, .data = try http_response.makeGitStatusErrorResponse(allocator, "provider must be \"github\", \"gitlab\", or \"generic\"") });
        }
    }

    var fetch_detail: ?[]u8 = null;
    const result = useCase(allocator, io, path_param, pr_param, provider_param, &fetch_detail) catch |err| switch (err) {
        error.NotARepository => {
            return res.jsonResponse(.{ .status_code = 404, .data = try http_response.makeGitStatusErrorResponse(allocator, "not a git repository") });
        },
        error.CliMissing => {
            // Name the CLI the caller actually needs. The use case picks
            // the forge from the provider/URL/remote, so a GitLab repo
            // with no glab installed must not be told to install gh.
            const cli = handlerCli(allocator, io, path_param, pr_param, provider_param);
            const msg = try std.fmt.allocPrint(allocator, "{s} CLI not found on PATH (install {s} for {s} status)", .{ cli.program, cli.program, cli.forge });
            return res.jsonResponse(.{ .status_code = 422, .data = try http_response.makeGitStatusErrorResponse(allocator, msg) });
        },
        error.NoAssociatedPr => {
            const cli = handlerCli(allocator, io, path_param, pr_param, provider_param);
            const msg = if (pr_param.len > 0)
                try std.fmt.allocPrint(allocator, "no {s} found for '{s}'", .{ cli.label, pr_param })
            else
                try std.fmt.allocPrint(allocator, "no {s} found for the current branch", .{cli.label});
            return res.jsonResponse(.{ .status_code = 404, .data = try http_response.makeGitStatusErrorResponse(allocator, msg) });
        },
        error.FetchFailed => {
            // Surface the real CLI stderr (auth, bad number, rate limit) so
            // DevTools shows WHY it failed instead of the generic hint.
            const cli = handlerCli(allocator, io, path_param, pr_param, provider_param);
            const msg = if (fetch_detail) |d|
                try std.fmt.allocPrint(allocator, "failed to fetch {s} status: {s}", .{ cli.label, d })
            else
                try std.fmt.allocPrint(allocator, "failed to fetch {s} status (check number/URL, provider, and {s} auth)", .{ cli.label, cli.program });
            return res.jsonResponse(.{ .status_code = 502, .data = try http_response.makeGitStatusErrorResponse(allocator, msg) });
        },
        else => return err,
    };

    return res.jsonResponse(.{ .status_code = 200, .data = try http_response.makeGitPrStatusResponse(allocator, result) });
}

const testing = std.testing;

test "the CI rollup counts failures, passes and pending checks" {
    // The header chip and the merge box read this count, so the buckets have
    // to mean the same thing here as they do in the checks endpoint.
    const entries = [_]GhRollupEntry{
        .{ .name = "backend", .status = "COMPLETED", .conclusion = "FAILURE" },
        .{ .name = "lint", .status = "COMPLETED", .conclusion = "SUCCESS" },
        .{ .name = "docs", .status = "IN_PROGRESS" },
        .{ .name = "external", .state = "ERROR" },
        .{ .name = "old", .state = "SUCCESS" },
    };
    const summary = countRollup(&entries);
    try testing.expectEqual(@as(u32, 5), summary.total);
    try testing.expectEqual(@as(u32, 2), summary.failed);
    try testing.expectEqual(@as(u32, 2), summary.passed);
    try testing.expectEqual(@as(u32, 1), summary.pending);
}

test "normalizeStatus maps OPEN/CLOSED/MERGED" {
    try testing.expectEqualStrings("open", normalizeStatus("OPEN"));
    try testing.expectEqualStrings("open", normalizeStatus("open"));
    try testing.expectEqualStrings("closed", normalizeStatus("CLOSED"));
    try testing.expectEqualStrings("merged", normalizeStatus("MERGED"));
}

test "GhPrView parses open-PR payload with null mergedAt/closedAt" {
    // `gh pr view --json ...` emits `"mergedAt":null,"closedAt":null` for
    // OPEN PRs. Parsing that into non-optional `[]const u8` fails, which
    // surfaced as HTTP 502 for every open PR (PR #584).
    const allocator = testing.allocator;
    const raw =
        \\{"number":584,"title":"SyncEngine Phase 2","url":"https://github.com/acme/app/pull/584","state":"OPEN","mergeable":"MERGEABLE","mergeStateStatus":"UNSTABLE","headRefName":"worktree/sync-engine-phase2-cached-delta","baseRefName":"main","createdAt":"2026-09-21T08:51:37Z","updatedAt":"2026-09-21T08:51:37Z","mergedAt":null,"closedAt":null,"author":{"login":"ginwa123"},"additions":286,"deletions":103,"changedFiles":4}
    ;
    const parsed = try std.json.parseFromSliceLeaky(GhPrView, allocator, raw, .{ .ignore_unknown_fields = true });
    try testing.expectEqual(@as(i64, 584), parsed.number);
    try testing.expectEqualStrings("OPEN", parsed.state);
    try testing.expect(parsed.mergedAt == null);
    try testing.expect(parsed.closedAt == null);
    try testing.expectEqualStrings("open", normalizeStatus(parsed.state));
}

// ============================================================================
// Behavioural test suite for the `gh pr view` child-process path.

const open_descriptors = @import("helpers").open_descriptors;
const hf = @import("helpers").host_fixture;

/// A throwaway directory under `.zig-cache/tmp` plus fixture programs,
/// written by `host_fixture` so the spawn -> capture -> parse path under
/// test runs on every host instead of being skipped on Windows.
const Fixture = struct {
    inner: hf.Fixture,
    allocator: std.mem.Allocator,

    fn init(allocator: std.mem.Allocator) !Fixture {
        return .{ .inner = try hf.Fixture.init(allocator), .allocator = allocator };
    }

    fn deinit(self: *Fixture) void {
        self.inner.deinit();
    }

    /// The fixture root, as an absolute path.
    fn root(self: *Fixture) []const u8 {
        return self.inner.root;
    }

    /// Write a fixture program that behaves as `payload` describes.
    fn writeProgram(self: *Fixture, name: []const u8, payload: hf.Payload) ![]u8 {
        return self.inner.writeProgram(name, payload);
    }

    /// A subdirectory of the fixture root, created on demand.
    fn subDir(self: *Fixture, name: []const u8) ![]u8 {
        return self.inner.subDir(name);
    }
};

/// A realistic `glab mr view --output json` payload for an OPEN MR: GitLab's
/// own field names (`iid`, `web_url`, `source_branch`,
/// `detailed_merge_status`) and its `opened` state, plus `changes_count` as
const OPEN_MR_JSON =
    \\{"id":11463,"iid":7,"title":"Add GitLab support","description":"body","state":"opened","created_at":"2026-09-28T10:00:00.000Z","updated_at":"2026-09-29T11:30:00.000Z","merged_at":null,"closed_at":null,"author":{"id":42,"name":"Ginwa","username":"ginwa123","state":"active"},"source_branch":"worktree/gitlab-support","target_branch":"main","web_url":"https://gitlab.com/acme/sub/app/-/merge_requests/7","merge_status":"can_be_merged","detailed_merge_status":"mergeable","changes_count":"4"}
;

const OPEN_PR_JSON =
    \\{"number":584,"title":"SyncEngine Phase 2","url":"https://github.com/acme/app/pull/584","state":"OPEN","mergeable":"MERGEABLE","mergeStateStatus":"UNSTABLE","headRefName":"worktree/x","baseRefName":"main","createdAt":"2026-09-21T08:51:37Z","updatedAt":"2026-09-21T08:51:37Z","mergedAt":null,"closedAt":null,"author":{"login":"ginwa123"},"additions":286,"deletions":103,"changedFiles":4}
;

/// True when a usable `git` is on PATH (the `useCase` tests need one).
fn haveGit() bool {
    var c = std.process.spawn(std.testing.io, .{
        .argv = &.{ "git", "--version" },
        .stdin = .ignore,
        .stdout = .ignore,
        .stderr = .ignore,
    }) catch return false;
    _ = c.wait(std.testing.io) catch return false;
    return true;
}

/// A real (empty) git repo inside the fixture, so the
/// `git rev-parse --git-dir` gate in `useCaseWith` passes.
fn makeGitRepo(fx: *Fixture) ![]u8 {
    // Fixture git must not run under hook-exported GIT_DIR/GIT_WORK_TREE.
    try @import("helpers").git_env_guard.requireCleanGitEnv();
    const a = fx.allocator;
    const repo = try fx.subDir("repo");
    var r = run_captured.run(a, std.testing.io, &.{ "git", "init", "-q", repo }, .{
        .timeout_ms = 30_000,
    }) catch return error.SkipZigTest;
    defer r.deinit(a);
    if (r.term.exited != 0) return error.SkipZigTest;
    return repo;
}

/// A directory that is genuinely NOT inside a git repository.
pub fn makeNonRepoDir(allocator: std.mem.Allocator) ![]u8 {
    var name_buf: [48]u8 = undefined;
    var seed: [4]u8 = undefined;
    std.Io.random(std.testing.io, &seed);
    const name = try std.fmt.bufPrint(&name_buf, "pabrik-nonrepo-{x}-{x}{x}{x}", .{
        seed[0], seed[1], seed[2], seed[3],
    });
    const path = try std.fmt.allocPrint(allocator, "/tmp/{s}", .{name});
    errdefer allocator.free(path);
    const dir = try std.Io.Dir.cwd().createDirPathOpen(std.testing.io, path, .{});
    std.Io.Dir.close(dir, std.testing.io);
    return path;
}

pub fn removeNonRepoDir(allocator: std.mem.Allocator, path: []const u8) void {
    std.Io.Dir.cwd().deleteTree(std.testing.io, path) catch {};
    allocator.free(path);
}

/// True when the ambient environment already makes git claim every path is a
/// repository — see the KNOWN LIMITATION note on the probe in `useCaseWith`.
/// git exports `GIT_DIR` / `GIT_WORK_TREE` to the hooks it runs, so under
pub fn gitProbeIsEnvHijacked(allocator: std.mem.Allocator, empty_dir: []const u8) bool {
    const check = std.process.run(allocator, std.testing.io, .{
        .argv = &.{ "git", "-C", empty_dir, "rev-parse", "--git-dir" },
    }) catch return true;
    defer {
        allocator.free(check.stdout);
        allocator.free(check.stderr);
    }
    return check.term.exited == 0;
}

/// `useCaseWith` dupes every string of the response into the caller's
/// allocator (the request arena in production). Tests pass
/// `testing.allocator`, so they have to give the copies back.
fn freeResponse(a: std.mem.Allocator, res: http_response.GitPrStatusResponse) void {
    inline for (.{
        res.provider,  res.pr_url,    res.title,       res.state,
        res.status,    res.mergeable, res.merge_state, res.head_ref,
        res.base_ref,  res.author,    res.created_at,  res.updated_at,
        res.merged_at, res.closed_at,
    }) |s| a.free(s);
}

// ─────────────────────────── runGhPrView ───────────────────────────

test "runGhPrView returns gh stdout verbatim" {
    const a = testing.allocator;
    var fx = try Fixture.init(a);
    defer fx.deinit();

    const gh = try fx.writeProgram("gh", .{ .stdout = "{\"number\":7,\"state\":\"OPEN\"}" });
    defer a.free(gh);

    var detail: ?[]u8 = null;
    defer if (detail) |d| a.free(d);
    const out = try runGhPrView(a, testing.io, gh, fx.root(), "", 10_000, &detail);
    defer a.free(out);
    try testing.expectEqualStrings("{\"number\":7,\"state\":\"OPEN\"}", out);
    try testing.expect(detail == null);
}

test "runGhPrView builds `pr view --json <fields>` and omits an empty pr arg" {
    const a = testing.allocator;
    var fx = try Fixture.init(a);
    defer fx.deinit();

    const argv_file = try std.fmt.allocPrint(a, "{s}/argv", .{fx.root()});
    defer a.free(argv_file);
    const gh = try fx.writeProgram("gh", .{ .argv_file = argv_file });
    defer a.free(gh);

    var detail: ?[]u8 = null;
    defer if (detail) |d| a.free(d);
    const out = try runGhPrView(a, testing.io, gh, fx.root(), "", 10_000, &detail);
    defer a.free(out);

    // Exactly four arguments when pr_arg is empty: pr / view / --json / fields
    const recorded = try std.Io.Dir.cwd().readFileAlloc(testing.io, argv_file, a, .limited(64 * 1024));
    defer a.free(recorded);
    try testing.expect(hf.recordedArgvContainsSequence(recorded, &.{ "pr", "view", "--json", GH_JSON_FIELDS }));
    // Nothing else was passed — in particular no empty pr argument.
    try testing.expect(!hf.recordedArgvContains(recorded, ""));
}

test "runGhPrView passes a pr number / URL / branch through verbatim" {
    const a = testing.allocator;
    var fx = try Fixture.init(a);
    defer fx.deinit();

    const argv_file = try std.fmt.allocPrint(a, "{s}/argv", .{fx.root()});
    defer a.free(argv_file);
    const gh = try fx.writeProgram("gh", .{ .argv_file = argv_file });
    defer a.free(gh);

    for ([_][]const u8{ "42", "https://github.com/acme/app/pull/9", "feature-x" }) |pr_arg| {
        var detail: ?[]u8 = null;
        defer if (detail) |d| a.free(d);
        const out = try runGhPrView(a, testing.io, gh, fx.root(), pr_arg, 10_000, &detail);
        defer a.free(out);
        // The fixture records the argv it was handed, so read the record
        // back rather than the (empty) stdout.
        const recorded = try std.Io.Dir.cwd().readFileAlloc(testing.io, argv_file, a, .limited(64 * 1024));
        defer a.free(recorded);
        // The pr argument is passed through verbatim, in position, after
        // `pr view` — not quoted, rewritten or dropped.
        try testing.expect(hf.recordedArgvContainsSequence(recorded, &.{ "pr", "view", pr_arg }));
    }
}

test "runGhPrView runs the child in the requested cwd" {
    const a = testing.allocator;
    var fx = try Fixture.init(a);
    defer fx.deinit();

    const gh = try fx.writeProgram("gh", .{ .print_cwd = true });
    defer a.free(gh);
    const repo = try fx.subDir("repo");
    defer a.free(repo);

    var detail: ?[]u8 = null;
    defer if (detail) |d| a.free(d);
    const out = try runGhPrView(a, testing.io, gh, repo, "", 10_000, &detail);
    defer a.free(out);
    try testing.expect(std.mem.indexOf(u8, out, "repo") != null);
}

test "runGhPrView: 'no pull requests found' maps to NoAssociatedPr" {
    const a = testing.allocator;
    var fx = try Fixture.init(a);
    defer fx.deinit();

    for ([_][]const u8{
        "no pull requests found for branch",
        "no pull request found for branch",
        "could not find any pull request",
    }) |msg| {
        const gh = try fx.writeProgram("gh", .{ .stderr = msg, .exit_code = 1 });
        defer a.free(gh);

        var detail: ?[]u8 = null;
        defer if (detail) |d| a.free(d);
        try testing.expectError(
            error.NoAssociatedPr,
            runGhPrView(a, testing.io, gh, fx.root(), "", 10_000, &detail),
        );
    }
}

test "runGhPrView: auth failure surfaces the real gh stderr in fetch_detail" {
    const a = testing.allocator;
    var fx = try Fixture.init(a);
    defer fx.deinit();

    const gh = try fx.writeProgram("gh", .{
        .stderr = "gh: To use GitHub CLI in a GitHub Actions workflow, set the GH_TOKEN environment variable.",
        .exit_code = 4,
    });
    defer a.free(gh);

    var detail: ?[]u8 = null;
    defer if (detail) |d| a.free(d);
    try testing.expectError(error.FetchFailed, runGhPrView(a, testing.io, gh, fx.root(), "", 10_000, &detail));
    try testing.expect(detail != null);
    try testing.expect(std.mem.indexOf(u8, detail.?, "GH_TOKEN") != null);
}

test "runGhPrView: a non-zero exit with empty stderr still records the code" {
    const a = testing.allocator;
    var fx = try Fixture.init(a);
    defer fx.deinit();

    const gh = try fx.writeProgram("gh", .{ .exit_code = 9 });
    defer a.free(gh);

    var detail: ?[]u8 = null;
    defer if (detail) |d| a.free(d);
    try testing.expectError(error.FetchFailed, runGhPrView(a, testing.io, gh, fx.root(), "", 10_000, &detail));
    try testing.expect(detail != null);
    try testing.expect(std.mem.indexOf(u8, detail.?, "exited with code 9") != null);
}

test "runGhPrView: >64 KiB of gh stderr does NOT deadlock (crash-class regression)" {
    // THE regression test for the production hang.
    const a = testing.allocator;
    var fx = try Fixture.init(a);
    defer fx.deinit();

    // 1024 x 1 KiB of stderr: far past one pipe buffer, so the drain has
    // to keep reading while the child keeps writing or it deadlocks.
    const gh = try fx.writeProgram("gh", .{
        .stderr = "E" ** 1024,
        .repeat_stderr = 1024,
        .exit_code = 1,
    });
    defer a.free(gh);

    var detail: ?[]u8 = null;
    defer if (detail) |d| a.free(d);
    // 20s deadline: generous enough to be reliable on a loaded CI box,
    // and the process is killed either way, so this can never hang the
    // suite the way the pre-fix code hung the worker thread.
    try testing.expectError(
        error.FetchFailed,
        runGhPrView(a, testing.io, gh, fx.root(), "", 20_000, &detail),
    );
    // 1 MiB of stderr was drained, then trimmed down to MAX_FETCH_DETAIL.
    try testing.expectEqual(@as(usize, MAX_FETCH_DETAIL), detail.?.len);
}

test "runGhPrView: a gh that never exits is killed at the deadline" {
    const a = testing.allocator;
    var fx = try Fixture.init(a);
    defer fx.deinit();

    const gh = try fx.writeProgram("gh", .{ .sleep_ms = 60_000 });
    defer a.free(gh);

    var detail: ?[]u8 = null;
    defer if (detail) |d| a.free(d);
    try testing.expectError(error.FetchFailed, runGhPrView(a, testing.io, gh, fx.root(), "", 300, &detail));
    try testing.expect(detail != null);
    try testing.expect(std.mem.indexOf(u8, detail.?, "timed out") != null);
}

test "runGhPrView: a gh killed by a signal is reported, not a success" {
    const a = testing.allocator;
    var fx = try Fixture.init(a);
    defer fx.deinit();

    const gh = try fx.writeProgram("gh", .{ .kill_self = true });
    defer a.free(gh);

    var detail: ?[]u8 = null;
    defer if (detail) |d| a.free(d);
    try testing.expectError(error.FetchFailed, runGhPrView(a, testing.io, gh, fx.root(), "", 10_000, &detail));
    try testing.expect(detail != null);
    // POSIX reports the signal that killed the child; Windows has no signal
    // to send, so the fixture exits with a code instead and the detail names
    // that. Either way it must NOT read as a clean success.
    try testing.expect(std.mem.indexOf(u8, detail.?, "signal") != null or
        std.mem.indexOf(u8, detail.?, "exited with code") != null);
}

test "runGhPrView: a missing gh binary maps to CliMissing" {
    const a = testing.allocator;
    var fx = try Fixture.init(a);
    defer fx.deinit();

    var detail: ?[]u8 = null;
    defer if (detail) |d| a.free(d);
    try testing.expectError(error.CliMissing, runGhPrView(
        a,
        testing.io,
        "/pabrik/definitely/not/gh",
        fx.root(),
        "",
        10_000,
        &detail,
    ));
}

test "runGhPrView: empty gh stdout is an empty slice, not a silent failure" {
    const a = testing.allocator;
    var fx = try Fixture.init(a);
    defer fx.deinit();

    const gh = try fx.writeProgram("gh", .{});
    defer a.free(gh);

    var detail: ?[]u8 = null;
    defer if (detail) |d| a.free(d);
    const out = try runGhPrView(a, testing.io, gh, fx.root(), "", 10_000, &detail);
    defer a.free(out);
    try testing.expectEqual(@as(usize, 0), out.len);
    try testing.expect(detail == null);
}

const ConcurrentGhCtx = struct {
    a: std.mem.Allocator,
    gh: []const u8,
    root: []const u8,
    ok: *bool,
};

fn concurrentGhWorker(ctx: *ConcurrentGhCtx) void {
    ctx.ok.* = true;
    for (0..8) |_| {
        var detail: ?[]u8 = null;
        defer if (detail) |d| ctx.a.free(d);
        const out = runGhPrView(ctx.a, testing.io, ctx.gh, ctx.root, "", 10_000, &detail) catch {
            ctx.ok.* = false;
            return;
        };
        defer ctx.a.free(out);
        if (!std.mem.eql(u8, out, "{\"number\":1,\"state\":\"OPEN\"}")) {
            ctx.ok.* = false;
            return;
        }
    }
}

test "runGhPrView: 8 concurrent callers never trip the double-close abort" {
    // The reported crash was a `closeFd` EBADF inside `childCleanupPosix` on
    // a worker-pool thread, so it only ever showed up under concurrency.
    // Descriptors on POSIX, handles on Windows: one count per host here.
    const a = testing.allocator;
    var fx = try Fixture.init(a);
    defer fx.deinit();

    const gh = try fx.writeProgram("gh", .{ .stdout = "{\"number\":1,\"state\":\"OPEN\"}" });
    defer a.free(gh);

    const before = try open_descriptors.count();
    const oks = try a.alloc(bool, 8);
    defer a.free(oks);
    const ctxs = try a.alloc(ConcurrentGhCtx, 8);
    defer a.free(ctxs);
    const threads = try a.alloc(std.Thread, 8);
    defer a.free(threads);

    for (0..8) |i| {
        oks[i] = false;
        ctxs[i] = .{ .a = a, .gh = gh, .root = fx.root(), .ok = &oks[i] };
        threads[i] = try std.Thread.spawn(.{}, concurrentGhWorker, .{&ctxs[i]});
    }
    for (threads) |t| t.join();
    for (oks) |ok| try testing.expect(ok);

    const after = try open_descriptors.count();
    try testing.expect(after <= before + 8);
}

// ───────────────────────────── useCase ─────────────────────────────

test "useCase maps a valid gh payload onto GitPrStatusResponse" {
    if (!haveGit()) return error.SkipZigTest;
    const a = testing.allocator;
    var fx = try Fixture.init(a);
    defer fx.deinit();
    const repo = try makeGitRepo(&fx);
    defer a.free(repo);

    const gh = try fx.writeProgram("gh", .{ .stdout = OPEN_PR_JSON });
    defer a.free(gh);

    var detail: ?[]u8 = null;
    defer if (detail) |d| a.free(d);
    const res = try useCaseWith(a, testing.io, gh, repo, "", null, &detail);
    defer freeResponse(a, res);

    try testing.expectEqual(@as(i64, 584), res.number);
    try testing.expectEqualStrings("https://github.com/acme/app/pull/584", res.pr_url);
    try testing.expectEqualStrings("SyncEngine Phase 2", res.title);
    try testing.expectEqualStrings("OPEN", res.state);
    try testing.expectEqualStrings("open", res.status);
    try testing.expectEqualStrings("MERGEABLE", res.mergeable);
    try testing.expectEqualStrings("UNSTABLE", res.merge_state);
    try testing.expectEqualStrings("worktree/x", res.head_ref);
    try testing.expectEqualStrings("main", res.base_ref);
    try testing.expectEqualStrings("ginwa123", res.author);
    // mergedAt/closedAt are JSON null -> empty strings, never garbage.
    try testing.expectEqualStrings("", res.merged_at);
    try testing.expectEqualStrings("", res.closed_at);
    try testing.expectEqual(@as(i64, 286), res.additions);
    try testing.expectEqual(@as(i64, 103), res.deletions);
    try testing.expectEqual(@as(i64, 4), res.changed_files);
}

test "useCase: a non-git path never spawns gh (repo-gate regression)" {
    if (!haveGit()) return error.SkipZigTest;
    const a = testing.allocator;
    var fx = try Fixture.init(a);
    defer fx.deinit();
    const not_repo = try makeNonRepoDir(a);
    defer removeNonRepoDir(a, not_repo);
    if (gitProbeIsEnvHijacked(a, not_repo)) {
        std.debug.print("!! skipping: this environment exports GIT_DIR/GIT_WORK_TREE, so git calls any path a repository (see the KNOWN LIMITATION note in useCaseWith) !!\n", .{});
        return error.SkipZigTest;
    }

    // A `gh` that succeeds AND drops a sentinel: if the repo gate ever fails
    // to short-circuit, the sentinel appears and this test fails with a
    // message that names the actual problem.
    const sentinel = try std.fmt.allocPrint(a, "{s}/gh-was-run", .{fx.root()});
    defer a.free(sentinel);
    const gh = try fx.writeProgram("gh", .{
        .touch_file = sentinel,
        .stdout = "{\"number\":1,\"state\":\"OPEN\"}",
    });
    defer a.free(gh);

    var detail: ?[]u8 = null;
    defer if (detail) |d| a.free(d);
    // A success here means the gate let it through; free the response
    // so the test allocator stays honest either way.
    if (useCaseWith(a, testing.io, gh, not_repo, "", null, &detail)) |res| {
        freeResponse(a, res);
    } else |_| {}
    if (std.Io.Dir.cwd().access(std.testing.io, sentinel, .{})) |_| {
        std.debug.print("!! the repo gate did not short-circuit: gh was spawned for a non-repo path !!\n", .{});
        return error.GhWasSpawned;
    } else |_| {}
}

test "useCase: a missing path is NotARepository" {
    if (!haveGit()) return error.SkipZigTest;
    const a = testing.allocator;
    var fx = try Fixture.init(a);
    defer fx.deinit();

    var detail: ?[]u8 = null;
    defer if (detail) |d| a.free(d);
    try testing.expectError(
        error.NotARepository,
        useCaseWith(a, testing.io, "/bin/sh", "/pabrik/no/such/repo", "", null, &detail),
    );
}

test "useCase: an unknown provider string is rejected" {
    if (!haveGit()) return error.SkipZigTest;
    const a = testing.allocator;
    var fx = try Fixture.init(a);
    defer fx.deinit();
    const repo = try makeGitRepo(&fx);
    defer a.free(repo);

    var detail: ?[]u8 = null;
    defer if (detail) |d| a.free(d);
    try testing.expectError(
        error.FetchFailed,
        useCaseWith(a, testing.io, "/bin/sh", repo, "", "bitbucket", &detail),
    );
    try testing.expect(detail != null);
    try testing.expect(std.mem.indexOf(u8, detail.?, "unknown provider") != null);
}

test "useCase: the generic provider is rejected — it has no forge CLI" {
    // `generic` is a legitimate provider for DIFFING (pure local refs,
    // git_pr_diff.zig) but there is no CLI to ask for status, so the request
    // is unanswerable and must say so rather than silently falling back to
    if (!haveGit()) return error.SkipZigTest;
    const a = testing.allocator;
    var fx = try Fixture.init(a);
    defer fx.deinit();
    const repo = try makeGitRepo(&fx);
    defer a.free(repo);

    var detail: ?[]u8 = null;
    defer if (detail) |d| a.free(d);
    try testing.expectError(
        error.FetchFailed,
        useCaseWith(a, testing.io, "/bin/sh", repo, "", "generic", &detail),
    );
    try testing.expect(detail != null);
    try testing.expect(std.mem.indexOf(u8, detail.?, "no forge CLI") != null);
}

test "useCase: a GitLab MR URL routes to the glab path, not gh" {
    // The regression this pins: before GitLab support, a GitLab MR URL
    // was rejected with "not a GitHub URL". Now it must spawn `glab`.
    if (!haveGit()) return error.SkipZigTest;
    const a = testing.allocator;
    var fx = try Fixture.init(a);
    defer fx.deinit();
    const repo = try makeGitRepo(&fx);
    defer a.free(repo);

    // Records its argv so we can prove `glab mr view` ran, not `gh`.
    const glab_argv = try std.fmt.allocPrint(a, "{s}/glab-argv", .{fx.root()});
    defer a.free(glab_argv);
    const glab = try fx.writeProgram("glab", .{
        .argv_file = glab_argv,
        .stdout = OPEN_MR_JSON,
    });
    defer a.free(glab);

    var detail: ?[]u8 = null;
    defer if (detail) |d| a.free(d);
    const res = try useCaseWithPrograms(a, testing.io, .{ .gh = "/bin/sh", .glab = glab }, repo, "https://gitlab.com/acme/app/-/merge_requests/3", null, &detail);
    defer freeResponse(a, res);

    try testing.expectEqualStrings("gitlab", res.provider);
    try testing.expectEqual(@as(i64, 7), res.number);

    const recorded = try std.Io.Dir.cwd().readFileAlloc(testing.io, glab_argv, a, .limited(64 * 1024));
    defer a.free(recorded);
    try testing.expect(hf.recordedArgvContainsSequence(recorded, &.{ "mr", "view" }));
    try testing.expect(hf.recordedArgvContainsSequence(recorded, &.{ "--output", "json" }));
    try testing.expect(hf.recordedArgvContains(recorded, "https://gitlab.com/acme/app/-/merge_requests/3"));
}

test "useCase: the origin remote decides the forge when no provider is given" {
    // This is the badge/refresh path: the frontend calls pr/status with
    // no provider for a GitLab repo, so the remote is the only signal.
    if (!haveGit()) return error.SkipZigTest;
    const a = testing.allocator;
    var fx = try Fixture.init(a);
    defer fx.deinit();
    const repo = try makeGitRepo(&fx);
    defer a.free(repo);
    // scp-style, the shape a GitLab clone actually has.
    var set = run_captured.run(a, testing.io, &.{ "git", "-C", repo, "remote", "add", "origin", "git@gitlab.com:acme/app.git" }, .{ .timeout_ms = 30_000 }) catch return error.SkipZigTest;
    defer set.deinit(a);
    if (set.term.exited != 0) return error.SkipZigTest;

    const glab = try fx.writeProgram("glab", .{ .stdout = OPEN_MR_JSON });
    defer a.free(glab);

    var detail: ?[]u8 = null;
    defer if (detail) |d| a.free(d);
    const res = try useCaseWithPrograms(a, testing.io, .{ .gh = "/pabrik/no/such/gh", .glab = glab }, repo, "", null, &detail);
    defer freeResponse(a, res);
    try testing.expectEqualStrings("gitlab", res.provider);
}

test "useCase: a GitHub repo with a gh origin still routes to gh" {
    if (!haveGit()) return error.SkipZigTest;
    const a = testing.allocator;
    var fx = try Fixture.init(a);
    defer fx.deinit();
    const repo = try makeGitRepo(&fx);
    defer a.free(repo);
    var set = run_captured.run(a, testing.io, &.{ "git", "-C", repo, "remote", "add", "origin", "git@github.com:acme/app.git" }, .{ .timeout_ms = 30_000 }) catch return error.SkipZigTest;
    defer set.deinit(a);
    if (set.term.exited != 0) return error.SkipZigTest;

    // `gh` is the only working fixture here; a glab route would fail to
    // spawn and the test would not get to assert the provider.
    const gh = try fx.writeProgram("gh", .{ .stdout = OPEN_PR_JSON });
    defer a.free(gh);

    var detail: ?[]u8 = null;
    defer if (detail) |d| a.free(d);
    const res = try useCaseWithPrograms(a, testing.io, .{ .gh = gh, .glab = "/pabrik/no/such/glab" }, repo, "", null, &detail);
    defer freeResponse(a, res);
    try testing.expectEqualStrings("github", res.provider);
}

test "useCase: a GitHub PR URL is accepted" {
    if (!haveGit()) return error.SkipZigTest;
    const a = testing.allocator;
    var fx = try Fixture.init(a);
    defer fx.deinit();
    const repo = try makeGitRepo(&fx);
    defer a.free(repo);

    const gh = try fx.writeProgram("gh", .{ .stdout = OPEN_PR_JSON });
    defer a.free(gh);

    var detail: ?[]u8 = null;
    defer if (detail) |d| a.free(d);
    const res = try useCaseWith(
        a,
        testing.io,
        gh,
        repo,
        "https://github.com/acme/app/pull/584",
        null,
        &detail,
    );
    defer freeResponse(a, res);
    try testing.expectEqual(@as(i64, 584), res.number);
}

test "useCase: garbage stdout from gh is a FetchFailed with a size hint" {
    if (!haveGit()) return error.SkipZigTest;
    const a = testing.allocator;
    var fx = try Fixture.init(a);
    defer fx.deinit();
    const repo = try makeGitRepo(&fx);
    defer a.free(repo);

    const gh = try fx.writeProgram("gh", .{ .stdout = "not json at all" });
    defer a.free(gh);

    var detail: ?[]u8 = null;
    defer if (detail) |d| a.free(d);
    try testing.expectError(error.FetchFailed, useCaseWith(a, testing.io, gh, repo, "", null, &detail));
    try testing.expect(detail != null);
    try testing.expect(std.mem.indexOf(u8, detail.?, "invalid JSON") != null);
}

test "useCase: an empty stdout from gh is a FetchFailed, never a bogus 200" {
    if (!haveGit()) return error.SkipZigTest;
    const a = testing.allocator;
    var fx = try Fixture.init(a);
    defer fx.deinit();
    const repo = try makeGitRepo(&fx);
    defer a.free(repo);

    const gh = try fx.writeProgram("gh", .{});
    defer a.free(gh);

    var detail: ?[]u8 = null;
    defer if (detail) |d| a.free(d);
    try testing.expectError(error.FetchFailed, useCaseWith(a, testing.io, gh, repo, "", null, &detail));
}

test "useCase: 'no pull requests found' surfaces as NoAssociatedPr" {
    if (!haveGit()) return error.SkipZigTest;
    const a = testing.allocator;
    var fx = try Fixture.init(a);
    defer fx.deinit();
    const repo = try makeGitRepo(&fx);
    defer a.free(repo);

    const gh = try fx.writeProgram("gh", .{
        .stderr = "no pull requests found for branch \"worktree/x\"",
        .exit_code = 1,
    });
    defer a.free(gh);

    var detail: ?[]u8 = null;
    defer if (detail) |d| a.free(d);
    try testing.expectError(error.NoAssociatedPr, useCaseWith(a, testing.io, gh, repo, "", null, &detail));
}

test "useCase: a missing gh binary surfaces as CliMissing" {
    if (!haveGit()) return error.SkipZigTest;
    const a = testing.allocator;
    var fx = try Fixture.init(a);
    defer fx.deinit();
    const repo = try makeGitRepo(&fx);
    defer a.free(repo);

    var detail: ?[]u8 = null;
    defer if (detail) |d| a.free(d);
    try testing.expectError(
        error.CliMissing,
        useCaseWith(a, testing.io, "/pabrik/definitely/not/gh", repo, "", null, &detail),
    );
}

// ───────────────────────── GitLab (glab) path ─────────────────────────

test "normalizeStatus maps GitLab's opened/merged/locked states" {
    // `opened` is the load-bearing one: without it every open GitLab MR
    // reports status "opened", which the frontend's `status === 'open'`
    // check misses, so the badge shows nothing at all.
    try testing.expectEqualStrings("open", normalizeStatus("opened"));
    try testing.expectEqualStrings("open", normalizeStatus("OPENED"));
    try testing.expectEqualStrings("merged", normalizeStatus("merged"));
    try testing.expectEqualStrings("closed", normalizeStatus("closed"));
    try testing.expectEqualStrings("locked", normalizeStatus("locked"));
    // GitHub's vocabulary must be untouched.
    try testing.expectEqualStrings("open", normalizeStatus("OPEN"));
    try testing.expectEqualStrings("closed", normalizeStatus("CLOSED"));
    try testing.expectEqualStrings("merged", normalizeStatus("MERGED"));
}

test "GlabMrView maps a real glab payload onto GitPrStatusResponse" {
    if (!haveGit()) return error.SkipZigTest;
    const a = testing.allocator;
    var fx = try Fixture.init(a);
    defer fx.deinit();
    const repo = try makeGitRepo(&fx);
    defer a.free(repo);

    const glab = try fx.writeProgram("glab", .{ .stdout = OPEN_MR_JSON });
    defer a.free(glab);

    var detail: ?[]u8 = null;
    defer if (detail) |d| a.free(d);
    const res = try useCaseWithPrograms(a, testing.io, .{ .gh = "/pabrik/no/such/gh", .glab = glab }, repo, "", "gitlab", &detail);
    defer freeResponse(a, res);

    try testing.expectEqualStrings("gitlab", res.provider);
    try testing.expectEqual(@as(i64, 7), res.number); // iid, not the global id
    try testing.expectEqualStrings("https://gitlab.com/acme/sub/app/-/merge_requests/7", res.pr_url);
    try testing.expectEqualStrings("Add GitLab support", res.title);
    try testing.expectEqualStrings("opened", res.state); // raw forge state
    try testing.expectEqualStrings("open", res.status); // normalized
    try testing.expectEqualStrings("worktree/gitlab-support", res.head_ref);
    try testing.expectEqualStrings("main", res.base_ref);
    try testing.expectEqualStrings("ginwa123", res.author);
    try testing.expectEqualStrings("mergeable", res.mergeable); // detailed wins
    try testing.expectEqualStrings("can_be_merged", res.merge_state);
    try testing.expectEqualStrings("", res.merged_at); // JSON null, never garbage
    try testing.expectEqualStrings("", res.closed_at);
    try testing.expectEqual(@as(i64, 4), res.changed_files); // string "4" -> 4
}

test "buildGlabResponse survives the glab field renames" {
    // A glab upgrade must not 502 the endpoint for every GitLab user.
    // This payload uses the ALTERNATE names an older/newer glab emits.
    const a = testing.allocator;
    var fx = try Fixture.init(a);
    defer fx.deinit();

    const alt =
        \\{"iid":0,"id":99,"title":"Alt names","state":"merged","url":"https://gitlab.com/g/r/-/merge_requests/99","source_branch":"b","target_branch":"main","merge_status":"can_be_merged","merged_at":"2026-09-29T00:00:00Z","author":"someone","additions":10,"deletions":2,"changes_count":5}
    ;
    var detail: ?[]u8 = null;
    defer if (detail) |d| a.free(d);
    const res = try buildGlabResponse(a, .gitlab, alt, alt.len, pr_cli.GLAB_CLI, &detail);
    defer freeResponse(a, res);

    try testing.expectEqual(@as(i64, 99), res.number); // falls back to id
    try testing.expectEqualStrings("https://gitlab.com/g/r/-/merge_requests/99", res.pr_url); // url, not web_url
    try testing.expectEqualStrings("merged", res.status);
    try testing.expectEqualStrings("someone", res.author); // bare string author
    try testing.expectEqualStrings("can_be_merged", res.mergeable); // only merge_status present
    try testing.expectEqualStrings("can_be_merged", res.merge_state);
    try testing.expectEqualStrings("2026-09-29T00:00:00Z", res.merged_at);
    try testing.expectEqual(@as(i64, 10), res.additions); // numeric, not string
    try testing.expectEqual(@as(i64, 2), res.deletions);
    try testing.expectEqual(@as(i64, 5), res.changed_files);
}

test "buildGlabResponse reports unparseable stdout naming glab" {
    const a = testing.allocator;
    var fx = try Fixture.init(a);
    defer fx.deinit();
    var detail: ?[]u8 = null;
    defer if (detail) |d| a.free(d);
    try testing.expectError(error.FetchFailed, buildGlabResponse(a, .gitlab, "not json", 8, pr_cli.GLAB_CLI, &detail));
    try testing.expect(detail != null);
    try testing.expect(std.mem.indexOf(u8, detail.?, "glab mr view") != null);
}

test "isNotFoundStderr separates a missing MR from an auth failure" {
    // A missing MR is a 404; an auth failure must stay a 502 so the
    // user learns to log in instead of being told the MR is missing.
    for ([_][]const u8{
        "no merge requests found",
        "no merge request found for branch",
        "Merge request not found",
        "404 Not Found",
    }) |msg| try testing.expect(isNotFoundStderr(msg, .gitlab));

    for ([_][]const u8{
        "no pull requests found for branch",
        "could not find any pull request",
    }) |msg| try testing.expect(isNotFoundStderr(msg, .github));

    for ([_][]const u8{
        "glab: authentication failed, please run glab auth login",
        "gh: To use GitHub CLI in a GitHub Actions workflow, set GH_TOKEN",
        "HTTP 401: Bad credentials",
    }) |msg| {
        try testing.expect(!isNotFoundStderr(msg, .gitlab));
        try testing.expect(!isNotFoundStderr(msg, .github));
    }
}

// ─────────── source-contract guard against the regression ───────────

test "useCaseWithPrograms: --saas refuses a real repository rather than asking the host's git" {
    const allocator = testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const path_len = try tmp.dir.realPath(std.testing.io, &buf);
    const repo = try allocator.dupe(u8, buf[0..path_len]);
    defer allocator.free(repo);

    var init = run_captured.run(allocator, std.testing.io, &.{ "git", "init", "-q", repo }, .{ .timeout_ms = 30_000 }) catch
        return error.SkipZigTest;
    defer init.deinit(allocator);
    if (init.term.exited != 0) return error.SkipZigTest;

    var detail: ?[]u8 = null;
    defer if (detail) |d| allocator.free(d);

    runtime_mode.setCurrent(.saas);
    defer runtime_mode.setCurrent(.local);
    if (!runtime_mode.vm_backend_available) return;

    // The repository is right here on the host. With a workspace configured
    // and no VM answering, the endpoint says "not a git repository" instead
    // of letting the host's git look at a tenant's tree.
    try testing.expectError(
        error.NotARepository,
        useCaseWithPrograms(allocator, std.testing.io, .{}, repo, "", null, &detail),
    );
}
