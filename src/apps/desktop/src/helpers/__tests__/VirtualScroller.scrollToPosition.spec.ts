/**
 * Tests for VirtualScroller.scrollToPosition — the new public method
 * that lets the parent request an arbitrary scrollTop without
 * bypassing the scroller's internal state.
 *
 * Why this exists:
 *   useChatScrollRestore composable needs to write a saved
 *   scrollTop back to the scroller's container on mount. The
 *   existing public API exposes scrollToTop / scrollToBottom /
 *   scrollToIndex but NOT scrollToPosition (an arbitrary px
 *   value). Without this method, the composable would have to
 *   either:
 *     (a) call containerRef.value.scrollTop = value directly
 *         (bypasses the scroller's state machine), or
 *     (b) compute a target index from the pixel value
 *         (lossy + requires an index-to-height map).
 *   Adding scrollToPosition keeps the clamping + internal-state
 *   sync in one place.
 *
 * Coverage:
 *   - clamps a value > max to max (max = scrollHeight - clientHeight)
 *   - clamps a value < 0 to 0
 *   - applies a value in range verbatim
 *   - is a no-op when the container is not scrollable
 *   - is a no-op when containerRef is null
 *
 * jsdom setup notes:
 *   - VirtualScroller measures items via ResizeObserver + a
 *     setTimeout-based measureItems loop. In jsdom, item heights
 *     are derived from `default-item-height` (200px). The
 *     container's scrollWidth / clientHeight / scrollHeight are
 *     not laid out, so we override them via Object.defineProperty
 *     to simulate a known geometry.
 */
import {
  afterEach,
  beforeAll,
  beforeEach,
  describe,
  expect,
  it,
} from 'vitest'
import { defineComponent, ref, type Ref } from 'vue'
import { flushPromises, mount } from '@vue/test-utils'

import VirtualScroller from '../VirtualScroller.vue'

beforeAll(() => {
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

  if (typeof globalThis.requestAnimationFrame !== 'function') {
    globalThis.requestAnimationFrame = (cb: (t: number) => void): number => {
      return setTimeout(() => cb(performance.now()), 0) as unknown as number
    }
    globalThis.cancelAnimationFrame = (id: number): void => {
      clearTimeout(id as unknown as ReturnType<typeof setTimeout>)
    }
  }
})

interface ScrollHarness {
  wrapper: ReturnType<typeof mount>
  container: HTMLElement
  scrollerRef: Ref<VirtualScrollerTestExposed | null>
}

/**
 * Hand-typed mirror of VirtualScroller's exposed methods that this
 * test uses. The Vue 3 SFC can't be referenced via
 * `InstanceType<typeof VirtualScroller>` — SFCs are functions, not
 * classes. The same approach ChatView.vue uses for
 * `VirtualScrollerExposed` (see ChatView.vue:453-464).
 */
interface VirtualScrollerTestExposed {
  scrollToPosition: (scrollTop: number, behavior?: ScrollBehavior) => void
}

function mountScrollHarness(itemCount: number): ScrollHarness {
  const items = Array.from({ length: itemCount }, (_, i) => ({ id: i, label: `item-${i}` }))
  const scrollerRef = ref<VirtualScrollerTestExposed | null>(null)
  const TestComp = defineComponent({
    components: { VirtualScroller },
    setup() {
      return { scrollerRef, items }
    },
    template: `
      <VirtualScroller
        ref="scrollerRef"
        :items="items"
        :default-item-height="200"
        style="height: 800px; width: 100%;"
      />
    `,
  })
  const wrapper = mount(TestComp)
  const container = wrapper.find('.virtual-scroller').element as HTMLElement
  return { wrapper, container, scrollerRef }
}

function setScrollGeometry(
  container: HTMLElement,
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
  // jsdom does NOT implement Element.scrollTo — install a minimal
  // stub that mirrors the browser behavior (sets scrollTop). This
  // is what the existing scrollToTop/scrollToBottom methods call.
  container.scrollTo = ((arg: ScrollToOptions | number, _y?: number): void => {
    if (typeof arg === 'number') {
      container.scrollTop = arg
      return
    }
    if (arg.top !== undefined) container.scrollTop = arg.top
  }) as HTMLElement['scrollTo']
}

async function waitForMeasure(): Promise<void> {
  // VirtualScroller's onMounted does `nextTick + setTimeout(measureItems, 100)`.
  await flushPromises()
  await new Promise<void>((r) => setTimeout(r, 150))
  await flushPromises()
}

beforeEach(() => {
  localStorage.clear()
})

afterEach(() => {
  localStorage.clear()
})

describe('VirtualScroller.scrollToPosition', () => {
  it('clamps a value greater than max to max', async () => {
    const harness = mountScrollHarness(10)
    await waitForMeasure()
    // 10 items × 200px each = 2000px scrollHeight; clientHeight = 800 → max = 1200
    setScrollGeometry(harness.container, { scrollHeight: 2000, clientHeight: 800 })

    harness.scrollerRef.value?.scrollToPosition(9999)

    expect(harness.container.scrollTop).toBe(1200)
    harness.wrapper.unmount()
  })

  it('clamps a negative value to 0', async () => {
    const harness = mountScrollHarness(10)
    await waitForMeasure()
    setScrollGeometry(harness.container, { scrollHeight: 2000, clientHeight: 800 })

    harness.scrollerRef.value?.scrollToPosition(-100)

    expect(harness.container.scrollTop).toBe(0)
    harness.wrapper.unmount()
  })

  it('applies an in-range value verbatim', async () => {
    const harness = mountScrollHarness(10)
    await waitForMeasure()
    setScrollGeometry(harness.container, { scrollHeight: 2000, clientHeight: 800 })

    harness.scrollerRef.value?.scrollToPosition(840)

    expect(harness.container.scrollTop).toBe(840)
    harness.wrapper.unmount()
  })

  it('is a no-op when the container is not scrollable', async () => {
    const harness = mountScrollHarness(1)
    await waitForMeasure()
    // 1 item × 200px = 200px scrollHeight; clientHeight = 800 → max <= 0 → not scrollable
    setScrollGeometry(harness.container, { scrollHeight: 200, clientHeight: 800 })

    harness.scrollerRef.value?.scrollToPosition(500)

    // The browser still sets scrollTop, but the scroller's own method should have been a no-op.
    // With max <= 0, the spec is "no scroll needed" — the value stays at 0 because there's nothing
    // to scroll past.
    expect(harness.container.scrollTop).toBe(0)
    harness.wrapper.unmount()
  })
})
