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

The `--selftest` mode runs the scanner against eight fixtures — a clean
file, the banned idiom, a `switch` else, a bare `@panic`, a comment, a
`unreachableFoo` near-miss, and tab- and newline-separated splits. It
exists for the same reason `ci-change-filter.sh --selftest` does: a
scanner that has quietly stopped matching is a silent outage, and the
only way to notice is to check it against known input on every run.

---

## 2. Adding a new rule here

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
4. **Land it with zero debt.** Convert every existing violation in the
   same change. A rule that ships with a baseline allowlist is a rule
   nobody can tell is being followed, and the allowlist becomes a
   second, worse rule to maintain.
5. **Say what is not banned.** Every rule here has an explicit
   "what is NOT banned" section, because a rule whose edge cases are
   undocumented gets bypassed the first time someone hits one.
