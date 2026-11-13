"""Shared pytest fixtures for the functional UI test suites.

Mirrors the structure of ``tests/functional/conftest.py`` but adds
Playwright fixtures on top of the ``UIHarness`` lifecycle.

The fixtures:

* ``default_pabrik_bin`` (session-scoped) — resolves the path to a
  built ``pabrik`` binary from ``$PABRIK_BIN`` or known zig-out paths.
  Reuses the same resolution logic as the parent ``functional/`` suite.

* ``pinned_backend_port`` (session-scoped) — the one backend port this
  pytest worker uses for every test. Pinning it is what lets a single
  Vite dev server serve the whole worker: ``vite.config.ts`` reads its
  proxy target once, at config load.

* ``vite_server`` (session-scoped) — ONE Vite dev server per worker,
  booted once and torn down once. Vite compiles its module graph
  lazily, so a per-test server paid the whole compile on every test's
  first ``page.goto`` (4.16 s cold vs 0.91 s warm, measured).

* ``ui_harness`` (function-scoped) — boots a fresh pabrik backend per
  test against an isolated tmpdir HOME, on the pinned port, proxied by
  the shared Vite server. Teardown runs even when the test
  asserts-fail (the ``try/finally`` block is the second line of
  defense; the first is ``is_safe_tmp`` inside
  ``FunctionalHarness.teardown``).

* ``browser`` (session-scoped) — a single Playwright Chromium browser
  shared across tests for boot speed. Each test gets its own
  ``browser_context`` so cookies/cache don't leak between tests.

* ``page`` (function-scoped) — a fresh ``Page`` bound to a fresh
  ``browser_context`` per test. Auto-records a screenshot on test
  failure to ``tests/functional_ui/artifacts/<test_name>/<timestamp>.png``.

* ``artifacts_dir`` (function-scoped) — a per-test directory for
  screenshots and other on-disk artifacts. Created under
  ``tests/functional_ui/artifacts/<test_name>`` and NOT auto-cleaned
  (debug aids, kept across runs).

⛔  Isolation: the harness's tmpdir is rmtree'd by the parent's
teardown. The artifacts dir is a separate, non-harness directory under
``tests/functional_ui/artifacts`` that survives the test run.
"""

from __future__ import annotations

import os
import time
from datetime import datetime, timezone
from pathlib import Path
from typing import Iterator

import pytest

from harness import _reap_orphan_test_pids, find_free_port_random
from ui_harness import UIHarness, ViteServer, FunctionalHarnessError
from platform_gates import apply_runtime_gates, collect_ignore_for

collect_ignore = collect_ignore_for()


def pytest_configure(config: pytest.Config) -> None:
    """Register custom marks so PytestUnknownMarkWarning stays quiet.

    ``no_sse_gate`` is applied to tests that need the SSE emit endpoint
    left disabled (e.g. the gate-off contract test). It's a private mark
    used by the autouse fixture in chatview_sse_stick_ui_test.py to
    decide whether to arm PABRIK_TEST_SSE_EMIT=1.
    """
    config.addinivalue_line(
        "markers",
        "no_sse_gate: skip arming PABRIK_TEST_SSE_EMIT=1 for this test",
    )


def pytest_collection_modifyitems(config: pytest.Config, items: list[pytest.Item]) -> None:
    """Apply the runtime (skip-marker) half of the platform-gate table.

    Delegated to ``platform_gates`` rather than inlined: the hook body is
    the same for both suites, and a copy that has to be kept in agreement
    in two places is a copy that will drift. See
    ``apply_runtime_gates`` for why items are marked rather than ignored.
    """
    apply_runtime_gates(items)


def pytest_sessionfinish(session: pytest.Session, exitstatus: int) -> None:
    """Reap children left behind by a previous run that was killed.

    A SIGKILLed pytest never reaches fixture teardown, so its Vite and
    pabrik children survive in their own process groups. They keep
    burning CPU and holding ports, which is what turned a 4.5 s/test
    suite into a 37 s/test one on this host. The pidfile each harness
    writes is the only handle that outlives the kill.
    """
    try:
        _reap_orphan_test_pids()
    except Exception:
        pass


# ─── Session-scoped: resolve the pabrik binary once ──────────────────────────


def _resolve_pabrik_bin() -> Path:
    """Find the pabrik binary in standard locations.

    Same resolution order as ``tests/functional/conftest.py``:
      1. ``$PABRIK_BIN`` env var (used by CI)
      2. ``./zig-out/bin/pabrik`` (after ``zig build install:linux:system``)
      3. ``./zig-out/bin/pabrikcore-linux-x86_64``
      4. ``./zig-out/bin/pabrikcore-macos-aarch64``
      5. ``./zig-out/bin/pabrikcore-macos-x86_64``
    """
    candidates: list[Path] = []
    env_bin = os.environ.get("PABRIK_BIN")
    if env_bin:
        candidates.append(Path(env_bin))
    candidates.extend([
        Path("./zig-out/bin/pabrik"),
        Path("./zig-out/bin/pabrik.exe"),
        Path("./zig-out/bin/pabrikcore-linux-x86_64"),
        Path("./zig-out/bin/pabrikcore-macos-aarch64"),
        Path("./zig-out/bin/pabrikcore-macos-x86_64"),
        Path("./zig-out/bin/pabrikcore-windows-x86_64"),
        Path("./zig-out/bin/pabrikcore-windows-x86_64.exe"),
    ])
    for c in candidates:
        if c.exists() and os.access(c, os.X_OK):
            return c.resolve()
    raise FileNotFoundError(
        "No pabrik binary found. Set PABRIK_BIN or run "
        "`zig build install:linux:system` first."
    )


@pytest.fixture(scope="session")
def default_pabrik_bin() -> Path:
    """Session-scoped: the pabrik binary path. Skips the test if missing."""
    try:
        return _resolve_pabrik_bin()
    except FileNotFoundError as e:
        pytest.skip(str(e))


# ─── Session-scoped: one backend port + one Vite server per worker ──────────


@pytest.fixture(scope="session")
def pinned_backend_port() -> int:
    """Session-scoped: the backend port every test in this worker binds.

    Drawn once from the harness's random range, which is partitioned per
    pytest-xdist worker (see ``harness._xdist_port_slot``), so two
    workers never draw from the same window.
    """
    return find_free_port_random()


@pytest.fixture(scope="session")
def vite_server(pinned_backend_port: int, default_pabrik_bin: Path) -> Iterator[ViteServer]:
    """Session-scoped: ONE Vite dev server, proxying to the pinned port.

    Booted once per worker. Its ``/api`` proxy target is fixed at
    process start, which is why ``ui_harness`` always binds the pinned
    port rather than drawing a new one per test.
    """
    server = ViteServer.boot(pinned_backend_port)
    try:
        yield server
    finally:
        server.teardown()


# ─── Worker-scoped: make the shared Vite server actually ready ──────────────

#: Document identity marker the warm-up installs on every document it loads.
#: A full page reload replaces the document, so a changed marker is how the
#: warm-up sees that the dev server reloaded the client under it.
_BOOT_MARKER_SCRIPT = "window.__pabrikWarmUpDocument = Math.random()"

#: Budget for EACH warm-up phase (the first navigation, the mount wait, and the
#: reload loop's deadline). The first browser load of a shard pays the dev
#: server's whole module-graph compile, which is far more than any single
#: test's own budget.
WARM_UP_TIMEOUT_S = 180.0

#: How long the document must stay put before the warm-up trusts it. It has to
#: outlast the gap between Vite's optimizer passes, which run seconds apart; a
#: reload inside the window restarts it, so the only failure mode is a pass that
#: lands after the window closes. Sizing it comfortably above that gap is worth
#: the wait — it is paid once per worker.
WARM_UP_QUIET_S = 10.0


def _warm_vite_module_graph(browser, vite_server: ViteServer) -> None:
    """Load the app once, and wait until the dev server stops reloading it.

    ``ViteServer.boot`` only waits for a 200 on ``/``. Vite transforms on
    demand, and on a cold ``node_modules`` — every CI job — its dependency
    optimizer re-bundles seconds after that answer and FULL-RELOADS every
    connected client on each pass. So the first test to drive a browser races a
    reload it did not cause, while the tests after it inherit an optimizer that
    has already settled: a failure that depends only on which test is first is
    a harness precondition, not a product bug.

    Paying the compile and absorbing the reloads here, once per worker, in a
    throwaway context, is what turns "the server answers" into "the server is
    ready". The context is its own so the IndexedDB chat/session cache a boot
    writes cannot reach a test's.
    """
    context = browser.new_context(viewport={"width": 1280, "height": 800})
    try:
        page = context.new_page()
        page.add_init_script(_BOOT_MARKER_SCRIPT)
        page.goto(
            vite_server.url("/app"),
            wait_until="domcontentloaded",
            timeout=WARM_UP_TIMEOUT_S * 1000,
        )
        page.wait_for_function(
            "() => { const app = document.getElementById('app');"
            " return !!app && app.children.length > 0; }",
            timeout=WARM_UP_TIMEOUT_S * 1000,
        )
        deadline = time.monotonic() + WARM_UP_TIMEOUT_S
        while True:
            marker = page.evaluate("() => window.__pabrikWarmUpDocument")
            page.wait_for_timeout(WARM_UP_QUIET_S * 1000)
            if page.evaluate("() => window.__pabrikWarmUpDocument") == marker:
                return
            if time.monotonic() > deadline:
                raise FunctionalHarnessError(
                    "the shared Vite dev server reloaded the app on every load for "
                    f"{WARM_UP_TIMEOUT_S:.0f}s, so no test could act on a document "
                    "that stays put. Its log is at "
                    f"{vite_server.log_path}."
                )
    finally:
        context.close()


#: Set by the first browser test of the worker; every later one skips the
#: warm-up. Module-level, so it is per worker the same way ``vite_server`` is.
_vite_warmed = False


def _warm_once(request: pytest.FixtureRequest, vite_server: ViteServer) -> None:
    """Warm the shared dev server, the first time a test brings a browser.

    ``request.fixturenames`` is what says a browser is coming, so the wire-only
    tests that use ``ui_harness`` without a ``page`` still boot nothing but the
    backend. ``code_editor_viewer_ui_test`` serves the app from ``vite build``
    output through ``prod_harness`` and never reaches this fixture at all.
    """
    global _vite_warmed
    if _vite_warmed or "page" not in request.fixturenames:
        return
    _vite_warmed = True
    _warm_vite_module_graph(request.getfixturevalue("browser"), vite_server)


# ─── Function-scoped: a fresh backend per test ─────────────────────────────


@pytest.fixture
def ui_harness(
    default_pabrik_bin: Path, vite_server: ViteServer, request: pytest.FixtureRequest
) -> Iterator[UIHarness]:
    """Function-scoped: a fresh pabrik per test, isolated tmpdir HOME.

    The backend binds the worker's pinned port so the shared Vite
    server's proxy target stays valid. The ``try/finally`` ensures
    teardown runs even when the test asserts-fail mid-execution. The
    harness's teardown itself calls ``is_safe_tmp`` and refuses to
    rmtree an unsafe path.

    The first test that drives a browser also warms the dev server, after
    this backend is up so the app boots against a live ``/api`` (see
    ``_warm_vite_module_graph``).
    """
    h = UIHarness.boot(default_pabrik_bin, vite=vite_server)
    try:
        _warm_once(request, vite_server)
        yield h
    finally:
        try:
            h.teardown()
        except FunctionalHarnessError as e:
            pytest.fail(f"ui_harness teardown refused: {e}", pytrace=False)


# ─── Session-scoped: a single Playwright Chromium browser ───────────────────


@pytest.fixture(scope="session")
def browser(default_pabrik_bin: Path):  # noqa: ARG001 — implicit dep so we skip if no pabrik
    """Session-scoped Playwright Chromium browser.

    Reused across tests for boot speed (~2s amortised). Each test
    gets its own ``browser_context`` (see the ``page`` fixture below)
    so cookies, cache, and IndexedDB don't bleed between tests.

    Skips the test session if Playwright isn't installed or the
    Chromium binary isn't available. See README.md for the one-time
    setup: ``pip install playwright && playwright install chromium``.
    """
    pytest.importorskip("playwright")
    try:
        from playwright.sync_api import sync_playwright
    except ImportError:
        pytest.skip("playwright Python package not installed")

    with sync_playwright() as p:
        try:
            browser_instance = p.chromium.launch(headless=True)
        except Exception as e:
            msg = str(e).lower()
            if "executable" in msg or "chromium" in msg or "browser" in msg:
                pytest.skip(
                    f"Playwright Chromium not installed: {e}. "
                    f"Run `playwright install chromium` first."
                )
            raise
        try:
            yield browser_instance
        finally:
            browser_instance.close()


# ─── Function-scoped: a fresh page per test ────────────────────────────────


@pytest.fixture
def page(browser, request: pytest.FixtureRequest):
    """Function-scoped: a fresh browser context + page per test.

    Each test gets a NEW ``browser.new_context()`` so cookies, cache,
    and IndexedDB are isolated. The page's viewport is set to a
    realistic desktop size (1280x800).

    Auto-records a screenshot on test failure to
    ``tests/functional_ui/artifacts/<test_name>/<timestamp>.png``.
    Screenshots are a debugging aid — they survive the test run.
    """
    context = browser.new_context(viewport={"width": 1280, "height": 800})
    page_instance = context.new_page()
    try:
        yield page_instance
    finally:
        outcome = getattr(request, "_outcome", None)
        if outcome is not None and outcome.errors:
            artifacts_root = Path(__file__).parent / "artifacts"
            artifacts_root.mkdir(parents=True, exist_ok=True)
            test_dir = artifacts_root / request.node.name
            test_dir.mkdir(parents=True, exist_ok=True)
            timestamp = datetime.now(timezone.utc).strftime("%Y%m%dT%H%M%S")
            screenshot_path = test_dir / f"{timestamp}.png"
            try:
                page_instance.screenshot(path=str(screenshot_path), full_page=True)
            except Exception:
                pass
        context.close()


# ─── Function-scoped: a per-test artifacts dir (test-controlled) ───────────


@pytest.fixture
def artifacts_dir(request: pytest.FixtureRequest) -> Path:
    """Function-scoped: ``tests/functional_ui/artifacts/<test_name>/``.

    Tests can use this to write intermediate files (downloaded
    artifacts, CSV exports, etc.) without polluting the harness's
    tmpdir. Survives the test run by design — these are debug aids.
    """
    artifacts_root = Path(__file__).parent / "artifacts"
    test_dir = artifacts_root / request.node.name
    test_dir.mkdir(parents=True, exist_ok=True)
    return test_dir


# ─── Optional: pyvirtualdisplay for X11-less CI environments ────────────────


@pytest.fixture(scope="session")
def virtual_display():
    """No-op fixture. Reserved for future tests that need Xvfb."""
    return None
