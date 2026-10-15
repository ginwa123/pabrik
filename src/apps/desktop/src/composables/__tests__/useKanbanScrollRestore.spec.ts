/**
 * Tests for useKanbanScrollRestore — verifies the
 * save-on-scroll + restore-on-mount contract.
 *
 * Why these tests exist:
 *   The kanban columns row inside <KanbanView> needs to preserve
 *   its horizontal scroll position across Vue's standalone ↔
 *   3-column layout transition (the bug fixed by plan
 *   docs/superpowers/plans/2026-07-23-preserve-kanban-horizontal-scroll.md).
 *   Without this composable, the new instance's overflow-x-auto
 *   container starts at scrollLeft = 0 every time the layout flips.
 *   These tests pin the contract so a future refactor can't
 *   regress it.
 *
 * Coverage:
 *   - restores saved scrollLeft on mount (after rAF × 2)
 *   - clamps restored value to scrollWidth - clientWidth
 *   - skips restore when saved value is 0
 *   - persists on `scrollend` immediately (no timer advance)
 *   - persists on `scroll` after the 250 ms debounce
 *   - flushes the pending debounced write on unmount
 *   - swallows localStorage throw (private-mode / quota-exceeded)
 *
 * jsdom setup notes:
 *   - localStorage must be stubbed (jsdom 29 dropped it from
 *     default globals — same trick as useCodeEditor.spec.ts:26-43).
 *   - scrollWidth / clientWidth are not laid out in jsdom; we
 *     override them with `Object.defineProperty` so the clamp
 *     math has real numbers.
 *   - `requestAnimationFrame` is provided by jsdom but synchronous
 *     in tests; awaiting it twice in the composable produces a
 *     microtask + macrotask cycle. We advance with
 *     `await Promise.resolve()` × N + `vi.advanceTimersByTime(0)`
 *     where needed.
 */
import { afterEach, beforeAll, beforeEach, describe, expect, it, vi } from 'vitest'
import { defineComponent, h, nextTick, ref, type Ref } from 'vue'
import { flushPromises, mount } from '@vue/test-utils'

import { useKanbanScrollRestore } from '../useKanbanScrollRestore'

beforeAll(() => {
  // jsdom 29 dropped localStorage from default globals — install a stub.
  Object.defineProperty(globalThis, 'localStorage', {
    value: (() => {
      const store = new Map<string, string>()
      return {
        getItem: (k: string) => store.get(k) ?? null,
        setItem: (k: string, v: string) => store.set(k, v),
        removeItem: (k: string) => store.delete(k),
        clear: () => store.clear(),
        get length() {
          return store.size
        },
        key: (i: number) => Array.from(store.keys())[i] ?? null,
      }
    })(),
    writable: true,
    configurable: true,
  })

  // jsdom does NOT provide requestAnimationFrame — polyfill it using setTimeout(0) so the
  // composable's `await rAF × 2` actually resolves. When vi.useFakeTimers() is active (e.g.
  // debounce tests), rAF resolves when `vi.advanceTimersByTime(0)` runs the setTimeout queue.
  if (typeof globalThis.requestAnimationFrame !== 'function') {
    globalThis.requestAnimationFrame = (cb: (t: number) => void): number => {
      return setTimeout(() => cb(performance.now()), 0) as unknown as number
    }
    globalThis.cancelAnimationFrame = (id: number): void => {
      clearTimeout(id as unknown as ReturnType<typeof setTimeout>)
    }
  }
})

interface TestHarness {
  wrapper: ReturnType<typeof mount>
  container: HTMLDivElement
  inner: HTMLDivElement
  itemIdRef: Ref<string>
}

function mountHarness(initialKey = 'kanban-scroll-item_test'): TestHarness {
  const itemIdRef = ref(initialKey)
  const TestComp = defineComponent({
    setup() {
      const containerRef = ref<HTMLDivElement | null>(null)
      // The composable is called inside setup so onMounted hooks
      // into the parent component's lifecycle.
      useKanbanScrollRestore(containerRef, itemIdRef)
      return { containerRef }
    },
    template: `<div ref="containerRef" class="outer"><div class="inner" style="width: 5000px;"></div></div>`,
  })
  const wrapper = mount(TestComp)
  const container = wrapper.find('.outer').element as HTMLDivElement
  const inner = wrapper.find('.inner').element as HTMLDivElement
  return { wrapper, container, inner, itemIdRef }
}

/**  * Configure jsdom to report a known scrollWidth/clientWidth on the container. Without this,
 * scrollWidth = 0 in jsdom and the composable's "max <= 0" early-exit would skip the restore.
 * Property descriptors must be `configurable: true` so individual tests can override per-case. */
function setScrollGeometry(
  container: HTMLDivElement,
  { scrollWidth, clientWidth }: { scrollWidth: number; clientWidth: number },
): void {
  Object.defineProperty(container, 'scrollWidth', {
    value: scrollWidth,
    writable: true,
    configurable: true,
  })
  Object.defineProperty(container, 'clientWidth', {
    value: clientWidth,
    writable: true,
    configurable: true,
  })
}

/**  * Wait the two `requestAnimationFrame` ticks the composable awaits before applying the restore,
 * plus a microtask flush so Vue's reactive effects settle. jsdom's rAF resolves via the macrotask
 * queue — awaiting `requestAnimationFrame` directly is the canonical way to wait for it. */
async function waitForRestore(): Promise<void> {
  await flushPromises()
  // jsdom provides `requestAnimationFrame` (defined on window).
  // The composable awaits two rAF ticks before applying the
  // restore — mirror those exactly here.
  await new Promise<void>((r) => requestAnimationFrame(() => r()))
  await new Promise<void>((r) => requestAnimationFrame(() => r()))
  await flushPromises()
}

beforeEach(() => {
  // Default: real timers (so jsdom's requestAnimationFrame resolves). Tests that need deterministic
  // debounce timing call `vi.useFakeTimers()` themselves and reset with `vi.useRealTimers()` in
  // their own teardown.
  vi.useRealTimers()
  // Clean any leftover storage between tests.
  localStorage.clear()
})

afterEach(() => {
  vi.useRealTimers()
  localStorage.clear()
})

describe('useKanbanScrollRestore', () => {
  it('restores saved scrollLeft on mount (clamped to current max)', async () => {
    localStorage.setItem('kanban-scroll-item_test', '1234')

    const harness = mountHarness()
    setScrollGeometry(harness.container, {
      scrollWidth: 5000,
      clientWidth: 500,
    }) // max = 4500

    await waitForRestore()

    expect(harness.container.scrollLeft).toBe(1234)
    harness.wrapper.unmount()
  })

  it('clamps the restored value to scrollWidth - clientWidth', async () => {
    // Saved 9999, but the container can only scroll to 4500.
    localStorage.setItem('kanban-scroll-item_test', '9999')

    const harness = mountHarness()
    setScrollGeometry(harness.container, {
      scrollWidth: 5000,
      clientWidth: 500,
    })

    await waitForRestore()

    // max = 5000 - 500 = 4500
    expect(harness.container.scrollLeft).toBe(4500)
    harness.wrapper.unmount()
  })

  it('skips the RESTORE but still attaches listeners when no saved value', async () => {
    // Pre-condition: nothing saved (initial state).
    const harness = mountHarness()
    setScrollGeometry(harness.container, {
      scrollWidth: 5000,
      clientWidth: 500,
    })

    await waitForRestore()

    // Restore is a no-op: scrollLeft stays at 0.
    expect(harness.container.scrollLeft).toBe(0)

    // The composable MUST still attach scroll listeners even when
    // there's no saved value — the user might scroll from scratch,
    // and without a listener the first saved value would never
    // land in localStorage. Verify by scrolling + dispatching
    // scrollend → localStorage should now have a non-null value.
    harness.container.scrollLeft = 200
    harness.container.dispatchEvent(new Event('scrollend'))
    expect(localStorage.getItem('kanban-scroll-item_test')).toBe('200')

    harness.wrapper.unmount()
  })

  it('persists scrollLeft on scrollend immediately (no timer advance)', async () => {
    const harness = mountHarness()
    setScrollGeometry(harness.container, {
      scrollWidth: 5000,
      clientWidth: 500,
    })

    await waitForRestore()

    // Simulate the user scrolling right.
    harness.container.scrollLeft = 888
    // jsdom supports `new Event('scrollend')` because HTMLElement
    // has an `onscrollend` property slot.
    harness.container.dispatchEvent(new Event('scrollend'))

    // No timer advance — the scrollend path is synchronous.
    expect(localStorage.getItem('kanban-scroll-item_test')).toBe('888')

    harness.wrapper.unmount()
  })

  it('persists scrollLeft on scroll after 250 ms debounce', async () => {
    const harness = mountHarness()
    setScrollGeometry(harness.container, {
      scrollWidth: 5000,
      clientWidth: 500,
    })

    await waitForRestore()

    // Switch to fake timers so the debounce is deterministic.
    vi.useFakeTimers()

    // Scroll, then verify NOT written immediately.
    harness.container.scrollLeft = 777
    harness.container.dispatchEvent(new Event('scroll'))

    expect(localStorage.getItem('kanban-scroll-item_test')).toBeNull()

    // Advance JUST under the debounce — still not written.
    vi.advanceTimersByTime(200)
    expect(localStorage.getItem('kanban-scroll-item_test')).toBeNull()

    // Advance past the debounce — now written.
    vi.advanceTimersByTime(100)
    expect(localStorage.getItem('kanban-scroll-item_test')).toBe('777')

    vi.useRealTimers()
    harness.wrapper.unmount()
  })

  it('debounces a rapid scroll stream into a single write per scroll-stop', async () => {
    const harness = mountHarness()
    setScrollGeometry(harness.container, {
      scrollWidth: 5000,
      clientWidth: 500,
    })

    await waitForRestore()

    vi.useFakeTimers()

    // Simulate a fast drag (60 Hz scroll events).
    for (let i = 0; i < 10; i++) {
      harness.container.scrollLeft = 100 + i
      harness.container.dispatchEvent(new Event('scroll'))
      vi.advanceTimersByTime(20) // not enough to fire
    }

    // Only ONE write — for the LAST scrollLeft — should happen.
    vi.advanceTimersByTime(300)

    expect(localStorage.getItem('kanban-scroll-item_test')).toBe('109')

    vi.useRealTimers()
    harness.wrapper.unmount()
  })

  it('flushes the pending debounced write on unmount', async () => {
    const harness = mountHarness()
    setScrollGeometry(harness.container, {
      scrollWidth: 5000,
      clientWidth: 500,
    })

    await waitForRestore()

    vi.useFakeTimers()

    // Scroll, but do NOT advance the timer — schedule is pending.
    harness.container.scrollLeft = 999
    harness.container.dispatchEvent(new Event('scroll'))

    expect(localStorage.getItem('kanban-scroll-item_test')).toBeNull()

    // Unmount BEFORE the debounce fires. The composable should
    // flush the pending write synchronously.
    vi.useRealTimers() // let the unmount flushPending run synchronously
    harness.wrapper.unmount()
    expect(localStorage.getItem('kanban-scroll-item_test')).toBe('999')
  })

  it('handles localStorage.setItem throw gracefully (no exception)', async () => {
    const setItemSpy = vi.spyOn(Storage.prototype, 'setItem').mockImplementation(() => {
      throw new Error('QuotaExceededError')
    })

    const harness = mountHarness()
    setScrollGeometry(harness.container, {
      scrollWidth: 5000,
      clientWidth: 500,
    })

    await waitForRestore()

    // No throw on scrollend despite setItem throwing.
    expect(() => {
      harness.container.scrollLeft = 500
      harness.container.dispatchEvent(new Event('scrollend'))
    }).not.toThrow()

    setItemSpy.mockRestore()
    harness.wrapper.unmount()
  })

  it('uses a reactive storage key (per-itemId)', async () => {
    // The composable uses the key verbatim — the caller is responsible for building the full key
    // (e.g. `kanban-scroll-<itemId>`). Seed storage with two distinct FULL keys.
    localStorage.setItem('kanban-scroll-item_A', '111')
    localStorage.setItem('kanban-scroll-item_B', '222')

    // Mount with item_A first.
    const harnessA = mountHarness('kanban-scroll-item_A')
    setScrollGeometry(harnessA.container, {
      scrollWidth: 5000,
      clientWidth: 500,
    })
    await waitForRestore()
    expect(harnessA.container.scrollLeft).toBe(111)

    // Scroll, persist.
    harnessA.container.scrollLeft = 333
    harnessA.container.dispatchEvent(new Event('scrollend'))
    expect(localStorage.getItem('kanban-scroll-item_A')).toBe('333')

    harnessA.wrapper.unmount()

    // Mount with item_B — the storage key changes. Should restore
    // item_B's value (222), not item_A's.
    const harnessB = mountHarness('kanban-scroll-item_B')
    setScrollGeometry(harnessB.container, {
      scrollWidth: 5000,
      clientWidth: 500,
    })
    await waitForRestore()
    expect(harnessB.container.scrollLeft).toBe(222)

    harnessB.wrapper.unmount()
  })

  it('removes the scroll listener on unmount (no late writes)', async () => {
    const harness = mountHarness()
    setScrollGeometry(harness.container, {
      scrollWidth: 5000,
      clientWidth: 500,
    })
    await waitForRestore()

    harness.container.scrollLeft = 100
    harness.container.dispatchEvent(new Event('scroll'))

    harness.wrapper.unmount()

    vi.useFakeTimers()
    // After unmount, the listener should be gone. Dispatching more
    // scroll events must NOT cause writes.
    harness.container.dispatchEvent(new Event('scroll'))
    vi.advanceTimersByTime(500)
    expect(localStorage.getItem('kanban-scroll-item_test')).toBe('100')

    // And a scrollend post-unmount also does not write (listener gone).
    harness.container.dispatchEvent(new Event('scrollend'))
    expect(localStorage.getItem('kanban-scroll-item_test')).toBe('100')
    vi.useRealTimers()
  })

  it('does not throw when containerRef is null at flush time', async () => {
    // Defensive: the composable's `flushPending` reads `containerRef.value` — if the ref is null
    // when unmount fires (e.g. parent template rendered an error boundary), the composable should
    // silently skip rather than throw.
    const itemIdRef = ref('item_test')
    const TestComp = defineComponent({
      setup() {
        const containerRef = ref<HTMLDivElement | null>(null)
        useKanbanScrollRestore(containerRef, itemIdRef)
        return () => h('div') // never renders the container
      },
    })
    const wrapper = mount(TestComp)
    await nextTick()

    expect(() => wrapper.unmount()).not.toThrow()
  })
})

/**  * The `axis: 'y'` variant — used by the kanban row-mode list, which scrolls vertically (the columns
 * row scrolls horizontally). Same contract, different offset property. */
describe('useKanbanScrollRestore (axis: y)', () => {
  function mountVerticalHarness(initialKey = 'kanban-row-scroll-item_test') {
    const itemIdRef = ref(initialKey)
    const TestComp = defineComponent({
      setup() {
        const containerRef = ref<HTMLDivElement | null>(null)
        useKanbanScrollRestore(containerRef, itemIdRef, 'y')
        return { containerRef }
      },
      template: `<div ref="containerRef" class="outer"><div class="inner" style="height: 5000px;"></div></div>`,
    })
    const wrapper = mount(TestComp)
    const container = wrapper.find('.outer').element as HTMLDivElement
    return { wrapper, container, itemIdRef }
  }

  function setVerticalGeometry(
    container: HTMLDivElement,
    { scrollHeight, clientHeight }: { scrollHeight: number; clientHeight: number },
  ): void {
    Object.defineProperty(container, 'scrollHeight', {
      value: scrollHeight,
      writable: true,
      configurable: true,
    })
    Object.defineProperty(container, 'clientHeight', {
      value: clientHeight,
      writable: true,
      configurable: true,
    })
  }

  it('restores saved scrollTop on mount (clamped to current max)', async () => {
    localStorage.setItem('kanban-row-scroll-item_test', '1234')

    const harness = mountVerticalHarness()
    setVerticalGeometry(harness.container, { scrollHeight: 5000, clientHeight: 500 })

    await waitForRestore()

    expect(harness.container.scrollTop).toBe(1234)
    // The horizontal axis is untouched.
    expect(harness.container.scrollLeft).toBe(0)
    harness.wrapper.unmount()
  })

  it('clamps the restored scrollTop to scrollHeight - clientHeight', async () => {
    localStorage.setItem('kanban-row-scroll-item_test', '9999')

    const harness = mountVerticalHarness()
    setVerticalGeometry(harness.container, { scrollHeight: 5000, clientHeight: 500 })

    await waitForRestore()

    expect(harness.container.scrollTop).toBe(4500)
    harness.wrapper.unmount()
  })

  it('skips the restore when the content fits (max <= 0)', async () => {
    localStorage.setItem('kanban-row-scroll-item_test', '800')

    const harness = mountVerticalHarness()
    setVerticalGeometry(harness.container, { scrollHeight: 400, clientHeight: 500 })

    await waitForRestore()

    expect(harness.container.scrollTop).toBe(0)
    harness.wrapper.unmount()
  })

  it('persists scrollTop on scrollend', async () => {
    const harness = mountVerticalHarness()
    setVerticalGeometry(harness.container, { scrollHeight: 5000, clientHeight: 500 })
    await waitForRestore()

    harness.container.scrollTop = 777
    harness.container.dispatchEvent(new Event('scrollend'))
    await flushPromises()

    expect(localStorage.getItem('kanban-row-scroll-item_test')).toBe('777')
    harness.wrapper.unmount()
  })

  it('flushes the pending debounced write on unmount', async () => {
    const harness = mountVerticalHarness()
    setVerticalGeometry(harness.container, { scrollHeight: 5000, clientHeight: 500 })
    await waitForRestore()

    vi.useFakeTimers()

    harness.container.scrollTop = 321
    harness.container.dispatchEvent(new Event('scroll'))
    // Unmount BEFORE the 250 ms debounce fires.
    harness.wrapper.unmount()

    expect(localStorage.getItem('kanban-row-scroll-item_test')).toBe('321')
    vi.useRealTimers()
  })

  it('does not read the horizontal key when axis is y', async () => {
    // A stale horizontal value must not leak into the vertical restore.
    localStorage.setItem('kanban-row-scroll-item_test', '0')
    localStorage.setItem('kanban-scroll-item_test', '9999')

    const harness = mountVerticalHarness()
    setVerticalGeometry(harness.container, { scrollHeight: 5000, clientHeight: 500 })

    await waitForRestore()

    expect(harness.container.scrollTop).toBe(0)
    harness.wrapper.unmount()
  })
})
