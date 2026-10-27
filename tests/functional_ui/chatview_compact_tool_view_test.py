"""The compact chat view: one turn's tool calls, folded into one card.

Two bugs this guards, both seen in the real app:

1. The compact view drew EVERY call as a group card that said "1 tool calls"
   and carried neither the tool nor its argument, so it said LESS than the dev
   view.
2. Nothing ever folded: the chat groups CONSECUTIVE tool rows, and a chat that
   fires one tool per turn has a thinking turn between each call — so every
   group held one call. The fold has to follow the TURN (every call until the
   assistant stops), not the row adjacency.

Each test:
1. Boots a fresh pabrik + Vite (the ``ui_harness`` fixture).
2. Writes a config.json — with ``chat_view: "compact"`` for the compact view,
   without it for the dev view. The backend reads config.json fresh per
   request, so a post-boot write is picked up.
3. Seeds ``sessions`` + ``llm_history`` rows: one thinking turn and one tool
   result per call, then the assistant's stop — so the tool rows are NOT
   adjacent and the thoughts separate them.
4. Drives headless Chromium at the chat deep link and asserts what the chat
   SHOWS.
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


# The calls of ONE agent turn: the agent thinks, calls one tool, thinks, calls
# the next — so in the transcript the tool rows are separated by thoughts and
# never end up in one group.
CALLS = [
    ("read_file", {"path": "/tmp/alpha.ts"}),
    ("command", {"command": "ls -la"}),
    ("search", {"pattern": "needle"}),
]


def _seed_transcript(h: UIHarness, workspace_id: str, session_id: str) -> None:
    """Seed one turn: a thought and a tool result per call, then the stop."""
    seed = DbSeed(_seed_db_path(h))
    with seed.connect() as conn:
        seed.seed_session(conn, session_id, "Compact View", cwd=str(h.temp_dir))
        bind_session_workspace(conn, workspace_id, session_id)
        seed.seed_user_message(conn, session_id, text="read the file and tell me what it draws")
        for index, (tool, parameters) in enumerate(CALLS):
            call_id = f"tc_{tool}_{index}"
            seed.seed_assistant_message(
                conn,
                session_id,
                text="",
                finish_reason="tool_calls",
                reasoning_content=f"Thinking about step {index + 1}",
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
        # The turn ends here: the assistant stops, so every call above is one run.
        seed.seed_assistant_message(conn, session_id, text="Done.", finish_reason="stop")


def test_one_turn_of_calls_folds_into_one_card(ui_harness: UIHarness, page) -> None:
    """The calls of a turn fold into one card, even with thoughts between them."""
    h = ui_harness
    session_id = "sess_compact_view_fold_001"
    workspace_id = create_workspace(h)
    _write_config(h, "compact")
    _seed_transcript(h, workspace_id, session_id)

    open_chatview(page, h, workspace_id, session_id)
    page.locator('[data-testid="compact-tool-group"]').first.wait_for(timeout=20000)

    cards = page.locator('[data-testid="compact-tool-group"]')
    assert cards.count() == 1, (
        f"one turn's calls must fold into ONE card, got {cards.count()} cards"
    )
    count = page.locator('[data-testid="compact-tool-group-count"]').first.inner_text()
    assert count.strip() == f"{len(CALLS)} tool calls", (
        f"the card must count the whole turn, got {count!r}"
    )
    assert page.locator('[data-testid="compact-tool-row"]').count() == 0, (
        "a folded run must not draw its rows"
    )


def test_the_thoughts_of_the_turn_are_inside_the_card(ui_harness: UIHarness, page) -> None:
    """A thought belongs to the call it led to, so it lives in the card — a
    Thought row leaking out below the card is the bug this guards."""
    h = ui_harness
    session_id = "sess_compact_view_thoughts_001"
    workspace_id = create_workspace(h)
    _write_config(h, "compact")
    _seed_transcript(h, workspace_id, session_id)

    open_chatview(page, h, workspace_id, session_id)
    page.locator('[data-testid="compact-tool-group"]').first.wait_for(timeout=20000)

    assert page.locator(".assistant-reasoning").count() == 0, (
        "a folded turn must not draw the dev view's Thought rows below the card"
    )
    body = page.locator(".tool-sequence-compact").first.inner_text()
    assert "Thinking about step 1" not in body, (
        f"a folded card must stay shut until it is opened, got {body!r}"
    )

    page.locator('[data-testid="compact-tool-group-header"]').first.click()
    page.locator('[data-testid="compact-thought-row"]').first.wait_for(timeout=10000)

    inside = page.evaluate(
        """() => document.querySelectorAll(
             '[data-testid="compact-tool-chain"] [data-testid="compact-thought-row"]').length"""
    )
    assert inside == len(CALLS), (
        f"every thought of the turn must draw INSIDE the chain, got {inside} of {len(CALLS)}"
    )
    previews = page.locator('[data-testid="compact-thought-preview"]').all_text_contents()
    assert previews == [f"Thinking about step {i + 1}" for i in range(len(CALLS))], (
        f"each thought must carry its own line, got {previews}"
    )
    whole = page.locator("body").inner_text()
    for index in range(len(CALLS)):
        text = f"Thinking about step {index + 1}"
        assert whole.count(text) == 1, f"{text!r} must be drawn once, got {whole.count(text)}"


def test_unfolding_the_card_shows_the_tool_and_its_argument(ui_harness: UIHarness, page) -> None:
    """Unfolded, each call is one line: the tool and the argument."""
    h = ui_harness
    session_id = "sess_compact_view_rows_001"
    workspace_id = create_workspace(h)
    _write_config(h, "compact")
    _seed_transcript(h, workspace_id, session_id)

    open_chatview(page, h, workspace_id, session_id)
    page.locator('[data-testid="compact-tool-group-header"]').first.click()
    page.locator('[data-testid="compact-tool-row"]').first.wait_for(timeout=10000)

    rows = page.locator('[data-testid="compact-tool-row"]')
    assert rows.count() == len(CALLS), (
        f"unfolding must draw one row per call, got {rows.count()}"
    )
    names = page.locator('[data-testid="compact-tool-row-name"]').all_text_contents()
    assert names == [tool for tool, _ in CALLS], f"each row must name its tool, got {names}"

    primaries = page.locator('[data-testid="compact-tool-row-primary"]').all_text_contents()
    assert primaries == ["/tmp/alpha.ts", "ls -la", "needle"], (
        f"each row must show the argument that identifies the call, got {primaries}"
    )
    body = page.locator(".tool-sequence").first.inner_text()
    assert "1 tool calls" not in body, f"no row may be a group of one, got {body!r}"


def test_a_row_opens_the_full_card(ui_harness: UIHarness, page) -> None:
    """The `+` on a row opens the dev card for that call."""
    h = ui_harness
    session_id = "sess_compact_view_expand_001"
    workspace_id = create_workspace(h)
    _write_config(h, "compact")
    _seed_transcript(h, workspace_id, session_id)

    open_chatview(page, h, workspace_id, session_id)
    page.locator('[data-testid="compact-tool-group-header"]').first.click()
    page.locator('[data-testid="compact-tool-row"]').first.wait_for(timeout=10000)

    # The only card on screen is the run's own group card: the rows are lines.
    assert page.locator(".chat-tool-card").count() == 1, (
        "the compact rows must not draw the dev cards"
    )
    page.locator('[data-testid="compact-tool-row-expand"]').first.click()
    page.wait_for_function(
        "() => document.querySelectorAll('.chat-tool-card').length >= 2", timeout=10000
    )
    assert page.locator(".chat-tool-card").count() == 2, (
        "the `+` on a row must open the dev card for that one call"
    )


def test_dev_view_still_draws_the_cards(ui_harness: UIHarness, page) -> None:
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
