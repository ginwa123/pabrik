/** Shared contracts for the KanbanTaskDetail panel and its extracted children. */
import type { ComputedRef, Ref, SetupContext } from 'vue'
import type { Task, KanbanColumn } from '../../stores/workspaces'
import type { PreviewFile } from '../file/FilePreview.vue'
import type { FolderEntry } from '../../api'
import type { useKanbanTagSuggestions } from '../../composables/useKanbanTagSuggestions'
import type { MergeMethod } from '../../helpers/mergeWording'

export interface TaskDetailProps {
  show: boolean
  mode?: 'edit' | 'create'
  task: Task | null
  column?: KanbanColumn | null // optional — shown in metadata strip
  errorMessage?: string | null // optional — red banner in body
  // Absolute path used as the root for the `@`-trigger file picker in <KanbanDescriptionEditor>.
  cwd?: string
  // NEW (plan: kanban-task-tags-autocomplete.md, Task 2.7): Workspace id required by the tag-suggestions composable.
  workspaceId?: string
  // NEW (plan: 2026-08-06-kanban-add-task-button-placement).
  availableColumns?: KanbanColumn[]
  // NEW (kanban task dependencies).
  tasks?: Task[]
  // NEW (plan: 2026-08-24-kanban-create-run-disable-double-click).
  creating?: boolean
}

export type TaskDetailEmit = SetupContext<TaskDetailEmits>['emit']
export type TaskTagSuggestions = ReturnType<typeof useKanbanTagSuggestions>

export interface TaskDetailEmits {
  // v-model:show two-way binding — emits `false` when the dialog wants to close (X button, Cancel button, backdrop click, Escape key).
  'update:show': [value: boolean]
  // Explicit close event for parents that bind `:show` (one-way) and listen for `@close` to flip their own ref.
  close: []
  save: [
    payload: {
      mode: 'edit'
      name: string
      description: string
      tags: string[]
      depends_on?: string[]
    },
  ]
  // Create-mode counterpart.
  create: [
    payload: {
      mode: 'create'
      name: string
      description: string
      // Auto-retry-until-stop (Option A): the toggle's live value at the moment of Create.
      is_auto_retry_until_stop: '0' | '1'
      // Create-mode only.
      useGitWorktree: boolean
      // Create-mode only.
      worktreePath: string
      // Create-mode only.
      worktreeBaseBranch: string
      // Create-mode only.
      autoMerge: boolean
      // Create-mode only. The `Method:` line under that note: merge | squash | rebase.
      autoMergeMethod: string
      // NEW (kanban task tags, Migration 067): array of free-form tag strings.
      tags: string[]
      // NEW (plan: 2026-08-06-kanban-task-profile-selector).
      selectedAgent: string
      // NEW (plan: 2026-08-06-kanban-no-base64-in-desc).
      pendingFiles: PreviewFile[]
      // NEW (Migration 070 — kanban-cwd-session-optional plan).
      skillNames: string[]
      cwdSession?: string
    },
  ]
  // Emitted in edit mode when the user flips the unattended toggle.
  'update-unattended': [payload: { value: '0' | '1'; previous: '0' | '1' }]
  // NEW (plan: 2026-08-06-kanban-create-task-run-agent).
  'create-and-run': [
    payload: {
      mode: 'create_and_run'
      name: string
      description: string
      is_auto_retry_until_stop: '0' | '1'
      // Mirror of `useGitWorktree` on the `create` emit (baked into queue_message).
      useGitWorktree: boolean
      // Mirror of `worktreePath` on the `create` emit (the `Path:` line).
      worktreePath: string
      // Mirror of `worktreeBaseBranch` on the `create` emit (the `Base:` line).
      worktreeBaseBranch: string
      // Mirror of `autoMerge` on the `create` emit (the `#Notes AutoMerge` line).
      autoMerge: boolean
      // Mirror of `autoMergeMethod` on the `create` emit (the `Method:` line).
      autoMergeMethod: string
      tags: string[]
      // NEW (plan: 2026-08-06-kanban-task-profile-selector).
      selectedAgent: string
      // NEW (plan: 2026-08-06-kanban-no-base64-in-desc).
      pendingFiles: PreviewFile[]
      // NEW (Migration 070 — kanban-cwd-session-optional plan).
      skillNames: string[]
      cwdSession?: string
    },
  ]
  // NEW (plan: 2026-08-06-kanban-add-task-button-placement).
  'column-change': [columnId: string]
  // NEW (plan: 2026-08-14-kanban-task-detail-edit-cwd).
  'update-cwd': [payload: { cwd: string }]
  // NEW (plan: 2026-08-18-kanban-task-detail-start-agent).
  'start-agent': [payload: { taskId: string }]
}

export interface AgentEntry {
  name: string
  model: string
  base_url: string
}

export interface SkillEntry {
  name: string
  description: string
}

/** Everything the extracted sub-panels read. */
export type TaskDetailResolvedProps = Required<TaskDetailProps>

export interface TaskDetailContext {
  props: TaskDetailResolvedProps
  emit: TaskDetailEmit
  tagSuggestions: TaskTagSuggestions
  cwd: ComputedRef<string>
  isCreateMode: ComputedRef<boolean>
  name: Ref<string>
  description: Ref<string>
  unattended: Ref<'0' | '1'>
  useGitWorktree: Ref<boolean>
  autoMerge: Ref<boolean>
  autoMergeMethod: Ref<MergeMethod>
  homeDir: Ref<string>
  worktreePath: Ref<string>
  worktreeBaseBranch: Ref<string>
  tags: Ref<string[]>
  dependsOn: Ref<string[]>
  selectedAgent: Ref<string>
  isAgentPickerOpen: Ref<boolean>
  availableAgents: Ref<AgentEntry[]>
  agentsLoading: Ref<boolean>
  selectedSkills: Ref<string[]>
  skillSearch: Ref<string>
  isSkillPickerOpen: Ref<boolean>
  availableSkills: Ref<SkillEntry[]>
  skillsLoading: Ref<boolean>
  selectedColumnId: Ref<string | null>
  isColumnPickerOpen: Ref<boolean>
  cwdSession: Ref<string>
  isCwdPickerOpen: Ref<boolean>
  pendingAction: Ref<'create' | 'create_and_run' | null>
  previewFilePath: Ref<string | null>
  imagePopupUrl: Ref<string | null>
  isDirty: ComputedRef<boolean>
  isValid: ComputedRef<boolean>
  canSave: ComputedRef<boolean>
  canRunAgent: ComputedRef<boolean>
  isCreating: ComputedRef<boolean>
  canCommitCreate: ComputedRef<boolean>
  pendingCommitLabel: ComputedRef<string | null>
  isWorkerRunning: ComputedRef<boolean>
  skillLabel: ComputedRef<string>
  selectedSkillCount: ComputedRef<number>
  filteredSkills: ComputedRef<SkillEntry[]>
  taskTypeLabel: ComputedRef<string | null>
  columnLabel: ComputedRef<string | null>
  filteredTagSuggestions: ComputedRef<string[]>
  dependsCandidates: ComputedRef<Array<{ id: string; name: string }>>
  blockedDepIds: ComputedRef<string[]>
  imageUrls: ComputedRef<string[]>
  isMediaLoading: ComputedRef<boolean>
  cwdPickerStyle: ComputedRef<Record<string, string>>
  setTagsInputEl: (el: unknown) => void
  setDescriptionEditorEl: (el: unknown) => void
  setColumnPickerEl: (el: unknown) => void
  setCwdPickerEl: (el: unknown) => void
  loadFoldersForCwdPicker: (path: string) => Promise<FolderEntry[]>
  handleStartAgent: () => void
  handleEnterKey: () => void
  handleSave: () => void
  handleClose: () => void
  handleRunAgent: () => void
  commitTagsDraftOnSaveMouseDown: () => void
  handleKeydown: (event: KeyboardEvent) => void
  handleUnattendedToggle: (event: Event) => void
  handleUseGitWorktreeToggle: (event: Event) => void
  handleAutoMergeToggle: (event: Event) => void
  toggleAgentPicker: () => void
  selectAgent: (name: string) => void
  toggleSkillPicker: () => void
  toggleSkill: (name: string) => void
  clearSkills: () => void
  toggleColumnPicker: () => void
  selectColumn: (id: string) => void
  handleDocumentClickColumn: (event: MouseEvent) => void
  toggleCwdPicker: () => void
  selectCwd: (path: string) => void
  handleDocumentClickCwd: (event: MouseEvent) => void
  handleImagePopupKeydown: (e: KeyboardEvent) => void
  openImagePopup: (url: string) => void
  closeImagePopup: () => void
  closeFilePreview: () => void
}
