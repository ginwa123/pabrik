/** Behavioural tests for the kanban `?sorts=` URL round-trip. **Bug fixed (2026-08-06):** "when
 * click chatview, my sort url is gone" — opening a task from the kanban drops the `?sorts=` param. */
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest'
import { setActivePinia, createPinia } from 'pinia'
import { nextTick, ref, createApp } from 'vue'
import { mount, flushPromises } from '@vue/test-utils'

import AppLayout from '../components/AppLayout.vue'
import * as api from '../api'
import { useWorkspacesStore } from '../stores/workspaces'
import { makeLocalStorageStub } from './helpers'
import {
  installSseBus,
  __resetSseBus,
  __setSseBusGlobalClient,
} from '../helpers/sseBus'
import type { SseClient, SseState } from '../helpers/sseClient'
import { useTabsStore } from '../stores/tabs'

// Stub vue-router (AppLayout uses useRoute()/useRouter() for URL
// sync). Mirrors AppLayout.kanbanChatDialog.spec.ts:33-53.
const { useRouteMock, useRouterMock, routerReplaceCalls } = vi.hoisted(() => {
  // Shared across mounts so a test can inspect what AppLayout navigated to
  // (useRouter() hands back a fresh object per mount, so a per-mount spy would
  // be unreachable from the test body).
  const routerReplaceCalls: Array<{ path?: string; query?: Record<string, string> }> = []
  return {
    routerReplaceCalls,
    useRouteMock: vi.fn(() => ({
      query: {} as Record<string, string>,
      path: '/app',
      fullPath: '/app',
    })),
    useRouterMock: vi.fn(() => ({
      replace: vi.fn((target: { path?: string; query?: Record<string, string> }) => {
        routerReplaceCalls.push(target)
        return Promise.resolve()
      }),
      push: vi.fn(),
    })),
  }
})
vi.mock('vue-router', async () => {
  const actual = await vi.importActual<typeof import('vue-router')>('vue-router')
  return { ...actual, useRouter: useRouterMock, useRoute: useRouteMock }
})

// Mirror AppLayout.kanbanChatDialog.spec.ts's fixtures so the
// existing test infrastructure (jsdom + vue-test-utils) just
// works.
const WS_ID = 'ws_sort_url'
const ITEM_ID = 'item_sort_url'
const TASK_ID = 'task_sort_url'

const baseItem = {
  id: ITEM_ID,
  name: 'SortURL Round-trip Test',
  item_type: 'kanban',
  kanban_columns: [
    { id: 'col_a', name: 'todo', workspace_item_id: ITEM_ID, position: 0, created_at: '2026-01-01' },
    { id: 'col_b', name: 'in_progress', workspace_item_id: ITEM_ID, position: 1, created_at: '2026-01-01' },
  ],
}

// Local bus installer (mirrors AppLayout.kanbanChatDialog.spec.ts
// — the project doesn't have a shared one yet).
function installBusForTests() {
  const app = createApp({})
  installSseBus(app)
  __setSseBusGlobalClient({
    close: () => {},
    reconnect: () => {},
    getState: () => 'connecting' as SseState,
    onStateChange: () => () => {},
  } as SseClient)
}

function mountAppLayout(): ReturnType<typeof mount> {
  return mount(AppLayout, {
    attachTo: document.body,
    global: {
      provide: { processingState: ref({}) },
      stubs: {
        Sidebar: true,
        RightSidebar: true,
        GitFileViewer: true,
        SkillDetail: true,
        SettingsView: true,
        CodeEditor: true,
        KanbanView: true,
        DesignView: true,
        Chats: true,
        // `@click` stands in for the in-chat ✕, which emits `close`. With tab
        // mode off that routes through handleCloseTaskView's legacy path — the
        // only remaining caller of the savedSortsParam contract.
        ChatView: {
          template: `<div data-testid="chatview-stub" @click="$emit('close')" />`,
          props: ['chatId', 'chatName', 'cwd', 'showHeader'],
        },
      },
    },
  })
}

// Mock the workspace-store API calls so init() doesn't wipe the
// injected fixture (same approach as AppLayout.kanbanChatDialog.spec.ts).
function rewireApiForFixture(store: ReturnType<typeof useWorkspacesStore>) {
  // Snapshot the fixture tree NOW: lazy init() replaces `workspaces.value` with empty-items rows
  // BEFORE calling getWorkspacesItems, so a live read would see the wiped tree.
  // eslint-disable-next-line @typescript-eslint/no-explicit-any
  const snapshot = JSON.parse(JSON.stringify(store.workspaces)) as any[]
  vi.spyOn(api, 'getWorkspaces').mockImplementation(async () => ({
     
    // eslint-disable-next-line @typescript-eslint/no-explicit-any
    workspaces: snapshot as any,
  }))
   
  vi.spyOn(api, 'getWorkspacesItems').mockImplementation(async (wsId: string) => {
     
    // eslint-disable-next-line @typescript-eslint/no-explicit-any
    const ws = snapshot.find((w: any) => w.id === wsId)
    // eslint-disable-next-line @typescript-eslint/no-explicit-any
    return { items: (ws?.items ?? []) as any, count: ws?.items?.length ?? 0 }
   
  })
  vi.spyOn(api, 'getTasks').mockImplementation(async (wsId: string, itemId: string) => {
     
    // eslint-disable-next-line @typescript-eslint/no-explicit-any
    const ws = snapshot.find((w: any) => w.id === wsId)
    // eslint-disable-next-line @typescript-eslint/no-explicit-any
    const item = ws?.items?.find((i: any) => i.id === itemId)
    return {
      // eslint-disable-next-line @typescript-eslint/no-explicit-any
      tasks: (item?.tasks ?? []) as any,
      has_more: false,
      next_cursor: null,
    }
  })
}

describe('AppLayout — kanban ?sorts= URL round-trip via task view', () => {
  beforeEach(() => {
    setActivePinia(createPinia())
    document.body.innerHTML = ''
    Object.defineProperty(globalThis, 'localStorage', {
      value: makeLocalStorageStub(),
      writable: true,
      configurable: true,
    })
    installBusForTests()
    // Stub API calls fired by AppLayout's onMounted →
    // initializeFromSystemFolder → init() (otherwise the fetch fails
    // on the relative URL). Mirrors AppLayout.kanbanChatDialog.spec.ts.
    vi.spyOn(api, 'getWorkspaces').mockImplementation(async () => ({
      workspaces: [],
    }))
    vi.spyOn(api, 'getWorkspacesItems').mockImplementation(async () => ({
      items: [],
      count: 0,
    }))
    vi.spyOn(api, 'getTasks').mockImplementation(async () => ({
      tasks: [],
      has_more: false,
      next_cursor: null,
    }))
     
    vi.spyOn(api, 'getSystemFolder').mockResolvedValue({
      entries: [],
      path: '/',
      absolute: '/',
      home: '/',
    })
     
    // eslint-disable-next-line @typescript-eslint/no-explicit-any
    vi.spyOn(api, 'getSession').mockResolvedValue({ cwd: '' } as any)
    vi.spyOn(api, 'getChatHistory').mockResolvedValue({
      messages: [],
      has_more: false,
      next_cursor: null,
      total: 0,
    // eslint-disable-next-line @typescript-eslint/no-explicit-any
    } as any)
    vi.useFakeTimers()
    routerReplaceCalls.length = 0
  })

  afterEach(() => {
    vi.useRealTimers()
    vi.restoreAllMocks()
    __resetSseBus()
  })

 

  it('tab mode off: restores ?sorts= from the snapshot when the chat closes', async () => {
    // Tab mode off is the ONLY remaining caller of the savedSortsParam
    // contract: with tabs on, the board tab carries its own ?sorts= and the
    // chat closes back onto it (see AppLayout.tabs.spec.ts).
    localStorage.setItem('pabrik-tabs-enabled', 'false')
    const store = useWorkspacesStore()
    store.workspaces = [
      { id: WS_ID, name: 'WS', items: [{
        ...baseItem,
        tasks: [{ id: TASK_ID, name: 'Some Task' }],
      // eslint-disable-next-line @typescript-eslint/no-explicit-any
      } as any] },
    // eslint-disable-next-line @typescript-eslint/no-explicit-any
    ] as any
    rewireApiForFixture(store)
    // Pre-populate the snapshot field the way Sidebar.vue does on user click — this simulates the
    // user being on the `?view=workspace&...&sorts=col_a:name:asc` URL right before they click a
    // card.
    store.savedSortsParam = 'col_a:name:asc'

    const wrapper = mountAppLayout()
    await flushPromises()
    expect(useTabsStore().enabled).toBe(false)

    // Simulate the active task state (the chat view mounts).
    store.setActiveTask(TASK_ID)
    await nextTick()


    expect(wrapper.find('[data-testid="chatview-stub"]').exists()).toBe(true)

    // Close the chat. handleCloseTaskView must read savedSortsParam, write
    // sorts=col_a:name:asc back into the URL, then clear the snapshot so a
    // subsequent close doesn't accidentally restore a stale sort.
    routerReplaceCalls.length = 0
    await wrapper.find('[data-testid="chatview-stub"]').trigger('click')
    await nextTick()

    // The store field must be cleared (consumed on close) so a
    // subsequent close-without-a-fresh-task-open doesn't carry a
    // stale snapshot forward.
    expect(store.savedSortsParam).toBe('')
    const sorted = routerReplaceCalls.find((call) => call.query && 'sorts' in call.query)
    expect(sorted?.query?.sorts).toBe('col_a:name:asc')
    expect(sorted?.path).toBe(`/app/${WS_ID}/projects/${ITEM_ID}`)

    wrapper.unmount()
  })

  it('tab mode off: does NOT set sorts= when no snapshot was taken (snapshot empty)', async () => {
    localStorage.setItem('pabrik-tabs-enabled', 'false')
    const store = useWorkspacesStore()
    store.workspaces = [
      { id: WS_ID, name: 'WS', items: [{
        ...baseItem,
        tasks: [{ id: TASK_ID, name: 'Some Task' }],
      // eslint-disable-next-line @typescript-eslint/no-explicit-any
      } as any] },
    // eslint-disable-next-line @typescript-eslint/no-explicit-any
    ] as any
    rewireApiForFixture(store)
    // No snapshot — user opened the task from a workspace that didn't have ?sorts= in its URL.
    expect(store.savedSortsParam).toBe('')

    const wrapper = mountAppLayout()
    await flushPromises()

    store.setActiveTask(TASK_ID)
    await nextTick()

    // Close the chat through the in-chat ✕.
    routerReplaceCalls.length = 0
    await wrapper.find('[data-testid="chatview-stub"]').trigger('click')
    await nextTick()

    // Snapshot was empty, must still be empty (nothing to consume,
    // nothing to write), and no navigation may carry a sorts= param.
    expect(store.savedSortsParam).toBe('')
    expect(routerReplaceCalls.every((call) => !(call.query && 'sorts' in call.query))).toBe(true)

    wrapper.unmount()
  })
})
