/** Behavioural test for the design-page-sync fix. Plan:
 * docs/superpowers/plans/2026-08-06-design-page-sync-fix.md Tests: 1. setActiveDesignPage(newId) on
 * the store → local activePageId updates within one tick. 2. */
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest'
import { flushPromises, mount } from '@vue/test-utils'
import { setActivePinia, createPinia } from 'pinia'
import DesignView from '../DesignView.vue'
import { useWorkspacesStore } from '../../../stores/workspaces'
import type { WorkspaceItem } from '../../../stores/workspaces'

const WS_ID = 'ws_test'
const DESIGN_ID = 'item_design_sync'
const PAGE_ID_1 = 'page_first'
const PAGE_ID_2 = 'page_second'

function makeDesignItem(overrides: Partial<WorkspaceItem> = {}): WorkspaceItem {
  return {
    id: DESIGN_ID,
    name: 'Design Sync',
    item_type: 'design',
    path: '/tmp/design-sync',
    tasks: [],
    ...overrides,
  }
}

function makePage(id: string, name: string) {
  return {
    id,
    workspace_item_id: DESIGN_ID,
    name,
    workspace_item_task_id: `task_${id}`,
    width: 1440,
    height: 1024,
    position: 0,
    created_at: '2026-08-06 00:00:00',
    updated_at: '2026-08-06 00:00:00',
  }
}

function mountDesignView() {
  return mount(DesignView, {
    props: { item: makeDesignItem(), workspaceId: WS_ID, itemId: DESIGN_ID },
  })
}

describe('DesignView — activePageId syncs from store activeDesignPageId', () => {
  let originalFetch: typeof fetch
  let fetchMock: ReturnType<typeof vi.fn>

  beforeEach(() => {
    setActivePinia(createPinia())
    originalFetch = global.fetch
    fetchMock = vi.fn()
    global.fetch = fetchMock as unknown as typeof fetch
    // Initial listDesignPages response with 2 pages.
    fetchMock.mockResolvedValueOnce({
      ok: true,
      status: 200,
      json: () => Promise.resolve({
        pages: [makePage(PAGE_ID_1, 'Alpha'), makePage(PAGE_ID_2, 'Beta')],
        count: 2,
      }),
      text: () => Promise.resolve(''),
    } as Response)
  })

  afterEach(() => {
    fetchMock.mockReset()
    global.fetch = originalFetch
  })

  it('sets initial activePageId from the store after loadPages()', async () => {
    // Pre-set the store so the first click is a sync test, not an
    // initial-load test.
    const store = useWorkspacesStore()
    store.setActiveDesignPage(PAGE_ID_1)
    const wrapper = mountDesignView()
    await flushPromises()
    const vm = wrapper.vm as unknown as { activePageId: string }
    expect(vm.activePageId).toBe(PAGE_ID_1)
    wrapper.unmount()
  })

  it('mirrors store.activeDesignPageId changes into local activePageId (the bug fix)', async () => {
    const store = useWorkspacesStore()
    store.setActiveDesignPage(PAGE_ID_1)
    const wrapper = mountDesignView()
    await flushPromises()
    const vm = wrapper.vm as unknown as { activePageId: string }
    expect(vm.activePageId).toBe(PAGE_ID_1)

    // Simulate the user clicking a DIFFERENT page in the sidebar.
    store.setActiveDesignPage(PAGE_ID_2)
    await flushPromises()

    // The fix: local activePageId should now be PAGE_ID_2.
    expect(vm.activePageId).toBe(PAGE_ID_2)
    wrapper.unmount()
  })

  it('does NOT mirror when the store value matches the local value (no-op guard)', async () => {
    // Setting the store to the same value the local ref already has should not trigger any work. We
    // assert this implicitly: the fix uses an equality guard so a no-op set doesn't fire the
    // elements-fetch watcher below (which would be a redundant GET).
    const store = useWorkspacesStore()
    store.setActiveDesignPage(PAGE_ID_1)
    const wrapper = mountDesignView()
    await flushPromises()
    const vm = wrapper.vm as unknown as { activePageId: string }

    // After mount, fetchMock has been called once for loadPages.
    // Reset the spy to count only subsequent calls.
    fetchMock.mockClear()

    // Setting the SAME pageId shouldn't trigger another fetch.
    store.setActiveDesignPage(PAGE_ID_1)
    await flushPromises()
    expect(vm.activePageId).toBe(PAGE_ID_1)
    expect(fetchMock).not.toHaveBeenCalled()
    wrapper.unmount()
  })

  it('handleSelectPage (local flow) still routes through the store (regression check)', async () => {
    const store = useWorkspacesStore()
    store.setActiveDesignPage(PAGE_ID_1)
    const wrapper = mountDesignView()
    await flushPromises()
    const vm = wrapper.vm as unknown as {
      activePageId: string
      handleSelectPage: (id: string) => void
    }
    expect(vm.activePageId).toBe(PAGE_ID_1)
    // Existing flow: clicking a page row inside DesignView itself
    // (e.g. the empty state's "+ Add the first page" followed by
    // a different page picker). Should still work.
    vm.handleSelectPage(PAGE_ID_2)
    expect(vm.activePageId).toBe(PAGE_ID_2)
    expect(store.activeDesignPageId).toBe(PAGE_ID_2)
    wrapper.unmount()
  })
})
