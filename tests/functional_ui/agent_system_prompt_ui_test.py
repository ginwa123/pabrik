"""Playwright UI tests for the Agent view's System Prompt section.

Each test:

1. Boots a fresh pabrik + Vite via the ``ui_harness`` fixture.
2. Creates a workspace + agent via the API (fast, deterministic).
3. Drives a headless Chromium at
   ``<vite_url>/app?view=workspace&workspaceId=<ws>&itemId=<agent>``
   and asserts the System Prompt section renders / mutates correctly.

No real LLM is invoked. The point is to verify the *render + interact
path* of the System Prompt UI (Migration 080): the section, the
add/edit dialog, optimistic list updates, and delete. The wire layer
is covered by ``tests/functional/agent_system_prompt_test.py``.

Plan: docs/superpowers/plans/2026-08-21-agent-system-prompt.md
"""

from __future__ import annotations

from typing import Any

import pytest

from harness import harness_path
from ui_harness import UIHarness


# ─── Helpers ────────────────────────────────────────────────────────────────


def _create_workspace(h: UIHarness, name: str = "ui-asp-ws") -> str:
    r = h.http("POST", "/api/workspaces", json_body={"name": name}, expect=201)
    return r.json()["id"]


def _create_agent(h: UIHarness, workspace_id: str, name: str = "ui asp agent") -> str:
    r = h.http(
        "POST",
        f"/api/workspaces/{workspace_id}/items/agent",
        json_body={"name": name, "path": harness_path(h, "agent-system-prompt-ui-test")},
        expect=201,
    )
    return r.json()["item"]["id"]


def _agent_url(h: UIHarness, workspace_id: str, agent_id: str) -> str:
    """The Vue app renders agent items inside ``/app`` with workspaceId +
    itemId query params (same shape the kanban UI tests use)."""
    return h.web_url(
        f"/app?view=workspace&workspaceId={workspace_id}&itemId={agent_id}"
    )


def _open_agent_view(page, h: UIHarness, workspace_id: str, agent_id: str) -> None:
    page.goto(_agent_url(h, workspace_id, agent_id), wait_until="domcontentloaded",
              timeout=60000)
    # The System Prompt section heading is the "Vue mounted the agent
    # view" signal. domcontentloaded alone doesn't guarantee the SPA
    # finished its API round-trips.
    page.locator('[data-testid="agent-system-prompt-panel"]').first.wait_for(
        timeout=20000, state="visible"
    )


def _wait_for_text(page, text: str, timeout_ms: int = 10000) -> None:
    page.locator(f"text={text}").first.wait_for(timeout=timeout_ms, state="attached")


# ─── Tests ──────────────────────────────────────────────────────────────────


def test_system_prompt_section_renders_empty_state(ui_harness: UIHarness, page) -> None:
    """A fresh agent shows the System Prompt panel with the empty state."""
    h = ui_harness
    ws_id = _create_workspace(h)
    agent_id = _create_agent(h, ws_id)

    _open_agent_view(page, h, ws_id, agent_id)

    panel = page.locator('[data-testid="agent-system-prompt-panel"]')
    assert panel.count() > 0, "System Prompt panel missing from agent view"
    _wait_for_text(page, "No system prompts yet")
    # The + Add button is present.
    assert page.locator('[data-testid="agent-add-system-prompt"]').is_visible()


def test_add_system_prompt_via_dialog(ui_harness: UIHarness, page) -> None:
    """Clicking + Add opens the dialog; submitting creates a row that
    renders in the section (optimistic append) AND persists (reload)."""
    h = ui_harness
    ws_id = _create_workspace(h)
    agent_id = _create_agent(h, ws_id)

    _open_agent_view(page, h, ws_id, agent_id)

    # Open the dialog.
    page.locator('[data-testid="agent-add-system-prompt"]').click()
    dialog = page.locator('[data-testid="agent-system-prompt-dialog"]')
    dialog.wait_for(timeout=10000, state="visible")

    # Fill title + content.
    page.locator('[data-testid="agent-system-prompt-title"]').fill("Persona")
    page.locator('[data-testid="agent-system-prompt-content"]').fill(
        "You are a pirate captain. Speak in nautical metaphors."
    )

    # Submit is enabled once content is non-empty.
    submit = page.locator('[data-testid="agent-system-prompt-submit"]')
    assert submit.is_enabled(), "submit should enable after content is filled"
    submit.click()

    # Dialog closes on success; the new row renders optimistically.
    dialog.wait_for(timeout=10000, state="detached")
    _wait_for_text(page, "Persona")
    _wait_for_text(page, "You are a pirate captain. Speak in nautical metaphors.")

    # Persistence: reload the page — the row must still be there
    # (proves the POST hit the backend, not just local state).
    page.reload(wait_until="domcontentloaded")
    page.locator('[data-testid="agent-system-prompt-panel"]').first.wait_for(
        timeout=20000, state="visible"
    )
    _wait_for_text(page, "Persona")


def test_edit_system_prompt_via_dialog(ui_harness: UIHarness, page) -> None:
    """✎ opens the dialog pre-filled; saving updates the row in place."""
    h = ui_harness
    ws_id = _create_workspace(h)
    agent_id = _create_agent(h, ws_id)

    # Seed one prompt via the API (fast path — the add flow is covered
    # by the test above).
    r = h.http(
        "POST",
        f"/api/agents/{agent_id}/system_prompt",
        json_body={"title": "Original", "content": "original body"},
        expect=201,
    )
    prompt_id = r.json()["id"]

    _open_agent_view(page, h, ws_id, agent_id)
    _wait_for_text(page, "Original")

    page.locator('[data-testid="agent-edit-system-prompt"]').first.click()
    dialog = page.locator('[data-testid="agent-system-prompt-dialog"]')
    dialog.wait_for(timeout=10000, state="visible")

    # Fields are pre-filled from the row.
    title_input = page.locator('[data-testid="agent-system-prompt-title"]')
    content_input = page.locator('[data-testid="agent-system-prompt-content"]')
    assert title_input.input_value() == "Original"
    assert content_input.input_value() == "original body"

    title_input.fill("Renamed")
    content_input.fill("updated body")
    page.locator('[data-testid="agent-system-prompt-submit"]').click()

    dialog.wait_for(timeout=10000, state="detached")
    _wait_for_text(page, "Renamed")
    _wait_for_text(page, "updated body")

    # Persisted: reload and re-check via the bundle (source of truth —
    # there is no GET-by-id endpoint; the bundle is the read path).
    page.reload(wait_until="domcontentloaded")
    page.locator('[data-testid="agent-system-prompt-panel"]').first.wait_for(
        timeout=20000, state="visible"
    )
    _wait_for_text(page, "Renamed")
    bundle = h.http(
        "GET", f"/api/workspaces/{ws_id}/items/{agent_id}/agent", expect=200
    ).json()
    rows = [p for p in bundle["system_prompts"] if p["id"] == prompt_id]
    assert rows and rows[0]["title"] == "Renamed", (
        f"edit did not persist: {bundle['system_prompts']!r}"
    )


def test_remove_system_prompt(ui_harness: UIHarness, page) -> None:
    """✕ removes the row optimistically; the deletion persists."""
    h = ui_harness
    ws_id = _create_workspace(h)
    agent_id = _create_agent(h, ws_id)

    h.http(
        "POST",
        f"/api/agents/{agent_id}/system_prompt",
        json_body={"title": "Doomed", "content": "delete me"},
        expect=201,
    )

    _open_agent_view(page, h, ws_id, agent_id)
    _wait_for_text(page, "Doomed")

    # The click is NOT a barrier for the DELETE. `handleAgentRemoveSystemPrompt`
    # filters the row out of `agentSystemPrompts` and only then awaits
    # `api.deleteAgentSystemPrompt`, so the two optimistic assertions below are
    # satisfied while the request is still in flight — and the bundle GET after
    # them can overtake it. That is what "delete did not persist" was on CI run
    # 38127927593 (shard 1/3, a loaded runner): the row was read back mid-flight,
    # not left behind. Waiting on the DELETE's own response is the barrier, and
    # it also means a silently-failing delete can no longer pass.
    with page.expect_response(
        lambda r: r.request.method == "DELETE" and "/system_prompt/" in r.url
    ) as deleted:
        page.locator('[data-testid="agent-remove-system-prompt"]').first.click()

    # Row disappears optimistically; empty state returns.
    page.locator("text=Doomed").first.wait_for(timeout=10000, state="detached")
    _wait_for_text(page, "No system prompts yet")

    # A non-2xx leaves the row in place (the handler restores it), so the
    # persistence check below is only meaningful once this is green.
    assert deleted.value.status == 200, (
        f"DELETE /system_prompt returned {deleted.value.status}"
    )

    # Persisted: the bundle no longer lists it.
    bundle = h.http(
        "GET", f"/api/workspaces/{ws_id}/items/{agent_id}/agent", expect=200
    ).json()
    assert bundle["system_prompts"] == [], (
        f"delete did not persist: {bundle['system_prompts']!r}"
    )


def test_dialog_submit_disabled_for_whitespace_content(
    ui_harness: UIHarness, page
) -> None:
    """The dialog's submit stays disabled while content is whitespace-only
    (mirrors the backend's ContentRequired validation)."""
    h = ui_harness
    ws_id = _create_workspace(h)
    agent_id = _create_agent(h, ws_id)

    _open_agent_view(page, h, ws_id, agent_id)

    page.locator('[data-testid="agent-add-system-prompt"]').click()
    dialog = page.locator('[data-testid="agent-system-prompt-dialog"]')
    dialog.wait_for(timeout=10000, state="visible")

    submit = page.locator('[data-testid="agent-system-prompt-submit"]')
    # Empty content → disabled.
    assert submit.is_disabled(), "submit should be disabled with empty content"
    # Whitespace-only content → still disabled.
    page.locator('[data-testid="agent-system-prompt-content"]').fill("   \n\t  ")
    assert submit.is_disabled(), "submit should be disabled for whitespace-only content"
    # Real content → enabled.
    page.locator('[data-testid="agent-system-prompt-content"]').fill("real body")
    assert submit.is_enabled(), "submit should enable with real content"
