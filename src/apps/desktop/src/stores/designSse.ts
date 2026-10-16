/** DesignSse — bus-backed design-event handlers (Chunk 6 of the design-mode-redesign plan). Mirrors
 * `kanbanSse.ts` byte-for-byte in structure. */
/** The bus is opened once by App.vue via `installSseBus`; this store just subscribes to the
 * `design` channel via `useSseBus().on('design', ...)` and dispatches incoming events to the
 * workspacesStore so the local Pinia state stays in sync with the backend. */
/** The backend's design SSE routing keys (`design_element_created`, `design_element_updated`,
 * `design_element_deleted`) are GLOBAL — every connected client receives every event. */
/** The bus listener filters client-side by `event.workspace_id == activeWorkspaceId` before
 * dispatching to the store. */
/** Workspace switches update the filter via `setActiveWorkspaceId` (no re-subscription — the bus
 * listener is workspace-agnostic). **Page-id tracking** — incoming events carry `event.page_id +
 * element_id`, so for a full re-fetch we need to know which page the user is currently editing. */
/** Chunk 7 (AppLayout v-else-if for design) will wire the active page id via the workspacesStore
 * (e.g. `activePageId` ref); the SSE handler in this store will then resolve the right page before
 * calling `fetchDesignElements`. */
/** Until Chunk 7 lands, the handler takes a conservative approach: re-fetch the elements for the
 * event's pageId directly (`fetchDesignElements(workspaceId, itemId, pageId)`), trusting the
 * workspaceStore's per-item `design_elements` cache. */
/** The fetched data is the FULL page record from the backend (the API returns `{ page, elements[]
 * }`); the store action overwrites the item's `design_elements` with the response. Plan:
 * docs/superpowers/plans/2026-07-08-design-mode-redesign.md Chunk 6. */
import { defineStore } from 'pinia'
import { ref } from 'vue'
import { useSseBus, __getSseBusGlobalClient } from '../helpers/sseBus'
import type { DesignElementEvent } from '../api'
import { useWorkspacesStore, isRecentLocalMutation } from './workspaces'
import { designLogger } from '../helpers/designLogger'

export const useDesignSseStore = defineStore('designSse', () => {
  // Mutable ref so `setActiveWorkspaceId` can update the filter without re-subscribing.
  const activeWorkspaceId = ref<string>('')

  // The unsubscribe function for the bus listener. Stashed so
  // `closeDesignSse()` can detach the handler on unmount. Null
  // before `initDesignSse` runs and after `closeDesignSse` runs.
  let offDesign: (() => void) | null = null

  // Unsubscribe for the bus's "you may have missed events" signal — see
  // `kanbanSse.ts` / `helpers/sseTabChannel.ts`.
  let offResync: (() => void) | null = null

  // Disposer for the `bus.state → fetchInitialDesign` subscription.
  // See `initDesignSse` below for why this is needed even though
  // we're no longer owning the EventSource.
  let stopOpenSub: (() => void) | null = null

  /** Subscribe the design store to the bus's `design` channel. The function signature stays `async`
   * + `Promise<void>` to preserve the cooperative-init semantic contract with AppLayout's
   * `initSseStores(activeWorkspaceId)` awaiting designSseStore.initDesignSse(newId) })` (Chunk
   * 8). */
  /** The body is synchronous (bus subscription is in-memory), but callers still `await` us and
   * that's part of the public API. Idempotent: a second call with the same workspaceId is a no-op
   * (the listener + filter are already in place). */
  /** A call with a different workspaceId updates the filter without re-subscribing. The bus
   * listener is GLOBAL — workspace-id filtering happens inside the handler closure, so we don't
   * detach/re-attach. */
  /** Throws if the bus is not yet installed — call this AFTER App.vue's `onMounted` has run. */
  /** The bus is installed by App.vue's `onMounted`, which runs after AppLayout.vue's mount in
   * practice (AppLayout's `initSseStores` on workspace switch fires only after both components have
   * mounted, by which point the bus is ready). */
  async function initDesignSse(workspaceId: string): Promise<void> {
    // Set the filter first — if we're called for the first time, the listener (registered below)
    // will read this value on its first event. If we're called for a re-init with a new
    // workspaceId, the existing listener sees the new value on its next event.
    activeWorkspaceId.value = workspaceId

    // Already subscribed — just refresh the filter and return.
    if (offDesign) return

    const bus = useSseBus()
    offDesign = bus.on('design', (event: DesignElementEvent) => {
      // Drop events for other workspaces — the backend fans out design events globally, so any
      // connected client receives them all. Skipping the no-op fetch keeps the local store's
      // re-fetch rate at 1 per actual mutation.
      if (event.workspace_id !== activeWorkspaceId.value) return
      // Chunk 3 (design-drag-debounce-batch): LOCAL-MUTATION DEDUPE. Every locally-issued geometry
      // PATCH (single or batch) registers the affected element_id(s) in the `recentLocalMutations`
      // Map (workspaces.ts) with a 1500 ms TTL.
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
      // Re-fetch the elements for the page named in the event. The server-side change might apply
      // to ANY active page (not just the one the user is currently viewing — another tab, another
      // browser, an LLM tool call from a chat session all trigger the same fan-out).
      void ws.fetchDesignElements(event.workspace_id, event.item_id, event.page_id)
      designLogger.info({
        reason: 'fetch:response',
        caller: 'designSse.handleDesignElementEvent',
        endpoint: '/design/pages/:page_id (GET)',
        workspaceId: event.workspace_id,
        itemId: event.item_id,
        pageId: event.page_id,
      })
      // Defensive: unknown event shapes are silently dropped. The backend's
      // on_event_sent_design.zig emits three shapes (`created` / `updated` / `deleted`) but they
      // share the same payload struct, so no per-action branching is needed.
    })

    // Re-sync the design state from the DB on every (re)connect of the bus's underlying global
    // SseClient. The server may have restarted and lost in-memory state (just like the kanban SSE
    // pattern in kanbanSse.ts:122-141).
    if (bus.state.value === 'open') void fetchInitialDesign(activeWorkspaceId.value)
    stopOpenSub = __getSseBusGlobalClient()?.onStateChange((s) => {
      if (s === 'open') void fetchInitialDesign(activeWorkspaceId.value)
    }) ?? null

    // Stale-on-wake (cross-tab sharing) — same reasoning as `kanbanSse.ts`: a
    // takeover or a return from a long hidden period can miss events without any
    // `bus.state` transition to hang a refresh off.
    offResync = bus.onResync?.(() => {
      if (activeWorkspaceId.value !== '') void fetchInitialDesign(activeWorkspaceId.value)
    }) ?? null
  }

  /**    * Tear down the design-event handlers. Called on AppLayout unmount (and at the end of each test).
   * Mirrors the pre-migration `closeKanbanSse` contract but for the bus listener instead of a
   * self-managed SseClient. */
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

  /** Update the workspace filter without re-subscribing the bus listener. Called by AppLayout's
   * `initSseStores` on workspace switch when the user switches workspaces after the initial setup. */
  /** A workspace switch is just a filter change because the backend's design routing keys are
   * global (every connected client sees every design event). Re-installs the bus handlers if they
   * were torn down (e.g. by a prior `closeDesignSse` then a workspace re-mount). */
  /** The async signature matches `initDesignSse` so AppLayout can `await` either the same way. */
  async function setActiveWorkspaceId(workspaceId: string): Promise<void> {
    await initDesignSse(workspaceId)
  }

  /** Initial design-element sync on SSE (re)connect. */
  async function fetchInitialDesign(workspaceId: string): Promise<void> {
    const ws = useWorkspacesStore()
    const item = ws.activeWorkspaceItem
    const parentWs = ws.activeWorkspace
    if (!item || item.item_type !== 'design') return
    // Only fetch if the active item actually belongs to the
    // workspace we just (re)connected for — otherwise we'd hit a
    // foreign item with stale state.
    if (!parentWs || parentWs.id !== workspaceId) return
    // No-op until Chunk 7 wires the active page id. When Chunk 7 lands, this will read
    // `activePageId` from the workspaces store (or a related design-mode ref) and call
    // `ws.fetchDesignElements(workspaceId, item.id, activePageId)`.
    void workspaceId
  }

  return {
    // Expose the active workspace id so tests + Chunk-7 diagnostics can read it. The filter update
    // in AppLayout's `initSseStores` will also benefit — for now it's only read by the SSE handler
    // closure.
    activeWorkspaceId,
    initDesignSse,
    closeDesignSse,
    setActiveWorkspaceId,
  }
})

/** Extract the list of element ids from a design SSE event. The single-element wire shape carries
 * `element_id`; the batch wire shape (Chunk 3 of design-drag-debounce-batch) carries `element_ids`. */
function extractElementIds(event: DesignElementEvent): string[] {
  const e = event as unknown as {
    element_id?: string
    element_ids?: string[]
  }
  if (Array.isArray(e.element_ids)) return e.element_ids
  if (typeof e.element_id === 'string' && e.element_id.length > 0) return [e.element_id]
  return []
}
