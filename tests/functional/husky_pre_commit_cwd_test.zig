//! The pre-commit hook's Zig lint step is reachable from the CWD the hook
//! actually runs in.
//!
//! WHAT BROKE, AND WHY THIS FILE EXISTS
//! -----------------------------------
//! `.husky/pre-commit` mirrors the lint steps of CI: the frontend
//! `pnpm run lint:check` (which needs CWD=src/apps/desktop), the Zig
//! coding-standards scan `bash scripts/lint-no-catch-unreachable.sh`, and
//! `zig build zginlint:check` (both of which need CWD=repo root, because
//! their paths and their `build.zig` step are spelled relative to it).
//!
//! The hook satisfied the first requirement with a bare `cd` and then tried
//! to get back with `cd ../..`:
//!
//!     cd src/apps/desktop || exit 1
//!     pnpm run lint:check
//!     cd ../..                       # <-- lands in src/, not the root
//!     bash scripts/lint-no-catch-unreachable.sh --selftest
//!
//! `src/apps/desktop` is THREE levels below the root, so `../..` from there
//! is `src/`. The Zig step then died with
//!
//!     bash: scripts/lint-no-catch-unreachable.sh: No such file or directory
//!     husky - pre-commit script failed (code 127)
//!
//! which is what a developer saw on a commit whose frontend lint had just
//! passed. The hook's own comment claimed "The Zig half needs no cd: the
//! lint script resolves the repo root from its own location" — true of the
//! SCRIPT, but the hook had already moved, so the relative path it invoked
//! never resolved. `.husky/pre-push` already used the correct form
//! (`(cd src/apps/desktop && pnpm run build)`); pre-commit did not.
//!
//! The fix is the subshell: the frontend lint runs in `( ... )`, so the
//! parent's CWD never moves and the Zig step's relative path resolves.
//!
//! WHAT THESE TESTS ASSERT
//! -----------------------
//! They run the REAL hook file through a real `sh`, with stub `pnpm` and
//! `bash` executables first on PATH, and assert:
//!
//!   1. the hook exits 0 and the Zig scan's success line is in its stdout
//!      (the step RAN, and it was not deleted);
//!   2. the stub `pnpm` was invoked with CWD=src/apps/desktop and the
//!      argument `run lint:check` — the frontend half still mirrors CI;
//!   3. the CWD the hook is in when it invokes `bash
//!      scripts/lint-no-catch-unreachable.sh` is the repo root — the
//!      property `cd ../..` broke, observed directly rather than inferred;
//!   4. the hook still names every invocation CI makes, and still runs the
//!      frontend lint in a subshell;
//!   5. the third mirrored step, `zig build zginlint:check`, runs from the
//!      repo root with the argv the `zginlint` CI job uses.
//!
//! WHY STUBS AND NOT THE REAL COMMANDS
//! ----------------------------------
//! `pnpm run lint:check` is a ~90 s, 895-file oxlint+eslint pass. This
//! suite is about the hook's CWD discipline, not about the linter, and a
//! test costing 90 s to say "the hook cd'd correctly" would be skipped by
//! everyone. The `pnpm` stub records the two facts under test (CWD + argv)
//! and exits 0.
//!
//! The `bash` stub is different: it RECORDS and then `exec`s the real
//! bash, so the Zig lint step still runs for real (~50 ms scan plus a
//! 9-fixture selftest). That is deliberate — the Zig step is the subject,
//! and a stubbed-out scan would let a hook that never invokes it pass.
//!
//! WHY THE `bash` STUB IS THE RIGHT OBSERVATION POINT: the stub `pnpm`
//! records the CWD of the hook's CHILD, which is the subshell — correctly
//! inside `src/apps/desktop`. That is the frontend half working, not the
//! Zig half. What decides whether `scripts/...` resolves is the CWD of the
//! hook ITSELF at the moment it spawns `bash`, and a child inherits
//! exactly that. So the `bash` stub's `pwd -P` is the observation that
//! catches the bug.
//!
//! WHY `rg` GATES ONE TEST: the Zig lint step fails closed when `rg` is
//! absent (by design — a lint that cannot run must never report the tree
//! clean), so on a machine with no ripgrep the hook exits 1 for an
//! environmental reason. That test skips with a printed reason; the CWD
//! tests do not need `rg` and do not skip.
//!
//! PLATFORM: the hook is `#!/usr/bin/env sh` and both stubs are `/bin/sh`
//! scripts, so this suite is POSIX-only. On Windows the hook is not what a
//! developer's `git commit` runs (husky's `_/h` shells out to `sh -e`, and
//! the repo's Windows cells use `shell: bash` = Git Bash). The skip is a
//! statement about the platform, not about the test: there is no Windows
//! CWD discipline to get wrong here, because there is no Windows hook.

const std = @import("std");
const builtin = @import("builtin");
const testing = std.testing;
const harness = @import("harness.zig");
const gpa = testing.allocator;
const io = testing.io;

const Io = std.Io;

/// The hook under test, relative to the repo root.
///
/// Relative, not absolute: the hook is invoked with the repo root as CWD
/// (that is what husky does — `core.hooksPath` is `.husky/_`, and git runs
/// hooks from the worktree root), and the whole point of the test is that
/// the hook's CWD is the root. Handing it an absolute path would hide a
/// CWD bug in the invocation instead of exposing it.
const HOOK_REL = ".husky/pre-commit";

/// The frontend lint step's required CWD, relative to the repo root.
const DESKTOP_REL = "src/apps/desktop";

/// The Zig lint step's script, spelled the way the hook spells it.
const ZIG_LINT_REL = "scripts/lint-no-catch-unreachable.sh";

/// The Zig scan's success line, which appears in the hook's stdout only if
/// the step actually ran. Assembled from two pieces because the linter scans
/// raw bytes and would flag the literal pair here.
const ZIG_SCAN_OK_LINE = "no 'catch" ++ " unreachable'";

/// What `zig build zginlint:check` prints when the tree is pinned.
const ZGINLINT_OK_LINE = "within the pinned ceilings";

/// The zginlint step as an executable line, newlines included so the
/// matching needle cannot be the hook's own header comment.
const ZGINLINT_HOOK_LINE = "\nzig build zginlint:check\n";

///
/// The hook runs a real selftest plus a real scan; 120 s is generous for
/// ~1 s of work and still bounds a wedged child.
const HOOK_TIMEOUT_MS: i64 = 120_000;

/// `subprocess.run(timeout=<ms>)` as `std.process.RunOptions.timeout`.
///
/// `Io.Timeout.duration` is a `Clock.Duration` — a (raw duration, clock)
/// PAIR, not a bare duration — and its constructors live on the RAW half.
/// `.awake` is monotonic: an NTP step during a run must not extend or
/// collapse the budget.
fn timeoutMs(ms: i64) Io.Timeout {
    return .{ .duration = .{
        .raw = .{ .nanoseconds = @as(i96, ms) * std.time.ns_per_ms },
        .clock = .awake,
    } };
}

/// Exit code of a finished child, or null if a signal stopped it.
///
/// `Child.Term` is a tagged union, NOT an optional: `.exited` is a `u8`
/// field, so `res.term.exited orelse ...` does not compile and a bare
/// `res.term.exited != 0` would read the wrong field on a signalled run.
fn exitCode(term: std.process.Child.Term) ?u8 {
    return switch (term) {
        .exited => |c| c,
        else => null,
    };
}

/// Absolute path of a repo-root-relative file. Owned.
///
/// `realPathFile` rather than cwd-relative concatenation: the hook is
/// spawned with an explicit CWD, so anything handed to it has to already
/// be absolute. It also fails loudly on a missing file, which is what
/// `assert HOOK.exists()` did in the Python original.
fn repoFileAbs(rel: []const u8) ![]u8 {
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const n = Io.Dir.cwd().realPathFile(io, rel, &buf) catch |err| switch (err) {
        error.FileNotFound, error.NameTooLong => {
            std.debug.print("hook file missing: {s}\n", .{rel});
            return error.TestUnexpectedResult;
        },
        else => return err,
    };
    return gpa.dupe(u8, buf[0..n]);
}

/// The repo root as an absolute path. Owned.
fn repoRootAbs() ![]u8 {
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const n = try Io.Dir.cwd().realPathFile(io, ".", &buf);
    return gpa.dupe(u8, buf[0..n]);
}

/// Write `contents` to `<dir>/<name>`, make it executable, return its path.
///
/// Owned by the caller. Mirrors `writeExecutableScript` in
/// `mcp_test_test.zig`: the stub has to be executable, and on POSIX that
/// is a `chmod` the caller must not forget.
fn writeExecutable(dir: []const u8, name: []const u8, contents: []const u8) ![]u8 {
    const path = try std.fs.path.join(gpa, &.{ dir, name });
    errdefer gpa.free(path);
    var f = try Io.Dir.cwd().createFile(io, path, .{});
    defer f.close(io);
    try f.writeStreamingAll(io, contents);
    if (builtin.os.tag != .windows) {
        try f.setPermissions(io, @enumFromInt(0o755));
    }
    return path;
}

/// Read a whole file. Owned.
fn readFile(path: []const u8) ![]u8 {
    return Io.Dir.cwd().readFileAlloc(io, path, gpa, .limited(1 << 20));
}

/// Read a whole file, or null when it does not exist. Owned when non-null.
///
/// The record files are written by the stubs, so "the stub never ran" and
/// "the stub ran and wrote nothing" are different failures and the caller
/// needs to tell them apart.
fn readFileOrNull(path: []const u8) !?[]u8 {
    return Io.Dir.cwd().readFileAlloc(io, path, gpa, .limited(1 << 20)) catch |err| switch (err) {
        error.FileNotFound => null,
        else => return err,
    };
}

/// The stub `pnpm`: record the CWD it was invoked from and the argv it got,
/// then exit 0 so the hook proceeds to the Zig step.
///
/// `pwd -P` (physical) rather than `pwd`: the assertion is about which
/// DIRECTORY the hook is in, and a logical `pwd` would echo whatever
/// `$PWD` the parent exported — which is exactly the value a `cd ../..`
/// bug leaves stale. `-P` asks the kernel.
///
/// The two records go to two files so a partial write cannot interleave
/// them into one unparseable line.
const PNPM_STUB =
    \\#!/bin/sh
    \\pwd -P > "$PNPM_STUB_CWD_OUT"
    \\printf '%s\n' "$*" > "$PNPM_STUB_ARGS_OUT"
    \\exit 0
;

/// The stub `bash`: record the CWD of every invocation of the Zig lint
/// script, then hand off to the REAL bash so the step still runs.
///
/// The `case` filter matters. The lint script's own `--selftest` re-invokes
/// itself through `command -v bash`, which on a PATH with this stub first
/// resolves to the stub — so without the filter the record would also
/// capture that nested call. Filtering on the script name keeps the record
/// to the invocations the HOOK makes, which is what the assertion is about.
///
/// `exec` rather than a subshell call: the stub must not add a process to
/// the tree, or the hook's `set -e` would see the stub's exit status
/// instead of the real bash's.
///
/// `$BASH_SHIM_REAL` is an ABSOLUTE path resolved before the stub dir was
/// prepended to PATH — a bare `exec bash` would find the stub again and
/// recurse until the process limit.
const BASH_STUB =
    \\#!/bin/sh
    \\case "$*" in
    \\  *lint-no-catch-unreachable.sh*)
    \\    pwd -P >> "$BASH_SHIM_CWD_OUT"
    \\    ;;
    \\esac
    \\exec "$BASH_SHIM_REAL" "$@"
;

/// The stub `zig`: record the CWD and argv of the hook's one invocation,
/// print what a green `zginlint:check` prints, then exit 0. Stubbed for the
/// same reason `pnpm` is — the real step compiles the CLI and walks 847 files.
const ZIG_STUB =
    \\#!/bin/sh
    \\pwd -P > "$ZIG_STUB_CWD_OUT"
    \\printf '%s\n' "$*" > "$ZIG_STUB_ARGS_OUT"
    \\printf '%s\n' "$ZGINLINT_OK_LINE"
    \\exit 0
;

/// A scratch dir holding the two stubs and their record files.
const Fixture = struct {
    scratch: []u8,
    bindir: []u8,
    pnpm: []u8,
    bash: []u8,
    zig: []u8,
    pnpm_cwd_out: []u8,
    pnpm_args_out: []u8,
    bash_cwd_out: []u8,
    zig_cwd_out: []u8,
    zig_args_out: []u8,

    fn deinit(self: *Fixture) void {
        harness.cleanupExtraDir(io, gpa, self.scratch);
        gpa.free(self.zig_args_out);
        gpa.free(self.zig_cwd_out);
        gpa.free(self.bash_cwd_out);
        gpa.free(self.pnpm_args_out);
        gpa.free(self.pnpm_cwd_out);
        gpa.free(self.zig);
        gpa.free(self.bash);
        gpa.free(self.pnpm);
        gpa.free(self.bindir);
        gpa.free(self.scratch);
    }
};

/// Build the stub fixture.
///
/// A `makeScratchDir` fixture, NOT `std.testing.tmpDir`: the latter lands
/// in `<cwd>/.zig-cache/tmp/`, inside the git worktree, and a stray
/// executable there is both a `git status` nuisance and a path the hook
/// could theoretically resolve. The scratch dir is under the OS temp root
/// and carries the `pabrik-fix-` marker, so `cleanupExtraDir` gates its
/// delete.
fn makeFixture() !Fixture {
    const scratch = try harness.makeScratchDir(gpa);
    errdefer gpa.free(scratch);

    const bindir = try std.fs.path.join(gpa, &.{ scratch, "bin" });
    errdefer gpa.free(bindir);
    try Io.Dir.cwd().createDirPath(io, bindir);

    const pnpm = try writeExecutable(bindir, "pnpm", PNPM_STUB);
    errdefer gpa.free(pnpm);

    // The real bash path is baked into the stub's ENVIRONMENT, not its
    // text: the path is host-specific and the stub is a fixed literal.
    const bash = try writeExecutable(bindir, "bash", BASH_STUB);
    errdefer gpa.free(bash);

    const zig = try writeExecutable(bindir, "zig", ZIG_STUB);
    errdefer gpa.free(zig);

    const pnpm_cwd_out = try std.fs.path.join(gpa, &.{ scratch, "pnpm-cwd.txt" });
    errdefer gpa.free(pnpm_cwd_out);
    const pnpm_args_out = try std.fs.path.join(gpa, &.{ scratch, "pnpm-args.txt" });
    errdefer gpa.free(pnpm_args_out);
    const bash_cwd_out = try std.fs.path.join(gpa, &.{ scratch, "bash-cwd.txt" });
    errdefer gpa.free(bash_cwd_out);
    const zig_cwd_out = try std.fs.path.join(gpa, &.{ scratch, "zig-cwd.txt" });
    errdefer gpa.free(zig_cwd_out);
    const zig_args_out = try std.fs.path.join(gpa, &.{ scratch, "zig-args.txt" });
    errdefer gpa.free(zig_args_out);

    return .{
        .scratch = scratch,
        .bindir = bindir,
        .pnpm = pnpm,
        .bash = bash,
        .zig = zig,
        .pnpm_cwd_out = pnpm_cwd_out,
        .pnpm_args_out = pnpm_args_out,
        .bash_cwd_out = bash_cwd_out,
        .zig_cwd_out = zig_cwd_out,
        .zig_args_out = zig_args_out,
    };
}

/// The environment the hook runs under: the parent's, with the stub bindir
/// FIRST on PATH and the record paths exported.
///
/// The stub bindir must precede everything else, or a real `pnpm` on the
/// developer's PATH wins and the test records nothing. `PATH` is rebuilt
/// from the ambient one rather than replaced, because the hook also needs
/// `dirname`, `mktemp`, `rg` and a real `bash` from it.
///
/// `std.process.run`'s `.environ_map` REPLACES the child environment, so
/// every variable the parent has must be copied in — dropping `HOME` or
/// `XDG_*` would change the hook's behaviour for reasons unrelated to the
/// CWD under test.
fn hookEnviron(fx: *Fixture, real_bash: []const u8) !std.process.Environ.Map {
    var map = try std.process.Environ.createMap(std.testing.environ, gpa);
    errdefer map.deinit();

    const ambient_path = std.testing.environ.getAlloc(gpa, "PATH") catch "";
    defer gpa.free(ambient_path);
    const path = try std.fmt.allocPrint(gpa, "{s}{c}{s}", .{
        fx.bindir,
        std.fs.path.delimiter,
        ambient_path,
    });
    defer gpa.free(path);
    try map.put("PATH", path);

    try map.put("PNPM_STUB_CWD_OUT", fx.pnpm_cwd_out);
    try map.put("PNPM_STUB_ARGS_OUT", fx.pnpm_args_out);
    try map.put("BASH_SHIM_CWD_OUT", fx.bash_cwd_out);
    try map.put("BASH_SHIM_REAL", real_bash);
    try map.put("ZIG_STUB_CWD_OUT", fx.zig_cwd_out);
    try map.put("ZIG_STUB_ARGS_OUT", fx.zig_args_out);
    try map.put("ZGINLINT_OK_LINE", ZGINLINT_OK_LINE);
    return map;
}

/// Run the real hook from the repo root with the stubs on PATH.
///
/// Returns the child's exit code plus its captured streams; the caller
/// owns the two buffers and must free them.
const HookRun = struct {
    code: ?u8,
    stdout: []u8,
    stderr: []u8,

    fn deinit(self: *HookRun) void {
        gpa.free(self.stdout);
        gpa.free(self.stderr);
    }
};

fn runHook(hook_abs: []const u8, root: []const u8, fx: *Fixture, real_bash: []const u8) !HookRun {
    var env_map = try hookEnviron(fx, real_bash);
    defer env_map.deinit();

    const res = std.process.run(gpa, io, .{
        .argv = &.{ "sh", hook_abs },
        // The CWD husky gives the hook: the worktree root. This is the
        // precondition the whole test is about — if it were wrong, the
        // Zig step would fail for a reason that is not the hook's bug.
        .cwd = .{ .path = root },
        .environ_map = &env_map,
        .timeout = timeoutMs(HOOK_TIMEOUT_MS),
    }) catch |err| {
        std.debug.print("could not run the hook ({s})\n", .{@errorName(err)});
        return error.TestUnexpectedResult;
    };
    return .{ .code = exitCode(res.term), .stdout = res.stdout, .stderr = res.stderr };
}

/// Absolute path of the real `bash`, resolved on the AMBIENT PATH.
///
/// Probed with `std.process.run`, which inherits the real process
/// environment — NOT the stub bindir — so the answer is the system bash
/// and not the stub this suite is about to install. Owned.
fn realBashAbs() ![]u8 {
    const res = std.process.run(gpa, io, .{
        .argv = &.{ "sh", "-c", "command -v bash" },
        .timeout = timeoutMs(10_000),
    }) catch |err| {
        std.debug.print("could not probe for bash ({s})\n", .{@errorName(err)});
        return error.TestUnexpectedResult;
    };
    defer {
        gpa.free(res.stdout);
        gpa.free(res.stderr);
    }
    if (exitCode(res.term) != 0) {
        std.debug.print("no `bash` on PATH to run the hook's Zig lint step\n", .{});
        return error.SkipZigTest;
    }
    const trimmed = std.mem.trimEnd(u8, res.stdout, "\r\n");
    if (trimmed.len == 0) {
        std.debug.print("`command -v bash` printed nothing\n", .{});
        return error.TestUnexpectedResult;
    }
    return gpa.dupe(u8, trimmed);
}

/// Is `rg` resolvable on the AMBIENT PATH?
///
/// The Zig lint step fails closed when `rg` is absent (by design — a lint
/// that cannot run must never report the tree clean), so on a machine with
/// no ripgrep the hook exits 1 for an environmental reason. Probing with
/// `std.process.run` inherits the real environment, so the answer is about
/// the machine, not about the stub bindir.
fn hasRipgrep() bool {
    const res = std.process.run(gpa, io, .{
        .argv = &.{ "sh", "-c", "command -v rg >/dev/null 2>&1" },
        .timeout = timeoutMs(10_000),
    }) catch return false;
    defer {
        gpa.free(res.stdout);
        gpa.free(res.stderr);
    }
    return exitCode(res.term) == 0;
}

/// Everything a test needs to run the hook once: the hook's absolute path,
/// the repo root, the real bash, and the stub fixture.
///
/// One setup helper so the four tests cannot drift apart in what they
/// install — a test that forgot the `bash` stub would silently stop
/// observing the CWD and still pass.
const Setup = struct {
    hook: []u8,
    root: []u8,
    real_bash: []u8,
    fx: Fixture,

    fn deinit(self: *Setup) void {
        self.fx.deinit();
        gpa.free(self.real_bash);
        gpa.free(self.root);
        gpa.free(self.hook);
    }

    fn run(self: *Setup) !HookRun {
        return runHook(self.hook, self.root, &self.fx, self.real_bash);
    }
};

fn makeSetup() !Setup {
    const hook = try repoFileAbs(HOOK_REL);
    errdefer gpa.free(hook);
    const root = try repoRootAbs();
    errdefer gpa.free(root);
    const real_bash = try realBashAbs();
    errdefer gpa.free(real_bash);
    var fx = try makeFixture();
    errdefer fx.deinit();
    return .{ .hook = hook, .root = root, .real_bash = real_bash, .fx = fx };
}

// ============================================================================
// The tests
// ============================================================================

// The headline regression: the hook exits 0 and the Zig scan's success line
// is in its stdout, which means the step RAN. Pre-fix it exited 127 with
// `bash: scripts/lint-no-catch-unreachable.sh: No such file or directory`,
// because `cd ../..` had left the hook in `src/`.
test "pre_commit_hook_reaches_the_zig_lint_step" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;
    if (!hasRipgrep()) {
        std.debug.print(
            "skipping: no `rg` on PATH, and the Zig lint step fails closed " ++
                "without it (by design), so the hook would exit 1 for an " ++
                "environmental reason rather than the CWD bug under test\n",
            .{},
        );
        return error.SkipZigTest;
    }

    var s = try makeSetup();
    defer s.deinit();

    var run = try s.run();
    defer run.deinit();

    if (run.code == null or run.code.? != 0) {
        std.debug.print(
            "hook exited {?d}, expected 0.\n--stdout--\n{s}\n--stderr--\n{s}\n",
            .{ run.code, run.stdout, run.stderr },
        );
        return error.TestUnexpectedResult;
    }

    // The Zig step's own success line is in the hook's stdout. Asserting it
    // (rather than only the exit code) distinguishes "the scan ran and
    // found nothing" from "the hook skipped the step entirely" — a hook
    // that had deleted the Zig lines would also exit 0.
    if (std.mem.indexOf(u8, run.stdout, ZIG_SCAN_OK_LINE) == null) {
        std.debug.print(
            "hook exited 0 but never ran the Zig scan:\n{s}\n",
            .{run.stdout},
        );
        return error.TestUnexpectedResult;
    }

    // The same guard for the third step. A hook that dropped
    // `zig build zginlint:check` would still exit 0 on this fixture,
    // because the `zig` stub is only invoked when the hook names it.
    if (std.mem.indexOf(u8, run.stdout, ZGINLINT_OK_LINE) == null) {
        std.debug.print(
            "hook exited 0 but never ran `zig build zginlint:check`:\n{s}\n",
            .{run.stdout},
        );
        return error.TestUnexpectedResult;
    }
}

// The frontend half still mirrors CI: `pnpm run lint:check` from
// src/apps/desktop. The subshell fix must not have moved the lint itself.
test "pre_commit_hook_runs_the_frontend_lint_from_the_desktop_dir" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;

    var s = try makeSetup();
    defer s.deinit();

    var run = try s.run();
    defer run.deinit();

    // The stub must have been invoked at all. A hook that never reaches
    // the frontend lint would leave both record files absent, and reading
    // a missing file must be a failure rather than a vacuous pass.
    const recorded_cwd = (try readFileOrNull(s.fx.pnpm_cwd_out)) orelse {
        std.debug.print(
            "the stub pnpm was never invoked (no {s}); hook exited {?d}\n--stderr--\n{s}\n",
            .{ s.fx.pnpm_cwd_out, run.code, run.stderr },
        );
        return error.TestUnexpectedResult;
    };
    defer gpa.free(recorded_cwd);

    const want_cwd = try std.fs.path.join(gpa, &.{ s.root, DESKTOP_REL });
    defer gpa.free(want_cwd);

    // `pwd -P` emits a trailing newline; trim it before comparing.
    const got_cwd = std.mem.trimEnd(u8, recorded_cwd, "\r\n");
    if (!std.mem.eql(u8, got_cwd, want_cwd)) {
        std.debug.print(
            "frontend lint ran from \"{s}\", expected \"{s}\"\n",
            .{ got_cwd, want_cwd },
        );
        return error.TestUnexpectedResult;
    }

    const recorded_args = (try readFileOrNull(s.fx.pnpm_args_out)) orelse {
        std.debug.print("the stub pnpm recorded no argv\n", .{});
        return error.TestUnexpectedResult;
    };
    defer gpa.free(recorded_args);
    const got_args = std.mem.trimEnd(u8, recorded_args, "\r\n");
    if (!std.mem.eql(u8, got_args, "run lint:check")) {
        std.debug.print(
            "frontend lint invoked as \"pnpm {s}\", expected \"pnpm run lint:check\"\n",
            .{got_args},
        );
        return error.TestUnexpectedResult;
    }
}

// The property `cd ../..` broke, asserted directly rather than through the
// exit code: when the hook invokes the Zig lint script, its own CWD is the
// repo root.
//
// HOW THIS OBSERVES IT: the `bash` stub records `pwd -P` for every
// invocation of `scripts/lint-no-catch-unreachable.sh` and then execs the
// real bash. A child inherits its parent's CWD, so the recorded value IS
// the hook's CWD at that moment. Pre-fix it was `src/`; the assertion is
// that it is the root.
//
// This is the test that catches the bug on its own: it needs neither `rg`
// nor a passing scan, and it does not care what the hook's exit code was.
test "pre_commit_hook_invokes_the_zig_lint_from_the_repo_root" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;

    var s = try makeSetup();
    defer s.deinit();

    var run = try s.run();
    defer run.deinit();

    const recorded = (try readFileOrNull(s.fx.bash_cwd_out)) orelse {
        std.debug.print(
            "the hook never invoked `bash {s}` — the Zig coding-standards " ++
                "gate is not mirrored locally at all\n",
            .{ZIG_LINT_REL},
        );
        return error.TestUnexpectedResult;
    };
    defer gpa.free(recorded);

    // One line per invocation. CI makes two (selftest, then scan), so at
    // least two lines is the floor; the FIRST is the one whose CWD decides
    // whether the relative path resolves.
    var lines = std.mem.splitScalar(u8, recorded, '\n');
    var first: ?[]const u8 = null;
    var count: usize = 0;
    while (lines.next()) |raw| {
        const line = std.mem.trimEnd(u8, raw, "\r");
        if (line.len == 0) continue;
        if (first == null) first = line;
        count += 1;
    }

    const got = first orelse {
        std.debug.print("the bash stub recorded no CWD\n", .{});
        return error.TestUnexpectedResult;
    };

    if (!std.mem.eql(u8, got, s.root)) {
        std.debug.print(
            "the hook invoked `bash {s}` from \"{s}\", not the repo root " ++
                "\"{s}\" — so the relative path cannot resolve (this is the " ++
                "`cd ../..` bug)\n",
            .{ ZIG_LINT_REL, got, s.root },
        );
        return error.TestUnexpectedResult;
    }

    if (count < 2) {
        std.debug.print(
            "the hook invoked the Zig lint script {d} time(s); CI's `lint` " ++
                "job runs it twice (--selftest, then the scan)\n",
            .{count},
        );
        return error.TestUnexpectedResult;
    }
}

// The third mirrored step has the same CWD requirement as the Zig scan:
// `zig build zginlint:check` resolves `build.zig` and the baseline
// relative to the repo root.

// Observed through the `zig` stub's `pwd -P`, for the same reason the bash
// stub is: a child inherits the hook's CWD, so the record IS the hook's.
test "pre_commit_hook_invokes_zginlint_from_the_repo_root" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;

    var s = try makeSetup();
    defer s.deinit();

    var run = try s.run();
    defer run.deinit();

    const recorded_cwd = (try readFileOrNull(s.fx.zig_cwd_out)) orelse {
        std.debug.print(
            "the hook never invoked `zig` — the zginlint gate is not " ++
                "mirrored locally at all (hook exited {?d})\n",
            .{run.code},
        );
        return error.TestUnexpectedResult;
    };
    defer gpa.free(recorded_cwd);

    const got_cwd = std.mem.trimEnd(u8, recorded_cwd, "\r\n");
    if (!std.mem.eql(u8, got_cwd, s.root)) {
        std.debug.print(
            "the hook invoked `zig` from \"{s}\", not the repo root " ++
                "\"{s}\" — `build.zig` and the baseline would not resolve\n",
            .{ got_cwd, s.root },
        );
        return error.TestUnexpectedResult;
    }

    const recorded_args = (try readFileOrNull(s.fx.zig_args_out)) orelse {
        std.debug.print("the stub zig recorded no argv\n", .{});
        return error.TestUnexpectedResult;
    };
    defer gpa.free(recorded_args);
    const got_args = std.mem.trimEnd(u8, recorded_args, "\r\n");
    if (!std.mem.eql(u8, got_args, "build zginlint:check")) {
        std.debug.print(
            "the hook invoked `zig {s}`, expected `zig build zginlint:check`\n",
            .{got_args},
        );
        return error.TestUnexpectedResult;
    }
}

// The hook must not have been "fixed" by deleting the Zig step, and must
// not have regressed to a bare `cd`.
//
// A hook that drops the two `bash scripts/lint-no-catch-unreachable.sh`
// lines exits 0 on every commit and mirrors nothing — the exact failure
// mode PR #398 left behind ("the CI job was deleted, which left this hook
// mirroring nothing"). And a hook that went back to a bare
// `cd src/apps/desktop` would pass the exit-code test only by accident of
// where it happened to land.
test "pre_commit_hook_invokes_the_zig_lint_script_by_its_repo_relative_path" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;

    const hook = try repoFileAbs(HOOK_REL);
    defer gpa.free(hook);

    const body = try readFile(hook);
    defer gpa.free(body);

    // Both invocations the CI job makes: the selftest first (a scanner
    // that has stopped matching is a silent outage), then the scan.
    const needle_selftest = "bash " ++ ZIG_LINT_REL ++ " --selftest";
    const needle_scan = "bash " ++ ZIG_LINT_REL ++ "\n";
    if (std.mem.indexOf(u8, body, needle_selftest) == null) {
        std.debug.print(
            "the hook no longer runs `{s}` — the Zig coding-standards gate " ++
                "is not mirrored locally\n",
            .{needle_selftest},
        );
        return error.TestUnexpectedResult;
    }
    if (std.mem.indexOf(u8, body, needle_scan) == null) {
        std.debug.print(
            "the hook no longer runs `{s}` — the Zig coding-standards gate " ++
                "is not mirrored locally\n",
            .{ZIG_LINT_REL},
        );
        return error.TestUnexpectedResult;
    }

    // And the zginlint gate must still be named. Dropping this line would
    // leave the hook mirroring a job it no longer runs.
    if (std.mem.indexOf(u8, body, ZGINLINT_HOOK_LINE) == null) {
        std.debug.print(
            "the hook no longer runs `{s}` — the zginlint gate is not " ++
                "mirrored locally\n",
            .{ZGINLINT_HOOK_LINE},
        );
        return error.TestUnexpectedResult;
    }

    // And the frontend lint must still be there, in a subshell. A bare
    // `cd src/apps/desktop` is the shape that broke; the subshell is what
    // keeps the parent's CWD at the root.
    if (std.mem.indexOf(u8, body, "(cd " ++ DESKTOP_REL) == null) {
        std.debug.print(
            "the hook no longer runs the frontend lint in a subshell " ++
                "(`(cd {s} && ...)`) — a bare `cd` is what moved the CWD " ++
                "out from under the Zig step\n",
            .{DESKTOP_REL},
        );
        return error.TestUnexpectedResult;
    }
}
