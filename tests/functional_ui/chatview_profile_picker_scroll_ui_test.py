"""The composer's `@` agent list must FIT the viewport and SCROLL.

Regression for task_1792162397680_1 ("scroll not work in models profile"),
carried over when the agent chip became the `@` list: the list is the same
surface, inside the composer card, and a long roster must not run off the top
of the window or hide its rows behind a clip.

The two halves of the defect are GEOMETRY claims, so neither can be pinned in
jsdom (no layout engine, no `getBoundingClientRect` worth reading, and the SFC
scoped CSS is not applied). This suite drives the real app (Vite + pabrik +
headless Chromium), seeds a roster LONGER than the viewport, and asserts:

  1. the list's top edge is on screen and its bottom stays inside the window;
  2. the list is taller than its own box AND its box is a scroll container —
     i.e. the overflow has somewhere to go;
  3. a real wheel gesture over the list moves it (the user's actual complaint:
     "scroll not work");
  4. the FIRST row and the LAST row are both reachable and fully on screen.

Test 3's precondition guard asserts the list is genuinely taller than the
viewport, so a future shortening of the seed cannot make these assertions pass
vacuously.

Run (frontend served from THIS worktree; the backend binary may come from
anywhere since only frontend code is under test):
    PABRIK_BIN=/home/ginwa/pabrik/zig-out/bin/pabrik \\
        /tmp/uivenv/bin/python -m pytest -s \\
        tests/functional_ui/chatview_profile_picker_scroll_ui_test.py -v
"""

from __future__ import annotations

import json
import sys

from chatview_boot import bind_session_workspace, create_workspace, open_chatview, seed_db_path
from db_seed import DbSeed

#: A row is one line (~28px: `@name` + model), so 40 agents is ~1100px of list —
#: comfortably taller than the 800px test viewport, which is the whole point (a
#: list that fits cannot regress into "unreachable").
PROFILE_COUNT = 40

#: Sub-pixel layout + round-trip: a row flush with the viewport edge is fine.
SLACK_PX = 2

#: The agent the list must place last, to prove the BOTTOM of a long list is
#: reachable too (the top is covered by the first row).
LAST_PROFILE = f"profile-slot-{PROFILE_COUNT:02d}"

#: The composer's textarea, and the list `@` opens.
TEXTAREA = '[data-testid="chat-message-textarea"]'
AGENT_LIST = '[data-testid="agent-picker-list"]'
AGENT_ROW = "[data-agent-name]"


def _seed_profiles(h, workspace_id: str, count: int = PROFILE_COUNT) -> None:
    """Give ``count`` profiles to the USER document and to this WORKSPACE.

    The chat's `@` list reads `GET /api/workspaces/:id/config`, and a workspace
    starts with no profiles of its own: nothing is copied from the user
    document and nothing is inherited on read. So the list the composer renders
    is exactly what was saved in the workspace (the `PUT` below); config.json
    stays in step because the rest of the chat still reads it. The config dir
    is OS-dependent (`getDefaultConfigDir`), so mirror the backend's lookup the
    same way `kanban_profile_select_ui_test.py` does.
    """
    if sys.platform == "darwin":
        config_dir = h.temp_dir / "Library" / "Application Support" / "pabrik"
    elif sys.platform == "win32":
        config_dir = h.temp_dir / "AppData" / "Roaming" / "pabrik"
    else:
        config_dir = h.temp_dir / ".config" / "pabrik"
    config_dir.mkdir(parents=True, exist_ok=True)
    profiles = {
        f"profile-slot-{i:02d}": {
            "model": f"stub-model-{i:02d}",
            "base_url": f"http://127.0.0.1:1/v1/{i:02d}",
            "api_key": "stub-not-real",
        }
        for i in range(1, count + 1)
    }
    (config_dir / "config.json").write_text(
        json.dumps(
            {
                "model": "stub-model-01",
                "url_style": "openai",
                "profiles_models": profiles,
                "active_profile": "profile-slot-01",
            },
            indent=2,
        )
    )
    h.http(
        "PUT",
        f"/api/workspaces/{workspace_id}/config",
        json_body={"profiles": profiles, "active_profile": "profile-slot-01"},
        expect=200,
    )


def _open_chat(ui_harness, page, session_id: str) -> None:
    """Boot a workspace + a session whose entity renders the real composer."""
    h = ui_harness
    workspace_id = create_workspace(h, name="picker-scroll-ws")
    seed = DbSeed(seed_db_path(h))
    with seed.connect() as conn:
        seed.seed_session(conn, session_id, "Picker scroll")
        bind_session_workspace(conn, workspace_id, session_id)
        seed.seed_user_message(conn, session_id, "hello")
    _seed_profiles(h, workspace_id)
    open_chatview(page, h, workspace_id, session_id, timeout_ms=60000)
    # The textarea is `:disabled` until the session resolves — that is the
    # readiness gate now that the chip is gone.
    page.wait_for_function(
        f"() => {{ const t = document.querySelector('{TEXTAREA}');"
        " return !!t && !t.disabled; }",
        timeout=30000,
    )
    page.wait_for_timeout(500)


#: One geometry sample of the OPEN list, in viewport coordinates.
_GEOM_SCRIPT = r"""
() => {
  const list = document.querySelector('[data-testid="agent-picker-list"]');
  if (!list) return null;
  const rows = list.querySelectorAll('[data-agent-name]');
  const firstRow = rows[0] || null;
  const lastRow = rows[rows.length - 1] || null;
  const box = (el) => {
    const r = el.getBoundingClientRect();
    return { top: r.top, bottom: r.bottom, left: r.left, right: r.right,
             width: r.width, height: r.height };
  };
  const style = getComputedStyle(list);
  return {
    viewportHeight: window.innerHeight,
    dropdown: box(list),
    firstRow: firstRow ? box(firstRow) : null,
    lastRow: lastRow ? box(lastRow) : null,
    lastRowName: lastRow ? lastRow.getAttribute('data-agent-name') : null,
    rows: rows.length,
    scrollTop: list.scrollTop,
    scrollHeight: list.scrollHeight,
    clientHeight: list.clientHeight,
    overflowY: style.overflowY,
    maxHeight: style.maxHeight,
    position: style.position,
  };
}
"""


def _geom(page) -> dict:
    g = page.evaluate(_GEOM_SCRIPT)
    assert g is not None, "the `@` agent list is not in the DOM"
    return g


def _open_picker(page) -> None:
    """Type `@` in the composer; the list opens after the 100 ms debounce."""
    page.locator(TEXTAREA).first.click()
    page.locator(TEXTAREA).first.fill("@")
    page.wait_for_selector(AGENT_LIST, timeout=10000)
    page.wait_for_selector(AGENT_ROW, timeout=10000)
    page.wait_for_timeout(200)


def _wheel_over_dropdown(page, g: dict, delta_y: int) -> None:
    """Wheel at a point INSIDE the list that is on screen."""
    box = g["dropdown"]
    x = box["left"] + min(60.0, box["width"] / 2)
    y = max(1.0, min(box["bottom"], g["viewportHeight"]) - 24.0)
    page.mouse.move(x, y)
    page.mouse.wheel(0, delta_y)
    page.wait_for_timeout(250)


def test_dropdown_is_a_scroll_container_that_fits_the_viewport(ui_harness, page) -> None:
    """The list must not run off the window, and must scroll."""
    _open_chat(ui_harness, page, "sess-picker-scroll")
    _open_picker(page)
    g = _geom(page)
    print(f"\n[picker-scroll] geometry: {g}")

    # Instrument guard: the seeded list really is longer than the screen, so
    # "the list fits" cannot pass by having nothing to show.
    assert g["scrollHeight"] > g["viewportHeight"], (
        f"the agent list ({g['scrollHeight']}px) is not taller than the "
        f"viewport ({g['viewportHeight']}px) — the seed is too short to "
        f"reproduce the reported overflow: {g}"
    )
    assert g["rows"] >= PROFILE_COUNT, (
        f"only {g['rows']} rows rendered; the seeded profiles did not load "
        f"into the `@` list: {g}"
    )

    assert g["dropdown"]["top"] >= -SLACK_PX, (
        f"the list starts {g['dropdown']['top']:.0f}px above the top of the "
        f"window, so its first rows can never be read: {g}"
    )
    assert g["dropdown"]["bottom"] <= g["viewportHeight"] + SLACK_PX, (
        f"the list runs past the bottom of the window: {g}"
    )

    # ...and there must be somewhere for the overflow to go.
    assert g["overflowY"] in ("auto", "scroll"), (
        f"the list is not a scroll container (overflow-y: "
        f"{g['overflowY']!r}); with {g['scrollHeight']}px of rows in a "
        f"{g['clientHeight']}px box the rest is unreachable"
    )
    assert g["scrollHeight"] > g["clientHeight"], (
        f"the rows ({g['scrollHeight']}px) do not overflow the box "
        f"({g['clientHeight']}px), so this assertion set proves nothing: {g}"
    )


def test_wheel_over_the_list_scrolls_it(ui_harness, page) -> None:
    """The user's literal complaint: the wheel does nothing over the list."""
    _open_chat(ui_harness, page, "sess-picker-wheel")
    _open_picker(page)
    before = _geom(page)
    assert before["scrollTop"] == 0, f"the list was not at the top: {before}"

    _wheel_over_dropdown(page, before, 400)
    after = _geom(page)
    print(f"\n[picker-scroll] wheel: scrollTop {before['scrollTop']} -> {after['scrollTop']}")

    assert after["scrollTop"] > 0, (
        f"a wheel gesture over the open list did not scroll it (scrollTop "
        f"stayed at {after['scrollTop']}, scrollHeight "
        f"{after['scrollHeight']}, clientHeight {after['clientHeight']}) — "
        f"this is the reported bug: {after}"
    )
    # Scrolling the list must not drag the composer out from under the pointer.
    assert after["dropdown"]["bottom"] <= after["viewportHeight"] + SLACK_PX, (
        f"the list moved with the transcript instead of scrolling "
        f"internally: {after}"
    )


def test_first_and_last_rows_are_both_reachable(ui_harness, page) -> None:
    """Every agent must be readable: the top row AND the bottom row."""
    _open_chat(ui_harness, page, "sess-picker-ends")
    _open_picker(page)

    # ── Top of the list: the first seeded agent ────────────────────────────
    top = _geom(page)
    assert top["firstRow"]["top"] >= -SLACK_PX, (
        f"the list's FIRST row is off-screen at y={top['firstRow']['top']:.0f} "
        f"— the first agent is unreachable: {top}"
    )
    assert top["firstRow"]["bottom"] <= top["viewportHeight"] + SLACK_PX, (
        f"the list's first row is below the window (the list is not anchored "
        f"inside the composer any more): {top}"
    )

    # ── Bottom of the list: the last seeded agent ──────────────────────────
    assert top["lastRowName"] == LAST_PROFILE, (
        f"the list's last row is {top['lastRowName']!r}, expected "
        f"{LAST_PROFILE!r} — the full seed is not rendered: {top}"
    )
    _wheel_over_dropdown(page, top, 5000)
    bottom = _geom(page)
    print(f"\n[picker-scroll] ends: {bottom}")
    assert bottom["lastRow"]["bottom"] <= bottom["viewportHeight"] + SLACK_PX, (
        f"the list's LAST row ({bottom['lastRowName']}) is below the window "
        f"even after scrolling to the end: {bottom}"
    )
    assert bottom["lastRow"]["top"] >= -SLACK_PX, (
        f"the list's last row is above the window: {bottom}"
    )
