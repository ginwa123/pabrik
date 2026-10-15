/**
 * `IndexedDbStoreLive` — the production `SyncStore` Layer.
 *
 * One service, one database connection, three object stores. The previous
 * shape gave every engine its own `IndexedDbStore` instance, so the same
 * `pabrik-sync` file was opened three times (once per engine) with the
 * object-store name baked into the instance. Passing the store name per
 * call removes that duplication.
 *
 * The adapter keeps an in-memory mirror of everything it writes, exactly as
 * before, so a browser with IndexedDB disabled (or a rejected open) still
 * serves reads. It is now honest about failures though: an IndexedDB error
 * surfaces as `SyncStorageError` on the error channel instead of being
 * swallowed into a silent empty result, and the engine decides whether to
 * degrade. That decision previously lived in a bare `catch {}`.
 */
import { Effect, Layer } from 'effect'
import { SyncStorageError } from './SyncError'
import { SyncStore, type SyncStoreShape, sortNewestFirst } from './SyncStore'
import type { Syncable } from './SyncTypes'
import { getCurrentUserId } from '../helpers/userScope'

const DB_NAME = 'pabrik-sync'

/**
 * Per-user database name.
 *
 * The sync cache holds full message bodies, so one shared database means
 * B inherits A's cached chats. Splitting the DATABASE (rather than adding a
 * `userId` to every key path) needs no schema or key migration and makes a
 * cross-user read impossible by construction — the other user's rows are in
 * a different database.
 *
 * No identity (auth off, or `/api/auth/me` unresolved) keeps the legacy
 * `pabrik-sync` name, so the auth-off path is unchanged.
 */
function dbName(): string {
  const userId = getCurrentUserId()
  return userId ? `${DB_NAME}:${userId}` : DB_NAME
}

// v2 added sessions; v3 adds the task-list cache; v4 adds documents.
const DB_VERSION = 4
const KNOWN_STORES = ['messages', 'sessions', 'tasks', 'documents']
const TASK_STORE_KEY_PATH: string[] = ['ctx', 'id']
/** Every store sorts on the engine's normalised `sortKey` field. */
const SORT_KEY_PATH = 'sortKey'

/** Object stores whose primary key is the row id alone. */
const keyPathFor = (store: string): string | string[] =>
  store === 'tasks' ? TASK_STORE_KEY_PATH : 'id'

type IdbModule = typeof import('idb')

/** Builds the live `SyncStore`. Exported separately from the Layer so specs
 * can drive the adapter with a stubbed `idb` module. */
export const makeIndexedDbSyncStore = (): SyncStoreShape => {
  let dbPromise: Promise<import('idb').IDBPDatabase> | null = null
  let idbFailed = false
  const mem = new Map<string, Syncable[]>()
  const memCursors = new Map<string, string | null>()

  const cell = (store: string, key: string): string => `${store} ${key}`

  const idb = async (): Promise<IdbModule | null> => {
    if (typeof indexedDB === 'undefined') return null
    try {
      return await import('idb')
    } catch {
      return null
    }
  }

  const db = async (): Promise<import('idb').IDBPDatabase | null> => {
    if (idbFailed || typeof indexedDB === 'undefined') return null
    if (!dbPromise) {
      const mod = await idb()
      if (!mod) return null
      dbPromise = mod.openDB(dbName(), DB_VERSION, {
        upgrade(idbDb) {
          for (const name of KNOWN_STORES) {
            if (idbDb.objectStoreNames.contains(name)) continue
            const store = idbDb.createObjectStore(name, { keyPath: keyPathFor(name) })
            store.createIndex('by_ctx_sort', ['ctx', SORT_KEY_PATH])
          }
          if (!idbDb.objectStoreNames.contains('sync_state')) {
            idbDb.createObjectStore('sync_state', { keyPath: 'key' })
          }
        },
      })
      dbPromise.catch(() => {
        idbFailed = true
        dbPromise = null
      })
    }
    try {
      return await dbPromise
    } catch {
      idbFailed = true
      dbPromise = null
      return null
    }
  }

  /** Wraps an IndexedDB operation so a rejection becomes a typed
   * `SyncStorageError` instead of an unhandled promise rejection. */
  const attempt = <A>(
    store: string,
    op: string,
    body: () => Promise<A>,
  ): Effect.Effect<A, SyncStorageError> =>
    Effect.tryPromise({
      try: body,
      catch: (e) =>
        new SyncStorageError({
          op,
          store,
          reason: e instanceof Error ? e.message : String(e),
        }),
    })

  return {
    getAll: <T extends Syncable>(store: string, key: string, limit: number) => {
      const memRows = (mem.get(cell(store, key)) ?? []).slice()
      if (typeof indexedDB === 'undefined') {
        return Effect.succeed(sortNewestFirst(memRows).slice(0, limit) as T[])
      }
      return Effect.gen(function* () {
        const handle = yield* Effect.promise(db)
        if (!handle) return yield* Effect.succeed(sortNewestFirst(memRows).slice(0, limit) as T[])
        const rows = yield* attempt(store, 'getAll', async () => {
          const tx = handle.transaction(store, 'readonly')
          const index = tx.store.index('by_ctx_sort')
          return (await index.getAll(IDBKeyRange.bound([key, -Infinity], [key, Infinity]))) as T[]
        })
        return sortNewestFirst(rows).slice(0, limit) as T[]
      })
    },

    putAll: <T extends Syncable>(store: string, key: string, items: ReadonlyArray<T>) => {
      const stamped = items.map((item) => ({ ...item, ctx: key }))
      const c = cell(store, key)
      const byId = new Map((mem.get(c) ?? []).map((r) => [r.id, r]))
      for (const item of stamped) byId.set(item.id, item as unknown as Syncable)
      mem.set(c, [...byId.values()])
      if (typeof indexedDB === 'undefined') return Effect.void
      return Effect.gen(function* () {
        const handle = yield* Effect.promise(db)
        if (!handle) return
        yield* attempt(store, 'putAll', async () => {
          const tx = handle.transaction(store, 'readwrite')
          for (const item of stamped) await tx.store.put(item)
          await tx.done
        })
      })
    },

    remove: (store: string, key: string, id: string) => {
      const primaryKey = store === 'tasks' ? [key, id] : id
      const c = cell(store, key)
      mem.set(
        c,
        (mem.get(c) ?? []).filter((r) => r.id !== id),
      )
      if (typeof indexedDB === 'undefined') return Effect.void
      return Effect.gen(function* () {
        const handle = yield* Effect.promise(db)
        if (!handle) return
        yield* attempt(store, 'remove', async () => {
          await handle.delete(store, primaryKey as never)
        })
      })
    },

    getOlder: <T extends Syncable>(
      store: string,
      key: string,
      beforeSortKey: string | number,
      limit: number,
    ) => {
      const fromMem = (): T[] =>
        sortNewestFirst(
          (mem.get(cell(store, key)) ?? []).filter((r) => r.sortKey < beforeSortKey),
        ).slice(0, limit) as T[]
      if (typeof indexedDB === 'undefined') return Effect.succeed(fromMem())
      return Effect.gen(function* () {
        const handle = yield* Effect.promise(db)
        if (!handle) return yield* Effect.succeed(fromMem())
        const rows = yield* attempt(store, 'getOlder', async () => {
          const tx = handle.transaction(store, 'readonly')
          const index = tx.store.index('by_ctx_sort')
          return (await index.getAll(
            IDBKeyRange.bound([key, -Infinity], [key, beforeSortKey as never], false, true),
          )) as T[]
        })
        return sortNewestFirst(rows).slice(0, limit) as T[]
      })
    },

    getCursor: (store: string, key: string) => {
      const c = cell(store, key)
      if (typeof indexedDB === 'undefined') return Effect.succeed(memCursors.get(c) ?? null)
      return Effect.gen(function* () {
        const handle = yield* Effect.promise(db)
        if (!handle) return yield* Effect.succeed(memCursors.get(c) ?? null)
        const row = yield* attempt(store, 'getCursor', () =>
          handle.get('sync_state', `${store}:${key}`),
        )
        return ((row as { cursor?: string | null } | undefined)?.cursor ?? null) as string | null
      })
    },

    setCursor: (store: string, key: string, cursor: string | null) => {
      const c = cell(store, key)
      memCursors.set(c, cursor)
      if (typeof indexedDB === 'undefined') return Effect.void
      return Effect.gen(function* () {
        const handle = yield* Effect.promise(db)
        if (!handle) return
        yield* attempt(store, 'setCursor', async () => {
          await handle.put('sync_state', { key: `${store}:${key}`, cursor })
        })
      })
    },

    clear: (store: string, key: string) => {
      const c = cell(store, key)
      mem.delete(c)
      memCursors.delete(c)
      if (typeof indexedDB === 'undefined') return Effect.void
      return Effect.gen(function* () {
        const handle = yield* Effect.promise(db)
        if (!handle) return
        yield* attempt(store, 'clear', async () => {
          const tx = handle.transaction(store, 'readwrite')
          const index = tx.store.index('by_ctx_sort')
          let cursor = await index.openCursor(IDBKeyRange.bound([key, -Infinity], [key, Infinity]))
          while (cursor) {
            await cursor.delete()
            cursor = await cursor.continue()
          }
          await tx.done
          await handle.delete('sync_state', `${store}:${key}`)
        })
      })
    },
  }
}

/** Production layer: the IndexedDB-backed local cache. */
export const IndexedDbStoreLive: Layer.Layer<SyncStore> = Layer.sync(
  SyncStore,
  makeIndexedDbSyncStore,
)
