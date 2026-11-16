import { ref, type ComputedRef } from 'vue'
import type { Router } from 'vue-router'
import * as api from '../../api'
import { buildProjectSettingsUrl } from '../../helpers/appUrl'
import type { useWorkspacesStore, Workspace, WorkspaceItem } from '../../stores/workspaces'

type KanbanPanelDeps = {
  router: Router
  workspacesStore: ReturnType<typeof useWorkspacesStore>
  activeWorkspaceItem: ComputedRef<WorkspaceItem | undefined>
  activeWorkspace: ComputedRef<Workspace | undefined>
}

/** Every kanban surface AppLayout mounts: column editor, settings page, spec copy, move gate. */
export function useKanbanPanel(deps: KanbanPanelDeps) {
  const { router, workspacesStore } = deps
  const activeWorkspaceItem = deps.activeWorkspaceItem
  const activeWorkspace = deps.activeWorkspace

// ─── Design 3-column resize (separate from kanban) ─────────────────────
type KanbanEditorMode = 'add' | 'rename' | 'delete'
const showKanbanColumnEditor = ref(false)
const kanbanColumnEditorMode = ref<KanbanEditorMode>('add')
const kanbanColumnEditorTargetId = ref<string | null>(null)
const kanbanColumnEditorInitialName = ref<string>('')
const kanbanColumnEditorInitialDescription = ref<string>('')
const kanbanColumnEditorInitialIsDone = ref<boolean>(false)

// Look up the column by id in the active kanban item.
const findKanbanColumn = (columnId: string) => {
  return activeWorkspaceItem.value?.kanban_columns?.find((c) => c.id === columnId)
}

// + Column on the kanban header: open the editor in 'add' mode.
const handleKanbanAddColumn = () => {
  kanbanColumnEditorMode.value = 'add'
  kanbanColumnEditorTargetId.value = null
  kanbanColumnEditorInitialName.value = ''
  showKanbanColumnEditor.value = true
}

// ⋮ menu "Rename" on a column: open the editor in 'rename' mode, pre-filled with the column's current name and description.
const handleKanbanRequestRenameColumn = (columnId: string) => {
  const col = findKanbanColumn(columnId)
  if (!col) return
  kanbanColumnEditorMode.value = 'rename'
  kanbanColumnEditorTargetId.value = columnId
  kanbanColumnEditorInitialName.value = col.name
  kanbanColumnEditorInitialDescription.value = col.description ?? ''
  kanbanColumnEditorInitialIsDone.value = col.is_done ?? false
  showKanbanColumnEditor.value = true
}

/** Forward a kanban rename (from either the Settings dialog header pencil or the KanbanView header pencil) to the store. */
const handleKanbanRenameItem = (newName: string) => {
  if (!activeWorkspaceItem.value) return
  const ws = activeWorkspace.value
  if (!ws) return
  void workspacesStore.updateKanbanItemName(ws.id, activeWorkspaceItem.value.id, newName)
}

// ⋮ menu "Delete" on a column: open the editor in 'delete' mode (the editor renders the confirmation copy itself).
const handleKanbanRequestDeleteColumn = (columnId: string) => {
  const col = findKanbanColumn(columnId)
  if (!col) return
  kanbanColumnEditorMode.value = 'delete'
  kanbanColumnEditorTargetId.value = columnId
  kanbanColumnEditorInitialName.value = col.name
  kanbanColumnEditorInitialDescription.value = col.description ?? ''
  showKanbanColumnEditor.value = true
}

const handleKanbanColumnEditorClose = () => {
  showKanbanColumnEditor.value = false
}

const handleKanbanColumnEditorAdd = (name: string, description: string) => {
  if (!activeWorkspaceItem.value) return
  const ws = activeWorkspace.value
  if (!ws) return
  void workspacesStore.addKanbanColumn(ws.id, activeWorkspaceItem.value.id, name, description)
  showKanbanColumnEditor.value = false
}

const handleKanbanColumnEditorRename = (name: string, description: string, isDone: boolean) => {
  if (!activeWorkspaceItem.value || !kanbanColumnEditorTargetId.value) return
  const ws = activeWorkspace.value
  if (!ws) return
  void workspacesStore.updateKanbanColumn(
    ws.id,
    activeWorkspaceItem.value.id,
    kanbanColumnEditorTargetId.value,
    { name, description, is_done: isDone },
  )
  showKanbanColumnEditor.value = false
}

const handleKanbanColumnEditorDelete = () => {
  if (!activeWorkspaceItem.value || !kanbanColumnEditorTargetId.value) return
  const ws = activeWorkspace.value
  if (!ws) return
  void workspacesStore.deleteKanbanColumn(
    ws.id,
    activeWorkspaceItem.value.id,
    kanbanColumnEditorTargetId.value,
  )
  showKanbanColumnEditor.value = false
}

// ─── Kanban settings page (plan: 2026-09-02-kanban-settings-as-page) ────
const handleOpenKanbanSettings = () => {
  const itemId = activeWorkspaceItem.value?.id ?? ''
  const workspaceId = activeWorkspace.value?.id ?? ''
  if (!itemId) return
  // The URL names the workspace AND the board, so a reload knows which workspace the board is in.
  if (!workspaceId) {
    router.push({ path: `/app/kanban/${itemId}/settings` })
    return
  }
  router.push(buildProjectSettingsUrl(workspaceId, itemId))
}

const handleKanbanSettingsAddColumn = (name: string, description: string) => {
  if (!activeWorkspaceItem.value) return
  const ws = activeWorkspace.value
  if (!ws) return
  void workspacesStore.addKanbanColumn(ws.id, activeWorkspaceItem.value.id, name, description)
  // Dialog stays open so the user can add more columns in succession.
}

const handleKanbanSettingsEditColumn = (payload: {
  columnId: string
  name: string
  description: string
  is_done?: boolean
}) => {
  if (!activeWorkspaceItem.value) return
  const ws = activeWorkspace.value
  if (!ws) return
  void workspacesStore.updateKanbanColumn(ws.id, activeWorkspaceItem.value.id, payload.columnId, {
    name: payload.name,
    description: payload.description,
    ...(payload.is_done !== undefined ? { is_done: payload.is_done } : {}),
  })
}

const handleKanbanSettingsDeleteColumn = (columnId: string) => {
  if (!activeWorkspaceItem.value) return
  const ws = activeWorkspace.value
  if (!ws) return
  void workspacesStore.deleteKanbanColumn(ws.id, activeWorkspaceItem.value.id, columnId)
}

// ─── CopyKanbanSpecDialog ────────────────────────────────────────────────
const showCopyKanbanSpecDialog = ref(false)

const handleOpenCopyKanbanSpec = () => {
  showCopyKanbanSpecDialog.value = true
}

const handleCloseCopyKanbanSpec = () => {
  showCopyKanbanSpecDialog.value = false
}

const handleCopyKanbanSpec = (sourceItemId: string, mode: 'replace' | 'append') => {
  if (!activeWorkspaceItem.value || !activeWorkspace.value) return
  void workspacesStore
    .copyKanbanSpecFrom(activeWorkspace.value.id, activeWorkspaceItem.value.id, sourceItemId, mode)
    .then(() => {
      showCopyKanbanSpecDialog.value = false
    })
}

// + Add on a column: handled LOCALLY by KanbanView (no longer bubbles up here).


// Drag-and-drop task move.
const showMoveBlockedConfirm = ref(false)
const moveBlockedMessage = ref('')
const pendingBlockedMove = ref<{ taskId: string; columnId: string; position: number } | null>(null)

const handleKanbanMoveTask = async (payload: {
  taskId: string
  columnId: string
  position: number
}) => {
  if (!activeWorkspaceItem.value) return
  const ws = activeWorkspace.value
  if (!ws) return
  try {
    await workspacesStore.moveTaskToColumn(
      ws.id,
      activeWorkspaceItem.value.id,
      payload.taskId,
      payload.columnId,
      payload.position,
    )
  }
  // eslint-disable-next-line local/no-try-catch -- UI event handler forking on a typed 409 (parseMoveBlockers narrows the unknown into the confirm-dialog path); the non-gate branch logs via console.error
  catch (err) {
    const blockers = api.parseMoveBlockers(err)
    if (blockers) {
      const names = blockers.map((b) => b.name).filter((n) => n.length > 0)
      moveBlockedMessage.value =
        names.length > 0
          ? `This task is blocked by: ${names.join(', ')}. Move anyway?`
          : 'This task is blocked by incomplete dependencies. Move anyway?'
      pendingBlockedMove.value = { ...payload }
      showMoveBlockedConfirm.value = true
      return
    }
    console.error('[AppLayout] Failed to move kanban task:', err)
  }
}

// "Move anyway" confirm: retry the pending move with force=true.
const handleMoveBlockedConfirm = () => {
  const pending = pendingBlockedMove.value
  showMoveBlockedConfirm.value = false
  pendingBlockedMove.value = null
  if (!pending || !activeWorkspaceItem.value || !activeWorkspace.value) return
  void workspacesStore
    .moveTaskToColumn(
      activeWorkspace.value.id,
      activeWorkspaceItem.value.id,
      pending.taskId,
      pending.columnId,
      pending.position,
      true,
    )
    .catch((err: unknown) => {
      console.error('[AppLayout] Failed to force-move kanban task:', err)
    })
}

const handleMoveBlockedClose = () => {
  showMoveBlockedConfirm.value = false
  pendingBlockedMove.value = null
}

  return {
    showKanbanColumnEditor,
    kanbanColumnEditorMode,
    kanbanColumnEditorInitialName,
    kanbanColumnEditorInitialDescription,
    kanbanColumnEditorInitialIsDone,
    showCopyKanbanSpecDialog,
    showMoveBlockedConfirm,
    moveBlockedMessage,
    handleKanbanMoveTask,
    handleMoveBlockedConfirm,
    handleMoveBlockedClose,
    handleKanbanAddColumn,
    handleKanbanRequestRenameColumn,
    handleKanbanRequestDeleteColumn,
    handleKanbanRenameItem,
    handleOpenKanbanSettings,
    handleKanbanSettingsAddColumn,
    handleKanbanSettingsEditColumn,
    handleKanbanSettingsDeleteColumn,
    handleKanbanColumnEditorClose,
    handleKanbanColumnEditorAdd,
    handleKanbanColumnEditorRename,
    handleKanbanColumnEditorDelete,
    handleOpenCopyKanbanSpec,
    handleCloseCopyKanbanSpec,
    handleCopyKanbanSpec,
  }
}
