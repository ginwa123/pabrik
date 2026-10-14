"""Functional UI evidence: a remote kanban move refreshes ONE row, not limit=100.

Covers the kanbanSse single-row fast path (follow-up to the self-echo
dedupe): when a ``kanban_task moved`` SSE event arrives for a task that
is already cached and the board is on the default view, the browser must
confirm with a single-row ``GET .../tasks/<id>`` instead of the blind
``GET .../tasks?limit=100&column_id=...`` column refetch.

The test drives the REAL wire loop:

  1. Seed workspace + kanban + one task (in "todo") via the backend API.
  2. Open the board in a real Chromium page and wait until the task card
     renders (proves mount + initial per-column fetches settled).
  3. Start capturing the page's ``/api/workspaces`` traffic.
  4. Move the task to "in progress" via ``PATCH .../tasks/<id>/move``
     from the test process — i.e. a REMOTE move from the browser's
     point of view, exactly what the agent's ``kanban_move_task`` tool
     (or a second tab) produces.
  5. Wait for the browser's single-row ``GET .../tasks/<id>`` (the SSE
     round-trip → mirror → refreshTask chain).
  6. Assert ZERO ``GET .../tasks?...`` list fetches happened after the
     move, and that the card is still rendered.

Against the pre-fix frontend this fails at step 6: the SSE handler
fired ``tasks?limit=100&column_id=<dest>`` on every move event.
"""

from __future__ import annotations

import time
from urllib.parse import urlparse

from ui_harness import UIHarness


# ─── Helpers (mirrored from kanban_lifecycle_ui_test.py) ────────────────────


def _create_workspace(h: UIHarness, name: str = "ui-kanban-singlerow-ws") -> str:
    r = h.http("POST", "/api/workspaces", json_body={"name": name}, expect=201)
    return r.json()["id"]


def _create_kanban(h: UIHarness, workspace_id: str, name: str = "ui sprint") -> str:
    r = h.http(
        "POST",
        f"/api/workspaces/{workspace_id}/items/kanban",
        json_body={"name": name},
        expect=201,
    )
    return r.json()["item"]["id"]


def _kanban_url(h: UIHarness, workspace_id: str, kanban_id: str) -> str:
    return h.web_url(f"/app?view=workspace&workspaceId={workspace_id}&itemId={kanban_id}")


def _is_single_task_get(url: str, task_id: str) -> bool:
    """GET /api/.../tasks/<task_id> with NO query string (api.getTask)."""
    parts = urlparse(url)
    return (
        parts.path.endswith(f"/tasks/{task_id}")
        and parts.query == ""
    )


def _is_task_list_get(url: str) -> bool:
    """GET /api/.../tasks?... (fetchKanbanTasks / fetchKanbanTasksForAllColumns)."""
    parts = urlparse(url)
    return parts.path.endswith("/tasks") and parts.query != ""


# ─── Test ───────────────────────────────────────────────────────────────────


def test_remote_move_refreshes_single_row_not_limit_100(
    ui_harness: UIHarness, page
) -> None:
    """A remote move must refresh 1 row, never a tasks?limit=100 column fetch."""
    h = ui_harness
    ws_id = _create_workspace(h)
    kanban_id = _create_kanban(h, ws_id)

    r = h.http(
        "GET",
        f"/api/workspaces/{ws_id}/items/{kanban_id}/kanban/columns",
        expect=200,
    )
    columns = r.json()["columns"]
    todo = next(c for c in columns if c["name"].lower() == "todo")
    in_progress = next(c for c in columns if c["name"].lower() == "in progress")

    task_title = "single-row-refresh-me"
    task_id = h.http(
        "POST",
        f"/api/workspaces/{ws_id}/items/{kanban_id}/tasks",
        json_body={"name": task_title, "column_id": todo["id"]},
        expect=201,
    ).json()["id"]

    # Open the board; wait until the card renders (mount fetches settled).
    page.goto(_kanban_url(h, ws_id, kanban_id), wait_until="domcontentloaded", timeout=60000)
    page.locator(f"text={task_title}").first.wait_for(timeout=20000)
    page.wait_for_timeout(1500)  # let mount traffic + SSE connect settle

    # Capture the page's workspace-API traffic from here on.
    captured: list[str] = []
    page.on(
        "request",
        lambda req: captured.append(req.url)
        if "/api/workspaces" in req.url and req.method == "GET"
        else None,
    )

    # REMOTE move (from the browser's perspective): PATCH from the test
    # process, exactly like the agent's kanban_move_task tool would.
    move_resp = h.http(
        "PATCH",
        f"/api/workspaces/{ws_id}/items/{kanban_id}/tasks/{task_id}/move",
        json_body={"column_id": in_progress["id"], "position": 0},
        expect=200,
    ).json()
    assert move_resp["success"] is True

    # Wait for the browser's single-row confirm (SSE → mirror → refreshTask).
    deadline = time.monotonic() + 20.0
    while time.monotonic() < deadline:
        if any(_is_single_task_get(u, task_id) for u in captured):
            break
        page.wait_for_timeout(200)
    single_row_gets = [u for u in captured if _is_single_task_get(u, task_id)]
    assert single_row_gets, (
        f"Browser never issued GET .../tasks/{task_id} after the remote move. "
        f"Captured workspace GETs: {captured!r}. Either the SSE event never "
        f"reached the page, or the fast path did not fire."
    )

    # Give any straggler column fetch time to appear, then assert none did.
    page.wait_for_timeout(2500)
    list_gets = [u for u in captured if _is_task_list_get(u)]
    assert not list_gets, (
        f"Browser fired {len(list_gets)} task-LIST fetch(es) after a remote move "
        f"(expected only the single-row refresh): {list_gets!r}. "
        f"Full captured traffic: {captured!r}."
    )

    # The card converged: still rendered after the move + refresh.
    assert page.locator(f"text={task_title}").count() > 0, (
        f"Task {task_title!r} disappeared from the board after the remote move."
    )
