/** The board's load path: URL sorts + per-column pagination plan + the parallel per-column fetch.
 * Extracted from KanbanView.vue so the component keeps only the guard around it. */
import { nextTick } from 'vue'
import type { Ref } from 'vue'
import type { RouteLocationNormalizedLoaded } from 'vue-router'
import type { useWorkspacesStore } from '../../stores/workspaces'
import { parseSortsParam } from './kanbanBoardUrl'
import type { KanbanLayout, SortEntry } from './kanbanViewTypes'

export interface LoadBoardArgs {
  store: ReturnType<typeof useWorkspacesStore>
  wsId: string
  itemId: string
  route: RouteLocationNormalizedLoaded | undefined
  urlLayout: KanbanLayout | null
  layout: Ref<KanbanLayout>
  columnSorts: Ref<Record<string, SortEntry>>
  columnRefs: Ref<Record<string, unknown>>
  writeSortsToUrl: () => void
}

export const loadBoardData = async ({
  store,
  wsId,
  itemId,
  route: routeObj,
  urlLayout,
  layout,
  columnSorts,
  columnRefs,
  writeSortsToUrl,
}: LoadBoardArgs): Promise<void> => {
  const sortsRaw = routeObj ? (routeObj.query?.sorts as string | undefined) : undefined
  const urlEntries = sortsRaw ? parseSortsParam(sortsRaw) : []
  const nonDefaultUrlEntries = urlEntries.filter(
    (e) => !(e.sortBy === 'position' && e.direction === 'asc'),
  )

  // Step 1b: mirror the URL's `?layout=` into the local ref so a deep link wins over the stored
  // preference. The ref is initialised from the URL at setup time, but this re-runs on item
  // navigation, where the query carries over to a different board.
  if (urlLayout && urlLayout !== layout.value) layout.value = urlLayout

  // Step 2: mirror URL sorts into columnSorts (drives the watcher's URL write — no-op since the URL
  // already matches, no fetch). Also fires the column's local setSortMode on the next tick so the
  // UI's "active sort" highlight matches.
  if (urlEntries.length > 0) {
    const next: Record<string, SortEntry> = {}
    for (const entry of urlEntries) {
      next[entry.columnId] = entry
    }
    columnSorts.value = next
    // The old columnSorts watcher mirrored this assignment back to the
    // URL; call it explicitly (no-op — the URL already matches).
    writeSortsToUrl()
    void nextTick(() => {
      for (const entry of urlEntries) {
        const col = columnRefs.value[entry.columnId] as
          { setSortMode?: (s: string, d: string) => void } | null | undefined
        if (col && typeof col.setSortMode === 'function') {
          col.setSortMode(entry.sortBy, entry.direction)
        }
      }
    })
  }

  // Step 3: load columns (always — even if the URL has only
  // default entries, we still need the column list to render
  // the board).
  await store.fetchKanbanColumns(wsId, itemId)

  // Step 4: figure out the fetch plan.
  const item = store.workspaces
    .find((ws) => ws.id === wsId)
    ?.items.find((it) => it.id === itemId)
  if (!item) return
  const cp = item.columnPagination ?? {}
  const needFetch = (item.kanban_columns ?? []).filter((col) => !cp[col.id])

  let fetchPlan: Array<{
    columnId: string
    sortBy?: 'created_at' | 'updated_at' | 'name'
    direction?: 'asc' | 'desc'
  }>

  // Build a set of columns mentioned in the URL (default or non-default). Used by the "fetch other
  // columns with default sort" path to skip columns that already have an explicit URL entry (their
  // fetch carries the URL sort instead).
  const urlEntryColumnIds = new Set(urlEntries.map((e) => e.columnId))

  if (nonDefaultUrlEntries.length > 0) {
    // URL has non-default sort entries (e.g. ?sorts=col_a:name:asc). 1. Fetch the URL-mentioned
    // columns with their URL sort. 2.
    const urlSortFetches = nonDefaultUrlEntries.map((e) => {
      const apiSortBy =
        e.sortBy === 'position' ? undefined : (e.sortBy as 'created_at' | 'updated_at' | 'name')
      return { columnId: e.columnId, sortBy: apiSortBy, direction: e.direction }
    })
    const defaultFetches = needFetch
      .filter((col) => !urlEntryColumnIds.has(col.id))
      .map((col) => ({ columnId: col.id }))
    fetchPlan = [...urlSortFetches, ...defaultFetches]
  } else if (needFetch.length === 0) {
    // No non-default URL entries AND no unpaginated columns → nothing to do. Single endpoint
    // (fetchKanbanColumns) is already fired above; no per-column fetch needed.
    return
  } else {
    // No non-default URL entries AND unpaginated columns exist → fetch all unpaginated columns with
    // default sort. This is the "first-time visit" path (no URL sort history) AND the "URL has only
    // default entries" path (those columns re-fetch with default sort on mount).
    fetchPlan = needFetch.map((col) => ({ columnId: col.id }))
  }

  // Step 5: fire per-column fetches in parallel.
  await Promise.all(
    fetchPlan.map((p) =>
      store.fetchKanbanTasks(
        wsId,
        itemId,
        p.columnId,
        10,
        undefined, // cursor — page 1
        undefined, // q — no search filter
        p.sortBy,
        p.direction,
      ),
    ),
  )
}
