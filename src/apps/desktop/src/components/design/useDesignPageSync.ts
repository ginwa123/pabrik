import { onMounted, onUpdated, ref } from 'vue'
import type { ComputedRef, Ref, WritableComputedRef } from 'vue'
import { useWorkspacesStore } from '../../stores/workspaces'

type Deps = {
  workspaceId: ComputedRef<string>
  effectiveItemId: ComputedRef<string>
  activePageId: WritableComputedRef<string>
  selectedIds: Ref<Set<string>>
  nudgeOffsets: Map<string, { x: number; y: number }>
  lastChosenPage: Ref<string>
}

export function useDesignPageSync(deps: Deps) {
  const { workspaceId, effectiveItemId, activePageId, selectedIds, nudgeOffsets, lastChosenPage } =
    deps
  const workspacesStore = useWorkspacesStore()

  // Page activation (mirrors KanbanView's loadColumns pattern).
  const activatePage = (pageId: string): void => {
    selectedIds.value = new Set()
    // Nudge offsets are per-element; fresh page means every cached offset is for an element that no longer exists.
    nudgeOffsets.clear()
    if (!pageId) return
    if (!workspaceId.value || !effectiveItemId.value) return
    void workspacesStore.fetchDesignElements(workspaceId.value, effectiveItemId.value, pageId)
  }
  // Effect cursor: the page the effects last ran for.
  const prevActivePage = ref(activePageId.value)
  const claimAndActivatePage = (): void => {
    const pageId = activePageId.value
    if (pageId === prevActivePage.value) return
    prevActivePage.value = pageId
    activatePage(pageId)
  }

  const choosePage = (choice: string): void => {
    if (choice === lastChosenPage.value) return
    lastChosenPage.value = choice
    activePageId.value = choice
    claimAndActivatePage()
  }
  onMounted(() => {
    prevActivePage.value = activePageId.value
  })
  onUpdated(() => {
    claimAndActivatePage()
  })

  return { activatePage, claimAndActivatePage, choosePage }
}
