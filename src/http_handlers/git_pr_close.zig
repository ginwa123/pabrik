//! `POST /api/git/pr/close` — close a pull/merge request through the forge
//! CLI (`gh pr close` / `glab mr close`).

const std = @import("std");
const http_response = @import("http_response.zig");
const pabrik_core = @import("pabrikcore");
const gserverz = pabrik_core.gserverz;
const pr_provider = pabrik_core.pr_provider;
const pr_cli = pabrik_core.pr_cli;
const run_captured = @import("helpers").run_captured;
const pr_status = @import("git_pr_status.zig");

/// A close is a network write, so it gets the same budget as a merge — and it
/// is still bounded, so a credential prompt cannot wedge a worker.
pub const CLOSE_TIMEOUT_MS: u32 = 60_000;

/// Per-stream capture cap. Close output is a line or two; this is only here so
/// a CLI that decides to dump a wall of text cannot exhaust the arena.
const MAX_CAPTURE_BYTES: usize = 64 * 1024;

const CloseError = error{
    /// No forge CLI for this repo (the `generic` provider), an empty `pr`, or
    /// a spawn-time failure. The caller has `detail`.
    ForgeUnsupported,
    /// The close ran and failed, or the status re-read afterwards did.
    CloseFailed,
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

/// What a close did, as the forge reports it.
pub const CloseOutcome = struct {
    /// True only when the forge now reports the change request as closed.
    closed: bool,
    /// Which forge did it — echoed so the UI can label the result.
    provider: pr_provider.PrProvider,
    /// The forge's answer AFTER the command ran — the same payload
    /// `GET /api/git/pr/status` returns.
    status: http_response.GitPrStatusResponse,
};

fn closeUseCase(
    allocator: std.mem.Allocator,
    io: std.Io,
    path: []const u8,
    pr_arg: []const u8,
    provider_override: ?[]const u8,
    detail: *?[]u8,
) !CloseOutcome {
    return closeUseCaseWithPrograms(allocator, io, .{}, path, pr_arg, provider_override, detail);
}

/// `pub` so the functional/behavioural suites drive the real path against
/// fixture scripts.
pub fn closeUseCaseWithPrograms(
    allocator: std.mem.Allocator,
    io: std.Io,
    programs: Programs,
    path: []const u8,
    pr_arg: []const u8,
    provider_override: ?[]const u8,
    detail: *?[]u8,
) !CloseOutcome {
    // Same resolution order as status and merge (`resolveProvider` is shared
    // for exactly this reason): explicit provider > URL-shaped `pr` > the
    // repository's own origin remote.
    const provider = pr_status.resolveProvider(allocator, io, path, pr_arg, provider_override) catch |err| switch (err) {
        error.UnknownProvider, error.UnsupportedProvider => return error.ForgeUnsupported,
    };
    const cli = pr_cli.cliFor(provider) orelse return error.ForgeUnsupported;
    const prog = programs.forProvider(provider);
    if (prog.len == 0) return error.ForgeUnsupported;

    var argv_buf: [pr_cli.close_argv_max][]const u8 = undefined;
    const argv = pr_cli.closeArgv(&argv_buf, provider, prog, pr_arg) orelse {
        // The only input `closeArgv` refuses is an empty ref, and that refusal
        // is the point: both CLIs would otherwise close whatever branch is
        // checked out, which is not something a list row can mean.
        pr_status.setFetchDetail(allocator, detail, "pr is required: closing the change request for whatever branch happens to be checked out is never what this endpoint means");
        return error.ForgeUnsupported;
    };

    var res = run_captured.run(allocator, io, argv, .{
        .cwd = path,
        .max_output_bytes = MAX_CAPTURE_BYTES,
        .timeout_ms = CLOSE_TIMEOUT_MS,
    }) catch |err| {
        // Spawn-time failure (CLI not installed, cwd gone). `bufPrint`, not
        // `allocPrint`: setFetchDetail copies into the request arena, so an
        // allocated temporary here would only leak.
        var msg_buf: [224]u8 = undefined;
        const msg = std.fmt.bufPrint(&msg_buf, "{s} (is the {s} CLI installed and on PATH?)", .{ @errorName(err), cli.program }) catch "forge CLI spawn failed";
        pr_status.setFetchDetail(allocator, detail, msg);
        return error.ForgeUnsupported;
    };
    defer res.deinit(allocator);

    if (res.timed_out) {
        pr_status.setFetchDetailFmt(allocator, detail, "{s} {s} close timed out after {d}s", .{ cli.program, cli.noun, CLOSE_TIMEOUT_MS / 1000 });
        return error.CloseFailed;
    }

    switch (res.term) {
        .exited => |code| {
            if (code != 0) {
                // The CLI's own words — "Pull request #893 is already closed",
                // "HTTP 403: Resource not accessible by integration", a
                // protected-branch refusal. Rendered verbatim.
                pr_status.setFetchDetail(allocator, detail, res.stderr);
                if (detail.* == null) {
                    pr_status.setFetchDetailFmt(allocator, detail, "{s} {s} close exited with code {d} (no stderr)", .{ cli.program, cli.noun, code });
                }
                return error.CloseFailed;
            }
        },
        else => {
            pr_status.setFetchDetailFmt(allocator, detail, "the {s} CLI was killed before it finished", .{cli.program});
            return error.CloseFailed;
        },
    }

    // Exit code 0. That is not the answer — ask the forge. A failure to
    // re-read is CloseFailed rather than a success: we cannot prove the close
    // happened, and "I do not know" must never render as "Closed".
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
        pr_status.setFetchDetailFmt(
            allocator,
            detail,
            "the {s} command was accepted, but the resulting status could not be read: {s}",
            .{ cli.program, status_detail orelse "unknown error" },
        );
        return error.CloseFailed;
    };

    const closed = std.mem.eql(u8, status.status, "closed");
    if (!closed) {
        // The honest in-between: the CLI exited 0 and the forge did NOT close
        // it. This is a 200 with closed:false — an error status here would
        // hide the one fact the user needs, which is what the forge thinks.
        pr_status.setFetchDetailFmt(
            allocator,
            detail,
            "the {s} command was accepted, but the forge still reports #{d} as {s}",
            .{ cli.program, status.number, if (status.status.len > 0) status.status else "unchanged" },
        );
    }

    return .{ .closed = closed, .provider = provider, .status = status };
}

/// Tell every client that this branch's change request moved, so the
/// sidebar's RECENT icon and the kanban card badge re-read the forge instead
/// of keeping the colour they cached before the close.
fn emitPrStateEvent(ctx: gserverz.HttpContext, cwd: []const u8, branch: []const u8, action: []const u8) void {
    const di = pabrik_core.getSingleton() catch return;
    pabrik_core.git_pr_state_events.emitGitPrStateEvent(ctx.allocator, di.event_bus, .{
        .action = action,
        .cwd = cwd,
        .branch = branch,
    });
}

/// POST /api/git/pr/close Body: `{ "path": "<repo>", "pr": "<n|url|branch>",
/// "provider": "github" }` A thin wrapper: parse + validate, delegate to the
/// use case, map the domain result onto HTTP.
pub fn gitPrCloseHandler(ctx: gserverz.HttpContext, req: gserverz.HttpRequest, res: gserverz.HttpResponse) !gserverz.HttpResponse {
    const allocator = ctx.allocator;

    // Leaky parse: the per-request arena reaps it (see the sibling handlers).
    const Body = struct {
        path: []const u8 = "",
        /// Number, IID, URL or branch. REQUIRED: see `closeArgv`.
        pr: []const u8 = "",
        provider: []const u8 = "",
    };
    const parsed = std.json.parseFromSliceLeaky(Body, allocator, req.body, .{}) catch {
        return res.jsonResponse(.{ .status_code = 400, .data = try http_response.makeErrorResponse(allocator, .{ .@"error" = "Invalid JSON body" }) });
    };

    if (parsed.path.len == 0) {
        return res.jsonResponse(.{ .status_code = 400, .data = try http_response.makeErrorResponse(allocator, .{ .@"error" = "path is required" }) });
    }
    if (parsed.pr.len == 0) {
        return res.jsonResponse(.{ .status_code = 400, .data = try http_response.makeErrorResponse(allocator, .{ .@"error" = "pr is required (a number, URL, or branch)" }) });
    }
    if (parsed.provider.len > 0 and pr_provider.PrProvider.fromString(parsed.provider) == null) {
        return res.jsonResponse(.{ .status_code = 400, .data = try http_response.makeErrorResponse(allocator, .{ .@"error" = "provider must be \"github\", \"gitlab\", or \"generic\"" }) });
    }

    var detail: ?[]u8 = null;
    const outcome = closeUseCase(
        allocator,
        ctx.io,
        parsed.path,
        parsed.pr,
        if (parsed.provider.len > 0) parsed.provider else null,
        &detail,
    ) catch |err| switch (err) {
        error.ForgeUnsupported => {
            const msg = detail orelse "this change request has no forge CLI, so it cannot be closed from here";
            return res.jsonResponse(.{ .status_code = 422, .data = try http_response.makeErrorResponse(allocator, .{ .@"error" = msg }) });
        },
        error.CloseFailed => {
            const msg = detail orelse "the close command failed";
            // 502: the forge is the upstream and it said no (already merged,
            // protected, no permission, rate limit, auth).
            return res.jsonResponse(.{ .status_code = 502, .data = try http_response.makeErrorResponse(allocator, .{ .@"error" = msg }) });
        },
    };

    // A close MOVED this branch's change request, and every badge reads a
    // shared 60s cache that still holds the pre-close answer.
    if (outcome.closed and outcome.status.head_ref.len > 0) {
        emitPrStateEvent(ctx, parsed.path, outcome.status.head_ref, "closed");
    }

    return res.jsonResponse(.{ .status_code = 200, .data = try http_response.makeGitPrCloseResponse(allocator, .{
        .closed = outcome.closed,
        .detail = detail orelse "",
        .provider = outcome.provider.toString(),
        .status = outcome.status,
    }) });
}

// ============================================================================
// Tests
// ============================================================================

const testing = std.testing;
const builtin_t = @import("builtin");
const hf = @import("helpers").host_fixture;

/// A throwaway directory plus fixture programs, written by `host_fixture`
/// so they run on POSIX (`#!/bin/sh`) and Windows (`.cmd`) alike.
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

    fn writeProgram(self: *Fixture, name: []const u8, payload: hf.Payload) ![]u8 {
        return self.inner.writeProgram(name, payload);
    }

    /// Write a body this file rendered for the current host.
    fn writeProgramText(self: *Fixture, name: []const u8, script: []const u8) ![]u8 {
        return self.inner.writeProgramText(name, script);
    }
};

/// A program that answers like `gh`: `close` records the whole argv and
/// exits with `close_code`; anything else prints `view_json`. The branch on
/// the subcommand is what `host_fixture.Payload` cannot express.
fn ghScript(fx: *Fixture, argv_file: []const u8, close_code: u8, close_stderr: []const u8, view_json: []const u8) ![]u8 {
    const script = if (builtin_t.os.tag == .windows) blk: {
        // Both emit statements come from `host_fixture`, so this body cannot
        // drift onto a different — and silently wrong — Windows output
        // primitive, the way a hand-typed `copy /b` did.
        var out_buf: [128]u8 = undefined;
        var out_w: std.Io.Writer = .fixed(&out_buf);
        try hf.cmdEmitLine(&out_w, .stdout, null);
        var err_buf: [128]u8 = undefined;
        var err_w: std.Io.Writer = .fixed(&err_buf);
        try hf.cmdEmitLine(&err_w, .stderr, null);
        break :blk try std.fmt.allocPrint(fx.allocator,
            // `%~n0` is the script's own name — the analogue of the POSIX
            // branch's `basename "$0"` — and it shares ONE line with %*,
            // because the Windows record IS cmd's single command tail.
            \\@echo off
            \\if "%~2"=="close" (
            \\  > "{s}" echo %~n0 %*
            \\  {s}  exit /b {d}
            \\)
            \\{s}exit /b 0
            \\
        , .{ argv_file, err_w.buffered(), close_code, out_w.buffered() });
    } else try std.fmt.allocPrint(fx.allocator,
        \\#!/bin/sh
        \\if [ "$2" = "close" ]; then
        \\  echo "$(basename "$0")" > '{s}'
        \\  for a in "$@"; do echo "$a"; done >> '{s}'
        \\  printf '%s' '{s}' >&2
        \\  exit {d}
        \\fi
        \\printf '%s' '{s}'
        \\exit 0
        \\
    , .{ argv_file, argv_file, close_stderr, close_code, view_json });
    defer fx.allocator.free(script);
    const prog = try fx.writeProgramText("gh", script);
    // The Windows branch reads its payloads from sidecar data files, because
    // `cmd.exe`'s `echo` cannot emit a byte-exact payload.
    if (builtin_t.os.tag == .windows) {
        try fx.inner.tmp.dir.writeFile(std.testing.io, .{
            .sub_path = hf.sidecarFileName(.stdout),
            .data = view_json,
        });
        try fx.inner.tmp.dir.writeFile(std.testing.io, .{
            .sub_path = hf.sidecarFileName(.stderr),
            .data = close_stderr,
        });
    }
    return prog;
}

const CLOSED_VIEW =
    \\{"number":893,"title":"feat(secrets)","url":"https://github.com/a/b/pull/893","state":"CLOSED","mergeable":"","mergeStateStatus":"","headRefName":"worktree/secrets","baseRefName":"main","createdAt":"","updatedAt":"","mergedAt":null,"closedAt":"2026-10-12T07:00:00Z","author":{"login":"me"},"additions":0,"deletions":0,"changedFiles":0,"headRefOid":""}
;

const OPEN_VIEW =
    \\{"number":893,"title":"feat(secrets)","url":"https://github.com/a/b/pull/893","state":"OPEN","mergeable":"MERGEABLE","mergeStateStatus":"CLEAN","headRefName":"worktree/secrets","baseRefName":"main","createdAt":"","updatedAt":"","mergedAt":null,"closedAt":null,"author":{"login":"me"},"additions":0,"deletions":0,"changedFiles":0,"headRefOid":""}
;

test "close: a closed re-read means closed, and no branch deletion is ever passed" {
    const a = testing.allocator;
    var fx = try Fixture.init(a);
    defer fx.deinit();

    const argv_file = try std.fmt.allocPrint(a, "{s}/argv", .{fx.root()});
    defer a.free(argv_file);
    const gh = try ghScript(&fx, argv_file, 0, "", CLOSED_VIEW);
    defer a.free(gh);

    var detail: ?[]u8 = null;
    const out = try closeUseCaseWithPrograms(a, testing.io, .{ .gh = gh }, fx.root(), "893", "github", &detail);
    const st = out.status;
    defer {
        a.free(out.status.provider);
        a.free(out.status.pr_url);
        a.free(out.status.title);
        a.free(out.status.state);
        a.free(out.status.status);
        a.free(out.status.mergeable);
        a.free(out.status.merge_state);
        a.free(out.status.head_sha);
        a.free(out.status.head_ref);
        a.free(out.status.base_ref);
        a.free(out.status.author);
        a.free(out.status.created_at);
        a.free(out.status.updated_at);
        a.free(out.status.merged_at);
        a.free(out.status.closed_at);
    }

    try testing.expect(out.closed);
    try testing.expectEqualStrings("closed", st.status);
    try testing.expectEqual(pr_provider.PrProvider.github, out.provider);
    try testing.expect(detail == null);

    const recorded = try std.Io.Dir.cwd().readFileAlloc(testing.io, argv_file, a, .limited(64 * 1024));
    defer a.free(recorded);
    // The program name plus the three arguments, in order. The recorded
    // shape differs per host (one per line on POSIX, space-separated on
    // Windows), so the assertion goes through the host-aware helper.
    try testing.expect(hf.recordedArgvContainsSequence(recorded, &.{ "gh", "pr", "close", "893" }));
    // The two destructive flags that must never be built here, asserted on the
    // argv that was actually spawned rather than on the builder's source.
    try testing.expect(!hf.recordedArgvContains(recorded, "--delete-branch"));
    try testing.expect(!hf.recordedArgvContains(recorded, "--comment"));
}

test "close: an exit 0 that did NOT close is closed:false with the forge's own answer" {
    const a = testing.allocator;
    var fx = try Fixture.init(a);
    defer fx.deinit();

    const argv_file = try std.fmt.allocPrint(a, "{s}/argv", .{fx.root()});
    defer a.free(argv_file);
    // `gh` exits 0 (it does when the PR is already closed, among others) but
    // the re-read still says OPEN. Reporting success here would be the lie the
    // re-read exists to prevent.
    const gh = try ghScript(&fx, argv_file, 0, "", OPEN_VIEW);
    defer a.free(gh);

    var detail: ?[]u8 = null;
    const out = try closeUseCaseWithPrograms(a, testing.io, .{ .gh = gh }, fx.root(), "893", "github", &detail);
    defer {
        a.free(out.status.provider);
        a.free(out.status.pr_url);
        a.free(out.status.title);
        a.free(out.status.state);
        a.free(out.status.status);
        a.free(out.status.mergeable);
        a.free(out.status.merge_state);
        a.free(out.status.head_sha);
        a.free(out.status.head_ref);
        a.free(out.status.base_ref);
        a.free(out.status.author);
        a.free(out.status.created_at);
        a.free(out.status.updated_at);
        a.free(out.status.merged_at);
        a.free(out.status.closed_at);
    }

    try testing.expect(!out.closed);
    const d = detail orelse return error.NoDetail;
    defer a.free(d);
    try testing.expect(std.mem.indexOf(u8, d, "still reports #893") != null);
}

test "close: a failing close surfaces the CLI's stderr" {
    const a = testing.allocator;
    var fx = try Fixture.init(a);
    defer fx.deinit();

    const argv_file = try std.fmt.allocPrint(a, "{s}/argv", .{fx.root()});
    defer a.free(argv_file);
    const gh = try ghScript(&fx, argv_file, 1, "HTTP 403: Resource not accessible by integration", CLOSED_VIEW);
    defer a.free(gh);

    var detail: ?[]u8 = null;
    const res = closeUseCaseWithPrograms(a, testing.io, .{ .gh = gh }, fx.root(), "893", "github", &detail);
    try testing.expectError(error.CloseFailed, res);
    const d = detail orelse return error.NoDetail;
    defer a.free(d);
    try testing.expect(std.mem.indexOf(u8, d, "403") != null);
}

test "close: an empty pr is refused instead of closing the current branch" {
    const a = testing.allocator;
    var fx = try Fixture.init(a);
    defer fx.deinit();

    var detail: ?[]u8 = null;
    const res = closeUseCaseWithPrograms(a, testing.io, .{}, fx.root(), "", "github", &detail);
    try testing.expectError(error.ForgeUnsupported, res);
    const d = detail orelse return error.NoDetail;
    defer a.free(d);
    try testing.expect(std.mem.indexOf(u8, d, "pr is required") != null);
}

test "close: the generic provider has no CLI to close with" {
    const a = testing.allocator;
    var fx = try Fixture.init(a);
    defer fx.deinit();

    var detail: ?[]u8 = null;
    const res = closeUseCaseWithPrograms(a, testing.io, .{}, fx.root(), "893", "generic", &detail);
    try testing.expectError(error.ForgeUnsupported, res);
}
