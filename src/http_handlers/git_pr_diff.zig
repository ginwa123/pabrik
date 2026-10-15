const std = @import("std");
const http_response = @import("http_response.zig");
const pabrik_core = @import("pabrikcore");
const gserverz = pabrik_core.gserverz;
const pr_provider = pabrik_core.pr_provider;

/// Cap for the returned unified diff (1MB). Larger PRs truncate with
/// `truncated=true` — the panel renders what fits and notes the cut.
pub const MAX_DIFF_BYTES: usize = 1024 * 1024;

/// Which backend produces the diff. Resolved purely from
/// (provider, cli_available) so it is unit-testable without IO.
pub const DiffStrategy = enum {
    gh_cli,
    glab_cli,
    git_fetch_pr_ref,
    git_fetch_mr_ref,
    git_local_range,
};

/// Pick the diff strategy. `cli_available` = whether the provider's CLI (`gh`
/// / `glab`) is on PATH. `generic` never has a CLI and always diffs locally.
pub fn resolveStrategy(provider: pr_provider.PrProvider, cli_available: bool) DiffStrategy {
    return switch (provider) {
        .github => if (cli_available) .gh_cli else .git_fetch_pr_ref,
        .gitlab => if (cli_available) .glab_cli else .git_fetch_mr_ref,
        .generic => .git_local_range,
    };
}

const PrDiffError = error{ NotARepository, FetchFailed, DiffFailed };

/// Every strategy returns OWNED slices — `diff_content` may be up to
/// MAX_DIFF_BYTES, so leaking it per request is not an option, and `base` /
/// `head` must outlive the `defer`s that built them.
const PrDiffResult = struct {
    diff_content: []const u8,
    truncated: bool,
    base: []const u8,
    head: []const u8,

    fn deinit(self: PrDiffResult, allocator: std.mem.Allocator) void {
        allocator.free(self.diff_content);
        allocator.free(self.base);
        allocator.free(self.head);
    }
};

/// Check whether a CLI binary resolves on PATH (`gh` / `glab`).
/// Pure spawn probe: `cmd --version`, output discarded.
fn cliAvailable(allocator: std.mem.Allocator, io: std.Io, cmd: []const u8) bool {
    const res = std.process.run(allocator, io, .{ .argv = &.{ cmd, "--version" } }) catch return false;
    defer {
        allocator.free(res.stdout);
        allocator.free(res.stderr);
    }
    return res.term.exited == 0;
}

/// Run argv, return trimmed stdout on exit 0/1 (git diff uses exit 1
/// when differences exist), else the mapped error.
fn runGit(allocator: std.mem.Allocator, io: std.Io, argv: []const []const u8) ![]u8 {
    const res = std.process.run(allocator, io, .{ .argv = argv }) catch return error.DiffFailed;
    defer allocator.free(res.stderr);
    errdefer allocator.free(res.stdout);
    if (res.term.exited != 0 and res.term.exited != 1) return error.DiffFailed;
    return res.stdout;
}

/// Auto-detect the base branch: origin/main → origin/master → origin/develop
/// → "main" fallback.
fn detectBase(allocator: std.mem.Allocator, io: std.Io, path: []const u8) ![]const u8 {
    const bases = [_][]const u8{ "main", "master", "develop" };
    for (bases) |b| {
        var buf: [64]u8 = undefined;
        const origin_b = std.fmt.bufPrint(&buf, "origin/{s}", .{b}) catch continue;
        const probe = std.process.run(allocator, io, .{ .argv = &.{ "git", "-C", path, "rev-parse", "--verify", origin_b } }) catch continue;
        defer {
            allocator.free(probe.stdout);
            allocator.free(probe.stderr);
        }
        if (probe.term.exited == 0) return allocator.dupe(u8, b);
    }
    return allocator.dupe(u8, "main");
}

/// Current branch ("" when detached). Returns an OWNED string.
fn currentBranch(allocator: std.mem.Allocator, io: std.Io, path: []const u8) ![]const u8 {
    const res = std.process.run(allocator, io, .{ .argv = &.{ "git", "-C", path, "branch", "--show-current" } }) catch return allocator.dupe(u8, "");
    defer allocator.free(res.stderr);
    if (res.term.exited != 0) {
        allocator.free(res.stdout);
        return allocator.dupe(u8, "");
    }
    const trimmed = std.mem.trim(u8, res.stdout, " \n\r");
    if (trimmed.len == res.stdout.len) return res.stdout;
    defer allocator.free(res.stdout);
    return allocator.dupe(u8, trimmed);
}

/// GitHub refuses to serve the `/pulls/{n}` diff once a pull request
/// touches more than this many files, answering HTTP 406 (surfaced by
/// `gh pr diff` as `PullRequest.diff too_large` on a nonzero exit).
pub const FORGE_MAX_DIFF_FILES: u32 = 300;

/// Try the forge CLI (`gh pr diff` / `glab mr diff`). Returns null when the
/// CLI is absent, exits nonzero, or produced nothing usable — every case
/// where the caller must fall back to the git refspec.
fn tryForgeCli(
    allocator: std.mem.Allocator,
    io: std.Io,
    provider: pr_provider.PrProvider,
    normalized: []const u8,
) !?PrDiffResult {
    const ref = pr_provider.parsePrRef(normalized, provider) orelse return null;
    const number = ref.number orelse return null;
    var argv: [6][]const u8 = undefined;
    if (provider == .github) {
        argv = .{ "gh", "pr", "diff", number, "--repo", ref.repo_path };
    } else {
        argv = .{ "glab", "mr", "diff", number, "-R", ref.repo_path };
    }
    const res = std.process.run(allocator, io, .{ .argv = &argv }) catch return null;
    defer allocator.free(res.stderr);
    errdefer allocator.free(res.stdout);
    if (res.term.exited != 0) {
        allocator.free(res.stdout);
        return null;
    }
    const capped = try capDiff(allocator, res.stdout);
    errdefer allocator.free(capped.text);
    // The CLI reports no base/head (it diffs server-side); owned empties so
    // PrDiffResult.deinit can free all three unconditionally.
    const base = try allocator.dupe(u8, "");
    errdefer allocator.free(base);
    const head = try allocator.dupe(u8, "");
    return PrDiffResult{
        .diff_content = capped.text,
        .truncated = capped.truncated,
        .base = base,
        .head = head,
    };
}

/// Fetch the forge's well-known head ref over the repo's own `origin`
/// (`pull/N/head` on GitHub, `merge-requests/IID/head` on GitLab) and diff it
/// against the base.
fn fetchRefRange(
    allocator: std.mem.Allocator,
    io: std.Io,
    path: []const u8,
    number: []const u8,
    is_pr: bool,
    base_override: ?[]const u8,
) !PrDiffResult {
    // `+` forces the update.
    const refspec = if (is_pr)
        try std.fmt.allocPrint(allocator, "+pull/{s}/head:refs/pabrik-pr/{s}", .{ number, number })
    else
        try std.fmt.allocPrint(allocator, "+merge-requests/{s}/head:refs/pabrik-mr/{s}", .{ number, number });
    defer allocator.free(refspec);
    const local_ref = if (is_pr)
        try std.fmt.allocPrint(allocator, "refs/pabrik-pr/{s}", .{number})
    else
        try std.fmt.allocPrint(allocator, "refs/pabrik-mr/{s}", .{number});
    // NOT deferred-free: ownership moves into PrDiffResult.head.
    const fetch_argv: [6][]const u8 = .{ "git", "-C", path, "fetch", "origin", refspec };
    const fetch = std.process.run(allocator, io, .{ .argv = &fetch_argv }) catch return error.FetchFailed;
    defer {
        allocator.free(fetch.stdout);
        allocator.free(fetch.stderr);
    }
    if (fetch.term.exited != 0) {
        allocator.free(local_ref);
        return error.FetchFailed;
    }
    const base = if (base_override) |b|
        try allocator.dupe(u8, b)
    else
        try detectBase(allocator, io, path);
    const range = std.fmt.allocPrint(allocator, "{s}...{s}", .{ base, local_ref }) catch {
        allocator.free(base);
        allocator.free(local_ref);
        return error.OutOfMemory;
    };
    defer allocator.free(range);
    const diff_argv: [5][]const u8 = .{ "git", "-C", path, "diff", range };
    const diff = runGit(allocator, io, &diff_argv) catch {
        allocator.free(base);
        allocator.free(local_ref);
        return error.DiffFailed;
    };
    const capped = capDiff(allocator, diff) catch {
        allocator.free(base);
        allocator.free(local_ref);
        return error.OutOfMemory;
    };
    return .{ .diff_content = capped.text, .truncated = capped.truncated, .base = base, .head = local_ref };
}

/// Cap diff output at MAX_DIFF_BYTES. Consumes `owned`: returns it
/// whole when small, otherwise a duped prefix (original freed).
fn capDiff(allocator: std.mem.Allocator, owned: []u8) !struct { text: []const u8, truncated: bool } {
    if (owned.len <= MAX_DIFF_BYTES) return .{ .text = owned, .truncated = false };
    const prefix = try allocator.dupe(u8, owned[0..MAX_DIFF_BYTES]);
    allocator.free(owned);
    return .{ .text = prefix, .truncated = true };
}

fn useCase(
    allocator: std.mem.Allocator,
    io: std.Io,
    path: []const u8,
    pr_url: []const u8,
    provider_override: ?[]const u8,
    base_override: ?[]const u8,
    head_override: ?[]const u8,
) !PrDiffResult {
    // 1) Must be a git repo.
    {
        const check = std.process.run(allocator, io, .{ .argv = &.{ "git", "-C", path, "rev-parse", "--git-dir" } }) catch return error.NotARepository;
        defer {
            allocator.free(check.stdout);
            allocator.free(check.stderr);
        }
        if (check.term.exited != 0) return error.NotARepository;
    }

    const normalized = try pr_provider.normalizePrUrl(allocator, pr_url);
    defer allocator.free(normalized);

    const provider: pr_provider.PrProvider = if (provider_override) |o|
        pr_provider.PrProvider.fromString(o) orelse return error.DiffFailed
    else
        pr_provider.detectProvider(normalized);

    // github/gitlab need a parseable ref (number/IID).
    var number: []const u8 = "";
    if (provider != .generic) {
        const ref = pr_provider.parsePrRef(normalized, provider) orelse return error.DiffFailed;
        number = ref.number orelse return error.DiffFailed;
    }

    const strategy: DiffStrategy = switch (provider) {
        .github => resolveStrategy(.github, cliAvailable(allocator, io, "gh")),
        .gitlab => resolveStrategy(.gitlab, cliAvailable(allocator, io, "glab")),
        .generic => .git_local_range,
    };

    switch (strategy) {
        // The CLI is a fast path, not a guarantee: it exits nonzero on auth
        // failure AND on the forge's oversized-PR refusal (GitHub caps the PR
        // diff at FORGE_MAX_DIFF_FILES files).
        .gh_cli, .glab_cli => {
            if (try tryForgeCli(allocator, io, provider, normalized)) |cli_result| {
                return cli_result;
            }
            return fetchRefRange(allocator, io, path, number, provider == .github, base_override);
        },
        .git_fetch_pr_ref, .git_fetch_mr_ref => {
            return fetchRefRange(allocator, io, path, number, strategy == .git_fetch_pr_ref, base_override);
        },
        .git_local_range => {
            const base: []const u8 = if (base_override) |b|
                try allocator.dupe(u8, b)
            else
                try detectBase(allocator, io, path);
            errdefer allocator.free(base);
            const head: []const u8 = blk: {
                if (head_override) |h| break :blk try allocator.dupe(u8, h);
                // Detached HEAD reports "", which `git diff main...` cannot
                // resolve; fall back to the literal ref.
                const cb = try currentBranch(allocator, io, path);
                if (cb.len != 0) break :blk cb;
                allocator.free(cb);
                break :blk try allocator.dupe(u8, "HEAD");
            };
            errdefer allocator.free(head);
            const range = try std.fmt.allocPrint(allocator, "{s}...{s}", .{ base, head });
            defer allocator.free(range);
            const diff_argv: [5][]const u8 = .{ "git", "-C", path, "diff", range };
            const diff = try runGit(allocator, io, &diff_argv);
            const capped = try capDiff(allocator, diff);
            return .{ .diff_content = capped.text, .truncated = capped.truncated, .base = base, .head = head };
        },
    }
}

/// GET /api/git/pr/diff?path=<cwd>&pr_url=<url>[&provider=][&base=][&head=]
/// Returns the PR's full unified diff (1MB cap) for the right panel.
pub fn gitPrDiffHandler(ctx: gserverz.HttpContext, req: gserverz.HttpRequest, res: gserverz.HttpResponse) !gserverz.HttpResponse {
    const allocator = ctx.allocator;
    const io = ctx.io;

    const query = req.query;
    const path_param = query.get("path") orelse {
        return res.jsonResponse(.{ .status_code = 400, .data = try http_response.makeGitStatusErrorResponse(allocator, "Missing path parameter") });
    };
    const pr_url_param = query.get("pr_url") orelse {
        return res.jsonResponse(.{ .status_code = 400, .data = try http_response.makeGitStatusErrorResponse(allocator, "Missing pr_url parameter") });
    };
    if (pr_url_param.len == 0) {
        return res.jsonResponse(.{ .status_code = 400, .data = try http_response.makeGitStatusErrorResponse(allocator, "pr_url cannot be empty") });
    }
    const provider_param = query.get("provider");
    if (provider_param) |pv| {
        if (pv.len > 0 and pr_provider.PrProvider.fromString(pv) == null) {
            return res.jsonResponse(.{ .status_code = 400, .data = try http_response.makeGitStatusErrorResponse(allocator, "provider must be \"github\", \"gitlab\", or \"generic\"") });
        }
    }
    const base_param = query.get("base");
    const head_param = query.get("head");

    const result = useCase(allocator, io, path_param, pr_url_param, provider_param, base_param, head_param) catch |err| switch (err) {
        error.NotARepository => {
            return res.jsonResponse(.{ .status_code = 404, .data = try http_response.makeGitStatusErrorResponse(allocator, "not a git repository") });
        },
        error.FetchFailed => {
            return res.jsonResponse(.{ .status_code = 502, .data = try http_response.makeGitStatusErrorResponse(allocator, "failed to fetch PR diff from the forge CLI and from the repo's origin remote (check the PR URL and that origin can reach pull/N/head)") });
        },
        error.DiffFailed => {
            return res.jsonResponse(.{ .status_code = 502, .data = try http_response.makeGitStatusErrorResponse(allocator, "failed to compute PR diff (check base/head refs)") });
        },
        else => return err,
    };

    defer result.deinit(allocator);
    return res.jsonResponse(.{ .status_code = 200, .data = try makeGitPrDiffResponse(allocator, pr_url_param, result) });
}

pub const GitPrDiffResponse = struct {
    pr_url: []const u8,
    base: []const u8,
    head: []const u8,
    diff_content: []const u8,
    truncated: bool,
};

fn makeGitPrDiffResponse(allocator: std.mem.Allocator, pr_url: []const u8, result: PrDiffResult) ![]u8 {
    var buf = std.ArrayList(u8).empty;
    defer buf.deinit(allocator);

    const escapeString = struct {
        fn escape(a: std.mem.Allocator, s: []const u8) ![]u8 {
            var out = std.ArrayList(u8).empty;
            defer out.deinit(a);
            for (s) |c| {
                switch (c) {
                    '"' => try out.appendSlice(a, "\\\""),
                    '\\' => try out.appendSlice(a, "\\\\"),
                    '\n' => try out.appendSlice(a, "\\n"),
                    '\r' => try out.appendSlice(a, "\\r"),
                    '\t' => try out.appendSlice(a, "\\t"),
                    else => try out.append(a, c),
                }
            }
            return try out.toOwnedSlice(a);
        }
    }.escape;

    try buf.appendSlice(allocator, "{\"pr_url\":\"");
    const e_url = try escapeString(allocator, pr_url);
    defer allocator.free(e_url);
    try buf.appendSlice(allocator, e_url);
    try buf.appendSlice(allocator, "\", \"base\":\"");
    const e_base = try escapeString(allocator, result.base);
    defer allocator.free(e_base);
    try buf.appendSlice(allocator, e_base);
    try buf.appendSlice(allocator, "\", \"head\":\"");
    const e_head = try escapeString(allocator, result.head);
    defer allocator.free(e_head);
    try buf.appendSlice(allocator, e_head);
    try buf.appendSlice(allocator, "\", \"diff_content\":\"");
    const e_diff = try escapeString(allocator, result.diff_content);
    defer allocator.free(e_diff);
    try buf.appendSlice(allocator, e_diff);
    try buf.appendSlice(allocator, "\", \"truncated\":");
    try buf.appendSlice(allocator, if (result.truncated) "true" else "false");
    try buf.appendSlice(allocator, "}");

    return try buf.toOwnedSlice(allocator);
}

const testing = std.testing;

test "resolveStrategy picks CLI when present, fetch fallback otherwise" {
    try testing.expectEqual(DiffStrategy.gh_cli, resolveStrategy(.github, true));
    try testing.expectEqual(DiffStrategy.git_fetch_pr_ref, resolveStrategy(.github, false));
    try testing.expectEqual(DiffStrategy.glab_cli, resolveStrategy(.gitlab, true));
    try testing.expectEqual(DiffStrategy.git_fetch_mr_ref, resolveStrategy(.gitlab, false));
    try testing.expectEqual(DiffStrategy.git_local_range, resolveStrategy(.generic, true));
    try testing.expectEqual(DiffStrategy.git_local_range, resolveStrategy(.generic, false));
}
