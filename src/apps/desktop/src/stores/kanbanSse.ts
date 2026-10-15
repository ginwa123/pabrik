/**
 * KanbanSse — bus-backed kanban event handlers (Chunk 10 of the
 * unify-frontend-sse plan).
 *
 * Before this migration, the store opened its OWN EventSource via
 * `createUnifiedSseConnection` for the `kanban` channel — the 5th
 * duplicate subscription to a stream the bus (opened by App.vue at
 * app start via `installSseBus`) already subscribes to. That setup
 * opened an EventSource per Pinia store activation (and a 2nd one
 * for every `initKanbanSse` re-entry), saturating the browser's
 * per-origin HTTP/1.1 connection pool and triggering the chained
 * `ERR_INCOMPLETE_CHUNKED_ENCODING` reconnect loop.
 *
 * After: the store subscribes via `useSseBus().on('kanban', ...)`
 * (one listener per Pinia store activation, lifetime ≈ page
 * lifetime). The bus's singleton EventSource owns the actual network
 * stream and re-emits events to all subscribers with built-in
 * reconnect-on-drop.
 *
 * The async `initKanbanSse` signature is preserved (callers in
 * AppLayout's `initSseStores` `await` it) even though the body is
 * synchronous, because the cooperative-init semantic contract with
 * the AppLayout caller is part of the public API.
 *
 * The backend's kanban SSE routing keys (`kanban_column`,
 * `kanban_task`) are GLOBAL — every connected client receives every
 * event. The handler filters client-side by `event.workspace_id ==
 * activeWorkspaceId` before dispatching to workspacesStore. Workspace
 * switches update the filter via `setActiveWorkspaceId` (no
 * re-subscription — the bus listener is workspace-agnostic).
 *
 * Plan: docs/superpowers/plans/2026-06-30-unify-frontend-sse.md
 *   Chunk 10.
 */
import { defineStore } from 'pinia'
import { ref } from 'vue'
import { useSseBus, __getSseBusGlobalClient } from '../helpers/sseBus'
import type { KanbanColumnEvent, KanbanTaskEvent } from '../api'
import { useWorkspacesStore, isRecentLocalMutation } from './workspaces'

export const useKanbanSseStore = defineStore('kanbanSse', () => {
  // Mutable ref so `setActiveWorkspaceId` can update the filter
  // without re-subscribing. The `bus.on('kanban', ...)` closure
  // captured at install time reads `activeWorkspaceId.value` on
  // EVERY event, so flipping it takes effect immediately for
  // incoming events (no need to detach + re-attach the listener).
  const activeWorkspaceId = ref<string>('')

  // The unsubscribe function for the bus listener. Stashed so
  // `closeKanbanSse()` can detach the handler on unmount. Null
  // before `initKanbanSse` runs and after `closeKanbanSse` runs.
  let offKanban: (() => void) | null = null

  // Unsubscribe for the bus's "you may have missed events" signal (see
  // `helpers/sseTabChannel.ts`). The `bus.state` subscription below covers
  // transitions the SseClient itself emits; this covers the two cases where the
  // state never changes but deliveries were still lost: taking over the shared
  // connection from another tab, and returning from a long hidden period.
  let offResync: (() => void) | null = null

  // Disposer for the `bus.state → fetchInitialKanban` subscription.
  // See `initKanbanSse` below for why this is needed even though
  // we're no longer owning the EventSource.
  let stopOpenSub: (() => void) | null = null

  // Throttle for open-triggered refetches (see fetchInitialKanban).
  let lastKanbanFetchAt = 0

  /**
   * Subscribe the kanban store to the bus's `kanban` channel. The
   * function signature stays `async` + `Promise<void>` to preserve
   * the cooperative-init semantic contract with AppLayout's
   * `initSseStores(activeWorkspaceId)` awaiting
   * kanbanSseStore.initKanbanSse(newId) })`. The body is synchronous
   * (bus subscription is in-memory), but callers still `await` us
   * and that's part of the public API.
   *
   * Idempotent: a second call with the same workspaceId is a no-op
   * (the listener + filter are already in place). A call with a
   * different workspaceId updates the filter without re-subscribing.
   * The bus listener is GLOBAL — workspace-id filtering happens
   * inside the handler closure, so we don't detach/re-attach.
   *
   * Throws if the bus is not yet installed — call this AFTER App.vue's
   * `onMounted` has run. The bus is installed by App.vue's
   * `onMounted`, which runs after AppLayout.vue's mount in practice
   * (the AppLayout's `initSseStores` on workspace switch fires only
   * after both components have mounted, by which point the bus is
   * ready). The async signature preserves the cooperative-init
   * contract with that caller — even though the body is now
   * synchronous, callers still `await` us.
   */
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
      // Dispatch by event family. Column events refresh the column
      // list (renames, reorder, add, delete); task events refresh
      // the task list (move, assign, unassign). A full re-fetch (vs
      // in-place patch) is the simplest correct action — sibling
      // positions renumber as part of every move, and the SSE
      // payload doesn't include the new positions of every sibling,
      // so client-side patching would be brittle.
      //
      // The `'column_id' in event` / `'task_id' in event` check
      // narrows the discriminated union (`KanbanColumnEvent` has
      // `column_id`, `KanbanTaskEvent` has `task_id`, neither has
      // the other).
      if ('column_id' in event) {
        void ws.fetchKanbanColumns(event.workspace_id, event.item_id)
      } else if ('task_id' in event) {
        // `human_touched` (chatview-open api-spam fix, 2026-08-24):
        // fired by `PUT .../tasks/:id/touched` every time the user
        // opens a task's chat. The wire payload carries the full
        // after-state (`needs_human_review: false`, no column change)
        // so we patch the local task IN PLACE and return — NO
        // refetch. Pre-fix, this event fell through to the unassign
        // branch below (`new_column_id` is null on the wire) and
        // fired one `tasks?limit=100` per column — 7 calls / ~5 MB
        // on a 270-task board — just from opening a chatview.
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
        // Mirror the local task's column (and position) BEFORE the
        // refetch. Without this mirror, `fetchKanbanTasks`'s merge
        // logic — `otherTasks = filter(t => t.kanban_column_id !==
        // columnId)` — keeps the stale source-column copy AND adds
        // the fresh destination-column copy from the wire, producing
        // a visible duplicate in the user's UI until refresh.
        //
        // User-initiated moves don't hit this because
        // `moveTaskToColumn` mutates the local column id before the
        // SSE round-trip. Non-UI moves (agent's `kanban_move_task`
        // tool, edits from another tab) bypass `moveTaskToColumn`,
        // so we have to mirror here.
        ws.mirrorKanbanTaskMove(
          event.workspace_id,
          event.item_id,
          event.task_id,
          event.new_column_id ?? null,
          event.new_position ?? undefined,
        )
        // Self-echo dedupe (same pattern as designSse): the backend
        // fans `kanban_task` events to every client INCLUDING the
        // mover, so a drag-and-drop via `moveTaskToColumn` would
        // otherwise refetch the destination column
        // (tasks?limit=100) right after the PATCH — the extra
        // request in the Network panel. The local store already
        // holds the truth (moveTaskToColumn mutated + registered
        // this task id), so skip the refetch. Remote moves (agent
        // tool, other tab) never register and still refetch below.
        if (isRecentLocalMutation(event.task_id)) return
        // Kanban task search (Chunk 7): forward the active q so a remote move/edit during a search
        // doesn't reset the user's narrowed view to the unfiltered list. activeSearchQueries is a
        // Map<itemId, string>; undefined when no search active.
        const q = ws.activeSearchQueries.get(event.item_id)
        // Kanban sort-by (Chunk 3): forward the active sort so a
        // remote move during a non-default sort re-fetches in the
        // SAME order the user is looking at. Without this, the
        // just-received event lands in the wrong visual position
        // (the api's 'updated_at' / 'desc' default would silently
        // override the user's pick). activeSortBy +
        // activeSortDirection are Map<itemId, ...> populated by
        // fetchKanbanTasks; both are undefined when no user sort
        // is active (init path).
        const sortBy = ws.activeSortBy.get(event.item_id)
        const direction = ws.activeSortDirection.get(event.item_id)

        // Per-column SSE refetch (Option B, 2026-08-06): refetch
        // JUST the affected column, not the whole board. The event
        // carries `new_column_id` (the destination column for move /
        // assign; null for unassign). For unassign, we still need
        // to refresh the source column (where the task was) — but
        // since the SSE payload doesn't carry the source column id,
        // we conservatively iterate all columns. This is the rare
        // edge case (unassign is manual via the UI), so the cost
        // is acceptable.
        //
        // Single-row fast path (not a blind limit=100 column fetch):
        // the mirror above already applied the event's column,
        // position AND in-array slot, so one GET for the moved row
        // is enough to converge with server truth. A cursor/delta
        // fetch on latest local updated_at cannot replace this —
        // moveTask writes ONLY the kanban join table (column +
        // position renumbering) and never bumps updated_at, so an
        // updated_at-delta would return empty for exactly this
        // event. The full column fetch remains the fallback when
        // the task isn't cached (event beat the initial load — the
        // fresh page materializes the missing row), while searching
        // (the mirror bypasses the backend q filter), or under a
        // custom sort (array order no longer matches the view).
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

    // Re-sync the kanban state from the DB on every (re)connect of
    // the bus's underlying global SseClient. The server may have
    // restarted and lost in-memory state (just like the workers SSE
    // pattern in App.vue:44-58, `fetchInitialWorkers`). The bus's
    // state transitions to 'open' on first connect AND on every
    // successful reconnect from 'reconnecting'.
    //
    // `{ immediate: true }` covers the fast path where the bus is
    // already 'open' by the time we get here (the SseClient defers
    // its first `start()` via `setTimeout(0)`, so App.vue's
    // `installSseBus` may have already opened the stream before
    // AppLayout.vue mounted).
    // Explicit `onStateChange` subscription on the underlying SseClient
    // (not a reactive watcher). The immediate check covers the fast
    // path where the bus is already open when init runs.
    if (bus.state.value === 'open') void fetchInitialKanban(activeWorkspaceId.value)
    stopOpenSub =
      __getSseBusGlobalClient()?.onStateChange((s) => {
        if (s === 'open') void fetchInitialKanban(activeWorkspaceId.value)
      }) ?? null

    // Stale-on-wake (cross-tab sharing): the subscription above only fires on state
    // transitions the SseClient itself emits. A window that TOOK OVER the shared
    // connection, or that returns from a long hidden period (browsers freeze and
    // throttle hidden tabs, so deliveries and rendering were skipped), may have
    // missed events with no state change at all. Re-fetch from the API — every
    // tab can do that directly, whoever holds the SSE connection.
    offResync =
      bus.onResync?.(() => {
        if (activeWorkspaceId.value !== '') void fetchInitialKanban(activeWorkspaceId.value)
      }) ?? null
  }

  /** Tear down the kanban-event handlers. Called on AppLayout unmount
   * (and at the end of each test). Mirrors the pre-migration
   * `closeKanbanSse` contract but for the bus listener instead of a
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

  /**
   * Update the workspace filter without re-subscribing the bus
   * listener. Called by AppLayout's `initSseStores` on workspace switch
   * when the user switches workspaces after the initial setup. A
   * workspace switch is just a filter change because the backend's
   * kanban routing keys are global (every connected client sees every
   * kanban event).
   *
   * Re-installs the bus handlers if they were torn down (e.g. by a
   * prior `closeKanbanSse` then a workspace re-mount). The async
   * signature matches `initKanbanSse` so AppLayout can `await` either
   * the same way.
   */
  async function setActiveWorkspaceId(workspaceId: string): Promise<void> {
    await initKanbanSse(workspaceId)
  }

  /**
   * Initial kanban-column sync on SSE (re)connect. Mirrors
   * `fetchInitialWorkers()` in App.vue — a server restart can lose
   * in-memory state, so the next open should re-fetch the active
   * kanban item's columns to make sure local state matches the DB.
   *
   * No-op if the active workspace item isn't a kanban (chat folders
   * don't have columns; the SSE events for other workspaces are
   * filtered out at the dispatch layer anyway).
   */
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
