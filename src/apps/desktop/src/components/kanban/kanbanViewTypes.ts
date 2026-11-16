/** Contracts for KanbanView and the pieces it was split into. */
import type { Ref, SetupContext } from 'vue'
import type { RouteLocationNormalizedLoaded, Router } from 'vue-router'
import type { KanbanColumn, Task, WorkspaceItem } from '../../stores/workspaces'
import type { useWorkspacesStore } from '../../stores/workspaces'

export interface KanbanViewProps {
    item: WorkspaceItem
    workspaceId?: string
    itemId?: string
}

export type KanbanViewEmit = SetupContext<KanbanViewEmits>['emit']

export interface KanbanViewEmits {
  addColumn: []
  moveTask: [{ taskId: string; columnId: string; position: number }]
  renameColumn: [{ columnId: string; name: string }]
  deleteColumn: [columnId: string]
  // Column drag-and-drop reorder (Trello/Jira UX).
  reorderColumn: [{ columnId: string; targetColumnId: string }]
  // Open the per-board KanbanSettingsDialog (host owns it).
  openSettings: []
  // (openAgentSettings was REMOVED in the kanban-agent-as-tab plan — the Agent button now navigates directly to the settings page instead of emitting for the host …
  selectTask: [taskId: string]
  openTaskInBackground: [payload: { workspaceId: string; itemId: string; taskId: string }]
  openTaskDetailInBackground: [payload: { workspaceId: string; itemId: string; taskId: string }]
  deleteTask: [workspaceId: string, itemId: string, taskId: string]
  renameTask: [workspaceId: string, itemId: string, taskId: string, currentName: string]
  pinTask: [workspaceId: string, itemId: string, taskId: string, isPinned: boolean]
  // Open the per-task detail dialog (kanban-task-detail-dialog feature).
  viewTaskDetail: [taskId: string]
  // The column's "⋮" menu sends these; the host opens KanbanColumnEditor in the right mode.
  requestRenameColumn: [columnId: string]
  requestDeleteColumn: [columnId: string]
  /** Fired when the user renames the kanban via the inline pencil on the header title. */
  renameItem: [name: string]
  // Chat pane (kanban-embed-chatview plan, Task 2+4).
  closeChat: []
}

export type KanbanViewResolvedProps = Required<KanbanViewProps>

export type KanbanLayout = 'columns' | 'rows'

export const LAYOUT_PARAM = 'layout'
export const LAYOUT_STORAGE_KEY = 'pabrik-kanban-layout'
export const DENSITY_STORAGE_KEY = 'pabrik-kanban-row-density'
export const COLLAPSED_STORAGE_PREFIX = 'pabrik-kanban-row-collapsed:'
export const PRS_PARAM = 'prs'
export const ADD_COLUMN_PARAM = 'column'

export interface SortEntry {
  columnId: string
  sortBy: 'position' | 'created_at' | 'updated_at' | 'name'
  direction: 'asc' | 'desc'
}

/** What every board module needs from the component instance. */
export interface KanbanBoardDeps {
  props: KanbanViewResolvedProps
  emit: KanbanViewEmit
  store: ReturnType<typeof useWorkspacesStore>
  router: Router
  route: RouteLocationNormalizedLoaded
  effectiveItemId: Ref<string>
  layout: Ref<KanbanLayout>
  tasks: Ref<Task[]>
  sortedColumns: Ref<KanbanColumn[]>
}
