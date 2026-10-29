import type { ComputedRef, Ref } from 'vue'
import type { RouteLocationNormalizedLoaded, Router } from 'vue-router'
import { buildAppUrl, buildTaskAppUrl, parseAppPath } from '../../helpers/appUrl'
import { parseItemIdWithChat } from '../../helpers/buildItemIdWithChat'
import { openInNewTab } from '../../helpers/openInNewTab'
import type { useWorkspacesStore, Workspace, WorkspaceItem } from '../../stores/workspaces'
import type { SidebarHandle } from './types'

type KanbanCardDeps = {
  router: Router
  route: RouteLocationNormalizedLoaded
  workspacesStore: ReturnType<typeof useWorkspacesStore>
  sidebarRef: Ref<SidebarHandle | null>
  activeWorkspaceItem: ComputedRef<WorkspaceItem | undefined>
  activeWorkspace: ComputedRef<Workspace | undefined>
}

/** The kanban column + card events AppLayout forwards to the store and to Sidebar. */
export function useKanbanCardEvents(deps: KanbanCardDeps) {
  const { router, route, workspacesStore, sidebarRef } = deps
  const activeWorkspaceItem = deps.activeWorkspaceItem
  const activeWorkspace = deps.activeWorkspace

// "Rename column" emitted from the inline rename input inside <KanbanColumn>. The column lets the
// user type a new name directly (no modal) and emits this on blur / Enter. Direct store call.
const handleKanbanRenameColumn = (payload: { columnId: string; name: string }) => {
  if (!activeWorkspaceItem.value) return
  const ws = activeWorkspace.value
  if (!ws) return
  void workspacesStore.updateKanbanColumn(ws.id, activeWorkspaceItem.value.id, payload.columnId, {
    name: payload.name,
  })
}

// "Delete column" emitted from the column's quick-delete path (the ⋮ menu's "Delete" goes through
// the editor flow above, but the column may also expose a faster path in a future iteration).
// Direct store call.
const handleKanbanDeleteColumn = (columnId: string) => {
  if (!activeWorkspaceItem.value) return
  const ws = activeWorkspace.value
  if (!ws) return
  void workspacesStore.deleteKanbanColumn(ws.id, activeWorkspaceItem.value.id, columnId)
}

// Column header drag-and-drop reorder (Trello/Jira UX).
const handleKanbanReorderColumn = (payload: { columnId: string; targetColumnId: string }) => {
  if (!activeWorkspaceItem.value) return
  const ws = activeWorkspace.value
  if (!ws) return
  void workspacesStore.reorderKanbanColumn(
    ws.id,
    activeWorkspaceItem.value.id,
    payload.columnId,
    payload.targetColumnId,
  )
}

// Task-level events (select-task, delete-task, rename-task, pin-task) re-emitted by <KanbanColumn>.
// These all live in Sidebar (because they need access to chatsListRef and the modal state for
// rename), so we forward them via the exposed methods.
const handleKanbanSelectTask = (taskId: string) => {
  sidebarRef.value?.selectTask(taskId)
}

// Right-click "Open in new tab" on a kanban card. Builds the task
// chat URL from the card's explicit ids and opens a real browser
// tab — no store mutation, the board stays put.
const handleKanbanOpenTaskInBackground = (payload: {
  workspaceId: string
  itemId: string
  taskId: string
}) => {
  openInNewTab(
    router,
    buildTaskAppUrl({
      taskId: payload.taskId,
      activeWorkspaceId: payload.workspaceId || activeWorkspace?.value?.id || null,
      activeWorkspaceItemId: payload.itemId || null,
      activeDesignPageId: null,
      activeItemType: 'kanban',
      currentQuery: route.query,
    }),
  )
}

// Right-click "Open details in new tab" on a kanban card. Builds the BOARD url (no /chat/ suffix) +
// ?detail=<taskId> so the new tab loads the kanban with the inline detail panel pre-opened.
// Preserves sorts/pageId breadcrumb via currentQuery.
const handleKanbanOpenTaskDetailInBackground = (payload: {
  workspaceId: string
  itemId: string
  taskId: string
}) => {
  const pathParsed = parseAppPath(route.path)
  const wsId =
    payload.workspaceId ||
    activeWorkspace?.value?.id ||
    (pathParsed.kind === 'project' ||
    pathParsed.kind === 'projectChat' ||
    pathParsed.kind === 'projectAdd'
      ? pathParsed.workspaceId
      : '') ||
    (route.query.workspaceId as string) ||
    ''
  const pathProject =
    pathParsed.kind === 'project' ||
    pathParsed.kind === 'projectChat' ||
    pathParsed.kind === 'projectAdd'
      ? pathParsed.projectId
      : ''
  const bareItemId =
    payload.itemId ||
    pathProject ||
    parseItemIdWithChat((route.query.itemId as string) ?? '').itemId ||
    activeWorkspaceItem?.value?.id ||
    ''
  // Strip any existing /chat/ suffix — the detail tab is the
  // board, not the chat.
  const bare = bareItemId.split('/chat/')[0] ?? bareItemId
  const sub: Record<string, string> = { detail: payload.taskId }
  const sorts = route.query.sorts
  if (typeof sorts === 'string' && sorts !== '') sub.sorts = sorts
  openInNewTab(router, buildAppUrl({ workspaceId: wsId, projectId: bare, query: sub }))
}

const handleKanbanDeleteTask = (workspaceId: string, itemId: string, taskId: string) => {
  sidebarRef.value?.deleteTask(workspaceId, itemId, taskId)
}

const handleKanbanRenameTask = (
  workspaceId: string,
  itemId: string,
  taskId: string,
  currentName: string,
) => {
  sidebarRef.value?.renameTask(workspaceId, itemId, taskId, currentName)
}

const handleKanbanPinTask = (
  workspaceId: string,
  itemId: string,
  taskId: string,
  isPinned: boolean,
) => {
  sidebarRef.value?.pinTask(workspaceId, itemId, taskId, isPinned)
}
  return {
    handleKanbanRenameColumn,
    handleKanbanDeleteColumn,
    handleKanbanReorderColumn,
    handleKanbanSelectTask,
    handleKanbanOpenTaskInBackground,
    handleKanbanOpenTaskDetailInBackground,
    handleKanbanDeleteTask,
    handleKanbanRenameTask,
    handleKanbanPinTask,
  }
}
