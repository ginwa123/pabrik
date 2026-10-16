"""The pill hover preview box is READABLE, and it sits NEXT TO its pill.

Why this suite exists
---------------------
PR #953 added a styled box that opens when a user-pill is hovered, and it
shipped broken. ``.user-pill-message`` set ``max-width: 280px`` with no
``width``, so the absolutely-positioned box was shrink-to-fit against its
containing block — the rail's own 32px padding box — and ``max-width`` never
bound:

    measured   33.7px wide, 11.7px of content (padding 10px x 2),
               2 characters per line, 4 lines deep, ellipsis-clamped
               (the "/ s k ..." sliver in the report)

A second defect hid behind the first: ``right: 0`` already anchored the box's
right edge at the rail's right edge, and ``translateX(-100%)`` then moved it a
further own-width left, so the gap from pill to box was ``boxWidth - 24px`` —
9.7px while the box was a collapsed sliver, 256px once it had a real width.
Fixing the width alone would have thrown the box into the middle of the
transcript, so both declarations have to be asserted together.

jsdom can say nothing about either: no layout engine, no
``getBoundingClientRect``, no custom-property resolution. That is precisely why
a green unit suite shipped a 34px box. ``UserPillRail.spec.ts`` can only pin the
styling CONTRACT (a ``width:`` must be present, ``translate(-100%`` must not);
this suite proves the painted result, which is the half that was missing.

Run (the frontend is served from THIS worktree; the backend binary may come from
anywhere since only frontend code is under test):

    PABRIK_BIN=/path/to/zig-out/bin/pabrikcore-linux-x86_64 \\
        /tmp/pabrik-ui-venv/bin/python -m pytest -s \\
        tests/functional_ui/chatview_pillrail_hover_test.py -v
"""

from __future__ import annotations

from typing import Any

from chatview_boot import bind_session_workspace, create_workspace, open_chatview
from db_seed import DbSeed
from ui_harness import UIHarness

#: The reported message, verbatim. The worst case for the bug: 44 characters
#: with no early break, so a collapsed box breaks it after every character.
REPORTED_TEXT = "/skill-behavior-unit-tests /skill-no-comments"

#: A box narrower than this cannot hold the preview on one readable line.
#: The shipped bug measured 33.7px; the fix measures 280px.
MIN_BOX_PX = 200

#: ``margin-right: 8px`` measured from the rail's LEFT edge (the fix anchors the
#: box with ``right: 100%``). Slack covers sub-pixel layout.
GAP_MIN_PX, GAP_MAX_PX = 6, 14

#: 24px pill + 4px padding x 2. If the rail ever stops being this narrow, the
#: whole "shrink-to-fit against a 32px containing block" premise has changed.
RAIL_MAX_PX = 40

#: The reported preview at 280px is 1-2 lines; a collapsed box renders 4+.
MAX_LINES = 2

#: The reported message first so its pill exists; the rest only stack the rail.
FILLER = ["hi", "Delete profile not work fix that", "no catalog yet ? why ?", "another question"]

#: A pane comfortably wider than the ~346px a 280px box needs from the right edge,
#: so "the box opens over the transcript" is not a coin-flip on the CI viewport.
VIEWPORT = {"width": 1440, "height": 900}


def _seed_session(h: UIHarness, workspace_id: str, session_id: str) -> None:
    """One user group per message, alternating with an assistant ack."""
    seed = DbSeed(h.temp_dir / ".config" / "pabrik" / "agent.db")
    with seed.connect() as conn:
        seed.seed_session(conn, session_id, "Pill hover preview")
        bind_session_workspace(conn, workspace_id, session_id)
        turns = [REPORTED_TEXT, *FILLER]
        stamps = DbSeed.baseline_timestamps(count=len(turns) * 2, interval_seconds=30)
        for i, text in enumerate(turns):
            seed.seed_user_message(conn, session_id, text, created_at=stamps[i * 2])
            seed.seed_assistant_message(conn, session_id, "ack", created_at=stamps[i * 2 + 1])


def _open_chat(h: UIHarness, page: Any, session_id: str) -> None:
    page.set_viewport_size(VIEWPORT)
    workspace_id = create_workspace(h)
    _seed_session(h, workspace_id, session_id)
    open_chatview(page, h, workspace_id, session_id, timeout_ms=60000)
    page.wait_for_function(
        "() => { const w = document.querySelector('.messages-scroll-hide-native');"
        " return !!(w && w.querySelector('.virtual-scroller')); }",
        timeout=30000,
    )
    # The rail renders once >= 2 user groups arrive from history.
    page.wait_for_function(
        "() => document.querySelectorAll('[data-testid=\"user-pill\"]').length >= 2",
        timeout=30000,
    )
    page.wait_for_timeout(1500)


def _hover_reported_pill(h: UIHarness, page: Any, session_id: str) -> None:
    _open_chat(h, page, session_id)
    # Wait for the labelled pill, do not merely count it once: the rail renders on
    # the first history payload and can re-render as later pages arrive, so a count
    # taken too early reads zero and fails for a reason that is not under test.
    selector = '[data-testid="user-pill"][aria-label*="skill-behavior-unit-tests"]'
    page.wait_for_selector(selector, timeout=30000)
    pill = page.locator(selector)
    assert pill.count() >= 1, "the reported message has no pill on the rail"
    pill.first.hover()
    page.wait_for_function(
        "() => document.querySelectorAll('[data-testid=\"user-pill-message\"]').length === 1",
        timeout=5000,
    )


#: One geometry sample, in viewport coordinates (what the user sees).
_GEOM_SCRIPT = r"""
() => {
  const rail = document.querySelector('[data-testid="user-pill-rail"]');
  const wrapper = document.querySelector('.messages-scroll-hide-native');
  const boxes = document.querySelectorAll('[data-testid="user-pill-message"]');
  if (!rail || !wrapper) return null;
  const box = boxes[0] || null;
  const rect = (el) => {
    const r = el.getBoundingClientRect();
    return { left: r.left, right: r.right, top: r.top, bottom: r.bottom,
             width: r.width, height: r.height };
  };
  // Range client rects are real laid-out line boxes, so "how many lines is this
  // message" is measured rather than inferred from the clamped box height.
  let lineCount = 0;
  if (box) {
    const range = document.createRange();
    range.selectNodeContents(box);
    lineCount = range.getClientRects().length;
  }
  return {
    rail: rect(rail),
    wrapper: rect(wrapper),
    box: box ? rect(box) : null,
    boxCount: boxes.length,
    pillCount: document.querySelectorAll('[data-testid="user-pill"]').length,
    lineCount,
    // The box is capped at 3 lines; if the text does not fit, the message the
    // user is reaching for is truncated and the preview has failed.
    clamped: box ? box.scrollHeight > Math.ceil(box.clientHeight) + 1 : false,
    text: box ? box.textContent.trim() : '',
    // Pill-to-box distance. `right: 0` + `translateX(-100%)` made this grow with
    // the box width (256px at full width) and jsdom cannot see any of it.
    gapPx: box ? rail.getBoundingClientRect().left - box.getBoundingClientRect().right : null,
  };
}
"""


def _geom(page: Any) -> dict:
    g = page.evaluate(_GEOM_SCRIPT)
    assert g is not None, "the pill rail or the transcript wrapper was not found"
    return g


def test_hovering_a_pill_opens_a_readable_box_beside_it(ui_harness: UIHarness, page) -> None:
    _hover_reported_pill(ui_harness, page, "sess-pill-hover")
    g = _geom(page)
    print(f"\n[pill-hover] geometry: {g}")

    # Instrument guards. Without these the box assertion can pass on a rail that
    # is no longer the narrow containing block which caused the bug.
    assert g["pillCount"] >= 2, f"the rail needs >= 2 pills to render: {g}"
    assert g["rail"]["width"] <= RAIL_MAX_PX, f"the rail is no longer narrow: {g}"
    assert len(g["text"]) >= 20, f"the preview is too short to prove anything: {g}"

    assert g["boxCount"] == 1, f"hovering one pill must open exactly one box: {g}"
    assert REPORTED_TEXT in g["text"], f"the box shows the hovered message: {g}"

    # THE regression: `max-width` with no `width` collapsed the box to 33.7px,
    # 2 characters per line, because its containing block is the 32px rail.
    assert g["box"]["width"] >= MIN_BOX_PX, (
        f"the preview box is {g['box']['width']:.1f}px wide — it has collapsed "
        f"against its containing block again: {g}"
    )
    assert g["lineCount"] <= MAX_LINES, f"the message is broken over too many lines: {g}"
    assert not g["clamped"], f"the message is ellipsis-clamped, so it is not readable: {g}"

    # ... and the anchor. `right: 0` + `translateX(-100%)` counted the offset
    # twice, which is invisible while the box is a sliver and 256px at full width.
    assert GAP_MIN_PX <= g["gapPx"] <= GAP_MAX_PX, (
        f"the box sits {g['gapPx']:.1f}px from its pill — the anchor is "
        f"double-counted or detached: {g}"
    )

    # It opens over the transcript, never off the pane's edge.
    assert g["box"]["left"] >= g["wrapper"]["left"] - 1, f"the box overhangs the pane: {g}"
    assert g["box"]["right"] <= g["wrapper"]["right"] + 1, f"the box overhangs the pane: {g}"


def test_the_box_closes_when_the_pointer_leaves(ui_harness: UIHarness, page) -> None:
    _hover_reported_pill(ui_harness, page, "sess-pill-hover-close")
    page.mouse.move(5, 5)
    page.wait_for_function(
        "() => document.querySelectorAll('[data-testid=\"user-pill-message\"]').length === 0",
        timeout=5000,
    )
    g = _geom(page)
    assert g["boxCount"] == 0, f"the box outlived the hover: {g}"
