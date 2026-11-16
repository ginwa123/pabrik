/** "Agents in this chat" offers the agents the chat is NOT running yet — in the tab-strip app bar as much as in the plain one. */
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

const SESSION_ID = 's_roster_agents'
const LEAD = 'Simple Engineer'
const OWN = 'deepseek auto'
const THIRD = 'BEAM'

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
  skills: [],
  messages: ROWS,
}

vi.mock('../api', async (importOriginal) => {
  const actual = await importOriginal<typeof import('../api')>()
  return {
    ...actual,
    getChatHistory: () => Promise.resolve(PAGE as never),
    fetchChatHistoryEffect: () => Effect.succeed(PAGE as never),
  }
})

function makeStubClient(): SseClient {
  const stub = {
    close: vi.fn(),
    reconnect: vi.fn(),
    getState: () => 'connecting' as SseState,
    onStateChange: (_cb: (s: SseState, _info: SseStateInfo) => void) => () => {},
  }
  return stub as never
}

const CONFIG = {
  profiles: {
    [LEAD]: { model: 'm-1', base_url: 'http://x', url_style: 'openai' },
    [OWN]: { model: 'm-2', base_url: 'http://x', url_style: 'openai' },
    [THIRD]: { model: 'm-3', base_url: 'http://x', url_style: 'openai' },
  },
  active_profile: OWN,
}

const ROSTER = {
  session_id: SESSION_ID,
  group: true,
  lead: LEAD,
  members: [{ name: LEAD, role: 'lead' as const }],
}

function installMocks(): void {
  vi.spyOn(api, 'getQueuedMessages').mockResolvedValue({ messages: [] } as never)
  vi.spyOn(api, 'getSession').mockResolvedValue({
    session_id: SESSION_ID,
    session_name: '',
    selectedAgent: null,
    subAgentName: '',
    cwd: '/tmp/work',
    git_worktree_cwd: '',
  } as never)
  vi.spyOn(api, 'getGitStatus').mockResolvedValue({
    is_git_repo: false,
    branch: '',
    status: 'clean',
    is_clean: true,
  } as never)
  vi.spyOn(api, 'getPabrikConfig').mockResolvedValue(CONFIG as never)
  vi.spyOn(api, 'getWorkspaceConfig').mockResolvedValue(CONFIG as never)
  vi.spyOn(api, 'getStreamSnapshot').mockResolvedValue({ active: false, content: '' } as never)
  vi.spyOn(api, 'getSessionGroup').mockResolvedValue(ROSTER as never)
}

async function waitFor(predicate: () => boolean, tries = 120): Promise<void> {
  for (let i = 0; i < tries; i++) {
    if (predicate()) return
    await new Promise((r) => setTimeout(r, 10))
    await nextTick()
  }
}

describe('ChatView — the roster panel offers the agents the chat is not running', () => {
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

  async function mountChat(): Promise<VueWrapper> {
    installMocks()
    wrapper = mount(ChatView, {
      props: { chatId: SESSION_ID, chatName: 'Roster agents', showHeader: true },
      attachTo: document.body,
    })
    await waitFor(() => wrapper!.findAll('[data-group-key]').length > 0)
    await waitFor(
      () => wrapper!.find('[data-testid="chat-group-roster-count"]').text().trim() === '1',
    )
    return wrapper
  }

  it('offers a configured agent that is not in the roster yet', async () => {
    const w = await mountChat()

    await w.get('[data-testid="chat-group-roster-toggle"]').trigger('click')

    expect(w.find(`[data-testid="chat-group-add-${THIRD}"]`).exists()).toBe(true)
  })

  it('does not offer an agent the roster already runs', async () => {
    const w = await mountChat()

    await w.get('[data-testid="chat-group-roster-toggle"]').trigger('click')

    expect(w.find(`[data-testid="chat-group-add-${LEAD}"]`).exists()).toBe(false)
  })
})
