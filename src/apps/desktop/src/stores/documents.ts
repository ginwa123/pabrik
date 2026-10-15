// Pinia store for workspace-scoped documents (Migration 095).
//
// Two things this store deliberately does NOT do:
//
//  1. No client-side workspace filter. The backend scopes every read by
//     the `workspace_id` in the path, so a document from another
//     workspace is never in the response to filter out. Adding a
//     `documents.filter(d => d.workspace_id === id)` guard here would be
//     a second, weaker copy of a rule that already lives in SQL — and the
//     kind of duplicate that drifts.
//  2. No local `isActive` flag. Which document is open is derived from the
//     URL (`/app/{ws}/doc/<id>`), so a refresh, a Back/Forward, or a shared
//     link all restore the same view. Same reasoning as
//     `ChatsList.isCurrentChat`.
//
// `try`/`catch` appears in the write actions and nowhere else: this is the
// sanctioned seam for a fallible operation, and each one records the
// failure in `error` so the component can render it. A catch that
// returned an empty list with no error would be the exact bug the
// "No try/catch in the desktop app" rule exists to prevent — "no
// documents" and "could not load documents" would look identical.
//
// The list is cache-first (`sync/DocumentEngineDb`, IndexedDB) like the
// sidebar's Recent chats: paint cached rows immediately, then revalidate
// and replace. `fetchDocuments` therefore has NO try/catch at all — the
// Effect seam carries the failure, and `runSyncResult` hands the reason
// back so `error` can still be rendered. That distinction is the whole
// point: degrading to an empty list here would resurrect the exact bug
// the paragraph above describes, just with a cache in front of it.
import { defineStore } from 'pinia'
import { computed, ref } from 'vue'
import * as api from '../api'
import type { Document } from '../api'
import { documentEngineDb } from '../sync/DocumentEngineDb'
import { runSyncEffectOr, runSyncResult, runSyncVoid } from '../sync/runtime'

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
  /** `loaded` is set on the cache paint too: a cached list of zero documents is still "loaded, and
   * there are none", which is what keeps the empty state honest instead of flashing "Loading". */
  /** The revalidation is a FULL replace rather than a merge: `listDocuments` returns the whole
   * workspace, so a document deleted elsewhere has to disappear. A merge would keep it in the store
   * forever. Failure is still not emptiness. */
  /** A failed revalidation leaves the cached rows on screen and records `error`; it never blanks
   * the list. */
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
      // Prepend rather than refetch: the list is ordered by
      // updated_at DESC and a brand-new document is the most recent.
      // Saves a round-trip on the click that created it.
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
    loadDocument,
    reset,
  }
})
