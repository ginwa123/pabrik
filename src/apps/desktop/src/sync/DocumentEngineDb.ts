/** Document-list child of the generic sync engine (sidebar local-first). Mirrors SessionEngineDb:
 * cache-then-revalidate over `api.listDocuments`, each row keeping the full server object in `raw`
 * so cached paints render through the store with no shape drift. */
/** The cache is partitioned by workspace (`ctx` = workspace id), matching the Documents section's
 * `workspaceId` prop boundary. Why IndexedDB and not localStorage: `Document.content` is the full
 * markdown body and `listDocuments` returns every body in the workspace. */
/** A workspaces-style localStorage cache (~100 bytes/row) would hit the ~5 MB quota after a handful
 * of real documents, and the cache helper is fail-silent by design — so it would degrade to a
 * silent permanent miss with no error to explain it. IndexedDB has no such ceiling. */
/** Cursor note: like sessions, there is no cursor. */
/** `listDocuments` is a single unpaginated call returning the whole workspace, so a delta is "the
 * whole list" — merge is a same-id replace, and rows the server no longer returns are dropped by
 * the store's full-page write rather than lingering as orphans (see `fetchDeltaPage`). */
import { Effect } from 'effect'
import * as api from '../api'
import type { Document } from '../api'
import { BaseSyncEngine } from './SyncEngine'
import { SyncRemoteError, type SyncError } from './SyncError'
import type { SyncStoreShape } from './SyncStore'
import { makeIndexedDbSyncStore } from './IndexedDbStore'
import type { SyncDelta } from './SyncTypes'

/** Full server row for one document (title, body, timestamps). */
export type DocumentRawRow = Document

export interface DocumentRow {
  id: string
  /** `updated_at` wall-clock string — matches the backend's updated_at DESC order. */
  sortKey: string
  /** Complete server object, so cached paints match the network shape. */
  raw: DocumentRawRow
}

/** Workspace partition key. A document belongs to exactly one workspace. */
export type DocumentCtx = string

export function documentSortKey(d: Document): string {
  return d.updated_at || ''
}

export function toDocumentRow(d: Document): DocumentRow {
  return {
    id: d.id,
    sortKey: documentSortKey(d),
    raw: d,
  }
}

export interface DocumentDelta extends SyncDelta<DocumentRow> {
  total: number
}

export class DocumentEngineDb extends BaseSyncEngine<DocumentRow, DocumentCtx> {
  constructor(
    // Namespace indirection (NOT a bare `listDocuments` import): the property is read at call time
    // so `vi.spyOn(api, 'listDocuments')` — the seam every Documents spec uses — intercepts engine
    // fetches too. Same reason as SessionEngineDb.
    private fetchFn: typeof api.listDocuments = (...args) => api.listDocuments(...args),
    storeName = 'documents',
    store: SyncStoreShape = makeIndexedDbSyncStore(),
  ) {
    super(storeName, store)
  }

  /** Newest-first: larger `updated_at` sorts earlier (ISO strings compare lexicographically). */
  compareFn(a: DocumentRow, b: DocumentRow): number {
    if (a.sortKey === b.sortKey) return 0
    return a.sortKey < b.sortKey ? 1 : -1
  }

  cursorOf(item: DocumentRow): string | null {
    return item.sortKey || null
  }

  protected fetchDelta(
    cursor: string | null,
    limit: number,
    ctx: DocumentCtx,
  ): Effect.Effect<SyncDelta<DocumentRow>, SyncRemoteError> {
    return this.fetchDeltaPage(ctx)
  }

  /**    * Full-list revalidate. `listDocuments` is unpaginated and returns the whole workspace, so
   * `limit` and the stored cursor are both irrelevant — accepted for the base-class contract and
   * ignored. */
  fetchDeltaPage(ctx: DocumentCtx): Effect.Effect<DocumentDelta, SyncRemoteError> {
    return Effect.tryPromise({
      try: () => this.fetchFn(ctx),
      catch: (e) =>
        new SyncRemoteError({
          op: 'documents.fetchDelta',
          reason: e instanceof Error ? e.message : String(e),
        }),
    }).pipe(
      Effect.map((data): DocumentDelta => {
        const items: DocumentRow[] = (data.documents ?? []).map(toDocumentRow)
        return {
          items,
          nextCursor: null,
          hasMore: false,
          // No cursor is persisted: the next revalidate is a full refetch.
          cursorToSave: null,
          total: data.count ?? items.length,
        }
      }),
    )
  }

  /** Background refresh for a cached paint: fetch the whole workspace, replace the cached rows for
   * this ctx, hand back the delta. */
  /** Honest about failure — a rejected fetch surfaces as `SyncRemoteError` rather than a null
   * result, so the store can tell "no documents" from "the list could not refresh" and keep the
   * painted rows in the latter case. */
  /** `clear(ctx)` before `putLocal` matters here in a way it does not for sessions: a document
   * deleted from another window (or by the agent's `delete_document` tool) would otherwise stay in
   * the cache forever, because a merge only ever adds or replaces by id. */
  loadDelta(ctx: DocumentCtx): Effect.Effect<DocumentDelta, SyncError> {
    // A generator's `this` is its own, so capture the engine outside.
    // oxlint-disable-next-line typescript-eslint/no-this-alias -- see SyncEngine.syncOnMount
    const engine = this
    return Effect.gen(function* () {
      const delta = yield* engine.fetchDeltaPage(ctx)
      yield* engine.clear(ctx)
      yield* engine.putLocal(ctx, delta.items)
      return delta
    })
  }

  /** Write-through for a single created/edited document. Never fails. */
  putDocument(ctx: DocumentCtx, doc: DocumentRawRow): Effect.Effect<void> {
    return this.putLocal(ctx, [toDocumentRow(doc)])
  }

  /** Evict one document (delete, or a workspace switch reset). Never fails. */
  removeDocument(ctx: DocumentCtx, id: string): Effect.Effect<void> {
    return this.removeLocal(ctx, id)
  }
}

/** App-wide singleton used by the documents store. */
export const documentEngineDb = new DocumentEngineDb()
