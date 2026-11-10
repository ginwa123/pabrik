//! `pabrik headless pr …` — the change-request backend with no server and no
//! port: `checks` reads the forge's CI rollup, `wait` polls it until every check
//! is green, `merge` lands it. Every op is the HTTP handler's own use case.

const std = @import("std");
const pabrik_core = @import("pabrikcore");

const args = @import("args.zig");
const git_pr_checks = @import("../http_handlers/git_pr_checks.zig");
const git_pr_merge = @import("../http_handlers/git_pr_merge.zig");
const http_response = @import("../http_handlers/http_response.zig");

const pr_cli = pabrik_core.pr_cli;

/// The merge box's own cadence, so a headless wait and a click behave alike.
pub const DEFAULT_INTERVAL_MS: u64 = 10_000;
pub const DEFAULT_TIMEOUT_MS: u64 = 15 * 60_000;

pub const Verdict = enum { pass, fail, pending, empty };

/// A cancelled check is not a green run: the forge never concluded it, so
/// claiming "all checks passed" would be a lie the merge then pays for.
pub fn verdict(summary: http_response.GitPrChecksSummary) Verdict {
    if (summary.total == 0) return .empty;
    if (summary.failed > 0 or summary.cancelled > 0) return .fail;
    if (summary.pending > 0) return .pending;
    return .pass;
}

pub const Output = struct {
    json: []u8,
    exit_code: u8 = 0,
};

const WaitDto = struct {
    outcome: []const u8,
    polls: u32,
    provider: []const u8,
    pr_url: []const u8,
    summary: http_response.GitPrChecksSummary,
    checks: []const http_response.GitPrCheckEntry,
    steps_truncated: bool,
};

pub fn run(allocator: std.mem.Allocator, io: std.Io, a: args.PrArgs) !Output {
    return switch (a.op) {
        .checks => checks(allocator, io, a),
        .merge => merge(allocator, io, a),
        .wait => wait(allocator, io, a),
    };
}

fn providerOf(a: args.PrArgs) ?[]const u8 {
    return if (a.provider.len > 0) a.provider else null;
}

fn checks(allocator: std.mem.Allocator, io: std.Io, a: args.PrArgs) !Output {
    var detail: ?[]u8 = null;
    const res = git_pr_checks.useCase(allocator, io, a.path, a.pr, providerOf(a), &detail, .{}) catch |err| {
        return .{ .json = try failureJson(allocator, err, detail), .exit_code = 1 };
    };
    return .{ .json = try http_response.makeGitPrChecksResponse(allocator, res) };
}

fn merge(allocator: std.mem.Allocator, io: std.Io, a: args.PrArgs) !Output {
    const method = pr_cli.MergeMethod.fromString(a.method) orelse {
        return .{
            .json = try http_response.makeErrorResponse(allocator, .{ .@"error" = "method must be \"merge\", \"squash\", or \"rebase\"" }),
            .exit_code = 1,
        };
    };

    var detail: ?[]u8 = null;
    const outcome = git_pr_merge.mergeUseCase(allocator, io, a.path, a.pr, providerOf(a), method, .{
        .delete_branch = a.delete_branch,
        .head_sha = a.head_sha,
        .subject = a.title,
        .body = a.body,
    }, &detail) catch |err| {
        return .{ .json = try failureJson(allocator, err, detail), .exit_code = 1 };
    };

    return .{
        .json = try http_response.makeGitPrMergeResponse(allocator, .{
            .success = !outcome.pending,
            .method = outcome.method.toString(),
            .pending = outcome.pending,
            .status = outcome.status,
        }),
        // Accepted-but-not-merged is not success: a script that merged nothing
        // must not read exit 0 as "it landed".
        .exit_code = if (outcome.pending) 1 else 0,
    };
}

fn wait(allocator: std.mem.Allocator, io: std.Io, a: args.PrArgs) !Output {
    const interval_ms = if (a.interval_ms == 0) DEFAULT_INTERVAL_MS else a.interval_ms;
    const timeout_ms = if (a.timeout_ms == 0) DEFAULT_TIMEOUT_MS else a.timeout_ms;
    var polls: u32 = 0;
    var elapsed: u64 = 0;

    while (true) {
        // One arena per poll: a 15-minute wait must not hold every payload it
        // ever read, and the final JSON is built in the caller's allocator
        // while this poll's bytes are still alive.
        var arena = std.heap.ArenaAllocator.init(allocator);
        defer arena.deinit();
        const aa = arena.allocator();

        var detail: ?[]u8 = null;
        const res = git_pr_checks.useCase(aa, io, a.path, a.pr, providerOf(a), &detail, .{}) catch |err| {
            return .{ .json = try failureJson(allocator, err, detail), .exit_code = 1 };
        };
        polls += 1;

        switch (verdict(res.summary)) {
            .pass => return .{ .json = try waitJson(allocator, "pass", polls, res), .exit_code = 0 },
            .fail => return .{ .json = try waitJson(allocator, "fail", polls, res), .exit_code = 1 },
            .pending, .empty => {},
        }

        if (elapsed + interval_ms > timeout_ms) {
            return .{ .json = try waitJson(allocator, "timeout", polls, res), .exit_code = 1 };
        }
        std.Io.sleep(io, .fromMilliseconds(@intCast(interval_ms)), .awake) catch {};
        elapsed += interval_ms;
    }
}

fn waitJson(
    allocator: std.mem.Allocator,
    outcome: []const u8,
    polls: u32,
    res: http_response.GitPrChecksResponse,
) ![]u8 {
    return std.json.Stringify.valueAlloc(allocator, WaitDto{
        .outcome = outcome,
        .polls = polls,
        .provider = res.provider,
        .pr_url = res.pr_url,
        .summary = res.summary,
        .checks = res.checks,
        .steps_truncated = res.steps_truncated,
    }, .{});
}

/// The forge's own sentence when it gave one, and a plain one when the failure
/// was ours. stdout is the machine channel, so a failure is still one object.
fn failureJson(allocator: std.mem.Allocator, err: anyerror, detail: ?[]u8) ![]u8 {
    const msg = detail orelse switch (err) {
        error.NotARepository => "not a git repository",
        error.CliMissing => "the forge CLI is not on PATH",
        error.ForgeUnsupported => "this change request has no forge CLI that can answer",
        error.NoAssociatedPr => "no pull request found for that ref",
        error.FetchFailed => "failed to fetch pull request checks",
        error.MergeFailed => "the merge command failed",
        else => @errorName(err),
    };
    return http_response.makeErrorResponse(allocator, .{ .@"error" = msg });
}

const testing = std.testing;

test "verdict: no checks at all is empty, not a pass" {
    try testing.expectEqual(Verdict.empty, verdict(.{}));
}

test "verdict: every check passed or skipped is a pass" {
    try testing.expectEqual(Verdict.pass, verdict(.{ .total = 5, .passed = 4, .skipped = 1 }));
}

test "verdict: a running check keeps the wait going" {
    try testing.expectEqual(Verdict.pending, verdict(.{ .total = 3, .passed = 2, .pending = 1 }));
}

test "verdict: a failed check ends the wait" {
    try testing.expectEqual(Verdict.fail, verdict(.{ .total = 3, .passed = 2, .failed = 1 }));
}

test "verdict: a cancelled check is not a green run" {
    try testing.expectEqual(Verdict.fail, verdict(.{ .total = 3, .passed = 2, .cancelled = 1 }));
}

test "verdict: a pending check outranks nothing, so a red run is still red" {
    try testing.expectEqual(Verdict.fail, verdict(.{ .total = 3, .failed = 1, .pending = 2 }));
}
