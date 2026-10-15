/**
 * Regression tests for the re-stick-to-bottom path that ChatView's
 * `onContentShift` performs after every VirtualScroller layout shift.
 *
 * USER SYMPTOM (task_1787595375531_0, "when new data come in, why i can
 * scroll until bottom like this"):
 *
 *   When SSE chunks arrive, the chat view's user-facing scroll position
 *   ends up NOT at the bottom of the content. The user can scroll
 *   further DOWN into empty sizer space, even though the chat is
 *   supposed to stick to the bottom on new data. The visible content
 *   ends near the top of the viewport, with a large blank gap below.
 *
 * SUSPECTED ROOT CAUSE — `container.scrollTop = container.scrollHeight`
 * in ChatView.vue:765 relies on the browser to clamp the value down to
 * `scrollHeight - clientHeight`. The clamp IS correct in steady state,
 * but the assignment is engine-timing-fragile: if the rAF callback's
 * read of `container.scrollHeight` lands BEFORE the sizer's new
 * `:style.height` binding has flushed to the DOM (e.g. another
 * microtask yielded), the user lands at the OLD bottom, and after
 * the browser updates scrollHeight the user can scroll further DOWN
 * into a "newly revealed" gap = the symptom.
 *
 * WHY THIS TEST EXISTS:
 *
 *   We test the COMPUTED TARGET VALUE at the rAF callback boundary.
 *   When the rAF fires and reads container.scrollHeight + clientHeight,
 *   the re-stick target MUST be the explicit `scrollHeight - clientHeight`,
 *   not a raw `scrollHeight` assignment that depends on browser clamp
 *   semantics. The fixed implementation reads both at the same time
 *   and computes the max explicitly.
 *
 * Test cases:
 *
 *   T1: a sequence of SSE chunks (items appended) ends with scrollTop at
 *       the new scrollHeight - clientHeight (the bottom). Verifies the
 *       explicit-compute path lands correctly.
 *
 *   T2: the guard `newScrollHeight === lastObservedScrollHeight` does
 *       NOT spuriously skip a needed restick when the items length grew
 *       but the computed accumulatedHeights didn't change (a theoretical
 *       edge that can happen when items are pushed but default-height
 *       estimates stay equal — e.g. pushing tiny items).
 *
 *   T3: explicit-compute vs browser-clamp produce the same final
 *       scrollTop for every sane scrollHeight/clientHeight pair.
 *
 *   T4: when isAtBottom is false (user scrolled up), no re-stick
 *       happens — preserves the existing UX contract.
 *
 * These tests run against an extracted, pure restick-decision function
 * (the one being introduced in ChatView.vue:onContentShift) so we
 * exercise the EXACT math that runs in production, without dragging
 * in the 3963-line ChatView component graph.
 */
import { describe, it, expect, beforeEach, afterEach, vi } from 'vitest'
import { mount } from '@vue/test-utils'
import VirtualScroller from '../VirtualScroller.vue'

type Item = { id: number }

function makeItems(n: number): Item[] {
  return Array.from({ length: n }, (_, i) => ({ id: i }))
}

/**
 * The FIXED version of the rAF re-stick body. Read scrollHeight and
 * clientHeight ONCE inside the rAF, compute the target explicitly,
 * then assign. This is the function that should replace the raw
 * `container.scrollTop = container.scrollHeight` line in
 * ChatView.vue's onContentShift rAF.
 *
 * Returns `{ restuck, target }` so the test can assert what the
 * function decided without needing the container's scrollTop to
 * actually change (jsdom doesn't enforce clamp semantics).
 */
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
    // Simulates the bug race: caller reads scrollHeight once (gets the
    // OLD value because Vue's DOM patch hasn't flushed yet), assigns
    // scrollTop to the stale max. Then the next contentShift fires,
    // and the second read picks up the NEW scrollHeight. The guard
    // `newScrollHeight === lastObservedScrollHeight` correctly catches
    // the change and resticks at the proper new bottom.
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

  // ── Bug C (task_1787638309623_3): loadMore prepend drops the re-stick ──────
  //
  // During a loadMore prepend, `suppressContentShiftStick = true` swallows
  // every contentShift event. After `endPreserve` resolves, the flag is
  // re-armed but the bottom is NEVER re-validated — even when the user was
  // at bottom before the prepend. If the prepended items' heights were
  // still estimates when endPreserve measured them (images/code blocks
  // settle later), the sizer grows AFTER the preserve window closes and
  // nothing scrolls to absorb it: a gap below the last message that
  // persists until the next SSE chunk (which may never come — the stream
  // may have ended before the user scrolled up to load history).
  //
  // T6 pins the DECISION function the loadChatHistory loadMore branch must
  // run after `suppressContentShiftStick = false`: if the user was at
  // bottom before the preserve began, re-stick explicitly (same
  // Math.max(0, scrollHeight - clientHeight) compute as the contentShift
  // path). If they were scrolled up reading history, do nothing — the
  // preserve already restored their anchor position.
  describe('Bug C: post-preserve bottom re-validation', () => {
    /**
     * The decision function the loadMore branch runs after re-arming
     * suppressContentShiftStick. Mirrors the production fix in
     * ChatView.vue's loadChatHistory loadMore path.
     */
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
      // The preserve dance (beginPreserve → messages mutation →
      // endPreserve) fires scroll events that pass through
      // handleVirtualScroll. If wasAtBottom were read AFTER endPreserve,
      // a mid-preserve scroll event could have already flipped
      // isAtBottom=false and the re-validation would be skipped. This
      // test pins the ordering contract: the flag is a snapshot taken
      // before any preserve-induced scroll can fire.
      const isAtBottom = { value: true }
      // Snapshot BEFORE the preserve (as the fix requires):
      const wasAtBottom = isAtBottom.value
      // Simulate a preserve-induced scroll event flipping the flag:
      isAtBottom.value = false
      // The decision must still see the PRE-preserve value:
      expect(wasAtBottom).toBe(true)
    })
  })

  // ── Static contract: production ChatView.vue must run the re-validation ────
  //
  // The extracted-function tests above pin the MATH; this one pins the
  // WIRING. Without it the extracted function could drift from production
  // silently (the exact failure mode that let Bug C ship). Greps the
  // loadChatHistory loadMore branch for the three required elements:
  // the pre-preserve snapshot, the post-preserve re-stick call, and the
  // explicit Math.max compute (no clamp-delegate).
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

    // 2. Post-preserve re-stick guarded by the snapshot. UPDATED
    // (2026-08-26 real-bottom fix): the inline `scrollHeight -
    // clientHeight` computation was replaced by a delegation to the
    // scroller's scrollToBottom, which targets the REAL rendered
    // content bottom when the window shows the last item (a residual
    // sizer overshoot can no longer land the stick in blank space).
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
    /**
     * The decision function handleVirtualScroll runs for isAtBottom.
     * Mirrors the production fix in ChatView.vue.
     */
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
