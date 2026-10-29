<!--
  KanbanTaskDetail — focused, edit-in-place task detail view
  rendered INLINE in KanbanView's side panel (no Teleport modal,
  no backdrop). Refactored from KanbanTaskDetailDialog so the
  board stays visible next to the form.

  Layout (top → bottom):
    1. Header — "Task details" title + close button.
    2. Task name — large, editable input. Full width.
    3. Metadata strip (read-only) — column name, task type, pinned
       indicator, timestamps. Hidden when no metadata is available.
    4. Description label.
    5. Description textarea — large (rows=10 vs AddTaskDialog's 3),
       full width, monospace-friendly font (matches the existing
       AddTaskDialog / AddKanbanDialog description textarea).
    6. Save / Cancel buttons at the bottom right. Save is disabled
       when the form is clean (no changes) or the name is empty
       after trim.

  Unattended-mode toggle (edit mode only, below the description):
    A right-aligned switch that flips the session's
    `is_auto_retry_until_stop` flag (which lives on the sessions
    table, not workspace_item_tasks, so the host must call
    `api.updateSession` to persist it). The flag persists IMMEDIATELY
    on flip — independent of the Save button — matching iOS-style
    toggle UX (a switch should not need an explicit Save click to
    take effect). On toggle, the dialog emits `update-unattended`
    with the new value ('0' or '1') and the host persists via
    `api.updateSession(task.id, { isAutoRetryUntilStop })`. On
    toggle failure, the dialog rolls back its local state to the
    previous value (passed back via `update-unattended-error`) and
    shows a short-lived errorMessage.

  ▶ Start agent button (edit mode only, in the actions row):
    Outlined secondary button between Cancel and Save. Mirrors the
    create-mode ▶ Create task & run agent button. Clicking triggers
    the LLM worker on the existing session via the new
    POST /api/.../tasks/:task_id/start_agent endpoint — no
    queue_message is sent. Disabled when a worker is already
    running for this task's session (the frontend's best-effort
    check; the backend's atomic DB lookup is the source of truth).

  Public API:
    props:
      show          boolean
      mode          'edit' | 'create'  (default: 'edit')
      task          Task | null
                              edit mode: required (the task to edit)
                              create mode: ignored — form starts empty
      column        KanbanColumn | null  (optional — shown in metadata strip;
                              required in create mode so the parent knows
                              where to place the new task)
      errorMessage  string | null  (optional — shows a red banner in the
                              body when set; typically bound to a save
                              handler's catch-block error)
    emits:
      close      []
      save       [{ mode: 'edit', name, description }]
                Emitted when the user clicks Save in edit mode. The host
                calls workspacesStore.updateTaskDetails(...) and closes
                the dialog on success.
      create     [{ mode: 'create', name, description }]
                Emitted when the user clicks Create task in create mode.
                The host calls workspacesStore.addTask(...) +
                moveTaskToColumn(...) to persist the new task.
      update-unattended     [{ value: '0' | '1' }]
                Emitted in edit mode when the user flips the
                unattended-mode toggle. Host persists via
                `api.updateSession(task.id, { isAutoRetryUntilStop })`.
      update-unattended-error  [{ value: '0' | '1', error: Error }]
                Optional: if the host wants the dialog to roll back to
                a known-good value on PUT failure, it can re-bind the
                prop / emit back through the same component (we do not
                handle rollback internally — the host owns it).

  This dialog is purely presentational — no API calls, no store
  reads. The host (AppLayout / KanbanView) owns the "open + for which
  task / in which column" state and wires the emits to store actions.

  Pattern source: KanbanSettingsDialog.vue — Teleport to body,
  max-height 70vh, transition + backdrop, semantic CSS variables
  for theme compatibility.
-->
<script setup lang="ts">
import {
  computed,
  nextTick,
  onBeforeUnmount,
  onMounted,
  onUnmounted,
  onUpdated,
  provide,
  ref,
} from 'vue'
import type { KanbanColumn, Task } from '../../stores/workspaces'
import { useWorkspacesStore } from '../../stores/workspaces'
import { useKanbanTagSuggestions } from '../../composables/useKanbanTagSuggestions'
import * as api from '../../api'
import { getSystemFolder } from '../../api'
import TaskDetailActions from './TaskDetailActions.vue'
import TaskDetailFields from './TaskDetailFields.vue'
import TaskDetailHeader from './TaskDetailHeader.vue'
import TaskDetailPreviews from './TaskDetailPreviews.vue'
import TaskDetailSidePanel from './TaskDetailSidePanel.vue'
import { TASK_DETAIL_KEY } from './kanbanTaskDetailContext'
import type { TaskDetailContext, TaskDetailEmits, TaskDetailProps } from './kanbanTaskDetailTypes'
import { useTaskDetailActions } from './useTaskDetailActions'
import { useTaskDetailState } from './useTaskDetailState'

const props = withDefaults(defineProps<TaskDetailProps>(), {
  mode: 'edit',
  column: null,
  errorMessage: null,
  cwd: '',
  workspaceId: '',
  availableColumns: (): KanbanColumn[] => [],
  tasks: (): Task[] => [],
  creating: false,
})

// ─── Tag suggestions composable (Task 2.7) ───────────────────────────── Lazily fetches distinct
// tags from other tasks on this kanban for the autocomplete dropdown in <KanbanTagsInput>.
const tagSuggestions = useKanbanTagSuggestions(
  computed(() => props.workspaceId ?? ''),
  computed(() => props.column?.workspace_item_id ?? ''),
)

const emit = defineEmits<TaskDetailEmits>()

const state = useTaskDetailState(props, tagSuggestions)
const actions = useTaskDetailActions(props, emit, state)
const cwd = computed<string>(() => props.cwd ?? '')

const {
  agentsLoading,
  availableAgents,
  availableSkills,
  cwdSession,
  dependsOn,
  description,
  homeDir,
  isCreateMode,
  isSkillPickerOpen,
  name,
  pendingAction,
  selectedAgent,
  selectedColumnId,
  selectedSkills,
  skillSearch,
  skillsLoading,
  tags,
  unattended,
  useGitWorktree,
  worktreeBaseBranch,
  worktreePath,
} = state

const {
  handleDocumentClickColumn,
  handleDocumentClickCwd,
  handleEnterKey,
  handleImagePopupKeydown,
  handleKeydown,
  selectCwd,
} = actions

provide(TASK_DETAIL_KEY, {
  props,
  emit,
  tagSuggestions,
  cwd,
  ...state,
  ...actions,
} as TaskDetailContext)

const nameInput = ref<HTMLInputElement | null>(null)
// Resolve $HOME for the worktree prefill. Called on create-mode open;
// failure leaves homeDir empty so the prefill falls back to `~` display
// and expandWorktreePath becomes a trim-only passthrough.
const loadHomeDir = async () => {
  if (homeDir.value !== '') return
  try {
    const info = await getSystemFolder()
    if (info?.home?.trim()) homeDir.value = info.home.trim()
  } catch {
    // Offline / backend down — keep the `~` fallback.
  }
}

// Plan 2026-08-06-kanban-task-profile-selector. Load the agents this workspace can actually RUN
// with (mirrors ChatView.loadAgents). Called on dialog open in create mode; failure -> empty list
// (the picker still works, just only shows "Default").
const loadAgents = async () => {
  if (!isCreateMode.value) return
  agentsLoading.value = true
  try {
    const wsId = props.workspaceId ?? ''
    const config = wsId ? await api.getWorkspaceConfig(wsId) : await api.getPabrikConfig()
    const agents = (config.profiles ?? {}) as Record<
      string,
      { model?: string; base_url?: string; enabled?: boolean }
    >
    availableAgents.value = Object.entries(agents)
      .filter(([, p]) => p.enabled !== false)
      .map(([name, p]) => ({
        name,
        model: p.model ?? '',
        base_url: p.base_url ?? '',
      }))
  } catch (err) {
    console.error('Failed to load agents:', err)
    availableAgents.value = []
  } finally {
    agentsLoading.value = false
  }
}

const loadSkills = async () => {
  if (!isCreateMode.value) return
  skillsLoading.value = true
  try {
    const wsId = props.workspaceId ?? ''
    if (wsId === '') {
      availableSkills.value = []
      return
    }
    const res = await api.getSkills(wsId)
    availableSkills.value = (res.skills ?? []).map((sk) => ({
      name: sk.name,
      description: sk.description ?? '',
    }))
    // eslint-disable-next-line local/no-try-catch -- mirrors loadAgents directly above: a failed fetch must degrade to an empty picker, not break the dialog
  } catch (err) {
    console.error('Failed to load skills:', err)
    availableSkills.value = []
  } finally {
    skillsLoading.value = false
  }
}

// Reset form whenever the dialog opens OR the target task changes. In create mode we always start
// blank (regardless of `task`). In edit mode we prefill from `task` (today's behavior). Runs from
// the mount/update open guard below instead of a watcher.
const openDialog = async (): Promise<void> => {
  // The commit split button narrates the in-flight action via pendingAction; clear any stale
  // attribution from the previous session here, in the open handler, instead of watching
  // isCreating.
  pendingAction.value = null
  if (isCreateMode.value) {
    name.value = ''
    description.value = ''
    unattended.value = '1'
    useGitWorktree.value = false
    worktreePath.value = ''
    worktreeBaseBranch.value = ''
    tags.value = [] // NEW: start with empty tags in create mode
    selectedAgent.value = '' // NEW: agent selector defaults to backend default
    selectedSkills.value = []
    skillSearch.value = ''
    isSkillPickerOpen.value = false
    // NEW (plan: 2026-08-14-kanban-task-detail-edit-cwd). Sync cwdSession from the parent kanban's
    // path on dialog open so the picker shows the kanban-level fallback by default. The legacy code
    // initialized from the ref literal (`ref<string>(props.cwd ??
    cwdSession.value = props.cwd ?? ''
  } else if (props.task) {
    name.value = props.task.name
    description.value = props.task.description ?? ''
    unattended.value = props.task.is_auto_retry_until_stop === '1' ? '1' : '0'
    // Migration 067 — prefill tags from the loaded task. tags?
    // is optional (legacy tasks may lack it); fallback to [].
    tags.value = props.task.tags ?? []
    // Dependencies prefill (same optional + fallback pattern).
    dependsOn.value = props.task.depends_on ? [...props.task.depends_on] : []
    // NEW (plan: 2026-08-14-kanban-task-detail-edit-cwd). Sync the per-task cwd picker with the
    // task's persisted cwd in edit mode. Equivalent to the create-mode `cwdSession.value =
    // props.cwd ?? ''` for create, but reads the task row.
    cwdSession.value = props.task.cwd ?? ''
    // Media-flags change — list/get carry only `is_have_image` / `is_have_video` flags.
    if (props.task?.id) {
      const t = props.task
      const needMedia =
        (t.is_have_image === true && (!t.imageUrls || t.imageUrls.length === 0)) ||
        (t.is_have_video === true && (!t.videoUrls || t.videoUrls.length === 0))
      if (needMedia && props.workspaceId && props.column?.workspace_item_id) {
        void useWorkspacesStore().fetchTaskMedia(
          props.workspaceId,
          props.column.workspace_item_id,
          t.id,
        )
      }
    }
  }
  await nextTick()
  nameInput.value?.focus()
  // Selecting the text is only useful in edit mode (so a rename
  // is a single keystroke). In create mode the input is empty —
  // `select()` is a no-op but skipping it removes a code-smell.
  if (!isCreateMode.value) nameInput.value?.select()
  // NEW (Task 2.7): reset the suggestions composable + start a lazy load. Reset clears any state
  // from the previous dialog session so a different kanban (or a fresh open of the same one)
  // doesn't see stale suggestions from the previous task.
  tagSuggestions.reset()
  // Don't await — let the fetch happen in the background. The dropdown only opens when the user
  // focuses the input, which is itself a separate trigger; awaiting here would block the focus call
  // on a network round-trip for no benefit.
  if (props.workspaceId) {
    void tagSuggestions.ensureLoaded()
  }
  // NEW (plan: 2026-08-06-kanban-task-profile-selector). Fetch agents for the picker in create
  // mode. Same fire-and-forget pattern as tagSuggestions — the dropdown only opens when the user
  // clicks it.
  if (isCreateMode.value) {
    void loadAgents()
    void loadHomeDir()
    void loadSkills()
  }
  // Sync selectedColumnId from the parent's `column` prop on open
  // (create mode only). Re-assigning the same id is a no-op, so the
  // host round-trip in scenario (b) stays loop-free.
  if (isCreateMode.value) {
    selectedColumnId.value = props.column?.id ?? null
  }
}

// Open guard: run the open handler on mount-with-show plus any update
// that changes show, the target task, the mode, or the column.
const prevOpenKey = ref('')
const openKey = () =>
  `${props.show ? '1' : '0'}|${props.task?.id ?? ''}|${props.mode}|${props.column?.id ?? ''}`
onMounted(() => {
  prevOpenKey.value = openKey()
  if (props.show) void openDialog()
})
onUpdated(() => {
  const key = openKey()
  if (key !== prevOpenKey.value) {
    prevOpenKey.value = key
    if (props.show) void openDialog()
  }
})

onMounted(() => document.addEventListener('keydown', handleImagePopupKeydown))
onBeforeUnmount(() => document.removeEventListener('keydown', handleImagePopupKeydown))

// NEW (plan: 2026-08-06-kanban-add-task-button-placement). Register the click-outside listener for
// the column picker at mount, deregister at unmount.
onMounted(() => {
  document.addEventListener('click', handleDocumentClickColumn)
  // NEW (Migration 070 — kanban-cwd-session-optional plan). Same
  // pattern for the per-task cwd picker.
  document.addEventListener('mousedown', handleDocumentClickCwd)
})
onUnmounted(() => {
  document.removeEventListener('click', handleDocumentClickColumn)
  document.removeEventListener('mousedown', handleDocumentClickCwd)
})

// Exposed for tests (and the deprecated Dialog wrapper below,
// which delegates its own selectCwd to the inner panel).
defineExpose({ selectCwd })
</script>

<template>
  <div
    v-if="show && (task || isCreateMode)"
    class="kanban-task-detail flex min-h-0 w-full flex-1 flex-col"
    style="
      background-color: var(--semantic-card-bg);
      border: 1px solid var(--color-border);
      border-radius: 12px;
    "
    @keydown="handleKeydown"
    :aria-labelledby="isCreateMode ? 'kanban-task-detail-create-title' : 'kanban-task-detail-title'"
    data-testid="kanban-task-detail-dialog"
    data-kanban-task-detail
  >
    <!-- Inline panel Card. The host (KanbanView) controls the width
         via its full-cover view — no Teleport / backdrop / fixed
         positioning here. Header + actions are sticky so they stay
         reachable while the host container scrolls. -->
    <!-- Header — sticky so Back/Close stay reachable on long
         forms (the host cover container scrolls, not this card). -->
    <TaskDetailHeader />

    <!-- NEW (plan: 2026-08-19-kanban-error-banner-on-front).
               Error banner. Lifted OUT of the scrollable body so it
               stays permanently visible — even when the user scrolls
               down through the form fields (which used to push the
               banner off-screen, making it look like it was 'in the
               back of the dialog'). It is now a sibling of header /
               body / actions inside the dialog card, with shrink-0 so
               the flex column doesn't collapse it, and explicit
               `position: relative; z-index: 10` so it always renders
               above any descendant stacking context inside the body
               (e.g. the dropdowns in KanbanTagsInput which have
               z-50 on their dropdowns). The host sets errorMessage
               on a save/create/start-agent handler failure so the
               user can retry without losing their typed content
               (the form is NOT reset on error — only on a successful
               submit, via the open guard's `show` change). -->
    <div
      v-if="errorMessage"
      class="shrink-0 px-5 py-3 text-body"
      style="
        background-color: rgba(239, 68, 68, 0.12);
        border-bottom: 1px solid var(--color-border);
        color: rgb(220, 38, 38);
        position: relative;
        z-index: 10;
      "
      role="alert"
      data-testid="kanban-task-detail-error"
    >
      <div class="px-3 py-2 rounded-lg" style="border: 1px solid rgba(239, 68, 68, 0.4)">
        {{ errorMessage }}
      </div>
    </div>
    <!-- Body (scrollable). Reduced top padding to pt-4 (16px) — the
               header already has pb-4 below it, so adding py-4 would have
               stacked 32px of empty space between header text and the
               first form field. pt-4 keeps a clean rhythm without the
               dead air. -->
    <div class="flex-1 overflow-y-auto min-h-0 px-5 pt-4 pb-4">
      <div class="ktd-grid">
        <div class="ktd-main">
          <div class="mb-5">
            <label
              for="kanban-task-detail-name"
              class="block text-dense font-medium mb-2"
              style="color: var(--semantic-text-muted)"
            >
              Task name
            </label>
            <input
              id="kanban-task-detail-name"
              ref="nameInput"
              v-model="name"
              type="text"
              placeholder="Enter task name…"
              :data-testid="
                isCreateMode ? 'kanban-task-detail-create-name' : 'kanban-task-detail-name'
              "
              class="ktd-title w-full outline-none"
              @keyup.enter="handleEnterKey"
            />
          </div>
          <TaskDetailFields />
        </div>
        <TaskDetailSidePanel />
      </div>
    </div>
    <TaskDetailActions />
  </div>
  <TaskDetailPreviews />
</template>

<style scoped>
.ktd-grid {
  display: grid;
  grid-template-columns: minmax(0, 1fr) minmax(320px, 24%);
  gap: 24px;
  align-items: start;
}


.ktd-main > * {
  max-width: 1000px;
}


.ktd-title {
  font-size: var(--text-title);
  font-weight: 600;
  color: var(--semantic-text);
  padding: 2px 0 8px;
  border-bottom: 1px solid var(--color-border);
  background-color: transparent;
}


@media (max-width: 1023px) {
  .ktd-grid {
    grid-template-columns: minmax(0, 1fr);
  }
}

</style>
