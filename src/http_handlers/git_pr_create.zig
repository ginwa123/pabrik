const std = @import("std");
const http_response = @import("http_response.zig");
const pabrik_core = @import("pabrikcore");
const gserverz = pabrik_core.gserverz;
const pr_provider = pabrik_core.pr_provider;
const pr_cli = pabrik_core.pr_cli;
const run_captured = @import("helpers").run_captured;

/// The `gh` binary. See `git_pr_status.zig` for the shared constants.
const GH_PROGRAM = "gh";

/// Wall-clock budget for one `gh pr create`. Creating a PR uploads a
/// branch, so this is more generous than the read-only `pr view` budget
/// — but still bounded, so a credential prompt can't wedge a worker.
const GH_TIMEOUT_MS: u32 = 60_000;

/// Per-stream capture cap for the PR URL / gh error text.
const MAX_CAPTURE_BYTES: usize = 64 * 1024;

/// Outcome of running `gh pr create` in a worktree.
const GhStatus = enum { success, gh_failed };

const CreatePullRequestResult = struct {
    status: GhStatus,
    /// Populated on success (the PR URL `gh` printed on stdout, trimmed).
    /// Empty on failure.
    pr_url: []const u8,
    /// Populated on failure (the trimmed `gh` stderr, or a synthesized
    /// message like "FileNotFound (is the gh CLI installed and on PATH?)"
    /// when spawn itself failed). Empty on success.
    stderr: []const u8,
};

/// Use case — spawn `gh pr create` in the worktree directory and capture the
/// result.
fn createPullRequestUseCase(
    allocator: std.mem.Allocator,
    io: std.Io,
    provider: pr_provider.PrProvider,
    worktree_path: []const u8,
    base: []const u8,
    title: []const u8,
    body: []const u8,
) !CreatePullRequestResult {
    // The program MUST be derived from the provider.
    const cli = pr_cli.cliFor(provider) orelse return ghFailed(allocator, "the generic provider has no forge CLI, so a pull/merge request cannot be created");
    return createPullRequestUseCaseWith(allocator, io, cli.program, provider, worktree_path, base, title, body);
}

fn createPullRequestUseCaseWith(
    allocator: std.mem.Allocator,
    io: std.Io,
    prog: []const u8,
    provider: pr_provider.PrProvider,
    worktree_path: []const u8,
    base: []const u8,
    title: []const u8,
    body: []const u8,
) !CreatePullRequestResult {
    const cli = pr_cli.cliFor(provider) orelse return ghFailed(allocator, "the generic provider has no forge CLI, so a pull/merge request cannot be created");

    // `glab mr create` does not infer the source branch the way `gh pr
    // create` infers it from the worktree checkout, and it must be told
    // explicitly.
    var source_branch: ?[]u8 = null;
    // FUNCTION scope on purpose.
    defer if (source_branch) |b| allocator.free(b);
    if (provider == .gitlab) {
        source_branch = currentBranch(allocator, io, worktree_path);
        if (source_branch == null) {
            return ghFailed(allocator, "could not determine the current branch in the worktree, which glab mr create needs as --source-branch");
        }
    }

    var argv_buf: [pr_cli.create_argv_max][]const u8 = undefined;
    const argv = pr_cli.createArgv(&argv_buf, provider, prog, base, source_branch orelse "", title, body) orelse
        return ghFailed(allocator, "could not build the create command for this provider");

    // stdout + stderr are captured concurrently and capped; the child
    // is killed + reaped if it outlives the deadline, so a `gh` stuck
    // on a credential prompt can't wedge a worker-pool thread forever.
    var res = run_captured.run(allocator, io, argv, .{
        .cwd = worktree_path,
        .max_output_bytes = MAX_CAPTURE_BYTES,
        .timeout_ms = GH_TIMEOUT_MS,
    }) catch |err| {
        // Spawn-time failure (CLI not installed, perm denied, etc).
        // Synthesize a stderr message so the handler can return it verbatim.
        var msg_buf: [192]u8 = undefined;
        const msg = std.fmt.bufPrint(&msg_buf, "{s} (is the {s} CLI installed and on PATH?)", .{ @errorName(err), cli.program }) catch "forge CLI spawn failed";
        return ghFailed(allocator, msg);
    };
    defer res.deinit(allocator);

    if (res.timed_out) {
        return ghFailed(allocator, std.fmt.allocPrint(allocator, "{s} {s} create timed out", .{ cli.program, cli.noun }) catch "create timed out");
    }

    switch (res.term) {
        .exited => |code| {
            if (code != 0) {
                // Surface the CLI error verbatim so the user can debug
                // (e.g. "no commits between origin/main and worktree/feature-x").
                return ghFailed(allocator, std.mem.trim(u8, res.stderr, " \n\r"));
            }
        },
        .signal => return ghFailed(allocator, std.fmt.allocPrint(allocator, "{s} killed by signal", .{cli.program}) catch "killed by signal"),
        else => return ghFailed(allocator, std.fmt.allocPrint(allocator, "{s} terminated abnormally", .{cli.program}) catch "terminated abnormally"),
    }

    // The CLI prints the PR/MR URL on stdout, but NOT always on its own:
    // `glab mr create` prefixes a "Creating merge request for <branch> on
    // <host>…" banner before the link.
    return .{
        .status = .success,
        .pr_url = allocator.dupe(u8, pr_cli.extractCreatedUrl(res.stdout)) catch "",
        .stderr = "",
    };
}

/// The branch checked out in `path`, OWNED by `allocator` (the caller must
/// free it), or null when it cannot be determined — detached HEAD, not a
/// repo, git missing.
fn currentBranch(allocator: std.mem.Allocator, io: std.Io, path: []const u8) ?[]u8 {
    const res = std.process.run(allocator, io, .{ .argv = &.{ "git", "-C", path, "branch", "--show-current" } }) catch return null;
    defer {
        allocator.free(res.stdout);
        allocator.free(res.stderr);
    }
    if (res.term.exited != 0) return null;
    const trimmed = std.mem.trim(u8, res.stdout, " \n\r");
    if (trimmed.len == 0) return null;
    return allocator.dupe(u8, trimmed) catch null;
}

/// `.gh_failed` result whose `stderr` is a copy of `msg` in the request
/// arena, so the caller can free `msg` (or pass a borrowed literal)
/// without a use-after-free in the HTTP response.
fn ghFailed(allocator: std.mem.Allocator, msg: []const u8) CreatePullRequestResult {
    return .{
        .status = .gh_failed,
        .pr_url = "",
        .stderr = allocator.dupe(u8, msg) catch "gh pr create failed",
    };
}

/// HTTP handler for `POST /api/git/pr`.
pub fn gitPrCreateHandler(ctx: gserverz.HttpContext, req: gserverz.HttpRequest, res: gserverz.HttpResponse) !gserverz.HttpResponse {
    const allocator = ctx.allocator;

    // Parse JSON body using the Leaky variant — see memory
    // pabrik-http-handler-thin-wrapper-pattern.md.
    const Body = struct {
        worktree_path: []const u8 = "",
        base: []const u8 = "main",
        title: []const u8 = "",
        body: []const u8 = "",
        /// Which forge to open on. "" = auto-detect from the worktree's
        /// `origin` remote, falling back to GitHub. Optional so every
        /// existing GitHub caller keeps working unchanged.
        provider: []const u8 = "",
    };
    const parsed = std.json.parseFromSliceLeaky(Body, allocator, req.body, .{}) catch {
        return res.jsonResponse(.{ .status_code = 400, .data = try http_response.makeErrorResponse(allocator, .{ .@"error" = "Invalid JSON body" }) });
    };

    if (parsed.worktree_path.len == 0) {
        return res.jsonResponse(.{ .status_code = 400, .data = try http_response.makeErrorResponse(allocator, .{ .@"error" = "worktree_path is required" }) });
    }
    if (parsed.title.len == 0) {
        return res.jsonResponse(.{ .status_code = 400, .data = try http_response.makeErrorResponse(allocator, .{ .@"error" = "title is required" }) });
    }

    // `resolveCreateProvider` fails only on an unparseable provider name,
    // so a bare `catch` is exhaustive here — an `else => return err` arm
    // is an unreachable prong and breaks the exe build.
    const provider = resolveCreateProvider(allocator, ctx.io, parsed) catch {
        return res.jsonResponse(.{ .status_code = 400, .data = try http_response.makeErrorResponse(allocator, .{ .@"error" = "provider must be \"github\", \"gitlab\", or \"generic\"" }) });
    };

    const result = try createPullRequestUseCase(
        allocator,
        ctx.io,
        provider,
        parsed.worktree_path,
        parsed.base,
        parsed.title,
        parsed.body,
    );

    const status_code: u16 = switch (result.status) {
        .success => 200,
        .gh_failed => 500,
    };

    return res.jsonResponse(.{ .status_code = status_code, .data = try http_response.makeGitPrCreateResponse(allocator, http_response.GitPrCreateResponse{
        .success = result.status == .success,
        .pr_url = result.pr_url,
        .provider = provider.toString(),
        .@"error" = result.stderr,
    }) });
}

/// Which forge to create on. There is no URL to sniff here (we are
/// making one), so the order is: explicit body field, then the
/// worktree's `origin` remote, then GitHub.
fn resolveCreateProvider(allocator: std.mem.Allocator, io: std.Io, body: anytype) !pr_provider.PrProvider {
    if (body.provider.len > 0) {
        return pr_provider.PrProvider.fromString(body.provider) orelse error.UnknownProvider;
    }
    const res = std.process.run(allocator, io, .{
        .argv = &.{ "git", "-C", body.worktree_path, "remote", "get-url", "origin" },
    }) catch return .github;
    defer {
        allocator.free(res.stdout);
        allocator.free(res.stderr);
    }
    if (res.term.exited != 0) return .github;
    const p = pr_provider.detectProviderFromRemote(res.stdout);
    if (!pr_cli.hasCli(p)) return .github;
    return p;
}

// ===== Tests merged from git_pr_create_test.zig (2026-09-11 flatten) =====
// Behavioural tests: the forge CLI argv + output handling.

const builtin_t = @import("builtin");

fn skipOnWindows() bool {
    return builtin_t.os.tag == .windows;
}

fn haveGit() bool {
    var c = std.process.spawn(std.testing.io, .{
        .argv = &.{"git", "--version"},
        .stdin = .ignore,
        .stdout = .ignore,
        .stderr = .ignore,
    }) catch return false;
    _ = c.wait(std.testing.io) catch return false;
    return true;
}

/// A throwaway dir under `.zig-cache/tmp` plus executable fixtures.
const Fixture = struct {
    tmp: std.testing.TmpDir,
    root: []u8,
    allocator: std.mem.Allocator,

    fn init(allocator: std.mem.Allocator) !Fixture {
        var tmp = std.testing.tmpDir(.{});
        errdefer tmp.cleanup();
        // NOT sized from `std.fs.max_path_bytes`: that is ~96 KB on Windows,
        // and this is a stack buffer.
        var buf: [512]u8 = undefined;
        const root = try tmp.dir.realPath(std.testing.io, &buf);
        const owned = try allocator.dupe(u8, buf[0..root]);
        return .{ .tmp = tmp, .root = owned, .allocator = allocator };
    }

    fn deinit(self: *Fixture) void {
        self.tmp.cleanup();
        self.allocator.free(self.root);
    }

    fn writeExec(self: *Fixture, name: []const u8, script: []const u8) ![]u8 {
        try self.tmp.dir.writeFile(std.testing.io, .{ .sub_path = name, .data = script });
        if (builtin_t.os.tag != .windows) {
            try self.tmp.dir.setFilePermissions(std.testing.io, name, .executable_file, .{});
        }
        return std.fmt.allocPrint(self.allocator, "{s}/{s}", .{ self.root, name });
    }

    /// `writeExec` for an allocator-owned script: writes, frees, returns.
    fn writeScript(self: *Fixture, name: []const u8, script: []const u8) ![]u8 {
        defer self.allocator.free(script);
        return self.writeExec(name, script);
    }
};

/// A git repo inside the fixture, with one commit and a checked-out
/// branch — `glab mr create` needs `--source-branch`, which the use case
/// reads from `git branch --show-current`.
fn makeGitRepoOnBranch(fx: *Fixture) ![]u8 {
    const a = fx.allocator;
    const repo = try std.fmt.allocPrint(a, "{s}/repo", .{fx.root});
    var init = run_captured.run(a, std.testing.io, &.{ "git", "init", "-q", "-b", "worktree/feature-x", repo }, .{
        .timeout_ms = 30_000,
    }) catch return error.SkipZigTest;
    defer init.deinit(a);
    if (init.term.exited != 0) return error.SkipZigTest;
    return repo;
}

/// Frees every owned field of a create result.
fn freeCreateResult(a: std.mem.Allocator, res: CreatePullRequestResult) void {
    a.free(res.pr_url);
    a.free(res.stderr);
}

const testing = std.testing;
// ───────────────────────── GitLab (glab) create path ─────────────────────────

test "create: github still runs the exact historical gh pr create argv" {
    if (skipOnWindows()) return error.SkipZigTest;
    if (!haveGit()) return error.SkipZigTest;
    const a = testing.allocator;
    var fx = try Fixture.init(a);
    defer fx.deinit();
    const repo = try makeGitRepoOnBranch(&fx);
    defer a.free(repo);

    const argv_file = try std.fmt.allocPrint(a, "{s}/argv", .{fx.root});
    defer a.free(argv_file);
    // Echoes the URL so the success path is also exercised.
    const gh = try fx.writeScript("gh", try std.fmt.allocPrint(a,
        "#!/bin/sh\nfor a in \"$@\"; do echo \"$a\"; done > '{s}'\necho '{s}'"
    , .{ argv_file, "https://github.com/acme/app/pull/42" }));
    defer a.free(gh);

    const res = try createPullRequestUseCaseWith(a, std.testing.io, gh, .github, repo, "main", "T", "B");
    defer freeCreateResult(a, res);

    try testing.expectEqual(GhStatus.success, res.status);
    try testing.expectEqualStrings("https://github.com/acme/app/pull/42", res.pr_url);

    const recorded = try std.Io.Dir.cwd().readFileAlloc(std.testing.io, argv_file, a, .limited(64 * 1024));
    defer a.free(recorded);
    // No --head: gh infers it from the worktree checkout, and that
    // behaviour must not change for existing GitHub users.
    try testing.expect(std.mem.indexOf(u8, recorded, "pr\ncreate\n--base\nmain\n--title\nT\n--body\nB\n") != null);
    try testing.expect(std.mem.indexOf(u8, recorded, "--head") == null);
}

test "create: gitlab runs glab mr create with --source-branch and --yes" {
    // --yes is load-bearing: without it glab drops into an interactive
    // confirm in a non-tty child and burns the whole 60s budget.
    // --source-branch is equally required because glab will not infer it.
    if (skipOnWindows()) return error.SkipZigTest;
    if (!haveGit()) return error.SkipZigTest;
    const a = testing.allocator;
    var fx = try Fixture.init(a);
    defer fx.deinit();
    const repo = try makeGitRepoOnBranch(&fx);
    defer a.free(repo);

    const argv_file = try std.fmt.allocPrint(a, "{s}/argv", .{fx.root});
    defer a.free(argv_file);
    const glab = try fx.writeScript("glab", try std.fmt.allocPrint(a,
        "#!/bin/sh\nfor a in \"$@\"; do echo \"$a\"; done > '{s}'\necho '{s}'"
    , .{ argv_file, "https://gitlab.com/group/sub/repo/-/merge_requests/7" }));
    defer a.free(glab);

    const res = try createPullRequestUseCaseWith(a, std.testing.io, glab, .gitlab, repo, "main", "T", "B");
    defer freeCreateResult(a, res);

    try testing.expectEqual(GhStatus.success, res.status);
    try testing.expectEqualStrings("https://gitlab.com/group/sub/repo/-/merge_requests/7", res.pr_url);

    const recorded = try std.Io.Dir.cwd().readFileAlloc(std.testing.io, argv_file, a, .limited(64 * 1024));
    defer a.free(recorded);
    try testing.expect(std.mem.indexOf(u8, recorded, "mr\ncreate\n--source-branch\nworktree/feature-x\n--target-branch\nmain\n--title\nT\n--description\nB\n--yes\n") != null);
}

test "create: a glab banner before the URL does not become pr_url" {
    // THE regression this guards: the use case used to treat the WHOLE
    // trimmed stdout as the URL. glab prints a banner first, so that stored a
    // non-URL as pr_url, and the frontend then handed it to set_pull_request,
    if (skipOnWindows()) return error.SkipZigTest;
    if (!haveGit()) return error.SkipZigTest;
    const a = testing.allocator;
    var fx = try Fixture.init(a);
    defer fx.deinit();
    const repo = try makeGitRepoOnBranch(&fx);
    defer a.free(repo);

    const glab = try fx.writeExec("glab",
        "#!/bin/sh\n" ++
            "echo 'Creating merge request for worktree/feature-x on gitlab.com'\n" ++
            "echo\n" ++
            "echo 'https://gitlab.com/g/s/r/-/merge_requests/7'\n"
    );
    defer a.free(glab);

    const res = try createPullRequestUseCaseWith(a, std.testing.io, glab, .gitlab, repo, "main", "T", "B");
    defer freeCreateResult(a, res);
    try testing.expectEqualStrings("https://gitlab.com/g/s/r/-/merge_requests/7", res.pr_url);
}

test "create: the generic provider fails without spawning anything" {
    if (skipOnWindows()) return error.SkipZigTest;
    const a = testing.allocator;
    var fx = try Fixture.init(a);
    defer fx.deinit();
    // A script that would leave a sentinel if it ever ran.
    const sentinel = try std.fmt.allocPrint(a, "{s}/ran", .{fx.root});
    defer a.free(sentinel);
    const prog = try fx.writeScript("nope", try std.fmt.allocPrint(a, "touch '{s}'\n", .{sentinel}));
    defer a.free(prog);

    const res = try createPullRequestUseCaseWith(a, std.testing.io, prog, .generic, fx.root, "main", "T", "B");
    defer freeCreateResult(a, res);
    try testing.expectEqual(GhStatus.gh_failed, res.status);
    try testing.expect(std.mem.indexOf(u8, res.stderr, "no forge CLI") != null);
    // The sentinel is the real assertion: if the generic provider ever
    // falls through to a spawn, this file appears.
    const spawned = if (std.Io.Dir.cwd().access(std.testing.io, sentinel, .{})) |_| true else |_| false;
    if (spawned) {
        std.debug.print("!! the generic provider spawned a CLI instead of short-circuiting !!\n", .{});
        return error.CLIWasSpawned;
    }
}

test "create: a missing CLI names glab, not gh" {
    if (skipOnWindows()) return error.SkipZigTest;
    const a = testing.allocator;
    var fx = try Fixture.init(a);
    defer fx.deinit();

    const res = try createPullRequestUseCaseWith(a, std.testing.io, "/pabrik/definitely/not/glab", .gitlab, fx.root, "main", "T", "B");
    defer freeCreateResult(a, res);
    try testing.expectEqual(GhStatus.gh_failed, res.status);
    try testing.expect(std.mem.indexOf(u8, res.stderr, "glab") != null);
    try testing.expect(std.mem.indexOf(u8, res.stderr, "gh") == null);
}
