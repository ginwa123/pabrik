"""New Chat is enabled on a fresh boot with no workspace selected.

Regression for "new chat keep disabled?": the top-left New Chat button
bound `:disabled` to the raw `activeWorkspaceId` ref, which is only set
by the header dropdown or a `?workspaceId=` URL restore. On a fresh boot
(bare `/app`, empty localStorage) the ref stays null while the header
already shows a workspace via the `activeWorkspace` computed — so the
button sat permanently disabled (greyed out, `disabled` attribute set,
title "Select a workspace first").

The fix resolves the button's workspace from the same `activeWorkspace`
computed the header uses
(`Sidebar.vue: newChatWorkspaceId = activeWorkspace?.id`).

What each layer proves:

* `Sidebar.newChat.spec.ts` (vitest) — the handler creates the chat in
  the DEFAULT project and the fresh-boot fallback enables the button.
  Cheap, but jsdom: it cannot prove the button is actually clickable
  in a real browser on a real boot.
* THIS file (Playwright) — opens bare `/app` in a FRESH browser
  context (no clicks, no dropdown, no localStorage) and asserts the
  button becomes enabled, then clicks it and asserts a task-chat URL.
  On the broken code the button never enables, so the wait times out
  and the test fails there.

Run:
    PABRIK_BIN=<worktree>/zig-out/bin/pabrikcore-linux-x86_64 \\
        /home/ginwa/ginwaaitoolbox/.venv-func/bin/python -m pytest -s \\
        tests/functional_ui/sidebar_new_chat_enabled_ui_test.py -v
"""

from __future__ import annotations

import re

from ui_harness import UIHarness

_NEW_CHAT_BUTTON = '[data-testid="sidebar-new-chat-button"]'

# The URL the New Chat click navigates to:
# /app/<workspace>/projects/<default-item>/chat/<new-task>.
_CHAT_URL_RE = re.compile(r"/app/[^/]+/projects/[^/]+/chat/[^/]+")


def _create_workspace(h: UIHarness, name: str) -> str:
    r = h.http("POST", "/api/workspaces", json_body={"name": name}, expect=201)
    return r.json()["id"]


def _goto_fresh_boot(page, h: UIHarness) -> None:
    """Open bare /app: no workspace in the URL, no prior selection.

    The browser context is fresh per test (see the `page` fixture), so
    localStorage carries no persisted workspace either — this is the
    exact state from the bug report.
    """
    page.goto(h.web_url("/app"), wait_until="domcontentloaded", timeout=60000)
    # Cold-start allowance: the first test in a fresh environment pays
    # Vite's first compile + module-graph build before Vue mounts at
    # all, so the shell gets a generous budget. The button wait below
    # stays tight — once the shell is up, the sidebar renders fast.
    page.locator('[data-testid="sidebar-header-expanded"]').wait_for(timeout=60000)
    page.locator(_NEW_CHAT_BUTTON).wait_for(timeout=60000, state="visible")


def _wait_for_new_chat_enabled(page, timeout: int = 20000) -> None:
    """Poll until the button enables.

    An immediate `is_enabled()` would be a race (checked before the
    workspace list lands); the poll waits for the store to resolve the
    fallback workspace. On the broken code the button NEVER enables, so
    this times out there — which is the regression signal.
    """
    page.wait_for_function(
        """() => {
          const b = document.querySelector('[data-testid="sidebar-new-chat-button"]');
          return b && !b.disabled;
        }""",
        timeout=timeout,
    )


def test_new_chat_enabled_on_fresh_boot(ui_harness: UIHarness, page) -> None:
    """The button enables itself once workspaces load — no selection needed."""
    h = ui_harness
    # Two workspaces so "first" is a real fallback choice, not "the only one".
    _create_workspace(h, "ui-new-chat-first-ws")
    _create_workspace(h, "ui-new-chat-second-ws")

    _goto_fresh_boot(page, h)
    _wait_for_new_chat_enabled(page)

    btn = page.locator(_NEW_CHAT_BUTTON)
    assert btn.is_enabled(), (
        "New Chat button is disabled on a fresh boot with workspaces present — "
        "the raw-activeWorkspaceId regression is back"
    )
    assert btn.get_attribute("title") != "Select a workspace first", (
        "button still shows the no-workspace tooltip while workspaces exist"
    )


def test_new_chat_click_creates_chat_from_fresh_boot(ui_harness: UIHarness, page) -> None:
    """Clicking it from a fresh boot opens a task chat in the default project."""
    h = ui_harness
    _create_workspace(h, "ui-new-chat-click-ws")

    _goto_fresh_boot(page, h)
    _wait_for_new_chat_enabled(page)

    page.locator(_NEW_CHAT_BUTTON).click()
    # The click resolves the default project, creates the task, and
    # router.replaces to its chat URL. Predicate form: the task id is
    # generated server-side so it cannot be spelled out in advance.
    page.wait_for_url(
        lambda url: bool(_CHAT_URL_RE.search(url)),
        timeout=60000,
    )
    assert _CHAT_URL_RE.search(page.url), (
        f"New Chat click landed at an unexpected URL: {page.url}"
    )
    # And the chat actually rendered (not just a URL change).
    page.locator('[data-testid="chat-app-bar"]').wait_for(timeout=20000, state="visible")
