/**
 * `SyncStore` — the local-cache boundary of the sync engine.
 *
 * This used to be a plain interface with exactly one production
 * implementation (`IndexedDbStore`) plus a hand-rolled in-memory fallback
 * inside the engine. That is a Layer written by hand and never labelled as
 * one, so we now say it out loud: the tag is the service, the IndexedDB
 * adapter is `IndexedDbStoreLive`, and `makeMemorySyncStore` is the fake
 * every spec substitutes via `Layer.succeed`.
 *
 * Rows are carried through the generic parameter rather than through a
 * per-store interface, and the object-store name is an explicit argument.
 * That is what lets a single service — and a single database connection —
 * back the `messages`, `sessions` and `tasks` stores, instead of each engine
 * opening its own handle to the same file.
 */
import { Context, Effect, Layer } from 'effect'
import { SyncStorageError } from './SyncError'
import type { Syncable } from './SyncTypes'

export interface SyncStoreShape {
  /** Newest `limit` rows for `key`, already sorted newest-first. */
  readonly getAll: <T extends Syncable>(
    store: string,
    key: string,
    limit: number,
  ) => Effect.Effect<T[], SyncStorageError>

  readonly putAll: <T extends Syncable>(
    store: string,
    key: string,
    items: readonly T[],
  ) => Effect.Effect<void, SyncStorageError>

  readonly remove: (store: string, key: string, id: string) => Effect.Effect<void, SyncStorageError>

  /** Up to `limit` rows strictly older than `beforeSortKey`, newest-first. */
  readonly getOlder: <T extends Syncable>(
    store: string,
    key: string,
    beforeSortKey: string | number,
    limit: number,
  ) => Effect.Effect<T[], SyncStorageError>

  readonly getCursor: (store: string, key: string) => Effect.Effect<string | null, SyncStorageError>

  readonly setCursor: (
    store: string,
    key: string,
    cursor: string | null,
  ) => Effect.Effect<void, SyncStorageError>

  readonly clear: (store: string, key: string) => Effect.Effect<void, SyncStorageError>
}

export class SyncStore extends Context.Tag('app/SyncStore')<SyncStore, SyncStoreShape>() {}

/** Newest-first by sortKey desc; handles the string|number sortKey union. */
export function sortNewestFirst<T extends Syncable>(rows: ReadonlyArray<T>): T[] {
  return rows.slice().sort((a, b) => {
    const ak = a.sortKey
    const bk = b.sortKey
    if (typeof ak === 'number' && typeof bk === 'number') return bk - ak
    return String(bk) < String(ak) ? -1 : String(bk) > String(ak) ? 1 : 0
  })
}

const cell = (store: string, key: string): string => `${store} ${key}`

/**  * In-memory `SyncStore`: the no-IndexedDB fallback (SSR, tests, private browsing) and the test
 * double. It cannot fail, so its error channel is `never` — which is precisely why substituting it
 * needs no stubbing. */
export function makeMemorySyncStore(): SyncStoreShape {
  const rows = new Map<string, Syncable[]>()
  const cursors = new Map<string, string | null>()

  return {
    getAll: <T extends Syncable>(store: string, key: string, limit: number) =>
      Effect.succeed(sortNewestFirst(rows.get(cell(store, key)) ?? []).slice(0, limit) as T[]),
    putAll: <T extends Syncable>(store: string, key: string, items: readonly T[]) => {
      const c = cell(store, key)
      const byId = new Map((rows.get(c) ?? []).map((r) => [r.id, r]))
      for (const item of items) byId.set(item.id, item)
      rows.set(c, [...byId.values()])
      return Effect.void
    },
    remove: (store: string, key: string, id: string) => {
      const c = cell(store, key)
      rows.set(
        c,
        (rows.get(c) ?? []).filter((r) => r.id !== id),
      )
      return Effect.void
    },
    getOlder: <T extends Syncable>(
      store: string,
      key: string,
      beforeSortKey: string | number,
      limit: number,
    ) =>
      Effect.succeed(
        sortNewestFirst(
          (rows.get(cell(store, key)) ?? []).filter((r) => r.sortKey < beforeSortKey),
        ).slice(0, limit) as T[],
      ),
    getCursor: (store: string, key: string) =>
      Effect.succeed(cursors.get(cell(store, key)) ?? null),
    setCursor: (store: string, key: string, cursor: string | null) => {
      cursors.set(cell(store, key), cursor)
      return Effect.void
    },
    clear: (store: string, key: string) => {
      rows.delete(cell(store, key))
      cursors.delete(cell(store, key))
      return Effect.void
    },
  }
}

/** Ready-made layer for specs and for the no-IndexedDB runtime. */
export const memorySyncStoreLayer: Layer.Layer<SyncStore> = Layer.sync(
  SyncStore,
  makeMemorySyncStore,
)
