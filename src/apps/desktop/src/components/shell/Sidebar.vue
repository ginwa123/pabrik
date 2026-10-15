<!-- eslint-disable vue/multi-word-component-names -->
<script setup lang="ts">
import { ref, computed, onUnmounted } from 'vue'
import { useRouter, useRoute } from 'vue-router'
import { useNavigationStore } from '../../stores/navigation'
import { useWorkspacesStore } from '../../stores/workspaces'
import { useSidebarStore } from '../../stores/sidebar'
import { useNotificationStore } from '../../stores/notifications'
import ProjectsList from '../workspace/ProjectsList.vue'
import DocumentsList from '../workspace/DocumentsList.vue'
import WorkspaceSwitcher from '../workspace/WorkspaceSwitcher.vue'
import ChatsList from '../views/ChatsList.vue'
import WorkspaceModal from '../dialogs/WorkspaceModal.vue'
import { getAuthMeCached, invalidateAuthMe } from '../../helpers/authMe'
import { purgeForeignScopedKeys, setCurrentUserId } from '../../helpers/userScope'
import RenameWorkspaceModal from '../dialogs/RenameWorkspaceModal.vue'
import RenameTaskModal from '../dialogs/RenameTaskModal.vue'
import RenameDesignPageModal from '../dialogs/RenameDesignPageModal.vue'
import AddItemDialog from '../dialogs/AddItemDialog.vue'
import AddKanbanDialog from '../dialogs/AddKanbanDialog.vue'
// NEW (design-mode feature): the modal that creates a design workspace item (DesignView's
// container). Opened via the "+ Add Item → Add Design" dropdown option in ProjectsList. Plan:
// docs/superpowers/plans/2026-06-13-design-mode.md.
import AddDesignDialog from '../design/AddDesignDialog.vue'
import AddAgentDialog from '../dialogs/AddAgentDialog.vue'
import AddRoutineItemDialog from '../dialogs/AddRoutineItemDialog.vue'
import AddMemoryDialog from '../dialogs/AddMemoryDialog.vue'
import ConfirmDialog from '../dialogs/ConfirmDialog.vue'
import AddTaskPickerDialog from '../dialogs/AddTaskPickerDialog.vue'
import type { WorkspaceItem } from '../../stores/workspaces'
import { buildAppUrl, buildTaskAppUrl, parseAppPath } from '../../helpers/appUrl'
import { parseItemIdWithChat } from '../../helpers/buildItemIdWithChat'
import { useCurrentMainView } from '../../composables/useCurrentMainView'
import { openInNewTab } from '../../helpers/openInNewTab'

const router = useRouter()
const route = useRoute()
// URL-derived main view (path-based contract) — chat navigations
// resolve their workspace from it before falling back to the store.
const currentMainView = useCurrentMainView()
const navigationStore = useNavigationStore()

const props = defineProps<{
  collapsed?: boolean
  width?: number
}>()

const emit = defineEmits<{
  navigate: [
    id: string,
    chatName?: string,
    taskId?: string,
    workspaceId?: string,
    itemId?: string,
    // NEW (design-pages-in-workspace-tree plan, 2026-08-06):
    // optional 6th arg — page id for the design-view navigation
    // (so a click on a design page in the sidebar tree switches
    // the URL off `?view=task` back to `?view=workspace&pageId=Z`).
    // Matches the matching AppLayout.handleNavigate signature.
    pageId?: string,
    // NEW (kanban default-URL, 2026-08-06): optional 7th arg —
    // a pre-built `?sorts=` query string. Sidebar populates it
    // when the user clicks a kanban workspace item (commits the
    // default sort per column). AppLayout.handleNavigate mirrors
    // it into the URL. Undefined for non-kanban navigations.
    sortsParam?: string,
  ]
  'toggle-collapse': []
  resize: [width: number]
  // Header dropdown switch (plan: docs/plans/2026-09-22-revamp-
  // workspace-ui-dropdown-projects.md) — AppLayout pushes
  // ?view=workspace&workspaceId=X (history entry, not replace).
  selectWorkspace: [workspaceId: string]
}>()

// Default task name for the auto-created standard chat. The user
// clicks "Standard Chat" on the picker → we create the task with
// this name and navigate straight to the chatview. Renaming is
// available via the task row's rename modal, and ChatView's
// existing first-message convention auto-renames the chat once
// the user sends a message.
const DEFAULT_NEW_CHAT_NAME = 'New Chat'

// In-flight guard for the top-left New Chat button. The store's
// isNavigatingToTask covers the create+route inside
// createAndOpenStandardChat, but this click handler also has to resolve
// the default project first, and two clicks landing in that gap would both
// reach addTask. A ref (not a local) because the button's `:disabled`
// binding reads it.
const isCreatingChat = ref(false)

// Resolved workspace for the New Chat action. Uses the store's
// `activeWorkspace` computed (explicit → persisted → item-owning →
// first workspace), NOT the raw `activeWorkspaceId` ref — the ref is
// only set by the header dropdown or a `?workspaceId=` URL restore,
// so a fresh boot with workspaces but no explicit selection left the
// button permanently disabled while the header already showed a
// workspace. Same precedence fix as DocumentsList below.
const newChatWorkspaceId = computed(() => workspacesStore.activeWorkspace?.id ?? null)

// Chat-id updates forward to ChatsList, which owns the live navItems mirror (plan:
// 2026-09-22-revamp-ui-chats). Sidebar kept no list of its own — the pre-refactor
// navItems/chatsLoading mirror below was dead state (never rendered, never refreshed).
const updateChatId = (oldId: string, newId: string) => {
  chatsListRef.value?.updateChatId(oldId, newId)
}

// Expose method to open the Add Task picker dialog. Called by
// AppLayout's <KanbanView> when the user clicks "+" on a kanban
// column (the kanban now lives in the main content area, not in the
// sidebar, so the picker needs to be opened from outside). Uses the
// same flow as handleAddTask below — picker → standard/routine/memory
// → store action. Returns nothing; the picker takes over from there.
const openTaskPicker = (workspaceId: string, itemId: string) => {
  pickerWorkspaceId.value = workspaceId
  pickerItemId.value = itemId
  showAddTaskPicker.value = true
}

// Skip the picker and go straight to the standard chat dialog.
// Used by the kanban's "+ Add on column" path — kanban cards are
// always standard chats (the column is a workflow stage, not a
// task-type discriminator), so the Routine / Memory options would
// be noise. Mirrors the picker → standard dialog transition that
// `handleAddTaskPick('standard')` performs internally.
//
// (Removed in the kanban-add-task-via-detail-dialog feature: the
// kanban now handles its own "+ Add" flow locally via
// KanbanTaskDetailDialog in create mode. Sidebar no longer needs
// to expose this.)

const workspacesStore = useWorkspacesStore()
const sidebarStore = useSidebarStore()

// State
const isCollapsed = computed(() => props.collapsed ?? false)
const sidebarWidth = computed(() => props.width ?? 280)

// Dialog states
const showAddWorkspaceModal = ref(false)
const showAddItemDialog = ref(false)
const addItemTargetWorkspaceId = ref<string | null>(null)
// Kanban dialog state (Chunk 6 of workspace-item-kanban plan).
// Reuses `addItemTargetWorkspaceId` as the target workspace (the
// kanban item is created in that workspace, same as folder/memory).
const showAddKanbanDialog = ref(false)
// NEW (design-mode feature): mirrors showAddKanbanDialog for the
// design-mode flow. The 'design' branch in handleAddItem (below)
// flips this on, which mounts <AddDesignDialog> below the kanban
// dialog. See AddDesignDialog.vue for the internal flow.
// Plan: docs/superpowers/plans/2026-06-13-design-mode.md.
const showAddDesignDialog = ref(false)
const showAddMemoryDialog = ref(false)
const addMemoryTargetWorkspaceId = ref<string | null>(null)
const showDeleteConfirm = ref(false)
const deleteConfirmConfig = ref<{ title: string; message: string; onConfirm: () => void } | null>(
  null,
)
const showRenameWorkspaceModal = ref(false)
const renameTargetWorkspaceId = ref<string | null>(null)
const renameTargetName = ref('')
const showRenameTaskModal = ref(false)
const renameTargetTaskWorkspaceId = ref<string | null>(null)
const renameTargetTaskItemId = ref<string | null>(null)
const renameTargetTaskId = ref<string | null>(null)
const renameTargetTaskName = ref('')
// NEW (rename-design-pages plan, 2026-08-06): ⋮ menu "Rename" opens the RenameDesignPageModal. Same
// four-ref pattern as the task-rename state above — the four vars survive across modal close +
// reopen lifecycles, since the modal's emit('rename', name) only carries the name (not the ids).
const showRenameDesignPageModal = ref(false)
const renameTargetDesignPageWorkspaceId = ref<string | null>(null)
const renameTargetDesignPageItemId = ref<string | null>(null)
const renameTargetDesignPageId = ref<string | null>(null)
const renameTargetDesignPageName = ref('')

// ─── Add Task picker + per-type dialog state (Chunk 6) ──────────────────────
//
// When the user clicks the green `+` on a workspace item:
//   1. AddTaskPickerDialog opens with two cards (Standard / Memory).
//   2. On pick, the picker closes and the per-type flow runs:
//      - Standard: auto-create a task named "New Chat" and navigate
//        straight to its ChatView. No dialog (the "name + description"
//        prompt was noise — chat name is editable later via the rename
//        modal on the task row, and an empty description is fine).
//      - Memory:  open AddMemoryDialog in `mode='task'` (needs content
//        and the .md filename).
//
// We track workspaceId + itemId on each dialog's `Open` ref so the
// create callback knows where to create the task. Memory tasks do
// NOT auto-navigate — memories have no chat session to open.
// Standard tasks always auto-navigate to their new ChatView (the
// user just clicked "Standard Chat", they want to be IN the chat).
const showAddTaskPicker = ref(false)
const pickerWorkspaceId = ref<string | null>(null)
const pickerItemId = ref<string | null>(null)
// Memory task flow (2026-06-20): picked from the AddTaskPickerDialog
// "Memory" card, opens AddMemoryDialog in `mode='task'`, then
// the create callback calls addTask with taskType='memory'.
const showAddMemoryTaskDialog = ref(false)
const addMemoryTaskWorkspaceId = ref<string | null>(null)
const addMemoryTaskItemId = ref<string | null>(null)

// Resize handling
const isResizing = ref(false)
const resizeStartX = ref(0)
const resizeStartWidth = ref(0)

// Ref to ChatsList component
const chatsListRef = ref<InstanceType<typeof ChatsList> | null>(null)

const startResize = (e: MouseEvent | TouchEvent) => {
  isResizing.value = true
  const clientX = 'touches' in e && e.touches[0] ? e.touches[0].clientX : (e as MouseEvent).clientX
  resizeStartX.value = clientX
  resizeStartWidth.value = sidebarWidth.value
  document.addEventListener('mousemove', handleResize)
  document.addEventListener('mouseup', stopResize)
  document.body.style.userSelect = 'none'
  document.body.style.cursor = 'col-resize'
}

const handleResize = (e: MouseEvent | TouchEvent) => {
  if (!isResizing.value) return
  const clientX = 'touches' in e && e.touches[0] ? e.touches[0].clientX : (e as MouseEvent).clientX
  const deltaX = clientX - resizeStartX.value
  const newWidth = Math.max(72, Math.min(480, resizeStartWidth.value + deltaX))
  emit('resize', newWidth)
}

const stopResize = () => {
  isResizing.value = false
  document.removeEventListener('mousemove', handleResize)
  document.removeEventListener('mouseup', stopResize)
  document.body.style.userSelect = ''
  document.body.style.cursor = ''
}

onUnmounted(() => {
  stopResize()
})

// ─── Session Events SSE ────────────────────────────────────────────────────────
//
// Sidebar previously had a stub `connectSessionsSse` /
// `disconnectSessionsSse` pair that did nothing. The real
// sessions SSE connection lives in `ChatsList.vue` (which
// mounts alongside the sidebar). Sidebar exposes the chats
// list via a ref and doesn't need its own connection — the
// stubs have been removed as part of the SSE refactor.

const toggleCollapse = () => emit('toggle-collapse')
const goToSettings = () => emit('navigate', 'settings')

// Auth state — controls the Logout button in the sidebar header.
// Hidden when the backend runs without `--auth` (`auth_enabled=false`).
const authEnabled = ref(false)
const loggingOut = ref(false)

async function refreshAuthState() {
  try {
    // Cached: every window focus fires this — a slow /me must not
    // hammer the server on each alt-tab (see helpers/authMe).
    const { data } = await getAuthMeCached()
    if (!data) return
    authEnabled.value = !!data.auth_enabled
  } catch {
    /* offline — leave logout hidden */
  }
}

async function handleLogout() {
  if (loggingOut.value) return
  loggingOut.value = true
  try {
    await fetch('/api/auth/logout', { method: 'POST', credentials: 'same-origin' })
  } catch {
    /* session already dead server-side — still bounce to login */
  } finally {
    // Drop the cached authed /me so the guard redirects to /login.
    invalidateAuthMe()
    // Drop this user's scoped browser state (plan 2026-09-25, W5): the next
    // user on this browser profile must not inherit the workspace list,
    // active chat, open tabs, task media or diff comments.
    setCurrentUserId(null)
    purgeForeignScopedKeys()
    loggingOut.value = false
    await router.replace('/login')
  }
}

if (typeof window !== 'undefined') {
  refreshAuthState()
  window.addEventListener('focus', refreshAuthState)
  onUnmounted(() => window.removeEventListener('focus', refreshAuthState))
}

// Sibling-tab identity change (plan 2026-09-25, W5): when another tab logs
// out or switches user, `pabrik-auth-me:v1` is rewritten/removed. The
// `storage` event fires in THIS tab, so drop the previous user's scoped keys
// here too — otherwise an already-open tab keeps painting A's cache after B
// signed in next door.
if (typeof window !== 'undefined') {
  const onStorage = (e: StorageEvent) => {
    if (e.key !== null && e.key !== 'pabrik-auth-me:v1') return
    setCurrentUserId(null)
    purgeForeignScopedKeys()
    refreshAuthState()
  }
  window.addEventListener('storage', onStorage)
  onUnmounted(() => window.removeEventListener('storage', onStorage))
}
// Handle navigation events from ChatsList component
const handleChatsNavigate = (id: string, chatName?: string) => {
  if (id.startsWith('chat-')) {
    // Navigate to chat (path-based: /app/{ws}/chat/{sid}). The
    // workspace is the current main view's when present, else the
    // store's active workspace (ChatsList is scoped to it).
    const sessionId = id.replace('chat-', '')
    navigationStore.setActiveChat(sessionId, chatName || '')
    workspacesStore.setActiveWorkspaceItem(null)
    workspacesStore.setActiveTask(null)
    const mainView = currentMainView.value
    const wsForChat =
      (mainView.kind === 'chat' && mainView.workspaceId) ||
      (mainView.kind === 'workspace' && mainView.workspaceId) ||
      workspacesStore.activeWorkspaceId ||
      ''
    if (wsForChat) {
      router.replace(buildAppUrl({ workspaceId: wsForChat, chatSessionId: sessionId }))
    } else {
      router.replace({ path: '/app', query: { view: 'chat', session: sessionId } })
    }
  } else {
    // Direct navigation
    emit('navigate', id, chatName)
  }
}

// Toggle nav section and reload chats if needed
// eslint-disable-next-line @typescript-eslint/no-unused-vars
const _toggleNavSectionAndReload = () => {
  sidebarStore.toggleNavExpanded()
  // If expanding and no chats loaded yet, trigger load
  if (sidebarStore.navExpanded && chatsListRef.value) {
    chatsListRef.value.loadChats()
  }
}

const openDeleteConfirm = (config: { title: string; message: string; onConfirm: () => void }) => {
  deleteConfirmConfig.value = config
  showDeleteConfirm.value = true
}

const handleDeleteConfirm = () => {
  if (deleteConfirmConfig.value?.onConfirm) {
    deleteConfirmConfig.value.onConfirm()
  }
  showDeleteConfirm.value = false
  deleteConfirmConfig.value = null
}
// Dismiss path for ConfirmDialog — separate method so the template
// binding stays a single identifier (multi-statement inline handlers
// get mangled by the semi:false formatter into invalid Vue).
const handleDeleteConfirmClose = () => {
  showDeleteConfirm.value = false
  deleteConfirmConfig.value = null
}

// Workspace handlers
/**
 * Right-click "Go to settings" from a workspace item row. Opens
 * the item's own settings surface in a NEW browser tab (never navigates the current tab, NOT the global /app/settings page):
 * kanban items open their KanbanSettingsView (Columns + Agent tabs),
 * agent items open their AgentView config (Tools / System Prompt /
 * Knowledge), routine items open their RoutineView config
 * (description / instruction / schedule).
 */
const handleGoToSettings = (payload: {
  workspaceId: string
  itemId: string
  itemType?: string
}) => {
  if (payload.itemType === 'kanban') {
    openInNewTab(router, { path: `/app/kanban/${payload.itemId}/settings`, query: {} })
    return
  }
  openInNewTab(router, buildAppUrl({ workspaceId: payload.workspaceId, projectId: payload.itemId }))
}

/**
 * Ctrl/Cmd+click (or middle click) on a workspace item: open a real
 * browser tab and stay where the user is. The click never navigates,
 * so nothing in the render chain has to know about it.
 */
const handleOpenItemInBackground = (payload: {
  workspaceId: string
  itemId: string
  name: string
  itemType?: string
}) => {
  openInNewTab(router, buildAppUrl({ workspaceId: payload.workspaceId, projectId: payload.itemId }))
}

/**
 * Right-click "Open in new tab" on a task row/card. Builds the task
 * chat URL from the row's explicit ids (NOT the active store state —
 * the row may belong to a non-active item) and opens a real browser
 * tab. Never mutates navigation state: the current tab stays put.
 */
const handleOpenTaskInBackground = (payload: {
  workspaceId: string
  itemId: string
  itemType?: string
  taskId: string
}) => {
  openInNewTab(
    router,
    buildTaskAppUrl({
      taskId: payload.taskId,
      activeWorkspaceId: payload.workspaceId || null,
      activeWorkspaceItemId: payload.itemId || null,
      activeDesignPageId: null,
      activeItemType: payload.itemType ?? null,
      currentQuery: route.query,
    }),
  )
}

// Right-click / Ctrl+click / middle-click on a design page row:
// open the page in a real browser tab, never navigating here.
const handleOpenDesignPageInBackground = (payload: {
  workspaceId: string
  itemId: string
  pageId: string
}) => {
  openInNewTab(
    router,
    buildAppUrl({
      workspaceId: payload.workspaceId,
      projectId: payload.itemId,
      query: { pageId: payload.pageId },
    }),
  )
}

const handleSelectItem = async (workspaceId: string, itemId: string) => {
  workspacesStore.setActiveTask(null)
  const workspace = workspacesStore.workspaces.find((ws) => ws.id === workspaceId)
  const item = workspace?.items.find((i) => i.id === itemId)
  if (item?.path && !item.isLoaded && !item.isLoading) {
    await workspacesStore.fetchFolderContents(workspaceId, itemId)
  }
  // Reset active state in ChatsList component
  if (chatsListRef.value) {
    chatsListRef.value.resetActiveChat()
  }
  workspacesStore.setActiveWorkspaceItem(itemId)
  // NEW (kanban-sort-by default-URL, 2026-08-06): when the user
  // clicks a kanban workspace item, ALWAYS append `?sorts=` to the
  // URL with the default sort (`updated_at:desc`) for every column.
  // The user's mental model: a URL without `sorts` means "no
  // explicit sort" — but they want the URL to commit to a default
  // on first click so a refresh preserves it (and so the wire
  // payload doesn't carry silent defaults). Folders / designs /
  // chats don't get the sort param.
  //
  // FIX (kanban-sort-independence, task_1785730557641, 2026-08-06,
  // refresh follow-up): DO NOT overwrite the URL's existing `sorts`
  // when the user re-navigates to the SAME kanban. Pre-fix, every
  // Sidebar click on a kanban wrote `?sorts=col_X:updated_at:desc,...`
  // for every column — clobbering the user's custom picks (e.g.
  // col_X:name:desc) with the default. The fix: only write the
  // default when the URL doesn't already have `sorts=` for this
  // kanban. If the URL has sorts, preserve them (the user has
  // already committed to those picks on a previous visit).
  //
  // Build the `sorts` string from the kanban's columns. If the
  // columns aren't loaded yet, fetch them on demand (cheap HTTP
  // GET, idempotent) so the URL is complete on the first click.
  let sortsParam: string | undefined
  if (item?.item_type === 'kanban') {
    // Preserve the existing URL's `sorts` for THIS kanban (the
    // user has already committed to those picks). Only fall back
    // to building the default if there's no existing sorts — this
    // is the FIRST visit to this kanban (URL has no sorts at all,
    // or the current itemId doesn't match the kanban in the URL).
    // The item id is read from the path first (path-based URLs),
    // then the legacy query (transition window).
    const existingSorts = route.query.sorts as string | undefined
    const pathParsed = parseAppPath(route.path)
    const urlItemId =
      pathParsed.kind === 'project' || pathParsed.kind === 'projectChat'
        ? pathParsed.projectId
        : parseItemIdWithChat((route.query.itemId as string | undefined) ?? '').itemId
    if (existingSorts && urlItemId === itemId) {
      // Re-navigation to the SAME kanban — preserve the user's existing sort picks so we don't
      // clobber them with the default. The KanbanView's URL-restore on mount reads `sorts` and
      // applies each entry to its column.
      sortsParam = existingSorts
    } else {
      const columns = item.kanban_columns ?? []
      if (columns.length === 0) {
        // Fire-and-await: the URL we emit must include the column ids, so we wait for the columns
        // to land. fetchKanbanColumns is idempotent — safe to call even if columns are already in
        // flight from elsewhere (e.g. Sidebar expansion).
        try {
          await workspacesStore.fetchKanbanColumns(workspaceId, itemId)
        } catch {
          // Swallow — the URL will simply omit `sorts` and the
          // KanbanView mount path will apply its own fallback when
          // columns arrive. Better than throwing mid-click.
        }
      }
    }
  }
  // Carry (workspaceId, itemId) into the URL so the kanban / folder / design view survives a page
  // reload. The URL is the source of truth on reload; the in-memory `activeWorkspaceItemId` would
  // otherwise reset to null on a refresh.
  emit('navigate', 'workspace', undefined, undefined, workspaceId, itemId, undefined, sortsParam)
}

const handleDeleteWorkspace = (workspaceId: string) => {
  openDeleteConfirm({
    title: 'Delete Workspace',
    message: 'Delete workspace and all items?',
    onConfirm: () => workspacesStore.removeWorkspace(workspaceId),
  })
}

const handleDeleteItem = (workspaceId: string, itemId: string) => {
  openDeleteConfirm({
    title: 'Delete Project',
    message: 'Delete this project?',
    onConfirm: () => workspacesStore.removeWorkspaceItem(workspaceId, itemId),
  })
}

const handleAddItem = (workspaceId: string, itemType: string) => {
  addItemTargetWorkspaceId.value = workspaceId
  if (itemType === 'folder') showAddItemDialog.value = true
  if (itemType === 'kanban') showAddKanbanDialog.value = true
  // NEW (design-mode feature): routes the 'design' itemType to AddDesignDialog. Mirrors the kanban
  // routing above — both dialogs share the (workspaceId, itemType) routing pattern emitted by
  // ProjectsList. Plan: docs/superpowers/plans/2026-06-13-design-mode.md.
  if (itemType === 'design') showAddDesignDialog.value = true
  // Agent Mode (plan 2026-08-15-agent-mode, task_1786962724740_0):
  // routes the 'agent' itemType to the new AddAgentDialog.
  if (itemType === 'agent') showAddAgentDialog.value = true
  // Workspace routines (Migration 084, plan
  // 2026-09-10-workspace-items-routines): routes the 'routine'
  // itemType to AddRoutineItemDialog.
  if (itemType === 'routine') showAddRoutineItemDialog.value = true
  if (itemType === 'memory') {
    addMemoryTargetWorkspaceId.value = workspaceId
    showAddMemoryDialog.value = true
  }
}

const handleCreateItem = async (name: string, path: string) => {
  if (addItemTargetWorkspaceId.value) {
    const itemId = await workspacesStore.addWorkspaceItem(
      addItemTargetWorkspaceId.value,
      name,
      path,
    )
    if (itemId) await workspacesStore.fetchFolderContents(addItemTargetWorkspaceId.value, itemId)
  }
}

// Kanban item creation (Chunk 6 of workspace-item-kanban plan):
// user fills in the name + picks a project folder, AddKanbanDialog
// emits `create(name, path)`, we call workspacesStore.addKanbanItem
// (the store action from Chunk 5) which POSTs to
// /api/workspaces/:wsId/items/kanban and pushes the new item + its
// 3 default columns into the local store. Then close the dialog.
// The new item appears in the sidebar immediately (the workspace
// is auto-expanded by the store action, same UX as
// addWorkspaceItem). The path is required so every chat session
// created under the kanban's tasks has a cwd to run git / file
// tools in.
const handleCreateKanban = async (name: string, path: string) => {
  if (addItemTargetWorkspaceId.value) {
    await workspacesStore.addKanbanItem(addItemTargetWorkspaceId.value, name, path)
  }
  showAddKanbanDialog.value = false
}

const handleCloseAddKanbanDialog = () => {
  showAddKanbanDialog.value = false
}

// NEW (design-mode feature): mirrors handleCreateKanban. User
// fills in the name + picks a project folder, AddDesignDialog
// emits `create(name, path)`, we call workspacesStore.addDesignItem
// (the store action) which POSTs to /api/workspaces/:wsId/items/design
// and pushes the new item (with empty tasks + design_elements
// arrays) into the local store. The new item appears in the
// sidebar immediately and is auto-selected so the user lands in
// the new DesignView. The path is required so every chat session
// / design page created under this design item has a cwd to run
// git / file tools in. Plan:
// docs/superpowers/plans/2026-06-13-design-mode.md.
const handleCreateDesign = async (name: string, path: string) => {
  if (addItemTargetWorkspaceId.value) {
    await workspacesStore.addDesignItem(addItemTargetWorkspaceId.value, name, path)
  }
  showAddDesignDialog.value = false
}

const handleCloseAddDesignDialog = () => {
  showAddDesignDialog.value = false
}

// Agent Mode (plan 2026-08-15-agent-mode, task_1786962724740_0):
// agent item create + dialog state — mirrors the design flow above.
const showAddAgentDialog = ref(false)
const handleCreateAgent = async (name: string, path: string) => {
  if (addItemTargetWorkspaceId.value) {
    await workspacesStore.addAgentItem(addItemTargetWorkspaceId.value, name, path)
  }
  showAddAgentDialog.value = false
}
const handleCloseAddAgentDialog = () => {
  showAddAgentDialog.value = false
}

// Workspace routines (Migration 084, plan
// 2026-09-10-workspace-items-routines): routine item create +
// dialog state — mirrors the agent flow above.
const showAddRoutineItemDialog = ref(false)
const handleCreateRoutineItem = async (name: string, path: string) => {
  if (addItemTargetWorkspaceId.value) {
    await workspacesStore.addRoutineItem(addItemTargetWorkspaceId.value, name, path)
  }
  showAddRoutineItemDialog.value = false
}
const handleCloseAddRoutineItemDialog = () => {
  showAddRoutineItemDialog.value = false
}

/**
 * Resolve the cwd to scope a new local memory to. Uses the first
 * folder-type item in the target workspace as the project root
 * (the most natural "cwd" for the workspace). Falls back to ''
 * when the workspace has no folder items — the AddMemoryDialog
 * then shows its own "no cwd" error and refuses to submit.
 */
const resolveCwdForMemory = (workspaceId: string): string => {
  // workspacesStore is a Pinia store; its `workspaces` getter auto-unwraps the underlying ref (no
  // `.value` access in the store-public surface). See src/apps/desktop/src/stores/workspaces.ts for
  // the store definition.
  const ws = workspacesStore.workspaces.find((w) => w.id === workspaceId)
  if (!ws) return ''
  // Find the first folder item (item_type === 'folder') — its `path`
  // is the absolute path to a real project directory on disk, which
  // is what the local-memories backend will scope the file to.
  for (const item of ws.items) {
    if (item.item_type === 'folder' && item.path) return item.path
    if (item.item_type === 'design' && item.path) return item.path
  }
  return ''
}

/**
 * Resolve the cwd to scope a new memory TASK to. Unlike
 * `resolveCwdForMemory` (which uses the workspace's first folder),
 * this function takes the SPECIFIC item_id the user picked — the
 * memory task is attached to that item, and the .md file is
 * scoped to that item's path. Returns '' if the item can't be
 * found or has no path (in which case the AddMemoryDialog will
 * show its own "no cwd" error and refuse to submit).
 */
const resolveCwdForItem = (itemId: string): string => {
  const item = workspacesStore.allWorkspaceItems.find((i) => i.id === itemId)
  if (!item) return ''
  return item.path ?? ''
}

const handleCloseAddMemoryDialog = () => {
  showAddMemoryDialog.value = false
  addMemoryTargetWorkspaceId.value = null
}

const handleCreateMemory = async (name: string, _content: string, path: string) => {
  // The local memory file is created by AddMemoryDialog (via
  // createLocalMemory API) and lives at
  // `<cwd>/.pabrik/memories/<name>.md`. The next chat in this
  // workspace will pick it up via `loadLocalKnowledge` (see
  // `src/modules/agent/prompts.zig:263`). We currently just log
  // the success — a future iteration could:
  //   - Emit a typed toast (the notifications store currently only
  //     has notifyError, so this would require a `notifySuccess`).
  //   - Register a workspace-item reference so the memory shows
  //     up in the sidebar list (mirrors Add Project's behavior).
  //
  // The 3-arg signature `(name, content, path)` matches the
  // AddMemoryDialog emit shape; the legacy flow doesn't need
  // `content` (the dialog already sent it to the API), so we
  // prefix-underscore it to silence the unused-arg warning.
  console.info(`[Sidebar] local memory created: ${name} at ${path}`)
}

const handleAddWorkspace = () => (showAddWorkspaceModal.value = true)
// WorkspaceSwitcher.select → AppLayout.handleSelectWorkspace (push).
const handleSwitcherSelect = (workspaceId: string) => emit('selectWorkspace', workspaceId)
// Right-click / Ctrl+click / middle-click on a switcher option:
// open the workspace in a real browser tab, never navigating here.
const handleOpenWorkspaceInBackground = (workspaceId: string) => {
  openInNewTab(router, buildAppUrl({ workspaceId }))
}
const handleCreateWorkspace = (name: string) => workspacesStore.addWorkspace(name)
const handleCloseModal = () => (showAddWorkspaceModal.value = false)
const handleCloseAddItemDialog = () => {
  showAddItemDialog.value = false
  addItemTargetWorkspaceId.value = null
}

const handleRenameWorkspace = (workspaceId: string, currentName: string) => {
  renameTargetWorkspaceId.value = workspaceId
  renameTargetName.value = currentName
  showRenameWorkspaceModal.value = true
}

const handleConfirmRename = async (newName: string) => {
  if (renameTargetWorkspaceId.value) {
    await workspacesStore.renameWorkspace(renameTargetWorkspaceId.value, newName)
  }
  showRenameWorkspaceModal.value = false
  renameTargetWorkspaceId.value = null
  renameTargetName.value = ''
}

const handleCloseRenameModal = () => {
  showRenameWorkspaceModal.value = false
  renameTargetWorkspaceId.value = null
  renameTargetName.value = ''
}

// ─── Rename Task ────────────────────────────────────────────────────────────
// Mirrors the workspace-rename pattern above. The state is split
// across four refs (workspace id, item id, task id, name) instead
// of a single object because the modal's emit('rename', name) only
// carries the name — the targets need to survive across the modal's
// close + reopen lifecycle.
const handleRenameTask = (
  workspaceId: string,
  itemId: string,
  taskId: string,
  currentName: string,
) => {
  renameTargetTaskWorkspaceId.value = workspaceId
  renameTargetTaskItemId.value = itemId
  renameTargetTaskId.value = taskId
  renameTargetTaskName.value = currentName
  showRenameTaskModal.value = true
}

const handleConfirmTaskRename = async (newName: string) => {
  if (
    renameTargetTaskWorkspaceId.value &&
    renameTargetTaskItemId.value &&
    renameTargetTaskId.value
  ) {
    await workspacesStore.renameTask(
      renameTargetTaskWorkspaceId.value,
      renameTargetTaskItemId.value,
      renameTargetTaskId.value,
      newName,
    )
  }
  showRenameTaskModal.value = false
  renameTargetTaskWorkspaceId.value = null
  renameTargetTaskItemId.value = null
  renameTargetTaskId.value = null
  renameTargetTaskName.value = ''
}

const handleCloseTaskRenameModal = () => {
  showRenameTaskModal.value = false
  renameTargetTaskWorkspaceId.value = null
  renameTargetTaskItemId.value = null
  renameTargetTaskId.value = null
  renameTargetTaskName.value = ''
}

// ─── Rename Design Page (rename-design-pages, 2026-08-06) ───────────────
//
// Mirrors the workspace-rename + task-rename patterns. The state
// is split across four refs (workspace id, item id, page id, name)
// because the modal's emit('rename', name) only carries the name —
// the ids need to survive across the modal's close + reopen cycle.
//
// On confirm, calls `workspacesStore.renameDesignPage(...)`. The
// store handles the optimistic update + rollback + PATCH
// round-trip; Sidebar's only job is opening the modal + dispatching
// the action. Failure surfaces as a toast via the store's catch
// (renamed page = re-throws so the modal close awaits, then the
// caller catches + notifies).
const handleRenameDesignPage = (
  workspaceId: string,
  itemId: string,
  pageId: string,
  currentName: string,
) => {
  renameTargetDesignPageWorkspaceId.value = workspaceId
  renameTargetDesignPageItemId.value = itemId
  renameTargetDesignPageId.value = pageId
  renameTargetDesignPageName.value = currentName
  showRenameDesignPageModal.value = true
}

const handleConfirmDesignPageRename = async (newName: string) => {
  if (
    renameTargetDesignPageWorkspaceId.value &&
    renameTargetDesignPageItemId.value &&
    renameTargetDesignPageId.value
  ) {
    try {
      await workspacesStore.renameDesignPage(
        renameTargetDesignPageWorkspaceId.value,
        renameTargetDesignPageItemId.value,
        renameTargetDesignPageId.value,
        newName,
      )
    } catch (err) {
      const message = err instanceof Error ? err.message : String(err)
      useNotificationStore().notifyError('Failed to rename page', message)
    }
  }
  showRenameDesignPageModal.value = false
  renameTargetDesignPageWorkspaceId.value = null
  renameTargetDesignPageItemId.value = null
  renameTargetDesignPageId.value = null
  renameTargetDesignPageName.value = ''
}

const handleCloseDesignPageRenameModal = () => {
  showRenameDesignPageModal.value = false
  renameTargetDesignPageWorkspaceId.value = null
  renameTargetDesignPageItemId.value = null
  renameTargetDesignPageId.value = null
  renameTargetDesignPageName.value = ''
}

// Shared standard-chat create+navigate flow (2026-09-09 agent-mode
// direct-to-chat): auto-create a task named "New Chat" and navigate
// straight to its ChatView. Used by BOTH the picker Standard-Chat pick
// (`handleAddTaskPick('standard')` below) and the agent-mode direct path
// (`handleAddTask` bypasses the picker for `item_type === 'agent'`).
// The task row appears in the sidebar's task list under the parent item;
// the chat name is "New Chat" until the user renames it or the first user
// message auto-renames it (ChatView's existing convention).
const createAndOpenStandardChat = async (workspaceId: string, itemId: string) => {
  workspacesStore.isNavigatingToTask = true
  try {
    const taskId = await workspacesStore.addTask(workspaceId, itemId, {
      name: DEFAULT_NEW_CHAT_NAME,
    })
    if (!taskId) return
    workspacesStore.setActiveTask(taskId)
    if (workspacesStore.activeWorkspaceItemId !== itemId) {
      workspacesStore.setActiveWorkspaceItem(itemId)
    }
    // Build the URL from the passed ids, not stale store state. The store values are correct after
    // setActiveTask in the happy path, but the passed ids are the source of truth for which item
    // the + button was clicked on.
    const parentItem = workspacesStore.workspaces
      .flatMap((ws) => ws.items)
      .find((it) => it.id === itemId)
    const itemType = parentItem?.item_type ?? workspacesStore.activeWorkspaceItem?.item_type ?? null
    await router.replace(
      buildTaskAppUrl({
        taskId,
        activeWorkspaceId: workspaceId,
        activeWorkspaceItemId: itemId,
        activeDesignPageId: workspacesStore.activeDesignPageId,
        activeItemType: itemType,
        currentQuery: route.query,
      }),
    )
  } finally {
    workspacesStore.isNavigatingToTask = false
  }
}

// The top-left "New Chat" action. It never asks which project to use —
// that is the whole point. The workspace's DEFAULT project (Migration 094)
// is an agent-mode item whose path is the server user's home directory,
// and it is where the chat is created; the server ensures that default
// exists on every items read, so this is normally a pure local find and
// the button is instant.
//
// Everything past resolving the default is delegated to
// createAndOpenStandardChat, unchanged: the race guard, the store flags,
// and the router.replace that makes the new chat's URL deep-linkable and
// Back/Forward-correct. Reimplementing any of that here is how two
// subtly-different "new chat" paths get born.
const handleNewChat = async () => {
  const workspaceId = newChatWorkspaceId.value
  // No active workspace means no chat is possible. The button is disabled
  // in this state, but guard anyway — a programmatic call must not
  // quietly create a workspace as a side effect of a sidebar click.
  if (!workspaceId) return
  if (isCreatingChat.value) return
  isCreatingChat.value = true
  try {
    const project = await workspacesStore.ensureDefaultProject(workspaceId)
    // undefined means the ensure failed. Do NOT navigate and do NOT
    // fabricate a local item — a wrong project id would land the user on
    // a project that does not exist, which is worse than doing nothing.
    if (!project) return
    await createAndOpenStandardChat(workspaceId, project.id)
  } finally {
    isCreatingChat.value = false
  }
}

// Open the picker when the user clicks the green `+` on a
// non-agent workspace item. Chunk 6: previously this directly
// created a `Task <time>` row and auto-navigated. Now we route
// through AddTaskPickerDialog → AddTaskDialog / AddRoutineDialog /
// AddMemoryDialog. Kanban items handle "+ Add" locally inside
// KanbanView.vue (no picker — kanban cards are always standard
// chats; the picker is for non-kanban parents where the user might
// want a routine / memory / chat task).
//
// Agent-mode items (`item_type === 'agent'`) skip the picker entirely
// (2026-09-09): an agent item IS a chat container, so `+` directly
// creates a Standard Chat and opens it — no Routine / Memory choice.
//
// Routine items have no task list — the + button is hidden in
// WorkspaceItem.vue, but guard here too so a programmatic call
// can't open the picker under a scheduler-owned parent.
const handleAddTask = (workspaceId: string, item: WorkspaceItem) => {
  if (item.item_type === 'routine') return
  if (item.item_type === 'agent') {
    void createAndOpenStandardChat(workspaceId, item.id)
    return
  }
  pickerWorkspaceId.value = workspaceId
  pickerItemId.value = item.id
  showAddTaskPicker.value = true
}

// Route the pick to the right create flow. The picker dialog
// self-closes on pick (see AddTaskPickerDialog.vue: handleStandard,
// handleRoutine, and handleMemory emit both 'pick' and 'close'),
// so the @close handler (handleCloseAddTaskPicker) runs as a side
// effect of the pick — no explicit close call needed here.
//
// For 'standard' we DON'T show a dialog. The previous flow opened
// AddTaskDialog asking for a name + description, but that was pure
// friction: the user just clicked "Standard Chat", they want to
// start chatting, not write a name. Auto-create a task named
// "New Chat" and navigate straight to its ChatView. The chat name
// is editable later via the rename modal on the task row (and via
// the auto-rename-on-first-message convention that already runs
// in ChatView's stream lifecycle).
const handleAddTaskPick = async (taskType: 'standard' | 'memory') => {
  const workspaceId = pickerWorkspaceId.value
  const itemId = pickerItemId.value
  // Clear the picker targets FIRST so a re-entry from the auto-create
  // path (which itself triggers router.replace) doesn't leak the
  // workspaceId/itemId into a future accidental re-open.
  pickerWorkspaceId.value = null
  pickerItemId.value = null

  if (taskType === 'standard') {
    // No dialog — auto-create + navigate via the shared helper (also
    // used by the agent-mode direct path in `handleAddTask`).
    if (!workspaceId || !itemId) return
    await createAndOpenStandardChat(workspaceId, itemId)
    return
  }

  // 'memory' (2026-06-20): open AddMemoryDialog in `mode='task'` (it won't call the API itself; the
  // create callback here calls addTask with taskType='memory' which triggers the backend's
  // file-write + task-insert in one POST).
  addMemoryTaskWorkspaceId.value = workspaceId
  addMemoryTaskItemId.value = itemId
  showAddMemoryTaskDialog.value = true
}

const handleCloseAddTaskPicker = () => {
  showAddTaskPicker.value = false
  pickerWorkspaceId.value = null
  pickerItemId.value = null
}

// Memory task flow (2026-06-20). AddMemoryDialog in `mode='task'`
// emits `create(name, content, path)` when the user submits; we
// forward to addTask which POSTs to the backend with
// taskType='memory'. The backend's task_create.zig handles the
// .md file write AND the workspace_item_tasks INSERT in one call
// (and rolls back the .md on task-row failure — no orphan files).
//
// We do NOT navigate to the new memory task — memory tasks have
// no chat session (the .md file IS the content; the AI reads it
// on the next chat in this workspace). The task row shows up in
// the sidebar's task list where the user can inspect it.
const handleCreateMemoryTask = async (name: string, content: string) => {
  const workspaceId = addMemoryTaskWorkspaceId.value
  const itemId = addMemoryTaskItemId.value
  if (!workspaceId || !itemId) return
  await workspacesStore.addTask(workspaceId, itemId, {
    name,
    taskType: 'memory',
    memory: { name, content },
  })
  showAddMemoryTaskDialog.value = false
  addMemoryTaskWorkspaceId.value = null
  addMemoryTaskItemId.value = null
  // Defensive: close the picker too. AddTaskPickerDialog already self-closes on pick, but the
  // create callback is the last word on dialog state — see handleAddTaskCreated for the same
  // rationale applied to the standard path.
  handleCloseAddTaskPicker()
}

const handleCloseAddMemoryTaskDialog = () => {
  showAddMemoryTaskDialog.value = false
  addMemoryTaskWorkspaceId.value = null
  addMemoryTaskItemId.value = null
}

// The single owner of the task-delete confirmation. Every delete path (kanban card context menu,
// kanban row button, sidebar task row) arrives here, so naming the task is what tells the user
// which card they are about to destroy — the menu they just used to pick it.
const handleDeleteTask = (workspaceId: string, itemId: string, taskId: string) => {
  const item = workspacesStore.workspaces
    .find((w) => w.id === workspaceId)
    ?.items.find((i) => i.id === itemId)
  const taskName = item?.tasks?.find((t) => t.id === taskId)?.name
  openDeleteConfirm({
    title: 'Delete task',
    message: taskName
      ? `“${taskName}” will be permanently deleted. This cannot be undone.`
      : 'This task will be permanently deleted. This cannot be undone.',
    onConfirm: () => workspacesStore.deleteTask(workspaceId, itemId, taskId),
  })
}

const handleSelectTask = async (taskId: string) => {
  const currentSorts = route.query?.sorts
  if (typeof currentSorts === 'string' && currentSorts.length > 0) {
    workspacesStore.savedSortsParam = currentSorts
  }
  // FIX (task-url-overwrite, task_1785959660154, 2026-08-06):
  // Set the navigation flag BEFORE mutating the store. The
  // AppLayout URL sync watcher reads `workspacesStore.isNavigatingToTask`
  // and returns early when it's true — closing the race window
  // between setActiveTask's synchronous store mutation (which
  // fires the watcher) and Vue Router's asynchronous URL update
  // (which would otherwise leave the watcher seeing
  // `route.query.view === 'workspace'` and clobbering the in-flight
  // task URL with `router.replace({ view: 'workspace', ... })`).
  workspacesStore.isNavigatingToTask = true
  try {
    workspacesStore.setActiveTask(taskId)
    if (chatsListRef.value) {
      chatsListRef.value.resetActiveChat()
    }
    // NEW (better-url-browser, 2026-08-06): APPEND the URL instead
    // of REPLACE. The user reported "when click task in kanban, no
    // need replace url, but append the url browser" — clicking a
    // kanban task used to write a lean `?view=task&task=X&itemId=Y`
    // URL via router.replace, which (a) dropped the workspace +
    // per-column sort context the user was on, and (b) clobbered the
    // browser history so the back button skipped the kanban URL.
    //
    // Now we PUSH the new URL with the current route.query spread
    // underneath, then override `view`, `task`, and `itemId`. This:
    //   1. Preserves the breadcrumb (workspaceId / pageId / sorts)
    //      so a refresh of the task URL still carries the kanban
    //      context, matching the sidebar's mental model of "I'm on
    //      kanban X, opened task Y from column Z".
    //   2. Keeps the previous URL in the browser history so the back
    //      button returns naturally to the kanban URL (no need to
    //      manually pre-fill `savedSortsParam` for back-restore).
    //   3. Still works for deep links — if the user landed on the
    //      task URL via bookmark with NO workspace context, the
    //      spread copies nothing and the resulting URL stays lean.
    //
    // The `savedSortsParam` snapshot above remains the close-restore
    // fallback for cases where AppLayout's handleCloseTaskView runs
    // WITHOUT the URL having preserved context (e.g. an older URL
    // pattern that lands on task without kanban context).
    //
    // NEW (add-workspace-id-params, 2026-08-06): always include
    // workspaceId + itemId + pageId from the active store state, with
    // the URL breadcrumb as a fallback. Pre-fix the URL could end up
    // as `?view=task&task=X&itemId=Y` (no workspaceId) when the user
    // landed on a kanban URL that didn't include workspaceId — sharing
    // / refreshing that URL lost the workspace context. The helper
    // reads from the store FIRST (authoritative source) and falls back
    // to the current URL only when no active store state exists.
    //
    // `await router.push(...)` is critical: Vue Router updates the
    // route ref asynchronously (during the navigation guard / scroll
    // sequence). Awaiting ensures the URL is `view=task&task=X` by
    // the time any subsequent watcher fires. Even with the flag
    // guard, awaiting is the cleanest close — the flag's `finally`
    // clears only after the navigation is committed.
    const target = buildTaskAppUrl({
      taskId,
      activeWorkspaceId: workspacesStore.activeWorkspace?.id ?? null,
      activeWorkspaceItemId: workspacesStore.activeWorkspaceItemId,
      activeDesignPageId: workspacesStore.activeDesignPageId,
      activeItemType: workspacesStore.activeWorkspaceItem?.item_type ?? null,
      currentQuery: route.query,
    })
    // handleSelectTask uses router.push (NOT replace) so the previous
    // kanban / design URL stays in the browser history and the back
    // button returns naturally (better-url-browser, 2026-08-06). The
    // `itemId` derived from `activeWorkspaceItemId` is included via the
    // helper's store-derived value (NOT the `parentItemId` we computed
    // above — they should be equal but the store is authoritative).
    await router.push(target)
  } finally {
    workspacesStore.isNavigatingToTask = false
  }
}

// pickBreadcrumbFromQuery moved to `helpers/buildTaskUrlQuery.ts`
// (add-workspace-id-params plan, 2026-08-06) so it can be shared
// across Sidebar, AppLayout, and any future task-URL builders.

const handleLoadMoreTasks = (workspaceId: string, itemId: string) => {
  // Click-to-load pagination: invoked by the "Load more" button in
  // WorkspaceItem.vue. The store action is the only place that calls
  // api.getTasks with a cursor — no auto-load / scroll listener /
  // intersection observer. Mirrors the _loadMoreChats pattern in
  // ChatsList.vue:121-183.
  //
  // Per-column pagination (kanban-per-column-pagination plan,
  // 2026-08-06): the sidebar's "Load more" picks the FIRST column
  // with hasMore=true and fetches that column's next page. This
  // matches the user's mental model: "I clicked Load more on the
  // sidebar; give me more tasks for this board" (the first column
  // that still has more is the cheapest visible next-page).
  const workspace = workspacesStore.workspaces.find((w) => w.id === workspaceId)
  const item = workspace?.items.find((i) => i.id === itemId)
  if (!item) return
  const colPagination = item.columnPagination ?? {}
  for (const [columnId, state] of Object.entries(colPagination)) {
    if (state.hasMore && !state.isLoading) {
      void workspacesStore.loadMoreTasksForColumn(workspaceId, itemId, columnId)
      return
    }
  }
}

// Item-level reorder (the revamp plan removed workspace-level reorder
// from the UI; the store action + API remain). <ProjectsList> emits
// the workspaceId + orderedItemIds payload on a successful drop; the
// store action does the optimistic update + API call + silent rollback
// on error. Plan:
// docs/superpowers/plans/2026-06-16-workspace-item-position-reorder.md
const handleReorderWorkspaceItems = (workspaceId: string, orderedItemIds: string[]) => {
  workspacesStore.reorderWorkspaceItems(workspaceId, orderedItemIds)
}

// NEW (pinned-tasks feature, plan:
// docs/superpowers/plans/2026-06-20-pinned-workspace-item-tasks.md):
// pin/unpin and drag-reorder of the pinned subset, both forwarded
// from <WorkspaceItem> via <ProjectsList>. The store actions
// perform the optimistic update + API call + silent rollback.
const handlePinTask = (workspaceId: string, itemId: string, taskId: string, isPinned: boolean) => {
  workspacesStore.pinTask(workspaceId, itemId, taskId, isPinned)
}

// NEW (design-pages-in-workspace-tree plan, 2026-08-06): the design
// page events from the sidebar tree. WorkspaceItem already set
// activeDesignPageId + activeWorkspaceItemId on `select-design-page`
// (so the store is in the right state before this handler runs);
// we just need to navigate AppLayout to the design view. The
// design-view mount reads the activeDesignPageId from the store
// and renders the page.
//
// FIX (2026-08-06, post-#169 fix): the previous implementation
// was a no-op — it relied on AppLayout's URL-sync watcher (line
// 237 in AppLayout.vue) to mirror the store change into the URL.
// But that watcher has a guard `currentView !== 'workspace' &&
// currentView !== undefined → return` — meaning it REFUSES to
// overwrite the URL when the user is on a different view (e.g.
// `?view=task&task=X`). So when the user was on a chat task
// view (their last navigation), clicked a page in the sidebar,
// the store updated but the URL stayed at `?view=task&task=X`
// and the canvas didn't switch to DesignView. The user reported:
// *"when i click its not go to design mode"*.
//
// The fix: explicitly emit `navigate` to switch the URL to
// `?view=workspace&workspaceId=X&itemId=Y&pageId=Z`. AppLayout's
// `handleNavigate('workspace', ...)` does `router.replace(...)`
// which switches the URL view off task/chat back to workspace.
// Once on workspace view, the watcher syncs pageId too.
const handleSelectDesignPage = (workspaceId: string, itemId: string, pageId: string) => {
  // WorkspaceItem already activated the item + set the page.
  // We intentionally don't re-call setActiveWorkspaceItem here
  // to avoid duplicate AppLayout re-renders (WorkspaceItem's
  // handler guards that call on activeWorkspaceItemId !== item.id).
  //
  // Emit `navigate` with view='workspace' + workspaceId + itemId +
  // pageId to switch the URL off the current view (e.g. ?view=task)
  // and into the design view, with the page id preserved in the
  // URL for reload resilience. AppLayout.handleNavigate now reads
  // the 6th positional arg (pageId) and writes it to the query.
  emit('navigate', 'workspace', undefined, undefined, workspaceId, itemId, pageId)
}

// NEW (2026-08-06, task 1785912441877): design-page delete now
// requires confirmation, matching the existing pattern for
// workspaces / items / tasks (`handleDeleteWorkspace` etc.).
//
// Clicking × on a design page in the sidebar tree is too easy to
// do by accident — every other delete (workspace / item / task)
// already shows the <ConfirmDialog>. The store's
// `deleteDesignPage` action still handles cache + active-page
// fallback + error notification; we just gate it behind the same
// confirm dialog so a stray click can't nuke a page.
const handleDeleteDesignPage = (workspaceId: string, itemId: string, pageId: string) => {
  openDeleteConfirm({
    title: 'Delete Page',
    message: 'Delete this design page? This cannot be undone.',
    onConfirm: async () => {
      try {
        await workspacesStore.deleteDesignPage(workspaceId, itemId, pageId)
      } catch (err) {
        const message = err instanceof Error ? err.message : String(err)
        useNotificationStore().notifyError('Failed to delete page', message)
      }
    },
  })
}

// "+ Add Page" button. The store's `addDesignPage` action returns
// the new page object; we set it as active so the canvas shows the
// empty new page (matching DesignView's pre-fix handleAddPage
// behaviour). Also expands the design item if it isn't already
// (otherwise the new page row appears collapsed inside the
// sidebar, which is confusing for the user).
const handleAddDesignPage = async (workspaceId: string, itemId: string) => {
  // Expand first so the user sees the new row appear.
  if (workspacesStore.expandedItemIds[itemId] !== true) {
    workspacesStore.toggleExpandedItem(itemId)
  }
  // Pick the next untitled name (mirrors DesignView's pre-fix
  // `computeNextUntitledName` — same high-water-mark + 1 rule).
  const pages = workspacesStore.designPagesByItemId[itemId] ?? []
  const name = computeNextUntitledName(pages)
  try {
    const created = await workspacesStore.addDesignPage(workspaceId, itemId, name)
    if (created) {
      // The store's `addDesignPage` action already set the new page as active (matches pre-fix
      // DesignView handleAddPage). We only need to activate the design item so AppLayout routes to
      // DesignView.
      if (workspacesStore.activeWorkspaceItemId !== itemId) {
        workspacesStore.setActiveWorkspaceItem(itemId)
      }
    }
  } catch (err) {
    const message = err instanceof Error ? err.message : String(err)
    useNotificationStore().notifyError('Failed to add page', message)
  }
}

// Compute the next untitled name (mirrors DesignView's pre-fix `computeNextUntitledName`). Copied
// here to keep the sidebar logic independent of DesignView — the function is 20 lines and
// Sidebar/DesignView don't share a common parent module.
const UNTITLED_BASE = 'Untitled'
const UNTITLED_PATTERN = /^Untitled (\d+)$/
function computeNextUntitledName(existingPages: ReadonlyArray<{ name: string }>): string {
  let hasUnnumbered = false
  let maxNumbered = 0
  for (const p of existingPages) {
    if (p.name === UNTITLED_BASE) {
      hasUnnumbered = true
      continue
    }
    const match = UNTITLED_PATTERN.exec(p.name)
    if (match && match[1]) {
      const n = Number.parseInt(match[1], 10)
      if (Number.isFinite(n) && n > 0 && n > maxNumbered) {
        maxNumbered = n
      }
    }
  }
  if (!hasUnnumbered && maxNumbered === 0) return UNTITLED_BASE
  return `${UNTITLED_BASE} ${maxNumbered + 1}`
}

const handleReorderPinnedTasks = (workspaceId: string, itemId: string, orderedIds: string[]) => {
  workspacesStore.reorderPinnedTasks(workspaceId, itemId, orderedIds)
}

// ─── Routines (Chunk 7 of task-routines plan) ────────────────────────────
// These two handlers close the wiring loop from the routine-task
// row in WorkspaceItemTask.vue (which emits `runRoutine` and
// `editRoutine`) up through WorkspaceItem → ProjectsList → here.
// Sidebar is the only component that touches the store, so it
// owns the user-visible side effects (route to chat).
//
// NOTE: per-task routine handlers (handleRunRoutine,
// handleEditRoutine + EditRoutineDialog plumbing) were deleted with
// per-task routines (Migration 084, plan
// 2026-09-10-workspace-items-routines). Workspace-level routines
// fire via RoutineView → workspacesStore.runRoutineItem.

// ─── Kanban handlers ────────────────────────────────────────────────────────
//
// The kanban board lives in the main content area (rendered by
// <AppLayout> when activeWorkspaceItem.item_type === 'kanban'), not
// inline in the sidebar anymore. AppLayout's <KanbanView> wires its
// events directly to the workspaces store (moveTaskToColumn,
// addKanbanColumn, updateKanbanColumn, deleteKanbanColumn) — see
// AppLayout.vue's handle*Kanban* functions. The only Sidebar-side
// concern is the "+ Add" button on a column, which opens the
// AddTaskPickerDialog; that flow is exposed via `openTaskPicker`
// (see defineExpose below) and called by AppLayout.
//
// Kept here for reference (deleted in this commit):
//   - handleAddKanbanTask    (replaced by AppLayout's call to
//                             sidebarRef.openTaskPicker)
//   - handleMoveKanbanTask   (moved to AppLayout's
//                             handleKanbanMoveTask)
//   - handleAddKanbanColumn  (moved to AppLayout's
//                             handleKanbanAddColumn)
//   - handleRenameKanbanColumn (moved to AppLayout's
//                               handleKanbanRenameColumn)
//   - handleDeleteKanbanColumn (moved to AppLayout's
//                               handleKanbanDeleteColumn)

// Expose the task event handlers for AppLayout to call when the
// kanban board (now mounted in the main content area, not the
// sidebar) emits select-task / delete-task / rename-task /
// pin-task. AppLayout holds the
// kanban view; the handlers themselves still live here because
// they need access to the modal state (rename, edit-routine) and
// the chatsList ref (select-task resets the chat row's active
// state). Re-exporting via defineExpose keeps the kanban events
// in the same place the original WorkspaceItem path was using.
//
// Placed at the end of the script (rather than with the other
// state) so the handler references are not in the temporal dead
// zone — the arrow functions are only invoked from AppLayout at
// runtime, by which point all `handle*` consts are initialized.
defineExpose({
  updateChatId,
  openTaskPicker,
  // Pass-throughs for the kanban's task events. The signature
  // matches the existing handlers exactly; AppLayout's KanbanView
  // forwards its emitted events to these.
  selectTask: (taskId: string) => handleSelectTask(taskId),
  deleteTask: (workspaceId: string, itemId: string, taskId: string) =>
    handleDeleteTask(workspaceId, itemId, taskId),
  renameTask: (workspaceId: string, itemId: string, taskId: string, currentName: string) =>
    handleRenameTask(workspaceId, itemId, taskId, currentName),
  pinTask: (workspaceId: string, itemId: string, taskId: string, isPinned: boolean) =>
    handlePinTask(workspaceId, itemId, taskId, isPinned),
})
</script>

<template>
  <aside
    class="h-screen flex flex-col relative transition-all duration-200 ease-out select-none"
    :style="{
      width: isCollapsed ? '64px' : sidebarWidth + 'px',
      backgroundColor: 'var(--semantic-sidebar-bg)',
      borderRight: '1px solid var(--color-border)',
    }"
  >
    <!-- Resize Handle -->
    <div
      v-if="!isCollapsed"
      class="absolute right-0 top-0 bottom-0 w-1 cursor-col-resize z-10 opacity-0 hover:opacity-100 transition-opacity"
      style="background: var(--color-violet)"
      @mousedown="startResize"
    />

    <!-- Collapse/Expand Button. A minimal chevron-only button — no
         shadow, no scale on hover, just a thin border that matches
         the sidebar's typographic treatment. The chevron points in
         the *target* direction (left when expanded, right when
         collapsed) so the click intent reads at a glance.

         `top-24` (96px), not `top-16` (64px): this button is absolutely
         positioned, so it does NOT move when content is inserted above
         it. The 48px header plus the 40px New Chat row ends at 88px,
         which means `top-16` would leave the chevron sitting ON TOP of
         the New Chat row, swallowing its clicks. -->
    <button
      @click="toggleCollapse"
      data-testid="sidebar-collapse-toggle"
      class="absolute -right-2.5 top-24 z-20 w-5 h-5 rounded flex items-center justify-center transition-colors duration-150"
      style="background: var(--semantic-card-bg); border: 1px solid var(--color-border)"
      :title="isCollapsed ? 'Expand sidebar' : 'Collapse sidebar'"
      :aria-label="isCollapsed ? 'Expand sidebar' : 'Collapse sidebar'"
    >
      <svg
        class="w-3 h-3 transition-transform duration-150"
        :style="{
          color: 'var(--semantic-text-dim)',
          transform: isCollapsed ? 'rotate(180deg)' : 'rotate(0deg)',
        }"
        fill="none"
        viewBox="0 0 24 24"
        stroke="currentColor"
      >
        <path stroke-linecap="round" stroke-linejoin="round" stroke-width="2" d="M15 19l-7-7 7-7" />
      </svg>
    </button>

    <!-- Header. Minimal text-driven header — no logo gradient
         pill, no decorative sub-label. Two layouts: collapsed shows
         a thin monogram of the active workspace; expanded shows the
         WorkspaceSwitcher dropdown (current workspace name + chevron)
         + a small settings/logout pair. The thin border-bottom keeps
         the section boundary visible without any visual heaviness.
         Plan: docs/plans/2026-09-22-revamp-workspace-ui-dropdown-projects.md -->
    <div
      class="h-12 flex items-center shrink-0"
      :class="isCollapsed ? 'justify-center px-0' : 'px-[var(--sb-gutter)] justify-between'"
      style="border-bottom: 1px solid var(--color-border)"
    >
      <div
        v-if="!isCollapsed"
        class="flex items-center gap-2 min-w-0"
        data-testid="sidebar-header-expanded"
      >
        <WorkspaceSwitcher
          :workspaces="workspacesStore.workspaces"
          :active-workspace-id="workspacesStore.activeWorkspace?.id ?? null"
          @select="handleSwitcherSelect"
          @open-workspace-in-background="handleOpenWorkspaceInBackground"
          @add-workspace="handleAddWorkspace"
          @rename-workspace="handleRenameWorkspace"
          @delete-workspace="handleDeleteWorkspace"
        />
      </div>
      <WorkspaceSwitcher
        v-else
        collapsed
        :workspaces="workspacesStore.workspaces"
        :active-workspace-id="workspacesStore.activeWorkspace?.id ?? null"
        @select="handleSwitcherSelect"
        @open-workspace-in-background="handleOpenWorkspaceInBackground"
        @add-workspace="handleAddWorkspace"
        @rename-workspace="handleRenameWorkspace"
        @delete-workspace="handleDeleteWorkspace"
        data-testid="sidebar-header-collapsed"
      />
      <div v-if="!isCollapsed" class="flex items-center gap-3">
        <button
          @click="goToSettings"
          class="text-micro font-medium transition-colors duration-150 hover:text-[--semantic-text]"
          style="color: var(--semantic-text-dim)"
          title="Settings"
          aria-label="Settings"
          data-testid="sidebar-settings-button"
        >
          Settings
        </button>
        <button
          v-if="authEnabled"
          :disabled="loggingOut"
          @click="handleLogout"
          class="text-micro font-medium transition-colors duration-150 hover:text-[--semantic-text]"
          style="color: var(--semantic-text-dim)"
          title="Log out"
          aria-label="Log out"
          data-testid="sidebar-logout-button"
        >
          {{ loggingOut ? '…' : 'Logout' }}
        </button>
      </div>
    </div>

    <!-- New Chat. Sits between the header and the content, above ChatsList,
         because it is the one action that never needs a project picked
         first: it creates the chat inside the workspace's DEFAULT project
         (Migration 094 — an agent-mode item whose path is the server
         user's home directory, so the chat runs with $HOME as its cwd).
         The server ensures that default on every items read, so this is
         normally a pure local find with no round trip.

         Bare text, matching the Settings/Logout weight above rather than a
         filled pill: the 2026-09-22 revamp moved this whole sidebar to a
         text-driven treatment and a heavy button would fight it. Collapsed
         to a 64px rail it becomes an icon — a 64px rail must not drop the
         only always-visible chat affordance, and the label moves to
         title/aria-label. -->
    <button
      data-testid="sidebar-new-chat-button"
      class="h-10 flex items-center gap-2 shrink-0 px-[var(--sb-gutter)] border-b transition-colors duration-150 disabled:cursor-not-allowed disabled:opacity-40"
      :class="isCollapsed ? 'justify-center px-0' : 'hover:bg-[var(--semantic-card-bg)]'"
      style="border-color: var(--color-border)"
      :disabled="!newChatWorkspaceId || isCreatingChat"
      :title="
        !newChatWorkspaceId
          ? 'Select a workspace first'
          : isCollapsed
            ? 'New Chat'
            : 'Start a new chat in the default project'
      "
      aria-label="New Chat"
      @click="handleNewChat"
    >
      <span
        class="w-[var(--sb-hit)] text-center text-meta leading-none"
        :style="{ color: 'var(--semantic-text-dim)' }"
        aria-hidden="true"
        >{{ isCreatingChat ? '◌' : '✎' }}</span
      >
      <span
        v-if="!isCollapsed"
        class="text-dense font-medium"
        :style="{ color: 'var(--semantic-text-dim)' }"
        >New Chat</span
      >
    </button>

    <!-- Content. This <nav> is the ONE vertical scroller for the panel:
         Recent + Projects + Documents stack in one flow and scroll
         together.

         It used to be `overflow-hidden` with a `flex-1 min-h-0` wrapper
         around <ProjectsList>, so Projects absorbed ALL leftover height
         and <DocumentsList> (`shrink-0`, last child) was pushed to the
         very bottom of the sidebar — separated from Projects by a
         screen-tall empty box whenever the project list was short. The
         section is documented as living BELOW Projects, so nothing may
         grow to fill the gap. -->
    <nav
      class="flex-1 flex flex-col min-h-0 overflow-y-auto overflow-x-hidden"
      :class="isCollapsed ? 'px-2 py-3' : 'py-2'"
    >
      <!-- Chats List Component -->
      <ChatsList ref="chatsListRef" :collapsed="isCollapsed" @navigate="handleChatsNavigate" />

      <!-- Workspaces. `shrink-0`, NOT `flex-1`: the section must be as
           tall as its rows and no taller, so the next section starts
           directly under the last project row. -->
      <div class="shrink-0">
        <ProjectsList
          v-if="!isCollapsed"
          :workspace="workspacesStore.activeWorkspace ?? null"
          :active-workspace-item-id="workspacesStore.activeWorkspaceItemId"
          @select-item="handleSelectItem"
          @open-item-in-background="handleOpenItemInBackground"
          @delete-item="handleDeleteItem"
          @request-add-item="handleAddItem"
          @add-task="handleAddTask"
          @select-task="handleSelectTask"
          @open-task-in-background="handleOpenTaskInBackground"
          @delete-task="handleDeleteTask"
          @rename-task="handleRenameTask"
          @load-more-tasks="handleLoadMoreTasks"
          @reorder-workspace-items="handleReorderWorkspaceItems"
          @pin-task="handlePinTask"
          @reorder-pinned-tasks="handleReorderPinnedTasks"
          @select-design-page="handleSelectDesignPage"
          @delete-design-page="handleDeleteDesignPage"
          @add-design-page="handleAddDesignPage"
          @rename-design-page="handleRenameDesignPage"
          @open-design-page-in-background="handleOpenDesignPageInBackground"
          @go-to-settings="handleGoToSettings"
        />
      </div>

      <!-- Documents (Migration 095). Its own section BELOW Projects — a
           document belongs to the workspace, not to a project, so it
           never appears inside the project tree.

           `activeWorkspace?.id`, NOT the raw `activeWorkspaceId` ref: the
           ref is only set by the header dropdown or a `?workspaceId=` URL
           restore, so a user who navigates by clicking a project row got
           "No workspace selected" with a workspace plainly selected. The
           computed carries the documented precedence fallback — explicit →
           persisted → item-owning workspace → first workspace. Every other
           consumer in this file (WorkspaceSwitcher, ProjectsList) binds it
           the same way. -->
      <DocumentsList
        v-if="!isCollapsed"
        :workspace-id="workspacesStore.activeWorkspace?.id ?? null"
      />
    </nav>

    <!-- Modals -->
    <WorkspaceModal
      :show="showAddWorkspaceModal"
      @close="handleCloseModal"
      @create="handleCreateWorkspace"
    />
    <RenameWorkspaceModal
      :show="showRenameWorkspaceModal"
      :current-name="renameTargetName"
      @close="handleCloseRenameModal"
      @rename="handleConfirmRename"
    />
    <RenameTaskModal
      :show="showRenameTaskModal"
      :current-name="renameTargetTaskName"
      @close="handleCloseTaskRenameModal"
      @rename="handleConfirmTaskRename"
    />
    <!-- NEW (rename-design-pages, 2026-08-06): ⋮ menu "Rename"
         opens this modal; confirm fires workspaceStore.renameDesignPage
         which PATCHes the page + optimistically updates the local cache. -->
    <RenameDesignPageModal
      :show="showRenameDesignPageModal"
      :current-name="renameTargetDesignPageName"
      @close="handleCloseDesignPageRenameModal"
      @rename="handleConfirmDesignPageRename"
    />
    <AddItemDialog
      :show="showAddItemDialog"
      @close="handleCloseAddItemDialog"
      @create="handleCreateItem"
    />
    <AddKanbanDialog
      :show="showAddKanbanDialog"
      @close="handleCloseAddKanbanDialog"
      @create="handleCreateKanban"
    />
    <!-- NEW (design-mode feature): modal for creating a design-mode
         workspace item. Wired to the 'design' itemType in
         handleAddItem (above). See AddDesignDialog.vue for the
         internal flow. Plan:
         docs/superpowers/plans/2026-06-13-design-mode.md. -->
    <AddDesignDialog
      :show="showAddDesignDialog"
      @close="handleCloseAddDesignDialog"
      @create="handleCreateDesign"
    />
    <AddAgentDialog
      :show="showAddAgentDialog"
      @close="handleCloseAddAgentDialog"
      @create="handleCreateAgent"
    />
    <!-- Workspace routines (Migration 084): modal for creating a
         routine-mode workspace item. Wired to the 'routine' itemType
         in handleAddItem (above). -->
    <AddRoutineItemDialog
      :show="showAddRoutineItemDialog"
      @close="handleCloseAddRoutineItemDialog"
      @create="handleCreateRoutineItem"
    />
    <AddMemoryDialog
      :show="showAddMemoryDialog"
      :cwd="addMemoryTargetWorkspaceId ? resolveCwdForMemory(addMemoryTargetWorkspaceId) : ''"
      @close="handleCloseAddMemoryDialog"
      @create="handleCreateMemory"
    />
    <AddTaskPickerDialog
      :show="showAddTaskPicker"
      @close="handleCloseAddTaskPicker"
      @pick="handleAddTaskPick"
    />
    <!-- AddTaskDialog was removed in 2026-07-26 — the "Standard Chat"
         path now auto-creates the task + navigates straight to its
         ChatView, no name/description prompt. See handleAddTaskPick.
         (AddRoutineDialog was removed in Migration 084 — routines are
         workspace items now, see AddRoutineItemDialog above.) -->
    <AddMemoryDialog
      v-if="addMemoryTaskItemId"
      :show="showAddMemoryTaskDialog"
      :cwd="resolveCwdForItem(addMemoryTaskItemId)"
      mode="task"
      @close="handleCloseAddMemoryTaskDialog"
      @create="handleCreateMemoryTask"
    />
    <ConfirmDialog
      :show="showDeleteConfirm"
      :title="deleteConfirmConfig?.title || 'Confirm'"
      :message="deleteConfirmConfig?.message || ''"
      confirm-text="Delete"
      @close="handleDeleteConfirmClose"
      @confirm="handleDeleteConfirm"
    />
  </aside>
</template>

<style scoped>
/* Smooth transitions */
aside {
  transition: width 0.2s ease-out;
}
</style>
