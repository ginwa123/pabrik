/** The provide/inject seam for the board: KanbanView provides one context object and the three
 * extracted panels inject it, so a panel holds markup and nothing else. */
import { inject, type InjectionKey, type Ref } from 'vue'
import type { KanbanColumn, Task, WorkspaceItem } from '../../stores/workspaces'
import type { PrListTab } from './KanbanPrList.vue'
import type { KanbanRowDensity } from './KanbanTaskRow.vue'
import type { FolderEntry } from '../../api'
import type { PreviewFile } from '../file/FilePreview.vue'
import type { KanbanViewEmit, KanbanLayout, SortEntry } from './kanbanViewTypes'

export interface KanbanBoardContext {
  item: WorkspaceItem
  itemId: string
  workspaceId: string
  emit: KanbanViewEmit
  layout: Ref<KanbanLayout>
  setLayout: (next: KanbanLayout) => void
  rowDensity: Ref<KanbanRowDensity>
  setRowDensity: (next: KanbanRowDensity) => void
  collapsedColumnIds: Ref<string[]>
  toggleColumnCollapsed: (columnId: string) => void
  searchQuery: Ref<string>
  onSearchInput: (newQ: string) => void
  tasks: Ref<Task[]>
  sortedColumns: Ref<KanbanColumn[]>
  runAllBusyByColumn: Ref<Record<string, boolean>>
  stopAllBusyByColumn: Ref<Record<string, boolean>>
  runAllSummary: Ref<string | null>
  setColumnsContainerEl: (el: unknown) => void
  setRowsContainerEl: (el: unknown) => void
  setColumnRef: (columnId: string) => (el: unknown) => void
  prColumnKey: (columnId: string) => string
  handleRunAllAgents: (columnId: string) => void
  handleStopAllAgents: (columnId: string) => void
  handleRunAgentFromMenu: (payload: { taskId: string }) => void
  handleViewTaskDetail: (taskId: string) => void
  handleColumnSortChange: (
    columnId: string,
    payload: { sortBy: SortEntry['sortBy']; direction: SortEntry['direction'] },
  ) => void
  showPathPicker: Ref<boolean>
  pathPickerBusy: Ref<boolean>
  loadItemsForPathPicker: (path: string) => Promise<FolderEntry[]>
  handleProjectRootSelected: (path: string) => Promise<void>
  prPluralLabel: Ref<string>
  prOpenCount: Ref<number | null>
  prOpenTruncated: Ref<boolean>
  openPrList: () => void
  prsOpen: Ref<boolean>
  prsTab: Ref<PrListTab>
  setPrListEl: (el: unknown) => void
  closePrList: () => void
  onPrTabChange: (tab: PrListTab) => void
  onPrListOpenCount: (n: number) => void
  onPrListClosed: (payload: { number: number; headRef: string }) => void
  handleOpenSettings: () => void
  handleOpenAgentSettings: () => void
  handleOpenCreateDialog: () => void
  showTaskDetail: Ref<boolean>
  showCreateDialog: Ref<boolean>
  onDetailShowUpdate: (open: boolean) => void
  onCreateShowUpdate: (open: boolean) => void
  activeTaskDetail: Ref<Task | null>
  activeTaskDetailColumn: Ref<KanbanColumn | null>
  activeCreateColumn: Ref<KanbanColumn | null>
  activeCreateColumnId: Ref<string | null>
  startAgentError: Ref<string | null>
  createError: Ref<string | null>
  createBusy: Ref<boolean>
  handleTaskDetailSave: (payload: {
    name: string
    description: string
    tags?: string[]
    depends_on?: string[]
  }) => Promise<void>
  handleCreateTaskSave: (payload: {
    mode: 'create' | 'create_session' | 'create_and_run'
    name: string
    description: string
    is_auto_retry_until_stop?: '0' | '1'
    useGitWorktree?: boolean
    worktreePath?: string
    worktreeBaseBranch?: string
    tags?: string[]
    selectedAgent?: string
    pendingFiles?: PreviewFile[]
    skillNames?: string[]
    cwdSession?: string
  }) => Promise<void>
  handleUnattendedToggle: (payload: { value: '0' | '1'; previous: '0' | '1' }) => Promise<void>
  handleUpdateCwd: (payload: { cwd: string }) => Promise<void>
  handleStartAgent: (payload: { taskId: string }) => Promise<void>
}

export const KANBAN_BOARD_KEY: InjectionKey<KanbanBoardContext> = Symbol('kanban-board')

export function useKanbanBoardContext(): KanbanBoardContext {
  const ctx = inject(KANBAN_BOARD_KEY)
  if (!ctx) throw new Error('KanbanView context missing — mount through KanbanView.vue')
  return ctx
}
