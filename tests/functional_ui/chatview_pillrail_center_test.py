"""The user-pill rail is centered on the VISIBLE transcript, not the column.

`UserPillRail` is `position: absolute` inside the transcript wrapper with
`top: 50%`. That was correct while the composer was the last in-flow flex
child (the wrapper ended where the composer began), but commit `6d8a706c`
floated the composer over the transcript: the wrapper now owns the FULL
column height and the dock occludes its bottom ~150px. A stale `top: 50%`
therefore sits half a composer-height BELOW the visible center — the exact
"pillbar not in center" report.

The fix reads the same `--chat-composer-inset` contract the floating
composer already publishes on `.chat-column` (and `ChatScrollSlider`'s
track already consumes):
`top: calc(50% - var(--chat-composer-inset, 0px) / 2)`.

Centering is a GEOMETRY claim, so jsdom cannot pin it: no layout engine,
no `getBoundingClientRect`, no custom-property resolution. This suite
drives the real app (Vite + pabrik + headless Chromium) and asserts:

  1. the rail's vertical midpoint is the midpoint of the VISIBLE
     transcript (column top → dock top), within rounding slack;
  2. the rail never dips behind the floating dock.

The instrument guards keep both honest: the inset must be published and
non-trivial (otherwise old and new code agree and the test is vacuous),
and the dock must be tall enough that the pre-fix code would miss by
more than the slack.

Run (frontend served from THIS worktree; the backend binary may come from
anywhere since only frontend code is under test):
    PABRIK_BIN=/path/to/zig-out/bin/pabrikcore-linux-x86_64 \
        /tmp/pabrik-ui-venv/bin/python -m pytest -s \
        tests/functional_ui/chatview_pillrail_center_test.py -v
"""

from __future__ import annotations

from pathlib import Path

from db_seed import DbSeed

BODY = (
    "Message {i} paragraph one.\n\n"
    "Message {i} paragraph two with longer text so the bubble has real "
    "height in the virtual scroller. Lorem ipsum dolor sit amet, "
    "consectetur adipiscing elit, sed do eiusmod tempor incididunt ut "
    "labore et dolore magna aliqua.\n\n"
    "Message {i} paragraph three with even more filler so each bubble "
    "measures a few hundred pixels tall in real layout."
)

#: Layout/rounding slack. Sub-pixel layout + the rail's own
#: `translateY(-50%)` rounding both move things by a pixel or two.
SLACK_PX = 12

#: The dock must be at least this tall for the test to prove anything:
#: the pre-fix error is `inset / 2 ≈ dock_height / 2`, so a short dock
#: would let the old code pass inside the slack.
MIN_DOCK_PX = 100


def _seed_db_path(h) -> Path:
    return h.temp_dir / ".config" / "pabrik" / "agent.db"


def _seed_session(h, session_id: str, workspace_id: str, count: int = 12) -> None:
    seed = DbSeed(_seed_db_path(h))
    with seed.connect() as conn:
        seed.seed_session(conn, session_id, "Pill rail centering")
        conn.execute(
            "UPDATE sessions SET workspace_id = ? WHERE id = ?",
            (workspace_id, session_id),
        )
        stamps = DbSeed.baseline_timestamps(count=count, interval_seconds=30)
        # Alternate user/assistant so every user turn is its own group:
        # N user groups → N rail pills (the rail needs >= 2 to render).
        for i in range(count):
            body = BODY.format(i=i)
            if i % 2 == 0:
                seed.seed_user_message(conn, session_id, body, created_at=stamps[i])
            else:
                seed.seed_assistant_message(conn, session_id, body, created_at=stamps[i])


def _open_chat(ui_harness, page, session_id: str) -> None:
    h = ui_harness
    ws = h.http("POST", "/api/workspaces", json_body={"name": "pill-ws"}, expect=201)
    workspace_id = ws.json()["id"]
    _seed_session(h, session_id, workspace_id)
    page.goto(
        h.web_url(f"/app/{workspace_id}/chat/{session_id}"),
        wait_until="load",
        timeout=60000,
    )
    page.wait_for_function(
        "() => { const w = document.querySelector('.messages-scroll-hide-native');"
        " return !!(w && w.querySelector('.virtual-scroller')); }",
        timeout=20000,
    )
    # The composer's ResizeObserver publishes `--chat-composer-inset`
    # on its first callback; wait for it so the rail's centering input
    # is in place before measuring.
    page.wait_for_function(
        "() => { const d = document.querySelector('.composer-dock');"
        " return !!d && d.offsetHeight > 0; }",
        timeout=20000,
    )
    # The rail renders once >= 2 user groups arrive from history.
    page.wait_for_function(
        "() => document.querySelectorAll('[data-testid=\"user-pill\"]').length >= 2",
        timeout=20000,
    )
    page.wait_for_timeout(2500)  # initial render + measure passes settle


#: One geometry sample, in viewport coordinates (what the user sees).
_GEOM_SCRIPT = r"""
() => {
  const column = document.querySelector('.chat-column');
  const dock = document.querySelector('.composer-dock');
  const rail = document.querySelector('[data-testid="user-pill-rail"]');
  const wrapper = document.querySelector('.messages-scroll-hide-native');
  if (!column || !dock || !rail) return null;
  const box = (el) => {
    const r = el.getBoundingClientRect();
    return { top: r.top, bottom: r.bottom, left: r.left, right: r.right,
             width: r.width, height: r.height };
  };
  const insetRaw = getComputedStyle(column).getPropertyValue('--chat-composer-inset');
  return {
    column: box(column),
    wrapper: wrapper ? box(wrapper) : null,
    dock: box(dock),
    rail: box(rail),
    railTop: getComputedStyle(rail).top,
    insetPx: parseFloat(insetRaw) || 0,
    pillCount: document.querySelectorAll('[data-testid="user-pill"]').length,
    hasAppBar: !!document.querySelector('[data-testid="chat-app-bar"]'),
  };
}
"""


def _geom(page) -> dict:
    g = page.evaluate(_GEOM_SCRIPT)
    assert g is not None, "chat column / composer dock / pill rail not found"
    return g


def test_rail_is_centered_on_the_visible_transcript(ui_harness, page) -> None:
    session_id = "sess-pill-center"
    _open_chat(ui_harness, page, session_id)
    g = _geom(page)
    print(f"\n[pill-rail] geometry: {g}")

    # Instrument guards — without these the centering assertion is vacuous.
    assert g["pillCount"] >= 2, f"rail needs >= 2 pills to render: {g}"
    assert g["insetPx"] > 0, (
        "the composer inset was never published, so stale and fixed code "
        f"agree at top:50%: {g}"
    )
    assert g["dock"]["height"] >= MIN_DOCK_PX, (
        f"dock is only {g['dock']['height']:.0f}px tall — the pre-fix error "
        f"(inset/2) would fit inside the {SLACK_PX}px slack and prove nothing: {g}"
    )

    # The visible transcript runs from the wrapper top to the dock top
    # (the dock floats OVER the wrapper's bottom part). The wrapper sits
    # below the chat app bar when one is rendered (standalone now shows
    # ChatAppBar like every other mode), so measuring from the column
    # top would include the ~44px header and miss by header/2. Fall back
    # to the column top only when the wrapper box is unavailable.
    top = g["wrapper"]["top"] if g.get("wrapper") else g["column"]["top"]
    visible_center = (top + g["dock"]["top"]) / 2
    rail_center = (g["rail"]["top"] + g["rail"]["bottom"]) / 2
    assert abs(rail_center - visible_center) <= SLACK_PX, (
        f"pill rail is not centered on the visible transcript: rail center "
        f"{rail_center:.1f} vs visible center {visible_center:.1f} "
        f"(wrapper top {top:.1f}, column top {g['column']['top']:.1f}, "
        f"dock top {g['dock']['top']:.1f}, inset {g['insetPx']:.0f}px, "
        f"appBar {g.get('hasAppBar')}): {g}"
    )


def test_rail_clears_the_floating_dock(ui_harness, page) -> None:
    session_id = "sess-pill-clearance"
    _open_chat(ui_harness, page, session_id)
    g = _geom(page)
    print(f"\n[pill-rail] clearance: {g}")

    assert g["rail"]["bottom"] <= g["dock"]["top"] + SLACK_PX, (
        f"the pill rail dips behind the floating composer: rail bottom "
        f"{g['rail']['bottom']:.1f} vs dock top {g['dock']['top']:.1f}: {g}"
    )
