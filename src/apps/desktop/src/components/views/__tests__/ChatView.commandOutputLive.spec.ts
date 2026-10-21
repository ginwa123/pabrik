import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest'
import { createPinia, setActivePinia } from 'pinia'
import { createApp, nextTick, ref, type App as VueApp, type Ref } from 'vue'
import { flushPromises, mount, type VueWrapper } from '@vue/test-utils'
import { createMemoryHistory, createRouter } from 'vue-router'
import { Effect } from 'effect'

import * as api from '../../../api'
import ChatView from '../ChatView.vue'
import {
  __dispatchSseBus,
  __resetSseBus,
  __setSseBusGlobalClient,
  installSseBus,
} from '../../../helpers/sseBus'
import type { SseClient, SseState, SseStateInfo } from '../../../helpers/sseClient'
import { makeLocalStorageStub } from '../../../__tests__/helpers'
import { chatEngineDb } from '../../../sync/ChatEngineDb'

const SESSION_ID = 'session_command_output'

const commandEnvelope = (data: Record<string, unknown> | null): string =>
  JSON.stringify({
    tool: 'command',
    parameters: {
      command: "printf '%s\\n' '--- numbered excerpts ---'",
      timeout: 10,
      workdir: '/tmp',
    },
    success: true,
    data,
    error: null,
    v: 1,
  })

const commandEvent = (content: string): api.SseEvent =>
  ({
    id: 'tool-row-1',
    session_id: SESSION_ID,
    type: 'full',
    role: 'tool',
    model: 'test-model',
    cwd: '/tmp',
    content,
    finish_reason: 'tool',
    tool_call_id: 'call_command_1',
    tool_name: 'command',
    is_input: false,
    is_output: true,
  }) as api.SseEvent

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
  vi.spyOn(api, 'getChatHistory').mockResolvedValue({
    messages: [],
    has_more: false,
    next_cursor: null,
    cwd: '/tmp',
    git_worktree_cwd: '',
    max_total_tokens: 0,
    max_capacity_total_tokens: 0,
  })
  vi.spyOn(api, 'getStreamSnapshot').mockResolvedValue({ active: false, content: '' })
  vi.spyOn(api, 'getQueuedMessages').mockResolvedValue({ messages: [], count: 0 })
  vi.spyOn(api, 'getSession').mockResolvedValue({
    sessionId: SESSION_ID,
    sessionName: '',
    createdAt: '',
    agent: '',
    selectedAgent: '',
    cwd: '/tmp',
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

async function mountChatView(processingState: Ref<Record<string, boolean>>): Promise<VueWrapper> {
  const router = createRouter({
    history: createMemoryHistory(),
    routes: [{ path: '/', component: { template: '<div />' } }],
  })
  await router.push('/')
  await router.isReady()

  const wrapper = mount(ChatView, {
    props: { chatId: SESSION_ID, chatName: 'Command output regression' },
    attachTo: document.body,
    global: {
      plugins: [router],
      provide: { processingState },
    },
  })

  for (let i = 0; i < 30; i++) {
    await new Promise((resolve) => setTimeout(resolve, 0))
    await nextTick()
    if ((wrapper.vm as unknown as { isStreaming?: boolean }).isStreaming) break
  }
  await flushPromises()
  await nextTick()
  return wrapper
}

describe('ChatView command tool output — live placeholder-to-result update', () => {
  let wrapper: VueWrapper | null = null
  let app: VueApp | null = null

  beforeEach(async () => {
    Object.defineProperty(globalThis, 'localStorage', {
      value: makeLocalStorageStub(),
      writable: true,
      configurable: true,
    })
    setActivePinia(createPinia())
    await Effect.runPromise(chatEngineDb.clear(SESSION_ID))

    __resetSseBus()
    app = createApp({})
    installSseBus(app)
    __setSseBusGlobalClient(makeStubClient('open'))
    installApiMocks()
  })

  afterEach(async () => {
    wrapper?.unmount()
    wrapper = null
    __resetSseBus()
    app = null
    await Effect.runPromise(chatEngineDb.clear(SESSION_ID))
    vi.restoreAllMocks()
  })

  it('renders stdout in the existing expanded card when the same tool row receives its final SSE', async () => {
    wrapper = await mountChatView(ref<Record<string, boolean>>({}))

    __dispatchSseBus('llm', commandEvent(commandEnvelope(null)))
    await flushPromises()
    await nextTick()

    const card = wrapper.find('.chat-tool-card')
    expect(card.exists()).toBe(true)
    expect(card.text()).toContain('command')

    await card.get('div[role="button"]').trigger('click')
    await nextTick()
    expect(card.text()).toContain('Arguments')
    expect(card.text()).not.toContain('LIVE_STDOUT_MARKER')

    const finalContent = commandEnvelope({
      command: "printf '%s\\n' '--- numbered excerpts ---'",
      stdout: 'LIVE_STDOUT_MARKER\nsecond output line',
      stderr: '',
      exit_code: 0,
      truncated: false,
      timeout: false,
      stdout_lines: 2,
      stderr_lines: 0,
    })
    __dispatchSseBus('llm', commandEvent(finalContent))
    await flushPromises()
    await nextTick()
    await nextTick()

    expect(card.text()).toContain('stdout')
    expect(card.text()).toContain('LIVE_STDOUT_MARKER')
    expect(card.text()).toContain('second output line')
  })

  it('keeps a final SSE received while the initial history request is in flight', async () => {
    let resolveHistory!: (value: Awaited<ReturnType<typeof api.getChatHistory>>) => void
    const history = new Promise<Awaited<ReturnType<typeof api.getChatHistory>>>((resolve) => {
      resolveHistory = resolve
    })
    vi.spyOn(api, 'getChatHistory').mockReturnValue(history)

    wrapper = await mountChatView(ref<Record<string, boolean>>({}))

    const finalContent = commandEnvelope({
      command: "printf '%s\\n' '--- numbered excerpts ---'",
      stdout: 'RACE_STDOUT_MARKER',
      stderr: '',
      exit_code: 0,
      truncated: false,
      timeout: false,
      stdout_lines: 1,
      stderr_lines: 0,
    })
    __dispatchSseBus('llm', commandEvent(finalContent))
    await flushPromises()

    resolveHistory({
      messages: [
        {
          id: 'tool-row-1',
          role: 'tool',
          content: commandEnvelope(null),
          created_at: 1_700_000_000,
          tool_name: 'command',
          tool_call_id: 'call_command_1',
        },
      ],
      has_more: false,
      next_cursor: null,
      cwd: '/tmp',
      git_worktree_cwd: '',
      max_total_tokens: 0,
      max_capacity_total_tokens: 0,
    })
    await flushPromises()
    await nextTick()
    await nextTick()

    const card = wrapper.find('.chat-tool-card')
    expect(card.exists()).toBe(true)
    await card.get('div[role="button"]').trigger('click')
    await nextTick()
    expect(card.text()).toContain('RACE_STDOUT_MARKER')
    const cachedAfterHistory = await Effect.runPromise(chatEngineDb.primeFromCache(SESSION_ID, 100))
    expect(cachedAfterHistory[0]?.raw.content).toContain('RACE_STDOUT_MARKER')
  })

  it('does not replace chunks received while a stream snapshot is loading', async () => {
    let resolveHistory!: (value: Awaited<ReturnType<typeof api.getChatHistory>>) => void
    const history = new Promise<Awaited<ReturnType<typeof api.getChatHistory>>>((resolve) => {
      resolveHistory = resolve
    })
    vi.spyOn(api, 'getChatHistory').mockReturnValue(history)

    let resolveSnapshot!: (value: Awaited<ReturnType<typeof api.getStreamSnapshot>>) => void
    const snapshot = new Promise<Awaited<ReturnType<typeof api.getStreamSnapshot>>>((resolve) => {
      resolveSnapshot = resolve
    })
    vi.spyOn(api, 'getStreamSnapshot').mockReturnValue(snapshot)

    wrapper = await mountChatView(ref<Record<string, boolean>>({}))
    __dispatchSseBus('llm', {
      session_id: SESSION_ID,
      type: 'chunk',
      content: 'LIVE_BEFORE_SNAPSHOT',
    })
    await flushPromises()

    resolveHistory({
      messages: [],
      has_more: false,
      next_cursor: null,
      cwd: '/tmp',
      git_worktree_cwd: '',
      max_total_tokens: 0,
      max_capacity_total_tokens: 0,
    })
    await flushPromises()
    await nextTick()

    __dispatchSseBus('llm', {
      session_id: SESSION_ID,
      type: 'chunk',
      content: '_LIVE_AFTER_SNAPSHOT_REQUEST',
    })
    resolveSnapshot({ active: true, content: 'STALE_SNAPSHOT' })
    await flushPromises()
    await nextTick()
    await nextTick()

    expect(wrapper.text()).toContain('LIVE_BEFORE_SNAPSHOT')
    expect(wrapper.text()).toContain('_LIVE_AFTER_SNAPSHOT_REQUEST')
    expect(wrapper.text()).not.toContain('STALE_SNAPSHOT')
  })

  it('persists the final stdout over the placeholder row in the local sync cache', async () => {
    wrapper = await mountChatView(ref<Record<string, boolean>>({}))

    __dispatchSseBus('llm', commandEvent(commandEnvelope(null)))
    await flushPromises()
    await nextTick()

    const placeholderCache = await Effect.runPromise(chatEngineDb.primeFromCache(SESSION_ID, 100))
    expect(placeholderCache).toHaveLength(1)
    expect(placeholderCache[0]?.raw.content).not.toContain('CACHE_STDOUT_MARKER')

    const finalContent = commandEnvelope({
      command: "printf '%s\\n' '--- numbered excerpts ---'",
      stdout: 'CACHE_STDOUT_MARKER\nsecond output line',
      stderr: '',
      exit_code: 0,
      truncated: false,
      timeout: false,
      stdout_lines: 2,
      stderr_lines: 0,
    })
    __dispatchSseBus('llm', commandEvent(finalContent))
    await flushPromises()
    await nextTick()

    const finalCache = await Effect.runPromise(chatEngineDb.primeFromCache(SESSION_ID, 100))
    expect(finalCache).toHaveLength(1)
    expect(finalCache[0]?.raw.content).toContain('CACHE_STDOUT_MARKER')
  })
})
