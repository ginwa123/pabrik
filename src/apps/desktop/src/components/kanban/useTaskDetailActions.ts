/** Handlers for the KanbanTaskDetail panel: the emit-and-submit actions, the picker toggles and the
 * document-level click/key listeners they need. Pure plumbing — no fetch, no try/catch (the loaders
 * that need one stay in KanbanTaskDetail.vue). */
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
    tags,
    dependsOn,
    selectedAgent,
    isAgentPickerOpen,
    selectedSkills,
    skillSearch,
    isSkillPickerOpen,
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

// Pre-populate from the parent kanban's `cwd` prop on dialog open. The parent (KanbanView) passes
// the kanban's `path` (kanban-level cwd) as this prop — when set, the new task's per-task cwd
// defaults to it (the user can change or skip).
const toggleCwdPicker = () => {
  isCwdPickerOpen.value = !isCwdPickerOpen.value
}
// NEW (plan: 2026-08-14-kanban-task-detail-edit-cwd). In edit mode the picker fires `update-cwd` so
// the host persists immediately (same iOS-style immediate-save UX as the unattended toggle).
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
    // The dialog root carries the `data-testid="file-picker-dialog"` testid, so we can match it
    // (and its Teleport-portal descendants) without touching the picker ref.
    !(target as Element | null)?.closest?.('[data-testid="file-picker-dialog"]')
  ) {
    // User intent: clicking outside the picker should NOT close it by accident — the picker has
    // explicit Cancel and Select affordances for closing.
    return // no-op: explicitly do NOT close the picker on outside click
  }
}

// NEW (plan: 2026-08-06-kanban-folder-picker-style). Computed style object for the cwd picker
// button.
const cwdPickerStyle = computed<Record<string, string>>(() => ({
  backgroundColor: cwdSession.value ? 'var(--semantic-active-bg)' : 'var(--semantic-sidebar-bg)',
  border: '1px solid var(--color-border)',
  color: cwdSession.value ? 'var(--semantic-text)' : 'var(--semantic-text-dim)',
}))
// FilePickerDialog data adapter — same `path: string => Promise<T[]>` contract used by
// AddKanbanDialog. Mirrors its loadItemsForPicker helper (kept duplicated, not extracted, per the
// AddKanbanDialog comment).
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

// ─── Handlers ─────────────────────────────────────────────────────────── NEW (plan:
// 2026-08-18-kanban-task-detail-start-agent). Edit-mode handler for the ▶ Start agent button.
const handleStartAgent = () => {
  if (isWorkerRunning.value) return
  if (!props.task?.id) return
  emit('start-agent', { taskId: props.task.id })
}

// Enter key on the task-name input: in create mode it auto
// create-tasks-AND-runs the agent (same as clicking
// "▶ Create task & run agent"); in edit mode it saves.
const handleEnterKey = () => {
  if (isCreateMode.value) {
    handleRunAgent()
  } else {
    handleSave()
  }
}

const handleSave = () => {
  if (!canSave.value) return
  // In-flight guard: while the host's create request is in flight, drop further Save clicks so a
  // double-click can't emit `create` twice (duplicate tasks). Edit mode is unaffected — the host
  // only binds `creating` on the create-mode mount.
  if (isCreateMode.value && isCreating.value) return
  // Belt + suspenders: if the user typed a tag and clicked Save without pressing Enter/comma, the
  // KanbanTagsInput still holds the draft in its local `draftInput` ref.
  tagsInputRef.value?.commitDraft()
  // canSave reads tags.value; re-check after the commit in case the user's draft was the only
  // "dirty" signal and committing it didn't change isDirty (e.g. duplicate draft). canSave
  // recomputes reactively, but the read here is intentional.
  if (!canSave.value) return
  if (isCreateMode.value) pendingAction.value = 'create'
  if (isCreateMode.value) {
    emit('create', {
      mode: 'create',
      name: name.value.trim(),
      description: description.value,
      // Forward the unattended toggle's current value. The immediate-flip handler
      // (handleUnattendedToggle) already updated `unattended` via PUT in edit mode; in create mode
      // there's no session row yet, so this is the FIRST (and only) time the value gets sent.
      is_auto_retry_until_stop: unattended.value,
      // Forwarded for the create-and-run path (baked into queue_message).
      // Expanded to absolute so a `~` prefill never reaches the wire —
      // the agent's validatePath rejects non-absolute paths.
      useGitWorktree: useGitWorktree.value,
      worktreePath: expandWorktreePath(worktreePath.value),
      worktreeBaseBranch: worktreeBaseBranch.value.trim(),
      // NEW (Migration 067 — kanban task tags): forward the
      // current tags array. The KanbanTagsInput already
      // validates + dedupes, so the array is ready to persist.
      tags: tags.value,
      // NEW (plan: 2026-08-06-kanban-task-profile-selector). Empty string = backend default. Host
      // captures but does NOT persist on plain create (Path A — the backend's task_create.zig has
      // no selected_profile_model field).
      selectedAgent: selectedAgent.value,
      // NEW (plan: 2026-08-06-kanban-no-base64-in-desc). Create mode image attachments: the editor
      // never writes base64 into `description`. Instead it stages pasted/picked images in
      // `pendingFiles`.
      pendingFiles: [...(descriptionEditorRef.value?.pendingFiles ?? [])],
      // NEW (Migration 070 — kanban-cwd-session-optional plan). Per-task cwd override. The dialog's
      // folder picker populates `cwdSession` (defaults to the parent kanban's path when set; empty
      // when the kanban is cwd-less or the user skipped the picker).
      cwdSession: cwdSession.value,
      skillNames: [...selectedSkills.value],
    })
  } else {
    // Dependencies ride the same save only when changed: omitted
    // means "leave untouched" on the wire (`[]` clears, so only
    // send it when the picker actually moved).
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
  // Emit BOTH events so both binding patterns work:
  //   - v-model:show (KanbanView) listens for `update:show`
  //   - :show + @close (KanbanSettingsDialog-style) listens for `close`
  emit('update:show', false)
  emit('close')
}

// Mirror of handleSave but for the create dialog's primary half ("▶ Create task & run agent"), and
// for Enter on the name field. Emits `create-and-run` with mode='create_and_run' so the host can
// branch.
const handleRunAgent = () => {
  if (!canRunAgent.value) return
  // In-flight guard: while the host's create request is in flight,
  // drop further clicks so a double-click can't emit
  // `create-and-run` twice (duplicate tasks + duplicate agents).
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
    tags: tags.value,
    // NEW (plan: 2026-08-06-kanban-task-profile-selector). Empty string = backend default. Host
    // threads through to runAgentOnNewTask which sets selected_profile_model on the session at
    // creation time so the chatview's picker reflects it on landing.
    selectedAgent: selectedAgent.value,
    // NEW (plan: 2026-08-06-kanban-no-base64-in-desc). Mirror of
    // handleSave's pendingFiles — see that handler for the
    // orchestration contract.
    pendingFiles: [...(descriptionEditorRef.value?.pendingFiles ?? [])],
    // NEW (Migration 070 — kanban-cwd-session-optional plan).
    // Mirror of handleSave's cwdSession — see that handler for the
    // 3-level fallback chain contract.
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

// Toggle the unattended-mode flag. Emits `update-unattended` so the host can call
// api.updateSession(task.id, { isAutoRetryUntilStop }) and persist it.
const handleUnattendedToggle = (event: Event) => {
  const target = event.target as HTMLInputElement
  const newValue: '0' | '1' = target.checked ? '1' : '0'
  const previous = unattended.value
  // Optimistic local flip so the switch reflects the user's click
  // immediately. If the PUT fails, the SSE re-fetch (or a manual
  // rollback in the host) will correct it on the next paint.
  unattended.value = newValue
  emit('update-unattended', { value: newValue, previous })
}

// Create-mode only: no immediate-save emit (unlike
// handleUnattendedToggle) — read at Create / Create-&-run click time.
const handleUseGitWorktreeToggle = (event: Event) => {
  const target = event.target as HTMLInputElement
  useGitWorktree.value = target.checked
  if (target.checked && worktreePath.value.trim() === '') {
    worktreePath.value = `${resolveWorktreeDir()}/${slugifyWorktreeName(name.value)}-${Date.now()}`
  }
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

// Add or drop one skill. The dropdown deliberately stays open: picking
// several in one pass is the whole point of the multi-select.
const toggleSkill = (name: string) => {
  selectedSkills.value = selectedSkills.value.includes(name)
    ? selectedSkills.value.filter((n) => n !== name)
    : [...selectedSkills.value, name]
}

const clearSkills = () => {
  selectedSkills.value = []
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
