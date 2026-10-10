/**
 * "Sometimes it does not autoscroll to bottom" — the at-bottom stick disarms itself.
 *
 * ── The defect ──────────────────────────────────────────────────────────────
 * Two components measured "the bottom" with two different rulers, and the
 * disagreement was larger than either one's tolerance:
 *
 *   VirtualScroller.scrollToBottom  (VirtualScroller.vue)
 *     lands the container on the REAL content bottom —
 *     `topSpacer + content.offsetHeight` — whenever the height model overshoots
 *     by more than HYSTERESIS_PX (50). This is the blank-viewport fix: without
 *     it a sizer overshoot parks the reader in a fully-blank region.
 *
 *   ChatView.handleVirtualScroll
 *     decided at-bottom with the DOM's ruler, `scrollHeight - clientHeight`,
 *     against BOTTOM_THRESHOLD (10).
 *
 * With the tail cap latched — `sizerHeight = min(modelTotal, tailContentBottom +
 * maxTailGap)`, and `maxTailGap` DEFAULTS TO 100 — the two rulers disagree by
 * exactly the overshoot. So a *successful* auto-stick produced the scroll event
 * that marked the reader as having LEFT the bottom. Every downstream gate reads
 * that flag — `scrollToBottom(force=false)`, the `onContentShift` re-stick, the
 * SSE-chunk `remeasure` branch, and the messages-length watcher — and all four
 * went quiet for the rest of the mount. The "scroll to bottom" FAB appeared
 * while the reader sat on the last message.
 *
 * ── The fix ─────────────────────────────────────────────────────────────────
 * One ruler: `VirtualScroller.bottomScrollTop()` is now exposed, and everything
 * that asks "is the reader at the bottom?" asks the scroller. The tests below
 * pin BOTH rulers — `decideIsAtBottomDomRuler` is the old behaviour, kept as
 * the executable statement of the bug (delete it and the regression is no
 * longer described anywhere); `decideIsAtBottom` is the shipped one.
 *
 * ── Why the arithmetic lives here rather than in a mount spec ───────────────
 * `handleVirtualScroll` cannot be mounted in isolation: it is an inline handler
 * inside a 6.2k-line SFC whose at-bottom decision is interleaved with prefetch
 * arming, pill selection and six log sites. The repo's established answer to
 * this (chatViewContentShiftRestick.spec.ts) is to pin the math in pure
 * functions and pin the WIRING with source-contract tests at the bottom of this
 * file. Both halves must change together — the comment in that spec calls the
 * drift between them "the exact failure mode that let Bug C ship".
 */

import { mount, type ComponentMountingOptions } from '@vue/test-utils'
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest'
import { nextTick, ref } from 'vue'
import VirtualScroller from '../VirtualScroller.vue'
import {
  AT_BOTTOM_STABLE_TOLERANCE_PX,
  BOTTOM_THRESHOLD,
  buildScrollContext,
} from '../scrollLogger'
import { useChatScrollRestore } from '@/composables/useChatScrollRestore'

/** scrollLogger.ts — the at-bottom tolerance itself. Deliberately tiny. */
const BOTTOM_THRESHOLD_PX = BOTTOM_THRESHOLD
/** VirtualScroller default `maxTailGap`; ChatView never overrides it. */
const MAX_TAIL_GAP = 100
/** VirtualScroller `HYSTERESIS_PX` — the model overshoot that flips the ruler. */
const HYSTERESIS_PX = 50
/** How far the reader may sit below the real bottom before the stick disengages. */
const RETENTION_CAP_PX = 100

/**
 * The state `VirtualScroller.scrollToBottom` computes internally, reduced to
 * the two numbers a caller needs. Mirrors `bottomScrollTop()` in
 * VirtualScroller.vue.
 */
interface BottomPlan {
  /** Where the scroller parks the container. */
  target: number
  /** How far that is from the DOM's own max — the two rulers' disagreement. */
  domGap: number
  /** True when the real-bottom override fired (overshoot > hysteresis). */
  usedRealBottom: boolean
}

/** Mirror of VirtualScroller's `bottomScrollTop()`. */
function planBottom(args: {
  scrollHeight: number
  clientHeight: number
  /** `range.topSpacer + content.offsetHeight` — the real content bottom. */
  realBottom: number
  /** True when the rendered window covers the last item. */
  windowCoversTail: boolean
  /** `content.offsetHeight`; 0 means "unknown", which disables the override. */
  contentHeight: number
}): BottomPlan {
  const { scrollHeight, clientHeight, realBottom, windowCoversTail, contentHeight } = args
  const modelBottom = Math.max(0, scrollHeight - clientHeight)
  let target = modelBottom
  if (windowCoversTail && contentHeight > 0) {
    const real = Math.max(0, realBottom - clientHeight)
    if (modelBottom - real > HYSTERESIS_PX) target = real
  }
  return {
    target,
    domGap: scrollHeight - target - clientHeight,
    usedRealBottom: target !== modelBottom,
  }
}

interface DecisionInput {
  /** Gap measured with the scroller's own ruler (the shipped behaviour). */
  distanceFromBottom: number
  previousIsAtBottom: boolean
  contentGrew: boolean
  userScrolledUp: boolean
}

/**
 * Mirror of the at-bottom decision in ChatView.handleVirtualScroll, as shipped:
 * the gap comes from `bottomScrollTop()`.
 */
function decideIsAtBottom(args: DecisionInput): boolean {
  const newIsAtBottom = args.distanceFromBottom < BOTTOM_THRESHOLD_PX
  const retainedThroughGrowth =
    args.previousIsAtBottom &&
    args.contentGrew &&
    !args.userScrolledUp &&
    args.distanceFromBottom < RETENTION_CAP_PX
  return newIsAtBottom || retainedThroughGrowth
}

/**
 * The SHIPPED decision once the gap is measured against the STABLE anchor
 * (`settledBottom`) rather than a live `bottomScrollTop()`.
 *
 * The tolerance widens to `AT_BOTTOM_STABLE_TOLERANCE_PX` because the anchor is
 * written at the end of a measure pass and the model can still converge by up to
 * the tail gap before the next scroll event is handled. That residual is the
 * model's own movement, not the reader's.
 */
function decideIsAtBottomStableAnchor(args: DecisionInput): boolean {
  const newIsAtBottom = args.distanceFromBottom < AT_BOTTOM_STABLE_TOLERANCE_PX
  const retainedThroughGrowth =
    args.previousIsAtBottom &&
    args.contentGrew &&
    !args.userScrolledUp &&
    args.distanceFromBottom < RETENTION_CAP_PX
  return newIsAtBottom || retainedThroughGrowth
}

/**
 * The PRE-FIX decision: same code, but the gap came from
 * `scrollHeight - scrollTop - clientHeight`. Kept so the regression stays
 * described in executable form — every test below that says "flips false" is
 * really saying "this is what the DOM ruler did".
 */
function decideIsAtBottomDomRuler(args: DecisionInput & { domGap: number }): boolean {
  return decideIsAtBottom({ ...args, distanceFromBottom: args.domGap })
}

const QUIET_FRAME = { previousIsAtBottom: true, contentGrew: false, userScrolledUp: false }

// ── The reported bug, stated as arithmetic ───────────────────────────────────

describe('the two rulers, and the disarm they caused', () => {
  it('with the tail cap latched the rulers disagree by exactly maxTailGap', () => {
    const realBottom = 24000
    const plan = planBottom({
      scrollHeight: realBottom + MAX_TAIL_GAP,
      clientHeight: 800,
      realBottom,
      windowCoversTail: true,
      contentHeight: realBottom,
    })
    expect(plan.usedRealBottom).toBe(true)
    expect(plan.domGap).toBe(MAX_TAIL_GAP)
  })

  it('the DOM ruler called a successful auto-stick "left the bottom"', () => {
    const plan = planBottom({
      scrollHeight: 24000 + MAX_TAIL_GAP,
      clientHeight: 800,
      realBottom: 24000,
      windowCoversTail: true,
      contentHeight: 24000,
    })
    expect(
      decideIsAtBottomDomRuler({ ...QUIET_FRAME, distanceFromBottom: 0, domGap: plan.domGap }),
    ).toBe(false)
  })

  it('retainedThroughGrowth could not rescue it — its cap is a strict < 100', () => {
    // Every other conjunct holds: the reader WAS at the bottom, content grew,
    // and there was no upward gesture. Only `distanceFromBottom < 100` fails,
    // because the cap produces exactly 100.
    const decision = decideIsAtBottom({
      distanceFromBottom: MAX_TAIL_GAP,
      previousIsAtBottom: true,
      contentGrew: true,
      userScrolledUp: false,
    })
    expect(decision).toBe(false)
  })

  it('the shared ruler reads the same position as at the bottom', () => {
    // Same geometry, same landed scrollTop, the ruler the scroller reports.
    const plan = planBottom({
      scrollHeight: 24000 + MAX_TAIL_GAP,
      clientHeight: 800,
      realBottom: 24000,
      windowCoversTail: true,
      contentHeight: 24000,
    })
    // The reader is AT `plan.target`; the shared ruler's gap is 0.
    expect(
      decideIsAtBottom({ ...QUIET_FRAME, distanceFromBottom: plan.target - plan.target }),
    ).toBe(true)
  })
})

// ── The edge matrix: every overshoot, both rulers ────────────────────────────

describe('overshoot matrix — when does the DOM ruler break the stick?', () => {
  const clientHeight = 800
  const realBottom = 24000

  function overshootCase(overshoot: number) {
    const plan = planBottom({
      scrollHeight: realBottom + overshoot,
      clientHeight,
      realBottom,
      windowCoversTail: true,
      contentHeight: realBottom,
    })
    return {
      plan,
      shared: decideIsAtBottom({ ...QUIET_FRAME, distanceFromBottom: 0 }),
      dom: decideIsAtBottomDomRuler({ ...QUIET_FRAME, distanceFromBottom: 0, domGap: plan.domGap }),
    }
  }

  const cases: Array<[label: string, overshoot: number, domSticks: boolean, domGap: number]> = [
    ['model agrees exactly with reality', 0, true, 0],
    ['sub-pixel noise', 5, true, 0],
    ['just inside BOTTOM_THRESHOLD', 9, true, 0],
    ['exactly BOTTOM_THRESHOLD (no gap is ever produced)', 10, true, 0],
    ['still under the real-bottom trigger', 49, true, 0],
    ['exactly HYSTERESIS_PX (override needs >)', 50, true, 0],
    ['first overshoot that flips the ruler', 51, false, 51],
    ['mid-range overshoot', 300, false, 300],
    ['just under the retention cap', 99, false, 99],
    ['exactly the default maxTailGap', 100, false, 100],
    ['far overshoot', 4000, false, 4000],
  ]

  for (const [label, overshoot, domSticks, domGap] of cases) {
    it(`${label} (${overshoot}px): DOM ruler ${domSticks ? 'keeps' : 'drops'} the stick, shared ruler always keeps it`, () => {
      const { plan, shared, dom } = overshootCase(overshoot)
      // The gap the DOM ruler would measure, pinned explicitly: a gap of 0 is
      // the whole point of the sub-hysteresis rows (scrollToBottom falls
      // through to the DOM max, so there is no disagreement to see).
      expect(plan.domGap).toBe(domGap)
      expect(dom).toBe(domSticks)
      // The shared ruler reads the position the reader is actually at, so it
      // never flips — for ANY overshoot.
      expect(shared).toBe(true)
    })
  }

  it('the broken band is every overshoot above the hysteresis, not just the capped 100px', () => {
    // The tail cap is only ONE producer. An uncapped model that overshoots by
    // 51..modelTotal takes the same branch, so the disarm was a BAND.
    const broken = [0, 5, 9, 10, 49, 50, 51, 99, 100, 300, 4000].filter(
      (o) => !overshootCase(o).dom,
    )
    expect(broken).toEqual([51, 99, 100, 300, 4000])
  })
})

// ── The cases the fix must NOT break ────────────────────────────────────────

describe('reading history still disengages the stick', () => {
  it('a genuine upward gesture past the tolerance disengages', () => {
    expect(
      decideIsAtBottom({
        distanceFromBottom: 4000,
        previousIsAtBottom: true,
        contentGrew: true,
        userScrolledUp: true,
      }),
    ).toBe(false)
  })

  it('a reader parked 3000px above the bottom is not at the bottom', () => {
    expect(
      decideIsAtBottom({
        distanceFromBottom: 3000,
        previousIsAtBottom: false,
        contentGrew: true,
        userScrolledUp: false,
      }),
    ).toBe(false)
  })

  it('mid-transcript the scroller reports the DOM max, so the ruler is unchanged there', () => {
    // Window away from the tail: the real-bottom override is skipped, so both
    // rulers are the DOM edge and nothing about reading history changes.
    const plan = planBottom({
      scrollHeight: 29000,
      clientHeight: 800,
      realBottom: 12000,
      windowCoversTail: false,
      contentHeight: 800,
    })
    expect(plan.usedRealBottom).toBe(false)
    expect(plan.domGap).toBe(0)
    expect(decideIsAtBottom({ ...QUIET_FRAME, distanceFromBottom: 4000 })).toBe(false)
  })

  it('an unknown content height falls back to the DOM max (no guessed position)', () => {
    const plan = planBottom({
      scrollHeight: 24500,
      clientHeight: 800,
      realBottom: 20000,
      windowCoversTail: true,
      contentHeight: 0,
    })
    expect(plan.usedRealBottom).toBe(false)
    expect(plan.target).toBe(24500 - 800)
  })
})

// ── The real component ──────────────────────────────────────────────────────
//
// Pure arithmetic cannot prove the component publishes the number the pure
// function assumed. These mount VirtualScroller and read the actual
// `bottomScrollTop()` off the exposed instance.

type Item = { id: string }
const N = 120

function mountScroller(opts?: { maxTailGap?: number; buffer?: number }) {
  const items: Item[] = Array.from({ length: N }, (_, i) => ({ id: `m${i}` }))
  const props: NonNullable<ComponentMountingOptions<typeof VirtualScroller>['props']> = {
    items,
    buffer: opts?.buffer ?? 30,
    defaultItemHeight: 64,
    totalCount: N,
    itemKey: (item: unknown) => (item as Item).id,
  }
  if (opts?.maxTailGap !== undefined) props.maxTailGap = opts.maxTailGap
  const wrapper = mount(VirtualScroller, { props })
  const el = wrapper.element as HTMLElement
  Object.defineProperty(el, 'clientHeight', { value: 800, configurable: true, writable: true })
  return { wrapper, el }
}

function contentEl(el: HTMLElement): HTMLElement {
  const c = el.querySelector('.virtual-scroller-content')
  if (!c) throw new Error('.virtual-scroller-content not found')
  return c as HTMLElement
}

function mockChildren(el: HTMLElement, height: number): void {
  for (const child of Array.from(contentEl(el).children)) {
    Object.defineProperty(child, 'offsetHeight', { value: height, configurable: true })
  }
}

function setScrollHeight(el: HTMLElement, value: number): void {
  Object.defineProperty(el, 'scrollHeight', { value, configurable: true, writable: true })
}

function scrollTo(el: HTMLElement, top: number): void {
  el.scrollTop = top
  el.dispatchEvent(new Event('scroll'))
}

type ScrollerVm = {
  bottomScrollTop: () => number
  scrollToBottom: (b?: ScrollBehavior) => void
  scrollToPosition: (t: number, b?: ScrollBehavior) => void
}

function vm(wrapper: { vm: unknown }): ScrollerVm {
  return wrapper.vm as ScrollerVm
}

describe('VirtualScroller publishes the bottom it actually lands on', () => {
  beforeEach(() => {
    vi.useFakeTimers()
  })
  afterEach(() => {
    vi.useRealTimers()
    vi.restoreAllMocks()
    vi.unstubAllGlobals()
  })

  it('bottomScrollTop() equals the scrollTop scrollToBottom() writes', async () => {
    const { wrapper, el } = mountScroller()
    await nextTick()
    setScrollHeight(el, 24500)

    const anchor = vm(wrapper).bottomScrollTop()
    // Capture what scrollToBottom actually asks the DOM for.
    let requested = -1
    ;(el as unknown as { scrollTo: (o: { top: number }) => void }).scrollTo = (o) => {
      requested = o.top
    }
    vm(wrapper).scrollToBottom('auto')

    expect(anchor).toBe(requested)
    expect(anchor).toBeGreaterThan(0)
  })

  it('the published anchor is always a reachable position, overshoot or not', async () => {
    const { wrapper, el } = mountScroller({ maxTailGap: 0 })
    await nextTick()
    // Rows measure far taller than the 64px estimate → the model overshoots.
    mockChildren(el, 400)
    setScrollHeight(el, 20000)
    await nextTick()
    vi.advanceTimersByTime(150)
    await nextTick()
    scrollTo(el, 1e7)
    await nextTick()
    vi.advanceTimersByTime(150)
    await nextTick()

    const anchor = vm(wrapper).bottomScrollTop()
    const domEdge = el.scrollHeight - el.clientHeight
    // The invariant that must hold in EVERY configuration, asserted
    // unconditionally so the test can never quietly pass by skipping: the
    // published anchor is a position the container can actually be at, and it
    // is never above the DOM max. An anchor past the max is unreachable — the
    // browser clamps there — so every at-bottom comparison against it is
    // permanently false. Which is the bug, wearing a different variable.
    expect(anchor).toBeLessThanOrEqual(domEdge)
    expect(anchor).toBeGreaterThanOrEqual(0)
  })

  it('the anchor is exactly where scrollToBottom puts the reader', async () => {
    // The one property the whole fix rests on: two numbers, one position.
    const { wrapper, el } = mountScroller({ maxTailGap: 0 })
    await nextTick()
    mockChildren(el, 400)
    setScrollHeight(el, 20000)
    await nextTick()
    vi.advanceTimersByTime(150)
    await nextTick()
    scrollTo(el, 1e7)
    await nextTick()
    vi.advanceTimersByTime(150)
    await nextTick()

    let requested = -1
    ;(el as unknown as { scrollTo: (o: { top: number }) => void }).scrollTo = (o) => {
      requested = o.top
    }
    vm(wrapper).scrollToBottom('auto')
    expect(vm(wrapper).bottomScrollTop()).toBe(requested)
  })

  it('the published bottom never exceeds the DOM max, so it is always reachable', async () => {
    const { wrapper, el } = mountScroller()
    await nextTick()
    setScrollHeight(el, 5000)
    expect(vm(wrapper).bottomScrollTop()).toBeLessThanOrEqual(5000 - 800)
  })

  it('reports 0 when there is no container yet (mount race guard)', () => {
    const { wrapper } = mountScroller()
    const scroller = wrapper.vm as unknown as { containerRef: HTMLElement | null }
    scroller.containerRef = null
    expect(vm(wrapper).bottomScrollTop()).toBe(0)
  })
})

// ── The logger cannot contradict the decision ───────────────────────────────

describe('buildScrollContext reports the same gap the decision used', () => {
  const container = document.createElement('div')
  Object.defineProperty(container, 'scrollHeight', { value: 24500, configurable: true })
  Object.defineProperty(container, 'clientHeight', { value: 800, configurable: true })
  Object.defineProperty(container, 'scrollTop', {
    value: 23400,
    configurable: true,
    writable: true,
  })

  it('uses the scroller ruler when the scroller exposes one', () => {
    const ctx = buildScrollContext(container, {
      chatId: 'c',
      messages: 3,
      isAtBottom: true,
      // The scroller parks the reader at the real bottom, 300px above the DOM
      // edge — the reader IS at the bottom, so the log must say so.
      virtualScrollerRef: { value: { bottomScrollTop: () => 23400 } },
    })
    expect(ctx.distanceFromBottom).toBe(0)
  })

  it('falls back to the DOM edge when the scroller cannot be asked', () => {
    for (const ref of [null, { value: null }, { value: {} }, { value: { bottomScrollTop: 1 } }]) {
      const ctx = buildScrollContext(container, {
        chatId: 'c',
        messages: 3,
        isAtBottom: false,
        virtualScrollerRef: ref as { value: unknown } | null,
      })
      expect(ctx.distanceFromBottom).toBe(24500 - 23400 - 800)
    }
  })

  it('falls back when the scroller returns a non-finite number', () => {
    const ctx = buildScrollContext(container, {
      chatId: 'c',
      messages: 3,
      isAtBottom: false,
      virtualScrollerRef: { value: { bottomScrollTop: () => Number.NaN } },
    })
    expect(ctx.distanceFromBottom).toBe(300)
  })
})

// ── The scroll-restore composable ────────────────────────────────────────────

describe('useChatScrollRestore asks the caller where the bottom is', () => {
  function withLocalStorage(): void {
    const store: Record<string, string> = {}
    vi.stubGlobal('localStorage', {
      getItem: (k: string) => (k in store ? store[k] : null),
      setItem: (k: string, v: string) => {
        store[k] = String(v)
      },
      removeItem: (k: string) => {
        delete store[k]
      },
      clear: () => {
        for (const k in store) delete store[k]
      },
      key: () => null,
      length: 0,
    } as unknown as Storage)
  }

  function makeContainer() {
    const el = document.createElement('div')
    Object.defineProperty(el, 'scrollHeight', { value: 24500, configurable: true })
    Object.defineProperty(el, 'clientHeight', { value: 800, configurable: true })
    return el
  }

  it('a save made at the real content bottom is recognised as "still at bottom"', () => {
    // The scroller's edge is 23400; the DOM edge is 23700. A reader who closed
    // the chat at 23400 was ON the last message — restoring them verbatim
    // would be wrong, and so would treating them as "scrolled up".
    withLocalStorage()
    localStorage.setItem('k', '23400')
    const el = makeContainer()
    const { restore } = useChatScrollRestore(ref(el), 'k', () => 23400)
    expect(restore()).toBeNull()
  })

  it('a genuine mid-history save is still restored', () => {
    withLocalStorage()
    localStorage.setItem('k', '9000')
    const el = makeContainer()
    const { restore } = useChatScrollRestore(ref(el), 'k', () => 23400)
    expect(restore()).toBe(9000)
  })

  it('without a resolver it keeps the plain-container behaviour', () => {
    withLocalStorage()
    localStorage.setItem('k', '23700')
    const el = makeContainer()
    const { restore } = useChatScrollRestore(ref(el), 'k')
    expect(restore()).toBeNull()
    vi.unstubAllGlobals()
  })
})

// ── Wiring: the components must still call what the math assumed ────────────

// ── The moving-target ruler (2026-10-10) ────────────────────────────────────
//
// The shared ruler fixed the DISAGREEMENT between two notions of the bottom. It
// did not fix the fact that the shared one is recomputed from live DOM on every
// read, and its two inputs move independently:
//
//     domEdge    = scrollHeight - clientHeight       (the height MODEL)
//     realBottom = topSpacer + content.offsetHeight  (the RENDERED rows)
//
// The real-bottom override engages only while `domEdge - realBottom` exceeds
// HYSTERESIS_PX. So when the model converges — or the rendered window shifts and
// `topSpacer` jumps — the SAME stationary reader is measured against a different
// number. Instrumented trace from a real browser, one SSE chunk apart, the reader
// never having moved:
//
//     frame A: bottomEdge=30114  scrollTop=30071  -> 43px short -> atBottom=false
//     frame B: bottomEdge=30093  scrollTop=30093  ->  0px short -> atBottom=true
//
// The reader did not move 43px; the RULER moved. `isAtBottom` therefore
// oscillates, the jump-to-bottom arrow blinks, and every follow gate disarms on
// the short frames. `retainedThroughGrowth` papers over most of them, but it is
// capped at <100px and does not fire when `contentGrew` is false — so on a slow
// runner the last settle lands on a short frame and the arrow is up when anything
// samples it. That is the macOS flake in
// `chatview_at_bottom_stick_ui_test.py::test_the_stick_survives_a_sizer_that_overshoots_the_content`.
//
// The fix: judge against `settledBottom` — where the bottom sat when the stick
// LAST acted — which only changes when the scroller deliberately repositions.

describe('the live ruler is a moving target, and the stick must not care', () => {
  const clientHeight = 800

  it('a stationary reader reads as at-bottom, then not, as the model converges', () => {
    // The reader is parked at 30071 — exactly where the scroller put them.
    const scrollTop = 30071

    // Frame A: the model still overshoots by 150px, so the real-bottom override
    // fires and the ruler reports the real content bottom. The reader sits 43px
    // short of it.
    const frameA = planBottom({
      scrollHeight: scrollTop + clientHeight + 150,
      clientHeight,
      realBottom: scrollTop + clientHeight + 43,
      windowCoversTail: true,
      contentHeight: scrollTop + clientHeight + 43,
    })
    expect(frameA.usedRealBottom).toBe(true)
    const gapA = frameA.target - scrollTop
    expect(gapA).toBe(43)
    expect(gapA).toBeGreaterThan(BOTTOM_THRESHOLD_PX)

    // Frame B: the model has converged (topSpacer moved, the sizer shrank), so
    // the override no longer fires and the ruler reports the DOM edge instead —
    // which is exactly where the reader is sitting.
    const frameB = planBottom({
      scrollHeight: scrollTop + clientHeight,
      clientHeight,
      realBottom: scrollTop + clientHeight,
      windowCoversTail: true,
      contentHeight: scrollTop + clientHeight,
    })
    expect(frameB.usedRealBottom).toBe(false)
    const gapB = frameB.target - scrollTop
    expect(gapB).toBe(0)

    // Same reader, same gesture (none), two different answers.
    expect(decideIsAtBottom({ ...QUIET_FRAME, distanceFromBottom: gapA })).toBe(false)
    expect(decideIsAtBottom({ ...QUIET_FRAME, distanceFromBottom: gapB })).toBe(true)
  })

  it('the stable anchor holds the answer still across that convergence', () => {
    const scrollTop = 30071
    // `settledBottom` is where the bottom sat when the stick last acted. The
    // reader was parked there, so the gap against it is 0 in BOTH frames — the
    // model converging underneath does not move the anchor.
    const settledBottom = scrollTop

    // The two frames from the test above: the live ruler answers 43px-short in
    // one and 0px-short in the other.
    const liveGaps = [43, 0]
    for (const liveGap of liveGaps) {
      const anchorGap = Math.max(0, settledBottom - scrollTop)
      expect(anchorGap).toBe(0)
      expect(
        decideIsAtBottomStableAnchor({ ...QUIET_FRAME, distanceFromBottom: anchorGap }),
      ).toBe(true)
      // The live read is the one that flip-flops; that is the whole point.
      expect(decideIsAtBottom({ ...QUIET_FRAME, distanceFromBottom: liveGap })).toBe(
        liveGap < BOTTOM_THRESHOLD_PX,
      )
    }
  })

  it('the widened tolerance absorbs the model, not a deliberate scroll-up', () => {
    // The bound is BOTTOM_THRESHOLD + the overshoot hysteresis: the largest step
    // the ruler can take between two frames. NOT maxTailGap — that would swallow
    // a reader 101px up, which retainedThroughGrowth's own cap keeps disengaged.
    expect(AT_BOTTOM_STABLE_TOLERANCE_PX).toBe(BOTTOM_THRESHOLD_PX + HYSTERESIS_PX)
    expect(AT_BOTTOM_STABLE_TOLERANCE_PX).toBeLessThan(RETENTION_CAP_PX)

    // A reader one viewport up is nowhere near it and still reads as scrolled up.
    expect(
      decideIsAtBottomStableAnchor({
        ...QUIET_FRAME,
        distanceFromBottom: clientHeight,
      }),
    ).toBe(false)

    // …and so is a reader a modest way up, well past the retention cap.
    expect(
      decideIsAtBottomStableAnchor({
        ...QUIET_FRAME,
        distanceFromBottom: RETENTION_CAP_PX + 1,
      }),
    ).toBe(false)

    // The residual the widening exists to absorb — the 43px the instrumented
    // trace showed the ruler moving under a stationary reader — is inside it.
    expect(
      decideIsAtBottomStableAnchor({ ...QUIET_FRAME, distanceFromBottom: 43 }),
    ).toBe(true)
  })

  it('a live read keeps the tight threshold, so a real scroll-up is caught at once', () => {
    // The widening applies ONLY to the stable-anchor path. A live read with a
    // 43px gap must still disarm immediately — otherwise the fix would be a fat
    // threshold wearing a different name.
    expect(decideIsAtBottom({ ...QUIET_FRAME, distanceFromBottom: 43 })).toBe(false)
    expect(AT_BOTTOM_STABLE_TOLERANCE_PX).toBeGreaterThan(BOTTOM_THRESHOLD_PX)
  })
})

describe('wiring — both sides really use the shared ruler', () => {
  async function readSource(relPath: string): Promise<string> {
    const { readFileSync } = await import('node:fs')
    const { dirname, resolve } = await import('node:path')
    const { fileURLToPath } = await import('node:url')
    return readFileSync(resolve(dirname(fileURLToPath(import.meta.url)), relPath), 'utf8')
  }

  it('VirtualScroller exposes bottomScrollTop and scrollToBottom delegates to it', async () => {
    const src = await readSource('../VirtualScroller.vue')
    expect(src).toMatch(/const bottomScrollTop = \(\): number =>/)
    expect(src).toMatch(/defineExpose\(\{[\s\S]*?bottomScrollTop,/)
    // If scrollToBottom ever grows its own copy of the math, the two drift —
    // which is the entire class of bug this spec exists for.
    //
    // Asserted on the FUNCTION BODY, not on one exact statement sequence. The
    // body legitimately grew a line: it now records where it left the reader
    // (`settledBottom`) so the next measure pass can tell that a bottom
    // reader has not moved. A regex pinned to the old two-line shape failed on
    // that bookkeeping even though the delegation never changed — a contract
    // test that breaks on a rename of a local is not protecting the contract.
    // What is pinned is the claim itself: the value scrolled to comes from
    // `bottomScrollTop()`, and the arithmetic the shared ruler exists to
    // eliminate is absent from the body.
    const body =
      /const scrollToBottom = \(behavior: ScrollBehavior = 'auto'\) => \{([\s\S]*?)\n\}/.exec(src)
    const fn = body?.[1] ?? ''
    if (fn === '') throw new Error('could not locate the scrollToBottom body to assert on')
    expect(fn).toMatch(/bottomScrollTop\(\)/)
    expect(fn).toMatch(/scrollTo\(\{\s*top:\s*\w+,?\s*behavior\s*\}\)/)
    expect(fn).not.toMatch(/scrollHeight\s*-\s*clientHeight/)
  })

  it('ChatView measures at-bottom with bottomScrollTop, not the raw sizer', async () => {
    const src = await readSource('../../components/views/ChatView.vue')
    // The live read is still there — it is the fallback and the ceiling.
    expect(src).toMatch(
      /const liveEdge = virtualScrollerRef\.value\?\.bottomScrollTop\?\.\(\)\s*\?\?\s*scrollHeight - clientHeight/,
    )
    expect(src).toMatch(/const distanceFromBottom = Math\.max\(0, bottomEdge - actualScrollTop\)/)
    // The pre-fix expression must be GONE from the decision.
    expect(src).not.toMatch(
      /const distanceFromBottom = scrollHeight - actualScrollTop - clientHeight/,
    )
  })

  it('ChatView prefers the stable anchor over the live read', async () => {
    const src = await readSource('../../components/views/ChatView.vue')
    // The moving-target fix: `settledBottom` is read off the scroller and used
    // as the floor for the edge the decision measures against.
    expect(src).toMatch(/const settled = virtualScrollerRef\.value\?\.settledBottom/)
    // The anchor REPLACES the live read; it is not max-ed with it. `settledBottom`
    // comes from `bottomScrollTop()` at the end of a pass, and when the
    // real-bottom override disengages that read returns the DOM edge — up to
    // `maxTailGap` HIGHER than where the reader sits. Max-ing it in inflates the
    // gap and disarms the very stick this protects.
    expect(src).toMatch(
      /typeof settled === 'number' && Number\.isFinite\(settled\)\s*\?\s*settled\s*:\s*liveEdge/,
    )
    expect(src).not.toMatch(/Math\.max\(settled, liveEdge\)/)
    // The widened tolerance applies ONLY on the stable-anchor path. A live read
    // must keep BOTTOM_THRESHOLD, or this is a fat threshold in disguise.
    expect(src).toMatch(/AT_BOTTOM_STABLE_TOLERANCE_PX/)
    // Whitespace-tolerant: prettier wraps the ternary across lines.
    expect(src).toMatch(
      /typeof settled === 'number' && Number\.isFinite\(settled\)\s*\?\s*AT_BOTTOM_STABLE_TOLERANCE_PX\s*:\s*BOTTOM_THRESHOLD/,
    )
  })

  it('VirtualScroller exposes settledBottom as a live getter', async () => {
    const src = await readSource('../VirtualScroller.vue')
    // A getter, not a snapshot: `settledBottom` is a non-reactive `let` written
    // inside measure passes, so a value in defineExpose would freeze at setup.
    expect(src).toMatch(/defineExpose\(\{[\s\S]*?get settledBottom\(\)/)
  })

  it('ChatView hands the same ruler to the scroll-restore composable', async () => {
    const src = await readSource('../../components/views/ChatView.vue')
    expect(src).toMatch(
      /useChatScrollRestore\([\s\S]*?\(el\) =>\s*virtualScrollerRef\.value\?\.bottomScrollTop\?\.\(\)\s*\?\?\s*el\.scrollHeight - el\.clientHeight/,
    )
  })

  it('the at-bottom tolerance stays tight — the fix is a shared ruler, not a fat threshold', async () => {
    // Bumping BOTTOM_THRESHOLD to 100+ would mask the symptom by declaring a
    // 100px-away reader "at the bottom", re-engaging the stick for someone who
    // deliberately scrolled up. Pin the tolerance so that shortcut stays closed.
    const logger = await readSource('../scrollLogger.ts')
    const m = /export const BOTTOM_THRESHOLD = (\d+)/.exec(logger)
    expect(m).not.toBeNull()
    expect(Number(m![1])).toBe(BOTTOM_THRESHOLD_PX)
    expect(BOTTOM_THRESHOLD_PX).toBeLessThan(RETENTION_CAP_PX)
  })
})
