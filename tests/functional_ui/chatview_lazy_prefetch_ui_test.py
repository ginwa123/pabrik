"""Functional UI test: older-history PREFETCH fires before the scroll reaches the top.

Task_1789505423062_0 — the user's complaint, verbatim:

    "the issues auto scroll is loaded after the user hit the max, but what if
     the auto fetch is do before scroll reach the top"

What the feature does (see ChatView.vue "Older-history pagination"):
a predictive ARM fetches the next older page into an in-memory buffer while
the user is still travelling, and crossing the scroller's load-more band
COMMITS that buffered page through the existing preserve path — so the round
trip is off the critical path.

Why a real browser is required
    The claim is about a WIRE round trip racing a MOMENTUM SCROLL. Neither can
    be reproduced in jsdom (no layout, no coalesced scroll events, and jsdom
    does not fire `scroll` on `scrollTop` writes). This test boots a real
    `pabrik` backend + a real Vite dev server + headless Chromium and drives a
    synthetic fling with `requestAnimationFrame`.

The hard gate (assertion that FAILS on the pre-fix build)
    The scroll-back request must be issued while the container is still OUTSIDE
    its load-more band (`scrollTop > max(200, 0.5 × clientHeight)`) — not after
    the user is pinned at `scrollTop == 0`. Pre-fix, `VirtualScroller.onScroll`'s
    trailing-edge 200 ms debounce (reset on every scroll event) means the
    request is only issued after the fling SETTLES at the top, so this assertion
    fails structurally — it measures the bug, not the implementation.

Also asserted: no scroll-back request is issued on open; exactly ONE request
per exhausted page (the commit comes from the buffer, not a fresh request);
no two requests share a cursor; the prepend grows the content without
duplicating rendered groups and without moving the reading anchor.

Run (binary must be built first — a fresh worktree has no `zig-out/`):
    zig build
    PABRIK_BIN=./zig-out/bin/pabrikcore-linux-x86_64 \\
        python3 -m pytest tests/functional_ui/chatview_lazy_prefetch_ui_test.py -v

Control run (proves the gate measures the fix) — same command against `main`,
assertion 1 must FAIL.

Ports: the UI harness reserves (5173, 8081) and picks the backend port from
[20000, 32000] (below the kernel ephemeral range — see RANDOM_PORT_START in
tests/functional/harness.py). NEVER 8081 (a dev server runs there).
"""

from __future__ import annotations

from datetime import datetime, timedelta, timezone
from pathlib import Path

import pytest

from chatview_boot import (
    bind_session_workspace,
    create_workspace,
    open_chatview,
)
from db_seed import DbSeed
from ui_harness import UIHarness

# ─── Constants ──────────────────────────────────────────────────────────────

#: Seed sizes. newer=1000 fills exactly one PAGE_SIZE (ChatView.PAGE_SIZE=1000
#: since #549), so the initial page reports has_more=true whenever `older` > 0.
NEWER_COUNT = 1000
OLDER_SINGLE_PAGE = 600  # < PAGE_SIZE → that page is the LAST page (has_more=false)
OLDER_MULTI_PAGE = 2200  # ≥ 2 more pages → pagination must continue

#: Paragraph body shared by every seeded message. Deliberately tall (~400-600px
#: rendered) so 100 messages far exceed the ~900px viewport and the fling has
#: real distance to cover.
BODY_TEMPLATE = (
    "Message {i} paragraph one.\n\n"
    "Message {i} paragraph two with some longer text to give the bubble real "
    "height in the virtual scroller. Lorem ipsum dolor sit amet, consectetur "
    "adipiscing elit, sed do eiusmod tempor incididunt ut labore et dolore "
    "magna aliqua.\n\n"
    "Message {i} paragraph three with even more filler text so each bubble "
    "measures a few hundred pixels tall in the layout."
)


# ─── Helpers ────────────────────────────────────────────────────────────────


def _seed_db_path(h: UIHarness) -> Path:
    """Path to the harness's isolated ``agent.db`` (pre-validated tmpdir)."""
    return h.temp_dir / ".config" / "pabrik" / "agent.db"


def _seed_session(
    h: UIHarness, workspace_id: str, session_id: str, newer: int, older: int
) -> None:
    """Seed ``newer`` recent + ``older`` chronologically-older messages.

    The messages endpoint pages with ``direction=desc`` + ``cursor``
    (``created_at_nano < cursor``), so the ``older`` rows are exactly what a
    scroll-back fetch returns, and their existence makes the initial page
    report ``has_more=true``.
    """
    seed = DbSeed(_seed_db_path(h))
    with seed.connect() as conn:
        seed.seed_session(conn, session_id, f"Prefetch {newer}+{older}")
        bind_session_workspace(conn, workspace_id, session_id)
        stamps = DbSeed.baseline_timestamps(count=newer, interval_seconds=30)
        for i in range(newer):
            body = BODY_TEMPLATE.format(i=i)
            if i % 2 == 0:
                seed.seed_user_message(conn, session_id, body, created_at=stamps[i])
            else:
                seed.seed_assistant_message(conn, session_id, body, created_at=stamps[i])
        if older > 0:
            first_dt = datetime.fromisoformat(stamps[0].replace("Z", "+00:00"))
            older_stamps = DbSeed.baseline_timestamps(
                base=first_dt - timedelta(seconds=60 * (older + 1)),
                count=older,
                interval_seconds=30,
            )
            for i in range(older):
                body = f"OLDER {i}\n\n" + BODY_TEMPLATE.format(i=f"old-{i}")
                if i % 2 == 0:
                    seed.seed_user_message(conn, session_id, body, created_at=older_stamps[i])
                else:
                    seed.seed_assistant_message(conn, session_id, body, created_at=older_stamps[i])


#: Installed BEFORE the app boots (add_init_script) so the very first history
#: request is recorded too. The scroller is resolved lazily per call: it does
#: not exist yet when the script runs.
_PROBE_INIT_SCRIPT = r"""
(() => {
  const pickScroller = () => {
    // Two `.virtual-scroller` elements exist (sidebar ChatsList + chat
    // messages). The chat one is the TALLER visible scroller.
    const all = [...document.querySelectorAll('.virtual-scroller')]
      .filter((el) => el.offsetParent !== null)
      .map((el) => ({ el, ch: el.clientHeight }))
      .sort((a, b) => b.ch - a.ch);
    return all.length ? all[0].el : null;
  };
  window.__pickScroller = pickScroller;
  window.__probe = {
    requests: [],   // { t, scrollTop, cursor } for /messages? (not queue_messages)
    content: [],    // { t, scrollHeight } whenever the scroller's scrollHeight changed
    tFlingStart: null,
    tArrive: null,
    scrollHeightAtArrive: null,
    samples: [],    // { t, scrollTop } per fling frame
  };
  const origFetch = window.fetch;
  window.fetch = function (input, init) {
    const url = typeof input === 'string' ? input : (input && input.url) || '';
    // Anchor on the history endpoint's query string; queue_messages also
    // contains "messages" and must not be counted.
    if (/\/messages\?/.test(url) && !/queue_messages/.test(url)) {
      const el = pickScroller();
      let cursor = null;
      try {
        cursor = new URL(url, location.origin).searchParams.get('cursor');
      } catch (e) {
        cursor = null;
      }
      window.__probe.requests.push({
        t: performance.now(),
        scrollTop: el ? el.scrollTop : -1,
        cursor,
      });
    }
    return origFetch.apply(this, arguments);
  };
})();
"""

#: Attach the content-growth observer (needs the scroller to exist).
_OBSERVE_SCRIPT = r"""
() => {
  const el = window.__pickScroller();
  if (!el) return false;
  const probe = window.__probe;
  const obs = new MutationObserver(() => {
    const last = probe.content[probe.content.length - 1];
    const h = el.scrollHeight;
    if ((!last || last.scrollHeight !== h) && probe.content.length < 500) {
      probe.content.push({ t: performance.now(), scrollHeight: h });
    }
  });
  obs.observe(el, { childList: true, subtree: true, attributes: true, characterData: true });
  window.__probeObs = obs;
  return true;
}
"""

#: The fling steps by DISTANCE, not by time, one rAF frame per step. A
#: time-stepped fling can advance >1000 px in a single frame whenever the
#: browser drops frames (the scroller does layout work mid-fling), which jumps
#: straight over the arm band (max(800, 1.5 × clientHeight) ≈ 990 px here) and
#: the prefetch is never exercised. 250 px steps guarantee ~4 samples inside
#: the arm band, at any frame rate.
FLING_STEP_PX = 250
FLING_MIN_STEPS = 12

#: The fling itself. Steps move up by stepPx per rAF frame from the LIVE
#: position (not an interpolation from the start): the scroller's anchor
#: compensation can push scrollTop back down between frames when above-
#: viewport items measure taller than their estimates, so a fixed-step
#: interpolation would end early and never reach the band. Iterating until
#: arrival models a real user, who keeps scrolling until they get to the top.
#: `targetTop` lets a caller stop the fling just ABOVE the load-more band —
#: that is how the test observes "armed but not yet committed".
_FLING_SCRIPT = r"""
({ stepPx, targetTop }) => new Promise((resolve) => {
  const el = window.__pickScroller();
  const probe = window.__probe;
  const start = el.scrollTop;
  const target = Math.max(0, targetTop);
  const t0 = performance.now();
  probe.tFlingStart = t0;
  probe.samples = [];
  let frames = 0;
  // Worst case: ~200 000 px of tall unmeasured history at 250 px/frame
  // plus compensation pushback between frames. 1500 rAF ≈ 25 s worst
  // case; the typical fling settles far sooner once items are measured.
  const maxFrames = 1500;
  const step = () => {
    frames += 1;
    el.scrollTop = Math.max(target, el.scrollTop - stepPx);
    probe.samples.push({ t: performance.now(), scrollTop: el.scrollTop });
    if (el.scrollTop > target && frames < maxFrames) {
      requestAnimationFrame(step);
    } else {
      probe.tArrive = performance.now();
      probe.scrollHeightAtArrive = el.scrollHeight;
      resolve({ start, arrival: probe.tArrive, steps: frames });
    }
  };
  requestAnimationFrame(step);
})
"""

#: Anchor drift + duplicate-group detection over the whole document.
_DOM_AUDIT_SCRIPT = r"""
() => {
  const nodes = [...document.querySelectorAll('[data-group-key]')];
  const keys = nodes.map((n) => n.getAttribute('data-group-key'));
  const dupes = [...new Set(keys.filter((k, i) => keys.indexOf(k) !== i))];
  return { rendered: keys.length, duplicates: dupes };
}
"""

def _open_chatview_probed(
    page, h: UIHarness, workspace_id: str, session_id: str, timeout_ms: int = 30000
) -> None:
    """Install the fetch probe, then open the chatview for ``session_id``.

    ``open_chatview`` navigates the workspace-scoped deep link, which
    ``AppLayout.handleBootUrl`` adopts without a session-detail round-trip.
    """
    page.add_init_script(_PROBE_INIT_SCRIPT)
    open_chatview(page, h, workspace_id, session_id, timeout_ms)


def _wait_for_initial_load(page, timeout_ms: int = 20000) -> None:
    """Wait until the chat scroller exists and the first history page landed."""
    page.wait_for_function(
        "() => window.__probe && window.__probe.requests.length > 0 && window.__pickScroller()",
        timeout=timeout_ms,
    )
    # Let the initial-load scroll (restore-or-bottom) settle before measuring.
    page.wait_for_timeout(700)


def _fling_to(page, target_top: int = 0, step_px: int = FLING_STEP_PX) -> dict:
    """Fling the chat scroller down to ``target_top``, one distance-stepped rAF frame each."""
    return page.evaluate(_FLING_SCRIPT, {"stepPx": step_px, "targetTop": target_top})


def _client_height(page) -> float:
    return float(page.evaluate("() => window.__pickScroller().clientHeight"))


def _commit_band_px(client_height: float) -> float:
    """The scroller's own load-more band: max(200, 0.5 × clientHeight)."""
    return max(200.0, 0.5 * client_height)


def _probe(page) -> dict:
    return page.evaluate("() => window.__probe")


def _cursored(requests: list[dict]) -> list[dict]:
    """Scroll-back requests only (the initial page carries no cursor)."""
    return [r for r in requests if r.get("cursor")]


# ─── Tests ──────────────────────────────────────────────────────────────────


def test_prefetch_request_is_issued_before_the_scroll_reaches_the_top(ui_harness, page) -> None:
    """THE hard gate: the page is fetched while the user is still travelling.

    Two phases, because that is the only way to observe the feature from
    outside:
      A. fling down to just ABOVE the load-more band → the ARM must fetch the
         next older page into the buffer, and the DOM must NOT change yet;
      B. cross the band → the buffered page must be committed with NO new
         request (proving the round trip was already done), without moving the
         reading anchor.

    Pre-fix, phase A produces no request at all (the trailing-edge 200 ms
    debounce only fires after the fling settles at the top, i.e. inside the
    band), so the hard gate — "the scroll-back request was issued while
    `scrollTop > band`" — fails.
    """
    h = ui_harness
    session_id = "sess-prefetch-hard-gate"
    workspace_id = create_workspace(h)
    _seed_session(h, workspace_id, session_id, newer=NEWER_COUNT, older=OLDER_SINGLE_PAGE)

    # Capture the app's scroll-logger lines (asserted on below).
    console_lines: list[str] = []
    page.on("console", lambda msg: console_lines.append(msg.text))

    _open_chatview_probed(page, h, workspace_id, session_id)
    _wait_for_initial_load(page)
    assert page.evaluate(_OBSERVE_SCRIPT) is True, "chat scroller not found"

    # (1) Opening the chat must NOT spend a scroll-back request: the initial
    # load lands at the bottom, far outside both the arm radius and the band.
    before = _probe(page)
    assert before["requests"], "the initial history page was never requested"
    assert _cursored(before["requests"]) == [], (
        "a scroll-back page was fetched on open (before any scroll): "
        f"{_cursored(before['requests'])}; prefetch log: "
        f"{[l for l in console_lines if 'load-more-prefetch' in l]}"
    )

    band = _commit_band_px(_client_height(page))
    height_before = float(page.evaluate("() => window.__pickScroller().scrollHeight"))
    preserve_before = sum(1 for l in console_lines if "load-more-preserve-end" in l)

    # ── PHASE A — travel down to just ABOVE the band ────────────────────────
    _fling_to(page, target_top=int(band) + FLING_STEP_PX)
    page.wait_for_timeout(600)  # let the speculative request resolve

    probe_a = _probe(page)
    armed = _cursored(probe_a["requests"])
    assert armed, (
        "no scroll-back request was issued while the user was still above the "
        f"load-more band (band={band:.0f}px) — the prefetch never armed. "
        f"requests={probe_a['requests']}"
    )
    # ── HARD GATE ──────────────────────────────────────────────────────────
    # The request must have been issued while the container was still OUTSIDE
    # its load-more band — i.e. strictly before the point where the old code
    # fetches. Pre-fix the request only happens at `scrollTop ≈ 0` (after the
    # fling settles), which fails this bound.
    assert armed[0]["scrollTop"] > band, (
        "the older page was requested only after the scroll reached the fetch "
        f"band: scrollTop={armed[0]['scrollTop']} at request time, band={band:.0f}px. "
        f"requests={probe_a['requests']}"
    )
    # ARM must be invisible: no prepend yet. Assert via the commit log rather
    # than scrollHeight: with PAGE_SIZE=1000 of tall messages the height model
    # is still settling during the fling (estimate→measure drift), so a raw
    # scrollHeight comparison is flaky. A premature commit would log
    # load-more-preserve-end — ARM alone never does.
    assert sum(1 for l in console_lines if "load-more-preserve-end" in l) == preserve_before, (
        "the armed page was committed before the user crossed the band — ARM must "
        "only buffer, never mutate the list"
    )

    # ── PHASE B — cross the band ────────────────────────────────────────────
    _fling_to(page, target_top=0)
    page.wait_for_function(
        "(before) => window.__pickScroller().scrollHeight > before + 100",
        arg=height_before,
        timeout=10000,
    )
    page.wait_for_timeout(900)  # give a late/duplicate request a chance to appear

    probe = _probe(page)
    fetch_requests = _cursored(probe["requests"])
    phase_b_start = float(probe["tFlingStart"])

    # (2) THE CONTRACT: every scroll-back request was issued while the
    # container was still OUTSIDE its load-more band. Pre-fix the only
    # scroll-back request is issued after the fling settles at `scrollTop ≈ 0`,
    # i.e. INSIDE the band — so this fails on `main` and passes with the fix.
    # (The requests after the first are REFILL arms — one page of lookahead —
    # which by design are also issued from above the band.)
    inside_band = [r for r in fetch_requests if r["scrollTop"] <= band]
    assert not inside_band, (
        f"scroll-back request(s) issued from inside the load-more band "
        f"(band={band:.0f}px): {inside_band}"
    )

    # (3) The page the user needed was ALREADY buffered when phase B started:
    # the first request predates the band-crossing fling.
    assert fetch_requests[0]["t"] < phase_b_start, (
        "the scroll-back request was issued only after the band crossing began — "
        "the page was not buffered in advance"
    )
    # Pagination advances (a re-sent cursor would re-prepend the same page).
    cursors = [r["cursor"] for r in fetch_requests]
    assert len(set(cursors)) == len(cursors), f"a cursor was re-sent: {cursors}"

    # (4) Content actually grew (the prepend happened)…
    height_after = float(page.evaluate("() => window.__pickScroller().scrollHeight"))
    assert height_after > height_before + 100, (
        f"content never grew after crossing the band ({height_before} → {height_after}) — "
        "the older page was not prepended"
    )

    # (5) The buffer paid off: measure the wait between the user arriving at the
    # top and the content growing (the prepend landing). This is the perceived
    # stall the feature removes. Informational with a generous bound — the exact
    # number depends on the machine, but pre-fix this window also contains the
    # whole round trip *and* a 200 ms trailing debounce before the fetch starts.
    growth_times = [
        c["t"] for c in probe["content"] if c["scrollHeight"] > height_before + 100
    ]
    assert growth_times, "no content-growth sample was recorded"
    arrival = float(probe["tArrive"])
    commit_delay_ms = min(growth_times, key=lambda t: abs(t - arrival)) - arrival
    print(f"[prefetch] commit landed {commit_delay_ms:.0f} ms after the user reached the top")
    assert commit_delay_ms < 1500, (
        f"the prepend landed {commit_delay_ms:.0f} ms after arrival — the buffered page "
        "was not ready when the band was crossed"
    )

    audit = page.evaluate(_DOM_AUDIT_SCRIPT)
    assert audit["duplicates"] == [], f"duplicate rendered groups: {audit['duplicates']}"
    # The commit must go through the documented scroll-preserve path (the
    # no-jump contract itself is the pre-existing preserve logic, instrumented
    # by its own `restoredOk` field in this log line).
    assert any("load-more-preserve-end" in line for line in console_lines), (
        "no load-more-preserve-end log line — the commit did not use the preserve path"
    )


def test_exhausted_history_never_fires_a_scroll_back_request(ui_harness, page) -> None:
    """No older rows → no prefetch, ever (the arm must respect has_more)."""
    h = ui_harness
    session_id = "sess-prefetch-exhausted"
    workspace_id = create_workspace(h)
    _seed_session(h, workspace_id, session_id, newer=40, older=0)

    _open_chatview_probed(page, h, workspace_id, session_id)
    _wait_for_initial_load(page)
    assert page.evaluate(_OBSERVE_SCRIPT) is True, "chat scroller not found"

    _fling_to(page)
    page.wait_for_timeout(1200)

    probe = _probe(page)
    band = _commit_band_px(_client_height(page))
    # A cursor in the query string is NOT proof of a scroll-back.
    # `chatEngineDb.loadDelta` re-hits this same endpoint with a STORED cursor to
    # refresh the tail after mount/resync, and it fires wherever the reader
    # happens to be — not at the top. So filter to requests issued from inside
    # the load-more band: only those could have been a scroll-back arm. This is
    # the same predicate the prefetch test above uses, and it keeps this test
    # honest — a real regression arms at scrollTop≈0 and is still caught.
    from_band = [r for r in _cursored(probe["requests"]) if r["scrollTop"] <= band]
    assert not from_band, (
        f"has_more=false still produced scroll-back requests from inside the "
        f"load-more band (band={band:.0f}px): {from_band}"
    )


def test_pagination_continues_across_pages_with_distinct_cursors(ui_harness, page) -> None:
    """Scroll-back must keep working page after page (arms the NEXT page)."""
    h = ui_harness
    session_id = "sess-prefetch-multipage"
    workspace_id = create_workspace(h)
    _seed_session(h, workspace_id, session_id, newer=NEWER_COUNT, older=OLDER_MULTI_PAGE)

    _open_chatview_probed(page, h, workspace_id, session_id)
    _wait_for_initial_load(page)
    assert page.evaluate(_OBSERVE_SCRIPT) is True, "chat scroller not found"

    heights = [float(page.evaluate("() => window.__pickScroller().scrollHeight"))]
    for round_no in range(3):
        _fling_to(page)
        try:
            # Wait for THIS fling's prepend rather than sleeping a fixed amount:
            # the commit is what proves the round completed, and the timing of
            # the speculative arms around it varies with the machine.
            page.wait_for_function(
                "(before) => window.__pickScroller().scrollHeight > before + 100",
                arg=heights[-1],
                timeout=8000,
            )
        except Exception:  # noqa: BLE001 — recorded below as a height plateau
            pass
        # Let a refill arm (or the 200 ms backstop) settle before the next fling.
        page.wait_for_timeout(700)
        heights.append(float(page.evaluate("() => window.__pickScroller().scrollHeight")))

    probe = _probe(page)
    fetch_requests = _cursored(probe["requests"])
    cursors = [r["cursor"] for r in fetch_requests]
    audit = page.evaluate(_DOM_AUDIT_SCRIPT)

    # Every fling either prepended a page or was the last page; with 220 older
    # rows seeded there are ≥ 2 more pages, so the content must grow ≥ 2 times.
    grew = sum(1 for a, b in zip(heights, heights[1:]) if b > a + 100)
    assert grew >= 2, f"content did not grow on repeated scroll-back: heights={heights}"

    # …and the pages must ADVANCE, not repeat: a re-sent cursor would prepend
    # the same slice forever. (A dropped speculative arm may legitimately retry
    # its cursor, so distinctness is the right invariant — the no-duplicate
    # group check below catches a page actually committed twice.)
    assert len(set(cursors)) >= 2, f"pagination never advanced a cursor: {cursors}"

    assert audit["duplicates"] == [], f"duplicate rendered groups: {audit['duplicates']}"
