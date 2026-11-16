import { computed, ref } from 'vue'
import type { ComputedRef, Ref } from 'vue'
import type { DesignElement as DesignElementApi, DesignPage } from '../../api'
import type { useDesignHandlers } from '../../composables/useDesignHandlers'
import type { useDesignHistory } from '../../composables/useDesignHistory'
import { useWorkspacesStore } from '../../stores/workspaces'

type Deps = {
  workspaceId: ComputedRef<string>
  effectiveItemId: ComputedRef<string>
  activePageId: ComputedRef<string>
  pages: ComputedRef<DesignPage[]>
  elements: ComputedRef<DesignElementApi[]>
  selectedIds: Ref<Set<string>>
  designHandlers: ReturnType<typeof useDesignHandlers>
  history: ReturnType<typeof useDesignHistory>
}

export function useDesignContextActions(deps: Deps) {
  const {
    workspaceId,
    effectiveItemId,
    activePageId,
    pages,
    elements,
    selectedIds,
    designHandlers,
    history,
  } = deps
  const workspacesStore = useWorkspacesStore()

  // Chunk 5: handlers for the 4 reorder + select-all + delete events emitted by the LayersPanel context menu (and the canvas's own DesignContextMenu).
  function handleDesignSelectAll(): void {
    selectedIds.value = new Set(elements.value.map((e) => e.id))
  }

  async function handleDesignContextMenuDelete(targetIds: string[]): Promise<void> {
    if (!workspaceId.value || !effectiveItemId.value || !activePageId.value) return
    if (targetIds.length === 0) return
    if (!confirm(`Delete ${targetIds.length} element${targetIds.length === 1 ? '' : 's'}?`)) return
    // Undo/redo plan (Chunk 5): capture the deleted elements + their HTML bodies BEFORE the deletion so undo can restore everything.
    const deletedElements = targetIds
      .map((id) => {
        const el = elements.value.find((e) => e.id === id)
        if (!el) return null
        return { element: { ...el }, htmlBody: null as string | null }
      })
      .filter((e): e is { element: DesignElementApi; htmlBody: string | null } => e !== null)
    void history.captureDelete(deletedElements)
    for (const id of targetIds) {
      void workspacesStore.deleteDesignElement(
        workspaceId.value,
        effectiveItemId.value,
        activePageId.value,
        id,
      )
    }
    // Drop any deleted ids from the local selection Set so the remaining selection (if any) stays intact.
    const deleted = new Set(targetIds)
    const next = new Set<string>()
    for (const id of selectedIds.value) {
      if (!deleted.has(id)) next.add(id)
    }
    selectedIds.value = next
  }

  // NEW (2026-08-06, design-move-to-page plan, Chunk 8): pass-through computed properties for the MoveToPageDialog.
  const pagesForMoveDialog = computed<DesignPage[]>(() => pages.value)
  const elementNameForMoveDialog = computed<string>(() => {
    const id = moveToPageDialogElementId.value
    if (!id) return ''
    const el = elements.value.find((e) => e.id === id)
    return el?.name ?? id
  })

  // NEW (Chunk 2 of the right-click group menu plan): when the layers panel emits `group` from the context menu, mirror the Cmd+G path: inject the targetIds into …
  const handleDesignGroupFromContextMenu = (targetIds: string[]): void => {
    if (targetIds.length < 2) return
    selectedIds.value = new Set(targetIds)
    // Push the group entry — the parent group's id is determined by the backend; for the capture entry we record `beforeParentExisted: true` (parent row doesn't …
    void history.captureGroup('__pending__', targetIds, true)
    void designHandlers.groupSelection()
  }

  // Chunk 9 of grouped-layers plan: dissolve the single selected group/frame.
  const handleDesignUngroupFromContextMenu = (elementId: string): void => {
    if (!elementId) return
    void designHandlers.ungroupSelection(elementId)
  }

  // NEW (2026-08-06, design-leave-group plan): pull the SINGLE selected element out of its current parent group/frame to top-level.
  const handleDesignLeaveGroupFromContextMenu = (elementId: string): void => {
    if (!elementId) return
    if (!workspaceId.value || !effectiveItemId.value || !activePageId.value) return
    void designHandlers.leaveGroup(elementId)
  }

  // NEW (2026-08-06, design-move-to-page plan, Chunk 8): open the MoveToPageDialog with the right-clicked element.
  const moveToPageDialogElementId = ref<string>('')
  const moveToPageDialogVisible = computed({
    get: () => moveToPageDialogElementId.value !== '',
    set: (v) => {
      if (!v) moveToPageDialogElementId.value = ''
    },
  })
  const handleDesignMoveToPageFromContextMenu = (elementId: string): void => {
    if (!elementId) return
    if (!workspaceId.value || !effectiveItemId.value || !activePageId.value) return
    moveToPageDialogElementId.value = elementId
  }
  const handleDesignMoveToPageDialogSelect = async (newPageId: string): Promise<void> => {
    const elementId = moveToPageDialogElementId.value
    if (!elementId || !workspaceId.value || !effectiveItemId.value || !activePageId.value) {
      moveToPageDialogElementId.value = ''
      return
    }
    const success = await designHandlers.moveToPage(elementId, newPageId)
    // Close the dialog regardless — failure already shows an error toast.
    moveToPageDialogElementId.value = ''
    // Q6: handler navigates to the target page on success (no-op on failure).
    void success
  }
  const handleDesignMoveToPageDialogClose = (): void => {
    moveToPageDialogElementId.value = ''
  }

  return {
    handleDesignSelectAll,
    handleDesignContextMenuDelete,
    pagesForMoveDialog,
    elementNameForMoveDialog,
    moveToPageDialogVisible,
    handleDesignGroupFromContextMenu,
    handleDesignUngroupFromContextMenu,
    handleDesignLeaveGroupFromContextMenu,
    handleDesignMoveToPageFromContextMenu,
    handleDesignMoveToPageDialogSelect,
    handleDesignMoveToPageDialogClose,
  }
}
