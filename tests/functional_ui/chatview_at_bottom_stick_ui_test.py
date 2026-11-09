"""Functional UI test: the at-bottom stick stays armed for the whole session.

The report, verbatim:

    "auto scroll bottom if it already reached bottom, but the issues now its,
     sometimes not autoscroll bottom"

What was wrong
    ChatView and VirtualScroller each had their own idea of "the bottom":

      * `VirtualScroller.scrollToBottom` parks the reader on the REAL content
        bottom — `topSpacer + content.offsetHeight` — whenever the height model
        overshoots by more than its hysteresis. That is the blank-viewport fix:
        the sizer is a height MODEL, and trusting it can strand the reader in a
        fully blank region.
      * ChatView decided at-bottom with the DOM's ruler, `scrollHeight -
        clientHeight`, against a 10px tolerance.

    With the tail cap latched (`maxTailGap`, 100px by default) the two disagree
    by the overshoot. So a *successful* auto-stick produced the scroll event
    that immediately said "the user left the bottom", and all four gates that
    read that flag — the conditional `scrollToBottom`, the `contentShift`
    re-stick, the SSE-chunk remeasure and the messages-length watcher — went
    quiet for the rest of the mount. The chat simply stopped following the
    stream, and the jump-to-bottom arrow appeared while the reader sat on the
    last message. Hence "sometimes": it needs the tail cap latched, i.e. a long
    chat whose tail rows are shorter than the running median.

Why a real browser is the only place this can be proven
    The defect is entirely about AGREEMENT BETWEEN TWO RULERS on real measured
    geometry. jsdom has no layout, so `scrollHeight`, `offsetHeight` and the
    `translate3d` on the content window are all zeros there — the two rulers
    are identical and the bug is invisible by construction. Here the sizer
    really does overshoot a short tail, and both numbers are readable.

The two observables
    1. `.chat-scroll-to-bottom` — rendered under `v-if="!isAtBottom && …"`, so
       its ABSENCE is the flag every follow gate reads. This is the primary
       assertion: a scroll position can look right while the app believes the
       reader walked away, and that is precisely the bug.
    2. The app's own ruler, recomputed in the page from the same DOM nodes the
       scroller reads (`topSpacer` from the content transform + the rendered
       rows' real heights). Asserting `scrollTop` against `scrollHeight` — as
       the older send-scroll test does with `BOTTOM_TOL_PX = 24` — measures the
       BUG, not the behaviour: a correct stick sits up to `maxTailGap` above
       the DOM max on purpose.

Run (the frontend is served from THIS worktree — that is the code under test;
the backend binary can come from anywhere, since no backend code changed):

    zig build
    PABRIK_BIN=./zig-out/bin/pabrikcore-linux-x86_64 \\
        python3 -m pytest tests/functional_ui/chatview_at_bottom_stick_ui_test.py -v

Ports: the UI harness reserves (5173, 8081) and picks both the backend and the
Vite port from [20000, 32000]. NEVER 8081 — a dev server runs there.
"""

from __future__ import annotations

import pytest

from chatview_boot import bind_session_workspace, create_workspace, open_chatview
from db_seed import DbSeed
from ui_harness import UIHarness

#: A long chat so the tail cap has room to latch, and the transcript is many
#: viewports tall. Virtualized, so the cost is bounded by the scroller window.
TURN_COUNT = 600

#: Tall bodies for the head, one-liners for the tail. This is the shape that
#: makes the height model overshoot: the estimator learns a tall median from
#: the head and the short tail inherits it, so the sizer reserves far more
#: space than the tail really occupies. Same construction as
#: chatview_tail_gap_probe_test.py.
TALL_BODY = (
    "Turn {i} — paragraph one.\n\n"
    "Turn {i} — paragraph two with enough text to give the bubble real height in "
    "the virtual scroller. Lorem ipsum dolor sit amet, consectetur adipiscing "
    "elit, sed do eiusmod tempor incididunt ut labore et dolore magna aliqua.\n\n"
    "Turn {i} — paragraph three with even more filler so each bubble measures a "
    "few hundred pixels tall in real layout."
)
SHORT_BODIES = ("ok", "go on", "Done.", "On it.", "thanks", "noted")

#: `VirtualScroller`'s `maxTailGap` default. A correct stick is allowed to sit
#: this far above the DOM max — that gap IS the blank-viewport protection.
MAX_TAIL_GAP_PX = 100
#: `VirtualScroller`'s `HYSTERESIS_PX` — below this the scroller trusts the
#: sizer and both rulers coincide.
HYSTERESIS_PX = 50
#: Layout/rounding slack for a "parked at the bottom" comparison.
SLACK_PX = 24


@pytest.fixture(autouse=True)
def _arm_sse_emit_gate(monkeypatch: pytest.MonkeyPatch) -> None:
    """Arm the test-only SSE emit gate BEFORE the harness boots."""
    monkeypatch.setenv("PABRIK_TEST_SSE_EMIT", "1")


# ─── Reading the two rulers from a real browser ──────────────────────────────

# Two `.virtual-scroller` elements exist (the sidebar chat list and the chat
# transcript). Scope to the transcript's own wrapper and keep a "tallest
# visible" fallback so a template rename is a readable failure, not a null.
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

# NOTE: this is a MULTI-LINE script and every `//` comment sits on its own
# line. Playwright evaluates it as one line, so a trailing `//` comment would
# swallow the closing brace and fail with "Unexpected end of input" — which is
# what string-concatenating the script into a single line would produce. (The
# sibling probes get away without `//` comments for exactly that reason.)
_GEOM_SCRIPT = (
    r"""
() => {
  const el = """
    + _CHAT_SCROLLER
    + r""";
  if (!el) return null;
  const content = el.querySelector('.virtual-scroller-content');
  if (!content) return null;
  const m = /translate3d\(0px,\s*([-\d.]+)px/.exec(content.style.transform || '');
  const topSpacer = m ? parseFloat(m[1]) : 0;
  const kids = [...content.children];
  const rowsSum = kids.reduce((acc, k) => acc + (k.offsetHeight || 0), 0);
  const contentBottom = topSpacer + rowsSum;
  const clientHeight = el.clientHeight;
  const domEdge = el.scrollHeight - clientHeight;
  // The app's OWN bottom, read from the value it exposes for exactly this
  // purpose (`VirtualScroller.bottomScrollTop`, the same number the
  // auto-stick targets and the same one `isAtBottom` is measured against).
  // Re-deriving it here would be re-implementing the predicate under test —
  // and getting it wrong is exactly the bug this file exists to catch, which
  // is how the first draft of this helper "passed" while asserting nothing.
  // Vue 3 attaches `__vueParentComponent` to every element, and the scroller's
  // root element is that component's own root, so `exposed` is the real
  // instance. Falls back to the DOM edge if the internal handle is not
  // reachable (a production build that stripped it, a future template change),
  // so a rename degrades to the weaker assertion instead of a null.
  let appBottom = domEdge;
  let appRulerSource = 'dom-fallback';
  try {
    const inst = el.__vueParentComponent;
    const exposed = inst && inst.exposed;
    if (exposed && typeof exposed.bottomScrollTop === 'function') {
      const v = exposed.bottomScrollTop();
      if (typeof v === 'number' && isFinite(v)) {
        appBottom = v;
        appRulerSource = 'exposed';
      }
    }
  } catch (e) {
    appBottom = domEdge;
  }
  return {
    scrollTop: el.scrollTop,
    scrollHeight: el.scrollHeight,
    clientHeight: clientHeight,
    maxScrollTop: domEdge,
    topSpacer: topSpacer,
    realBottom: contentBottom,
    appBottom: appBottom,
    appRulerSource: appRulerSource,
    // How far the two rulers disagree — the quantity the fix removed.
    rulerGap: domEdge - appBottom,
    arrow: !!document.querySelector('.chat-scroll-to-bottom'),
    rendered: kids.length,
    lastIdx: kids.length
      ? parseInt(kids[kids.length - 1].getAttribute('data-vs-index'), 10)
      : null,
  };
}
"""
)


def _geom(page) -> dict:
    g = page.evaluate(_GEOM_SCRIPT)
    assert g is not None, "chat message scroller not found"
    assert g["appRulerSource"] == "exposed", (
        "could not read VirtualScroller.bottomScrollTop from the mounted "
        "instance — this test would silently fall back to the DOM ruler, which "
        f"is the pre-fix definition: {g}"
    )
    return g


def _seed_session(
    h: UIHarness, workspace_id: str, session_id: str, *, mixed: bool = False
) -> None:
    """Seed a transcript far taller than the viewport.

    `mixed=True` gives the tall-head/short-tail shape whose learned median
    makes the model overshoot on its own. It is available for probes, but the
    tests here use the uniform shape by default: the overshoot is STAGED
    explicitly (see `_stage_persistent_overshoot`) so the defect is reproduced
    deterministically, and a mixed seed adds a second, unrelated variable — a
    large model correction when the head is first measured, which moves the
    reader on its own and fails assertions for reasons unrelated to the stick.
    """
    seed = DbSeed(h.temp_dir / ".config" / "pabrik" / "agent.db")
    tall_until = int(TURN_COUNT * 0.6) if mixed else TURN_COUNT
    with seed.connect() as conn:
        seed.seed_session(conn, session_id, f"At-bottom stick {TURN_COUNT}")
        bind_session_workspace(conn, workspace_id, session_id)
        stamps = DbSeed.baseline_timestamps(count=TURN_COUNT, interval_seconds=30)
        for i in range(TURN_COUNT):
            body = TALL_BODY.format(i=i) if i < tall_until else SHORT_BODIES[i % len(SHORT_BODIES)]
            if i % 2 == 0:
                seed.seed_user_message(conn, session_id, body, created_at=stamps[i])
            else:
                seed.seed_assistant_message(conn, session_id, body, created_at=stamps[i])


def _open_chat(page, h: UIHarness, session_id: str) -> str:
    workspace_id = create_workspace(h)
    _seed_session(h, workspace_id, session_id)
    open_chatview(page, h, workspace_id, session_id)
    page.wait_for_function(
        "() => { const w = document.querySelector('.messages-scroll-hide-native');"
        " return !!(w && w.querySelector('.virtual-scroller')); }",
        timeout=30000,
    )
    # Initial render, then the scroller's measurement passes. The overshoot this
    # whole file depends on only exists AFTER the model has learned the head's
    # median, so cutting this short measures the wrong thing.
    page.wait_for_timeout(2500)
    return workspace_id


def _emit_chunk(h: UIHarness, session_id: str, text: str) -> None:
    h.http(
        "POST",
        "/api/dev/sse/emit_llm",
        json_body={"type": "chunk", "content": text, "session_id": session_id},
        expect=200,
    )


def _emit_chunk_and_settle(
    page, h: UIHarness, session_id: str, text: str, marker: str
) -> dict:
    """Emit a chunk, wait for it to land, then wait for the scroller to rest.

    ``_settle`` alone can return before the chunk has reached the browser:
    it stops on motion ceasing, and a scroller that has not started moving
    yet is trivially at rest. The chunk has landed when the transcript
    grew — ``scrollHeight`` is the one signal that works whether or not
    the new row is inside the virtual window, which it is not when the
    reader has scrolled up. ``marker`` is the fallback for a chunk that
    lands without growing the sizer.
    """
    before = page.evaluate(
        "() => { const el = " + _CHAT_SCROLLER + "; return el ? el.scrollHeight : 0; }"
    )
    _emit_chunk(h, session_id, text)
    page.wait_for_function(
        "([t, h0]) => {"
        "  const el = " + _CHAT_SCROLLER + ";"
        "  if (!el) return false;"
        "  return el.scrollHeight > h0 || document.body.textContent.includes(t);"
        "}",
        arg=[marker, before],
        timeout=15000,
    )
    return _settle(page)


def _emit_turn(h: UIHarness, session_id: str, text: str, *, index: int) -> None:
    h.http(
        "POST",
        "/api/dev/sse/emit_llm",
        json_body={
            "type": "full",
            "session_id": session_id,
            "role": "assistant",
            "content": text,
            "finish_reason": "stop",
            "index": index,
        },
        expect=200,
    )


def _scroll_to_fraction(page, frac: float) -> None:
    page.evaluate(
        "() => { const el = " + _CHAT_SCROLLER + "; if (el) el.scrollTop = el.scrollHeight * "
        + str(frac)
        + "; }"
    )
    _settle(page)


def _set_scroll_top(page, top_js: str) -> None:
    page.evaluate(f"() => {{ const el = {_CHAT_SCROLLER}; if (el) el.scrollTop = {top_js}; }}")
    _settle(page)


def _ruler_gap(page) -> float:
    """How far the app's bottom and the DOM's bottom disagree, right now."""
    return float(_geom(page)["rulerGap"])


_STAGE_OVERSHOOT_JS = r"""
(px) => {
  const wrap = document.querySelector('.messages-scroll-hide-native');
  const el = wrap ? wrap.querySelector('.virtual-scroller') : null;
  if (!el) return {ok: false, why: 'no scroller'};
  const sizer = el.querySelector('.virtual-scroller-sizer');
  if (!sizer) return {ok: false, why: 'no sizer'};
  const content = el.querySelector('.virtual-scroller-content');
  if (!content) return {ok: false, why: 'no content'};
  const base = parseFloat(sizer.style.height) || 0;
  if (window.__atBottomOvershoot) {
    window.__atBottomOvershoot.stop();
    window.__atBottomOvershoot = null;
  }
  // A one-shot bump is NOT enough: the scroller's own measure pass recomputes
  // the sizer from the model within a frame and heals it, so the overshoot is
  // gone before any at-bottom decision reads it. A model that KEEPS overshooting
  // is the real condition — that is exactly what the tail cap does at the end
  // of a long chat — so the gap is held for as long as the test needs it.
  //
  // The hold is RELATIVE to the live content bottom, not an absolute height.
  // Pinning an absolute value would stop being an overshoot the moment the
  // stream grew past it and would silently become an UNDERSHOOT, which is a
  // different (and much less interesting) state. The loop only writes the
  // sizer's own inline height; the app then runs its real scroll, its real
  // measure pass and its real at-bottom decision on the result.
  const tick = () => {
    const m = /translate3d\(0px,\s*([-\d.]+)px/.exec(content.style.transform || '');
    const top = m ? parseFloat(m[1]) : 0;
    const rows = [...content.children].reduce((a, k) => a + (k.offsetHeight || 0), 0);
    sizer.style.height = Math.max(base, top + rows) + px + 'px';
  };
  const id = setInterval(tick, 16);
  tick();
  window.__atBottomOvershoot = {
    stop() { clearInterval(id); },
    base: base,
    px: px,
  };
  return {ok: true, base: base, overshoot: px};
}
"""

_RELEASE_OVERSHOOT_JS = r"""
() => {
  if (!window.__atBottomOvershoot) return {ok: true, was: null};
  const was = {base: window.__atBottomOvershoot.base, px: window.__atBottomOvershoot.px};
  window.__atBottomOvershoot.stop();
  window.__atBottomOvershoot = null;
  return {ok: true, was: was};
}
"""


def _stage_persistent_overshoot(page, px: int) -> dict:
    """Hold the height model `px` above the real content, until released.

    The defect needs the model to overshoot the content by more than
    `HYSTERESIS_PX` (50). Whether a given seeding produces that depends on the
    estimator's learned median, and in practice a settled chat lands within a
    few px — so a test that merely SEEDS an overshooting chat passes on the
    pre-fix build too, and proves nothing. Staging the input is what makes this
    a regression test rather than a smoke test.
    """
    return page.evaluate(_STAGE_OVERSHOOT_JS, px)


def _release_overshoot(page) -> dict:
    return page.evaluate(_RELEASE_OVERSHOOT_JS)


# ─── The edge-case matrix ────────────────────────────────────────────────────


#: Wait until the scroller stops moving before sampling it.
#:
#: The chunk tests used a fixed 450ms sleep and then sampled. On a loaded
#: runner the measure + auto-stick cycle has not finished in 450ms, so the
#: sample catches the reader mid-settle and reports "the stick died again
#: mid-stream" — a flake that hits Linux and macOS alike (it failed on both
#: here and on `main`). Waiting for the scroller to actually come to rest is
#: what the test actually means by "after the chunk", and it does NOT wait
#: for the condition under assertion: it stops on motion ceasing, so a stick
#: that has genuinely disarmed still settles and still fails.
_SETTLE_JS = r"""
() => new Promise((resolve) => {
  const el = (() => {
    const wrap = document.querySelector('.messages-scroll-hide-native');
    return wrap ? wrap.querySelector('.virtual-scroller') : null;
  })();
  if (!el) { resolve({ok: false}); return; }
  const deadline = performance.now() + 8000;
  let lastTop = el.scrollTop;
  let lastH = el.scrollHeight;
  let stable = 0;
  const tick = () => {
    const t = el.scrollTop;
    const hh = el.scrollHeight;
    if (t === lastTop && hh === lastH) {
      stable += 1;
    } else {
      stable = 0;
      lastTop = t;
      lastH = hh;
    }
    if (stable >= 4) { resolve({ok: true, scrollTop: lastTop, scrollHeight: lastH}); return; }
    if (performance.now() > deadline) {
      resolve({ok: false, scrollTop: lastTop, scrollHeight: lastH});
      return;
    }
    requestAnimationFrame(tick);
  };
  requestAnimationFrame(tick);
})
"""


def _settle(page) -> dict:
    """Block until the chat scroller stops moving, then return its position."""
    return page.evaluate(_SETTLE_JS)


def test_the_stick_survives_a_sizer_that_overshoots_the_content(
    ui_harness: UIHarness, page
) -> None:
    """THE regression: the two rulers disagree, and the stick must not die.

    This is the test that is red on the pre-fix build, and it is deliberately
    the first one. Every other test here passes either way, because a settled
    chat leaves a ruler gap of 0-3px and the two definitions coincide. The
    defect only appears once the height MODEL overshoots the real content by
    more than the scroller's hysteresis — which is what the tail cap
    (`maxTailGap`, 100px) produces routinely at the end of a long chat, and
    what `_inflate_sizer` stages on demand.

    The sequence is exactly the reported failure:

      1. the reader is at the bottom and the stick is armed;
      2. the model overshoots, so the DOM's max is 150px BELOW where a
         successful auto-stick lands;
      3. the app's own `bottomScrollTop` still targets the real content bottom,
         so the next auto-stick puts the reader in exactly that 150px gap;
      4. the scroll event that follows measures the reader 150px from the DOM's
         max and concludes they scrolled up.

    Pre-fix, step 4 flips `isAtBottom` false for good: the arrow appears, and
    every following chunk grows the transcript off-screen. Post-fix the same
    sequence reports a gap of 0 and the stick holds.
    """
    h = ui_harness
    session_id = "sess-at-bottom-overshoot"
    _open_chat(page, h, session_id)

    page.evaluate("() => { const el = " + _CHAT_SCROLLER + "; if (el) el.scrollTop = 1e9; }")
    _settle(page)
    armed = _geom(page)
    print(f"\n[at-bottom] armed before the overshoot : {armed}")
    assert not armed["arrow"], f"precondition failed: the stick is not armed: {armed}"

    try:
        # Stage the overshoot, and PROVE it took effect before asserting
        # anything downstream — otherwise this test could pass by never
        # reproducing the defect at all.
        staged0 = _stage_persistent_overshoot(page, 150)
        assert staged0.get("ok"), f"could not stage the overshoot: {staged0}"
        _settle(page)
        staged = _geom(page)
        print(f"[at-bottom] staged overshoot : {staged}")
        assert staged["rulerGap"] > HYSTERESIS_PX, (
            "the staging did not take: the two rulers still agree, so this test "
            f"would pass without exercising the defect at all: {staged}"
        )

        # The next auto-stick: a chunk. Pre-fix this is where the stick dies.
        _emit_chunk(h, session_id, "The chunk that arrives while the model overshoots. " * 3)
        _settle(page)
        after = _geom(page)
        print(f"[at-bottom] after the first chunk : {after}")

        assert not after["arrow"], (
            f"the stick disarmed itself on a model overshoot of {staged['rulerGap']:.0f}px "
            f"— the reader was at the bottom the whole time: {after}"
        )
        assert after["scrollTop"] >= after["appBottom"] - SLACK_PX, (
            f"the reader is stranded {after['appBottom'] - after['scrollTop']:.0f}px above "
            f"the bottom after a routine chunk: {after}"
        )

        # …and it must stay alive for the rest of the stream, not for one chunk.
        for k in range(6):
            _emit_chunk(
                h, session_id, f"Follow-up {k}: " + "more words for the tail row. " * 3
            )
            _settle(page)
        final = _geom(page)
        print(f"[at-bottom] after the rest of the stream : {final}")
        assert not final["arrow"], f"the stick died again mid-stream: {final}"
        assert final["scrollTop"] >= final["appBottom"] - SLACK_PX, (
            f"reader stranded: {final}"
        )
    finally:
        _release_overshoot(page)


def test_a_long_chat_opens_with_the_stick_armed(ui_harness: UIHarness, page) -> None:
    """Edge case: the initial load must not arm-then-disarm itself.

    This is the exact shape of the report. The initial `scrollToBottom(true)`
    parks the reader on the real content bottom; the browser then fires a real
    scroll event; and pre-fix that event measured the reader 100px short of
    the DOM max and concluded they had scrolled up. The arrow appeared on a
    chat the reader never touched, and nothing re-armed it.
    """
    h = ui_harness
    session_id = "sess-at-bottom-open"
    _open_chat(page, h, session_id)

    g = _geom(page)
    print(f"\n[at-bottom] on open : {g}")
    assert g["maxScrollTop"] > 5000, f"transcript is not usably scrollable: {g}"
    assert g["rendered"] > 0, f"nothing rendered: {g}"
    assert not g["arrow"], (
        "a chat opened at its newest turn shows the jump-to-bottom arrow, so "
        f"the app believes the reader walked away from a bottom they never left: {g}"
    )
    assert g["scrollTop"] >= g["appBottom"] - SLACK_PX, (
        "the reader is not parked on the app's own bottom: "
        f"scrollTop={g['scrollTop']} appBottom={g['appBottom']} {g}"
    )
    # The blank-viewport protection must still be doing its job: the fix moved
    # the RULER, it did not move the landing position. A settled overshoot far
    # past the cap is the blank-viewport bug returning.
    assert g["rulerGap"] <= MAX_TAIL_GAP_PX + SLACK_PX, (
        f"the sizer overshoots the real content by {g['rulerGap']:.0f}px, past the "
        f"{MAX_TAIL_GAP_PX}px tail cap — the reader could be stranded in blank space: {g}"
    )


def test_the_stick_survives_a_long_stream(ui_harness: UIHarness, page) -> None:
    """Edge case: "sometimes" means a stick that dies partway through.

    A single successful stick is not the claim. The claim is that the STATE it
    leaves behind — the flag every follow gate reads — is still set after the
    tenth chunk. Pre-fix, the first chunk was enough to disarm it forever, and
    the transcript quietly stopped growing into the viewport.
    """
    h = ui_harness
    session_id = "sess-at-bottom-stream"
    _open_chat(page, h, session_id)

    opened = _geom(page)
    assert not opened["arrow"], f"precondition failed: not armed on open: {opened}"

    samples: list[dict] = []
    for k in range(12):
        _emit_chunk_and_settle(
            page,
            h,
            session_id,
            f"Stream part {k}: " + "a run of words that makes the tail row grow. " * 4,
            f"Stream part {k}",
        )
        samples.append(_geom(page))

    print(f"\n[at-bottom] stream samples: {[(s['scrollTop'], s['arrow']) for s in samples]}")
    disarmed = [(i, s) for i, s in enumerate(samples) if s["arrow"]]
    assert not disarmed, (
        "the stick disarmed itself mid-stream — the reader was at the bottom and "
        f"the app decided otherwise at chunk {disarmed[0][0]}: {disarmed[0][1]}"
    )
    stranded = [s for s in samples if s["scrollTop"] < s["appBottom"] - SLACK_PX]
    assert not stranded, f"a chunk left the reader short of the bottom: {stranded[0]}"

    # The stream must have actually moved things, or this test proved nothing.
    final = samples[-1]
    assert final["appBottom"] > opened["appBottom"], (
        f"streaming did not grow the transcript, so nothing was under test: "
        f"{opened['appBottom']} -> {final['appBottom']}"
    )


def test_scrolling_up_disengages_and_the_stream_leaves_it_alone(ui_harness: UIHarness, page) -> None:
    """Edge case: the other half of the contract.

    A fix that made `isAtBottom` un-falsifiable would pass every test above and
    be wrong in a worse way: the reader who scrolled up to read history would
    be dragged back down on the next chunk. So the flag must still flip, and
    content growth must not re-engage it.
    """
    h = ui_harness
    session_id = "sess-at-bottom-scrolled-up"
    _open_chat(page, h, session_id)

    _scroll_to_fraction(page, 0.35)
    page.wait_for_function(
        "() => !!document.querySelector('.chat-scroll-to-bottom')", timeout=10000
    )
    parked = _geom(page)
    print(f"\n[at-bottom] scrolled up : {parked}")
    assert parked["arrow"], "precondition failed: scrolling up did not disarm the stick"
    assert parked["scrollTop"] < parked["appBottom"] - SLACK_PX

    # A NEGATIVE assertion: the claim is that nothing happens. There is no
    # DOM signal for "the chunk landed" here — the reader is scrolled up,
    # so the tail row is outside the virtual window and neither its text
    # nor the sizer height changes. Proving absence needs a bounded wait.
    for k in range(4):
        _emit_chunk(
            h,
            session_id,
            f"Background stream {k}: " + "words that grow the tail row. " * 4,
        )
        page.wait_for_timeout(450)

    after = _geom(page)
    print(f"[at-bottom] after stream while scrolled up : {after}")
    assert abs(after["scrollTop"] - parked["scrollTop"]) <= SLACK_PX, (
        "the reader scrolled up to read history and the stream dragged them back: "
        f"{parked['scrollTop']} -> {after['scrollTop']}"
    )
    assert after["arrow"], (
        f"the stick re-engaged for a reader who is still in the history: {after}"
    )


def test_returning_to_the_bottom_rearms_the_stick(ui_harness: UIHarness, page) -> None:
    """Edge case: the reader comes back down and the stick must come back too.

    The recovery path matters as much as the arm path. Scrolling up, then back
    down, is a gesture pair a reader does constantly while waiting for a stream
    — and if the re-arm is off by a few px, the next chunk is invisible again.
    """
    h = ui_harness
    session_id = "sess-at-bottom-return"
    _open_chat(page, h, session_id)

    _scroll_to_fraction(page, 0.4)
    page.wait_for_function(
        "() => !!document.querySelector('.chat-scroll-to-bottom')", timeout=10000
    )
    assert _geom(page)["arrow"], "precondition failed: did not disarm on scroll up"

    # Come back with the app's OWN affordance — the jump-to-bottom button. That
    # is the gesture a reader actually makes ("take me to the newest turn"),
    # and it is the one that must leave the stick ARMED, not merely scrolled
    # once. Driving the scroller from the test instead would skip the very
    # state transition under test.
    page.click(".chat-scroll-to-bottom")
    page.wait_for_function(
        "() => !document.querySelector('.chat-scroll-to-bottom')", timeout=15000
    )
    _settle(page)
    back = _geom(page)
    print(f"\n[at-bottom] back at the bottom : {back}")
    assert back["appRulerSource"] == "exposed", (
        "could not read the app's own bottom from the scroller, so the numeric "
        f"comparison below is measuring the DOM edge instead: {back}"
    )
    assert back["scrollTop"] >= back["appBottom"] - SLACK_PX, (
        f"the reader is at the bottom but not where the app thinks it is: {back}"
    )

    # …and the re-armed stick follows the next chunk. That is the claim this
    # test makes. Sampled per chunk, so a failure names the chunk that broke it
    # instead of pointing at the last of four.
    #
    # NOTE the deliberate stop at ONE chunk. The second chunk collapses the
    # reader ~15.9k px up with no content change at all (`scrollHeight`
    # 96873 -> 96868) while the rendered window expands 34 -> 66 rows. That is
    # a DIFFERENT defect — an anchor-compensation jump in the remeasure path,
    # not the at-bottom ruler — and it is tracked, with this reproduction, in
    # `test_a_large_remeasure_does_not_yank_an_at_bottom_reader` below. Folding
    # it in here would have made this test red for a reason it does not own.
    _emit_chunk_and_settle(
        page,
        h,
        session_id,
        "After the return: " + "words that grow the tail. " * 4,
        "After the return",
    )
    final = _geom(page)
    print(f"\n[at-bottom] re-arm, one chunk later : {final}")
    assert not final["arrow"], f"the re-armed stick did not survive one chunk: {final}"
    assert final["scrollTop"] >= final["appBottom"] - SLACK_PX, f"reader stranded: {final}"


def test_a_large_remeasure_does_not_yank_an_at_bottom_reader(
    ui_harness: UIHarness, page
) -> None:
    """The anchor-compensation jump — the defect this test was an xfail for.

    This WAS a `strict=False` xfail: a large remeasure yanked an at-bottom
    reader ~15.9k px up with NO content change (scrollHeight 96873 -> 96868)
    while the rendered window expanded from 34 to 66 rows, and the stick then
    read the displaced reader as deliberately scrolled up. The marker said to
    delete it when the compensation was fixed — that is what happened, in
    `VirtualScroller.measureItems` (an at-bottom reader is re-targeted at the
    bottom edge instead of compensated around the anchor) plus the stale
    tail-cap fix in `recordTailContentBottom`. So this is now a real assertion:
    if the fix regresses, the xfail is gone and the test goes red.

    Root cause in one line: the anchor's job is to hold still whatever the
    reader is looking at, and a reader at the bottom has no view to preserve —
    the content they are reading is what the pass just resized. So the pass
    preserved a position they never chose, thousands of pixels above the
    newest content, and ChatView's `isAtBottom` correctly reported the position
    the scroller had put them in.

    The signature to look for if it ever regresses: `scrollTop` drops by
    thousands of px while `scrollHeight` is unchanged, and `rendered` jumps.
    That combination means a viewport write with no content cause — the
    scroller moved the reader, not the transcript.

    The sequence matters, and getting it wrong passes: the jump only happens
    after the reader has been UP the history and returned via the
    jump-to-bottom button, i.e. once the height model has been corrected for a
    window that was not the tail. A stream on a freshly-opened chat does not
    reproduce it.
    """
    h = ui_harness
    session_id = "sess-at-bottom-remeasure-yank"
    _open_chat(page, h, session_id)

    # The two steps that put the scroller in the state where the jump happens.
    _scroll_to_fraction(page, 0.4)
    page.wait_for_function(
        "() => !!document.querySelector('.chat-scroll-to-bottom')", timeout=10000
    )
    page.click(".chat-scroll-to-bottom")
    page.wait_for_function(
        "() => !document.querySelector('.chat-scroll-to-bottom')", timeout=15000
    )
    _settle(page)
    before = _geom(page)
    print(f"\n[remeasure-yank] armed : {before}")
    assert not before["arrow"], f"precondition failed: not armed: {before}"

    for k in range(2):
        _emit_chunk_and_settle(
            page,
            h,
            session_id,
            f"Trigger {k}: " + "words that grow the tail. " * 4,
            f"Trigger {k}",
        )
        now = _geom(page)
        print(f"[remeasure-yank] chunk {k}: {before['scrollTop']} -> {now['scrollTop']}")
        assert now["scrollTop"] >= now["appBottom"] - SLACK_PX, (
            "the reader was yanked away from the bottom with no content cause: "
            f"scrollTop {before['scrollTop']} -> {now['scrollTop']} while "
            f"scrollHeight only moved {before['scrollHeight']} -> {now['scrollHeight']} "
            f"and the window went {before['rendered']} -> {now['rendered']} rows"
        )


def test_a_reader_a_viewport_above_the_bottom_is_not_at_the_bottom(
    ui_harness: UIHarness, page
) -> None:
    """Edge case: the tolerance was NOT fattened to paper over the symptom.

    The tempting shortcut for "the DOM ruler says 100px off" is to raise
    `BOTTOM_THRESHOLD` to 120 and call the reader at the bottom. That re-engages
    the stick for someone who deliberately scrolled up, and yanks them down on
    the next chunk. So the tolerance is pinned from outside: park the reader a
    full viewport above the bottom and demand that the app still knows they are
    not at the bottom.
    """
    h = ui_harness
    session_id = "sess-at-bottom-tolerance"
    _open_chat(page, h, session_id)

    page.evaluate(
        "() => { const el = " + _CHAT_SCROLLER + "; if (el) el.scrollTop = 1e9; }"
    )
    _settle(page)
    bottom = _geom(page)
    assert not bottom["arrow"], f"precondition failed: not armed at the bottom: {bottom}"

    # One viewport up, then a few more — a deliberate read, not a fumble.
    for offset in (1, 2, 4):
        page.evaluate(
            "() => { const el = " + _CHAT_SCROLLER + "; if (el) el.scrollTop = 1e9; }"
        )
        _settle(page)
        page.evaluate(
            f"() => {{ const el = {_CHAT_SCROLLER}; if (el) el.scrollTop -= el.clientHeight * {offset}; }}"
        )
        _settle(page)
        g = _geom(page)
        assert g["arrow"], (
            f"{offset} viewport(s) above the bottom, but the app calls it 'at the "
            f"bottom' — the tolerance has been fattened instead of the ruler fixed: {g}"
        )

    # And a stream must not drag them back.
    _emit_chunk_and_settle(
        page,
        h,
        session_id,
        "Should not pull the reader down. " * 4,
        "Should not pull the reader down",
    )
    after = _geom(page)
    assert after["arrow"], f"the stick re-engaged for a deliberate reader: {after}"


def test_sending_from_history_still_lands_on_the_newest_turn(
    ui_harness: UIHarness, page
) -> None:
    """Edge case: the reader's own act overrides whatever the flag says.

    Sending is an explicit request to go to the newest turn, so it must take
    effect from anywhere in the history. This is the companion to
    chatview_send_scrolls_to_bottom_ui_test.py; it is repeated here because the
    ruler change touches the same gate that test exercises, and a green run of
    one suite should not depend on the other never having been run.
    """
    h = ui_harness
    session_id = "sess-at-bottom-send"
    _open_chat(page, h, session_id)

    before = _geom(page)
    assert before["maxScrollTop"] > 5000, f"transcript is not scrollable: {before}"

    _scroll_to_fraction(page, 0.3)
    page.wait_for_function(
        "() => !!document.querySelector('.chat-scroll-to-bottom')", timeout=10000
    )
    history = _geom(page)
    assert history["arrow"], "precondition failed: not disarmed in the history"

    text = "and now open the PR for the scroll fix"
    page.wait_for_selector(".file-input-wrapper textarea", timeout=15000)
    page.fill(".file-input-wrapper textarea", text)
    page.click("[data-testid='send-message-button']")
    _emit_turn(h, session_id, text, index=9001)

    page.wait_for_function(
        "() => !document.querySelector('.chat-scroll-to-bottom')", timeout=15000
    )
    _settle(page)
    after = _geom(page)
    print(f"\n[at-bottom] after send from history : {after}")
    assert not after["arrow"], f"the send did not re-arm the stick: {after}"
    assert after["scrollTop"] >= after["appBottom"] - SLACK_PX, (
        f"the sent turn is still below the fold: {history} -> {after}"
    )
    assert after["appBottom"] > history["appBottom"], (
        f"the sent turn did not grow the transcript, so nothing was under test: {history} -> {after}"
    )

    # The turn the reader asked for is ON SCREEN, not merely accounted for.
    on_screen = page.evaluate(
        "() => {"
        "  const el = " + _CHAT_SCROLLER + ";"
        "  const rows = [...document.querySelectorAll('[data-group-key]')];"
        "  if (!rows.length) return {found: false};"
        "  const elBox = el.getBoundingClientRect();"
        "  const box = rows[rows.length - 1].getBoundingClientRect();"
        "  return {found: true, visible: box.bottom > elBox.top && box.top < elBox.bottom};"
        "}"
    )
    assert on_screen.get("found"), "no transcript rows rendered"
    assert on_screen.get("visible"), f"the newest row is off screen: {on_screen}"
