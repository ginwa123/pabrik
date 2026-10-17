# Coding Standards

Rules that are enforced by a machine, not by memory. Each one names the
tool that checks it, so "is this a rule?" is a question with a
command-line answer.

`AGENTS.md` is the agent-facing companion — it covers how to explore,
test and commit. This file covers what the code itself must and must not
contain.

---

## 1. Never write `catch unreachable`

**Banned.** The lint is `scripts/lint-no-catch-unreachable.sh`, wired
into the `lint` job of `.github/workflows/ci.yml` and mirrored by
`.husky/pre-commit`. It scans every `.zig` file under `src/` and fails
the build on any hit. The same rule also runs as `zginlint`'s
`zginlint/no-catch-unreachable` (§4) over `src`, `tests`, `tools` and
`build.zig` — the wider of the two scopes, and how the 20 sites outside
`src/` were found and converted when that rule landed.

```zig
// WRONG — banned in every build mode.
const x = somethingFallible() catch unreachable;

// RIGHT — the sanctioned form.
const x = somethingFallible() catch @panic("somethingFallible failed");
```

### Why

`catch unreachable` is the only error-handling idiom in Zig whose
failure mode changes with the optimisation level, and it gets *worse*
as the build gets faster:

| Build mode | What `catch unreachable` does |
|---|---|
| Debug / ReleaseSafe | Panics with `reached unreachable code` — no file, no line, no error name, no clue which `catch` fired |
| ReleaseFast | **Undefined behaviour.** The compiler may assume the error branch is dead and delete the check entirely |

The Debug message is the reason `AGENTS.md` has a whole "Crash Triage —
Read the Reporter Before Theorising" section: `reached unreachable code`
has cost this repo real hours, because the panic tells you where the
unreachable *landed*, not which `catch` produced it.

The ReleaseFast row is worse and quieter. Once the check is deleted, the
failure surfaces somewhere else entirely — a wild write, a truncated
response, a hang — and the stack trace points at an innocent victim.
`ReleaseFast` also skips `recoverableOsBugDetected`, so the safety net
that catches a double-`close` in Debug is simply not there.

### The replacement

`catch @panic("...")` is a drop-in swap. `@panic` returns `noreturn`,
which coerces to the same result type `unreachable` did, so no call site,
no signature and no test changes. What you gain is a panic that fires in
**every** build mode and carries a message you wrote.

**Write the message as if the reader has only the message.** Name the
operation that failed, not the Zig concept:

```zig
// Useless — restates the language.
catch @panic("unreachable")

// Useless — the reader already knows it is OOM.
catch @panic("out of memory")

// Useful — says which buffer, and what was being formatted into it.
catch @panic("bufPrint failed formatting the request id")

// Useful — names the subsystem and the invariant that broke.
catch @panic("event_bus: mutex lock failed")
```

Rules for the message:

1. **Name the operation.** `bufPrint`, `dupe`, `lock`, `getSingleton` —
   whatever the left-hand side was doing.
2. **Name the subject** when there is one: which buffer, which path,
   which id.
3. **State the invariant** if the failure means one was violated:
   `"expected exactly one row"`.
4. **Keep it one line.** A panic message is not a log; if you need more
   than a sentence, the site probably wants real error handling instead
   of a panic.
5. **Never interpolate the error.** `catch @panic("{s}")` with
   `@errorName(err)` is tempting, but `catch |err|` is the construct that
   binds `err` — if you have the error, handle it or propagate it. A
   panic is for "this genuinely cannot happen".

### When a panic is the wrong answer

`catch @panic` is the sanctioned *replacement*, not a licence to panic
everywhere. If the failure is reachable — an allocation that can
genuinely fail under memory pressure, a file that can genuinely be
missing, a parse of untrusted input — propagate it with `try` or handle
it with `catch |err|`. The sites this lint converted were all
"provably cannot fail" cases (a `bufPrint` into a buffer sized for the
format, a `dupe` of a literal), which is exactly the population a panic
is for.

### What is NOT banned

- **`unreachable` as a `switch` prong or `else`.** That is the compiler
  proving exhaustiveness. It is correct and it stays.
  ```zig
  return switch (x) {
      0 => 1,
      else => unreachable,   // fine
  };
  ```
- **`@panic("...")` on its own.** That *is* the sanctioned form.
- **`catch @panic("...")`.** The sanctioned form.

Only the exact `catch unreachable` token pair is rejected.

### Comments count

The lint scans comments too. A commented-out `catch unreachable` is a
trap for the next person to uncomment it, and a comment that names the
idiom is an invitation to paste it. Reword the comment — say what the
code does, not what it must not do.

### Running it

```bash
scripts/lint-no-catch-unreachable.sh            # scan src/, exit 1 on any hit
scripts/lint-no-catch-unreachable.sh --selftest # verify the scanner itself
```

Requires `rg` (ripgrep) on PATH. If it is missing the script **fails** —
it does not skip and it does not report the tree clean. A lint that
cannot run must never answer "clean", because "clean" is the one answer
that lets a violation merge.

The `--selftest` mode runs the scanner against nine fixtures — a clean
file, the banned idiom, a `switch` else, a bare `@panic`, a comment, a
`unreachableFoo` near-miss, tab- and newline-separated splits, and a run
under a PATH with no `rg` that must fail rather than pass. It exists for
the same reason `ci-change-filter.sh --selftest` does: a scanner that has
quietly stopped matching is a silent outage, and the only way to notice
is to check it against known input on every run.

That last fixture is not decorative. The first version of this script
wrote `rg ... 2>/dev/null || true`, which turned `rg: command not found`
into "no matches" — so it reported the tree clean on a runner that ships
no ripgrep, and CI went green on a scan that had never run. The selftest
caught it on the first CI run. When you add a lint, assume the tool it
shells out to will one day be absent, and decide *then* what the answer
should be.

---

## 2. A test handles every platform, or it is not a test

**Banned.** A test that only asserts on the host it was written for. The
target is **zero skipped tests on every platform** — the same tests, the
same assertions, on Linux, macOS and Windows. The checker is
`scripts/check-zig-test-skips.sh`, wired into
the `Skipped-test ceiling (zig build test)` step of
`.github/workflows/ci-backend.yml` — so it runs on all three
`backend (<platform>) / build` cells — and re-run every night on Windows
by `.github/workflows/ci-windows-nightly.yml`.

```zig
// WRONG — 94 tests did this on Windows, and nothing said so.
test "..." {
    if (builtin.os.tag == .windows) return error.SkipZigTest;
    ...
}

// ALSO WRONG — the same thing with the evidence removed: the runner
// counts this as a PASS, so the test reports green while asserting
// nothing at all on the platform it declined to check.
test "..." {
    if (builtin.os.tag == .windows) return;
    ...
}

// STILL WRONG — a test that is about one platform. It looks thorough and
// it is the same defect: on the hosts it does not name, this test
// asserted nothing, and its name says so.
test "buildOpenArgv returns a two-word opener plus url on unix" {
    if (comptime builtin.os.tag == .windows) return error.SkipZigTest;
    ...
}
```

The fix for all three is one test that covers every host — a table over
the platforms the code switches on, with an unknown host FAILING rather
than passing vacuously (see `src/apps/desktop_app/browser.zig`, whose
Windows argv is three words and whose unix argv is two, and which now
asserts both from one test body with no branch that declines):

```zig
test "buildOpenArgv: this host's opener words, then the url" {
    var opener_words: []const []const u8 = &.{};
    switch (builtin.os.tag) {
        .windows => opener_words = &.{ "rundll32", "url.dll,FileProtocolHandler" },
        .macos => opener_words = &.{"open"},
        .linux => opener_words = &.{"xdg-open"},
        else => {}, // leaves it empty -> the length assert below FAILS
    }
    var buf: [3][]const u8 = undefined;
    const argv = buildOpenArgv(url, &buf);
    try testing.expectEqual(opener_words.len + 1, argv.len);
    for (opener_words, 0..) |word, i| try testing.expectEqualStrings(word, argv[i]);
    try testing.expectEqualStrings(url, argv[argv.len - 1]);
}
```

### Why

Zig has exactly one way for a test to decline to run:
`return error.SkipZigTest;`. The runner counts it, prints no failure, and
`zig build test --summary all` ends with

```
Build Summary: 14/14 steps succeeded; 4163/4257 tests passed (94 skipped)
```

Measured on one *green* run (2026-10-13, run 38428191906):

| cell | result | skipped |
|---|---|---|
| `backend (Linux X64)` | 4247/4257 passed | **10** |
| `backend (macOS ARM64)` | 4229/4244 passed | **15** |
| `backend (Windows X64)` | 4163/4257 passed | **94** |

**Update, 2026-10-16 — Windows is at ZERO.** The ceiling went 91 → 50 → 0 in
a single day as the families above were converted one at a time: the
`/bin/sh` fixtures to `helpers.host_fixture`, the symlink sites to a
directory junction (no privilege needed), the `/proc`-only counters to
`helpers.open_descriptors` (open fds on Linux, open handles on Windows), the
PTY session tests to bookkeeping with `error.UnsupportedPlatform` asserted
where Windows genuinely has no PTY, and the six `Agent.callStreaming` tests
to a `std.Io.net` fixture. Linux dropped 10 → 4 and macOS 15 → 4 in the same
change, since those converted tests now run there too; the ceiling for a
platform at zero is a literal `0`.

Windows skipped nine times what Linux did, on a green pipeline, with 81
test bodies under `src/` able to bail out on Windows — 61 through a
`skipOnWindows()` helper, 17 behind a direct `.windows` gate, 3 that need
a symlink privilege. The overwhelming majority spawn a fixture that is a
`/bin/sh` script, so the Windows runner could never execute them; every
Windows-only regression in child-process spawn/capture and in the
git/PR handlers shipped with no test behind it. The `return;` form is
worse still, because it does not even show up in that `(94 skipped)`
count.

The failure mode is the point: **a skip does not fail anything.** A
component that is untested on a platform looks exactly like a component
that is well tested on it, and the only place the difference appears is a
parenthesised number nobody diffs.

### The rule

**Target: zero on every platform.** Until it is reached, the skipped
count is a metric with a per-platform ceiling, and the ceiling may only
fall (see "Why a ceiling exists at all" below for the date on it):

| count vs ceiling | verdict |
|---|---|
| `count > ceiling` | **FAIL** — a platform silently lost coverage |
| `count < ceiling` | PASS, with a notice naming the exact value to re-pin |
| no `N/M tests passed` line | **FAIL** — "could not measure" must never read as "no skips" |

The ceilings live in `baseline_for()` in
`scripts/check-zig-test-skips.sh` and are lowered by editing that
function, so every change to them is in a diff a reviewer sees.
`--strict` (fail on any skip at all) is the end state and is available
today.

### What is NOT banned

- **`error.SkipZigTest` as a construct.** It is the right primitive for a
  test whose subject genuinely does not exist on this host. What is
  banned is a skip that nobody notices, which is why it is a counted,
  ceilinged number rather than a forbidden token.
- **A local run.** The checker runs where the count is meaningful: the
  three backend cells and the nightly Windows job. Nothing about
  `zig build test` on a dev box changes.
- **`.husky/pre-commit`.** §3 asks a new rule to be mirrored there, and
  this one deliberately is not: the hook mirrors the `lint` job, whose
  work is a scan of the tree, while this rule's input is a full
  `zig build test` run. `--selftest` is the part worth running on every
  commit, and it is cheap.
- **A host table inside one test.** Naming each platform the code under
  test switches on — and failing on one nobody handled — is not a
  platform-specific test; it is the general form. What is banned is a
  body that *declines work* for a host (`return`, `return
  error.SkipZigTest`, or an `if/else` that asserts only on one side).
- **Production code that switches on the platform.** The rule is about
  the test asserting for every platform, not about removing
  platform-dependent *behaviour* from the code. If behaviour is
  genuinely host-specific, the test's job is to cover every host, not to
  pick one.

### Running it

```bash
scripts/check-zig-test-skips.sh --selftest          # verify the parser/verdict
scripts/check-zig-test-skips.sh --baselines         # print the ceilings
scripts/check-zig-test-skips.sh --run               # run the suite and check it
scripts/check-zig-test-skips.sh --summary build.log --platform windows
zig build test --summary all | tee build.log        # what CI feeds it
```

The `--selftest` mode runs the parser and the verdict against fixtures —
the real aggregate line, the paren-less zero-skip form, a log with
several `Build Summary:` lines, a log with none (must report
unmeasurable, not clean), a missing file, the ceiling boundary, and
`--strict` — for the same reason
`lint-no-catch-unreachable.sh --selftest` exists: a parser that has
quietly stopped matching is a silent outage, and the only way to notice
is to run it against known input on every invocation.

### Why a ceiling exists at all — and when it goes away

**Zero on every platform is the requirement. The ceiling is a dated
stopgap, not the rule's final form**, and this is the deliberate
exception to §3's "land it with zero debt".

The debt is 50 Windows skips. Their fix is not a per-platform test — it
is a fixture that runs everywhere, which for this repo means no test may
depend on `/bin/sh` being present. That conversion cannot be verified
from POSIX (a Windows payload is only known-good when Windows has run
it), so a flat zero shipped today would be either a permanently red
Windows cell or deleted tests. The ceiling exists so the number is
printed on every cell and every night, cannot grow, and names the edit
that lowers it.

### How the `/bin/sh` dependency was actually removed

Zig 0.16's Windows spawn path
(`std.Io.Threaded.windowsCreateProcessPathExt`) already handles batch
files: when the program name ends in `.cmd` or `.bat` it calls
`CreateProcessW` with `lpApplicationName = <system32>\cmd.exe` and
`lpCommandLine = cmd.exe /d /e:ON /v:OFF /c "<script>" <escaped args>`.
So a `.cmd` file IS spawnable from `std.process.spawn` on Windows — the
missing piece was only a helper that writes the right payload per host.

That helper is `src/helpers/host_fixture.zig`. `Fixture.writeProgram`
takes a `Payload` (stdout, stderr, exit code, an argv-recording file, a
sentinel to touch, print-cwd, sleep, kill-self, repeat-N) and renders a
`#!/bin/sh` script on POSIX or a `.cmd` batch file on Windows. Both
dialects are written in lockstep, so a new `Payload` field cannot be
honoured on one host and silently ignored on the other — and the module's
own tests run on every host, because a fixture helper that declines a
host is the same defect one level up.

Two consequences worth knowing before adding a fixture:

- **The recorded argv has a different shape per host.** POSIX records one
  argument per line; `cmd.exe` receives the arguments as one command-line
  string, so `echo %*` records them space-separated. Assert through
  `host_fixture.recordedArgvContains` / `recordedArgvContainsSequence`,
  which match whole arguments in whichever shape this host produced. A
  substring match is a trap: `--head` must not be satisfied by
  `--head-ref`, and the create suite asserts that flag is ABSENT.
- **`printf '%s'` cannot carry a NUL.** The POSIX renderer emits payloads
  with `printf '%b'` and octal-escapes every non-printable byte, so the
  "non-UTF8 bytes survive capture" test still proves the pipe is
  byte-transparent.

The conversion, in one line per family:

| family | tests | state |
|---|---|---|
| `git_pr_status` | 25 | converted — `host_fixture` payloads |
| `run_captured` | 16 | converted — `host_fixture` payloads |
| `git_pr_list` / `create` / `close`, `status_pull_request` | 18 | converted — `host_fixture` payloads |
| `mcp_stdio` | 6 | still open — needs an NDJSON speaker fixture |
| symlink / `/proc` / `setenv` sites | 6 | still open — a host-general helper (handle count, env set, link-or-fail-loudly) |
| the ~84 `return;` vacuous passes | 0 counted | still open — convert to a real assertion, never to a skip |

The 59 converted tests are why the ceiling could fall from 91 to 50 in
one change. The remaining 50 are the families whose Windows payload has
not yet been run on Windows, which is exactly what the nightly job is
for.

`--strict` is the finish line and is already wired and tested; flipping
the step to it is a one-word change once the table above is empty.

---

## 3. Adding a new rule here

A rule belongs in this file when a machine can check it and a human
should not have to remember it. Before adding one:

1. **Prefer the compiler.** If Zig can reject it, it does not need a
   lint.
2. **Prefer a real test.** If the rule is about behaviour, assert the
   behaviour — see "Tests — Assert Behaviour, Never Source Text" in
   `AGENTS.md`. A `test` block that greps a `.zig` file's source text is
   not a test and is not acceptable here.
3. **A whole-repo textual rule is a lint.** Put it in `scripts/`, give it
   a `--selftest`, wire it into the `lint` job of
   `.github/workflows/ci.yml`, and mirror it in `.husky/pre-commit`.
   `scripts/ci-change-filter.sh` is the template. A rule that needs to
   understand Zig rather than match a line of it belongs in `zginlint`
   instead (§4), which is a real linter with its own job.
4. **Fail closed.** If the lint shells out to a tool, check the tool is
   there and fail when it is not. Never let "I could not check" degrade
   into "nothing to report" — that is the one failure mode that ships a
   violation, and it is invisible in the green check.
5. **Land it with zero debt.** Convert every existing violation in the
   same change. A rule that ships with a baseline allowlist is a rule
   nobody can tell is being followed, and the allowlist becomes a
   second, worse rule to maintain.
6. **Say what is not banned.** Every rule here has an explicit
   "what is NOT banned" section, because a rule whose edge cases are
   undocumented gets bypassed the first time someone hits one.

---

## 4. A comment block is at most three lines

**Capped.** The rule is `zginlint/max-comment-lines`, implemented in
github.com/ginwa123/zglint and pinned by URL + hash in `build.zig.zon`. It
is run by `zig build zginlint:check`, wired into the `zginlint` job of
`.github/workflows/ci.yml` and mirrored by `.husky/pre-commit`. The tree is
at zero findings, so the gate asks for zero — there is no baseline and no
suppression.

```zig
// WRONG — one block, four lines.
// The runner reads its own shard of the queue, retries a failed delivery
// twice, then parks the message in the dead-letter table.
// Talk to the platform team before changing the retry count.

// RIGHT — three lines. The extra sentences belong in the commit message,
// the PR body or `docs/`, where they are read once and do not sit in the
// middle of the function they describe.
```

### The rule

- A **comment line** carries comment content and no code byte, so a blank
  line or a line with code on it ends the block.
- A **comment block** is a run of consecutive comment lines. Three lines
  pass, four fail, and the finding is reported at the block's first line.
- The ceiling is a CLI option: `--max-comment-lines N`.
- `///` doc comments and `//!` container docs are comments like any other.
  There is no doc-string exemption.

### What is NOT banned

- **Comments.** The rule is about length, not existence. A three-line
  comment explaining a non-obvious invariant is what it is trying to
  produce.
- **A trailing comment after code.** `const x = 1; // note` is not a block
  and never counts towards one.
- **Comment markers inside a literal.** `"// not a comment"` and a
  multi-line string fenced with `\\` are text; the lexer knows the
  difference and is unit-tested on it.
- **`/* ... */` in any shape.** A block comment counts by the lines it
  spans, nested or not: a 10-line one is a finding, a 2-line one is not.
- **Prose everywhere else.** Docs, commit messages, PR bodies, issue text
  and YAML comments are not Zig and are not scanned. Three lines is a
  ceiling on code comments, not on writing.

### Why

A comment block is a paragraph, and a paragraph in the middle of a
function grows until the code is off the screen. ESLint's `max-len` makes
the same bet one level down: a number small enough that nobody argues with
it, enforced by a machine, so that "this comment is too long" stops being
a review comment. Three lines is enough for the *why* — which operation
this is guarding, which invariant it is relying on — and not enough to
smuggle a design document into a function body. The design document goes
where it can be found: `docs/`, the commit message, the module README.

### Zero, not a ceiling

**The ceiling is gone.** The rule shipped with a per-file baseline
(`zginlint-baseline.json`) because the tree carried 6,532 findings in 727
files and converting them in the same change would have buried the rule
itself. That conversion has now happened, so the ratchet is deleted: there
is no pin file, no `--baseline` flag, no `zig build zginlint:pin`, and no
per-file allowance. A finding is a finding.

| | |
|---|---|
| any finding | **FAIL** |
| a clean tree | PASS |

This is §3's rule 5 applied to itself: *"a rule that ships with a baseline
allowlist is a rule nobody can tell is being followed, and the allowlist
becomes a second, worse rule to maintain."* The baseline was the second
rule. It is gone.

**What the conversion did.** Every over-long block was re-wrapped to at
most three lines, cut at a sentence boundary so no sentence is left
half-written. Where a block held more than three lines of prose, the
overflow was deleted rather than relocated — 1.8 MB of it, spread over
6,113 blocks. Relocating it would have meant 33 machine-written
`README.md` files, three of them clobbering hand-written ones, in a diff
nobody could review; that is the same failure the baseline was avoiding,
one level down. The three lines that remain carry the load-bearing *why*.
The rest was the design document §4 says does not belong in a function
body.

**How it was checked.** The conversion touched comment lines only, and that
is not a claim — it was verified. For all 727 files: zero findings remain,
`zig ast-check` is clean, and the sequence of code-bearing lines is
byte-identical to the pre-conversion tree. A comment-only refactor cannot
change behaviour, and the diff proves it did not.

### Running it

```bash
zig build zginlint:check   # the gate: fail on any finding
zig build zginlint         # install zig-out/bin/zginlint from the pin
zig-out/bin/zginlint --help
```

Exit codes: `0` clean, `1` findings, `2` a usage or I/O error. The
linter's README (github.com/ginwa123/zglint) covers the lexer's contract,
the CLI and how to add a rule, and its own unit tests are part of that
repo's CI — not `zig build test` here, because a consumer build never runs
a dependency's test blocks.

---

## 5. The same ceiling, in Vue and TypeScript

**Capped.** §4's rule is not a Zig rule, it is a rule about comments, and
the desktop app is where most of this repo's comments now live. The Vue/TS
half is `local/max-comment-lines`, implemented in
`src/apps/desktop/eslint-rules/maxCommentLines.ts` and run by
`pnpm run lint:check` (`oxlint . && eslint . --cache`), which is the gate
`.github/workflows/ci.yml`'s `lint` job runs and `.husky/pre-commit`
mirrors.

```ts
// WRONG — one block, four lines.
// The runner reads its own shard of the queue, retries a failed delivery
// twice, then parks the message in the dead-letter table.
// Talk to the platform team before changing the retry count.

// RIGHT — three lines. The extra sentences belong in the commit message,
// the PR body or `docs/`, where they are read once and do not sit in the
// middle of the function they describe.
```

### The rule

Identical to §4's, because it is the same rule:

- A **comment line** carries comment content and no code byte, so a blank
  line or a line with code on it ends the block.
- A **comment block** is a run of consecutive comment lines. Three lines
  pass, four fail, and the finding is reported at the block's first line.
- A `/* ... */` comment counts by the lines it spans, nested or not.
- `/** ... */` JSDoc counts like any other comment. There is no doc-string
  exemption — the frontend's API docs are the bulk of the baselined debt.

### What is NOT banned

- **Comments.** The rule is about length, not existence.
- **A trailing comment after code.** `const x = 1 // note` has a code byte
  on its line, so it is not a comment line and never joins a block.
- **Comment markers inside a literal.** `"// not a comment"` and a
  template literal holding `/*` are text. ESLint's lexer already knows the
  difference, so the rule inherits it rather than reimplementing a scanner.
- **HTML comments in `<template>`.** Out of scope, and this is a gap
  rather than a decision: 464 of the 1,107 in this repo are multi-line,
  and they are overwhelmingly prose explaining a branch of the view chain
  (`<!-- Kanban view (plan: …). The kanban now owns the chat pane … -->`).
  `vue-eslint-parser` exposes them as `HTMLComment` nodes, so they ARE
  reachable — capping them means rewriting 153 files of template prose,
  which is the unreviewable whole-repo diff §4 avoided with a baseline.
- **CSS comments in `<style>`.** Out of scope for a harder reason:
  `vue-eslint-parser` does not parse the style block at all, so there is
  no AST to read and no honest way to count them. 102 exist, 72 of them
  multi-line.

Both gaps are named here so the next person does not have to rediscover
them, and so nobody mistakes "not scanned" for "not a problem".

### Why ESLint and not a second linter

The frontend already has a per-file count ratchet — `eslint
--suppress-rule` plus `eslint-suppressions.json` — and it is the mechanism
`local/no-try-catch` and `local/no-watch` already ride. A second, parallel
baseline format for the same job would be a second thing to maintain and a
second thing to get wrong, so this rule plugs into the existing one.

### Why a ceiling exists at all — and when it goes away

**Zero is the requirement for new code. The ceiling is a dated stopgap for
the code that is already here**, and it is the third deliberate exception
to §3's "land it with zero debt".

Measured 2026-10-15 over `src/`: **3,822 findings in 733 files**, with
`src/api/index.ts` at 289 blocks and
`src/components/views/ChatView.vue` at 205. The rule's own files are at
**zero** — `eslint-rules/maxCommentLines.ts`, `eslint.config.ts` and
`src/__tests__/maxCommentLines.spec.ts` are deliberately absent from the
baseline, so a block over three lines in one of them fails the gate
immediately.

Why not convert them in this change: the conversion is 733 files and it is
not mechanical. Each block has to be shortened, moved into a `///` doc
comment, or deleted after establishing that nothing depends on it. So the
ceiling follows §2's and §4's shape:

| | |
|---|---|
| a file over its pinned count | **FAIL** |
| a file with findings that is not pinned | **FAIL** (a new file cannot sneak in) |
| a count below its pin | FAIL, naming the value to re-pin |

`eslint-suppressions.json` is the pin, regenerated by
`pnpm run lint:banned-baseline` — **only after fixing debt, never to
silence a new violation**. The count may only fall, and the way it falls
is that you re-pin after the fix lands.

### Running it

```bash
cd src/apps/desktop
pnpm run lint:check            # the gate: oxlint + eslint, suppressions applied
pnpm run lint:banned-baseline  # re-pin the baseline to today's counts
pnpm run test                  # the rule's own behaviour tests
```

`src/__tests__/maxCommentLines.spec.ts` pins both directions — that the
rule fires on a four-line block and stays silent on a three-line one, on a
trailing comment, on a marker inside a string literal, and on the two
documented gaps above. A rule that silently stops matching is worse than
no rule, so those cases are the spec's real subject.

`src/apps/desktop/docs/comment-length-policy.md` is the working companion:
how to fix a finding (shorten, split, move, delete), what stays legal, and
why there is no inline exemption.
