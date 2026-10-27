//! `GET /api/git/pr/checks?path=<repo>[&pr=<n|url>][&provider=github]` Two
//! hops, because the question has two levels: 1.

const std = @import("std");
const http_response = @import("http_response.zig");
const pabrik_core = @import("pabrikcore");
const gserverz = pabrik_core.gserverz;
const git_route = @import("git_route.zig");
const pr_provider = pabrik_core.pr_provider;
const pr_cli = pabrik_core.pr_cli;
const run_captured = @import("helpers").run_captured;
// Provider resolution + the error-detail helper are shared with the status
// endpoint: two endpoints that disagree about which forge a repo is on would
// show a GitHub user GitLab error text.
const pr_status = @import("git_pr_status.zig");

const ChecksError = error{
    NotARepository,
    CliMissing,
    /// No CLI can answer: gitlab has no `mr checks`, generic has no CLI.
    ForgeUnsupported,
    NoAssociatedPr,
    FetchFailed,
};

pub const CHECKS_TIMEOUT_MS: u32 = 20_000;
/// Shorter than hop 1: the panel waits on the whole request, and degrading one
/// job's steps beats degrading every row.
pub const RUN_VIEW_TIMEOUT_MS: u32 = 10_000;

/// `run view --json jobs` is the big one (every job × every step). 1 MiB is past
/// any real workflow and still bounds one request.
const CHECKS_MAX_OUTPUT_BYTES: usize = 1024 * 1024;

/// Each run lookup is a network round trip. Past this we return what we have
/// and set `steps_truncated` so the panel says "partial" instead of showing a
/// quietly short list.
pub const MAX_RUN_LOOKUPS: usize = 6;

/// gh prints this for a job that has not finished. It is not a timestamp.
const ZERO_TIME = "0001-01-01T00:00:00Z";

const GhCheckRow = struct {
    bucket: []const u8 = "",
    name: []const u8 = "",
    state: []const u8 = "",
    link: []const u8 = "",
    workflow: []const u8 = "",
    startedAt: []const u8 = "",
    completedAt: []const u8 = "",
};

const GhRunStep = struct {
    name: []const u8 = "",
    number: u32 = 0,
    conclusion: []const u8 = "",
    status: []const u8 = "",
    startedAt: []const u8 = "",
    completedAt: []const u8 = "",
};

const GhRunJob = struct {
    /// Matches the id at the tail of a check row's `link`.
    databaseId: i64 = 0,
    name: []const u8 = "",
    conclusion: []const u8 = "",
    steps: []const GhRunStep = &.{},
};

const GhRunJobs = struct {
    jobs: []const GhRunJob = &.{},
};

/// Injectable so the tests can point the whole path at a fixture script.
pub const Programs = struct {
    gh: []const u8 = "gh",

    fn forProvider(self: Programs, provider: pr_provider.PrProvider) []const u8 {
        return switch (provider) {
            .github => self.gh,
            .gitlab, .generic => "",
        };
    }
};

fn cleanTime(s: []const u8) []const u8 {
    if (std.mem.eql(u8, s, ZERO_TIME)) return "";
    return s;
}

/// Only red jobs get a run lookup: a passing job's steps are noise in a panel
/// about what broke, and a pending job's last step is still running, so the
/// "failing step" would be a moving target.
fn wantsSteps(bucket: []const u8) bool {
    return std.ascii.eqlIgnoreCase(bucket, "fail") or
        std.ascii.eqlIgnoreCase(bucket, "cancel");
}

/// A run we looked up (or failed to). `stdout` is the DUPED `gh run view`
/// payload, parsed later in `buildResponse`.
const RunLookup = struct {
    run_id: []const u8,
    stdout: []u8 = "",
    /// Non-empty renders on every failed entry in this run, so "could not read
    /// the steps" never looks like "there were none".
    err: []const u8 = "",
};

/// `gh pr checks` in `path`. Returns stdout (owned), or "" when the PR has no
/// checks — gh exits non-zero with "no checks reported…" there, and that is a
/// real answer, not a failure.
fn runChecks(
    allocator: std.mem.Allocator,
    io: std.Io,
    prog: []const u8,
    path: []const u8,
    pr_arg: []const u8,
    fetch_detail: *?[]u8,
) ![]u8 {
    var argv_buf: [pr_cli.checks_argv_max][]const u8 = undefined;
    // `.github` is not a guess: useCase refused every other provider first.
    const argv = pr_cli.checksArgv(&argv_buf, .github, prog, pr_arg) orelse return error.ForgeUnsupported;

    var res = run_captured.run(allocator, io, argv, .{
        .cwd = path,
        .max_output_bytes = CHECKS_MAX_OUTPUT_BYTES,
        .timeout_ms = CHECKS_TIMEOUT_MS,
    }) catch |err| switch (err) {
        error.FileNotFound => return error.CliMissing,
        error.AccessDenied, error.PermissionDenied, error.InvalidExe => return error.CliMissing,
        else => {
            var buf: [128]u8 = undefined;
            pr_status.setFetchDetail(allocator, fetch_detail, std.fmt.bufPrint(&buf, "failed to run gh pr checks ({s})", .{@errorName(err)}) catch "failed to run gh pr checks");
            return error.FetchFailed;
        },
    };
    defer res.deinit(allocator);

    if (res.timed_out) {
        var buf: [96]u8 = undefined;
        pr_status.setFetchDetail(allocator, fetch_detail, std.fmt.bufPrint(&buf, "gh pr checks timed out after {d}s", .{CHECKS_TIMEOUT_MS / 1000}) catch "gh pr checks timed out");
        return error.FetchFailed;
    }

    // gh exits 8 ("checks pending") WITH a usable payload, so the exit code is
    // only read when stdout is empty.
    var no_checks = false;
    switch (res.term) {
        .exited => |code| {
            if (std.mem.trim(u8, res.stdout, " \n\r").len > 0) {
                no_checks = false;
            } else {
                const stderr_trimmed = std.mem.trim(u8, res.stderr, " \n\r");
                if (stderr_trimmed.len == 0) {
                    var code_buf: [96]u8 = undefined;
                    pr_status.setFetchDetail(allocator, fetch_detail, std.fmt.bufPrint(&code_buf, "gh pr checks exited with code {d} (no stderr)", .{code}) catch "gh pr checks failed (no stderr)");
                    return error.FetchFailed;
                }
                if (std.ascii.indexOfIgnoreCase(stderr_trimmed, "no check") != null) {
                    no_checks = true;
                } else if (std.ascii.indexOfIgnoreCase(stderr_trimmed, "no pull request") != null) {
                    return error.NoAssociatedPr;
                } else {
                    pr_status.setFetchDetail(allocator, fetch_detail, stderr_trimmed);
                    return error.FetchFailed;
                }
            }
        },
        else => {
            pr_status.setFetchDetail(allocator, fetch_detail, "gh pr checks terminated by signal");
            return error.FetchFailed;
        },
    }

    return allocator.dupe(u8, if (no_checks) "" else res.stdout);
}

/// `gh run view <run_id> --json jobs`. Never fails the request: a bad run id, a
/// network blip, or a collected run all come back as a `RunLookup.err` the panel
/// renders next to the job. Losing one step list must not lose 40 check rows.
fn lookupRun(
    allocator: std.mem.Allocator,
    io: std.Io,
    prog: []const u8,
    path: []const u8,
    run_id: []const u8,
) RunLookup {
    var argv_buf: [pr_cli.run_jobs_argv_max][]const u8 = undefined;
    const argv = pr_cli.runJobsArgv(&argv_buf, prog, run_id) orelse
        return .{ .run_id = run_id, .err = "could not build the run lookup command" };

    var res = run_captured.run(allocator, io, argv, .{
        .cwd = path,
        .max_output_bytes = CHECKS_MAX_OUTPUT_BYTES,
        .timeout_ms = RUN_VIEW_TIMEOUT_MS,
    }) catch |err| {
        var buf: [96]u8 = undefined;
        return .{
            .run_id = run_id,
            .err = std.fmt.bufPrint(&buf, "run {s} lookup failed ({s})", .{ run_id, @errorName(err) }) catch "run lookup failed",
        };
    };
    defer res.deinit(allocator);

    if (res.timed_out) return .{ .run_id = run_id, .err = "run lookup timed out" };
    switch (res.term) {
        .exited => |code| {
            if (code != 0) {
                const stderr_trimmed = std.mem.trim(u8, res.stderr, " \n\r");
                return .{
                    .run_id = run_id,
                    .err = if (stderr_trimmed.len > 0)
                        allocator.dupe(u8, stderr_trimmed[0..@min(stderr_trimmed.len, 200)]) catch "run lookup failed"
                    else
                        "run lookup failed",
                };
            }
        },
        else => return .{ .run_id = run_id, .err = "run lookup terminated by signal" },
    }

    // Duped so the parse in buildResponse reads live bytes.
    const owned = allocator.dupe(u8, res.stdout) catch
        return .{ .run_id = run_id, .err = "run lookup ran out of memory" };
    return .{ .run_id = run_id, .stdout = owned };
}

/// By id, not by name: a matrix workflow can repeat a name across runs, and a
/// wrong job's steps are worse than no steps.
fn findJob(jobs: []const GhRunJob, database_id: i64) ?GhRunJob {
    for (jobs) |j| {
        if (j.databaseId == database_id) return j;
    }
    return null;
}

fn tally(summary: *http_response.GitPrChecksSummary, bucket: []const u8) void {
    summary.total += 1;
    if (std.ascii.eqlIgnoreCase(bucket, "pass")) {
        summary.passed += 1;
    } else if (std.ascii.eqlIgnoreCase(bucket, "fail")) {
        summary.failed += 1;
    } else if (std.ascii.eqlIgnoreCase(bucket, "pending")) {
        summary.pending += 1;
    } else if (std.ascii.eqlIgnoreCase(bucket, "cancel")) {
        summary.cancelled += 1;
    } else {
        // `skipping` plus anything a future gh invents. Counting the unknown as
        // skipped keeps total == sum(parts), which the panel's badge assumes.
        summary.skipped += 1;
    }
}

/// Parse the checks payload and fetch steps for the red jobs.
fn buildResponse(
    allocator: std.mem.Allocator,
    io: std.Io,
    prog: []const u8,
    path: []const u8,
    pr_arg: []const u8,
    trimmed: []const u8,
) !http_response.GitPrChecksResponse {
    if (trimmed.len == 0) {
        return .{
            .provider = try allocator.dupe(u8, "github"),
            .pr_url = try allocator.dupe(u8, pr_arg),
            .checks = &.{},
        };
    }

    // parseFromSliceLeaky BORROWS strings from `trimmed`, which the caller
    // frees — so every string is duped below. Numbers copy by value.
    const rows = try std.json.parseFromSliceLeaky([]const GhCheckRow, allocator, trimmed, .{ .ignore_unknown_fields = true });

    var entries: std.ArrayList(http_response.GitPrCheckEntry) = .empty;
    defer entries.deinit(allocator);
    var summary: http_response.GitPrChecksSummary = .{};

    for (rows) |row| {
        tally(&summary, row.bucket);
        try entries.append(allocator, .{
            .name = try allocator.dupe(u8, row.name),
            .workflow = try allocator.dupe(u8, row.workflow),
            .bucket = try allocator.dupe(u8, row.bucket),
            .state = try allocator.dupe(u8, row.state),
            .link = try allocator.dupe(u8, row.link),
            .started_at = try allocator.dupe(u8, cleanTime(row.startedAt)),
            .completed_at = try allocator.dupe(u8, cleanTime(row.completedAt)),
        });
    }

    var lookups: std.ArrayList(RunLookup) = .empty;
    defer lookups.deinit(allocator);
    var budget_used: usize = 0;
    var budget_exhausted = false;

    for (entries.items) |*entry| {
        if (!wantsSteps(entry.bucket)) continue;
        // An external checker has no Actions run: no steps is a fact about the
        // check, not a lookup failure, so it is skipped silently.
        const run_id = pr_cli.runIdFromJobLink(entry.link) orelse continue;

        var seen = false;
        for (lookups.items) |l| {
            if (std.mem.eql(u8, l.run_id, run_id)) {
                seen = true;
                break;
            }
        }
        if (seen) continue;

        if (budget_used >= MAX_RUN_LOOKUPS) {
            budget_exhausted = true;
            continue;
        }
        budget_used += 1;
        try lookups.append(allocator, lookupRun(allocator, io, prog, path, run_id));
    }

    for (entries.items) |*entry| {
        if (!wantsSteps(entry.bucket)) continue;
        const run_id = pr_cli.runIdFromJobLink(entry.link) orelse continue;
        const job_id_str = pr_cli.jobIdFromJobLink(entry.link) orelse continue;
        const job_id = std.fmt.parseInt(i64, job_id_str, 10) catch continue;

        var lookup: ?RunLookup = null;
        for (lookups.items) |l| {
            if (std.mem.eql(u8, l.run_id, run_id)) {
                lookup = l;
                break;
            }
        }
        if (lookup == null) {
            // The run was never fetched — budget. Say so rather than show a red
            // job with no steps and no explanation.
            entry.steps_error = if (budget_exhausted)
                "step details were not fetched — too many failing workflows for one lookup"
            else
                "step details were not fetched";
            continue;
        }
        const l = lookup.?;
        if (l.err.len > 0) {
            entry.steps_error = try allocator.dupe(u8, l.err);
            continue;
        }
        const jobs = std.json.parseFromSliceLeaky(GhRunJobs, allocator, std.mem.trim(u8, l.stdout, " \n\r"), .{ .ignore_unknown_fields = true }) catch {
            entry.steps_error = "the workflow run returned unreadable step data";
            continue;
        };
        const job = findJob(jobs.jobs, job_id) orelse {
            entry.steps_error = "the workflow run no longer lists this job";
            continue;
        };
        var steps: std.ArrayList(http_response.GitPrCheckStep) = .empty;
        defer steps.deinit(allocator);
        for (job.steps) |s| {
            try steps.append(allocator, .{
                .name = try allocator.dupe(u8, s.name),
                .number = s.number,
                .conclusion = try allocator.dupe(u8, s.conclusion),
                .status = try allocator.dupe(u8, s.status),
                .started_at = try allocator.dupe(u8, cleanTime(s.startedAt)),
                .completed_at = try allocator.dupe(u8, cleanTime(s.completedAt)),
            });
        }
        entry.steps = try steps.toOwnedSlice(allocator);
    }

    return .{
        .provider = try allocator.dupe(u8, "github"),
        .pr_url = try allocator.dupe(u8, pr_arg),
        .checks = try entries.toOwnedSlice(allocator),
        .summary = summary,
        .steps_truncated = budget_exhausted,
    };
}

fn useCase(
    allocator: std.mem.Allocator,
    io: std.Io,
    path: []const u8,
    pr_arg: []const u8,
    provider_override: ?[]const u8,
    fetch_detail: *?[]u8,
) !http_response.GitPrChecksResponse {
    return useCaseWithPrograms(allocator, io, .{}, path, pr_arg, provider_override, fetch_detail);
}

fn useCaseWith(
    allocator: std.mem.Allocator,
    io: std.Io,
    prog: []const u8,
    path: []const u8,
    pr_arg: []const u8,
    provider_override: ?[]const u8,
    fetch_detail: *?[]u8,
) !http_response.GitPrChecksResponse {
    return useCaseWithPrograms(allocator, io, .{ .gh = prog }, path, pr_arg, provider_override, fetch_detail);
}

fn useCaseWithPrograms(
    allocator: std.mem.Allocator,
    io: std.Io,
    programs: Programs,
    path: []const u8,
    pr_arg: []const u8,
    provider_override: ?[]const u8,
    fetch_detail: *?[]u8,
) !http_response.GitPrChecksResponse {
    {
        const check = git_route.run(allocator, io, path, &.{ "rev-parse", "--git-dir" }, .{}) catch return error.NotARepository;
        defer {
            allocator.free(check.stdout);
            allocator.free(check.stderr);
        }
        if (check.term.exited != 0) return error.NotARepository;
    }

    const provider = pr_status.resolveProvider(allocator, io, path, pr_arg, provider_override) catch |err| {
        switch (err) {
            error.UnknownProvider => pr_status.setFetchDetail(allocator, fetch_detail, "unknown provider (expected github, gitlab, or generic)"),
            error.UnsupportedProvider => pr_status.setFetchDetail(allocator, fetch_detail, "the generic provider has no forge CLI, so CI checks cannot be resolved (pass provider=github)"),
            else => |e| return e,
        }
        return error.ForgeUnsupported;
    };

    // Real buffer, not `&.{}`: checksArgv also returns null for an undersized
    // buffer, so probing with an empty slice would reject GitHub too.
    var probe_buf: [pr_cli.checks_argv_max][]const u8 = undefined;
    if (pr_cli.checksArgv(&probe_buf, provider, programs.forProvider(provider), pr_arg) == null) {
        pr_status.setFetchDetail(allocator, fetch_detail, "CI checks are available for GitHub pull requests only");
        return error.ForgeUnsupported;
    }

    const raw = try runChecks(allocator, io, programs.forProvider(provider), path, pr_arg, fetch_detail);
    defer allocator.free(raw);

    return try buildResponse(allocator, io, programs.forProvider(provider), path, pr_arg, std.mem.trim(u8, raw, " \n\r"));
}

/// `pr` is optional; when omitted gh resolves the PR for the current branch,
/// matching `/api/git/pr/status`.
pub fn gitPrChecksHandler(ctx: gserverz.HttpContext, req: gserverz.HttpRequest, res: gserverz.HttpResponse) !gserverz.HttpResponse {
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
            return res.jsonResponse(.{ .status_code = 422, .data = try http_response.makeGitStatusErrorResponse(allocator, "gh CLI not found on PATH (install gh to see pull request CI checks)") });
        },
        // 422, not 404 and not 200-with-no-rows: the panel has to be able to say
        // "not available for this forge", which is a different message from
        // "this PR has no CI".
        error.ForgeUnsupported => {
            return res.jsonResponse(.{ .status_code = 422, .data = try http_response.makeGitStatusErrorResponse(allocator, fetch_detail orelse "CI checks are not available for this provider") });
        },
        error.NoAssociatedPr => {
            const msg = if (pr_param.len > 0)
                try std.fmt.allocPrint(allocator, "no pull request found for '{s}'", .{pr_param})
            else
                try std.fmt.allocPrint(allocator, "no pull request found for the current branch", .{});
            return res.jsonResponse(.{ .status_code = 404, .data = try http_response.makeGitStatusErrorResponse(allocator, msg) });
        },
        error.FetchFailed => {
            const msg = if (fetch_detail) |d|
                try std.fmt.allocPrint(allocator, "failed to fetch pull request checks: {s}", .{d})
            else
                try std.fmt.allocPrint(allocator, "failed to fetch pull request checks (check number/URL, provider, and gh auth)", .{});
            return res.jsonResponse(.{ .status_code = 502, .data = try http_response.makeGitStatusErrorResponse(allocator, msg) });
        },
        else => return err,
    };

    return res.jsonResponse(.{ .status_code = 200, .data = try http_response.makeGitPrChecksResponse(allocator, result) });
}

// ===== Tests =====

const testing = std.testing;
test "wantsSteps only drills into red jobs" {
    try testing.expect(wantsSteps("fail"));
    try testing.expect(wantsSteps("FAIL"));
    try testing.expect(wantsSteps("cancel"));
    try testing.expect(!wantsSteps("pending"));
    try testing.expect(!wantsSteps("pass"));
    try testing.expect(!wantsSteps("skipping"));
    try testing.expect(!wantsSteps(""));
}

test "cleanTime blanks gh's zero timestamp" {
    try testing.expectEqualStrings("", cleanTime(ZERO_TIME));
    try testing.expectEqualStrings("2026-10-03T19:11:04Z", cleanTime("2026-10-03T19:11:04Z"));
    try testing.expectEqualStrings("", cleanTime(""));
}

test "tally keeps total equal to the sum of the parts, including unknown buckets" {
    var s: http_response.GitPrChecksSummary = .{};
    for ([_][]const u8{ "pass", "fail", "pending", "cancel", "skipping", "something-gh-invents" }) |b| tally(&s, b);
    try testing.expectEqual(@as(u32, 6), s.total);
    try testing.expectEqual(@as(u32, 1), s.passed);
    try testing.expectEqual(@as(u32, 1), s.failed);
    try testing.expectEqual(@as(u32, 1), s.pending);
    try testing.expectEqual(@as(u32, 1), s.cancelled);
    // Unknown buckets land in `skipped` rather than vanishing — the badge adds
    // the parts up and a dropped row breaks it.
    try testing.expectEqual(@as(u32, 2), s.skipped);
}

test "findJob matches on databaseId, not on name" {
    const jobs = [_]GhRunJob{
        .{ .databaseId = 1, .name = "backend (Linux X64) / build" },
        .{ .databaseId = 2, .name = "backend (Linux X64) / build" },
    };
    try testing.expectEqual(@as(i64, 2), findJob(&jobs, 2).?.databaseId);
    try testing.expect(findJob(&jobs, 3) == null);
    try testing.expect(findJob(&.{}, 1) == null);
}

test "buildResponse parses rows, tallies them, and reports the pr ref" {
    // buildResponse dups into the caller's allocator — in production a
    // per-request arena. An arena here so the test can free the lot.
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const io = testing.io;
    const stdout =
        \\[{"bucket":"pass","name":"path filter","state":"SUCCESS","link":"https://github.com/acme/app/actions/runs/371/job/1","workflow":"ci","startedAt":"2026-10-03T19:11:04Z","completedAt":"2026-10-03T19:11:11Z"},
        \\ {"bucket":"fail","name":"backend (Windows X64) / build","state":"FAILURE","link":"https://circleci.com/x","workflow":"","startedAt":"0001-01-01T00:00:00Z","completedAt":"0001-01-01T00:00:00Z"}]
    ;
    const out = try buildResponse(allocator, io, "gh", "/tmp", "42", std.mem.trim(u8, stdout, " \n\r"));
    try testing.expectEqualStrings("github", out.provider);
    try testing.expectEqualStrings("42", out.pr_url);
    try testing.expectEqual(@as(usize, 2), out.checks.len);
    try testing.expectEqual(@as(u32, 2), out.summary.total);
    try testing.expectEqual(@as(u32, 1), out.summary.passed);
    try testing.expectEqual(@as(u32, 1), out.summary.failed);
    try testing.expectEqualStrings("path filter", out.checks[0].name);
    try testing.expectEqualStrings("2026-10-03T19:11:04Z", out.checks[0].started_at);
    // ZERO_TIME must not reach the wire as year 1.
    try testing.expectEqualStrings("", out.checks[1].completed_at);
    // An external check has no Actions run: no steps, and NO steps_error either
    // — there was nothing to fail.
    try testing.expectEqualStrings("", out.checks[1].steps_error);
    try testing.expectEqual(@as(usize, 0), out.checks[1].steps.len);
    try testing.expect(!out.steps_truncated);
}

test "buildResponse treats an empty payload as zero checks, not as a failure" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const io = testing.io;
    const out = try buildResponse(allocator, io, "gh", "/tmp", "", "");
    try testing.expectEqual(@as(usize, 0), out.checks.len);
    try testing.expectEqual(@as(u32, 0), out.summary.total);
    try testing.expectEqualStrings("github", out.provider);
}

test "buildResponse rejects a payload that is not the checks array" {
    const allocator = testing.allocator;
    const io = testing.io;
    // `gh pr checks` without `--json` prints a table. Parsing it as a list must
    // fail loudly, not yield "0 checks, all good".
    if (buildResponse(allocator, io, "gh", "/tmp", "42", "path filter\tsuccess\t1m2s")) |_| {
        return error.ExpectedParseFailure;
    } else |_| {}
}

test "makeGitPrChecksResponse serializes the documented wire shape" {
    const allocator = testing.allocator;
    const steps = [_]http_response.GitPrCheckStep{.{
        .name = "zig build test",
        .number = 3,
        .conclusion = "failure",
        .status = "completed",
    }};
    const checks = [_]http_response.GitPrCheckEntry{
        .{
            .name = "backend (Windows X64) / build",
            .workflow = "ci",
            .bucket = "fail",
            .state = "FAILURE",
            .link = "https://github.com/acme/app/actions/runs/1/job/2",
            .steps = &steps,
        },
        // A passing job: no steps were fetched, and `steps_error` stays empty.
        .{ .name = "lint (oxlint + eslint)", .bucket = "pass", .state = "SUCCESS" },
    };
    const body = try http_response.makeGitPrChecksResponse(allocator, .{
        .provider = "github",
        .pr_url = "42",
        .checks = &checks,
        .summary = .{ .total = 2, .failed = 1, .passed = 1 },
    });
    defer allocator.free(body);
    try testing.expect(std.mem.indexOf(u8, body, "\"bucket\":\"fail\"") != null);
    try testing.expect(std.mem.indexOf(u8, body, "\"conclusion\":\"failure\"") != null);
    try testing.expect(std.mem.indexOf(u8, body, "\"steps_truncated\":false") != null);
    // Keys the frontend reads must be present even when empty: a missing
    // `steps_error` would read as "no error" and a missing `steps` as "no
    // steps", which are the same thing today only by luck.
    try testing.expect(std.mem.indexOf(u8, body, "\"steps\":[]") != null);
    try testing.expect(std.mem.indexOf(u8, body, "\"steps_error\":\"\"") != null);
}
