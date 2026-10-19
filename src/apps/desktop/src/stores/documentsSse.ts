/** DocumentsSse — bus-backed document-event handlers. The backend emits these from the AGENT TOOLS
 * only (`add_document` / `edit_document` / `delete_document`, see
 * `src/agentic_loop/document_events.zig`), so a tab never receives an echo of its own UI edit. */
import { defineStore } from 'pinia'
import { ref } from 'vue'
import { useSseBus, __getSseBusGlobalClient } from '../helpers/sseBus'
import type { DocumentEvent } from '../api'
import { useDocumentsStore } from './documents'

export const useDocumentsSseStore = defineStore('documentsSse', () => {
  // Mutable ref so `setActiveWorkspaceId` can update the filter without re-subscribing.
  const activeWorkspaceId = ref<string>('')

  // The unsubscribe function for the bus listener. Stashed so `closeDocumentsSse()`
  // can detach the handler on unmount.
  let offDocuments: (() => void) | null = null

  // Unsubscribe for the bus's "you may have missed events" signal (see `helpers/sseTabChannel.ts`).
  let offResync: (() => void) | null = null

  // Disposer for the `bus.state → refreshDocuments` subscription.
  let stopOpenSub: (() => void) | null = null

  let lastDocumentsFetchAt = 0

  /** Subscribe the documents store to the bus's `documents` channel. */
  async function initDocumentsSse(workspaceId: string): Promise<void> {
    // Set the filter first: a fresh listener reads it on its first event, and a re-init
    // just moves the filter for the listener that is already registered.
    activeWorkspaceId.value = workspaceId

    if (offDocuments) return

    const bus = useSseBus()
    offDocuments = bus.on('documents', (event: DocumentEvent) => {
      // Drop events for other workspaces — the backend fans document events out globally, so any
      // connected client receives them all. Without this every tab re-reads its document list when
      // ANY workspace's agent writes one.
      if (event.workspace_id !== activeWorkspaceId.value) return
      // The payload carries no body, and a delete has to make a row disappear, so re-read the
      // list. `fetchDocuments` revalidates the WHOLE workspace, so create / update / delete all
      // land — a per-action branch would need three different partial-update paths for no gain.
      void useDocumentsStore().fetchDocuments(event.workspace_id)
    })

    // Re-sync on every (re)connect of the bus's underlying global SseClient: a mutation that
    // landed while the stream was down was announced to nobody.
    if (bus.state.value === 'open') refreshDocuments(activeWorkspaceId.value)
    stopOpenSub =
      __getSseBusGlobalClient()?.onStateChange((s) => {
        if (s === 'open') refreshDocuments(activeWorkspaceId.value)
      }) ?? null

    // Stale-on-wake (cross-tab sharing): `bus.state` only fires on transitions the SseClient
    // itself emits, so a takeover can miss events with no transition to hang a refresh off.
    offResync =
      bus.onResync?.(() => {
        if (activeWorkspaceId.value !== '') refreshDocuments(activeWorkspaceId.value)
      }) ?? null
  }

  /** Tear down the document-event handlers. Called on AppLayout unmount (and at the end of
   * each test). */
  function closeDocumentsSse(): void {
    if (offDocuments) {
      offDocuments()
      offDocuments = null
    }
    if (offResync) {
      offResync()
      offResync = null
    }
    if (stopOpenSub) {
      stopOpenSub()
      stopOpenSub = null
    }
    activeWorkspaceId.value = ''
  }

  /** Update the workspace filter without re-subscribing the bus listener. Called by AppLayout's
   * `initSseStores` on workspace switch after the initial setup. */
  async function setActiveWorkspaceId(workspaceId: string): Promise<void> {
    await initDocumentsSse(workspaceId)
  }

  /** Re-read the active workspace's documents after a (re)connect. Throttled: `bus.state` flips
   * to 'open' on every reconnect, and without a guard each one would refetch the whole list. */
  function refreshDocuments(workspaceId: string): void {
    if (Date.now() - lastDocumentsFetchAt < 10_000) return
    lastDocumentsFetchAt = Date.now()
    if (workspaceId === '') return
    // `fetchDocuments` reports failures through its own `error` ref; it does not reject.
    void useDocumentsStore().fetchDocuments(workspaceId)
  }

  return { initDocumentsSse, closeDocumentsSse, setActiveWorkspaceId }
})
