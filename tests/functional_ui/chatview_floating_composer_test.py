"""The chat composer FLOATS over the transcript, and nothing is occluded.

The composer used to be the last flex child of the chat column: a block
with a `border-top` and an opaque `--semantic-sidebar-bg` fill. It now
floats — `position: absolute` on the (relative) column, with a
`composer-scrim` gradient fading to the transcript's own background — and
the newest message is padded by `--chat-composer-inset` so it can always
be scrolled clear of the card.

Those are the two halves of "floating", and both are GEOMETRY claims, so
neither can be pinned in jsdom: there is no layout engine, no
`getBoundingClientRect` worth reading, and no CSS custom-property
resolution. This suite drives the real app (Vite + pabrik + headless
Chromium) and asserts:

  1. the dock is an absolute overlay pinned to the column's bottom edge,
     and carries no top border;
  2. the transcript scroller's bottom edge is the COLUMN's bottom edge —
     i.e. the composer no longer steals a slice of the transcript's
     height, which is the whole point of floating;
  3. scrolled to the very bottom, the newest message is fully above the
     dock (the clearance actually works, at a real viewport);
  4. the scrim is a gradient that dissolves into the transcript
     background (`#181616`), not the old bar fill (`#12120f`) — a
     1-shade seam is the tell-tale of getting that wrong.

The unit half of the contract lives in
`src/apps/desktop/src/__tests__/ChatView.floatingComposer.spec.ts`.

Run (frontend served from THIS worktree; the backend binary may come from
anywhere since only frontend code is under test):
    PABRIK_BIN=/home/ginwa/ginwaaitoolbox/zig-out/bin/pabrikcore-linux-x86_64 \\
        /tmp/pabrik-ui-venv/bin/python -m pytest -s \\
        tests/functional_ui/chatview_floating_composer_test.py -v
"""

from __future__ import annotations

from pathlib import Path

from db_seed import DbSeed

BODY = (
    "Message {i} paragraph one.\\n\\n"
    "Message {i} paragraph two with longer text so the bubble has real "
    "height in the virtual scroller. Lorem ipsum dolor sit amet, "
    "consectetur adipiscing elit, sed do eiusmod tempor incididunt ut "
    "labore et dolore magna aliqua.\\n\\n"
    "Message {i} paragraph three with even more filler so each bubble "
    "measures a few hundred pixels tall in real layout."
)

#: The transcript's own background. `--semantic-content-bg` = `--color-bg`
#: = #181616. The scrim MUST fade to this; fading to the composer's old
#: `--semantic-sidebar-bg` (#12120f) leaves a 1-shade seam.
CONTENT_BG_RGB = (24, 22, 22)

#: Layout/rounding slack. Sub-pixel layout + the scroller's hysteresis
#: dead-band both move things by a pixel or two.
SLACK_PX = 4


def _seed_db_path(h) -> Path:
    return h.temp_dir / ".config" / "pabrik" / "agent.db"


def _seed_session(h, session_id: str, workspace_id: str, count: int = 40) -> None:
    seed = DbSeed(_seed_db_path(h))
    with seed.connect() as conn:
        seed.seed_session(conn, session_id, "Floating composer")
        conn.execute(
            "UPDATE sessions SET workspace_id = ? WHERE id = ?",
            (workspace_id, session_id),
        )
        stamps = DbSeed.baseline_timestamps(count=count, interval_seconds=30)
        for i in range(count):
            body = BODY.format(i=i)
            if i % 2 == 0:
                seed.seed_user_message(conn, session_id, body, created_at=stamps[i])
            else:
                seed.seed_assistant_message(conn, session_id, body, created_at=stamps[i])


def _open_chat(ui_harness, page, session_id: str) -> None:
    h = ui_harness
    ws = h.http("POST", "/api/workspaces", json_body={"name": "float-ws"}, expect=201)
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
    # on its first callback; wait for it so the clearance is in place
    # before we scroll.
    page.wait_for_function(
        "() => { const d = document.querySelector('.composer-dock');"
        " return !!d && d.offsetHeight > 0; }",
        timeout=20000,
    )
    page.wait_for_timeout(2500)  # initial render + measure passes settle


#: One geometry sample, in viewport coordinates (what the user sees).
_GEOM_SCRIPT = r"""
() => {
  const wrap = document.querySelector('.messages-scroll-hide-native');
  const scroller = wrap ? wrap.querySelector('.virtual-scroller') : null;
  const column = document.querySelector('.chat-column');
  const dock = document.querySelector('.composer-dock');
  const scrim = document.querySelector('.composer-scrim');
  if (!scroller || !column || !dock || !scrim) return null;
  const box = (el) => {
    const r = el.getBoundingClientRect();
    return { top: r.top, bottom: r.bottom, left: r.left, right: r.right,
             width: r.width, height: r.height };
  };
  // The newest rendered message = the last group row in the DOM.
  const rows = [...document.querySelectorAll('.virtual-scroller-content [data-group-key]')];
  const lastRow = rows.length ? rows[rows.length - 1] : null;
  const scrimStyle = getComputedStyle(scrim);
  const dockStyle = getComputedStyle(dock);
  // The clearance is PADDING on the last row, so the row's border box ends
  // at the bottom of the scroll range by construction — the box the user
  // actually reads stops where the padding starts.
  const lastRowPaddingBottom = lastRow
    ? parseFloat(getComputedStyle(lastRow).paddingBottom) || 0
    : 0;
  const lastRowBox = lastRow ? box(lastRow) : null;
  return {
    column: box(column),
    scroller: box(scroller),
    dock: box(dock),
    scrim: box(scrim),
    lastRow: lastRowBox,
    lastRowContentBottom: lastRowBox
      ? lastRowBox.bottom - lastRowPaddingBottom
      : null,
    lastRowPaddingBottom: lastRowPaddingBottom,
    lastRowIsPadded: lastRow
      ? lastRow.classList.contains('last-transcript-row')
      : false,
    dockPosition: dockStyle.position,
    dockBorderTop: dockStyle.borderTopWidth,
    scrimImage: scrimStyle.backgroundImage,
    scrimPointerEvents: scrimStyle.pointerEvents,
    scrollTop: scroller.scrollTop,
    scrollHeight: scroller.scrollHeight,
    clientHeight: scroller.clientHeight,
  };
}
"""


def _geom(page) -> dict:
    g = page.evaluate(_GEOM_SCRIPT)
    assert g is not None, "floating composer / chat scroller not found"
    return g


#: Who is painted on top at the two points a user looks at when they decide
#: the composer is usable: the middle of the textarea, and the middle of the
#: Send button.
#:
#: The scrim is deliberately `pointer-events: none`, which HIDES it from
#: hit-testing — that is why the whole geometry half of this suite (and
#: `elementFromPoint` anywhere else) reported a perfectly healthy composer
#: while the user was looking at an empty card. Flipping the scrim to
#: `pointer-events: auto` for the duration of the probe makes it hit-testable
#: again, and because hit-testing walks the same stacking order that painting
#: does, the returned element is the one the user actually sees.
_PAINT_ORDER_SCRIPT = r"""
() => {
  const card = document.querySelector('.composer-card');
  const scrim = document.querySelector('.composer-scrim');
  const ta = document.querySelector('[data-testid="chat-message-textarea"]');
  const send = document.querySelector('[data-testid="send-message-button"]');
  const present = { card: !!card, scrim: !!scrim, textarea: !!ta, send: !!send };
  if (!card || !scrim || !ta || !send) return { missing: true, present };

  scrim.style.pointerEvents = 'auto';
  const mid = (el) => {
    const r = el.getBoundingClientRect();
    return [r.left + r.width / 2, r.top + r.height / 2];
  };
  const describe = (el) => {
    if (!el) return 'null';
    const tid = el.getAttribute('data-testid');
    return (
      el.tagName +
      (tid ? '#' + tid : '') +
      (el === scrim ? ' [SCRIM]' : '') +
      (card.contains(el) ? ' [in-card]' : '')
    );
  };
  const points = {};
  for (const [name, el] of [['textarea', ta], ['send', send]]) {
    const [x, y] = mid(el);
    const hit = document.elementFromPoint(x, y);
    points[name] = {
      point: [Math.round(x), Math.round(y)],
      hit: describe(hit),
      isScrim: hit === scrim,
      insideCard: !!(hit && card.contains(hit)),
    };
  }
  const cardRect = card.getBoundingClientRect();
  return {
    missing: false,
    present,
    // Guards the instrument: if the scrim did not actually become hittable,
    // the assertions below would pass vacuously.
    scrimMadeHittable: getComputedStyle(scrim).pointerEvents === 'auto',
    scrimCoversCard: scrim.getBoundingClientRect().bottom > cardRect.top,
    points,
    cardHeight: Math.round(cardRect.height),
    formHeight: Math.round(ta.getBoundingClientRect().height),
  };
}
"""


def test_composer_docks_to_the_column_bottom_as_an_overlay(ui_harness, page) -> None:
    session_id = "sess-float-overlay"
    _open_chat(ui_harness, page, session_id)
    g = _geom(page)
    print(f"\n[float-composer] overlay: {g}")

    assert g["dockPosition"] == "absolute", (
        f"composer dock is {g['dockPosition']!r}, expected an absolute overlay"
    )
    # Pinned to the column's bottom edge.
    assert abs(g["dock"]["bottom"] - g["column"]["bottom"]) <= SLACK_PX, (
        f"dock bottom {g['dock']['bottom']} is not the column bottom "
        f"{g['column']['bottom']}"
    )
    # The hard bar it replaced is gone.
    assert float(g["dockBorderTop"].removesuffix("px")) <= SLACK_PX, (
        f"dock still has a top border ({g['dockBorderTop']}) — the scrim was "
        "meant to replace it, not sit on top of it"
    )
    # The scrim must not eat clicks meant for the transcript behind it.
    assert g["scrimPointerEvents"] == "none", (
        f"scrim pointer-events is {g['scrimPointerEvents']}, expected 'none'"
    )


def test_transcript_owns_the_full_column_height(ui_harness, page) -> None:
    """The whole point of floating: the composer no longer costs height."""
    session_id = "sess-float-height"
    _open_chat(ui_harness, page, session_id)
    g = _geom(page)
    print(f"\n[float-composer] height: {g}")

    assert abs(g["scroller"]["bottom"] - g["column"]["bottom"]) <= SLACK_PX, (
        "the transcript scroller stops short of the column bottom, so the "
        f"composer is still taking layout height: scroller bottom "
        f"{g['scroller']['bottom']} vs column bottom {g['column']['bottom']}"
    )
    # And it is genuinely taller than the composer it now floats over.
    assert g["scroller"]["height"] > g["dock"]["height"] + 50, (
        f"scroller height {g['scroller']['height']} is not meaningfully taller "
        f"than the dock {g['dock']['height']} — the overlay is eating the view"
    )


def test_newest_message_is_never_occluded_at_the_bottom(ui_harness, page) -> None:
    session_id = "sess-float-clearance"
    _open_chat(ui_harness, page, session_id)

    page.evaluate(
        "() => { const el = document.querySelector('.messages-scroll-hide-native')"
        " .querySelector('.virtual-scroller'); if (el) el.scrollTop = 1e9; }"
    )
    page.wait_for_timeout(2000)
    g = _geom(page)
    print(f"\n[float-composer] clearance: {g}")

    assert g["scrollTop"] >= g["scrollHeight"] - g["clientHeight"] - 2, (
        f"not parked at the bottom of the scroll range: {g}"
    )
    assert g["lastRow"] is not None, "no transcript row rendered at the bottom"
    assert g["lastRowIsPadded"], (
        "the newest row does not carry `last-transcript-row`, so it has no "
        "clearance for the floating composer"
    )
    # The padding must actually cover the dock it clears — this is the
    # number the ResizeObserver publishes, and if it ever drifts below the
    # dock the newest message goes dark under the card.
    assert g["lastRowPaddingBottom"] >= g["dock"]["height"] - SLACK_PX, (
        f"last-row clearance ({g['lastRowPaddingBottom']:.0f}px) is smaller "
        f"than the dock it must clear ({g['dock']['height']:.0f}px)"
    )
    assert g["lastRowContentBottom"] <= g["dock"]["top"] + SLACK_PX, (
        "the newest message is UNDER the floating composer at the bottom of "
        f"the scroll range: content bottom {g['lastRowContentBottom']} vs "
        f"dock top {g['dock']['top']}"
    )


def test_scrim_fades_into_the_transcript_background(ui_harness, page) -> None:
    session_id = "sess-float-scrim"
    _open_chat(ui_harness, page, session_id)
    g = _geom(page)
    print(f"\n[float-composer] scrim: {g['scrimImage']}")

    img = g["scrimImage"]
    assert "linear-gradient" in img, f"scrim is not a gradient: {img!r}"
    assert "rgba(0, 0, 0, 0)" in img or "transparent" in img, (
        f"scrim gradient does not fade to transparent: {img!r}"
    )
    r, gg, b = CONTENT_BG_RGB
    assert f"rgb({r}, {gg}, {b})" in img, (
        f"scrim does not fade to the transcript background rgb({r}, {gg}, {b}) "
        f"(--semantic-content-bg / --color-bg): {img!r}"
    )
    # Fading to the old bar fill instead would leave a 1-shade seam.
    assert "rgb(18, 18, 15)" not in img, (
        f"scrim fades to the old composer bar fill (--semantic-sidebar-bg), "
        f"which shows a seam against the transcript: {img!r}"
    )
    # The fade band must extend ABOVE the dock, or the transcript is hard-cut
    # where it disappears under the composer.
    assert g["scrim"]["height"] > g["dock"]["height"] + 20, (
        f"scrim ({g['scrim']['height']}px) is not taller than the dock "
        f"({g['dock']['height']}px) — there is no fade band above it"
    )


def test_scrim_does_not_paint_over_the_composer(ui_harness, page) -> None:
    """The scrim is a BACKDROP: the composer card must paint above it.

    The scrim is a positioned descendant of the dock (`position: absolute`,
    `z-index: auto`) and CSS paints positioned descendants AFTER in-flow,
    non-positioned content. The card used to be static, so the scrim's opaque
    band — which spans the dock's full height — painted straight over the
    input row: the textarea, the paperclip and the Send button all vanished
    and the user was left with an empty card and a toolbar.

    Every other assertion in this suite still passed while that was true, and
    so did `elementFromPoint`, because `pointer-events: none` hides the scrim
    from hit-testing. This probe flips the scrim back to `pointer-events: auto`
    so hit-testing follows paint order, and requires the composer to be the
    thing on top at the two points the user actually looks at.
    """
    session_id = "sess-float-paintregion"
    _open_chat(ui_harness, page, session_id)

    p = page.evaluate(_PAINT_ORDER_SCRIPT)
    print(f"\n[float-composer] paint order: {p}")
    assert p.get("missing") is not True, f"composer pieces missing: {p}"

    # The instrument itself: without this the assertions below are vacuous.
    assert p["scrimMadeHittable"], (
        "could not make the scrim hit-testable, so this probe would pass "
        f"without proving anything: {p}"
    )
    # Precondition — if the scrim did not overlap the card, this test would
    # not be testing the thing it claims to test.
    assert p["scrimCoversCard"], (
        f"the scrim no longer overlaps the card, so paint order is moot: {p}"
    )
    for name, point in p["points"].items():
        assert not point["isScrim"], (
            f"the scrim is painted over the {name} at {point['point']} — the "
            f"composer is invisible to the user: {p}"
        )
        assert point["insideCard"], (
            f"something outside the composer card is on top of the {name} at "
            f"{point['point']} (got {point['hit']}): {p}"
        )

    # The card must not merely be on top — it must still be a real composer.
    # A collapsed/zero-height form is the same user-visible bug in another
    # disguise, and the box maths above would happily pass it.
    assert p["formHeight"] >= 30, (
        f"the input row collapsed to {p['formHeight']}px inside a "
        f"{p['cardHeight']}px card — the composer is not usable: {p}"
    )
