/**
 * Lazy-load + paginated tag suggestions for a kanban.
 *
 * Plan: docs/superpowers/plans/2026-07-30-kanban-task-tags-autocomplete.md
 *
 * Lifecycle:
 *   - `ensureLoaded()` — fetches the first page if not yet loaded.
 *   - `loadNextPage()` — fetches the next page (appends to internal list).
 *   - `reset()` — clears the internal list (used when the dialog closes).
 *
 * The fetched list is exposed as readonly `tags`. `hasMore` and
 * `loading` are exposed for UI to render a "Loading more..." indicator.
 *
 * The composable does NOT trigger fetches automatically — the caller
 * (KanbanTagsInput) is responsible for calling `ensureLoaded()` on
 * focus and `loadNextPage()` from an IntersectionObserver on the
 * scroll sentinel. This keeps the composable testable and the
 * "when to fetch" logic in the component.
 *
 * Args are REACTIVE: callers can pass plain strings, Vue refs, or
 * getter functions. The composable reads the live value via `toValue`
 * on every fetch (NOT wrapped in a cached computed), so that when
 * the dialog's `column` prop becomes available the next
 * `ensureLoaded()` picks up the new id and fetches properly.
 *
 * Why not wrap in `computed`? A `computed` would CACHE the first
 * resolved value. For a plain-string arg, that's fine (the value
 * never changes). For a ref arg, the computed would re-run when the
 * ref's `.value` changes (because `toValue` accesses `.value` which
 * subscribes). But for a raw closure that reads a let-variable, the
 * closure itself doesn't notify Vue's reactivity — the computed
 * stays cached at the stale value. Reading `toValue` directly on each
 * fetch sidesteps the cache altogether.
 *
 * Graceful degradation: if either `workspaceId` or `itemId` is empty
 * at the moment of fetch, the call is a no-op (`hasMore = false`,
 * no network request). This prevents 400s when the dialog passes
 * placeholder values during the React/Vue render tick.
 */
import { ref, toValue, type MaybeRefOrGetter, type Ref } from 'vue'
import { getKanbanTagSuggestions, type KanbanTagSuggestion } from '../api'

export interface UseKanbanTagSuggestionsOptions {
  limit?: number
}

export function useKanbanTagSuggestions(
  workspaceId: MaybeRefOrGetter<string>,
  itemId: MaybeRefOrGetter<string>,
  options?: UseKanbanTagSuggestionsOptions,
) {
  const limit = options?.limit ?? 8
  const tags: Ref<KanbanTagSuggestion[]> = ref([])
  const hasMore = ref(false)
  const loading = ref(false)
  const loaded = ref(false)
  const offset = ref(0)
  let inFlight = false

  async function fetchPage(targetOffset: number): Promise<void> {
    if (inFlight) return
    // Resolve the live values on every fetch — not cached, so the composable picks up changes when
    // the parent re-renders with new args (e.g. dialog opens before column is resolved, then later
    // column becomes available).
    const wsId = toValue(workspaceId)
    const realItemId = toValue(itemId)
    // Graceful degradation: empty args = no-op (no network request). Avoids 400s when the caller
    // passes placeholder values during the render tick.
    // Leave `loaded` as false so the next `ensureLoaded()` call (after the args become available,
    // e.g. when the dialog's column prop resolves) will retry.
    if (!wsId || !realItemId) {
      hasMore.value = false
      return
    }
    inFlight = true
    loading.value = true
    try {
      const page = await getKanbanTagSuggestions(wsId, realItemId, {
        limit,
        offset: targetOffset,
      })
      tags.value = [...tags.value, ...page.tags]
      hasMore.value = page.has_more
      loaded.value = true
      offset.value = targetOffset + limit
    } catch {
      hasMore.value = false
    } finally {
      loading.value = false
      inFlight = false
    }
  }

  async function ensureLoaded(): Promise<void> {
    if (loaded.value) return
    await fetchPage(0)
  }

  async function loadNextPage(): Promise<void> {
    if (!hasMore.value || inFlight) return
    await fetchPage(offset.value)
  }

  function reset(): void {
    tags.value = []
    hasMore.value = false
    loading.value = false
    loaded.value = false
    offset.value = 0
  }

  return { tags, hasMore, loading, loaded, ensureLoaded, loadNextPage, reset }
}
