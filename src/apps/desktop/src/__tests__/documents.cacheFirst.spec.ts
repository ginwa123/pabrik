/** The documents list is cache-first, like the sidebar's Recent chats. Two layers are proven
 * separately, because they fail differently: - `DocumentEngineDb` against an injected memory store
 * — deterministic, no IndexedDB, so it can assert the exact cache contents after each write. */
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest'
import { Effect } from 'effect'
import { setActivePinia, createPinia } from 'pinia'

import * as api from '../api'
import type { Document } from '../api'
import { DocumentEngineDb, documentEngineDb, toDocumentRow } from '../sync/DocumentEngineDb'
import { makeMemorySyncStore } from '../sync/SyncStore'
import { runSyncVoid } from '../sync/runtime'
import { useDocumentsStore } from '../stores/documents'

const WS = 'ws_cache'
const OTHER_WS = 'ws_other'

const doc = (over: Partial<Document> = {}): Document => ({
  id: 'doc_1',
  workspace_id: WS,
  title: 'Release plan',
  content: '# heading',
  format: 'markdown',
  created_at: '2026-09-01 10:00:00',
  updated_at: '2026-09-01 10:00:00',
  ...over,
})

/** Every engine gets its own in-memory store, as ChatEngineDb's spec does. */
const engineWith = (fetchFn: unknown) =>
  new DocumentEngineDb(fetchFn as never, 'documents', makeMemorySyncStore())

const run = <A, E>(eff: Effect.Effect<A, E>): Promise<A> => Effect.runPromise(eff)

describe('DocumentEngineDb — cache contents', () => {
  it('loadDelta persists rows so the next mount paints from cache', async () => {
    const eng = engineWith(async () => ({ documents: [doc()], count: 1 }))

    const delta = await run(eng.loadDelta(WS))
    expect(delta.items.map((r) => r.id)).toEqual(['doc_1'])

    const cached = await run(eng.primeFromCache(WS, 50))
    expect(cached.map((r) => r.id)).toEqual(['doc_1'])
    // The BODY is cached, not just the title — that is the whole point of
    // using IndexedDB rather than a localStorage metadata cache.
    expect(cached[0]!.raw.content).toBe('# heading')
  })

  it('REPLACES rather than merges, so a server-side delete actually disappears', async () => {
    // The regression a merge would introduce: two rows land in the cache,
    // then the server returns one. The evicted row must not survive to be
    // painted on every later cold boot (clicking it would 404).
    const store = makeMemorySyncStore()
    const twoRows = async () => ({
      documents: [doc({ id: 'doc_1' }), doc({ id: 'doc_2' })],
      count: 2,
    })

    const first = new DocumentEngineDb(twoRows as never, 'documents', store)
    await run(first.loadDelta(WS))
    expect(await run(first.primeFromCache(WS, 50))).toHaveLength(2)

    // A FRESH engine over the SAME store models the next app session
    // reading what the last one persisted.
    const next = new DocumentEngineDb(
      (async () => ({ documents: [doc({ id: 'doc_1' })], count: 1 })) as never,
      'documents',
      store,
    )
    await run(next.loadDelta(WS))

    const after = await run(next.primeFromCache(WS, 50))
    expect(after.map((r) => r.id)).toEqual(['doc_1'])
  })

  it("partitions by workspace — one workspace never paints another's documents", async () => {
    const eng = engineWith(async () => ({ documents: [doc({ id: 'doc_1' })], count: 1 }))
    await run(eng.loadDelta(WS))
    await run(eng.putDocument(OTHER_WS, doc({ id: 'doc_9', workspace_id: OTHER_WS })))

    expect(await run(eng.primeFromCache(WS, 50))).toHaveLength(1)
    expect((await run(eng.primeFromCache(OTHER_WS, 50))).map((r) => r.id)).toEqual(['doc_9'])
  })

  it('removeDocument evicts, and newest-first ordering is preserved', async () => {
    const eng = engineWith(async () => ({ documents: [], count: 0 }))
    await run(eng.putDocument(WS, doc({ id: 'old', updated_at: '2026-01-01 00:00:00' })))
    await run(eng.putDocument(WS, doc({ id: 'new', updated_at: '2026-09-01 00:00:00' })))

    const rows = await run(eng.primeFromCache(WS, 50))
    expect(rows.map((r) => r.id)).toEqual(['new', 'old'])

    await run(eng.removeDocument(WS, 'new'))
    expect((await run(eng.primeFromCache(WS, 50))).map((r) => r.id)).toEqual(['old'])
  })

  it('toDocumentRow keeps the full server object in raw', () => {
    const row = toDocumentRow(doc())
    expect(row.id).toBe('doc_1')
    expect(row.sortKey).toBe('2026-09-01 10:00:00')
    expect(row.raw.content).toBe('# heading')
  })
})

describe('useDocumentsStore — cache-first contract', () => {
  beforeEach(async () => {
    setActivePinia(createPinia())
    // The singleton's cache outlives `createPinia()` — that is the point of
    // it — so each test starts from a cold cache explicitly.
    await runSyncVoid(documentEngineDb.clear(WS), 'spec.clear')
    await runSyncVoid(documentEngineDb.clear(OTHER_WS), 'spec.clear')
  })

  afterEach(() => {
    vi.restoreAllMocks()
  })

  it('a REAL cold boot paints from cache with the network dead (the regression)', async () => {
    // Seed the cache the way a previous session would have, then throw away every scrap of
    // in-memory state. This is the user scenario the cache exists for: reload the app offline and
    // still see the documents.
    await run(documentEngineDb.putDocument(WS, doc()))
    setActivePinia(createPinia())
    const store = useDocumentsStore()
    expect(store.documents).toHaveLength(0) // nothing in memory yet

    vi.spyOn(api, 'listDocuments').mockRejectedValue(new Error('offline'))
    await store.fetchDocuments(WS)

    expect(store.documents).toHaveLength(1)
    expect(store.documents[0]!.title).toBe('Release plan')
    // The BODY came back too, so clicking the row opens real content with
    // no second round trip.
    expect(store.documents[0]!.content).toBe('# heading')
    // And the failure is still VISIBLE, not swallowed into the empty value.
    expect(store.error).toContain('offline')
  })

  it('a failed revalidation never blanks rows that are already on screen', async () => {
    const store = useDocumentsStore()
    vi.spyOn(api, 'listDocuments').mockResolvedValue({ documents: [doc()], count: 1 })
    await store.fetchDocuments(WS)
    expect(store.documents).toHaveLength(1)

    vi.spyOn(api, 'listDocuments').mockRejectedValue(new Error('offline'))
    await store.fetchDocuments(WS)

    // The regression this cache change could reintroduce: a failed refresh
    // degrading to an empty list, which reads to the user as data loss.
    expect(store.documents).toHaveLength(1)
    expect(store.error).toContain('offline')
  })

  it('create / update / delete keep the cache in step with the server', async () => {
    const store = useDocumentsStore()
    vi.spyOn(api, 'listDocuments').mockResolvedValue({ documents: [], count: 0 })
    await store.fetchDocuments(WS)

    vi.spyOn(api, 'createDocument').mockResolvedValue({
      document: doc({ id: 'doc_new', title: 'Fresh' }),
    })
    const created = await store.createDocument(WS, 'Fresh')
    expect(created?.id).toBe('doc_new')
    expect((await run(documentEngineDb.primeFromCache(WS, 50))).map((r) => r.id)).toEqual([
      'doc_new',
    ])

    vi.spyOn(api, 'updateDocument').mockResolvedValue({
      document: doc({ id: 'doc_new', title: 'Renamed', content: 'edited body' }),
    })
    await store.updateDocument(WS, 'doc_new', { title: 'Renamed' })
    const cached = await run(documentEngineDb.primeFromCache(WS, 50))
    // The BODY travels with the write-through, so an offline reload cannot
    // show the pre-edit body under the post-edit title.
    expect(cached[0]!.raw.title).toBe('Renamed')
    expect(cached[0]!.raw.content).toBe('edited body')

    vi.spyOn(api, 'deleteDocument').mockResolvedValue(undefined as never)
    await store.deleteDocument(WS, 'doc_new')
    // Evicted, not left to reappear on the next cold boot.
    expect(await run(documentEngineDb.primeFromCache(WS, 50))).toHaveLength(0)
  })

  it('a cold cache plus a dead backend renders the error, never "No documents yet"', async () => {
    const store = useDocumentsStore()
    vi.spyOn(api, 'listDocuments').mockRejectedValue(new Error('HTTP 500'))

    await store.fetchDocuments(WS)

    // The empty-vs-unavailable contract, now behind a cache. It is easier to
    // break here: "no cached rows" and "the revalidation failed" are the
    // same `[]` unless the failure is carried in the type.
    expect(store.documents).toHaveLength(0)
    expect(store.error).toContain('HTTP 500')
    expect(store.loaded).toBe(false)
  })
})
