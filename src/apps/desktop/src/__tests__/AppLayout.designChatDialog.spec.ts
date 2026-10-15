// AppLayout — design chat dialog mount wiring.
//
// When the user clicks the top-right 💬 button in DesignView, the
// `open-chat` event fires with `{ pageId, pageName, workspaceItemTaskId }`.
// AppLayout's `handleDesignOpenChat` does:
//   1. workspacesStore.setActiveTask(payload.workspaceItemTaskId)
//   2. sets a local `activeDesignChatTaskId` ref
//   3. sets a local `activeDesignChatPageName` ref
// The new `<DesignChatDialog>` mount reads these local refs (NOT the
// store's `activeTask` computed — see bug fix comment below) and
// renders centred on top of the design canvas.
//
// Bug fix (2026-08-06, user report "chat button keep not popup,
// chatview"): the dialog's v-if gate was previously `activeTask &&
// ...item_type === 'design'`. The `activeTask` computed walks
// `workspaces.value[].items[].tasks` looking for the task — but
// in production design items have empty `tasks` arrays after
// `init()` (the backend's `getWorkspacesItems` returns items
// WITHOUT tasks for design items, AND `init()` skips the per-item
// `api.getTasks` fetch for `item_type === 'design'` — see
// workspaces.ts:639). So `activeTask` was always null for design
// items, the dialog v-if never fired, and the chat button had no
// effect. The fix: gate on `activeDesignChatTaskId` (a local ref
// captured from the openChat payload's FK) instead.
//
// This spec verifies the mount gates correctly:
//   - No design chat task set → dialog not rendered
//   - handleDesignOpenChat on a design item → dialog rendered
//   - handleDesignOpenChat on a non-design item (e.g. kanban) →
//     dialog NOT rendered (kanban renders its chat as its own view)
//   - The design dialog does NOT depend on the store's `activeTask`
//     computed (the bug) — verified by NOT populating tasks on
// the design item, simulating the production state where init() strips them. The test follows the
// established vue-teleport-vitest-document-queryselector pattern (attachTo: document.body +
// document.querySelector).

import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest'
import { setActivePinia, createPinia } from 'pinia'
import { mount, flushPromises, type VueWrapper } from '@vue/test-utils'
import { ref } from 'vue'
import AppLayout from '../components/AppLayout.vue'
import { useWorkspacesStore } from '../stores/workspaces'
import type { WorkspaceItem } from '../stores/workspaces'
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

function makeDesignItem(): WorkspaceItem {
  // No tasks array — matches the production state where init() strips design items of tasks. The
  // whole point of the bug fix is that the design chat dialog must work WITHOUT relying on the
  // store's `activeTask` computed (which would return null here).
  return {
    id: DESIGN_ITEM_ID,
    name: 'Design',
    item_type: 'design',
    tasks: [],
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
        KanbanView: true,
        DesignView: true,
        Chats: true,
        // NOTE: do NOT stub DesignChatDialog — we want the real
        // <Teleport to="body"> content to render so document.querySelector
        // can find the dialog testids.
      },
    },
  })
}

describe('AppLayout — design chat dialog mount', () => {
  let wrapper: VueWrapper | null = null

  beforeEach(() => {
    // jsdom 29 dropped localStorage — install stub before pinia loads.
    Object.defineProperty(globalThis, 'localStorage', {
      value: makeLocalStorageStub(),
      writable: true,
      configurable: true,
    })
    installBusForTests()
    // Stub the workspace-store API calls fired by AppLayout's onMounted
    // → initializeFromSystemFolder → init() → getWorkspaces(). Without
    // these, jsdom's fetch throws an ERR_INVALID_URL on every test
    // (no test server) — the error is caught by AppLayout's own
    // try/catch so the test still passes, but it floods the output.
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
    // eslint-disable-next-line @typescript-eslint/no-explicit-any
    vi.spyOn(api, 'listDesignPages').mockResolvedValue({ pages: [] } as any)
    vi.useFakeTimers()
    setActivePinia(createPinia())
    document.body.innerHTML = ''
  })

  // Mock the API calls in init() so they preserve the per-test fixture.

  // Each test calls this AFTER setting store.workspaces = [...] and
  // BEFORE mount, so init() doesn't wipe the fixture.
  function rewireApiForFixture(store: ReturnType<typeof useWorkspacesStore>) {
    // eslint-disable-next-line @typescript-eslint/no-explicit-any
    const snapshot = JSON.parse(JSON.stringify(store.workspaces)) as any[]

    vi.spyOn(api, 'getWorkspaces').mockImplementation(async () => {
      // Snapshot the fixture tree NOW (JSON): lazy init() replaces `workspaces.value` with
      // empty-items rows BEFORE calling getWorkspacesItems, so a live read would see the wiped
      // tree. eslint-disable-next-line @typescript-eslint/no-explicit-any
      return { workspaces: snapshot as any }
    })
    vi.spyOn(api, 'getWorkspacesItems').mockImplementation(async (wsId: string) => {
      // eslint-disable-next-line @typescript-eslint/no-explicit-any
      const ws = snapshot.find((w: any) => w.id === wsId)

      // eslint-disable-next-line @typescript-eslint/no-explicit-any
      return { items: (ws?.items ?? []) as any, count: ws?.items?.length ?? 0 }
    })
    vi.spyOn(api, 'getTasks').mockImplementation(async () => {
      return { tasks: [], has_more: false, next_cursor: null }
    })
    vi.spyOn(api, 'listDesignPages').mockImplementation(async () => {
      // eslint-disable-next-line @typescript-eslint/no-explicit-any
      return { pages: [] } as any
    })
  }

  afterEach(() => {
    vi.useRealTimers()
    vi.restoreAllMocks()
    wrapper?.unmount()
    wrapper = null
    document.querySelectorAll('[data-testid="design-chat-dialog"]').forEach((el) => el.remove())
    document
      .querySelectorAll('[data-testid="design-chat-dialog-root"]')
      .forEach((el) => el.remove())
  })

  // Helper to simulate the user clicking the 💬 button in DesignView. AppLayout exposes
  // `handleDesignOpenChat` via defineExpose so the test can invoke the same code path that
  // DesignView's emit chain triggers in production.
  const clickDesignChatButton = (pageId: string, pageName: string) => {
    if (!wrapper) throw new Error('wrapper not mounted')
    const exposed = wrapper.vm as unknown as {
      handleDesignOpenChat: (payload: {
        pageId: string
        pageName: string
        workspaceItemTaskId: string
      }) => Promise<void>
    }
    return exposed.handleDesignOpenChat({
      pageId,
      pageName,

      workspaceItemTaskId: TASK_ID,
    })
  }

  it('does NOT render DesignChatDialog when no design chat is open', async () => {
    const store = useWorkspacesStore()
    store.workspaces = [
      { id: WS_ID, name: 'WS', items: [makeDesignItem()] },
      // eslint-disable-next-line @typescript-eslint/no-explicit-any
    ] as any
    store.setActiveWorkspaceItem(DESIGN_ITEM_ID)
    rewireApiForFixture(store)
    wrapper = mountAppLayout()
    await flushPromises()
    expect(document.querySelector('[data-testid="design-chat-dialog"]')).toBeNull()
  })

  it('renders DesignChatDialog when handleDesignOpenChat fires for a design item (bug fix)', async () => {
    // THE BUG: before this fix, the dialog v-if was
    // `activeTask && item_type === 'design'`. The store's
    // `activeTask` computed returns null for design items
    // because their tasks array is empty post-init(). So clicking
    // 💬 had no visible effect — the dialog never appeared.
    //
    // THE FIX: the dialog now gates on `activeDesignChatTaskId`
    // (a local ref set by handleDesignOpenChat from the
    // workspaceItemTaskId FK), and uses a synthetic Task object
    // for ChatView's API. This test simulates the full bug

    // scenario: design item with NO tasks (production state),
    // user clicks 💬, dialog should appear.
    const store = useWorkspacesStore()
    store.workspaces = [
      {
        id: WS_ID,
        name: 'WS',
        items: [makeKanbanItem(), makeDesignItem()],
      },
      // eslint-disable-next-line @typescript-eslint/no-explicit-any
    ] as any
    store.setActiveWorkspaceItem(DESIGN_ITEM_ID)
    rewireApiForFixture(store)
    wrapper = mountAppLayout()
    await flushPromises()
    // Pre-condition: dialog NOT rendered before click
    expect(document.querySelector('[data-testid="design-chat-dialog"]')).toBeNull()
    // Simulate 💬 click on a design page
    await clickDesignChatButton('page_1', 'Login')
    await flushPromises()
    // Dialog appears (this is the bug fix)
    expect(document.querySelector('[data-testid="design-chat-dialog"]')).not.toBeNull()
  })

  it('does NOT render DesignChatDialog when handleDesignOpenChat fires for a non-design item (kanban)', async () => {
    const store = useWorkspacesStore()
    store.workspaces = [
      {
        id: WS_ID,
        name: 'WS',
        items: [makeKanbanItem(), makeDesignItem()],
      },
      // eslint-disable-next-line @typescript-eslint/no-explicit-any
    ] as any
    // Simulate: active is kanban (the most realistic case — user navigates to kanban, then 💬 button
    // shouldn't render design chat). But handleDesignOpenChat guards on item_type === 'design' so
    // this is a no-op.
    store.setActiveWorkspaceItem(KANBAN_ITEM_ID)
    rewireApiForFixture(store)
    wrapper = mountAppLayout()
    await flushPromises()
    // Try to call handleDesignOpenChat with the kanban item active.
    // The handler's early-return prevents any state mutation.
    await clickDesignChatButton('page_1', 'Login')
    await flushPromises()
    expect(document.querySelector('[data-testid="design-chat-dialog"]')).toBeNull()
  })

  it('renders dialog header with the active page name from the openChat payload', async () => {
    const store = useWorkspacesStore()
    store.workspaces = [
      {
        id: WS_ID,
        name: 'WS',
        items: [makeKanbanItem(), makeDesignItem()],
      },
      // eslint-disable-next-line @typescript-eslint/no-explicit-any
    ] as any
    store.setActiveWorkspaceItem(DESIGN_ITEM_ID)
    rewireApiForFixture(store)
    wrapper = mountAppLayout()
    await flushPromises()
    await clickDesignChatButton('page_1', 'Login Page')
    await flushPromises()
    const title = document.querySelector('[data-testid="design-chat-dialog-title"]')
    expect(title).not.toBeNull()
    expect(title?.textContent).toContain('Design Chat: Login Page')
  })

  it('closes the dialog when handleCloseTaskView is invoked via @close emit', async () => {
    // handleDesignOpenChat also calls workspacesStore.setActiveTask, which the dialog's open-state
    // watcher (designChatDialogOpen) mirrors. Clearing activeTask via handleCloseTaskView must flip
    // the watcher → dialog hidden.
    const store = useWorkspacesStore()
    store.workspaces = [
      {
        id: WS_ID,
        name: 'WS',
        items: [makeKanbanItem(), makeDesignItem()],
      },
      // eslint-disable-next-line @typescript-eslint/no-explicit-any
    ] as any
    store.setActiveWorkspaceItem(DESIGN_ITEM_ID)
    rewireApiForFixture(store)
    wrapper = mountAppLayout()
    await flushPromises()
    await clickDesignChatButton('page_1', 'Will Close')
    await flushPromises()
    expect(document.querySelector('[data-testid="design-chat-dialog"]')).not.toBeNull()
    // Simulate the ✕ button → emits 'close' → AppLayout's
    // handleCloseTaskView → setActiveTask(null) → local ref cleared
    store.setActiveTask(null)
    await flushPromises()
    expect(document.querySelector('[data-testid="design-chat-dialog"]')).toBeNull()
  })
})
