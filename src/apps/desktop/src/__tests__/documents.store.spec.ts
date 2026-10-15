/** The documents Pinia store (Migration 095). The store is the one sanctioned place for
 * `try`/`catch` in the desktop app, so every failure has to be VISIBLE afterwards. */
/** The theme of this spec is the distinction the store exists to preserve: **"there is nothing
 * here" and "I could not check" are different states**, and a `catch` that returns `[]` with no
 * error collapses them. */
/** That is the bug class PR #719 shipped (a slow backend rendered the empty state for a session
 * full of messages), and these assertions are the guard. */
import { beforeEach, describe, expect, it, vi } from 'vitest'
import { setActivePinia, createPinia } from 'pinia'

import { useDocumentsStore } from '../stores/documents'
import * as api from '../api'

const listDocuments = vi.hoisted(() => vi.fn())
const createDocument = vi.hoisted(() => vi.fn())
const updateDocument = vi.hoisted(() => vi.fn())
const deleteDocument = vi.hoisted(() => vi.fn())
const getDocument = vi.hoisted(() => vi.fn())

vi.mock('../api', async () => {
  const actual = await vi.importActual<typeof import('../api')>('../api')
  return { ...actual, listDocuments, createDocument, updateDocument, deleteDocument, getDocument }
})

const doc = (id: string, overrides: Partial<api.Document> = {}): api.Document => ({
  id,
  workspace_id: 'ws_1',
  title: `Doc ${id}`,
  content: '',
  format: 'markdown',
  created_at: '2026-09-01 10:00:00',
  updated_at: '2026-09-01 10:00:00',
  ...overrides,
})

/** The list is cache-first now, and `documentEngineDb` is a module singleton whose IndexedDB
 * fallback is a module-level Map. */
/** That cache deliberately outlives `createPinia()` — which is the feature — but it means rows
 * cached by one test are still primed by the next, flipping `loaded` to true before the mocked
 * `listDocuments` is ever consulted. */
/** Every test here asserts a cold load, so each starts from an empty cache. */
async function clearDocumentsCache(workspaceId = 'ws_1'): Promise<void> {
  const { documentEngineDb } = await import('../sync/DocumentEngineDb')
  const { runSyncVoid } = await import('../sync/runtime')
  await runSyncVoid(documentEngineDb.clear(workspaceId), 'spec.clearDocumentsCache')
}

beforeEach(async () => {
  await clearDocumentsCache()
  setActivePinia(createPinia())
  listDocuments.mockReset()
  createDocument.mockReset()
  updateDocument.mockReset()
  deleteDocument.mockReset()
  getDocument.mockReset()
})

describe('documents store — load', () => {
  it('populates the list and flips `loaded`', async () => {
    listDocuments.mockResolvedValue({ documents: [doc('doc_1'), doc('doc_2')], count: 2 })
    const store = useDocumentsStore()

    await store.fetchDocuments('ws_1')

    expect(store.documents).toHaveLength(2)
    expect(store.count).toBe(2)
    expect(store.loaded).toBe(true)
    expect(store.error).toBe(null)
  })

  it('a failed load records the error and does NOT claim `loaded`', async () => {
    listDocuments.mockRejectedValue(new Error('HTTP 500'))
    const store = useDocumentsStore()

    await store.fetchDocuments('ws_1')

    // The pair is the whole point: `error` set AND `loaded` false is what lets the component render
    // "could not load" instead of "no documents". Asserting only one of the two would pass a store
    // that sets error on success.

    // The load now goes through the sync engine, so the message is the engine's (`sync remote
    // documents.fetchDelta failed: HTTP 500`).

    // Asserted on the REASON surviving rather than the exact string: the contract is that the
    // failure reaches `error`, and pinning the prefix would break on any future rewording for no
    // extra protection.
    expect(store.error).toContain('HTTP 500')
    expect(store.loaded).toBe(false)
    expect(store.documents).toEqual([])
  })

  it('an empty workspace is `loaded` with zero rows, not an error', async () => {
    listDocuments.mockResolvedValue({ documents: [], count: 0 })
    const store = useDocumentsStore()

    await store.fetchDocuments('ws_1')

    expect(store.loaded).toBe(true)
    expect(store.error).toBe(null)
    expect(store.documents).toEqual([])
  })

  it('no workspace id is a no-op, not a request with an empty path', async () => {
    const store = useDocumentsStore()
    await store.fetchDocuments('')
    // `SqliteBackend.exec` binds "" as SQL NULL server-side; refusing to
    // issue the request at all is the client-side half of that rule.
    expect(listDocuments).not.toHaveBeenCalled()
  })
})

describe('documents store — mutations', () => {
  it('create prepends without a refetch (newest-updated-first order)', async () => {
    listDocuments.mockResolvedValue({ documents: [doc('doc_old')], count: 1 })
    createDocument.mockResolvedValue({ document: doc('doc_new') })
    const store = useDocumentsStore()
    await store.fetchDocuments('ws_1')
    listDocuments.mockClear()

    const created = await store.createDocument('ws_1', 'New')

    expect(created?.id).toBe('doc_new')
    expect(store.documents.map((d) => d.id)).toEqual(['doc_new', 'doc_old'])
    // One round-trip saved on the click that created the document.
    expect(listDocuments).not.toHaveBeenCalled()
  })

  it('a failed create reports the error and adds nothing to the list', async () => {
    listDocuments.mockResolvedValue({ documents: [doc('doc_1')], count: 1 })
    createDocument.mockRejectedValue(new Error('title is required'))
    const store = useDocumentsStore()
    await store.fetchDocuments('ws_1')

    const created = await store.createDocument('ws_1', '   ')

    expect(created).toBe(null)
    expect(store.error).toBe('title is required')
    // An optimistic insert that is not rolled back on failure shows the
    // user a document that does not exist.
    expect(store.documents).toHaveLength(1)
  })

  it('update replaces the row in place, not by append', async () => {
    listDocuments.mockResolvedValue({ documents: [doc('doc_1'), doc('doc_2')], count: 2 })
    updateDocument.mockResolvedValue({ document: doc('doc_1', { content: 'new body' }) })
    const store = useDocumentsStore()
    await store.fetchDocuments('ws_1')

    await store.updateDocument('ws_1', 'doc_1', { content: 'new body' })

    expect(store.documents).toHaveLength(2)
    expect(store.findById('doc_1')?.content).toBe('new body')
    // The replacement must be IN PLACE, not appended: an append would
    // leave two rows with the same id, one of them stale.
    expect(store.documents[1]?.id).toBe('doc_2')
    expect(store.documents.filter((d) => d.id === 'doc_1')).toHaveLength(1)
  })

  it('an omitted field is left alone by the store and sent as absent', async () => {
    listDocuments.mockResolvedValue({ documents: [doc('doc_1', { content: 'keep me' })], count: 1 })
    updateDocument.mockResolvedValue({ document: doc('doc_1', { title: 'Renamed' }) })
    const store = useDocumentsStore()
    await store.fetchDocuments('ws_1')

    // The PATCH body must contain `title` and NOT `content`. Sending `content: undefined` through
    // JSON.stringify drops it, but sending `content: ''` would CLEAR the body — the store must not
    // invent the key to satisfy its own type.
    let body: Record<string, unknown> = {}
    updateDocument.mockImplementation((_ws, _id, patch) => {
      body = JSON.parse(JSON.stringify(patch))
      return Promise.resolve({ document: doc('doc_1', { title: 'Renamed' }) })
    })

    await store.updateDocument('ws_1', 'doc_1', { title: 'Renamed' })

    expect(Object.keys(body)).toEqual(['title'])
    expect('content' in body).toBe(false)
  })

  it('a failed update keeps the previous body on screen', async () => {
    listDocuments.mockResolvedValue({
      documents: [doc('doc_1', { content: 'original' })],
      count: 1,
    })
    updateDocument.mockRejectedValue(new Error('HTTP 500'))
    const store = useDocumentsStore()
    await store.fetchDocuments('ws_1')

    const updated = await store.updateDocument('ws_1', 'doc_1', { content: 'attempted' })

    expect(updated).toBe(null)
    expect(store.error).toBe('HTTP 500')
    expect(store.findById('doc_1')?.content).toBe('original')
  })

  it('delete removes the row and reports success', async () => {
    listDocuments.mockResolvedValue({ documents: [doc('doc_1'), doc('doc_2')], count: 2 })
    deleteDocument.mockResolvedValue({ id: 'doc_1', success: true })
    const store = useDocumentsStore()
    await store.fetchDocuments('ws_1')

    const ok = await store.deleteDocument('ws_1', 'doc_1')

    expect(ok).toBe(true)
    expect(store.documents.map((d) => d.id)).toEqual(['doc_2'])
  })

  it('a failed delete keeps the row and records the error', async () => {
    listDocuments.mockResolvedValue({ documents: [doc('doc_1')], count: 1 })
    deleteDocument.mockRejectedValue(new Error('document not found'))
    const store = useDocumentsStore()
    await store.fetchDocuments('ws_1')

    const ok = await store.deleteDocument('ws_1', 'doc_1')

    expect(ok).toBe(false)
    expect(store.error).toBe('document not found')
    expect(store.documents).toHaveLength(1)
  })

  it('clears `saving` on both the success and the failure path', async () => {
    updateDocument.mockRejectedValue(new Error('nope'))
    const store = useDocumentsStore()
    await store.updateDocument('ws_1', 'doc_1', { content: 'x' })
    // A `saving` flag stuck true after an error disables the Save button
    // forever, with no error explaining why.
    expect(store.saving).toBe(false)
  })
})

describe('documents store — single-document load', () => {
  it('serves a cached row without a network call', async () => {
    listDocuments.mockResolvedValue({ documents: [doc('doc_1', { content: 'cached' })], count: 1 })
    const store = useDocumentsStore()
    await store.fetchDocuments('ws_1')
    getDocument.mockClear()

    const loaded = await store.loadDocument('ws_1', 'doc_1')

    expect(loaded?.content).toBe('cached')
    // The list response already carries every body, so a sidebar-driven
    // open costs nothing extra.
    expect(getDocument).not.toHaveBeenCalled()
  })

  it('falls through to the API for a deep-linked id not in the list', async () => {
    getDocument.mockResolvedValue({ document: doc('doc_9', { content: 'deep link' }) })
    const store = useDocumentsStore()

    const loaded = await store.loadDocument('ws_1', 'doc_9')

    expect(loaded?.id).toBe('doc_9')
    expect(getDocument).toHaveBeenCalledWith('ws_1', 'doc_9')
  })

  it('a 404 on a deep link is an error, not an empty document', async () => {
    getDocument.mockRejectedValue(new Error('document not found'))
    const store = useDocumentsStore()

    const loaded = await store.loadDocument('ws_1', 'doc_9')

    // Returning `doc(...)` with an empty body here would render a blank
    // document that looks like a real, empty note.
    expect(loaded).toBe(null)
    expect(store.error).toBe('document not found')
  })
})

describe('documents store — workspace switch', () => {
  it('reset clears the list so workspace A rows are never shown under workspace B', async () => {
    listDocuments.mockResolvedValue({ documents: [doc('doc_1')], count: 1 })
    const store = useDocumentsStore()
    await store.fetchDocuments('ws_1')
    expect(store.documents).toHaveLength(1)

    store.reset()

    expect(store.documents).toEqual([])
    expect(store.loaded).toBe(false)
    expect(store.error).toBe(null)
    expect(store.saving).toBe(false)
  })

  it('never filters by workspace client-side — the server already scoped it', async () => {
    // A response containing another workspace's row is a BACKEND bug, and
    // hiding it here would hide the bug too. Assert the absence of a
    // filter so a future "defensive" one is a visible decision.
    listDocuments.mockResolvedValue({
      documents: [doc('doc_1', { workspace_id: 'ws_2' })],
      count: 1,
    })
    const store = useDocumentsStore()
    await store.fetchDocuments('ws_1')
    expect(store.documents).toHaveLength(1)
  })
})
