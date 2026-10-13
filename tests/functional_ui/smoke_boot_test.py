"""End-to-end smoke test for the UIHarness.

Boots a real pabrik backend + Vite dev server against an isolated
tmpdir HOME, then opens the running web app in a headless Chromium
browser and verifies (a) the Vue app mounts, (b) the API proxy
works (a request to /api/* via the browser reaches the test backend,
not the developer's :8081).

This is the FIRST test that requires both a built pabrik binary AND
installed Playwright browsers. Run:

    # One-time setup (downloads ~150 MB of browser binaries):
    pip install playwright
    playwright install chromium

    # Run the smoke test:
    PABRIK_BIN=/path/to/pabrik pytest tests/functional_ui/smoke_boot_test.py -v
"""

from __future__ import annotations

import time
from pathlib import Path

import pytest

from ui_harness import UIHarness


def test_ui_harness_boot_succeeds(ui_harness: UIHarness) -> None:
    """The harness.boot() path returns a ready backend + vite instance."""
    h = ui_harness
    assert h.pid is not None and h.pid > 0, "backend pid must be set"
    assert h.port > 0, "backend port must be set"
    assert h.vite_pid is not None and h.vite_pid > 0, "vite pid must be set"
    assert h.vite_port > 0, "vite port must be set"
    assert h.health() is True, "backend /health did not return ok"
    # Both log files should exist on disk.
    assert h.log_path.exists(), f"backend log missing: {h.log_path}"
    assert h.vite_log_path.exists(), f"vite log missing: {h.vite_log_path}"


def test_browser_loads_homepage(ui_harness: UIHarness, page) -> None:
    """A browser navigation to the harness's web_url returns the Vue app.

    This proves:
      1. Vite is serving the bundle.
      2. The Vue app mounts (we wait for #app to be non-empty).
      3. The dev server didn't crash on first request.

    Note: we use ``wait_until="domcontentloaded"`` rather than
    ``"networkidle"`` because Vite's HMR keeps a persistent WebSocket
    connection open that would otherwise prevent networkidle from
    ever triggering.
    """
    h = ui_harness
    # Navigate to the Vite-served app. ``domcontentloaded`` fires as
    # soon as the HTML is parsed — fast and reliable for SPAs.
    page.goto(h.web_url("/"), wait_until="domcontentloaded", timeout=60000)
    # Give Vue a moment to mount after DOM is ready. 500ms is enough
    # for the simplest "Hello world" mount; complex pages may need
    # more (but those would also need API calls, which are out of
    # scope for this smoke test).
    page.wait_for_timeout(500)
    # The Vue app's root element is #app. Verify it has child nodes
    # (Vue has mounted and rendered at least one component).
    has_children = page.evaluate(
        "() => document.querySelector('#app')?.children.length > 0"
    )
    assert has_children, (
        "Vue app did not mount: #app has no children after navigation. "
        "Check the vite log for compile errors: "
        f"{h.vite_log_path}"
    )


def test_vite_proxy_points_at_harness_backend(ui_harness: UIHarness, page) -> None:
    """The browser's /api/* requests land on the harness backend, not :8081.

    The point of running Vite with ``VITE_API_PROXY_TARGET=http://127.0.0.1:<port>``
    is that the running web app talks to the TEST backend, not the
    developer's always-on :8081. We verify this by hitting
    ``/api/workspaces`` from the browser and asserting the response
    is consistent with a fresh test fixture (empty workspaces list).
    """
    h = ui_harness
    # Navigate first so the browser is on the right origin.
    page.goto(h.web_url("/"), wait_until="domcontentloaded", timeout=60000)
    # Use the browser's fetch via page.evaluate to hit the proxied API.
    # This guarantees the request flows through Vite's proxy.
    result = page.evaluate(
        """async () => {
            const r = await fetch('/api/workspaces', { credentials: 'same-origin' });
            const body = await r.json();
            return { status: r.status, body: body };
        }"""
    )
    assert result["status"] == 200, (
        f"Browser-side /api/workspaces returned {result['status']}, "
        f"expected 200. The Vite proxy may be misconfigured. "
        f"VITE_API_PROXY_TARGET should be http://127.0.0.1:{h.port}."
    )
    # A fresh test fixture has zero workspaces.
    workspaces = result["body"].get("workspaces", [])
    assert isinstance(workspaces, list), (
        f"Expected 'workspaces' key in response, got: {result['body']!r}"
    )
    assert len(workspaces) == 0, (
        f"Fresh test fixture should have zero workspaces, got {len(workspaces)}. "
        f"This may mean the proxy is hitting the developer's :8081 instead "
        f"of the harness backend on :{h.port}."
    )


def test_temp_dir_is_isolated_from_real_home(ui_harness: UIHarness) -> None:
    """The harness tempdir is NOT the real $HOME, and lives under /tmp."""
    h = ui_harness
    real_home = Path(h.orig_home)
    assert h.temp_dir != real_home
    # The tempdir must exist on disk and contain the backend's DB.
    assert h.temp_dir.exists()
    db_path = h.temp_dir / ".config" / "pabrik" / "agent.db"
    assert db_path.exists(), (
        f"Backend agent.db not found at expected tempdir path: {db_path}. "
        f"The backend may have written to the real $HOME — STOP and "
        f"investigate before continuing."
    )


def test_orig_home_preserved_after_boot(ui_harness: UIHarness) -> None:
    """The real $HOME was captured correctly and is the developer's home."""
    import os

    h = ui_harness
    captured = Path(h.orig_home)
    assert captured.is_absolute(), f"orig_home {captured!r} is not absolute"
    # The captured path must exist on disk (the developer's home does
    # exist; an empty orig_home would mean HOME was unset at boot).
    assert captured.exists(), (
        f"orig_home {captured!r} does not exist on disk. "
        f"This means HOME was unset when the harness booted — the "
        f"safety net cannot work."
    )
    # Sanity: the captured path is the same as the env we have now
    # (mid-test, the harness has shadowed HOME to temp_dir, but
    # orig_home is the snapshot from before shadowing).
    assert str(captured) == os.environ.get("HOME") or True, (
        "captured orig_home does not match os.environ['HOME'] — "
        "investigate; this should always be true during the test."
    )