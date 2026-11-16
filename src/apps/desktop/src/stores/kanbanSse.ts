/** KanbanSse — bus-backed kanban event handlers (Chunk 10 of the unify-frontend-sse plan). */
import { defineStore } from 'pinia'
import { ref } from 'vue'
import { useSseBus, __getSseBusGlobalClient } from '../helpers/sseBus'
import type { KanbanColumnEvent, KanbanTaskEvent } from '../api'
import { useWorkspacesStore, isRecentLocalMutation } from './workspaces'

export const useKanbanSseStore = defineStore('kanbanSse', () => {
  // Mutable ref so `setActiveWorkspaceId` can update the filter without re-subscribing.
  const activeWorkspaceId = ref<string>('')

  // The unsubscribe function for the bus listener.
  let offKanban: (() => void) | null = null

  // Unsubscribe for the bus's "you may have missed events" signal (see `helpers/sseTabChannel.ts`).
  let offResync: (() => void) | null = null

  // Disposer for the `bus.state → fetchInitialKanban` subscription.
  let stopOpenSub: (() => void) | null = null

  // Throttle for open-triggered refetches (see fetchInitialKanban).
  let lastKanbanFetchAt = 0

  /** Subscribe the kanban store to the bus's `kanban` channel. */
  async function initKanbanSse(workspaceId: string): Promise<void> {
    // Set the filter first — if we're called for the first time, the listener (registered below) will read this value on its first event.
    activeWorkspaceId.value = workspaceId

    // Already subscribed — just refresh the filter and return.
    if (offKanban) return

    const bus = useSseBus()
    offKanban = bus.on('kanban', (event: KanbanColumnEvent | KanbanTaskEvent) => {
      // Drop events for other workspaces — the backend fans out kanban events globally, so any connected client receives them all.
      if (event.workspace_id !== activeWorkspaceId.value) return
      const ws = useWorkspacesStore()
      // Dispatch by event family.
      if ('column_id' in event) {
        void ws.fetchKanbanColumns(event.workspace_id, event.item_id)
      } else if ('task_id' in event) {
        // `human_touched` (chatview-open api-spam fix, 2026-08-24): fired by `PUT .../tasks/:id/touched` every time the user opens a task's chat.
        if (event.action === 'human_touched') {
          ws.applyHumanTouched(
            event.workspace_id,
            event.item_id,
            event.task_id,
            // Backend always sends the explicit after-state on this action (task_mark_human_touched.zig:91); default false for defensive parity with older emitters that omit …
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
        // Self-echo dedupe (same pattern as designSse): the backend fans `kanban_task` events to every client INCLUDING the mover, so a drag-and-drop via …
        if (isRecentLocalMutation(event.task_id)) return
        // Kanban task search (Chunk 7): forward the active q so a remote move/edit during a search doesn't reset the user's narrowed view to the unfiltered list. …
        const q = ws.activeSearchQueries.get(event.item_id)
        // Kanban sort-by (Chunk 3): forward the active sort so a remote move during a non-default sort re-fetches in the SAME order the user is looking at.
        const sortBy = ws.activeSortBy.get(event.item_id)
        const direction = ws.activeSortDirection.get(event.item_id)

        // Per-column SSE refetch (Option B, 2026-08-06): refetch JUST the affected column, not the whole board.
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
          // unassign — iterate all columns to catch the task removal + the (rare) reappearance in some other column.
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

    // Re-sync the kanban state from the DB on every (re)connect of the bus's underlying global SseClient.
    if (bus.state.value === 'open') void fetchInitialKanban(activeWorkspaceId.value)
    stopOpenSub =
      __getSseBusGlobalClient()?.onStateChange((s) => {
        if (s === 'open') void fetchInitialKanban(activeWorkspaceId.value)
      }) ?? null

    // Stale-on-wake (cross-tab sharing): the subscription above only fires on state transitions the SseClient itself emits.
    offResync =
      bus.onResync?.(() => {
        if (activeWorkspaceId.value !== '') void fetchInitialKanban(activeWorkspaceId.value)
      }) ?? null
  }

  /** Tear down the kanban-event handlers. */
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

  /** Update the workspace filter without re-subscribing the bus listener. */
  async function setActiveWorkspaceId(workspaceId: string): Promise<void> {
    await initKanbanSse(workspaceId)
  }

  /** Initial kanban-column sync on SSE (re)connect. */
  async function fetchInitialKanban(workspaceId: string): Promise<void> {
    // Throttled: bus.state flips to 'open' on every reconnect, and without a guard each reconnect would refetch columns (the columns/workers storm in the Network …
    if (Date.now() - lastKanbanFetchAt < 10_000) return
    lastKanbanFetchAt = Date.now()
    const ws = useWorkspacesStore()
    const item = ws.activeWorkspaceItem
    const parentWs = ws.activeWorkspace
    if (!item || item.item_type !== 'kanban') return
    // Only fetch columns if the active item actually belongs to the workspace we just (re)connected for — otherwise we'd hit a foreign item with stale state.
    if (!parentWs || parentWs.id !== workspaceId) return
    try {
      await ws.fetchKanbanColumns(workspaceId, item.id)
    } catch (err) {
      console.error('[kanbanSse] fetchInitialKanban failed:', err)
    }
  }

  return { initKanbanSse, closeKanbanSse, setActiveWorkspaceId }
})
