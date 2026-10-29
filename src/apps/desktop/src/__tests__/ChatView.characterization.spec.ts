/** Behavior lock for ChatView: mounts the real component against a wire fixture that reaches every
 * render branch, then pins what renders — it fails when a refactor changes what the user sees. */
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest'
import { setActivePinia, createPinia } from 'pinia'
import { createApp, nextTick, type App as VueApp } from 'vue'
import { mount, type VueWrapper } from '@vue/test-utils'
import { Effect } from 'effect'

import * as api from '../api'
import ChatView from '../components/views/ChatView.vue'
import FileInput from '../components/file/FileInput.vue'
import ChatRightSidebar from '../components/views/chat_right_sidebar/ChatRightSidebar.vue'
import ChatScrollSlider from '../components/chat/ChatScrollSlider.vue'
import UserPillRail from '../components/chat/UserPillRail.vue'
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

const RICH_BLOCKS = [
  'prose before',
  '<html><body><p>framed</p></body></html>',
  '```mermaid\ngraph TD; A-->B\n```',
  '```plantuml\n@startuml\nA -> B\n@enduml\n```',
  '```d2\na -> b\n```',
  'prose after',
].join('\n\n')

const BG_COMMAND =
  '<background_command><pid>4242</pid><command>sleep 5</command><stdout>done</stdout></background_command>'

const COMPACTION = JSON.stringify({ compact_messages: [{ role: 'user', content: 'old turn' }] })

const FILE_ATTACHMENTS = JSON.stringify([{ name: 'spec.pdf', mime: 'application/pdf', bytes: 10 }])

/** One row per render branch: multi-message groups, reasoning, rich blocks, tool cards,
 *  image-only user rows, document chips, a compaction envelope and a background completion. */
const FIXTURE_ROWS = [
  { id: 'u1', role: 'user', content: 'hello there', created_at: 1_700_000_001 },
  {
    id: 'a1',
    role: 'assistant',
    content: 'answer one',
    reasoning_content: 'thinking it over',
    created_at: 1_700_000_002,
  },
  { id: 'a2', role: 'assistant', content: RICH_BLOCKS, created_at: 1_700_000_003 },
  {
    id: 'a3',
    role: 'assistant',
    content: '',
    finish_reason: 'tool_calls',
    tool_calls_json: JSON.stringify([
      { id: 'tc1', type: 'function', function: { name: 'read_file' } },
      { id: 'tc2', type: 'function', function: { name: 'search_files' } },
    ]),
    created_at: 1_700_000_004,
  },
  {
    id: 't1',
    role: 'tool',
    content: 'file body',
    tool_name: 'read_file',
    tool_call_id: 'tc1',
    created_at: 1_700_000_005,
  },
  {
    id: 't2',
    role: 'tool',
    content: 'two hits',
    tool_name: 'search_files',
    tool_call_id: 'tc2',
    created_at: 1_700_000_006,
  },
  {
    id: 'u2',
    role: 'user',
    content: '',
    image_url: 'https://example.test/one.png',
    created_at: 1_700_000_007,
  },
  {
    id: 'u3',
    role: 'user',
    content: 'see attached',
    file_attachments: FILE_ATTACHMENTS,
    created_at: 1_700_000_008,
  },
  { id: 'a4', role: 'assistant', content: 'final answer', created_at: 1_700_000_009 },
  { id: 'u5', role: 'user', content: COMPACTION, created_at: 1_700_000_010 },
  { id: 'a5', role: 'assistant', content: 'between', created_at: 1_700_000_011 },
  { id: 'u6', role: 'user', content: BG_COMMAND, created_at: 1_700_000_012 },
]

const ctl = vi.hoisted(() => ({
  base: {
    has_more: false,
    next_cursor: null,
    cwd: '/tmp/work',
    git_worktree_cwd: '',
    max_total_tokens: 1234,
    max_capacity_total_tokens: 200000,
    skills: [] as unknown[],
  },
  rows: [] as unknown[],
}))

vi.mock('../api', async (importOriginal) => {
  const actual = await importOriginal<typeof import('../api')>()
  const page = () => ({ ...ctl.base, messages: ctl.rows })
  return {
    ...actual,
    getChatHistory: () => Promise.resolve(page()),
    fetchChatHistoryEffect: () => Effect.succeed(page()),
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

function installBaseMocks() {
  /* eslint-disable @typescript-eslint/no-explicit-any */
  vi.spyOn(api, 'getQueuedMessages').mockResolvedValue({ messages: [] } as any)
  vi.spyOn(api, 'getSession').mockResolvedValue({
    session_id: 's_char',
    session_name: '',
    selectedAgent: null,
    cwd: '/tmp/work',
    git_worktree_cwd: '',
  } as any)
  vi.spyOn(api, 'getGitStatus').mockResolvedValue({
    is_git_repo: true,
    branch: 'main',
    status: 'clean',
    is_clean: true,
  } as any)
  vi.spyOn(api, 'getPabrikConfig').mockResolvedValue({
    profiles: { alpha: { model: 'm-1', base_url: 'http://x', url_style: 'openai' } },
    active_profile: 'alpha',
  } as any)
  vi.spyOn(api, 'getStreamSnapshot').mockResolvedValue({
    active: false,
    content: '',
  } as any)
  /* eslint-enable @typescript-eslint/no-explicit-any */
}

async function waitFor(predicate: () => boolean, tries = 120): Promise<void> {
  for (let i = 0; i < tries; i++) {
    if (predicate()) return
    await new Promise((r) => setTimeout(r, 10))
    await nextTick()
  }
}

/** Elements that carry visible meaning, in document order. */
const LANDMARKS: Array<[string, string]> = [
  ['iframe.chat-html-frame', 'html-frame'],
  ['details.assistant-reasoning', 'reasoning'],
  ['.assistant-messages', 'assistant-messages'],
  ['.assistant-item', 'assistant-item'],
  ['.tool-sequence', 'tool-sequence'],
  ['.tool-item', 'tool-item'],
  ['.markdown-content', 'markdown'],
  ['.chat-attached-file-chip', 'file-chip'],
  ['.chat-attached-image-thumb', 'image-thumb'],
  ['img', 'img'],
]

const MARKUP_LANDMARKS: Array<[string, string]> = [
  ['[data-testid="compaction-card"]', 'compaction-card'],
  ['[data-testid="chat-tool-card"]', 'tool-card'],
]

function projectRow(el: Element): string[] {
  const tokens: string[] = []
  const walk = (node: Element): void => {
    for (const [selector, token] of [...LANDMARKS, ...MARKUP_LANDMARKS]) {
      if (node.matches(selector)) {
        tokens.push(token)
        break
      }
    }
    for (const child of Array.from(node.children)) walk(child)
  }
  walk(el)
  return tokens
}

/** What the transcript must contain, as an order-independent multiset of landmark paths.
 *  DOM order is not stable in jsdom (the scroller re-windows on every measure), so the lock is on
 *  WHICH rows render and WHAT each row draws — never on their sequence. */
const EXPECTED_ROW_TOKENS: string[][] = [
  [],
  ['markdown', 'tool-sequence', 'tool-item'],
  ['markdown', 'assistant-messages', 'assistant-item'],
  ['markdown', 'assistant-messages', 'assistant-item'],
  ['compaction-card'],
  ['file-chip', 'image-thumb', 'img'],
  ['markdown', 'tool-sequence', 'tool-item', 'tool-item'],
  [
    'markdown',
    'reasoning',
    'assistant-messages',
    'assistant-item',
    'assistant-item',
    'html-frame',
    'img',
    'assistant-item',
  ],
]

function normalize(rows: string[][]): string[] {
  return rows.map((t) => t.join('>')).sort()
}

describe('ChatView behavior lock — transcript projection', () => {
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
    ctl.rows = FIXTURE_ROWS
    __resetSseBus()
    app = createApp({})
    installSseBus(app)
    __setSseBusGlobalClient(makeStubClient())
    installBaseMocks()
  })

  afterEach(() => {
    wrapper?.unmount()
    wrapper = null
    __resetSseBus()
    app = null
    vi.restoreAllMocks()
  })

  async function mountAndProject(
    chatId: string,
    props: Record<string, unknown>,
  ): Promise<{
    rowTokens: string[]
    groupCount: number
    lastRowKeys: string[]
    topPaddedKeys: string[]
    chrome: Record<string, boolean>
  }> {
    wrapper = mount(ChatView, {
      props: { chatId, chatName: 'Characterization', ...props },
      attachTo: document.body,
    })
    await waitFor(() => wrapper!.findAll('[data-group-key]').length > 0)
    await nextTick()

    const rows = wrapper.findAll('[data-group-key]')
    return {
      rowTokens: normalize(rows.map((w) => projectRow(w.element))),
      groupCount: rows.length,
      lastRowKeys: rows
        .filter((w) => w.element.classList.contains('last-transcript-row'))
        .map((w) => w.element.getAttribute('data-group-key') ?? ''),
      topPaddedKeys: rows
        .filter((w) => w.element.classList.contains('pt-6'))
        .map((w) => w.element.getAttribute('data-group-key') ?? ''),
      chrome: {
        composerDock: wrapper.find('[data-testid="composer-dock"]').exists(),
        composerScrim: wrapper.find('[data-testid="composer-scrim"]').exists(),
        tokensStatus: wrapper.find('[data-testid="tokens-status"]').exists(),
        agentPicker: wrapper.find('[data-testid="agent-picker-button"]').exists(),
        worktreeButton: wrapper.find('[data-testid="worktree-status-button"]').exists(),
        pillRail: wrapper.findComponent(UserPillRail).exists(),
        scrollSlider: wrapper.findComponent(ChatScrollSlider).exists(),
        rightSidebar: wrapper.findComponent(ChatRightSidebar).exists(),
        emptyState: wrapper.text().includes('How can I help you?'),
        skeleton: wrapper.find('[data-testid="chat-initializing-skeleton"]').exists(),
        loadError: wrapper.find('[data-testid="chat-load-error"]').exists(),
        fileInput: wrapper.findComponent(FileInput).exists(),
      },
    }
  }

  it('renders every transcript branch exactly as it does today', async () => {
    const got = await mountAndProject('s_char_dev', { showHeader: true })

    expect(got.rowTokens).toEqual(normalize(EXPECTED_ROW_TOKENS))
    expect(got.groupCount).toBe(EXPECTED_ROW_TOKENS.length)
    expect(got.lastRowKeys).toHaveLength(1)
    expect(got.topPaddedKeys).toHaveLength(1)
    expect(got.chrome).toEqual({
      composerDock: true,
      composerScrim: true,
      tokensStatus: true,
      agentPicker: true,
      worktreeButton: true,
      pillRail: true,
      scrollSlider: true,
      rightSidebar: true,
      emptyState: false,
      skeleton: false,
      loadError: false,
      fileInput: true,
    })
  })

  it('renders the same transcript in the compact view', async () => {
    useChatViewStore().setMode('compact')
    const got = await mountAndProject('s_char_compact', {})
    expect(got.rowTokens).toEqual(normalize(EXPECTED_ROW_TOKENS))
  })

  it('mounts the same transcript read-only in the peek mode', async () => {
    const got = await mountAndProject('s_char_embedded', { embedded: true, hideInput: true })
    expect(got.rowTokens).toEqual(normalize(EXPECTED_ROW_TOKENS))
    expect(got.chrome).toEqual({
      composerDock: false,
      composerScrim: false,
      tokensStatus: false,
      agentPicker: false,
      worktreeButton: false,
      pillRail: true,
      scrollSlider: true,
      rightSidebar: false,
      emptyState: false,
      skeleton: false,
      loadError: false,
      fileInput: false,
    })
  })

  it('opens the agent picker and reports the chosen agent', async () => {
    wrapper = mount(ChatView, {
      props: { chatId: 's_char_agents', chatName: 'Characterization' },
      attachTo: document.body,
    })
    await waitFor(() => wrapper!.findAll('[data-group-key]').length > 0)

    const picker = wrapper.find('[data-testid="agent-picker-button"]')
    expect(picker.exists()).toBe(true)
    await picker.trigger('click')
    await nextTick()
    const menu = wrapper.find('[data-testid="agent-picker-menu"]')
    expect(menu.exists()).toBe(true)
    expect(wrapper.find('[data-testid="agent-picker-default"]').exists()).toBe(true)
    expect(wrapper.find('[data-testid="agent-picker-alpha"]').exists()).toBe(true)
  })

  it('sends the composer text through api.sendChatMessage', async () => {
    const send = vi.spyOn(api, 'sendChatMessage').mockResolvedValue(undefined as never)
    wrapper = mount(ChatView, {
      props: { chatId: 's_char_send', chatName: 'Characterization' },
      attachTo: document.body,
    })
    await waitFor(() => wrapper!.findAll('[data-group-key]').length > 0)

    await wrapper.findComponent(FileInput).vm.$emit('submit', 'hello agent')
    await nextTick()
    expect(send).toHaveBeenCalledTimes(1)
    expect(send.mock.calls[0]?.[0]).toBe('s_char_send')
    expect(send.mock.calls[0]?.[1]).toBe('hello agent')
  })
})
