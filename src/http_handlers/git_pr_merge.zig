//! `POST /api/git/pr/merge` — merge a pull/merge request through the forge
//! CLI (`gh pr merge` / `glab mr merge`).
//!
//! Body:
//! ```json
//! { "path": "<repo>", "pr": "<n|url|branch>", "provider": "github",
//!   "method": "squash", "title": "...", "body": "...",
//!   "delete_branch": false, "head_sha": "<40-hex>" }
//! ```
//!
//! ## Why the response is a re-read of the status, not an exit code
//!
//! A forge CLI exiting 0 does not mean a pull request merged. It can mean:
//!   - `glab mr merge` accepted the command and merely ARMED auto-merge
//!     (its `--auto-merge` default is true whenever a pipeline is running),
//!   - a GitHub merge queue accepted the PR and has not merged it yet.
//!
//! Both are "plausible-looking successes", and a merge button cannot afford
//! one. So this handler runs the merge, then re-reads the status through
//! `git_pr_status.useCaseWithPrograms` — the same path the 30 s poll uses —
//! and reports the forge's own answer. `pending` is the honest middle state:
//! accepted, not merged.
//!
//! ## Why a method is mandatory
//!
//! `gh pr merge` with no strategy flag drops into an interactive prompt
//! ("What merge method would you like to use?"). A non-tty child cannot
//! answer it, so the request would hang until the timeout killed the child.
//! `pr_cli.MergeMethod` makes exactly one flag mandatory on GitHub, and the
//! handler refuses an empty or unknown method with a 400 before spawning
//! anything.
//!
//! ## Auto-merge is deliberately not implemented
//!
//! There is no `--auto` / `--auto-merge` path and no fallback to one. The
//! GitLab arm nonetheless passes `--auto-merge=false` explicitly, so a
//! future change to glab's own default cannot turn "merge now" back into
//! "arm it and say it worked".

const std = @import("std");
const http_response = @import("http_response.zig");
const pabrik_core = @import("pabrikcore");
const gserverz = pabrik_core.gserverz;
const pr_provider = pabrik_core.pr_provider;
const pr_cli = pabrik_core.pr_cli;
const run_captured = @import("helpers").run_captured;
// Provider resolution and the error-detail helper are shared with the status
// endpoint: two endpoints that disagreed about which forge a repo is on would
// merge the wrong thing.
const pr_status = @import("git_pr_status.zig");

/// A merge is a network write, so this is as generous as `gh pr create`'s
/// budget — and still bounded, so a credential prompt cannot wedge a worker.
pub const MERGE_TIMEOUT_MS: u32 = 60_000;

/// Per-stream capture cap. Merge output is a line or two; a URL or a git
/// error is the most we ever need.
const MAX_CAPTURE_BYTES: usize = 64 * 1024;

const MergeError = error{
    /// No forge CLI to run: the `generic` provider, or a provider whose
    /// binary is not on PATH.
    ForgeUnsupported,
    /// The merge itself failed (non-zero exit, signal kill, timeout, or the
    /// status re-read afterwards). The caller has `detail`.
    MergeFailed,
};

/// The forge binaries. Injectable so tests can point the whole path at
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

/// What a merge did, as the forge reports it.
pub const MergeOutcome = struct {
    /// The strategy that was requested (echoed, not re-derived from flags).
    method: pr_cli.MergeMethod,
    /// The command was accepted but the forge has not merged the change
    /// request: a merge queue, or an armed auto-merge.
    pending: bool,
    /// The forge's answer AFTER the command ran — the same payload
    /// `GET /api/git/pr/status` returns.
    status: http_response.GitPrStatusResponse,
};

/// `detail` receives the CLI's own stderr (or a synthesized hint) on failure,
/// capped and trimmed by `pr_status.setFetchDetail`. The HTTP layer renders it
/// verbatim so the user sees "Pull request is not mergeable" instead of a
/// generic apology.
fn mergeUseCase(
    allocator: std.mem.Allocator,
    io: std.Io,
    path: []const u8,
    pr_arg: []const u8,
    provider_override: ?[]const u8,
    method: pr_cli.MergeMethod,
    opts: pr_cli.MergeOptions,
    detail: *?[]u8,
) !MergeOutcome {
    return mergeUseCaseWithPrograms(allocator, io, .{}, path, pr_arg, provider_override, method, opts, detail);
}

fn mergeUseCaseWithPrograms(
    allocator: std.mem.Allocator,
    io: std.Io,
    programs: Programs,
    path: []const u8,
    pr_arg: []const u8,
    provider_override: ?[]const u8,
    method: pr_cli.MergeMethod,
    opts: pr_cli.MergeOptions,
    detail: *?[]u8,
) !MergeOutcome {
    // Same resolution order as the status endpoint (`resolveProvider` is
    // shared for exactly this reason): explicit provider > URL-shaped `pr`
    // argument > the repository's own origin remote.
    const provider = pr_status.resolveProvider(allocator, io, path, pr_arg, provider_override) catch |err| switch (err) {
        error.UnknownProvider, error.UnsupportedProvider => return error.ForgeUnsupported,
    };
    const cli = pr_cli.cliFor(provider) orelse return error.ForgeUnsupported;
    const prog = programs.forProvider(provider);
    if (prog.len == 0) return error.ForgeUnsupported;

    var argv_buf: [pr_cli.merge_argv_max][]const u8 = undefined;
    const argv = pr_cli.mergeArgv(&argv_buf, provider, prog, pr_arg, method, opts) orelse
        return error.ForgeUnsupported;

    var res = run_captured.run(allocator, io, argv, .{
        .cwd = path,
        .max_output_bytes = MAX_CAPTURE_BYTES,
        .timeout_ms = MERGE_TIMEOUT_MS,
    }) catch |err| {
        // Spawn-time failure: CLI not installed, not executable, cwd gone.
        // `bufPrint`, not `allocPrint`: setFetchDetail copies into the request
        // arena, so an allocated temporary here would only leak.
        var msg_buf: [224]u8 = undefined;
        const msg = std.fmt.bufPrint(&msg_buf, "{s} (is the {s} CLI installed and on PATH?)", .{ @errorName(err), cli.program }) catch "forge CLI spawn failed";
        pr_status.setFetchDetail(allocator, detail, msg);
        return error.ForgeUnsupported;
    };
    defer res.deinit(allocator);

    if (res.timed_out) {
        const msg = std.fmt.allocPrint(allocator, "{s} {s} merge timed out after {d}s", .{ cli.program, cli.noun, MERGE_TIMEOUT_MS / 1000 }) catch "merge timed out";
        pr_status.setFetchDetail(allocator, detail, msg);
        return error.MergeFailed;
    }

    switch (res.term) {
        .exited => |code| {
            if (code != 0) {
                // The CLI's own words: "Pull request is not mergeable",
                // "Protected branch update failed", a GraphQL error, …
                pr_status.setFetchDetail(allocator, detail, res.stderr);
                return error.MergeFailed;
            }
        },
        else => {
            pr_status.setFetchDetail(allocator, detail, "the forge CLI was killed before it finished");
            return error.MergeFailed;
        },
    }

    // Exit code 0. That is not the answer — ask the forge.
    //
    // A failure to re-read is reported as MergeFailed rather than as a
    // success: we cannot prove the merge happened, and "I do not know" must
    // never render as "Merged".
    var status_detail: ?[]u8 = null;
    const status = pr_status.useCaseWithPrograms(
        allocator,
        io,
        .{ .gh = programs.gh, .glab = programs.glab },
        path,
        pr_arg,
        provider_override,
        &status_detail,
    ) catch {
        const msg = std.fmt.allocPrint(allocator, "the {s} command was accepted, but the resulting status could not be read", .{cli.program}) catch "status re-read failed";
        pr_status.setFetchDetail(allocator, detail, msg);
        return error.MergeFailed;
    };

    return .{
        .method = method,
        .pending = !std.mem.eql(u8, status.status, "merged"),
        .status = status,
    };
}

/// Tell every client that this branch's change request moved, so the sidebar's
/// RECENT icon and the kanban card badge re-read the forge instead of keeping
/// the colour they cached before the mutation.
///
/// Never fails the caller — a successful merge must not be reported as a
/// failure because the UI could not be told about it. The merge box's own
/// local invalidate is the path that cannot be lost; this one is what carries
/// the news to a second tab (see agentic_loop/git_pr_state_events.zig).
fn emitPrStateEvent(ctx: gserverz.HttpContext, cwd: []const u8, branch: []const u8, action: []const u8) void {
    const di = pabrik_core.getSingleton() catch return;
    pabrik_core.git_pr_state_events.emitGitPrStateEvent(ctx.allocator, di.event_bus, .{
        .action = action,
        .cwd = cwd,
        .branch = branch,
    });
}

/// POST /api/git/pr/merge
pub fn gitPrMergeHandler(ctx: gserverz.HttpContext, req: gserverz.HttpRequest, res: gserverz.HttpResponse) !gserverz.HttpResponse {
    const allocator = ctx.allocator;

    // Leaky parse: the per-request arena reaps it (see the sibling handlers).
    const Body = struct {
        path: []const u8 = "",
        /// Number, IID, URL or branch. Empty = the one for the current
        /// branch, which both CLIs resolve from the repo themselves.
        pr: []const u8 = "",
        provider: []const u8 = "",
        /// "merge" | "squash" | "rebase". REQUIRED — see the module comment.
        method: []const u8 = "",
        /// Commit message for the merge/squash commit.
        title: []const u8 = "",
        body: []const u8 = "",
        delete_branch: bool = false,
        head_sha: []const u8 = "",
    };
    const parsed = std.json.parseFromSliceLeaky(Body, allocator, req.body, .{}) catch {
        return res.jsonResponse(.{ .status_code = 400, .data = try http_response.makeErrorResponse(allocator, .{ .@"error" = "Invalid JSON body" }) });
    };

    if (parsed.path.len == 0) {
        return res.jsonResponse(.{ .status_code = 400, .data = try http_response.makeErrorResponse(allocator, .{ .@"error" = "path is required" }) });
    }
    // Refusing an empty method is not pedantry: `gh pr merge` without a
    // strategy flag prompts interactively, and the prompt can only be
    // answered by hanging until the timeout kills the child.
    const method = pr_cli.MergeMethod.fromString(parsed.method) orelse {
        return res.jsonResponse(.{ .status_code = 400, .data = try http_response.makeErrorResponse(allocator, .{ .@"error" = "method must be \"merge\", \"squash\", or \"rebase\"" }) });
    };
    if (parsed.provider.len > 0 and pr_provider.PrProvider.fromString(parsed.provider) == null) {
        return res.jsonResponse(.{ .status_code = 400, .data = try http_response.makeErrorResponse(allocator, .{ .@"error" = "provider must be \"github\", \"gitlab\", or \"generic\"" }) });
    }

    var detail: ?[]u8 = null;
    const outcome = mergeUseCase(
        allocator,
        ctx.io,
        parsed.path,
        parsed.pr,
        if (parsed.provider.len > 0) parsed.provider else null,
        method,
        .{
            .delete_branch = parsed.delete_branch,
            .head_sha = parsed.head_sha,
            .subject = parsed.title,
            .body = parsed.body,
        },
        &detail,
    ) catch |err| switch (err) {
        error.ForgeUnsupported => {
            // 422: the request was understood and this forge cannot answer
            // it — the same status `git_pr_checks` uses for unsupported.
            const msg = detail orelse "this change request has no forge CLI, so it cannot be merged from here";
            return res.jsonResponse(.{ .status_code = 422, .data = try http_response.makeErrorResponse(allocator, .{ .@"error" = msg }) });
        },
        error.MergeFailed => {
            const msg = detail orelse "the merge command failed";
            // 502: the forge is the upstream, and it said no (conflict,
            // protection, approval, rate limit, auth).
            return res.jsonResponse(.{ .status_code = 502, .data = try http_response.makeErrorResponse(allocator, .{ .@"error" = msg }) });
        },
    };

    // A merge MOVED this branch's change request, and every badge reads a
    // shared 60s cache that still holds the pre-merge answer. Emitted only for
    // a REAL merge: an accepted-but-pending one (a merge queue, an armed
    // auto-merge) leaves the change request `open`, so there is no state change
    // to show.
    //
    // Free of extra forge work: the status re-read above already carries
    // `head_ref`, which is exactly the branch half of the frontend's cache key.
    if (!outcome.pending and outcome.status.head_ref.len > 0) {
        emitPrStateEvent(ctx, parsed.path, outcome.status.head_ref, "merged");
    }

    return res.jsonResponse(.{ .status_code = 200, .data = try http_response.makeGitPrMergeResponse(allocator, .{
        .success = !outcome.pending,
        .method = outcome.method.toString(),
        .pending = outcome.pending,
        .status = outcome.status,
    }) });
}
