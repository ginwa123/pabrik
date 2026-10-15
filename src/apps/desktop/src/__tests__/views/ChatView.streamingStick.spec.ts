/**
 * Regression tests for the "yank-to-bottom while reading during streaming"
 * bug (video report: user scrolls up to read history while the run is still
 * streaming — Stop button visible — and the viewport snaps back to the
 * bottom on every new chunk).
 *
 * Contract under test (ChatView.vue):
 *   - `onContentShift` re-sticks to the bottom ONLY when `isAtBottom` is
 *     true. A user who scrolled up (`isAtBottom == false`) must never be
 *     yanked down by tail growth below their viewport.
 *   - Conversely, a user who IS at the bottom must keep following the tail
 *     (the stick still works — guards against over-correcting the fix).
 *
 * How the scenario is simulated in jsdom (no layout):
 *   - Prototype-level scrollHeight=20000 / clientHeight=800 (same as
 *     ChatView.scrollRestore.spec.ts) makes a 100-message chat scrollable.
 *   - A user scroll-up is a real `scroll` event dispatched on the
 *     `.virtual-scroller` container with a lower scrollTop.
 *   - Tail growth (an SSE chunk / completed tool card landing below the
 *     viewport) is simulated by raising the container's scrollHeight and
 *     emitting `content-shift` from the VirtualScroller child — the exact
 *     event the scroller emits when its measured total grows.
 *
 * ⛔  WHY THIS FILE USES A `vi.mock` MODULE FACTORY, NOT `vi.spyOn`
 *
 * This spec was dead: it mocked `api.getChatHistory` with `vi.spyOn`, which no
 * longer reaches ChatView's history load, so `.virtual-scroller` never mounted
 * and BOTH tests failed with ".virtual-scroller not mounted" — on every run,
 * in CI and locally, since the `chatEngineDb` refactor. The symptom class this
 * file guards therefore had no working guard at all.
 *
 * There are TWO seams, and both must be a hoisted module mock:
 *   1. `chatEngineDb` (`sync/ChatEngineDb.ts`) drives the cache prime and the
 *      delta. Its constructor is
 *        `constructor(private fetchFn: typeof getChatHistory = getChatHistory)`
 *      and that default is bound ONCE, when `new ChatEngineDb()` runs at module
 *      load — a `vi.spyOn` installed later replaces the property on the api
 *      module object but does NOT rebind the already-captured `fetchFn`.
 *   2. `api.fetchChatHistoryEffect(...)` is called DIRECTLY by ChatView for the
 *      authoritative network load in `runHistoryLoadAttempt`. Mocking only (1)
 *      leaves (2) hitting the real network: the fetch fails in jsdom, the retry
 *      loop keeps `isLoading` true, `isInitializing` never clears, and the
 *      `<VirtualScroller>` (gated on `!isInitializing && …`) never renders.
 *
 * `vi.mock` IS hoisted above the module graph, so `chatEngineDb`'s captured
 * `fetchFn` resolves to the mock. That is the only seam that works.
 */
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest'
import { setActivePinia, createPinia } from 'pinia'
import { createApp, nextTick, type App as VueApp } from 'vue'
import { mount, type VueWrapper } from '@vue/test-utils'
import { Effect } from 'effect'

import * as api from '../../api'
import ChatView from '../../components/views/ChatView.vue'
import VirtualScroller from '../../helpers/VirtualScroller.vue'

// ── The hoisted api mock (see "WHY THIS FILE USES A vi.mock MODULE FACTORY") ──
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
import { installSseBus, __resetSseBus, __setSseBusGlobalClient } from '../../helpers/sseBus'
import type { SseClient, SseState, SseStateInfo } from '../../helpers/sseClient'

// ChatView calls useRoute()/useRouter() on mount (URL param sync). In jsdom
// there is no router — stub the pair (same pattern as
// AppLayout.chatview.spec.ts).
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

// jsdom 29 does NOT implement HTMLElement.prototype.scrollTo — polyfill a
// real implementation so scrollToBottom / scrollToPosition observably move
// scrollTop (same polyfill as ChatView.scrollRestore.spec.ts).
if (
  typeof (globalThis as { HTMLElement?: { prototype: { scrollTo?: unknown } } }).HTMLElement
    ?.prototype.scrollTo === 'undefined'
) {
  ;(
    globalThis as unknown as { HTMLElement: { prototype: { scrollTo: (arg: unknown) => void } } }
  ).HTMLElement.prototype.scrollTo = function (arg: unknown) {
    if (typeof arg === 'number') {
      ;(this as HTMLElement).scrollTop = arg
      return
    }
    if (arg && typeof arg === 'object' && 'top' in arg) {
      const top = (arg as { top?: number }).top
      if (typeof top === 'number') {
        ;(this as HTMLElement).scrollTop = top
      }
    }
  }
}

// No layout in jsdom: every element reports a 20000px scrollHeight against
// an 800px viewport, so the 100-message chat is scrollable from mount.
Object.defineProperty(HTMLElement.prototype, 'scrollHeight', {
  configurable: true,
  get(): number {
    return 20000
  },
})
Object.defineProperty(HTMLElement.prototype, 'clientHeight', {
  configurable: true,
  get(): number {
    return 800
  },
})

function makeStubClient(initial: SseState): SseClient {
  // eslint-disable-next-line @typescript-eslint/no-explicit-any
  const stub: any = {
    close: vi.fn(),
    reconnect: vi.fn(),
    getState: () => stub._state,
    onStateChange: (_cb: (s: SseState, _info: SseStateInfo) => void) => {
      return () => {}
    },
  }
  stub._state = initial
  return stub as SseClient
}

function installApiMocks(): void {
  historyRows.length = 0
  for (let i = 0; i < 100; i++) {
    historyRows.push({
      id: `msg_${i}`,
      role: 'user' as const,
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
  vi.spyOn(api, 'getPabrikConfig').mockResolvedValue({
    profiles: {},
    // eslint-disable-next-line @typescript-eslint/no-explicit-any
  } as any)
}

async function mountChatView(chatId: string): Promise<VueWrapper> {
  const wrapper = mount(ChatView, {
    props: { chatId, chatName: 'Test Chat' },
    attachTo: document.body,
  })
  // Wait for the transcript to paint. The scroller's mount gate is
  // `!isInitializing && (isLoading || messageGroups.length > 0)`, and
  // `isInitializing` only clears once the history load settles — so the
  // scroller's presence IS the load-completed signal, and keying the wait on it
  // turns a silent "never rendered" into the one error that explains it.
  for (let i = 0; i < 60; i++) {
    await new Promise((r) => setTimeout(r, 40))
    await nextTick()
    if (wrapper.find('.virtual-scroller').exists()) break
  }
  // Let mount-time timers (VirtualScroller 100ms measure, loadMore 200ms
  // debounce, initial-load rAFs) flush so the scenario starts clean.
  await new Promise((r) => setTimeout(r, 400))
  await nextTick()
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

/** Dispatch a user scroll gesture on the scroller container. */
async function userScrollTo(container: HTMLElement, top: number): Promise<void> {
  container.scrollTop = top
  container.dispatchEvent(new Event('scroll'))
  await nextTick()
  // Flush the scroller's 200ms loadMore debounce (has_more=false in the
  // mock, so it suppresses without mutating — but let it settle anyway).
  await new Promise((r) => setTimeout(r, 300))
  await nextTick()
}

/**  * Simulate tail growth below the viewport (an SSE chunk / tool card landing while the user reads):
 * raise scrollHeight, then emit the exact event VirtualScroller fires when its measured total
 * grows. */
async function growTail(
  wrapper: VueWrapper,
  container: HTMLElement,
  grownHeight: number,
): Promise<void> {
  Object.defineProperty(container, 'scrollHeight', {
    configurable: true,
    get(): number {
      return grownHeight
    },
  })
  const scroller = wrapper.findComponent(VirtualScroller)
  if (!scroller.exists()) throw new Error('VirtualScroller child not found')
  scroller.vm.$emit('content-shift', { topSpacer: 0, bottomSpacer: 0, total: grownHeight })
  // onContentShift debounces through requestAnimationFrame — let it land.
  await new Promise((r) => setTimeout(r, 150))
  await nextTick()
}

describe('ChatView — no yank-to-bottom while reading during streaming', () => {
  let wrapper: VueWrapper | null = null
  let app: VueApp | null = null

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

    __resetSseBus()
    app = createApp({})
    installSseBus(app)
    __setSseBusGlobalClient(makeStubClient('connecting'))
  })

  afterEach(() => {
    wrapper?.unmount()
    wrapper = null
    __resetSseBus()
    app = null
    vi.restoreAllMocks()
  })

  it('scrolled-up reader + tail growth below the viewport does NOT yank to bottom', async () => {
    installApiMocks()
    wrapper = await mountChatView('task_streaming_stick_up')

    const container = findScrollerContainer(wrapper)
    // Initial load lands at the bottom (20000 - 800).
    expect(container.scrollTop).toBe(20000 - 800)

    // The user scrolls up to read history (the video scenario: run still
    // streaming, Stop button visible).
    await userScrollTo(container, 5000)
    expect(container.scrollTop).toBe(5000)

    // A chunk lands below the viewport: +6000px of tail growth.
    await growTail(wrapper, container, 26000)

    // The reading position must be untouched — no stick, no yank.
    expect(container.scrollTop).toBe(5000)
  })

  it('at-bottom reader + tail growth still follows the tail (stick intact)', async () => {
    installApiMocks()
    wrapper = await mountChatView('task_streaming_stick_bottom')

    const container = findScrollerContainer(wrapper)
    expect(container.scrollTop).toBe(20000 - 800)

    // Growth while pinned at the bottom must re-stick to the new bottom.
    await growTail(wrapper, container, 26000)

    expect(container.scrollTop).toBe(26000 - 800)
  })
})
