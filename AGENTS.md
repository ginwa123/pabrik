
#Mandatory
DONT KILL THE PORT 8081 SERVER,
for testing use another port like 8080

## Verification — Always Use Functional Tests, Never a Live Server

When verifying HTTP behavior (route order, wire payloads, error messages, JSON
serialization, authentication), do NOT spin up a live `pabrik` binary and `curl`
it. Three recurring failure modes only surface from a real wire round-trip and
NONE of them are visible from unit tests:

1. **Route-order shadowing** — `matchRoute` walks routes in registration order
   (see `kabelweb repo src/server/router.zig:182`), so a literal
   `/foo/reorder` registered AFTER `/foo/:bar` is captured with `bar="reorder"`.
   Unit tests on the useCase don't exercise routing.
2. **Empty-slice-as-NULL binding** — `SqliteBackend.exec` binds `""` slices as
   SQL NULL, which violates `NOT NULL` columns (precedent: Migration 079's
   `content` column). Unit tests that pass `""` directly to a SQLite column via
   `INSERT VALUES ('')` work, but PATCH flows that pass `""` through
   `useCase` don't — the bind collapses to NULL mid-execution.
3. **Strict validators treating `""` as a value** — `std.fs.path.isAbsolute("")`
   is false, so an empty `file_path` from an "atomic mode switch" payload fails
   validation. Unit tests usually pass a non-empty path; the empty case is only
   exercised by the frontend's real wire body.

**What to do instead — write an isolated functional test** that boots a fresh
`pabrik` binary against an isolated tmpdir HOME per test, then replays the EXACT
JSON body the frontend sends:

```python
# tests/functional/agent_knowledge_edit_test.py — PR #291 follow-up
def test_text_mode_save_clears_file_path_and_sets_content(harness):
    """The edit dialog's Text-mode save sends {label, content, file_path:""}."""
    ws = _create_workspace(harness)
    agent = _create_agent(harness, ws)
    row = _add_file_knowledge(harness, agent)
    updated = _patch(harness, agent, row["id"], {
        "label": "Switched to text",
        "content": "inline body after switch",
        "file_path": "",
    })
    assert updated["file_path"] == ""
    assert updated["content"] == "inline body after switch"
```

The harness at `tests/functional/harness.py` does all the heavy lifting:
- Picks a free port in 8080..8199 (excluding 8081 — see the mandatory note above).
- Sets `HOME` to an isolated tmpdir (`/tmp/pabrik-func-<uuid>/`) — the harness's
  `is_safe_tmp()` validator gates every `rmtree` so your real `$HOME` is never
  touched (see `tests/functional/README.md` ⛔ section).
- Tears down the binary + tmpdir on test exit (even on assert-fail).
- Runs `zig-out/bin/pabrikcore-linux-x86_64` (or whatever `$PABRIK_BIN` points at).

For Zig-only behavior, an in-memory SQLite test in the same `useCase` file is
enough — but for any HTTP route or wire payload, ALWAYS graduate to the python
functional harness.

**There is no third option.** An earlier version of this file recommended a
"Zig static-contract test" — a `test` block that greps the impl's source text —
as the light-weight middle ground. That was wrong, and ~700 of them accumulated
because of it. They are gone; see the next section for why, and for what to
write instead.

**Anti-pattern: `nohup ./zig-out/bin/pabrik... --port 8080` + `curl`.** Leaks the
process across tool calls, conflicts with the harness, and is exactly what
missed the bugs in PR #291.



**Concrete example** (task_1786507100896, PR #215): backend's `onEventSendSessions` had an `event_type_name` if/else that knew about `created` and `deleted` and fell through to `session_unknown` for everything else. `action="updated"` (the most common case — fired by the auto-rename-on-first-message cascade in `workflow.zig` and the unattended toggle in `llm_history.zig`) reached the wire as `event: session_unknown`, which the frontend's `additionalEventTypes` didn't pre-register. The browser silently dropped it. Sidebar task rows kept showing "New Chat" until a manual page refresh.

## Tests — Assert Behaviour, Never Source Text

**The rule: a `test` block must call the code or observe its output. If it
opens a `.zig` file under `src/` and searches that text, it is not a test.**

This repo had ~700 such tests. They looked like this:

```zig
const HANDLER_PATH = "src/http_handlers/foo.zig";
fn readSource(allocator: std.mem.Allocator, path: []const u8) ![]u8 {
    // openFile + allocRemaining
}
test "foo handler is registered in http_routes.zig" {
    const src = try readSource(allocator, "src/http_routes.zig");
    try testing.expect(std.mem.indexOf(u8, src, "/api/foo") != null);
}
```

or, in the purest form, an offset comparison:

```zig
test "http_routes: exactly one authed group exists, created before any use()" {
    const group_at = std.mem.indexOf(u8, source, "gs.router.group(\"\")").?;
    const use_at   = std.mem.indexOf(u8, source, "authed.use(...authMiddleware);").?;
    if (use_at < group_at) return error.MiddlewareBeforeGroup;
}
```

**Why they are worse than useless — they are simultaneously noisy AND blind:**

- *Noisy.* Rename `authMiddleware`, change a route literal's wording, extract a
  function, add a parameter — the test goes red and nothing is wrong.
- *Blind.* Delete the route outright and the test still passes if any other
  line mentions the string. Add a second, unauthenticated `group("")` ahead of
  the routes and the *offset* test still passes if the offsets happen to line
  up. The thing it is named after — "exactly one authed group, created before
  any use" — is not what it checks.
- *Redundant.* A large share asserted things the compiler already enforces.
  "X is re-exported from Y", "mod.zig exports X", "the root aliases Z": break
  the alias or the import and the file does not compile. A test for that is a
  test that can never fail for the reason it exists.
- *Absent assertions are unmaintainable.* "No envelope builder formats the key
  into a message" is a permanent burden on every future edit, and it does not
  even cover the envelope builders added tomorrow.
- *Whole-repo textual lints are not unit tests.* "No test opens a file at a
  literal `/tmp` path" walked every `.zig` under `src/` on every `zig build
  test`. That belongs in `scripts/` + CI, if it is wanted at all.

**What to write instead — in order of preference:**

1. **Call the function and assert the return value.** The strongest witness is
   the production entry point itself. `http_routes.registerAll` is now split so
   a test can build the REAL route table (`registerAllOn(router)`) and assert
   what `Router.matchRoute` **resolves** — which is the only honest witness for
   route order, and it replaces seven separate greps.
2. **Drive the handler / tool and assert the wire payload.** Error→status
   mapping, key masking, validation: call it with the offending input and look
   at what comes back. Include a **positive control** so an absence assertion
   cannot pass vacuously (`GET /api/config/pabrik never ships a web_search key
   in cleartext` first proves the sentinel IS present before masking).
3. **Assert a property, not a position.** The old
   "the four prompt rules sit in the STATIC PREFIX, before dynamic blocks" test
   compared four byte offsets. The replacement calls `buildMessages` twice with
   two different sessions and asserts the two returned prompts share an
   **identical byte prefix** — which is the actual prompt-cache property, and
   something no offset comparison could ever establish.
4. **Concurrency properties need threads, not greps.** "the id generator has an
   atomic counter (Mac CI 500 regression)" is now 32 threads calling the real
   generator and asserting 32 distinct ids.
5. **Not a unit test at all?** Then it is a **lint** (`scripts/` + CI) or a
   **functional test** (`tests/functional/`). Say which, in the plan.

**Anti-patterns to name in review:**

- `const X_PATH = "src/...";` anywhere in a file's test section. That is the
  smell. There should be **zero** `.zig` path literals under `src/` in tests.
- `@embedFile("...zig")` in a test.
- A test whose name contains `static contract`, `wiring`, `is re-exported from`,
  `is registered in`, `defines pub fn`, `calls <fn>`, `does NOT use`, or
  `never <verb>` **and** whose body is an `indexOf` on a buffer named `source`.
- `indexOf` on JSON **the test itself just serialized** is fine — that is a
  wire assertion, not a source assertion. Keep those.

**Note on naming.** Four tests in `src/modules/agent/tools/document.zig` were
renamed from `static contract:` to `schema contract:`. They were never greps —
they reflect over the live `AgentTool` constants the model receives, which is
the product. If you grep for `test "static contract` to find this class, you
will find those too; the new name keeps them out of that scan.

**Landmine note.** This class is easy to reintroduce by accident, because
"just check the wiring" feels cheaper than standing up a context. If you cannot
reach the behaviour from a test, write the contract down in the plan and say
where it belongs (lint vs. functional harness). Do not write the grep.

**A test that declines to run is a test that did not run.** Zig's
`return error.SkipZigTest;` is the right primitive for a test whose subject
genuinely does not exist on the host, but the count of them is a *metric with a
per-platform ceiling* — measured 2026-10-13: Linux 10, macOS 15, Windows 94 —
enforced by `scripts/check-zig-test-skips.sh` in every backend cell and nightly
on Windows. Prefer a platform-specific assertion over a bail-out, and never
write `if (builtin.os.tag == .windows) return;`, which reports PASS while
asserting nothing. Rule, rationale and the conversion recipe:
`CODING_STANDARDS.md` §2.

## Code Exploration with Graphify — graph-first, grep-second

> **Audience:** any AI agent (Claude, GPT, sub-agent, future-me) that writes,
> edits, reviews, or tests code in this repo. Humans may also find it useful.
>
> **Authority:** this file is loaded automatically by every agent at session
> start. Treat the rules below as non-negotiable. If a rule conflicts with a
> specific task, surface the conflict to the user before acting.

Before exploring or making changes in an unfamiliar module, query the knowledge
graph instead of manually grepping. Graphify combines Tree-sitter static
analysis with LLM-driven semantic extraction into `graphify-out/` (`graph.json`
+ interactive `graph.html` + `GRAPH_REPORT.md`). It only sends semantic
descriptions to the model — never raw source code.

### 0. Freshness check (do this first — graph goes stale fast)

```bash
stat -c '%y %n' graphify-out/graph.json  # if >1 day old, refresh:
graphify update .                        # re-extract, no LLM needed, fast
```

- `graph.json` older than ~1 day → run `graphify update .` before trusting
  query results (this repo moves fast — 9k+ nodes, 600+ communities).
- Missing `graphify-out/` entirely → full build (slow, LLM-backed) is needed;
  ask the user before running it.
- Never hand-edit `graph.json` / `.graphify_labels.json` — they are generated.

### 1. MCP tools (preferred — you already have these connected)

| Goal | Tool | Example |
|---|---|---|
| Project overview | `mcp_graphify_graph_stats` | node/edge/community counts + confidence |
| Find core abstractions | `mcp_graphify_god_nodes` (`top_n: 10`) | hubs like `vue`, `useWorkspacesStore`, `FunctionalHarness` |
| Ask a question | `mcp_graphify_query_graph` (`mode: bfs`, `depth: 2-3`, `token_budget: 4000-6000`) | `"agentic loop workflow tools execution"` |
| Node detail | `mcp_graphify_get_node` (`label: "Agent"`) | file, location, community |
| What depends on X | `mcp_graphify_get_neighbors` (`label: "useWorkspacesStore"`) | callers + callees with edge types |
| Whole subsystem | `mcp_graphify_get_community` (`community_id: N`) | all nodes in one cluster |
| How A reaches B | `mcp_graphify_shortest_path` (`source`, `target`, `max_hops`) | e.g. `ChatView.vue` → `workflow.zig` |
| PR review | `mcp_graphify_list_prs` / `get_pr_impact` / `triage_prs` | blast radius before merging |

Always pass `project_path: /home/ginwa/ginwaaitoolbox` (or the worktree path)
so queries hit the right `graphify-out/graph.json`.

### 2. CLI fallback (shell / sub-agents without MCP)

- `graphify query "<question>" --budget 4000` (add `--dfs` to trace one path)
- `graphify god-nodes --top 10`
- `graphify path "A" "B"` / `graphify explain "X"` / `graphify affected "X" --depth 2`

### 3. Recommended workflow

1. `graph_stats` → scale check (2026-09-03 refresh: ~14.9k nodes / ~22k edges / ~906 communities).
2. `god_nodes` → orient (frontend: `vue`/`useWorkspacesStore`; backend:
   `Agent` in `src/modules/agent/Agent.zig`, `workflow.zig` + `tools.zig` in
   `src/ai_workflow/tui/agentic_loop/`; DB: `migration.zig` + `SqliteBackend`;
   tests: `FunctionalHarness` in `tests/functional/harness.py`).
3. `query_graph` BFS depth 2–3 with a focused keyword set per layer
   (backend: `agentic loop tools execution`; frontend: `ChatView kanban sidebar`;
   DB: `sqlite migration llm_history sessions`). One broad query returns README
   noise — split by layer.
4. `get_node` / `get_neighbors` on the hits that matter, then `read_file` at the
   cited `src=… loc=L…` to confirm (graph snippets are ~100 chars — never quote
   them as source).
5. Before refactoring: `shortest_path` (blast radius) + `affected` (reverse deps).

### 4. Pitfalls

- **Truncated BFS is normal.** Large queries return `TRUNCATED: showing 130/1000
  nodes` — raise `token_budget` or narrow with `context_filter: ["call"]` /
  a specific `get_node` instead of re-asking broadly.
- **Stale graph lies.** A month-old `graph.json` misses new `tools_exec_*.zig`
  files and renamed Vue components. Check `stat` first (see §0).
- **Community IDs are unstable** across rebuilds — cite node labels + file paths,
  not `community=N`, in plans and PR descriptions.
- **MCP `project_path` matters in worktrees.** In a git worktree, point it at
  the worktree root so you query the worktree's `graphify-out/`, not main's.


## Code Comments — No `// NEW (plan: ...)` Tags

Do NOT annotate new code with `// NEW (plan: YYYY-MM-DD-<slug>)` (or
`<!-- NEW (plan: ...) -->` in templates). The repo's history already
carries a few of these from older work — do not add more, and strip
any you just introduced before committing.

Why: the tag states *when* code landed, never *why* it exists. `git
blame` + the plan doc already answer "when"; the comment should
answer "why" in one plain sentence, or not exist at all.

- ❌ `// NEW (plan: 2026-09-11-foo). Mirror of handleSave's X — see ...`
- ✅ `// Mirror of handleSave's X (baked into queue_message).`
- ✅ No comment at all when the code is self-evident (`useGitWorktree:
  useGitWorktree.value` needs no annotation).

Plan-doc references belong in the plan file and the PR description —
not inline in source.


## Frontend — Every View Switch Must Update the Browser URL

Any in-app navigation — tab switches, view toggles, dialog opens that
represent a distinct view — MUST sync to the browser URL (route path or
query param, e.g. `?panel=files|pr|commits` in `SidebarDiffPanel.vue`
via `readTabParam`/`syncTabParam` + `router.replace`). A view that only
lives in component state is unreachable by refresh, Back/Forward, and
shared links.

Why: the commits tab first shipped as a local `showCommits` boolean —
switching Files → Commits left the URL unchanged, so refresh lost the
view and Back/Forward skipped it. The fix folded the tab into the
existing `?panel=` param so mount restores it.

- ✅ New tab/toggle reuses the view's existing URL param (extend the
  union, don't invent a second param).
- ✅ Mount reads the param back (deep-linkable); clicks write it
  (`router.replace`, not `push`, for tab switches).
- ✅ Cover with a spec: click asserts the query value, mount-with-query
  asserts the restored view (see `SidebarDiffPanel.tabs.spec.ts`).
- ❌ Local-only `ref` booleans for view state in routed components.


## Frontend — No Emoji as Icons; Use Inline SVG

An emoji may NOT stand in for an icon. If a standalone glyph's job is to
identify an object or an action, it MUST be inline SVG — ideally a shared
component, not a third hand-copied `<path>`.

Why, in order of how much damage each one does:

- **They render at unpredictable sizes.** A status column built from
  📝 ➕ 🗑️ 🔄 📋 ❓ renders six different pixel heights next to 12px
  monospace paths, because each glyph has its own advance width and
  baseline in the platform emoji font. The row is 28px because of what
  is in it, and six sizes is six reasons the row drifts.
- **They are multi-colour and fight the palette.** The app is dark-only
  and muted (`--semantic-text #c5c9c5`, `--color-violet #8992a7`).
  GitLab's `#FC6D26` orange sitting next to the kanagawa palette reads
  as an error, so brand emoji AND brand hex both break the house rule
  that colour comes from a CSS variable. `fill="currentColor"` fixes both.
- **They are not portable.** This app ships Windows, macOS and Linux. The
  same commit picks up Segoe UI Emoji / Apple Color Emoji / Noto Color
  Emoji, and the three do not draw the same glyph.
- **They carry no meaning the app can assert on.** 🔀 in the PR header
  said "some kind of change request" when the panel must tell a GitHub
  pull request from a GitLab merge request — the exact distinction
  `helpers/forgeWording.ts` exists to enforce in prose, thrown away by
  the icon. You cannot lock a spec onto an emoji; you *can* lock a spec
  onto an SVG path (house pattern:
  `WorkspaceItemTaskCard.gitBranch.spec.ts:90-99` pins `M6 3v12`).
- **They are how provider-bug prose comes back.** The PR surface already
  has one of these — `<pr-url>/conflicts` is GitHub-only and GitLab 404s
  on it. An icon that cannot distinguish the two forges invites the next
  one.

- ✅ `<ForgeIcon :provider="prProvider" size-class="w-4 h-4" />` —
  `components/git/ForgeIcon.vue`: inline SVG, `fill="currentColor"`,
  both marks from the Simple Icons 24×24 set (CC0-1.0).
- ✅ A shared component once two callers need it — `SpinnerIcon.vue`,
  `EmptyState.vue`, `SseStatusBadge.vue` all exist for that reason.
- ✅ A *typographic* character when it is genuinely a character:
  `✕ ▶ ▼ ↻ ◫ ⋮ ⌕ ⚠`. Monochrome, one font stack, fixed advance. That is
  what the right sidebar's rail and tab strip use.
- ✅ An icon that names a thing gets a `data-testid` (and `data-forge`
  on `ForgeIcon`) so a spec can assert which mark rendered.
- ❌ `<span class="text-body">🔀</span>` in a panel header.
- ❌ `<span class="text-display mb-3">🔀</span>` as an empty-state glyph —
  `EmptyState` takes a `#glyph` slot for exactly that case.

Honest status: this was written while redesigning the chat right
sidebar, so offenders are still in the tree — `🔀` in
`WorktreeMenu.vue:124` and `CreatePrDialog.vue:112`, plus `🌿` and `✓` in
`SidebarDiffPanel.vue`. Sweep them when a component next touches those
lines; do not start a tree-wide emoji sweep inside an unrelated change.


## Frontend — Banned Code in Vue/TS (the `useEffect` ban)

`src/apps/desktop/` enforces the Vue/TS analogue of React's **"You Might Not
Need an Effect"** doctrine. The bans are LINT RULES, not advice — the full
table, the React→Vue mapping, and the "what is NOT banned" list live in
the Vue/TS banned-code rules in `src/apps/desktop/eslint-rules/`. Read those
before arguing with a lint error.

| Rule | Bans | Fix |
|---|---|---|
| `local/no-watch-effect` | `watchEffect()` — implicit deps | `watch(src, cb)`, or `computed()` |
| `local/no-watch-feedback-loop` | a `watch` that writes back into the value it watches (self-retrigger) | `computed()`, or move the write into the handler |
| `local/no-derived-state-watch` | a `watch` whose body only assigns computable state | `computed()`, or `toRef()` |
| — | (a mirror you ALSO write via v-model/handler is **allowed** — it is state, not derived) | keep the watcher |
| `local/no-silent-fallback-catch` | a `catch` that returns `[]`/`null`/`''` with no log, no error ref, no comment | put the failure in the type (`sync/runtime.ts`) |
| `@typescript-eslint/ban-ts-comment` | `@ts-ignore`, `@ts-nocheck` | fix the type; `@ts-expect-error -- reason` is allowed |
| `@typescript-eslint/no-explicit-any` | bare `any` | narrow it, or add an inline `--reason` disable |

**`watch(() => props.id, () => load())` is ALLOWED**, and so is
`watch(() => props.x, v => { draft.value = v })` when `draft` is also bound with
`v-model` — a value you can write yourself is state, not derived state, and
`computed()` would make the input read-only. `watch(() => props.id, () => load())`
is the legitimate `useEffect` equivalent and the dominant idiom here (46 of 103
real call sites) — the derived-state rule requires the callback body to
contain **no call at all** before it fires. Do not "fix" a lint error by
rewriting a real side-effect watcher as `computed`; that deletes the
behaviour.

Both `watch` rules now stand at **zero** occurrences and need no baseline. Only
`local/no-silent-fallback-catch` is ratcheted, pinned by
`src/apps/desktop/eslint-suppressions.json` (87 sites). Fixing a site is good;
adding one turns CI red. Regenerate with
`pnpm run lint:banned-baseline` **only after** fixing debt — never to silence
a new violation. Note that `--suppress-rule` records only `error`-severity
violations, so those rules must stay at `error`; softening one to `warn`
silently disables its baseline.

`src/__tests__/bannedCodeRules.spec.ts` pins both directions (that each ban
fires, and that the legitimate shapes stay silent). If you change a rule,
run it.


## Frontend — No `try`/`catch` in the desktop app; use Effect-TS

New frontend code in `src/apps/desktop/` MUST express fallibility in the
**type**, not in a `try`/`catch` block. `src/apps/desktop/src/sync/` is the
reference implementation; the `effect` package is already a dependency.

**This is now enforced, not advisory.** `local/no-try-catch`
(`src/apps/desktop/eslint-rules/noTryCatch.ts`) bans the construct outright;
537 pre-existing sites across 132 files are pinned as baseline debt in
`eslint-suppressions.json`, so the count can only fall. The full policy — the
Effect spellings, the `runSync*` seam table, and what stays legal — is
`src/apps/desktop/docs/try-catch-policy.md`.

**Why — this is not a style preference, it is a correctness rule.**
`SyncError.ts` says it outright: before Effect, *"a backend outage, a corrupt
IndexedDB database and a legitimately empty result all reached the UI as the
same value. The engine's callers could not tell 'there is nothing new' from
'we could not check'."*

PR #719 is that exact bug, live, in the chatview:

```ts
// ❌ The catch swallows the failure into a plausible-looking success.
try {
  const data = await api.getChatHistory(sid, PAGE_SIZE, undefined)
  messages.value = data.messages
} catch {
  return { messages: [], has_more: false, next_cursor: null, skills: [] }
}
```

`getChatHistory` returned `messages: []` on transport failure *and* on a real
empty session, so `error` stayed `null`, and the empty state's
`v-if="!isLoading && !error && messages.length === 0"` was true. A slow
backend rendered **"How can I help you?"** for sessions full of messages. The
`chat-load-error` block and its Retry button were **dead code** — the only
route to them was a `catch` around a function that could never throw.

### The rules

- **A fallible operation returns `Effect<A, E>`, not a promise that may reject
  and not a promise that may return a fake empty.** Declare the failure as a
  tagged error (`Data.TaggedError`), as `sync/SyncError.ts` does.
- **The caller picks the policy, and the policy is visible in the type.** Do
  not hard-code "degrade to empty" inside the API layer — that is the move
  that caused the bug. Offer both a rejecting variant and an explicitly
  named best-effort wrapper, and make call sites say which one they want.
- **Reuse the existing seam.** `runSyncEffect` / `runSyncEffectOr` /
  `runSyncVoid` (`sync/runtime.ts`) are the Vue-`<script setup>` bridge: they
  run an `Effect`, log the squashed cause in dev, and degrade to a value the
  caller named. `Effect.runPromise(Effect.exit(effect))` + `Exit.isSuccess` is
  the shape to copy for a new seam.
- **`try { … } finally { … }` with no handler is still allowed** — releasing a
  resource is not handling a failure, and there is no error channel to widen.
  A `catch` is not, however exceptional the case: the rule fires on the
  construct, because a `catch` binding is `unknown` and the caller's signature
  still claims success. If a case genuinely cannot be an Effect, add
  `// eslint-disable-next-line local/no-try-catch -- <reason>` and bring it to
  review — that is the exemption process, not a helper that hides the `catch`.
- **`promise.catch(fn)` is deliberately NOT banned.** Ten of its 30 sites are
  fire-and-forget `router.replace(...)` navigations and three are best-effort
  `res.text()` reads, where the failure genuinely cannot reach the user. The
  dangerous subset — the one that returns an empty-looking value with no
  diagnostic — is already caught by `local/no-silent-fallback-catch`.
- **Never let a caught error disappear into a value the UI cannot
  distinguish from a legitimate answer.** If a fallback value is returned,
  the reason must still reach a log or a ref.

### Checklist before you commit frontend code

- [ ] Did I add a `try`/`catch`? Can the failure live in the error channel instead?
- [ ] Does any "empty" value get returned on the failure path? If so, is
      "empty" still distinguishable from "unavailable" downstream?
- [ ] Is any `error` ref effectively **write-only** (set, never rendered)?
      That is the fingerprint of a swallowed failure.
- [ ] Does the spec prove the failure path? A test that only seeds the happy
      path will pass on code that has this bug.

Repo-specific notes: `scrollLogger.*({ reason })` takes a closed `ScrollReason`
union (a retry is not a scroll reason — use `console.warn`); `oxlint`'s
`no-useless-catch` rejects a `catch (e) { throw e }` wrapper; and prettier
wraps long `v-if` expressions across lines, so source-contract regexes must be
whitespace-tolerant.

**Paying the debt down is a separate task.** The baseline is 537 sites; each
fix is usually a one-line `Effect.tryPromise` around the single `await` inside
the `try`. Regenerate with `pnpm run lint:banned-baseline` **after** fixing
debt, never to silence a new violation.



## Settings — User scope vs Workspace scope

The settings UI has exactly **two** scopes, and which one a setting lives in is
a statement about what it applies to.

| Scope | Route | Applies to |
|---|---|---|
| **User** | `/app/settings` | every workspace |
| **Workspace** | `/app/:workspaceId/settings` | that one workspace |

- **User scope holds `General` only** — notifications, retry delay, web launch,
  browser tabs. Those genuinely apply everywhere.
- **Workspace scope holds `Overview`, `Secrets`, `Skills`, `Memories`, and the
  four config sections `Profiles`, `MCP Servers`, `Tools`, `Skill Evals`**
  (web search rides inside MCP Servers).

Why those four moved: they were never really user-level. A profile carries a
model *and* an API key, an MCP server list and a tool allowlist are per-project
facts, and skill evals run over the workspace's own skills. Hosting them under a
scope whose own label reads "applies everywhere" made the label a lie.

### How a workspace's config is stored

`workspace_settings` (Migration 105) holds a **sparse JSON overlay** keyed on
`(owner, workspace_id)`. `owner` is `''` without `--auth` and the user id with
it — a workspace is shared between users and the overlay holds API keys.
`src/agentic_loop/session_llm_config.zig` merges the overlay over the user-level
config text *before* parsing, so a run in that workspace gets the merged config.

The merge rule is one line: **objects deep-merge; scalars and arrays replace.**
That is what lets a workspace override one profile's model and keep its key, and
why a workspace's `tools` list REPLACES the user's rather than unioning.

### Rules

- **Only the workspace-scoped keys are stored.** `PUT
  /api/workspaces/:id/config` slices the body down to them and returns **400**
  when the body carries none — storing `{}` would report success while every
  setting the user typed stayed at user level.
- **Never touch the process-global `LlmConfig` singleton from the workspace
  routes.** One pointer cannot serve N workspaces. That is the trap
  `session_llm_config.zig` exists to avoid.
- **"No overlay" is an ABSENT ROW; "deliberately inherited" is a row with an
  EMPTY body.** `hasRow` ("may I seed this?") and `hasOverlay` ("does it
  override anything?") are different questions — collapsing them makes a
  deliberate reset come back on the next boot.
- **The editor is `PabrikConfigEditor`** — one component, both scopes, driven by
  a `PabrikConfigSource`. It renders ONE section; navigation is `SettingsShell`'s
  sidebar plus `?section=`, and there is no tab strip inside it.
- **Both scopes can edit the raw JSON** (`Form | JSON`, URL-backed as
  `?mode=json`). An invalid paste can never be applied, left, or saved over
  silently — that is the whole contract of that mode.
- **A scope's sections live in ONE list.** `WORKSPACE_AGENT_SECTIONS` (in
  `helpers/configSource.ts`) is what the shell derives its nav from and what the
  workspace view renders, so a section cannot be listed but unrenderable.

## Crash Triage — Read the Reporter Before Theorising

When a `pabrik` process dies — `thread <tid> panic: reached unreachable code`,
a SIGSEGV/SIGABRT, or an agent run that simply stops — the report is ALREADY
WRITTEN. Never start from the terminal scrollback: it is truncated, and a
Ctrl-C swallows the stack trace entirely.

- **`$TMPDIR/agentic_coding.log`** is the crash log (`src/main.zig:90-93` sets
  the path; `src/service/crash_handler.zig` writes it). The panic handler and
  the signal handler both append here and mirror the same block to stderr, so
  a functional-test child's report also lands in the harness's captured log.
- One report = one block: `=== CRASH: received signal <SIG>` … `=============`,
  carrying the build mode, the fault address, a symbolicated trace
  (`function` + `file:line`) and raw addresses for `addr2line -e <exe> <addr>`.
- **The log is truncated on every boot.** Copy it out (`cp
  $TMPDIR/agentic_coding.log /tmp/…`) the moment a crash is reported, or the
  evidence is gone — that is exactly what happened to the 2026-10-12T16:57
  `loop_counter=79` crash.
- Triage by SIGNATURE, not by count: `(signal, build mode, first frame under
  src/)` collapsed one 31k-line log into 3 distinct bugs, not 15 bugs. The *victim* frame
  is often innocent — a wild `close(2)` reports wherever it happens to land, so
  a static-serve fd bug can surface inside an agent-loop thread.

`reached unreachable code` on a **Debug** build is Zig's runtime-safety panic,
not pabrik's. It is most often `std.Io.Threaded.recoverableOsBugDetected()`
firing because `close(2)` returned `EBADF`: a descriptor closed twice, usually
by a raw fd close racing an `Io` handle that no longer owns the number. Find
the FIRST close, not the reported one — and note `ReleaseFast` skips
`recoverableOsBugDetected` entirely, so the same bug is silent there and only
shows up as a truncated response. `tests/functional/static_serve_concurrency_test.zig`
is the guard for that class.
