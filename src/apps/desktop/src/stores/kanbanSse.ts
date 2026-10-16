/** KanbanSse — bus-backed kanban event handlers (Chunk 10 of the unify-frontend-sse plan). */
import { defineStore } from 'pinia'
import { ref } from 'vue'
import { useSseBus, __getSseBusGlobalClient } from '../helpers/sseBus'
import type { KanbanColumnEvent, KanbanTaskEvent } from '../api'
import { useWorkspacesStore, isRecentLocalMutation } from './workspaces'

export const useKanbanSseStore = defineStore('kanbanSse', () => {
  // Mutable ref so `setActiveWorkspaceId` can update the filter without re-subscribing.
  const activeWorkspaceId = ref<string>('')

  // The unsubscribe function for the bus listener. Stashed so
  // `closeKanbanSse()` can detach the handler on unmount. Null
  // before `initKanbanSse` runs and after `closeKanbanSse` runs.
  let offKanban: (() => void) | null = null

  // Unsubscribe for the bus's "you may have missed events" signal (see `helpers/sseTabChannel.ts`).
  let offResync: (() => void) | null = null

  // Disposer for the `bus.state → fetchInitialKanban` subscription.
  // See `initKanbanSse` below for why this is needed even though
  // we're no longer owning the EventSource.
  let stopOpenSub: (() => void) | null = null

  // Throttle for open-triggered refetches (see fetchInitialKanban).
  let lastKanbanFetchAt = 0

  /** Subscribe the kanban store to the bus's `kanban` channel. The function signature stays `async`
   * + `Promise<void>` to preserve the cooperative-init semantic contract with AppLayout's
   * `initSseStores(activeWorkspaceId)` awaiting kanbanSseStore.initKanbanSse(newId) })`. */
  async function initKanbanSse(workspaceId: string): Promise<void> {
    // Set the filter first — if we're called for the first time, the listener (registered below)
    // will read this value on its first event. If we're called for a re-init with a new
    // workspaceId, the existing listener sees the new value on its next event.
    activeWorkspaceId.value = workspaceId

    // Already subscribed — just refresh the filter and return.
    if (offKanban) return

    const bus = useSseBus()
    offKanban = bus.on('kanban', (event: KanbanColumnEvent | KanbanTaskEvent) => {
      // Drop events for other workspaces — the backend fans out kanban events globally, so any
      // connected client receives them all. Skipping the no-op fetch keeps the local store's
      // re-fetch rate at 1 per actual mutation.
      if (event.workspace_id !== activeWorkspaceId.value) return
      const ws = useWorkspacesStore()
      // Dispatch by event family. Column events refresh the column list (renames, reorder, add,
      // delete); task events refresh the task list (move, assign, unassign).
      if ('column_id' in event) {
        void ws.fetchKanbanColumns(event.workspace_id, event.item_id)
      } else if ('task_id' in event) {
        // `human_touched` (chatview-open api-spam fix, 2026-08-24): fired by `PUT
        // .../tasks/:id/touched` every time the user opens a task's chat.
        if (event.action === 'human_touched') {
          ws.applyHumanTouched(
            event.workspace_id,
            event.item_id,
            event.task_id,
            // Backend always sends the explicit after-state on this
            // action (task_mark_human_touched.zig:91); default false
            // for defensive parity with older emitters that omit it.
            event.needs_human_review ?? false,
          )
          return
        }
        // Mirror the local task's column (and position) BEFORE the refetch.
        ws.mirrorKanbanTaskMove(
          event.workspace_id,
          event.item_id,
          event.task_id,
          event.new_column_id ?? null,
          event.new_position ?? undefined,
        )
        // Self-echo dedupe (same pattern as designSse): the backend fans `kanban_task` events to
        // every client INCLUDING the mover, so a drag-and-drop via `moveTaskToColumn` would
        // otherwise refetch the destination column (tasks?limit=100) right after the PATCH.
        if (isRecentLocalMutation(event.task_id)) return
        // Kanban task search (Chunk 7): forward the active q so a remote move/edit during a search
        // doesn't reset the user's narrowed view to the unfiltered list. activeSearchQueries is a
        // Map<itemId, string>; undefined when no search active.
        const q = ws.activeSearchQueries.get(event.item_id)
        // Kanban sort-by (Chunk 3): forward the active sort so a remote move during a non-default
        // sort re-fetches in the SAME order the user is looking at.
        const sortBy = ws.activeSortBy.get(event.item_id)
        const direction = ws.activeSortDirection.get(event.item_id)

        // Per-column SSE refetch (Option B, 2026-08-06): refetch JUST the affected column, not the
        // whole board. The event carries `new_column_id` (the destination column for move / assign;
        // null for unassign).
        const affectedColumnId = event.new_column_id
        if (affectedColumnId && affectedColumnId.length > 0) {
          const hasSearch = q !== undefined && q.length > 0
          const hasCustomSort = sortBy !== undefined && direction !== undefined
          const isCached =
            ws.findCachedTask(event.workspace_id, event.item_id, event.task_id) !== undefined
          if (!hasSearch && !hasCustomSort && isCached) {
            void ws.refreshTask(event.workspace_id, event.item_id, event.task_id)
          } else {
            void ws.fetchKanbanTasks(
              event.workspace_id,
              event.item_id,
              affectedColumnId,
              100, // limit — initial fetch size
              undefined,
              q,
              sortBy,
              direction,
            )
          }
        } else {
          // unassign — iterate all columns to catch the task
          // removal + the (rare) reappearance in some other column.
          void ws.fetchKanbanTasksForAllColumns(
            event.workspace_id,
            event.item_id,
            100,
            q,
            sortBy,
            direction,
          )
        }
      }
      // Defensive: unknown event shapes are silently dropped.
    })

    // Re-sync the kanban state from the DB on every (re)connect of the bus's underlying global
    // SseClient. The server may have restarted and lost in-memory state (just like the workers SSE
    // pattern in App.vue:44-58, `fetchInitialWorkers`).
    if (bus.state.value === 'open') void fetchInitialKanban(activeWorkspaceId.value)
    stopOpenSub =
      __getSseBusGlobalClient()?.onStateChange((s) => {
        if (s === 'open') void fetchInitialKanban(activeWorkspaceId.value)
      }) ?? null

    // Stale-on-wake (cross-tab sharing): the subscription above only fires on state transitions the
    // SseClient itself emits.
    offResync =
      bus.onResync?.(() => {
        if (activeWorkspaceId.value !== '') void fetchInitialKanban(activeWorkspaceId.value)
      }) ?? null
  }

  /**    * Tear down the kanban-event handlers. Called on AppLayout unmount (and at the end of each test).
   * Mirrors the pre-migration `closeKanbanSse` contract but for the bus listener instead of a
   * self-managed SseClient. */
  function closeKanbanSse(): void {
    if (offKanban) {
      offKanban()
      offKanban = null
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
  async function setActiveWorkspaceId(workspaceId: string): Promise<void> {
    await initKanbanSse(workspaceId)
  }

  /** Initial kanban-column sync on SSE (re)connect. Mirrors `fetchInitialWorkers()` in App.vue — a
   * server restart can lose in-memory state, so the next open should re-fetch the active kanban
   * item's columns to make sure local state matches the DB. */
  async function fetchInitialKanban(workspaceId: string): Promise<void> {
    // Throttled: bus.state flips to 'open' on every reconnect, and without a
    // guard each reconnect would refetch columns (the columns/workers storm in
    // the Network panel). Skips when the last fetch was <10s ago.
    if (Date.now() - lastKanbanFetchAt < 10_000) return
    lastKanbanFetchAt = Date.now()
    const ws = useWorkspacesStore()
    const item = ws.activeWorkspaceItem
    const parentWs = ws.activeWorkspace
    if (!item || item.item_type !== 'kanban') return
    // Only fetch columns if the active item actually belongs to the
    // workspace we just (re)connected for — otherwise we'd hit a
    // foreign item with stale state.
    if (!parentWs || parentWs.id !== workspaceId) return
    try {
      await ws.fetchKanbanColumns(workspaceId, item.id)
    } catch (err) {
      console.error('[kanbanSse] fetchInitialKanban failed:', err)
    }
  }

  return { initKanbanSse, closeKanbanSse, setActiveWorkspaceId }
})
