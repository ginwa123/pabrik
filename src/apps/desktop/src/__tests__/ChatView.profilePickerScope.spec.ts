/** The New Chat agent picker must list the agents a run in THIS workspace will actually use. */
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest'
import { setActivePinia, createPinia } from 'pinia'
import { createApp, nextTick, ref } from 'vue'
import { createMemoryHistory, createRouter, type Router } from 'vue-router'
import { mount, flushPromises, type VueWrapper } from '@vue/test-utils'

import * as api from '../api'
import { Effect } from 'effect'
import ChatView from '../components/views/ChatView.vue'
import { useWorkspacesStore } from '../stores/workspaces'
import { installSseBus, __resetSseBus, __setSseBusGlobalClient } from '../helpers/sseBus'
import type { SseClient, SseState, SseStateInfo } from '../helpers/sseClient'
import { makeLocalStorageStub } from './helpers'

const USER_PROFILES = {
  '900ribu': { model: 'MiniMax-M3', base_url: 'https://api.minimax.io/v1' },
  opencode: { model: 'step-5-preview-free', base_url: 'https://opencode.ai/zen/go/v1' },
}
/** The same user set PLUS the overlay-only profile the picker used to lose. */
const WORKSPACE_PROFILES = {
  ...USER_PROFILES,
  kilo: {
    model: 'nvidia/nemotron-3-super-120b-a12b:free',
    base_url: 'https://api.kilo.ai/api/gateway/chat/completions',
  },
}

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

function installApiMocks() {
  const history = {
    messages: [],
    has_more: false,
    next_cursor: null,
    cwd: '/tmp',
    git_worktree_cwd: '',
    max_total_tokens: 0,
    max_capacity_total_tokens: 0,
  }
  // ChatView's mount loads through `fetchChatHistoryEffect`; `getChatHistory` alone never reaches
  // it, so the mount stalled on the 404 the global fetch stub answers with.
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
  vi.spyOn(api, 'getGitStatus').mockResolvedValue({ is_git_repo: false } as any)
  vi.spyOn(api, 'getPabrikConfig').mockResolvedValue({
    profiles: USER_PROFILES,
    active_profile: null,
    // eslint-disable-next-line @typescript-eslint/no-explicit-any
  } as any)
  const wsSpy = vi.spyOn(api, 'getWorkspaceConfig').mockResolvedValue({
    profiles: WORKSPACE_PROFILES,
    active_profile: null,
    // eslint-disable-next-line @typescript-eslint/no-explicit-any
  } as any)
  return wsSpy
}

async function mountChatView(sessionId: string, router?: Router): Promise<VueWrapper> {
  const wrapper = mount(ChatView, {
    props: { chatId: sessionId, chatName: 'Scope Chat' },
    attachTo: document.body,
    global: {
      provide: { processingState: ref<Record<string, boolean>>({}) },
      ...(router ? { plugins: [router] } : {}),
    },
  })
  // Settle the async mount (loadAgents + the session watcher).
  for (let i = 0; i < 30; i++) {
    await new Promise((r) => setTimeout(r, 0))
    await nextTick()
    if ((wrapper.vm as unknown as { isStreaming?: boolean }).isStreaming) break
  }
  await flushPromises()
  await nextTick()
  return wrapper
}

/** The picker as the user sees it: open it, then name the rows on screen. */
async function openPickerRows(wrapper: VueWrapper): Promise<string[]> {
  const chip = wrapper.find('[data-testid="agent-picker-button"]')
  if (!chip.exists()) throw new Error('agent chip not found — picker cannot be opened')
  await chip.trigger('click.stop')
  await nextTick()
  return wrapper
    .findAll('[data-testid^="agent-picker-"]')
    .map((el) => el.attributes('data-testid') ?? '')
}

let vueApp: ReturnType<typeof createApp> | null = null

beforeEach(() => {
  setActivePinia(createPinia())
  vueApp = createApp({})
  installSseBus(vueApp)
  __setSseBusGlobalClient(makeStubClient('open'))
  Object.defineProperty(globalThis, 'localStorage', {
    value: makeLocalStorageStub(),
    writable: true,
    configurable: true,
  })
})

afterEach(() => {
  __resetSseBus()
  vueApp = null
  vi.restoreAllMocks()
})

describe('ChatView agent picker — workspace scope', () => {
  it('lists a profile that exists only in the workspace overlay, and asks the workspace scope for it', async () => {
    const ws = useWorkspacesStore()
    ws.workspaces = [
      // eslint-disable-next-line @typescript-eslint/no-explicit-any
      { id: 'ws_with_kilo', name: 'has kilo', items: [], expanded: false } as any,
    ]
    ws.activeWorkspaceId = 'ws_with_kilo'
    const wsSpy = installApiMocks()

    const wrapper = await mountChatView('sess_ws_scope')
    const rows = await openPickerRows(wrapper)

    // The regression: `kilo` was in the workspace's Settings -> Profiles list
    // and in no picker row, because the list came from the user scope.
    expect(rows).toContain('agent-picker-kilo')
    expect(wsSpy).toHaveBeenCalledWith('ws_with_kilo')
    expect(vi.mocked(api.getPabrikConfig)).not.toHaveBeenCalled()
    wrapper.unmount()
  })

  it('falls back to the user-scope config when no workspace is in scope', async () => {
    // Negative control for the test above: with nothing in scope the picker
    // really does read the user scope, so the absence of `kilo` there is the
    // scope's doing and not an empty list passing vacuously.
    const wsSpy = installApiMocks()

    const wrapper = await mountChatView('sess_no_ws')
    const rows = await openPickerRows(wrapper)

    expect(rows).toContain('agent-picker-900ribu')
    expect(rows).not.toContain('agent-picker-kilo')
    expect(wsSpy).not.toHaveBeenCalled()
    expect(vi.mocked(api.getPabrikConfig)).toHaveBeenCalled()
    wrapper.unmount()
  })

  it('the route workspace wins over a different active workspace in the store', async () => {
    // `/app/:workspaceId/chat/:sessionId` is the canonical chat URL, and it is the only source that
    // is right on a cold deep-link load - the store has not resolved an active workspace yet at
    // that point.
    const router = createRouter({
      history: createMemoryHistory(),
      routes: [
        { path: '/app/:workspaceId/chat/:sessionId', component: { template: '<div />' } },
        { path: '/app/chat/:sessionId', component: { template: '<div />' } },
      ],
    })
    await router.push('/app/ws_from_url/chat/sess_route')
    await router.isReady()

    const ws = useWorkspacesStore()
    ws.workspaces = [
      // eslint-disable-next-line @typescript-eslint/no-explicit-any
      { id: 'ws_from_store', name: 'other', items: [], expanded: false } as any,
    ]
    ws.activeWorkspaceId = 'ws_from_store'
    const wsSpy = installApiMocks()

    const wrapper = await mountChatView('sess_route', router)

    expect(wsSpy).toHaveBeenCalledWith('ws_from_url')
    expect(wsSpy).not.toHaveBeenCalledWith('ws_from_store')
    const listed = (wrapper.vm as unknown as { availableAgents?: { name: string }[] })
      .availableAgents
    expect((listed ?? []).map((p) => p.name)).toContain('kilo')
    wrapper.unmount()
  })
})
