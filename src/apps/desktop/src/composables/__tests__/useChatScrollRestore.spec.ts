/**
 * Tests for useChatScrollRestore — verifies the save-on-scroll +
 * restore-on-mount contract for ChatView's VirtualScroller.
 *
 * Why these tests exist:
 *   When a user opens a task from the kanban sidebar, ChatView
 *   mounts with `:key="task-<id>"`. Closing + reopening a different
 *   task remounts ChatView (fresh state, scrollTop = 0). Reopening
 *   the same task ALSO remounts ChatView because the parent's
 *   `:key` change in the surrounding `v-if/v-else-if` chain drops the
 *   previous instance. Without this composable, the user loses
 *   their scroll position every time they close + reopen a chat.
 *
 *   The composable persists `scrollTop` to localStorage keyed by
 *   `chat-scroll-<task_id>` (per the project's `task.id ==
 *   session.id` convention from migration 052). On reopen, the
 *   composable exposes a `restore()` function that the ChatView
 *   calls to get the saved value — if non-null and not "near
 *   bottom", ChatView calls `scrollToPosition(saved)` instead of
 *   `scrollToBottom`. The "near bottom" branch covers the common
 *   case where the user closed while at the bottom and should
 *   land at the (possibly slightly grown) genuine bottom.
 *
 * Coverage:
 *   - restores saved scrollTop on mount (after scrollHeight is known)
 *   - clamps restored value to scrollHeight - clientHeight
 *   - restore() returns null when no saved value
 *   - restore() returns null when saved value is 0
 *   - restore() returns null when container is not scrollable
 *   - restore() returns null when saved position is "near bottom"
 *     (within BOTTOM_THRESHOLD_PX of the max)
 *   - restorePosition(value) clamps + applies a given value
 *   - persists scrollTop on scrollend immediately
 *   - persists scrollTop on scroll after 250 ms debounce
 *   - flushes the pending debounced write on unmount
 *   - handles localStorage.setItem throw gracefully
 *
 * jsdom setup notes:
 *   - localStorage must be stubbed (jsdom 29 dropped it from
 *     default globals — same trick as useCodeEditor.spec.ts:26-43).
 *   - scrollHeight / clientHeight are not laid out in jsdom; we
 *     override them with `Object.defineProperty` so the clamp
 *     math has real numbers.
 *   - `requestAnimationFrame` polyfill mirrors
 *     useKanbanScrollRestore.spec.ts:70-82.
 *   - The composable waits for `scrollHeight > clientHeight` OR
 *     a 500ms safety net before reading (chat items are async-
 *     measured, unlike the kanban's static columns), so we
 *     configure scrollHeight BEFORE mounting the harness rather
 *     than waiting for items to render.
 */
import {
  afterEach,
  beforeAll,
  beforeEach,
  describe,
  expect,
  it,
  vi,
} from 'vitest'
import { defineComponent, ref, type Ref } from 'vue'
import { flushPromises, mount } from '@vue/test-utils'

import { useChatScrollRestore } from '../useChatScrollRestore'

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

/** The composable returns { restore, restorePosition }. The harness
 * captures the return value via a module-scope slot so the test
 * can assert on the saved value (mirrors the `restore`-time
 * contract: the parent reads `restore()` AFTER its own
 * `await rAF × 2` so the saved value is computed by then). */
const capturedRestore: { current: (() => number | null) | null } = { current: null }
const capturedRestorePosition: { current: ((value: number) => void) | null } = {
  current: null,
}

interface TestHarness {
  wrapper: ReturnType<typeof mount>
  container: HTMLDivElement
  keyRef: Ref<string>
}

function mountHarness(
  initialKey = 'chat-scroll-task_test',
  initialGeometry: { scrollHeight: number; clientHeight: number } = {
    scrollHeight: 5000,
    clientHeight: 800,
  },
): TestHarness {
  // Reset the captured-restore slots so prior tests don't leak.
  capturedRestore.current = null
  capturedRestorePosition.current = null

  const keyRef = ref(initialKey)
  const TestComp = defineComponent({
    setup() {
      const containerRef = ref<HTMLDivElement | null>(null)
      const result = useChatScrollRestore(containerRef, keyRef)
      capturedRestore.current = result.restore
      capturedRestorePosition.current = result.restorePosition
      return { containerRef }
    },
    template: `<div ref="containerRef" class="outer" style="overflow: auto;"><div class="inner" style="height: 5000px;"></div></div>`,
  })
  const wrapper = mount(TestComp)
  const container = wrapper.find('.outer').element as HTMLDivElement
  setScrollGeometry(container, initialGeometry)
  return { wrapper, container, keyRef }
}

function setScrollGeometry(
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

/**
 * Wait for the composable's onMounted handler to:
 *   1. read the saved scrollTop from localStorage
 *   2. wait for scrollHeight > clientHeight (or 500ms safety net)
 *   3. attach scroll + scrollend listeners
 *
 * The scrollHeight poll happens inside `await` loops that check
 * `Date.now() - start < 500` against setTimeout(16). With real
 * timers (default in beforeEach), one iteration of the poll is
 * 16ms; the poll succeeds immediately because the harness sets
 * scrollHeight > clientHeight BEFORE mountHarness returns. A 100ms
 * real wait is plenty.
 */
async function waitForRestore(): Promise<void> {
  await flushPromises()
  await new Promise<void>((r) => setTimeout(r, 100))
  await flushPromises()
}

beforeEach(() => {
  vi.useRealTimers()
  localStorage.clear()
})

afterEach(() => {
  vi.useRealTimers()
  localStorage.clear()
})

describe('useChatScrollRestore — restore contract', () => {
  it('restore() returns the saved scrollTop when not near bottom', async () => {
    localStorage.setItem('chat-scroll-task_test', '840')

    const harness = mountHarness()
    await waitForRestore()

    expect(capturedRestore.current).not.toBeNull()
    expect(capturedRestore.current!()).toBe(840)
    harness.wrapper.unmount()
  })

  it('restore() returns null when the saved position is "near bottom" (within 40px of max)', async () => {
    // scrollHeight=5000, clientHeight=800 → max=4200. saved=4200 → distance from bottom=0
    localStorage.setItem('chat-scroll-task_test', '4200')

    const harness = mountHarness()
    await waitForRestore()

    expect(capturedRestore.current!()).toBeNull()
    harness.wrapper.unmount()
  })

  it('restore() returns null when the saved position is just-inside bottom (max - BOTTOM_THRESHOLD_PX + 1)', async () => {
    // max=4200, BOTTOM_THRESHOLD_PX=40 → boundary = 4160. saved=4160 → distance=40 → "near bottom" → null
    localStorage.setItem('chat-scroll-task_test', '4160')

    const harness = mountHarness()
    await waitForRestore()

    expect(capturedRestore.current!()).toBeNull()
    harness.wrapper.unmount()
  })

  it('restore() returns null when the saved position is in the middle (max - BOTTOM_THRESHOLD_PX - 1)', async () => {
    // max=4200, BOTTOM_THRESHOLD_PX=40 → boundary at 4160. saved=4159 → distance=41 → NOT near bottom → restored
    localStorage.setItem('chat-scroll-task_test', '4159')

    const harness = mountHarness()
    await waitForRestore()

    expect(capturedRestore.current!()).toBe(4159)
    harness.wrapper.unmount()
  })

  it('restore() returns null when no saved value exists', async () => {
    const harness = mountHarness()
    await waitForRestore()

    expect(capturedRestore.current!()).toBeNull()
    harness.wrapper.unmount()
  })

  it('restore() returns null when the saved value is 0', async () => {
    localStorage.setItem('chat-scroll-task_test', '0')

    const harness = mountHarness()
    await waitForRestore()

    expect(capturedRestore.current!()).toBeNull()
    harness.wrapper.unmount()
  })

  it('restore() returns null when the container is not scrollable', async () => {
    localStorage.setItem('chat-scroll-task_test', '500')

    const harness = mountHarness('chat-scroll-task_noscroll', {
      scrollHeight: 800,
      clientHeight: 800,
    })
    await waitForRestore()

    expect(capturedRestore.current!()).toBeNull()
    harness.wrapper.unmount()
  })

  it('restorePosition(value) clamps the given value to [0, scrollHeight - clientHeight]', async () => {
    const harness = mountHarness()
    await waitForRestore()

    // value > max → clamp to max
    capturedRestorePosition.current!(9999)
    expect(harness.container.scrollTop).toBe(4200)

    // value < 0 → clamp to 0
    capturedRestorePosition.current!(-100)
    expect(harness.container.scrollTop).toBe(0)

    // value in range → apply verbatim
    capturedRestorePosition.current!(840)
    expect(harness.container.scrollTop).toBe(840)

    harness.wrapper.unmount()
  })

  it('restorePosition is a no-op when containerRef is null', async () => {
    // Mount, then force the ref to null via unmount. The captured
    // restorePosition still references the (now-detached) ref's
    // value (null after unmount). Call it — should not throw.
    const harness = mountHarness()
    await waitForRestore()
    harness.wrapper.unmount()
    expect(() => capturedRestorePosition.current!(500)).not.toThrow()
  })
})

describe('useChatScrollRestore — save contract', () => {
  it('persists scrollTop on scrollend immediately (no timer advance)', async () => {
    const harness = mountHarness()
    await waitForRestore()

    harness.container.scrollTop = 888
    harness.container.dispatchEvent(new Event('scrollend'))

    expect(localStorage.getItem('chat-scroll-task_test')).toBe('888')

    harness.wrapper.unmount()
  })

  it('persists scrollTop on scroll after 250 ms debounce', async () => {
    const harness = mountHarness()
    await waitForRestore()

    vi.useFakeTimers()
    harness.container.scrollTop = 777
    harness.container.dispatchEvent(new Event('scroll'))
    expect(localStorage.getItem('chat-scroll-task_test')).toBeNull()

    vi.advanceTimersByTime(200)
    expect(localStorage.getItem('chat-scroll-task_test')).toBeNull()

    vi.advanceTimersByTime(100)
    expect(localStorage.getItem('chat-scroll-task_test')).toBe('777')

    vi.useRealTimers()
    harness.wrapper.unmount()
  })

  it('debounces a rapid scroll stream into a single write per scroll-stop', async () => {
    const harness = mountHarness()
    await waitForRestore()

    vi.useFakeTimers()

    for (let i = 0; i < 10; i++) {
      harness.container.scrollTop = 100 + i
      harness.container.dispatchEvent(new Event('scroll'))
      vi.advanceTimersByTime(20)
    }

    vi.advanceTimersByTime(300)

    expect(localStorage.getItem('chat-scroll-task_test')).toBe('109')

    vi.useRealTimers()
    harness.wrapper.unmount()
  })

  it('flushes the pending debounced write on unmount', async () => {
    const harness = mountHarness()
    await waitForRestore()

    vi.useFakeTimers()
    harness.container.scrollTop = 999
    harness.container.dispatchEvent(new Event('scroll'))
    expect(localStorage.getItem('chat-scroll-task_test')).toBeNull()

    vi.useRealTimers() // let unmount's flushPending run synchronously
    harness.wrapper.unmount()
    expect(localStorage.getItem('chat-scroll-task_test')).toBe('999')
  })

  it('handles localStorage.setItem throw gracefully (no exception)', async () => {
    const setItemSpy = vi
      .spyOn(Storage.prototype, 'setItem')
      .mockImplementation(() => {
        throw new Error('QuotaExceededError')
      })

    const harness = mountHarness()
    await waitForRestore()

    expect(() => {
      harness.container.scrollTop = 500
      harness.container.dispatchEvent(new Event('scrollend'))
    }).not.toThrow()

    setItemSpy.mockRestore()
    harness.wrapper.unmount()
  })

  it('uses a reactive storage key (per-taskId)', async () => {
    localStorage.setItem('chat-scroll-task_A', '111')
    localStorage.setItem('chat-scroll-task_B', '222')

    const harnessA = mountHarness('chat-scroll-task_A')
    await waitForRestore()
    expect(capturedRestore.current!()).toBe(111)
    harnessA.wrapper.unmount()

    const harnessB = mountHarness('chat-scroll-task_B')
    await waitForRestore()
    expect(capturedRestore.current!()).toBe(222)
    harnessB.wrapper.unmount()
  })

  it('removes the scroll listener on unmount (no late writes)', async () => {
    const harness = mountHarness()
    await waitForRestore()

    harness.container.scrollTop = 100
    harness.container.dispatchEvent(new Event('scroll'))

    harness.wrapper.unmount()

    vi.useFakeTimers()
    harness.container.dispatchEvent(new Event('scroll'))
    vi.advanceTimersByTime(500)
    expect(localStorage.getItem('chat-scroll-task_test')).toBe('100')

    harness.container.dispatchEvent(new Event('scrollend'))
    expect(localStorage.getItem('chat-scroll-task_test')).toBe('100')
    vi.useRealTimers()
  })
})
