/**
 * Tests for the update_plan + get_plan tool dispatcher in ChatView.vue.
 *
 * The component imports UpdatePlan.vue + GetPlan.vue which must be
 * stubbed via vi.mock(...) following the SubAgentPeekPanel.spec.ts
 * pattern. The stubs emit a recognisable DOM marker (data-tool-name +
 * a class hook) so we can assert which tool renderer was selected for
 * each message.
 *
 * Behavioural contract:
 *   - A `role: 'tool'` message with `tool_name === 'update_plan'`
 *     dispatches to <UpdatePlan :message="msg" />.
 *   - A `role: 'tool'` message with `tool_name === 'get_plan'`
 *     dispatches to <GetPlan :message="msg" />.
 *   - Other tool names do NOT route to either component.
 *
 * Plan: docs/superpowers/plans/2026-08-19-session-plan-agent-tool.md
 *   Task 8
 */
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

// ──────────────────────────────────────────────────────────────────────── Stub the new tool-output
// components.

// We don't need to assert their internal rendering here (that lives in UpdatePlan.spec.ts /
// GetPlan.spec.ts if we ever write them) — we only need to know that the ChatView dispatcher routes
// the right tool_name to the right component.

// The stubs expose `data-tool-name` so we can verify the vnode was emitted with the expected
// `msg.tool_name` prop. ────────────────────────────────────────────────────────────────────────

vi.mock('../components/tool_outputs/UpdatePlan.vue', () => ({
  default: {
    name: 'UpdatePlan',
    // No `parameters` prop — the component parses the plan body directly from the inner
    // <plan><![CDATA[...]]></plan> block of the <tool> envelope (mirrors get_plan's wire shape).
    // The dispatcher doesn't thread anything extra.
    props: ['message'],
    template:
      '<div class="update-plan-stub" :data-tool-name="message.tool_name" :data-msg-id="message.id"></div>',
  },
}))

vi.mock('../components/tool_outputs/GetPlan.vue', () => ({
  default: {
    name: 'GetPlan',
    props: ['message'],
    template:
      '<div class="get-plan-stub" :data-tool-name="message.tool_name" :data-msg-id="message.id"></div>',
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

// ────────────────────────────────────────────────────────────────────────
// Wire envelope helpers (mirrors the backend's JSON `wrapToolOutput` shape)
// ────────────────────────────────────────────────────────────────────────

const wireToolEnvelope = (inner: unknown, paramsJson: string): string =>
  JSON.stringify({
    tool: 'tool',
    parameters: JSON.parse(paramsJson),
    success: true,
    data: inner,
    error: null,
    v: 1,
  })

const updatePlanSuccessEnvelope = (
  sessionId = 's_test_001',
  updatedAt = '2026-08-19 21:00:00',
): unknown => ({ session_id: sessionId, updated_at: updatedAt })

const getPlanPresentEnvelope = (markdown: string): unknown => ({ plan: markdown })

const getPlanEmptyEnvelope = (): unknown => ({ empty: true })

// ──────────────────────────────────────────────────────────────────────── Test helpers — mock the
// api module + SSE bus + localStorage so the mount is fast and stable (parity with
// profileCascade.spec.ts). ────────────────────────────────────────────────────────────────────────

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
    createdAt: '2026-08-19 00:00:00',
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

/**  * Each call mounts a FRESH session id on purpose: ChatView primes its messages from the
 * IndexedDB-backed `chatEngineDb` cache keyed by session id, so reusing one id made test N+1 paint
 * test N's rows instead of the freshly-mocked `getChatHistory` response. */
async function mountChatViewWithMessages(messages: Message[]) {
  const chatId = `s_plan_${++mountSeq}`
  installChatViewMocks({ messages, sessionId: chatId })

  const processingState = ref<Record<string, boolean>>({})
  const router = await makeRouter()

  // Use a per-test container so multiple mounts don't bleed DOM
  // into each other. attachTo: document.body would persist the
  // previous test's stub across cases.
  const container = document.createElement('div')
  container.id = `chatview-test-container-${mountSeq}`
  document.body.appendChild(container)

  const wrapper = mount(ChatView, {
    props: { chatId, chatName: 'Test Chat' },
    attachTo: container,
    global: {
      plugins: [router],
      provide: { processingState },
    },
  })
  // Wait for onMounted's loadChatHistory + the watch on sessionId to
  // settle. Same loop as ChatView.profileCascade.spec.ts.
  for (let i = 0; i < 30; i++) {
    await new Promise((r) => setTimeout(r, 0))
    await nextTick()
    const streaming = (wrapper.vm as unknown as { isStreaming?: boolean }).isStreaming
    if (streaming) break
  }
  await flushPromises()
  await nextTick()
  return wrapper
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
  // Tear down any leftover container elements from the previous
  // mount so the next test starts with a clean DOM.
  document.querySelectorAll('[id^="chatview-test-container-"]').forEach((el) => el.remove())
  __resetSseBus()
  vueApp = null
  sseBusGlobalClient = null
  vi.restoreAllMocks()
})

// ────────────────────────────────────────────────────────────────────────
// Tests
// ────────────────────────────────────────────────────────────────────────

describe('ChatView tool dispatcher — update_plan + get_plan', () => {
  it('routes an update_plan tool result to the <UpdatePlan> component', async () => {
    await mountChatViewWithMessages([
        {
          id: 'm_user',
          role: 'user',
          content: 'Build feature X',
          created_at: 1000,
        },
        {
          id: 'm_asst',
          role: 'assistant',
          content: '',
          created_at: 1001,
          finish_reason: 'tool_calls',
          tool_calls_json: JSON.stringify([
            { id: 'tc1', type: 'function', function: { name: 'update_plan' } },
          ]),
        },
        {
          id: 'm_update_plan',
          role: 'tool',
          content: wireToolEnvelope(
            updatePlanSuccessEnvelope('s_test_001', '2026-08-19 21:00:00'),
            JSON.stringify({ content: '## Goal\n- [ ] step 1' }),
          ),
          created_at: 1002,
          tool_name: 'update_plan',
          tool_call_id: 'tc1',
        },
      ])

    const stub = document.querySelector('.update-plan-stub')
    expect(stub).not.toBeNull()
    expect(stub?.getAttribute('data-tool-name')).toBe('update_plan')
    expect(stub?.getAttribute('data-msg-id')).toBe('m_update_plan')

    // The get_plan stub must NOT render in this scenario.
    expect(document.querySelector('.get-plan-stub')).toBeNull()
  })

  it('routes a get_plan tool result (with plan body) to the <GetPlan> component', async () => {
    await mountChatViewWithMessages([
        {
          id: 'm_user',
          role: 'user',
          content: 'Show me the plan',
          created_at: 1000,
        },
        {
          id: 'm_asst',
          role: 'assistant',
          content: '',
          created_at: 1001,
          finish_reason: 'tool_calls',
          tool_calls_json: JSON.stringify([
            { id: 'tc1', type: 'function', function: { name: 'get_plan' } },
          ]),
        },
        {
          id: 'm_get_plan',
          role: 'tool',
          content: wireToolEnvelope(
            getPlanPresentEnvelope('## Goal\n- [x] step 1 done\n- [ ] step 2'),
            '{}',
          ),
          created_at: 1002,
          tool_name: 'get_plan',
          tool_call_id: 'tc1',
        },
      ])

    const stub = document.querySelector('.get-plan-stub')
    expect(stub).not.toBeNull()
    expect(stub?.getAttribute('data-tool-name')).toBe('get_plan')
    expect(stub?.getAttribute('data-msg-id')).toBe('m_get_plan')

    // The update_plan stub must NOT render in this scenario.
    expect(document.querySelector('.update-plan-stub')).toBeNull()
  })

  it('routes a get_plan {empty:true} result to the <GetPlan> component too', async () => {
    // The empty/no-plan sentinel still belongs to get_plan — the
    // dispatcher must not skip it.
    await mountChatViewWithMessages([
        {
          id: 'm_asst',
          role: 'assistant',
          content: '',
          created_at: 1001,
          finish_reason: 'tool_calls',
          tool_calls_json: JSON.stringify([
            { id: 'tc1', type: 'function', function: { name: 'get_plan' } },
          ]),
        },
        {
          id: 'm_get_plan_empty',
          role: 'tool',
          content: wireToolEnvelope(getPlanEmptyEnvelope(), '{}'),
          created_at: 1002,
          tool_name: 'get_plan',
          tool_call_id: 'tc1',
        },
      ])

    const stub = document.querySelector('.get-plan-stub')
    expect(stub).not.toBeNull()
    expect(stub?.getAttribute('data-tool-name')).toBe('get_plan')
  })

  it('routes both update_plan and get_plan in the same session', async () => {
    // The agent often chains update_plan → get_plan within a single
    // turn (or across adjacent turns). The dispatcher must handle
    // both messages with their respective components.
    await mountChatViewWithMessages([
        {
          id: 'm_update_plan',
          role: 'tool',
          content: wireToolEnvelope(
            updatePlanSuccessEnvelope(),
            JSON.stringify({ content: '## Steps\n- [x] step 1' }),
          ),
          created_at: 1002,
          tool_name: 'update_plan',
          tool_call_id: 'tc1',
        },
        {
          id: 'm_get_plan',
          role: 'tool',
          content: wireToolEnvelope(getPlanPresentEnvelope('## Steps\n- [x] step 1'), '{}'),
          created_at: 1003,
          tool_name: 'get_plan',
          tool_call_id: 'tc2',
        },
      ])

    const updateStub = document.querySelector('.update-plan-stub')
    const getStub = document.querySelector('.get-plan-stub')
    expect(updateStub).not.toBeNull()
    expect(getStub).not.toBeNull()
    expect(updateStub?.getAttribute('data-tool-name')).toBe('update_plan')
    expect(updateStub?.getAttribute('data-msg-id')).toBe('m_update_plan')
    expect(getStub?.getAttribute('data-tool-name')).toBe('get_plan')
    expect(getStub?.getAttribute('data-msg-id')).toBe('m_get_plan')
  })

  it('does NOT route other tool names to either component', async () => {
    // A read_file tool result must dispatch to its own component,
    // not bleed into the plan tools. This guards against future
    // dispatcher refactors that might widen the v-else-if branch.
    await mountChatViewWithMessages([
        {
          id: 'm_read_file',
          role: 'tool',
          content: wireToolEnvelope(
            '<path>/tmp/foo.txt</path><content>hello</content>',
            JSON.stringify({ path: '/tmp/foo.txt' }),
          ),
          created_at: 1002,
          tool_name: 'read_file',
          tool_call_id: 'tc1',
        },
      ])

    expect(document.querySelector('.update-plan-stub')).toBeNull()
    expect(document.querySelector('.get-plan-stub')).toBeNull()
  })
})
