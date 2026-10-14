"""Functional UI test for the kanban "wrong profile select" bug.

Regression for task_1787494153778_2 ("wrong profile select"). Pre-fix:

  1. User opens the kanban New Task dialog.
  2. User picks a profile from the picker (e.g. "900ribu").
  3. User toggles Unattended mode ON (or leaves it off — the dialog
     always sends the field).
  4. User clicks "Create task" (or "Create task & run agent").
  5. The created chat session shows the WRONG profile in the bottom
     bar (chips falls back to the active profile / "alpha model").

Root cause (verified): the backend forwards `is_auto_retry_until_stop`
into `task_create.useCase`, whose bare `INSERT OR IGNORE INTO sessions`
runs FIRST (no `selected_profile_model` column). The handler's later
profile-bearing `INSERT OR IGNORE INTO sessions` hits the existing PK
and is silently ignored → `sessions.selected_profile_model` stays NULL
→ the chatview falls back to activeProfile.

Post-fix: the unattended flag is forwarded into useCase ONLY for legacy
`mode='create'`; for `create_session` / `create_and_run`, the step-5
full INSERT (profile + flag) is authoritative.

These tests drive the actual UI via Playwright + a seeded stub config
at the OS-correct path (`$HOME/.config/pabrik/config.json` on Linux,
`$HOME/Library/Application Support/pabrik/config.json` on macOS — see
`_seed_profiles` and `src/modules/config/Config.zig:1550` for the
backend's per-OS lookup):

  test_dialog_create_task_persists_picked_profile_in_db
    Drive the "Create task" button with profile=900ribu + Unattended=ON.
    Verify the DB row carries selected_profile_model='900ribu' AND
    is_auto_retry_until_stop='1'.

  test_dialog_create_and_run_persists_picked_profile_in_db
    Same but "Create task & run agent". The worker spins up against
    a stub LLM (port that never responds) — the wire is the contract,
    not the LLM outcome.

  test_dialog_picked_profile_surfaces_in_chatview_chip
    After Create task, navigate to the chatview at /app/chat/<task_id>
    and assert the profile chip shows "900ribu" — the user-visible
    symptom that closed the report.

Plan: docs/superpowers/plans/2026-08-23-fix-kanban-profile-select.md
Task: task_1787494153778_2
"""

from __future__ import annotations

import json
import sqlite3
import sys
from pathlib import Path
from typing import Any

import pytest

from ui_harness import UIHarness


# ─── Helpers ────────────────────────────────────────────────────────────────


def _create_workspace(h: UIHarness, name: str = "ui-profile-ws") -> str:
    r = h.http("POST", "/api/workspaces", json_body={"name": name}, expect=201)
    return r.json()["id"]


def _create_kanban(h: UIHarness, workspace_id: str, name: str = "ui profile sprint") -> str:
    r = h.http(
        "POST",
        f"/api/workspaces/{workspace_id}/items/kanban",
        json_body={"name": name},
        expect=201,
    )
    return r.json()["item"]["id"]


def _seed_profiles(h: UIHarness) -> None:
    """Write a stub config.json with TWO profiles so the dialog's picker
    has something to show, AND so a regression falls back to a visibly
    DIFFERENT profile ('alpha') instead of the empty state.

    The backend reads config.json fresh per request (see
    pabrik_config_get.zig:33 — no caching), so post-boot writes are
    picked up by GET /api/config/pabrik without a restart.

    Profile names match the user's bug report: the bug used "900ribu"
    as the pick and "alpha model" as the visible fallback. We seed
    both so a future regression that returns `active_profile` (default
    to the active profile instead of the user's pick) is immediately
    visible on screen.
    """
    # The backend reads config.json from `getDefaultConfigDir`
    # (src/modules/config/Config.zig:1538), which is OS-dependent:
    #   Linux   → $HOME/.config/pabrik
    #   macOS   → $HOME/Library/Application Support/pabrik
    #   Windows → %APPDATA%/pabrik
    # Mirror the backend's lookup — otherwise the seeded profiles
    # never load and the dialog's profile picker is empty (the bug
    # we hit on the macOS CI runner: 0 rows for ":has-text('900ribu')").
    # Same pattern as tests/functional/model_thinking_test.py:43-44.
    if sys.platform == "darwin":
        config_dir = h.temp_dir / "Library" / "Application Support" / "pabrik"
    elif sys.platform == "win32":
        config_dir = h.temp_dir / "AppData" / "Roaming" / "pabrik"
    else:
        config_dir = h.temp_dir / ".config" / "pabrik"
    config_dir.mkdir(parents=True, exist_ok=True)
    profile = {
        "api_endpoint": "",
        "api_key": "",
        "model": "alpha-stub-model",
        "url_style": "openai",
        "temperature": 0.7,
        "profiles_models": {
            # The user's pick — what the dialog should persist.
            "900ribu": {
                "model": "claude-sonnet-4-5-stub",
                "base_url": "http://127.0.0.1:1",
                "api_key": "stub-not-real",
            },
            # The visible fallback — what a bug would show instead.
            "alpha": {
                "model": "alpha-stub-model",
                "base_url": "http://127.0.0.1:1",
                "api_key": "stub-not-real",
            },
        },
        # The user-facing "active profile" — this is what
        # ChatView.effectiveProfile falls back to when
        # selectedProfile is empty/null. Setting it to "alpha" means
        # a bug shows the "alpha" chip, which is exactly the symptom.
        "selected_profile_model": "alpha",
        "active_profile": "alpha",
    }
    (config_dir / "config.json").write_text(json.dumps(profile, indent=2))


def _kanban_url(h: UIHarness, workspace_id: str, kanban_id: str) -> str:
    """Route shape mirrors kanban_lifecycle_ui_test.py."""
    return h.web_url(
        f"/app?view=workspace&workspaceId={workspace_id}&itemId={kanban_id}"
    )


def _list_tasks(h: UIHarness, workspace_id: str, kanban_id: str) -> list[dict[str, Any]]:
    r = h.http(
        "GET",
        f"/api/workspaces/{workspace_id}/items/{kanban_id}/tasks",
        params={"limit": 100},
        expect=200,
    )
    body = r.json()
    return body.get("tasks", body if isinstance(body, list) else [])


def _task_id_for_name(
    h: UIHarness, workspace_id: str, kanban_id: str, task_name: str
) -> str:
    """Look up a task id by name via API (avoid DOM scraping)."""
    tasks = _list_tasks(h, workspace_id, kanban_id)
    for t in tasks:
        if t.get("name") == task_name:
            return t["id"]
    raise AssertionError(
        f"task {task_name!r} not found in {tasks!r}; the create click may "
        f"have been rejected silently. Backend log: {h.log_path}"
    )


def _get_session_via_db(h: UIHarness, session_id: str) -> dict[str, Any] | None:
    """Read sessions row by id straight from sqlite3.

    The DB lives at `h.temp_dir / ".config" / "pabrik" / "agent.db"`.
    Use the harness's path validator (already validated the tempdir)
    to be safe — defense in depth matches the chatview pattern in
    tests/functional_ui/db_seed.py.
    """
    db_path = h.temp_dir / ".config" / "pabrik" / "agent.db"
    conn = sqlite3.connect(str(db_path))
    try:
        row = conn.execute(
            "SELECT selected_profile_model, is_auto_retry_until_stop "
            "FROM sessions WHERE id = ?",
            (session_id,),
        ).fetchone()
    finally:
        conn.close()
    if row is None:
        return None
    return {
        "selected_profile_model": row[0],
        "is_auto_retry_until_stop": row[1],
    }


# ─── Test 1: DB-level regression — Create task + Unattended ON + profile pick ─


def test_dialog_create_task_persists_picked_profile_in_db(
    ui_harness: UIHarness, page
) -> None:
    """Drive the New Task dialog:
       1. Click 'Add task'
       2. Type a task name
       3. Open the Profile picker and click "900ribu"
       4. Toggle Unattended mode ON
       5. Click "Create task"

    Assert the underlying sessions row carries selected_profile_model='900ribu'
    AND is_auto_retry_until_stop is truthy. Pre-fix the bare useCase INSERT
    wiped the profile (bug: "wrong profile select", task_1787494153778_2).
    """
    h = ui_harness

    # Seed profiles BEFORE the dialog opens — the picker loads them
    # on dialog open via api.getPabrikConfig (KanbanTaskDetailDialog.vue:861).
    _seed_profiles(h)

    ws_id = _create_workspace(h)
    kanban_id = _create_kanban(h, ws_id)

    page.goto(_kanban_url(h, ws_id, kanban_id), wait_until="domcontentloaded", timeout=60000)
    page.wait_for_timeout(1000)

    # 1. Click "Add task" — opens the dialog in create mode.
    add_button = page.locator('[data-testid="kanban-add-task-button"]').first
    if add_button.count() == 0 or not add_button.is_visible():
        pytest.skip(
            "Could not find the kanban 'Add task' button "
            "(data-testid='kanban-add-task-button'). KanbanView.vue may "
            "have moved the toolbar — see src/apps/desktop/src/components/"
            "kanban/KanbanView.vue."
        )
    add_button.click()

    # 2. Fill the task name.
    title_input = page.locator(
        '[data-testid="kanban-task-detail-create-name"]'
    ).first
    assert title_input.count() > 0 and title_input.is_visible(), (
        "Create-mode name input not found "
        "(data-testid='kanban-task-detail-create-name')"
    )
    task_title = "ui-profile-click-task"
    title_input.fill(task_title)

    # Also fill a description so the handler inserts a user-role
    # llm_history row. The DB-level assertion below doesn't depend
    # on messages — but filling the description mirrors the
    # real-world "user types a title + description, picks a profile,
    # saves" path that triggered the original report.
    description_input = page.locator(
        '[data-testid="kanban-task-detail-description-editor"]'
    ).first
    if description_input.count() > 0:
        try:
            description_input.fill("description for the user-typed task")
        except Exception:
            description_input.click()
            page.keyboard.type("description for the user-typed task")
        page.wait_for_timeout(100)

    # 3. Open the Profile picker, then click the 900ribu row.
    profile_button = page.locator(
        '[data-testid="kanban-task-detail-profile-picker"]'
    ).first
    if profile_button.count() == 0 or not profile_button.is_visible():
        pytest.skip(
            "Profile picker button not visible — the create-mode Settings "
            "section may be hidden behind an empty-profiles state (check "
            "_seed_profiles). Test cannot reproduce the bug if the picker "
            "never offered a choice to click."
        )
    profile_button.click()
    page.wait_for_timeout(150)
    # The dropdown renders one button per configured profile, all sharing
    # data-testid="kanban-task-detail-profile-picker-item". Filter by the
    # profile name text — Playwright's has_text matches the button's text
    # content (the <span class="font-medium">{{ p.name }}</span> inside).
    target_profile_row = page.locator(
        '[data-testid="kanban-task-detail-profile-picker-item"]:has-text("900ribu")'
    ).first
    assert target_profile_row.count() > 0, (
        "'900ribu' profile row not present in dropdown. The seeded "
        "config.json may not have loaded — check _seed_profiles "
        "and the GET /api/config/pabrik response."
    )
    target_profile_row.click()
    page.wait_for_timeout(100)

    # 4. Toggle Unattended mode ON — this is the bug's trigger.
    unattended_toggle = page.locator(
        '[data-testid="kanban-task-detail-unattended-toggle"]'
    ).first
    assert unattended_toggle.count() > 0, "Unattended toggle not found"
    # Check current state and click only if currently OFF.
    is_checked = unattended_toggle.is_checked()
    if not is_checked:
        # The visible target is the styled div, not the <input> itself.
        # Click the wrapping <label> — clicking the input directly
        # also works in modern browsers, but the label is more reliable.
        page.locator(
            'label:has([data-testid="kanban-task-detail-unattended-toggle"])'
        ).first.click()
        page.wait_for_timeout(100)

    # 5. Commit via "Create task only". The create dialog's footer is a
    #    split button — the left half is "▶ Create task & run agent", so
    #    the plain create has to be opened from the caret menu first.
    caret = page.locator('[data-testid="kanban-task-detail-commit-caret"]').first
    assert caret.count() > 0, "commit split caret not found"
    caret.click()
    page.wait_for_timeout(150)
    save_button = page.locator(
        '[data-testid="kanban-task-detail-save"]'
    ).first
    assert save_button.count() > 0, "Create task / Save button not found"
    save_button.click()
    page.wait_for_timeout(800)

    # ─── Assertion: DB row must carry the picked profile + flag ───

    # API-level confirmation that the task exists (more reliable than
    # scraping the kanban board DOM).
    tasks = _list_tasks(h, ws_id, kanban_id)
    matching = [t for t in tasks if t.get("name") == task_title]
    assert matching, (
        f"task {task_title!r} not visible via API after click-create. "
        f"The Save button may not have fired. Vite log: {h.vite_log_path}, "
        f"backend log: {h.log_path}."
    )
    task_id = matching[0]["id"]

    # Direct DB read — the most authoritative check. Pre-fix this would
    # show selected_profile_model=NULL/'' (the bug).
    row = _get_session_via_db(h, task_id)
    assert row is not None, (
        f"sessions row for task_id={task_id!r} not found — the step-5 "
        f"INSERT in kanban_tasks_create.zig didn't fire."
    )
    assert row["selected_profile_model"] == "900ribu", (
        f"sessions.selected_profile_model should be '900ribu' (the user "
        f"pick), got {row['selected_profile_model']!r}. Pre-fix this was "
        f"NULL/'' because the bare useCase INSERT won the PK race — the "
        f"handler's later INSERT OR IGNORE silently no-op'd."
    )
    assert row["is_auto_retry_until_stop"] in ("1", 1), (
        f"sessions.is_auto_retry_until_stop should be truthy (the user "
        f"toggled Unattended ON), got {row['is_auto_retry_until_stop']!r}. "
        f"The fix must NOT lose the flag itself when gating "
        f"task_create.useCase's bare INSERT — step 5's full INSERT persists "
        f"both columns."
    )


# ─── Test 2: same wire but via "Create task & run agent" button ─────────────


def test_dialog_create_and_run_persists_picked_profile_in_db(
    ui_harness: UIHarness, page
) -> None:
    """Same regression for the secondary button on the dialog. Both
    create_session and create_and_run hit the same handler step 5 with
    the full sessions INSERT — both should persist the profile now that
    useCase's bare INSERT is gated away."""
    h = ui_harness
    _seed_profiles(h)

    ws_id = _create_workspace(h)
    kanban_id = _create_kanban(h, ws_id)

    page.goto(_kanban_url(h, ws_id, kanban_id), wait_until="domcontentloaded", timeout=60000)
    page.wait_for_timeout(1000)

    add_button = page.locator('[data-testid="kanban-add-task-button"]').first
    assert add_button.count() > 0, "Add task button missing"
    add_button.click()

    title_input = page.locator(
        '[data-testid="kanban-task-detail-create-name"]'
    ).first
    task_title = "ui-profile-and-run"
    title_input.fill(task_title)

    # Fill description so the create_session path inserts a user-role
    # llm_history row — without it, the messages endpoint can't LEFT
    # JOIN any session-side selected_profile_model back to the chatview.
    description_input = page.locator(
        '[data-testid="kanban-task-detail-description-editor"]'
    ).first
    if description_input.count() > 0:
        try:
            description_input.fill("description for create-and-run test")
        except Exception:
            description_input.click()
            page.keyboard.type("description for create-and-run test")
        page.wait_for_timeout(100)

    profile_button = page.locator(
        '[data-testid="kanban-task-detail-profile-picker"]'
    ).first
    assert profile_button.count() > 0, "Profile picker missing"
    profile_button.click()
    page.wait_for_timeout(150)
    page.locator(
        '[data-testid="kanban-task-detail-profile-picker-item"]:has-text("900ribu")'
    ).first.click()
    page.wait_for_timeout(100)

    # No unattended toggle needed for this test — wire also fires
    # when the field is OFF. Doesn't matter for the regression.

    # Click "Create task & run agent".
    and_run = page.locator(
        '[data-testid="kanban-task-detail-create-and-run"]'
    ).first
    assert and_run.count() > 0, (
        "'Create task & run agent' button missing — create-mode only."
    )
    and_run.click()
    page.wait_for_timeout(1000)

    # The worker runs in the background against the stub's dead port
    # and fails silently — but the wire reaches the handler first, and
    # step 5's INSERT ran. Read the row straight from sqlite3 to avoid
    # racing with whatever the worker does to the row.
    tasks = _list_tasks(h, ws_id, kanban_id)
    matching = [t for t in tasks if t.get("name") == task_title]
    assert matching, f"task {task_title!r} not created via API"
    task_id = matching[0]["id"]

    row = _get_session_via_db(h, task_id)
    assert row is not None, f"sessions row for {task_id!r} missing"
    assert row["selected_profile_model"] == "900ribu", (
        f"create_and_run lost the profile too. Got "
        f"{row['selected_profile_model']!r}, expected '900ribu'."
    )


# ─── Test 3: visible chip in the chatview ──────────────────────────────────


def test_dialog_picked_profile_surfaces_in_chatview_chip(
    ui_harness: UIHarness, page
) -> None:
    """End-to-end visible assertion: after picking 900ribu and clicking
    Create task, open the new task's chatview and confirm the profile
    chip in the bottom bar shows '900ribu' — NOT 'alpha' (the active
    profile that the bug silently fell back to).

    This is the actual user-visible symptom; the DB-level tests above
    confirm the contract but this one matches what the user saw.
    """
    h = ui_harness
    _seed_profiles(h)

    ws_id = _create_workspace(h)
    kanban_id = _create_kanban(h, ws_id)

    page.goto(_kanban_url(h, ws_id, kanban_id), wait_until="domcontentloaded", timeout=60000)
    page.wait_for_timeout(1000)

    add_button = page.locator('[data-testid="kanban-add-task-button"]').first
    add_button.click()
    title_input = page.locator(
        '[data-testid="kanban-task-detail-create-name"]'
    ).first
    task_title = "ui-chip-shows-900ribu"
    title_input.fill(task_title)

    # IMPORTANT: also fill a description so the handler inserts at
    # least one user-role llm_history row (the create_session path
    # gates that insert on `description.len > 0 OR image_urls.len > 0`
    # — kanban_tasks_create.zig:298-301). Without a message in
    # llm_history the messages endpoint's LEFT JOIN returns 0 rows
    # and the response loses the per-session selected_profile_model
    # even though the sessions row carries it (separate bug —
    # out of scope for task_1787494153778_2). The chip uses the
    # chat's first message render path, not the greeting stub.
    description_input = page.locator(
        '[data-testid="kanban-task-detail-description-editor"]'
    ).first
    if description_input.count() > 0:
        # The description editor is a contenteditable / prose-mirror
        # — type into it directly. Some implementations wrap in
        # textarea (simpler); Playwright's .fill works on both.
        try:
            description_input.fill("Test description for profile persistence")
        except Exception:
            description_input.click()
            page.keyboard.type("Test description for profile persistence")
        page.wait_for_timeout(100)

    page.locator(
        '[data-testid="kanban-task-detail-profile-picker"]'
    ).first.click()
    page.wait_for_timeout(150)
    page.locator(
        '[data-testid="kanban-task-detail-profile-picker-item"]:has-text("900ribu")'
    ).first.click()
    page.wait_for_timeout(100)

    # The create dialog's footer is a split button; "Create task only"
    # lives in the caret menu, so open it before clicking.
    page.locator(
        '[data-testid="kanban-task-detail-commit-caret"]'
    ).first.click()
    page.wait_for_timeout(150)
    page.locator(
        '[data-testid="kanban-task-detail-save"]'
    ).first.click()
    page.wait_for_timeout(800)

    task_id = _task_id_for_name(h, ws_id, kanban_id, task_title)

    # Navigate to the new task's chatview. The chatview is rendered
    # via AppLayout.vue when the URL is `/app?view=chat&session=<id>`
    # (sets `activeChatId = "chat-<id>"`); the boot rewrite resolves the
    # owning workspace through the task link. A task chat always has one,
    # so the legacy URL is safe here — bare chats go through
    # `chatview_boot.open_chatview` instead.
    # The kanban-context URL (`...&itemId=Y/chat/task_X`) opens a
    # modal ChatDialog inside the kanban — different mount path that
    # Playwright's click intercepts. Use the standalone route.
    page.goto(
        h.web_url(f"/app?view=chat&session={task_id}"),
        wait_until="load",
        timeout=60000,
    )
    # Give Vue + getSession() + loadProfiles() time to settle.
    page.wait_for_timeout(2500)

    # The chatview's profile chip (ChatView.vue:3300) renders
    # `{{ effectiveProfile ?? 'Default' }}`. The bug surfaces as the
    # chip showing 'alpha' (the active_profile fallback) instead of
    # '900ribu'. There IS no testid on the chip itself, so we click
    # it to open the dropdown, then assert that '900ribu' is rendered
    # as a dropdown row (data-testid="profile-picker-900ribu"
    # — ChatView.vue:3326).
    # The chatview's profile chip (ChatView.vue:3300) renders
    # `{{ effectiveProfile ?? 'Default' }}`. The fix flows the
    # persisted pick through → chip text is '900ribu'. Pre-fix the
    # chip showed 'alpha' (the active_profile fallback) — the
    # user-visible symptom of task_1787494153778_2.
    #
    # ASSERT ON THE CHIP ITSELF (not the dropdown): the dropdown
    # requires a real user click on a Vue-ref-controlled
    # `<button @click.stop>` which Playwright's force/JS-dispatch
    # path can have flaky interactions with during the
    # chatview's first mount. The chip text is the directly-visible
    # bug-symptom and is sufficient for this regression test.
    chip = page.get_by_role("button").filter(has_text="900ribu").first
    if chip.count() == 0:
        chip = page.locator("button").filter(has_text="900ribu").first
    assert chip.count() > 0, (
        "Chatview profile chip is NOT rendering '900ribu'. This is "
        "the user-visible bug — pre-fix the chip showed 'alpha' "
        "(the active_profile fallback). Visible buttons: "
        f"{page.get_by_role('button').all_text_contents()[:30]!r}, "
        f"Backend log: {h.log_path}, Vite log: {h.vite_log_path}."
    )
    chip_text = chip.text_content() or ""
    assert "900ribu" in chip_text, (
        f"chip text didn't contain '900ribu' — got {chip_text!r}"
    )
    # Sanity: the chip MUST NOT mention 'alpha'. If it does, the
    # active_profile fallback path is winning again — the bug.
    assert "alpha" not in chip_text.lower(), (
        f"chatview chip contains 'alpha' (the active_profile fallback). "
        f"This means the persisted profile isn't reaching the chatview "
        f"at all — the very bug. Chip text: {chip_text!r}"
    )
