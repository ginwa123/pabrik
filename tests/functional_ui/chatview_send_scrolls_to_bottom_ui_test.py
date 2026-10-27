"""Functional UI test: sending a message takes the transcript to the bottom.

The report, verbatim:

    "after send or quueue message it should automatically go to bottom"

Why a real browser is the only place this can be proven
    The whole auto-stick is gated on one boolean, `isAtBottom`, and a reader
    who has scrolled up to read history is `false` by definition. A send has to
    RE-ARM that boolean, and the pre-fix code did not: it called
    `scrollToBottom(true, …)`, which writes `container.scrollTop` and leaves the
    flag to whatever the browser reports afterwards. jsdom has no layout and no
    `scroll` event on `scrollTop` writes, so a unit test can neither reproduce
    that nor observe the consequence. Here the scroll is real, the geometry is
    real, and the turn the server echoes back is real.

The hard gate
    The assertion is made against the bottom measured AFTER the sent turn has
    landed, not the bottom that existed when the button was pressed. A pin that
    aims at the pre-send bottom passes a "did you scroll down?" check and still
    leaves the turn the reader just asked for one screen below the fold — which
    is the reported symptom.

    The observable for the flag itself is the floating jump-to-bottom arrow
    (`.chat-scroll-to-bottom`), which ChatView renders under
    `v-if="!isAtBottom && messageGroups.length > 0"`. Arrow gone == the stick is
    armed. That is a stronger statement than a scroll position: it is the state
    the follow gates read.

    Also asserted: the turn that was sent is actually ON SCREEN (its row is
    inside the viewport), not merely that the scroller moved.

What this does NOT prove
    HONEST SCOPE, read this before trusting a green run as "the bug is dead".

    1. Both tests here PASS on the pre-fix build. In a real browser the
       pre-fix `scrollToBottom(true, …)` does move the scroller, and the native
       `scroll` event that follows does flip `isAtBottom`. The failure the fix
       removes is the one this harness cannot stage: a scroll write that is a
       no-op (so no event, so no flag), and `isPreservingScroll` swallowing the
       pin during a lazy-load prepend with nothing scheduled to retry it. Both
       are real; neither is reachable from Playwright against a live server.

    2. The QUEUE half of the report is not covered here. Queueing needs a live
       worker — the server parks a turn in `session_queue_messages` only when
       one is already running — and the harness's stub LLM profile points at a
       dead port, so a run dies instantly and every turn ends up RUNNING
       instead of QUEUED. Holding a worker open needs a live LLM endpoint, and
       pabrik reads its profile at boot, so it cannot be swapped in from a
       fixture. The queue path is covered instead by
       `src/apps/desktop/src/__tests__/ChatView.sendScrollsToBottom.spec.ts`
       (which pins the `queue_queued` branch to the same re-arm the send uses)
       and by `ChatScrollPolicyTest.aQueuedTurnFollowsTheTranscriptWhenTheWorkerDrainsIt`
       on Android.

    What IS proved here: the behaviour the user reported, end to end, in a real
    browser against a real backend — send from up in the history, and the turn
    lands where they can see it.

Run (the frontend is served from THIS worktree — that is the code under test;
the backend binary can come from anywhere, since no backend code changed):

    zig build
    PABRIK_BIN=./zig-out/bin/pabrikcore-linux-x86_64 \\
        python3 -m pytest tests/functional_ui/chatview_send_scrolls_to_bottom_ui_test.py -v

Environment notes found the hard way here, both pre-existing and both the
reason `chatview_ui_test.py` is red on a clean tree:

  * The chat only opens at `/app/<workspace_id>/chat/<session_id>`. The
    `/app?view=chat&session=…` shape used by `chatview_ui_test.py` needs a
    workspace already in context and otherwise lands on the home screen, where
    every geometry assertion would be about the wrong scroller.
  * `page.add_init_script` is a no-op in this Playwright build, so request
    interception has to be installed with `page.evaluate` after navigation.

Ports: the UI harness reserves (5173, 8081) and picks the backend port from
[20000, 32000]. NEVER 8081 — a dev server runs there.
"""

from __future__ import annotations

from pathlib import Path

import pytest

from db_seed import DbSeed

#: Enough turns that the transcript is comfortably taller than the 800px
#: viewport, so "scrolled into history" is a real position and not a rounding
#: error. Virtualized, so the cost is bounded by the scroller's window.
TURN_COUNT = 400

#: How far up to park the reader before sending. Anywhere in the middle will
#: do; the point is only that `isAtBottom` is false.
HISTORY_FRACTION = 0.35

#: Slack for "parked at the bottom", in CSS px, measured against the app's OWN
#: bottom (`VirtualScroller.bottomScrollTop`, the number the auto-stick targets).
#: A few px because the sample and the write are not the same frame.
APP_BOTTOM_TOL_PX = 8

#: Mirrors the scroller's `maxTailGap` prop (VirtualScroller default, not
#: overridden by ChatView). It is how much blank the sizer is ALLOWED to reserve
#: below the real content, so it bounds how far the two rulers may disagree.
MAX_TAIL_GAP_PX = 100
TAIL_GAP_SLACK_PX = 8

#: Slack for the PRECONDITION "the reader is clearly up in history", in CSS px.
BOTTOM_TOL_PX = 24

#: Index fed to the dev SSE emitter. It becomes the row's id (`test-{index}`),
#: so it has to be distinct from anything the seeded rows or a real run use.
ECHO_INDEX = 9001


@pytest.fixture(autouse=True)
def _arm_sse_emit_gate(monkeypatch: pytest.MonkeyPatch) -> None:
    """Arm the test-only SSE emit gate BEFORE the harness boots."""
    monkeypatch.setenv("PABRIK_TEST_SSE_EMIT", "1")


# ─── The scroller ────────────────────────────────────────────────────────────

# Two `.virtual-scroller` elements exist (the sidebar chat list and the chat
# transcript). Scope to the transcript's own wrapper, which is what
# chatview_tail_gap_probe_test.py does, and fall back to the tallest visible
# scroller so a template rename is a readable failure rather than a null.
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

# `.chat-scroll-to-bottom` is rendered only while `isAtBottom` is false, so its
# presence IS the flag — read in the same evaluate as the geometry so the two
# can never disagree about which frame they describe.
# The app's OWN bottom, not the DOM edge. `scrollToBottom` deliberately parks the
# reader at the real content bottom, and the sizer may reserve up to `maxTailGap`
# (100px) of blank below it — so `scrollHeight - clientHeight` is a position the
# app never occupies, by an amount that depends on how far the height model has
# converged. Asserting it is how this helper used to fail on a slow runner
# (measured on CI: scrollTop 23267 vs dom edge 23315) and pass on a fast one.
# `bottomScrollTop` is the same number the stick targets and `isAtBottom` reads;
# re-deriving it here would re-implement the predicate under test.
_APP_BOTTOM_JS = (
    "(() => {"
    "  const el = " + _CHAT_SCROLLER + ";"
    "  if (!el) return { bottom: null, source: 'no-element' };"
    "  const domEdge = el.scrollHeight - el.clientHeight;"
    "  try {"
    "    const inst = el.__vueParentComponent;"
    "    const exposed = inst && inst.exposed;"
    "    if (exposed && typeof exposed.bottomScrollTop === 'function') {"
    "      const v = exposed.bottomScrollTop();"
    "      if (typeof v === 'number' && isFinite(v)) return { bottom: v, source: 'exposed' };"
    "    }"
    "  } catch (e) {"
    "    return { bottom: domEdge, source: 'dom-fallback' };"
    "  }"
    "  return { bottom: domEdge, source: 'dom-fallback' };"
    "})()"
)

_GEOM_SCRIPT = (
    "() => {"
    "  const el = " + _CHAT_SCROLLER + ";"
    "  if (!el) return null;"
    "  const ruler = " + _APP_BOTTOM_JS + ";"
    "  const domEdge = el.scrollHeight - el.clientHeight;"
    "  return {"
    "    scrollTop: el.scrollTop,"
    "    scrollHeight: el.scrollHeight,"
    "    clientHeight: el.clientHeight,"
    "    maxScrollTop: domEdge,"
    "    appBottom: ruler.bottom,"
    "    appRulerSource: ruler.source,"
    "    rulerGap: domEdge - ruler.bottom,"
    "    arrow: !!document.querySelector('.chat-scroll-to-bottom'),"
    "  };"
    "}"
)


def _geom(page) -> dict:
    g = page.evaluate(_GEOM_SCRIPT)
    assert g is not None, "chat message scroller not found"
    assert g["appRulerSource"] == "exposed", (
        "could not read VirtualScroller.bottomScrollTop from the mounted instance — the "
        "assertions below would silently fall back to the DOM ruler, which is the pre-fix "
        f"definition of 'at the bottom': {g}"
    )
    return g


def _open_chat(page, h, session_id: str) -> None:
    # Route shape note. `/app?view=chat&session=…` only opens the transcript
    # when the app already has a workspace in context; with none it silently
    # lands on the workspace-selection home screen, and every assertion after
    # this point would be about the wrong scroller. The workspace-path shape
    # carries its own context and is what chatview_tail_gap_probe_test.py uses.
    workspace_id = h.http(
        "POST",
        "/api/workspaces",
        json_body={"name": f"send-scroll-{session_id}"},
        expect=(200, 201),
    ).json()["id"]
    page.goto(
        h.web_url(f"/app/{workspace_id}/chat/{session_id}"),
        wait_until="load",
        timeout=60000,
    )
    page.wait_for_function(
        f"() => !!({_CHAT_SCROLLER}) && "
        f"({_CHAT_SCROLLER}).scrollHeight > ({_CHAT_SCROLLER}).clientHeight",
        timeout=30000,
    )
    # Let the initial-load branch (restore-or-bottom) and the scroller's
    # measurement pass settle before anything is measured.
    page.wait_for_timeout(1200)


def _park_in_history(page) -> dict:
    """Scroll the reader up into history and prove the stick disengaged."""
    page.evaluate(
        "() => { const el = " + _CHAT_SCROLLER + "; el.scrollTop = el.scrollHeight * "
        + str(HISTORY_FRACTION)
        + "; }"
    )
    # The arrow appearing IS the proof: ChatView renders it only when
    # `isAtBottom` is false, so waiting for it is waiting for the flag to flip
    # rather than for a scroll position to look right.
    page.wait_for_function(
        "() => !!document.querySelector('.chat-scroll-to-bottom')",
        timeout=10000,
    )
    page.wait_for_timeout(400)
    g = _geom(page)
    assert g["arrow"], "precondition failed: the reader is not treated as scrolled up"
    assert g["scrollTop"] < g["appBottom"] - BOTTOM_TOL_PX, (
        f"precondition failed: the reader is already at the bottom: {g}"
    )
    return g


def _send(page, text: str) -> None:
    """Submit through the real composer, exactly as a user would."""
    page.wait_for_selector(".file-input-wrapper textarea", timeout=15000)
    page.fill(".file-input-wrapper textarea", text)
    page.click("[data-testid='send-message-button']")
    # The draft is cleared synchronously by FileInput before the emit, so this
    # is the cheapest proof the submit actually went through.
    page.wait_for_function(
        "() => { const t = document.querySelector('.file-input-wrapper textarea');"
        " return t && t.value.trim() === ''; }",
        timeout=10000,
    )


def _echo_user_turn(h, session_id: str, text: str, *, index: int = ECHO_INDEX) -> None:
    """The row the server sends back over SSE when it accepts the turn.

    There is no optimistic bubble by design (see the 2026-08-23 note in
    `handleFileInputSubmit`), so this frame is the only thing that makes the
    sent turn exist — and it is therefore the thing the follow has to survive
    until. A queued turn is the same story later and slower: the row appears
    when the worker drains the queue, not when the reader asked.
    """
    h.http(
        "POST",
        "/api/dev/sse/emit_llm",
        json_body={
            "type": "full",
            "session_id": session_id,
            "role": "user",
            "content": text,
            "finish_reason": "stop",
            "index": index,
        },
        expect=200,
    )


def _wait_parked_at_bottom(page, *, what: str) -> dict:
    """Wait for the stick to be armed AND the viewport to be at the bottom.

    The two conditions are asserted together on purpose. `scrollTop` at the
    bottom can be true of a scroller that has not yet been told it is at the
    bottom — that is the state every follow gate reads, and the state the
    pre-fix code leaves behind.

    Both the wait and the assertion use the APP's ruler (`bottomScrollTop`), not
    `scrollHeight - clientHeight`. The scroller parks the reader at the REAL
    content bottom and may reserve up to `maxTailGap` (100px) of blank below it,
    so the DOM edge is a position the app never occupies and the disagreement
    grows as the height model converges — i.e. it is timing-shaped. That is what
    made this test flaky: under 6x CPU throttling the reader sits 56px above the
    DOM edge (scrollTop 23001, domEdge 23057) with `bottomScrollTop()` == 23001
    and the arrow gone, while the same build on a fast runner sits 0-3px away.
    CI caught the same thing at 48px (scrollTop 23267 vs 23315, tolerance 24).

    30s, not 15s: this wait straddles an SSE echo plus a remeasure, and the
    15s bound was the tightest `wait_for_function` in the suite (30000 is
    what the other 40 use). It held everywhere except the slower macOS
    runners, where it expired mid-settle — a bound problem, not a behaviour
    difference, since the same test passes consistently on Linux. The
    assertions below are unchanged: if the stick never arms, this still fails.

    What keeps the lenient ruler honest: the arrow must be gone (`isAtBottom`
    armed), the ruler disagreement must stay within `maxTailGap` (so a sizer that
    reserves a screen of blank still fails), and `_geom` refuses to run on the
    DOM fallback.
    """
    page.wait_for_function(
        "() => {"
        "  const el = " + _CHAT_SCROLLER + ";"
        "  if (!el) return false;"
        "  if (document.querySelector('.chat-scroll-to-bottom')) return false;"
        "  const ruler = " + _APP_BOTTOM_JS + ";"
        "  if (ruler.bottom === null) return false;"
        "  return el.scrollTop >= ruler.bottom - " + str(APP_BOTTOM_TOL_PX) + ";"
        "}",
        timeout=30000,
    )
    page.wait_for_timeout(400)
    g = _geom(page)
    assert not g["arrow"], f"{what}: the jump-to-bottom arrow is showing, so isAtBottom is false: {g}"
    assert g["rulerGap"] <= MAX_TAIL_GAP_PX + TAIL_GAP_SLACK_PX, (
        f"{what}: the sizer reserves {g['rulerGap']}px of blank below the real content, past the "
        f"{MAX_TAIL_GAP_PX}px the tail cap allows — 'the bottom' is unreachable by design: {g}"
    )
    assert g["scrollTop"] >= g["appBottom"] - APP_BOTTOM_TOL_PX, (
        f"{what}: not parked at the transcript's bottom: {g}"
    )
    return g


def _seed_session(h, session_id: str, count: int = TURN_COUNT) -> None:
    seed = DbSeed(h.temp_dir / ".config" / "pabrik" / "agent.db")
    with seed.connect() as conn:
        seed.seed_session(conn, session_id, f"Send-scroll {count}")
        stamps = DbSeed.baseline_timestamps(count=count, interval_seconds=30)
        for i in range(count):
            body = (
                f"Turn {i}. A paragraph long enough that the bubble has real "
                "height in the virtual scroller, so the transcript is far "
                "taller than the viewport and scrolling up is a real place to "
                "be rather than a rounding error."
            )
            if i % 2 == 0:
                seed.seed_user_message(conn, session_id, body, created_at=stamps[i])
            else:
                seed.seed_assistant_message(conn, session_id, body, created_at=stamps[i])


# ─── The tests ───────────────────────────────────────────────────────────────


def test_sending_from_history_lands_on_the_newest_turn(ui_harness, page) -> None:
    """The report: send a message from up in the history, end up at the bottom.

    The bottom this asserts against is the one that exists AFTER the sent turn
    has been echoed back. A pin aimed at the pre-send bottom moves the scroller
    and still leaves the turn the reader just asked for below the fold.
    """
    h = ui_harness
    session_id = "chat-send-scroll-send"
    _seed_session(h, session_id)
    _open_chat(page, h, session_id)

    before = _geom(page)
    assert before["maxScrollTop"] > 2000, f"transcript is not scrollable: {before}"
    assert not before["arrow"], f"a chat should open on its newest turn: {before}"

    history = _park_in_history(page)
    assert history["scrollTop"] < history["maxScrollTop"] - BOTTOM_TOL_PX

    text = "and then open a PR for the scroll fix"
    _send(page, text)
    _echo_user_turn(h, session_id, text)

    after = _wait_parked_at_bottom(page, what="after sending from history")

    # The turn is not merely accounted for in the scroll range — it is on
    # screen. This is the user's actual complaint: the message they just sent
    # was somewhere they could not see it.
    assert after["maxScrollTop"] > history["maxScrollTop"], (
        "the sent turn did not grow the transcript at all, so this test proved "
        f"nothing: {history} -> {after}"
    )
    on_screen = page.evaluate(
        "() => {"
        "  const el = " + _CHAT_SCROLLER + ";"
        "  const rows = [...document.querySelectorAll('[data-group-key]')];"
        "  if (!rows.length) return {found: false};"
        "  const elBox = el.getBoundingClientRect();"
        "  const box = rows[rows.length - 1].getBoundingClientRect();"
        "  return {"
        "    found: true,"
        "    visible: box.bottom > elBox.top && box.top < elBox.bottom,"
        "    text: (rows[rows.length - 1].textContent || '').slice(0, 200),"
        "  };"
        "}"
    )
    assert on_screen.get("found"), "no transcript rows rendered"
    assert on_screen.get("visible"), (
        "the scroller reports the bottom but the newest row is off screen: "
        f"{on_screen}"
    )


def test_sending_twice_in_a_row_keeps_following(ui_harness, page) -> None:
    """The follow survives a second turn, not just the first.

    The pin is a one-shot act. What has to hold is the STATE it leaves behind:
    the next turn has to be followed too, which is only true if the stick was
    armed rather than merely scrolled to once.
    """
    h = ui_harness
    session_id = "chat-send-scroll-twice"
    _seed_session(h, session_id)
    _open_chat(page, h, session_id)

    _park_in_history(page)
    first = "first follow-up"
    _send(page, first)
    _echo_user_turn(h, session_id, first)
    _wait_parked_at_bottom(page, what="after the first turn")

    # Read history again — this time while the transcript is already following.
    page.evaluate(
        "() => { const el = " + _CHAT_SCROLLER + "; el.scrollTop = el.scrollHeight * 0.4; }"
    )
    page.wait_for_function(
        "() => !!document.querySelector('.chat-scroll-to-bottom')", timeout=10000
    )

    second = "second follow-up"
    _send(page, second)
    _echo_user_turn(h, session_id, second)

    _wait_parked_at_bottom(page, what="after the second turn")
