"""Functional UI test: a reload keeps the tabs a session already had open.

The reported bug (kanban task_1794509765044_1, "Refresh do not clear existing
open tab"): a session's strip held the session tab plus four file tabs; after
F5 only the session tab was left.

Root cause, and why the auth half of this file exists: the tab list is stored
under a per-user key (`userScopedKey`), and the identity that key depends on
was only resolved by the router guard's async `/api/auth/me`. The tabs store is
created before that `await` returns, so it READ the unscoped key and then WROTE
the scoped one — the list was saved under a key it was never read from, and
every reload started from an empty list. With auth off the identity is always
null, so read and write agree and the bug is invisible: that is why the
no-auth test below passes on the broken build and the `--auth` one does not.

Run:
    PABRIK_BIN=./zig-out/bin/pabrikcore-linux-x86_64 \\
      /tmp/pabrik/ui-venv/bin/python -m pytest \\
      tests/functional_ui/tabs_refresh_ui_test.py -v -s
"""

from __future__ import annotations

import os
import subprocess
from pathlib import Path
from urllib.parse import urlencode

from harness import FunctionalHarness
from ui_harness import UIHarness

FILE_A = "tabs_refresh_a.ts"
FILE_B = "tabs_refresh_b.ts"

TAB_SELECTOR = '[role="tab"]'

AUTH_EMAIL = "uitest@example.com"
AUTH_PASSWORD = "supersecret123"


def _make_cwd(h: FunctionalHarness, suffix: str) -> Path:
    cwd = Path(h.temp_dir) / suffix
    cwd.mkdir(parents=True, exist_ok=True)
    for name in (FILE_A, FILE_B):
        (cwd / name).write_text(f"export const name = '{name}'\n", encoding="utf-8")
    return cwd


def _create_workspace_with_agent(h: FunctionalHarness, cwd: Path) -> str:
    ws_id = h.http(
        "POST", "/api/workspaces", json_body={"name": "ui-tabs-refresh"}, expect=201
    ).json()["id"]
    h.http(
        "POST",
        f"/api/workspaces/{ws_id}/items/agent",
        json_body={"name": "ui-tabs-refresh-agent", "path": str(cwd)},
        expect=201,
    )
    return ws_id


def _create_session(h: FunctionalHarness, cwd: Path) -> str:
    r = h.http(
        "POST",
        "/api/llm/session",
        json_body={"name": "ui-tabs-refresh-chat", "cwd_session": str(cwd)},
        expect=201,
    )
    return r.json()["id"]


def _chat_url(h: UIHarness, ws_id: str, session_id: str) -> str:
    return h.web_url(f"/app/{ws_id}/chat/{session_id}")


def _file_url(h: UIHarness, ws_id: str, session_id: str, name: str) -> str:
    query = urlencode({"view": "code-editor", "file": name})
    return h.web_url(f"/app/{ws_id}/chat/{session_id}?{query}")


def _tab_titles(page) -> list[str]:
    tabs = page.locator(TAB_SELECTOR)
    return [tabs.nth(i).inner_text().strip() for i in range(tabs.count())]


def _wait_for_tabs(page, count: int) -> None:
    page.wait_for_function(
        "n => document.querySelectorAll('[role=\"tab\"]').length === n",
        arg=count,
        timeout=30000,
    )


def _open_two_files_and_reload(page, h: UIHarness, ws_id: str, session_id: str) -> None:
    """The user's gesture: a chat, two files opened in it, then F5."""
    page.goto(_chat_url(h, ws_id, session_id), wait_until="domcontentloaded", timeout=60000)
    page.wait_for_selector(".messages-scroll-hide-native", timeout=30000)
    _wait_for_tabs(page, 1)

    for name in (FILE_A, FILE_B):
        page.goto(
            _file_url(h, ws_id, session_id, name),
            wait_until="domcontentloaded",
            timeout=60000,
        )
        page.wait_for_selector('[data-testid="code-editor"]', timeout=30000)

    _wait_for_tabs(page, 3)
    before = _tab_titles(page)
    print(f"\n[tabs before reload] {before}")

    page.reload(wait_until="domcontentloaded", timeout=60000)
    page.wait_for_selector('[data-testid="code-editor"]', timeout=30000)
    _wait_for_tabs(page, 3)
    after = _tab_titles(page)
    print(f"[tabs after reload] {after}")
    assert after == before, f"reload changed the strip: {before} -> {after}"


def test_reload_keeps_the_sessions_open_tabs(ui_harness: UIHarness, page) -> None:
    """Auth off: the identity is always null, so read and write already agree."""
    h = ui_harness
    cwd = _make_cwd(h, "tabs-refresh")
    ws_id = _create_workspace_with_agent(h, cwd)
    session_id = _create_session(h, cwd)

    _open_two_files_and_reload(page, h, ws_id, session_id)


def _create_admin(bin_path: Path, home: Path) -> None:
    """`pabrik create-admin` against the harness's isolated HOME."""
    env = dict(os.environ)
    env["HOME"] = str(home)
    env["XDG_CONFIG_HOME"] = str(home / ".config")
    env["XDG_STATE_HOME"] = str(home / ".local" / "state")
    env["XDG_DATA_HOME"] = str(home / ".local" / "share")
    env["XDG_CACHE_HOME"] = str(home / ".cache")
    r = subprocess.run(
        [str(bin_path), "create-admin", "--email", AUTH_EMAIL, "--password", AUTH_PASSWORD],
        capture_output=True,
        text=True,
        env=env,
        timeout=30,
    )
    assert r.returncode == 0, f"create-admin failed: {r.stderr[-2000:]}"


def _api(page, method: str, path: str, body: dict | None = None) -> dict:
    """A same-origin API call carrying the browser's session cookie."""
    return page.evaluate(
        """async ([method, path, body]) => {
            const res = await fetch(path, {
                method,
                credentials: 'same-origin',
                headers: body ? { 'content-type': 'application/json' } : {},
                body: body ? JSON.stringify(body) : undefined,
            })
            return { status: res.status, body: await res.json().catch(() => null) }
        }""",
        [method, path, body],
    )


def test_reload_keeps_the_sessions_open_tabs_with_auth(
    default_pabrik_bin: Path, browser
) -> None:
    """Auth on (the SaaS shape): the tab list lives under a per-user key."""
    h = UIHarness.boot(default_pabrik_bin, extra_args=("--auth",))
    try:
        _create_admin(default_pabrik_bin, h.temp_dir)
        context = browser.new_context(viewport={"width": 1280, "height": 800})
        page = context.new_page()
        try:
            page.goto(h.web_url("/app"), wait_until="domcontentloaded", timeout=60000)
            page.wait_for_url("**/login**", timeout=20000)
            page.get_by_placeholder("you@example.com").fill(AUTH_EMAIL)
            page.get_by_placeholder("••••••••").fill(AUTH_PASSWORD)
            page.get_by_role("button", name="Sign in").click()
            page.wait_for_function(
                "() => !location.pathname.startsWith('/login')", timeout=20000
            )
            page.wait_for_function(
                """async () => {
                    const r = await fetch('/api/auth/me', { credentials: 'same-origin' })
                    const d = await r.json()
                    return d.authenticated === true
                }""",
                timeout=20000,
            )

            cwd = _make_cwd(h, "tabs-refresh-auth")
            ws = _api(page, "POST", "/api/workspaces", {"name": "ui-tabs-refresh-auth"})
            assert ws["status"] == 201, ws
            ws_id = ws["body"]["id"]
            item = _api(
                page,
                "POST",
                f"/api/workspaces/{ws_id}/items/agent",
                {"name": "ui-tabs-refresh-auth-agent", "path": str(cwd)},
            )
            assert item["status"] == 201, item
            sess = _api(
                page,
                "POST",
                "/api/llm/session",
                {"name": "ui-tabs-refresh-auth-chat", "cwd_session": str(cwd)},
            )
            assert sess["status"] == 201, sess

            _open_two_files_and_reload(page, h, ws_id, sess["body"]["id"])
        finally:
            context.close()
    finally:
        h.teardown()
