/** Pure domain types for the sync engine, kept separate from both the
 * service definition and the engine so `SyncStore` and `SyncEngine` can
 * depend on them without an import cycle. */
export interface Syncable {
  id: string
  /** Monotonic sort key used for older-page queries (e.g. created_at_nano). */
  sortKey: string | number
}

export interface SyncPage<T> {
  items: T[]
  nextCursor: string | null
  hasMore: boolean
}

export interface SyncDelta<T> extends SyncPage<T> {
  /** Cursor to persist after a successful delta (usually nextCursor). */
  cursorToSave: string | null
}
