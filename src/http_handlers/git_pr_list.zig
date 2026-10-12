//! `GET /api/git/pr/list` — the change requests of one repository, for the
//! kanban board's PR surface (`KanbanPrList.vue`).
//!
//! ## Why this is its own endpoint and not N calls to `/status`
//!
//! `/api/git/pr/status` answers "what is the state of THIS change request",
//! so it needs a ref. The board wants the opposite shape: every open PR/MR of
//! the board's repo, including the ones whose card was deleted, and there is
//! no way to enumerate those through `gh pr view`. `gh pr list` / `glab mr
//! list` is that enumeration, and it is a different command with a different
//! (search-backed) JSON field allow-list — hence a separate argv builder, a
//! separate parser, and a separate endpoint.
//!
//! ## What the answer is not
//!
//! `truncated: true` means the cap bound and there may be more rows. An empty
//! `changes` array means the FORGE said there are none — a CLI failure is a
//! 4xx/5xx with a sentence, never an empty list, because "no open pull
//! requests" and "we could not ask" are different facts and the UI renders
//! them differently.

const std = @import("std");
const http_response = @import("http_response.zig");
const pabrik_core = @import("pabrikcore");
const gserverz = pabrik_core.gserverz;
const pr_provider = pabrik_core.pr_provider;
const pr_cli = pabrik_core.pr_cli;
const run_captured = @import("helpers").run_captured;
// Provider resolution, the error-detail formatter and the state normalizer
// are shared with the status endpoint: two endpoints that disagreed about
// which forge a repo is on would list one forge's rows and close the other's.
const pr_status = @import("git_pr_status.zig");

/// A list is a read, so it gets the read budget — generous enough for a
/// cold GitHub search, bounded enough that a credential prompt cannot wedge
/// a worker-pool thread.
pub const LIST_TIMEOUT_MS: u32 = 20_000;

/// Per-stream capture cap. A page of 100 rows with long titles is ~60 KiB, so
/// this is more than an order of magnitude of headroom while still bounding a
/// CLI that decides to print a wall of text.
const MAX_CAPTURE_BYTES: usize = 1024 * 1024;

pub const DEFAULT_LIMIT: u32 = 30;
/// Anything above this is refused rather than clamped: a clamped page would
/// report `truncated` for a limit the caller never asked for, and the caller
/// would have no way to learn its parameter was ignored.
pub const MAX_LIMIT: u32 = 100;

const ListError = error{
    /// `path` is not inside a git repository.
    NotARepository,
    /// No forge CLI on PATH (or the forge has none).
    CliMissing,
    /// The CLI ran and failed, or answered something unparseable. `detail`
    /// carries its own words.
    FetchFailed,
};

/// The forge binaries. Injectable so tests point the whole path at fixture
/// scripts instead of real, authenticated CLIs.
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

fn listUseCase(
    allocator: std.mem.Allocator,
    io: std.Io,
    path: []const u8,
    state: pr_cli.ListState,
    limit: u32,
    provider_override: ?[]const u8,
    detail: *?[]u8,
) !http_response.GitPrListResponse {
    return listUseCaseWithPrograms(allocator, io, .{}, path, state, limit, provider_override, detail);
}

/// The whole read path: repo gate → provider → argv → spawn → parse.
///
/// `pub` so the functional suite can drive it against fixture scripts through
/// the same seam the status/merge paths expose.
pub fn listUseCaseWithPrograms(
    allocator: std.mem.Allocator,
    io: std.Io,
    programs: Programs,
    path: []const u8,
    state: pr_cli.ListState,
    limit: u32,
    provider_override: ?[]const u8,
    detail: *?[]u8,
) !http_response.GitPrListResponse {
    if (!isGitRepository(allocator, io, path)) return error.NotARepository;

    const provider = pr_status.resolveProvider(allocator, io, path, "", provider_override) catch |err| switch (err) {
        error.UnknownProvider => {
            pr_status.setFetchDetail(allocator, detail, "unknown provider (expected github, gitlab, or generic)");
            return error.FetchFailed;
        },
        error.UnsupportedProvider => {
            pr_status.setFetchDetail(allocator, detail, "the generic provider has no forge CLI, so its change requests cannot be listed (pass provider=github or provider=gitlab)");
            return error.FetchFailed;
        },
    };
    const cli = pr_cli.cliFor(provider) orelse return error.CliMissing;
    const prog = programs.forProvider(provider);
    if (prog.len == 0) return error.CliMissing;

    // `limit_buf` outlives the spawn because it lives here, in the caller's
    // frame — see the note on `listArgv`.
    var argv_buf: [pr_cli.list_argv_max][]const u8 = undefined;
    var limit_buf: [16]u8 = undefined;
    const argv = pr_cli.listArgv(&argv_buf, &limit_buf, provider, prog, state, limit) orelse return error.CliMissing;

    var res = run_captured.run(allocator, io, argv, .{
        .cwd = path,
        .max_output_bytes = MAX_CAPTURE_BYTES,
        .timeout_ms = LIST_TIMEOUT_MS,
    }) catch |err| switch (err) {
        // The CLI not being on PATH is the overwhelmingly common spawn
        // failure (the repo gate above already proved the directory exists),
        // and it is a 422 with a "install gh" sentence, not a 502.
        error.FileNotFound, error.AccessDenied, error.PermissionDenied, error.InvalidExe => return error.CliMissing,
        else => {
            var msg_buf: [160]u8 = undefined;
            const msg = std.fmt.bufPrint(&msg_buf, "failed to run {s} {s} list ({s})", .{ cli.program, cli.noun, @errorName(err) }) catch "failed to run the forge CLI";
            pr_status.setFetchDetail(allocator, detail, msg);
            return error.FetchFailed;
        },
    };
    defer res.deinit(allocator);

    if (res.timed_out) {
        const msg = std.fmt.allocPrint(allocator, "{s} {s} list timed out after {d}s", .{ cli.program, cli.noun, LIST_TIMEOUT_MS / 1000 }) catch "forge CLI list timed out";
        pr_status.setFetchDetail(allocator, detail, msg);
        return error.FetchFailed;
    }

    switch (res.term) {
        .exited => |code| {
            if (code != 0) {
                // The CLI's own words: an auth failure, a rate limit, a repo
                // it cannot resolve. Replacing that with a generic apology is
                // how a user never learns to run `gh auth login`.
                pr_status.setFetchDetail(allocator, detail, res.stderr);
                if (detail.* == null) {
                    var code_buf: [96]u8 = undefined;
                    const msg = std.fmt.bufPrint(&code_buf, "{s} {s} list exited with code {d} (no stderr)", .{ cli.program, cli.noun, code }) catch "forge CLI list failed (no stderr)";
                    pr_status.setFetchDetail(allocator, detail, msg);
                }
                return error.FetchFailed;
            }
        },
        else => {
            const msg = std.fmt.allocPrint(allocator, "{s} {s} list was killed before it finished", .{ cli.program, cli.noun }) catch "forge CLI list was killed";
            pr_status.setFetchDetail(allocator, detail, msg);
            return error.FetchFailed;
        },
    }

    const trimmed = std.mem.trim(u8, res.stdout, " \n\r\t");
    // Exit 0 with no stdout is an empty RESULT, not a failure. The text mode
    // of both CLIs prints prose when there is something to say (which the
    // parsers below reject loudly, so a mis-passed JSON flag cannot masquerade
    // as an empty repo); silence on the JSON flag means nothing matched.
    if (trimmed.len == 0) {
        return .{
            .provider = try allocator.dupe(u8, provider.toString()),
            .program = try allocator.dupe(u8, cli.program),
            .state = try allocator.dupe(u8, state.toString()),
            .changes = &.{},
            .truncated = false,
            .detail = try allocator.dupe(u8, "the forge CLI printed no output, which reads as no matching change requests"),
        };
    }

    const items = switch (provider) {
        .github => try parseGithubList(allocator, trimmed, cli, detail),
        .gitlab => try parseGlabList(allocator, trimmed, cli, detail),
        .generic => unreachable,
    };

    return .{
        .provider = try allocator.dupe(u8, provider.toString()),
        .program = try allocator.dupe(u8, cli.program),
        .state = try allocator.dupe(u8, state.toString()),
        .changes = items,
        // Exactly `limit` rows means the page may be cut short. Fewer means we
        // saw everything, however large "everything" was.
        .truncated = items.len == limit,
        .detail = "",
    };
}

/// `git -C <path> rev-parse --git-dir` exits 0 only inside a repository.
///
/// KNOWN LIMITATION, shared with `git_pr_status.zig`: git honours an ambient
/// `GIT_DIR` / `GIT_WORK_TREE`, so a pabrik started from inside a git hook
/// would answer "yes" for any path. Passing an explicit `environ_map` to this
/// probe is the fix, tracked there rather than duplicated here.
fn isGitRepository(allocator: std.mem.Allocator, io: std.Io, path: []const u8) bool {
    const check = std.process.run(allocator, io, .{ .argv = &.{ "git", "-C", path, "rev-parse", "--git-dir" } }) catch return false;
    defer {
        allocator.free(check.stdout);
        allocator.free(check.stderr);
    }
    return check.term.exited == 0;
}

/// `gh pr list --json <fields>` rows. The shape is pinned by the field list we
/// pass (`pr_cli.GH_LIST_JSON_FIELDS`), so — unlike the glab parser — a rigid
/// struct is correct here: a renamed field would mean gh changed its contract,
/// not that our flag drifted.
const GhPrRow = struct {
    number: i64 = 0,
    title: []const u8 = "",
    url: []const u8 = "",
    state: []const u8 = "",
    isDraft: bool = false,
    headRefName: []const u8 = "",
    baseRefName: []const u8 = "",
    /// `null` on a PR whose author account was deleted; `?` keeps that from
    /// failing the whole page.
    author: ?GhAuthor = null,
    updatedAt: []const u8 = "",
};

const GhAuthor = struct { login: []const u8 = "" };

fn parseGithubList(
    allocator: std.mem.Allocator,
    trimmed: []const u8,
    cli: pr_cli.Cli,
    detail: *?[]u8,
) ![]http_response.GitPrListItem {
    const rows = std.json.parseFromSliceLeaky([]const GhPrRow, allocator, trimmed, .{ .ignore_unknown_fields = true }) catch {
        setParseDetail(allocator, detail, cli, trimmed.len);
        return error.FetchFailed;
    };
    const out = try allocator.alloc(http_response.GitPrListItem, rows.len);
    for (rows, 0..) |r, i| {
        out[i] = .{
            .number = r.number,
            .title = try allocator.dupe(u8, r.title),
            .url = try allocator.dupe(u8, r.url),
            .state = try allocator.dupe(u8, pr_status.normalizeStatus(r.state)),
            .is_draft = r.isDraft,
            .head_ref = try allocator.dupe(u8, r.headRefName),
            .base_ref = try allocator.dupe(u8, r.baseRefName),
            .author = try allocator.dupe(u8, if (r.author) |a| a.login else ""),
            .updated_at = try allocator.dupe(u8, r.updatedAt),
        };
    }
    return out;
}

/// `glab mr list --output json` rows.
///
/// Alias-tolerant on purpose, like `GlabMrView` in `git_pr_status.zig`:
/// `glab` has no `--json <fields>` flag, so it renders whatever the installed
/// version renders, and the keys have moved across releases (the identifier
/// has been `iid` and `id`; draft has been `draft` and `work_in_progress`).
/// A rigid struct here means a routine `glab` upgrade 502s the whole list for
/// every GitLab user.
///
/// IMPLEMENTATION GATE: these key names were NOT verified against a live
/// GitLab (this machine has no GitLab token — `glab auth status` is a 401), so
/// the aliases above are the documented ones plus the ones `GlabMrView` already
/// relies on. The response is honest either way — a field that moved renders as
/// an empty string on that row, never as a wrong value — and the first person
/// who runs this against a real GitLab MR should tighten the aliases to what it
/// actually answered.
const GlabMrRow = struct {
    iid: i64 = 0,
    id: i64 = 0,
    title: []const u8 = "",
    web_url: []const u8 = "",
    url: []const u8 = "",
    state: []const u8 = "",
    draft: bool = false,
    work_in_progress: bool = false,
    source_branch: []const u8 = "",
    target_branch: []const u8 = "",
    updated_at: []const u8 = "",
    author: std.json.Value = .null,
};

fn parseGlabList(
    allocator: std.mem.Allocator,
    trimmed: []const u8,
    cli: pr_cli.Cli,
    detail: *?[]u8,
) ![]http_response.GitPrListItem {
    // `parseFromSlice`, deliberately NOT the Leaky variant: `GlabMrRow` holds
    // a `std.json.Value` (the author object), and a Value duplicates itself
    // into a parser-owned arena that the Leaky variant has no `deinit` to hand
    // back. Every string below is copied into the caller's arena before this
    // returns, so the `defer` is safe.
    var parsed = std.json.parseFromSlice([]const GlabMrRow, allocator, trimmed, .{ .ignore_unknown_fields = true }) catch {
        setParseDetail(allocator, detail, cli, trimmed.len);
        return error.FetchFailed;
    };
    defer parsed.deinit();

    const rows = parsed.value;
    const out = try allocator.alloc(http_response.GitPrListItem, rows.len);
    for (rows, 0..) |r, i| {
        out[i] = .{
            // `iid` is the per-project number users see in the URL; `id` is
            // the global one. Prefer the one on the MR page.
            .number = if (r.iid != 0) r.iid else r.id,
            .title = try allocator.dupe(u8, r.title),
            .url = try allocator.dupe(u8, pr_status.firstNonEmpty(&.{ r.web_url, r.url })),
            .state = try allocator.dupe(u8, pr_status.normalizeStatus(r.state)),
            .is_draft = r.draft or r.work_in_progress,
            .head_ref = try allocator.dupe(u8, r.source_branch),
            .base_ref = try allocator.dupe(u8, r.target_branch),
            .author = try allocator.dupe(u8, pr_status.glabAuthorName(r.author)),
            .updated_at = try allocator.dupe(u8, r.updated_at),
        };
    }
    return out;
}

/// "invalid JSON from <prog> <noun> list (N bytes stdout)" — names the CLI
/// that produced it, because the overwhelmingly common cause is a version
/// whose JSON flag we did not pass (a text table parsed as JSON).
fn setParseDetail(allocator: std.mem.Allocator, detail: *?[]u8, cli: pr_cli.Cli, raw_len: usize) void {
    var buf: [256]u8 = undefined;
    const msg = std.fmt.bufPrint(&buf, "invalid JSON from {s} {s} list ({d} bytes stdout)", .{ cli.program, cli.noun, raw_len }) catch "invalid JSON from the forge CLI";
    pr_status.setFetchDetail(allocator, detail, msg);
}

/// `limit` from the query string: absent/empty → `DEFAULT_LIMIT`, anything
/// not in 1..=MAX_LIMIT → null (→ 400). No clamping: see `MAX_LIMIT`.
fn parseLimit(raw: ?[]const u8) ?u32 {
    const s = raw orelse return DEFAULT_LIMIT;
    const trimmed = std.mem.trim(u8, s, " \t");
    if (trimmed.len == 0) return DEFAULT_LIMIT;
    const n = std.fmt.parseInt(u32, trimmed, 10) catch return null;
    if (n == 0 or n > MAX_LIMIT) return null;
    return n;
}

/// GET /api/git/pr/list?path=<repo>[&state=open|closed|merged|all][&limit=30][&provider=github]
///
/// The kanban board's PR surface: every open change request of the board's
/// repo, not just the one attached to a session. Errors name the program the
/// user would have to fix ("gh", never a generic "the forge").
pub fn gitPrListHandler(ctx: gserverz.HttpContext, req: gserverz.HttpRequest, res: gserverz.HttpResponse) !gserverz.HttpResponse {
    const allocator = ctx.allocator;
    const io = ctx.io;
    const query = req.query;

    const path_param = query.get("path") orelse {
        return res.jsonResponse(.{ .status_code = 400, .data = try http_response.makeErrorResponse(allocator, .{ .@"error" = "Missing path parameter" }) });
    };
    if (path_param.len == 0) {
        return res.jsonResponse(.{ .status_code = 400, .data = try http_response.makeErrorResponse(allocator, .{ .@"error" = "path cannot be empty" }) });
    }

    const state = pr_cli.ListState.fromString(query.get("state") orelse "") orelse {
        return res.jsonResponse(.{ .status_code = 400, .data = try http_response.makeErrorResponse(allocator, .{ .@"error" = "state must be \"open\", \"closed\", \"merged\", or \"all\"" }) });
    };

    const limit = parseLimit(query.get("limit")) orelse {
        return res.jsonResponse(.{ .status_code = 400, .data = try http_response.makeErrorResponse(allocator, .{ .@"error" = "limit must be an integer between 1 and 100" }) });
    };

    const provider_param = query.get("provider");
    if (provider_param) |pv| {
        if (pv.len > 0 and pr_provider.PrProvider.fromString(pv) == null) {
            return res.jsonResponse(.{ .status_code = 400, .data = try http_response.makeErrorResponse(allocator, .{ .@"error" = "provider must be \"github\", \"gitlab\", or \"generic\"" }) });
        }
    }

    var detail: ?[]u8 = null;
    const result = listUseCase(allocator, io, path_param, state, limit, provider_param, &detail) catch |err| switch (err) {
        error.NotARepository => {
            return res.jsonResponse(.{ .status_code = 404, .data = try http_response.makeErrorResponse(allocator, .{ .@"error" = "not a git repository" }) });
        },
        error.CliMissing => {
            // Name the CLI for THIS repo's forge: a GitLab repo with no glab
            // must not be told to install gh.
            const cli = handlerCli(allocator, io, path_param, provider_param);
            const msg = try std.fmt.allocPrint(allocator, "{s} CLI not found on PATH (install {s} to list {s}s)", .{ cli.program, cli.program, cli.label });
            return res.jsonResponse(.{ .status_code = 422, .data = try http_response.makeErrorResponse(allocator, .{ .@"error" = msg }) });
        },
        error.FetchFailed => {
            const cli = handlerCli(allocator, io, path_param, provider_param);
            const msg = if (detail) |d|
                try std.fmt.allocPrint(allocator, "failed to list {s}s: {s}", .{ cli.label, d })
            else
                try std.fmt.allocPrint(allocator, "failed to list {s}s (check {s} auth and the repo's remote)", .{ cli.label, cli.program });
            return res.jsonResponse(.{ .status_code = 502, .data = try http_response.makeErrorResponse(allocator, .{ .@"error" = msg }) });
        },
        // Allocation failure and anything else the use case can still raise
        // (only OOM today): let the server's error path answer rather than
        // inventing a status for it here.
        else => return err,
    };

    return res.jsonResponse(.{ .status_code = 200, .data = try http_response.makeGitPrListResponse(allocator, result) });
}

/// Best-effort provider, used ONLY to word an error message. A list request
/// carries no `pr` argument, so the resolution order is the override then the
/// repo's own origin remote — the same order the use case used.
fn handlerCli(
    allocator: std.mem.Allocator,
    io: std.Io,
    path: []const u8,
    provider_override: ?[]const u8,
) pr_cli.Cli {
    const p = pr_status.resolveProvider(allocator, io, path, "", provider_override) catch return pr_cli.GH_CLI;
    return pr_cli.cliFor(p) orelse pr_cli.GH_CLI;
}

// ============================================================================
// Tests
// ============================================================================

const testing = std.testing;
const builtin_t = @import("builtin");

fn skipOnWindows() bool {
    return builtin_t.os.tag == .windows;
}

/// A throwaway directory plus executable fixture scripts — the same shape the
/// `git_pr_create.zig` / `git_pr_status.zig` suites use, so the whole path
/// (argv → spawn → capture → parse) runs with no real `gh` on PATH and no
/// network.
const Fixture = struct {
    tmp: std.testing.TmpDir,
    root: []u8,
    allocator: std.mem.Allocator,

    fn init(allocator: std.mem.Allocator) !Fixture {
        var tmp = std.testing.tmpDir(.{});
        errdefer tmp.cleanup();
        var buf: [512]u8 = undefined;
        const root = try tmp.dir.realPath(testing.io, &buf);
        return .{ .tmp = tmp, .root = try allocator.dupe(u8, buf[0..root]), .allocator = allocator };
    }

    fn deinit(self: *Fixture) void {
        self.tmp.cleanup();
        self.allocator.free(self.root);
    }

    fn writeExec(self: *Fixture, name: []const u8, script: []const u8) ![]u8 {
        try self.tmp.dir.writeFile(testing.io, .{ .sub_path = name, .data = script });
        if (!skipOnWindows()) try self.tmp.dir.setFilePermissions(testing.io, name, .executable_file, .{});
        return std.fmt.allocPrint(self.allocator, "{s}/{s}", .{ self.root, name });
    }
};

/// A git repo inside the fixture (the use case gates on `rev-parse`).
fn makeGitRepo(fx: *Fixture) ![]u8 {
    const a = fx.allocator;
    const repo = try std.fmt.allocPrint(a, "{s}/repo", .{fx.root});
    var init = run_captured.run(a, testing.io, &.{ "git", "init", "-q", "-b", "main", repo }, .{ .timeout_ms = 30_000 }) catch return error.SkipZigTest;
    defer init.deinit(a);
    if (init.term.exited != 0) return error.SkipZigTest;
    return repo;
}

/// A `gh`/`glab` stand-in that records its argv and prints `payload`.
fn scriptPrinting(fx: *Fixture, name: []const u8, argv_file: []const u8, payload: []const u8) ![]u8 {
    return fx.writeExec(name, try std.fmt.allocPrint(fx.allocator,
        "#!/bin/sh\nfor a in \"$@\"; do echo \"$a\"; done > '{s}'\ncat <<'JSONEOF'\n{s}\nJSONEOF\n",
        .{ argv_file, payload },
    ));
}

test "parseLimit: default, explicit, and the values it refuses" {
    try testing.expectEqual(DEFAULT_LIMIT, parseLimit(null).?);
    try testing.expectEqual(DEFAULT_LIMIT, parseLimit("").?);
    try testing.expectEqual(@as(u32, 7), parseLimit("7").?);
    try testing.expectEqual(MAX_LIMIT, parseLimit("100").?);
    // Refused rather than clamped: a silent clamp would report `truncated`
    // for a limit nobody asked for.
    try testing.expect(parseLimit("0") == null);
    try testing.expect(parseLimit("101") == null);
    try testing.expect(parseLimit("-1") == null);
    try testing.expect(parseLimit("abc") == null);
    try testing.expect(parseLimit("3.5") == null);
}

test "parseGithubList maps rows, normalizes state, and tolerates a null author" {
    const a = testing.allocator;
    const raw =
        \\[{"number":909,"title":"fix(settings): remove redundant workspace-name box","url":"https://github.com/ginwa123/pabrik/pull/909","state":"OPEN","isDraft":false,"headRefName":"worktree/why-theres-a-box","baseRefName":"main","author":{"login":"ginwa123"},"updatedAt":"2026-10-12T06:34:01Z"},
        \\ {"number":788,"title":"fix(windows-ci)","url":"https://github.com/ginwa123/pabrik/pull/788","state":"CLOSED","isDraft":true,"headRefName":"worktree/fix-windows-ci","baseRefName":"main","author":null,"updatedAt":"2026-10-05T00:00:00Z"}]
    ;
    var detail: ?[]u8 = null;
    const rows = try parseGithubList(a, raw, pr_cli.GH_CLI, &detail);
    defer {
        for (rows) |r| {
            a.free(r.title);
            a.free(r.url);
            a.free(r.state);
            a.free(r.head_ref);
            a.free(r.base_ref);
            a.free(r.author);
            a.free(r.updated_at);
        }
        a.free(rows);
    }
    try testing.expectEqual(@as(usize, 2), rows.len);
    try testing.expectEqual(@as(i64, 909), rows[0].number);
    try testing.expectEqualStrings("open", rows[0].state);
    try testing.expectEqualStrings("ginwa123", rows[0].author);
    try testing.expectEqualStrings("worktree/why-theres-a-box", rows[0].head_ref);
    try testing.expect(!rows[0].is_draft);
    // A deleted author account must not fail the page, and CLOSED must not
    // arrive at the UI as the raw forge spelling.
    try testing.expectEqualStrings("", rows[1].author);
    try testing.expectEqualStrings("closed", rows[1].state);
    try testing.expect(rows[1].is_draft);
    try testing.expect(detail == null);
}

test "parseGithubList rejects a payload that is not JSON, naming the CLI" {
    const a = testing.allocator;
    var detail: ?[]u8 = null;
    // What a gh that ignored our JSON flag prints: a text table.
    const res = parseGithubList(a, "Showing 3 of 3 open pull requests", pr_cli.GH_CLI, &detail);
    try testing.expectError(error.FetchFailed, res);
    const d = detail orelse return error.NoDetail;
    defer a.free(d);
    try testing.expect(std.mem.indexOf(u8, d, "gh pr list") != null);
    try testing.expect(std.mem.indexOf(u8, d, "invalid JSON") != null);
}

test "parseGithubList treats an empty array as zero rows, not as a failure" {
    const a = testing.allocator;
    var detail: ?[]u8 = null;
    const rows = try parseGithubList(a, "[]", pr_cli.GH_CLI, &detail);
    try testing.expectEqual(@as(usize, 0), rows.len);
}

test "parseGlabList reads the iid/web_url spelling and the draft aliases" {
    const a = testing.allocator;
    const raw =
        \\[{"iid":7,"id":99123,"title":"feat(secrets): seal values","web_url":"https://gitlab.com/g/s/r/-/merge_requests/7","state":"opened","work_in_progress":true,"source_branch":"worktree/secrets","target_branch":"main","updated_at":"2026-10-11T12:00:00Z","author":{"username":"ginwa123","name":"gilang"}},
        \\ {"id":99124,"title":"docs(secrets): plan","url":"https://gitlab.com/g/s/r/-/merge_requests/8","state":"merged","draft":false,"source_branch":"worktree/plan","target_branch":"main","updated_at":"2026-10-10T12:00:00Z","author":"bare-string-author"}]
    ;
    var detail: ?[]u8 = null;
    const rows = try parseGlabList(a, raw, pr_cli.GLAB_CLI, &detail);
    defer {
        for (rows) |r| {
            a.free(r.title);
            a.free(r.url);
            a.free(r.state);
            a.free(r.head_ref);
            a.free(r.base_ref);
            a.free(r.author);
            a.free(r.updated_at);
        }
        a.free(rows);
    }
    try testing.expectEqual(@as(usize, 2), rows.len);
    try testing.expectEqual(@as(i64, 7), rows[0].number);
    // `opened` is GitLab's spelling of open — the UI switches on "open".
    try testing.expectEqualStrings("open", rows[0].state);
    try testing.expect(rows[0].is_draft);
    try testing.expectEqualStrings("https://gitlab.com/g/s/r/-/merge_requests/7", rows[0].url);
    try testing.expectEqualStrings("ginwa123", rows[0].author);
    // Falls back to `id` when `iid` is absent, to `url` when `web_url` is,
    // and to a bare-string author — three aliases in one row.
    try testing.expectEqual(@as(i64, 99124), rows[1].number);
    try testing.expectEqualStrings("https://gitlab.com/g/s/r/-/merge_requests/8", rows[1].url);
    try testing.expectEqualStrings("merged", rows[1].state);
    try testing.expectEqualStrings("bare-string-author", rows[1].author);
}

test "list: github asks by state and limit, and the recorded argv says so" {
    if (skipOnWindows()) return error.SkipZigTest;
    const a = testing.allocator;
    var fx = try Fixture.init(a);
    defer fx.deinit();
    const repo = try makeGitRepo(&fx);
    defer a.free(repo);

    const argv_file = try std.fmt.allocPrint(a, "{s}/argv", .{fx.root});
    defer a.free(argv_file);
    const payload =
        \\[{"number":909,"title":"T","url":"https://github.com/a/b/pull/909","state":"OPEN","isDraft":false,"headRefName":"worktree/x","baseRefName":"main","author":{"login":"me"},"updatedAt":"2026-10-12T06:34:01Z"}]
    ;
    const gh = try scriptPrinting(&fx, "gh", argv_file, payload);
    defer a.free(gh);

    var detail: ?[]u8 = null;
    const out = try listUseCaseWithPrograms(a, testing.io, .{ .gh = gh }, repo, .closed, 5, "github", &detail);
    defer {
        a.free(out.provider);
        a.free(out.program);
        a.free(out.state);
        for (out.changes) |r| {
            a.free(r.title);
            a.free(r.url);
            a.free(r.state);
            a.free(r.head_ref);
            a.free(r.base_ref);
            a.free(r.author);
            a.free(r.updated_at);
        }
        a.free(out.changes);
    }

    try testing.expectEqualStrings("github", out.provider);
    try testing.expectEqualStrings("gh", out.program);
    try testing.expectEqualStrings("closed", out.state);
    try testing.expectEqual(@as(usize, 1), out.changes.len);
    // One row came back for a limit of 5, so the page is necessarily complete.
    try testing.expect(!out.truncated);
    try testing.expectEqualStrings("open", out.changes[0].state);

    const recorded = try std.Io.Dir.cwd().readFileAlloc(testing.io, argv_file, a, .limited(64 * 1024));
    defer a.free(recorded);
    try testing.expect(std.mem.indexOf(u8, recorded, "pr\nlist\n--state\nclosed\n--limit\n5\n--json\n") != null);
}

test "list: a full page reports truncated, and an empty stdout is an empty result" {
    if (skipOnWindows()) return error.SkipZigTest;
    const a = testing.allocator;
    var fx = try Fixture.init(a);
    defer fx.deinit();
    const repo = try makeGitRepo(&fx);
    defer a.free(repo);

    const argv_file = try std.fmt.allocPrint(a, "{s}/argv", .{fx.root});
    defer a.free(argv_file);

    // Exactly `limit` rows: we cannot know whether more exist.
    const two = try scriptPrinting(&fx, "gh", argv_file,
        \\[{"number":1,"title":"a","url":"u","state":"OPEN","isDraft":false,"headRefName":"b1","baseRefName":"main","author":{"login":"me"},"updatedAt":""},
        \\ {"number":2,"title":"b","url":"u","state":"OPEN","isDraft":false,"headRefName":"b2","baseRefName":"main","author":{"login":"me"},"updatedAt":""}]
    );
    defer a.free(two);

    var detail: ?[]u8 = null;
    const full = try listUseCaseWithPrograms(a, testing.io, .{ .gh = two }, repo, .open, 2, "github", &detail);
    try testing.expect(full.truncated);
    try testing.expectEqual(@as(usize, 2), full.changes.len);

    // A CLI that prints nothing on the JSON flag exited cleanly with nothing
    // to report — an empty list with a note, never an error.
    const silent = try fx.writeExec("gh-silent", "#!/bin/sh\nexit 0\n");
    defer a.free(silent);
    var detail2: ?[]u8 = null;
    const none = try listUseCaseWithPrograms(a, testing.io, .{ .gh = silent }, repo, .open, 30, "github", &detail2);
    try testing.expectEqual(@as(usize, 0), none.changes.len);
    try testing.expect(!none.truncated);
    try testing.expect(none.detail.len > 0);
}

test "list: a failing CLI surfaces its own stderr rather than an empty list" {
    if (skipOnWindows()) return error.SkipZigTest;
    const a = testing.allocator;
    var fx = try Fixture.init(a);
    defer fx.deinit();
    const repo = try makeGitRepo(&fx);
    defer a.free(repo);

    const fail = try fx.writeExec("gh-fail", "#!/bin/sh\necho 'To get started with GitHub CLI, please run: gh auth login' >&2\nexit 4\n");
    defer a.free(fail);

    var detail: ?[]u8 = null;
    const res = listUseCaseWithPrograms(a, testing.io, .{ .gh = fail }, repo, .open, 30, "github", &detail);
    try testing.expectError(error.FetchFailed, res);
    const d = detail orelse return error.NoDetail;
    defer a.free(d);
    try testing.expect(std.mem.indexOf(u8, d, "gh auth login") != null);
}

test "list: a missing CLI is CliMissing (422), not a fetch failure" {
    if (skipOnWindows()) return error.SkipZigTest;
    const a = testing.allocator;
    var fx = try Fixture.init(a);
    defer fx.deinit();
    const repo = try makeGitRepo(&fx);
    defer a.free(repo);

    var detail: ?[]u8 = null;
    const res = listUseCaseWithPrograms(a, testing.io, .{ .gh = "/pabrik/no/such/gh" }, repo, .open, 30, "github", &detail);
    try testing.expectError(error.CliMissing, res);
}

test "list: a non-repository path is refused before any CLI runs" {
    const a = testing.allocator;
    var fx = try Fixture.init(a);
    defer fx.deinit();
    var detail: ?[]u8 = null;
    const res = listUseCaseWithPrograms(a, testing.io, .{}, fx.root, .open, 30, "github", &detail);
    try testing.expectError(error.NotARepository, res);
}

test "list: the generic provider has no CLI, and says so instead of an empty list" {
    if (skipOnWindows()) return error.SkipZigTest;
    const a = testing.allocator;
    var fx = try Fixture.init(a);
    defer fx.deinit();
    const repo = try makeGitRepo(&fx);
    defer a.free(repo);

    var detail: ?[]u8 = null;
    const res = listUseCaseWithPrograms(a, testing.io, .{}, repo, .open, 30, "generic", &detail);
    try testing.expectError(error.FetchFailed, res);
    const d = detail orelse return error.NoDetail;
    defer a.free(d);
    try testing.expect(std.mem.indexOf(u8, d, "generic provider has no forge CLI") != null);
}
