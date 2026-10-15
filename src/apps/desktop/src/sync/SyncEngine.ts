/**
 * Generic local-first sync engine.
 *
 * Storage-agnostic orchestration: cache-then-delta reads, cursor tracking,
 * write-through, and older-page loads from cache. Knows nothing about chat —
 * concrete children (e.g. ChatEngineDb) wire the object-store name, the
 * compare function and the network fetcher.
 *
 * Effect notes
 * ------------
 * Every operation returns an `Effect` instead of a `Promise`. The important
 * change is not the promise wrapper, it is the second type parameter:
 *
 *   - Operations documented as best-effort (`putLocal`, `removeLocal`,
 *     `setCursor`, `clear`) keep their "must never break the UI" contract and
 *     therefore have an error channel of `never`. They still swallow, but
 *     with `Effect.catchAll` and a warning, instead of a bare `catch {}` that
 *     discarded the reason entirely.
 *   - Operations a caller may want to reason about (`primeFromCache`,
 *     `getCursor`, `loadOlderFromCache`) surface `SyncError`, so "the backend
 *     is down" is no longer indistinguishable from "there is nothing new".
 *
 * Two structural changes fall out of the port:
 *
 *  - The engine no longer keeps a private in-memory mirror. The `SyncStore`
 *    is always present — `IndexedDbStoreLive` falls back to memory when
 *    IndexedDB is unavailable, and `makeMemorySyncStore` is the SSR/spec
 *    variant — so the two parallel memory maps that used to exist (one here,
 *    one inside the store) collapse into one.
 *  - The store is injected as a value rather than a `Layer`, and each engine
 *    instance keeps its own — the pre-port behaviour, deliberately. A
 *    `Layer.sync` would construct a fresh instance per `Effect.provide`
 *    (rebuilding the IndexedDB connection on every operation), and sharing one
 *    instance across engines changes which rows a given engine can see, which
 *    is a separate behavioural change that needs its own test coverage.
 *    `IndexedDbStoreLive` remains available for callers that compose a whole
 *    program and want the store in context.
 */
import { Effect, Either } from 'effect'
import type { SyncError } from './SyncError'
import { SyncRemoteError } from './SyncError'
import { makeIndexedDbSyncStore } from './IndexedDbStore'
import type { SyncStoreShape } from './SyncStore'
import type { Syncable, SyncDelta } from './SyncTypes'

export type { Syncable, SyncDelta, SyncPage } from './SyncTypes'

/** Result of a mount-time cache-then-revalidate read. */
export interface SyncMountResult<T> {
  items: T[]
  /** True when the cache supplied the first paint. */
  fromCache: boolean
  /** The revalidated delta, or `null` when the revalidation failed. */
  delta: SyncDelta<T> | null
  /**    * Why the revalidation failed, when it did. `null` means the delta fetch succeeded — including
   * the "it succeeded and returned no rows" case that the previous `catch { return { items: cached,
   * fromCache, delta } }` made indistinguishable from failure. */
  error: SyncError | null
}

export abstract class BaseSyncEngine<T extends Syncable, C = string> {
  /**    * @param storeName Object-store name this engine reads and writes. @param store Local-cache
   * implementation; specs substitute a fake. Defaults to a fresh IndexedDB-backed store per engine,
   * matching the isolation the pre-port constructors had. */
  constructor(
    protected readonly storeName: string,
    protected readonly store: SyncStoreShape = makeIndexedDbSyncStore(),
  ) {}

  /** Remote delta fetch. Rejections arrive as `SyncRemoteError`. */
  protected abstract fetchDelta(
    cursor: string | null,
    limit: number,
    ctx: C,
  ): Effect.Effect<SyncDelta<T>, SyncRemoteError>

  protected abstract cursorOf(item: T): string | null

  protected abstract compareFn(a: T, b: T): number

  protected memKey(ctx: C): string {
    return String(ctx)
  }

  protected sortKeyOf(item: T): string | number {
    return item.sortKey
  }

  getCursor(ctx: C): Effect.Effect<string | null, SyncError> {
    return this.store.getCursor(this.storeName, this.memKey(ctx))
  }

  /** Best-effort: the store's own mirror is already updated. Never fails. */
  setCursor(ctx: C, cursor: string | null): Effect.Effect<void> {
    return this.store
      .setCursor(this.storeName, this.memKey(ctx), cursor)
      .pipe(Effect.catchAll((e) => this.note(`setCursor(${this.storeName})`, e)))
  }

  clear(ctx: C): Effect.Effect<void> {
    return this.store
      .clear(this.storeName, this.memKey(ctx))
      .pipe(Effect.catchAll((e) => this.note(`clear(${this.storeName})`, e)))
  }

  /** Cache-first read for mount: newest `limit` rows, already sorted. */
  primeFromCache(ctx: C, limit: number): Effect.Effect<T[], SyncError> {
    return this.store
      .getAll<T>(this.storeName, this.memKey(ctx), limit)
      .pipe(Effect.map((rows) => rows.slice().sort(this.compareFn.bind(this)) as T[]))
  }

  /** Cache-then-delta: return cached rows immediately when present, then fetch
   * the network delta, merge (dedupe by id), persist, and advance the cursor.
   * Never fails — a broken cache or an unreachable backend degrades to the
   * painted cache — but `error` now records why, which the previous bare
   * `catch` discarded. */
  syncOnMount(ctx: C, limit: number): Effect.Effect<SyncMountResult<T>> {
    // `Effect.gen` takes a generator function, and a generator's `this` is its own — so `this` has
    // to be captured outside. It cannot be destructured instead: the engine API lives on the
    // prototype, and an unbound destructured method would run with `this === undefined`.
    // oxlint-disable-next-line typescript-eslint/no-this-alias -- see above
    const engine = this
    return Effect.gen(function* () {
      const cached = yield* engine
        .primeFromCache(ctx, limit)
        .pipe(Effect.catchAll(() => Effect.succeed<T[]>([])))

      const attempt = yield* Effect.either(
        Effect.gen(function* () {
          const cursor = yield* engine.getCursor(ctx)
          const delta = yield* engine.fetchDelta(cursor, limit, ctx)
          const merged = engine.mergeReplacing(cached, delta.items)
          yield* engine.putLocal(ctx, delta.items)
          if (delta.cursorToSave !== undefined) {
            yield* engine.setCursor(ctx, delta.cursorToSave)
          }
          return {
            items: merged,
            fromCache: cached.length > 0,
            delta,
            error: null,
          } satisfies SyncMountResult<T>
        }),
      )

      if (Either.isRight(attempt)) return attempt.right
      return {
        items: cached,
        fromCache: cached.length > 0,
        delta: null,
        error: attempt.left,
      } satisfies SyncMountResult<T>
    })
  }

  /** Best-effort write-through (e.g. SSE `full` handler). Never fails: a cache
   * write must not break the live update path that triggered it. */
  putLocal(ctx: C, items: T[]): Effect.Effect<void> {
    if (items.length === 0) return Effect.void
    return this.store
      .putAll(this.storeName, this.memKey(ctx), items)
      .pipe(Effect.catchAll((e) => this.note(`putLocal(${this.storeName})`, e)))
  }

  /** Best-effort single-row eviction (e.g. SSE `deleted`). Never fails. */
  removeLocal(ctx: C, id: string): Effect.Effect<void> {
    return this.store
      .remove(this.storeName, this.memKey(ctx), id)
      .pipe(Effect.catchAll((e) => this.note(`removeLocal(${this.storeName})`, e)))
  }

  /**    * Older-page read for scroll-back: cache first. An empty result means the caller should fetch
   * from the network — an *error* now says the cache itself is unavailable, which the previous
   * `catch { return [] }` could not. */
  loadOlderFromCache(
    ctx: C,
    beforeSortKey: string | number,
    limit: number,
  ): Effect.Effect<T[], SyncError> {
    return this.store.getOlder<T>(this.storeName, this.memKey(ctx), beforeSortKey, limit)
  }

  /** Write-through merge: a same-id incoming row replaces the cached value. */
  protected mergeReplacing(cached: T[], incoming: T[]): T[] {
    const byId = new Map(cached.map((item) => [item.id, item]))
    for (const item of incoming) byId.set(item.id, item)
    return [...byId.values()].sort(this.compareFn.bind(this))
  }

  /** Swallow a best-effort failure, keeping the reason diagnosable. */
  private note(op: string, error: SyncError): Effect.Effect<void> {
    if (import.meta.env?.DEV) {
      console.warn(`[sync] best-effort ${op} failed: ${error._tag} ${error.reason}`)
    }
    return Effect.void
  }
}
