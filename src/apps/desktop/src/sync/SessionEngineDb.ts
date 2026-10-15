/**
 * Session-list child of the generic sync engine (sidebar local-first).
 *
 * Mirrors ChatEngineDb: cache-then-revalidate over api.getChats, each row
 * keeping the full server object in `raw` so cached mounts render through
 * the single ChatsList mapper with no shape drift. The cache is
 * partitioned by workspace (`ctx` = workspace id, `'all'` when unscoped),
 * matching ChatsList's `scopedWorkspaceId` refetch boundary.
 *
 * Cursor note: the backend paginates with an opaque cursor pointing at
 * the last item's sort value (session_list.zig) — it pages *older*, so
 * it cannot serve as a "newer tail" delta cursor the way ChatEngineDb's
 * created_at_nano does. loadDelta therefore re-fetches page 1 (desc)
 * and merges by id (30 rows, cheap, always correct). Infinite-scroll
 * cursors stay component-local (chatsNextCursor); no sync cursor is
 * persisted.
 */
import { Effect } from 'effect'
import * as api from '../api'
import type { Chat } from '../api'
import { BaseSyncEngine } from './SyncEngine'
import { SyncRemoteError, type SyncError } from './SyncError'
import type { SyncStoreShape } from './SyncStore'
import { makeIndexedDbSyncStore } from './IndexedDbStore'
import type { SyncDelta } from './SyncTypes'

/** Full server row for one session (branch, timestamps, model...). */
export type SessionRawRow = Chat

export interface SessionRow {
  id: string
  /** `updated_at` wall-clock string — matches the backend `sort_by=updated_at` order. */
  sortKey: string
  /** Complete server object, so cached renders match the network shape. */
  raw: SessionRawRow
}

/** Workspace partition key: workspace id, or `'all'` when unscoped. */
export type SessionCtx = string

export function sessionSortKey(m: Chat): string {
  return m.updated_at || ''
}

export function toSessionRow(m: Chat): SessionRow {
  return {
    id: m.session_id,
    sortKey: sessionSortKey(m),
    raw: m,
  }
}

export interface SessionDelta extends SyncDelta<SessionRow> {
  total: number
}

export class SessionEngineDb extends BaseSyncEngine<SessionRow, SessionCtx> {
  constructor(
    // Namespace indirection (NOT a bare `getChats` import): the property
    // is read at call time so `vi.spyOn(api, 'getChats')` — the seam
    // every ChatsList spec uses — intercepts engine fetches too.
    private fetchFn: typeof api.getChats = (...args) => api.getChats(...args),
    storeName = 'sessions',
    store: SyncStoreShape = makeIndexedDbSyncStore(),
  ) {
    super(storeName, store)
  }

  /** Newest-first: larger `updated_at` sorts earlier (ISO strings compare lexicographically). */
  compareFn(a: SessionRow, b: SessionRow): number {
    if (a.sortKey === b.sortKey) return 0
    return a.sortKey < b.sortKey ? 1 : -1
  }

  cursorOf(item: SessionRow): string | null {
    return item.sortKey || null
  }

  protected fetchDelta(
    cursor: string | null,
    limit: number,
    ctx: SessionCtx,
  ): Effect.Effect<SyncDelta<SessionRow>, SyncRemoteError> {
    return this.fetchDeltaPage(cursor, limit, ctx)
  }

  /** Page-1 revalidate: the backend cursor only pages older, so a stored
   * cursor is useless for "what's new" — always fetch the head of the
   * list desc and let the caller merge by id. `_cursor` is accepted for
   * the base-class contract and ignored. */
  fetchDeltaPage(
    _cursor: string | null,
    limit: number,
    ctx: SessionCtx,
  ): Effect.Effect<SessionDelta, SyncRemoteError> {
    const workspaceId = ctx === 'all' ? undefined : ctx
    return Effect.tryPromise({
      try: () => this.fetchFn('updated_at', 'desc', limit, undefined, workspaceId),
      catch: (e) =>
        new SyncRemoteError({
          op: 'sessions.fetchDelta',
          reason: e instanceof Error ? e.message : String(e),
        }),
    }).pipe(
      Effect.map((data): SessionDelta => {
        const items: SessionRow[] = (data.sessions ?? []).map(toSessionRow)
        return {
          items,
          nextCursor: data.next_cursor ?? null,
          hasMore: data.has_more ?? false,
          cursorToSave: data.next_cursor ?? null,
          total: data.total ?? items.length,
        }
      }),
    )
  }

  /** Background refresh for a cached mount: fetch page 1, persist it.
   * Now honest about failure — a rejected fetch surfaces as
   * `SyncRemoteError` instead of the old `catch { return null }`, so a
   * caller can tell "no new sessions" from "the sidebar could not refresh". */
  loadDelta(ctx: SessionCtx, limit: number): Effect.Effect<SessionDelta, SyncError> {
    // A generator's `this` is its own, so capture the engine outside.
    // oxlint-disable-next-line typescript-eslint/no-this-alias -- see SyncEngine.syncOnMount
    const engine = this
    return Effect.gen(function* () {
      const delta = yield* engine.fetchDeltaPage(null, limit, ctx)
      yield* engine.putLocal(ctx, delta.items)
      return delta
    })
  }

  /** Evict one session (SSE `deleted` / removeChat). Never fails. */
  removeSession(ctx: SessionCtx, id: string): Effect.Effect<void> {
    return this.removeLocal(ctx, id)
  }
}

/** App-wide singleton used by ChatsList. */
export const sessionEngineDb = new SessionEngineDb()
