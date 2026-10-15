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
    Plan: docs/superpowers/specs/2026-08-18-kanban-task-detail-start-agent.md

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
  ref,
  computed,
  nextTick,
  onMounted,
  onBeforeUnmount,
  onUnmounted,
  onUpdated,
  inject,
} from 'vue'
import type { Task, KanbanColumn } from '../../stores/workspaces'
import { useWorkspacesStore } from '../../stores/workspaces'
import { useKanbanTagSuggestions } from '../../composables/useKanbanTagSuggestions'
import KanbanDescriptionEditor from './KanbanDescriptionEditor.vue'
import type { PreviewFile } from '../file/FilePreview.vue'
import KanbanTagsInput from './KanbanTagsInput.vue'
import FilePreviewModal from './FilePreviewModal.vue'
import * as api from '../../api'
import { getSystemFolder, listFolder, type FolderEntry } from '../../api'
import FilePickerDialog from '../FilePickerDialog.vue'
import GitBaseBranchSelect from './GitBaseBranchSelect.vue'
import UiIcon from '../ui/UiIcon.vue'
import WorkerElapsedChip from '../WorkerElapsedChip.vue'

const props = withDefaults(
  defineProps<{
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
    // NEW (plan: 2026-08-06-kanban-add-task-button-placement). The
    // available columns for the create-mode column dropdown. Empty
    // array = no dropdown rendered (legacy callers, edit mode, or
    // kanbans that haven't loaded columns yet). Edit mode passes
    // empty. The host (KanbanView) passes `sortedColumns` from the
    // active kanban.
    availableColumns?: KanbanColumn[]
    // NEW (plan: 2026-08-24-kanban-create-run-disable-double-click).
    // True while the host's create request is in flight. Disables
    // BOTH create-mode commit buttons ("Create task" and
    // "▶ Create task & run agent") and swaps their labels to
    // "Creating…" so a double-click can't emit `create` /
    // `create-and-run` twice and spawn duplicate tasks/agents.
    // Edit mode ignores it (the host only binds it on the
    // create-mode mount).
    creating?: boolean
  }>(),
  {
    mode: 'edit',
    column: null,
    errorMessage: null,
    cwd: '',
    workspaceId: '',
    availableColumns: (): KanbanColumn[] => [],
    creating: false,
  },
)

// ─── Tag suggestions composable (Task 2.7) ─────────────────────────────
// Lazily fetches distinct tags from other tasks on this kanban for
// the autocomplete dropdown in <KanbanTagsInput>. The composable's
// internal `loaded`/`hasMore`/`loading` refs drive the dropdown
// gating — calls to ensureLoaded() on dialog open, and loadNextPage()
// from the IntersectionObserver on the input's scroll sentinel.
// The composable handles empty workspaceId / empty itemId gracefully
// (no fetch attempted), so we can pass the fallbacks unconditionally
// without conditional wiring. We source the item id from the column
// prop (which carries the parent kanban's workspace_item_id) —
// Task itself doesn't carry workspace_item_id, but every active task
// in the kanban is reachable via column.workspace_item_id. Pass
// refs (not raw strings) so the composable can react when the
// column becomes available — earlier we passed raw strings and
// the composable was permanently bound to empty IDs when the
// dialog opened before column was resolved.
const tagSuggestions = useKanbanTagSuggestions(
  computed(() => props.workspaceId ?? ''),
  computed(() => props.column?.workspace_item_id ?? ''),
)

const emit = defineEmits<{
  // v-model:show two-way binding — emits `false` when the dialog wants to close (X button, Cancel
  // button, backdrop click, Escape key). Parent uses `v-model:show` so this is what makes the
  // dialog actually close.
  'update:show': [value: boolean]
  // Explicit close event for parents that bind `:show` (one-way) and listen for `@close` to flip
  // their own ref. Kept for backward compatibility with the existing test suite and for the
  // KanbanSettingsDialog-style pattern.
  close: []
  save: [payload: { mode: 'edit'; name: string; description: string; tags: string[] }]
  // Create-mode counterpart. Host wires this to workspacesStore.addTask
  // + moveTaskToColumn. Same payload shape as `save` but with
  // mode='create' so the parent handler can switch on it.
  create: [
    payload: {
      mode: 'create'
      name: string
      description: string
      // Auto-retry-until-stop (Option A): the toggle's live value
      // at the moment of Create. `'1'` (default — feature on)
      // is forwarded too so the host can pass it through to
      // api.createTask; the helper filters out `'0'` so the backend
      // only inserts a sessions row when the user actually opted in.
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
      // NEW (plan: 2026-08-06-kanban-task-profile-selector). Selected
      // profile-model name (empty string = backend default / top-level
      // config). Forwarded to the host for both `create` and
      // `create-and-run`; Path A only threads it through to the
      // backend when the user clicks "Create task & run agent".
      selectedProfile: string
      // NEW (plan: 2026-08-06-kanban-no-base64-in-desc). Files the
      // dialog's editor staged in create mode (no base64 ever written
      // into `description`). Always present — empty array when no
      // images were pasted/picked. Host uploads each via
      // `api.uploadTaskAttachment(taskId, file)` AFTER addTask
      // returns the new taskId, then patches the description with
      // `![name](<url>)` markdown via `updateTaskDetails`.
      pendingFiles: PreviewFile[]
      // NEW (Migration 070 — kanban-cwd-session-optional plan).
      // Per-task cwd override. Absolute path on disk or '' for
      // cwd-less. Empty string is the canonical "no per-task cwd"
      // sentinel — the backend stores '' and the session_create
      // 3-level fallback chain falls back to the kanban's path +
      // the per-session sandbox. The dialog's folder picker
      // (NEW) populates this field; skipped / picker-canceled
      // leaves it as ''. Plan:
      // docs/superpowers/plans/2026-08-06-kanban-cwd-session-optional.md
      cwdSession?: string
    },
  ]
  // Emitted in edit mode when the user flips the unattended toggle.
  // The host persists via api.updateSession(task.id, { isAutoRetryUntilStop }).
  // value is '1' when toggled ON, '0' when toggled OFF. Emitted
  // BEFORE the optimistic UI flip so the host can capture the
  // pre-toggle value (in case it needs to roll back on PUT failure).
  'update-unattended': [payload: { value: '0' | '1'; previous: '0' | '1' }]
  // NEW (plan: 2026-08-06-kanban-create-task-run-agent). Emitted
  // when the user clicks "Create task & run agent" in create mode.
  // Same payload shape as `create` but with mode='create_and_run'
  // so the host can branch on it. The host (KanbanView) handles
  // the create + move + run + navigate dance.
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
      // Threaded through to runAgentOnNewTask so the agent runs with the chosen profile.
      selectedProfile: string
      // NEW (plan: 2026-08-06-kanban-no-base64-in-desc). Mirror of
      // the `pendingFiles` field on the `create` emit above.
      pendingFiles: PreviewFile[]
      // NEW (Migration 070 — kanban-cwd-session-optional plan).
      // Mirror of the `cwdSession` field on the `create` emit
      // above. The dialog's folder picker populates this in both
      // create and create-and-run modes; the host threads it into
      // runAgentOnNewTask's `cwd` (overriding the kanban-level path
      // + sandbox fallback).
      cwdSession?: string
    },
  ]
  // NEW (plan: 2026-08-06-kanban-add-task-button-placement). Create
  // mode only. Fires when the user picks a different column from the
  // create-mode dropdown. The parent (KanbanView) updates its
  // `activeCreateColumnId` so the final `moveTaskToColumn` on submit
  // puts the new task in the chosen column. Edit mode does not emit
  // this event — the task is already in a column, and migrating an
  // existing task to a new column is out of scope.
  'column-change': [columnId: string]
  // NEW (plan: 2026-08-14-kanban-task-detail-edit-cwd). Edit mode
  // only. Fires when the user picks a different cwd from the picker
  // in edit mode. The host persists immediately via
  // `api.updateTaskSimple(task.id, { cwd })`, matching the
  // `update-unattended` immediate-save UX (iOS-style — no Save click
  // required). In create mode the cwd selection is forwarded via the
  // `create` / `create-and-run` emit's `cwdSession` field instead, so
  // this emit is only meaningful in edit mode.
  'update-cwd': [payload: { cwd: string }]
  // NEW (plan: 2026-08-18-kanban-task-detail-start-agent). Edit
  // mode only. Fires when the user clicks the ▶ Start agent
  // button. The host calls `workspacesStore.startAgentOnTask(...)`
  // which POSTs to the new backend endpoint; the agent runs on the
  // existing chat history without queueing a new user message.
  // The button is `:disabled` while `processingState[task.id]`
  // is true, so this emit only fires when no worker is in flight.
  'start-agent': [payload: { taskId: string }]
}>()

// ─── Form state ──────────────────────────────────────────────────────────

const name = ref('')
const description = ref('')
const unattended = ref<'0' | '1'>('1')
// "Use git worktree" toggle (create mode only, default OFF). When ON,
// the host bakes `#Notes UseGitWorktree` into the create_and_run
// queue_message. Plain create ignores it (no queue_message there).
const useGitWorktree = ref(false)
// Worktree path input (create mode only, visible when the toggle is
// ON). Canonical root is $HOME/.config/pabrik/.worktrees (Option A) —
// prefilled on toggle-on as <slug>-<timestamp> from the task name plus
// Date.now() so concurrent tasks never collide; the user can accept or
// edit it. Empty = agent picks the path itself (bare `#Notes UseGitWorktree`).
// The prefill is always an absolute path: validatePath in
// set_git_worktree.zig rejects `~`-prefixed paths (not absolute), so a
// literal `~` would fail at tool-call time. Home is resolved via
// getSystemFolder().home; until loaded we fall back to `~` for display
// and expand on emit.
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
// Base ref the new worktree branches FROM (create mode only, visible when
// the toggle is ON). Empty = no `Base:` line in the queue_message, so the
// agent branches from the repo's current HEAD (the pre-existing behavior).
// The dropdown lists the repo's real refs (`GitBaseBranchSelect`) and
// lets the user name one the list does not show.
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
// Template ref for the chip input — handleSave calls commitDraft()
// imperatively before reading `tags.value` so a draft tag typed but
// not yet committed (Enter/comma not pressed) isn't dropped on Save.
// The component's @blur handler covers the normal case; this is the
// explicit "click Save without leaving the field" safety net.
const tagsInputRef = ref<{ commitDraft: () => void } | null>(null)
// Template ref for the description editor — used in CREATE MODE to read the staged image files
// (pendingFiles) so the dialog can hand them to the host's create-then-upload orchestrator. The
// editor exposes pendingFiles via defineExpose; see KanbanDescriptionEditor.vue for the contract.
const descriptionEditorRef = ref<{ pendingFiles: PreviewFile[] } | null>(null)
const nameInput = ref<HTMLInputElement | null>(null)
// Description is UNLIMITED (no maxlength) — the backend stores TEXT with no length check.
// The description is ALWAYS shown as the editor (textarea + paperclip +
// char counter). A "Preview" toggle used to flip to <MarkdownDescription>
// for a rendered view, but the toggle was removed per user feedback —
// the dialog stays focused on the editor. Image/file-paths in the
// description still render correctly when the task is viewed elsewhere
// (e.g. <WorkspaceItemTaskCard> on the kanban board, the chat view's
// task description render).
//
// (plan: 2026-08-06-kanban-no-base64-in-desc) — see also.

// NEW (plan: 2026-08-06-kanban-task-profile-selector). Profile-model picker state (create mode
// only). selectedProfile='' = backend default / "Default (top-level config)". Loaded from LlmConfig
// profiles; mirrors ChatView's picker pattern.
interface ProfileEntry {
  name: string
  model: string
  base_url: string
}
const selectedProfile = ref('')
const isProfilePickerOpen = ref(false)
const profilePickerRef = ref<HTMLElement | null>(null)
const availableProfiles = ref<ProfileEntry[]>([])
const profilesLoading = ref(false)

// NEW (plan: 2026-08-06-kanban-add-task-button-placement). Column
// dropdown state (create mode only). selectedColumnId mirrors the
// parent's `column` prop on dialog open; the picker emits
// `column-change` so the host updates its activeCreateColumnId in
// real-time. Click outside the picker closes it (mirrors the profile
// picker behaviour).
const selectedColumnId = ref<string | null>(props.column?.id ?? null)
const isColumnPickerOpen = ref(false)
const columnPickerRef = ref<HTMLElement | null>(null)
const toggleColumnPicker = () => {
  isColumnPickerOpen.value = !isColumnPickerOpen.value
}
const selectColumn = (id: string) => {
  selectedColumnId.value = id
  isColumnPickerOpen.value = false
  emit('column-change', id)
}

// NEW (Migration 070 — kanban-cwd-session-optional plan). Per-task
// cwd picker state (create mode only). Default: when the parent
// kanban has a path, pre-populate the picker with that path (the
// kanban's project root becomes the new task's per-task cwd by
// default; the user can change or skip). When the parent kanban is
// cwd-less, the picker starts empty.
//
// `cwdSession` is the per-task cwd we emit to the parent. Empty
// string = "no per-task cwd" (falls back to kanban-level path +
// sandbox). The picker writes the absolute path; the picker dialog's
// "cancel" / backdrop-close leaves it empty.
//
// Starts empty — populated lazily by openDialog() via the mount/update
// open guard below (openKey covers show, task id, and mode).
// Initializing from the ref literal
// (`ref<string>(props.cwd ?? '')`) used to work, but broke when the
// parent re-mounted the dialog with a different cwd (the ref would
// keep its first-mount value). The open guard handles BOTH initial
// mount AND re-mount correctly. Plan:
// docs/superpowers/plans/2026-08-14-kanban-task-detail-edit-cwd.md
const cwdSession = ref<string>('')
const isCwdPickerOpen = ref(false)
const cwdPickerRef = ref<HTMLElement | null>(null)
// Pre-populate from the parent kanban's `cwd` prop on dialog open.
// The parent (KanbanView) passes the kanban's `path` (kanban-level
// cwd) as this prop — when set, the new task's per-task cwd defaults
// to it (the user can change or skip). When the parent kanban is
// cwd-less, the picker starts empty.
//
// NEW (plan: 2026-08-14-kanban-task-detail-edit-cwd): in edit
// mode, pre-populate from `props.task?.cwd` instead — the task's
// persisted per-task cwd takes precedence over the kanban-level
// fallback so the picker reflects "where does THIS task run"
// rather than the kanban's project root.
//
// Initialized from the prop (NOT via the open guard below) so the picker
// has the right value on the very first render — without the
// initial-value read, the guard would need `show` to flip false→true to
// fire, which leaves the picker empty if the parent mounts the dialog
// with `show=true` on the first tick (same pattern as
// `selectedColumnId` above, which also initializes from its prop).
//
// NEW (plan: 2026-08-14-kanban-task-detail-edit-cwd). Edit mode
// initializer: when the dialog opens in edit mode, sync `cwdSession`
// from the task's persisted `cwd` field (empty string for
// cwd-less tasks, path for tasks with a per-task cwd set). Mirrors
// the create-mode pre-population from `props.cwd` (the parent
// kanban's path). Without this branch the picker would render the
// empty-state placeholder on every edit-mode dialog open, making
// "where does this task run?" an unanswerable question until the user
// clicked the picker.
//
// Implementation note: openDialog() via the openKey guard below
// handles the initial sync AND the rare "user clicks task A then
// task B with the dialog already open" re-sync — cwd re-syncs
// whenever show flips true OR the target task swaps.
// cwdSession sync lives in the open handler below (it sets the same
// values in both modes), so no separate show-only sync is needed.
const toggleCwdPicker = () => {
  isCwdPickerOpen.value = !isCwdPickerOpen.value
}
// NEW (plan: 2026-08-14-kanban-task-detail-edit-cwd). In edit mode
// the picker fires `update-cwd` so the host persists immediately
// (same iOS-style immediate-save UX as the unattended toggle). In
// create mode the cwd selection is captured in `cwdSession` and
// forwarded via the `create` / `create-and-run` emit's
// `cwdSession` field on Save — `update-cwd` is a no-op there
// because the task doesn't exist yet (no row to PATCH).
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
    // Allow the FilePickerDialog dropdown contents to escape the
    // ref's containment check. The picker teleports to <body> so
    // it isn't a DOM descendant of cwdPickerRef — without this
    // allow-list, any click inside the picker (including the Browse
    // tab and the search input) closes the dropdown immediately,
    // forcing the user to re-click the picker trigger to reopen
    // it. Plan: docs/superpowers/plans/2026-08-14-kanban-task-detail-edit-cwd.md
    !cwdPickerRef.value.contains(target) &&
    // Walk up from the click target to see if any ancestor is the teleported FilePickerDialog root.
    // The dialog root carries the `data-testid="file-picker-dialog"` testid, so we can match it
    // (and its Teleport-portal descendants) without touching the picker ref.
    !(target as Element | null)?.closest?.('[data-testid="file-picker-dialog"]')
  ) {
    // User intent: clicking outside the picker should NOT close it
    // by accident — the picker has explicit Cancel and Select affordances
    // for closing. The legacy close-on-outside-click behaviour caught
    // false positives every time the user clicked on the kanban column
    // body, another card, the dialog backdrop, etc. while the picker
    // was open (e.g. moving the mouse over to read context), forcing
    // them to reopen it. The new contract: once open, the picker stays
    // open until the user clicks the picker trigger again, selects a
    // folder, or presses Cancel/Select inside the FilePickerDialog.
    // (Backdrop click on the KanbanTaskDetailDialog itself still closes
    // the whole dialog, but that's a different handler at the dialog
    // root — see `@click.self="handleClose"` on the modal container.)
    // Plan: docs/superpowers/plans/2026-08-14-kanban-task-detail-edit-cwd.md
    return // no-op: explicitly do NOT close the picker on outside click
  }
}

// NEW (plan: 2026-08-06-kanban-folder-picker-style). Computed
// style object for the cwd picker button. The previous version used
// a static `style="..."` attribute with template expressions
// (`cwdSession ? ... : ...`) inline — Vue does NOT evaluate
// expressions inside static style attributes, so the resulting CSS
// was syntactically invalid and the browser silently dropped the
// `color` and `background-color` properties. The picker looked
// identical regardless of whether cwd was set. This computed is
// the proper `:style` binding so the conditional resolves correctly
// at render time. When cwd is set: bright text on the active-bg
// (clearly reads as "you picked something"). When cwd is empty:
// dim text on the sidebar-bg (clearly reads as "skip / optional").
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

// File preview modal state. Opened when the user clicks a file-path
// chip in either the inline MarkdownDescription (display mode) or the
// editor's preview.
const previewFilePath = ref<string | null>(null)
// eslint-disable-next-line @typescript-eslint/no-unused-vars -- kept for diff readability.
const _openFilePreview = (path: string) => {
  previewFilePath.value = path
}
const closeFilePreview = () => {
  previewFilePath.value = null
}

// Persisted-image gallery preview. The thumbnail strip renders <img>
// tags but had no click handler, so users on already-created tasks
// (edit mode) could see the thumbnails but could NOT preview them at
// full size — the create-mode flow goes through FilePreview.vue (File
// + blob: URL) which doesn't fit persisted data: URLs. This ref
// holds the currently-popped image src; clicking a thumbnail sets it,
// Esc / backdrop-click clears it. The overlay is Teleported to body
// so it escapes the dialog's overflow:hidden ancestors and renders
// full-screen.
const imagePopupUrl = ref<string | null>(null)
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
onMounted(() => document.addEventListener('keydown', handleImagePopupKeydown))
onBeforeUnmount(() => document.removeEventListener('keydown', handleImagePopupKeydown))

// True when the dialog is rendering the create flow (rather than
// edit-in-place). Drives header copy / icon, save-button text, the
// form-state reset rule, and which emit fires on submit.
const isCreateMode = computed<boolean>(() => props.mode === 'create')

// Which commit the user actually pressed. Declared ahead of openDialog
// below so the open handler can clear it.
// `creating` is one host flag covering both create paths, so on its own
// the footer cannot tell "Create task" from "Create task & run agent".
// The `null` branch is deliberate: the host can raise `creating`
// through a path this dialog did not initiate, and then there is
// nothing to attribute, so the label falls back to neutral "Creating…".
const pendingAction = ref<'create' | 'create_and_run' | null>(null)

// Reset form whenever the dialog opens OR the target task changes. In create mode we always start
// blank (regardless of `task`). In edit mode we prefill from `task` (today's behavior). Runs from
// the mount/update open guard below instead of a watcher.
const openDialog = async (): Promise<void> => {
  // The commit split button narrates the in-flight action via
  // pendingAction; clear any stale attribution from the previous
  // session here, in the open handler, instead of watching isCreating.
  // (pendingCommitLabel already returns null when !isCreating, so this
  // is hygiene for the next open, not a render dependency.)
  pendingAction.value = null
  if (isCreateMode.value) {
    name.value = ''
    description.value = ''
    unattended.value = '1'
    useGitWorktree.value = false
    worktreePath.value = ''
    worktreeBaseBranch.value = ''
    tags.value = [] // NEW: start with empty tags in create mode
    selectedProfile.value = '' // NEW: profile selector defaults to backend default
    // NEW (plan: 2026-08-14-kanban-task-detail-edit-cwd). Sync
    // cwdSession from the parent kanban's path on dialog open so
    // the picker shows the kanban-level fallback by default.
    // The legacy code initialized from the ref literal (`ref<string>(props.cwd ?? '')`)
    // which silently broke when the parent passed a different
    // cwd on a subsequent open with the same dialog instance.
    cwdSession.value = props.cwd ?? ''
  } else if (props.task) {
    name.value = props.task.name
    description.value = props.task.description ?? ''
    unattended.value = props.task.is_auto_retry_until_stop === '1' ? '1' : '0'
    // Migration 067 — prefill tags from the loaded task. tags?
    // is optional (legacy tasks may lack it); fallback to [].
    tags.value = props.task.tags ?? []
    // NEW (plan: 2026-08-14-kanban-task-detail-edit-cwd).
    // Sync the per-task cwd picker with the task's persisted cwd
    // in edit mode. Equivalent to the create-mode
    // `cwdSession.value = props.cwd ?? ''` for create, but reads
    // the task row. `task?.cwd ?? ''` coerces legacy
    // pre-Migration-070 tasks (whose `cwd` is undefined) to the
    // empty-state placeholder — same UX as the read-only strip
    // that lived in the metadata strip pre-fix. This branch
    // also covers the rare "user clicks task A then task B with
    // the dialog already open" case via the openKey guard's
    // `props.task?.id` segment.
    cwdSession.value = props.task.cwd ?? ''
    // Media-flags change — list/get carry only `is_have_image` /
    // `is_have_video` flags; the gallery lazy-loads via the
    // store's fetchTaskMedia (GET .../tasks/:id/media) when a flag
    // is true and the arrays are still empty. imageUrls is a
    // computed tracking `props.task.imageUrls` so optimistic
    // `updateTaskDetails({ imageUrls })` writes still re-render
    // without a re-open.
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
  // Don't await — let the fetch happen in the background. The
  // dropdown only opens when the user focuses the input, which is
  // itself a separate trigger; awaiting here would block the
  // focus call on a network round-trip for no benefit.
  // NEW (plan: 2026-08-06-kanban-tags-autocomplete-in-create-mode):
  // Removed `props.task` from the guard. The fetch needs only the
  // kanban's workspace_item_id (from column.workspace_item_id),
  // which is available in BOTH edit and create modes via the host
  // bindings. The composable's fetchPage already short-circuits on
  // empty item_id (useKanbanTagSuggestions.ts:73-76), so the gate
  // was redundant AND was the reason the existing-tag dropdown never
  // appeared in the "+ Add task" dialog.
  if (props.workspaceId) {
    void tagSuggestions.ensureLoaded()
  }
  // NEW (plan: 2026-08-06-kanban-task-profile-selector). Fetch profiles for the picker in create
  // mode. Same fire-and-forget pattern as tagSuggestions — the dropdown only opens when the user
  // clicks it.
  if (isCreateMode.value) {
    void loadProfiles()
    void loadHomeDir()
  }
  // Sync selectedColumnId from the parent's `column` prop on open
  // (create mode only). Re-assigning the same id is a no-op, so the
  // host round-trip in scenario (b) stays loop-free.
  if (isCreateMode.value) {
    selectedColumnId.value = props.column?.id ?? null
  }
}

// selectedColumnId sync lives at the end of the open handler above.

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

// NEW (plan: 2026-08-06-kanban-add-task-button-placement). Register
// the click-outside listener for the column picker at mount,
// deregister at unmount. Mirrors the profile picker's pattern (the
// profile picker uses inline @click.stop on its dropdown to avoid
// the same listener — both approaches are fine; the column picker
// uses the document listener because the dropdown is a sibling of
// the trigger button rather than a child).
onMounted(() => {
  document.addEventListener('click', handleDocumentClickColumn)
  // NEW (Migration 070 — kanban-cwd-session-optional plan). Same
  // pattern for the per-task cwd picker.
  document.addEventListener('mousedown', handleDocumentClickCwd)
  document.addEventListener('click', handleDocumentClickCommitMenu)
})
onUnmounted(() => {
  document.removeEventListener('click', handleDocumentClickColumn)
  document.removeEventListener('mousedown', handleDocumentClickCwd)
  document.removeEventListener('click', handleDocumentClickCommitMenu)
})

// Dirty tracking — the Save button enables only when the form is
// ready to submit. Two semantics:
//   - edit mode: the form must differ from the props.task baseline
//     (saves a wasted API call on a no-op Save click).
//   - create mode: any non-empty name is "dirty enough to submit"
//     (the task doesn't exist yet so there's nothing to compare to).
const isDirty = computed<boolean>(() => {
  if (isCreateMode.value) return isValid.value
  if (!props.task) return false
  const nameChanged = name.value.trim() !== props.task.name
  const descChanged = description.value !== (props.task.description ?? '')
  // Migration 067 — tags dirty check. Compare arrays via JSON.stringify
  // (cheap for ≤ 30 tags). Stable order matters: the chip input
  // preserves the user's add order, but if the backend ever returns
  // a different order, the dialog will treat the row as "dirty"
  // and push a no-op update. Acceptable; the order is stable
  // because we never re-sort tags on the backend.
  const tagsBefore = props.task.tags ?? []
  const tagsAfter = tags.value
  const tagsEqual =
    tagsBefore.length === tagsAfter.length && tagsBefore.every((t, i) => t === tagsAfter[i])
  const tagsChanged = !tagsEqual
  return nameChanged || descChanged || tagsChanged
})

const isValid = computed<boolean>(() => name.value.trim().length > 0)
const canSave = computed<boolean>(() => isDirty.value && isValid.value)
// "Create task & run agent" requires only a name (description is
// optional — empty description degrades to a queued message that is
// just the title). The unattended toggle flows through separately.
const canRunAgent = computed<boolean>(() => isValid.value)

// In-flight gate for the create-mode commit controls. While the
// host's create request is in flight (`creating` prop true) every
// commit control is disabled. The handlers also early-return as
// belt-and-suspenders (a disabled button drops clicks at the
// browser level, but the guard makes the emit impossible even if a
// click slips through — e.g. the mousedown-commits-draft path
// re-enabling the button mid-click).
const isCreating = computed<boolean>(() => props.creating === true)
const canCommitCreate = computed<boolean>(() => !isCreating.value && isValid.value)

const pendingCommitLabel = computed<string | null>(() => {
  if (!isCreating.value) return null
  return pendingAction.value === 'create_and_run' ? 'Starting…' : 'Creating…'
})

// Inject the processingState map (provided by App.vue; populated via
// SSE worker events). The Start agent menu item is `:disabled` when a
// worker is already running for this task's session. Edit-mode only —
// create mode has its own ▶ Create task & run agent control.
//
// Defensive: `inject()` may return `undefined` if the provider is
// missing (e.g. tests that mount the dialog in isolation). The
// computed below treats that as "no worker running" (button enabled).
//
// Plan: docs/superpowers/specs/2026-08-18-kanban-task-detail-start-agent.md
const processingState = inject<Record<string, boolean> | undefined>('processingState', undefined)
const isWorkerRunning = computed<boolean>(() => {
  if (!props.task?.id) return false
  return processingState?.[props.task.id] === true
})

// ─── Commit split button ────────────────────────────────────────────────
// The two commit actions are one split control: the left half is the
// action we expect you to want, the caret menu holds the alternative
// (create mode → "Create task only", edit mode → "▶ Start agent").
//
// The menu is always mounted and toggled with v-show rather than v-if.
// display:none already removes a subtree from the a11y tree and the tab
// order, so nothing is exposed while closed, and keeping it mounted
// preserves the popup's state across toggles.
const commitMenuOpen = ref(false)
const commitMenuRef = ref<HTMLElement | null>(null)

const toggleCommitMenu = () => {
  commitMenuOpen.value = !commitMenuOpen.value
}

const closeCommitMenu = () => {
  commitMenuOpen.value = false
}

// A menu item commits the form, so it must close the menu it came from —
// otherwise the popup sits over the panel the action just navigated to.
const runMenuAction = (action: () => void) => {
  closeCommitMenu()
  action()
}

const handleDocumentClickCommitMenu = (event: MouseEvent) => {
  if (!commitMenuOpen.value) return
  const target = event.target as Node | null
  if (commitMenuRef.value && target && !commitMenuRef.value.contains(target)) {
    closeCommitMenu()
  }
}

// ─── Handlers ───────────────────────────────────────────────────────────

// NEW (plan: 2026-08-18-kanban-task-detail-start-agent). Edit-mode
// handler for the ▶ Start agent button. Emits `start-agent` with the
// task id; KanbanView's handler calls workspacesStore.startAgentOnTask,
// which POSTs to the new backend endpoint. The dialog stays open on
// failure (host sets errorMessage); closes on success.
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
  // Belt + suspenders: if the user typed a tag and clicked Save
  // without pressing Enter/comma, the KanbanTagsInput still holds the
  // draft in its local `draftInput` ref. The mousedown handler
  // below commits it before click logic runs, but commit again here
  // to handle the (rarer) case where mousedown didn't fire (e.g.
  // keyboard activation via Space/Enter).
  tagsInputRef.value?.commitDraft()
  // canSave reads tags.value; re-check after the commit in case the
  // user's draft was the only "dirty" signal and committing it
  // didn't change isDirty (e.g. duplicate draft). canSave recomputes
  // reactively, but the read here is intentional — the Save button
  // is disabled while canSave is false.
  if (!canSave.value) return
  // Attribute the in-flight state to this action so the split button can
  // narrate which commit the user actually pressed.
  if (isCreateMode.value) pendingAction.value = 'create'
  if (isCreateMode.value) {
    emit('create', {
      mode: 'create',
      name: name.value.trim(),
      description: description.value,
      // Forward the unattended toggle's current value. The
      // immediate-flip handler (handleUnattendedToggle) already
      // updated `unattended` via PUT in edit mode; in create
      // mode there's no session row yet, so this is the FIRST
      // (and only) time the value gets sent. Host threads it
      // through to api.createTask -> backend POST /tasks which
      // inserts a sessions row when the value is '1'.
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
      selectedProfile: selectedProfile.value,
      // NEW (plan: 2026-08-06-kanban-no-base64-in-desc). Create
      // mode image attachments: the editor never writes base64
      // into `description`. Instead it stages pasted/picked
      // images in `pendingFiles`. The host (KanbanView.
      // handleCreateTaskSave) reads them after `addTask`
      // returns the new taskId, uploads each via
      // `api.uploadTaskAttachment(taskId, file)`, then patches
      // the description with `![name](<url>)` markdown. Empty
      // array (not undefined) so the host can use the length
      // without a guard.
      pendingFiles: [...(descriptionEditorRef.value?.pendingFiles ?? [])],
      // NEW (Migration 070 — kanban-cwd-session-optional plan).
      // Per-task cwd override. The dialog's folder picker
      // populates `cwdSession` (defaults to the parent kanban's
      // path when set; empty when the kanban is cwd-less or the
      // user skipped the picker). Empty string is the canonical
      // "no per-task cwd" sentinel — the backend stores '' and
      // the session_create 3-level fallback chain falls back to
      // the kanban-level path + the per-session sandbox. Host
      // threads this through to workspacesStore.addTask's
      // `cwd` param and to runAgentOnNewTask's `cwd` for the
      // create-and-run flow.
      cwdSession: cwdSession.value,
    })
  } else {
    emit('save', {
      mode: 'edit',
      name: name.value.trim(),
      description: description.value,
      // NEW (Migration 067): forward tags.
      tags: tags.value,
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

// Mirror of handleSave but for the create dialog's primary half
// ("▶ Create task & run agent"), and for Enter on the name field.
// Emits `create-and-run` with mode='create_and_run' so the host can
// branch. Same payload as `create` (same fields, different mode
// discriminator) so the host's single handler can switch on mode.
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
    selectedProfile: selectedProfile.value,
    // NEW (plan: 2026-08-06-kanban-no-base64-in-desc). Mirror of
    // handleSave's pendingFiles — see that handler for the
    // orchestration contract.
    pendingFiles: [...(descriptionEditorRef.value?.pendingFiles ?? [])],
    // NEW (Migration 070 — kanban-cwd-session-optional plan).
    // Mirror of handleSave's cwdSession — see that handler for the
    // 3-level fallback chain contract.
    cwdSession: cwdSession.value,
  })
}

// Commit any draft tag typed in the chip input the moment the user
// mousedowns the Save button. Why mousedown and not @blur on the
// input: the Save button has `:disabled="!canSave"`, and a draft
// tag typed without Enter/comma leaves canSave=false (the draft is
// in the chip input's local ref, not in `tags.value` yet). If we
// only relied on @blur, the click would land on a still-disabled
// button and the browser would drop it. mousedown is NOT gated by
// the disabled attribute (it's a low-level event), so we can
// commit the draft, the canSave computed flips to true, and the
// subsequent click event fires on the now-enabled button.
const commitTagsDraftOnSaveMouseDown = () => {
  tagsInputRef.value?.commitDraft()
}

const handleKeydown = (event: KeyboardEvent) => {
  // Escape peels one layer at a time: an open commit menu absorbs the key
  // instead of the whole panel closing and losing the form.
  if (event.key === 'Escape' && commitMenuOpen.value) {
    event.stopPropagation()
    closeCommitMenu()
    return
  }
  if (event.key === 'Escape') handleClose()
}

// Exposed for tests (and the deprecated Dialog wrapper below,
// which delegates its own selectCwd to the inner panel).
defineExpose({ selectCwd })

// Toggle the unattended-mode flag. Emits `update-unattended` so the
// host can call api.updateSession(task.id, { isAutoRetryUntilStop })
// and persist it. We do NOT roll back on PUT failure here — the
// host owns the optimistic-vs-server-truth contract (and would
// re-bind task.is_auto_retry_until_stop via the workspaces store
// on next SSE event). For the common case where the user toggles
// and the host's PUT succeeds, the visual state matches the server
// immediately, which is the whole point of the toggle being
// immediate (not deferred to Save click).
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

// Plan 2026-08-06-kanban-task-profile-selector. Load the profiles this
// workspace can actually RUN with (mirrors ChatView.loadProfiles). Called on
// dialog open in create mode; failure -> empty list (the picker still works,
// just only shows "Default").
//
// The workspace scope matters: a run merges this workspace's config overlay
// over the user config, so a profile defined only in the overlay is selectable
// here and the user-scope `/api/config/pabrik` would not list it.
const loadProfiles = async () => {
  if (!isCreateMode.value) return
  profilesLoading.value = true
  try {
    const wsId = props.workspaceId ?? ''
    const config = wsId ? await api.getWorkspaceConfig(wsId) : await api.getPabrikConfig()
    const profiles = (config.profiles ?? {}) as Record<
      string,
      { model?: string; base_url?: string }
    >
    availableProfiles.value = Object.entries(profiles).map(([name, p]) => ({
      name,
      model: p.model ?? '',
      base_url: p.base_url ?? '',
    }))
  } catch (err) {
    console.error('Failed to load profiles:', err)
    availableProfiles.value = []
  } finally {
    profilesLoading.value = false
  }
}

const toggleProfilePicker = () => {
  isProfilePickerOpen.value = !isProfilePickerOpen.value
}

const selectProfile = (name: string) => {
  selectedProfile.value = name
  isProfilePickerOpen.value = false
}

// ─── Metadata helpers ───────────────────────────────────────────────────

const taskTypeLabel = computed<string | null>(() => {
  const t = props.task?.task_type
  if (t === 'memory') return 'Memory'
  return null // 'standard' and undefined both show no badge
})

const columnLabel = computed<string | null>(() => {
  return props.column?.name ?? null
})

// NEW (Task 2.7): Filter the suggestions composable's tags down to
// the names that are NOT already on the current task's draft chips.
// The model can't know about an unsaved draft, so we hide
// already-committed chips client-side. Case-insensitive set lookup
// so "Bug" doesn't show as a suggestion when the task has "bug".
const filteredTagSuggestions = computed<string[]>(() => {
  const excludeLower = new Set(tags.value.map((t) => t.toLowerCase()))
  return tagSuggestions.tags.value
    .map((s) => s.name)
    .filter((n) => !excludeLower.has(n.toLowerCase()))
})

// NEW (Migration 069 — kanban image urls column). The dialog's
// image gallery reads from the task row's `imageUrls` array. In
// edit mode this is the persisted column (loaded via the store's
// normalizeTaskTags from the `||`-joined wire string). In create
// mode the editor stages add/remove ops in its own `previewFiles`
// ref (mirrored into `pendingFiles` for the host to PATCH on save),
// so the gallery is naturally empty until the task is persisted.
//
// Tracking `props.task?.imageUrls` directly (not a local ref) keeps
// the gallery in sync with the host's optimistic
// `updateTaskDetails({ imageUrls })` write — the store mutates the
// task in place, the computed re-evaluates, the gallery re-renders
// without any re-open dance.
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
</script>

<template>
  <div
    v-if="show && (task || isCreateMode)"
    class="kanban-task-detail w-full flex flex-col"
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
    <div
      class="px-5 pt-5 pb-4 shrink-0 sticky top-0 z-10"
      style="
        border-bottom: 1px solid var(--color-border);
        background-color: var(--semantic-card-bg);
      "
    >
      <div class="flex items-center justify-between gap-3">
        <div class="flex items-center gap-2 min-w-0">
          <button
            type="button"
            @click="handleClose"
            data-testid="kanban-task-detail-back"
            class="shrink-0 h-8 px-2 rounded-lg flex items-center gap-1 text-body font-medium transition-colors duration-200 hover:opacity-80"
            style="color: var(--semantic-text-muted)"
            title="Back to board"
          >
            <svg class="w-4 h-4" fill="none" viewBox="0 0 24 24" stroke="currentColor">
              <path
                stroke-linecap="round"
                stroke-linejoin="round"
                stroke-width="2"
                d="M15 19l-7-7 7-7"
              />
            </svg>
            <span>Back</span>
          </button>
          <h3
            :id="isCreateMode ? 'kanban-task-detail-create-title' : 'kanban-task-detail-title'"
            class="text-lead font-semibold flex items-center gap-2 truncate"
            style="color: var(--semantic-text)"
          >
            <UiIcon :name="isCreateMode ? 'plus' : 'pencil'" />
            {{ isCreateMode ? 'New task' : 'Task details' }}
          </h3>
        </div>
        <button
          type="button"
          @click="handleClose"
          data-testid="kanban-task-detail-close"
          class="w-8 h-8 rounded-lg flex items-center justify-center transition-colors duration-200 hover:opacity-80"
          style="color: var(--semantic-text-muted)"
          title="Close"
        >
          <svg class="w-5 h-5" fill="none" viewBox="0 0 24 24" stroke="currentColor">
            <path
              stroke-linecap="round"
              stroke-linejoin="round"
              stroke-width="2"
              d="M6 18L18 6M6 6l12 12"
            />
          </svg>
        </button>
      </div>
      <p class="text-dense mt-1" style="color: var(--semantic-text-dim)">
        {{
          isCreateMode
            ? 'Create a new task, or start an agent on it right away.'
            : 'Edit name, description, and tags. Changes save on click.'
        }}
      </p>
    </div>

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
      <!-- Task name input — big, prominent, full-width -->
      <div class="mb-4">
        <label
          for="kanban-task-detail-name"
          class="block text-dense font-medium mb-2"
          style="color: var(--semantic-text-dim)"
        >
          Task name
        </label>
        <input
          id="kanban-task-detail-name"
          ref="nameInput"
          v-model="name"
          type="text"
          placeholder="Enter task name…"
          :data-testid="isCreateMode ? 'kanban-task-detail-create-name' : 'kanban-task-detail-name'"
          class="w-full px-3 py-2.5 rounded-lg text-lead font-medium outline-none transition-all duration-200"
          style="
            background-color: var(--semantic-sidebar-bg);
            border: 1px solid var(--color-border);
            color: var(--semantic-text);
          "
          @keyup.enter="handleEnterKey"
        />
      </div>

      <!-- Metadata strip (read-only). Hidden when no metadata
                 is available, which keeps the layout tight for the
                 common case (standard task with no pin / column
                 yet to load). In create mode the strip renders ONLY
                 when a column is provided — pin/type don't apply to
                 a brand-new task. The column + type + pinned items
                 render as small chips (sidebar-bg + dim text) instead
                 of plain dim text so they read as "metadata badges"
                 rather than orphan labels. -->
      <div
        v-if="columnLabel || (!isCreateMode && (taskTypeLabel || task?.is_pinned))"
        class="mb-4 flex items-center gap-2 flex-wrap"
        data-testid="kanban-task-detail-metadata"
      >
        <!-- NEW (plan: 2026-08-06-kanban-add-task-button-placement).
                   Column picker (create mode only). Replaces the read-only
                   column chip in create mode — the user picks the target
                   column inside the dialog (mirrors the profile picker
                   pattern: button trigger + ▾ dropdown + ✓ checkmark +
                   click-outside close). Pick emits column-change so the
                   host updates activeCreateColumnId in real-time. Edit mode
                   falls through to the static chip below. -->
        <div
          v-if="isCreateMode && props.availableColumns.length > 0"
          ref="columnPickerRef"
          class="relative"
        >
          <button
            type="button"
            @click.stop="toggleColumnPicker"
            class="min-w-[180px] px-2.5 py-1 rounded-md text-dense hover:opacity-80 inline-flex items-center justify-between gap-1.5"
            style="
              background-color: var(--semantic-sidebar-bg);
              border: 1px solid var(--color-border);
              color: var(--semantic-text);
            "
            data-testid="kanban-task-detail-column-picker"
          >
            <span class="inline-flex items-center gap-1.5">
              <UiIcon name="clipboard" />
              <span class="font-medium">{{ columnLabel }}</span>
            </span>
            <span class="text-micro" style="color: var(--semantic-text-dim)">▾</span>
          </button>
          <div
            v-if="isColumnPickerOpen"
            class="absolute top-full mt-1 left-0 min-w-[180px] rounded-lg shadow-lg z-20 overflow-hidden"
            style="background-color: var(--semantic-card-bg); border: 1px solid var(--color-border)"
            data-testid="kanban-task-detail-column-picker-dropdown"
            @click.stop
          >
            <button
              v-for="col in props.availableColumns"
              :key="col.id"
              type="button"
              @click="selectColumn(col.id)"
              class="w-full text-left px-3 py-2 text-dense hover:opacity-80 flex items-center justify-between"
              style="color: var(--semantic-text)"
              :data-testid="`kanban-task-detail-column-picker-item-${col.id}`"
            >
              <span class="font-medium">{{ col.name }}</span>
              <span v-if="selectedColumnId === col.id">✓</span>
            </button>
          </div>
        </div>
        <!-- Edit mode: read-only column chip (NEW: styled as
                   a chip instead of plain dim text). Folder icon
                   prefix + bordered pill, matches the cwd picker
                   + profile picker visual language in the same dialog. -->
        <span
          v-else-if="columnLabel"
          data-testid="kanban-task-detail-column"
          class="inline-flex items-center gap-1.5 px-2.5 py-1 rounded-md text-dense font-medium"
          style="
            background-color: var(--semantic-sidebar-bg);
            border: 1px solid var(--color-border);
            color: var(--semantic-text);
          "
        >
          <UiIcon name="clipboard" />
          {{ columnLabel }}
        </span>
        <span
          v-if="!isCreateMode && taskTypeLabel"
          data-testid="kanban-task-detail-type"
          class="inline-flex items-center gap-1 px-2.5 py-1 rounded-md text-dense font-medium"
          style="
            background-color: var(--semantic-sidebar-bg);
            border: 1px solid var(--color-border);
            color: var(--semantic-text-muted);
          "
        >
          {{ taskTypeLabel }}
        </span>
        <span
          v-if="!isCreateMode && task?.is_pinned"
          data-testid="kanban-task-detail-pinned"
          class="inline-flex items-center gap-1 px-2.5 py-1 rounded-md text-dense font-medium"
          style="
            background-color: var(--semantic-sidebar-bg);
            border: 1px solid var(--color-border);
            color: var(--semantic-text-muted);
          "
        >
          <UiIcon name="pin" />
          Pinned
        </span>
        <!-- The read-only cwd strip (legacy) was removed by the
                   2026-08-14-kanban-task-detail-edit-cwd plan: the
                   picker button label now shows the cwd in both
                   modes, so the read-only span was redundant.
                   Plan: docs/superpowers/plans/
                   2026-08-14-kanban-task-detail-edit-cwd.md -->
      </div>

      <!-- Description — editor by default in both modes (preserves the
                 existing test contract: the textarea is always
                 available). A "Preview" toggle below renders the
                 current description as Markdown so the user can see
                 how it'll look on the card without leaving the form.

                 The editor owns its own textarea, paperclip, char
                 counter, @-trigger file picker, and image previews —
                 the dialog just passes the v-model and the cwd. -->
      <div>
        <div class="mb-1">
          <label
            for="kanban-task-detail-description"
            class="block text-dense font-medium"
            style="color: var(--semantic-text-dim)"
          >
            Description
          </label>
        </div>
        <p class="text-meta mb-2" style="color: var(--semantic-text-dim)">
          Markdown supported. Type <span class="font-mono">@</span> to link a file. Paste or attach
          images.
        </p>

        <!-- Migration 069 — kanban image urls gallery. Reads
                   from task.imageUrls (set by the create-mode host
                   flow OR loaded from the row on edit-mode open).
                   Each image is a `data:image/<mime>;base64,...`
                   URL (from the `||`-delimited column string split
                   by the store's normalizeTaskTags). The editor
                   handles add/remove via its existing
                   `pendingFiles` mechanism; this gallery is the
                   read-only display of what's currently persisted.
                   Plan: docs/superpowers/plans/2026-08-06-kanban-
                   image-urls-column.md. -->
        <div
          v-if="imageUrls.length > 0"
          class="mb-3 flex flex-wrap gap-2"
          data-testid="kanban-task-detail-image-gallery"
        >
          <img
            v-for="(url, idx) in imageUrls"
            :key="idx"
            :src="url"
            :alt="`Task image ${idx + 1}`"
            class="w-24 h-24 object-cover rounded border cursor-pointer transition-opacity hover:opacity-80"
            style="border-color: var(--color-border)"
            :data-testid="`kanban-task-detail-image-${idx}`"
            @click="openImagePopup(url)"
          />
        </div>
        <div
          v-else-if="isMediaLoading"
          class="mb-3 text-meta"
          style="color: var(--semantic-text-dim)"
          data-testid="kanban-task-detail-media-loading"
        >
          Loading media…
        </div>

        <!-- Editor: shown in BOTH create + edit modes. The
                   previous "Preview" toggle button (which flipped to
                   <MarkdownDescription>) was removed per user
                   feedback — the dialog stays focused on the editor.
                   Plan: 2026-08-06-kanban-no-base64-in-desc. -->
        <KanbanDescriptionEditor
          ref="descriptionEditorRef"
          v-model="description"
          :cwd="cwd"
          :task-id="props.task?.id ?? ''"
          :max-length="undefined"
          :test-id="
            isCreateMode
              ? 'kanban-task-detail-create-description'
              : 'kanban-task-detail-description'
          "
          data-testid="kanban-task-detail-description-editor"
        />
      </div>

      <!-- Tags (Migration 067 — kanban task tags feature).
                 Free-form chip input. Always shown (create + edit
                 modes). The KanbanTagsInput component handles all
                 validation + dedupe + color rendering. -->
      <div class="mt-4">
        <label
          for="kanban-task-detail-tags"
          class="block text-dense font-medium mb-1"
          style="color: var(--semantic-text-dim)"
        >
          Tags
        </label>
        <p class="text-meta mb-2" style="color: var(--semantic-text-dim)">
          Optional. Press Enter or comma to add. Letters, digits, underscores, hyphens.
        </p>
        <KanbanTagsInput
          ref="tagsInputRef"
          v-model="tags"
          :suggestions="filteredTagSuggestions"
          :has-more="tagSuggestions.hasMore.value"
          :loading-more="tagSuggestions.loading.value"
          :on-load-more="tagSuggestions.loadNextPage"
          :test-id="isCreateMode ? 'kanban-task-detail-create-tags' : 'kanban-task-detail-tags'"
        />
      </div>

      <!-- Settings section. Groups the per-task cwd picker, profile
                 picker (create-mode only), and Unattended-mode toggle
                 into one visually-coherent region — all three answer
                 the same question: "how will this task run?". The
                 section sits below Tags, separated by a divider, with
                 a small subheading that announces the group. This
                 replaces the previous scattered layout (one row with
                 `border-top`, another row right after with another
                 `border-top` and `mt-2`) that read as three separate
                 floating controls instead of one settings block. -->
      <div
        class="mt-5 pt-4"
        style="border-top: 1px solid var(--color-border)"
        data-testid="kanban-task-detail-settings-section"
      >
        <h4 class="text-dense font-semibold mb-3" style="color: var(--semantic-text-dim)">
          Settings
        </h4>

        <!-- Row 1: per-task cwd picker (always shown) +
                profile picker (create mode only). Both use the same
                chip-style trigger so they read as a pair. -->
        <div
          class="flex items-center gap-2 flex-wrap mb-3"
          data-testid="kanban-task-detail-settings-pickers"
        >
          <!-- Per-task cwd picker. Same trigger pattern as the
                     profile picker (button toggle + click-outside
                     close + ▾ caret). Pre-populated from the parent
                     kanban's path in create mode, or the task's
                     persisted `cwd` field in edit mode. Plan:
                     docs/superpowers/plans/2026-08-14-kanban-task-
                     detail-edit-cwd.md -->
          <div ref="cwdPickerRef" class="relative shrink-0">
            <button
              type="button"
              @click.stop="toggleCwdPicker"
              class="px-2.5 py-1 rounded-md text-dense hover:opacity-80 inline-flex items-center gap-1.5 transition-opacity duration-200"
              :style="cwdPickerStyle"
              :title="
                cwdSession
                  ? `Project root: ${cwdSession}`
                  : isCreateMode
                    ? 'No project root (optional)'
                    : 'No project root. Click to set a per-task cwd.'
              "
              data-testid="kanban-task-detail-cwd-picker"
            >
              <svg
                xmlns="http://www.w3.org/2000/svg"
                viewBox="0 0 20 20"
                fill="currentColor"
                class="w-3.5 h-3.5 shrink-0"
                aria-hidden="true"
                data-testid="kanban-task-detail-cwd-picker-icon"
              >
                <path
                  d="M2 5a2 2 0 012-2h4.586a1 1 0 01.707.293L11 5h5a2 2 0 012 2v8a2 2 0 01-2 2H4a2 2 0 01-2-2V5z"
                />
              </svg>
              <span class="font-medium">Project root</span>
              <span
                class="font-mono truncate max-w-[200px] inline-block align-middle"
                style="color: var(--semantic-text-muted)"
              >
                {{ cwdSession ? cwdSession : '(none)' }}
              </span>
              <span class="text-micro shrink-0" style="color: var(--semantic-text-dim)">▾</span>
            </button>
            <div
              v-if="isCwdPickerOpen"
              class="absolute z-30 mt-1 left-0"
              data-testid="kanban-task-detail-cwd-picker-dropdown"
            >
              <FilePickerDialog
                v-model="isCwdPickerOpen"
                mode="folder"
                :load-items="loadFoldersForCwdPicker"
                :key-for="(e: any) => e.path as string"
                :path-for="(e: any) => e.path as string"
                :is-expandable="(e: any) => e.is_directory as boolean"
                :label-for="(e: any) => e.name as string"
                :close-on-select="true"
                :initial-path="cwdSession || props.cwd || '/'"
                :selected-path="cwdSession || props.cwd || ''"
                title="Select Per-Task Project Root"
                :enable-recent-history="true"
                @select="selectCwd"
              />
            </div>
          </div>

          <!-- Profile picker (create mode only). Same chip-style
                     trigger as the cwd picker so they read as siblings. -->
          <div v-if="isCreateMode" ref="profilePickerRef" class="relative shrink-0">
            <button
              type="button"
              @click.stop="toggleProfilePicker"
              class="px-2.5 py-1 rounded-md text-dense hover:opacity-80 inline-flex items-center gap-1.5 transition-opacity duration-200"
              style="
                background-color: var(--semantic-sidebar-bg);
                border: 1px solid var(--color-border);
                color: var(--semantic-text);
              "
              :title="
                selectedProfile
                  ? `Using profile: ${selectedProfile}`
                  : 'Using default (top-level config)'
              "
              data-testid="kanban-task-detail-profile-picker"
            >
              <UiIcon name="robot" />
              <span class="font-medium">Profile</span>
              <span style="color: var(--semantic-text-muted)">{{
                selectedProfile || 'Default'
              }}</span>
              <span class="text-micro shrink-0" style="color: var(--semantic-text-dim)">▾</span>
            </button>
            <div
              v-if="isProfilePickerOpen"
              class="absolute top-full mt-1 left-0 min-w-[240px] rounded-lg shadow-lg z-20 overflow-hidden"
              style="
                background-color: var(--semantic-card-bg);
                border: 1px solid var(--color-border);
              "
              data-testid="kanban-task-detail-profile-picker-dropdown"
              @click.stop
            >
              <button
                type="button"
                @click="selectProfile('')"
                class="w-full text-left px-3 py-2 text-dense hover:opacity-80 flex items-center justify-between"
                style="color: var(--semantic-text)"
                data-testid="kanban-task-detail-profile-picker-item"
              >
                <span class="font-medium">Default (top-level config)</span>
                <span v-if="selectedProfile === ''">✓</span>
              </button>
              <button
                v-for="p in availableProfiles"
                :key="p.name"
                type="button"
                @click="selectProfile(p.name)"
                class="w-full text-left px-3 py-2 text-dense hover:opacity-80"
                style="color: var(--semantic-text); border-top: 1px solid var(--color-border)"
                data-testid="kanban-task-detail-profile-picker-item"
              >
                <div class="flex items-center justify-between">
                  <span class="font-medium">{{ p.name }}</span>
                  <span v-if="selectedProfile === p.name">✓</span>
                </div>
                <div class="text-micro mt-0.5" style="color: var(--semantic-text-muted)">
                  {{ p.model }} · {{ p.base_url }}
                </div>
              </button>
              <div
                v-if="!profilesLoading && availableProfiles.length === 0"
                class="px-3 py-2 text-dense"
                style="color: var(--semantic-text-muted)"
                data-testid="kanban-task-detail-profile-picker-empty"
              >
                No profiles configured. Add one in Settings.
              </div>
            </div>
          </div>
        </div>

        <!-- Row 2: Unattended mode toggle (always shown).
                   Separated from the pickers by a hairline divider so
                   the toggle reads as its own control, not "part of the
                   picker row". -->
        <div
          class="pt-3 flex items-center justify-between gap-3"
          style="border-top: 1px solid var(--color-border)"
          data-testid="kanban-task-detail-unattended"
        >
          <div class="flex-1 min-w-0">
            <div class="text-dense font-medium" style="color: var(--semantic-text-dim)">
              Unattended mode
            </div>
            <div class="text-meta mt-0.5" style="color: var(--semantic-text-dim)">
              Keep retrying past the 10-error limit for overnight runs. Off = stop on
              too-many-retries.
            </div>
          </div>
          <label
            class="relative inline-flex items-center cursor-pointer shrink-0"
            style="color: var(--semantic-text)"
          >
            <input
              type="checkbox"
              :checked="unattended === '1'"
              @change="handleUnattendedToggle"
              class="sr-only peer"
              data-testid="kanban-task-detail-unattended-toggle"
            />
            <div
              class="w-11 h-6 rounded-full transition-colors duration-200"
              style="background-color: var(--semantic-text-dim)"
              :style="unattended === '1' ? { backgroundColor: '#f59e0b' } : {}"
            />
            <div
              class="absolute top-0.5 left-0.5 w-5 h-5 rounded-full transition-transform duration-200"
              style="background-color: white"
              :class="unattended === '1' ? 'translate-x-5' : ''"
            />
          </label>
        </div>

        <!-- Use-git-worktree toggle (create mode only). Same switch
                   styling as the unattended row above. -->
        <div
          v-if="isCreateMode"
          class="pt-3 flex items-center justify-between gap-3"
          data-testid="kanban-task-detail-use-git-worktree"
        >
          <div class="flex-1 min-w-0">
            <div class="text-dense font-medium" style="color: var(--semantic-text-dim)">
              Use git worktree
            </div>
            <div class="text-meta mt-0.5" style="color: var(--semantic-text-dim)">
              Run the agent in a fresh git worktree so its changes stay isolated from your working
              tree.
            </div>
          </div>
          <label
            class="relative inline-flex items-center cursor-pointer shrink-0"
            style="color: var(--semantic-text)"
          >
            <input
              type="checkbox"
              :checked="useGitWorktree"
              @change="handleUseGitWorktreeToggle"
              class="sr-only peer"
              data-testid="kanban-task-detail-use-git-worktree-toggle"
            />
            <div
              class="w-11 h-6 rounded-full transition-colors duration-200"
              style="background-color: var(--semantic-text-dim)"
              :style="useGitWorktree ? { backgroundColor: '#f59e0b' } : {}"
            />
            <div
              class="absolute top-0.5 left-0.5 w-5 h-5 rounded-full transition-transform duration-200"
              style="background-color: white"
              :class="useGitWorktree ? 'translate-x-5' : ''"
            />
          </label>
        </div>
        <!-- Worktree path input (create mode only, visible when the
                   toggle is ON). Baked as the `Path:` line after
                   `#Notes UseGitWorktree` in the queue_message. -->
        <div
          v-if="isCreateMode && useGitWorktree"
          class="pt-2 flex flex-col gap-1"
          data-testid="kanban-task-detail-use-git-worktree-path-wrap"
        >
          <label
            class="text-dense font-medium"
            style="color: var(--semantic-text-dim)"
            for="kanban-worktree-path-input"
          >
            Worktree path
          </label>
          <input
            id="kanban-worktree-path-input"
            type="text"
            v-model="worktreePath"
            placeholder="/home/you/.config/pabrik/.worktrees/my-task-1757792000000"
            class="w-full px-2 py-1.5 rounded-lg text-dense"
            style="
              background-color: var(--semantic-sidebar-bg);
              border: 1px solid var(--color-border);
              color: var(--semantic-text);
            "
            data-testid="kanban-task-detail-use-git-worktree-path"
          />
          <div class="text-meta" style="color: var(--semantic-text-dim)">
            Default: $HOME/.config/pabrik/.worktrees/&lt;task-name&gt;-&lt;timestamp&gt;. Must be
            absolute; the parent folder must exist.
          </div>
        </div>
        <!-- Base-branch picker (create mode only, visible when the
                   toggle is ON). Baked as the `Base:` line right after
                   `Path:` in the queue_message, so the agent passes it to
                   `set_git_worktree`'s `base` argument and the worktree is
                   created FROM that ref. -->
        <div
          v-if="isCreateMode && useGitWorktree"
          class="pt-2 flex flex-col gap-1 items-start"
          data-testid="kanban-task-detail-use-git-worktree-base-wrap"
        >
          <GitBaseBranchSelect
            v-model="worktreeBaseBranch"
            :repo-path="cwdSession || cwd"
            data-testid="kanban-task-detail-use-git-worktree-base"
          />
          <div class="text-meta" style="color: var(--semantic-text-dim)">
            Optional but recommended. The new worktree's branch is created from this ref (e.g.
            origin/main). "HEAD (default)" branches from whatever the repo currently has checked
            out.
          </div>
        </div>
      </div>
    </div>

    <!-- Actions — sticky so the commit row stays reachable on long
         forms (the host cover container scrolls, not this card).

         Cancel is a ghost button: a border on a button means "this is
         one of the choices you make", and Cancel is the absence of
         one. It must not compete with the commit action beside it.

         The two commit actions are one split control. The left half is
         the action we expect you to want; the caret menu holds the
         alternative. Create mode's half is "▶ Create task & run
         agent" — which is also what Enter on the name field does, so
         the visual default and the keyboard default agree. Edit mode's
         half is "Save" and the menu holds "▶ Start agent". -->
    <div
      class="px-5 py-4 shrink-0 sticky bottom-0 z-10 flex flex-wrap justify-end gap-2"
      style="border-top: 1px solid var(--color-border); background-color: var(--semantic-card-bg)"
    >
      <button
        type="button"
        @click="handleClose"
        data-testid="kanban-task-detail-cancel"
        class="px-3 py-1.5 rounded-lg text-body font-medium transition-all duration-200 hover:opacity-80 focus:outline-none focus-visible:ring-2 focus-visible:ring-offset-2 focus-visible:ring-[--color-blue]"
        style="color: var(--semantic-text-dim)"
        title="Discard and close"
      >
        Cancel
      </button>

      <div ref="commitMenuRef" class="relative shrink-0 flex">
        <!-- Primary half. Gradient, rounded on the left, butted against
             the caret with a hairline seam. -->
        <button
          v-if="isCreateMode"
          type="button"
          @mousedown="commitTagsDraftOnSaveMouseDown"
          @click="handleRunAgent"
          :disabled="!canCommitCreate"
          data-testid="kanban-task-detail-create-and-run"
          class="px-3 py-1.5 rounded-l-lg text-body font-medium transition-all duration-200 disabled:opacity-50 disabled:cursor-not-allowed disabled:hover:opacity-50 hover:opacity-80 focus:outline-none focus-visible:ring-2 focus-visible:ring-offset-2 focus-visible:ring-[--color-blue]"
          style="
            background: linear-gradient(135deg, var(--color-violet), var(--color-blue));
            color: var(--color-bg);
          "
          title="Create the task and start the agent. The title + description becomes the first user message. (Enter)"
        >
          <span
            v-if="isCreating"
            aria-hidden="true"
            class="inline-block w-3 h-3 rounded-full align-[-2px] mr-1.5"
            style="
              border: 2px solid rgba(24, 22, 22, 0.35);
              border-top-color: var(--color-bg);
              animation: ktd-spin 0.7s linear infinite;
            "
          ></span>
          <template v-if="isCreating">{{ pendingCommitLabel }}</template>
          <template v-else
            ><span aria-hidden="true">▶</span
            ><span class="ml-1">Create task &amp; run agent</span></template
          >
        </button>
        <button
          v-else
          type="button"
          @mousedown="commitTagsDraftOnSaveMouseDown"
          @click="handleSave"
          :disabled="!canSave"
          data-testid="kanban-task-detail-save"
          class="px-3 py-1.5 rounded-l-lg text-body font-medium transition-all duration-200 disabled:opacity-50 disabled:cursor-not-allowed disabled:hover:opacity-50 hover:opacity-80 focus:outline-none focus-visible:ring-2 focus-visible:ring-offset-2 focus-visible:ring-[--color-blue]"
          style="
            background: linear-gradient(135deg, var(--color-violet), var(--color-blue));
            color: var(--color-bg);
          "
        >
          Save
        </button>
        <button
          type="button"
          @click.stop="toggleCommitMenu"
          :disabled="isCreateMode ? !canCommitCreate : !canSave"
          data-testid="kanban-task-detail-commit-caret"
          class="px-2 py-1.5 rounded-r-lg text-body font-medium transition-all duration-200 disabled:opacity-50 disabled:cursor-not-allowed disabled:hover:opacity-50 hover:opacity-80 focus:outline-none focus-visible:ring-2 focus-visible:ring-offset-2 focus-visible:ring-[--color-blue]"
          style="
            background: linear-gradient(135deg, var(--color-violet), var(--color-blue));
            color: var(--color-bg);
            border-left: 1px solid rgba(24, 22, 22, 0.25);
          "
          aria-haspopup="menu"
          :aria-expanded="commitMenuOpen"
          aria-label="More commit options"
          title="More commit options"
        >
          <span aria-hidden="true" class="text-micro leading-none">{{
            commitMenuOpen ? '▲' : '▼'
          }}</span>
        </button>

        <!-- Alternative commit. v-show, not v-if: display:none already
             pulls the subtree out of the a11y tree and the tab order,
             so a mounted-but-closed menu exposes nothing. -->
        <div
          v-show="commitMenuOpen"
          role="menu"
          data-testid="kanban-task-detail-commit-menu"
          class="absolute bottom-full right-0 mb-2 z-20 py-1 rounded-lg shadow-lg min-w-[230px]"
          style="background-color: var(--semantic-card-bg); border: 1px solid var(--color-border)"
        >
          <button
            v-if="isCreateMode"
            type="button"
            role="menuitem"
            @mousedown="commitTagsDraftOnSaveMouseDown"
            @click="runMenuAction(handleSave)"
            :disabled="!canCommitCreate"
            data-testid="kanban-task-detail-save"
            class="w-full px-3 py-2 text-left text-body transition-opacity duration-200 disabled:opacity-50 disabled:cursor-not-allowed hover:opacity-80 focus:outline-none focus-visible:ring-2 focus-visible:ring-[--color-blue]"
            style="color: var(--semantic-text)"
          >
            <span>Create task only</span>
            <span class="block text-meta mt-0.5" style="color: var(--semantic-text-dim)">
              Add it to the board without starting a worker.
            </span>
          </button>
          <button
            v-else
            type="button"
            role="menuitem"
            @click="runMenuAction(handleStartAgent)"
            :disabled="isWorkerRunning"
            :title="
              isWorkerRunning
                ? 'A worker is already running on this task — wait for it to finish before starting a new agent.'
                : 'Trigger the agent on the existing chat context. No new message is queued — the agent resumes whatever context is already in the session.'
            "
            data-testid="kanban-task-detail-start-agent"
            class="w-full px-3 py-2 text-left text-body transition-opacity duration-200 disabled:opacity-50 disabled:cursor-not-allowed hover:opacity-80 focus:outline-none focus-visible:ring-2 focus-visible:ring-[--color-blue]"
            style="color: var(--semantic-text)"
          >
            <span aria-hidden="true">▶</span>
            <span class="ml-1">Start agent</span>
            <!-- Why the button is disabled, without needing a hover: the
                 elapsed chip states how long the current run has been
                 going, so "wait for it to finish" has a number attached. -->
            <WorkerElapsedChip
              v-if="isWorkerRunning && props.task"
              :session-id="props.task.id"
              test-id="kanban-task-detail-elapsed"
            />
            <span class="block text-meta mt-0.5" style="color: var(--semantic-text-dim)">
              Resume the agent on this task's existing chat context.
            </span>
          </button>
        </div>
      </div>
    </div>
  </div>

  <!-- File preview modal. Mounted at the panel root so it's not
       affected by the parent transition. The path comes from the
       chip click; cwd comes from props (the kanban's filesystem
       root, threaded in from KanbanView.item.path). -->
  <FilePreviewModal
    v-if="previewFilePath"
    :show="previewFilePath !== null"
    :cwd="cwd"
    :file-path="previewFilePath"
    @close="closeFilePreview"
  />

  <!-- Persisted-image gallery preview. Teleported to body so it
       escapes the dialog overflow. Opened by clicking a gallery
       thumbnail (imagePopupUrl). Esc / backdrop-click closes it. -->
  <Teleport to="body">
    <div
      v-if="imagePopupUrl"
      class="fixed inset-0 z-[10000] flex items-center justify-center bg-black/85 p-5"
      data-testid="kanban-task-detail-image-popup-overlay"
      @click="closeImagePopup"
    >
      <button
        type="button"
        class="absolute top-2 right-2 p-2 text-white opacity-70 hover:opacity-100 transition-opacity"
        aria-label="Close image preview"
        @click.stop="closeImagePopup"
      >
        <svg class="w-6 h-6" fill="none" stroke="currentColor" viewBox="0 0 24 24">
          <path
            stroke-linecap="round"
            stroke-linejoin="round"
            stroke-width="2"
            d="M6 18L18 6M6 6l12 12"
          />
        </svg>
      </button>
      <img
        :src="imagePopupUrl"
        alt="Task image preview"
        class="max-w-full max-h-full object-contain rounded-lg"
        data-testid="kanban-task-detail-image-popup-img"
        @click.stop
      />
    </div>
  </Teleport>
</template>

<style scoped>
.kanban-task-detail {
  /* Inline side-panel: the host controls width + scroll. */
}

/* The commit button's in-flight spinner. Declared here rather than as
   a Tailwind `animate-spin` utility because the ring needs a
   token-matched border colour to read against the violet→blue
   gradient, and inline `style` on the element already carries it. */
@keyframes ktd-spin {
  to {
    transform: rotate(360deg);
  }
}

@media (prefers-reduced-motion: reduce) {
  [style*='ktd-spin'] {
    animation: none !important;
  }
}
</style>
