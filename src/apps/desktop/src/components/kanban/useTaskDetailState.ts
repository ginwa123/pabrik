/** Reactive state and derived values for the KanbanTaskDetail panel. */
import { computed, inject, ref } from 'vue'
import {
  browserSkillDefaultsStorage,
  readSkillDefaults,
  resolveDefaultSkills,
  skillDefaultsKey as skillDefaultsStorageKey,
  writeSkillDefaults,
} from '../../helpers/kanbanSkillDefaults'
import type { PreviewFile } from '../file/FilePreview.vue'
import type { MergeMethod } from '../../helpers/mergeWording'
import type {
  AgentEntry,
  SkillEntry,
  TaskDetailProps,
  TaskTagSuggestions,
} from './kanbanTaskDetailTypes'

export function useTaskDetailState(props: TaskDetailProps, tagSuggestions: TaskTagSuggestions) {
// True when the dialog is rendering the create flow (rather than edit-in-place).
const isCreateMode = computed<boolean>(() => props.mode === 'create')

// ─── Form state ──────────────────────────────────────────────────────────
const name = ref('')
const description = ref('')
const unattended = ref<'0' | '1'>('1')
// "Use git worktree" toggle (create mode only, default OFF).
const useGitWorktree = ref(false)
// Worktree path input (create mode only, visible when the toggle is ON).
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
// Base ref the new worktree branches FROM (create mode only, visible when the toggle is ON).
const worktreeBaseBranch = ref('')
// "Auto merge" toggle (create mode only, default OFF).
const autoMerge = ref(false)
const autoMergeMethod = ref<MergeMethod>('squash')
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
// NEW (kanban task dependencies).
const dependsOn = ref<string[]>([])
// Template ref for the chip input — handleSave calls commitDraft() imperatively before reading `tags.value` so a draft tag typed but not yet committed …
const tagsInputRef = ref<{ commitDraft: () => void } | null>(null)
// Template ref for the description editor — used in CREATE MODE to read the staged image files (pendingFiles) so the dialog can hand them to the host's …
const descriptionEditorRef = ref<{ pendingFiles: PreviewFile[] } | null>(null)

const selectedAgent = ref('')
const isAgentPickerOpen = ref(false)
const availableAgents = ref<AgentEntry[]>([])
const agentsLoading = ref(false)


// Skills picker (create only, Migration 112).
const selectedSkills = ref<string[]>([])
const skillSearch = ref('')
const isSkillPickerOpen = ref(false)
const availableSkills = ref<SkillEntry[]>([])
const skillsLoading = ref(false)
// True once the human touched the picker in this dialog session.
const skillsUserEdited = ref(false)

const skillDefaultsKey = (): string =>
  skillDefaultsStorageKey(props.workspaceId ?? '', props.column?.workspace_item_id ?? '')

const savedSkillDefaults = (): string[] =>
  readSkillDefaults(browserSkillDefaultsStorage(), skillDefaultsKey())

const rememberSkills = (names: string[]): void => {
  skillsUserEdited.value = true
  writeSkillDefaults(browserSkillDefaultsStorage(), skillDefaultsKey(), names)
}

const resetSkillsEdited = (): void => {
  skillsUserEdited.value = false
}

const prefillSkillsIfUntouched = (availableNames: string[]): void => {
  if (skillsUserEdited.value) return
  selectedSkills.value = resolveDefaultSkills(savedSkillDefaults(), availableNames)
}


// NEW (plan: 2026-08-06-kanban-add-task-button-placement).
const selectedColumnId = ref<string | null>(props.column?.id ?? null)
const isColumnPickerOpen = ref(false)
const columnPickerRef = ref<HTMLElement | null>(null)


// NEW (Migration 070 — kanban-cwd-session-optional plan).
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

// Which commit the user actually pressed.
const pendingAction = ref<'create' | 'create_and_run' | null>(null)

// File preview modal state.
const previewFilePath = ref<string | null>(null)
// Persisted-image gallery preview.
const imagePopupUrl = ref<string | null>(null)

// Dirty tracking — the Save button enables only when the form is ready to submit.
const isDirty = computed<boolean>(() => {
  if (isCreateMode.value) return isValid.value
  if (!props.task) return false
  const nameChanged = name.value.trim() !== props.task.name
  const descChanged = description.value !== (props.task.description ?? '')
  // Migration 067 — tags dirty check.
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

// "Create task & run agent" requires only a name (description is optional — empty description degrades to a queued message that is just the title).
const canRunAgent = computed<boolean>(() => isValid.value)


// In-flight gate for the create-mode commit controls.
const isCreating = computed<boolean>(() => props.creating === true)
const canCommitCreate = computed<boolean>(() => !isCreating.value && isValid.value)


const pendingCommitLabel = computed<string | null>(() => {
  if (!isCreating.value) return null
  return pendingAction.value === 'create_and_run' ? 'Starting…' : 'Creating…'
})


// Inject the processingState map (provided by App.vue; populated via SSE worker events).
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

// NEW (Task 2.7): Filter the suggestions composable's tags down to the names that are NOT already on the current task's draft chips.
const filteredTagSuggestions = computed<string[]>(() => {
  const excludeLower = new Set(tags.value.map((t) => t.toLowerCase()))
  return tagSuggestions.tags.value
    .map((s) => s.name)
    .filter((n) => !excludeLower.has(n.toLowerCase()))
})

// NEW (kanban task dependencies).
const dependsCandidates = computed<Array<{ id: string; name: string }>>(() =>
  (props.tasks ?? []).map((t) => ({ id: t.id, name: t.name })),
)
const blockedDepIds = computed<string[]>(() => (props.task?.blocked_by ?? []).map((b) => b.task_id))


// NEW (Migration 069 — kanban image urls column).
const imageUrls = computed<string[]>(() => props.task?.imageUrls ?? [])
// Media-flags change — async lazy media: flags true but arrays still empty means the background fetchTaskMedia hasn't resolved yet.
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
    autoMerge,
    autoMergeMethod,
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
    skillsUserEdited,
    rememberSkills,
    resetSkillsEdited,
    prefillSkillsIfUntouched,
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
