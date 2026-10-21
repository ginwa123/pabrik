import { beforeEach, describe, expect, it, vi } from 'vitest'
import { setActivePinia, createPinia } from 'pinia'
import { createApp, type App as VueApp, nextTick, ref } from 'vue'
import { mount } from '@vue/test-utils'
import * as api from '../api'
import ChatsList from '../components/views/ChatsList.vue'
import { useNavigationStore } from '../stores/navigation'
import { makeLocalStorageStub } from './helpers'
import { installSseBus, __resetSseBus, __setSseBusGlobalClient } from '../helpers/sseBus'

const routeQuery: Record<string, string> = {}

vi.mock('vue-router', async () => {
  const actual = await vi.importActual<typeof import('vue-router')>('vue-router')
  return {
    ...actual,
    useRouter: () => ({ replace: vi.fn(), push: vi.fn() }),
    useRoute: () => ({ query: routeQuery, path: '/app', fullPath: '/app' }),
  }
})

// eslint-disable-next-line @typescript-eslint/no-explicit-any
function makeStubClient(): any {
  return { close: vi.fn(), reconnect: vi.fn(), getState: () => 'connecting', onStateChange: () => () => {} }
}

function mountChatsList() {
  return mount(ChatsList, {
    global: { provide: { processingState: ref<Record<string, boolean>>({}) } },
  })
}

async function flushLoadChats() {
  await new Promise((r) => setTimeout(r, 0))
  await nextTick()
  await nextTick()
}

describe('ChatsList — fresh-tab title', () => {
  let app: VueApp
  beforeEach(() => {
    setActivePinia(createPinia())
    Object.defineProperty(globalThis, 'localStorage', { value: makeLocalStorageStub(), writable: true, configurable: true })
    __resetSseBus()
    app = createApp({})
    installSseBus(app)
    __setSseBusGlobalClient(makeStubClient())
    for (const k of Object.keys(routeQuery)) delete routeQuery[k]
    vi.restoreAllMocks()
  })

  it('learns the session name from the loaded list on deep-link boot', async () => {
    routeQuery.view = 'chat'
    routeQuery.session = 'chat_1'
    vi.spyOn(api, 'getChats').mockResolvedValue({
      sessions: [{ session_id: 'chat_1', session_name: 'agent tool present files', updated_at: '2026-06-18T10:00:00Z' }],
      has_more: false,
      next_cursor: null,
      total: 1,
      // eslint-disable-next-line @typescript-eslint/no-explicit-any
    } as any)
    const getSessionSpy = vi.spyOn(api, 'getSession').mockResolvedValue(null)
    const wrapper = mountChatsList()
    await flushLoadChats()
    expect(useNavigationStore().activeChatName).toBe('agent tool present files')
    expect(getSessionSpy).not.toHaveBeenCalled()
    wrapper.unmount()
  })

  it('falls back to getSession past page 1', async () => {
    routeQuery.view = 'chat'
    routeQuery.session = 'chat_deep'
    vi.spyOn(api, 'getChats').mockResolvedValue({
      sessions: [{ session_id: 'chat_other', session_name: 'Other', updated_at: '2026-06-18T10:00:00Z' }],
      has_more: true,
      next_cursor: 'c',
      total: 2,
      // eslint-disable-next-line @typescript-eslint/no-explicit-any
    } as any)
    vi.spyOn(api, 'getSession').mockResolvedValue({
      sessionId: 'chat_deep',
      cwd: '',
      createdAt: '',
      agent: '',
      sessionName: 'deep task name',
      selectedAgent: undefined,
      // eslint-disable-next-line @typescript-eslint/no-explicit-any
    } as any)
    const wrapper = mountChatsList()
    await flushLoadChats()
    await flushLoadChats()
    expect(useNavigationStore().activeChatName).toBe('deep task name')
    wrapper.unmount()
  })
})
