/** Drawing one tool card must not cost more because its turn sits later in the transcript: the
 * walk that re-parsed every preceding turn's `tool_calls_json` was O(n^2) and ran for every card of
 * the compact view on every SSE chunk (measured: 287 ms of main-thread work per chunk). */
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest'
import { setActivePinia, createPinia } from 'pinia'
import { createApp, nextTick, type App as VueApp } from 'vue'
import { mount, type VueWrapper } from '@vue/test-utils'
import { Effect } from 'effect'

import * as api from '../../api'
import ChatView from '../../components/views/ChatView.vue'

const TURNS = 6

const toolCallsJsonFor = (turn: number): string =>
  JSON.stringify([
    {
      id: `call_spawn_${turn}`,
      type: 'function',
      function: {
        name: 'spawn_sub_agent',
        arguments: JSON.stringify({
          sub_agents: [
            {
              agent_name: `worker_${turn}`,
              instruction: `do step ${turn}`,
              tools: ['read_file'],
            },
          ],
        }),
      },
    },
  ])

const SPAWN_JSON = Array.from({ length: TURNS }, (_, turn) => toolCallsJsonFor(turn))

const historyRows = (): unknown[] => {
  const rows: unknown[] = [
    {
      id: 'msg_user',
      role: 'user',
      content: 'spawn a few workers',
      created_at: 1,
      image_url: '',
      finish_reason: '',
    },
  ]
  for (let turn = 0; turn < TURNS; turn++) {
    rows.push({
      id: `msg_assistant_${turn}`,
      role: 'assistant',
      content: '',
      created_at: 2 + turn * 2,
      image_url: '',
      finish_reason: 'tool_calls',
      tool_calls_json: SPAWN_JSON[turn],
    })
    rows.push({
      id: `msg_tool_${turn}`,
      role: 'tool',
      content: JSON.stringify({
        tool: 'spawn_sub_agent',
        parameters: '{}',
        success: true,
        data: {},
        error: null,
        v: 1,
      }),
      created_at: 3 + turn * 2,
      image_url: '',
      finish_reason: '',
      tool_name: 'spawn_sub_agent',
      tool_call_id: `call_spawn_${turn}`,
    })
  }
  return rows
}

const historyResponse = () => ({
  messages: historyRows(),
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

import { installSseBus, __resetSseBus, __setSseBusGlobalClient } from '../../helpers/sseBus'
import type { SseClient, SseState } from '../../helpers/sseClient'

function makeStubClient(initial: SseState): SseClient {
  // eslint-disable-next-line @typescript-eslint/no-explicit-any
  const stub: any = {
    close: vi.fn(),
    reconnect: vi.fn(),
    getState: () => stub._state,
    onStateChange: () => () => {},
  }
  stub._state = initial
  return stub as SseClient
}

const installApiMocks = (): void => {
  vi.spyOn(api, 'getQueuedMessages').mockResolvedValue({ messages: [] } as never)
  vi.spyOn(api, 'getSession').mockResolvedValue({
    session_id: 'placeholder',
    session_name: '',
    selectedAgent: null,
    cwd: '',
    git_worktree_cwd: '',
  } as never)
  vi.spyOn(api, 'getGitStatus').mockResolvedValue({
    is_git_repo: false,
    branch: '',
    has_changes: false,
    is_clean: true,
    current: '',
    status: 'clean',
  } as never)
  vi.spyOn(api, 'getPabrikConfig').mockResolvedValue({
    chat_view: 'compact',
    profiles: {},
  } as never)
}

/** Every `JSON.parse` call the view makes on one of the fixture payloads. */
const toolCallsJsonParses = (spy: { mock: { calls: unknown[][] } }): number[] =>
  SPAWN_JSON.map((payload) => spy.mock.calls.filter((call) => call[0] === payload).length)

async function mountChatView(chatId: string): Promise<VueWrapper> {
  const wrapper = mount(ChatView, {
    props: { chatId, chatName: 'Test Chat' },
    attachTo: document.body,
  })
  for (let i = 0; i < 80; i++) {
    await new Promise((r) => setTimeout(r, 40))
    await nextTick()
    if (wrapper.find('.virtual-scroller').exists()) break
  }
  await new Promise((r) => setTimeout(r, 400))
  await nextTick()
  if (!wrapper.find('.virtual-scroller').exists()) {
    throw new Error('.virtual-scroller not mounted — the history load never settled')
  }
  return wrapper
}

describe('ChatView, the JSON.parse cost of one tool card', () => {
  let wrapper: VueWrapper | null = null
  let app: VueApp | null = null
  let parseSpy: ReturnType<typeof vi.spyOn>

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
    parseSpy = vi.spyOn(JSON, 'parse')
  })

  afterEach(() => {
    wrapper?.unmount()
    wrapper = null
    __resetSseBus()
    app = null
    parseSpy.mockRestore()
    vi.restoreAllMocks()
  })

  it('does not re-read an earlier turn while drawing a later turn’s card', async () => {
    installApiMocks()
    wrapper = await mountChatView('task_spawn_args_index')

    const parses = toolCallsJsonParses(parseSpy as never)

    expect(parses.reduce((total, count) => total + count, 0)).toBeGreaterThanOrEqual(TURNS)
    expect(new Set(parses).size).toBe(1)
  })
})
