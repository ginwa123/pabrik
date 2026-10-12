// Functional wire tests for the kanban board's PR surface:
//   GET  /api/git/pr/list   — the repo's change requests
//   POST /api/git/pr/close  — close one of them
//
// These are the two routes `KanbanPrList.vue` calls, so this suite is the
// only place their status codes, their JSON keys and the route table's
// resolution are exercised together.
//
// WHY EACH TEST EXISTS (the four failures a unit test cannot see):
//
//   1. Route resolution. `/api/git/pr/list` and `/api/git/pr/close` are
//      literal paths, and the router walks registration order — so a
//      future `:param` sibling added above them would silently capture
//      both. The witness is behavioural, not a grep: a request with no
//      `path` must answer the HANDLER's 400 ("Missing path parameter"),
//      not the router's 404. That is what `list_missing_path_is_400`
//      asserts, and it fails the moment the route stops resolving to this
//      handler.
//   2. Strict validators. `state` and `limit` are validated before any
//      spawn; a bad `limit` that got clamped instead of refused would
//      report `truncated` for a page nobody asked for.
//   3. Empty vs unknown. A forge failure must be a 502 carrying the CLI's
//      own sentence — never a 200 with `changes: []`, which is the PR #719
//      bug class (an empty surface that cannot be told from a failed one).
//   4. The close answer. `closed` must be the forge's RE-READ state, so a
//      CLI that exits 0 without closing anything reports `false` plus a
//      sentence instead of a success.
//
// HOW THE FAKE `gh` REACHES THE SERVER: PATH. The backend spawns `gh` by
// bare name (`Programs.gh = "gh"`) and the only injection seam
// (`listUseCaseWithPrograms`) is unit-test-only, invisible over HTTP — so
// `PathShadow` prepends a bindir to `std.testing.environ`, which is the
// exact block `Harness.boot` copies into the child env. The server is
// booted AFTER the shadow is installed.
//
// WHERE THE FIXTURE LIVES: `harness.makeScratchDir`, never
// `std.testing.tmpDir` — the `pabrik-func-` namespace is what
// `reapOrphanTestPids` deletes on every boot, and `<cwd>/.zig-cache/tmp/`
// is INSIDE a git worktree, where `git rev-parse` walks up and the fixture
// repo would resolve to the worktree's own branch.

const std = @import("std");
const testing = std.testing;
const harness = @import("harness.zig");
const Harness = harness.Harness;
const gpa = testing.allocator;
const io = testing.io;

// ============================================================================
// Fixtures
// ============================================================================

/// The suite's own scratch directory (the git repo + the fake bin),
/// outside the harness's tempdir namespace.
const Scratch = struct {
    root: []u8,

    fn init() !Scratch {
        return .{ .root = try harness.makeScratchDir(gpa) };
    }

    /// LIFO note: `cleanupExtraDir` READS `root`, so the free is registered
    /// first — freeing the slice before the cleaner read it is a
    /// use-after-free that happens to read as a plausible path.
    fn deinit(self: *Scratch) void {
        harness.cleanupExtraDir(io, gpa, self.root);
        gpa.free(self.root);
    }

    fn path(self: *Scratch, parts: []const []const u8) ![]u8 {
        return harness.harnessPath(gpa, self.root, parts);
    }
};

/// `git` in `cwd` with the fixture identity baked in, so the suite never
/// depends on the machine's global git config (`commit.gpgsign=false`
/// additionally stops a developer's signing setup from failing the commit).
fn git(cwd: []const u8, args: []const []const u8) !void {
    var argv: std.ArrayList([]const u8) = .empty;
    defer argv.deinit(gpa);
    try argv.appendSlice(gpa, &.{
        "git",                  "-c",          "user.email=t@t",
        "-c",                   "user.name=t", "-c",
        "commit.gpgsign=false",
    });
    try argv.appendSlice(gpa, args);

    var child = try std.process.spawn(io, .{ .argv = argv.items, .cwd = .{ .path = cwd } });
    const term = child.wait(io) catch |err| {
        std.debug.print("git {s} did not wait: {s}\n", .{ args[0], @errorName(err) });
        return error.SkipZigTest;
    };
    switch (term) {
        .exited => |code| if (code != 0) {
            std.debug.print("git {s} exited {d}\n", .{ args[0], code });
            return error.TestUnexpectedResult;
        },
        else => {
            std.debug.print("git {s} died by signal\n", .{args[0]});
            return error.TestUnexpectedResult;
        },
    }
}

/// A real worktree (not a bare `.git`) at a path the handler can gate on.
fn buildRepo(s: *Scratch, name: []const u8) ![]u8 {
    const cwd = try s.path(&.{name});
    errdefer gpa.free(cwd);

    try std.Io.Dir.cwd().createDirPath(io, cwd);
    try git(s.root, &.{ "init", "--initial-branch=main", "--quiet", cwd });

    {
        const p = try std.fs.path.join(gpa, &.{ cwd, "a.txt" });
        defer gpa.free(p);
        var f = try std.Io.Dir.cwd().createFile(io, p, .{});
        defer f.close(io);
        try f.writeStreamingAll(io, "hi\n");
    }
    try git(cwd, &.{ "add", "-A" });
    try git(cwd, &.{ "commit", "--quiet", "-m", "base" });

    return cwd;
}

fn writeExecScript(path: []const u8, contents: []const u8) !void {
    var f = try std.Io.Dir.cwd().createFile(io, path, .{});
    defer f.close(io);
    try f.writeStreamingAll(io, contents);
    // `.executable_file` also makes the file READABLE, which OR-ing an
    // exec bit into a fresh file's mode does not guarantee.
    try std.Io.Dir.cwd().setFilePermissions(io, path, .executable_file, .{});
}

/// An executable `gh` stub in its OWN bindir, so prepending that directory
/// to PATH cannot shadow another command the server needs (notably `git`,
/// which the repo gate runs).
fn installFakeGh(s: *Scratch, dir_name: []const u8, body: []const u8) ![]u8 {
    const bindir = try s.path(&.{dir_name});
    errdefer gpa.free(bindir);
    try std.Io.Dir.cwd().createDirPath(io, bindir);

    const gh_path = try std.fs.path.join(gpa, &.{ bindir, "gh" });
    defer gpa.free(gh_path);
    try writeExecScript(gh_path, body);

    return bindir;
}

/// Prepend `prefix` to `PATH` in `std.testing.environ` — the exact block
/// `Harness.boot` copies into the child env. Scoped by `restore`: the
/// shadow must not outlive the test, or every later suite in the same
/// process would spawn the fake `gh`.
const PathShadow = struct {
    gpa: std.mem.Allocator,
    saved: std.process.Environ,
    entries: [:null]const ?[*:0]const u8,

    fn install(alloc: std.mem.Allocator, prefix: []const u8) !PathShadow {
        // POSIX only: on Windows `Environ` is a PEB pointer read through
        // `GlobalBlock`, which Zig offers no way to shadow — and the
        // fixture `gh` is a `/bin/sh` script anyway.
        if (comptime @import("builtin").os.tag != .windows) {
            const saved = std.testing.environ;
            const orig = saved.block.slice;

            const entries = try alloc.allocSentinel(?[*:0]const u8, orig.len, null);
            errdefer alloc.free(entries);

            var owned: std.ArrayList([:0]u8) = .empty;
            defer owned.deinit(alloc);
            errdefer for (owned.items) |o| alloc.free(o);

            for (orig, 0..) |maybe, i| {
                const str = std.mem.span(maybe.?);
                if (std.mem.startsWith(u8, str, "PATH=")) {
                    try owned.append(alloc, try std.fmt.allocPrintSentinel(alloc, "PATH={s}{c}{s}", .{
                        prefix,
                        std.fs.path.delimiter,
                        str["PATH=".len..],
                    }, 0));
                } else {
                    try owned.append(alloc, try alloc.dupeZ(u8, str));
                }
                entries[i] = owned.items[owned.items.len - 1].ptr;
            }

            std.testing.environ = .{ .block = .{ .slice = entries } };
            return .{ .gpa = alloc, .saved = saved, .entries = entries };
        } else {
            return error.SkipZigTest;
        }
    }

    fn restore(self: PathShadow) void {
        std.testing.environ = self.saved;
        for (self.entries) |e| self.gpa.free(std.mem.span(e.?));
        self.gpa.free(self.entries);
    }
};

// ============================================================================
// The fake `gh` payloads — literals, so what the CLI prints is visible in
// the diff next to the assertion that reads it.
// ============================================================================

/// Two rows: one open PR on a worktree branch (the board join key) and one
/// merged, draft PR, so `state` normalization and `is_draft` are both
/// exercised by one payload.
const LIST_ROWS_JSON =
    \\[{"number":909,"title":"fix(settings): remove redundant workspace-name box","url":"https://github.com/ginwa123/pabrik/pull/909","state":"OPEN","isDraft":false,"headRefName":"worktree/why-theres-a-box-workspace-1791785919283","baseRefName":"main","author":{"login":"ginwa123"},"updatedAt":"2026-10-12T06:34:01Z"},
    \\ {"number":893,"title":"feat(secrets): seal workspace secret values at rest","url":"https://github.com/ginwa123/pabrik/pull/893","state":"MERGED","isDraft":true,"headRefName":"worktree/workspace-secrets-hardening-impl","baseRefName":"main","author":{"login":"ginwa123"},"updatedAt":"2026-10-11T18:56:40Z"}]
;

/// `gh pr view --json …` AFTER a successful close.
const CLOSED_VIEW_JSON =
    \\{"number":893,"title":"feat(secrets)","url":"https://github.com/ginwa123/pabrik/pull/893","state":"CLOSED","mergeable":"","mergeStateStatus":"","headRefName":"worktree/workspace-secrets-hardening-impl","baseRefName":"main","createdAt":"","updatedAt":"","mergedAt":null,"closedAt":"2026-10-12T07:00:00Z","author":{"login":"ginwa123"},"additions":0,"deletions":0,"changedFiles":0,"headRefOid":""}
;

/// The same re-read when the close did NOT take effect.
const OPEN_VIEW_JSON =
    \\{"number":893,"title":"feat(secrets)","url":"https://github.com/ginwa123/pabrik/pull/893","state":"OPEN","mergeable":"MERGEABLE","mergeStateStatus":"CLEAN","headRefName":"worktree/workspace-secrets-hardening-impl","baseRefName":"main","createdAt":"","updatedAt":"","mergedAt":null,"closedAt":null,"author":{"login":"ginwa123"},"additions":0,"deletions":0,"changedFiles":0,"headRefOid":""}
;

/// `gh pr list --json …` printing nothing at all — a repo with no matches.
const GH_EMPTY_LIST_SCRIPT =
    \\#!/bin/sh
    \\echo '[]'
;

/// The auth failure a logged-out machine gets, verbatim.
const GH_AUTH_FAILURE_SCRIPT =
    \\#!/bin/sh
    \\echo 'To get started with GitHub CLI, please run: gh auth login' >&2
    \\exit 4
;

// ============================================================================
// JSON readers — every one of them FAILS on an absent key rather than
// defaulting, so a renamed field cannot pass as a value.
// ============================================================================

fn asObject(v: std.json.Value) !std.json.ObjectMap {
    return switch (v) {
        .object => |o| o,
        else => error.TestUnexpectedResult,
    };
}

fn arrayLen(doc: *const harness.Json, key: []const u8) !usize {
    const o = try asObject(doc.value().*);
    return switch (o.get(key) orelse {
        std.debug.print("response has no `{s}`\n", .{key});
        return error.TestUnexpectedResult;
    }) {
        .array => |a| a.items.len,
        else => {
            std.debug.print("`{s}` is not an array\n", .{key});
            return error.TestUnexpectedResult;
        },
    };
}

fn itemAt(doc: *const harness.Json, key: []const u8, index: usize) !std.json.ObjectMap {
    const o = try asObject(doc.value().*);
    const arr = switch (o.get(key) orelse {
        std.debug.print("response has no `{s}`\n", .{key});
        return error.TestUnexpectedResult;
    }) {
        .array => |a| a,
        else => {
            std.debug.print("`{s}` is not an array\n", .{key});
            return error.TestUnexpectedResult;
        },
    };
    return asObject(arr.items[index]);
}

fn expectEqualStr(doc: *const harness.Json, key: []const u8, want: []const u8) !void {
    const got = doc.str(key) orelse {
        std.debug.print("response has no string `{s}`\n", .{key});
        return error.TestUnexpectedResult;
    };
    if (!std.mem.eql(u8, got, want)) {
        std.debug.print("`{s}` = \"{s}\", expected \"{s}\"\n", .{ key, got, want });
        return error.TestUnexpectedResult;
    }
}

fn expectEqualBool(doc: *const harness.Json, key: []const u8, want: bool) !void {
    const got = doc.boolean(key) orelse {
        std.debug.print("response has no boolean `{s}`\n", .{key});
        return error.TestUnexpectedResult;
    };
    if (got != want) {
        std.debug.print("`{s}` = {}, expected {}\n", .{ key, got, want });
        return error.TestUnexpectedResult;
    }
}

fn expectObjStr(o: std.json.ObjectMap, key: []const u8, want: []const u8) !void {
    const got = switch (o.get(key) orelse {
        std.debug.print("row has no `{s}`\n", .{key});
        return error.TestUnexpectedResult;
    }) {
        .string => |s| s,
        else => {
            std.debug.print("row `{s}` is not a string\n", .{key});
            return error.TestUnexpectedResult;
        },
    };
    if (!std.mem.eql(u8, got, want)) {
        std.debug.print("row `{s}` = \"{s}\", expected \"{s}\"\n", .{ key, got, want });
        return error.TestUnexpectedResult;
    }
}

fn expectObjBool(o: std.json.ObjectMap, key: []const u8, want: bool) !void {
    const got = switch (o.get(key) orelse {
        std.debug.print("row has no `{s}`\n", .{key});
        return error.TestUnexpectedResult;
    }) {
        .bool => |b| b,
        else => {
            std.debug.print("row `{s}` is not a bool\n", .{key});
            return error.TestUnexpectedResult;
        },
    };
    if (got != want) {
        std.debug.print("row `{s}` = {}, expected {}\n", .{ key, got, want });
        return error.TestUnexpectedResult;
    }
}

/// The `error` sentence, which must be PRESENT — an absent key is a failure,
/// not an empty string.
fn requireError(doc: *const harness.Json, needle: []const u8) !void {
    return requireField(doc, "error", needle);
}

/// A named string field that must exist and mention `needle`. Shared by the
/// error bodies (`error`) and the `{ closed: false }` answer (`detail`) — the
/// assertion is the same, because "the sentence must be there" is.
fn requireField(doc: *const harness.Json, field: []const u8, needle: []const u8) !void {
    const got = doc.str(field) orelse {
        std.debug.print("body carries no `{s}` field\n", .{field});
        return error.TestUnexpectedResult;
    };
    if (needle.len > 0 and std.mem.indexOf(u8, got, needle) == null) {
        std.debug.print("`{s}` = \"{s}\", expected it to mention \"{s}\"\n", .{ field, got, needle });
        return error.TestUnexpectedResult;
    }
}

fn bootHarness() !Harness {
    return Harness.boot(io, gpa, .{});
}

/// The `POST /api/git/pr/close` body the frontend sends, built from the
/// fixture repo. The harness copies `json_body` internally, so this temporary
/// is freed by the caller immediately after the request.
fn closeBody(repo: []const u8) ![]const u8 {
    return std.fmt.allocPrint(gpa, "{{\"path\":\"{s}\",\"pr\":\"893\",\"provider\":\"github\"}}", .{repo});
}

// ============================================================================
// GET /api/git/pr/list
// ============================================================================

// 1. No `path` → the HANDLER's 400. This is also the route-resolution
//    witness: a 404 here would mean `/api/git/pr/list` never reached its
//    handler (a `:param` sibling registered above it, or a dropped route).
test "list_missing_path_is_400" {
    try harness.requirePabrikBin(io, gpa);

    var h = try bootHarness();
    defer h.deinit(io) catch |err| std.debug.print("teardown: {s}\n", .{@errorName(err)});

    var r = try h.http(io, .GET, "/api/git/pr/list", .{ .expect = &.{400} });
    defer r.deinit();
    var doc = try r.json();
    defer doc.deinit();

    try requireError(&doc, "Missing path parameter");
}

// 2. An unknown `state` is refused before anything is spawned. Accepting it
//    silently would list the wrong set and label the tab with it.
test "list_unknown_state_is_400" {
    try harness.requirePabrikBin(io, gpa);

    var s = try Scratch.init();
    defer s.deinit();
    const repo = try buildRepo(&s, "pr-list-state");
    defer gpa.free(repo);

    var h = try bootHarness();
    defer h.deinit(io) catch |err| std.debug.print("teardown: {s}\n", .{@errorName(err)});

    var r = try h.http(io, .GET, "/api/git/pr/list", .{
        .params = &.{
            .{ .name = "path", .value = repo },
            .{ .name = "state", .value = "OPEN" },
        },
        .expect = &.{400},
    });
    defer r.deinit();
    var doc = try r.json();
    defer doc.deinit();

    try requireError(&doc, "state must be");
}

// 3. A limit outside 1..=100 is refused, not clamped: a clamped page would
//    answer `truncated` for a limit the caller never asked for.
test "list_limit_out_of_range_is_400" {
    try harness.requirePabrikBin(io, gpa);

    var s = try Scratch.init();
    defer s.deinit();
    const repo = try buildRepo(&s, "pr-list-limit");
    defer gpa.free(repo);

    var h = try bootHarness();
    defer h.deinit(io) catch |err| std.debug.print("teardown: {s}\n", .{@errorName(err)});

    for ([_][]const u8{ "0", "101", "abc" }) |bad| {
        var r = try h.http(io, .GET, "/api/git/pr/list", .{
            .params = &.{
                .{ .name = "path", .value = repo },
                .{ .name = "limit", .value = bad },
            },
            .expect = &.{400},
        });
        defer r.deinit();
        var doc = try r.json();
        defer doc.deinit();
        try requireError(&doc, "limit must be");
    }
}

// 4. A plain directory is 404 — a real handler answer, not route shadowing.
test "list_non_repo_is_404" {
    try harness.requirePabrikBin(io, gpa);

    var s = try Scratch.init();
    defer s.deinit();
    const plain = try s.path(&.{"plain"});
    defer gpa.free(plain);
    try std.Io.Dir.cwd().createDirPath(io, plain);

    var h = try bootHarness();
    defer h.deinit(io) catch |err| std.debug.print("teardown: {s}\n", .{@errorName(err)});

    var r = try h.http(io, .GET, "/api/git/pr/list", .{
        .params = &.{.{ .name = "path", .value = plain }},
        .expect = &.{404},
    });
    defer r.deinit();
    var doc = try r.json();
    defer doc.deinit();

    try requireError(&doc, "not a git repository");
}

// 5. The happy path, and the two fields the BOARD depends on: `head_ref`
//    (matched against `task.git_branch`, exactly) and the normalized
//    `state` (the UI switches on "open"/"merged"/"closed", never on the
//    forge's own spelling).
test "list_returns_rows_with_the_branch_the_board_joins_on" {
    try harness.requirePabrikBin(io, gpa);

    var s = try Scratch.init();
    defer s.deinit();
    const repo = try buildRepo(&s, "pr-list-happy");
    defer gpa.free(repo);

    const bindir = try installFakeGh(&s, "bin-happy", "#!/bin/sh\necho '" ++ LIST_ROWS_JSON ++ "'\n");
    defer gpa.free(bindir);

    var shadow = try PathShadow.install(gpa, bindir);
    defer shadow.restore();

    var h = try bootHarness();
    defer h.deinit(io) catch |err| std.debug.print("teardown: {s}\n", .{@errorName(err)});

    var r = try h.http(io, .GET, "/api/git/pr/list", .{
        .params = &.{
            .{ .name = "path", .value = repo },
            .{ .name = "state", .value = "open" },
            .{ .name = "limit", .value = "5" },
        },
        .expect = &.{200},
    });
    defer r.deinit();
    var doc = try r.json();
    defer doc.deinit();

    try expectEqualStr(&doc, "provider", "github");
    try expectEqualStr(&doc, "program", "gh");
    try expectEqualStr(&doc, "state", "open");
    // Two rows came back for a limit of five, so the page is complete.
    try expectEqualBool(&doc, "truncated", false);

    if (try arrayLen(&doc, "changes") != 2) {
        std.debug.print("expected 2 rows\n", .{});
        return error.TestUnexpectedResult;
    }

    const first = try itemAt(&doc, "changes", 0);
    try expectObjStr(first, "head_ref", "worktree/why-theres-a-box-workspace-1791785919283");
    try expectObjStr(first, "state", "open");
    try expectObjStr(first, "base_ref", "main");
    try expectObjStr(first, "author", "ginwa123");
    try expectObjBool(first, "is_draft", false);

    // MERGED is normalized, and `is_draft` survives the trip.
    const second = try itemAt(&doc, "changes", 1);
    try expectObjStr(second, "state", "merged");
    try expectObjBool(second, "is_draft", true);
}

// 6. An empty answer is a 200 with an empty array — the forge said there is
//    nothing, which is NOT the same fact as a failure (test 7).
test "list_empty_is_200_with_an_empty_array" {
    try harness.requirePabrikBin(io, gpa);

    var s = try Scratch.init();
    defer s.deinit();
    const repo = try buildRepo(&s, "pr-list-empty");
    defer gpa.free(repo);

    const bindir = try installFakeGh(&s, "bin-empty", GH_EMPTY_LIST_SCRIPT);
    defer gpa.free(bindir);

    var shadow = try PathShadow.install(gpa, bindir);
    defer shadow.restore();

    var h = try bootHarness();
    defer h.deinit(io) catch |err| std.debug.print("teardown: {s}\n", .{@errorName(err)});

    var r = try h.http(io, .GET, "/api/git/pr/list", .{
        .params = &.{.{ .name = "path", .value = repo }},
        .expect = &.{200},
    });
    defer r.deinit();
    var doc = try r.json();
    defer doc.deinit();

    if (try arrayLen(&doc, "changes") != 0) {
        std.debug.print("expected zero rows\n", .{});
        return error.TestUnexpectedResult;
    }
    if (doc.get("error") != null) {
        std.debug.print("an empty list must not carry an `error`\n", .{});
        return error.TestUnexpectedResult;
    }
}

// 7. A failed CLI is a 502 carrying its own sentence. If this ever renders
//    as an empty 200, the UI shows "no open pull requests" for a repo it
//    could not read at all.
test "list_gh_failure_is_502_with_the_cli_sentence" {
    try harness.requirePabrikBin(io, gpa);

    var s = try Scratch.init();
    defer s.deinit();
    const repo = try buildRepo(&s, "pr-list-fail");
    defer gpa.free(repo);

    const bindir = try installFakeGh(&s, "bin-fail", GH_AUTH_FAILURE_SCRIPT);
    defer gpa.free(bindir);

    var shadow = try PathShadow.install(gpa, bindir);
    defer shadow.restore();

    var h = try bootHarness();
    defer h.deinit(io) catch |err| std.debug.print("teardown: {s}\n", .{@errorName(err)});

    var r = try h.http(io, .GET, "/api/git/pr/list", .{
        .params = &.{.{ .name = "path", .value = repo }},
        .expect = &.{502},
    });
    defer r.deinit();
    var doc = try r.json();
    defer doc.deinit();

    // The remedy, not an apology: the user needs to see "gh auth login".
    try requireError(&doc, "gh auth login");
}

// ============================================================================
// POST /api/git/pr/close
// ============================================================================

// 8. No `pr` → 400 from the handler. An empty ref would make both CLIs close
//    whatever branch happens to be checked out.
test "close_missing_pr_is_400" {
    try harness.requirePabrikBin(io, gpa);

    var h = try bootHarness();
    defer h.deinit(io) catch |err| std.debug.print("teardown: {s}\n", .{@errorName(err)});

    var r = try h.http(io, .POST, "/api/git/pr/close", .{
        .json_body = "{\"path\":\"/tmp\"}",
        .expect = &.{400},
    });
    defer r.deinit();
    var doc = try r.json();
    defer doc.deinit();

    try requireError(&doc, "pr is required");
}

// 9. The happy path: the CLI closes it, the re-read confirms, the answer is
//    200 with `closed: true` AND the post-close status the PR tab's badge
//    renders.
test "close_returns_the_forge_answer" {
    try harness.requirePabrikBin(io, gpa);

    var s = try Scratch.init();
    defer s.deinit();
    const repo = try buildRepo(&s, "pr-close-ok");
    defer gpa.free(repo);

    const script =
        \\#!/bin/sh
        \\if [ "$2" = "close" ]; then
        \\  echo 'Closed pull request #893'
        \\  exit 0
        \\fi
        \\echo '
    ++ CLOSED_VIEW_JSON ++
        \\'
    ;
    const bindir = try installFakeGh(&s, "bin-close-ok", script);
    defer gpa.free(bindir);

    var shadow = try PathShadow.install(gpa, bindir);
    defer shadow.restore();

    var h = try bootHarness();
    defer h.deinit(io) catch |err| std.debug.print("teardown: {s}\n", .{@errorName(err)});

    const body = try closeBody(repo);
    defer gpa.free(body);
    var r = try h.http(io, .POST, "/api/git/pr/close", .{
        .json_body = body,
        .expect = &.{200},
    });
    defer r.deinit();
    var doc = try r.json();
    defer doc.deinit();

    try expectEqualBool(&doc, "closed", true);
    try expectEqualStr(&doc, "provider", "github");

    const status = try asObject(doc.value().*);
    const inner = try asObject(status.get("status") orelse {
        std.debug.print("response has no `status`\n", .{});
        return error.TestUnexpectedResult;
    });
    try expectObjStr(inner, "status", "closed");
    try expectObjStr(inner, "head_ref", "worktree/workspace-secrets-hardening-impl");
}

// 10. Exit 0 plus a re-read that still says OPEN is `closed: false` with a
//     sentence — never a success. This is the whole reason the endpoint
//     re-reads instead of trusting the exit code.
test "close_that_the_forge_still_reports_open_is_not_success" {
    try harness.requirePabrikBin(io, gpa);

    var s = try Scratch.init();
    defer s.deinit();
    const repo = try buildRepo(&s, "pr-close-noop");
    defer gpa.free(repo);

    const script =
        \\#!/bin/sh
        \\if [ "$2" = "close" ]; then
        \\  exit 0
        \\fi
        \\echo '
    ++ OPEN_VIEW_JSON ++
        \\'
    ;
    const bindir = try installFakeGh(&s, "bin-close-noop", script);
    defer gpa.free(bindir);

    var shadow = try PathShadow.install(gpa, bindir);
    defer shadow.restore();

    var h = try bootHarness();
    defer h.deinit(io) catch |err| std.debug.print("teardown: {s}\n", .{@errorName(err)});

    const body = try closeBody(repo);
    defer gpa.free(body);
    var r = try h.http(io, .POST, "/api/git/pr/close", .{
        .json_body = body,
        .expect = &.{200},
    });
    defer r.deinit();
    var doc = try r.json();
    defer doc.deinit();

    try expectEqualBool(&doc, "closed", false);
    // The sentence rides in `detail`: this is a 200, because the forge DID answer —
    // it simply did not do what was asked. An `error` field here would be claiming a
    // transport/command failure the forge never reported.
    try requireField(&doc, "detail", "still reports");
    if (doc.get("error") != null) {
        std.debug.print("closed:false must not carry an `error`\n", .{});
        return error.TestUnexpectedResult;
    }
}

// 11. A close the forge refuses is a 502 with the forge's sentence. It must
//     not be a 200 with `closed: false` ("the forge did nothing") — those are
//     different failures and the row renders them differently.
test "close_failure_is_502_with_the_forge_sentence" {
    try harness.requirePabrikBin(io, gpa);

    var s = try Scratch.init();
    defer s.deinit();
    const repo = try buildRepo(&s, "pr-close-403");
    defer gpa.free(repo);

    const bindir = try installFakeGh(&s, "bin-close-403",
        \\#!/bin/sh
        \\echo 'HTTP 403: Resource not accessible by integration' >&2
        \\exit 1
    );
    defer gpa.free(bindir);

    var shadow = try PathShadow.install(gpa, bindir);
    defer shadow.restore();

    var h = try bootHarness();
    defer h.deinit(io) catch |err| std.debug.print("teardown: {s}\n", .{@errorName(err)});

    const body = try closeBody(repo);
    defer gpa.free(body);
    var r = try h.http(io, .POST, "/api/git/pr/close", .{
        .json_body = body,
        .expect = &.{502},
    });
    defer r.deinit();
    var doc = try r.json();
    defer doc.deinit();

    try requireError(&doc, "403");
}

comptime {
    // Body-analysis barrier: an unreferenced helper is never type-checked, so
    // a stdlib rename inside one is invisible until a caller appears.
    _ = Scratch.init;
    _ = Scratch.deinit;
    _ = Scratch.path;
    _ = buildRepo;
    _ = git;
    _ = writeExecScript;
    _ = installFakeGh;
    _ = PathShadow.install;
    _ = PathShadow.restore;
    _ = asObject;
    _ = arrayLen;
    _ = itemAt;
    _ = expectEqualStr;
    _ = expectEqualBool;
    _ = expectObjStr;
    _ = expectObjBool;
    _ = requireError;
    _ = requireField;
    _ = bootHarness;
}
