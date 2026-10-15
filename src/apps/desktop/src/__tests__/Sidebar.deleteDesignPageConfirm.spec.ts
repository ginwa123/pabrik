/**
 * Behavioural tests for `Sidebar.handleDeleteDesignPage` confirmation flow
 * (task 1785912441877, 2026-08-06).
 *
 * **Bug fixed (2026-08-06):** Clicking × on a design page in the sidebar
 * tree immediately called `workspacesStore.deleteDesignPage` — too easy to
 * nuke a page by accident. Now the click opens the existing `ConfirmDialog`
 * (already wired via `openDeleteConfirm(...)`) and only DELETEs after the
 * user explicitly clicks "Delete" in the dialog.
 *
 * Mirrors the existing confirmation pattern for workspaces / items / tasks
 * (`Sidebar.handleDeleteWorkspace`, `handleDeleteItem`, `handleDeleteTask`).
 *
 * No static-contract checks — every assertion is on the live dialog state
 * + the store action called. The dialog is rendered through `<Teleport
 * to="body">` so DOM assertions use `document.body.querySelector` instead
 * of `wrapper.find` (see skill `vue-teleport-vitest-document-queryselector`).
 */
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest'
import { setActivePinia, createPinia } from 'pinia'
import { nextTick, ref, createApp } from 'vue'
import { mount } from '@vue/test-utils'

import Sidebar from '../components/shell/Sidebar.vue'
import * as api from '../api'
import { useWorkspacesStore } from '../stores/workspaces'
import { makeLocalStorageStub } from './helpers'
import {
  installSseBus,
  __resetSseBus,
  __setSseBusGlobalClient,
} from '../helpers/sseBus'
import type { SseClient } from '../helpers/sseClient'

 
// eslint-disable-next-line @typescript-eslint/no-explicit-any
function makeStubClient(initial: 'connecting'): any {
  return {
    state: initial,
    lastError: null,
    getState: () => initial,
    isConnected: () => false,
    onEvent: () => {},
    onError: () => {},
    onStateChange: () => () => {},
    close: () => {},
  }
}

const { useRouteMock, useRouterMock } = vi.hoisted(() => ({
  useRouteMock: vi.fn(() => ({ query: {} as Record<string, string>, path: '/app', fullPath: '/app' })),
  useRouterMock: vi.fn(() => ({ replace: vi.fn(), push: vi.fn() })),
}))
vi.mock('vue-router', async () => {
  const actual = await vi.importActual<typeof import('vue-router')>('vue-router')
  return { ...actual, useRoute: useRouteMock, useRouter: useRouterMock }
})

const WS_ID = 'ws_design_page_confirm'
const ITEM_ID = 'item_design_page_confirm'
const PAGE_ID = 'page_to_delete'

const baseItem = {
  id: ITEM_ID,
  name: 'design',
  item_type: 'design',
  path: '/tmp',
  kanban_columns: [],
  tasks: [],
  isLoaded: true,
  isLoading: false,
}

function mountSidebar() {
  return mount(Sidebar, {
    attachTo: document.body,
    global: {
      mocks: { $router: { replace: vi.fn() } },
      provide: { processingState: ref<Record<string, boolean>>({}) },
    },
  })
}

// The <ConfirmDialog> uses <Teleport to="body">, so its DOM lives in
// document.body. The sidebar's wrapper.find does NOT see teleported
// nodes. Use document.querySelector to assert dialog visibility.
function dialogInDom(): Element | null {
  return document.body.querySelector('.fixed.inset-0')
}

function findButtonByText(re: RegExp): HTMLButtonElement | undefined {
  return Array.from(document.body.querySelectorAll('button')).find(
    (b) => re.test(b.textContent ?? ''),
  )
}

describe('Sidebar.handleDeleteDesignPage — confirmation dialog (2026-08-06)', () => {
  beforeEach(() => {
    setActivePinia(createPinia())
    document.body.innerHTML = ''
    Object.defineProperty(globalThis, 'localStorage', {
      value: makeLocalStorageStub(),
      writable: true,
      configurable: true,
    })
    __resetSseBus()
    const app = createApp({})
    installSseBus(app)
    __setSseBusGlobalClient(makeStubClient('connecting') as SseClient)
    vi.spyOn(api, 'getChats').mockResolvedValue({
      sessions: [],
      has_more: false,
      next_cursor: null,
      total: 0,
    })
    useRouteMock.mockImplementation(() => ({
      query: {},
      path: '/app',
      fullPath: '/app',
    }))
  })

  afterEach(() => {
    __resetSseBus()
    vi.restoreAllMocks()
  })

  it('clicking × on a design page opens the ConfirmDialog (does NOT delete immediately)', async () => {
    const store = useWorkspacesStore()
     
    const deleteSpy = vi.spyOn(store, 'deleteDesignPage').mockResolvedValue(undefined)
    // eslint-disable-next-line @typescript-eslint/no-explicit-any
    store.workspaces = [{ id: WS_ID, name: 'WS', items: [baseItem] }] as any

 

    const wrapper = mountSidebar()
    // eslint-disable-next-line @typescript-eslint/no-explicit-any
    const sidebar = wrapper.vm as any
    // simulate the @delete-design-page emit chain from DesignPageRow →
    // WorkspaceItem → ProjectsList → Sidebar's `handleDeleteDesignPage`.
    sidebar.handleDeleteDesignPage(WS_ID, ITEM_ID, PAGE_ID)
    await nextTick()

    // No delete was issued yet — the user must confirm first.
    expect(deleteSpy).not.toHaveBeenCalled()
    // The ConfirmDialog should now be visible (teleported to body).
    expect(dialogInDom()).not.toBeNull()
    // Title + message both reference the delete action.
    expect(document.body.textContent ?? '').toMatch(/delete.*page/i)
    wrapper.unmount()
  })

   
  it('confirming the dialog calls workspacesStore.deleteDesignPage exactly once', async () => {
    const store = useWorkspacesStore()
    const deleteSpy = vi.spyOn(store, 'deleteDesignPage').mockResolvedValue(undefined)
     
    // eslint-disable-next-line @typescript-eslint/no-explicit-any
    store.workspaces = [{ id: WS_ID, name: 'WS', items: [baseItem] }] as any

    const wrapper = mountSidebar()
    // eslint-disable-next-line @typescript-eslint/no-explicit-any
    const sidebar = wrapper.vm as any
    sidebar.handleDeleteDesignPage(WS_ID, ITEM_ID, PAGE_ID)
    await nextTick()

    // Click the confirm button (the red "Delete" inside the dialog).
    const confirmBtn = findButtonByText(/^delete$/i)
    expect(confirmBtn).toBeDefined()
    confirmBtn!.click()
    await nextTick()

    expect(deleteSpy).toHaveBeenCalledTimes(1)
    expect(deleteSpy).toHaveBeenCalledWith(WS_ID, ITEM_ID, PAGE_ID)
    wrapper.unmount()
   
  })

  it('cancelling the dialog does NOT call workspacesStore.deleteDesignPage', async () => {
     
    const store = useWorkspacesStore()
    const deleteSpy = vi.spyOn(store, 'deleteDesignPage').mockResolvedValue(undefined)
    // eslint-disable-next-line @typescript-eslint/no-explicit-any
    store.workspaces = [{ id: WS_ID, name: 'WS', items: [baseItem] }] as any

    const wrapper = mountSidebar()
    // eslint-disable-next-line @typescript-eslint/no-explicit-any
    const sidebar = wrapper.vm as any
    sidebar.handleDeleteDesignPage(WS_ID, ITEM_ID, PAGE_ID)
    await nextTick()

    // Click the cancel button inside the dialog.
    const cancelBtn = findButtonByText(/^cancel$/i)
    expect(cancelBtn).toBeDefined()
    cancelBtn!.click()
    await nextTick()

     
    expect(deleteSpy).not.toHaveBeenCalled()
    wrapper.unmount()
  })

 

  it('clicking the dialog backdrop does NOT call workspacesStore.deleteDesignPage', async () => {
    const store = useWorkspacesStore()
    const deleteSpy = vi.spyOn(store, 'deleteDesignPage').mockResolvedValue(undefined)
    // eslint-disable-next-line @typescript-eslint/no-explicit-any
    store.workspaces = [{ id: WS_ID, name: 'WS', items: [baseItem] }] as any

    const wrapper = mountSidebar()
    // eslint-disable-next-line @typescript-eslint/no-explicit-any
    const sidebar = wrapper.vm as any
    sidebar.handleDeleteDesignPage(WS_ID, ITEM_ID, PAGE_ID)
    await nextTick()

    const outerWrap = dialogInDom()
    expect(outerWrap).not.toBeNull()
    // The dialog wrapper listens for click.self — clicking the outer
    // backdrop div closes the dialog without firing the confirm path.
    outerWrap!.dispatchEvent(new MouseEvent('click', { bubbles: true }))
    await nextTick()

    expect(deleteSpy).not.toHaveBeenCalled()
    wrapper.unmount()
  })

  it('onConfirm error path surfaces the failure via notifyError (no unhandled rejection)', async () => {
    // Regression guard for the only piece of new logic in this diff: the try/catch around
    // `workspacesStore.deleteDesignPage` MUST call `useNotificationStore().notifyError('Failed to
    // delete page', ...)` on rejection so a failed backend DELETE isn't a silent UX failure.

    // Without this test, a future refactor could remove the try/catch and the dialog would still
    // appear to work (4 happy-path tests pass).
    const store = useWorkspacesStore()
    const { useNotificationStore } = await import('../stores/notifications')
    vi.spyOn(store, 'deleteDesignPage').mockRejectedValue(new Error('boom'))
    const notifySpy = vi.spyOn(useNotificationStore(), 'notifyError').mockImplementation(() => {})
    // eslint-disable-next-line @typescript-eslint/no-explicit-any
    store.workspaces = [{ id: WS_ID, name: 'WS', items: [baseItem] }] as any

    const wrapper = mountSidebar()
    // eslint-disable-next-line @typescript-eslint/no-explicit-any
    const sidebar = wrapper.vm as any
    sidebar.handleDeleteDesignPage(WS_ID, ITEM_ID, PAGE_ID)
    await nextTick()

    const confirmBtn = findButtonByText(/^delete$/i)
    expect(confirmBtn).toBeDefined()
    confirmBtn!.click()
    await nextTick()
    // Flush the microtask queue so the onConfirm async catches its
    // rejection and calls notifyError.
    await Promise.resolve()
    await nextTick()

    expect(notifySpy).toHaveBeenCalledWith('Failed to delete page', 'boom')
    wrapper.unmount()
  })
})