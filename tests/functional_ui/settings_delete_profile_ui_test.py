"""Functional UI test: deleting a profile from the workspace Profiles list sticks.

Regression for task_1792162309659_0 ("Delete profile not work"). The Profiles
list only exists in WORKSPACE settings (`/app/:workspaceId/settings`), and pre-fix
its `deleteProfile` was a no-op stub: the row vanished locally, no request was
sent, and the next load brought it back — a workspace overlay that OMITS a
profile still inherits it from the user config the merge layers it over.

The wire-level tests in `tests/functional/workspace_config_test.zig` pin the
endpoint. This one pins what the user actually reported: the click, and the row
still being gone after a reload.
"""

from __future__ import annotations

import json
import sys

from ui_harness import UIHarness


def _config_dir(h: UIHarness):
    """The OS-correct config dir the backend reads (Config.getDefaultConfigDir)."""
    if sys.platform == "darwin":
        return h.temp_dir / "Library" / "Application Support" / "pabrik"
    if sys.platform == "win32":
        return h.temp_dir / "AppData" / "Roaming" / "pabrik"
    return h.temp_dir / ".config" / "pabrik"


def _seed_profiles(h: UIHarness, names: list[str]) -> None:
    directory = _config_dir(h)
    directory.mkdir(parents=True, exist_ok=True)
    profiles = {
        name: {
            "model": f"{name}-model",
            "base_url": "http://127.0.0.1:1",
            "api_key": "stub-not-real",
            "url_style": "openai",
            "sub_agents": [],
        }
        for name in names
    }
    (directory / "config.json").write_text(
        json.dumps({"profiles_models": profiles, "active_profile": names[0]}, indent=2)
    )


def _create_workspace(h: UIHarness, name: str) -> str:
    return h.http("POST", "/api/workspaces", json_body={"name": name}, expect=201).json()["id"]


def _profile_rows(page):
    return page.locator('[data-testid="profile-list"] > li')


def _row_names(page) -> list[str]:
    rows = _profile_rows(page)
    names = []
    for i in range(rows.count()):
        text = rows.nth(i).inner_text()
        names.append(text.split("\n")[1].strip() if "\n" in text else text.strip())
    return names


def test_deleting_a_profile_removes_it_and_it_stays_gone_after_a_reload(
    ui_harness: UIHarness, page
) -> None:
    h = ui_harness
    _seed_profiles(h, ["doomed", "keeper"])

    workspace_id = _create_workspace(h, "delete-profile-ws")

    page.goto(
        h.web_url(f"/app/{workspace_id}/settings?section=profiles"),
        wait_until="domcontentloaded",
        timeout=60000,
    )
    page.wait_for_selector('[data-testid="profile-list"] > li', timeout=30000)
    assert sorted(_row_names(page)) == ["doomed", "keeper"], (
        f"the seeded profiles did not render: {_row_names(page)!r}"
    )

    _profile_rows(page).filter(has_text="doomed").first.locator(
        '[data-testid="delete-btn"]'
    ).click()

    confirm = page.locator('button:has-text("Delete")').last
    confirm.wait_for(state="visible", timeout=10000)
    confirm.click()

    page.wait_for_function(
        "() => document.querySelectorAll('[data-testid=\"profile-list\"] > li').length === 1",
        timeout=15000,
    )
    assert _row_names(page) == ["keeper"], f"the row survived the delete: {_row_names(page)!r}"

    # The reload is the regression: pre-fix the profile came back here (no
    # request was sent at all, and the overlay merge would have re-inherited it).
    page.reload(wait_until="domcontentloaded")
    page.wait_for_selector('[data-testid="profile-list"] > li', timeout=30000)
    rows_after_reload = _row_names(page)
    assert "doomed" not in rows_after_reload, (
        f"the deleted profile is back after a reload: {rows_after_reload!r}"
    )
    assert rows_after_reload == ["keeper"], f"unexpected rows: {rows_after_reload!r}"

    # And the API agrees, so the reload above was not a rendering artifact.
    body = h.http(
        "GET", f"/api/workspaces/{workspace_id}/config", expect=200
    ).json()
    assert "doomed" not in body.get("profiles", {}), body.get("profiles")
    assert "keeper" in body.get("profiles", {}), body.get("profiles")
