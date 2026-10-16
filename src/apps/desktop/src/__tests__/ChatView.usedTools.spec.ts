/** Tests for the `used_tools` tool dispatcher in ChatView.vue. `used_tools` used to fall through to
 * the generic `v-else` fallback, which dumped the raw payload into a one-liner: used_tools → ✓
 * {"count":10,"tools":[{"name":"update_plan",…]} It now has a dedicated card. */
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest'
import { setActivePinia, createPinia } from 'pinia'
import { createApp, nextTick, ref } from 'vue'
import { mount, flushPromises } from '@vue/test-utils'
import { createMemoryHistory, createRouter, type Router } from 'vue-router'

import * as api from '../api'
import ChatView from '../components/views/ChatView.vue'
import { installSseBus, __resetSseBus, __setSseBusGlobalClient } from '../helpers/sseBus'
import type { SseClient, SseState, SseStateInfo } from '../helpers/sseClient'
import { makeLocalStorageStub } from './helpers'
import type { Message } from '../api'

// ──────────────────────────────────────────────────────────────────────── Stubs — we only assert
// WHICH renderer the dispatcher picked, so the stubs are thin markers rather than the real
// components. ────────────────────────────────────────────────────────────────────────
vi.mock('../components/tool_outputs/UsedTools.vue', () => ({
  default: {
    name: 'UsedTools',
    props: ['message'],
    template:
      '<div class="used-tools-stub" :data-tool-name="message.tool_name" :data-msg-id="message.id"></div>',
  },
}))

vi.mock('../components/tool_outputs/ProgressiveTool.vue', () => ({
  default: {
    name: 'ProgressiveTool',
    props: ['content', 'toolName', 'parameters', 'expanded'],
    template: '<div class="progressive-stub" :data-tool-name="toolName"></div>',
  },
}))

// jsdom 29 dropped Element.prototype.scrollTo; polyfill for VirtualScroller.
if (
  typeof (globalThis as { HTMLElement?: { prototype: { scrollTo?: unknown } } }).HTMLElement
    ?.prototype.scrollTo === 'undefined'
) {
  ;(
    globalThis as unknown as { HTMLElement: { prototype: { scrollTo: () => void } } }
  ).HTMLElement.prototype.scrollTo = function () {
    // no-op
  }
}

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

// ──────────────────────────────────────────────────────────────────────── Wire helpers (mirror the
// backend `wrapToolOutput` shape for `used_tools` — see src/agentic_loop/tools_exec_used_tools.zig)
// ────────────────────────────────────────────────────────────────────────
const usedToolsEnvelope = (tools: { name: string; description: string }[]): string =>
  JSON.stringify({
    tool: 'used_tools',
    parameters: {},
    success: true,
    data: { count: tools.length, tools },
    error: null,
    v: 1,
  })

const USED_TOOLS_PAYLOAD = usedToolsEnvelope([
  { name: 'read_file', description: 'Read a file by path.' },
  { name: 'update_plan', description: 'The `update_plan` tool sets the task plan.' },
  { name: 'mcp_graphify_query_graph', description: 'Ask the knowledge graph.' },
])

const searchToolEnvelope = (): string =>
  JSON.stringify({
    tool: 'search_tool',
    parameters: { query: 'graph' },
    success: true,
    data: { tools: [{ name: 'mcp_graphify_query_graph', description: 'Ask.' }] },
    error: null,
    v: 1,
  })

/** The assistant turn that issued the call — ChatView groups a tool row under it. */
const assistantToolCall = (toolName: string, id = 'tc1'): Message => ({
  id: 'm_asst',
  role: 'assistant',
  content: '',
  created_at: 1001,
  finish_reason: 'tool_calls',
  tool_calls_json: JSON.stringify([{ id, type: 'function', function: { name: toolName } }]),
})

// ──────────────────────────────────────────────────────────────────────── Test helpers.
function installChatViewMocks(opts: { messages: Message[]; sessionId: string }) {
  vi.spyOn(api, 'getChatHistory').mockResolvedValue({
    messages: opts.messages,
    has_more: false,
    next_cursor: null,
    cwd: '/tmp',
    git_worktree_cwd: '',
    max_total_tokens: 0,
    max_capacity_total_tokens: 0,
  })
  vi.spyOn(api, 'getQueuedMessages').mockResolvedValue({ messages: [], count: 0 })
  vi.spyOn(api, 'getSession').mockResolvedValue({
    sessionId: opts.sessionId,
    sessionName: '',
    createdAt: '2026-09-26 00:00:00',
    agent: '',
    selectedProfile: '',
    cwd: '',
    git_worktree_cwd: '',
  })
  vi.spyOn(api, 'getGitStatus').mockResolvedValue({
    is_git_repo: false,
    branch: '',
    has_changes: false,
    is_clean: true,
    current: '',
    status: '',
  })
  vi.spyOn(api, 'getPabrikConfig').mockResolvedValue({ profiles: {} })
}

/**  * ChatView reads `route.query` and calls `router.replace` (diff deep-linking), so the mount needs a
 * real router — without one `useRoute()` returns undefined and the render throws. Catch-all route
 * keeps the path opaque. */
async function makeRouter(): Promise<Router> {
  const router = createRouter({
    history: createMemoryHistory(),
    routes: [{ path: '/:pathMatch(.*)*', name: 'catch-all', component: { template: '<div/>' } }],
  })
  await router.push('/app')
  await router.isReady()
  return router
}

let mountSeq = 0

/** Mount ChatView with `messages` and return the per-test container. Queries must be scoped to the
 * returned container (`document.querySelector` would see the previous test's tree when a mount
 * leaves anything behind). */
async function mountChatViewWithMessages(messages: Message[]) {
  const chatId = `s_used_tools_${++mountSeq}`
  installChatViewMocks({ messages, sessionId: chatId })

  const processingState = ref<Record<string, boolean>>({})
  const router = await makeRouter()

  const container = document.createElement('div')
  container.id = `chatview-used-tools-container-${mountSeq}`
  document.body.appendChild(container)

  const wrapper = mount(ChatView, {
    props: { chatId, chatName: 'Test Chat' },
    attachTo: container,
    global: {
      plugins: [router],
      provide: { processingState },
    },
  })
  for (let i = 0; i < 30; i++) {
    await new Promise((r) => setTimeout(r, 0))
    await nextTick()
    const streaming = (wrapper.vm as unknown as { isStreaming?: boolean }).isStreaming
    if (streaming) break
  }
  await flushPromises()
  await nextTick()
  return container
}

let vueApp: ReturnType<typeof createApp> | null = null
let sseBusGlobalClient: SseClient | null = null

beforeEach(() => {
  setActivePinia(createPinia())
  vueApp = createApp({})
  installSseBus(vueApp)
  sseBusGlobalClient = makeStubClient('open')
  __setSseBusGlobalClient(sseBusGlobalClient)
  Object.defineProperty(globalThis, 'localStorage', {
    value: makeLocalStorageStub(),
    writable: true,
    configurable: true,
  })
})

afterEach(() => {
  document.querySelectorAll('[id^="chatview-used-tools-container-"]').forEach((el) => el.remove())
  __resetSseBus()
  vueApp = null
  sseBusGlobalClient = null
  vi.restoreAllMocks()
})

// ────────────────────────────────────────────────────────────────────────
// Tests
// ────────────────────────────────────────────────────────────────────────
describe('ChatView tool dispatcher — used_tools', () => {
  it('routes a used_tools tool result to the <UsedTools> component', async () => {
    const el = await mountChatViewWithMessages([
        { id: 'm_user', role: 'user', content: 'What tools do you have?', created_at: 1000 },
        assistantToolCall('used_tools'),
        {
          id: 'm_used_tools',
          role: 'tool',
          content: USED_TOOLS_PAYLOAD,
          created_at: 1002,
          tool_name: 'used_tools',
          tool_call_id: 'tc1',
        },
      ])

    const stub = el.querySelector('.used-tools-stub')
    expect(stub).not.toBeNull()
    expect(stub?.getAttribute('data-tool-name')).toBe('used_tools')
    expect(stub?.getAttribute('data-msg-id')).toBe('m_used_tools')

    // The raw JSON payload must NOT reach the generic fallback row.
    expect(el.textContent).not.toContain('{"count":3,"tools"')
  })

  it('routes an ERRORED used_tools result to <UsedTools> as well', async () => {
    // The error branch must not fall through either — the card owns the
    // red-border + error-body rendering.
    const errored = JSON.stringify({
      tool: 'used_tools',
      parameters: {},
      success: false,
      data: null,
      error: 'used_tools failed: OutOfMemory',
      v: 1,
    })
    const el = await mountChatViewWithMessages([
        assistantToolCall('used_tools'),
        {
          id: 'm_used_tools_err',
          role: 'tool',
          content: errored,
          created_at: 1002,
          tool_name: 'used_tools',
          tool_call_id: 'tc1',
        },
      ])

    const stub = el.querySelector('.used-tools-stub')
    expect(stub).not.toBeNull()
    expect(stub?.getAttribute('data-msg-id')).toBe('m_used_tools_err')
  })

  it('does NOT capture search_tool — the progressive card keeps it', async () => {
    // Guard against a widened branch: both cards render name/description
    // rows, so `startsWith`-style logic would swallow search_tool.
    const el = await mountChatViewWithMessages([
        assistantToolCall('search_tool'),
        {
          id: 'm_search_tool',
          role: 'tool',
          content: searchToolEnvelope(),
          created_at: 1002,
          tool_name: 'search_tool',
          tool_call_id: 'tc1',
        },
      ])

    expect(el.querySelector('.used-tools-stub')).toBeNull()
    const prog = el.querySelector('.progressive-stub')
    expect(prog).not.toBeNull()
    expect(prog?.getAttribute('data-tool-name')).toBe('search_tool')
  })

  it('routes used_tools and search_tool independently in the same session', async () => {
    const el = await mountChatViewWithMessages([
        assistantToolCall('used_tools', 'tc1'),
        {
          id: 'm_used_tools',
          role: 'tool',
          content: USED_TOOLS_PAYLOAD,
          created_at: 1002,
          tool_name: 'used_tools',
          tool_call_id: 'tc1',
        },
        assistantToolCall('search_tool', 'tc2'),
        {
          id: 'm_search_tool',
          role: 'tool',
          content: searchToolEnvelope(),
          created_at: 1003,
          tool_name: 'search_tool',
          tool_call_id: 'tc2',
        },
      ])

    expect(el.querySelector('.used-tools-stub')?.getAttribute('data-msg-id')).toBe('m_used_tools')
    expect(el.querySelector('.progressive-stub')?.getAttribute('data-tool-name')).toBe(
      'search_tool',
    )
  })

  it('does NOT route an unrelated tool name to <UsedTools>', async () => {
    const el = await mountChatViewWithMessages([
        assistantToolCall('read_file'),
        {
          id: 'm_read_file',
          role: 'tool',
          content: JSON.stringify({
            tool: 'read_file',
            parameters: { path: '/tmp/foo.txt' },
            success: true,
            data: { path: '/tmp/foo.txt', content: 'hello' },
            error: null,
            v: 1,
          }),
          created_at: 1002,
          tool_name: 'read_file',
          tool_call_id: 'tc1',
        },
      ])

    expect(el.querySelector('.used-tools-stub')).toBeNull()
  })
})
