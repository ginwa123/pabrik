"""Functional UI test: "Agents in this chat" lists each agent once.

Reported from a live chat, with a screenshot of the panel:

    deepseek auto   [this chat]
    Simple Engineer            Make lead  Remove
    deepseek auto   [lead]                 Remove

The chat's own agent was drawn twice — once as the chat's agent, once as the
roster member it had also joined (and taken the lead of). Three defects in the
same panel:

1. The panel listed the chat's own agent and the roster side by side, so an
   agent that is both appeared twice.
2. The tab-strip app bar handed the panel the ROSTER as the list of agents it
   may offer ("+ <agent>"), so a group chat could never gain a third agent.
3. The panel offered the agent the chat already answers as, which is how the
   duplicate row above was created in the first place.

Each test seeds a real chat, opens the panel and asserts what it SHOWS.

Run:
    PABRIK_BIN=./zig-out/bin/pabrikcore-linux-x86_64 \\
        python3 -m pytest tests/functional_ui/chatview_group_roster_ui_test.py -v
"""

from __future__ import annotations

from pathlib import Path

import pytest

from chatview_boot import bind_session_workspace, create_workspace, open_chatview
from db_seed import DbSeed
from ui_harness import UIHarness


# ─── Constants ──────────────────────────────────────────────────────────────

OWN_AGENT = "deepseek auto"
LEAD_AGENT = "Simple Engineer"
THIRD_AGENT = "BEAM"


# ─── Helpers ────────────────────────────────────────────────────────────────


def _seed_db_path(h: UIHarness) -> Path:
    return h.temp_dir / ".config" / "pabrik" / "agent.db"


def _seed_agents(h: UIHarness, workspace_id: str) -> None:
    """Three configured agents, `OWN_AGENT` marked active — so it owns the chat."""
    profiles = {
        name: {
            "model": f"{name}-stub-model",
            "base_url": "http://127.0.0.1:1",
            "api_key": "stub-not-real",
        }
        for name in (OWN_AGENT, LEAD_AGENT, THIRD_AGENT)
    }
    h.http(
        "PUT",
        f"/api/workspaces/{workspace_id}/config",
        json_body={"profiles": profiles, "active_profile": OWN_AGENT},
        expect=200,
    )


def _seed_chat(h: UIHarness, workspace_id: str, session_id: str) -> None:
    seed = DbSeed(_seed_db_path(h))
    with seed.connect() as conn:
        seed.seed_session(conn, session_id, "Group roster")
        bind_session_workspace(conn, workspace_id, session_id)
        seed.seed_user_message(conn, session_id, "hai")


def _join(h: UIHarness, session_id: str, agent: str, role: str = "worker") -> None:
    h.http(
        "POST",
        f"/api/llm/session/{session_id}/group/members",
        json_body={"agent": agent, "role": role},
        expect=200,
    )


def _make_lead(h: UIHarness, session_id: str, agent: str) -> None:
    h.http(
        "POST",
        f"/api/llm/session/{session_id}/group/lead",
        json_body={"agent": agent},
        expect=200,
    )


def _open_panel(page, h: UIHarness, workspace_id: str, session_id: str) -> None:
    page.set_viewport_size({"width": 1440, "height": 900})
    open_chatview(page, h, workspace_id, session_id)
    page.locator('[data-testid="chat-message-textarea"]').wait_for(
        timeout=30000, state="visible"
    )
    page.locator('[data-testid="chat-group-roster-toggle"]').click()
    page.locator('[data-testid="chat-group-roster-panel"]').wait_for(
        timeout=10000, state="visible"
    )


def _rows(page) -> list[str]:
    """The agent names the panel draws, top to bottom."""
    return page.eval_on_selector_all(
        '[data-testid="chat-group-roster-panel"] > div[data-testid]',
        "els => els.map(e => e.innerText.split('\\n')[0].trim())",
    )


# ─── Tests ──────────────────────────────────────────────────────────────────


def test_the_chat_own_agent_that_joined_the_roster_is_listed_once(
    page, ui_harness: UIHarness
) -> None:
    """THE bug contract: the screenshot's chat — own agent in the roster, and
    leading it — draws ONE row for that agent, carrying both badges."""
    h = ui_harness
    session_id = "sess_roster_own_member"
    workspace_id = create_workspace(h)
    _seed_agents(h, workspace_id)
    _seed_chat(h, workspace_id, session_id)
    _join(h, session_id, LEAD_AGENT)
    _join(h, session_id, OWN_AGENT)
    _make_lead(h, session_id, OWN_AGENT)

    _open_panel(page, h, workspace_id, session_id)

    assert _rows(page) == [LEAD_AGENT, OWN_AGENT], (
        f"the panel drew {_rows(page)!r} — the chat's own agent must appear once"
    )

    own_row = page.locator(f'[data-testid="chat-group-member-{OWN_AGENT}"]')
    assert own_row.count() == 1, "the own agent that joined the roster was drawn twice"
    assert own_row.locator('[data-testid="chat-group-own-agent-badge"]').inner_text().strip() == (
        "this chat"
    )
    assert own_row.locator('[data-testid="chat-group-lead-badge"]').inner_text().strip() == "lead"
    assert own_row.locator(f'[data-testid="chat-group-remove-{OWN_AGENT}"]').count() == 1


def test_the_panel_offers_an_agent_the_roster_is_not_running_yet(
    page, ui_harness: UIHarness
) -> None:
    """A group chat can gain a third agent from the panel — the tab strip used
    to hand it the roster itself, so the "+ <agent>" list was always empty."""
    h = ui_harness
    session_id = "sess_roster_add_third"
    workspace_id = create_workspace(h)
    _seed_agents(h, workspace_id)
    _seed_chat(h, workspace_id, session_id)
    _join(h, session_id, LEAD_AGENT)

    _open_panel(page, h, workspace_id, session_id)

    assert page.locator(f'[data-testid="chat-group-add-{THIRD_AGENT}"]').count() == 1, (
        "the panel offered no agent outside the roster"
    )
    assert page.locator(f'[data-testid="chat-group-add-{LEAD_AGENT}"]').count() == 0, (
        "the panel offered an agent the roster already runs"
    )


def test_the_toggle_counts_the_agents_the_panel_lists(page, ui_harness: UIHarness) -> None:
    """The badge and the panel never disagree: 2 agents listed, 2 in the badge."""
    h = ui_harness
    session_id = "sess_roster_count"
    workspace_id = create_workspace(h)
    _seed_agents(h, workspace_id)
    _seed_chat(h, workspace_id, session_id)
    _join(h, session_id, LEAD_AGENT)
    _join(h, session_id, OWN_AGENT)

    _open_panel(page, h, workspace_id, session_id)

    drawn = len(_rows(page))
    badge = page.locator('[data-testid="chat-group-roster-count"]').inner_text().strip()
    assert badge == str(drawn), f"the toggle says {badge} while the panel lists {drawn} agents"
