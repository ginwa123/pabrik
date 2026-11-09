/** The chat names the agent that answers: the composer chip and the transcript
 * badge both follow the backend's `selected → active_profile → top-level`
 * cascade, where a name that is not a configured profile is a miss. */
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest'
import { setActivePinia, createPinia } from 'pinia'
import { createApp, nextTick, type App as VueApp } from 'vue'
import { mount, type VueWrapper } from '@vue/test-utils'
import { Effect } from 'effect'

import * as api from '../api'
import ChatView from '../components/views/ChatView.vue'
import { useChatViewStore } from '../stores/chatView'
import { installSseBus, __resetSseBus, __setSseBusGlobalClient } from '../helpers/sseBus'
import type { SseClient, SseState, SseStateInfo } from '../helpers/sseClient'
import { makeLocalStorageStub } from './helpers'

const { useRouteMock, useRouterMock } = vi.hoisted(() => ({
  useRouteMock: vi.fn(() => ({
    query: {} as Record<string, string>,
    params: {} as Record<string, string>,
    path: '/app',
    fullPath: '/app',
  })),
  useRouterMock: vi.fn(() => ({ replace: vi.fn(), push: vi.fn(), back: vi.fn() })),
}))

vi.mock('vue-router', async () => {
  const actual = await vi.importActual<typeof import('vue-router')>('vue-router')
  return { ...actual, useRouter: useRouterMock, useRoute: useRouteMock }
})

const SESSION_ID = 's_agent_identity'

const ROWS = [
  { id: 'u1', role: 'user', content: 'hai', created_at: 1_700_000_001 },
  { id: 'a1', role: 'assistant', content: 'Halo!', created_at: 1_700_000_002 },
]

const PAGE = {
  has_more: false,
  next_cursor: null,
  cwd: '/tmp/work',
  git_worktree_cwd: '',
  max_total_tokens: 0,
  max_capacity_total_tokens: 0,
  skills: [] as unknown[],
  messages: ROWS,
}

vi.mock('../api', async (importOriginal) => {
  const actual = await importOriginal<typeof import('../api')>()
  return {
    ...actual,
    getChatHistory: () => Promise.resolve(PAGE),
    fetchChatHistoryEffect: () => Effect.succeed(PAGE),
  }
})

function makeStubClient(): SseClient {
  // eslint-disable-next-line @typescript-eslint/no-explicit-any
  const stub: any = {
    close: vi.fn(),
    reconnect: vi.fn(),
    getState: () => 'connecting' as SseState,
    onStateChange: (_cb: (s: SseState, _info: SseStateInfo) => void) => () => {},
  }
  return stub as SseClient
}

/** The workspace config: one live profile, and `alpha` marked active. */
const CONFIG = {
  profiles: { alpha: { model: 'm-1', base_url: 'http://x', url_style: 'openai' } },
  active_profile: 'alpha',
}

function installMocks(storedProfile: string | null): void {
  /* eslint-disable @typescript-eslint/no-explicit-any */
  vi.spyOn(api, 'getQueuedMessages').mockResolvedValue({ messages: [] } as any)
  vi.spyOn(api, 'getSession').mockResolvedValue({
    session_id: SESSION_ID,
    session_name: '',
    selectedAgent: storedProfile,
    subAgentName: '',
    cwd: '/tmp/work',
    git_worktree_cwd: '',
  } as any)
  vi.spyOn(api, 'getGitStatus').mockResolvedValue({
    is_git_repo: false,
    branch: '',
    status: 'clean',
    is_clean: true,
  } as any)
  vi.spyOn(api, 'getPabrikConfig').mockResolvedValue(CONFIG as any)
  vi.spyOn(api, 'getWorkspaceConfig').mockResolvedValue(CONFIG as any)
  vi.spyOn(api, 'getStreamSnapshot').mockResolvedValue({ active: false, content: '' } as any)
  /* eslint-enable @typescript-eslint/no-explicit-any */
}

async function waitFor(predicate: () => boolean, tries = 120): Promise<void> {
  for (let i = 0; i < tries; i++) {
    if (predicate()) return
    await new Promise((r) => setTimeout(r, 10))
    await nextTick()
  }
}

describe('ChatView — the chat names the agent that answers', () => {
  let wrapper: VueWrapper | null = null
  let app: VueApp | null = null

  beforeEach(() => {
    if (typeof localStorage === 'undefined' || typeof localStorage.getItem !== 'function') {
      Object.defineProperty(globalThis, 'localStorage', {
        value: makeLocalStorageStub(),
        writable: true,
        configurable: true,
      })
    } else {
      localStorage.clear()
    }
    if (typeof HTMLElement.prototype.scrollTo === 'undefined') {
      HTMLElement.prototype.scrollTo = function () {
        /* jsdom has no layout */
      }
    }
    setActivePinia(createPinia())
    useChatViewStore().setMode('dev')
    __resetSseBus()
    app = createApp({})
    installSseBus(app)
    __setSseBusGlobalClient(makeStubClient())
  })

  afterEach(() => {
    wrapper?.unmount()
    wrapper = null
    __resetSseBus()
    app = null
    vi.restoreAllMocks()
  })

  async function mountChat(storedProfile: string | null): Promise<VueWrapper> {
    installMocks(storedProfile)
    wrapper = mount(ChatView, {
      props: { chatId: SESSION_ID, chatName: 'Agent identity' },
      attachTo: document.body,
    })
    await waitFor(() => wrapper!.findAll('[data-group-key]').length > 0)
    await waitFor(() => wrapper!.find('[data-testid="composer-agent-chip"]').exists())
    return wrapper
  }

  it('names the active profile in the composer when the session stored none', async () => {
    const w = await mountChat(null)

    const chip = w.find('[data-testid="composer-agent-chip"]')
    expect(chip.text()).toBe('alpha')
    expect(chip.attributes('title')).toMatch(/active agent/i)
  })

  it('credits the reply to the active profile when the session stored none', async () => {
    const w = await mountChat(null)

    expect(w.find('.msg-author-name').text()).toBe('alpha')
  })

  it('falls through a stored profile that is no longer configured', async () => {
    const w = await mountChat('space')

    expect(w.find('[data-testid="composer-agent-chip"]').text()).toBe('alpha')
    expect(w.find('.msg-author-name').text()).toBe('alpha')
  })

  it('names the stored profile when it is still configured', async () => {
    const w = await mountChat('alpha')

    expect(w.find('[data-testid="composer-agent-chip"]').text()).toBe('alpha')
    expect(w.find('.msg-author-name').text()).toBe('alpha')
  })
})
