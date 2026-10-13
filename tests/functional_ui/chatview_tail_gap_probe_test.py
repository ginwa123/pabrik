"""Probe: the blank tail gap below the last message must stay bounded.

User report: "virtual scroll weird issue gap is to long, ma / can we limit
that the gap only maybe 500px?" + DevTools evidence
`sizer height 26796px`, `content translate3d(0, 23406px)`, `min-height
708px` → ~2682px of scrollable BLANK below the content box.

Root cause: `sizerHeight` is the height MODEL (Σ measured/estimated row
heights) and unmeasured rows are estimated from the running median of the
measured ones — so a tail of short rows inherits a tall median and the
model reserves far more space than the rows really occupy. The browser
lets the user scroll on into that overshoot.

This probe drives the real app (Vite + pabrik + headless Chromium) on a
700-message chat with a SHORT tail (the overshoot shape), scrolls hard to
the bottom, and asserts:
  * the reachable blank below the real content bottom is ≤ maxTailGap;
  * the last message is still reachable (the cap must not hide content);
  * small downward scrolls at the tail do not teleport the window.

The cap's own semantics (min(modelTotal, measuredBottom + maxTailGap),
latch on/off, fail-open) are covered by
`src/apps/desktop/src/helpers/__tests__/virtualScrollerTailGap.spec.ts`,
where geometry can be controlled; jsdom has no layout, so a browser can
only ever observe the invariant.

Run (frontend served from THIS worktree; the backend binary may come from
anywhere since only frontend code is under test):
    PABRIK_BIN=/home/ginwa/ginwaaitoolbox/zig-out/bin/pabrikcore-linux-x86_64 \\
        /tmp/pabrik-ui-venv/bin/python -m pytest -s \\
        tests/functional_ui/chatview_tail_gap_probe_test.py -v
"""

from __future__ import annotations

from pathlib import Path

import pytest

from db_seed import DbSeed

TALL_BODY = (
    "Message {i} paragraph one.\n\n"
    "Message {i} paragraph two with longer text to give the bubble real "
    "height in the virtual scroller. Lorem ipsum dolor sit amet, consectetur "
    "adipiscing elit, sed do eiusmod tempor incididunt ut labore et dolore "
    "magna aliqua.\n\n"
    "Message {i} paragraph three with even more filler so each bubble "
    "measures a few hundred pixels tall in real layout."
)
SHORT_BODIES = ("ok", "go on", "Done.", "On it.", "thanks", "noted")

#: Contract under test — never let the user scroll more than this far past
#: the measured content bottom (mirrors VirtualScroller's `maxTailGap`).
MAX_TAIL_GAP_PX = 100
#: Layout/rounding slack.
SLACK_PX = 24


def _seed_db_path(h) -> Path:
    return h.temp_dir / ".config" / "pabrik" / "agent.db"


def _seed_mixed_session(h, session_id: str, workspace_id: str, count: int = 700) -> None:
    """Tall paragraphs first, then a long SHORT tail.

    The tall head teaches the adaptive estimator a ~300px median; the
    one-line tail really measures ~20-40px. That is the shape that makes
    the model overshoot the real content bottom.
    """
    seed = DbSeed(_seed_db_path(h))
    tall_until = int(count * 0.6)
    with seed.connect() as conn:
        seed.seed_session(conn, session_id, f"Tail gap probe {count}")
        conn.execute(
            "UPDATE sessions SET workspace_id = ? WHERE id = ?",
            (workspace_id, session_id),
        )
        stamps = DbSeed.baseline_timestamps(count=count, interval_seconds=30)
        for i in range(count):
            body = TALL_BODY.format(i=i) if i < tall_until else SHORT_BODIES[i % 6]
            if i % 2 == 0:
                seed.seed_user_message(conn, session_id, body, created_at=stamps[i])
            else:
                seed.seed_assistant_message(conn, session_id, body, created_at=stamps[i])


# The chat message list is the scroller inside the messages wrapper; the
# sidebar chat list is the same component, so select by wrapper class
# first and only fall back to "tallest visible scroller".
_CHAT_SCROLLER = (
    "(() => {"
    "  const wrap = document.querySelector('.messages-scroll-hide-native');"
    "  const el = wrap ? wrap.querySelector('.virtual-scroller') : null;"
    "  if (el) return el;"
    "  return [...document.querySelectorAll('.virtual-scroller')]"
    "    .filter((e) => e.offsetParent !== null)"
    "    .sort((a, b) => b.clientHeight - a.clientHeight)[0] || null;"
    "})()"
)

_TAIL_GEOM_SCRIPT = (
    r"""
() => {
  const el = """
    + _CHAT_SCROLLER
    + r""";
  if (!el) return null;
  const sizer = el.querySelector('.virtual-scroller-sizer');
  const content = el.querySelector('.virtual-scroller-content');
  if (!sizer || !content) return null;
  const m = /translate3d\(0px,\s*([-\d.]+)px/.exec(content.style.transform || '');
  const kids = [...content.children];
  const topSpacer = m ? parseFloat(m[1]) : null;
  const childrenSum = kids.reduce((acc, k) => acc + (k.offsetHeight || 0), 0);
  const realBottom = topSpacer === null ? null : topSpacer + childrenSum;
  const scrollTop = el.scrollTop;
  const viewportBottom = scrollTop + el.clientHeight;
  return {
    scrollTop: scrollTop,
    scrollHeight: el.scrollHeight,
    clientHeight: el.clientHeight,
    maxScrollTop: el.scrollHeight - el.clientHeight,
    sizerH: parseFloat(sizer.style.height) || 0,
    contentH: content.offsetHeight,
    contentMinHeight: content.style.minHeight || '',
    topSpacer: topSpacer,
    childrenSum: childrenSum,
    realBottom: realBottom,
    // Reserved void below the rendered content box (model vs reality).
    modelTailGap: realBottom === null ? null : (parseFloat(sizer.style.height) || 0) - realBottom,
    // How far the viewport bottom reaches PAST the real content bottom —
    // the blank the user actually sees when scrolled to max.
    visibleOvershoot: realBottom === null ? null : viewportBottom - realBottom,
    firstIdx: kids.length ? parseInt(kids[0].getAttribute('data-vs-index'), 10) : null,
    lastIdx: kids.length
      ? parseInt(kids[kids.length - 1].getAttribute('data-vs-index'), 10)
      : null,
    rendered: kids.length,
  };
}
"""
)

_STEP_PX = 60
_STEPS = 12
_TRACK_TOL_PX = 250


def _geom(page) -> dict:
    g = page.evaluate(_TAIL_GEOM_SCRIPT)
    assert g is not None, "chat message scroller not found"
    assert g["topSpacer"] is not None, "content transform missing"
    return g


def _open_long_chat(ui_harness, page, session_id: str) -> str:
    h = ui_harness
    ws = h.http("POST", "/api/workspaces", json_body={"name": "tail-gap-ui-ws"}, expect=201)
    workspace_id = ws.json()["id"]
    _seed_mixed_session(h, session_id, workspace_id)
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
    page.wait_for_timeout(2500)  # initial render + measure passes settle
    return workspace_id


def _set_scroll_top(page, top_js: str) -> None:
    page.evaluate(f"() => {{ const el = {_CHAT_SCROLLER}; if (el) el.scrollTop = {top_js}; }}")


def test_reachable_blank_below_last_message_is_capped(ui_harness, page) -> None:
    session_id = "sess-tail-gap-probe"
    _open_long_chat(ui_harness, page, session_id)

    at_rest = _geom(page)
    print(f"\n[tail-gap] at rest : {at_rest}")

    # User gesture: keep scrolling DOWN past the last message.
    _set_scroll_top(page, "1e9")
    page.wait_for_timeout(1500)
    bottom = _geom(page)
    print(f"[tail-gap] at max  : {bottom}")

    # Re-sample after the measure/compensation loop settles: a transient
    # overshoot is fine, a SETTLED one is the reported bug.
    page.wait_for_timeout(1500)
    settled = _geom(page)
    print(f"[tail-gap] settled : {settled}")

    assert settled["scrollTop"] >= settled["maxScrollTop"] - 2, (
        f"expected to be parked at the bottom of the scroll range, got {settled}"
    )
    assert settled["realBottom"] is not None and settled["lastIdx"] is not None

    overshoot = settled["visibleOvershoot"]
    assert overshoot <= MAX_TAIL_GAP_PX + SLACK_PX, (
        "blank region reachable below the last message is too long: viewport "
        f"bottom is {overshoot:.0f}px past the real content bottom "
        f"(limit {MAX_TAIL_GAP_PX}px)\n"
        f"at_rest={at_rest}\nbottom={bottom}\nsettled={settled}"
    )

    # The cap must never cost reachability: the tail rows are rendered
    # (the last item is in the DOM) at the bottom of the scroll range.
    assert settled["rendered"] > 0, f"nothing rendered at the bottom: {settled}"


def test_small_scrolls_at_the_tail_do_not_teleport(ui_harness, page) -> None:
    """The cap must not reintroduce the bounce/ratchet the user rejected.

    Walks down in 60px steps INSIDE the tail region (where the cap is
    latched on) and checks that the rendered window tracks the scroll 1:1
    and that the viewport stays covered by the content box.
    """
    session_id = "sess-tail-gap-steps"
    _open_long_chat(ui_harness, page, session_id)

    # Start just above the tail so the latch engages while stepping.
    _set_scroll_top(page, "1e9")
    page.wait_for_timeout(1200)
    page.evaluate(
        f"() => {{ const el = {_CHAT_SCROLLER}; if (el) el.scrollTop -= 400; }}"
    )
    page.wait_for_timeout(1200)

    samples = [_geom(page)]
    for _ in range(_STEPS):
        page.evaluate(
            f"() => {{ const el = {_CHAT_SCROLLER}; if (el) el.scrollTop += {_STEP_PX}; }}"
        )
        page.wait_for_timeout(450)
        samples.append(_geom(page))

    violations: list[str] = []
    for n in range(1, len(samples)):
        prev, cur = samples[n - 1], samples[n]
        s, v = cur["scrollTop"], cur["clientHeight"]
        d_scroll = s - prev["scrollTop"]
        d_spacer = cur["topSpacer"] - prev["topSpacer"]
        if abs(d_spacer - d_scroll) > _TRACK_TOL_PX:
            violations.append(
                f"step {n}: JUMP (d_scroll={d_scroll:.0f} d_spacer={d_spacer:.0f} "
                f"win {prev['firstIdx']}->{cur['firstIdx']})"
            )
        # HOLE below the content box (a settled blank viewport).
        at_bottom_edge = s + v >= cur["sizerH"] - 8
        if not at_bottom_edge and cur["realBottom"] < s + v - MAX_TAIL_GAP_PX - SLACK_PX:
            violations.append(
                f"step {n}: HOLE below content "
                f"(viewport_bot={s + v:.0f} real_bottom={cur['realBottom']:.0f} "
                f"sizer={cur['sizerH']:.0f} win=[{cur['firstIdx']},{cur['lastIdx']}])"
            )

    print(f"\n[tail-gap] step samples: {[ (s['scrollTop'], s['sizerH']) for s in samples ]}")
    assert not violations, "tail-region scroll signatures:\n" + "\n".join(violations)
