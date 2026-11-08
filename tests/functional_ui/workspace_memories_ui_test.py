"""Functional UI test: Settings → Workspace → Memories reads the SQLite rows.

The page used to list `.md` files under `<item-path>/.pabrik/memories/`, so a
workspace whose agent had saved notes with `save_memory` still showed "No
memories yet". It now reads `agent_memories` through
`GET /api/workspaces/:id/memories`.

These tests pin what the user sees: the saved notes render, search narrows
them, a row opens to its full body, delete sticks across a reload, and a note
created in the UI reaches the same table the agent writes to.
"""

from __future__ import annotations

from ui_harness import UIHarness

SETTINGS_PATH = "/app/{workspace_id}/settings?section=memories"


def _create_workspace(h: UIHarness, name: str) -> str:
    return h.http("POST", "/api/workspaces", json_body={"name": name}, expect=201).json()["id"]


def _save_memory(h: UIHarness, workspace_id: str, content: str, tags: list[str]) -> str:
    body = h.http(
        "POST",
        f"/api/workspaces/{workspace_id}/memories",
        json_body={"content": content, "tags": tags},
        expect=201,
    ).json()
    return body["memory"]["id"]


def _list_memories(h: UIHarness, workspace_id: str) -> list[dict]:
    return h.http("GET", f"/api/workspaces/{workspace_id}/memories", expect=200).json()["memories"]


def _open_memories(page, h: UIHarness, workspace_id: str) -> None:
    page.goto(
        h.web_url(SETTINGS_PATH.format(workspace_id=workspace_id)),
        wait_until="domcontentloaded",
        timeout=60000,
    )
    page.wait_for_selector('[data-testid="workspace-memories-panel"]', timeout=30000)


def _row_texts(page) -> list[str]:
    rows = page.locator('[data-testid^="workspace-memories-row-"]')
    return [rows.nth(i).inner_text() for i in range(rows.count())]


def test_saved_memories_render_in_the_settings_page(ui_harness: UIHarness, page) -> None:
    h = ui_harness
    workspace_id = _create_workspace(h, "memories-ui")

    _save_memory(h, workspace_id, "the deploy target is staging", ["ops", "deploy"])
    _save_memory(h, workspace_id, "design tokens live in style.css", ["frontend"])

    _open_memories(page, h, workspace_id)

    page.wait_for_function(
        "() => document.querySelectorAll('[data-testid^=\"workspace-memories-row-\"]').length === 2",
        timeout=15000,
    )

    texts = _row_texts(page)
    assert any("the deploy target is staging" in text for text in texts), texts
    assert any("design tokens live in style.css" in text for text in texts), texts
    assert any("ops" in text for text in texts), texts
    assert any("frontend" in text for text in texts), texts

    assert page.locator('[data-testid="workspace-memories-count"]').inner_text().strip() == "2"
    assert page.locator('[data-testid="empty-state"]').count() == 0


def test_search_narrows_the_list_to_matching_notes(ui_harness: UIHarness, page) -> None:
    h = ui_harness
    workspace_id = _create_workspace(h, "memories-ui-search")

    _save_memory(h, workspace_id, "the deploy target is staging", ["ops"])
    _save_memory(h, workspace_id, "design tokens live in style.css", ["frontend"])

    _open_memories(page, h, workspace_id)
    page.wait_for_function(
        "() => document.querySelectorAll('[data-testid^=\"workspace-memories-row-\"]').length === 2",
        timeout=15000,
    )

    page.locator('[data-testid="workspace-memories-search"]').fill("deploy")
    page.wait_for_function(
        "() => document.querySelectorAll('[data-testid^=\"workspace-memories-row-\"]').length === 1",
        timeout=15000,
    )

    texts = _row_texts(page)
    assert "the deploy target is staging" in texts[0], texts
    assert page.locator('[data-testid="workspace-memories-count"]').inner_text().strip() == "1 match"

    page.locator('[data-testid="workspace-memories-search-clear"]').click()
    page.wait_for_function(
        "() => document.querySelectorAll('[data-testid^=\"workspace-memories-row-\"]').length === 2",
        timeout=15000,
    )


def test_a_row_opens_to_its_full_body(ui_harness: UIHarness, page) -> None:
    h = ui_harness
    workspace_id = _create_workspace(h, "memories-ui-expand")

    body = "first line of the note\nsecond line of the note\nthird line of the note"
    memory_id = _save_memory(h, workspace_id, body, ["ops"])

    _open_memories(page, h, workspace_id)
    row = page.locator(f'[data-testid="workspace-memories-row-{memory_id}"]')
    row.wait_for(state="visible", timeout=15000)

    assert "third line of the note" not in row.inner_text()

    row.locator("button").first.click()
    page.wait_for_function(
        f"""() => {{
            const row = document.querySelector('[data-testid="workspace-memories-row-{memory_id}"]');
            return row && row.innerText.includes('third line of the note');
        }}""",
        timeout=15000,
    )

    assert row.locator(f'[data-testid="workspace-memories-delete-{memory_id}"]').count() == 1


def test_deleting_a_memory_sticks_across_a_reload(ui_harness: UIHarness, page) -> None:
    h = ui_harness
    workspace_id = _create_workspace(h, "memories-ui-delete")

    doomed = _save_memory(h, workspace_id, "this note is about to be deleted", ["temp"])
    _save_memory(h, workspace_id, "this note stays", ["keep"])

    _open_memories(page, h, workspace_id)
    page.wait_for_function(
        "() => document.querySelectorAll('[data-testid^=\"workspace-memories-row-\"]').length === 2",
        timeout=15000,
    )

    page.locator(f'[data-testid="workspace-memories-row-{doomed}"] button').first.click()
    page.locator(f'[data-testid="workspace-memories-delete-{doomed}"]').click()

    page.wait_for_function(
        "() => document.querySelectorAll('[data-testid^=\"workspace-memories-row-\"]').length === 1",
        timeout=15000,
    )

    page.reload(wait_until="domcontentloaded")
    page.wait_for_selector('[data-testid="workspace-memories-panel"]', timeout=30000)
    page.wait_for_function(
        "() => document.querySelectorAll('[data-testid^=\"workspace-memories-row-\"]').length === 1",
        timeout=15000,
    )

    texts = _row_texts(page)
    assert any("this note stays" in text for text in texts), texts
    assert not any("about to be deleted" in text for text in texts), texts

    remaining = _list_memories(h, workspace_id)
    assert [m["content"] for m in remaining] == ["this note stays"], remaining


def test_a_note_created_in_the_ui_reaches_the_same_table(ui_harness: UIHarness, page) -> None:
    h = ui_harness
    workspace_id = _create_workspace(h, "memories-ui-create")

    _open_memories(page, h, workspace_id)
    page.wait_for_selector('[data-testid="empty-state"]', timeout=15000)

    page.locator('[data-testid="workspace-memories-new"]').click()
    page.locator('[data-testid="workspace-memories-create-body"]').fill(
        "cut releases from main on fridays"
    )
    page.locator('[data-testid="workspace-memories-create-tags"]').fill("ops, release")
    page.locator('[data-testid="workspace-memories-create-save"]').click()

    page.wait_for_function(
        "() => document.querySelectorAll('[data-testid^=\"workspace-memories-row-\"]').length === 1",
        timeout=15000,
    )

    stored = _list_memories(h, workspace_id)
    assert len(stored) == 1, stored
    assert stored[0]["content"] == "cut releases from main on fridays", stored
    assert stored[0]["tags"] == ["ops", "release"], stored
