/** DesignSse — bus-backed design-event handlers (Chunk 6 of the design-mode-redesign plan). */
import { defineStore } from 'pinia'
import { ref } from 'vue'
import { useSseBus, __getSseBusGlobalClient } from '../helpers/sseBus'
import type { DesignElementEvent } from '../api'
import { useWorkspacesStore, isRecentLocalMutation } from './workspaces'
import { designLogger } from '../helpers/designLogger'

export const useDesignSseStore = defineStore('designSse', () => {
  // Mutable ref so `setActiveWorkspaceId` can update the filter without re-subscribing.
  const activeWorkspaceId = ref<string>('')

  // The unsubscribe function for the bus listener.
  let offDesign: (() => void) | null = null

  // Unsubscribe for the bus's "you may have missed events" signal — see `kanbanSse.ts` / `helpers/sseTabChannel.ts`.
  let offResync: (() => void) | null = null

  // Disposer for the `bus.state → fetchInitialDesign` subscription.
  let stopOpenSub: (() => void) | null = null

  /** Subscribe the design store to the bus's `design` channel. */
  async function initDesignSse(workspaceId: string): Promise<void> {
    // Set the filter first — if we're called for the first time, the listener (registered below) will read this value on its first event.
    activeWorkspaceId.value = workspaceId

    // Already subscribed — just refresh the filter and return.
    if (offDesign) return

    const bus = useSseBus()
    offDesign = bus.on('design', (event: DesignElementEvent) => {
      // Drop events for other workspaces — the backend fans out design events globally, so any connected client receives them all.
      if (event.workspace_id !== activeWorkspaceId.value) return
      // Chunk 3 (design-drag-debounce-batch): LOCAL-MUTATION DEDUPE.
      const eventElementIds = extractElementIds(event)
      designLogger.info({
        reason: 'sse:received',
        caller: 'designSse.handleDesignElementEvent',
        sseEventType: event.action,
        sseEventIds: eventElementIds,
        workspaceId: event.workspace_id,
        itemId: event.item_id,
        pageId: event.page_id,
      })
      if (eventElementIds.length > 0) {
        const allLocal = eventElementIds.every((id) => isRecentLocalMutation(id))
        if (allLocal) {
          // Skip the GET — the local store already mirrors the truth.
          designLogger.info({
            reason: 'sse:dedupe-hit',
            caller: 'designSse.handleDesignElementEvent',
            sseEventType: event.action,
            sseEventIds: eventElementIds,
            sseDecision: 'skip',
            workspaceId: event.workspace_id,
            itemId: event.item_id,
            pageId: event.page_id,
          })
          return
        }
        designLogger.info({
          reason: 'sse:dedupe-miss',
          caller: 'designSse.handleDesignElementEvent',
          sseEventType: event.action,
          sseEventIds: eventElementIds,
          sseDecision: 'fetch',
          workspaceId: event.workspace_id,
          itemId: event.item_id,
          pageId: event.page_id,
        })
      }
      const ws = useWorkspacesStore()
      // Re-fetch the elements for the page named in the event.
      void ws.fetchDesignElements(event.workspace_id, event.item_id, event.page_id)
      designLogger.info({
        reason: 'fetch:response',
        caller: 'designSse.handleDesignElementEvent',
        endpoint: '/design/pages/:page_id (GET)',
        workspaceId: event.workspace_id,
        itemId: event.item_id,
        pageId: event.page_id,
      })
      // Defensive: unknown event shapes are silently dropped.
    })

    // Re-sync the design state from the DB on every (re)connect of the bus's underlying global SseClient.
    if (bus.state.value === 'open') void fetchInitialDesign(activeWorkspaceId.value)
    stopOpenSub = __getSseBusGlobalClient()?.onStateChange((s) => {
      if (s === 'open') void fetchInitialDesign(activeWorkspaceId.value)
    }) ?? null

    // Stale-on-wake (cross-tab sharing) — same reasoning as `kanbanSse.ts`: a takeover or a return from a long hidden period can miss events without any `bus.state` …
    offResync = bus.onResync?.(() => {
      if (activeWorkspaceId.value !== '') void fetchInitialDesign(activeWorkspaceId.value)
    }) ?? null
  }

  /** Tear down the design-event handlers. */
  function closeDesignSse(): void {
    if (offDesign) {
      offDesign()
      offDesign = null
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

  /** Update the workspace filter without re-subscribing the bus listener. */
  async function setActiveWorkspaceId(workspaceId: string): Promise<void> {
    await initDesignSse(workspaceId)
  }

  /** Initial design-element sync on SSE (re)connect. */
  async function fetchInitialDesign(workspaceId: string): Promise<void> {
    const ws = useWorkspacesStore()
    const item = ws.activeWorkspaceItem
    const parentWs = ws.activeWorkspace
    if (!item || item.item_type !== 'design') return
    // Only fetch if the active item actually belongs to the workspace we just (re)connected for — otherwise we'd hit a foreign item with stale state.
    if (!parentWs || parentWs.id !== workspaceId) return
    // No-op until Chunk 7 wires the active page id.
    void workspaceId
  }

  return {
    // Expose the active workspace id so tests + Chunk-7 diagnostics can read it.
    activeWorkspaceId,
    initDesignSse,
    closeDesignSse,
    setActiveWorkspaceId,
  }
})

/** Extract the list of element ids from a design SSE event. */
function extractElementIds(event: DesignElementEvent): string[] {
  const e = event as unknown as {
    element_id?: string
    element_ids?: string[]
  }
  if (Array.isArray(e.element_ids)) return e.element_ids
  if (typeof e.element_id === 'string' && e.element_id.length > 0) return [e.element_id]
  return []
}
