"""Functional UI test: two agents in one chat, and the rows say who spoke.

THE REPORTED BUG (task_1794933840587_1, session ``task_1794928875125_0``)

The human opened `llm_history` in a SQL browser and found ONE agent named twice:
``agent`` alternated between ``Simple Engineer`` (the 49 assistant rows) and the
column default ``Agent`` (the 49 tool rows of those same turns), while
``sessions`` said the chat runs ``deepseek auto`` and
``session_group_members`` held exactly ONE member. Three writers disagreed:

* the tool row took the agent of the PREVIOUS row (read before the turn's
  assistant row was written), so it was one turn behind — and once behind it
  stayed behind, because the previous row was itself a tool row saying ``Agent``;
* the chat's own agent never got named at all: the loop read the last row's own
  ``agent`` and the column default is the placeholder;
* ``saveMessage`` labelled the assistant envelope with the session profile even
  when the row's own column named a different speaker.

THE INVARIANT THIS FILE PINS

A tool row belongs to the assistant turn that called it: same ``loop_index``,
same ``agent``, same ``model``. No row of a real speaker carries the placeholder.
And the transcript, the wire and the roster agree about who is in the room.

WHAT IS FAKE

The transcript is seeded straight into the harness's isolated ``agent.db``
(``db_seed``) — no LLM runs. The rows are shaped exactly as the FIXED loop
writes them, so the assertions cover the read path (``wireAgentName`` → REST →
``useChatMessagePresentation`` → ``ChatMessageRow``) rather than a model.

Run:
    PABRIK_BIN=./zig-out/bin/pabrikcore-linux-x86_64 \\
        python3 -m pytest tests/functional_ui/chatview_multi_agent_attribution_ui_test.py -v
"""

from __future__ import annotations

import json
import sqlite3
from pathlib import Path
from typing import Any

import pytest

from chatview_boot import (
    bind_session_workspace,
    create_workspace,
    open_chatview,
    seed_db_path,
)
from db_seed import DbSeed
from ui_harness import UIHarness


# ─── The two agents of the reported chat ────────────────────────────────────

OWN_AGENT = "deepseek auto"
OWN_MODEL = "deepseek-v4.1-flash"
GROUP_AGENT = "Simple Engineer"
GROUP_MODEL = "hy4-flash-free"
PLACEHOLDER = "Agent"

OWN_ANSWER = "I read the file — the view is missing its footer."
GROUP_ANSWER = "Footer added and the build is green."


# ─── Seeding ────────────────────────────────────────────────────────────────


def _tool_envelope(tool: str, parameters: dict[str, Any], data: dict[str, Any]) -> str:
    """The canonical tool-result envelope the frontend's ``tryUnwrapToolOutput`` parses."""
    return json.dumps(
        {
            "tool": tool,
            "parameters": parameters,
            "success": True,
            "data": data,
            "error": None,
            "v": 1,
        }
    )


def _insert_row(
    conn: sqlite3.Connection,
    *,
    message_id: str,
    session_id: str,
    role: str,
    agent: str,
    model: str,
    loop_index: int,
    content: str = "",
    finish_reason: str | None = None,
    tool_calls_json: str = "",
    tool_call_id: str | None = None,
    tool_name: str | None = None,
) -> str:
    """INSERT one ``llm_history`` row with the columns attribution depends on.

    ``created_at_nano`` is a monotonic nanosecond stamp so ``ORDER BY`` is the
    seed order (production writes nanosecond timestamps too).
    """
    conn.execute(
        """
        INSERT INTO llm_history (
            id, session_id, model, response_content, finish_reason, role,
            tool_calls_json, tool_call_id, agent, loop_index, is_thinking,
            created_at_nano, is_input, is_output, tool_name, is_feed_to_llm
        ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, 0, ?, ?, ?, ?, 1)
        """,
        (
            message_id,
            session_id,
            model,
            content,
            finish_reason,
            role,
            tool_calls_json,
            tool_call_id,
            agent,
            loop_index,
            int(message_id),
            1 if role in ("user", "tool") else 0,
            1 if role in ("assistant", "tool") else 0,
            tool_name,
        ),
    )
    return message_id


def _seed_chat(h: UIHarness, workspace_id: str, session_id: str) -> None:
    """One human turn answered by the chat's own agent, then a hand-off to the group lead."""
    seed = DbSeed(seed_db_path(h))
    base = 1_794_930_000_000_000_000
    with seed.connect() as conn:
        seed.seed_session(conn, session_id, "Two agents", cwd=str(h.temp_dir))
        bind_session_workspace(conn, workspace_id, session_id)

        conn.execute(
            "UPDATE sessions SET selected_profile_model = ?, group_lead = ? WHERE id = ?",
            (OWN_AGENT, GROUP_AGENT, session_id),
        )
        conn.execute(
            """
            INSERT INTO session_group_members (session_id, agent_name, role, position)
            VALUES (?, ?, 'lead', 1)
            """,
            (session_id, GROUP_AGENT),
        )

        read_args = {"path": "/tmp/Footer.vue"}
        command_args = {"command": "npm run build", "cwd": "/tmp/app"}
        read_call = {
            "id": "call_read_1",
            "type": "function",
            "function": {"name": "read_file", "arguments": json.dumps(read_args)},
        }
        command_call = {
            "id": "call_build_2",
            "type": "function",
            "function": {"name": "command", "arguments": json.dumps(command_args)},
        }

        _insert_row(
            conn,
            message_id=str(base + 1),
            session_id=session_id,
            role="user",
            agent=PLACEHOLDER,
            model=OWN_MODEL,
            loop_index=0,
            content=json.dumps({"user": "u1", "name": "Budi", "msg": "add the footer"}),
        )
        _insert_row(
            conn,
            message_id=str(base + 2),
            session_id=session_id,
            role="assistant",
            agent=OWN_AGENT,
            model=OWN_MODEL,
            loop_index=1,
            finish_reason="tool_calls",
            tool_calls_json=json.dumps([read_call]),
        )
        _insert_row(
            conn,
            message_id=str(base + 3),
            session_id=session_id,
            role="tool",
            agent=OWN_AGENT,
            model=OWN_MODEL,
            loop_index=1,
            finish_reason="tool",
            tool_call_id="call_read_1",
            tool_name="read_file",
            content=_tool_envelope("read_file", read_args, {"content": "<template/>"}),
        )
        _insert_row(
            conn,
            message_id=str(base + 4),
            session_id=session_id,
            role="assistant",
            agent=OWN_AGENT,
            model=OWN_MODEL,
            loop_index=2,
            finish_reason="stop",
            content=json.dumps({"agent": OWN_AGENT, "msg": OWN_ANSWER}),
        )
        _insert_row(
            conn,
            message_id=str(base + 5),
            session_id=session_id,
            role="assistant",
            agent=GROUP_AGENT,
            model=GROUP_MODEL,
            loop_index=3,
            finish_reason="tool_calls",
            tool_calls_json=json.dumps([command_call]),
        )
        _insert_row(
            conn,
            message_id=str(base + 6),
            session_id=session_id,
            role="tool",
            agent=GROUP_AGENT,
            model=GROUP_MODEL,
            loop_index=3,
            finish_reason="tool",
            tool_call_id="call_build_2",
            tool_name="command",
            content=_tool_envelope(
                "command", command_args, {"stdout": "built", "exit_code": 0}
            ),
        )
        _insert_row(
            conn,
            message_id=str(base + 7),
            session_id=session_id,
            role="assistant",
            agent=GROUP_AGENT,
            model=GROUP_MODEL,
            loop_index=4,
            finish_reason="stop",
            content=json.dumps({"agent": GROUP_AGENT, "msg": GROUP_ANSWER}),
        )


def _seed_workspace_agents(h: UIHarness, workspace_id: str) -> None:
    """Both speakers must be configured, or the chat credits no author at all."""
    profiles = {
        OWN_AGENT: {
            "model": OWN_MODEL,
            "base_url": "http://127.0.0.1:1",
            "api_key": "stub-not-real",
        },
        GROUP_AGENT: {
            "model": GROUP_MODEL,
            "base_url": "http://127.0.0.1:1",
            "api_key": "stub-not-real",
        },
    }
    h.http(
        "PUT",
        f"/api/workspaces/{workspace_id}/config",
        json_body={"profiles": profiles},
        expect=200,
    )


# ─── The table ──────────────────────────────────────────────────────────────


def _rows(h: UIHarness, session_id: str) -> list[dict[str, Any]]:
    conn = sqlite3.connect(str(seed_db_path(h)))
    conn.row_factory = sqlite3.Row
    try:
        return [
            dict(r)
            for r in conn.execute(
                "SELECT * FROM llm_history WHERE session_id = ? ORDER BY created_at_nano ASC",
                (session_id,),
            )
        ]
    finally:
        conn.close()


def _assert_turn_attribution(rows: list[dict[str, Any]]) -> None:
    """THE invariant: a tool row belongs to the assistant turn that called it."""
    by_turn: dict[int, dict[str, list[dict[str, Any]]]] = {}
    for row in rows:
        by_turn.setdefault(int(row["loop_index"]), {}).setdefault(row["role"], []).append(row)

    tool_turns = [index for index, roles in by_turn.items() if roles.get("tool")]
    assert tool_turns, "the seeded transcript carries no tool row — the test proves nothing"

    for index in tool_turns:
        assistant = by_turn[index].get("assistant") or []
        assert assistant, f"loop_index {index} has a tool row but no assistant row"
        speaker = assistant[0]["agent"]
        model = assistant[0]["model"]
        for tool_row in by_turn[index]["tool"]:
            assert tool_row["agent"] == speaker, (
                f"loop_index {index}: the tool row says agent={tool_row['agent']!r} "
                f"but its turn was spoken by {speaker!r} — the tool row is one turn behind"
            )
            assert tool_row["model"] == model, (
                f"loop_index {index}: the tool row says model={tool_row['model']!r} "
                f"but its turn ran {model!r}"
            )


# ─── Tests ──────────────────────────────────────────────────────────────────


def test_the_table_names_one_speaker_per_turn(page, ui_harness: UIHarness) -> None:
    """The DB half: every tool row carries its turn's speaker, and no real speaker
    is recorded as the placeholder."""
    h = ui_harness
    session_id = "sess_multi_agent_table"
    workspace_id = create_workspace(h)
    _seed_chat(h, workspace_id, session_id)

    rows = _rows(h, session_id)
    _assert_turn_attribution(rows)

    tool_agents = {r["agent"] for r in rows if r["role"] == "tool"}
    assert tool_agents == {OWN_AGENT, GROUP_AGENT}, (
        f"the tool rows should name their own turn's speaker, got {tool_agents!r}"
    )
    assert PLACEHOLDER not in tool_agents

    assistant_agents = {r["agent"] for r in rows if r["role"] == "assistant"}
    assert assistant_agents == {OWN_AGENT, GROUP_AGENT}


def test_the_roster_tables_agree_with_the_transcript(page, ui_harness: UIHarness) -> None:
    """The other tables: the lead the roster names is the agent that actually
    spoke the last turn — not a ghost the transcript has never heard of."""
    h = ui_harness
    session_id = "sess_multi_agent_roster"
    workspace_id = create_workspace(h)
    _seed_chat(h, workspace_id, session_id)

    roster = h.http("GET", f"/api/llm/session/{session_id}/group", expect=200).json()
    assert [m["name"] for m in roster["members"]] == [GROUP_AGENT]
    assert roster["lead"] == GROUP_AGENT
    assert roster["group"] is True

    conn = sqlite3.connect(str(seed_db_path(h)))
    try:
        group_lead = conn.execute(
            "SELECT group_lead FROM sessions WHERE id = ?", (session_id,)
        ).fetchone()[0]
        profile = conn.execute(
            "SELECT selected_profile_model FROM sessions WHERE id = ?", (session_id,)
        ).fetchone()[0]
        lead_rows = conn.execute(
            "SELECT agent_name, role FROM session_group_members WHERE session_id = ?",
            (session_id,),
        ).fetchall()
    finally:
        conn.close()

    assert group_lead == GROUP_AGENT
    assert profile == OWN_AGENT
    assert lead_rows == [(GROUP_AGENT, "lead")]

    last_speaker = _rows(h, session_id)[-1]["agent"]
    assert last_speaker == group_lead, (
        f"the roster's lead is {group_lead!r} but the last turn was spoken by {last_speaker!r}"
    )


def test_the_wire_keeps_every_rows_speaker(page, ui_harness: UIHarness) -> None:
    """The read path: `wireAgentName` must hand the speaker to the client on the
    tool rows too — a tool envelope carries no author of its own, so a column that
    lost the name is unrecoverable downstream."""
    h = ui_harness
    session_id = "sess_multi_agent_wire"
    workspace_id = create_workspace(h)
    _seed_chat(h, workspace_id, session_id)

    body = h.http(
        "GET",
        f"/api/llm/session/{session_id}/messages?limit=100&sort_by=created_at&direction=asc",
        expect=200,
    ).json()
    wire = {m["id"]: m for m in body["messages"]}
    rows = _rows(h, session_id)

    for row in rows:
        sent = wire[row["id"]]["agent"]
        if row["role"] == "user":
            assert sent == row["agent"]
            continue
        assert sent == row["agent"], (
            f"{row['role']} row {row['id']} is stored as {row['agent']!r} "
            f"but the wire says {sent!r}"
        )
        assert sent != PLACEHOLDER, f"{row['role']} row {row['id']} reached the wire anonymous"


def test_the_chat_badges_both_agents_and_never_the_placeholder(
    page, ui_harness: UIHarness
) -> None:
    """The rendered half: two authors, two badges, and no badge for the column default."""
    h = ui_harness
    session_id = "sess_multi_agent_ui"
    workspace_id = create_workspace(h)
    _seed_workspace_agents(h, workspace_id)
    _seed_chat(h, workspace_id, session_id)

    page.set_viewport_size({"width": 1440, "height": 900})
    open_chatview(page, h, workspace_id, session_id)
    page.locator(f"text={GROUP_ANSWER}").first.wait_for(timeout=20000, state="attached")
    page.locator(f"text={OWN_ANSWER}").first.wait_for(timeout=20000, state="attached")

    names = page.locator(".msg-author-name")
    assert names.count() == 2, (
        f"expected one badge per answering agent, saw {names.count()}"
    )
    shown = {names.nth(i).inner_text().strip() for i in range(names.count())}
    assert shown == {OWN_AGENT, GROUP_AGENT}, f"badges named {shown!r}"
    assert PLACEHOLDER not in shown, (
        "the llm_history column default became a badge — it is not an author"
    )

    assert page.locator(f'.msg-author-name >> text={PLACEHOLDER}').count() == 0


@pytest.fixture(autouse=True)
def _no_sse_gate(monkeypatch: pytest.MonkeyPatch) -> None:
    """This file drives the REST transcript only; keep the dev SSE emit closed."""
    monkeypatch.delenv("PABRIK_TEST_SSE_EMIT", raising=False)
