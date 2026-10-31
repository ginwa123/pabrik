/** ChatView git-status cache-first paint (stale-while-revalidate). Contract under test: 1. On
 * init/cwd-switch, `checkGitStatus` paints the persisted localStorage entry SYNCHRONOUSLY — the
 * bottom chip shows the last-known branch while `api.getGitStatus` is still in flight. 2. */
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest'
import { setActivePinia, createPinia } from 'pinia'
import { createApp, nextTick, type App as VueApp } from 'vue'
import { mount, type VueWrapper } from '@vue/test-utils'
import { Effect } from 'effect'

import * as api from '../api'
import ChatView from '../components/views/ChatView.vue'
import { writeGitStatusCache, clearGitStatusCache } from '../helpers/gitStatusCache'
import { installSseBus, __resetSseBus, __setSseBusGlobalClient } from '../helpers/sseBus'
import type { SseClient, SseState, SseStateInfo } from '../helpers/sseClient'

// ChatView calls useRoute()/useRouter() on mount (URL param sync). In jsdom
// there is no router — stub the pair (same pattern as
// ChatView.streamingStick.spec.ts).
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

const CWD = '/tmp/main-repo'
const CHIP = '[data-testid="worktree-status-button"]'

const CACHED: api.GitStatus = {
  is_git_repo: true,
  branch: 'cached-branch',
  has_changes: false,
  is_clean: true,
  current: 'cached-branch',
  status: 'clean',
}

const FRESH: api.GitStatus = {
  is_git_repo: true,
  branch: 'fresh-branch',
  has_changes: true,
  is_clean: false,
  current: 'fresh-branch',
  status: 'modified',
}

// Inert global SSE stub — same shape as chatViewWorktree.spec.ts.
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

function installChatViewMocks(): void {
  const history = {
    messages: [],
    has_more: false,
    next_cursor: null,
    cwd: CWD,
    git_worktree_cwd: '',
    max_total_tokens: 0,
    max_capacity_total_tokens: 0,
  }
  // ChatView's mount loads through `fetchChatHistoryEffect`; `getChatHistory` alone never reaches
  // it, so the mount stalled on a 404 and never reached `startGitStatusPoll()`.
  vi.spyOn(api, 'fetchChatHistoryEffect').mockReturnValue(Effect.succeed(history))
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
  // eslint-disable-next-line @typescript-eslint/no-explicit-any
  vi.spyOn(api, 'getPabrikConfig').mockResolvedValue({ profiles: {} } as any)
}

async function mountChatView(chatId = 'session_test'): Promise<VueWrapper> {
  const wrapper = mount(ChatView, {
    props: { chatId, chatName: 'Test Chat' },
    attachTo: document.body,
  })
  // onMounted is async: loadChatHistory → connectSse → startGitStatusPoll.
  // Wait until connectSse has flipped isStreaming (earliest synchronous
  // signal that the init chain reached the git-status poll).
  for (let i = 0; i < 20; i++) {
    await new Promise((r) => setTimeout(r, 0))
    await nextTick()
    const streaming = (wrapper.vm as unknown as { isStreaming?: boolean }).isStreaming
    if (streaming) break
  }
  await nextTick()
  return wrapper
}

/** Flush a few macrotask + microtask rounds so deferred fetches settle. */
async function flush(times = 5): Promise<void> {
  for (let i = 0; i < times; i++) {
    await new Promise((r) => setTimeout(r, 0))
    await nextTick()
  }
}

describe('ChatView git-status cache-first paint', () => {
  let wrapper: VueWrapper | null = null
  let app: VueApp | null = null

  beforeEach(() => {
    // See chatViewWorktree.spec.ts: some jsdom setups ship without a
    // usable localStorage — install an in-memory stand-in.
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
    clearGitStatusCache(CWD)
    vi.restoreAllMocks()
    vi.unstubAllGlobals()
  })

  it('paints the cached status before the network fetch resolves, then overwrites with fresh', async () => {
    writeGitStatusCache(CWD, CACHED)
    installChatViewMocks()

    // Deferred fetch: stays pending until the test resolves it, so the
    // chip can only be showing the CACHE during the first assertion.
    let resolveFetch!: (s: api.GitStatus) => void
    const pending = new Promise<api.GitStatus>((resolve) => {
      resolveFetch = resolve
    })
    vi.spyOn(api, 'getGitStatus').mockReturnValue(pending)

    wrapper = await mountChatView('session_swr')

    // Phase 1 — cache painted, network still in flight.
    const chip = wrapper.find(CHIP)
    expect(chip.exists()).toBe(true)
    expect(chip.text()).toContain('cached-branch')
    expect(api.getGitStatus).toHaveBeenCalledWith(CWD)

    // Phase 2 — background fetch answers; fresh wins over cache.
    resolveFetch(FRESH)
    await flush()
    expect(wrapper.find(CHIP).text()).toContain('fresh-branch')
    expect(wrapper.find(CHIP).text()).not.toContain('cached-branch')
  })

  it('keeps the chip hidden on a cache miss until the fetch resolves', async () => {
    // No writeGitStatusCache — cold start for this cwd.
    installChatViewMocks()

    let resolveFetch!: (s: api.GitStatus) => void
    const pending = new Promise<api.GitStatus>((resolve) => {
      resolveFetch = resolve
    })
    vi.spyOn(api, 'getGitStatus').mockReturnValue(pending)

    wrapper = await mountChatView('session_cold')

    // Nothing cached → v-if gate (gitStatus === null) keeps the chip
    // out; no stale/incorrect branch is ever flashed.
    expect(wrapper.find(CHIP).exists()).toBe(false)

    resolveFetch(FRESH)
    await flush()
    expect(wrapper.find(CHIP).text()).toContain('fresh-branch')
  })

  it('does not repaint the cache over a newer in-memory value on a same-cwd refresh', async () => {
    writeGitStatusCache(CWD, CACHED)
    installChatViewMocks()

    // First fetch answers with FRESH and (via getGitStatus's write-through)
    // would normally refresh the cache too — here we rewrite the cache
    // behind ChatView's back afterwards to simulate a stale entry.
    const spy = vi.spyOn(api, 'getGitStatus').mockResolvedValue(FRESH)

    wrapper = await mountChatView('session_no_regress')
    await flush()
    expect(wrapper.find(CHIP).text()).toContain('fresh-branch')

    writeGitStatusCache(CWD, CACHED)

    // Real user path: chip → "Refresh status" → checkGitStatus(). Hold the fetch pending so only
    // the synchronous paint can change the chip. The gitStatusCwd gate must skip the localStorage
    // read — if it didn't, the chip would flip back to 'cached-branch' here.
    let resolveFetch!: (s: api.GitStatus) => void
    const pending = new Promise<api.GitStatus>((resolve) => {
      resolveFetch = resolve
    })
    spy.mockReturnValue(pending)

    const chip = wrapper.find(CHIP)
    await chip.trigger('click')
    await nextTick()
    await nextTick()
    const refreshItem = wrapper.find('[data-testid="worktree-menu-refresh"]')
    expect(refreshItem.exists()).toBe(true)
    await refreshItem.trigger('click')
    await flush()

    expect(wrapper.find(CHIP).text()).toContain('fresh-branch')
    expect(wrapper.find(CHIP).text()).not.toContain('cached-branch')

    resolveFetch(FRESH)
    await flush()
    expect(wrapper.find(CHIP).text()).toContain('fresh-branch')
  })
})
