/** Documents sidebar section + URL contract (Migration 095). Three things are proven here, and the
 * third is the one that usually rots: 1. The section renders below Projects, with the same header
 * geometry the spacing spec greps for. 2. */
import { beforeEach, describe, expect, it, vi } from 'vitest'
import { setActivePinia, createPinia } from 'pinia'
import { nextTick, ref } from 'vue'
import { flushPromises, mount } from '@vue/test-utils'
import { createMemoryHistory, createRouter } from 'vue-router'

import DocumentsList from '../components/workspace/DocumentsList.vue'
import { makeLocalStorageStub } from './helpers'
import { useDocumentsStore } from '../stores/documents'

const listDocuments = vi.hoisted(() => vi.fn())
const createDocument = vi.hoisted(() => vi.fn())

vi.mock('../api', async () => {
  const actual = await vi.importActual<typeof import('../api')>('../api')
  return {
    ...actual,
    listDocuments,
    createDocument,
    deleteDocument: vi.fn(),
    getDocument: vi.fn(),
    updateDocument: vi.fn(),
  }
})

const DOCS = [
  {
    id: 'doc_1',
    workspace_id: 'ws_1',
    title: 'Release plan',
    content: '# v1',
    format: 'markdown',
    created_at: '2026-09-01 10:00:00',
    updated_at: '2026-09-02 10:00:00',
  },
  {
    id: 'doc_2',
    workspace_id: 'ws_1',
    title: 'Meeting notes',
    content: 'notes',
    format: 'markdown',
    created_at: '2026-09-01 11:00:00',
    updated_at: '2026-09-01 11:00:00',
  },
]

async function makeRouter(path = '/app/ws_1', query: Record<string, string> = {}) {
  const router = createRouter({
    history: createMemoryHistory(),
    routes: [{ path: '/:pathMatch(.*)*', component: { template: '<div/>' } }],
  })
  await router.push({ path, query })
  await router.isReady()
  return router
}

/**  * The list is cache-first now (IndexedDB paint, then revalidate), so the DOM settles on a promise
 * boundary rather than a microtask. Two `nextTick()`s no longer reach the painted rows — this does,
 * and it is the same flush `SidebarDiffPanel.tabs.spec.ts` uses. */
async function settle(): Promise<void> {
  await flushPromises()
  await nextTick()
}

/** The documents list is cache-first now, and `documentEngineDb` is a module singleton whose
 * IndexedDB fallback is a module-level Map — so rows cached by one test are still primed by the
 * next one. */
async function clearDocumentsCache(workspaceId = 'ws_1'): Promise<void> {
  const { documentEngineDb } = await import('../sync/DocumentEngineDb')
  const { runSyncVoid } = await import('../sync/runtime')
  await runSyncVoid(documentEngineDb.clear(workspaceId), 'spec.clearDocumentsCache')
}

function mountList(router: Awaited<ReturnType<typeof makeRouter>>) {
  return mount(DocumentsList, {
    props: { workspaceId: 'ws_1' },
    global: { plugins: [router] },
  })
}

describe('DocumentsList — section chrome', () => {
  beforeEach(async () => {
    await clearDocumentsCache()
    setActivePinia(createPinia())
    Object.defineProperty(globalThis, 'localStorage', {
      value: makeLocalStorageStub(),
      writable: true,
      configurable: true,
    })
    listDocuments.mockReset()
    createDocument.mockReset()
    listDocuments.mockResolvedValue({ documents: DOCS, count: DOCS.length })
  })

  it('nests no control inside the section header', async () => {
    const router = await makeRouter()
    const wrapper = mountList(router)
    await nextTick()
    expect(wrapper.findAll('button button')).toHaveLength(0)
    wrapper.unmount()
  })

  it('renders the Documents header with the sidebar token geometry', async () => {
    const router = await makeRouter()
    const wrapper = mountList(router)
    await nextTick()

    const title = wrapper.get('[data-testid="documents-section-title"]')
    expect(title.text()).toBe('Documents')
    // The spacing spec greps the source for these two; asserting the
    // rendered class keeps the component and the spec in agreement.
    const header = wrapper.get('[data-testid="documents-section-header"]')
    expect(header.classes()).toContain('px-[var(--sb-gutter)]')
    expect(header.classes()).toContain('h-7')
    expect(header.classes()).toContain('border-b')
    wrapper.unmount()
  })

  it('lists every document for the workspace with a quiet count', async () => {
    const router = await makeRouter()
    const wrapper = mountList(router)
    await settle()

    expect(listDocuments).toHaveBeenCalledWith('ws_1')
    expect(wrapper.get('[data-testid="documents-count"]').text()).toBe('2')
    expect(wrapper.get('[data-testid="document-row-doc_1"]').text()).toBe('Release plan')
    expect(wrapper.get('[data-testid="document-row-doc_2"]').text()).toBe('Meeting notes')
    wrapper.unmount()
  })

  it('renders rows at the shared --sb-row height', async () => {
    const router = await makeRouter()
    const wrapper = mountList(router)
    await settle()

    const row = wrapper.get('[data-testid="document-row-doc_1"]')
    expect(row.classes()).toContain('h-[var(--sb-row)]')
    expect(row.classes()).toContain('text-dense')
    wrapper.unmount()
  })

  it('collapsing the section persists its own flag, independent of Projects', async () => {
    const router = await makeRouter()
    const wrapper = mountList(router)
    await nextTick()

    await wrapper.get('[data-testid="documents-section-header"]').trigger('click')
    await nextTick()
    expect(localStorage.getItem('pabrik-sidebar-documents-expanded')).toBe('false')
    expect(localStorage.getItem('pabrik-sidebar-projects-expanded')).toBe(null)
    wrapper.unmount()
  })

  it('the create button makes a document and opens it', async () => {
    const created = { ...DOCS[0], id: 'doc_new', title: 'Untitled document' }
    createDocument.mockResolvedValue({ document: created })
    const router = await makeRouter()
    const wrapper = mountList(router)
    await nextTick()

    await wrapper.get('[data-testid="documents-add-button"]').trigger('click')
    await flushPromises()
    await nextTick()

    expect(createDocument).toHaveBeenCalledWith('ws_1', 'Untitled document', '')
    // A document is a PAGE now, so the id lives in the path. Asserting the
    // query here would pass even if the view still rendered as an overlay.
    expect(router.currentRoute.value.path).toBe('/app/ws_1/doc/doc_new')
    expect(router.currentRoute.value.query.doc).toBeUndefined()
    wrapper.unmount()
  })
})

describe('DocumentsList — URL contract', () => {
  beforeEach(async () => {
    await clearDocumentsCache()
    setActivePinia(createPinia())
    Object.defineProperty(globalThis, 'localStorage', {
      value: makeLocalStorageStub(),
      writable: true,
      configurable: true,
    })
    listDocuments.mockReset()
    listDocuments.mockResolvedValue({ documents: DOCS, count: DOCS.length })
  })

  it('a row click writes the document PAGE to the URL and mount restores the highlight', async () => {
    const router = await makeRouter()
    const wrapper = mountList(router)
    await settle()

    await wrapper.get('[data-testid="document-row-doc_2"]').trigger('click')
    // `router.replace` resolves on a microtask, so a bare `nextTick()` can
    // observe the route BEFORE the navigation lands. This is the
    // flushPromises pattern SidebarDiffPanel.tabs.spec.ts uses.
    await flushPromises()
    // The click half. Without this, refresh loses the open document.
    // The id is in the PATH, and the document REPLACES the current main
    // view rather than layering `?doc=` on top of whatever was open.
    expect(router.currentRoute.value.path).toBe('/app/ws_1/doc/doc_2')
    expect(router.currentRoute.value.query.doc).toBeUndefined()
    wrapper.unmount()

    // The mount half. Without this, a shared link opens the right
    // document with no row highlighted.
    const restored = mountList(await makeRouter('/app/ws_1/doc/doc_2'))
    await settle()
    const style = restored.get('[data-testid="document-row-doc_2"]').attributes('style') ?? ''
    expect(style).toContain('--semantic-active-bg')
    const otherStyle = restored.get('[data-testid="document-row-doc_1"]').attributes('style') ?? ''
    expect(otherStyle).not.toContain('--semantic-active-bg')
    restored.unmount()
  })

  it('clicking a row clears the chat and project selection so only one row is active', async () => {
    const router = await makeRouter()
    const wrapper = mountList(router)
    await settle()

    await wrapper.get('[data-testid="document-row-doc_1"]').trigger('click')
    await flushPromises()

    // The workspaces store is what ProjectsList and ChatsList read for
    // their own highlight. Left set, a project row stays highlighted
    // alongside the document row.
    const { useWorkspacesStore } = await import('../stores/workspaces')
    const ws = useWorkspacesStore()
    expect(ws.activeWorkspaceItemId).toBe(null)
    expect(ws.activeTaskId).toBe(null)
    wrapper.unmount()
  })
})

describe('DocumentsList — failure is not emptiness', () => {
  beforeEach(async () => {
    await clearDocumentsCache()
    setActivePinia(createPinia())
    Object.defineProperty(globalThis, 'localStorage', {
      value: makeLocalStorageStub(),
      writable: true,
      configurable: true,
    })
    listDocuments.mockReset()
    createDocument.mockReset()
  })

  it('a failed list fetch renders the error, never the empty state', async () => {
    listDocuments.mockRejectedValue(new Error('HTTP 500 Internal Server Error'))
    const router = await makeRouter()
    const wrapper = mountList(router)
    await settle()
    await settle()

    // The regression: `catch` returning `[]` with no error makes this
    // identical to a workspace with no documents, and the user deletes
    // real notes to "fix" a backend blip.
    expect(wrapper.find('[data-testid="documents-error"]').exists()).toBe(true)
    expect(wrapper.find('[data-testid="documents-empty"]').exists()).toBe(false)
    wrapper.unmount()
  })

  it('a genuinely empty workspace renders the empty state', async () => {
    listDocuments.mockResolvedValue({ documents: [], count: 0 })
    const router = await makeRouter()
    const wrapper = mountList(router)
    await settle()

    expect(wrapper.find('[data-testid="documents-empty"]').exists()).toBe(true)
    expect(wrapper.find('[data-testid="documents-error"]').exists()).toBe(false)
    wrapper.unmount()
  })

  it('no workspace selected renders its own hint and issues no request', async () => {
    const router = await makeRouter()
    const wrapper = mount(DocumentsList, {
      props: { workspaceId: null },
      global: { plugins: [router] },
    })
    await settle()

    expect(listDocuments).not.toHaveBeenCalled()
    expect(wrapper.find('[data-testid="documents-no-workspace"]').exists()).toBe(true)
    wrapper.unmount()
  })

  it('a failed refresh keeps the last good list on screen', async () => {
    listDocuments.mockResolvedValueOnce({ documents: DOCS, count: DOCS.length })
    const router = await makeRouter()
    const wrapper = mountList(router)
    await settle()
    expect(wrapper.find('[data-testid="document-row-doc_1"]').exists()).toBe(true)

    listDocuments.mockRejectedValueOnce(new Error('boom'))
    const store = useDocumentsStore()
    await store.fetchDocuments('ws_1')
    await settle()

    // Blanking the list on a failed refresh would make a transient network error look like data
    // loss. The message is now the sync engine's (`sync remote documents.fetchDelta failed: boom`),
    // because the list load went through the Effect seam.
    expect(store.error).toContain('boom')
    expect(store.documents).toHaveLength(2)
    expect(wrapper.find('[data-testid="document-row-doc_1"]').exists()).toBe(true)
    wrapper.unmount()
  })
})

// `ref` is imported for the pinia `provide` contract shape that sibling
// specs use; kept so vue-tsc checks this file whole and the import is
// not silently dead.
void ref
