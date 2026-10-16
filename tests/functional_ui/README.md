# Functional UI Tests

Real-data, isolated-in-`/tmp` end-to-end coverage for the pabrik **web
app** — boots a real `pabrik` backend AND a real Vite dev server, then
drives the running UI with [Playwright Python](https://playwright.dev/python/).

Mirrors the isolation guarantees of the sibling `tests/functional/`
suite — the developer's real `$HOME` is never touched.

## ⛔ Safety Invariant

Same as `tests/functional/`:

1. **`is_safe_tmp(path, orig_home)` allow-list validator** — runs
   before any `shutil.rmtree`. The UI harness delegates ALL rmtree to
   `FunctionalHarness.teardown`, which is gated by this validator.
2. **Captured `Path` attribute, not `$HOME`** — `h.temp_dir` is set
   once at boot. Teardown rmtree's THIS attribute.
3. **`ORIG_HOME` snapshot + restore** — captured at boot, restored in
   teardown's first step.

The new dimension for the UI suite:

4. **Vite proxy target is per-test** — `vite.config.ts` reads
   `VITE_API_PROXY_TARGET` from the env; the harness sets it to
   `http://127.0.0.1:<backend_port>` so the running web app talks to
   the TEST backend, not the developer's always-on `:8081`.
5. **Cross-platform isolation** (macOS, Linux, Windows):
   - `is_safe_tmp` is OS-aware (Windows uses native backslash prefix).
   - pnpm is resolved via `shutil.which("pnpm") or shutil.which("pnpm.cmd")`.
     (2026-08-28 — pnpm migration: previously `npm`.)
   - Vite signal handling uses `os.killpg` on POSIX, `os.kill` on Windows.

See `harness_safety_test.py` for 11 cross-platform safety tests.
**If any of them fail, the harness has a P0 bug — do not merge.**

## Running

### One-time setup

```bash
# Install Python deps (including playwright).
pip install -r tests/functional_ui/requirements.txt

# Download Chromium binary (~150 MB to ~/.cache/ms-playwright).
playwright install chromium
```

### Quick smoke (no binary required)

```bash
PYTHONPATH=tests/functional:. pytest tests/functional_ui/harness_safety_test.py -v
# Expect: 11 passed.
```

### Full suite (requires a built pabrik + Playwright Chromium)

```bash
# Option A: use an existing binary
PABRIK_BIN=/path/to/pabrik pytest tests/functional_ui/

# Option B: let zig build do everything
zig build functional-test-ui
```

### Single suite

```bash
PABRIK_BIN=./zig-out/bin/pabrik pytest tests/functional_ui/kanban_lifecycle_ui_test.py -v
```

### Dry-run mode (skip rmtree; useful for debugging)

```bash
PABRIK_FUNCTIONAL_DRY_RUN=1 PABRIK_BIN=./zig-out/bin/pabrik pytest tests/functional_ui/smoke_boot_test.py -v -s
# tempdirs are NOT cleaned up; you can inspect them after the run.
```

### Parallel

```bash
PABRIK_BIN=./zig-out/bin/pabrik pytest tests/functional_ui/ -n auto
# Each worker gets its own pabrik + Vite, its own ports, its own tempdir.
```

## Adding a new suite

1. Create `tests/functional_ui/<feature>_ui_test.py`.
2. Use the `ui_harness` and `page` fixtures from `conftest.py`. They
   provide a fresh `UIHarness` + Playwright `Page` per test.
3. Write `def test_<scenario>()` functions. Each test is a fresh
   backend + Vite boot (~5-10s for pabrik, +5-15s for Vite's first
   compile) plus ~10s of UI interaction.
4. Drive the UI with Playwright's locators (see Playwright's
   [locator docs](https://playwright.dev/python/docs/locators)). Prefer
   semantic locators (`get_by_role`, `get_by_text`) over CSS selectors
   so tests survive small DOM refactors.
5. Use non-trivial data: ≥ 5 items per workspace, ≥ 30 tasks across
   kanban columns. The point is to exercise real shapes.
6. Verify locally with
   `pytest tests/functional_ui/<your>_ui_test.py -v`.
7. No build-side registration needed — pytest auto-discovers files
   matching `*_test.py` in the test directory.

## Test anatomy

```python
def test_create_kanban_task_via_ui(ui_harness: UIHarness, page) -> None:
    h = ui_harness
    # 1. Pre-create workspace + kanban via the API (faster than UI)
    ws_id = h.http("POST", "/api/workspaces", json_body={"name": "x"}, expect=201).json()["id"]
    kanban_id = h.http("POST", f"/api/workspaces/{ws_id}/items/kanban",
                       json_body={"name": "sprint"}, expect=201).json()["item"]["id"]

    # 2. Drive the UI to create a task
    page.goto(h.web_url(f"/w/{ws_id}/k/{kanban_id}"))
    page.get_by_role("button", name="Add task").click()
    page.get_by_placeholder("Task title").fill("first task")
    page.keyboard.press("Enter")

    # 3. Verify via API (more reliable than DOM scraping)
    tasks = h.http("GET", f"/api/workspaces/{ws_id}/items/{kanban_id}/kanban/tasks").json()["tasks"]
    assert any(t["name"] == "first task" for t in tasks)
```

## How isolation works

When a test starts:

1. `UIHarness.boot()` runs.
2. `FunctionalHarness.boot()` boots pabrik against an isolated tmpdir HOME.
3. `UIHarness.boot()` then resolves the frontend source tree (default:
   `src/apps/desktop/`) and spawns `pnpm run dev --port <vite_port>
   --strictPort --host 127.0.0.1` (2026-08-28 — pnpm migration:
   previously `npm run dev`; `--` separator dropped because vite 8
   silently dropped `--port` when it was forwarded as a positional
   arg).
4. The env var `VITE_API_PROXY_TARGET=http://127.0.0.1:<backend_port>`
   is set so Vite's `/api/*` proxy targets the test backend.
5. Vite's HTTP root is polled until it returns 200 (~5-15s for first
   build, faster on warm cache).
6. Playwright opens a fresh browser context, navigates to `h.web_url("/")`,
   and drives the running Vue app.

When the test ends:

1. The fixture's `try/finally` calls `h.teardown()`.
2. `teardown()` stops Vite first (so the frontend stops proxying).
3. `teardown()` stops the backend (via `FunctionalHarness.teardown`).
4. `FunctionalHarness.teardown()` restores HOME, validates the tempdir
   with `is_safe_tmp()`, and rmtree's it.
5. Screenshots taken on failure are saved to
   `tests/functional_ui/artifacts/<test_name>/<timestamp>.png` —
   these are SEPARATE from the tempdir and survive the run.

## Port allocation

Per project memory "Don't ever kill the process port 8081":

| Service  | Strategy         | Range / constraints (from `harness.RANDOM_PORT_*`) |
|----------|------------------|--------------------------------------------------|
| Backend  | random pick      | `[20000, 32000]`, reserved `(8081,)`               |
| Vite     | random pick      | `[20000, 32000]`, reserved `(5173, 8081)`          |

The harness picks a **random** port from a wide shared range (see
`find_free_port_random` + `RANDOM_PORT_START` / `RANDOM_PORT_END` in
`harness.py`). The range sits *below* Linux's default
`net.ipv4.ip_local_port_range` (32768-60999) on purpose: 40k-60k was
inside the pool the kernel hands out for outgoing connections, so a
probe bind could be stolen between the pick and the real listener
(commit f131e6c4). With 12,000 ports of headroom and 50 attempts per
boot, the probability of collision is effectively zero for any
realistic host occupancy. `ui_harness.VITE_PORT_START` /
`VITE_PORT_END` re-export the same two numbers, so the port-contract
tests in `harness_safety_test.py` cannot drift away from the picker.

This replaced the previous sequential scans (`8080, 8082..8199` for
the backend, `5180..5299` for vite) that caused two recurring CI
failures:

  1. **Sequential consumption** — long test suites filled the narrow
     120- or 5199-port windows and errored with "No free port found".
  2. **TIME_WAIT saturation** — even with `SO_REUSEADDR`, a CI runner
     holding 100+ TIME_WAITs could collide with the narrow scan ranges.

### Vite CLI quirk fixed in tandem

Vite 8 silently drops `--port` / `--strictPort` if `pnpm run dev`
forwards the argv with a literal `--` separator (vite treats `--` as
"end of named options", then takes the rest as positional args and
falls back to its default port 5173). The harness previously used
`pnpm run dev -- --port <port>` and observed in the CI log that vite
ignored the chosen port — it ended up on a sequential-scan fallback
instead. We now pass the flags directly to vite via
`pnpm run dev --port <port> --strictPort --host 127.0.0.1` (no `--`).

### TIME_WAIT reuse

The probe socket sets `SO_REUSEADDR` so it can bind ports in TIME_WAIT
state. pabrik's listener also sets `SO_REUSEADDR`, so it can bind the
same port despite lingering server-side TIME_WAITs from prior runs.
Vite's listener honors `SO_REUSEADDR` too.

## Why Playwright, not just HTTP?

- Real browser = real DOM = real Vue reactivity. An HTTP-only test
  can pass while a broken CSS rule makes the UI unusable.
- Playwright's locator API is resilient to small DOM refactors
  (`get_by_role("button", name="...")` survives class-name churn).
- Screenshots on failure give a post-mortem without manual repro.
- The same suite can be extended later to test Monaco editor,
  drag-and-drop, file uploads, etc. — anything that needs a real
  browser.

## What's NOT in scope

- **Vitest component tests** — `bunx vitest run` covers those for
  pure component logic.
- **Cross-browser testing** — Chromium only. Firefox/WebKit can be
  added later by tweaking the `browser` fixture in `conftest.py`.
- **Mobile viewports** — desktop only (1280x800). Add a `mobile_page`
  fixture if needed.
- **Performance / load testing** — out of scope for "functional
  correctness".

## Reference

- Sibling suite: `tests/functional/README.md`
- Parent harness: `tests/functional/harness.py` (where `FunctionalHarness`
  and `is_safe_tmp` live — the UI suite reuses them via composition)
- Vite proxy override: `src/apps/desktop/vite.config.ts`
- Chatview plan: `docs/superpowers/plans/2026-08-20-functional-ui-chatview-test.md`

## Chatview DB-seeded tests

`tests/functional_ui/chatview_ui_test.py` covers the chatview's
**render path** by seeding pre-shaped `sessions` + `llm_history` rows
directly into the harness's isolated `agent.db` — no real LLM is
invoked. The chatview's `GET /api/llm/session/<id>/messages` reads
these exact rows, so DB-seeding exercises the same wire shape the
production agent emits.

### Why DB-seed (not HTTP-seed)?

- **Honest** — tests the exact wire shape including edge cases the
  LLM never produces (malformed `tool_calls_json`, empty content,
  very long reasoning).
- **Fast** — `sqlite3` INSERTs are O(ms); no agent-loop warm-up.
- **Reproducible** — no LLM non-determinism.
- **Cheap** — no API-key quota burned.

### How it works

Each test does:

1. Boot harness (function-scoped, fresh `agent.db` per test).
2. Open Python `sqlite3` against `temp_dir/.config/pabrik/agent.db`.
3. INSERT `sessions` + `llm_history` rows via the `DbSeed`
   helper in `tests/functional_ui/db_seed.py`.
4. Navigate headless Chromium to `/app/chat/<session_id>` and
   assert the rendered DOM matches the seeded data.

The `DbSeed` helper validates the DB path with `is_safe_tmp`
as belt-and-suspenders — the harness already validated the
tempdir, but a regression there would let a test touch the real
home. The double-check raises `FunctionalHarnessError` and aborts
the test before any INSERT runs.

### Available helpers (`db_seed.py`)

```python
seed = DbSeed(h.temp_dir / ".config" / "pabrik" / "agent.db")
with seed.connect() as conn:
    sid = "sess_test_001"
    seed.seed_session(conn, sid, "Test Chat")
    seed.seed_user_message(conn, sid, "hi")
    seed.seed_assistant_message(conn, sid, "hello!")
    seed.seed_tool_result(conn, sid, "call_1", "bash", "stdout")
    seed.seed_compaction_user_message(conn, sid, summary="...", message_count=12)
```

`DbSeed.baseline_timestamps(count=8)` returns a chronologically
spaced list of UTC ISO strings — useful for tests that seed
multiple messages and need them in `created_at_at_nano` order.

### Covered scenarios (10 tests)

1. Empty state — no messages show the "How can I help you?" placeholder
2. Plain user/assistant exchange
3. Multi-turn conversation (4 user + 4 assistant bubbles)
4. Assistant with tool calls (no result yet)
5. Tool call + matching tool result (Bash card renders stdout)
6. Markdown rendering (heading, bold, code, fenced block)
7. User with attached images (2 thumbnails)
8. Reasoning content (collapsible thinking trace)
9. Code block copy button
10. Compaction card (`<compact_messages>` envelope)

### `<html>` wrapper-tag tests (`chatview_html_tag_ui_test.py`, 5 tests)

The LLM can wrap raw HTML in `<html>...</html>`; the chatview renders
each block as a live sandboxed iframe (`sandbox="allow-scripts"`,
null origin). Plan:
`docs/superpowers/plans/2026-08-23-html-tag-support.md`.

1. html-only message → one `iframe.chat-html-frame`, sandbox attr
   intact, payload NOT duplicated as markdown in the DOM
2. inner HTML executes — real Chromium clicks the button inside the
   srcdoc and verifies the onclick handler ran (jsdom can't do this)
3. mixed message — surrounding text still renders via marked AND the
   iframe srcdoc carries the inner payload
4. legacy markdown messages render unchanged, zero iframes
5. unclosed `<html>` (mid-stream shape) degrades safely: raw text
   shows through the legacy path, no iframe, no page errors

### `<mermaid>` wrapper-tag tests (`chatview_mermaid_ui_test.py`, 5 tests)

The LLM can wrap Mermaid source in `<mermaid>...</mermaid>` (the
`ResponseFormatting` prompt offers it); the chatview renders each block
as a live SVG diagram (`components/chat/MermaidDiagram.vue`, mermaid
imported lazily and themed from the app's CSS variables). A
```` ```mermaid ```` fence renders the same way.

1. a `<mermaid>` block → a laid-out `<svg>` with both nodes and labels,
   drawn in the APP palette (node fill `rgb(40,39,39)`, label ink
   `rgb(197,201,197)`, no stock `#ECECFF`), on the card surface
2. a ```` ```mermaid ```` fence renders the same diagram
3. mixed prose + block: markdown outside the tag still renders, and no
   html iframe is produced
4. a diagram that does not PARSE falls back to its own source (no svg,
   the reason in `[data-testid="chat-mermaid-error"]`, no page errors)
5. legacy markdown messages are untouched — zero diagram containers

The `present_files` card draws presented diagrams too:
`chatview_present_files_ui_test.py::test_present_files_markdown_and_mmd_render_diagrams`
presents a real `.md` (prose around a fence) and a real `.mmd` (bare
source), and asserts both render as app-themed SVG inside the card.