# agentic_loop/

Per-session agentic-loop helpers used by `workflow.zig` and the HTTP handlers.
Each file owns one DB-or-pure-data helper plus, where appropriate, its own
**inline `test` blocks** at the bottom of the file.

## Testing convention — **inline, not separate `_test.zig`**

Tests for the helpers in this directory live **inside** the implementation
file as `test "..." { ... }` blocks at the bottom — NOT in sibling
`<file>_test.zig` files. This matches the canonical pattern already in the
directory: [`is_session_kanban.zig`](./is_session_kanban.zig) ships six
inline tests for `isSessionKanban` and no separate `_test.zig`.

`agentic_loop/` enforces this convention strictly — there are **no separate
`_test.zig` files** in this directory as of the inlining refactor. All test
code is colocated with the implementation in a single file.

The rest of the pabrik codebase (e.g. `src/ai_workflow/tui/compaction_*.zig`,
`http_handlers/*_test.zig`) generally uses separate `_test.zig` files.
**`agentic_loop/` is the exception**, not the standard — keep tests inline
here for consistency with the existing files.

### Why inline here

1. **Each helper is small and self-contained.** Most files are 30-200 lines
   of pure logic against a 1-2 table SQLite fixture. Pulling the tests out
   into a separate file would scatter the fixture helpers and the assertions
   they cover across two files.
2. **Tests sit next to the code they exercise.** A future contributor who
   changes `is_worker_running.zig` sees the `test "..."` blocks at the
   bottom and runs them mentally as they read — no "find the test file"
   hop.

### ⚠️ Discovery is NOT automatic — you MUST register the file

**Zig's test runner only auto-discovers `test "..."` blocks in files that
are DIRECTLY `@import`ed by the test runner.** A transitive import chain
through `mod.zig` does **NOT** pull in test blocks.

`agentic_loop/test_runner.zig` must explicitly list each file whose
`test "..."` blocks should run. **Before commit**, run
`zig build test --summary all` and confirm:

```
$ rg 'agentic_loop' .zig-cache/o/*/test 2>/dev/null | sort -u | head
<file>.test.<test_name>...OK
```

If your test file appears but its `test "..."` lines do not, the file is
NOT imported by `agentic_loop/test_runner.zig` — add it.

## Files

As of 2026-08-19 (the inline-impl+tests refactor), every `.zig` file in
`agentic_loop/` owns its own test code. There is no `mod.zig` aggregator
and no separate `<file>_test.zig` files. The 3 exceptions that stay at
`tui/` for backwards compat are:
- `tui/mod.zig` — re-exports the public API surface (`pabrikcore.ai_mod.*`).
- `tui/test_runner.zig` — top-level test discovery for tests that live at
  `tui/`.
- `agentic_loop/test_runner.zig` — discovery for all `agentic_loop/` tests.

| File | Type | Notes |
|---|---|---|
| `test_runner.zig` | re-exports | Registers every test-bearing file for `zig build test` discovery. |
| `agent_memories.zig` | impl + inline tests | saveMemory / loadMemoriesByFts / getMemoryById. |
| `background_process.zig` | impl + inline tests | Background process tracking. |
| `delete_queue_worker.zig` | impl + inline tests | DB queue cleanup. |
| `delete_worker.zig` | impl + inline tests | |
| `design_io.zig` | impl + inline tests | sanitizeFilename + atomicWriteFile. |
| `design_model.zig` | impl + inline tests | Design canvas DB layer (large file — all tests inlined at the bottom). |
| `get_queue_message.zig` | impl + inline tests | |
| `has_queue_messagge.zig` | impl + inline tests | |
| `inherited_context.zig` | impl + inline tests | |
| `insert_llm_histories.zig` | impl + inline tests | |
| `insert_queue_message.zig` | impl + inline tests | |
| `is_session_kanban.zig` | impl + inline tests | |
| `is_worker_cancelled.zig` | impl + inline tests | |
| `is_worker_running.zig` | impl + inline tests | |
| `llm_history.zig` | impl + inline tests | Big file (~360KB after inlining). The "row" struct is in `llm_history_row.zig`. |
| `llm_history_row.zig` | impl + inline tests | `LLMHistory` struct (used by 4 sibling files). |
| `markHistoryNotForLLMRun.zig` | impl | (placeholder) |
| `models.zig` | impl + inline tests | Shared type definitions (`TUIHistory`). |
| `on_event_design.zig` | impl + inline tests | |
| `on_event_sent.zig` | impl + inline tests | |
| `on_event_sent_design.zig` | impl + inline tests | |
| `on_event_sent_kanban.zig` | impl + inline tests | |
| `parsing.zig` | impl + inline tests | |
| `prompts_*.zig` (×6) | impl + inline tests | |
| `retry_delay_ms.zig` | impl + inline tests | |
| `save_agent.zig` | impl + inline tests | |
| `session_skills.zig` | impl + inline tests | |
| `session_plan.zig` | impl + inline tests | |
| `sse_on_event_send_session.zig` | impl + inline tests | |
| `sse.zig` | impl + inline tests | |
| `tools.zig` | impl + inline tests | Tool registry. |
| `tools_exec_*.zig` (×40+) | impl + inline tests | Per-tool exec logic. |
| `update_session_name.zig` | impl + inline tests | |
| `update_task_name.zig` | — | (placeholder) |
| `update_worker.zig` | impl + inline tests | |
| `workflow.zig` | impl + inline tests | The agentic loop orchestrator. |
| `workflow_compact_message.zig` | impl + inline tests | Helpers + orchestration merged 2026-09-10 (ex-`workflow_commpact_message.zig` typo). |

## Running the tests

From the project root:

```bash
zig build test --summary all
```

The `agentic_loop/` tests are part of the full suite and counted in the
`test success` line at the end. To verify just `agentic_loop` tests:

```bash
TEST_BIN=$(find .zig-cache/o -name test -type f -executable \
    | xargs file 2>/dev/null | grep "x86-64" | grep -v windows \
    | sort | tail -n 1 | cut -d: -f1)
timeout 60 "$TEST_BIN" 2>&1 | rg 'agentic_loop' | sort -u
```

## Adding a test to a new helper

1. Write the helper in its own file, e.g. `foo.zig`. Each file should be
   self-contained — it owns its impl, types, AND its tests. There is no
   `mod.zig` to register new files in; `tui/mod.zig` imports the file
   directly if its public API needs to be surfaced as
   `pabrikcore.ai_mod.ai_workflow.agentic_loop.foo`.
2. Append `test "..." { ... }` blocks to the **bottom** of `foo.zig`.
   Use `testing.allocator` for any heap allocations; the project's
   `zig-0.16-inmemory-sqlite-test-setup` pattern (`std.Io.Threaded.init +
   db.init(io, ":memory:")`) is the right fixture for tests that need a DB.
3. **Add `_ = @import("foo.zig");`** to the `test { ... }` block in
   `agentic_loop/test_runner.zig`. Without this, the test compiles but
   never runs.
4. Run `zig build test --summary all` and confirm the new test appears in
   the per-test output of the test binary:
   ```
   $ TEST_BIN=$(find .zig-cache/o -name test -type f -executable | tail -n 1 | cut -d: -f1)
   $ "$TEST_BIN" 2>&1 | rg 'agentic_loop\.foo\.test\.'
   ai_workflow.tui.agentic_loop.foo.test.<your test name>...OK
   ```
5. Commit. The next contributor who runs `zig build test` will see the
   test pass on their machine too.

## Known production bugs surfaced by tests

Adding tests occasionally surfaces pre-existing bugs in production code.
When that happens:

1. **Fix the test to side-step the bug** if the bug is in adjacent code you
   don't want to touch in this PR. Add a comment in the test citing the bug.
2. **Fix the production bug** if it's a one-line surgical fix.
3. **Defer the fix to a follow-up PR** with a TODO comment in the test.

The example from this directory: `LLMHistory.deinit` unconditionally calls
`allocator.free` on `.agent`/`.session_name`/`.tool_name`, which panic
with "Invalid free" when those fields hold their string-literal defaults.
`getLLMHistories.zig` always heap-dupes those fields so production is safe,
but a defensive fix (making the three fields `?[]const u8 = null` with
conditional frees, or splitting the struct into "raw row" + "optional
agent fields") would close the gap.

## When tests need a real `EventBus`

`update_worker`, `delete_worker`, `insert_queue_message`,
`delete_queue_worker`, `sse_send_event_worker`, and
`sse_on_event_send_llMHistory` all emit via the `event_bus` SSE channel.
Tests that want to verify the SSE branch actually fires must:

1. Create a `std.Io.Threaded` (gives a real `std.Io` for the bus + logger).
2. Create an `event_bus.EventBus.init("test_bus", alloc, io)`.
3. Subscribe a top-level `fn (SseEvent) void` callback that captures the
   emitted event into a module-level `var captured: ?SseEvent = null`.
4. Call the helper with `event_bus = &bus`.
5. Assert on `captured.?.event_type`, parse `captured.?.data` as JSON, etc.

Tests that only want the DB-write behavior can pass `event_bus = null` +
`is_emit_sse = true` to confirm the SSE branch is skipped safely.

`onEventSendLLMHistory` also dereferences `logger.?` (line 89 of
`sse_on_event_send_llm_history.zig`), so the test must construct a real
`Logger` via `Logger.init(alloc, io, .{})` rather than passing `null`.

## File-size notes after inlining

After the inlining refactor, `llm_history.zig` is ~360KB and
`design_model.zig` is ~390KB. Both exceed the 256 KiB `.limited()` cap used
by some `http_handlers` static-contract tests, but those tests don't
currently read either file — only `llm_history_description_test.zig` (now
inlined into `llm_history.zig`) and the
`workspace_items_update_name_test.zig` static contract
(now inlined into `workflow.zig`) read source files, and both have been
bumped to `.limited(1024 * 1024)` to accommodate the larger impl files.

## Refactor history

**2026-08-19** — Inlined all `<file>_test.zig` files into their corresponding
implementation files. Deleted the orphaned `agentic_loop/mod.zig` aggregator
(the public API is still re-exported by `tui/mod.zig` which imports the
agentic_loop files directly). No more separate test files in this directory.

**2026-08-14** — [Flattened from `src/ai_workflow/tui/`](
../../../../docs/superpowers/plans/2026-08-14-flatten-tui-into-agentic-loop.md).
All 40+ impl files that previously sat at `tui/` top-level (next to the
two entry-point files `mod.zig` + `test_runner.zig`) now live here. The
`mod.zig` + `test_runner.zig` at `tui/` are kept as thin re-export /
test-discovery surfaces so the public `pabrikcore.ai_mod.*` API surface
stays stable.
