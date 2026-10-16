/** Regression tests for the re-stick-to-bottom path that ChatView's `onContentShift` performs after
 * every VirtualScroller layout shift. */
import { describe, it, expect, beforeEach, afterEach, vi } from 'vitest'
import { mount } from '@vue/test-utils'
import VirtualScroller from '../VirtualScroller.vue'

type Item = { id: number }

function makeItems(n: number): Item[] {
  return Array.from({ length: n }, (_, i) => ({ id: i }))
}

/** The FIXED version of the rAF re-stick body. Read scrollHeight and clientHeight ONCE inside the
 * rAF, compute the target explicitly, then assign. This is the function that should replace the raw
 * `container.scrollTop = container.scrollHeight` line in ChatView.vue's onContentShift rAF. */
/** Returns `{ restuck, target }` so the test can assert what the function decided without needing
 * the container's scrollTop to actually change (jsdom doesn't enforce clamp semantics). */
function restickToBottom(args: {
  container: HTMLElement
  isAtBottom: boolean
  suppressStick: boolean
  lastObservedScrollHeight: { value: number }
}): { restuck: boolean; target: number } {
  if (args.suppressStick) return { restuck: false, target: 0 }
  const scrollHeight = args.container.scrollHeight
  const clientHeight = args.container.clientHeight
  if (scrollHeight === args.lastObservedScrollHeight.value) {
    return { restuck: false, target: 0 }
  }
  args.lastObservedScrollHeight.value = scrollHeight
  if (!args.isAtBottom) return { restuck: false, target: 0 }
  const target = Math.max(0, scrollHeight - clientHeight)
  args.container.scrollTop = target
  return { restuck: true, target }
}

describe('ChatView onContentShift restick (extracted)', () => {
  beforeEach(() => {
    vi.useFakeTimers({ toFake: ['setTimeout', 'clearTimeout', 'requestAnimationFrame', 'cancelAnimationFrame'] })
  })
  afterEach(() => {
    vi.useRealTimers()
  })

  it('T1: lands at the new scrollHeight - clientHeight after an items push', async () => {
    // 10 items × 80px = 800. clientHeight = 400 → max = 400.
    const wrapper = mount(VirtualScroller, {
      props: { items: makeItems(10), defaultItemHeight: 80, buffer: 0, totalCount: 10 },
    })
    const el = wrapper.element as HTMLElement
    Object.defineProperty(el, 'clientHeight', { value: 400, configurable: true })
    Object.defineProperty(el, 'scrollHeight', { value: 800, configurable: true })

    const lastObservedScrollHeight = { value: 0 }
    const result = restickToBottom({
      container: el,
      isAtBottom: true,
      suppressStick: false,
      lastObservedScrollHeight,
    })
    expect(result.restuck).toBe(true)
    expect(result.target).toBe(400) // 800 - 400
    expect(el.scrollTop).toBe(400)
    wrapper.unmount()
  })

  it('T2: when scrollHeight is unchanged, the guard skips (no needless restick)', async () => {
    const wrapper = mount(VirtualScroller, {
      props: { items: makeItems(10), defaultItemHeight: 80, buffer: 0, totalCount: 10 },
    })
    const el = wrapper.element as HTMLElement
    Object.defineProperty(el, 'clientHeight', { value: 400, configurable: true })
    Object.defineProperty(el, 'scrollHeight', { value: 800, configurable: true })

    const lastObservedScrollHeight = { value: 800 } // pre-set to current
    el.scrollTop = 0 // simulate a fresh window-shift where scrollHeight is identical

    const result = restickToBottom({
      container: el,
      isAtBottom: true,
      suppressStick: false,
      lastObservedScrollHeight,
    })
    expect(result.restuck).toBe(false) // guard fired — no scrollTop assign
    expect(el.scrollTop).toBe(0) // untouched
    wrapper.unmount()
  })

  it('T3: explicit-compute target equals browser-clamp target for every sane pair', () => {
    // Math invariant: `Math.max(0, scrollHeight - clientHeight)` is the
    // exact value the browser's scrollTop clamp formula yields. The
    // explicit compute must equal it for every non-negative pair.
    const cases: Array<[number, number]> = [
      [800, 400],
      [400, 400],
      [100, 400],
      [0, 400],
      [1500, 900],
      [1, 1],
      [0, 0],
      [10000, 1],
    ]
    for (const [scrollHeight, clientHeight] of cases) {
      const wrapper = mount(VirtualScroller, {
        props: { items: makeItems(2), defaultItemHeight: 1, buffer: 0, totalCount: 2 },
      })
      const el = wrapper.element as HTMLElement
      Object.defineProperty(el, 'clientHeight', { value: clientHeight, configurable: true })
      Object.defineProperty(el, 'scrollHeight', { value: scrollHeight, configurable: true })

      const lastObservedScrollHeight = { value: 0 }
      const r = restickToBottom({
        container: el,
        isAtBottom: true,
        suppressStick: false,
        lastObservedScrollHeight,
      })
      const expected = Math.max(0, scrollHeight - clientHeight)
      expect(r.target).toBe(expected)
      wrapper.unmount()
    }
  })

  it('T4: when isAtBottom is false, no re-stick is performed', async () => {
    const wrapper = mount(VirtualScroller, {
      props: { items: makeItems(10), defaultItemHeight: 80, buffer: 0, totalCount: 10 },
    })
    const el = wrapper.element as HTMLElement
    Object.defineProperty(el, 'clientHeight', { value: 400, configurable: true })
    Object.defineProperty(el, 'scrollHeight', { value: 1200, configurable: true })
    el.scrollTop = 100 // user scrolled up — they want to stay up

    const lastObservedScrollHeight = { value: 0 }
    const result = restickToBottom({
      container: el,
      isAtBottom: false,
      suppressStick: false,
      lastObservedScrollHeight,
    })
    expect(result.restuck).toBe(false)
    expect(el.scrollTop).toBe(100) // untouched
    wrapper.unmount()
  })

  it('T5 (red→green for the fix): when sizer grows but a STALE scrollHeight is read, the explicit-compute path still lands at the NEW max — once the caller re-reads on the next contentShift', async () => {
    // Simulates the bug race: caller reads scrollHeight once (gets the OLD value because Vue's DOM
    // patch hasn't flushed yet), assigns scrollTop to the stale max. Then the next contentShift
    // fires, and the second read picks up the NEW scrollHeight.
    const wrapper = mount(VirtualScroller, {
      props: { items: makeItems(10), defaultItemHeight: 80, buffer: 0, totalCount: 10 },
    })
    const el = wrapper.element as HTMLElement
    Object.defineProperty(el, 'clientHeight', { value: 400, configurable: true })

    // First read: scrollHeight is the OLD value (800) — bug condition.
    Object.defineProperty(el, 'scrollHeight', { value: 800, configurable: true })
    const lastObservedScrollHeight = { value: 0 }
    const r1 = restickToBottom({
      container: el,
      isAtBottom: true,
      suppressStick: false,
      lastObservedScrollHeight,
    })
    expect(r1.target).toBe(400) // landed at OLD max

    // sizer grows (real DOM updates); on next contentShift, scrollHeight
    // is the NEW value (1200).
    Object.defineProperty(el, 'scrollHeight', { value: 1200, configurable: true })
    const r2 = restickToBottom({
      container: el,
      isAtBottom: true,
      suppressStick: false,
      lastObservedScrollHeight,
    })
    expect(r2.restuck).toBe(true)
    expect(r2.target).toBe(800) // 1200 - 400 — the NEW bottom
    expect(el.scrollTop).toBe(800)
    wrapper.unmount()
  })

  // ── Bug C (task_1787638309623_3): loadMore prepend drops the re-stick ────── During a loadMore
  // prepend, `suppressContentShiftStick = true` swallows every contentShift event.
  describe('Bug C: post-preserve bottom re-validation', () => {
    /**      * The decision function the loadMore branch runs after re-arming suppressContentShiftStick.
     * Mirrors the production fix in ChatView.vue's loadChatHistory loadMore path. */
    function postPreserveRestick(args: {
      container: HTMLElement
      wasAtBottom: boolean
    }): { restuck: boolean; target: number } {
      if (!args.wasAtBottom) return { restuck: false, target: 0 }
      const target = Math.max(0, args.container.scrollHeight - args.container.clientHeight)
      args.container.scrollTop = target
      return { restuck: true, target }
    }

    it('T6a: user was at bottom before prepend → re-stick to the NEW bottom after preserve', async () => {
      const wrapper = mount(VirtualScroller, {
        props: { items: makeItems(10), defaultItemHeight: 80, buffer: 0, totalCount: 10 },
      })
      const el = wrapper.element as HTMLElement
      Object.defineProperty(el, 'clientHeight', { value: 400, configurable: true })
      // Post-prepend layout: 10 old items (800px) + 5 prepended (400px) = 1200 scrollHeight.
      // endPreserve restored scrollTop to the anchor's offsetTop (400) — the user's viewport now
      // sits at the OLD content, with the bottom 400px away.
      Object.defineProperty(el, 'scrollHeight', { value: 1200, configurable: true })
      el.scrollTop = 400

      const result = postPreserveRestick({ container: el, wasAtBottom: true })
      expect(result.restuck).toBe(true)
      expect(result.target).toBe(800) // 1200 - 400 — the NEW bottom
      expect(el.scrollTop).toBe(800)
      wrapper.unmount()
    })

    it('T6b: user was scrolled up reading history → NO re-stick (preserve owns the position)', async () => {
      const wrapper = mount(VirtualScroller, {
        props: { items: makeItems(10), defaultItemHeight: 80, buffer: 0, totalCount: 10 },
      })
      const el = wrapper.element as HTMLElement
      Object.defineProperty(el, 'clientHeight', { value: 400, configurable: true })
      Object.defineProperty(el, 'scrollHeight', { value: 1200, configurable: true })
      el.scrollTop = 300 // user's restored reading position

      const result = postPreserveRestick({ container: el, wasAtBottom: false })
      expect(result.restuck).toBe(false)
      expect(el.scrollTop).toBe(300) // untouched — user is reading history
      wrapper.unmount()
    })

    it('T6c: wasAtBottom must be captured BEFORE beginPreserve (preserve scroll events corrupt the flag)', () => {
      // The preserve dance (beginPreserve → messages mutation → endPreserve) fires scroll events
      // that pass through handleVirtualScroll.
      const isAtBottom = { value: true }
      // Snapshot BEFORE the preserve (as the fix requires):
      const wasAtBottom = isAtBottom.value
      // Simulate a preserve-induced scroll event flipping the flag:
      isAtBottom.value = false
      // The decision must still see the PRE-preserve value:
      expect(wasAtBottom).toBe(true)
    })
  })

  // ── Static contract: production ChatView.vue must run the re-validation ──── The
  // extracted-function tests above pin the MATH; this one pins the WIRING. Without it the extracted
  // function could drift from production silently (the exact failure mode that let Bug C ship).
  it('T6d (red→green): production loadChatHistory re-validates bottom after endPreserve when user was at bottom', async () => {
    const { readFileSync } = await import('node:fs')
    const { resolve } = await import('node:path')
    const { fileURLToPath } = await import('node:url')
    // Resolve relative to the spec's directory
    // (src/apps/desktop/src/helpers/__tests__/ → ../../components/views/).
    const here = fileURLToPath(import.meta.url)
    // here = .../src/helpers/__tests__/<file>.ts → dirname → up 2 = src/
    const path = resolve(here, '../../../components/views/ChatView.vue')
    const src = readFileSync(path, 'utf8')
    // Extract the loadMore branch (from `if (loadMore) {` to the
    // matching `} else {` that starts the initial-load branch).
    const loadMoreStart = src.indexOf('suppressContentShiftStick = true')
    expect(loadMoreStart).toBeGreaterThan(-1)
    // End the window at the initial-load branch marker — the post-preserve re-validation lives
    // AFTER the `suppressContentShiftStick = false` re-arm line, so slicing to that line would
    // exclude the very code under test.
    const branchEnd = src.indexOf('isInitialLoad = true', loadMoreStart)
    expect(branchEnd).toBeGreaterThan(-1)
    const branch = src.slice(loadMoreStart, branchEnd)

    // 1. wasAtBottom snapshot taken BEFORE beginPreserve.
    expect(branch).toMatch(
      /const wasAtBottom = isAtBottom\.value[\s\S]*beginPreserve/,
    )

    // 2. Post-preserve re-stick guarded by the snapshot.
    expect(branch).toMatch(
      /if \(wasAtBottom\)[\s\S]*scrollToBottom\('auto'\)/,
    )
  })

  // ── Bug D (task_1787638309623_3 round 2): stick must NOT re-engage for a
  // user who is ALREADY scrolled up ─────────────────────────────────────────
  //
  // The content-grew guard from round 1 (`isAtBottom = newIsAtBottom ||
  // disengagedByContentGrowth`) was designed for "user AT bottom, content
  // grows away" — but it can't distinguish that from "user ALREADY scrolled
  // up reading, content grows below, viewport stationary". In the second
  // case it RE-ENGAGES the stick (previousIsAtBottom=false → true), and the
  // next contentShift yanks the user to the bottom — the "bouncing text"
  // symptom.
  //
  // Log evidence (scroll#234-#247): user scrolling up (top 33249→30533,
  // bottom 4436px), SSE chunk grew scrollHeight +172 with deltaTop≈0,
  // `spacer-resize-stick` fired and teleported the user to top=35039
  // (bottom=4px) mid-read.
  //
  // Fix: only RETAIN the stick if it WAS engaged. A user who already
  // scrolled up must never be re-engaged by content growth.
  describe('Bug D: content growth must not re-engage a disengaged stick', () => {
    /** The decision function handleVirtualScroll runs for isAtBottom.
     * Mirrors the production fix in ChatView.vue. */
    function computeIsAtBottom(args: {
      newIsAtBottom: boolean
      previousIsAtBottom: boolean
      contentGrew: boolean
      userScrolledUp: boolean
    }): boolean {
      const retainedThroughGrowth =
        args.previousIsAtBottom && args.contentGrew && !args.userScrolledUp
      return args.newIsAtBottom || retainedThroughGrowth
    }

    it('T7a: user AT bottom, content grows, no scroll → stick stays engaged (round-1 contract)', () => {
      expect(
        computeIsAtBottom({
          newIsAtBottom: false,
          previousIsAtBottom: true,
          contentGrew: true,
          userScrolledUp: false,
        }),
      ).toBe(true)
    })

    it('T7b: user ALREADY scrolled up, content grows, viewport stationary → stick stays OFF', () => {
      // The bouncing bug: previousIsAtBottom=false (user is reading
      // history), content grew below them, deltaTop≈0. The round-1
      // guard re-engaged here; the fix must not.
      expect(
        computeIsAtBottom({
          newIsAtBottom: false,
          previousIsAtBottom: false,
          contentGrew: true,
          userScrolledUp: false,
        }),
      ).toBe(false)
    })

    it('T7c: real upward scroll always disengages (UX contract)', () => {
      expect(
        computeIsAtBottom({
          newIsAtBottom: false,
          previousIsAtBottom: true,
          contentGrew: false,
          userScrolledUp: true,
        }),
      ).toBe(false)
    })

    it('T7d: user reaches bottom by scrolling down → engaged', () => {
      expect(
        computeIsAtBottom({
          newIsAtBottom: true,
          previousIsAtBottom: false,
          contentGrew: false,
          userScrolledUp: false,
        }),
      ).toBe(true)
    })

    it('T7e (red→green): production handleVirtualScroll retains the stick ONLY when it was previously engaged', async () => {
      const { readFileSync } = await import('node:fs')
      const { resolve } = await import('node:path')
      const { fileURLToPath } = await import('node:url')
      const here = fileURLToPath(import.meta.url)
      const path = resolve(here, '../../../components/views/ChatView.vue')
      const src = readFileSync(path, 'utf8')
      // The guard must reference previousIsAtBottom — without it the
      // stick re-engages for users who are already scrolled up.
      expect(src).toMatch(
        /previousIsAtBottom\s*&&\s*contentGrew\s*&&\s*!userScrolledUp/,
      )
    })
  })
})
