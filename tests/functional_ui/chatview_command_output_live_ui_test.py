"""Functional UI regression: command stdout updates live and survives reload.

The backend creates a tool-result placeholder, emits it, then updates that
same database row and emits the completed payload with the same id. ChatView
updates the existing card in place, but the completed event used to return
before the local-sync write-through. The in-memory card looked correct while
the IndexedDB row still held the placeholder's ``data:null`` envelope, so a
reload painted stale output until the server history replaced it.

This test drives the real SSE endpoint and the real browser IndexedDB. The
dev emit endpoint intentionally does not insert the synthetic rows, which
makes the cached reload assertion deterministic: before the fix, reload has
no server row to repair the stale cache.
"""

from __future__ import annotations

import json
import time
from pathlib import Path

import pytest

from chatview_boot import open_chatview
from db_seed import DbSeed
from harness import harness_path
from ui_harness import UIHarness

SESSION_ID = "sess_command_output_live_001"
# The test-only emitter canonicalizes full-event ids to `test-{index}`.
TOOL_ROW_ID = "test-1"
TOOL_CALL_ID = "call-command-output-live"
STDOUT_MARKER = "LIVE_COMMAND_STDOUT_MARKER"


def _tool_envelope(data: dict | None, workdir: str) -> str:
    return json.dumps(
        {
            "tool": "command",
            "parameters": {
                "command": "printf '%s\\n' '--- numbered excerpts ---'",
                "timeout": 10,
                "workdir": workdir,
            },
            "success": True,
            "data": data,
            "error": None,
            "v": 1,
        }
    )


def _event(content: str) -> dict:
    return {
        "index": 1,
        "type": "full",
        "role": "tool",
        "finish_reason": "tool",
        "content": content,
        "tool_call_id": TOOL_CALL_ID,
        "tool_name": "command",
        "is_input": False,
        "is_output": True,
    }


def _emit(h: UIHarness, payload: dict) -> None:
    h.http(
        "POST",
        "/api/dev/sse/emit_llm",
        json_body={**payload, "session_id": SESSION_ID},
        expect=200,
    )


def _emit_until_text(
    h: UIHarness,
    payload: dict,
    locator,
    needle: str,
    *,
    timeout_ms: int = 15000,
) -> None:
    deadline = time.monotonic() + timeout_ms / 1000
    while True:
        _emit(h, payload)
        end = min(deadline, time.monotonic() + 1.0)
        last_text = ""
        while time.monotonic() < end:
            if locator.count() > 0:
                last_text = locator.inner_text()
                if needle in last_text:
                    return
            time.sleep(0.1)
        if time.monotonic() >= deadline:
            raise AssertionError(
                f"timed out waiting for {needle!r}; last text was {last_text!r}"
            )


def _wait_for_cached_stdout(page, *, timeout_ms: int = 10000) -> None:
    deadline = time.monotonic() + timeout_ms / 1000
    while time.monotonic() < deadline:
        content = page.evaluate(
            """async ({ id }) => {
                const db = await new Promise((resolve, reject) => {
                    const request = indexedDB.open('pabrik-sync')
                    request.onsuccess = () => resolve(request.result)
                    request.onerror = () => reject(request.error)
                })
                const row = await new Promise((resolve, reject) => {
                    const tx = db.transaction('messages', 'readonly')
                    const request = tx.objectStore('messages').get(id)
                    request.onsuccess = () => resolve(request.result)
                    request.onerror = () => reject(request.error)
                })
                return row?.raw?.content ?? null
            }""",
            {"id": TOOL_ROW_ID},
        )
        if isinstance(content, str) and STDOUT_MARKER in content:
            return
        time.sleep(0.1)
    raise AssertionError("completed command stdout was not written to the local sync cache")


@pytest.fixture(autouse=True)
def _arm_sse_emit_gate(monkeypatch: pytest.MonkeyPatch) -> None:
    monkeypatch.setenv("PABRIK_TEST_SSE_EMIT", "1")


def test_command_stdout_updates_live_and_survives_reload(
    page,
    ui_harness: UIHarness,
) -> None:
    h = ui_harness
    # The seeded workspace-item path and the seeded sessions.cwd are both
    # resolved by the server (the command tool chdirs into `workdir`, the
    # chatview boots from `sessions.cwd`), so they must be real absolute
    # paths on the runner. A hardcoded "/tmp" works on ubuntu-24.04 and
    # names no directory at all on windows-2022.
    item_path = harness_path(h, "command-output-ui")
    workdir = harness_path(h)
    seed = DbSeed(Path(h.temp_dir) / ".config" / "pabrik" / "agent.db")
    with seed.connect() as conn:
        seed.seed_session(conn, SESSION_ID, "Command output live test")
        workspace_id = "ws_command_output_ui"
        item_id = "item_command_output_ui"
        conn.execute(
            "INSERT OR REPLACE INTO workspaces (id, name, position) VALUES (?, ?, ?)",
            (workspace_id, "Command output test workspace", 0),
        )
        conn.execute(
            "INSERT OR REPLACE INTO workspace_items "
            "(id, workspace_id, item_type, name, path, position) "
            "VALUES (?, ?, ?, ?, ?, ?)",
            (item_id, workspace_id, "kanban", "Command output test", item_path, 0),
        )
        conn.execute(
            "INSERT OR REPLACE INTO workspace_item_tasks "
            "(id, name, workspace_item_id, task_type) VALUES (?, ?, ?, ?)",
            (SESSION_ID, "Command output task", item_id, "standard"),
        )
        conn.execute(
            "UPDATE sessions SET cwd = ?, workspace_id = ? WHERE id = ?",
            (item_path, workspace_id, SESSION_ID),
        )

    page.set_viewport_size({"width": 1440, "height": 900})
    open_chatview(page, h, workspace_id, SESSION_ID)
    page.locator(".virtual-scroller").first.wait_for(timeout=15000, state="visible")

    card = page.locator(".chat-tool-card").filter(
        has=page.locator('[data-testid="shell-tool-pill"]', has_text="command")
    ).first
    _emit_until_text(h, _event(_tool_envelope(None, workdir)), card, "command")

    card.locator('div[role="button"]').click()
    card.get_by_text("Arguments", exact=True).wait_for(timeout=5000, state="visible")
    assert STDOUT_MARKER not in card.inner_text()

    completed = _tool_envelope(
        {
            "command": "printf '%s\\n' '--- numbered excerpts ---'",
            "stdout": f"{STDOUT_MARKER}\nsecond output line",
            "stderr": "",
            "exit_code": 0,
            "truncated": False,
            "timeout": False,
            "stdout_lines": 2,
            "stderr_lines": 0,
        },
        workdir,
    )
    _emit_until_text(h, _event(completed), card, STDOUT_MARKER)
    assert "second output line" in card.inner_text()
    _wait_for_cached_stdout(page)

    page.reload(wait_until="domcontentloaded", timeout=60000)
    reloaded_card = page.locator(".chat-tool-card").filter(
        has=page.locator('[data-testid="shell-tool-pill"]', has_text="command")
    ).first
    reloaded_card.wait_for(timeout=15000, state="attached")
    reloaded_card.locator('div[role="button"]').click()
    reloaded_card.get_by_text(STDOUT_MARKER, exact=False).wait_for(
        timeout=10000,
        state="visible",
    )
    assert "second output line" in reloaded_card.inner_text()
