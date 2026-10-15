// AppLayout — kanban task chat as a <main> view (its own tab).
//
// When the user opens a kanban task (URL
// `?view=workspace&...&itemId=Y/chat/task_<id>`, or by clicking a card) the
// stores hold `activeTask` + `activeTaskWorkspaceItemId`. Since the chat is
// its own tab, the AppLayout render chain gives that tab a CHAT body and the
// bare board tab a BOARD body — so this spec has two jobs:
//
//   1. the gate: chat only for a task whose parent IS the active kanban item
//   2. the chain: the chat and the board are mutually exclusive, never stacked
//
// (2) is the important one. The kanban VIEW branch only tests
// `item_type === 'kanban'`, so a chat branch written as `v-if` — or placed
// after the KanbanView branch — would render the board AND the chat at once.
// The old modal could not catch that: a Teleport rendered outside the chain.
// This spec used to be `AppLayout.kanbanChatDialog.spec.ts` and queried
// `document` for the teleported dialog. There is no modal any more, so it
// queries the mounted wrapper instead.
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest'
import { setActivePinia, createPinia } from 'pinia'
import { mount, flushPromises, type VueWrapper } from '@vue/test-utils'
import { ref } from 'vue'
import AppLayout from '../components/AppLayout.vue'
import { useWorkspacesStore } from '../stores/workspaces'
import type { WorkspaceItem, Task } from '../stores/workspaces'
import { makeLocalStorageStub } from './helpers'
import { installSseBus, __resetSseBus, __setSseBusGlobalClient } from '../helpers/sseBus'
import type { SseClient } from '../helpers/sseClient'

// Stub vue-router (AppLayout uses useRoute()/useRouter() for URL sync).
const { useRouteMock, useRouterMock } = vi.hoisted(() => ({
  useRouteMock: vi.fn(() => ({
    query: {} as Record<string, string>,
    path: '/app',
    fullPath: '/app',
  })),
  useRouterMock: vi.fn(() => ({
    replace: vi.fn(),
    push: vi.fn(),
    back: vi.fn(),
  })),
}))

vi.mock('vue-router', async () => {
  const actual = await vi.importActual<typeof import('vue-router')>('vue-router')
  return {
    ...actual,
    useRouter: useRouterMock,
    useRoute: useRouteMock,
  }
})

import * as api from '../api'

const WS_ID = 'ws_1'
const KANBAN_ITEM_ID = 'item_kanban_1'
const DESIGN_ITEM_ID = 'item_design_1'
const TASK_ID = 'task_1'
const TASK_ID_2 = 'task_2'

const CHAT_BODY = '[data-testid="kanban-chat-body"]'
const BOARD = '[data-testid="kanban-view-stub"]'

function makeStubClient(): SseClient {
  // eslint-disable-next-line @typescript-eslint/no-explicit-any
  const stub: any = {
    close: vi.fn(),
    reconnect: vi.fn(),
    getState: () => 'open',
    onStateChange: () => () => {},
  }
  return stub as SseClient
}

function installBusForTests() {
  __resetSseBus()
  installSseBus()
  __setSseBusGlobalClient(makeStubClient())
}

function makeKanbanItem(overrides: Partial<WorkspaceItem> = {}): WorkspaceItem {
  return {
    id: KANBAN_ITEM_ID,
    name: 'Sprint A',
    item_type: 'kanban',
    kanban_columns: [],
    tasks: [],
    ...overrides,
  } as WorkspaceItem
}

function makeDesignItem(tasks: Task[] = []): WorkspaceItem {
  return {
    id: DESIGN_ITEM_ID,
    name: 'Design',
    item_type: 'design',
    tasks,
  } as WorkspaceItem
}

function mountAppLayout(): VueWrapper {
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
        // A marker stub so the spec can prove the board is NOT rendered
        // alongside the chat.
        KanbanView: { template: `<div data-testid="kanban-view-stub" />` },
        DesignView: { template: `<div data-testid="design-view-stub" />` },
        // ChatView renders the chat name into its own header (the ✕ lives
        // there too), so the spec asserts the props it is handed rather than
        // re-testing ChatView's header markup.
        ChatView: {
          template:
            '<div data-testid="kanban-chat-body" :data-chat-id="chatId" :data-chat-name="chatName" :data-show-header="String(showHeader)" />',
          props: [
            'chatId',
            'chatName',
            'type',
            'cwd',
            'showHeader',
            'taskId',
            'taskName',
            'projectName',
          ],
        },
        Chats: true,
      },
    },
  })
}

describe('AppLayout — kanban task chat as its own view', () => {
  let wrapper: VueWrapper | null = null

  beforeEach(() => {
    Object.defineProperty(globalThis, 'localStorage', {
      value: makeLocalStorageStub(),
      writable: true,
      configurable: true,
    })
    installBusForTests()
    // Stub the workspace-store API calls fired by AppLayout's onMounted →
    // initializeFromSystemFolder → init(). Without them jsdom's fetch throws ERR_INVALID_URL (no
    // test server); AppLayout catches it, but it floods the output.
    // Each test rewires these to preserve its fixture.
    vi.spyOn(api, 'getWorkspaces').mockResolvedValue({ workspaces: [] })
    vi.spyOn(api, 'getWorkspacesItems').mockResolvedValue({ items: [], count: 0 })
    vi.spyOn(api, 'getTasks').mockResolvedValue({ tasks: [], has_more: false, next_cursor: null })
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
    setActivePinia(createPinia())
    document.body.innerHTML = ''
  })

  // init() overwrites workspaces.value with the API response, so the mocks must
  // echo the per-test fixture set immediately before mount.
  function rewireApiForFixture(store: ReturnType<typeof useWorkspacesStore>) {
    // Snapshot the fixture tree NOW (JSON): lazy init() replaces `workspaces.value` with
    // empty-items rows BEFORE calling getWorkspacesItems, so a live read would see the wiped tree.
    // eslint-disable-next-line @typescript-eslint/no-explicit-any
    const snapshot = JSON.parse(JSON.stringify(store.workspaces)) as any[]
    vi.spyOn(api, 'getWorkspaces').mockImplementation(async () => {
      // eslint-disable-next-line @typescript-eslint/no-explicit-any
      return { workspaces: snapshot as any }
    })
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

  afterEach(() => {
    vi.useRealTimers()
    vi.restoreAllMocks()
    wrapper?.unmount()
    wrapper = null
  })

  it('renders the BOARD and no chat when no task is active', async () => {
    const store = useWorkspacesStore()
    store.workspaces = [
      { id: WS_ID, name: 'WS', items: [makeKanbanItem()] },
      // eslint-disable-next-line @typescript-eslint/no-explicit-any
    ] as any
    store.setActiveWorkspaceItem(KANBAN_ITEM_ID)
    // init() replaces workspaces.value with the API response, so without this
    // the fixture (and therefore the active item) is wiped on mount.
    rewireApiForFixture(store)
    wrapper = mountAppLayout()
    await flushPromises()

    expect(wrapper.find(CHAT_BODY).exists()).toBe(false)
    expect(wrapper.find(BOARD).exists()).toBe(true)
  })

  it('renders the CHAT and NOT the board when the task belongs to the active kanban item', async () => {
    const store = useWorkspacesStore()
    store.workspaces = [
      {
        id: WS_ID,
        name: 'WS',
        items: [
          {
            ...makeKanbanItem(),
            tasks: [{ id: TASK_ID, name: 'Hello Task' } as Task],
          },
          makeDesignItem(),
        ],
      },
      // eslint-disable-next-line @typescript-eslint/no-explicit-any
    ] as any
    store.setActiveWorkspaceItem(KANBAN_ITEM_ID)
    store.setActiveTask(TASK_ID)
    rewireApiForFixture(store)
    wrapper = mountAppLayout()
    await flushPromises()

    const chat = wrapper.find(CHAT_BODY)
    expect(chat.exists()).toBe(true)
    // Migration 052 invariant: the chat session id IS the task id.
    expect(chat.attributes('data-chat-id')).toBe(TASK_ID)
    expect(chat.attributes('data-chat-name')).toBe('Hello Task')
    // The in-chat header (task name + ✕) is what keeps the chat closable with
    // tab mode off; ChatView renders it only when this prop is true.
    expect(chat.attributes('data-show-header')).toBe('true')
    // THE chain assertion: the board must not render alongside the chat.
    expect(wrapper.find(BOARD).exists()).toBe(false)
  })

  it('remounts the chat with the new session when a different task is selected', async () => {
    const store = useWorkspacesStore()
    store.workspaces = [
      {
        id: WS_ID,
        name: 'WS',
        items: [
          {
            ...makeKanbanItem(),
            tasks: [
              { id: TASK_ID, name: 'First' } as Task,
              { id: TASK_ID_2, name: 'Second' } as Task,
            ],
          },
        ],
      },
      // eslint-disable-next-line @typescript-eslint/no-explicit-any
    ] as any
    store.setActiveWorkspaceItem(KANBAN_ITEM_ID)
    store.setActiveTask(TASK_ID)
    rewireApiForFixture(store)
    wrapper = mountAppLayout()
    await flushPromises()
    expect(wrapper.find(CHAT_BODY).attributes('data-chat-id')).toBe(TASK_ID)

    // `:key="'kanban-chat-' + activeTask.id"` forces a fresh mount, which is
    // what preserves useChatScrollRestore's per-session scroll contract.
    store.setActiveTask(TASK_ID_2)
    await flushPromises()
    expect(wrapper.find(CHAT_BODY).attributes('data-chat-id')).toBe(TASK_ID_2)
    expect(wrapper.find(BOARD).exists()).toBe(false)
  })

  it('renders the BOARD, not the chat, when the active task belongs to a different item', async () => {
    const store = useWorkspacesStore()
    store.workspaces = [
      {
        id: WS_ID,
        name: 'WS',
        items: [
          // the kanban has NO matching task
          makeKanbanItem(),
          // the DESIGN item owns the active task
          makeDesignItem([{ id: TASK_ID, name: 'Design Task' } as Task]),
        ],
      },
      // eslint-disable-next-line @typescript-eslint/no-explicit-any
    ] as any
    // Task first, item second: setActiveTask re-parents to the design item, so
    // the kanban has to be re-selected afterwards to create the mismatch (this
    // is the "clicked a card, then switched the active item" shape).
    store.setActiveTask(TASK_ID)
    store.setActiveWorkspaceItem(KANBAN_ITEM_ID)
    rewireApiForFixture(store)
    wrapper = mountAppLayout()
    await flushPromises()

    // `activeTaskWorkspaceItemId === activeWorkspaceItem.id` is false, so the
    // chat branch is skipped and the board renders — never a chat for a task
    // that belongs to a different item.
    expect(wrapper.find(CHAT_BODY).exists()).toBe(false)
    expect(wrapper.find(BOARD).exists()).toBe(true)
  })

  it('renders the DESIGN view and no kanban chat when the active item is a design', async () => {
    const store = useWorkspacesStore()
    store.workspaces = [
      {
        id: WS_ID,
        name: 'WS',
        items: [makeKanbanItem(), makeDesignItem([{ id: TASK_ID, name: 'Design Task' } as Task])],
      },
      // eslint-disable-next-line @typescript-eslint/no-explicit-any
    ] as any
    store.setActiveWorkspaceItem(DESIGN_ITEM_ID)
    store.setActiveTask(TASK_ID)
    rewireApiForFixture(store)
    wrapper = mountAppLayout()
    await flushPromises()

    // Design keeps its canvas + DesignChatDialog; the kanban chat branch is
    // gated on `item_type === 'kanban'` and must not claim a design item.
    expect(wrapper.find(CHAT_BODY).exists()).toBe(false)
    expect(wrapper.find(BOARD).exists()).toBe(false)
  })
})
