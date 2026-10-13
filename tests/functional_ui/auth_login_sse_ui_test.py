"""UI test: login → /app redirect leaves SSE connected (no manual refresh).

Regression for the production report: after signing in at /login and
landing on /app, the SSE status badge showed "Connection lost" until
a manual page refresh. Refresh masked it because a fresh page load
re-opens every stream with the session cookie already present.

The test replays the exact user flow in headless Chromium against an
isolated backend (booted with `--auth`) + Vite dev server:

  1. Visit /app unauthenticated → expect bounce to /login?redirect=.
  2. Fill the login form, submit → expect landing on /app.
  3. Observe for a few seconds: collect every /api/events response
     status, console errors, and the SSE badge text.
  4. Assert at least one /api/events 200 arrived and no
     "Connection lost" badge is visible — WITHOUT any reload.

Run:
    PABRIK_BIN=./zig-out/bin/pabrik pytest tests/functional_ui/auth_login_sse_ui_test.py -v
"""

from __future__ import annotations

import os
import subprocess
from pathlib import Path

import pytest

from ui_harness import UIHarness

EMAIL = "uitest@example.com"
PASSWORD = "supersecret123"


def _boot_auth_ui(default_pabrik_bin: Path) -> UIHarness:
    return UIHarness.boot(default_pabrik_bin, extra_args=("--auth",))


def _create_admin(bin_path: Path, home: Path) -> None:
    """Run `pabrik create-admin` against the harness's isolated HOME.

    Every variable the harness shadows for the SERVER has to be
    shadowed here too, or this subprocess lands somewhere else. On
    Windows ``Config.zig getDefaultConfigDir`` reads ``%APPDATA%``, not
    ``$HOME`` — shadowing only ``HOME`` left ``create-admin`` writing its
    admin row into the runner's real profile while the test went on to
    assert against the tempdir's database.

    Mirrors the block in ``FunctionalHarness.boot``: ``HOME`` always,
    ``USERPROFILE``/``APPDATA``/``LOCALAPPDATA`` on Windows, XDG
    everywhere (Linux ``XDG_CONFIG_HOME`` beats ``$HOME/.config``).
    """
    env = dict(os.environ)
    env["HOME"] = str(home)
    if os.name == "nt":
        env["USERPROFILE"] = str(home)
        env["APPDATA"] = str(home / "AppData" / "Roaming")
        env["LOCALAPPDATA"] = str(home / "AppData" / "Local")
    env["XDG_CONFIG_HOME"] = str(home / ".config")
    env["XDG_STATE_HOME"] = str(home / ".local" / "state")
    env["XDG_DATA_HOME"] = str(home / ".local" / "share")
    env["XDG_CACHE_HOME"] = str(home / ".cache")
    r = subprocess.run(
        [str(bin_path), "create-admin", "--email", EMAIL, "--password", PASSWORD],
        capture_output=True,
        text=True,
        env=env,
        timeout=30,
    )
    assert r.returncode == 0, f"create-admin failed: {r.stderr[-2000:]}"


def test_login_redirect_keeps_sse_connected(
    default_pabrik_bin: Path, browser, tmp_path_factory
) -> None:
    h = _boot_auth_ui(default_pabrik_bin)
    try:
        _create_admin(default_pabrik_bin, h.temp_dir)

        context = browser.new_context(viewport={"width": 1280, "height": 800})
        page = context.new_page()
        try:
            events_statuses: list[int] = []
            console_errors: list[str] = []

            page.on(
                "response",
                lambda r: events_statuses.append(r.status)
                if "/api/events" in r.url
                else None,
            )
            page.on(
                "console",
                lambda m: console_errors.append(m.text)
                if m.type == "error"
                else None,
            )
            page.on(
                "pageerror",
                lambda e: console_errors.append(str(e)),
            )

            # 1. Deep-link /app while logged out → must bounce to /login.
            #
            # 60s, not the usual 30s: this is the FIRST page load and, on a
            # cold Vite transform cache, it pulls the whole module graph
            # (~800 requests — measured with a request listener on a Windows
            # box). With a warm cache it is ~5s; cold it exceeded 30s and the
            # test failed on `Page.goto: Timeout 30000ms exceeded` rather
            # than on anything it exists to assert. The redirect itself is
            # client-side, so a generous ceiling here costs nothing when the
            # cache is warm.
            page.goto(h.web_url("/app"), wait_until="domcontentloaded", timeout=60000)
            page.wait_for_url("**/login**", timeout=15000)

            # 1b. Force the production race: the global SSE bus connects
            # at app boot (App.vue) — possibly BEFORE login, while the
            # session is still anonymous. The backend answers the SSE
            # handshake with 200 headers and then terminates the stream
            # with `event: auth_error` (headers are already sent, so no
            # 401 status ever reaches the wire — the browser records a
            # 200). A first-attempt failure is terminal ('failed') by
            # design. Wait until that pre-login death is observed so the
            # test reproduces the reported state instead of racing past
            # it (leader election takes ~3s+).
            saw_pre_login_death = False
            for _ in range(50):
                if any("failed permanently" in e for e in console_errors):
                    saw_pre_login_death = True
                    break
                page.wait_for_timeout(500)
            assert saw_pre_login_death, (
                "pre-login SSE death never observed; the bus may not "
                f"have connected yet (console: {console_errors[:5]})"
            )
            events_statuses.clear()
            console_errors.clear()

            # 2. Sign in through the real form.
            page.get_by_placeholder("you@example.com").fill(EMAIL)
            page.get_by_placeholder("••••••••").fill(PASSWORD)
            page.get_by_role("button", name="Sign in").click()
            page.wait_for_url("**/app**", timeout=15000)

            # 3. Let streams settle: initial connect + at least one retry
            #    window if the first attempt raced the cookie.
            page.wait_for_timeout(8000)

            sse_errors = [e for e in console_errors if "sse" in e.lower() or "eventsource" in e.lower()]
            badge_gone = page.get_by_text("Connection lost").count() == 0

            assert events_statuses, (
                "browser never requested /api/events after login; "
                f"console errors: {console_errors[:5]}"
            )
            assert 200 in events_statuses, (
                f"no /api/events 200 after login (statuses: {events_statuses}); "
                f"SSE console errors: {sse_errors[:5]}; "
                f"all console errors: {console_errors[:8]}"
            )
            assert badge_gone, (
                "SSE badge shows 'Connection lost' after login redirect; "
                f"events statuses: {events_statuses}; errors: {sse_errors[:5]}"
            )
        finally:
            page.close()
            context.close()
    finally:
        h.teardown()
