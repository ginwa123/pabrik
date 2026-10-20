"""Sidebar navigation UI tests: kanban rows open the board, settings open a new tab.

Covers the right-click "Go to settings" feature (task_1789493500744_2)
and its follow-ups:

1. ``test_sidebar_click_kanban_opens_board`` — left-clicking a kanban
   workspace item opens its board.
2. ``test_sidebar_rightclick_kanban_go_to_settings_opens_new_tab`` —
   right-click shows "Go to settings"; activating it opens
   ``/app/{workspaceId}/projects/{id}/settings`` in a NEW browser tab
   while the current tab stays put.
3. ``test_sidebar_rightclick_agent_go_to_settings_opens_item_settings``
   — opens the agent's project URL and renders AgentView even when
   localStorage still selects a different workspace.
4. ``test_sidebar_task_then_kanban_opens_board`` — with an agent task
   chat active, clicking a kanban row still opens its board (the
   AppLayout URL-sync watcher must not resurrect the stale
   ``/chat/<taskId>`` suffix onto the new item).

Run:
    PABRIK_BIN=/home/ginwa/ginwaaitoolbox/zig-out/bin/pabrik \
      /home/ginwa/ginwaaitoolbox/.venv-func/bin/python -m pytest \
      tests/functional_ui/kanban_sidebar_open_ui_test.py -v -s
"""

from __future__ import annotations

from harness import harness_path
from ui_harness import UIHarness


def _create_workspace(h: UIHarness, name: str = "ui-kanban-open-ws") -> str:
    r = h.http("POST", "/api/workspaces", json_body={"name": name}, expect=201)
    return r.json()["id"]


def _create_kanban(h: UIHarness, workspace_id: str, name: str = "UIOPEN_BOARD") -> str:
    r = h.http(
        "POST",
        f"/api/workspaces/{workspace_id}/items/kanban",
        json_body={"name": name},
        expect=201,
    )
    return r.json()["item"]["id"]


def _create_agent(h: UIHarness, workspace_id: str, name: str = "UIAGENT_ITEM") -> str:
    r = h.http(
        "POST",
        f"/api/workspaces/{workspace_id}/items/agent",
        json_body={"name": name, "path": harness_path(h, "ui-kanban-after-task-agent")},
        expect=201,
    )
    return r.json()["item"]["id"]


def _create_agent_task(h: UIHarness, workspace_id: str, agent_id: str, name: str) -> str:
    r = h.http(
        "POST",
        f"/api/workspaces/{workspace_id}/items/{agent_id}/tasks",
        json_body={"name": name},
        expect=201,
    )
    body = r.json()
    return body.get("id", body.get("task", {}).get("id", ""))


def _collect_errors(page) -> list[str]:
    errors: list[str] = []
    page.on("console", lambda msg: errors.append(msg.text) if msg.type == "error" else None)
    page.on("pageerror", lambda exc: errors.append(str(exc)))
    return errors


def _print_errors(errors: list[str]) -> None:
    if errors:
        print("\n[console errors]")
        for e in errors:
            print(f"  - {e[:300]}")


def _expand_workspace(page, ws_name: str, item_name: str) -> None:
    """Make a sidebar item row visible, expanding its workspace if needed."""
    page.locator(f"text={ws_name}").first.wait_for(timeout=20000, state="visible")
    item_row = page.locator(f"text={item_name}").first
    try:
        item_row.wait_for(timeout=3000, state="visible")
    except Exception:
        page.locator(f"text={ws_name}").first.click()
        item_row.wait_for(timeout=10000, state="visible")


def test_sidebar_click_kanban_opens_board(ui_harness: UIHarness, page) -> None:
    """Clicking the kanban row in the sidebar opens its board."""
    h = ui_harness
    ws_id = _create_workspace(h)
    kanban_id = _create_kanban(h, ws_id)

    errors = _collect_errors(page)
    page.goto(h.web_url("/app"), wait_until="domcontentloaded", timeout=60000)
    _expand_workspace(page, "ui-kanban-open-ws", "UIOPEN_BOARD")
    page.locator("text=UIOPEN_BOARD").first.click()

    board = page.locator(f'[data-testid="kanban-view-{kanban_id}-columns"]')
    try:
        board.wait_for(timeout=20000, state="visible")
    finally:
        _print_errors(errors)
    assert board.is_visible(), (
        f"Kanban board did not open after sidebar click "
        f"(ws={ws_id}, kanban={kanban_id}). See console errors above / artifacts screenshot."
    )


def test_sidebar_rightclick_kanban_go_to_settings_opens_new_tab(
    ui_harness: UIHarness, page
) -> None:
    """Right-clicking the kanban row shows Go to settings; it opens a new tab."""
    h = ui_harness
    ws_id = _create_workspace(h, name="ui-kanban-menu-ws")
    kanban_id = _create_kanban(h, ws_id, name="UIMENU_BOARD")

    errors = _collect_errors(page)
    page.goto(h.web_url("/app"), wait_until="domcontentloaded", timeout=60000)
    _expand_workspace(page, "ui-kanban-menu-ws", "UIMENU_BOARD")
    page.locator("text=UIMENU_BOARD").first.click(button="right")

    entry = page.locator('[data-testid="go-to-settings-item"]')
    entry.wait_for(timeout=10000, state="visible")

    with page.expect_popup() as popup_info:
        entry.click()
    popup = popup_info.value
    popup.wait_for_load_state("domcontentloaded", timeout=60000)
    try:
        assert f"/app/{ws_id}/projects/{kanban_id}/settings" in popup.url, (
            f"Settings popup opened at unexpected URL: {popup.url}"
        )
        # The current tab must stay put (never navigates to settings itself).
        assert "/settings" not in page.url, f"Current tab navigated: {page.url}"
    finally:
        popup.close()
        _print_errors(errors)


def test_sidebar_rightclick_agent_go_to_settings_opens_item_settings(
    ui_harness: UIHarness, page
) -> None:
    """Go to settings opens AgentView in a fresh browser tab.

    The persisted workspace deliberately points at another workspace.
    A new tab must hydrate the workspace encoded in the project URL so
    the agent configuration surface renders instead of a blank main view.
    """
    h = ui_harness
    persisted_ws_id = _create_workspace(h, name="ui-agent-settings-persisted-ws")
    target_ws_id = _create_workspace(h, name="ui-agent-settings-target-ws")
    agent_id = _create_agent(h, target_ws_id, name="UISETTINGS_AGENT")

    errors = _collect_errors(page)
    page.goto(h.web_url("/app"), wait_until="domcontentloaded", timeout=60000)
    page.locator('[data-testid="workspace-switcher-trigger"]').wait_for(
        timeout=20000, state="visible"
    )
    page.locator('[data-testid="workspace-switcher-trigger"]').click()
    page.locator(f'[data-testid="workspace-switcher-option-{target_ws_id}"]').click()
    _expand_workspace(page, "ui-agent-settings-target-ws", "UISETTINGS_AGENT")
    # Keep the source page showing the target workspace, but make its
    # persisted selection stale before the popup boots. This reproduces
    # a fresh browser tab whose URL and localStorage point at different
    # workspaces without reloading the source page.
    page.evaluate(
        "workspaceId => localStorage.setItem('pabrik-active-workspace', workspaceId)",
        persisted_ws_id,
    )
    page.locator("text=UISETTINGS_AGENT").first.click(button="right")

    entry = page.locator('[data-testid="go-to-settings-item"]')
    entry.wait_for(timeout=10000, state="visible")
    original_url = page.url

    with page.expect_popup() as popup_info:
        entry.click()
    popup = popup_info.value
    popup_errors = _collect_errors(popup)
    popup.wait_for_load_state("domcontentloaded", timeout=60000)
    try:
        expected_path = f"/app/{target_ws_id}/projects/{agent_id}"
        popup.wait_for_url(f"**{expected_path}", timeout=60000)
        popup.locator('[data-testid="agent-view"]').wait_for(timeout=60000, state="visible")
        assert expected_path in popup.url, (
            f"Agent settings popup opened at unexpected URL: {popup.url}"
        )
        assert page.url == original_url, (
            f"Current tab navigated while opening agent settings: {original_url} -> {page.url}"
        )
        assert local_storage_value(popup, "pabrik-active-workspace") == target_ws_id, (
            "Agent settings popup did not select the workspace encoded in its URL"
        )
    finally:
        popup.close()
        _print_errors(errors)
        _print_errors(popup_errors)


def local_storage_value(page, key: str) -> str | None:
    return page.evaluate("key => localStorage.getItem(key)", key)


def test_sidebar_task_then_kanban_opens_board(ui_harness: UIHarness, page) -> None:
    """Select an agent task (chat opens), then click the kanban row.

    Regression for: with a task chat active, clicking a kanban
    workspace item must still open its board (the AppLayout URL-sync
    watcher must not resurrect the stale /chat/<taskId> suffix onto
    the new item — the chat branch would shadow the board).
    """
    h = ui_harness
    ws_id = _create_workspace(h, name="ui-kanban-after-task-ws")
    agent_id = _create_agent(h, ws_id)
    _create_agent_task(h, ws_id, agent_id, "UITASK_CHAT")
    kanban_id = _create_kanban(h, ws_id, "UITASK_BOARD")

    errors = _collect_errors(page)
    page.goto(h.web_url("/app"), wait_until="domcontentloaded", timeout=60000)
    _expand_workspace(page, "ui-kanban-after-task-ws", "UIAGENT_ITEM")

    # Expand the agent item so its task row is visible, then select it.
    agent_row = page.locator("text=UIAGENT_ITEM").first
    task_row = page.locator("text=UITASK_CHAT").first
    try:
        task_row.wait_for(timeout=3000, state="visible")
    except Exception:
        agent_row.click()
        task_row.wait_for(timeout=10000, state="visible")
    task_row.click()
    page.wait_for_timeout(2000)

    # Now click the kanban row: the board must take over the main view.
    page.locator("text=UITASK_BOARD").first.click()

    board = page.locator(f'[data-testid="kanban-view-{kanban_id}-columns"]')
    try:
        board.wait_for(timeout=20000, state="visible")
    finally:
        _print_errors(errors)
    assert board.is_visible(), (
        f"Kanban board did not open after task-then-kanban clicks "
        f"(ws={ws_id}, kanban={kanban_id}). See console errors above / artifacts screenshot."
    )
