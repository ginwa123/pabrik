"""Functional UI tests for the in-app code viewer (view=code-editor).

Reproduces the user-reported bug "when i click code editor there is no
code" (kanban task_1790594549955_1) against the REAL production bundle,
a real pabrik backend (isolated tmpdir HOME, random ports — never :8081)
and a real headless Chromium.

WHY PRODUCTION AND NOT THE VITE DEV SERVER
------------------------------------------
The blank viewer was a **bundle-resolution** bug, so it only exists in
the built artifact:

``CodeEditor.vue`` loaded monaco with
``await import(/* @vite-ignore */ 'monaco-editor')``. ``@vite-ignore``
tells Vite not to rewrite the specifier, so the emitted chunk ends up
with ``import(`monaco-editor`)`` — a bare specifier no browser can
resolve. ``onMounted`` rejected with
``TypeError: Failed to resolve module specifier "monaco-editor"``, so
the editor instance was never created: the header (language pill,
footer path) rendered while the body stayed empty — exactly the
screenshot in the bug report.

The Vite **dev** server resolves bare specifiers itself, so the dev-mode
UI harness cannot see this class of bug at all — and neither can the
jsdom unit tests (``vitest.config.ts`` aliases ``monaco-editor`` to a
stub and runs with ``dangerouslyIgnoreUnhandledErrors: true``). Hence:
``pnpm run build-only`` once per session, then boot the backend with
``--static-dir <dist>`` so the production bundle and the API share one
origin (no proxy, no dev server).

Covered scenarios:
  1. ``test_code_viewer_renders_code`` — the deep-linked viewer renders
     the file's real text, a line-number gutter and syntax tokens, with
     no module-resolution error in the console.
  2. ``test_code_viewer_restores_after_reload`` — reloading the URL
     renders the same content again (no silent blank).
  3. ``test_code_viewer_jump_to_line`` — ``?line=N`` marks the target
     row so the diff-review "open at this line" jump lands visibly.

Run:
    PABRIK_BIN=./zig-out/bin/pabrikcore-linux-x86_64 \\
      /tmp/pabrik-ui-venv/bin/python -m pytest \\
      tests/functional_ui/code_editor_viewer_ui_test.py -v -s
"""

from __future__ import annotations

import os
import shutil
import subprocess
from pathlib import Path
from typing import Iterator
from urllib.parse import urlencode

import pytest

from harness import FunctionalHarness

#: Distinctive filename so the assertions cannot match another file.
FILE_NAME = "code_viewer_sample.ts"

#: Marker embedded in the file body; asserted against the rendered view.
MARKER = "CODE_VIEWER_MARKER_7f3a91"

FILE_BODY = (
    "// sample for the code viewer UI test\n"
    "export function greet(name: string): string {\n"
    f"  const marker = '{MARKER}'\n"
    "  return `hello ${name} ${marker}`\n"
    "}\n"
)

#: Lines the viewer must number: same as the file (no phantom trailing
#: line for the final newline).
EXPECTED_LINES = len(FILE_BODY.rstrip("\n").split("\n"))

#: 1-based line holding MARKER (see FILE_BODY above).
MARKER_LINE = 3


# ─── fixtures ───────────────────────────────────────────────────────────────


def _frontend_root() -> Path:
    """Locate ``src/apps/desktop`` by walking up from this test file."""
    for parent in Path(__file__).resolve().parents:
        candidate = parent / "src" / "apps" / "desktop"
        if (candidate / "package.json").exists() and (candidate / "vite.config.ts").exists():
            return candidate
    raise RuntimeError(
        "could not locate src/apps/desktop from "
        f"{Path(__file__).resolve()} — run this suite from the repo checkout"
    )


@pytest.fixture(scope="session")
def frontend_dist(default_pabrik_bin: Path) -> Path:  # noqa: ARG001 — skip if no binary
    """Build the production frontend bundle once for the whole session.

    rolldown + vite 8 build this app in ~2s, so paying it once per
    session is far cheaper than one dev-server boot per test — and it is
    the only artifact that contains the bug this suite guards.
    """
    root = _frontend_root()
    pnpm = shutil.which("pnpm") or shutil.which("pnpm.cmd")
    if pnpm is None:
        pytest.skip("pnpm not found in PATH — cannot build the frontend bundle")

    env = os.environ.copy()
    env["BROWSER"] = "none"
    proc = subprocess.run(
        [pnpm, "run", "build-only"],
        cwd=str(root),
        env=env,
        capture_output=True,
        text=True,
        timeout=900,
    )
    if proc.returncode != 0:
        pytest.fail(
            "`pnpm run build-only` failed — the production bundle cannot be tested:\n"
            f"--- stdout (tail) ---\n{proc.stdout[-4000:]}\n"
            f"--- stderr (tail) ---\n{proc.stderr[-4000:]}",
            pytrace=False,
        )
    dist = root / "dist"
    if not (dist / "index.html").exists():
        pytest.fail(f"build produced no {dist / 'index.html'}", pytrace=False)
    return dist


@pytest.fixture
def prod_harness(
    default_pabrik_bin: Path, frontend_dist: Path
) -> Iterator[FunctionalHarness]:
    """pabrik backend serving the BUILT frontend at ``/`` (same origin as /api).

    ``--static-dir`` is the backend's own static handler (with an SPA
    fallback for /app paths), so the production bundle and the API share
    one origin — exactly how it is deployed.
    """
    h = FunctionalHarness.boot(
        default_pabrik_bin,
        extra_args=("--static-dir", str(frontend_dist)),
    )
    try:
        yield h
    finally:
        h.teardown()


# ─── helpers ────────────────────────────────────────────────────────────────


def _make_cwd(h: FunctionalHarness, suffix: str) -> Path:
    cwd = Path(h.temp_dir) / suffix
    cwd.mkdir(parents=True, exist_ok=True)
    (cwd / FILE_NAME).write_text(FILE_BODY, encoding="utf-8")
    return cwd


def _create_workspace_with_agent(h: FunctionalHarness, cwd: Path) -> str:
    """Workspace + agent item pointing at ``cwd``.

    Needed because a session only resolves to a workspace (and therefore
    only BOOTS a chat, instead of failing closed to ``/app``) when a
    workspace item's ``path`` matches the session cwd — see
    ``resolveWorkspaceId`` in ``session_get.zig``.
    """
    ws_id = h.http("POST", "/api/workspaces", json_body={"name": "ui-code-viewer"}, expect=201).json()["id"]
    h.http(
        "POST",
        f"/api/workspaces/{ws_id}/items/agent",
        json_body={"name": "ui-code-viewer-agent", "path": str(cwd)},
        expect=201,
    )
    return ws_id


def _create_session(h: FunctionalHarness, cwd: Path) -> str:
    r = h.http(
        "POST",
        "/api/llm/session",
        json_body={"name": "ui-code-viewer-chat", "cwd_session": str(cwd)},
        expect=201,
    )
    return r.json()["id"]


def _goto(page, url: str) -> None:
    """Navigate to an app deep link, gating on ``domcontentloaded``.

    Never gate on the browser ``load`` event. ``load`` waits for EVERY
    subresource the document pulls in, and this is a lazily-chunked SPA
    served by pabrik's own static handler, so on a loaded runner a single
    slow chunk turns into ``Page.goto: Timeout 30000ms exceeded`` — a
    failure reported at the navigation, pointing at nothing the test is
    about. That is what ``test_code_viewer_jump_to_line`` hit on CI run
    38127927593 (shard 1/3, where the shard took 5m13s for 46 tests) while
    macOS passed the same test on the same commit.

    The readiness gate belongs at the product surface the test asserts on:
    ``_assert_viewer_shows_code`` waits for ``[data-testid="code-editor"]``
    with the file's marker rendered. ``domcontentloaded`` is still a real
    barrier — module scripts are deferred, so it fires only after the
    entry's whole static import graph has executed and the app has mounted
    (same rationale as ``_open_agent_view`` in
    agent_system_prompt_ui_test.py).
    """
    page.goto(url, wait_until="domcontentloaded", timeout=30000)


def _open_sidebar(page) -> None:
    """Open the chat-owned right sidebar (it is closed by default)."""
    opener = page.locator('[data-testid="chat-sidebar-open"]')
    try:
        opener.wait_for(timeout=30000, state="visible")
        opener.click()
    except Exception:
        pass  # already open (persisted per chat type)


def _assert_chat_layout_with_viewer(page) -> None:
    """The viewer's real contract inside a chat.

    Regression (kanban task_1790594549955_1, follow-up): the viewer used
    to claim the whole <main>, unmounting ChatView — so the right sidebar
    the user clicked the file IN disappeared, and the composer was left
    floating over the file. Both must be gone/present as below.
    """
    viewer = page.locator('[data-testid="code-editor"]')
    viewer.wait_for(timeout=30000, state="visible")
    assert MARKER in viewer.locator('[data-testid="code-editor-body"]').inner_text()

    # The chat's own surfaces stay mounted.
    sidebar = page.locator('[data-testid="chat-right-sidebar"]')
    sidebar.wait_for(timeout=10000, state="visible")
    assert sidebar.is_visible(), "right sidebar disappeared with the code viewer"

    # The composer and the message list are hidden while the viewer is up.
    assert page.locator('[data-testid="chat-center-code"]').count() == 1, (
        "the viewer did not render in the chat's center column"
    )
    assert page.locator("text=Type a message").count() == 0, (
        "the chat composer is floating over the code viewer"
    )
    # The full-surface overlay must not be mounted alongside the chat.
    assert page.locator('[data-testid="code-viewer-overlay"]').count() == 0


def _app_url(
    h: FunctionalHarness,
    cwd: Path,
    *,
    line: int | None = None,
    session_id: str | None = None,
    workspace_id: str | None = None,
) -> str:
    """The readable code-editor deep link, in the shape the app writes.

    ``useCodeEditorSession.syncUrl`` does ``router.replace({ path:
    route.path, query })`` — it KEEPS the current path and only merges the
    editor keys. So a file opened from inside a chat lands on
    ``/app/{ws}/chat/{session}?view=code-editor&file=...``, and the ``cwd``
    is deliberately NOT in the URL: it resolves from the surrounding
    workspace/chat context on restore.

    The older bare ``/app?view=code-editor&file=...&cwd=...`` shape is
    dead — nothing writes it any more, and on a bare ``/app`` path there
    is no chat/task context, so ``rightSidebarCwd`` resolves to ``''``
    and ``restoreFromUrl`` takes its ``'No working directory'`` branch.
    That is why this helper takes the chat coordinates and builds the
    path form instead.

    Pass ``session_id``/``workspace_id`` for the in-chat shape. Omit both
    for the no-chat shape (bare ``/app``), which has no surrounding
    context to resolve the cwd from — so THAT branch still needs the
    explicit ``cwd`` query param, and renders through AppLayout's
    full-surface overlay.
    """
    query: dict[str, str] = {
        "view": "code-editor",
        "file": FILE_NAME,
    }
    if line is not None:
        query["line"] = str(line)
    if session_id and workspace_id:
        # In-chat: the cwd resolves from the chat context, so it stays
        # out of the URL exactly as `syncUrl` writes it.
        base = f"/app/{workspace_id}/chat/{session_id}"
    else:
        # No chat on screen: nothing to resolve the cwd from, so it must
        # travel explicitly.
        base = "/app"
        query["cwd"] = str(cwd)
    return f"http://127.0.0.1:{h.port}{base}?{urlencode(query)}"


def _collect_errors(page) -> list[str]:
    errors: list[str] = []
    page.on(
        "console",
        lambda msg: errors.append(msg.text) if msg.type == "error" else None,
    )
    page.on("pageerror", lambda exc: errors.append(str(exc)))
    return errors


def _assert_no_module_resolution_error(errors: list[str]) -> None:
    """The blank-viewer root cause, asserted directly.

    A bare module specifier reaching the browser surfaces here as
    ``Failed to resolve module specifier "monaco-editor"``. If this
    fires, a dependency is being resolved at runtime instead of at
    build time — i.e. the bundle is broken for that component.
    """
    bad = [e for e in errors if "resolve module specifier" in e or "monaco" in e.lower()]
    assert not bad, (
        "the browser could not resolve a module specifier — the code "
        "viewer's bundle is broken:\n" + "\n".join(f"  - {e[:400]}" for e in bad)
    )


def _assert_viewer_shows_code(page) -> None:
    viewer = page.locator('[data-testid="code-editor"]')
    viewer.wait_for(timeout=30000, state="visible")

    body = viewer.locator('[data-testid="code-editor-body"]')
    body.wait_for(timeout=10000, state="visible")
    text = body.inner_text()
    assert MARKER in text, (
        "code viewer rendered no file content (the reported blank viewer).\n"
        f"body text was: {text!r}"
    )

    # Line-number gutter — the diff-review pattern's left column.
    numbers = viewer.locator('[data-testid="code-line-number"]')
    assert numbers.count() == EXPECTED_LINES, (
        f"expected {EXPECTED_LINES} numbered rows, got {numbers.count()}"
    )
    assert numbers.first.inner_text().strip() == "1"

    # Syntax tokens — proves the shared zero-dep tokenizer drives the
    # render (same `tok-*` palette as the git diff review), not a dump.
    assert viewer.locator("span.tok-keyword").count() > 0, (
        "no syntax tokens rendered; the viewer is not using the "
        "diff-review highlighter"
    )


def _print_errors(errors: list[str], page) -> None:
    print(f"\n[final url] {page.url}")
    if errors:
        print("[console errors]")
        for e in errors:
            print(f"  - {e[:300]}")


# ─── tests ──────────────────────────────────────────────────────────────────


def test_code_viewer_renders_code(prod_harness: FunctionalHarness, page) -> None:
    """The production bundle renders the file's code in the viewer."""
    h = prod_harness
    cwd = _make_cwd(h, "code-viewer-prod")
    errors = _collect_errors(page)

    try:
        _goto(page, _app_url(h, cwd))
        _assert_viewer_shows_code(page)
        # The view switch is deep-linkable: the browser URL carries it.
        assert "view=code-editor" in page.url, page.url
        assert FILE_NAME in page.url, page.url
        _assert_no_module_resolution_error(errors)
    finally:
        _print_errors(errors, page)


def test_code_viewer_restores_after_reload(prod_harness: FunctionalHarness, page) -> None:
    """A reload of the code-editor URL re-renders the same file."""
    h = prod_harness
    cwd = _make_cwd(h, "code-viewer-prod-reload")
    errors = _collect_errors(page)

    try:
        _goto(page, _app_url(h, cwd))
        _assert_viewer_shows_code(page)

        # Same gate as _goto: the reload only has to re-parse the
        # document; the viewer assertions below are the real check.
        page.reload(wait_until="domcontentloaded", timeout=30000)
        _assert_viewer_shows_code(page)
        _assert_no_module_resolution_error(errors)
    finally:
        _print_errors(errors, page)


def test_code_viewer_jump_to_line(prod_harness: FunctionalHarness, page) -> None:
    """``?line=N`` marks the target row (the diff review's Open-at-line jump)."""
    h = prod_harness
    cwd = _make_cwd(h, "code-viewer-prod-line")
    errors = _collect_errors(page)

    try:
        _goto(page, _app_url(h, cwd, line=MARKER_LINE))
        _assert_viewer_shows_code(page)

        target = page.locator(
            f'[data-testid="code-line"][data-line="{MARKER_LINE}"][data-target="true"]'
        )
        assert target.count() == 1, (
            f"expected exactly one row marked as the ?line={MARKER_LINE} target, "
            f"got {target.count()}"
        )
        assert MARKER in target.inner_text()
        _assert_no_module_resolution_error(errors)
    finally:
        _print_errors(errors, page)


def test_right_sidebar_survives_the_code_viewer(prod_harness: FunctionalHarness, page) -> None:
    """Opening a file in a chat keeps the right sidebar (and hides the composer).

    The user clicks a file IN the right-sidebar Explorer; before the fix
    that sidebar (and the chat under it) was replaced by a full-surface
    overlay. Driven against the real production bundle.
    """
    h = prod_harness
    cwd = _make_cwd(h, "code-viewer-sidebar")
    ws_id = _create_workspace_with_agent(h, cwd)
    session_id = _create_session(h, cwd)
    errors = _collect_errors(page)

    try:
        # Standalone chat in this workspace, Explorer panel preselected.
        query = urlencode({"session": session_id, "sidebar": "explorer"})
        _goto(page, f"http://127.0.0.1:{h.port}/app/{ws_id}/chat/{session_id}?{query}")
        # Ready-gate on the chat's messages container, not on the empty-state
        # greeting. That greeting only renders while a session has no
        # messages, so it is a sentinel that can simply never appear — which
        # is why this test intermittently timed out on both Linux and macOS.
        # The messages container mounts with the chatview in both the empty
        # and the populated case (an empty session renders the empty state
        # without a virtual scroller), so it is the state this test needs
        # before it opens the sidebar.
        page.wait_for_selector(".messages-scroll-hide-native", timeout=30000)
        _open_sidebar(page)
        page.locator('[data-testid="chat-right-sidebar"]').wait_for(
            timeout=15000, state="visible"
        )

        # The user's gesture: open a file. This is the URL
        # `useCodeEditorSession.syncUrl` actually writes from inside a
        # chat — the chat path is KEPT and only the editor keys are
        # merged, with no `cwd` (it resolves from the chat context).
        # Navigating there directly is the same object graph the
        # Explorer's own click produces: same session, same viewer,
        # same sidebar.
        _goto(page, _app_url(h, cwd, session_id=session_id, workspace_id=ws_id))

        _assert_chat_layout_with_viewer(page)
        _assert_no_module_resolution_error(errors)
    finally:
        _print_errors(errors, page)
