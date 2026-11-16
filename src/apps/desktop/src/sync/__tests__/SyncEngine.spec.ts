import { describe, it, expect, vi } from 'vitest'
import { Effect } from 'effect'
import { BaseSyncEngine, type Syncable } from '../SyncEngine'
import { SyncRemoteError, SyncStorageError } from '../SyncError'
import { makeMemorySyncStore, type SyncStoreShape } from '../SyncStore'
import type { SyncDelta } from '../SyncTypes'

interface Item extends Syncable {
  id: string
  sortKey: number
}

const mk = (id: string, sortKey: number): Item => ({ id, sortKey })

const remoteFail = (reason: string) =>
  Effect.fail(new SyncRemoteError({ op: 'test.fetchDelta', reason }))

class TestEngine extends BaseSyncEngine<Item, string> {
  constructor(
    store: SyncStoreShape,
    private fetcher: (
      cursor: string | null,
      limit: number,
      ctx: string,
    ) => Effect.Effect<SyncDelta<Item>, SyncRemoteError>,
    storeName = 'items',
  ) {
    super(storeName, store)
  }
  protected fetchDelta(cursor: string | null, limit: number, ctx: string) {
    return this.fetcher(cursor, limit, ctx)
  }
  protected cursorOf(item: Item) {
    return item.id
  }
  protected compareFn(a: Item, b: Item) {
    return b.sortKey - a.sortKey
  }
}

const run = <A, E>(eff: Effect.Effect<A, E>): Promise<A> => Effect.runPromise(eff)

const emptyDelta = (): Effect.Effect<SyncDelta<Item>, SyncRemoteError> =>
  Effect.succeed({ items: [], nextCursor: null, hasMore: false, cursorToSave: null })

describe('BaseSyncEngine orchestration', () => {
  it('cache-then-delta merges, dedupes, and advances the cursor', async () => {
    const store = makeMemorySyncStore()
    await Effect.runPromise(store.putAll<Item>('items', 's1', [mk('a', 3), mk('b', 2)]))
    await Effect.runPromise(store.setCursor('items', 's1', 'cur-0'))
    const fetch = vi.fn(
      (): Effect.Effect<SyncDelta<Item>, SyncRemoteError> =>
        Effect.succeed({
          items: [mk('b', 2), mk('c', 1)],
          nextCursor: 'cur-1',
          hasMore: false,
          cursorToSave: 'cur-1',
        }),
    )
    const eng = new TestEngine(store, fetch)

    const res = await run(eng.syncOnMount('s1', 50))

    expect(res.fromCache).toBe(true)
    expect(res.error).toBeNull()
    expect(res.items.map((m) => m.id)).toEqual(['a', 'b', 'c'])
    expect(fetch).toHaveBeenCalledWith('cur-0', 50, 's1')
    expect(await run(eng.getCursor('s1'))).toBe('cur-1')
    // Persisted without dupes.
    expect((await run(store.getAll<Item>('items', 's1', 50))).map((m) => m.id).sort()).toEqual([
      'a',
      'b',
      'c',
    ])
  })

  it('keeps the painted cache when the network fails, and says why', async () => {
    const store = makeMemorySyncStore()
    await Effect.runPromise(store.putAll<Item>('items', 's1', [mk('a', 3)]))
    const eng = new TestEngine(store, () => remoteFail('offline'))

    const res = await run(eng.syncOnMount('s1', 50))

    expect(res.items.map((m) => m.id)).toEqual(['a'])
    expect(res.fromCache).toBe(true)
    expect(res.delta).toBeNull()
    // The reason the previous `catch {}` threw away.
    expect(res.error).toBeInstanceOf(SyncRemoteError)
    expect(res.error?._tag).toBe('SyncRemoteError')
    expect(res.error).toMatchObject({ op: 'test.fetchDelta', reason: 'offline' })
  })

  it('an empty-but-successful delta is distinguishable from a failure', async () => {
    const store = makeMemorySyncStore()
    const eng = new TestEngine(store, () => emptyDelta())

    const res = await run(eng.syncOnMount('s1', 50))

    // Same rendered rows as the failure case, opposite diagnosis.
    expect(res.items).toEqual([])
    expect(res.error).toBeNull()
    expect(res.delta).not.toBeNull()
    expect(res.delta?.items).toEqual([])
  })

  it('syncOnMount returns the same replacement it persists', async () => {
    const eng = new TestEngine(makeMemorySyncStore(), () =>
      Effect.succeed({
        items: [{ ...mk('tool-row-1', 3), label: 'server completed' } as Item],
        nextCursor: null,
        hasMore: false,
        cursorToSave: null,
      } as SyncDelta<Item>),
    )
    await run(eng.putLocal('s1', [{ ...mk('tool-row-1', 3), label: 'placeholder' } as Item]))

    const result = await run(eng.syncOnMount('s1', 50))

    expect(result.items[0]).toMatchObject({ id: 'tool-row-1', label: 'server completed' })
    expect((await run(eng.primeFromCache('s1', 50)))[0]).toMatchObject({
      label: 'server completed',
    })
  })

  it('putLocal replaces an existing row with the same id', async () => {
    const eng = new TestEngine(makeMemorySyncStore(), () => emptyDelta())

    await run(eng.putLocal('s1', [mk('tool-row-1', 3)]))
    await run(eng.putLocal('s1', [{ ...mk('tool-row-1', 3), label: 'completed' } as Item]))

    const rows = await run(eng.primeFromCache('s1', 10))
    expect(rows).toHaveLength(1)
    expect(rows[0]).toMatchObject({ id: 'tool-row-1', label: 'completed' })
  })

  it('putLocal never throws and loadOlderFromCache reads older rows', async () => {
    const eng = new TestEngine(makeMemorySyncStore(), () => emptyDelta())
    await run(eng.putLocal('s1', [mk('a', 3), mk('b', 2), mk('c', 1)]))

    const older = await run(eng.loadOlderFromCache('s1', 2, 10))
    expect(older.map((m) => m.id)).toEqual(['c'])

    await run(eng.clear('s1'))
    expect(await run(eng.primeFromCache('s1', 10))).toEqual([])
  })
})

describe('BaseSyncEngine error channels', () => {
  const boom = (op: string) =>
    Effect.fail(new SyncStorageError({ op, store: 'items', reason: 'quota' }))

  /** A store whose writes always fail, to prove best-effort ops stay total. */
  const failingWriteStore = (): SyncStoreShape => ({
    ...makeMemorySyncStore(),
    putAll: () => boom('putAll'),
    setCursor: () => boom('setCursor'),
    remove: () => boom('remove'),
    clear: () => boom('clear'),
  })

  it('best-effort writes swallow a storage failure instead of failing the live path', async () => {
    const eng = new TestEngine(failingWriteStore(), () => emptyDelta())

    // None of these reject — that is the contract the SSE handlers rely on.
    await expect(run(eng.putLocal('s1', [mk('a', 3)]))).resolves.toBeUndefined()
    await expect(run(eng.setCursor('s1', 'x'))).resolves.toBeUndefined()
    await expect(run(eng.removeLocal('s1', 'a'))).resolves.toBeUndefined()
    await expect(run(eng.clear('s1'))).resolves.toBeUndefined()
  })

  it('reads a failing store do report, so a broken cache is not read as "no rows"', async () => {
    const store: SyncStoreShape = {
      ...makeMemorySyncStore(),
      getAll: () =>
        Effect.fail(
          new SyncStorageError({ op: 'getAll', store: 'items', reason: 'db closed' }),
        ) as never,
    }
    const eng = new TestEngine(store, () => emptyDelta())

    const exit = await Effect.runPromise(Effect.exit(eng.primeFromCache('s1', 10)))
    expect(exit._tag).toBe('Failure')
  })

  it('a broken cache read still degrades to a mount instead of throwing', async () => {
    const store: SyncStoreShape = {
      ...makeMemorySyncStore(),
      getAll: () =>
        Effect.fail(
          new SyncStorageError({ op: 'getAll', store: 'items', reason: 'db closed' }),
        ) as never,
    }
    const eng = new TestEngine(store, () => emptyDelta())

    // syncOnMount's contract is still "never fails".
    const res = await run(eng.syncOnMount('s1', 10))
    expect(res.items).toEqual([])
    expect(res.fromCache).toBe(false)
    expect(res.error).toBeNull()
  })

  it('reports a storage error when the revalidation cannot complete either', async () => {
    const store: SyncStoreShape = {
      ...makeMemorySyncStore(),
      getCursor: () =>
        Effect.fail(
          new SyncStorageError({ op: 'getCursor', store: 'items', reason: 'db closed' }),
        ) as never,
      getAll: () =>
        Effect.fail(
          new SyncStorageError({ op: 'getAll', store: 'items', reason: 'db closed' }),
        ) as never,
    }
    const eng = new TestEngine(store, () => emptyDelta())

    const res = await run(eng.syncOnMount('s1', 10))
    expect(res.items).toEqual([])
    expect(res.error?._tag).toBe('SyncStorageError')
    expect(res.error).toMatchObject({ op: 'getCursor' })
  })
})
