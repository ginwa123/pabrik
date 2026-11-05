/** Document folders (Migration 140): the tree rules, and the gestures the
 * sidebar adds. Placement is asserted through the API calls the gestures
 * produce, so a refactor of the row markup cannot quietly break it. */
import { beforeEach, describe, expect, it, vi } from 'vitest'
import { setActivePinia, createPinia } from 'pinia'
import { nextTick } from 'vue'
import { flushPromises, mount } from '@vue/test-utils'
import { createMemoryHistory, createRouter } from 'vue-router'

import DocumentsList from '../components/workspace/DocumentsList.vue'
import { makeLocalStorageStub } from './helpers'
import { folderPath, isAtOrBelow, mergeLevel, useDocumentsStore } from '../stores/documents'
import type { Document, DocumentFolder } from '../api'

const listDocuments = vi.hoisted(() => vi.fn())
const createFolder = vi.hoisted(() => vi.fn())
const updateFolder = vi.hoisted(() => vi.fn())
const deleteFolder = vi.hoisted(() => vi.fn())
const updateDocument = vi.hoisted(() => vi.fn())
const createDocument = vi.hoisted(() => vi.fn())

vi.mock('../api', async () => {
  const actual = await vi.importActual<typeof import('../api')>('../api')
  return {
    ...actual,
    listDocuments,
    createFolder,
    updateFolder,
    deleteFolder,
    updateDocument,
    createDocument,
    reorderDocuments: vi.fn(),
    deleteDocument: vi.fn(),
    getDocument: vi.fn(),
  }
})

const FOLDERS: DocumentFolder[] = [
  {
    id: 'fld_debit',
    workspace_id: 'ws_1',
    parent_id: null,
    name: 'Sales debit note',
    position: 0,
  },
  {
    id: 'fld_split',
    workspace_id: 'ws_1',
    parent_id: 'fld_debit',
    name: 'Split bill',
    position: 0,
  },
]

function doc(id: string, title: string, folderId: string | null, position: number): Document {
  return {
    id,
    workspace_id: 'ws_1',
    title,
    content: '',
    format: 'markdown',
    created_at: '2026-09-01 10:00:00',
    updated_at: '2026-09-01 10:00:00',
    position,
    folder_id: folderId,
  }
}

const DOCS: Document[] = [
  doc('doc_in_split', 'POST split-bill', 'fld_split', 0),
  doc('doc_in_debit', 'POST sales-debit-notes/history', 'fld_debit', 0),
  doc('doc_root', 'Untitled document', null, 0),
]

async function makeRouter() {
  const router = createRouter({
    history: createMemoryHistory(),
    routes: [{ path: '/:pathMatch(.*)*', component: { template: '<div/>' } }],
  })
  await router.push({ path: '/app/ws_1' })
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
  globalThis.localStorage?.removeItem('pabrik.documents.folders.' + workspaceId)
}

function makeDragStore() {
  const store = new Map<string, string>()
  return {
    effectAllowed: 'none',
    dropEffect: 'none',
    setData(type: string, value: string) {
      store.set(type, value)
    },
    getData(type: string): string {
      return store.get(type) ?? ''
    },
  }
}

function dispatchDrag(type: string, el: Element, dt: unknown, clientY = 0) {
  // eslint-disable-next-line @typescript-eslint/no-explicit-any
  const event = new Event(type, { bubbles: true, cancelable: true }) as any
  event.dataTransfer = dt
  event.clientY = clientY
  el.dispatchEvent(event)
}

window.HTMLElement.prototype.scrollIntoView = vi.fn()

describe('document folders — the tree rules', () => {
  it('puts folders before documents at a level, each in saved order', () => {
    const level = mergeLevel(FOLDERS, DOCS, null)
    expect(
      level.map((entry) => (entry.kind === 'folder' ? entry.folder.id : entry.document.id)),
    ).toEqual(['fld_debit', 'doc_root'])
  })

  it('a folder and its documents occupy different levels', () => {
    const childLevel = mergeLevel(FOLDERS, DOCS, 'fld_debit')
    expect(
      childLevel.map((entry) => (entry.kind === 'folder' ? entry.folder.id : entry.document.id)),
    ).toEqual(['fld_split', 'doc_in_debit'])
  })

  it('a candidate inside an ancestor is reported, so a cycle can be refused', () => {
    expect(isAtOrBelow(FOLDERS, 'fld_debit', 'fld_split')).toBe(true)
    expect(isAtOrBelow(FOLDERS, 'fld_split', 'fld_debit')).toBe(false)
    expect(isAtOrBelow(FOLDERS, 'fld_debit', 'fld_debit')).toBe(true)
  })

  it('the path from the root is the folder names, outermost first', () => {
    expect(folderPath(FOLDERS, 'fld_split')).toEqual(['Sales debit note', 'Split bill'])
    expect(folderPath(FOLDERS, null)).toEqual([])
  })
})

describe('document folders — store writes', () => {
  beforeEach(async () => {
    await clearDocumentsCache()
    setActivePinia(createPinia())
    Object.defineProperty(globalThis, 'localStorage', {
      value: makeLocalStorageStub(),
      writable: true,
      configurable: true,
    })
    listDocuments.mockReset()
    createFolder.mockReset()
    updateFolder.mockReset()
    deleteFolder.mockReset()
    updateDocument.mockReset()
    listDocuments.mockResolvedValue({
      documents: DOCS,
      folders: FOLDERS,
      count: DOCS.length,
      folder_count: FOLDERS.length,
    })
  })

  it('moving a folder into its own descendant writes nothing and says why', async () => {
    const store = useDocumentsStore()
    await store.fetchDocuments('ws_1')

    const moved = await store.moveFolder('ws_1', 'fld_debit', 'fld_split')

    expect(moved).toBe(false)
    expect(updateFolder).not.toHaveBeenCalled()
    expect(store.error).toBe('A folder cannot be moved inside itself')
    expect(store.folders.find((f) => f.id === 'fld_debit')?.parent_id).toBeNull()
  })

  it('deleting a folder reparents its children and keeps every document', async () => {
    const store = useDocumentsStore()
    await store.fetchDocuments('ws_1')
    deleteFolder.mockResolvedValue({ id: 'fld_split', success: true, reparented_documents: 1 })

    const removed = await store.deleteFolder('ws_1', 'fld_split')

    expect(removed).toBe(true)
    expect(deleteFolder).toHaveBeenCalledWith('ws_1', 'fld_split')
    expect(store.folders.map((f) => f.id)).toEqual(['fld_debit'])
    // The document that lived there moved up one level; none disappeared.
    expect(store.documents).toHaveLength(DOCS.length)
    expect(store.documents.find((d) => d.id === 'doc_in_split')?.folder_id).toBe('fld_debit')
  })

  it('a rejected delete puts the folder and its document back', async () => {
    const store = useDocumentsStore()
    await store.fetchDocuments('ws_1')
    deleteFolder.mockRejectedValue(new Error('409 conflict'))

    const removed = await store.deleteFolder('ws_1', 'fld_split')

    expect(removed).toBe(false)
    expect(store.folders.map((f) => f.id)).toEqual(['fld_debit', 'fld_split'])
    expect(store.documents.find((d) => d.id === 'doc_in_split')?.folder_id).toBe('fld_split')
    expect(store.error).toContain('409 conflict')
  })

  it('a new folder appears in the list without a refetch', async () => {
    const store = useDocumentsStore()
    await store.fetchDocuments('ws_1')
    createFolder.mockResolvedValue({
      folder: {
        id: 'fld_new',
        workspace_id: 'ws_1',
        parent_id: null,
        name: 'New folder',
        position: -1,
      },
    })

    const folder = await store.createFolder('ws_1', 'New folder', null)

    expect(folder?.id).toBe('fld_new')
    expect(store.folders.map((f) => f.id)).toContain('fld_new')
    expect(listDocuments).toHaveBeenCalledTimes(1)
  })
})

describe('document folders — the sidebar', () => {
  beforeEach(async () => {
    await clearDocumentsCache()
    setActivePinia(createPinia())
    Object.defineProperty(globalThis, 'localStorage', {
      value: makeLocalStorageStub(),
      writable: true,
      configurable: true,
    })
    listDocuments.mockReset()
    createFolder.mockReset()
    updateDocument.mockReset()
    deleteDocumentReset()
    listDocuments.mockResolvedValue({
      documents: DOCS,
      folders: FOLDERS,
      count: DOCS.length,
      folder_count: FOLDERS.length,
    })
  })

  function deleteDocumentReset() {
    // The shared api mock keeps `deleteFolder` between tests in this block.
    deleteFolder.mockReset()
  }

  it('renders folder rows and indents their children by one 16px step', async () => {
    const router = await makeRouter()
    const wrapper = mount(DocumentsList, {
      props: { workspaceId: 'ws_1' },
      global: { plugins: [router] },
    })
    await settle()

    expect(wrapper.find('[data-testid="document-folder-fld_debit"]').exists()).toBe(true)
    expect(wrapper.find('[data-testid="document-folder-fld_split"]').exists()).toBe(true)
    expect(wrapper.find('[data-testid="document-row-doc_in_split"]').exists()).toBe(true)

    const root = wrapper.get('[data-testid="document-row-doc_root"]')
    const nested = wrapper.get('[data-testid="document-row-doc_in_split"]')
    // Depth is spent in --sb-mark steps: the root row sits on the gutter,
    // the row inside Split bill is two levels down.
    expect(root.attributes('style')).toContain('+ 0px')
    expect(nested.attributes('style')).toContain('+ 32px')
    wrapper.unmount()
  })

  it('collapsing a folder hides its children and flips aria-expanded', async () => {
    const router = await makeRouter()
    const wrapper = mount(DocumentsList, {
      props: { workspaceId: 'ws_1' },
      global: { plugins: [router] },
    })
    await settle()

    await wrapper.get('[data-testid="document-folder-fld_debit"]').trigger('click')
    await nextTick()

    expect(wrapper.find('[data-testid="document-folder-fld_split"]').exists()).toBe(false)
    expect(wrapper.find('[data-testid="document-row-doc_in_debit"]').exists()).toBe(false)
    // The folder row itself stays: the name and count are the way back in.
    expect(
      wrapper.get('[data-testid="document-folder-fld_debit"]').attributes('aria-expanded'),
    ).toBe('false')
    wrapper.unmount()
  })

  it('dragging a document onto a folder row moves it into that folder', async () => {
    const router = await makeRouter()
    const wrapper = mount(DocumentsList, {
      props: { workspaceId: 'ws_1' },
      global: { plugins: [router] },
    })
    await settle()
    updateDocument.mockResolvedValue({ document: { ...DOCS[2], folder_id: 'fld_debit' } })

    const dt = makeDragStore()
    dispatchDrag('dragstart', wrapper.get('[data-doc-id="doc_root"]').element, dt)
    dispatchDrag('dragover', wrapper.get('[data-folder-id="fld_debit"]').element, dt)
    dispatchDrag('drop', wrapper.get('[data-folder-id="fld_debit"]').element, dt)
    await settle()

    expect(updateDocument).toHaveBeenCalledWith('ws_1', 'doc_root', { folder_id: 'fld_debit' })
    wrapper.unmount()
  })

  it('the folder button creates a folder and opens its name for typing', async () => {
    createFolder.mockResolvedValue({
      folder: {
        id: 'fld_new',
        workspace_id: 'ws_1',
        parent_id: null,
        name: 'New folder',
        position: -1,
      },
    })
    const router = await makeRouter()
    const wrapper = mount(DocumentsList, {
      props: { workspaceId: 'ws_1' },
      global: { plugins: [router] },
    })
    await settle()

    await wrapper.get('[data-testid="documents-new-folder-button"]').trigger('click')
    await settle()

    expect(createFolder).toHaveBeenCalledWith('ws_1', 'New folder', null)
    expect(wrapper.find('[data-testid="document-folder-rename-input"]').exists()).toBe(true)
    wrapper.unmount()
  })

  it('the folder row delete button deletes the folder, not its documents', async () => {
    deleteFolder.mockResolvedValue({ id: 'fld_split', success: true, reparented_documents: 1 })
    const router = await makeRouter()
    const wrapper = mount(DocumentsList, {
      props: { workspaceId: 'ws_1' },
      global: { plugins: [router] },
    })
    await settle()

    await wrapper.get('[data-testid="document-folder-delete-fld_split"]').trigger('click')
    await settle()

    expect(deleteFolder).toHaveBeenCalledWith('ws_1', 'fld_split')
    wrapper.unmount()
  })
})
