/**
 * The reported shape, at the layer that can express it:
 *
 *   "Chatview has issue if sse send a llm chunk and llm full data finish
 *    reason stop, its like automatically go to bottom scrollbar chatview"
 *   + "if the messages many and the content response is long, it is not auto
 *      scroll bottom"
 *
 * THE SCENARIO
 *   A long chat (1000 messages) whose bubbles are not uniform: many are a
 *   normal paragraph, some are taller than the whole viewport, and some carry
 *   a collapsed "thought"/reasoning section that is a small pill until it is
 *   expanded. One long streamed response then arrives.
 *
 * WHY IT BREAKS
 *   Two things must be true at once, which is why a 20-message test never sees
 *   it:
 *
 *   1. The sizer is very tall (1000 messages), so a correction to the model
 *      above the viewport is measured in THOUSANDS of pixels, not tens.
 *   2. The virtual window keeps EXPANDING while the reader follows the stream,
 *      because the tall bubbles render far taller than the estimator guessed.
 *      Every newly rendered row above the anchor is measured for the first
 *      time, and its real height replaces the guess.
 *
 *   The anchor pass then compensates: `scrollTop += (prefix after − prefix
 *   before)`. That is correct for a reader in the history and wrong for a
 *   reader at the bottom, who has no view to preserve — the content they are
 *   reading is exactly what just got resized. The write strands them thousands
 *   of pixels above the bottom, and ChatView reads that as "the user left the
 *   bottom", disarming every follow gate for the rest of the mount. The rest
 *   of the long response then streams off-screen and the reader watches a gap
 *   grow. (`tests/functional_ui/chatview_at_bottom_stick_ui_test.py` recorded
 *   it as a −15,900px correction with `scrollHeight` essentially unchanged.)
 *
 * THE INVARIANT UNDER TEST
 *   Scoped to the scroller's own responsibility, one pass at a time: **if a
 *   measure pass finds the reader at the bottom, that pass leaves them at the
 *   bottom** — whatever it just did to the model. The correction is still
 *   APPLIED (the sizer converges); it is just aimed at the bottom instead of
 *   at the anchor.
 *
 *   Re-sticking across the passes BETWEEN remeasures is ChatView's job
 *   (`scrollToBottom` after `remeasure`, and `onContentShift` on growth), so
 *   asserting that here would be asserting the wrong layer. The companion
 *   `ChatView.tallBubbleAutoStick.spec.ts` asserts the app's own `isAtBottom`
 *   flag end-to-end over the same shape.
 *
 * Note on the reasoning section: jsdom cannot lay it out, so "tall because an
 * expanded thought block" is modelled here as height — which is what the
 * scroller actually consumes.
 */
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest'
import { mount } from '@vue/test-utils'
import { nextTick } from 'vue'

import VirtualScroller from '../VirtualScroller.vue'

/** The ChatView-like viewport the other specs in this suite use. */
const VIEWPORT = 800

/** "1000 messages" — long enough that the sizer is hundreds of screens tall. */
const ITEM_COUNT = 1000

/** `AT_BOTTOM_SLACK_PX` in VirtualScroller; mirrored so the test pins the contract. */
const SLACK_PX = 10

/**
 * A realistic bubble-height profile for a 1000-message chat, in px.
 *
 * Deliberately heterogeneous, because uniformity is what hides this class of
 * bug: with every row the same height the prefix correction cancels out and
 * nothing moves.
 *
 *   - 60% a normal paragraph bubble (~180px)
 *   - 25% a tall paste / diff / long tool output (~520px)
 *   - 12% TALLER THAN THE WHOLE VIEWPORT (900-1400px) — a full-screen message
 *   - 3%  a one-liner reply (~70px)
 *
 * Deterministic (index-derived, never random) so a failure reproduces exactly
 * and the test cannot flake on an unlucky draw.
 */
function bubbleHeight(index: number): number {
  const bucket = index % 100
  if (bucket < 60) return 180
  if (bucket < 85) return 520
  if (bucket < 97) return 900 + ((index * 37) % 500) // 900..1399, always > viewport
  return 70
}

/** Mount a scroller over 1000 items with a live (sizer-backed) scrollHeight. */
function mountLongChat(n: number = ITEM_COUNT) {
  const items = Array.from({ length: n }, (_, i) => ({ id: i }))
  const wrapper = mount(VirtualScroller, {
    props: {
      items,
      buffer: 30,
      defaultItemHeight: 64,
      totalCount: n,
      loadMoreAtTop: true,
    },
  })
  const el = wrapper.element as HTMLElement
  Object.defineProperty(el, 'clientHeight', { value: VIEWPORT, configurable: true })
  // In a real browser `scrollHeight` IS the sizer's height. A static stub does
  // not move as rows are measured, which would make `bottomScrollTop()` report
  // a stale edge and the at-bottom test below meaningless.
  const sizer = el.querySelector('.virtual-scroller-sizer') as HTMLElement | null
  Object.defineProperty(el, 'scrollHeight', {
    configurable: true,
    get(): number {
      const modelled = sizer ? Number.parseFloat(sizer.style.height) : 0
      return modelled > 0 ? modelled : n * 64
    },
  })
  const vm = wrapper.vm as unknown as {
    bottomScrollTop: () => number
    remeasure: () => void
  }
  return { wrapper, el, vm }
}

/** Give every rendered row its profile height, so a measure pass sees reality. */
function paintProfileHeights(el: HTMLElement, scale = 1) {
  const content = el.querySelector('.virtual-scroller-content')
  if (!content) throw new Error('.virtual-scroller-content not found')
  for (const child of Array.from(content.children)) {
    const idx = Number((child as HTMLElement).getAttribute('data-vs-index'))
    Object.defineProperty(child, 'offsetHeight', {
      value: Math.round(bubbleHeight(idx) * scale),
      configurable: true,
    })
  }
}

function scrollTo(el: HTMLElement, top: number) {
  el.scrollTop = top
  el.dispatchEvent(new Event('scroll'))
}

/**  * Teach the height model the profile, so corrections are measured against a realistic scale instead
 * of the 64px seed. Several passes, because the rendered window only covers part of a 1000-item
 * list and each pass measures the rows that are on screen. */
async function learnProfile(el: HTMLElement, scale = 1) {
  for (let pass = 0; pass < 4; pass++) {
    scrollTo(el, 0)
    await nextTick()
    vi.advanceTimersByTime(60)
    paintProfileHeights(el, scale)
    scrollTo(el, el.scrollTop)
    vi.advanceTimersByTime(60)
    await nextTick()
  }
}

/** Park on the app's own bottom — the number `scrollToBottom` writes. */
async function parkAtBottom(
  el: HTMLElement,
  vm: { bottomScrollTop: () => number },
): Promise<number> {
  const bottom = vm.bottomScrollTop()
  scrollTo(el, bottom)
  await nextTick()
  vi.advanceTimersByTime(60)
  await nextTick()
  return bottom
}

describe('VirtualScroller — a 1000-message chat with full-screen-tall bubbles', () => {
  beforeEach(() => {
    vi.useFakeTimers()
  })
  afterEach(() => {
    vi.useRealTimers()
  })

  it('keeps a bottom reader on the bottom when a pass inflates the model above the anchor', async () => {
    const { wrapper, el, vm } = mountLongChat()
    await learnProfile(el)

    let bottom = await parkAtBottom(el, vm)
    // Precondition: this is the "many messages" half of the report — the
    // corrections under test are thousands of pixels, not tens.
    expect(bottom / VIEWPORT).toBeGreaterThan(50)
    expect(el.scrollTop).toBe(bottom)

    // A long response lands: the rows already on screen turn out to be much
    // taller than the model reserved (markdown settles, a collapsed thought
    // block expands, a code block renders). One measure pass, then assert.
    paintProfileHeights(el, 1.8)
    vm.remeasure()

    const after = el.scrollTop
    bottom = vm.bottomScrollTop()
    const gap = bottom - after
    console.log(`[tall-bubbles] inflate: bottom=${bottom} scrollTop=${after} gap=${gap}`)
    expect(gap).toBeLessThanOrEqual(SLACK_PX)
    wrapper.unmount()
  })

  it('keeps a bottom reader on the bottom when a pass deflates the model above the anchor', async () => {
    // The opposite swing, and the one in the recorded browser capture: rows
    // above the anchor settle far SHORTER than the model reserved. The prefix
    // delta is large and NEGATIVE, so the anchor rule would subtract it from
    // scrollTop and park the reader in the history — which is what disarms the
    // auto-stick and leaves the rest of the response off-screen.
    const { wrapper, el, vm } = mountLongChat()
    // Learn the profile INFLATED, then let it settle to the real heights.
    await learnProfile(el, 1.8)

    const parked = await parkAtBottom(el, vm)
    expect(el.scrollTop).toBe(parked)

    paintProfileHeights(el, 0.25)
    vm.remeasure()

    const after = el.scrollTop
    const bottom = vm.bottomScrollTop()
    const gap = bottom - after
    console.log(`[tall-bubbles] deflate: bottom=${bottom} scrollTop=${after} gap=${gap}`)
    expect(gap).toBeLessThanOrEqual(SLACK_PX)
    wrapper.unmount()
  })

  it('holds the invariant across a long response, pass after pass', async () => {
    // One pass proving the rule is not one pass proving it survives a whole
    // turn. The reported symptom only shows up once the stick has already
    // died, so the LATER passes are the ones that matter.
    //
    // Each cycle is deliberately SYNCHRONOUS — park, paint, pass, assert. No
    // timer advancement between them, so no debounced pass runs behind the
    // assertions and the state stays attributable. Letting the timers run
    // here compounds a dozen implicit passes and the numbers stop meaning
    // anything (this harness reported a reader BELOW the bottom edge, which a
    // real browser clamps away and jsdom does not).
    const { wrapper, el, vm } = mountLongChat()
    await learnProfile(el)

    const bottom0 = await parkAtBottom(el, vm)
    expect(bottom0 / VIEWPORT).toBeGreaterThan(50)

    // A turn that grows in steps, as a streamed response does. Scales swing
    // both ways so the correction under test is sometimes positive and
    // sometimes negative and large.
    const gaps: number[] = []
    const bottoms: number[] = []
    for (const scale of [1.15, 1.35, 1.6, 1.9, 0.9, 1.25]) {
      scrollTo(el, vm.bottomScrollTop())
      // Vue's render is ASYNC: without this the window is still the one from
      // the previous position when `remeasure()` runs, so the pass measures
      // rows that are not the ones the reader is looking at and the model
      // never moves — the loop would then assert a static bottom and prove
      // nothing. `nextTick` alone is enough: it does not advance timers, so no
      // debounced pass runs between the paint and the assertion.
      await nextTick()
      paintProfileHeights(el, scale)
      vm.remeasure()
      gaps.push(vm.bottomScrollTop() - el.scrollTop)
      bottoms.push(vm.bottomScrollTop())
    }
    console.log(
      `[tall-bubbles] long turn gaps: ${JSON.stringify(gaps)} bottoms: ${JSON.stringify(bottoms)}`,
    )
    for (const [i, gap] of gaps.entries()) {
      if (Math.abs(gap) > SLACK_PX) {
        console.log(
          `[tall-bubbles] FAILED at pass ${i + 1} of ${gaps.length}: ` +
            `reader is ${gap}px off the bottom`,
        )
      }
      expect(Math.abs(gap)).toBeLessThanOrEqual(SLACK_PX)
    }
    // The model really was being corrected during the turn, so the gaps above
    // are measured against a moving bottom and not a static one. Asserted as
    // "the bottom moved at some point" rather than "it ended higher":
    // `measureItems` keeps a `HYSTERESIS_PX` (50px) dead-band for rows above
    // the anchor, so a small final step is legitimately absorbed and the total
    // can settle back where it started.
    expect(Math.max(...bottoms)).toBeGreaterThan(bottom0)
    wrapper.unmount()
  })

  it('leaves a reader in the history alone (the anchor still owns them)', async () => {
    // The guard against over-correcting into "the scroller always jumps to the
    // bottom". In a 1000-message chat the history reader is a long way from the
    // bottom, and the anchor rule must keep holding THEIR view still.
    const { wrapper, el, vm } = mountLongChat()
    await learnProfile(el)

    // Request a position deep in the history, then let the settle passes run.
    // The reader is NOT expected to still be at exactly the requested pixel —
    // measuring the rows that scroll in legitimately corrects the model above
    // them, and the anchor carries them along. So the baseline is the settled
    // position, not the request.
    const inHistory = Math.round(vm.bottomScrollTop() * 0.4)
    scrollTo(el, inHistory)
    await nextTick()
    vi.advanceTimersByTime(60)
    paintProfileHeights(el, 1)
    scrollTo(el, el.scrollTop)
    vi.advanceTimersByTime(60)
    await nextTick()
    // Precondition: they really are in the history, not at the tail.
    expect(vm.bottomScrollTop() - el.scrollTop).toBeGreaterThan(VIEWPORT * 5)

    // Same hostile correction, opposite position.
    paintProfileHeights(el, 1.8)
    vm.remeasure()

    const after = el.scrollTop
    const bottom = vm.bottomScrollTop()
    const distance = bottom - after
    console.log(
      `[tall-bubbles] history reader: scrollTop=${after} bottom=${bottom} distance=${distance}`,
    )
    // They moved — that is the anchor doing its job, riding a model that grew
    // above them — but they are still deep in the history, NOT at the tail.
    expect(distance).toBeGreaterThan(VIEWPORT * 5)
    wrapper.unmount()
  })
})
