const std = @import("std");
const pr_provider = @import("pr_provider.zig");

const PrProvider = pr_provider.PrProvider;

/// Fields requested from `gh pr view --json`. Kept here (not next to
/// the caller) so the argv builder and the parser it feeds cannot drift,
/// and so the GitLab builder below has an obvious sibling to read.
pub const GH_JSON_FIELDS = "number,title,url,state,mergeable,mergeStateStatus,headRefName,baseRefName,createdAt,updatedAt,mergedAt,closedAt,author,additions,deletions,changedFiles,headRefOid";

/// The command-line tool that owns a forge, plus the words its users expect
/// to read.
pub const Cli = struct {
    /// Program to spawn.
    program: []const u8,
    /// Subcommand noun (`gh pr`, `glab mr`).
    noun: []const u8,
    /// Sentence-case name for prose ("pull request", "merge request").
    label: []const u8,
    /// Uppercase short form for headings ("PR", "MR").
    short: []const u8,
    /// Proper name of the forge, for error messages.
    forge: []const u8,
};

pub const GH_CLI: Cli = .{
    .program = "gh",
    .noun = "pr",
    .label = "pull request",
    .short = "PR",
    .forge = "GitHub",
};

pub const GLAB_CLI: Cli = .{
    .program = "glab",
    .noun = "mr",
    .label = "merge request",
    .short = "MR",
    .forge = "GitLab",
};

/// The CLI that owns `provider`, or null when the provider has none.
/// `generic` deliberately returns null: a forge we cannot identify has
/// no CLI to ask, and its diffs come from local git refs.
pub fn cliFor(provider: PrProvider) ?Cli {
    return switch (provider) {
        .github => GH_CLI,
        .gitlab => GLAB_CLI,
        .generic => null,
    };
}

/// Whether `provider` is served by a forge CLI. The one-liner callers
/// use when they need a "not supported here" branch without pulling the
/// whole `Cli` apart.
pub fn hasCli(provider: PrProvider) bool {
    return cliFor(provider) != null;
}

/// Upper bound on `viewArgv` output.
pub const view_argv_max = 6;

/// Build the read-only "show me this PR/MR" argv: `<prog> <pr|mr> view
/// [<ref>] <provider flags>`.
pub fn viewArgv(storage: [][]const u8, provider: PrProvider, prog: []const u8, ref: []const u8) ?[]const []const u8 {
    const c = cliFor(provider) orelse return null;
    if (storage.len < view_argv_max) return null;

    var n: usize = 0;
    storage[n] = prog;
    n += 1;
    storage[n] = c.noun;
    n += 1;
    storage[n] = "view";
    n += 1;
    if (ref.len > 0) {
        storage[n] = ref;
        n += 1;
    }
    switch (provider) {
        .github => {
            storage[n] = "--json";
            n += 1;
            storage[n] = GH_JSON_FIELDS;
            n += 1;
        },
        .gitlab => {
            storage[n] = "--output";
            n += 1;
            storage[n] = "json";
            n += 1;
        },
        // `cliFor` already returned null for this.
        .generic => unreachable,
    }
    return storage[0..n];
}

/// Upper bound on `createArgv` output.
pub const create_argv_max = 12;

/// Build the "open a new PR/MR" argv: `<prog> <pr|mr> create
/// --base/--target-branch … --title …`. `prog` is explicit for the same
/// test-injection reason as `viewArgv`.
pub fn createArgv(
    storage: [][]const u8,
    provider: PrProvider,
    prog: []const u8,
    base: []const u8,
    source_branch: []const u8,
    title: []const u8,
    body: []const u8,
) ?[]const []const u8 {
    const c = cliFor(provider) orelse return null;
    if (storage.len < create_argv_max) return null;

    var n: usize = 0;
    storage[n] = prog;
    n += 1;
    storage[n] = c.noun;
    n += 1;
    storage[n] = "create";
    n += 1;
    switch (provider) {
        .github => {
            storage[n] = "--base";
            n += 1;
            storage[n] = base;
            n += 1;
            storage[n] = "--title";
            n += 1;
            storage[n] = title;
            n += 1;
            storage[n] = "--body";
            n += 1;
            storage[n] = body;
            n += 1;
        },
        .gitlab => {
            storage[n] = "--source-branch";
            n += 1;
            storage[n] = source_branch;
            n += 1;
            storage[n] = "--target-branch";
            n += 1;
            storage[n] = base;
            n += 1;
            storage[n] = "--title";
            n += 1;
            storage[n] = title;
            n += 1;
            storage[n] = "--description";
            n += 1;
            storage[n] = body;
            n += 1;
            storage[n] = "--yes";
            n += 1;
        },
        .generic => unreachable,
    }
    return storage[0..n];
}

/// Which strategy a merge uses.
pub const MergeMethod = enum {
    merge,
    squash,
    rebase,

    pub fn fromString(s: []const u8) ?MergeMethod {
        if (std.mem.eql(u8, s, "merge")) return .merge;
        if (std.mem.eql(u8, s, "squash")) return .squash;
        if (std.mem.eql(u8, s, "rebase")) return .rebase;
        return null;
    }

    pub fn toString(self: MergeMethod) []const u8 {
        return switch (self) {
            .merge => "merge",
            .squash => "squash",
            .rebase => "rebase",
        };
    }

    /// The strategy flag for `provider`, or null when the provider's default
    /// already means this method. Null is a real answer, not a failure: on
    /// GitLab, `--merge` does not exist and passing it would be a hard error.
    pub fn flag(self: MergeMethod, provider: PrProvider) ?[]const u8 {
        return switch (provider) {
            .github => switch (self) {
                .merge => "--merge",
                .squash => "--squash",
                .rebase => "--rebase",
            },
            .gitlab => switch (self) {
                .merge => null,
                .squash => "--squash",
                .rebase => "--rebase",
            },
            .generic => null,
        };
    }
};

/// Everything a merge needs beyond the method itself.
pub const MergeOptions = struct {
    /// Delete the source branch after merging. OFF by default in the UI:
    /// in this app the source branch is usually the session's own worktree
    /// branch, so ticking this deletes the branch the session stands on.
    delete_branch: bool = false,
    /// The head commit the caller believes it is merging. Both forges accept
    /// a guard, so a merge cannot land on a commit the user never saw.
    /// Empty = no guard.
    head_sha: []const u8 = "",
    /// Title / body of the commit the merge creates (squash subject).
    subject: []const u8 = "",
    body: []const u8 = "",
};

/// Upper bound on `mergeArgv` output: prog, noun, "merge", ref, strategy
/// flag, then at most four pairs of flag+value, plus GitLab's two mandatory
/// flags. 18 is past every arm.
pub const merge_argv_max = 18;

/// Build the "merge this PR/MR" argv: `<prog> <pr|mr> merge [<ref>] <provider
/// flags>`. `prog` is explicit for the same test-injection reason as
/// `viewArgv`.
pub fn mergeArgv(
    storage: [][]const u8,
    provider: PrProvider,
    prog: []const u8,
    ref: []const u8,
    method: MergeMethod,
    opts: MergeOptions,
) ?[]const []const u8 {
    const c = cliFor(provider) orelse return null;
    if (prog.len == 0) return null;
    if (storage.len < merge_argv_max) return null;

    var n: usize = 0;
    storage[n] = prog;
    n += 1;
    storage[n] = c.noun;
    n += 1;
    storage[n] = "merge";
    n += 1;
    if (ref.len > 0) {
        storage[n] = ref;
        n += 1;
    }
    if (method.flag(provider)) |f| {
        storage[n] = f;
        n += 1;
    }
    switch (provider) {
        .github => {
            if (opts.delete_branch) {
                storage[n] = "--delete-branch";
                n += 1;
            }
            if (opts.head_sha.len > 0) {
                storage[n] = "--match-head-commit";
                n += 1;
                storage[n] = opts.head_sha;
                n += 1;
            }
            if (opts.subject.len > 0) {
                storage[n] = "--subject";
                n += 1;
                storage[n] = opts.subject;
                n += 1;
            }
            if (opts.body.len > 0) {
                storage[n] = "--body";
                n += 1;
                storage[n] = opts.body;
                n += 1;
            }
        },
        .gitlab => {
            if (opts.delete_branch) {
                storage[n] = "--remove-source-branch";
                n += 1;
            }
            if (opts.head_sha.len > 0) {
                storage[n] = "--sha";
                n += 1;
                storage[n] = opts.head_sha;
                n += 1;
            }
            if (opts.subject.len > 0) {
                // GitLab separates the squash message from the merge-commit
                // message; GitHub takes subject/body for both.
                storage[n] = if (method == .squash) "--squash-message" else "--message";
                n += 1;
                storage[n] = opts.subject;
                n += 1;
            }
            storage[n] = "--yes";
            n += 1;
            storage[n] = "--auto-merge=false";
            n += 1;
        },
        .generic => unreachable,
    }
    return storage[0..n];
}

// ─── listArgv ────────────────────────────────────────────────────────────

/// Fields requested from `gh pr list --json`.
pub const GH_LIST_JSON_FIELDS = "number,title,url,state,isDraft,headRefName,baseRefName,author,updatedAt";

/// Which change requests a list asks for.
pub const ListState = enum {
    open,
    closed,
    merged,
    all,

    /// Empty means `open`: both CLIs default to open, so a caller that omits
    /// the parameter reads the same list the forge's own UI opens on.
    pub fn fromString(s: []const u8) ?ListState {
        if (s.len == 0) return .open;
        if (std.mem.eql(u8, s, "open")) return .open;
        if (std.mem.eql(u8, s, "closed")) return .closed;
        if (std.mem.eql(u8, s, "merged")) return .merged;
        if (std.mem.eql(u8, s, "all")) return .all;
        return null;
    }

    /// The wire name, echoed back in the response so the caller can label a
    /// tab from what the backend actually asked for.
    pub fn toString(self: ListState) []const u8 {
        return switch (self) {
            .open => "open",
            .closed => "closed",
            .merged => "merged",
            .all => "all",
        };
    }

    /// The GitLab arm of the filter, or null for `open` — GitLab expresses
    /// these as four booleans with open as the default, so there is no
    /// `--open` to pass. (`--opened` is not a glab flag.)
    fn glabFlag(self: ListState) ?[]const u8 {
        return switch (self) {
            .open => null,
            .closed => "--closed",
            .merged => "--merged",
            .all => "--all",
        };
    }
};

/// Upper bound on `listArgv` output: prog, noun, "list", GitHub's three
/// flag+value pairs, GitLab's state flag plus four pairs.
pub const list_argv_max = 16;

/// Build the "list the change requests" argv: `<prog> <pr|mr> list <state
/// filter> <limit> <json flag>`.
pub fn listArgv(
    storage: [][]const u8,
    limit_buf: []u8,
    provider: PrProvider,
    prog: []const u8,
    state: ListState,
    limit: u32,
) ?[]const []const u8 {
    const c = cliFor(provider) orelse return null;
    if (prog.len == 0) return null;
    if (limit == 0) return null;
    if (storage.len < list_argv_max) return null;

    const limit_str = std.fmt.bufPrint(limit_buf, "{d}", .{limit}) catch return null;

    var n: usize = 0;
    storage[n] = prog;
    n += 1;
    storage[n] = c.noun;
    n += 1;
    storage[n] = "list";
    n += 1;
    switch (provider) {
        .github => {
            storage[n] = "--state";
            n += 1;
            storage[n] = state.toString();
            n += 1;
            storage[n] = "--limit";
            n += 1;
            storage[n] = limit_str;
            n += 1;
            storage[n] = "--json";
            n += 1;
            storage[n] = GH_LIST_JSON_FIELDS;
            n += 1;
        },
        .gitlab => {
            if (state.glabFlag()) |flag| {
                storage[n] = flag;
                n += 1;
            }
            storage[n] = "-P";
            n += 1;
            storage[n] = limit_str;
            n += 1;
            // Without an explicit order the list arrives in whatever order
            // the API happens to return, and the UI's "newest activity
            // first" line would be a claim about nothing.
            storage[n] = "-o";
            n += 1;
            storage[n] = "updated_at";
            n += 1;
            storage[n] = "-S";
            n += 1;
            storage[n] = "desc";
            n += 1;
            storage[n] = "-F";
            n += 1;
            storage[n] = "json";
            n += 1;
        },
        .generic => unreachable,
    }
    return storage[0..n];
}

// ─── closeArgv ───────────────────────────────────────────────────────────

/// Upper bound on `closeArgv` output (prog, noun, "close", ref).
pub const close_argv_max = 4;

/// Build the "close this PR/MR" argv: `<prog> <pr|mr> close <ref>`. `ref` is
/// REQUIRED here, unlike `viewArgv`.
pub fn closeArgv(
    storage: [][]const u8,
    provider: PrProvider,
    prog: []const u8,
    ref: []const u8,
) ?[]const []const u8 {
    const c = cliFor(provider) orelse return null;
    if (prog.len == 0) return null;
    if (ref.len == 0) return null;
    if (storage.len < close_argv_max) return null;

    var n: usize = 0;
    storage[n] = prog;
    n += 1;
    storage[n] = c.noun;
    n += 1;
    storage[n] = "close";
    n += 1;
    storage[n] = ref;
    n += 1;
    return storage[0..n];
}

/// Fields requested from `gh pr checks --json`. `bucket` earns its place:
/// `state` is free-form (`SUCCESS`, `FAILURE`, `NEUTRAL`), `bucket` is gh's own
/// rollup into pass/fail/pending/skipping/cancel, which a UI can switch on.
pub const GH_CHECKS_JSON_FIELDS = "bucket,name,state,link,workflow,startedAt,completedAt";

/// Upper bound on `checksArgv` output.
pub const checks_argv_max = 6;

/// `<gh> pr checks [<ref>] --json <field list>`. Null for every provider but
/// GitHub: glab has no `mr checks` (its CI surface needs a pipeline id we do
/// not have).
pub fn checksArgv(storage: [][]const u8, provider: PrProvider, prog: []const u8, ref: []const u8) ?[]const []const u8 {
    switch (provider) {
        .github => {},
        .gitlab, .generic => return null,
    }
    if (storage.len < checks_argv_max) return null;

    var n: usize = 0;
    storage[n] = prog;
    n += 1;
    storage[n] = "pr";
    n += 1;
    storage[n] = "checks";
    n += 1;
    if (ref.len > 0) {
        storage[n] = ref;
        n += 1;
    }
    storage[n] = "--json";
    n += 1;
    storage[n] = GH_CHECKS_JSON_FIELDS;
    n += 1;
    return storage[0..n];
}

/// Upper bound on `runJobsArgv` output (prog, run, view, id, --json, jobs).
pub const run_jobs_argv_max = 6;

/// `<gh> run view <run_id> --json jobs` — the second hop behind the Checks tab.
/// `gh pr checks` reports jobs; only a run's step list answers "which task
/// failed". `jobs` only: the run's own fields are already on the check rows.
pub fn runJobsArgv(storage: [][]const u8, prog: []const u8, run_id: []const u8) ?[]const []const u8 {
    if (storage.len < run_jobs_argv_max) return null;
    if (run_id.len == 0) return null;

    var n: usize = 0;
    storage[n] = prog;
    n += 1;
    storage[n] = "run";
    n += 1;
    storage[n] = "view";
    n += 1;
    storage[n] = run_id;
    n += 1;
    storage[n] = "--json";
    n += 1;
    storage[n] = "jobs";
    n += 1;
    return storage[0..n];
}

/// `<run_id>` out of `…/actions/runs/<run_id>/job/<job_id>`. Borrows from
/// `link`. Null for a non-Actions check (CircleCI, a bot-posted status): there
/// is no run to drill into, which is "no steps", not "the lookup failed".
pub fn runIdFromJobLink(link: []const u8) ?[]const u8 {
    return digitsAfter(link, "/actions/runs/");
}

/// `<job_id>` at the tail of an Actions job link. How a check row finds its job
/// in `run view --json jobs` (whose jobs carry a `databaseId`).
pub fn jobIdFromJobLink(link: []const u8) ?[]const u8 {
    return digitsAfter(link, "/job/");
}

/// The digits right after `marker`, stopping at the first `/`, `?` or `#`.
/// Null when absent, empty, or non-numeric — a malformed link must not smuggle
/// a fragment through as an id.
fn digitsAfter(link: []const u8, marker: []const u8) ?[]const u8 {
    const at = std.mem.indexOf(u8, link, marker) orelse return null;
    const rest = link[at + marker.len ..];
    const end = std.mem.indexOfAny(u8, rest, "/?#") orelse rest.len;
    const digits = rest[0..end];
    if (digits.len == 0) return null;
    for (digits) |c| {
        if (!std.ascii.isDigit(c)) return null;
    }
    return digits;
}

/// Pick the URL out of a forge CLI's stdout after a successful create.
pub fn extractCreatedUrl(stdout: []const u8) []const u8 {
    var last_non_empty: []const u8 = "";
    var it = std.mem.splitBackwardsAny(u8, stdout, "\n");
    while (it.next()) |raw_line| {
        const line = std.mem.trim(u8, raw_line, " \t\r");
        if (line.len == 0) continue;
        if (last_non_empty.len == 0) last_non_empty = line;
        if (isHttpUrl(line)) return line;
    }
    return last_non_empty;
}

/// Whether `s` is a bare `http(s)://…` URL with a non-empty host.
/// Deliberately strict: a progress line like "✓ Created merge request
/// for branch-x!" is not a URL, and neither is an ANSI-decorated one.
pub fn isHttpUrl(s: []const u8) bool {
    const scheme_end = std.mem.indexOf(u8, s, "://") orelse return false;
    if (scheme_end == 0) return false;
    const scheme = s[0..scheme_end];
    if (!std.ascii.eqlIgnoreCase(scheme, "http") and !std.ascii.eqlIgnoreCase(scheme, "https")) return false;
    const after = s[scheme_end + 3 ..];
    const slash = std.mem.indexOfScalar(u8, after, '/') orelse after.len;
    return slash > 0;
}

// ─── Tests ───────────────────────────────────────────────────────────────

fn expectArgv(got: ?[]const []const u8, expected: []const []const u8) !void {
    const argv = got orelse return error.NullArgv;
    try std.testing.expectEqual(expected.len, argv.len);
    for (expected, argv) |want, have| try std.testing.expectEqualStrings(want, have);
}

test "cliFor maps providers onto their CLI, and generic onto none" {
    try std.testing.expectEqual(GH_CLI.program, cliFor(.github).?.program);
    try std.testing.expectEqualStrings("pr", cliFor(.github).?.noun);
    try std.testing.expectEqual(GLAB_CLI.program, cliFor(.gitlab).?.program);
    try std.testing.expectEqualStrings("mr", cliFor(.gitlab).?.noun);
    try std.testing.expectEqualStrings("merge request", cliFor(.gitlab).?.label);
    try std.testing.expectEqualStrings("MR", cliFor(.gitlab).?.short);
    try std.testing.expectEqualStrings("GitLab", cliFor(.gitlab).?.forge);
    try std.testing.expect(cliFor(.generic) == null);
    try std.testing.expect(!hasCli(.generic));
    try std.testing.expect(hasCli(.github) and hasCli(.gitlab));
}

test "viewArgv builds `gh pr view` with --json and no ref" {
    var storage: [view_argv_max][]const u8 = undefined;
    try expectArgv(viewArgv(&storage, .github, "gh", ""), &.{ "gh", "pr", "view", "--json", GH_JSON_FIELDS });
}

test "viewArgv builds `glab mr view` with --output json and no ref" {
    var storage: [view_argv_max][]const u8 = undefined;
    try expectArgv(viewArgv(&storage, .gitlab, "glab", ""), &.{ "glab", "mr", "view", "--output", "json" });
}

test "viewArgv passes a number / IID / URL / branch through verbatim" {
    var storage: [view_argv_max][]const u8 = undefined;
    try expectArgv(viewArgv(&storage, .github, "gh", "42"), &.{ "gh", "pr", "view", "42", "--json", GH_JSON_FIELDS });
    try expectArgv(viewArgv(&storage, .gitlab, "glab", "7"), &.{ "glab", "mr", "view", "7", "--output", "json" });
    try expectArgv(viewArgv(&storage, .gitlab, "glab", "https://gitlab.com/g/s/r/-/merge_requests/7"), &.{ "glab", "mr", "view", "https://gitlab.com/g/s/r/-/merge_requests/7", "--output", "json" });
    try expectArgv(viewArgv(&storage, .github, "gh", "feature-x"), &.{ "gh", "pr", "view", "feature-x", "--json", GH_JSON_FIELDS });
}

test "viewArgv returns null for a provider with no CLI" {
    var storage: [view_argv_max][]const u8 = undefined;
    try std.testing.expect(viewArgv(&storage, .generic, "gh", "") == null);
}

test "createArgv keeps the historical `gh pr create` shape" {
    var storage: [create_argv_max][]const u8 = undefined;
    try expectArgv(createArgv(&storage, .github, "gh", "main", "worktree/x", "T", "B"), &.{ "gh", "pr", "create", "--base", "main", "--title", "T", "--body", "B" });
}

test "createArgv for gitlab passes --source-branch and --yes" {
    // --yes is load-bearing: without it glab blocks on an interactive
    // confirm in a non-tty child and the create burns its 60s budget.
    var storage: [create_argv_max][]const u8 = undefined;
    try expectArgv(createArgv(&storage, .gitlab, "glab", "main", "worktree/x", "T", "B"), &.{ "glab", "mr", "create", "--source-branch", "worktree/x", "--target-branch", "main", "--title", "T", "--description", "B", "--yes" });
}

test "createArgv returns null for a provider with no CLI" {
    var storage: [create_argv_max][]const u8 = undefined;
    try std.testing.expect(createArgv(&storage, .generic, "gh", "main", "b", "T", "B") == null);
}

test "extractCreatedUrl takes the URL past a glab preamble" {
    // The exact shape `glab mr create` prints: banner, blank line, link.
    const stdout =
        \\Creating merge request for worktree/x on gitlab.com
        \\
        \\https://gitlab.com/group/sub/repo/-/merge_requests/7
        \\
    ;
    try std.testing.expectEqualStrings("https://gitlab.com/group/sub/repo/-/merge_requests/7", extractCreatedUrl(stdout));
}

test "extractCreatedUrl still works for a bare gh-style URL" {
    try std.testing.expectEqualStrings("https://github.com/acme/app/pull/42", extractCreatedUrl("https://github.com/acme/app/pull/42\n"));
    try std.testing.expectEqualStrings("https://github.com/acme/app/pull/42", extractCreatedUrl("https://github.com/acme/app/pull/42"));
}

test "extractCreatedUrl falls back to the last non-empty line" {
    // No URL anywhere: better to hand the caller whatever the CLI last
    // said than to store "" and lose the whole answer.
    try std.testing.expectEqualStrings("done", extractCreatedUrl("creating...\ndone\n\n"));
    try std.testing.expectEqualStrings("", extractCreatedUrl("\n\n  \n"));
}

test "isHttpUrl accepts http(s) with a host and rejects prose" {
    try std.testing.expect(isHttpUrl("https://gitlab.com/g/s/r/-/merge_requests/7"));
    try std.testing.expect(isHttpUrl("http://git.corp.example.com/a/b/pull/9"));
    try std.testing.expect(!isHttpUrl("Creating merge request for worktree/x"));
    try std.testing.expect(!isHttpUrl("://gitlab.com/a"));
    try std.testing.expect(!isHttpUrl("https:///a/b"));
    try std.testing.expect(!isHttpUrl("gitlab.com/a/b"));
}

test "checksArgv builds `gh pr checks` with --json and no ref" {
    var storage: [checks_argv_max][]const u8 = undefined;
    try expectArgv(checksArgv(&storage, .github, "gh", ""), &.{ "gh", "pr", "checks", "--json", GH_CHECKS_JSON_FIELDS });
}

test "checksArgv passes a number / URL / branch through verbatim" {
    var storage: [checks_argv_max][]const u8 = undefined;
    try expectArgv(checksArgv(&storage, .github, "gh", "42"), &.{ "gh", "pr", "checks", "42", "--json", GH_CHECKS_JSON_FIELDS });
    try expectArgv(checksArgv(&storage, .github, "gh", "https://github.com/acme/app/pull/42"), &.{ "gh", "pr", "checks", "https://github.com/acme/app/pull/42", "--json", GH_CHECKS_JSON_FIELDS });
}

test "checksArgv refuses every forge but GitHub" {
    // glab has no `mr checks`; returning null is what lets the handler
    // answer 422 ("not supported") instead of 200 with zero checks,
    // which a UI reads as "everything passed".
    var storage: [checks_argv_max][]const u8 = undefined;
    try std.testing.expect(checksArgv(&storage, .gitlab, "glab", "7") == null);
    try std.testing.expect(checksArgv(&storage, .generic, "gh", "") == null);
}

test "runJobsArgv builds `gh run view <id> --json jobs`" {
    var storage: [run_jobs_argv_max][]const u8 = undefined;
    try expectArgv(runJobsArgv(&storage, "gh", "37146940187"), &.{ "gh", "run", "view", "37146940187", "--json", "jobs" });
}

test "runJobsArgv rejects an empty run id and an undersized buffer" {
    var storage: [run_jobs_argv_max][]const u8 = undefined;
    try std.testing.expect(runJobsArgv(&storage, "gh", "") == null);
    var tiny: [run_jobs_argv_max - 1][]const u8 = undefined;
    try std.testing.expect(runJobsArgv(&tiny, "gh", "1") == null);
}

test "runIdFromJobLink pulls the run id out of an Actions job link" {
    try std.testing.expectEqualStrings("37146940187", runIdFromJobLink("https://github.com/acme/app/actions/runs/37146940187/job/111272848907").?);
    // Trailing query/fragment and a missing /job segment both terminate
    // the id the same way.
    try std.testing.expectEqualStrings("12", runIdFromJobLink("https://github.com/acme/app/actions/runs/12?checkSuite=1").?);
    try std.testing.expectEqualStrings("7", runIdFromJobLink("https://github.com/acme/app/actions/runs/7").?);
}

test "runIdFromJobLink returns null for a link that is not an Actions job" {
    // An external check has no run to drill into — the caller must read
    // this as "no steps", never as "the lookup failed".
    try std.testing.expect(runIdFromJobLink("https://circleci.com/gh/acme/app/1") == null);
    try std.testing.expect(runIdFromJobLink("https://api.github.com/repos/acme/app") == null);
    try std.testing.expect(runIdFromJobLink("") == null);
    // Present marker, non-numeric segment: a malformed link must not
    // smuggle "abc" through as a run id.
    try std.testing.expect(runIdFromJobLink("https://github.com/a/b/actions/runs/abc/job/1") == null);
    try std.testing.expect(runIdFromJobLink("https://github.com/a/b/actions/runs//job/1") == null);
}

test "jobIdFromJobLink pulls the job id, and only from an Actions link" {
    try std.testing.expectEqualStrings("111272848907", jobIdFromJobLink("https://github.com/acme/app/actions/runs/37146940187/job/111272848907").?);
    try std.testing.expectEqualStrings("9", jobIdFromJobLink("https://github.com/a/b/actions/runs/1/job/9?checkSuite=2").?);
    // A link with no job segment has no job to match a run against.
    try std.testing.expect(jobIdFromJobLink("https://github.com/acme/app/actions/runs/37146940187") == null);
    try std.testing.expect(jobIdFromJobLink("https://circleci.com/gh/acme/app/1") == null);
    try std.testing.expect(jobIdFromJobLink("") == null);
}

// ─── mergeArgv ───────────────────────────────────────────────────────────

fn hasArg(argv: []const []const u8, needle: []const u8) bool {
    for (argv) |a| {
        if (std.mem.eql(u8, a, needle)) return true;
    }
    return false;
}

test "MergeMethod round-trips its wire names and refuses everything else" {
    try std.testing.expectEqual(MergeMethod.merge, MergeMethod.fromString("merge").?);
    try std.testing.expectEqual(MergeMethod.squash, MergeMethod.fromString("squash").?);
    try std.testing.expectEqual(MergeMethod.rebase, MergeMethod.fromString("rebase").?);
    try std.testing.expectEqualStrings("squash", MergeMethod.squash.toString());
    // The contract the endpoint leans on: an empty or unknown method is
    // refused BEFORE anything is spawned. `gh pr merge` with no strategy
    // flag prompts for the method, and a non-tty child cannot answer.
    try std.testing.expect(MergeMethod.fromString("") == null);
    try std.testing.expect(MergeMethod.fromString("auto") == null);
    try std.testing.expect(MergeMethod.fromString("Squash") == null);
}

test "mergeArgv: github passes exactly one strategy flag" {
    var buf: [merge_argv_max][]const u8 = undefined;
    try expectArgv(mergeArgv(&buf, .github, "gh", "891", .merge, .{}), &.{ "gh", "pr", "merge", "891", "--merge" });
    try expectArgv(mergeArgv(&buf, .github, "gh", "891", .squash, .{}), &.{ "gh", "pr", "merge", "891", "--squash" });
    try expectArgv(mergeArgv(&buf, .github, "gh", "891", .rebase, .{}), &.{ "gh", "pr", "merge", "891", "--rebase" });
}

test "mergeArgv: github carries the head guard, the message and delete-branch" {
    var buf: [merge_argv_max][]const u8 = undefined;
    try expectArgv(
        mergeArgv(&buf, .github, "gh", "https://github.com/a/b/pull/891", .squash, .{
            .delete_branch = true,
            .head_sha = "4f21c9e",
            .subject = "fix(chatview): land where the reader left it (#891)",
            .body = "Squashed body",
        }),
        &.{
            "gh",                  "pr",
            "merge",               "https://github.com/a/b/pull/891",
            "--squash",            "--delete-branch",
            "--match-head-commit", "4f21c9e",
            "--subject",           "fix(chatview): land where the reader left it (#891)",
            "--body",              "Squashed body",
        },
    );
}

test "mergeArgv: a merge is never ARMED instead of performed" {
    // The regression this pins: `gh pr merge --auto` exits 0 with the PR
    // still open.
    var buf: [merge_argv_max][]const u8 = undefined;
    const argv = mergeArgv(&buf, .github, "gh", "891", .squash, .{ .head_sha = "abc123" }).?;
    try std.testing.expect(!hasArg(argv, "--auto"));
    try std.testing.expect(!hasArg(argv, "--disable-auto"));
}

test "mergeArgv: gitlab forces --yes and --auto-merge=false" {
    // Both flags are load-bearing and neither is optional: - without
    // -y/--yes, `glab mr merge` blocks on a confirmation prompt that a
    // non-tty child can never answer (the same trap `createArgv` documents
    var buf: [merge_argv_max][]const u8 = undefined;
    try expectArgv(
        mergeArgv(&buf, .gitlab, "glab", "7", .squash, .{ .delete_branch = true, .head_sha = "4f21c9e" }),
        &.{ "glab", "mr", "merge", "7", "--squash", "--remove-source-branch", "--sha", "4f21c9e", "--yes", "--auto-merge=false" },
    );
}

test "mergeArgv: gitlab's plain merge passes no strategy flag" {
    // `glab mr merge` with no strategy IS a merge commit. `--merge` is not a
    // glab flag, so emitting it would fail the request outright.
    var buf: [merge_argv_max][]const u8 = undefined;
    try expectArgv(
        mergeArgv(&buf, .gitlab, "glab", "7", .merge, .{}),
        &.{ "glab", "mr", "merge", "7", "--yes", "--auto-merge=false" },
    );
    try std.testing.expect(MergeMethod.merge.flag(.gitlab) == null);
    try std.testing.expectEqualStrings("--merge", MergeMethod.merge.flag(.github).?);
}

test "mergeArgv: gitlab separates the squash message from the merge message" {
    var buf: [merge_argv_max][]const u8 = undefined;
    const squashed = mergeArgv(&buf, .gitlab, "glab", "7", .squash, .{ .subject = "S" }).?;
    try std.testing.expect(hasArg(squashed, "--squash-message"));
    try std.testing.expect(!hasArg(squashed, "--message"));
    const merged = mergeArgv(&buf, .gitlab, "glab", "7", .merge, .{ .subject = "S" }).?;
    try std.testing.expect(hasArg(merged, "--message"));
    try std.testing.expect(!hasArg(merged, "--squash-message"));
}

test "mergeArgv: an empty ref means the current branch, and empty options are omitted" {
    var buf: [merge_argv_max][]const u8 = undefined;
    try expectArgv(mergeArgv(&buf, .github, "gh", "", .squash, .{}), &.{ "gh", "pr", "merge", "--squash" });
}

test "mergeArgv: null for a provider with no CLI, an empty program, or a small buffer" {
    var buf: [merge_argv_max][]const u8 = undefined;
    try std.testing.expect(mergeArgv(&buf, .generic, "gh", "1", .squash, .{}) == null);
    try std.testing.expect(mergeArgv(&buf, .github, "", "1", .squash, .{}) == null);
    var tiny: [merge_argv_max - 1][]const u8 = undefined;
    try std.testing.expect(mergeArgv(&tiny, .github, "1", "1", .squash, .{}) == null);
}

// ─── listArgv / closeArgv ────────────────────────────────────────────────

test "ListState round-trips its wire names, defaults empty to open, and refuses the rest" {
    try std.testing.expectEqual(ListState.open, ListState.fromString("open").?);
    try std.testing.expectEqual(ListState.closed, ListState.fromString("closed").?);
    try std.testing.expectEqual(ListState.merged, ListState.fromString("merged").?);
    try std.testing.expectEqual(ListState.all, ListState.fromString("all").?);
    // A caller that omits the parameter gets the forge's own default.
    try std.testing.expectEqual(ListState.open, ListState.fromString("").?);
    // `OPEN` is the gh JSON state, not a filter value: accepting either
    // case here would let a query param mean two different things.
    try std.testing.expect(ListState.fromString("OPEN") == null);
    try std.testing.expect(ListState.fromString("opened") == null);
    try std.testing.expect(ListState.fromString("draft") == null);
    try std.testing.expectEqualStrings("closed", ListState.closed.toString());
}

test "listArgv: github passes the state by value, the limit, and a list-only field set" {
    var buf: [list_argv_max][]const u8 = undefined;
    var lb: [16]u8 = undefined;
    try expectArgv(
        listArgv(&buf, &lb, .github, "gh", .open, 30),
        &.{ "gh", "pr", "list", "--state", "open", "--limit", "30", "--json", GH_LIST_JSON_FIELDS },
    );
    try expectArgv(
        listArgv(&buf, &lb, .github, "gh", .closed, 7),
        &.{ "gh", "pr", "list", "--state", "closed", "--limit", "7", "--json", GH_LIST_JSON_FIELDS },
    );
}

test "listArgv: gitlab maps the four states onto its four booleans" {
    var buf: [list_argv_max][]const u8 = undefined;
    var lb: [16]u8 = undefined;

    // `open` is glab's default, so no state flag at all — there is no
    // `--open`, and `--opened` is not a glab flag.
    const open = listArgv(&buf, &lb, .gitlab, "glab", .open, 30).?;
    try std.testing.expect(!hasArg(open, "--closed") and !hasArg(open, "--merged") and !hasArg(open, "--all"));
    try expectArgv(
        open,
        &.{ "glab", "mr", "list", "-P", "30", "-o", "updated_at", "-S", "desc", "-F", "json" },
    );

    try expectArgv(
        listArgv(&buf, &lb, .gitlab, "glab", .closed, 30),
        &.{ "glab", "mr", "list", "--closed", "-P", "30", "-o", "updated_at", "-S", "desc", "-F", "json" },
    );
    try expectArgv(
        listArgv(&buf, &lb, .gitlab, "glab", .merged, 30),
        &.{ "glab", "mr", "list", "--merged", "-P", "30", "-o", "updated_at", "-S", "desc", "-F", "json" },
    );
    try expectArgv(
        listArgv(&buf, &lb, .gitlab, "glab", .all, 30),
        &.{ "glab", "mr", "list", "--all", "-P", "30", "-o", "updated_at", "-S", "desc", "-F", "json" },
    );
}

test "listArgv: null for no CLI, an empty program, a zero limit, or too little storage" {
    var buf: [list_argv_max][]const u8 = undefined;
    var lb: [16]u8 = undefined;
    try std.testing.expect(listArgv(&buf, &lb, .generic, "gh", .open, 30) == null);
    try std.testing.expect(listArgv(&buf, &lb, .github, "", .open, 30) == null);
    // A zero limit would ask for nothing and render as an empty list, which
    // is indistinguishable from "there are none" — refused, not clamped.
    try std.testing.expect(listArgv(&buf, &lb, .github, "gh", .open, 0) == null);
    var tiny: [list_argv_max - 1][]const u8 = undefined;
    try std.testing.expect(listArgv(&tiny, &lb, .github, "gh", .open, 30) == null);
    // 5 bytes cannot hold "30" plus the terminator's headroom for larger
    // limits; bufPrint fails, and the builder must not hand back a
    // half-built argv.
    var small_lb: [1]u8 = undefined;
    try std.testing.expect(listArgv(&buf, &small_lb, .github, "gh", .open, 30) == null);
}

test "closeArgv: a plain close, with no comment and no branch deletion" {
    var buf: [close_argv_max][]const u8 = undefined;
    try expectArgv(closeArgv(&buf, .github, "gh", "893"), &.{ "gh", "pr", "close", "893" });
    try expectArgv(closeArgv(&buf, .gitlab, "glab", "7"), &.{ "glab", "mr", "close", "7" });

    // The two flags that must never appear. `--comment` has no glab
    // counterpart (so it would be a GitHub-only lie), and a branch deletion
    // here would delete the directory a session worktree lives in.
    const argv = closeArgv(&buf, .github, "gh", "893").?;
    try std.testing.expect(!hasArg(argv, "--comment"));
    try std.testing.expect(!hasArg(argv, "-c"));
    try std.testing.expect(!hasArg(argv, "--delete-branch"));
    try std.testing.expect(!hasArg(argv, "--remove-source-branch"));
}

test "closeArgv: a number, an IID, a URL or a branch all pass through verbatim" {
    var buf: [close_argv_max][]const u8 = undefined;
    try expectArgv(closeArgv(&buf, .github, "gh", "https://github.com/acme/app/pull/42"), &.{ "gh", "pr", "close", "https://github.com/acme/app/pull/42" });
    try expectArgv(closeArgv(&buf, .github, "gh", "worktree/feature-x"), &.{ "gh", "pr", "close", "worktree/feature-x" });
}

test "closeArgv: an empty ref is refused rather than closing the current branch" {
    var buf: [close_argv_max][]const u8 = undefined;
    try std.testing.expect(closeArgv(&buf, .github, "gh", "") == null);
    try std.testing.expect(closeArgv(&buf, .gitlab, "glab", "") == null);
    try std.testing.expect(closeArgv(&buf, .generic, "gh", "1") == null);
    try std.testing.expect(closeArgv(&buf, .github, "", "1") == null);
    var tiny: [close_argv_max - 1][]const u8 = undefined;
    try std.testing.expect(closeArgv(&tiny, .github, "gh", "1") == null);
}
