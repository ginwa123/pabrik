"""Functional UI test: a chat with no session row yet has no roster, not a 404.

THE BUG (reported from a live New Chat):

    The "Agents in this chat" panel showed a raw
    `HTTP 404 {"error":"Session not found"}` under its empty state, and the
    Network tab carried a red `GET /api/llm/session/<id>/group`.

    A "New Chat" is a `workspace_item_tasks` row; its `sessions` row is only
    written when the first message arrives (`task_create.zig` inserts one only
    for the unattended flag). So the roster read asked about a session that
    cannot exist yet, and `rosterUseCase` answered `SessionNotFound`.

THE FIX:

    `rosterUseCase` no longer requires a `sessions` row — a chat with no row
    yet has an empty roster, which is the honest answer. The write paths
    (`addMemberUseCase` and friends) still 404 for an unknown session, because
    you cannot join a chat that does not exist.

Each test:

1. Boots a fresh pabrik + Vite via the ``ui_harness`` fixture.
2. Creates the chat the way the sidebar's "New Chat" button does — a default
   project, then a task under it — so the state is the real one, not a fixture.
3. Drives headless Chromium at the chat deep link and asserts what the panel
   SHOWS, plus the status the roster endpoint answered with.

Run:
    PABRIK_BIN=./zig-out/bin/pabrikcore-linux-x86_64 \\
        python3 -m pytest tests/functional_ui/chatview_pending_chat_roster_ui_test.py -v
"""

from __future__ import annotations

import time
from pathlib import Path

import pytest

from chatview_boot import bind_session_workspace, create_workspace, open_chatview
from db_seed import DbSeed
from ui_harness import UIHarness


# ─── Helpers ────────────────────────────────────────────────────────────────


def _seed_db_path(h: UIHarness) -> Path:
    return h.temp_dir / ".config" / "pabrik" / "agent.db"


def _new_chat(h: UIHarness) -> tuple[str, str]:
    """Create a chat exactly the way the sidebar's "New Chat" button does."""
    workspace_id = create_workspace(h)
    project = h.http(
        "POST", f"/api/workspaces/{workspace_id}/default-project", expect=200
    ).json()["item"]
    task = h.http(
        "POST",
        f"/api/workspaces/{workspace_id}/items/{project['id']}/tasks",
        json_body={"name": "New Chat"},
        expect=201,
    ).json()
    return workspace_id, task["id"]


def _kanban_chat(h: UIHarness) -> tuple[str, str]:
    """Create a chat the way a kanban card does — that path writes the session."""
    workspace_id = create_workspace(h)
    kanban = h.http(
        "POST",
        f"/api/workspaces/{workspace_id}/items/kanban",
        json_body={"name": "roster board"},
        expect=201,
    ).json()["item"]
    columns = h.http(
        "GET",
        f"/api/workspaces/{workspace_id}/items/{kanban['id']}/kanban/columns",
        expect=200,
    ).json()["columns"]
    todo = next(c for c in columns if c["name"].lower() == "todo")
    task = h.http(
        "POST",
        f"/api/workspaces/{workspace_id}/items/{kanban['id']}/tasks",
        json_body={"name": "kanban chat", "column_id": todo["id"]},
        expect=201,
    ).json()
    return workspace_id, task["id"]


def _seed_workspace_agents(h: UIHarness, workspace_id: str) -> None:
    h.http(
        "PUT",
        f"/api/workspaces/{workspace_id}/config",
        json_body={
            "profiles": {
                "BEAM": {
                    "model": "beam-stub-model",
                    "base_url": "http://127.0.0.1:1",
                    "api_key": "stub-not-real",
                }
            }
        },
        expect=200,
    )


def _seed_real_chat(h: UIHarness, workspace_id: str, session_id: str) -> None:
    seed = DbSeed(_seed_db_path(h))
    with seed.connect() as conn:
        seed.seed_session(conn, session_id, "Roster control")
        bind_session_workspace(conn, workspace_id, session_id)
        seed.seed_user_message(conn, session_id, "hai")


def _record_group_responses(page) -> list:
    """Every response the roster endpoint produced, in order."""
    seen: list = []

    def on_response(response) -> None:
        if "/group" in response.url:
            seen.append(response)

    page.on("response", on_response)
    return seen


def _open_roster_panel(page, h: UIHarness, workspace_id: str, chat_id: str) -> None:
    page.set_viewport_size({"width": 1440, "height": 900})
    open_chatview(page, h, workspace_id, chat_id)
    page.locator('[data-testid="chat-message-textarea"]').wait_for(
        timeout=30000, state="visible"
    )
    page.locator('[data-testid="chat-group-roster-toggle"]').click()
    page.locator('[data-testid="chat-group-roster-panel"]').wait_for(
        timeout=10000, state="visible"
    )


# ─── Tests ──────────────────────────────────────────────────────────────────


def test_a_new_chat_shows_an_empty_roster_not_an_error(
    page, ui_harness: UIHarness
) -> None:
    """THE bug contract: a chat whose session row does not exist yet renders the
    empty roster, and the roster endpoint answers 200 instead of 404."""
    h = ui_harness
    workspace_id, chat_id = _new_chat(h)
    responses = _record_group_responses(page)

    _open_roster_panel(page, h, workspace_id, chat_id)

    assert page.locator('[data-testid="chat-group-roster-empty"]').count() == 1
    assert page.locator('[data-testid="chat-group-roster-error"]').count() == 0, (
        "the roster panel rendered an error for a chat that simply has no session yet"
    )
    assert page.locator('[data-testid="chat-group-roster-count"]').inner_text().strip() == "0"

    statuses = [r.status for r in responses]
    assert statuses, "the roster endpoint was never asked"
    assert 404 not in statuses, f"the roster endpoint answered 404: {statuses}"


def test_a_real_chat_still_reads_its_roster(page, ui_harness: UIHarness) -> None:
    """Control: the fix did not disable the endpoint — a chat that HAS a session
    row still reads its roster, and still shows the empty state."""
    h = ui_harness
    workspace_id = create_workspace(h)
    session_id = "sess_roster_control"
    _seed_real_chat(h, workspace_id, session_id)
    responses = _record_group_responses(page)

    _open_roster_panel(page, h, workspace_id, session_id)

    assert page.locator('[data-testid="chat-group-roster-empty"]').count() == 1
    assert page.locator('[data-testid="chat-group-roster-error"]').count() == 0

    statuses = [r.status for r in responses]
    assert 200 in statuses, f"the roster endpoint never answered 200: {statuses}"


def test_a_kanban_chat_reads_its_roster(page, ui_harness: UIHarness) -> None:
    """The other creation path: a kanban card writes its `sessions` row up
    front, so its chat reads a roster like any other."""
    h = ui_harness
    workspace_id, chat_id = _kanban_chat(h)
    responses = _record_group_responses(page)

    _open_roster_panel(page, h, workspace_id, chat_id)

    assert page.locator('[data-testid="chat-group-roster-empty"]').count() == 1
    assert page.locator('[data-testid="chat-group-roster-error"]').count() == 0

    statuses = [r.status for r in responses]
    assert 200 in statuses, f"the roster endpoint never answered 200: {statuses}"


def test_a_new_chat_can_still_join_an_agent(page, ui_harness: UIHarness) -> None:
    """The panel invites `+ <agent>` on a fresh chat, so that write has to work
    before the first message creates the session row."""
    h = ui_harness
    workspace_id, chat_id = _new_chat(h)
    _seed_workspace_agents(h, workspace_id)

    _open_roster_panel(page, h, workspace_id, chat_id)
    joins: list = []
    page.on(
        "response",
        lambda r: joins.append(r) if "/group/members" in r.url else None,
    )
    page.locator('[data-testid="chat-group-add-BEAM"]').click()

    count = page.locator('[data-testid="chat-group-roster-count"]')
    deadline = time.monotonic() + 10
    while count.inner_text().strip() != "1" and time.monotonic() < deadline:
        time.sleep(0.1)
    assert count.inner_text().strip() == "1", (
        f"joining BEAM on a fresh chat did not land: count={count.inner_text()!r}"
    )
    assert page.locator('[data-testid="chat-group-roster-error"]').count() == 0
    assert page.locator('[data-testid="chat-group-member-BEAM"]').count() == 1

    assert [r.status for r in joins] == [200], (
        f"the join answered {[r.status for r in joins]}"
    )

    roster = h.http("GET", f"/api/llm/session/{chat_id}/group", expect=200).json()
    assert [m["name"] for m in roster["members"]] == ["BEAM"]
    assert roster["group"] is True
    assert roster["lead"] == "BEAM"
