"""Functional UI test: scrolling up while SSE streams must not move the reader.

The report (task_1791776348154_5): *"sse is running but user want to read the
llm code to the top, so he scroll, but the issues is, its kind of jumping up and
bottom"*. Streaming is active, the reader scrolls up to read the response from
its first line, and the viewport oscillates.

## What was actually wrong (measured, not inferred)

The scroller's height model is mostly a GUESS: `VirtualScroller.estimateHeight`
returns the adaptive estimator's running median for every item that has never
been rendered, and in a 600-message chat that is ~560 of 600 items. So the
median is not a small local detail — it is multiplied by the number of
never-rendered rows.

The estimator is fed by whichever rows are on screen, so **scrolling moved it**.
Moving it rescaled every prefix sum by `unmeasuredCount x delta`, and
`measureItems`' anchor compensation turned that rescale into a `scrollTop` write
of the same size. Instrumented pass record from the reproduction (600-message
chat, 100px upward steps, one chunk per step):

    pass #18: oldAnchorTop 116536 -> newAnchorTop 138771      (shift +22,235)
              -> wrote scrollTop 138880
              -> the browser CLAMPED it to 120074 (the sizer had not
                 re-rendered for the new model yet) -> teleport up ~18.8k
    pass #19: shift -38,808 -> wrote 81266                    (teleport back)

No content was measured above the anchor in either pass. The visible result is
the flip-flop this file exists to catch: `applied` steps of -35,479 / +16,853 /
-17,812 px against a 100px request, `topSpacer` and the sizer swinging tens of
thousands of px per step.

The fix is in `AdaptiveItemHeightEstimator.freeze()` + the `measureItems` call
site: once the estimator's rolling window is full, the placeholder stops moving,
so a prefix sum above the viewport can only change when a row is really measured.
`estimateHeight` no longer depends on `scrollTop` at all.

## The assertions (all observable from the browser, no test-only hooks)

* per step, the reader ends up where they asked to be, give or take a bounded
  measurement correction;
* per step, the model must not rescale (a scrollHeight step of thousands of px
  is a guess moving, not content arriving);
* a reader parked mid-response must not be moved AT ALL by the stream, sampled
  frame by frame.

Run:
    PABRIK_BIN=./zig-out/bin/pabrikcore-linux-x86_64 \
        /tmp/pabrik-ui-venv/bin/python -m pytest \
        tests/functional_ui/chatview_stream_scroll_stability_ui_test.py -v
"""

from __future__ import annotations

import pytest

from chatview_boot import bind_session_workspace, create_workspace, open_chatview
from db_seed import DbSeed
from ui_harness import UIHarness

#: Long enough that the transcript is many viewports tall and the model is
#: dominated by never-rendered rows — that ratio is what turns an estimator move
#: into a multi-thousand-px scroll write.
TURN_COUNT = 600

TALL_BODY = (
    "Turn {i} — paragraph one.\n\n"
    "Turn {i} — paragraph two with enough text to give the bubble real height in "
    "the virtual scroller. Lorem ipsum dolor sit amet, consectetur adipiscing "
    "elit, sed do eiusmod tempor incididunt ut labore et dolore magna aliqua.\n\n"
    "Turn {i} — paragraph three with even more filler so each bubble measures a "
    "few hundred pixels tall in real layout."
)
#: The reader's step. One mouse wheel notch is ~100px, and it is small enough
#: that a compensation write of tens of thousands of px cannot hide inside it.
STEP_PX = 100
STEPS = 24

#: How far the settled position may differ from the requested step.
#:
#: The compensation legitimately writes on top of the gesture: a whole rendered
#: row entering/leaving the window moves the spacer by that row's height, and
#: `HYSTERESIS_PX` (50) plus the sizer's own dead-band release in steps of up to
#: that size. Observed on a clean run: 41px, in both directions. The bug this
#: guards produced 178-35479px, so the bound only has to separate "absorbed a
#: row" from "the model flogged the reader down the list".
STEP_TOLERANCE_PX = 200

#: How much the model may grow/shrink in one settled step. A streamed chunk adds
#: tens of px of real content; a moving guess rescaled the list by 18,573px.
#: (`VirtualScroller`'s `HYSTERESIS_PX` is 50, so the sizer can legitimately
#: step by a little more than the chunk.)
HEIGHT_STEP_TOLERANCE_PX = 1000

#: A reader parked mid-response: total motion allowed across a whole stream.
#: The parked case has no compensation premise at all — nothing above or at the
#: viewport is being measured for the first time — so the honest bound is "the
#: scroll position does not move", with a couple of px for rounding.
PARKED_DRIFT_TOLERANCE_PX = 4


@pytest.fixture(autouse=True)
def _arm_sse_emit_gate(monkeypatch: pytest.MonkeyPatch) -> None:
    """Arm the test-only SSE emit gate BEFORE the harness boots."""
    monkeypatch.setenv("PABRIK_TEST_SSE_EMIT", "1")


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

# NOTE: multi-line, and every `//` comment sits on its own line — Playwright
# evaluates an injected script as ONE line, so a trailing `//` would swallow the
# closing brace ("Unexpected end of input").
_GEOM_SCRIPT = (
    r"""
() => {
  const el = """
    + _CHAT_SCROLLER
    + r""";
  if (!el) return null;
  const content = el.querySelector('.virtual-scroller-content');
  if (!content) return null;
  const sizer = el.querySelector('.virtual-scroller-sizer');
  const m = /translate3d\(0px,\s*([-\d.]+)px/.exec(content.style.transform || '');
  return {
    scrollTop: el.scrollTop,
    scrollHeight: el.scrollHeight,
    clientHeight: el.clientHeight,
    topSpacer: m ? parseFloat(m[1]) : null,
    sizer: sizer ? parseFloat(sizer.style.height) || 0 : null,
    arrow: !!document.querySelector('.chat-scroll-to-bottom'),
    rendered: content.children.length,
  };
}
"""
)

# Per-frame sampler. Installed INTO the page (rAF), because Python-side polling
# samples the settled state only — which is precisely what hides an oscillation:
# a reader bounced back and forth inside one 200ms wait reads as "did not move".
_RECORDER_SCRIPT = (
    r"""
() => {
  const el = """
    + _CHAT_SCROLLER
    + r""";
  if (!el) return { error: 'no scroller' };
  const probe = { recording: false, tops: [] };
  window.__probe = probe;
  window.__probeTick = () => {
    if (probe.recording) probe.tops.push(el.scrollTop);
    requestAnimationFrame(window.__probeTick);
  };
  requestAnimationFrame(window.__probeTick);
  return { scrollTop: el.scrollTop };
}
"""
)


def _geom(page) -> dict:
    g = page.evaluate(_GEOM_SCRIPT)
    assert g is not None, "chat message scroller not found"
    return g


def _seed(h: UIHarness, workspace_id: str, session_id: str) -> None:
    seed = DbSeed(h.temp_dir / ".config" / "pabrik" / "agent.db")
    with seed.connect() as conn:
        seed.seed_session(conn, session_id, f"Stream scroll stability {TURN_COUNT}")
        bind_session_workspace(conn, workspace_id, session_id)
        stamps = DbSeed.baseline_timestamps(count=TURN_COUNT, interval_seconds=30)
        for i in range(TURN_COUNT):
            body = TALL_BODY.format(i=i)
            if i % 2 == 0:
                seed.seed_user_message(conn, session_id, body, created_at=stamps[i])
            else:
                seed.seed_assistant_message(conn, session_id, body, created_at=stamps[i])


def _open_chat(page, h: UIHarness, session_id: str) -> None:
    workspace_id = create_workspace(h)
    _seed(h, workspace_id, session_id)
    open_chatview(page, h, workspace_id, session_id)
    page.wait_for_function(
        "() => { const w = document.querySelector('.messages-scroll-hide-native');"
        " return !!(w && w.querySelector('.virtual-scroller')); }",
        timeout=30000,
    )
    # Initial render, then the scroller's measurement passes. The overshoot this
    # file depends on only exists AFTER the model has learned a real median.
    page.wait_for_timeout(2500)


def _emit_chunk(h: UIHarness, session_id: str, k: int) -> None:
    # Prose + a fenced code block: the shape of a real agent answer, and what
    # "read the llm code to the top" is about.
    body = (
        f"Sentence {k} of the answer, long enough to wrap onto a second line in "
        "the transcript so the row really grows. "
    ) * 3
    if k % 4 == 0:
        body += f"\n\n```python\ndef handler_{k}(payload):\n    return payload\n```\n\n"
    h.http(
        "POST",
        "/api/dev/sse/emit_llm",
        json_body={"type": "chunk", "content": body, "session_id": session_id},
        expect=200,
    )


def _step_up(page, px: int) -> None:
    page.evaluate(
        f"() => {{ const el = {_CHAT_SCROLLER}; el.scrollTop = el.scrollTop - ({px}); }}"
    )


def _walk_up(page, h: UIHarness, session_id: str, *, with_stream: bool, first_chunk: int) -> list[str]:
    """Walk the transcript upward in `STEP_PX` steps, auditing each one.

    `with_stream` interleaves a chunk before every step, which is the reported
    gesture: the reader scrolls while the answer is still being written.
    """
    violations: list[str] = []
    for i in range(STEPS):
        if with_stream:
            _emit_chunk(h, session_id, first_chunk + i)
            page.wait_for_timeout(60)
        before = _geom(page)
        _step_up(page, STEP_PX)
        # onScroll debounce + measure pass + rAF settle.
        page.wait_for_timeout(220)
        after = _geom(page)

        applied = before["scrollTop"] - after["scrollTop"]
        if abs(applied - STEP_PX) > STEP_TOLERANCE_PX:
            violations.append(
                f"step {i}: the reader asked for {STEP_PX}px and got {applied:.0f}px "
                f"(topSpacer {before['topSpacer']}->{after['topSpacer']}, "
                f"sizer {before['sizer']}->{after['sizer']}, "
                f"scrollHeight {before['scrollHeight']}->{after['scrollHeight']})"
            )
        d_height = after["scrollHeight"] - before["scrollHeight"]
        if abs(d_height) > HEIGHT_STEP_TOLERANCE_PX:
            violations.append(
                f"step {i}: the height model moved {d_height:.0f}px in one step "
                f"sizer {before['sizer']}->{after['sizer']} — a guess moving, not "
                f"content arriving (the stream adds tens of px per chunk)"
            )
        assert after["arrow"], (
            f"step {i}: the stick re-engaged for a reader who is reading history: {after}"
        )
    return violations


def _warm_up_the_response(page, h: UIHarness, session_id: str) -> None:
    """Stream the answer to a few viewports tall, so scrolling up into it is a
    real 'read it from the top' position rather than a one-screen wiggle."""
    for k in range(12):
        _emit_chunk(h, session_id, k)
        page.wait_for_timeout(90)
    page.wait_for_timeout(300)


def test_upward_scrolls_apply_while_the_stream_runs(ui_harness: UIHarness, page) -> None:
    """THE reported gesture: scroll up through a live response, in small steps.

    Fails on the pre-fix scroller with per-step applied deltas of
    -35479 / +16853 / -17812 px, because the model rescaled by tens of thousands
    of px while the reader scrolled and the anchor compensation wrote that
    rescale straight into `scrollTop`.
    """
    h = ui_harness
    session_id = "sess-stream-scroll-up"
    _open_chat(page, h, session_id)
    _warm_up_the_response(page, h, session_id)

    print(f"\n[scroll-stability] at the bottom before the walk: {_geom(page)}")
    violations = _walk_up(page, h, session_id, with_stream=True, first_chunk=12)
    print(f"[scroll-stability] after the walk: {_geom(page)}")
    assert not violations, "scrolling up while streaming moved the reader:\n" + "\n".join(
        violations
    )


def test_the_same_upward_scrolls_without_a_stream_are_no_worse(ui_harness: UIHarness, page) -> None:
    """Control: identical steps with no stream running.

    Without this, a failure above could be blamed on the walk itself (a
    measurement pass that lands badly on any scroll). The idle gesture is
    expected to be clean today and must stay clean.
    """
    h = ui_harness
    session_id = "sess-idle-scroll-up"
    _open_chat(page, h, session_id)
    _warm_up_the_response(page, h, session_id)

    violations = _walk_up(page, h, session_id, with_stream=False, first_chunk=0)
    assert not violations, "scrolling up with no stream moved the reader:\n" + "\n".join(
        violations
    )


def test_a_parked_reader_is_not_moved_by_the_stream(ui_harness: UIHarness, page) -> None:
    """The reader stops scrolling and reads, while the chunks keep coming.

    Sampled per animation frame inside the page: a 200ms Python-side wait
    samples the settled state and would report "did not move" for a view that
    oscillated twice inside the wait.

    Honesty note: this one already passed BEFORE the fix — a reader parked
    mid-response was stable, because the model rescale needs a moving window to
    happen. It is a guard on the invariant, not the witness for the bug; the
    witness is `test_upward_scrolls_apply_while_the_stream_runs`, which fails at
    step 18 on the pre-fix scroller with a 35,569px move against a 100px request.
    """
    h = ui_harness
    session_id = "sess-stream-parked"
    _open_chat(page, h, session_id)
    _warm_up_the_response(page, h, session_id)

    page.evaluate(
        f"() => {{ const el = {_CHAT_SCROLLER};"
        " el.scrollTop = el.scrollHeight - el.clientHeight - el.clientHeight * 1.6; }"
    )
    page.wait_for_timeout(500)
    parked = _geom(page)
    print(f"\n[scroll-stability] parked mid-response: {parked}")
    assert parked["arrow"], "precondition failed: the stick is still armed while parked"

    rec = page.evaluate(_RECORDER_SCRIPT)
    assert "error" not in rec, f"could not install the frame sampler: {rec}"
    page.evaluate("() => { window.__probe.tops = []; window.__probe.recording = true }")

    for k in range(40, 64):
        _emit_chunk(h, session_id, k)
        page.wait_for_timeout(120)

    tops = page.evaluate("() => { window.__probe.recording = false; return window.__probe.tops }")
    after = _geom(page)
    print(f"[scroll-stability] parked after the stream: {after}")
    assert len(tops) > 30, f"the frame sampler barely ran ({len(tops)} frames) — nothing under test"

    # The stream must have actually grown the content, or this proved nothing.
    assert after["scrollHeight"] > parked["scrollHeight"], (
        f"streaming did not grow the transcript: {parked['scrollHeight']} -> "
        f"{after['scrollHeight']}"
    )
    drift = max(tops) - min(tops)
    assert drift <= PARKED_DRIFT_TOLERANCE_PX, (
        f"a parked reader was moved {drift:.0f}px by the stream "
        f"(min {min(tops):.0f}, max {max(tops):.0f}, parked {parked['scrollTop']:.0f}); "
        f"frames={len(tops)}, content grew "
        f"{parked['scrollHeight']} -> {after['scrollHeight']}"
    )
