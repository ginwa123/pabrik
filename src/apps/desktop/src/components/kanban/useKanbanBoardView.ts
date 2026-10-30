/** The board's view state: the debounced search query and the per-column sort map that mirrors into
 * `?sorts=`. Extracted from KanbanView.vue; the component owns nothing but the calls. */
import { onUnmounted, ref } from 'vue'
import { buildBoardAppUrl, encodeSortsParam, flattenQuery } from './kanbanBoardUrl'
import { LAYOUT_PARAM, type KanbanBoardDeps, type KanbanLayout, type SortEntry } from './kanbanViewTypes'

export function useKanbanBoardView(
  deps: KanbanBoardDeps,
  persistLayout: (next: KanbanLayout) => void,
) {
  const { props, store, router, route, effectiveItemId, layout } = deps

  // ─── Search (kanban task search — Chunk 6) ──────────────────────────────── The search input is a
  // v-model'd ref. A 300ms trailing-edge debounce (hand-rolled — @vueuse/core is not installed in
  // this project) drives a refetch via store.fetchKanbanTasks(q).
const searchQuery = ref('')
let searchDebounceTimer: ReturnType<typeof setTimeout> | null = null

const clearSearchDebounce = () => {
  if (searchDebounceTimer !== null) {
    clearTimeout(searchDebounceTimer)
    searchDebounceTimer = null
  }
}

// Search input handler (replaces the old searchQuery watcher): every
// keystroke restarts the 300 ms debounce, then fires one request per
// column. Wired via `@update:model-value` on the search input below.
const onSearchInput = (newQ: string) => {
  searchQuery.value = newQ
  clearSearchDebounce()
  searchDebounceTimer = setTimeout(() => {
    searchDebounceTimer = null
    const trimmed = newQ.trim()
    // Per-column initial fetch (Option B): the search affects every
    // column, so we fire one request per column. fetchKanbanTasks
    // populates columnPagination per column with the new cursor.
    void store.fetchKanbanTasksForAllColumns(
      props.workspaceId,
      effectiveItemId.value,
      10, // limit (matches loadMoreTasks + the store's default)
      trimmed || undefined,
    )
  }, 300)
}

onUnmounted(clearSearchDebounce)

// (not just the latest one). Used by the URL mirror and by the
// fetch watcher.
const columnSorts = ref<Record<string, SortEntry>>({})

// Template refs to each KanbanColumn instance — needed so we can call the columns' setSortMode()
// (defineExpose seam) on URL restore. Map keyed by column.id, populated by the `ref="..."` callback
// in the template.
const columnRefs = ref<Record<string, unknown>>({})
const setColumnRef = (columnId: string) => (el: unknown) => {
  if (el) columnRefs.value[columnId] = el
}

// On mount: the URL restore (sorts parsing, columnSorts mirror, setSortMode) is handled INSIDE
// loadColumnsAndTasks above — see Step 1 + Step 2. No separate onMounted needed.
const writeSortsToUrl = () => {
  const encoded = encodeSortsParam(Object.values(columnSorts.value))
  // Preserve sibling params (`?detail=`, `?layout=`, …) — rebuilding the query from scratch here
  // used to silently drop them, so picking a column sort closed the detail panel and reset the
  // layout.
  const query = flattenQuery(route?.query as Record<string, unknown> | undefined)
  if (props.workspaceId) query.workspaceId = props.workspaceId
  if (effectiveItemId.value) query.itemId = effectiveItemId.value
  if (encoded) query.sorts = encoded
  else delete query.sorts
  if (layout.value === 'rows') query[LAYOUT_PARAM] = 'rows'
  else delete query[LAYOUT_PARAM]
  // Emit the CANONICAL path shape, not the legacy `/app?view=workspace` one.
  void router?.replace(buildBoardAppUrl(props.workspaceId, effectiveItemId.value, query))
}

// Handler for the column's sort-change emit. Updates the map (which mirrors the URL via
// writeSortsToUrl below) AND fires the fetch for ONLY the changed column — other columns' data is
// untouched (they keep their previously-fetched state, which still matches their own last sort).
const handleColumnSortChange = (
  columnId: string,
  payload: { sortBy: SortEntry['sortBy']; direction: SortEntry['direction'] },
) => {
  // 1. Update the columnSorts map + mirror the URL
  //    (`?sorts=col_X:...`) via writeSortsToUrl.
  columnSorts.value = {
    ...columnSorts.value,
    [columnId]: { columnId, sortBy: payload.sortBy, direction: payload.direction },
  }
  // Mirror to the URL (replaces the old columnSorts watcher arm).
  writeSortsToUrl()

  // 2. Fire the fetch for ONLY this column with its own sort. Other columns are untouched — their
  // local tasks still match their own last sort (the per-column fetch maintains each column's data
  // in its own sort order).
  if (payload.sortBy === 'position' && payload.direction === 'asc') {
    void store.fetchKanbanTasks(props.workspaceId, effectiveItemId.value, columnId, 10)
  } else {
    // The store's sortBy param excludes 'position' (no server
    // equivalent); narrow at the call site so the type checker
    // accepts the union.
    const apiSortBy =
      payload.sortBy === 'position'
        ? undefined
        : (payload.sortBy as 'created_at' | 'updated_at' | 'name')
    void store.fetchKanbanTasks(
      props.workspaceId,
      effectiveItemId.value,
      columnId,
      10,
      undefined, // cursor — reset to page 1 of the new sort
      undefined, // q — no search filter
      apiSortBy,
      payload.direction,
    )
  }
}

const setLayout = (next: KanbanLayout) => {
  if (layout.value === next) return
  layout.value = next
  persistLayout(next)
  // Router absent in unit tests is not an error: `router?.` is total, so local state still wins.
  const query = flattenQuery(route?.query as Record<string, unknown> | undefined)
  // `sorts` is written from the reactive ref, not read back off the (possibly stale)
  // `route.query` snapshot — the sorts watcher can fire in the same tick as this switch, and a
  // stale read would clobber it. Mirrors the protection the sorts watcher applies to `layout`.
  const encoded = encodeSortsParam(Object.values(columnSorts.value))
  if (encoded) query.sorts = encoded
  else delete query.sorts
  if (next === 'columns') delete query[LAYOUT_PARAM]
  else query[LAYOUT_PARAM] = next
  void router?.replace(buildBoardAppUrl(props.workspaceId, effectiveItemId.value, query))
}

  return {
    searchQuery,
    setLayout,
    onSearchInput,
    columnSorts,
    columnRefs,
    setColumnRef,
    writeSortsToUrl,
    handleColumnSortChange,
  }
}
