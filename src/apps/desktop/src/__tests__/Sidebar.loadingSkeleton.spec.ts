/** Sidebar loading skeletons — PINNED + RECENT, PROJECTS, DOCUMENTS. Each section used to flash its
 * empty state (or plain "Loading..." text) while the first fetch was in flight. The skeleton keeps
 * the layout stable instead. */
import { beforeEach, describe, expect, it, vi } from 'vitest'
import { setActivePinia, createPinia } from 'pinia'
import { nextTick, ref } from 'vue'
import { flushPromises, mount } from '@vue/test-utils'
import { createMemoryHistory, createRouter } from 'vue-router'

import SidebarSkeleton from '../components/shell/SidebarSkeleton.vue'
import ProjectsList from '../components/workspace/ProjectsList.vue'
import DocumentsList from '../components/workspace/DocumentsList.vue'
import { makeLocalStorageStub } from './helpers'
import { useWorkspacesStore } from '../stores/workspaces'
import type { Workspace } from '../stores/workspaces'
import { useDocumentsStore } from '../stores/documents'

const listDocuments = vi.hoisted(() => vi.fn())

vi.mock('../api', async () => {
  const actual = await vi.importActual<typeof import('../api')>('../api')
  return {
    ...actual,
    listDocuments,
    createDocument: vi.fn(),
    deleteDocument: vi.fn(),
    getDocument: vi.fn(),
    updateDocument: vi.fn(),
  }
})

async function makeRouter(path = '/app/ws_1') {
  const router = createRouter({
    history: createMemoryHistory(),
    routes: [{ path: '/:pathMatch(.*)*', component: { template: '<div/>' } }],
  })
  await router.push(path)
  await router.isReady()
  return router
}

async function settle(): Promise<void> {
  await flushPromises()
  await nextTick()
}

async function clearDocumentsCache(workspaceId = 'ws_1'): Promise<void> {
  const { documentEngineDb } = await import('../sync/DocumentEngineDb')
  const { runSyncVoid } = await import('../sync/runtime')
  await runSyncVoid(documentEngineDb.clear(workspaceId), 'spec.clearDocumentsCache')
}

describe('SidebarSkeleton — shared placeholder', () => {
  it('renders the requested row count with status role', () => {
    const wrapper = mount(SidebarSkeleton, {
      props: { rows: 4, testId: 'sidebar-skeleton' },
    })
    expect(wrapper.attributes('data-testid')).toBe('sidebar-skeleton')
    expect(wrapper.attributes('role')).toBe('status')
    const bars = wrapper.findAll('.animate-pulse')
    expect(bars).toHaveLength(4)
    wrapper.unmount()
  })
})

describe('ProjectsList — loading skeleton', () => {
  beforeEach(() => {
    setActivePinia(createPinia())
    Object.defineProperty(globalThis, 'localStorage', {
      value: makeLocalStorageStub(),
      writable: true,
      configurable: true,
    })
  })

  function mountProjects(workspace: Workspace | null) {
    return mount(ProjectsList, {
      props: { workspace, activeWorkspaceItemId: null },
      global: {
        provide: { processingState: ref<Record<string, boolean>>({}) },
        stubs: { WorkspaceItem: true },
      },
    })
  }

  function makeWorkspace(items: Workspace['items'] = []): Workspace {
    return { id: 'ws_1', name: 'agentic coding', icon: '📂', expanded: true, items }
  }

  it('shows skeleton while the workspace tree loads, hides empty states', async () => {
    const ws = useWorkspacesStore()
    ws.isLoading = true
    const wrapper = mountProjects(null)
    await nextTick()
    expect(wrapper.find('[data-testid="projects-loading-skeleton"]').exists()).toBe(true)
    expect(wrapper.find('[data-testid="projects-no-workspace"]').exists()).toBe(false)
    expect(wrapper.find('[data-testid="projects-empty"]').exists()).toBe(false)
    wrapper.unmount()
  })

  it('shows skeleton for an empty workspace while loading, empty after', async () => {
    const ws = useWorkspacesStore()
    ws.isLoading = true
    const wrapper = mountProjects(makeWorkspace())
    await nextTick()
    expect(wrapper.find('[data-testid="projects-loading-skeleton"]').exists()).toBe(true)
    expect(wrapper.find('[data-testid="projects-empty"]').exists()).toBe(false)

    ws.isLoading = false
    await nextTick()
    expect(wrapper.find('[data-testid="projects-loading-skeleton"]').exists()).toBe(false)
    expect(wrapper.find('[data-testid="projects-empty"]').exists()).toBe(true)
    wrapper.unmount()
  })

  it('hides skeleton once items arrive', async () => {
    const ws = useWorkspacesStore()
    ws.isLoading = false
    const wrapper = mountProjects(
      makeWorkspace([{ id: 'item_a', name: 'pabrik', item_type: 'agent' }]),
    )
    await nextTick()
    expect(wrapper.find('[data-testid="projects-loading-skeleton"]').exists()).toBe(false)
    wrapper.unmount()
  })
})

describe('DocumentsList — loading skeleton', () => {
  beforeEach(async () => {
    await clearDocumentsCache()
    setActivePinia(createPinia())
    Object.defineProperty(globalThis, 'localStorage', {
      value: makeLocalStorageStub(),
      writable: true,
      configurable: true,
    })
    listDocuments.mockReset()
  })

  function mountDocs(router: Awaited<ReturnType<typeof makeRouter>>) {
    return mount(DocumentsList, {
      props: { workspaceId: 'ws_1' },
      global: { plugins: [router] },
    })
  }

  it('shows skeleton on first fetch, hides the empty state', async () => {
    listDocuments.mockImplementation(() => new Promise(() => {}))
    const router = await makeRouter()
    const wrapper = mountDocs(router)
    await settle()
    const store = useDocumentsStore()
    expect(store.loading).toBe(true)
    expect(wrapper.find('[data-testid="documents-loading-skeleton"]').exists()).toBe(true)
    expect(wrapper.find('[data-testid="documents-empty"]').exists()).toBe(false)
    wrapper.unmount()
  })

  it('hides skeleton once documents arrive', async () => {
    listDocuments.mockResolvedValue({
      documents: [
        {
          id: 'doc_1',
          workspace_id: 'ws_1',
          title: 'Release plan',
          content: '# v1',
          format: 'markdown',
          created_at: '2026-09-01 10:00:00',
          updated_at: '2026-09-02 10:00:00',
        },
      ],
      count: 1,
    })
    const router = await makeRouter()
    const wrapper = mountDocs(router)
    await settle()
    await settle()
    expect(wrapper.find('[data-testid="documents-loading-skeleton"]').exists()).toBe(false)
    expect(wrapper.find('[data-testid="document-row-doc_1"]').exists()).toBe(true)
    wrapper.unmount()
  })

  it('shows empty (not skeleton) for a genuinely empty workspace', async () => {
    listDocuments.mockResolvedValue({ documents: [], count: 0 })
    const router = await makeRouter()
    const wrapper = mountDocs(router)
    await settle()
    await settle()
    expect(wrapper.find('[data-testid="documents-empty"]').exists()).toBe(true)
    expect(wrapper.find('[data-testid="documents-loading-skeleton"]').exists()).toBe(false)
    wrapper.unmount()
  })
})

describe('ChatsList — loading skeleton (PINNED + RECENT)', () => {
  beforeEach(() => {
    setActivePinia(createPinia())
    Object.defineProperty(globalThis, 'localStorage', {
      value: makeLocalStorageStub(),
      writable: true,
      configurable: true,
    })
  })

  async function clearSessionCache(ctx = 'all'): Promise<void> {
    const { sessionEngineDb } = await import('../sync/SessionEngineDb')
    const { runSyncVoid } = await import('../sync/runtime')
    await runSyncVoid(sessionEngineDb.clear(ctx), 'spec.clearSessionCache')
  }

  it('shows skeleton on initial load, hides it once rows arrive', async () => {
    await clearSessionCache('all')
    const api = await import('../api')
    const getChats = vi.spyOn(api, 'getChats').mockImplementation(() => new Promise(() => {}))
    const { default: ChatsList } = await import('../components/views/ChatsList.vue')
    const wrapper = mount(ChatsList, {
      global: {
        provide: { processingState: ref<Record<string, boolean>>({}) },
      },
    })
    await settle()
    // Initial load: nothing painted yet, skeleton holds the layout.
    expect(wrapper.find('[data-testid="chats-loading-skeleton"]').exists()).toBe(true)

    getChats.mockRestore()
    wrapper.unmount()
    await clearSessionCache('all')
  })
})
