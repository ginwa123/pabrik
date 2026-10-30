/** Reactive state and derived values for the KanbanTaskDetail panel. Split out of the SFC so the
 * panel stays readable; behaviour (handlers, emitters) lives in useTaskDetailActions.ts. */
import { computed, inject, ref } from 'vue'
import type { PreviewFile } from '../file/FilePreview.vue'
import type {
  AgentEntry,
  SkillEntry,
  TaskDetailProps,
  TaskTagSuggestions,
} from './kanbanTaskDetailTypes'

export function useTaskDetailState(props: TaskDetailProps, tagSuggestions: TaskTagSuggestions) {
// True when the dialog is rendering the create flow (rather than
// edit-in-place). Drives header copy / icon, save-button text, the
// form-state reset rule, and which emit fires on submit.
const isCreateMode = computed<boolean>(() => props.mode === 'create')

// ─── Form state ──────────────────────────────────────────────────────────
const name = ref('')
const description = ref('')
const unattended = ref<'0' | '1'>('1')
// "Use git worktree" toggle (create mode only, default OFF). When ON,
// the host bakes `#Notes UseGitWorktree` into the create_and_run
// queue_message. Plain create ignores it (no queue_message there).
const useGitWorktree = ref(false)
// Worktree path input (create mode only, visible when the toggle is ON). Canonical root is
// $HOME/.config/pabrik/.worktrees (Option A) — prefilled on toggle-on as <slug>-<timestamp> from
// the task name plus Date.now() so concurrent tasks never collide; the user can accept or edit it.
const WORKTREE_DIR_SUFFIX = '.config/pabrik/.worktrees'
const homeDir = ref('')
const resolveWorktreeDir = (): string => {
  const home = homeDir.value.trim()
  if (home !== '') {
    const sep = home.endsWith('/') ? '' : '/'
    return `${home}${sep}${WORKTREE_DIR_SUFFIX}`
  }
  return `~/${WORKTREE_DIR_SUFFIX}`
}
const expandWorktreePath = (raw: string): string => {
  const trimmed = raw.trim()
  const home = homeDir.value.trim()
  if (trimmed.startsWith('~/') && home !== '') {
    const sep = home.endsWith('/') ? '' : '/'
    return `${home}${sep}${trimmed.slice(2)}`
  }
  return trimmed
}
const worktreePath = ref('')
// Base ref the new worktree branches FROM (create mode only, visible when the toggle is ON). Empty
// = no `Base:` line in the queue_message, so the agent branches from the repo's current HEAD (the
// pre-existing behavior).
const worktreeBaseBranch = ref('')
const slugifyWorktreeName = (raw: string): string => {
  const slug = raw
    .trim()
    .toLowerCase()
    .replace(/[^a-z0-9]+/g, '-')
    .replace(/^-+|-+$/g, '')
    .slice(0, 50)
  return slug || 'task'
}
const tags = ref<string[]>([])
// NEW (kanban task dependencies). Chosen dependency ids, edited via KanbanDependsInput and
// persisted through the same save path as tags (no second save mechanism).
const dependsOn = ref<string[]>([])
// Template ref for the chip input — handleSave calls commitDraft() imperatively before reading
// `tags.value` so a draft tag typed but not yet committed (Enter/comma not pressed) isn't dropped
// on Save.
const tagsInputRef = ref<{ commitDraft: () => void } | null>(null)
// Template ref for the description editor — used in CREATE MODE to read the staged image files
// (pendingFiles) so the dialog can hand them to the host's create-then-upload orchestrator. The
// editor exposes pendingFiles via defineExpose; see KanbanDescriptionEditor.vue for the contract.
const descriptionEditorRef = ref<{ pendingFiles: PreviewFile[] } | null>(null)

const selectedAgent = ref('')
const isAgentPickerOpen = ref(false)
const availableAgents = ref<AgentEntry[]>([])
const agentsLoading = ref(false)


// Skills picker (create only, Migration 112). Source is api.getSkills — the
// same rows search_skills reads, so a picked name always resolves in
// use_skill({ name }).
const selectedSkills = ref<string[]>([])
const skillSearch = ref('')
const isSkillPickerOpen = ref(false)
const availableSkills = ref<SkillEntry[]>([])
const skillsLoading = ref(false)


// NEW (plan: 2026-08-06-kanban-add-task-button-placement). Column dropdown state (create mode
// only). selectedColumnId mirrors the parent's `column` prop on dialog open; the picker emits
// `column-change` so the host updates its activeCreateColumnId in real-time.
const selectedColumnId = ref<string | null>(props.column?.id ?? null)
const isColumnPickerOpen = ref(false)
const columnPickerRef = ref<HTMLElement | null>(null)


// NEW (Migration 070 — kanban-cwd-session-optional plan). Per-task cwd picker state (create mode
// only).
const cwdSession = ref<string>('')
const isCwdPickerOpen = ref(false)
const cwdPickerRef = ref<HTMLElement | null>(null)

const setTagsInputEl = (el: unknown) => {
  tagsInputRef.value = el as { commitDraft: () => void } | null
}
const setDescriptionEditorEl = (el: unknown) => {
  descriptionEditorRef.value = el as { pendingFiles: PreviewFile[] } | null
}
const setColumnPickerEl = (el: unknown) => {
  columnPickerRef.value = el as HTMLElement | null
}
const setCwdPickerEl = (el: unknown) => {
  cwdPickerRef.value = el as HTMLElement | null
}

// Which commit the user actually pressed. Declared ahead of openDialog below so the open handler
// can clear it. `creating` is one host flag covering both create paths, so on its own the footer
// cannot tell "Create task" from "Create task & run agent".
const pendingAction = ref<'create' | 'create_and_run' | null>(null)

// File preview modal state. Opened when the user clicks a file-path
// chip in either the inline MarkdownDescription (display mode) or the
// editor's preview.
const previewFilePath = ref<string | null>(null)
// Persisted-image gallery preview.
const imagePopupUrl = ref<string | null>(null)

// Dirty tracking — the Save button enables only when the form is
// ready to submit. Two semantics:
//     (the task doesn't exist yet so there's nothing to compare to).
const isDirty = computed<boolean>(() => {
  if (isCreateMode.value) return isValid.value
  if (!props.task) return false
  const nameChanged = name.value.trim() !== props.task.name
  const descChanged = description.value !== (props.task.description ?? '')
  // Migration 067 — tags dirty check. Compare arrays via JSON.stringify (cheap for ≤ 30 tags).
  // Stable order matters: the chip input preserves the user's add order, but if the backend ever
  // returns a different order, the dialog will treat the row as "dirty" and push a no-op update.
  const tagsBefore = props.task.tags ?? []
  const tagsAfter = tags.value
  const tagsEqual =
    tagsBefore.length === tagsAfter.length && tagsBefore.every((t, i) => t === tagsAfter[i])
  const tagsChanged = !tagsEqual
  // Dependencies dirty check (same order-sensitive compare).
  const depsBefore = props.task.depends_on ?? []
  const depsAfter = dependsOn.value
  const depsChanged =
    depsBefore.length !== depsAfter.length || depsBefore.some((d, i) => d !== depsAfter[i])
  return nameChanged || descChanged || tagsChanged || depsChanged
})

const isValid = computed<boolean>(() => name.value.trim().length > 0)
const canSave = computed<boolean>(() => isDirty.value && isValid.value)

// "Create task & run agent" requires only a name (description is
// optional — empty description degrades to a queued message that is
// just the title). The unattended toggle flows through separately.
const canRunAgent = computed<boolean>(() => isValid.value)


// In-flight gate for the create-mode commit controls. While the host's create request is in flight
// (`creating` prop true) every commit control is disabled.
const isCreating = computed<boolean>(() => props.creating === true)
const canCommitCreate = computed<boolean>(() => !isCreating.value && isValid.value)


const pendingCommitLabel = computed<string | null>(() => {
  if (!isCreating.value) return null
  return pendingAction.value === 'create_and_run' ? 'Starting…' : 'Creating…'
})


// Inject the processingState map (provided by App.vue; populated via SSE worker events). The Start
// agent menu item is `:disabled` when a worker is already running for this task's session.
const processingState = inject<Record<string, boolean> | undefined>('processingState', undefined)
const isWorkerRunning = computed<boolean>(() => {
  if (!props.task?.id) return false
  return processingState?.[props.task.id] === true
})


// One line wide however many skills are on: the first pick, then a count.
const skillLabel = computed<string>(() => {
  const picked = selectedSkills.value
  const first = picked[0]
  if (first === undefined) return 'None'
  return picked.length === 1 ? first : `${first} +${picked.length - 1}`
})

const selectedSkillCount = computed<number>(() => selectedSkills.value.length)

// The dropdown rows: a case-insensitive match on the name or the description.
// Picked skills stay listed (checked) so an untick is one click away.
const filteredSkills = computed<SkillEntry[]>(() => {
  const q = skillSearch.value.trim().toLowerCase()
  if (q === '') return availableSkills.value
  return availableSkills.value.filter(
    (sk) => sk.name.toLowerCase().includes(q) || sk.description.toLowerCase().includes(q),
  )
})


// ─── Metadata helpers ───────────────────────────────────────────────────
const taskTypeLabel = computed<string | null>(() => {
  const t = props.task?.task_type
  if (t === 'memory') return 'Memory'
  return null // 'standard' and undefined both show no badge
})

const columnLabel = computed<string | null>(() => {
  return props.column?.name ?? null
})

// NEW (Task 2.7): Filter the suggestions composable's tags down to the names that are NOT already
// on the current task's draft chips. The model can't know about an unsaved draft, so we hide
// already-committed chips client-side.
const filteredTagSuggestions = computed<string[]>(() => {
  const excludeLower = new Set(tags.value.map((t) => t.toLowerCase()))
  return tagSuggestions.tags.value
    .map((s) => s.name)
    .filter((n) => !excludeLower.has(n.toLowerCase()))
})

// NEW (kanban task dependencies). Picker candidates: same-board tasks as {id, name} pairs (the
// picker filters out self via selfTaskId). Incomplete dep ids mark blocked chips distinctly.
const dependsCandidates = computed<Array<{ id: string; name: string }>>(() =>
  (props.tasks ?? []).map((t) => ({ id: t.id, name: t.name })),
)
const blockedDepIds = computed<string[]>(() => (props.task?.blocked_by ?? []).map((b) => b.task_id))


// NEW (Migration 069 — kanban image urls column). The dialog's image gallery reads from the task
// row's `imageUrls` array. In edit mode this is the persisted column (loaded via the store's
// normalizeTaskTags from the `||`-joined wire string).
const imageUrls = computed<string[]>(() => props.task?.imageUrls ?? [])
// Media-flags change — async lazy media: flags true but arrays still empty means the background
// fetchTaskMedia hasn't resolved yet. Shows a lightweight loading hint instead of a blank gap.
// Non-blocking: the fetch runs fire-and-forget via `void` (see openDialog above).
const isMediaLoading = computed<boolean>(() => {
  const t = props.task
  if (!t || isCreateMode.value) return false
  if ((t.imageUrls?.length ?? 0) > 0 || (t.videoUrls?.length ?? 0) > 0) return false
  return t.is_have_image === true || t.is_have_video === true
})

  return {
    isCreateMode,
    name,
    description,
    unattended,
    useGitWorktree,
    homeDir,
    worktreePath,
    worktreeBaseBranch,
    tags,
    dependsOn,
    tagsInputRef,
    descriptionEditorRef,
    selectedAgent,
    isAgentPickerOpen,
    availableAgents,
    agentsLoading,
    selectedSkills,
    skillSearch,
    isSkillPickerOpen,
    availableSkills,
    skillsLoading,
    selectedColumnId,
    isColumnPickerOpen,
    columnPickerRef,
    cwdSession,
    isCwdPickerOpen,
    cwdPickerRef,
    pendingAction,
    previewFilePath,
    imagePopupUrl,
    isDirty,
    isValid,
    canSave,
    canRunAgent,
    isCreating,
    canCommitCreate,
    pendingCommitLabel,
    isWorkerRunning,
    skillLabel,
    selectedSkillCount,
    filteredSkills,
    taskTypeLabel,
    columnLabel,
    filteredTagSuggestions,
    dependsCandidates,
    blockedDepIds,
    imageUrls,
    isMediaLoading,
    resolveWorktreeDir,
    expandWorktreePath,
    slugifyWorktreeName,
    setTagsInputEl,
    setDescriptionEditorEl,
    setColumnPickerEl,
    setCwdPickerEl,
  }
}

export type TaskDetailState = ReturnType<typeof useTaskDetailState>
