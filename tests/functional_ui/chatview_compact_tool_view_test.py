"""The compact chat view: one line per tool call, carrying the tool and its argument.

The bug this guards: the compact view drew a run of ONE call as a group card
that said "1 tool calls" and carried neither the tool nor its argument, so the
compact view said LESS than the dev view. A chat that fires one tool per turn
groups every call on its own, so EVERY row read "1 tool calls".

Each test:
1. Boots a fresh pabrik + Vite (the ``ui_harness`` fixture).
2. Writes a config.json — with ``chat_view: "compact"`` for the compact view,
   without it for the dev view. The backend reads config.json fresh per
   request, so a post-boot write is picked up.
3. Seeds ``sessions`` + ``llm_history`` rows: one assistant turn and one tool
   result per call, each tool result carrying the JSON envelope the backend
   writes (tool, parameters, success, data, error, duration_ms).
4. Drives headless Chromium at the chat deep link and asserts what the chat
   SHOWS — the tool, the argument, and no "1 tool calls" group card.
"""

from __future__ import annotations

import json
import sys
from pathlib import Path

from chatview_boot import (
    bind_session_workspace,
    create_workspace,
    open_chatview,
)
from db_seed import DbSeed
from ui_harness import UIHarness


def _seed_db_path(h: UIHarness) -> Path:
    return h.temp_dir / ".config" / "pabrik" / "agent.db"


def _config_dir(h: UIHarness) -> Path:
    """The backend's per-OS config dir (Config.zig getDefaultConfigDir)."""
    if sys.platform == "darwin":
        return h.temp_dir / "Library" / "Application Support" / "pabrik"
    if sys.platform == "win32":
        return h.temp_dir / "AppData" / "Roaming" / "pabrik"
    return h.temp_dir / ".config" / "pabrik"


def _write_config(h: UIHarness, chat_view: str | None) -> None:
    """Write a config.json with (or without) the chat view mode."""
    config_dir = _config_dir(h)
    config_dir.mkdir(parents=True, exist_ok=True)
    body: dict[str, object] = {
        "api_key": "stub-not-real",
        "model": "stub-model",
        "base_url": "http://127.0.0.1:1",
    }
    if chat_view is not None:
        body["chat_view"] = chat_view
    (config_dir / "config.json").write_text(json.dumps(body), encoding="utf-8")


# The calls the chat shows, each in its own turn: the agent fired one tool per
# turn, so every tool row is a group of one.
CALLS = [
    ("read_file", {"path": "/tmp/alpha.ts"}),
    ("command", {"command": "ls -la"}),
    ("search", {"pattern": "needle"}),
]


def _seed_transcript(h: UIHarness, workspace_id: str, session_id: str) -> None:
    """Seed one assistant turn and one tool result per call."""
    seed = DbSeed(_seed_db_path(h))
    with seed.connect() as conn:
        seed.seed_session(conn, session_id, "Compact View", cwd=str(h.temp_dir))
        bind_session_workspace(conn, workspace_id, session_id)
        seed.seed_user_message(conn, session_id, text="read the file")
        for index, (tool, parameters) in enumerate(CALLS):
            call_id = f"tc_{tool}_{index}"
            seed.seed_assistant_message(
                conn,
                session_id,
                text="",
                finish_reason="tool_calls",
                tool_calls=[
                    {
                        "id": call_id,
                        "type": "function",
                        "function": {"name": tool, "arguments": json.dumps(parameters)},
                    }
                ],
            )
            envelope = {
                "tool": tool,
                "parameters": parameters,
                "success": True,
                "data": {},
                "error": None,
                "v": 1,
                "duration_ms": 1200 * (index + 1),
            }
            seed.seed_tool_result(
                conn,
                session_id,
                tool_call_id=call_id,
                tool_name=tool,
                content=json.dumps(envelope),
            )


def test_compact_view_draws_one_row_per_call_with_the_tool_and_its_argument(
    ui_harness: UIHarness, page,
) -> None:
    """The compact view shows the tool and its argument, not "1 tool calls"."""
    h = ui_harness
    session_id = "sess_compact_view_rows_001"
    workspace_id = create_workspace(h)
    _write_config(h, "compact")
    _seed_transcript(h, workspace_id, session_id)

    open_chatview(page, h, workspace_id, session_id)
    page.locator('[data-testid="compact-tool-row"]').first.wait_for(timeout=20000)

    rows = page.locator('[data-testid="compact-tool-row"]')
    assert rows.count() == len(CALLS), (
        f"the compact view must draw one row per call: expected {len(CALLS)}, "
        f"got {rows.count()}"
    )

    names = page.locator('[data-testid="compact-tool-row-name"]').all_text_contents()
    assert names == [tool for tool, _ in CALLS], (
        f"each row must name its tool, got {names}"
    )

    primaries = page.locator('[data-testid="compact-tool-row-primary"]').all_text_contents()
    expected = ["/tmp/alpha.ts", "ls -la", "needle"]
    assert primaries == expected, (
        f"each row must show the argument that identifies the call, got {primaries}"
    )

    body = page.locator(".tool-sequence").first.inner_text()
    assert "tool calls" not in body, (
        f"a run of one call must not be drawn as a group card, got {body!r}"
    )


def test_compact_view_expands_a_row_into_the_full_card(
    ui_harness: UIHarness, page,
) -> None:
    """The `+` on a row opens the dev card for that call."""
    h = ui_harness
    session_id = "sess_compact_view_expand_001"
    workspace_id = create_workspace(h)
    _write_config(h, "compact")
    _seed_transcript(h, workspace_id, session_id)

    open_chatview(page, h, workspace_id, session_id)
    page.locator('[data-testid="compact-tool-row"]').first.wait_for(timeout=20000)

    assert page.locator(".chat-tool-card").count() == 0, (
        "the compact view must not draw the dev cards while it is folded"
    )

    page.locator('[data-testid="compact-tool-row-expand"]').first.click()
    page.locator(".chat-tool-card").first.wait_for(timeout=10000)

    assert page.locator(".chat-tool-card").count() == 1, (
        "the `+` on a row must open the dev card for that one call"
    )


def test_dev_view_still_draws_the_cards(
    ui_harness: UIHarness, page,
) -> None:
    """Without the setting, the chat keeps drawing the dev cards."""
    h = ui_harness
    session_id = "sess_dev_view_cards_001"
    workspace_id = create_workspace(h)
    _write_config(h, None)
    _seed_transcript(h, workspace_id, session_id)

    open_chatview(page, h, workspace_id, session_id)
    page.locator(".chat-tool-card").first.wait_for(timeout=20000)

    assert page.locator(".chat-tool-card").count() == len(CALLS), (
        "the dev view must keep one card per call"
    )
    assert page.locator('[data-testid="compact-tool-row"]').count() == 0, (
        "the dev view must not draw the compact rows"
    )
