/**
 * "resume scroll why not match with user expectation? — it's always a bit on top"
 *
 * The reader closes a chat mid-transcript, reopens the same task, and lands
 * ABOVE where they were reading. Not at the top, not at the bottom — a bit up.
 *
 * ── The mechanism ───────────────────────────────────────────────────────────
 *
 * The restore is applied one frame after mount, but at that moment
 * VirtualScroller's height model is still ALL ESTIMATES: `defaultItemHeight`
 * is 64 and the first `measureItems` pass does not run until ~100 ms later. So
 * the restore is decided against a geometry that does not exist yet:
 *
 *   1. `restore()`'s "near bottom" test compares the saved value against the
 *      ESTIMATED bottom edge, so a reader who closed mid-transcript reads as
 *      "still at the bottom" and gets `scrollToBottom` instead of their own
 *      position.
 *   2. `scrollToPosition(saved)` clamps to the ESTIMATED max, so even when the
 *      restore does fire it writes a real coordinate into an estimated model —
 *      and the first measure pass then compensates the reader by the whole
 *      estimate error above the anchor.
 *
 * Measured on the real component before the fix: saved=9000 landed at 19200
 * (the bottom), saved=500 landed at 1452, saved=5000 landed at 15608.
 *
 * ── What is asserted here ───────────────────────────────────────────────────
 *
 * The app's own answer, on the real component with the real VirtualScroller:
 * the container's `scrollTop` once the mount settles. jsdom has no layout, so
 * row heights are mocked the way the sibling virtualScroller specs do — but the
 * restore path, the clamp, the measure pass and the at-bottom classification
 * are all production code.
 *
 * The saved position is deliberately in the MIDDLE of the transcript, well
 * clear of the "near bottom" branch, so the only thing that can move it is the
 * bug.
 *
 * ⛔ WHY THIS FILE OVERRIDES `Element.prototype.scrollTo` UNCONDITIONALLY
 *
 * `src/__tests__/setup.ts` already installs a polyfill that ASSIGNS `scrollTop`
 * and nothing else. A real browser also fires the `scroll` event, and
 * ChatView's `handleVirtualScroll` is what maintains `isAtBottom` — without the
 * event the flag keeps its initial `true`, `onContentShift` re-sticks to the
 * bottom, and the test manufactures a failure the product does not have. The
 * usual `if (typeof … === 'undefined')` guard therefore never fires here, and
 * copying it from a sibling spec silently produces a lying test.
 */
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest'
import { setActivePinia, createPinia } from 'pinia'
import { nextTick } from 'vue'
import { mount, type VueWrapper } from '@vue/test-utils'
import { Effect } from 'effect'

import * as api from '../../api'
import ChatView from '../../components/views/ChatView.vue'

// ── The hoisted api mock ────────────────────────────────────────────────────
// Two seams, both required, both hoisted (same reason as
// ChatView.streamingStick.spec.ts): `chatEngineDb` binds `fetchFn =
// getChatHistory` as a constructor default evaluated at module load, and
// ChatView's authoritative load calls `api.fetchChatHistoryEffect` directly.
const historyRows: unknown[] = []
const historyResponse = () => ({
  messages: historyRows,
  has_more: false,
  next_cursor: null,
  cwd: '/tmp',
  git_worktree_cwd: '',
  max_total_tokens: 0,
  max_capacity_total_tokens: 0,
  skills: [],
})
vi.mock('../../api', async (importOriginal) => {
  const actual = await importOriginal<typeof import('../../api')>()
  return {
    ...actual,
    getChatHistory: () => Promise.resolve(historyResponse()),
    fetchChatHistoryEffect: () => Effect.succeed(historyResponse()),
  }
})

vi.mock('vue-router', async () => {
  const actual = await vi.importActual<typeof import('vue-router')>('vue-router')
  return {
    ...actual,
    useRoute: () => ({ query: {}, path: '/app', params: {} }),
    useRouter: () => ({
      replace: vi.fn(() => Promise.resolve()),
      push: vi.fn(() => Promise.resolve()),
      back: vi.fn(),
    }),
  }
})

// Faithful `scrollTo`: assign the position AND fire the event a browser fires.
// See the ⛔ note in the header for why the guard cannot be used here.
Element.prototype.scrollTo = function scrollToPolyfill(
  this: Element,
  x?: number | ScrollToOptions,
  y?: number,
): void {
  const el = this as Element & { scrollTop?: number; scrollLeft?: number }
  let top: number | undefined
  let left: number | undefined
  if (typeof x === 'number') {
    top = x
    left = y ?? el.scrollLeft ?? 0
  } else if (x && typeof x === 'object') {
    top = x.top
    left = x.left
  }
  if (top !== undefined) el.scrollTop = top
  if (left !== undefined) el.scrollLeft = left
  el.dispatchEvent(new Event('scroll'))
}

// ── The geometry under test ─────────────────────────────────────────────────
//
// The whole bug is the gap between the ESTIMATE and the MEASURED height, so the
// two must be different numbers and both must be knowable:
//
//   VIEWPORT   800px
//   ROW        200px real (mocked offsetHeight)
//   ROWS       100  →  real total 20000px, real bottom 19200px
// ESTIMATE 64px → estimated total 6400px, estimated bottom 5600px A reader who closed at 9000px is
// in the middle of the REAL transcript and far above the ESTIMATED bottom — so the estimate cannot
// be the thing that decides where they land, or the restore is meaningless.
const VIEWPORT = 800
const ROW_HEIGHT = 200
const ROW_COUNT = 100
const REAL_TOTAL = ROW_HEIGHT * ROW_COUNT
const REAL_BOTTOM = REAL_TOTAL - VIEWPORT
const ESTIMATE = 64
const ESTIMATED_TOTAL = ESTIMATE * ROW_COUNT
const ESTIMATED_BOTTOM = ESTIMATED_TOTAL - VIEWPORT

/** Where the reader closed the chat: mid-transcript, well clear of the tail. */
const SAVED_POSITION = 9000

/** jsdom has no layout, so `scrollHeight` is whatever we say. The scroller's sizer is a real DOM
 * element with a real inline `height`, and a browser derives the container's scrollHeight from it —
 * so mirror that: the container reports the sizer's current height. */
/** That makes the estimate-vs-measured gap REAL rather than asserted, which is the only way this
 * test can tell "restored to the saved position" apart from "clamped to whatever the model
 * currently claims". */
Object.defineProperty(HTMLElement.prototype, 'clientHeight', {
  configurable: true,
  get(): number {
    return VIEWPORT
  },
})
Object.defineProperty(HTMLElement.prototype, 'scrollHeight', {
  configurable: true,
  get(): number {
    const sizer = (this as HTMLElement).querySelector?.('.virtual-scroller-sizer')
    return sizer ? parseFloat((sizer as HTMLElement).style.height) || 0 : 0
  },
})

function installApiMocks(): void {
  historyRows.length = 0
  for (let i = 0; i < ROW_COUNT; i++) {
    historyRows.push({
      id: `msg_${i}`,
      role: i % 2 === 0 ? 'user' : 'assistant',
      content: `Message ${i}`,
      created_at: i,
      image_url: '',
      finish_reason: '',
    })
  }
  // eslint-disable-next-line @typescript-eslint/no-explicit-any
  vi.spyOn(api, 'getQueuedMessages').mockResolvedValue({ messages: [] } as any)
  vi.spyOn(api, 'getSession').mockResolvedValue({
    session_id: 'placeholder',
    session_name: '',
    selectedProfile: null,
    cwd: '',
    git_worktree_cwd: '',
    // eslint-disable-next-line @typescript-eslint/no-explicit-any
  } as any)
  vi.spyOn(api, 'getGitStatus').mockResolvedValue({
    is_git_repo: false,
    branch: '',
    has_changes: false,
    is_clean: true,
    current: '',
    status: 'clean',
    // eslint-disable-next-line @typescript-eslint/no-explicit-any
  } as any)
  // eslint-disable-next-line @typescript-eslint/no-explicit-any
  vi.spyOn(api, 'getPabrikConfig').mockResolvedValue({ profiles: {} } as any)
}

/**  * Give every rendered row a real, uniform height. `measureItems` reads `offsetHeight` per child, so
 * this is what turns the estimate into a measurement — the exact step the restore used to race. */
function mockRowHeights(container: HTMLElement): void {
  const content = container.querySelector('.virtual-scroller-content')
  if (!content) return
  for (const child of Array.from(content.children)) {
    Object.defineProperty(child, 'offsetHeight', {
      value: ROW_HEIGHT,
      configurable: true,
    })
  }
}

async function mountChatView(chatId: string): Promise<VueWrapper> {
  const wrapper = mount(ChatView, {
    props: { chatId, chatName: 'Resume scroll' },
    attachTo: document.body,
  })
  // The scroller's mount gate is `!isInitializing && (isLoading ||
  // messageGroups.length > 0)`, and `isInitializing` only clears once the
  // history load settles — so its presence IS the load-completed signal.
  for (let i = 0; i < 60; i++) {
    await new Promise((r) => setTimeout(r, 40))
    await nextTick()
    if (wrapper.find('.virtual-scroller').exists()) break
  }
  return wrapper
}

function findScrollerContainer(wrapper: VueWrapper): HTMLElement {
  const el = wrapper.find('.virtual-scroller')
  if (!el.exists()) {
    throw new Error(
      '.virtual-scroller not mounted — the history load never settled, so this ' +
        'test would otherwise assert nothing (check the vi.mock seam above)',
    )
  }
  return el.element as HTMLElement
}

/**  * Let the mount chain settle: the initial-load rAFs, the scroller's 100 ms measure pass, and the
 * trailing pre-paint sweep. Row heights are re-mocked between waits because the rendered window
 * changes as the model converges. */
async function settleScroller(container: HTMLElement): Promise<void> {
  for (let i = 0; i < 6; i++) {
    mockRowHeights(container)
    await new Promise((r) => setTimeout(r, 60))
    await nextTick()
  }
}

describe('ChatView — reopening a chat lands where the reader left it', () => {
  let wrapper: VueWrapper | null = null

  beforeEach(() => {
    if (typeof localStorage === 'undefined' || typeof localStorage.getItem !== 'function') {
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
      } as Storage)
    } else {
      localStorage.clear()
    }
    setActivePinia(createPinia())
  })

  afterEach(() => {
    wrapper?.unmount()
    wrapper = null
    vi.restoreAllMocks()
  })

  it('restores the saved position, not the estimated bottom', async () => {
    // The reader closed the chat at 9000px of a 19200px transcript.
    localStorage.setItem('chat-scroll-task_resume', String(SAVED_POSITION))
    installApiMocks()

    wrapper = await mountChatView('task_resume')
    const container = findScrollerContainer(wrapper)

    // Before any measurement the model is pure estimate — this is the state the
    // restore used to run against, and the reason it landed wrong.
    expect(container.scrollHeight).toBe(ESTIMATED_TOTAL)
    expect(ESTIMATED_BOTTOM).toBeLessThan(SAVED_POSITION)

    await settleScroller(container)

    // The reader must be where they left off. The measured transcript is
    // 19200px tall, so 9000 is reachable and unambiguous.
    expect(container.scrollHeight).toBe(REAL_TOTAL)
    expect(container.scrollTop).toBe(SAVED_POSITION)
  })

  it('the measured transcript really is taller than the estimate (the precondition)', async () => {
    // Without this the test above could pass vacuously — if the estimate and
    // the measurement agreed there would be no gap for the restore to fall
    // into. This is the positive control.
    installApiMocks()
    wrapper = await mountChatView('task_precondition')
    const container = findScrollerContainer(wrapper)

    // Pure estimate, straight off the mount.
    expect(container.scrollHeight).toBe(ESTIMATED_TOTAL)

    await settleScroller(container)

    // Measured: the model converged on the real rows.
    expect(container.scrollHeight).toBe(REAL_TOTAL)
    expect(REAL_BOTTOM).toBeGreaterThan(ESTIMATED_BOTTOM)
  })

  it('a reader who closed on the last message still lands on the last message', async () => {
    // The other half of the contract: the "near bottom" branch must keep working, and it must now
    // be judged against the MEASURED bottom.
    // A save at the real bottom is above the estimated bottom, so the old code read it as "scrolled
    // up" and restored a stale position instead of following the tail.
    localStorage.setItem('chat-scroll-task_tail', String(REAL_BOTTOM))
    installApiMocks()

    wrapper = await mountChatView('task_tail')
    const container = findScrollerContainer(wrapper)
    await settleScroller(container)

    expect(container.scrollTop).toBe(REAL_BOTTOM)
  })

  it('a first-time visitor with nothing saved still lands at the bottom', async () => {
    // The wait must be gated on there being something to restore. A reader with
    // no saved position should not sit through it — and must not be parked at
    // the top of an unmeasured scroller while it runs.
    installApiMocks()

    wrapper = await mountChatView('task_fresh')
    const container = findScrollerContainer(wrapper)
    await settleScroller(container)

    // Nothing was stored before this mount, so the restore path was skipped
    // entirely and the initial-load branch went straight to the bottom.
    expect(container.scrollTop).toBe(REAL_BOTTOM)
  })
})
