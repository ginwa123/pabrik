/** Task-list child of the generic sync engine.
 * The cache is local-only. Each context stores the complete first-page
 * response keyed by the same request shape used by the store. Revalidation
 * calls the existing task-list endpoint again; it does not send a new
 * backend cursor or introduce a backend delta-query contract. */
import { Effect } from 'effect'
import * as api from '../api'
import type { Task } from '../api'
import { BaseSyncEngine } from './SyncEngine'
import { SyncRemoteError, type SyncError } from './SyncError'
import type { SyncStoreShape } from './SyncStore'
import { makeIndexedDbSyncStore } from './IndexedDbStore'
import type { SyncDelta } from './SyncTypes'

export type TaskRawRow = Task

export interface TaskRow {
  id: string
  /** Wire `updated_at`; newer-first sorting compares this value. */
  sortKey: string
  /** Complete server object, so cached renders do not lose task fields. */
  raw: TaskRawRow
}

export interface TaskRequest {
  workspaceId: string
  itemId: string
  columnId?: string
  q?: string
  sortBy?: 'created_at' | 'updated_at' | 'name'
  direction?: 'asc' | 'desc'
}

export type TaskCtx = TaskRequest

export function taskSortKey(task: Task): string {
  const wire = task as unknown as { updated_at?: unknown; updatedAt?: unknown }
  if (typeof wire.updated_at === 'string') return wire.updated_at
  if (wire.updatedAt instanceof Date) return wire.updatedAt.toISOString()
  return ''
}

export function toTaskRow(task: Task): TaskRow {
  return {
    id: task.id,
    sortKey: taskSortKey(task),
    raw: task,
  }
}

export function taskContextKey(request: TaskRequest): string {
  return JSON.stringify([
    request.workspaceId,
    request.itemId,
    request.columnId ?? '',
    request.q ?? '',
    request.sortBy ?? '',
    request.direction ?? '',
  ])
}

export interface TaskDelta extends SyncDelta<TaskRow> {
  /** The backend's older-page metadata; it is never used as a sync cursor. */
  paginationCursor: string | null
}

export class TaskEngineDb extends BaseSyncEngine<TaskRow, TaskCtx> {
  constructor(
    // Read the API namespace at call time so Vitest spies on api.getTasks
    // remain effective, as they are for the session engine.
    private fetchFn: typeof api.getTasks = (...args) => api.getTasks(...args),
    storeName = 'tasks',
    store: SyncStoreShape = makeIndexedDbSyncStore(),
  ) {
    super(storeName, store)
  }

  protected memKey(ctx: TaskCtx): string {
    return taskContextKey(ctx)
  }

  compareFn(a: TaskRow, b: TaskRow): number {
    if (a.sortKey === b.sortKey) return a.id < b.id ? 1 : a.id > b.id ? -1 : 0
    return a.sortKey < b.sortKey ? 1 : -1
  }

  // BaseSyncEngine uses this only as an internal local bookkeeping value.
  // It is deliberately not sent to the backend.
  cursorOf(item: TaskRow): string | null {
    return item.sortKey || null
  }

  private fetchFirstPage(
    limit: number,
    ctx: TaskCtx,
  ): Effect.Effect<Awaited<ReturnType<typeof api.getTasks>>, SyncRemoteError> {
    // Preserve the pre-cache call shape exactly. In particular, the
    // default board-wide path still calls getTasks(workspaceId, itemId).
    return Effect.tryPromise({
      try: () =>
        ctx.columnId === undefined &&
        ctx.q === undefined &&
        ctx.sortBy === undefined &&
        ctx.direction === undefined
          ? this.fetchFn(ctx.workspaceId, ctx.itemId)
          : this.fetchFn(
              ctx.workspaceId,
              ctx.itemId,
              limit,
              undefined,
              ctx.sortBy,
              ctx.direction,
              ctx.columnId,
              ctx.q,
            ),
      catch: (e) =>
        new SyncRemoteError({
          op: 'tasks.fetchDelta',
          reason: e instanceof Error ? e.message : String(e),
        }),
    })
  }

  protected fetchDelta(
    _cursor: string | null,
    limit: number,
    ctx: TaskCtx,
  ): Effect.Effect<TaskDelta, SyncRemoteError> {
    return Effect.map(
      this.fetchFirstPage(limit, ctx),
      (data): TaskDelta => ({
        items: (data.tasks ?? []).map(toTaskRow),
        nextCursor: data.next_cursor ?? null,
        hasMore: data.has_more ?? false,
        cursorToSave: null,
        paginationCursor: data.next_cursor ?? null,
      }),
    )
  }

  /** Revalidate the same first page used to build this cache context and
   * write the returned rows through. Older-page pagination is handled by
   * the store and also writes through with putLocal. */
  loadDelta(ctx: TaskCtx, limit: number): Effect.Effect<TaskDelta, SyncError> {
    // A generator's `this` is its own, so capture the engine outside.
    // oxlint-disable-next-line typescript-eslint/no-this-alias -- see SyncEngine.syncOnMount
    const engine = this
    return Effect.gen(function* () {
      const delta = yield* engine.fetchDelta(null, limit, ctx)
      yield* engine.putLocal(ctx, delta.items)
      // A complete first page lists every row in this context, so cached
      // rows it omits were deleted or moved out — evict them so future
      // offline primes do not resurrect them.
      if (!delta.hasMore) yield* engine.reconcileCompletePage(ctx, delta.items)
      return delta
    })
  }

  private reconcileCompletePage(ctx: TaskCtx, fresh: TaskRow[]): Effect.Effect<void> {
    // A generator's `this` is its own, so capture the engine outside.
    // oxlint-disable-next-line typescript-eslint/no-this-alias -- see SyncEngine.syncOnMount
    const engine = this
    return Effect.gen(function* () {
      const freshIds = new Set(fresh.map((row) => row.id))
      const cached = yield* engine
        .primeFromCache(ctx, 10000)
        .pipe(Effect.catchAll(() => Effect.succeed<TaskRow[]>([])))
      for (const row of cached) {
        if (!freshIds.has(row.id)) yield* engine.removeLocal(ctx, row.id)
      }
    })
  }

  putTaskInContexts(requests: TaskCtx[], task: Task): Effect.Effect<void> {
    // A generator's `this` is its own, so capture the engine outside.
    // oxlint-disable-next-line typescript-eslint/no-this-alias -- see SyncEngine.syncOnMount
    const engine = this
    const row = toTaskRow(task)
    return Effect.forEach(requests, (request) => engine.putLocal(request, [row]), {
      discard: true,
    })
  }

  removeTask(ctx: TaskCtx, id: string): Effect.Effect<void> {
    return this.removeLocal(ctx, id)
  }
}

export const taskEngineDb = new TaskEngineDb()
