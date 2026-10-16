/** Behavioural mount tests for DesignView.vue. */
import { flushPromises, mount } from '@vue/test-utils'
import { setActivePinia, createPinia } from 'pinia'
import { afterEach, beforeEach, describe as describeRuntime, expect as expectRuntime, it as itRuntime, vi } from 'vitest'
import DesignView from '../components/design/DesignView.vue'
import { useWorkspacesStore } from '../stores/workspaces'
import type { WorkspaceItem } from '../stores/workspaces'

const WS_ID = 'ws_1'
const ITEM_ID = 'item_1'

function makeItem(): WorkspaceItem {
  return {
    id: ITEM_ID,
    name: 'Test',
    item_type: 'design',
    path: '/tmp/test',
    design_elements: [],
  }
}

describeRuntime('DesignView → workspacesStore active page id', () => {
  const originalFetch = global.fetch
  const fetchMock = vi.fn()

  beforeEach(() => {
    setActivePinia(createPinia())
  })

  afterEach(() => {
    fetchMock.mockReset()
    global.fetch = originalFetch
  })

  itRuntime('publishes the active page id to the workspaces store on mount and on tab switch', async () => {
    fetchMock.mockResolvedValue({
      ok: true, status: 200,
      json: () => Promise.resolve({
        pages: [
          { id: 'page_first', workspace_item_id: ITEM_ID, name: 'A', width: 1440, height: 1024, position: 0, created_at: '', updated_at: '' },
          { id: 'page_second', workspace_item_id: ITEM_ID, name: 'B', width: 1440, height: 1024, position: 1, created_at: '', updated_at: '' },
        ],
        count: 2,
      }),
      text: () => Promise.resolve(''),
    } as Response)
    global.fetch = fetchMock as unknown as typeof fetch
    const wrapper = mount(DesignView, {
      props: { item: makeItem(), workspaceId: WS_ID, itemId: ITEM_ID },
    })
    await flushPromises()
    expectRuntime(useWorkspacesStore().activeDesignPageId).toBe('page_first')
    wrapper.unmount()
    // Regression (2026-07-29): pre-fix unmount cleared activeDesignPageId to ''. That broke the
    // chat-toggle flow: AppLayout's v-else-if chain renders TWO <DesignView> instances for the same
    // item (single-column + 3-column), and clicking 💬 swaps them.
    expectRuntime(useWorkspacesStore().activeDesignPageId).toBe('page_first')
  })

  itRuntime('preserves activeDesignPageId across unmount/remount (chat-toggle regression)', async () => {
    // Direct reproduction of the user's reported bug: open the design on a NON-default page (Kanban
    // Mode, page_third), then unmount + remount (which is exactly what happens when the user clicks
    // 💬 in AppLayout's v-else-if chain.
    fetchMock.mockResolvedValue({
      ok: true, status: 200,
      json: () => Promise.resolve({
        pages: [
          { id: 'page_first', workspace_item_id: ITEM_ID, name: 'AI Chat View', width: 1440, height: 1024, position: 0, created_at: '', updated_at: '' },
          { id: 'page_second', workspace_item_id: ITEM_ID, name: 'Settings', width: 1440, height: 1024, position: 1, created_at: '', updated_at: '' },
          { id: 'page_third', workspace_item_id: ITEM_ID, name: 'Kanban Mode', width: 1440, height: 1024, position: 2, created_at: '', updated_at: '' },
        ],
        count: 3,
      }),
      text: () => Promise.resolve(''),
    } as Response)
    global.fetch = fetchMock as unknown as typeof fetch
    const ws = useWorkspacesStore()

    // First mount: user lands on first page (no URL restore).
    const wrapper1 = mount(DesignView, {
      props: { item: makeItem(), workspaceId: WS_ID, itemId: ITEM_ID },
    })
    await flushPromises()
    expectRuntime(ws.activeDesignPageId).toBe('page_first')

    // User clicks the "Kanban Mode" tab.
    const vm1 = wrapper1.vm as unknown as {
      activePageId: string
      pages: Array<{ id: string }>
    }
    vm1.activePageId = 'page_third'
    await flushPromises()
    expectRuntime(ws.activeDesignPageId).toBe('page_third')

    // Simulate the chat-toggle unmount/remount cycle that
    // AppLayout's v-else-if chain performs when the user clicks 💬.
    wrapper1.unmount()
    await flushPromises()

    // Regression assertion: the store value must still be
    // 'page_third', NOT ''. Pre-fix, this was ''.
    expectRuntime(ws.activeDesignPageId).toBe('page_third')

    // Now remount (this is the 3-column DesignView).
    const wrapper2 = mount(DesignView, {
      props: { item: makeItem(), workspaceId: WS_ID, itemId: ITEM_ID },
    })
    await flushPromises()

    // The user's last-clicked tab must be restored.
    const vm2 = wrapper2.vm as unknown as { activePageId: string }
    expectRuntime(vm2.activePageId).toBe('page_third')
    expectRuntime(ws.activeDesignPageId).toBe('page_third')

    wrapper2.unmount()
  })

  itRuntime('cross-item navigation: stale activeDesignPageId does not bleed across design items', async () => {
    // When the user navigates from designItem A (page PA) to designItem B, the DesignView unmounts.
    // The store still holds PA's id.
    const ws = useWorkspacesStore()

    // Pre-seed the store with a stale page id from item A.
    ws.setActiveDesignPage('page_from_item_A')

    // Now mock fetch for item B (no overlap with item A's pages).
    fetchMock.mockResolvedValue({
      ok: true, status: 200,
      json: () => Promise.resolve({
        pages: [
          { id: 'page_B1', workspace_item_id: 'item_B', name: 'B-first', width: 1440, height: 1024, position: 0, created_at: '', updated_at: '' },
          { id: 'page_B2', workspace_item_id: 'item_B', name: 'B-second', width: 1440, height: 1024, position: 1, created_at: '', updated_at: '' },
        ],
        count: 2,
      }),
      text: () => Promise.resolve(''),
    } as Response)
    global.fetch = fetchMock as unknown as typeof fetch

    const itemB: WorkspaceItem = {
      id: 'item_B',
      name: 'Design B',
      item_type: 'design',
      path: '/tmp/test',
      design_elements: [],
    }
    const wrapper = mount(DesignView, {
      props: { item: itemB, workspaceId: WS_ID, itemId: 'item_B' },
    })
    await flushPromises()

    // loadPages must have validated that 'page_from_item_A' is NOT
    // in item B's pages and fallen back to 'page_B1' (the first).
    const vm = wrapper.vm as unknown as { activePageId: string }
    expectRuntime(vm.activePageId).toBe('page_B1')
    expectRuntime(ws.activeDesignPageId).toBe('page_B1')

    wrapper.unmount()
  })

  itRuntime('picks the active page from the store when it exists in the loaded pages (URL restore)', async () => {
    // AppLayout's URL restore watcher sets activeDesignPageId from the ?pageId=Z query before
    // DesignView mounts. DesignView must honor the store value (not always default to the first
    // page) so a page reload restores the user's last-clicked tab.
    fetchMock.mockResolvedValue({
      ok: true, status: 200,
      json: () => Promise.resolve({
        pages: [
          { id: 'page_first', workspace_item_id: ITEM_ID, name: 'A', width: 1440, height: 1024, position: 0, created_at: '', updated_at: '' },
          { id: 'page_second', workspace_item_id: ITEM_ID, name: 'B', width: 1440, height: 1024, position: 1, created_at: '', updated_at: '' },
        ],
        count: 2,
      }),
      text: () => Promise.resolve(''),
    } as Response)
    global.fetch = fetchMock as unknown as typeof fetch
    const ws = useWorkspacesStore()
    // Simulate AppLayout's pendingUrlRestore watcher having fired.
    ws.setActiveDesignPage('page_second')
    const wrapper = mount(DesignView, {
      props: { item: makeItem(), workspaceId: WS_ID, itemId: ITEM_ID },
    })
    await flushPromises()
    // The internal activePageId should be page_second (from the store),
    // not page_first (the first page default).
    expectRuntime((wrapper.vm as unknown as { activePageId: string }).activePageId).toBe('page_second')
    // The store value is still page_second (unchanged by the load).
    expectRuntime(ws.activeDesignPageId).toBe('page_second')
    wrapper.unmount()
  })
})

