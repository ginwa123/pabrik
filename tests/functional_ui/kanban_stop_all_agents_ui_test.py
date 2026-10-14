"""Functional UI test for the column "Stop all agents" bulk button.

Mirrors the "Run all agents" menu flow from the user's screenshot: the
column "⋮" menu offers Rename / Sort tasks… / Delete / Run all agents /
Stop all agents. This test drives the real Vue components via Playwright:

  1. Boot a fresh pabrik + Vite via the ``ui_harness`` fixture.
  2. Pre-create a workspace + kanban + 3 tasks in the first ("todo")
     column via the backend's HTTP API.
  3. Open the kanban in a real browser.
  4. Open the column "⋮" menu and verify the "Stop all agents" item
     renders alongside "Run all agents".
  5. Accept the ``confirm()`` gate, click "Stop all agents", and verify
     the summary banner appears with the stopped/skipped/failed counts.

This validates:
  - The menu item is wired (emit → host handler → store → bulk endpoint).
  - The ``confirm()`` gate does not block the Playwright click path
    (the test registers a dialog handler that accepts).
  - The summary banner renders with the server's counts (idle column →
    "Stopped 0, skipped 3 (not running), failed 0.").

Note: Playwright auto-dismisses ``confirm()`` dialogs unless a handler
is registered — without ``page.on("dialog", ...)`` the handler's
``if (!confirm(...)) return`` would abort and no banner would appear.
"""

from __future__ import annotations

from typing import Any

from ui_harness import UIHarness


# ─── Helpers ────────────────────────────────────────────────────────────────


def _create_workspace(h: UIHarness, name: str = "ui-stop-all-ws") -> str:
    r = h.http("POST", "/api/workspaces", json_body={"name": name}, expect=201)
    return r.json()["id"]


def _create_kanban(h: UIHarness, workspace_id: str, name: str = "ui stop-all sprint") -> str:
    r = h.http(
        "POST",
        f"/api/workspaces/{workspace_id}/items/kanban",
        json_body={"name": name},
        expect=201,
    )
    return r.json()["item"]["id"]


def _first_column(h: UIHarness, workspace_id: str, kanban_id: str) -> dict[str, Any]:
    r = h.http(
        "GET",
        f"/api/workspaces/{workspace_id}/items/{kanban_id}/kanban/columns",
        expect=200,
    )
    columns = r.json()["columns"]
    assert columns, "expected seeded kanban columns, got none"
    return columns[0]


def _create_task(
    h: UIHarness, workspace_id: str, kanban_id: str, name: str, column_id: str
) -> str:
    r = h.http(
        "POST",
        f"/api/workspaces/{workspace_id}/items/{kanban_id}/tasks",
        json_body={"name": name, "column_id": column_id},
        expect=201,
    )
    return r.json()["id"]


def _seed_column_with_three_tasks(h: UIHarness) -> tuple[str, str, str]:
    """Create workspace → kanban → 3 tasks in the first column.

    Returns (workspace_id, kanban_id, column_id).
    """
    ws_id = _create_workspace(h)
    kanban_id = _create_kanban(h, ws_id)
    column = _first_column(h, ws_id, kanban_id)
    for i in range(3):
        _create_task(h, ws_id, kanban_id, f"bulk-stop-task-{i}", column["id"])
    return ws_id, kanban_id, column["id"]


def _kanban_url(h: UIHarness, workspace_id: str, kanban_id: str) -> str:
    """Build the URL the Vue app uses for a kanban item (see kanban_lifecycle_ui_test.py)."""
    return h.web_url(f"/app?view=workspace&workspaceId={workspace_id}&itemId={kanban_id}")


def _open_board(page, h: UIHarness, ws_id: str, kanban_id: str) -> None:
    url = _kanban_url(h, ws_id, kanban_id)
    # ``domcontentloaded`` not ``networkidle``: Vite's HMR keeps a
    # persistent WebSocket open that prevents networkidle from ever firing.
    page.goto(url, wait_until="domcontentloaded", timeout=60000)
    page.wait_for_timeout(1000)  # give Vue + API calls time to settle


def _open_column_menu(page, column_id: str):
    trigger = page.locator(f'[data-testid="kanban-column-{column_id}-menu-trigger"]').first
    assert trigger.count() > 0, (
        f"Column menu trigger (data-testid='kanban-column-{column_id}-menu-trigger') "
        f"not found. The board may not have rendered, or the testid moved — "
        f"check KanbanColumn.vue."
    )
    trigger.click()
    page.wait_for_timeout(300)


# ─── Tests ──────────────────────────────────────────────────────────────────


def test_column_menu_offers_stop_all_agents(ui_harness: UIHarness, page) -> None:
    """The column ⋮ menu renders a Stop all agents item after Run all agents."""
    h = ui_harness
    ws_id, kanban_id, column_id = _seed_column_with_three_tasks(h)
    _open_board(page, h, ws_id, kanban_id)
    _open_column_menu(page, column_id)

    run_all = page.locator(f'[data-testid="kanban-column-{column_id}-menu-run-all"]').first
    assert run_all.count() > 0 and run_all.is_visible(), (
        "Run all agents menu item missing — the menu structure may have changed"
    )
    stop_all = page.locator(f'[data-testid="kanban-column-{column_id}-menu-stop-all"]').first
    assert stop_all.count() > 0 and stop_all.is_visible(), (
        "Stop all agents menu item missing (data-testid="
        f"'kanban-column-{column_id}-menu-stop-all'). Check KanbanColumn.vue."
    )
    assert "Stop all agents" in (stop_all.inner_text() or ""), (
        f"Stop-all item has unexpected label: {stop_all.inner_text()!r}"
    )


def test_stop_all_agents_click_shows_summary_banner(ui_harness: UIHarness, page) -> None:
    """Clicking Stop all agents (confirm accepted) renders the summary banner.

    Idle column → no worker rows → the server reports stopped=0, skipped=3.
    """
    h = ui_harness
    ws_id, kanban_id, column_id = _seed_column_with_three_tasks(h)
    _open_board(page, h, ws_id, kanban_id)

    # The host handler gates on confirm() — Playwright dismisses dialogs
    # by default, which would abort the flow. Accept it instead.
    page.on("dialog", lambda dialog: dialog.accept())
    _open_column_menu(page, column_id)

    stop_all = page.locator(f'[data-testid="kanban-column-{column_id}-menu-stop-all"]').first
    assert stop_all.count() > 0, "Stop all agents menu item not found"
    stop_all.click()

    banner = page.locator(f'[data-testid="kanban-view-{kanban_id}-run-all-summary"]').first
    banner.wait_for(timeout=10000, state="visible")
    text = banner.inner_text() or ""
    assert "Stopped 0" in text, (
        f"Expected 'Stopped 0' in summary banner, got {text!r}. "
        f"Backend log: {h.log_path}."
    )
    assert "skipped 3" in text, (
        f"Expected 'skipped 3' in summary banner, got {text!r}. "
        f"Backend log: {h.log_path}."
    )
