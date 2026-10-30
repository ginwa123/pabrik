/** Contracts for KanbanView and the pieces it was split into. The props and emits below are the
 * board's public API and are unchanged by the split — AppLayout keeps binding the same names. */
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
  // Column drag-and-drop reorder (Trello/Jira UX). Bubbled up
  // from <KanbanColumn> headers to AppLayout, which calls the
  // workspacesStore.reorderKanbanColumn action.
  reorderColumn: [{ columnId: string; targetColumnId: string }]
  // Open the per-board KanbanSettingsDialog (host owns it). No
  // payload — the host derives the active item from its own state.
  openSettings: []
  // (openAgentSettings was REMOVED in the kanban-agent-as-tab plan — the Agent button now navigates
  // directly to the settings page instead of emitting for the host to mount a dialog.
  selectTask: [taskId: string]
  openTaskInBackground: [payload: { workspaceId: string; itemId: string; taskId: string }]
  openTaskDetailInBackground: [payload: { workspaceId: string; itemId: string; taskId: string }]
  deleteTask: [workspaceId: string, itemId: string, taskId: string]
  renameTask: [workspaceId: string, itemId: string, taskId: string, currentName: string]
  pinTask: [workspaceId: string, itemId: string, taskId: string, isPinned: boolean]
  // Open the per-task detail dialog (kanban-task-detail-dialog feature). Consumed INTERNALLY here —
  // the dialog is mounted in this file's template (we own the kanban's columns & tasks, so
  // resolving the matching column is trivial). AppLayout doesn't need to know about this dialog.
  viewTaskDetail: [taskId: string]
  // The column's "⋮" menu sends these; the host opens
  // KanbanColumnEditor in the right mode.
  requestRenameColumn: [columnId: string]
  requestDeleteColumn: [columnId: string]
  /** * Fired when the user renames the kanban via the inline pencil on the header title. Mirrors
   * KanbanSettingsDialog's rename-item emit so AppLayout handles both with one handler. */
  renameItem: [name: string]
  // Chat pane (kanban-embed-chatview plan, Task 2+4). Fired when ChatView's header close button is
  // clicked. AppLayout's handler clears activeTask + navigates to view=workspace (URL is the source
  // of truth).
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

/** What every board module needs from the component instance. Passing one object keeps the wiring
 * in KanbanView.vue and the behaviour in the modules. */
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
