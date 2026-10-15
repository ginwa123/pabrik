# Plan — make `zig build test` emit a JSON report

- **Task**: `task_1792083205255_2` — "Make zig build test return a output in json file, it is possible?"
- **Worktree**: `~/.config/pabrik/.worktrees/make-zig-build-test-return-a-output-in-json-file-1792083176387`
- **Branch**: `worktree/make-zig-build-test-return-a-output-in-json-file-1792083176387` (base `origin/main`)
- **Status**: **Rev 1 — PLAN ONLY, no code. Awaiting review.** §8 has 4 open decisions for the human.

---

## 1. The answer, in one paragraph

**Yes — but not by flipping a flag.** Zig 0.16 has **no** JSON/JUnit test output and no
`--json` anywhere in `zig build`; that is verified, not assumed (§3). What Zig *does*
expose is a **custom test runner** hook — `TestOptions.test_runner`, a public build-system
API — so `zig build test` can be made to write a JSON file by adding a runner that records
each test's result. Two shapes are possible: a **~120-line "simple" runner** (proven end-to-end in a spike, §6.1) or a
**faithful copy of the std runner in "server" mode** that keeps today's live progress UX and
per-step counts byte-for-byte. The simple one is a smaller diff, but the measurement (§4.2,
§6.2) shows it costs the `P/T tests passed` sentence in `Build Summary:` — which is the *only*
input of the CI skip gate — and loses live progress; the server one is ~300 lines of forked
compiler code. §5 recommends the server one, §7 splits the work into 3 PRs, and §8 asks the 4
questions that decide the shape.

---

## 2. What exists today (verified against this tree)

### 2.1 `zig build test` is one step over ~11 test binaries

`const test_step = b.step("test", "Run tests")` — `build.zig:2398`.

| suite | `b.addTest` site | notes |
|---|---|---|
| `mod_tests` — the 4.4k-test suite | `build.zig:2430` | **sharded**: `-Dtest-shards` (default `min(8, cpus/2)`); `collectTestShardEntries` + `balanceTestShards` scan **4632** test names and hand each shard a `filters` list; one `b.addRunArtifact` + `prependVcpkgBinToPath` per shard; a `test:shard:<i>` step each |
| `mod_tests`, unsharded | `build.zig:2452` | used when `-Dtest-shards=1` or no names were scanned — one unfiltered binary (legacy path) |
| `test:desktop-app` | `build.zig:2164` | separate app tree |
| `test:cli` | `build.zig:2256` | |
| `test:tui` | `build.zig:2311` | |
| `test:helpers:run_captured` | `build.zig:2461` | |
| `test:helpers:test_path` | `build.zig:2475` | |
| `test:helpers:ansi` | `build.zig:2491` | |
| `test:helpers:git_env_guard` | `build.zig:2504` | |
| `test:zginlint` | `build.zig:2533` | |
| `test:ai_workflow:tui` | `build.zig:2564` | |
| `functional-test:zig` | `build.zig:2922` | `tests/functional/build.zig` — its own build file |

The Python suites (`functional-test`, `functional-test-ui`, `functional-test-all`) are pytest
(`pytest.ini`, `tests/conftest.py`) and are **out of scope here** — pytest can already emit
JUnit XML/JSON by itself, which is the natural second half of a unified report (§9).

### 2.2 Today the machine-readable form of a test run is *scraped human text*

- `scripts/check-zig-test-skips.sh` (423 lines) has exactly one input: the line
  `Build Summary: N/N steps succeeded; P/T tests passed (K skipped)`, sed-scraped at
  `scripts/check-zig-test-skips.sh:136-141`. Its own header states the consequence: it can
  count skips but **cannot name which tests skipped**, which is why per-platform ceilings are
  pinned by hand (linux 10 / macos 15 / windows 91) instead of a strict zero.
- CI does the same: `.github/workflows/ci-backend.yml:894`
  `zig build test --summary all -Dno-webapp-rebuild 2>&1 | tee "$RUNNER_TEMP/zig-test/summary.log"`,
  and the next step feeds that log to the script.

So CI already converts human text into machine decisions with regexes. **That is the gap this
task closes**: give the same run a JSON file, and both consumers read a file instead of a
sentence. A second, independent win: `--summary all` only ever reports **per-step** counts
(`build_runner.zig:1027-1038` prints `N pass (N total)`), never per-test names — so
"which test failed / skipped where" is not available in any structured form today at all.

---

## 3. Why Zig cannot do this natively (verified, not assumed)

| claim | how it was checked | result |
|---|---|---|
| No JUnit support in the toolchain | `rg -i junit /usr/lib/zig` + `strings -n5 /usr/bin/zig \| rg -i junit` | **zero hits** |
| No JSON test output flag | `zig build --help` (full options list) + `zig test --help` | only `--summary [all\|new\|failures\|line\|none]`, which is **text** |
| The default runner emits no structured file | `/usr/lib/zig/compiler/test_runner.zig` (607 lines, read in full) | writes human lines to stderr; structured results only over the `--listen=-` IPC socket |
| A custom runner *is* supported | `std/Build.zig:863` `TestOptions.test_runner`, `std/Build/Step/Compile.zig:372-378` `TestRunner{path, mode}`, `Compile.zig:1378-1381` emits `--test-runner <path>` | **public API, works** |

Conclusion: the JSON has to be produced by **our** code, inside the test-runner process
(which is the only place that knows per-test outcomes and can still write a file when tests
fail).

---

## 4. The mechanism, precisely

### 4.1 The two runner modes (this is the whole design space)

`b.addTest(.{ .root_module = ..., .test_runner = .{ .path = b.path("tools/x.zig"), .mode = … } })`

- **`mode = .server`** — `addRunArtifact` then calls `enableTestRunnerMode()`
  (`std/Build/Step/Run.zig:239-247`), which appends `--cache-dir=`, `--seed=0x…`,
  `--listen=-` and sets `stdio = .zig_test`. The runner must speak the `std.zig.Server`
  binary protocol: it answers `query_test_metadata` with `serveTestMetadata`, and each
  `run_test` with `serveStringMessage(.test_started)` + `serveTestResults(…)`. This is what
  the stock runner does, and it is what gives today's live progress bar and the per-step
  `N pass (N total)` summary line.
- **`mode = .simple`** — no `--listen=-`; the binary is run plainly and the build relies on
  its **exit code** (`std/Build.zig:982-985`). A runner can be ~120 lines: iterate
  `builtin.test_functions`, call `fn.func()`, record, write JSON, `exit(1)` if anything failed.
  Unknown argv entries are simply ignored, so the runner owns its own flags.

### 4.2 The four gotchas that decide the shape (all measured, §6.2)

1. **`.simple` + `addRunArtifact` runs the shards SERIALLY.** `run.stdio` stays
   `.infer_from_args`, and `Run.hasSideEffects()` (`Run.zig:~705-714`) is `true` for that
   case (no output args) — measured 3 CPU-bound shards: **4.21s serial** vs **1.91s parallel**
   once `run.expectExitCode(0)` is called (which flips `stdio` to `.check` via
   `Run.addCheck`, `Run.zig:645-648`). The 8-way sharding is the reason `zig build test` is
   bearable; losing it is not an option, so **`expectExitCode(0)` is mandatory** in any
   `.simple` design.
2. **A piped-stderr step gets its output re-printed as a per-step report, "no matter the
   result"** (`build_runner.zig:1381-1388`: *"No matter the result, we want to display
   error/warning messages"* — the condition is only `result_stderr.len > 0`). Since
   `result_failed_command` is set for every spawned step, the block ends in a **`failed
   command: …` line even when the step succeeded and the build exits 0**. This is
   **pre-existing, not something this plan introduces**: it already happens on `main`
   (pabrik's own notes record it on a run that finished
   `26/26 steps succeeded; 4334/4344 tests passed (10 skipped)`, exit 0 — the trigger there
   is a shard's `(warn)` output). Measured here: the default runner prints **no** such block
   when a shard is silent, and `.check` prints one as soon as the runner writes its per-test
   lines to stderr. The authoritative verdict is always `Build Summary:` + the exit code.
3. **`.check` loses the per-step test counts, and that breaks a CI consumer.** In `.check`
   mode the build runner never learns test outcomes, so `--summary all` prints only
   `Build Summary: 7/7 steps succeeded` — measured — whereas `.zig_test` prints
   `Build Summary: 7/7 steps succeeded; 3/3 tests passed` plus `1 pass (1 total)` per step.
   The `P/T tests passed (K skipped)` sentence is the **sole input** of
   `scripts/check-zig-test-skips.sh` and of the CI skip-ceiling step (§2.2), so a `.simple`
   runner would silently break both until PR 3 rewires them.
4. **`.server` mode must NOT call `run.expectExitCode(0)`** — `enableTestRunnerMode` already
   set `stdio = .zig_test`, and `addCheck` panics on any other union member:
   *"illegal call to addCheck: conflicting helper method calls. Suggest to directly set stdio
   field of Run instead"* (`Run.zig:650`, reproduced). `expectExitCode(0)` is legal **only**
   for the `.simple` case.

Points 1 and 3 are why §5 recommends `.mode = .server`; point 2 is pre-existing and is
neither caused nor worsened by it.

### 4.3 Caching interacts with the output file

`.check` and `.zig_test` steps are both cacheable (`hasSideEffects == false`). Measured: a
second `zig build test` with no source change is a **cache hit in 0.055s and does not
re-run the binaries** — so a JSON file written as a side channel is *not* regenerated, even
if it was deleted. Either declare the report as a real step output
(`run.addOutputFileArg("test-results.json")` + install) or accept staleness; §5.3 picks the
first.

---

## 5. Recommended design (Option A)

### 5.1 One runner, forked from the compiler's, in `.server` mode

New file `tools/test_runner_json.zig` — the stock runner
(`/usr/lib/zig/compiler/test_runner.zig`, 607 lines) with the fuzz branch dropped
(`-300` lines) and three additions:

1. `--json-out=<path>` (also honoured via `PABRIK_TEST_JSON_OUT`) — where to write; absent ⇒
   behave exactly like the stock runner and write nothing.
2. In the `run_test` handler, accumulate one record per test: index, name (from
   `query_test_metadata`), status (`pass` / `skip` / `fail`), error name, `leaked`, and
   duration measured around `test_fn.func()`.
3. On the `.exit` message, write the JSON **before** `std.process.exit(0)` — so the report
   exists on a red run too. `serveTestResults` is sent first, so `zig build`'s exit status and
   `--summary all` behaviour are unchanged.

Why fork instead of a 120-line runner: the protocol is the only thing that keeps the live
progress bar, keeps `--summary all`'s per-step test counts (which
`check-zig-test-skips.sh` scrapes today, §4.2.3), keeps the shards parallel, and avoids the
`failed command:` blocks of §4.2.2. The cost is honest: ~300 lines of code that track a
compiler internal (`std.zig.Server`), which §7 guards with a test.

Two rules that come with `.server` mode (both measured, §6.2):
`run.expectExitCode(0)` must **not** be called (it panics — `stdio` is already `.zig_test`),
and the report file must be declared as a real output (`run.addOutputFileArg`) or a cache hit
leaves it stale (§4.3).

### 5.2 `build.zig` — a tiny helper, then one line per suite

```zig
fn jsonTestRunner(b: *std.Build) ?std.Build.Step.Compile.TestRunner {
    if (!(b.option(bool, "test-json", "write a JSON test report (default: true)") orelse true))
        return null;                       // -Dtest-json=false ⇒ stock runner, zero risk path
    return .{ .path = b.path("tools/test_runner_json.zig"), .mode = .server };
}
```

then `.test_runner = jsonTestRunner(b)` at each of the ~11 `b.addTest` sites, and

```zig
const report = run_shard.addOutputFileArg(b.fmt("test-{s}.json", .{shard_label}));
```

so the file is a declared, cache-coherent output. Suites that are *not* the 8 shards each get
their own file; a shard that is a cache hit keeps the file Zig already has.

### 5.3 Aggregation — one file, stable path

A final `test:json` step (a small `tools/test_report_merge.zig`, wired like the existing
`tools/*.zig` helpers) depends on every report and merges them into
`zig-out/test-results.json`, and `zig build test` depends on it. Merging is trivial (concatenate
`tests[]`, sum `totals`) and it means consumers never glob a cache directory.

### 5.4 Schema (v1, additive-only)

```json
{
  "schema": "pabrik.test-report.v1",
  "generated": "2026-10-15T17:05:27Z",
  "zig": "0.16.0",
  "host": "x86_64-linux",
  "suites": [
    { "name": "mod_tests", "shard": 0, "shards": 8,
      "totals": { "total": 662, "passed": 660, "skipped": 2, "failed": 0, "leaked": 0 },
      "tests": [
        { "name": "src.apps.kanban.kanban_move_task", "status": "pass", "duration_ns": 412233 },
        { "name": "src.helpers.ansi.strip", "status": "skip", "error": null, "duration_ns": 8120 },
        { "name": "src.tools.command.spawn", "status": "fail", "error": "TestExpectedEqual",
          "duration_ns": 991002, "leaked": false }
      ] }
  ],
  "totals": { "total": 4362, "passed": 4352, "skipped": 10, "failed": 0 }
}
```

Rules that make it a *report* rather than a log dump: `tests[]` is per-test (the thing no
current output has), `status` is a closed enum, `error` is `null` or an error name, and
unknown fields are ignored by consumers.

### 5.5 Who consumes it

1. `scripts/check-zig-test-skips.sh` — replace the sed on `Build Summary:` with a read of
   `totals.skipped`, and, new, print **the names** of the skipped tests (the script's own
   header says that is the missing capability). Same ceilings, same verdicts, no regex.
2. `.github/workflows/ci-backend.yml` — upload `zig-out/test-results.json` as an artifact
   next to the `summary.log` it already keeps, so a reviewer sees failures by name.
3. Optional (own PR, §9): a `--junit` emitter beside the JSON, for the three platforms'
   job summaries.

---

## 6. Evidence — what was actually run

Spikes live outside the repo (`/tmp/zigjson_spike`, `/tmp/zigjson_par`) so the worktree stays
clean. Nothing here touched port 8081.

### 6.1 A `.simple` runner does produce JSON from `zig build test` (PASS)

3 tests (one pass, one fail, one `error.SkipZigTest`), ~120-line runner, `zig build test`:

```
1/3 subject.test.alpha passes...OK
2/3 subject.test.beta fails...FAIL
3/3 subject.test.gamma skips...SKIP
1 passed; 1 skipped; 1 failed.
error: process exited with code 1 (expected exited with code 0)
```
```json
{"schema":"pabrik.test-report.v1","suite":"spike","zig":"0.16.0",
 "tests":[{"name":"subject.test.alpha passes","status":"pass","error":null,"leaked":false},
          {"name":"subject.test.beta fails","status":"fail","error":"TestExpectedEqual","leaked":false},
          {"name":"subject.test.gamma skips","status":"skip","error":null,"leaked":false}],
 "totals":{"passed":1,"skipped":1,"failed":1,"leaked":0,"total":3}}
```

- console output preserved, JSON valid (`python3 -m json.tool`), **written on the red run**,
- `zig build` exits 1 because a test failed, and `--verbose` confirms **no `--listen=-`** is
  passed in `.simple` mode.

### 6.2 The four gotchas, measured

| experiment | result | consequence |
|---|---|---|
| 3 CPU-bound shards, `.simple`, no `expectExitCode(0)` | real **4.21s** / user 4.17s → **serial** | must call `expectExitCode(0)` |
| same, with `expectExitCode(0)` | real **1.91s** / user **6.61s** → **parallel** | keeps the 8-way sharding |
| `zig build test` twice, no source change | 2nd run **0.055s**, JSON **not** rewritten | declare the file as an output (§5.2) |
| `--summary all` with `.simple` + `expectExitCode(0)` | steps report `success 234ms`, but the summary is only `7/7 steps succeeded` and each shard's stderr is re-printed as a block ending in a spurious `failed command:` | `.simple` drops `P/T tests passed` — the input of `check-zig-test-skips.sh` |
| same layout with the **default** runner (`.zig_test`) | `Build Summary: 7/7 steps succeeded; 3/3 tests passed` + `1 pass (1 total)` per step, **no** report blocks (the shards were silent) | `.server` keeps the counts and the UX; the `failed command:` block needs stderr output, not a failure |
| `expectExitCode(0)` on a default-runner step | build runner **panics**: *illegal call to addCheck: conflicting helper method calls* (`Run.zig:650`) | never call it in `.server` mode |

### 6.3 What the spike did *not* prove

The `.server`-mode fork (§5.1) is **designed but not yet built** — it is a copy of a file that
was read in full, not a guess, but the first PR is where it gets compiled. Everything else in
§4 was executed on Zig 0.16.0, Linux x86_64.

---

## 7. Task list (3 PRs, each independently reviewable)

**PR 1 — the runner + per-suite JSON (the risky part, smallest surface).**
1. `tools/test_runner_json.zig` — fork of the stock runner, fuzz branch dropped, JSON on
   `--json-out=`, no behaviour change when the flag is absent.
2. `build.zig` — `jsonTestRunner(b)` helper + `-Dtest-json` (default on) at the 8-shard site
   and the unsharded `mod_tests` site only; `run.addOutputFileArg(...)` per shard.
3. **Guard test** (`zig build test:json-runner`): a self-check that asserts the report exists,
   parses, and that `totals.total` is non-zero — a Zig upgrade that changes `std.zig.Server`
   must fail loudly, not silently emit an empty report.
4. Verify: `zig build test --summary all` — same pass/skip numbers as before, same live
   progress, plus `zig-out/.../test-*.json`; `zig build test -Dtest-json=false` must behave
   exactly like `main`.

**PR 2 — the other suites + one merged file.**
5. Extend the helper to `test:desktop-app`, `test:cli`, `test:tui`, the four
   `test:helpers:*`, `test:zginlint`, `test:ai_workflow:tui`, `functional-test:zig`.
6. `tools/test_report_merge.zig` + a `test:json` step → `zig-out/test-results.json`
   (§5.4 schema), depended on by `zig build test`.

**PR 3 — consumers.**
7. `scripts/check-zig-test-skips.sh`: read the JSON; keep the ceilings and the verdict logic,
   add the skipped-test **names** to the notice; keep the text-scraping path as a fallback so
   the script still works on a log without a report.
8. `.github/workflows/ci-backend.yml`: upload the report as an artifact.

**Verification for every PR** (the repo's own bar): `zig build test --summary all` green on
Linux, the shard count unchanged, and `zig build test -Dtest-shards=1` still exercising the
unsharded path. Any server-side experiment that needs a port uses **8080** — port 8081 is
off-limits.

---

## 8. Open decisions for the human (these set the shape)

| # | question | my recommendation |
|---|---|---|
| D1 | **Which runner mode?** `.server` (fork ~300 lines; keeps live progress, per-step counts and parallel shards) vs `.simple` (~120 lines; serial unless `expectExitCode(0)`, **no `P/T tests passed` in the summary**, no live progress). | **`.server`** — `.simple` would break `check-zig-test-skips.sh` and the CI skip-ceiling step (they read the `P/T tests passed` sentence, which `.simple` never produces — measured, §6.2), so it is a regression on `main`'s behaviour, not just a UX difference. |
| D2 | **Default on or opt-in?** `zig build test` always writes the report, or only `zig build test -Dtest-json`? | **default on** (a flag that must be remembered is a flag CI forgets), with `-Dtest-json=false` as the escape hatch. |
| D3 | **Where does the file land?** `zig-out/test-results.json` (install prefix, CI-friendly) or a cache path? | **`zig-out/`**, one merged file, so no consumer globs a cache dir. |
| D4 | **JUnit XML too?** | **Yes, but as its own PR** (§9) — the JSON is the primitive; XML is a projection of it. |

---

## 9. Explicitly out of scope

- **JUnit XML** — a second emitter over the same `suites[]` data; useful for CI job summaries.
- **The pytest suites** (`functional-test*`) — they can already emit JUnit/JSON; folding them
  into one report is a separate task with its own wiring (`tests/functional/build.zig`).
- **Test timing analytics / flaky-test detection** — the schema carries `duration_ns` so this
  is *possible* later; nothing consumes it yet.
- **Any change to what tests run** — this task changes reporting only. The shard count,
  `--test-filter` behaviour and `prependVcpkgBinToPath` are untouched.

---

## 10. Risks

| risk | why it matters | mitigation |
|---|---|---|
| `std.zig.Server` is a compiler internal, not a stability contract | a Zig upgrade could break the fork silently — an empty report looks like a green run | the §7.3 guard test fails on `totals.total == 0`; the fork is one file with a header naming the upstream path + version it was taken from |
| Fork drift (`/usr/lib/zig/compiler/test_runner.zig` changes upstream) | the runner would stop matching what the compiler expects | `-Dtest-json=false` keeps the stock runner one flag away, so the blast radius of a bad upgrade is a build option |
| Report written but stale (cache hit) | a reader could believe an old report describes the current tree | the file is a declared step output (§5.2), and it carries `generated` + `zig` + `host` so staleness is visible |
| `.simple` chosen against this recommendation | the summary loses `P/T tests passed`, so `check-zig-test-skips.sh` and the CI skip-ceiling step fail with *"could not find a 'N/M tests passed' line"* — and shards silently serialize without `expectExitCode(0)` | §4.2/§6.2 are the measurement; if D1 goes the other way, PR 3 must land **in the same PR** as the runner, and `expectExitCode(0)` is mandatory |
