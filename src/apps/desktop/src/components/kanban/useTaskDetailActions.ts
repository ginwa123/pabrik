/** Handlers for the KanbanTaskDetail panel: the emit-and-submit actions, the picker toggles and the document-level click/key listeners they need. */
import { computed } from 'vue'
import { getSystemFolder, listFolder, type FolderEntry } from '../../api'
import type { TaskDetailEmit, TaskDetailProps } from './kanbanTaskDetailTypes'
import type { TaskDetailState } from './useTaskDetailState'

export function useTaskDetailActions(
  props: TaskDetailProps,
  emit: TaskDetailEmit,
  state: TaskDetailState,
) {
  const {
    isCreateMode,
    isWorkerRunning,
    canSave,
    canRunAgent,
    isCreating,
    pendingAction,
    name,
    description,
    unattended,
    useGitWorktree,
    worktreePath,
    worktreeBaseBranch,
    autoMerge,
    autoMergeMethod,
    tags,
    dependsOn,
    selectedAgent,
    isAgentPickerOpen,
    selectedSkills,
    skillSearch,
    isSkillPickerOpen,
    rememberSkills,
    selectedColumnId,
    isColumnPickerOpen,
    columnPickerRef,
    cwdSession,
    isCwdPickerOpen,
    cwdPickerRef,
    previewFilePath,
    imagePopupUrl,
    tagsInputRef,
    descriptionEditorRef,
    resolveWorktreeDir,
    expandWorktreePath,
    slugifyWorktreeName,
  } = state
const toggleColumnPicker = () => {
  isColumnPickerOpen.value = !isColumnPickerOpen.value
}
const selectColumn = (id: string) => {
  selectedColumnId.value = id
  isColumnPickerOpen.value = false
  emit('column-change', id)
}

// Pre-populate from the parent kanban's `cwd` prop on dialog open.
const toggleCwdPicker = () => {
  isCwdPickerOpen.value = !isCwdPickerOpen.value
}
// NEW (plan: 2026-08-14-kanban-task-detail-edit-cwd).
const selectCwd = (path: string) => {
  cwdSession.value = path
  isCwdPickerOpen.value = false
  if (!isCreateMode.value) {
    emit('update-cwd', { cwd: path })
  }
}
const handleDocumentClickCwd = (event: MouseEvent) => {
  if (!isCwdPickerOpen.value) return
  const target = event.target as Node | null
  if (
    cwdPickerRef.value &&
    target &&
    // Allow the FilePickerDialog dropdown contents to escape the ref's containment check.
    !cwdPickerRef.value.contains(target) &&
    // Walk up from the click target to see if any ancestor is the teleported FilePickerDialog root.
    !(target as Element | null)?.closest?.('[data-testid="file-picker-dialog"]')
  ) {
    // User intent: clicking outside the picker should NOT close it by accident — the picker has explicit Cancel and Select affordances for closing.
    return // no-op: explicitly do NOT close the picker on outside click
  }
}

// NEW (plan: 2026-08-06-kanban-folder-picker-style).
const cwdPickerStyle = computed<Record<string, string>>(() => ({
  backgroundColor: cwdSession.value ? 'var(--semantic-active-bg)' : 'var(--semantic-sidebar-bg)',
  border: '1px solid var(--color-border)',
  color: cwdSession.value ? 'var(--semantic-text)' : 'var(--semantic-text-dim)',
}))
// FilePickerDialog data adapter — same `path: string => Promise<T[]>` contract used by AddKanbanDialog.
const loadFoldersForCwdPicker = async (path: string): Promise<FolderEntry[]> => {
  const data = path ? await listFolder(path) : await getSystemFolder()
  return (data.entries || []) as FolderEntry[]
}
const handleDocumentClickColumn = (event: MouseEvent) => {
  if (!isColumnPickerOpen.value) return
  const target = event.target as Node | null
  if (columnPickerRef.value && target && !columnPickerRef.value.contains(target)) {
    isColumnPickerOpen.value = false
  }
}

// ─── Handlers ───────────────────────────────────────────────────────────
const handleStartAgent = () => {
  if (isWorkerRunning.value) return
  if (!props.task?.id) return
  emit('start-agent', { taskId: props.task.id })
}

// Enter key on the task-name input: in create mode it auto create-tasks-AND-runs the agent (same as clicking "▶ Create task & run agent"); in edit mode it saves.
const handleEnterKey = () => {
  if (isCreateMode.value) {
    handleRunAgent()
  } else {
    handleSave()
  }
}

const handleSave = () => {
  if (!canSave.value) return
  // In-flight guard: while the host's create request is in flight, drop further Save clicks so a double-click can't emit `create` twice (duplicate tasks).
  if (isCreateMode.value && isCreating.value) return
  // Belt + suspenders: if the user typed a tag and clicked Save without pressing Enter/comma, the KanbanTagsInput still holds the draft in its local `draftInput` …
  tagsInputRef.value?.commitDraft()
  // canSave reads tags.value; re-check after the commit in case the user's draft was the only "dirty" signal and committing it didn't change isDirty (e.g. …
  if (!canSave.value) return
  if (isCreateMode.value) pendingAction.value = 'create'
  if (isCreateMode.value) {
    emit('create', {
      mode: 'create',
      name: name.value.trim(),
      description: description.value,
      // Forward the unattended toggle's current value.
      is_auto_retry_until_stop: unattended.value,
      // Forwarded for the create-and-run path (baked into queue_message).
      useGitWorktree: useGitWorktree.value,
      worktreePath: expandWorktreePath(worktreePath.value),
      worktreeBaseBranch: worktreeBaseBranch.value.trim(),
      // Forwarded for the create-and-run path (baked into queue_message as `#Notes AutoMerge` + `Method:`).
      autoMerge: autoMerge.value,
      autoMergeMethod: autoMergeMethod.value,
      // NEW (Migration 067 — kanban task tags): forward the current tags array.
      tags: tags.value,
      // NEW (plan: 2026-08-06-kanban-task-profile-selector).
      selectedAgent: selectedAgent.value,
      // NEW (plan: 2026-08-06-kanban-no-base64-in-desc).
      pendingFiles: [...(descriptionEditorRef.value?.pendingFiles ?? [])],
      // NEW (Migration 070 — kanban-cwd-session-optional plan).
      cwdSession: cwdSession.value,
      skillNames: [...selectedSkills.value],
    })
  } else {
    // Dependencies ride the same save only when changed: omitted means "leave untouched" on the wire (`[]` clears, so only send it when the picker actually moved).
    const depsBefore = props.task?.depends_on ?? []
    const depsAfter = dependsOn.value
    const depsChanged =
      depsBefore.length !== depsAfter.length || depsBefore.some((d, i) => d !== depsAfter[i])
    emit('save', {
      mode: 'edit',
      name: name.value.trim(),
      description: description.value,
      // NEW (Migration 067): forward tags.
      tags: tags.value,
      ...(depsChanged ? { depends_on: [...depsAfter] } : {}),
    })
  }
}

const handleClose = () => {
  // Emit BOTH events so both binding patterns work
  emit('update:show', false)
  emit('close')
}

// Mirror of handleSave but for the create dialog's primary half ("▶ Create task & run agent"), and for Enter on the name field.
const handleRunAgent = () => {
  if (!canRunAgent.value) return
  // In-flight guard: while the host's create request is in flight, drop further clicks so a double-click can't emit `create-and-run` twice (duplicate tasks + …
  if (isCreating.value) return
  tagsInputRef.value?.commitDraft()
  if (!canRunAgent.value) return
  pendingAction.value = 'create_and_run'
  emit('create-and-run', {
    mode: 'create_and_run',
    name: name.value.trim(),
    description: description.value,
    is_auto_retry_until_stop: unattended.value,
    useGitWorktree: useGitWorktree.value,
    worktreePath: expandWorktreePath(worktreePath.value),
    worktreeBaseBranch: worktreeBaseBranch.value.trim(),
    autoMerge: autoMerge.value,
    autoMergeMethod: autoMergeMethod.value,
    tags: tags.value,
    // NEW (plan: 2026-08-06-kanban-task-profile-selector).
    selectedAgent: selectedAgent.value,
    // NEW (plan: 2026-08-06-kanban-no-base64-in-desc).
    pendingFiles: [...(descriptionEditorRef.value?.pendingFiles ?? [])],
    // NEW (Migration 070 — kanban-cwd-session-optional plan).
    cwdSession: cwdSession.value,
    skillNames: [...selectedSkills.value],
  })
}

// Commit any draft tag typed in the chip input the moment the user mousedowns the Save button.
const commitTagsDraftOnSaveMouseDown = () => {
  tagsInputRef.value?.commitDraft()
}

const handleKeydown = (event: KeyboardEvent) => {
  if (event.key === 'Escape') handleClose()
}

// Toggle the unattended-mode flag.
const handleUnattendedToggle = (event: Event) => {
  const target = event.target as HTMLInputElement
  const newValue: '0' | '1' = target.checked ? '1' : '0'
  const previous = unattended.value
  // Optimistic local flip so the switch reflects the user's click immediately.
  unattended.value = newValue
  emit('update-unattended', { value: newValue, previous })
}

// Create-mode only: no immediate-save emit (unlike handleUnattendedToggle) — read at Create / Create-&-run click time.
const handleUseGitWorktreeToggle = (event: Event) => {
  const target = event.target as HTMLInputElement
  useGitWorktree.value = target.checked
  if (target.checked && worktreePath.value.trim() === '') {
    worktreePath.value = `${resolveWorktreeDir()}/${slugifyWorktreeName(name.value)}-${Date.now()}`
  }
}


// Create-mode only: read at Create / Create-&-run click time, like the worktree toggle.
const handleAutoMergeToggle = (event: Event) => {
  const target = event.target as HTMLInputElement
  autoMerge.value = target.checked
}

const toggleAgentPicker = () => {
  isAgentPickerOpen.value = !isAgentPickerOpen.value
}

const selectAgent = (name: string) => {
  selectedAgent.value = name
  isAgentPickerOpen.value = false
}

const toggleSkillPicker = () => {
  isSkillPickerOpen.value = !isSkillPickerOpen.value
  if (!isSkillPickerOpen.value) skillSearch.value = ''
}

// Add or drop one skill.
const toggleSkill = (name: string) => {
  selectedSkills.value = selectedSkills.value.includes(name)
    ? selectedSkills.value.filter((n) => n !== name)
    : [...selectedSkills.value, name]
  rememberSkills(selectedSkills.value)
}

const clearSkills = () => {
  selectedSkills.value = []
  rememberSkills(selectedSkills.value)
}

const _openFilePreview = (path: string) => {
  previewFilePath.value = path
}
const closeFilePreview = () => {
  previewFilePath.value = null
}

const openImagePopup = (url: string) => {
  imagePopupUrl.value = url
}
const closeImagePopup = () => {
  imagePopupUrl.value = null
}
const handleImagePopupKeydown = (e: KeyboardEvent) => {
  if (e.key === 'Escape' && imagePopupUrl.value !== null) {
    closeImagePopup()
  }
}
  return {
    cwdPickerStyle,
    loadFoldersForCwdPicker,
    handleStartAgent,
    handleEnterKey,
    handleSave,
    handleClose,
    handleRunAgent,
    commitTagsDraftOnSaveMouseDown,
    handleKeydown,
    handleUnattendedToggle,
    handleUseGitWorktreeToggle,
  handleAutoMergeToggle,
    toggleAgentPicker,
    selectAgent,
    toggleSkillPicker,
    toggleSkill,
    clearSkills,
    toggleColumnPicker,
    selectColumn,
    handleDocumentClickColumn,
    toggleCwdPicker,
    selectCwd,
    handleDocumentClickCwd,
    handleImagePopupKeydown,
    openImagePopup,
    closeImagePopup,
    closeFilePreview,
  }
}

export type TaskDetailActions = ReturnType<typeof useTaskDetailActions>
