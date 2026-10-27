/** The compact view folds one agent turn into ONE chain: the calls AND the
 * thoughts between them. A thought that leaks out below the card is the bug. */
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest'
import { setActivePinia, createPinia } from 'pinia'
import { createApp, nextTick, type App as VueApp } from 'vue'
import { mount, type VueWrapper } from '@vue/test-utils'
import { Effect } from 'effect'

import * as api from '../../api'
import ChatView from '../../components/views/ChatView.vue'
import ToolCard from '../../components/tool_outputs/ToolCard.vue'

const THOUGHT_ONE = 'The billing schema lives in main.go, so read it first.'
const THOUGHT_TWO = 'The rows show the tax column is zero, so run the query again.'
const THOUGHT_THREE = 'Both queries agree, so the totals are wrong.'
const ANSWER = 'The bill totals are wrong because the tax column never gets filled.'

let config: Record<string, unknown> = {}
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

import { installSseBus, __resetSseBus, __setSseBusGlobalClient } from '../../helpers/sseBus'
import type { SseClient, SseState, SseStateInfo } from '../../helpers/sseClient'

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

const envelope = (tool: string, parameters: string, data: unknown): string =>
  JSON.stringify({ tool, parameters, success: true, data, error: null, v: 1 })

function seedTurn(): void {
  historyRows.length = 0
  historyRows.push({
    id: 'msg_user',
    role: 'user',
    content: 'why are the bill totals wrong?',
    created_at: 1,
  })
  historyRows.push({
    id: 'msg_think_one',
    role: 'assistant',
    content: '',
    created_at: 2,
    reasoning_content: THOUGHT_ONE,
    finish_reason: 'tool_calls',
  })
  historyRows.push({
    id: 'msg_tool_read',
    role: 'tool',
    content: envelope('read_file', '<path>/repo/main.go</path>', {
      path: '/repo/main.go',
      content: 'package main\n',
    }),
    created_at: 3,
    tool_name: 'read_file',
  })
  historyRows.push({
    id: 'msg_think_two',
    role: 'assistant',
    content: '',
    created_at: 4,
    reasoning_content: THOUGHT_TWO,
    finish_reason: 'tool_calls',
  })
  historyRows.push({
    id: 'msg_tool_command',
    role: 'tool',
    content: envelope('command', '<command>sqlite3 ruang.db "select sum(total) from bills"</command>', {
      command: 'sqlite3 ruang.db "select sum(total) from bills"',
      stdout: '0\n',
      stderr: '',
      exit_code: 0,
    }),
    created_at: 5,
    tool_name: 'command',
  })
  historyRows.push({
    id: 'msg_think_three',
    role: 'assistant',
    content: '',
    created_at: 6,
    reasoning_content: THOUGHT_THREE,
    finish_reason: 'tool_calls',
  })
  historyRows.push({
    id: 'msg_answer',
    role: 'assistant',
    content: ANSWER,
    created_at: 7,
    finish_reason: 'stop',
  })
  historyRows.reverse()
}

const installApiMocks = (mode: 'compact' | 'dev'): void => {
  config = mode === 'compact' ? { chat_view: 'compact' } : {}
  seedTurn()
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
  vi.spyOn(api, 'getPabrikConfig').mockImplementation(() => Promise.resolve(config) as never)
}

async function mountChatView(chatId: string): Promise<VueWrapper> {
  const wrapper = mount(ChatView, {
    props: { chatId, chatName: 'Test Chat' },
    attachTo: document.body,
  })
  for (let i = 0; i < 60; i++) {
    await new Promise((r) => setTimeout(r, 40))
    await nextTick()
    if (wrapper.find('.virtual-scroller').exists()) break
  }
  await new Promise((r) => setTimeout(r, 300))
  await nextTick()
  if (!wrapper.find('.virtual-scroller').exists()) {
    throw new Error('.virtual-scroller not mounted — the history load never settled')
  }
  return wrapper
}

const normalize = (html: string): string =>
  html
    .replace(/\s+tool-item-border/g, '')
    .replace(/\s*data-v-[0-9a-f]+=""?/g, '')
    .replace(/\s+/g, ' ')
    .trim()

describe('the compact view of a turn that thought between its calls', () => {
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

  it('keeps every thought of the turn out of the transcript until the card is opened', async () => {
    installApiMocks('compact')
    wrapper = await mountChatView('task_compact_folded')

    expect(wrapper.get('[data-testid="compact-tool-group-count"]').text()).toBe('2 tool calls')
    expect(wrapper.text()).not.toContain(THOUGHT_ONE)
    expect(wrapper.text()).not.toContain(THOUGHT_TWO)
    expect(wrapper.text()).not.toContain(THOUGHT_THREE)
  })

  it('draws the thoughts inside the one card the turn folded into, in the order they happened', async () => {
    installApiMocks('compact')
    wrapper = await mountChatView('task_compact_in_card')

    await wrapper.get('[data-testid="compact-tool-group-header"]').trigger('click')
    await nextTick()

    const chain = wrapper.get('[data-testid="compact-tool-chain"]')
    const items = chain
      .findAll('[data-testid="compact-thought-row"], [data-testid="compact-tool-row"]')
      .map((row) => row.attributes('data-testid'))
    expect(items).toHaveLength(5)

    expect(chain.findAll('[data-testid="compact-thought-row"]')).toHaveLength(3)
    expect(wrapper.text().match(new RegExp(THOUGHT_ONE, 'g'))).toHaveLength(1)
    expect(wrapper.findAll('.assistant-reasoning')).toHaveLength(0)
    expect(chain.text()).toContain(THOUGHT_ONE)
    expect(chain.text()).toContain(THOUGHT_TWO)
    expect(chain.text()).toContain(THOUGHT_THREE)
  })

  it('leaves the answer of the turn in the transcript, outside the card', async () => {
    installApiMocks('compact')
    wrapper = await mountChatView('task_compact_answer')

    await wrapper.get('[data-testid="compact-tool-group-header"]').trigger('click')
    await nextTick()

    expect(wrapper.text()).toContain(ANSWER)
    expect(wrapper.get('[data-testid="compact-tool-chain"]').text()).not.toContain(ANSWER)
  })

  it('renders a row opened inside the card exactly as the dev view renders that call', async () => {
    installApiMocks('compact')
    wrapper = await mountChatView('task_compact_same_card')
    await wrapper.get('[data-testid="compact-tool-group-header"]').trigger('click')
    await nextTick()

    const rows = wrapper.findAll('[data-testid="compact-tool-row-name"]')
    const readFileRow = rows.find((row) => row.text() === 'read_file')
    expect(readFileRow).toBeDefined()
    await readFileRow!.element
      .closest('[data-testid="compact-tool-row"]')!
      .querySelector('[data-testid="compact-tool-row-expand"]')!
      .dispatchEvent(new MouseEvent('click', { bubbles: true }))
    await nextTick()
    await nextTick()

    const compactCard = wrapper
      .findAllComponents(ToolCard)
      .find((card) => card.props('message').id === 'msg_tool_read')
    expect(compactCard).toBeDefined()
    const compactHtml = normalize(compactCard!.html())
    wrapper.unmount()

    installApiMocks('dev')
    wrapper = await mountChatView('task_dev_same_card')
    const devCard = wrapper
      .findAllComponents(ToolCard)
      .find((card) => card.props('message').id === 'msg_tool_read')
    expect(devCard).toBeDefined()
    await devCard!.find('[role="button"]').trigger('click')
    await nextTick()

    expect(compactHtml).toBe(normalize(devCard!.html()))
    expect(compactHtml).toContain('/repo/main.go')
  })

  it('keeps the dev view drawing the thought next to its own turn', async () => {
    installApiMocks('dev')
    wrapper = await mountChatView('task_dev_keeps_thought')

    expect(wrapper.findAll('.assistant-reasoning')).toHaveLength(3)
    expect(wrapper.find('[data-testid="compact-tool-chain"]').exists()).toBe(false)
  })
})
