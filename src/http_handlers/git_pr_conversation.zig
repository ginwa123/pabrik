//! `GET /api/git/pr/conversation` — the change request's body, its comments
//! and its review verdicts, read through the forge CLI.

const std = @import("std");
const http_response = @import("http_response.zig");
const pabrik_core = @import("pabrikcore");
const gserverz = pabrik_core.gserverz;
const pr_provider = pabrik_core.pr_provider;
const pr_cli = pabrik_core.pr_cli;
// The repo gate, the provider resolution and the stderr policy are shared with
// the status endpoint: two endpoints that disagreed about which forge a repo
// is on would read two different conversations.
const pr_status = @import("git_pr_status.zig");

/// One forge read, like the status read.
pub const CONVERSATION_TIMEOUT_MS: u32 = 20_000;

const ConversationError = error{
    /// The path is not a work tree, so no forge may be asked about it.
    NotARepository,
    /// No forge CLI on PATH.
    CliMissing,
    /// The change request does not exist.
    NoAssociatedPr,
    /// The CLI ran and did not answer.
    FetchFailed,
    /// The request arena ran out of memory.
    OutOfMemory,
};

/// The forge binaries. Injectable so the tests can point the whole path at
/// fixture scripts instead of real, authenticated CLIs.
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

// ─── GitHub's payload ─────────────────────────────────────────────────────

const GhAuthor = struct {
    login: []const u8 = "",
};

const GhComment = struct {
    author: GhAuthor = .{},
    body: []const u8 = "",
    createdAt: []const u8 = "",
    url: []const u8 = "",
};

const GhReview = struct {
    author: GhAuthor = .{},
    /// APPROVED | CHANGES_REQUESTED | COMMENTED | DISMISSED | PENDING.
    state: []const u8 = "",
    body: []const u8 = "",
    submittedAt: []const u8 = "",
    url: []const u8 = "",
};

const GhConversation = struct {
    body: []const u8 = "",
    title: []const u8 = "",
    number: i64 = 0,
    url: []const u8 = "",
    createdAt: []const u8 = "",
    /// APPROVED | CHANGES_REQUESTED | REVIEW_REQUIRED, or "" when the forge
    /// has no verdict to give.
    reviewDecision: []const u8 = "",
    author: GhAuthor = .{},
    comments: []GhComment = &.{},
    reviews: []GhReview = &.{},
};

// ─── GitLab's payload ──────────────────────────────────────────────────────
// Read through `std.json.Value`: glab renames its fields between releases,
// and a rename must cost one missing comment, never a 502 for the whole tab.

fn valueString(v: std.json.Value) []const u8 {
    return switch (v) {
        .string => |s| s,
        else => "",
    };
}

fn objectString(obj: std.json.ObjectMap, key: []const u8) []const u8 {
    const v = obj.get(key) orelse return "";
    return valueString(v);
}

fn objectInt(obj: std.json.ObjectMap, key: []const u8) i64 {
    const v = obj.get(key) orelse return 0;
    return switch (v) {
        .integer => |i| i,
        .float => |f| @intFromFloat(f),
        .string => |s| std.fmt.parseInt(i64, std.mem.trim(u8, s, " \t"), 10) catch 0,
        else => 0,
    };
}

/// The array at `key`, or null when the key is absent or is not an array.
fn objectArray(obj: std.json.ObjectMap, key: []const u8) ?[]std.json.Value {
    const v = obj.get(key) orelse return null;
    return switch (v) {
        .array => |a| a.items,
        else => null,
    };
}

/// The display name of a note's author: `username` first, then `name`.
fn noteAuthor(note: std.json.Value) []const u8 {
    const obj = switch (note) {
        .object => |o| o,
        else => return "",
    };
    const author = obj.get("author") orelse obj.get("user") orelse return "";
    const aobj = switch (author) {
        .object => |o| o,
        else => return valueString(author),
    };
    const username = objectString(aobj, "username");
    if (username.len > 0) return username;
    return objectString(aobj, "name");
}

/// The body of a note: `body` first, then `note`.
fn noteBody(note: std.json.Value) []const u8 {
    const obj = switch (note) {
        .object => |o| o,
        else => return "",
    };
    const body = objectString(obj, "body");
    if (body.len > 0) return body;
    return objectString(obj, "note");
}

/// A note's timestamp, or "" when the CLI did not print one.
fn noteCreatedAt(note: std.json.Value) []const u8 {
    const obj = switch (note) {
        .object => |o| o,
        else => return "",
    };
    return objectString(obj, "created_at");
}

/// A system note is the forge talking to itself ("changed the description").
/// It is not a comment from a person, so the thread leaves it out.
fn noteIsSystem(note: std.json.Value) bool {
    const obj = switch (note) {
        .object => |o| o,
        else => return false,
    };
    const v = obj.get("system") orelse return false;
    return switch (v) {
        .bool => |b| b,
        else => false,
    };
}

// ─── The read ──────────────────────────────────────────────────────────────

/// Read the conversation of the change request `pr_arg` names.
pub fn useCaseWithPrograms(
    allocator: std.mem.Allocator,
    io: std.Io,
    programs: Programs,
    path: []const u8,
    pr_arg: []const u8,
    provider_override: ?[]const u8,
    fetch_detail: *?[]u8,
) ConversationError!http_response.GitPrConversationResponse {
    if (!pr_status.isWorkTree(allocator, io, path)) return error.NotARepository;

    const provider = pr_status.resolveProvider(allocator, io, path, pr_arg, provider_override) catch |err| {
        switch (err) {
            error.UnknownProvider => pr_status.setFetchDetail(allocator, fetch_detail, "unknown provider (expected github or gitlab)"),
            error.UnsupportedProvider => pr_status.setFetchDetail(allocator, fetch_detail, "the generic provider has no forge CLI, so the conversation cannot be read"),
            else => |e| return e,
        }
        return error.FetchFailed;
    };

    const prog = programs.forProvider(provider);
    if (prog.len == 0) return error.CliMissing;
    var argv_buf: [pr_cli.conversation_argv_max][]const u8 = undefined;
    const argv = pr_cli.conversationArgv(&argv_buf, provider, prog, pr_arg) orelse return error.CliMissing;

    const raw = pr_status.runForgeView(allocator, io, provider, path, argv, CONVERSATION_TIMEOUT_MS, fetch_detail) catch |err| return err;
    defer allocator.free(raw);

    const trimmed = std.mem.trim(u8, raw, " \n\r");
    return switch (provider) {
        .github => try buildGithubResponse(allocator, provider, trimmed, fetch_detail),
        .gitlab => try buildGlabResponse(allocator, provider, trimmed, fetch_detail),
        .generic => unreachable,
    };
}

/// Build the wire response from `gh pr view --json` stdout.
fn buildGithubResponse(
    allocator: std.mem.Allocator,
    provider: pr_provider.PrProvider,
    trimmed: []const u8,
    fetch_detail: *?[]u8,
) ConversationError!http_response.GitPrConversationResponse {
    // Not the leaky parse: a body with an escaped newline makes the scanner
    // allocate, and the leaky variant never gives that memory back.
    var parsed = std.json.parseFromSlice(GhConversation, allocator, trimmed, .{ .ignore_unknown_fields = true }) catch {
        pr_status.setFetchDetail(allocator, fetch_detail, "invalid JSON from gh pr view (the conversation read)");
        return error.FetchFailed;
    };
    defer parsed.deinit();
    const conv = parsed.value;

    const comments = try allocator.alloc(http_response.GitPrConversationComment, conv.comments.len);
    errdefer allocator.free(comments);
    for (conv.comments, 0..) |c, i| {
        comments[i] = .{
            .author = try allocator.dupe(u8, c.author.login),
            .body = try allocator.dupe(u8, c.body),
            .created_at = try allocator.dupe(u8, c.createdAt),
            .url = try allocator.dupe(u8, c.url),
        };
    }

    const reviews = try allocator.alloc(http_response.GitPrConversationReview, conv.reviews.len);
    errdefer allocator.free(reviews);
    for (conv.reviews, 0..) |r, i| {
        reviews[i] = .{
            .author = try allocator.dupe(u8, r.author.login),
            .state = try allocator.dupe(u8, r.state),
            .body = try allocator.dupe(u8, r.body),
            .created_at = try allocator.dupe(u8, r.submittedAt),
            .url = try allocator.dupe(u8, r.url),
        };
    }

    return .{
        .provider = try allocator.dupe(u8, provider.toString()),
        .number = conv.number,
        .title = try allocator.dupe(u8, conv.title),
        .body = try allocator.dupe(u8, conv.body),
        .author = try allocator.dupe(u8, conv.author.login),
        .created_at = try allocator.dupe(u8, conv.createdAt),
        .review_decision = try allocator.dupe(u8, conv.reviewDecision),
        .comments = comments,
        .reviews = reviews,
        .comment_count = @intCast(comments.len + reviews.len),
        .detail = "",
    };
}

/// Build the wire response from `glab mr view --comments --output json`.
fn buildGlabResponse(
    allocator: std.mem.Allocator,
    provider: pr_provider.PrProvider,
    trimmed: []const u8,
    fetch_detail: *?[]u8,
) ConversationError!http_response.GitPrConversationResponse {
    var parsed = std.json.parseFromSlice(std.json.Value, allocator, trimmed, .{}) catch {
        pr_status.setFetchDetail(allocator, fetch_detail, "invalid JSON from glab mr view (the conversation read)");
        return error.FetchFailed;
    };
    defer parsed.deinit();
    const root = switch (parsed.value) {
        .object => |o| o,
        else => {
            pr_status.setFetchDetail(allocator, fetch_detail, "invalid JSON from glab mr view (the conversation read)");
            return error.FetchFailed;
        },
    };

    // `notes` is GitLab's own name; `comments` is what an older glab printed.
    const notes = objectArray(root, "notes") orelse objectArray(root, "comments");
    const comment_list = notes orelse &[_]std.json.Value{};
    var comments = try allocator.alloc(http_response.GitPrConversationComment, comment_list.len);
    errdefer allocator.free(comments);
    for (comment_list, 0..) |note, i| {
        comments[i] = .{
            .author = try allocator.dupe(u8, noteAuthor(note)),
            .body = try allocator.dupe(u8, noteBody(note)),
            .created_at = try allocator.dupe(u8, noteCreatedAt(note)),
            .url = "",
        };
    }

    const description = objectString(root, "description");
    const body = if (description.len > 0) description else objectString(root, "body");
    const author = root.get("author");
    const author_name = if (author) |a| pr_status.glabAuthorName(a) else "";

    return .{
        .provider = try allocator.dupe(u8, provider.toString()),
        .number = if (objectInt(root, "iid") != 0) objectInt(root, "iid") else objectInt(root, "id"),
        .title = try allocator.dupe(u8, objectString(root, "title")),
        .body = try allocator.dupe(u8, body),
        .author = try allocator.dupe(u8, author_name),
        .created_at = try allocator.dupe(u8, objectString(root, "created_at")),
        .review_decision = "",
        .comments = comments,
        .reviews = &.{},
        .comment_count = @intCast(comments.len),
        // An empty note list and a missing one read the same, so the honest
        // note is about the CLI, not about the merge request.
        .detail = if (notes == null) "this CLI's JSON output carries the description, not the merge request notes" else "",
    };
}

/// GET /api/git/pr/conversation?path=<repo>[&pr=<n|url|branch>][&provider=]
pub fn gitPrConversationHandler(ctx: gserverz.HttpContext, req: gserverz.HttpRequest, res: gserverz.HttpResponse) !gserverz.HttpResponse {
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
    const result = useCaseWithPrograms(allocator, io, .{}, path_param, pr_param, provider_param, &fetch_detail) catch |err| switch (err) {
        error.NotARepository => {
            return res.jsonResponse(.{ .status_code = 404, .data = try http_response.makeGitStatusErrorResponse(allocator, "not a git repository") });
        },
        error.CliMissing => {
            const cli = pr_cli.cliFor(pr_provider.PrProvider.github) orelse pr_cli.GH_CLI;
            const msg = try std.fmt.allocPrint(allocator, "{s} CLI not found on PATH (install {s} to read the conversation)", .{ cli.program, cli.program });
            return res.jsonResponse(.{ .status_code = 422, .data = try http_response.makeGitStatusErrorResponse(allocator, msg) });
        },
        error.NoAssociatedPr => {
            const msg = if (pr_param.len > 0)
                try std.fmt.allocPrint(allocator, "no change request found for '{s}'", .{pr_param})
            else
                "no change request found for the current branch";
            return res.jsonResponse(.{ .status_code = 404, .data = try http_response.makeGitStatusErrorResponse(allocator, msg) });
        },
        error.FetchFailed => {
            const msg = if (fetch_detail) |d|
                try std.fmt.allocPrint(allocator, "failed to read the conversation: {s}", .{d})
            else
                "failed to read the conversation (check the change request, the provider, and the CLI's auth)";
            return res.jsonResponse(.{ .status_code = 502, .data = try http_response.makeGitStatusErrorResponse(allocator, msg) });
        },
        else => |e| return e,
    };

    return res.jsonResponse(.{ .status_code = 200, .data = try http_response.makeGitPrConversationResponse(allocator, result) });
}

// ============================================================================
// Behavioural tests: the conversation read, against a fixture CLI.

const testing = std.testing;
const hf = @import("helpers").host_fixture;
const run_captured = @import("helpers").run_captured;

/// A `gh pr view --json` payload with a body, a comment and a review.
const CONVERSATION_JSON =
    \\{"body":"## What\n\nThe panel shows the title now.","title":"fix(url): the settings URL names the workspace","number":1010,"url":"https://github.com/acme/app/pull/1010","author":{"login":"gilang"},"createdAt":"2026-10-20T19:26:21Z","reviewDecision":"CHANGES_REQUESTED","comments":[{"author":{"login":"reviewer"},"body":"One spec still assumes the old shape.","createdAt":"2026-10-20T20:00:00Z","url":"https://github.com/acme/app/pull/1010#issue-1"}],"reviews":[{"author":{"login":"reviewer"},"state":"CHANGES_REQUESTED","body":"Two specs still assume the old URL shape.","submittedAt":"2026-10-20T20:05:00Z","url":"https://github.com/acme/app/pull/1010#pullrequestreview-1"}]}
;

/// A `glab mr view --comments --output json` payload: the description, the
/// notes, and no reviews.
const GLAB_CONVERSATION_JSON =
    \\{"iid":7,"title":"Add GitLab support","description":"The body of the merge request.","state":"opened","created_at":"2026-09-28T10:00:00.000Z","author":{"username":"gilang","name":"Gilang"},"notes":[{"body":"A note from a reviewer.","author":{"username":"reviewer"},"created_at":"2026-09-28T11:00:00.000Z"}]}
;

const Fixture = struct {
    inner: hf.Fixture,
    allocator: std.mem.Allocator,

    fn init(allocator: std.mem.Allocator) !Fixture {
        return .{ .inner = try hf.Fixture.init(allocator), .allocator = allocator };
    }

    fn deinit(self: *Fixture) void {
        self.inner.deinit();
    }

    fn root(self: *Fixture) []const u8 {
        return self.inner.root;
    }

    fn writeProgram(self: *Fixture, name: []const u8, payload: hf.Payload) ![]u8 {
        return self.inner.writeProgram(name, payload);
    }

    fn subDir(self: *Fixture, name: []const u8) ![]u8 {
        return self.inner.subDir(name);
    }
};

/// True when a usable `git` is on PATH (the repo gate needs one).
fn haveGit() bool {
    var c = std.process.spawn(testing.io, .{
        .argv = &.{ "git", "--version" },
        .stdin = .ignore,
        .stdout = .ignore,
        .stderr = .ignore,
    }) catch return false;
    _ = c.wait(testing.io) catch return false;
    return true;
}

/// A real (empty) git repo inside the fixture, so the repo gate passes.
fn makeGitRepo(fx: *Fixture) ![]u8 {
    try @import("helpers").git_env_guard.requireCleanGitEnv();
    const a = fx.allocator;
    const repo = try fx.subDir("repo");
    var r = run_captured.run(a, testing.io, &.{ "git", "init", "-q", repo }, .{
        .timeout_ms = 30_000,
    }) catch return error.SkipZigTest;
    defer r.deinit(a);
    if (r.term.exited != 0) return error.SkipZigTest;
    return repo;
}

/// Every string in the response is owned by the caller's allocator.
fn freeConversation(a: std.mem.Allocator, res: http_response.GitPrConversationResponse) void {
    inline for (.{
        res.provider,
        res.title,
        res.body,
        res.author,
        res.created_at,
        res.review_decision,
        res.detail,
    }) |s| a.free(s);
    for (res.comments) |c| {
        a.free(c.author);
        a.free(c.body);
        a.free(c.created_at);
        a.free(c.url);
    }
    a.free(res.comments);
    for (res.reviews) |r| {
        a.free(r.author);
        a.free(r.state);
        a.free(r.body);
        a.free(r.created_at);
        a.free(r.url);
    }
    a.free(res.reviews);
}

test "the conversation read maps a gh payload onto the response" {
    if (!haveGit()) return error.SkipZigTest;
    const a = testing.allocator;
    var fx = try Fixture.init(a);
    defer fx.deinit();
    const repo = try makeGitRepo(&fx);
    defer a.free(repo);

    const gh = try fx.writeProgram("gh", .{ .stdout = CONVERSATION_JSON });
    defer a.free(gh);

    var detail: ?[]u8 = null;
    defer if (detail) |d| a.free(d);
    const res = try useCaseWithPrograms(a, testing.io, .{ .gh = gh, .glab = "/pabrik/no/such/glab" }, repo, "1010", null, &detail);
    defer freeConversation(a, res);

    try testing.expectEqualStrings("github", res.provider);
    try testing.expectEqual(@as(i64, 1010), res.number);
    try testing.expectEqualStrings("fix(url): the settings URL names the workspace", res.title);
    try testing.expectEqualStrings("gilang", res.author);
    try testing.expectEqualStrings("2026-10-20T19:26:21Z", res.created_at);
    try testing.expectEqualStrings("CHANGES_REQUESTED", res.review_decision);
    try testing.expectEqualStrings("## What\n\nThe panel shows the title now.", res.body);
    try testing.expectEqual(@as(usize, 1), res.comments.len);
    try testing.expectEqualStrings("reviewer", res.comments[0].author);
    try testing.expectEqualStrings("One spec still assumes the old shape.", res.comments[0].body);
    try testing.expectEqual(@as(usize, 1), res.reviews.len);
    try testing.expectEqualStrings("CHANGES_REQUESTED", res.reviews[0].state);
    try testing.expectEqualStrings("Two specs still assume the old URL shape.", res.reviews[0].body);
    try testing.expectEqualStrings("2026-10-20T20:05:00Z", res.reviews[0].created_at);
    // The count is what the tab's pill shows: comments plus reviews.
    try testing.expectEqual(@as(i64, 2), res.comment_count);
}

test "the conversation read asks gh for the conversation fields" {
    if (!haveGit()) return error.SkipZigTest;
    const a = testing.allocator;
    var fx = try Fixture.init(a);
    defer fx.deinit();
    const repo = try makeGitRepo(&fx);
    defer a.free(repo);

    const argv_file = try std.fmt.allocPrint(a, "{s}/argv", .{fx.root()});
    defer a.free(argv_file);
    const gh = try fx.writeProgram("gh", .{ .argv_file = argv_file, .stdout = CONVERSATION_JSON });
    defer a.free(gh);

    var detail: ?[]u8 = null;
    defer if (detail) |d| a.free(d);
    const res = try useCaseWithPrograms(a, testing.io, .{ .gh = gh }, repo, "1010", null, &detail);
    defer freeConversation(a, res);

    const recorded = try std.Io.Dir.cwd().readFileAlloc(testing.io, argv_file, a, .limited(64 * 1024));
    defer a.free(recorded);
    // The ref is passed through in place, and the fields come after it.
    try testing.expect(hf.recordedArgvContainsSequence(recorded, &.{ "pr", "view", "1010", "--json", pr_cli.GH_CONVERSATION_JSON_FIELDS }));
}

test "a change request that does not exist is NoAssociatedPr" {
    if (!haveGit()) return error.SkipZigTest;
    const a = testing.allocator;
    var fx = try Fixture.init(a);
    defer fx.deinit();
    const repo = try makeGitRepo(&fx);
    defer a.free(repo);

    const gh = try fx.writeProgram("gh", .{ .stderr = "no pull requests found for branch \"x\"", .exit_code = 1 });
    defer a.free(gh);

    var detail: ?[]u8 = null;
    defer if (detail) |d| a.free(d);
    try testing.expectError(
        error.NoAssociatedPr,
        useCaseWithPrograms(a, testing.io, .{ .gh = gh }, repo, "", null, &detail),
    );
}

test "unreadable output from the CLI is a FetchFailed, not an empty thread" {
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
    try testing.expectError(
        error.FetchFailed,
        useCaseWithPrograms(a, testing.io, .{ .gh = gh }, repo, "", null, &detail),
    );
    try testing.expect(detail != null);
    try testing.expect(std.mem.indexOf(u8, detail.?, "invalid JSON") != null);
}

test "a path that is not a work tree is refused before the CLI runs" {
    if (!haveGit()) return error.SkipZigTest;
    const a = testing.allocator;
    var fx = try Fixture.init(a);
    defer fx.deinit();

    // A directory under /tmp, not the fixture's own root: the fixture lives
    // under the repository's .zig-cache, and git walks UP into the
    // repository from there, so the fixture root IS a work tree.
    const not_repo = try pr_status.makeNonRepoDir(a);
    defer pr_status.removeNonRepoDir(a, not_repo);
    if (pr_status.gitProbeIsEnvHijacked(a, not_repo)) return error.SkipZigTest;

    const sentinel = try std.fmt.allocPrint(a, "{s}/gh-was-run", .{fx.root()});
    defer a.free(sentinel);
    const gh = try fx.writeProgram("gh", .{ .touch_file = sentinel, .stdout = CONVERSATION_JSON });
    defer a.free(gh);

    var detail: ?[]u8 = null;
    defer if (detail) |d| a.free(d);
    if (useCaseWithPrograms(a, testing.io, .{ .gh = gh }, not_repo, "", null, &detail)) |res| {
        freeConversation(a, res);
        return error.GhWasSpawned;
    } else |err| {
        try testing.expectEqual(error.NotARepository, err);
    }
    // The sentinel proves the CLI never ran.
    try testing.expectError(error.FileNotFound, std.Io.Dir.cwd().access(testing.io, sentinel, .{}));
}

test "a glab payload maps its notes onto comments" {
    if (!haveGit()) return error.SkipZigTest;
    const a = testing.allocator;
    var fx = try Fixture.init(a);
    defer fx.deinit();
    const repo = try makeGitRepo(&fx);
    defer a.free(repo);

    const glab = try fx.writeProgram("glab", .{ .stdout = GLAB_CONVERSATION_JSON });
    defer a.free(glab);

    var detail: ?[]u8 = null;
    defer if (detail) |d| a.free(d);
    const res = try useCaseWithPrograms(a, testing.io, .{ .gh = "/pabrik/no/such/gh", .glab = glab }, repo, "7", "gitlab", &detail);
    defer freeConversation(a, res);

    try testing.expectEqualStrings("gitlab", res.provider);
    try testing.expectEqual(@as(i64, 7), res.number);
    try testing.expectEqualStrings("The body of the merge request.", res.body);
    try testing.expectEqualStrings("gilang", res.author);
    try testing.expectEqual(@as(usize, 1), res.comments.len);
    try testing.expectEqualStrings("reviewer", res.comments[0].author);
    try testing.expectEqualStrings("A note from a reviewer.", res.comments[0].body);
    // The notes were in the payload, so there is nothing to warn about.
    try testing.expectEqualStrings("", res.detail);
}
