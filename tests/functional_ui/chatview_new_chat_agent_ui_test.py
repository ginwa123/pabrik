"""Functional UI test: a New Chat names the agent that will answer.

THE BUG (reported from a live New Chat):

    "Agent default not selected?" — the composer showed no agent at all, so a
    reader could not tell which agent was the default. And in a chat that had
    already answered, the reply was badged with a profile the reader had never
    seen ("who the hell is S?").

    Both come from one mismatch. The backend resolves
    `selected → active_profile → top-level` and treats a name that is not a
    configured profile as a miss (`Config.zig::resolveEffectiveAgent`). The UI
    trusted the session's stored name verbatim, and after the composer chip was
    removed (a0c92e968) it rendered no agent at all.

THE FIX:

    `useChatComposerAgents.effectiveAgent` runs the same cascade, and the
    composer renders it as a chip. The transcript badge reads the same value,
    so a stale stored profile falls through to the agent that actually ran.

Each test:

1. Boots a fresh pabrik + Vite via the ``ui_harness`` fixture.
2. Seeds the workspace config the way Settings → Agents does — profiles plus
   the "Set active" default.
3. Drives headless Chromium: clicks the sidebar's New Chat button (the real
   user action) and asserts what the composer SHOWS.

Run:
    PABRIK_BIN=./zig-out/bin/pabrikcore-linux-x86_64 \\
        python3 -m pytest tests/functional_ui/chatview_new_chat_agent_ui_test.py -v
"""

from __future__ import annotations

import re
from pathlib import Path

from chatview_boot import bind_session_workspace, create_workspace, open_chatview
from db_seed import DbSeed
from ui_harness import UIHarness

#: The agent Settings → Agents marks active for this workspace.
DEFAULT_AGENT = "BEAM"
#: A second profile, so "the default" is a real choice and not "the only one".
OTHER_AGENT = "deepseek auto"
#: A profile the session stored but the workspace no longer configures.
GONE_AGENT = "space"

_NEW_CHAT_BUTTON = '[data-testid="sidebar-new-chat-button"]'
_AGENT_CHIP = '[data-testid="composer-agent-chip"]'
_TEXTAREA = '[data-testid="chat-message-textarea"]'

#: /app/<workspace>/projects/<default-item>/chat/<new-task>
_CHAT_URL_RE = re.compile(r"/app/[^/]+/projects/[^/]+/chat/[^/]+")


# ─── Helpers ────────────────────────────────────────────────────────────────


def _seed_db_path(h: UIHarness) -> Path:
    return h.temp_dir / ".config" / "pabrik" / "agent.db"


def _seed_agents(h: UIHarness, workspace_id: str, active: str | None) -> None:
    """Write the workspace's agents the way Settings → Agents does."""
    body: dict = {
        "profiles": {
            DEFAULT_AGENT: {
                "model": "beam-stub-model",
                "base_url": "http://127.0.0.1:1",
                "api_key": "stub-not-real",
            },
            OTHER_AGENT: {
                "model": "deepseek-stub-model",
                "base_url": "http://127.0.0.1:1",
                "api_key": "stub-not-real",
            },
        }
    }
    if active is not None:
        body["active_profile"] = active
    h.http("PUT", f"/api/workspaces/{workspace_id}/config", json_body=body, expect=200)


def _goto_fresh_boot(page, h: UIHarness) -> None:
    """Open bare /app: no workspace in the URL, no prior selection."""
    page.goto(h.web_url("/app"), wait_until="domcontentloaded", timeout=60000)
    page.locator('[data-testid="sidebar-header-expanded"]').wait_for(timeout=60000)
    page.locator(_NEW_CHAT_BUTTON).wait_for(timeout=60000, state="visible")


def _click_new_chat(page) -> None:
    """Click New Chat and wait for the chat it opens to render its composer."""
    page.wait_for_function(
        """() => {
          const b = document.querySelector('[data-testid="sidebar-new-chat-button"]');
          return b && !b.disabled;
        }""",
        timeout=20000,
    )
    page.locator(_NEW_CHAT_BUTTON).click()
    page.wait_for_url(lambda url: bool(_CHAT_URL_RE.search(url)), timeout=60000)
    page.locator(_TEXTAREA).wait_for(timeout=30000, state="visible")


def _chip_text(page) -> str:
    """The agent the composer names, once the config has landed."""
    page.locator(_AGENT_CHIP).wait_for(timeout=20000, state="visible")
    return page.locator(_AGENT_CHIP).inner_text().strip()


# ─── Tests ──────────────────────────────────────────────────────────────────


def test_new_chat_names_the_default_agent(page, ui_harness: UIHarness) -> None:
    """THE bug contract: click New Chat, and the composer says which agent
    answers — the one Settings marks active."""
    h = ui_harness
    workspace_id = create_workspace(h, "ui-new-chat-agent-ws")
    _seed_agents(h, workspace_id, active=DEFAULT_AGENT)

    _goto_fresh_boot(page, h)
    _click_new_chat(page)

    assert _chip_text(page) == DEFAULT_AGENT, (
        "a New Chat named no agent — the composer chip is missing or wrong"
    )
    assert "active agent" in page.locator(_AGENT_CHIP).get_attribute("title").lower(), (
        "the chip does not say the agent is the workspace's active one"
    )


def test_new_chat_without_an_active_agent_says_default(
    page, ui_harness: UIHarness
) -> None:
    """Control: with no "Set active" the chip still renders, and says so
    honestly instead of naming an agent that was never chosen."""
    h = ui_harness
    workspace_id = create_workspace(h, "ui-new-chat-no-default-ws")
    _seed_agents(h, workspace_id, active=None)

    _goto_fresh_boot(page, h)
    _click_new_chat(page)

    assert _chip_text(page) == "Default"
    assert "top-level" in page.locator(_AGENT_CHIP).get_attribute("title").lower()


def test_new_chat_roster_panel_names_the_chat_own_agent(
    page, ui_harness: UIHarness
) -> None:
    """The panel's copy says "beside the chat's own agent" — so it has to name
    it, or the reader is left asking who that agent is."""
    h = ui_harness
    workspace_id = create_workspace(h, "ui-new-chat-roster-ws")
    _seed_agents(h, workspace_id, active=DEFAULT_AGENT)

    _goto_fresh_boot(page, h)
    _click_new_chat(page)

    page.locator('[data-testid="chat-group-roster-toggle"]').click()
    page.locator('[data-testid="chat-group-roster-panel"]').wait_for(
        timeout=10000, state="visible"
    )

    own = page.locator('[data-testid="chat-group-own-agent"]')
    assert own.inner_text().strip().startswith(DEFAULT_AGENT), (
        f"the roster panel does not name the chat's own agent: {own.inner_text()!r}"
    )
    assert page.locator('[data-testid="chat-group-own-agent-badge"]').inner_text().strip() == (
        "this chat"
    )


def test_a_chat_whose_stored_agent_is_gone_names_the_active_one(
    page, ui_harness: UIHarness
) -> None:
    """The "who the hell is S?" case: the session stored a profile the
    workspace no longer configures, so the backend ran the active one. The
    composer and the reply badge must both name the agent that answered."""
    h = ui_harness
    workspace_id = create_workspace(h, "ui-stale-agent-ws")
    _seed_agents(h, workspace_id, active=DEFAULT_AGENT)

    session_id = "sess_stale_agent"
    seed = DbSeed(_seed_db_path(h))
    with seed.connect() as conn:
        seed.seed_session(conn, session_id, "Stale agent chat")
        bind_session_workspace(conn, workspace_id, session_id)
        conn.execute(
            "UPDATE sessions SET selected_profile_model = ? WHERE id = ?",
            (GONE_AGENT, session_id),
        )
        seed.seed_user_message(conn, session_id, "hai")
        seed.seed_assistant_message(conn, session_id, "Halo! Ada yang bisa dibantu?")

    page.set_viewport_size({"width": 1440, "height": 900})
    open_chatview(page, h, workspace_id, session_id)
    page.locator(_TEXTAREA).wait_for(timeout=30000, state="visible")

    assert _chip_text(page) == DEFAULT_AGENT, (
        f"the composer still names the gone profile {GONE_AGENT!r}"
    )
    page.locator(".msg-author-name").first.wait_for(timeout=20000, state="visible")
    assert page.locator(".msg-author-name").first.inner_text().strip() == DEFAULT_AGENT, (
        f"the reply is still credited to {GONE_AGENT!r}, which did not answer"
    )
