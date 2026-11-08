"""Functional UI test: switching Chat view to Compact actually saves.

Regression for task_1794127880460_1 ("change to compact mode its error").
The stored config carried a `tools` list whose first entry was `ask_user` — a
name the registry stopped carrying when the ask_user TOOL became a message
block. The settings editor hydrates that list from GET and replays it on every
save, so the PUT rejected the whole document with
`InvalidToolName: 'ask_user' is not in the unified tool registry` and the Chat
view toggle could never be persisted.

The wire-level tests in `tests/functional/config_tools_test.zig` pin the
endpoint. This one pins what the user reported: the click, and the value still
being there after a reload.
"""

from __future__ import annotations

import json
import sys

from ui_harness import UIHarness

STALE_TOOL = "ask_user"
LIVE_TOOLS = ["command", "glob"]


def _config_dir(h: UIHarness):
    """The OS-correct config dir the backend reads (Config.getDefaultConfigDir)."""
    if sys.platform == "darwin":
        return h.temp_dir / "Library" / "Application Support" / "pabrik"
    if sys.platform == "win32":
        return h.temp_dir / "AppData" / "Roaming" / "pabrik"
    return h.temp_dir / ".config" / "pabrik"


def _seed_config(h: UIHarness, tools: list[str], chat_view: str) -> None:
    directory = _config_dir(h)
    directory.mkdir(parents=True, exist_ok=True)
    (directory / "config.json").write_text(
        json.dumps(
            {"tools": tools, "chat_view": chat_view, "notify_on_complete": True}, indent=2
        )
    )


def _read_config(h: UIHarness) -> dict:
    return json.loads((_config_dir(h) / "config.json").read_text())


def _save_status(page) -> str:
    el = page.locator('[data-testid="save-status-text"]')
    return el.inner_text() if el.count() > 0 else ""


def test_switching_chat_view_to_compact_saves_despite_a_stale_stored_tool_name(
    ui_harness: UIHarness, page
) -> None:
    h = ui_harness
    _seed_config(h, [STALE_TOOL, *LIVE_TOOLS], "dev")

    page.goto(h.web_url("/app/settings"), wait_until="domcontentloaded", timeout=60000)
    page.wait_for_selector('[data-testid="chat-view-compact"]', timeout=30000)
    page.wait_for_function(
        "() => {"
        "  const el = document.querySelector('[data-testid=\"toggle-notify-on-complete\"]');"
        "  return !!el && el.checked;"
        "}",
        timeout=30000,
    )
    assert page.get_attribute('[data-testid="chat-view-dev"]', "aria-checked") == "true", (
        "the seeded chat_view=dev did not hydrate into the toggle"
    )

    page.click('[data-testid="chat-view-compact"]')

    page.wait_for_function(
        "() => {"
        "  const el = document.querySelector('[data-testid=\"save-status-text\"]');"
        "  if (!el) return false;"
        "  const text = el.textContent.trim();"
        "  return text === 'Saved' || text.startsWith(\"Couldn't save\");"
        "}",
        timeout=20000,
    )
    status = _save_status(page)
    assert status == "Saved", f"the save did not succeed: {status!r}"

    assert page.get_attribute('[data-testid="chat-view-compact"]', "aria-checked") == "true"

    on_disk = _read_config(h)
    assert on_disk.get("chat_view") == "compact", on_disk
    assert on_disk.get("tools") == LIVE_TOOLS, (
        f"the stale tool name was not dropped from the stored list: {on_disk.get('tools')!r}"
    )

    page.reload(wait_until="domcontentloaded")
    page.wait_for_selector('[data-testid="chat-view-compact"]', timeout=30000)
    assert page.get_attribute('[data-testid="chat-view-compact"]', "aria-checked") == "true", (
        "compact did not survive the reload"
    )

    body = h.http("GET", "/api/config/pabrik", expect=200).json()
    assert body.get("chat_view") == "compact", body.get("chat_view")
    assert body.get("tools") == LIVE_TOOLS, body.get("tools")
