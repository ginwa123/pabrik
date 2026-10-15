/**
 * Tests for useKanbanColumnScrollRestore — the save-on-scroll +
 * restore-on-appear contract for a kanban column's vertical scroll.
 *
 * Why these tests exist:
 *   A kanban column's card list is a <VirtualScroller> whose
 *   overflow-y-auto container is destroyed whenever the view around the
 *   board unmounts. That now happens on a normal user action: the tab
 *   strip switching from the board tab to a task-chat tab and back (and,
 *   with tab mode off, opening a task at all — the chat replaces the
 *   board). Without this composable the rebuilt column starts at
 *   scrollTop = 0, so the user loses their place in a column holding 50+
 *   cards. These tests pin the contract so a future refactor can't
 *   regress it.
 *
 * Coverage:
 *   - restores the saved scrollTop once the container appears
 *   - clamps the restored value to scrollHeight - clientHeight
 *   - skips restore when nothing was saved / the value is 0
 *   - skips restore when the container cannot scroll yet (max <= 0)
 *   - wires up when the container appears LATE (the VirtualScroller is
 *     behind v-if="cardsInColumn.length > 0", so on a cold load it is not
 *     in the DOM at setup) — the reason this composable exists separately
 *     from its horizontal sibling
 *   - persists on `scrollend` immediately
 *   - persists on `scroll` after the 250 ms debounce
 *   - flushes the last CAPTURED value on unmount, never a fresh DOM read
 *     (a torn-down element reports scrollTop = 0, which would wipe a good
 *     saved position)
 *   - swallows a localStorage write throw (private mode / quota)
 *
 * jsdom setup notes:
 *   - localStorage must be stubbed (jsdom 29 dropped it from default
 *     globals — same trick as useKanbanScrollRestore.spec.ts:26-43).
 *   - scrollHeight / clientHeight are not laid out in jsdom; they are
 *     overridden per test so the clamp math has real numbers.
 *   - jsdom does NOT dispatch a `scroll` event when `scrollTop` is
 *     assigned, so each test sets scrollTop and dispatches explicitly.
 *   - `scrollend` is feature-detected with `in`; the harness installs it
 *     explicitly for the fast-path test.
 */
import { afterEach, beforeAll, beforeEach, describe, expect, it, vi } from 'vitest'
import { defineComponent, nextTick, ref, type Ref } from 'vue'
import { flushPromises, mount } from '@vue/test-utils'

import { useKanbanColumnScrollRestore } from '../useKanbanColumnScrollRestore'

const KEY = 'kanban-col-scroll-item_test:col_a'

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

  // jsdom does NOT provide requestAnimationFrame — polyfill it with
  // setTimeout(0) so the composable's `await rAF × 2` resolves.
  if (typeof globalThis.requestAnimationFrame !== 'function') {
    globalThis.requestAnimationFrame = (cb: (t: number) => void): number =>
      setTimeout(() => cb(performance.now()), 0) as unknown as number
    globalThis.cancelAnimationFrame = (id: number): void => {
      clearTimeout(id as unknown as ReturnType<typeof setTimeout>)
    }
  }
})

interface TestHarness {
  wrapper: ReturnType<typeof mount>
  container: HTMLDivElement
  keyRef: Ref<string>
  /** Flip the container out of / into the DOM (the v-if case). */
  setVisible: (visible: boolean) => Promise<void>
}

function mountHarness({
  initialKey = KEY,
  withScrollEnd = false,
}: { initialKey?: string; withScrollEnd?: boolean } = {}): TestHarness {
  const keyRef = ref(initialKey)
  const visible = ref(true)

  const TestComp = defineComponent({
    setup() {
      const containerRef = ref<HTMLDivElement | null>(null)
      useKanbanColumnScrollRestore(containerRef, keyRef)
      return { containerRef, visible }
    },
    template: `<div v-if="visible" ref="containerRef" class="col-scroll"><div class="inner" /></div>`,
  })

  const wrapper = mount(TestComp)
  const container = wrapper.find('.col-scroll').element as HTMLDivElement

  if (withScrollEnd) {
    // Make the composable's `'onscrollend' in el` feature detect pass.
    Object.defineProperty(container, 'onscrollend', {
      value: null,
      writable: true,
      configurable: true,
    })
  }

  return {
    wrapper,
    container,
    keyRef,
    async setVisible(next: boolean) {
      visible.value = next
      await nextTick()
    },
  }
}

/**  * Give the container real scroll geometry. jsdom reports 0 for scrollHeight / clientHeight, which
 * would make the composable's "not scrollable yet" early-exit skip every restore. */
function setGeometry(
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

/** Wait the two requestAnimationFrame ticks the composable awaits before
 * applying a restore, plus a microtask flush so Vue's effects settle. */
async function waitForRestore(): Promise<void> {
  await flushPromises()
  await new Promise<void>((r) => requestAnimationFrame(() => r()))
  await new Promise<void>((r) => requestAnimationFrame(() => r()))
  await flushPromises()
}

function scrollTo(container: HTMLDivElement, top: number): void {
  container.scrollTop = top
  container.dispatchEvent(new Event('scroll'))
}

beforeEach(() => {
  vi.useRealTimers()
  localStorage.clear()
})

afterEach(() => {
  vi.useRealTimers()
  localStorage.clear()
})

describe('useKanbanColumnScrollRestore', () => {
  it('restores the saved scrollTop once the container appears', async () => {
    localStorage.setItem(KEY, '640')
    const harness = mountHarness()
    setGeometry(harness.container, { scrollHeight: 5000, clientHeight: 800 })

    await waitForRestore()

    expect(harness.container.scrollTop).toBe(640)
    harness.wrapper.unmount()
  })

  it('clamps the restored value to scrollHeight - clientHeight', async () => {
    // Saved 9999, but this container can only scroll to 4200.
    localStorage.setItem(KEY, '9999')
    const harness = mountHarness()
    setGeometry(harness.container, { scrollHeight: 5000, clientHeight: 800 })

    await waitForRestore()

    expect(harness.container.scrollTop).toBe(4200)
    harness.wrapper.unmount()
  })

  it('does nothing when no position was saved (first visit)', async () => {
    const harness = mountHarness()
    setGeometry(harness.container, { scrollHeight: 5000, clientHeight: 800 })

    await waitForRestore()

    expect(harness.container.scrollTop).toBe(0)
    harness.wrapper.unmount()
  })

  it('does nothing when the saved position is 0', async () => {
    localStorage.setItem(KEY, '0')
    const harness = mountHarness()
    setGeometry(harness.container, { scrollHeight: 5000, clientHeight: 800 })

    await waitForRestore()

    expect(harness.container.scrollTop).toBe(0)
    harness.wrapper.unmount()
  })

  it('does not restore while the container cannot scroll yet', async () => {
    localStorage.setItem(KEY, '640')
    const harness = mountHarness()
    // Content shorter than the viewport — nothing to scroll to.
    setGeometry(harness.container, { scrollHeight: 400, clientHeight: 800 })

    await waitForRestore()

    expect(harness.container.scrollTop).toBe(0)
    harness.wrapper.unmount()
  })

  it('waits for the column to become scrollable before giving up', async () => {
    // The cards may not be laid out by the second animation frame. Bailing out
    // on `max <= 0` immediately would silently drop the restore — the user
    // would come back to a column sitting at the top, which is the bug.
    localStorage.setItem(KEY, '640')
    const harness = mountHarness()
    setGeometry(harness.container, { scrollHeight: 400, clientHeight: 800 })

    // …the cards land a few frames later…
    setTimeout(() => {
      setGeometry(harness.container, { scrollHeight: 5000, clientHeight: 800 })
    }, 40)

    await waitForRestore()
    // …and the composable picks them up on its next poll.
    await new Promise<void>((r) => setTimeout(r, 60))
    await flushPromises()

    expect(harness.container.scrollTop).toBe(640)
    harness.wrapper.unmount()
  })

  it('wires up when the container appears LATE (the v-if card list)', async () => {
    // The regression this composable exists for: a kanban column renders its VirtualScroller under
    // `v-if="cardsInColumn.length > 0"`, so on a cold load (tasks still arriving) there is no
    // element at setup time.

    // If the listeners were attached only in onMounted, this column's position would never be saved
    // in the first place.
    localStorage.setItem(KEY, '640')
    const harness = mountHarness()
    await harness.setVisible(false)
    await flushPromises()

    // …the column's tasks arrive…
    await harness.setVisible(true)
    const container = harness.wrapper.find('.col-scroll').element as HTMLDivElement
    setGeometry(container, { scrollHeight: 5000, clientHeight: 800 })

    await waitForRestore()

    expect(container.scrollTop).toBe(640)

    // …and it can still SAVE from here, which is the other half of the bug.
    scrollTo(container, 1234)
    container.dispatchEvent(new Event('scrollend'))
    expect(localStorage.getItem(KEY)).toBe('1234')

    harness.wrapper.unmount()
  })

  it('persists immediately on scrollend', async () => {
    const harness = mountHarness({ withScrollEnd: true })
    setGeometry(harness.container, { scrollHeight: 5000, clientHeight: 800 })

    scrollTo(harness.container, 900)
    harness.container.dispatchEvent(new Event('scrollend'))

    expect(localStorage.getItem(KEY)).toBe('900')
    harness.wrapper.unmount()
  })

  it('persists on scroll after the 250 ms debounce', async () => {
    vi.useFakeTimers()
    const harness = mountHarness()
    setGeometry(harness.container, { scrollHeight: 5000, clientHeight: 800 })

    scrollTo(harness.container, 700)
    // Not written yet — the write is debounced.
    expect(localStorage.getItem(KEY)).toBeNull()

    vi.advanceTimersByTime(250)
    expect(localStorage.getItem(KEY)).toBe('700')

    harness.wrapper.unmount()
    vi.useRealTimers()
  })

  it('flushes the last CAPTURED value on unmount, not a fresh DOM read', async () => {
    // A torn-down element reports scrollTop = 0. Reading the DOM at flush
    // time would therefore wipe a good saved position with zero — which is
    // exactly the bug this guards.
    const harness = mountHarness({ withScrollEnd: true })
    setGeometry(harness.container, { scrollHeight: 5000, clientHeight: 800 })

    scrollTo(harness.container, 300)
    // The element is being torn down and now reports 0…
    harness.container.scrollTop = 0

    harness.wrapper.unmount()

    expect(localStorage.getItem(KEY)).toBe('300')
  })

  it('swallows a localStorage write failure (private mode / quota)', async () => {
    const harness = mountHarness({ withScrollEnd: true })
    setGeometry(harness.container, { scrollHeight: 5000, clientHeight: 800 })

    const spy = vi.spyOn(localStorage, 'setItem').mockImplementation(() => {
      throw new Error('QuotaExceededError')
    })

    scrollTo(harness.container, 900)
    expect(() => harness.container.dispatchEvent(new Event('scrollend'))).not.toThrow()
    // The user's scroll still worked; only persistence was lost.
    expect(harness.container.scrollTop).toBe(900)

    spy.mockRestore()
    harness.wrapper.unmount()
  })

  it('re-reads the storage key when the column changes', async () => {
    const harness = mountHarness({ initialKey: 'kanban-col-scroll-item_test:col_a' })
    setGeometry(harness.container, { scrollHeight: 5000, clientHeight: 800 })
    await waitForRestore()

    scrollTo(harness.container, 111)
    harness.container.dispatchEvent(new Event('scrollend'))
    expect(localStorage.getItem('kanban-col-scroll-item_test:col_a')).toBe('111')

    // Same component instance, different column (and therefore key).
    harness.keyRef.value = 'kanban-col-scroll-item_test:col_b'
    await nextTick()
    scrollTo(harness.container, 222)
    harness.container.dispatchEvent(new Event('scrollend'))

    expect(localStorage.getItem('kanban-col-scroll-item_test:col_b')).toBe('222')
    // …and the old column's position is left alone.
    expect(localStorage.getItem('kanban-col-scroll-item_test:col_a')).toBe('111')

    harness.wrapper.unmount()
  })
})
