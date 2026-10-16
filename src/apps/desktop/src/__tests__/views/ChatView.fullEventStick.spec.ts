/** Regression tests for the reported bug: "Chatview has issue if sse send a llm chunk and llm full
 * data finish reason stop, its like automatically go to bottom scrollbar chatview". ── Why this
 * file exists ──────────────────────────────────────────────────── 1. COVERAGE GAP. */
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest'
import { setActivePinia, createPinia } from 'pinia'
import { createApp, nextTick, ref, type App as VueApp, type Ref } from 'vue'
import { mount, type VueWrapper } from '@vue/test-utils'
import { Effect } from 'effect'

import * as api from '../../api'
import ChatView from '../../components/views/ChatView.vue'
import {
  installSseBus,
  __resetSseBus,
  __setSseBusGlobalClient,
  __dispatchSseBus,
} from '../../helpers/sseBus'
import type { SseClient, SseState, SseStateInfo } from '../../helpers/sseClient'

// ── The hoisted api mock (see "THE MOCK SEAM" above) ───────────────────────
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
    // For `chatEngineDb`'s captured fetchFn (cache prime + delta).
    getChatHistory: () => Promise.resolve(historyResponse()),
    // For ChatView's own authoritative network load.
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

// jsdom does not implement HTMLElement.prototype.scrollTo — polyfill a real
// implementation so scrollToBottom observably moves scrollTop.
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

// No layout in jsdom: every element reports these, so the transcript is
// scrollable from mount and the bottom is a fixed, known number.
const TOTAL_HEIGHT = 20000
const VIEWPORT = 800
const BOTTOM = TOTAL_HEIGHT - VIEWPORT

Object.defineProperty(HTMLElement.prototype, 'scrollHeight', {
  configurable: true,
  get(): number {
    return TOTAL_HEIGHT
  },
})
Object.defineProperty(HTMLElement.prototype, 'clientHeight', {
  configurable: true,
  get(): number {
    return VIEWPORT
  },
})

function makeStubClient(initial: SseState): SseClient {
  // eslint-disable-next-line @typescript-eslint/no-explicit-any
  const stub: any = {
    close: vi.fn(),
    reconnect: vi.fn(),
    getState: () => stub._state,
    onStateChange: (_cb: (s: SseState, _info: SseStateInfo) => void) => () => {},
  }
  stub._state = initial
  return stub as SseClient
}

function installApiMocks(): void {
  historyRows.length = 0
  for (let i = 0; i < 100; i++) {
    historyRows.push({
      id: `msg_${i}`,
      role: 'user',
      content: `Message ${i}`,
      created_at: i,
      image_url: '',
      finish_reason: '',
    })
  }
  // eslint-disable-next-line @typescript-eslint/no-explicit-any
  vi.spyOn(api, 'getStreamSnapshot').mockResolvedValue({ active: false, content: '' } as any)
  // eslint-disable-next-line @typescript-eslint/no-explicit-any
  vi.spyOn(api, 'getQueuedMessages').mockResolvedValue({ messages: [], count: 0 } as any)
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

async function mountChatView(
  chatId: string,
  processingState: Ref<Record<string, boolean>>,
): Promise<VueWrapper> {
  const wrapper = mount(ChatView, {
    props: { chatId, chatName: 'Test Chat' },
    attachTo: document.body,
    global: { provide: { processingState } },
  })
  // Wait for the transcript to paint. The mount gate is `!isInitializing && (isLoading ||
  // messageGroups.length > 0)` on the <VirtualScroller>, and `isInitializing` only clears once the
  // history load settles — so the scroller's presence IS the load-completed signal.
  for (let i = 0; i < 60; i++) {
    await new Promise((r) => setTimeout(r, 40))
    await nextTick()
    if (wrapper.find('.virtual-scroller').exists()) break
  }
  // Let mount-time timers (VirtualScroller measure, loadMore debounce,
  // initial-load rAFs) flush so the scenario starts clean.
  await new Promise((r) => setTimeout(r, 400))
  await nextTick()
  return wrapper
}

function findScrollerContainer(wrapper: VueWrapper): HTMLElement {
  const el = wrapper.find('.virtual-scroller')
  if (!el.exists()) throw new Error('.virtual-scroller not mounted — history load never settled')
  return el.element as HTMLElement
}

/** Dispatch a user scroll gesture on the scroller container. */
async function userScrollTo(container: HTMLElement, top: number): Promise<void> {
  container.scrollTop = top
  container.dispatchEvent(new Event('scroll'))
  await nextTick()
  await new Promise((r) => setTimeout(r, 300))
  await nextTick()
}

/** The real ChatView registers `bus.on('llm', …)` on mount; this injects. */
function emitLlm(payload: Record<string, unknown>): void {
  // eslint-disable-next-line @typescript-eslint/no-explicit-any
  __dispatchSseBus('llm', payload as any)
}

/** Let the chunk handler's rAF coalesce + the full handler's nextTick land. */
async function settle(): Promise<void> {
  await new Promise((r) => setTimeout(r, 300))
  await nextTick()
}

describe('ChatView — llm_chunk then llm_full(finish_reason=stop) auto-scroll', () => {
  let wrapper: VueWrapper | null = null
  let app: VueApp | null = null
  const processingState = ref<Record<string, boolean>>({})

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

  it('scrolled-up reader is not yanked to bottom by chunk → full(stop)', async () => {
    installApiMocks()
    wrapper = await mountChatView('task_full_stick_up', processingState)
    const container = findScrollerContainer(wrapper)

    // Initial load lands at the bottom.
    expect(container.scrollTop).toBe(BOTTOM)

    // The reader scrolls up to read history while the turn is in flight.
    await userScrollTo(container, 5000)
    expect(container.scrollTop).toBe(5000)

    // llm_chunk — the streaming row appears below the viewport.
    emitLlm({
      type: 'chunk',
      session_id: 'task_full_stick_up',
      role: 'assistant',
      content: 'Here is a long streamed answer that arrives below the fold. ',
    })
    await settle()
    expect(container.scrollTop).toBe(5000)

    // llm_full with finish_reason=stop — the streaming row is swapped for
    // the canonical DB row. This is the reported trigger.
    emitLlm({
      type: 'full',
      session_id: 'task_full_stick_up',
      id: 'db_row_final',
      role: 'assistant',
      content: 'Here is a long streamed answer that arrives below the fold. Done.',
      finish_reason: 'stop',
    })
    await settle()

    // The reading position must be untouched.
    expect(container.scrollTop).toBe(5000)
  })

  it('at-bottom reader still follows chunk → full(stop)', async () => {
    installApiMocks()
    wrapper = await mountChatView('task_full_stick_bottom', processingState)
    const container = findScrollerContainer(wrapper)
    expect(container.scrollTop).toBe(BOTTOM)

    emitLlm({
      type: 'chunk',
      session_id: 'task_full_stick_bottom',
      role: 'assistant',
      content: 'streamed body',
    })
    await settle()

    emitLlm({
      type: 'full',
      session_id: 'task_full_stick_bottom',
      id: 'db_row_final',
      role: 'assistant',
      content: 'streamed body, finished',
      finish_reason: 'stop',
    })
    await settle()

    // The stick must survive — over-correcting into "never auto-scroll" is
    // the opposite failure.
    expect(container.scrollTop).toBe(BOTTOM)
  })
})
