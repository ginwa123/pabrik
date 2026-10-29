import type { Ref } from 'vue'
import * as api from '../../api'
import { useNavigationStore } from '../navigation'
import type { Workspace } from './types'

interface SelectionParams {
  workspaces: Ref<Workspace[]>
  activeWorkspaceId: Ref<string | null>
  activeWorkspaceItemId: Ref<string | null>
  activeTaskId: Ref<string | null>
  expandedItemIds: Ref<Record<string, boolean>>
  writeActiveWorkspaceKey: (value: string | null) => void
  ensureWorkspaceItemsLoaded: (workspaceId: string) => Promise<void>
  loadExpandedWorkspaces: () => Set<string>
  saveExpandedWorkspaces: (expandedIds: Set<string>) => void
  saveExpandedItemIds: (expandedIds: Record<string, boolean>) => void
}

export function createSelectionActions(p: SelectionParams) {
  const {
    workspaces,
    activeWorkspaceId,
    activeWorkspaceItemId,
    activeTaskId,
    expandedItemIds,
    writeActiveWorkspaceKey,
    ensureWorkspaceItemsLoaded,
    loadExpandedWorkspaces,
    saveExpandedWorkspaces,
    saveExpandedItemIds,
  } = p

  function setActiveWorkspaceItem(itemId: string | null) {
    activeWorkspaceItemId.value = itemId
  }

  // Select a workspace (header dropdown / URL restore). Clears an active item/task that belongs to
  // a DIFFERENT workspace so the Projects section and main view never mix two workspace contexts
  async function setActiveWorkspace(workspaceId: string): Promise<void> {
    if (workspaces.value.length > 0 && !workspaces.value.some((ws) => ws.id === workspaceId)) {
      return
    }
    activeWorkspaceId.value = workspaceId
    writeActiveWorkspaceKey(workspaceId)
    if (activeWorkspaceItemId.value) {
      const owner = workspaces.value.find((ws) =>
        ws.items.some((item) => item.id === activeWorkspaceItemId.value),
      )
      if (owner && owner.id !== workspaceId) {
        activeWorkspaceItemId.value = null
        activeTaskId.value = null
      }
    }
    await ensureWorkspaceItemsLoaded(workspaceId)
  }

  // Toggle expanded state for workspace item (show/hide tasks list)
  function toggleExpandedItem(itemId: string) {
    console.log(
      '[toggleExpandedItem] Before:',
      JSON.stringify(expandedItemIds.value),
      'itemId:',
      itemId,
    )
    if (expandedItemIds.value[itemId]) {
      delete expandedItemIds.value[itemId]
    } else {
      expandedItemIds.value[itemId] = true
    }
    // Trigger reactivity
    expandedItemIds.value = { ...expandedItemIds.value }
    console.log('[toggleExpandedItem] After:', JSON.stringify(expandedItemIds.value))
    saveExpandedItemIds(expandedItemIds.value)
  }

  // Set active task - also ensures parent workspace is expanded
  function setActiveTask(taskId: string | null) {
    // FIX (2026-07-14): clear the navigation store's active chat so a subsequent SSE
    // session_created event (fired on every send) cannot navigate back into the previous chat when
    // the user is typing into a task. Mirrors navigationStore.setActiveTask (navigation.ts:123).
    if (taskId !== null) {
      useNavigationStore().clearActiveChat()
    }

    activeTaskId.value = taskId
    if (taskId) {
      // Find parent workspace and item, then expand workspace
      for (const workspace of workspaces.value) {
        for (const item of workspace.items) {
          if (item.tasks?.some((t) => t.id === taskId)) {
            // Found the parent - set active item
            activeWorkspaceItemId.value = item.id
            // Expand workspace and persist if not already expanded
            if (!workspace.expanded) {
              workspace.expanded = true
              const expandedWorkspaces = loadExpandedWorkspaces()
              expandedWorkspaces.add(workspace.id)
              saveExpandedWorkspaces(expandedWorkspaces)
            }
            // Chunk 7 of kanban-task-notification-icon: opening the chat counts as a human touch —
            // stamp `last_human_touched_at` so the kanban card's orange "AI finished — awaiting
            // review" dot flips to the green "reviewed" checkmark.
            void api.markTaskHumanTouched(workspace.id, item.id, taskId).catch((err: unknown) => {
              console.warn(
                '[workspacesStore.setActiveTask] markTaskHumanTouched failed (non-fatal):',
                err,
              )
            })
            return
          }
        }
      }
    }
  }

  return {
    setActiveWorkspaceItem,
    setActiveWorkspace,
    toggleExpandedItem,
    setActiveTask,
  }
}
