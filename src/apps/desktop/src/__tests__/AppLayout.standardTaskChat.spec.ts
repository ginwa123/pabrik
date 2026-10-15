// AppLayout — non-kanban / non-design task chat (folder / memory / chat items).
//
// Regression test for the blank chatview bug
// (task_1787027750097, 2026-08-14): when the URL was
//   ?view=workspace&workspaceId=X&itemId=Y/chat/task_Z
// and the workspace item Y was NOT a kanban or design (e.g. a folder
// item holding a "standard" chat task), AppLayout's v-else-if chain
// had no matching branch:
//   - KanbanView / the kanban chat branch — gated on item_type === 'kanban'
//   - DesignView / DesignChatDialog — gated on item_type === 'design'
//   - <ChatView v-else-if="activeChatId.startsWith('chat-')">
//     — gated on activeChatId, which setActiveTask CLEARS
//   - <Chats v-else-if="currentView === 'chat'">
//     — gated on currentView, which is 'workspace' here
//   - workspace folder preview — gated on !activeWorkspaceItem, which
//     is false here
// None matched → right pane rendered BLANK. The fix added a new branch in AppLayout.vue that
// renders <ChatView> directly when: activeWorkspaceItem && activeWorkspaceItem.item_type !==
// 'kanban' && activeWorkspaceItem.item_type !== 'design' && activeTask
// using the task id as the chat session id (migration 052 invariant:
// task.id == session.id).
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest'
import { setActivePinia, createPinia } from 'pinia'
import { mount, type VueWrapper } from '@vue/test-utils'
import { createApp, ref, nextTick } from 'vue'
import AppLayout from '../components/AppLayout.vue'
import { useWorkspacesStore } from '../stores/workspaces'
import type { WorkspaceItem, Task } from '../stores/workspaces'
import { makeLocalStorageStub } from './helpers'
import {
  installSseBus,
  __resetSseBus,
  __setSseBusGlobalClient,
} from '../helpers/sseBus'
import type { SseClient } from '../helpers/sseClient'

const { useRouteMock, useRouterMock } = vi.hoisted(() => ({
  useRouteMock: vi.fn(() => ({
    query: {} as Record<string, string>,
    path: '/app',
    fullPath: '/app',
  })),
  useRouterMock: vi.fn(() => ({ replace: vi.fn(), push: vi.fn(), back: vi.fn() })),
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

const WS_ID = 'ws_standard'
const FOLDER_ITEM_ID = 'item_folder_1'
const TASK_ID = 'task_folder_1'

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
  installSseBus(createApp({}))
  __setSseBusGlobalClient(makeStubClient())
}

function makeFolderItem(tasks: Task[] = []): WorkspaceItem {
  return {
    id: FOLDER_ITEM_ID,
    name: 'My Project',
    item_type: 'folder',
    path: '/abs/path',
    tasks,
    // eslint-disable-next-line @typescript-eslint/no-explicit-any
  } as any
}

function makeMemoryItem(tasks: Task[] = []): WorkspaceItem {
  return {
    id: 'item_memory_1',
    name: 'Memory',
    item_type: 'memory',
    tasks,
    // eslint-disable-next-line @typescript-eslint/no-explicit-any
  } as any
}

function makeChatItem(tasks: Task[] = []): WorkspaceItem {
  return {
    id: 'item_chat_1',
    name: 'Chat',
    item_type: 'chat',
    tasks,
    // eslint-disable-next-line @typescript-eslint/no-explicit-any
  } as any
}

function mountApp(): VueWrapper {
  return mount(AppLayout, {
    global: {
      mocks: { $router: { replace: vi.fn() } },
      provide: { processingState: ref<Record<string, boolean>>({}) },
      stubs: {
        // Custom ChatView stub: the default `true` stub renders no HTML, which makes prop-level
        // assertions impossible.
        // Bind the chat-id to a data attribute so the test can verify which branch actually mounted
        // <ChatView> (the new branch passes `chat-${activeTask.id}`, the standalone branch passes
        // `activeChatId`).
        ChatView: {
          template:
            '<div data-testid="chatview-stub" :data-chat-id="chatId" :data-chat-name="chatName" :data-chat-cwd="cwd" />',
          props: ['chatId', 'chatName', 'type', 'cwd', 'taskId', 'taskName', 'projectName', 'showHeader'],
        },
        Sidebar: true,
        RightSidebar: true,
        GitFileViewer: true,
        SkillDetail: true,
        Chats: true,
        SettingsView: true,
        CodeEditor: true,
        KanbanView: true,
        DesignView: true,
        DesignChatDialog: true,
      },
    },
    attachTo: document.body,
  })
}

describe('AppLayout — standard task chat (folder / memory / chat items)', () => {
  beforeEach(() => {
    setActivePinia(createPinia())
    Object.defineProperty(globalThis, 'localStorage', {
      value: makeLocalStorageStub(),
      writable: true,
      configurable: true,
    })
    installBusForTests()
    vi.spyOn(api, 'getWorkspaces').mockResolvedValue({ workspaces: [] })
    vi.spyOn(api, 'getWorkspacesItems').mockResolvedValue({ items: [], count: 0 })
    vi.spyOn(api, 'getTasks').mockResolvedValue({ tasks: [], has_more: false, next_cursor: null })
    vi.spyOn(api, 'getSystemFolder').mockResolvedValue({
      entries: [],
      path: '/',
      absolute: '/',
      home: '/',
      // eslint-disable-next-line @typescript-eslint/no-explicit-any
    } as any)
    // eslint-disable-next-line @typescript-eslint/no-explicit-any
    vi.spyOn(api, 'getSession').mockResolvedValue({ cwd: '' } as any)
    vi.spyOn(api, 'getChatHistory').mockResolvedValue({
      messages: [],
      has_more: false,
      next_cursor: null,
      total: 0,
      // eslint-disable-next-line @typescript-eslint/no-explicit-any
    } as any)
    useRouteMock.mockReset()
    useRouterMock.mockReset()
  })

  afterEach(() => {
    __resetSseBus()
    vi.restoreAllMocks()
  })

  it('renders <ChatView> when active task belongs to a folder item (regression: blank chatview)', async () => {
    // Pre-fix: NO branch matched → right pane rendered blank. Post-fix: this v-else-if matches:
    // activeWorkspaceItem.item_type !== 'kanban' && !== 'design' && activeTask
    const ws = useWorkspacesStore()
    ws.workspaces = [
      {
        id: WS_ID,
        name: 'WS',
        items: [makeFolderItem([{ id: TASK_ID, name: 'New Chat', task_type: 'standard' } as Task])],
      // eslint-disable-next-line @typescript-eslint/no-explicit-any
      } as any,
    ]
    ws.setActiveWorkspaceItem(FOLDER_ITEM_ID)
    ws.setActiveTask(TASK_ID)
    const wrapper = mountApp()
    await nextTick()
    // The new branch renders <ChatView> with the task id as chat-id.
    const chatView = wrapper.find('[data-testid="chatview-stub"]')
    expect(chatView.exists()).toBe(true)
    expect(chatView.attributes('data-chat-id')).toBe(`chat-${TASK_ID}`)
    wrapper.unmount()
  })

  it('renders <ChatView> when active task belongs to a memory item', async () => {
    const ws = useWorkspacesStore()
    ws.workspaces = [
      {
        id: WS_ID,
        name: 'WS',
        items: [makeMemoryItem([{ id: TASK_ID, name: 'Memory Task' } as Task])],
      // eslint-disable-next-line @typescript-eslint/no-explicit-any
      } as any,
    ]
    ws.setActiveWorkspaceItem('item_memory_1')
    ws.setActiveTask(TASK_ID)
    const wrapper = mountApp()
    await nextTick()
    expect(wrapper.find('[data-testid="chatview-stub"]').exists()).toBe(true)
    wrapper.unmount()
  })

  it('renders <ChatView> when active task belongs to a chat item', async () => {
    const ws = useWorkspacesStore()
    ws.workspaces = [
      {
        id: WS_ID,
        name: 'WS',
        items: [makeChatItem([{ id: TASK_ID, name: 'Chat Task' } as Task])],
      // eslint-disable-next-line @typescript-eslint/no-explicit-any
      } as any,
    ]
    ws.setActiveWorkspaceItem('item_chat_1')
    ws.setActiveTask(TASK_ID)
    const wrapper = mountApp()
    await nextTick()
    expect(wrapper.find('[data-testid="chatview-stub"]').exists()).toBe(true)
    wrapper.unmount()
  })

  it('does NOT render <ChatView> when no active task is set on the folder item', async () => {
    // activeWorkspaceItem is set (folder) but activeTask is null → the new branch's `&& activeTask`
    // guard fails, falling through to the workspace-folder-preview empty state. No chat renders
    // because there's nothing to chat with.
    const ws = useWorkspacesStore()
    ws.workspaces = [
      {
        id: WS_ID,
        name: 'WS',
        items: [makeFolderItem([{ id: TASK_ID, name: 'New Chat' } as Task])],
      // eslint-disable-next-line @typescript-eslint/no-explicit-any
      } as any,
    ]
    ws.setActiveWorkspaceItem(FOLDER_ITEM_ID)
    // No setActiveTask call.
    const wrapper = mountApp()
    await nextTick()
    expect(wrapper.find('[data-testid="chatview-stub"]').exists()).toBe(false)
    wrapper.unmount()
  })

  it('does NOT route a kanban task through this branch (its chat is the kanban view)', async () => {
    // This branch is gated on `item_type !== 'kanban' && !== 'design'`, so a kanban task is claimed
    // by the kanban chat branch instead. Guards against an accidental double-mount.
    // Both branches mount a <ChatView>, so the discriminator is the chat id: THIS branch passes
    // `chat-${task.id}` while the kanban branch passes the bare task id (migration 052).
    const ws = useWorkspacesStore()
    ws.workspaces = [
      {
        id: WS_ID,
        name: 'WS',
        items: [
          {
            id: 'item_kanban_1',
            name: 'Kanban',
            item_type: 'kanban',
            tasks: [{ id: TASK_ID, name: 'Kanban Task' } as Task],
            kanban_columns: [],
          // eslint-disable-next-line @typescript-eslint/no-explicit-any
          } as any,
        ],
      // eslint-disable-next-line @typescript-eslint/no-explicit-any
      } as any,
    ]
    ws.setActiveWorkspaceItem('item_kanban_1')
    ws.setActiveTask(TASK_ID)
    const wrapper = mountApp()
    await nextTick()
    const stub = wrapper.find('[data-testid="chatview-stub"]')
    expect(stub.exists()).toBe(true)
    expect(stub.attributes('data-chat-id')).toBe(TASK_ID)
    expect(stub.attributes('data-chat-id')).not.toBe(`chat-${TASK_ID}`)
    wrapper.unmount()
  })

  it('passes the workspace item path as :cwd to <ChatView> (regression: empty cwd_session in sendChatMessage)', async () => {
    // REGRESSION (task_1787027750097, follow-up): before the fix, the new branch (and the
    // standalone ChatView branch above) did NOT pass `:cwd` to <ChatView>.
    // ChatView's onMounted then fell back to `loadChatHistory` → `data.cwd`, which is empty when
    // `sessions.cwd` is NULL (the user's bug report showed the network panel with `cwd_session:
    // ""`).
    // The fix adds an `effectiveChatCwd` computed in AppLayout (`chatSessionCwd ||
    // activeWorkspaceItem.path`) and passes it as the `:cwd` prop to both ChatView mounts.
    const FOLDER_PATH = '/home/user/projects/myapp'
    const ws = useWorkspacesStore()
    ws.workspaces = [
      {
        id: WS_ID,
        name: 'WS',
        items: [
          // FOLDER item with a path — the cwd source for the chat.
          {
            ...makeFolderItem([
              { id: TASK_ID, name: 'New Chat', task_type: 'standard' } as Task,
            ]),
            path: FOLDER_PATH,
          // eslint-disable-next-line @typescript-eslint/no-explicit-any
          } as any,
        ],
      // eslint-disable-next-line @typescript-eslint/no-explicit-any
      } as any,
    ]
    ws.setActiveWorkspaceItem(FOLDER_ITEM_ID)
    ws.setActiveTask(TASK_ID)
    const wrapper = mountApp()
    await nextTick()
    const chatView = wrapper.find('[data-testid="chatview-stub"]')
    expect(chatView.exists()).toBe(true)
    // The :cwd prop must be the folder's path — ChatView's onMounted reads `if (props.cwd)
    // sessionCwd.value = props.cwd`, which becomes the `cwd_session` field on every
    // api.sendChatMessage call. Without this, the field was `""`.
    expect(chatView.attributes('data-chat-cwd')).toBe(FOLDER_PATH)
    wrapper.unmount()
  })
})