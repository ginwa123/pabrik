/** Shared contracts for the KanbanTaskDetail panel and its extracted children. The props and emits
 * below are the panel's public API and are unchanged by the split — every parent keeps binding the
 * same names. */
import type { ComputedRef, Ref, SetupContext } from 'vue'
import type { Task, KanbanColumn } from '../../stores/workspaces'
import type { PreviewFile } from '../file/FilePreview.vue'
import type { FolderEntry } from '../../api'
import type { useKanbanTagSuggestions } from '../../composables/useKanbanTagSuggestions'

export interface TaskDetailProps {
  show: boolean
  mode?: 'edit' | 'create'
  task: Task | null
  column?: KanbanColumn | null // optional — shown in metadata strip
  errorMessage?: string | null // optional — red banner in body
  // Absolute path used as the root for the `@`-trigger file picker
  // in <KanbanDescriptionEditor>. Falls back to '' (no picker
  // results) for legacy kanbans that don't have a path set.
  cwd?: string
  // NEW (plan: kanban-task-tags-autocomplete.md, Task 2.7): Workspace id required by the
  // tag-suggestions composable. Empty string = no fetch attempted (legacy callers + tests that
  // don't care about suggestions).
  workspaceId?: string
  // NEW (plan: 2026-08-06-kanban-add-task-button-placement). The available columns for the
  // create-mode column dropdown. Empty array = no dropdown rendered (legacy callers, edit mode,
  // or kanbans that haven't loaded columns yet). Edit mode passes empty.
  availableColumns?: KanbanColumn[]
  // NEW (kanban task dependencies). Candidate tasks for the
  // dependency picker (same board). Empty = picker hidden.
  tasks?: Task[]
  // NEW (plan: 2026-08-24-kanban-create-run-disable-double-click).
  // Edit mode ignores it (the host only binds it on the
  // create-mode mount).
  creating?: boolean
}

export type TaskDetailEmit = SetupContext<TaskDetailEmits>['emit']
export type TaskTagSuggestions = ReturnType<typeof useKanbanTagSuggestions>

export interface TaskDetailEmits {
  // v-model:show two-way binding — emits `false` when the dialog wants to close (X button, Cancel
  // button, backdrop click, Escape key). Parent uses `v-model:show` so this is what makes the
  // dialog actually close.
  'update:show': [value: boolean]
  // Explicit close event for parents that bind `:show` (one-way) and listen for `@close` to flip
  // their own ref. Kept for backward compatibility with the existing test suite and for the
  // KanbanSettingsDialog-style pattern.
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
  // Create-mode counterpart. Host wires this to workspacesStore.addTask
  // + moveTaskToColumn. Same payload shape as `save` but with
  // mode='create' so the parent handler can switch on it.
  create: [
    payload: {
      mode: 'create'
      name: string
      description: string
      // Auto-retry-until-stop (Option A): the toggle's live value at the moment of Create.
      is_auto_retry_until_stop: '0' | '1'
      // Create-mode only. `true` = isolate the agent in a fresh git
      // worktree (host bakes `#Notes UseGitWorktree` into the
      // create_and_run queue_message; plain create ignores it).
      useGitWorktree: boolean
      // Create-mode only. Custom worktree path input (visible when the worktree toggle is ON).
      // Empty string = agent picks the path itself; non-empty is baked as the `Path:` line after
      // `#Notes UseGitWorktree` in the queue_message.
      worktreePath: string
      // Create-mode only. Base ref the new worktree branches FROM, e.g. `origin/main`. Visible when
      // the worktree toggle is ON; empty string = no `Base:` line, so the agent branches from the
      // repo's current HEAD (the pre-existing behavior).
      worktreeBaseBranch: string
      // NEW (kanban task tags, Migration 067): array of free-form
      // tag strings. Empty array = no tags. Host forwards via
      // api.createTask's `tags` param; backend validates + persists.
      tags: string[]
      // NEW (plan: 2026-08-06-kanban-task-profile-selector). Selected agent-model name (empty
      // string = backend default / top-level config).
      selectedAgent: string
      // NEW (plan: 2026-08-06-kanban-no-base64-in-desc). Files the dialog's editor staged in create
      // mode (no base64 ever written into `description`). Always present — empty array when no
      // images were pasted/picked.
      pendingFiles: PreviewFile[]
      // NEW (Migration 070 — kanban-cwd-session-optional plan). Per-task cwd override. Absolute
      // path on disk or '' for cwd-less.
      skillNames: string[]
      cwdSession?: string
    },
  ]
  // Emitted in edit mode when the user flips the unattended toggle.
  // BEFORE the optimistic UI flip so the host can capture the
  // pre-toggle value (in case it needs to roll back on PUT failure).
  'update-unattended': [payload: { value: '0' | '1'; previous: '0' | '1' }]
  // NEW (plan: 2026-08-06-kanban-create-task-run-agent). Emitted when the user clicks "Create task
  // & run agent" in create mode. Same payload shape as `create` but with mode='create_and_run' so
  // the host can branch on it.
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
      // Mirror of `worktreeBaseBranch` on the `create` emit (the
      // `Base:` line).
      worktreeBaseBranch: string
      tags: string[]
      // NEW (plan: 2026-08-06-kanban-task-profile-selector). See note on the `create` emit above.
      // Threaded through to runAgentOnNewTask so the agent runs with the chosen agent.
      selectedAgent: string
      // NEW (plan: 2026-08-06-kanban-no-base64-in-desc). Mirror of
      // the `pendingFiles` field on the `create` emit above.
      pendingFiles: PreviewFile[]
      // NEW (Migration 070 — kanban-cwd-session-optional plan). Mirror of the `cwdSession` field on
      // the `create` emit above.
      skillNames: string[]
      cwdSession?: string
    },
  ]
  // NEW (plan: 2026-08-06-kanban-add-task-button-placement). Create mode only. Fires when the user
  // picks a different column from the create-mode dropdown.
  'column-change': [columnId: string]
  // NEW (plan: 2026-08-14-kanban-task-detail-edit-cwd). Edit mode only. Fires when the user picks a
  // different cwd from the picker in edit mode.
  'update-cwd': [payload: { cwd: string }]
  // NEW (plan: 2026-08-18-kanban-task-detail-start-agent). Edit mode only. Fires when the user
  // clicks the ▶ Start agent button.
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

/** Everything the extracted sub-panels read. Provided once by KanbanTaskDetail.vue so a child owns
 * markup only — behaviour stays in the parent's state/actions composables. */
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
