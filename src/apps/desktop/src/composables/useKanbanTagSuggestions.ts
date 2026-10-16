/** Lazy-load + paginated tag suggestions for a kanban. */
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
