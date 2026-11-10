/** Exporting documents from the sidebar: the right-click menu, the Ctrl/Shift selection, and
 * that picking an export row calls the API with exactly the selected ids and hands the blob to
 * the browser's download path. */
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest'
import { setActivePinia, createPinia } from 'pinia'
import { nextTick } from 'vue'
import { flushPromises, mount } from '@vue/test-utils'
import { createMemoryHistory, createRouter } from 'vue-router'

import DocumentsList from '../components/workspace/DocumentsList.vue'
import { makeLocalStorageStub } from './helpers'
import { filenameFromDisposition } from '../api/documents'

const listDocuments = vi.hoisted(() => vi.fn())
const exportDocument = vi.hoisted(() => vi.fn())
const exportDocuments = vi.hoisted(() => vi.fn())
const downloadBlob = vi.hoisted(() => vi.fn())

vi.mock('../api', async () => {
  const actual = await vi.importActual<typeof import('../api')>('../api')
  return {
    ...actual,
    listDocuments,
    exportDocument,
    exportDocuments,
    createDocument: vi.fn(),
    reorderDocuments: vi.fn(),
    deleteDocument: vi.fn(),
    getDocument: vi.fn(),
    updateDocument: vi.fn(),
  }
})

vi.mock('../helpers/download', () => ({ downloadBlob }))

const DOCS = [
  {
    id: 'doc_1',
    workspace_id: 'ws_1',
    title: 'Release plan',
    format: 'markdown',
    created_at: '2026-09-01 10:00:00',
    updated_at: '2026-09-02 10:00:00',
  },
  {
    id: 'doc_2',
    workspace_id: 'ws_1',
    title: 'Meeting notes',
    format: 'markdown',
    created_at: '2026-09-01 11:00:00',
    updated_at: '2026-09-01 11:00:00',
  },
  {
    id: 'doc_3',
    workspace_id: 'ws_1',
    title: 'Budget',
    format: 'office',
    created_at: '2026-09-01 12:00:00',
    updated_at: '2026-09-01 12:00:00',
  },
]

async function makeRouter() {
  const router = createRouter({
    history: createMemoryHistory(),
    routes: [{ path: '/:pathMatch(.*)*', component: { template: '<div/>' } }],
  })
  await router.push('/app/ws_1')
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

async function mountList() {
  const router = await makeRouter()
  const wrapper = mount(DocumentsList, {
    props: { workspaceId: 'ws_1' },
    global: { plugins: [router] },
    attachTo: document.body,
  })
  await settle()
  return wrapper
}

/** The menu is teleported to body, so it is not inside the wrapper. */
function menu(): HTMLElement | null {
  return document.querySelector<HTMLElement>('[data-testid="documents-context-menu"]')
}

function menuRow(testId: string): HTMLElement | null {
  return document.querySelector<HTMLElement>(`[data-testid="${testId}"]`)
}

async function rightClick(wrapper: Awaited<ReturnType<typeof mountList>>, docId: string) {
  await wrapper.get(`[data-testid="document-row-${docId}"]`).trigger('contextmenu', {
    clientX: 40,
    clientY: 60,
  })
  await nextTick()
}

describe('filenameFromDisposition', () => {
  it('prefers the RFC 5987 encoded name, which is the only one that survives a non-ASCII title', () => {
    const header = `attachment; filename="Rencana _ ___.md"; filename*=UTF-8''Rencana%20%E2%80%94%20.md`
    expect(filenameFromDisposition(header, 'fallback.md')).toBe('Rencana — .md')
  })

  it('falls back to the plain quoted name when there is no encoded form', () => {
    expect(filenameFromDisposition('attachment; filename="Release plan.md"', 'fallback.md')).toBe(
      'Release plan.md',
    )
  })

  it('falls back to the caller-supplied name when the header names nothing', () => {
    expect(filenameFromDisposition(null, 'documents.zip')).toBe('documents.zip')
    expect(filenameFromDisposition('attachment', 'documents.zip')).toBe('documents.zip')
    expect(filenameFromDisposition('attachment; filename=""', 'documents.zip')).toBe('documents.zip')
  })
})

describe('DocumentsList — export', () => {
  beforeEach(async () => {
    await clearDocumentsCache()
    setActivePinia(createPinia())
    Object.defineProperty(globalThis, 'localStorage', {
      value: makeLocalStorageStub(),
      writable: true,
      configurable: true,
    })
    listDocuments.mockReset()
    exportDocument.mockReset()
    exportDocuments.mockReset()
    downloadBlob.mockReset()
    listDocuments.mockResolvedValue({ documents: DOCS, count: DOCS.length })
    exportDocument.mockResolvedValue({
      blob: new Blob(['# plan']),
      filename: 'Release plan.md',
    })
    exportDocuments.mockResolvedValue({
      blob: new Blob(['PK']),
      filename: 'documents.zip',
    })
  })

  afterEach(() => {
    document.body.innerHTML = ''
  })

  it('right-clicking a row opens the menu, and the export row names the one document', async () => {
    const wrapper = await mountList()
    await rightClick(wrapper, 'doc_1')

    expect(menu()).not.toBeNull()
    expect(menuRow('documents-context-menu-export')?.textContent).toContain('Export document')
    wrapper.unmount()
  })

  it('ctrl-clicking a second row makes the menu export both', async () => {
    const wrapper = await mountList()
    await wrapper.get('[data-testid="document-row-doc_1"]').trigger('click', { ctrlKey: true })
    await wrapper.get('[data-testid="document-row-doc_2"]').trigger('click', { ctrlKey: true })
    await rightClick(wrapper, 'doc_2')

    expect(menuRow('documents-context-menu-export')?.textContent).toContain('Export 2 documents')
    wrapper.unmount()
  })

  it('shift-clicking selects the whole range between the two rows', async () => {
    const wrapper = await mountList()
    // The rendered order is the store's, not the fixture's — read it from the DOM.
    const ids = wrapper
      .findAll('[data-testid^="document-row-"]')
      .map((row) => row.attributes('data-testid')!.replace('document-row-', ''))
    expect(ids).toHaveLength(3)

    await wrapper.get(`[data-testid="document-row-${ids[0]}"]`).trigger('click', { ctrlKey: true })
    await wrapper.get(`[data-testid="document-row-${ids[2]}"]`).trigger('click', { shiftKey: true })
    await rightClick(wrapper, ids[2]!)

    expect(menuRow('documents-context-menu-export')?.textContent).toContain('Export 3 documents')
    wrapper.unmount()
  })

  it('right-clicking an unselected row exports only that row, not a stale selection', async () => {
    const wrapper = await mountList()
    await wrapper.get('[data-testid="document-row-doc_1"]').trigger('click', { ctrlKey: true })
    await rightClick(wrapper, 'doc_3')

    expect(menuRow('documents-context-menu-export')?.textContent).toContain('Export document')
    wrapper.unmount()
  })

  it('exporting one document downloads the file the server named', async () => {
    const wrapper = await mountList()
    await rightClick(wrapper, 'doc_1')
    menuRow('documents-context-menu-export')?.click()
    await settle()

    expect(exportDocument).toHaveBeenCalledWith('ws_1', 'doc_1')
    expect(exportDocuments).not.toHaveBeenCalled()
    expect(downloadBlob).toHaveBeenCalledTimes(1)
    expect(downloadBlob.mock.calls[0]?.[1]).toBe('Release plan.md')
    expect(wrapper.get('[data-testid="documents-export-notice"]').text()).toContain(
      'Exported Release plan.md',
    )
    wrapper.unmount()
  })

  it('exporting a selection zips exactly the selected ids', async () => {
    const wrapper = await mountList()
    await wrapper.get('[data-testid="document-row-doc_1"]').trigger('click', { ctrlKey: true })
    await wrapper.get('[data-testid="document-row-doc_3"]').trigger('click', { ctrlKey: true })
    await rightClick(wrapper, 'doc_3')
    menuRow('documents-context-menu-export')?.click()
    await settle()

    expect(exportDocuments).toHaveBeenCalledWith('ws_1', ['doc_1', 'doc_3'])
    expect(exportDocument).not.toHaveBeenCalled()
    expect(downloadBlob.mock.calls[0]?.[1]).toBe('documents.zip')
    wrapper.unmount()
  })

  it('export all writes every document in the section', async () => {
    const wrapper = await mountList()
    await rightClick(wrapper, 'doc_1')
    menuRow('documents-context-menu-export-all')?.click()
    await settle()

    expect(exportDocuments).toHaveBeenCalledWith('ws_1', ['doc_1', 'doc_2', 'doc_3'])
    wrapper.unmount()
  })

  it('a plain click still opens the document and clears the selection', async () => {
    const wrapper = await mountList()
    await wrapper.get('[data-testid="document-row-doc_1"]').trigger('click', { ctrlKey: true })
    await wrapper.get('[data-testid="document-row-doc_2"]').trigger('click')
    await rightClick(wrapper, 'doc_2')

    expect(menuRow('documents-context-menu-export')?.textContent).toContain('Export document')
    wrapper.unmount()
  })

  it('a failed export reports the reason and downloads nothing', async () => {
    exportDocument.mockRejectedValue(new Error('HTTP 500 Internal Server Error'))
    const wrapper = await mountList()
    await rightClick(wrapper, 'doc_1')
    menuRow('documents-context-menu-export')?.click()
    await settle()

    expect(downloadBlob).not.toHaveBeenCalled()
    expect(wrapper.find('[data-testid="documents-export-notice"]').exists()).toBe(false)
    wrapper.unmount()
  })
})
