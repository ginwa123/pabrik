/** Pinia store for design-mode undo/redo history. Holds per-page history stacks (Map<pageId, {past,
 * future}>). Persists to localStorage on every push (debounced 500 ms via the composable's
 * `useDebounceFn`). Cleared on page switch (Figma parity: redo stack lost when changing pages). */
/** The store is intentionally minimal — the `useDesignHistory` composable owns the business logic
 * (capture helpers, inverse/ forward application). */
/** The store is just the data layer. localStorage key format:
 * `design-history:v1:<workspaceId>:<itemId>:<pageId>` The `:v1:` segment is bumped on
 * schema-breaking changes; old buckets are silently discarded. */
import { defineStore } from 'pinia'
import { ref } from 'vue'
import type { DesignElement } from '../api'

// ─── Entry shape ──────────────────────────────────────────────────── Mirrors
// `useDesignHistory.HistoryEntry` (kept in sync — there is no shared types module yet because Pinia
// stores and composables resolve their own types lazily).

// When adding a new field, update both places.

export type EntryKind =
  | 'update'
  | 'delete'
  | 'create'
  | 'reorder'
  | 'group'
  | 'html_edit'

export interface HistoryEntry {
  id: string
  timestamp: number
  label: string
  pageId: string
  kind: EntryKind
  // For geometry/style/rename (single or multi-element):
  changes?: Array<{
    elementId: string
    before: Partial<DesignElement>
    after: Partial<DesignElement>
    htmlBody?: { before: string; after: string } | null
  }>
  // For delete (single or batch):
  deletedElements?: Array<{
    element: DesignElement
    htmlBody: string | null
  }>
  // For create:
  newElementId?: string
  // For group:
  groupOp?: {
    parentId: string
    childIds: string[]
    beforeParentExisted: boolean
  }
  // For reorder:
  reorderOp?: {
    beforeOrder: string[]
    afterOrder: string[]
  }
}

export interface HistoryStack {
  past: HistoryEntry[]
  future: HistoryEntry[]
}

export const HISTORY_CAP = 100
const SCHEMA_VERSION = 'v1'

export const useDesignHistoryStore = defineStore('designHistory', () => {
  // `stacksByPage` is keyed by `pageId`. Each value holds a past +
  // future stack scoped to that page. Per-item scoping (workspaceId
  // + itemId + pageId) is enforced by the localStorage key, not by
  // the in-memory map (the in-memory map is process-local; if a
  // user has multiple tabs open they each have their own map).
  const stacksByPage = ref<Record<string, HistoryStack>>({})

  function getStack(pageId: string): HistoryStack {
    let s = stacksByPage.value[pageId]
    if (!s) {
      s = { past: [], future: [] }
      stacksByPage.value[pageId] = s
    }
    return s
  }

  function push(pageId: string, entry: HistoryEntry): void {
    const s = getStack(pageId)
    s.past.push(entry)
    // Figma parity: any new push clears the redo stack.
    s.future.length = 0
    // Cap enforcement: evict the oldest entry when past.length > cap.
    while (s.past.length > HISTORY_CAP) {
      s.past.shift()
    }
  }

  function popPast(pageId: string): HistoryEntry | null {
    const s = getStack(pageId)
    return s.past.length > 0 ? (s.past.pop() ?? null) : null
  }

  function popFuture(pageId: string): HistoryEntry | null {
    const s = getStack(pageId)
    return s.future.length > 0 ? (s.future.pop() ?? null) : null
  }

  function clearPage(pageId: string): void {
    delete stacksByPage.value[pageId]
  }

  function clearAll(): void {
    stacksByPage.value = {}
  }

  // ─── localStorage helpers ────────────────────────────────────────
  // The composable owns the debounce. These are pure read/write
  // helpers keyed by `(workspaceId, itemId, pageId)`.

  function storageKey(workspaceId: string, itemId: string, pageId: string): string {
    return `design-history:${SCHEMA_VERSION}:${workspaceId}:${itemId}:${pageId}`
  }

  function loadFromStorage(
    workspaceId: string,
    itemId: string,
    pageId: string,
  ): HistoryStack | null {
    try {
      const raw = localStorage.getItem(storageKey(workspaceId, itemId, pageId))
      if (!raw) return null
      const parsed = JSON.parse(raw) as HistoryStack
      // Validate shape.
      if (
        !parsed ||
        !Array.isArray(parsed.past) ||
        !Array.isArray(parsed.future)
      ) {
        return null
      }
      return parsed
    } catch {
      // Schema mismatch or malformed JSON — discard silently.
      return null
    }
  }

  function saveToStorage(
    workspaceId: string,
    itemId: string,
    pageId: string,
    stack: HistoryStack,
  ): void {
    try {
      localStorage.setItem(
        storageKey(workspaceId, itemId, pageId),
        JSON.stringify(stack),
      )
    } catch {
      // localStorage quota exceeded or disabled — swallow silently.
    }
  }

  function loadAndApply(
    workspaceId: string,
    itemId: string,
    pageId: string,
  ): void {
    const stack = loadFromStorage(workspaceId, itemId, pageId)
    if (stack) {
      stacksByPage.value[pageId] = stack
    }
  }

  return {
    stacksByPage,
    getStack,
    push,
    popPast,
    popFuture,
    clearPage,
    clearAll,
    storageKey,
    loadFromStorage,
    saveToStorage,
    loadAndApply,
  }
})
