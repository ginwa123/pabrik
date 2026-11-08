"""Functional UI test: a live reply names its author, and a mention joins the roster.

Two defects, both reported from the same chat:

1. **The badge only appeared after a refresh.** `llm_history.agent` is the
   placeholder `Agent` on every row the loop writes; the real author lives in
   the assistant content envelope. The REST transcript recovered it
   (`session_messages_get.wireAgent`), the live `llm_full` event did not — so a
   streaming reply rendered anonymous and only gained its badge once the page
   reloaded the transcript over REST.

2. **`@`-mentioning an agent never put it in "Agents in this chat".** The
   composer's mention only inserted `@name ` text and switched the session's
   agent; nothing POSTed `/group/members`, so the roster stayed empty and the
   panel showed the empty state beside a transcript with two authors in it.

How the SSE path is driven without a real LLM: the harness boots pabrik with
`PABRIK_TEST_SSE_EMIT=1`, which arms `POST /api/dev/sse/emit_llm`. The test
seeds a session, opens the chatview, then fires `full` events through that
endpoint — the same wire path a real agent loop uses.

Run:
    PABRIK_BIN=./zig-out/bin/pabrikcore-linux-x86_64 \\
        python3 -m pytest tests/functional_ui/chatview_agent_author_ui_test.py -v
"""

from __future__ import annotations

import time
from pathlib import Path

import pytest

from chatview_boot import (
    bind_session_workspace,
    create_workspace,
    open_chatview,
)
from db_seed import DbSeed
from ui_harness import UIHarness

try:
    from playwright.sync_api import TimeoutError as _PlaywrightTimeoutError
except ImportError:  # pragma: no cover
    _PlaywrightTimeoutError = None  # type: ignore[assignment,misc]


# ─── Constants ──────────────────────────────────────────────────────────────

AUTHOR = "BEAM"
OTHER_AUTHOR = "deepseek auto"
PLACEHOLDER = "Agent"

LIVE_ANSWER = "Halo! Ada yang bisa saya bantu hari ini?"
PLACEHOLDER_ANSWER = "Oke, santai aja. Kalau nanti butuh sesuatu, tinggal panggil aja ya."

#: Per-attempt wait inside the emit-with-retry loop. The frontend opens ONE
#: EventSource per origin and only becomes leader after a heartbeat + jitter,
#: so an emit fired too early is dropped by the backend bus.
_EMIT_RETRY_WAIT_MS = 1000


# ─── Helpers ────────────────────────────────────────────────────────────────


def _seed_db_path(h: UIHarness) -> Path:
    return h.temp_dir / ".config" / "pabrik" / "agent.db"


def _seed_session(h: UIHarness, workspace_id: str, session_id: str) -> None:
    """One session with a single human turn — the assistant rows come from SSE."""
    seed = DbSeed(_seed_db_path(h))
    with seed.connect() as conn:
        seed.seed_session(conn, session_id, "Agent author test")
        bind_session_workspace(conn, workspace_id, session_id)
        seed.seed_user_message(conn, session_id, "hai")


def _seed_workspace_agents(h: UIHarness, workspace_id: str) -> None:
    """Two agents in the workspace config, so the composer's `@` has a list."""
    agents = {
        AUTHOR: {
            "model": "beam-stub-model",
            "base_url": "http://127.0.0.1:1",
            "api_key": "stub-not-real",
        },
        OTHER_AUTHOR: {
            "model": "deepseek-stub-model",
            "base_url": "http://127.0.0.1:1",
            "api_key": "stub-not-real",
        },
    }
    h.http(
        "PUT",
        f"/api/workspaces/{workspace_id}/config",
        json_body={"profiles": agents},
        expect=200,
    )


def _emit_llm_event(h: UIHarness, session_id: str, payload: dict) -> None:
    h.http(
        "POST",
        "/api/dev/sse/emit_llm",
        json_body={**payload, "session_id": session_id},
        expect=200,
    )


def _open_chat(page, h: UIHarness, workspace_id: str, session_id: str) -> None:
    page.set_viewport_size({"width": 1440, "height": 900})
    open_chatview(page, h, workspace_id, session_id)
    page.locator("text=hai").first.wait_for(timeout=15000, state="attached")


def _emit_and_wait_for(
    h: UIHarness,
    session_id: str,
    payload: dict,
    locator,
    *,
    state: str = "visible",
    timeout_ms: int = 15000,
) -> None:
    """Emit one SSE event, re-emitting until `locator` reaches `state`."""
    deadline = time.monotonic() + timeout_ms / 1000
    last_err: Exception | None = None
    while True:
        _emit_llm_event(h, session_id, payload)
        try:
            locator.wait_for(timeout=_EMIT_RETRY_WAIT_MS, state=state)
            return
        except Exception as e:  # noqa: BLE001 — filtered below
            if _PlaywrightTimeoutError is not None and not isinstance(
                e, _PlaywrightTimeoutError
            ):
                raise
            last_err = e
            if time.monotonic() >= deadline:
                assert last_err is not None
                raise last_err


def _full_event(content: str, agent_name: str, index: int = 1) -> dict:
    return {
        "type": "full",
        "index": index,
        "content": content,
        "role": "assistant",
        "finish_reason": "stop",
        "agent_name": agent_name,
    }


# ─── Fixtures ───────────────────────────────────────────────────────────────


@pytest.fixture(autouse=True)
def _arm_sse_emit_gate(monkeypatch: pytest.MonkeyPatch) -> None:
    monkeypatch.setenv("PABRIK_TEST_SSE_EMIT", "1")


# ─── Tests ──────────────────────────────────────────────────────────────────


def test_live_full_event_badges_its_author_without_a_reload(
    page, ui_harness: UIHarness
) -> None:
    """THE bug contract: the author the wire sends is on screen while the reply
    is still live — no page reload, no REST round-trip."""
    h = ui_harness
    session_id = "sess_agent_author_001"
    workspace_id = create_workspace(h)
    _seed_session(h, workspace_id, session_id)
    _open_chat(page, h, workspace_id, session_id)

    assert page.locator(".msg-author").count() == 0

    _emit_and_wait_for(
        h,
        session_id,
        _full_event(LIVE_ANSWER, AUTHOR),
        page.locator(f".msg-author-name >> text={AUTHOR}").first,
    )

    # The badge sits on the reply it belongs to, and the reply is the live row.
    assert page.locator(f"text={LIVE_ANSWER}").count() == 1
    assert page.locator(".msg-author-name").first.inner_text() == AUTHOR
    assert page.locator(".msg-author-avatar").first.inner_text() == AUTHOR[0].upper()


def test_placeholder_agent_never_becomes_a_badge(page, ui_harness: UIHarness) -> None:
    """`llm_history.agent`'s column default is not an author: a row that carries
    only the placeholder renders no badge at all."""
    h = ui_harness
    session_id = "sess_agent_author_002"
    workspace_id = create_workspace(h)
    _seed_session(h, workspace_id, session_id)
    _open_chat(page, h, workspace_id, session_id)

    _emit_and_wait_for(
        h,
        session_id,
        _full_event(PLACEHOLDER_ANSWER, PLACEHOLDER),
        page.locator(f"text={PLACEHOLDER_ANSWER}").first,
        state="attached",
    )

    assert page.locator(".msg-author").count() == 0
    assert page.locator(f".msg-author-name >> text={PLACEHOLDER}").count() == 0


def test_mentioning_an_agent_puts_it_in_the_roster(
    page, ui_harness: UIHarness
) -> None:
    """`@`-mentioning an agent joins it to the chat, so the roster panel counts
    it and the loop has a speaker to route to."""
    h = ui_harness
    session_id = "sess_agent_author_003"
    workspace_id = create_workspace(h)
    _seed_workspace_agents(h, workspace_id)
    _seed_session(h, workspace_id, session_id)
    _open_chat(page, h, workspace_id, session_id)

    count = page.locator('[data-testid="chat-group-roster-count"]')
    assert count.inner_text().strip() == "0"

    page.locator('[data-testid="chat-message-textarea"]').click()
    page.keyboard.type("@")
    page.locator('[data-testid="agent-picker-list"]').wait_for(
        timeout=10000, state="visible"
    )
    page.locator(f'[data-agent-name="{AUTHOR}"]').click()

    page.locator('[data-testid="chat-group-roster-count"]').wait_for(
        timeout=10000, state="visible"
    )
    deadline = time.monotonic() + 10
    while count.inner_text().strip() != "1" and time.monotonic() < deadline:
        time.sleep(0.1)
    assert count.inner_text().strip() == "1", (
        f"mentioning {AUTHOR} did not join it to the chat: count={count.inner_text()!r}"
    )

    page.locator('[data-testid="chat-group-roster-toggle"]').click()
    page.locator('[data-testid="chat-group-roster-panel"]').wait_for(
        timeout=10000, state="visible"
    )
    assert page.locator(f'[data-testid="chat-group-member-{AUTHOR}"]').count() == 1
    assert page.locator('[data-testid="chat-group-roster-empty"]').count() == 0

    roster = h.http("GET", f"/api/llm/session/{session_id}/group", expect=200).json()
    assert [m["name"] for m in roster["members"]] == [AUTHOR]
    assert roster["group"] is True
    assert roster["lead"] == AUTHOR
