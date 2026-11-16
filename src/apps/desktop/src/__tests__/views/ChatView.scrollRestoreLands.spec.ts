/** "resume scroll why not match with user expectation? — it's always a bit on top" The reader closes a chat mid-transcript, reopens the same task, and lands ABOVE … */
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest'
import { setActivePinia, createPinia } from 'pinia'
import { nextTick } from 'vue'
import { mount, type VueWrapper } from '@vue/test-utils'
import { Effect } from 'effect'

import * as api from '../../api'
import ChatView from '../../components/views/ChatView.vue'

// ── The hoisted api mock ────────────────────────────────────────────────────
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

/** jsdom has no layout, so `scrollHeight` is whatever we say. */
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
    selectedAgent: null,
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

/** Give every rendered row a real, uniform height. */
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
  // The scroller's mount gate is `!isInitializing && (isLoading || messageGroups.length > 0)`, and `isInitializing` only clears once the history load settles — so …
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

/** Let the mount chain settle: the initial-load rAFs, the scroller's 100 ms measure pass, and the trailing pre-paint sweep. */
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

    // Before any measurement the model is pure estimate — this is the state the restore used to run against, and the reason it landed wrong.
    expect(container.scrollHeight).toBe(ESTIMATED_TOTAL)
    expect(ESTIMATED_BOTTOM).toBeLessThan(SAVED_POSITION)

    await settleScroller(container)

    // The reader must be where they left off.
    expect(container.scrollHeight).toBe(REAL_TOTAL)
    expect(container.scrollTop).toBe(SAVED_POSITION)
  })

  it('the measured transcript really is taller than the estimate (the precondition)', async () => {
    // Without this the test above could pass vacuously — if the estimate and the measurement agreed there would be no gap for the restore to fall into.
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
    // The other half of the contract: the "near bottom" branch must keep working, and it must now be judged against the MEASURED bottom.
    localStorage.setItem('chat-scroll-task_tail', String(REAL_BOTTOM))
    installApiMocks()

    wrapper = await mountChatView('task_tail')
    const container = findScrollerContainer(wrapper)
    await settleScroller(container)

    expect(container.scrollTop).toBe(REAL_BOTTOM)
  })

  it('restores the saved position for a host that prefixes the chat id with `chat-`', async () => {
    // StandardTaskChatView and AppLayout's standalone branch both pass `chat-<sessionId>`; the kanban branch passes the bare id.
    localStorage.setItem('chat-scroll-task_prefixed', String(SAVED_POSITION))
    installApiMocks()

    wrapper = await mountChatView('chat-task_prefixed')
    const container = findScrollerContainer(wrapper)
    await settleScroller(container)

    expect(container.scrollTop).toBe(SAVED_POSITION)
  })

  it('a first-time visitor with nothing saved still lands at the bottom', async () => {
    // The wait must be gated on there being something to restore.
    installApiMocks()

    wrapper = await mountChatView('task_fresh')
    const container = findScrollerContainer(wrapper)
    await settleScroller(container)

    // Nothing was stored before this mount, so the restore path was skipped entirely and the initial-load branch went straight to the bottom.
    expect(container.scrollTop).toBe(REAL_BOTTOM)
  })
})
