// Pinia store for workspace-scoped documents (Migration 095). Two things this store deliberately
// does NOT do: 1. No client-side workspace filter.
import { defineStore } from 'pinia'
import { Effect } from 'effect'
import { computed, ref } from 'vue'
import * as api from '../api'
import type { Document } from '../api'
import { documentEngineDb } from '../sync/DocumentEngineDb'
import { SyncRemoteError } from '../sync/SyncError'
import { runSyncEffectOr, runSyncResult, runSyncVoid } from '../sync/runtime'

export function applyReorder(docs: Document[], orderedIds: string[]): Document[] {
  const remaining = new Map(docs.map((d) => [d.id, d]))
  const ordered: Document[] = []
  orderedIds.forEach((id, index) => {
    const doc = remaining.get(id)
    if (!doc) return
    remaining.delete(id)
    ordered.push({ ...doc, position: index })
  })
  return ordered.concat([...remaining.values()])
}

export const useDocumentsStore = defineStore('documents', () => {
  const documents = ref<Document[]>([])
  const loading = ref(false)
  const saving = ref(false)
  /** Last failure message, or null. Rendered by the view — never write-only. */
  const error = ref<string | null>(null)
  /**    * True once a list has been fetched for SOME workspace. Distinguishes "not loaded yet" (render
   * nothing) from "loaded, and there are none" (render the empty state) — without it a fresh
   * sidebar shows a misleading "No documents yet" before the first request returns. */
  const loaded = ref(false)

  const count = computed(() => documents.value.length)

  const findById = (id: string): Document | null => documents.value.find((d) => d.id === id) ?? null

  const toMessage = (e: unknown): string => (e instanceof Error ? e.message : String(e))

  /** Cache-first list load, then revalidate — the shape ChatsList uses for the sidebar's Recent
   * chats. The cache paint comes first and clears `loading`, so a returning user sees document
   * titles immediately instead of an empty section while the network answers. */
  async function fetchDocuments(workspaceId: string): Promise<void> {
    if (!workspaceId) return
    loading.value = true
    error.value = null
    try {
      // 1. Paint from cache. A cache failure is not the caller's problem —
      //    `runSyncEffectOr` reports it in dev and degrades to no rows, so a
      //    broken IndexedDB just means "no instant paint", never a hard stop.
      const cached = await runSyncEffectOr(
        documentEngineDb.primeFromCache(workspaceId, Number.MAX_SAFE_INTEGER),
        [],
        'documents.primeFromCache',
      )
      if (cached.length > 0) {
        documents.value = cached.map((r) => r.raw)
        loaded.value = true
        loading.value = false
      }

      // 2. Revalidate in the background and replace with the server's truth. `runSyncResult` (not
      // `runSyncEffect`) because this failure is RENDERED: the section shows `error` instead of the
      // empty state, so the reason has to survive to the UI.
      const result = await runSyncResult(
        documentEngineDb.loadDelta(workspaceId),
        'documents.loadDelta',
      )
      if (result.ok) {
        documents.value = result.value.items.map((r) => r.raw)
        loaded.value = true
      } else {
        error.value = result.reason
        if (cached.length === 0) {
          // Cold miss AND a revalidation that never arrived: there is nothing painted to protect,
          // so the list stays empty and the error block carries the reason. A populated list is
          // NEVER blanked here — the cached rows stay on screen above it.
          documents.value = []
        }
      }
    } finally {
      loading.value = false
    }
  }

  async function createDocument(
    workspaceId: string,
    title: string,
    content = '',
  ): Promise<Document | null> {
    if (!workspaceId) return null
    saving.value = true
    error.value = null
    try {
      const { document } = await api.createDocument(workspaceId, title, content)
      // Prepend rather than refetch: the backend positions a new document above
      // every existing one, so the prepend IS the saved order.
      documents.value = [document, ...documents.value]
      loaded.value = true
      // Write through so the next cold boot paints this document without
      // waiting for the revalidation. Best-effort: `putLocal` cannot fail
      // the caller, and the in-memory list above is already correct.
      await runSyncVoid(documentEngineDb.putDocument(workspaceId, document), 'documents.put')
      return document
    } catch (e) {
      error.value = toMessage(e)
      return null
    } finally {
      saving.value = false
    }
  }

  async function updateDocument(
    workspaceId: string,
    documentId: string,
    patch: { title?: string; content?: string },
  ): Promise<Document | null> {
    if (!workspaceId) return null
    saving.value = true
    error.value = null
    try {
      const { document } = await api.updateDocument(workspaceId, documentId, patch)
      documents.value = documents.value.map((d) => (d.id === document.id ? document : d))
      // Write through the edited row. Matters more here than for sessions:
      // the cached row carries the BODY, so without this an offline reload
      // would show the pre-edit document under the post-edit title.
      await runSyncVoid(documentEngineDb.putDocument(workspaceId, document), 'documents.put')
      return document
    } catch (e) {
      error.value = toMessage(e)
      return null
    } finally {
      saving.value = false
    }
  }

  async function deleteDocument(workspaceId: string, documentId: string): Promise<boolean> {
    if (!workspaceId) return false
    saving.value = true
    error.value = null
    try {
      await api.deleteDocument(workspaceId, documentId)
      documents.value = documents.value.filter((d) => d.id !== documentId)
      // Evict from the cache too. Without this the deleted row survives in
      // IndexedDB and the next cold boot paints a document that no longer
      // exists — and clicking it would open a 404.
      await runSyncVoid(
        documentEngineDb.removeDocument(workspaceId, documentId),
        'documents.remove',
      )
      return true
    } catch (e) {
      error.value = toMessage(e)
      return false
    } finally {
      saving.value = false
    }
  }

  async function reorderDocuments(workspaceId: string, orderedIds: string[]): Promise<boolean> {
    if (!workspaceId || orderedIds.length === 0) return false
    const previous = documents.value
    documents.value = applyReorder(previous, orderedIds)
    saving.value = true
    error.value = null
    try {
      const result = await runSyncResult(
        Effect.tryPromise({
          try: () => api.reorderDocuments(workspaceId, orderedIds),
          catch: (cause) =>
            new SyncRemoteError({
              op: 'documents.reorder',
              reason: cause instanceof Error ? cause.message : String(cause),
            }),
        }),
        'documents.reorder',
      )
      if (!result.ok) {
        documents.value = previous
        error.value = result.reason
        return false
      }
      documents.value = result.value.documents
      loaded.value = true
      for (const doc of result.value.documents) {
        await runSyncVoid(documentEngineDb.putDocument(workspaceId, doc), 'documents.put')
      }
      return true
    } finally {
      saving.value = false
    }
  }

  /**    * Fetch a single document for the editor. The list response already carries every body, so this
   * is a no-op when the row is cached and only reaches the network for a deep link opened before
   * the sidebar list loaded. */
  async function loadDocument(workspaceId: string, documentId: string): Promise<Document | null> {
    if (!workspaceId || !documentId) return null
    error.value = null
    const cached = findById(documentId)
    if (cached) return cached
    try {
      const { document } = await api.getDocument(workspaceId, documentId)
      return document
    } catch (e) {
      error.value = toMessage(e)
      return null
    }
  }

  /** Called on workspace switch so a stale list is never shown under a new header. */
  function reset(): void {
    documents.value = []
    error.value = null
    loaded.value = false
    loading.value = false
    saving.value = false
  }

  return {
    documents,
    loading,
    saving,
    error,
    loaded,
    count,
    findById,
    fetchDocuments,
    createDocument,
    updateDocument,
    deleteDocument,
    reorderDocuments,
    loadDocument,
    reset,
  }
})
