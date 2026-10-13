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
the build on any hit.

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

## 2. A test may not be skipped silently

**Banned.** The checker is `scripts/check-zig-test-skips.sh`, wired into
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

The skipped count is a metric with a per-platform ceiling, and the ceiling
may only fall:

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
- **Platform-specific *assertions*.** `if (comptime builtin.os.tag ==
  .windows) { try expectEqual(3, argv.len); } else { ... }` is the
  preferred shape — it asserts the host's real behaviour instead of
  declining to look at it.

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

### Why a ceiling and not zero

Zero is the goal, and this is the deliberate exception to §3's
"land it with zero debt". The debt here is 94 Windows skips whose fix is
a `/bin/sh` fixture payload per test, and a payload that is only correct
on POSIX cannot be verified on POSIX — the conversion needs a real
Windows run per test. Shipping the rule as a hard zero would therefore
mean either a permanently red Windows cell or deleting the tests, and
both are worse than a number that is printed on every run, cannot grow,
and names the exact edit that lowers it in the notice beside it. The
nightly Windows job is what makes the conversion iterable; each landed
payload lowers the ceiling in the same change that lands it.

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
   `scripts/ci-change-filter.sh` is the template.
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
