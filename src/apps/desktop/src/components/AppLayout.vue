<script setup lang="ts">
import { ref, computed, onMounted, onUnmounted, onUpdated, provide } from 'vue'
import { useRouter, useRoute } from 'vue-router'
import Sidebar from './shell/Sidebar.vue'
import GitFileViewer from './git/GitFileViewer.vue'
import SkillDetail from './shell/SkillDetail.vue'
import ChatView from './views/ChatView.vue'
import StandardTaskChatView from './views/StandardTaskChatView.vue'
import Chats from './views/Chats.vue'
import DocumentsView from './workspace/DocumentsView.vue'
import SettingsView from './views/SettingsView.vue'
import WorkspaceSettingsView from './views/WorkspaceSettingsView.vue'
import CodeViewerStage from './views/CodeViewerStage.vue'
import NotificationContainer from './shell/NotificationContainer.vue'
import SseStatusBadge from './shell/SseStatusBadge.vue'
import KanbanView from './kanban/KanbanView.vue'
import DesignChatDialog from './design/DesignChatDialog.vue'
import AgentView from './views/AgentView.vue'
import type { AgnosticKnowledgeRow, AgnosticSystemPromptRow } from './views/AgentView.vue'
import RoutineView from './views/RoutineView.vue'
import AgentChatView from './views/AgentChatView.vue'
import AgentKnowledgeDialog from './dialogs/AgentKnowledgeDialog.vue'
import AgentSystemPromptDialog from './dialogs/AgentSystemPromptDialog.vue'
import AgentKnowledgeDetailDialog from './dialogs/AgentKnowledgeDetailDialog.vue'
import KanbanColumnEditor from './kanban/KanbanColumnEditor.vue'
import KanbanSettingsView from './views/KanbanSettingsView.vue'
import CopyKanbanSpecDialog from './dialogs/CopyKanbanSpecDialog.vue'
import DesignView from './design/DesignView.vue'
import UiIcon from './ui/UiIcon.vue'
import { useNavigationStore } from '../stores/navigation'
import { useTabsStore } from '../stores/tabs'
import { sameRouteQuery, withTabParam } from '../helpers/tabTarget'
import { useTabShortcuts } from '../composables/useTabShortcuts'
import { useWorkspacesStore, type Task as TaskType } from '../stores/workspaces'
import { useSidebarStore } from '../stores/sidebar'
import { useKanbanSseStore } from '../stores/kanbanSse'
import { useDesignSseStore } from '../stores/designSse'
import * as api from '../api'
import type { DesignElement as DesignElementApi } from '../api'
import { buildToggle } from '../stores/agentToolToggle'
import {
  CODE_VIEWER_STATE_KEY,
  OPEN_IN_CODE_EDITOR_KEY,
  type CodeViewerState,
  type OpenInCodeEditorFn,
  type OpenInCodeEditorOptions,
} from '../composables/useCodeEditor'
import { useCodeEditorSession } from '../composables/useCodeEditorSession'
import { useDesignHandlers } from '../composables/useDesignHandlers'
import { useCurrentMainView } from '../composables/useCurrentMainView'
import {
  buildAppUrl,
  buildSettingsUrl,
  buildTaskAppUrl,
  isAppPath,
  normalizeAppPath,
  parseAppPath,
  type AppUrlLocation,
} from '../helpers/appUrl'
import { openInNewTab } from '../helpers/openInNewTab'
import { parseItemIdWithChat } from '../helpers/buildItemIdWithChat'
import { isWorkspaceAgentSection } from '../helpers/configSource'
import { resolveWorkspaceId } from '../helpers/workspaceScope'

const router = useRouter()
const route = useRoute()
const navigationStore = useNavigationStore()
const tabsStore = useTabsStore()
const workspacesStore = useWorkspacesStore()
// URL-derived main view (path-based contract) — used by navigations
// that need the current workspace without reading store flags.
const currentMainView = useCurrentMainView()
// eslint-disable-next-line @typescript-eslint/no-unused-vars -- kept for diff readability.
const sidebarStore = useSidebarStore()

// Ref to Sidebar component
const sidebarRef = ref<InstanceType<typeof Sidebar> | null>(null)

// Dev-only FPS overlay (desktop scroll-perf plan, Task 5): lets us
// measure platform rendering fixes (Linux gfx pinning, macOS scheme
// handler, Windows resize coalescing) in the running app. mount() is a
// no-op in prod builds; unmount on teardown keeps HMR clean.
import { mount as mountFpsOverlay, unmount as unmountFpsOverlay } from '../helpers/fpsOverlay'
onMounted(() => {
  mountFpsOverlay()
})
onUnmounted(() => {
  unmountFpsOverlay()
})

// Settings overlay state (now driven by route)

onMounted(() => {
  void handleBootUrl()
})

// Boot URL handling (plan: 2026-09-22-revamp-ui-chats).
//
// Canonical paths boot directly from the path (workspace/chat/project
// restore below). Legacy URLs are rewritten once via router.replace to
// the path contract — bookmarks / shared links from before the
// migration land here exactly once:
//
//   /app/chat/:sid            → /app/{ws}/chat/:sid  (ws via session detail)
//   /app/task/:tid            → /app/{ws}/projects/{item}/chat/:tid
//   ?view=chat&session=X      → /app/{ws}/chat/X     (ws via session detail)
//   ?view=task&task=X&…       → /app/{ws}/projects/{item}/chat/X (sync)
//   ?view=workspace&…         → /app/{ws}[/projects/{item}[/chat/T]] (sync)
//
// Unresolvable sessions/tasks fail closed to `/app` (never render a
// chat under the wrong workspace path). The `tab` param is preserved
// across every rewrite; project sub-state (pageId/sorts/detail) is
// preserved across workspace rewrites.
async function handleBootUrl(): Promise<void> {
  const rawQuery = route.query as Record<string, string | undefined>
  const cleanQuery = (): Record<string, string> => {
    const out: Record<string, string> = {}
    for (const [k, v] of Object.entries(rawQuery)) {
      if (typeof v === 'string' && v.length > 0) out[k] = v
    }
    return out
  }

  // 1. Trailing slash → normalize, continue boot on the normalized path.
  let path = route.path
  let query = cleanQuery()
  if (path !== normalizeAppPath(path) && isAppPath(path)) {
    path = normalizeAppPath(path)
    router.replace({ path, query })
  }

  // 2. Legacy path routes (registered so AppLayout mounts for the rewrite).
  const legacyChat = /^\/app\/chat\/([^/]+)\/?$/.exec(path)?.[1]
  const legacyTask = /^\/app\/task\/([^/]+)\/?$/.exec(path)?.[1]
  if (legacyChat) {
    await bootLegacyChat(legacyChat, keepTabParam(query))
    return
  }
  if (legacyTask) {
    await bootLegacyTask(legacyTask, keepTabParam(query))
    return
  }

  // 3. Legacy ?view= query URLs on /app → sync rewrite, then fall
  // through to the canonical boot below with the new values (the
  // replace does not remount us, so we continue manually).
  if (normalizeAppPath(path) === '/app' && query.view) {
    const rewritten = rewriteLegacyQuery(query)
    if (rewritten) {
      path = rewritten.path
      query = rewritten.query
      router.replace({ path, query })
    } else if (query.view === 'chat' && query.session) {
      await bootLegacyChat(query.session, keepTabParam(query))
      return
    }
    // Unknown ?view= values (gitfile/skill/code-editor overlays):
    // leave the URL alone, boot normally below.
  }

  // 4. Canonical boot from the (possibly rewritten) path.
  const parsed = parseAppPath(path)
  if (parsed.kind === 'chat') {
    workspacesStore.setActiveWorkspaceItem(null)
    navigationStore.setActiveChat(parsed.sessionId, navigationStore.activeChatName)
    fetchChatSessionCwd(parsed.sessionId)
  } else if (parsed.kind === 'projectChat') {
    workspacesStore.setActiveTask(parsed.chatTaskId)
  } else if (parsed.kind === 'doc') {
    // A document is its own page: drop any chat/project selection so the
    // sidebar's single-active-row contract holds and the document does
    // not look like it is "inside" a chat that is no longer on screen.
    workspacesStore.setActiveWorkspaceItem(null)
    workspacesStore.setActiveTask(null)
    navigationStore.setActiveChat('', navigationStore.activeChatName)
  } else {
    const q = route.query as Record<string, string | undefined>
    navigationStore.initFromUrl(
      (q.session as string | undefined) || undefined,
      undefined,
      (q.view as string | undefined) || undefined,
    )
  }

  // Prefer the workspace encoded by a workspace/project deep link. A
  // fresh tab may otherwise boot with the persisted/default workspace,
  // leave the URL-restored item inactive, and render a blank main view.
  // `chat` belongs here too: a chat path names its workspace, and
  // omitting it let the store fall back to the persisted
  // `pabrik-active-workspace` key — so the sidebar rendered one
  // workspace while the URL named another (task_1791556124905_10).
  const preferredWorkspaceId =
    parsed.kind === 'workspace' ||
    parsed.kind === 'project' ||
    parsed.kind === 'projectChat' ||
    parsed.kind === 'chat'
      ? parsed.workspaceId
      : undefined
  workspacesStore.initializeFromSystemFolder(preferredWorkspaceId)

  // 5. Overlay restore for deep links. The path boot above adopted
  // the workspace/chat context; reopen the editor so a reload or
  // shared link lands back on the file instead of silently dropping
  // it. Legacy base64 links resolve through their query cwd; new
  // readable links resolve through the adopted context (chat cwd is
  // awaited here; project items resolve when the tree loads — the
  // rightSidebarCwd watcher retries then).
  if (query.view === 'code-editor' && query.file) {
    if (parsed.kind === 'chat') {
      await fetchChatSessionCwd(parsed.sessionId)
    }
    await codeEditorSession.restoreFromUrl({
      fileParam: query.file,
      queryCwd: query.cwd ?? '',
      fallbackCwd: rightSidebarCwd.value,
      lineParam: query.line,
    })
  }
}

// The `tab` param is client-only (names the browser tab) — carry it
// across boot rewrites so a background tab doesn't lose its name.
function keepTabParam(query: Record<string, string>): Record<string, string> {
  return query.tab ? { tab: query.tab } : {}
}

// Legacy standalone chat (path or ?view=chat): resolve the owning
// workspace via the session-detail endpoint, then boot the chat under
// its path. Unresolvable → `/app` (fail-closed).
async function bootLegacyChat(sessionId: string, keep: Record<string, string>): Promise<void> {
  const wsId = await api.getSessionWorkspaceId(sessionId)
  // The URL points to a chat: clear any workspace-item active state
  // in BOTH branches (unresolvable sessions fail closed to `/app`,
  // but the stale item must still go — same as the old boot branch).
  workspacesStore.setActiveWorkspaceItem(null)
  navigationStore.setActiveChat(sessionId, navigationStore.activeChatName)
  fetchChatSessionCwd(sessionId)
  if (!wsId) {
    router.replace({ path: '/app', query: keep })
    workspacesStore.initializeFromSystemFolder()
    return
  }
  router.replace(buildAppUrl({ workspaceId: wsId, chatSessionId: sessionId, query: keep }))
  await workspacesStore.initializeFromSystemFolder()
}

// Legacy task link (/app/task/:tid): resolve the workspace via the
// session detail (task id == session id), then locate the parent item
// in the loaded tree. Parent found → full project-chat path; parent
// unknown (deleted task) → workspace path (fail-closed, no dialog).
async function bootLegacyTask(taskId: string, keep: Record<string, string>): Promise<void> {
  const wsId = await api.getSessionWorkspaceId(taskId)
  if (!wsId) {
    router.replace({ path: '/app', query: keep })
    workspacesStore.initializeFromSystemFolder()
    return
  }
  await workspacesStore.setActiveWorkspace(wsId)
  await workspacesStore.initializeFromSystemFolder()
  // Parent discovery runs inside setActiveTask against the loaded tree.
  workspacesStore.setActiveTask(taskId)
  const parentItemId = workspacesStore.activeWorkspaceItemId
  if (parentItemId) {
    router.replace(
      buildAppUrl({ workspaceId: wsId, projectId: parentItemId, chatTaskId: taskId, query: keep }),
    )
  } else {
    router.replace(buildAppUrl({ workspaceId: wsId, query: keep }))
  }
}

// Sync rewrite for legacy query URLs whose target is fully described
// by the query itself (no server lookup needed). Returns null when the
// query needs async resolution (?view=chat) or is not legacy at all.
function rewriteLegacyQuery(query: Record<string, string>): AppUrlLocation | null {
  const keepTab = keepTabParam(query)
  if (query.view === 'task' && query.task) {
    const rawItemId = query.itemId ?? ''
    const wsId = query.workspaceId ?? ''
    if (wsId && rawItemId) {
      const parsed = parseItemIdWithChat(rawItemId)
      return buildAppUrl({
        workspaceId: wsId,
        projectId: parsed.itemId,
        chatTaskId: query.task,
        query: keepTab,
      })
    }
    return null
  }
  if (query.view === 'workspace' && query.workspaceId) {
    const rawItemId = query.itemId ?? ''
    const parsed = rawItemId ? parseItemIdWithChat(rawItemId) : { itemId: '', chatTaskId: null }
    const sub: Record<string, string> = { ...keepTab }
    if (query.pageId) sub.pageId = query.pageId
    if (query.sorts) sub.sorts = query.sorts
    if (query.detail) sub.detail = query.detail
    // Kanban layout (columns | rows). Without this the boot rewrite drops
    // `?layout=rows` and a shared link / second machine loses row mode.
    if (query.layout) sub.layout = query.layout
    if (parsed.itemId) {
      return buildAppUrl({
        workspaceId: query.workspaceId,
        projectId: parsed.itemId,
        chatTaskId: parsed.chatTaskId ?? undefined,
        query: sub,
      })
    }
    return buildAppUrl({ workspaceId: query.workspaceId, query: sub })
  }
  return null
}

const toggleSidebar = () => {
  navigationStore.toggleSidebar()
}

const handleSidebarResize = (newWidth: number) => {
  navigationStore.setSidebarWidth(newWidth)
}

// Standalone-chat URL target (plan: 2026-09-22-revamp-ui-chats).
// Chats live under their workspace path. The workspace is the current
// main view's workspace when present, else the store's active
// workspace; without either we stay on the legacy query shape and the
// boot rewrite places it once the session resolves. (ChatsList passes
// its scoped workspace explicitly — this is the fallback for callers
// that only know the session id.)
function chatTarget(sessionId: string): AppUrlLocation {
  const wsForChat =
    (currentMainView.value.kind === 'chat' && currentMainView.value.workspaceId) ||
    (currentMainView.value.kind === 'workspace' && currentMainView.value.workspaceId) ||
    workspacesStore.activeWorkspaceId ||
    ''
  if (wsForChat) return buildAppUrl({ workspaceId: wsForChat, chatSessionId: sessionId })
  return { path: '/app', query: { view: 'chat', session: sessionId } }
}

const activeWorkspaceItem = computed(() => workspacesStore.activeWorkspaceItem)
const activeWorkspace = computed(() => workspacesStore.activeWorkspace)

// Subscribe to /api/kanban/events so live kanban mutations (column
// create / update / delete / reorder, task move / assign / unassign)
// refresh the visible board in real time without a manual reload.
// The store owns ONE global SSE connection for the app's lifetime
// (mirrors the workersSse pattern in App.vue) — workspace switches
// just update the client-side filter, no connection churn.
// Empty string when no workspace is active (the store treats "" as
// a valid workspaceId, but the activeWorkspace.value?.id falls
// through to "" so no kanban event is ever dispatched to a
// non-existent workspace — the workspacesStore.fetchKanbanColumns
// helper no-ops if the (workspaceId, itemId) pair doesn't resolve to
// a local item).
const kanbanSseStore = useKanbanSseStore()
const activeWorkspaceId = computed(() => activeWorkspace.value?.id ?? '')

// Subscribe to /api/kanban/events on the FIRST truthy activeWorkspaceId
// and update the client-side filter on every subsequent change.
// `initSseStores` (onMounted + store-subscription pump) covers all three
// startup shapes:
//   - URL has ?task=...  → setActiveTask ran before mount; immediate=true
//     opens the SSE on the first tick with the already-truthy id.
// (The old text referenced an `immediate` watcher; the trigger is now
// the explicit init call + pump.)
//   - URL has ?session=... (chat) or no URL params → activeWorkspaceId
//     is '' at mount; the pump stays idle until
//     initializeFromSystemFolder's post-init restoration
//     (workspaces.ts:1559-1577) sets activeWorkspaceItemId, then runs
//     with the now-truthy id and opens the SSE.
//   - User clicks a sidebar item mid-session → fires with the new id.
// `didInitSse` preserves the store's design: ONE connection for the
// app's lifetime, only filter updates on workspace switches (the
// backend's kanban routing keys are global, so we don't reopen).
//
// The watch callback is async so we can `await` `initKanbanSse`. The
// underlying `createSseClient` defers its initial `start()` to the
// next macrotask — awaiting the Promise here makes the SSE setup
// cooperative with other same-tick fetch API calls (workspace data,
// chat history) and prevents the EventSource HTTP request from
// saturating the browser's per-origin 6-connection pool.
// SSE subscription init lives in `initSseStores` (defined at the Design SSE
// section below, merging both stores under one did-init guard). It runs
// from onMounted + the store subscription pump at the bottom of this file.

// ─── URL → activeWorkspaceItemId / activeDesignPageId restoration ─────
//
// When the user reloads `/app?view=workspace&workspaceId=X&itemId=Y[&pageId=Z]`,
// the in-memory `activeWorkspaceItemId` (and `activeDesignPageId`) is null.
// We need to set them from the URL params, but only AFTER the workspaces
// array has loaded (so we can validate the (workspaceId, itemId) pair
// actually exists). The pageId restoration happens at the DesignView
// layer (it loads pages and reads `activeDesignPageId` from the store
// before falling back to the first page) — we just stash the URL value
// into the store here so DesignView can pick it up.
//
// Setup reads the URL synchronously (it runs before any async API
// calls) and stashes the params into `pendingUrlRestore`. The
// `workspaces` watcher fires the moment initializeFromSystemFolder
// populates the array (or in tests, the moment the test sets
// ws.workspaces = [...] before mount), validates the pair, calls
// setActiveWorkspaceItem (+ setActiveDesignPage if pageId is set), and
// clears the pending slot. If the pair no longer exists (deleted), we
// just leave the kanban blank.
const pendingUrlRestore = ref<{
  workspaceId: string
  itemId: string
  pageId: string
} | null>(
  (() => {
    // Path-based URLs first (plan: 2026-09-22-revamp-ui-chats). A
    // project is a workspace item, so the project path restores
    // exactly like the old `?view=workspace&itemId=` shape.
    const parsedPath = parseAppPath(route.path)
    if (parsedPath.kind === 'project' || parsedPath.kind === 'projectChat') {
      const pageId = route.query.pageId as string | undefined
      return {
        workspaceId: parsedPath.workspaceId,
        itemId: parsedPath.projectId,
        pageId: pageId ?? '',
      }
    }
    if (parsedPath.kind === 'workspace') {
      return { workspaceId: parsedPath.workspaceId, itemId: '', pageId: '' }
    }
    const view = route.query.view as string | undefined
    const wsId = route.query.workspaceId as string | undefined
    const rawItemId = route.query.itemId as string | undefined
    const pageId = route.query.pageId as string | undefined
    if (view === 'workspace' && wsId) {
      // SIMPLIFY-URL-BROWSER (2026-08-15): parse the wire-shape
      // itemId (may carry /chat/<taskId> suffix). pendingUrlRestore
      // only needs the bare id; the chat task id is restored
      // separately in onMounted above.
      //
      // Standalone workspace selection (revamp plan, 2026-09-22):
      // `?view=workspace&workspaceId=X` WITHOUT an itemId is valid —
      // the dropdown restores the selection and the Projects section
      // renders with no row active.
      const parsed = rawItemId ? parseItemIdWithChat(rawItemId) : { itemId: '' }
      return { workspaceId: wsId, itemId: parsed.itemId, pageId: pageId ?? '' }
    }
    return null
  })(),
)
// Keep one restore in flight while the target workspace lazily loads.
// A seeded workspace can appear in the list before its items arrive;
// checking that first snapshot would incorrectly clear the pending URL
// restore and leave a project deep link on the blank Chats view.
let urlRestoreInFlight = false
// URL restore (replaces the old workspaces watcher). Runs once from
// onMounted (covers fixtures seeded before mount) and from the store
// subscription pump (covers the async initializeFromSystemFolder path).
// Reads the live list by default so pump callers pass nothing.
const restoreUrlState = async (wsList = workspacesStore.workspaces) => {
  if (urlRestoreInFlight) return
  const pending = pendingUrlRestore.value
  if (!pending) return
  if (!wsList || wsList.length === 0) return
  const targetWorkspace = wsList.find((ws) => ws.id === pending.workspaceId)
  if (!targetWorkspace) {
    // Stale URL — clear it so we don't try again on every workspace
    // update. User will see the empty kanban-state placeholder and
    // can pick a workspace item manually.
    pendingUrlRestore.value = null
    return
  }

  const itemExists = targetWorkspace.items.some((item) => item.id === pending.itemId)
  if (!pending.itemId || itemExists) {
    // Fast path for fixtures and already-loaded items. Keep this
    // synchronous so callers that seed the store before mount do not
    // need an extra tick before the selected view renders.
    void workspacesStore.setActiveWorkspace(pending.workspaceId)
    if (pending.itemId) {
      workspacesStore.setActiveWorkspaceItem(pending.itemId)
      if (pending.pageId) {
        workspacesStore.setActiveDesignPage(pending.pageId)
      }
    }
    pendingUrlRestore.value = null
    return
  }

  // The target workspace is present but its items are still loading.
  // Wait for the lazy loader before deciding that the deep link is
  // stale; otherwise a fresh settings popup briefly shows Chats.
  urlRestoreInFlight = true
  try {
    await workspacesStore.setActiveWorkspace(pending.workspaceId)
    const loadedWorkspace = workspacesStore.workspaces.find((ws) => ws.id === pending.workspaceId)
    const loadedItemExists =
      loadedWorkspace?.items.some((item) => item.id === pending.itemId) ?? false
    if (loadedItemExists) {
      workspacesStore.setActiveWorkspaceItem(pending.itemId)
      if (pending.pageId) {
        workspacesStore.setActiveDesignPage(pending.pageId)
      }
    }
    pendingUrlRestore.value = null
  } finally {
    urlRestoreInFlight = false
  }
}

// Run once at setup (replicates the old `{ immediate: true }` watcher):
// with fixtures seeded before mount this restores synchronously, BEFORE
// initializeFromSystemFolder's seedList replaces the rows (a later call
// would see the seeded items as "loaded" and skip the fetch, stranding
// an empty tree — see ensureWorkspaceItemsLoaded). The onMounted + pump
// calls below cover the async-init path.
void restoreUrlState()

// IMPORTANT (2026-07-28 per-page chat scoping):
// When the user switches design pages (activeDesignPageId changes
// in the store, mirrored from DesignView's activePageId sync),
// we DO NOT swap the active chat task. The chat is bound to the
// page that opened it (via `handleDesignOpenChat`'s per-page
// lookup); switching tabs leaves that conversation alone. Closing
// the chat and reopening on a new page binds to the new page's
// chat predictably via `handleDesignOpenChat`. Any future "smart
// chat that follows the page" behavior must be opt-in, NOT
// implicit, to avoid disorienting users mid-conversation.
// Plan: docs/superpowers/plans/2026-07-28-design-per-page-chat-sessions.md

// ─── activeWorkspaceItem / activeDesignPage → URL mirror (reverse sync) ──
//
// The forward direction (sidebar click → URL) is wired through
// Sidebar.handleSelectItem → emit('navigate', 'workspace', …, wsId, itemId)
// → AppLayout.handleNavigate → router.replace. The reverse direction
// (activeWorkspaceItemId / activeDesignPageId changes from ANY source →
// URL) is needed for resilience: if the onMounted URL restore above sets
// activeWorkspaceItemId, the URL is already correct (it was the
// source), but if any future code path sets activeWorkspaceItemId
// programmatically (e.g., keyboard shortcut, deep link, restored
// from localStorage), the URL would NOT update and a refresh
// would lose the context. This subscription pump fills that gap. Also covers
// the active design page (DesignView emits selectPage → no URL
// update; DesignView's activePageId sync writes to the store,
// this subscription mirrors the store back to the URL).
//
// We guard against two footguns:
//   1. The pump must NOT overwrite the URL while the user is
//      on a route like view=task / view=chat / view=settings /
//      view=gitfile / view=skill / view=code-editor — those views
//      have their own URL contract and should be preserved.
//   2. The pump must NOT call router.replace when the URL
//      already matches the active state (would push redundant
//      history entries).
// activeWorkspaceItem / activeDesignPage -> URL mirror (replaces the old
// watcher). Called from the store subscription pump whenever either id
// changes, with the previous item id for the clear-guard below.
const syncItemToUrl = (oldItemId: string | null) => {
  const itemId = workspacesStore.activeWorkspaceItemId
  const pageId = workspacesStore.activeDesignPageId
  const wsId = workspacesStore.activeWorkspace?.id ?? ''
  const currentView = route.query.view as string | undefined
  // FIX (task-url-overwrite, task_1785959660154, 2026-08-06):
  // The URL sync watcher must NOT fire while Sidebar is in the
  // middle of a task navigation. The race that broke this:
  // Sidebar.handleSelectTask calls
  // workspacesStore.setActiveTask(taskId) (which synchronously
  // mutates activeWorkspaceItemId to the task's parent item via
  // the parent-discovery loop in workspaces.ts:3031-3107) and then
  // calls router.push({ view: 'workspace', workspaceId, itemId, .../chat/taskId }).
  // Vue Router resolves the push asynchronously (the route ref
  // updates after the navigation guard / scroll / etc.). This
  // watcher fires on the next microtask after the store mutation —
  // BEFORE Vue Router has applied the URL change. At that moment
  // route.query.view is still the OLD view (typically
  // 'workspace'), the existing guard
  // `if (currentView !== 'workspace' && currentView !== undefined) return`
  // does NOT return early, and the watcher clobbers the URL with
  // `router.replace({ view: 'workspace', workspaceId, itemId, ... })`.
  // The pending `router.push({ view: 'workspace', ..., /chat/<taskId> })`
  // is then applied AFTER the replace, but Vue Router's `replace`
  // semantics overwrite the push's history entry — the URL ends
  // up at view=workspace and the task never shows up.
  //
  // User report (task_1785959660154): "select task not show up
  // ... buildTaskUrlQuery view is task, but the url browser
  // still using view workspace".
  //
  // The fix: a `isNavigatingToTask` ref is set true at the start
  // of Sidebar.handleSelectTask and cleared after the URL update
  // completes. The watcher returns early when the flag is set,
  // so the race window is closed. The flag is stored in the
  // workspaces store (the natural home for cross-component view
  // state).
  //
  // SIMPLIFY-URL-BROWSER (2026-08-15): the `view: 'task'` arm
  // was removed from handleNavigate — the flag now guards the
  // chat-open (view=workspace + /chat/<taskId>) navigation too.
  if (workspacesStore.isNavigatingToTask) return
  // FIX (chat-click-url-overwrite, task_1787844892180_2, 2026-08-27):
  // Inverse of the task_1785959660154 race. When the user navigates
  // AWAY from a workspace item (e.g. Sidebar.handleChatsNavigate
  // clearing activeWorkspaceItemId before its own router.replace
  // applies), this watcher fires with itemId = null while
  // route.query.view is still 'workspace' from the previous page.
  // The currentView guard does NOT return early in that window and
  // the watcher would clobber the destination's URL with
  // router.replace({view: 'workspace'}). The fix: skip the mirror
  // when itemId is being cleared from a previously-truthy value —
  // the destination's router call wins, this watcher must not race.
  // The mirror still fires for the truthy → truthy and null → truthy
  // transitions (regression-guarded by
  // AppLayout.chatClickUrlOverwrite.spec.ts Test 2).
  if (!itemId && oldItemId) return
  // Only sync when we're on the workspace view — all other views
  // (chat, settings, gitfile, skill, code-editor) have their
  // own URL contract and should be preserved.
  if (currentView !== 'workspace' && currentView !== undefined) return

  // Path-based mirror (plan: 2026-09-22-revamp-ui-chats). Store
  // state maps onto buildAppUrl targets; the task-chat suffix is
  // preserved from the current URL when the suffixed task is still
  // the store's live task. Pre-fix the watcher overwrote the URL
  // with the bare item id, dropping the chat task id and closing
  // the chat dialog on every reactive update; navigating to a
  // DIFFERENT item still drops the suffix (Sidebar clears
  // activeTask first, so re-appending would resurrect the old chat
  // on top of the new item). Reads both the path suffix
  // (`.../projects/P/chat/T`) and the legacy query suffix
  // (`itemId=Y/chat/T`) so the transition window keeps working.
  //
  // `itemId` comes from `activeWorkspaceItemId` which is `string | null`.
  const safeItemId = itemId ?? ''
  // The live task id is read from `activeTaskId` (the raw id), NOT
  // the `activeTask` computed: the computed resolves the parent
  // item from the loaded tree, which is null when the parent's
  // workspace hasn't loaded its items yet (lazy loading) or in
  // tests that seed the task id without the full tree. The suffix
  // represents "chat dialog open for task T" — as long as T is the
  // active task id, the dialog stays, loaded parent or not.
  // Navigating to a DIFFERENT item still drops the suffix because
  // Sidebar clears the active task first (setActiveTask(null)).
  const liveTaskId = workspacesStore.activeTaskId ?? workspacesStore.activeTask?.id ?? null
  const pathParsed = parseAppPath(route.path)
  const urlChatTask =
    pathParsed.kind === 'projectChat'
      ? pathParsed.chatTaskId
      : parseItemIdWithChat((route.query.itemId as string) ?? '').chatTaskId
  const chatTaskId = urlChatTask && urlChatTask === liveTaskId ? urlChatTask : undefined

  const sub: Record<string, string> = {}
  // pageId is design-item-scoped — only include it when the active
  // item is a design. Empty pageId means "default to first page"
  // and is omitted from the URL to keep the URL clean. FIX
  // (chatview-bug, task_1785726648589): pre-fix, the watcher wrote
  // `pageId` to the URL based purely on `activeDesignPageId` being
  // truthy — without checking the active item's type. When the
  // user switched from a design to a kanban (or folder), the
  // store's `activeDesignPageId` stayed stale (carried over from
  // the design), and the URL ended up with a stale page for the
  // kanban. The fix: look up the active item and only include
  // pageId when it's a design.
  if (pageId) {
    const activeItem = workspacesStore.workspaces
      .flatMap((ws) => ws.items)
      .find((it) => it.id === itemId)
    if (activeItem?.item_type === 'design') {
      sub.pageId = pageId
    }
  }
  // FIX (kanban-sort-independence, task_1785730557641,
  // 2026-08-06): preserve the per-column `sorts` query param so
  // the URL survives navigation. Without this, this watcher
  // (which fires on every workspaceItemId change) would clobber
  // the URL and drop the `sorts=col_X:...` KanbanView wrote.
  const urlSorts = route.query.sorts as string | undefined
  if (urlSorts) {
    sub.sorts = urlSorts
  }
  // Preserve the kanban task-detail deep-link (?detail=<taskId>)
  // when staying on the SAME project, so reactive store updates
  // (e.g. setActiveTask parent-discovery, design page switches)
  // don't drop the open panel. Dropped when navigating to a
  // different item.
  const urlDetail = route.query.detail as string | undefined
  if (urlDetail) {
    const urlProject =
      pathParsed.kind === 'project' || pathParsed.kind === 'projectChat'
        ? pathParsed.projectId
        : parseItemIdWithChat((route.query.itemId as string) ?? '').itemId
    if (urlProject === safeItemId) {
      sub.detail = urlDetail
    }
  }
  // A document is its own path, so this mirror never targets one — there
  // is no `doc` query for a store write to strip.

  let target: AppUrlLocation | null = null
  if (wsId && safeItemId) {
    target = buildAppUrl({
      workspaceId: wsId,
      projectId: safeItemId,
      chatTaskId,
      query: sub,
    })
  } else if (workspacesStore.activeWorkspaceId) {
    // Standalone workspace selection (no active item): keep the
    // dropdown's workspaceId in the URL (revamp plan, 2026-09-22).
    target = buildAppUrl({ workspaceId: workspacesStore.activeWorkspaceId, query: sub })
  }
  if (!target) return
  // No-op when the URL already matches the store state (path +
  // sorts/detail/pageId) — avoids redundant replaces that would
  // churn history and re-trigger the route watcher. `tab` is
  // client-only (names the browser tab) and excluded from identity.
  {
    const urlQ = route.query as Record<string, unknown>
    const keys = new Set([...Object.keys(urlQ), ...Object.keys(target.query)])
    let same = route.path === target.path
    if (same) {
      for (const k of keys) {
        if (k === 'tab') continue
        const a = typeof urlQ[k] === 'string' ? (urlQ[k] as string) : undefined
        const b = target.query[k]
        if ((a ?? undefined) !== (b ?? undefined)) {
          same = false
          break
        }
      }
    }
    if (same) return
  }
  router.replace(target)
}

// ─── Design SSE — mirror the kanban pattern ─────────────────────────────
//
// Bus-backed design-event subscription (Chunk 6 of
// design-mode-redesign plan). The store opens its bus listener on the
// FIRST truthy activeWorkspaceId and just updates the filter on
// subsequent changes — same ONE-connection-per-app-lifetime contract
// as the kanban SSE store. The bus itself is installed once by
// App.vue; this watcher only schedules the subscription.
//
// `didInitDesignSse` keeps the SSE idempotent across remounts (e.g.
// HMR, route changes that briefly tear down AppLayout).
const designSseStore = useDesignSseStore()
// Merged SSE init (replaces the old kanban + design activeWorkspaceId
// watchers): ONE connection pair for the app lifetime, filter updates on
// workspace switches. Runs from onMounted + the store subscription pump.
let didInitSse = false
const initSseStores = async (newId: string) => {
  if (!newId) return
  if (!didInitSse) {
    didInitSse = true
    await kanbanSseStore.initKanbanSse(newId)
    await designSseStore.initDesignSse(newId)
  } else {
    await kanbanSseStore.setActiveWorkspaceId(newId)
    await designSseStore.setActiveWorkspaceId(newId)
  }
}

// NEW (Chunk 1, Task 1.3 of design-element-drag-and-drop plan).
// Extracted handlers so they're directly unit-testable. Reads the
// active page id from workspacesStore (mirrored by DesignView in
// Task 1.2) and routes patches to the geometry endpoint vs the
// full-update endpoint based on which keys are present.
const designHandlers = useDesignHandlers()

onUnmounted(() => {
  kanbanSseStore.closeKanbanSse()
  designSseStore.closeDesignSse()
})

// Computed refs from store
const activeChatId = computed(() => navigationStore.activeChatId)
const activeChatName = computed(() => navigationStore.activeChatName)
const sidebarCollapsed = computed(() => navigationStore.sidebarCollapsed)
const sidebarWidth = computed(() => navigationStore.sidebarWidth)

const handleUpdateChatId = (oldId: string, newId: string) => {
  if (activeChatId.value === `chat-${oldId}`) {
    navigationStore.setActiveChat(newId)
  }
  // Keep the strip's pointer in step: a brand-new chat starts life with the
  // synthetic `session-<timestamp>` id and gets its real one on the first
  // message, so a tab left keyed on the old id would be dead — and the route
  // funnel would add a second tab for the same chat.
  tabsStore.renameChatTab(oldId, newId)
  sidebarRef.value?.updateChatId(oldId, newId)
  // Keep the browser URL truthful: a brand-new chat mounts at
  // /app/{ws}/chat/<synthetic-id> and gets its real id on the first
  // message. Without this the address bar keeps the dead synthetic id, so
  // refresh/share lands on a missing session while the view shows the real
  // one (URL desync reported as "fix url browser").
  try {
    const chatParsed = parseAppPath(route.path)
    if (chatParsed.kind === 'chat' && chatParsed.sessionId === oldId) {
      router.replace(
        buildAppUrl({
          workspaceId: chatParsed.workspaceId,
          chatSessionId: newId,
          query: { ...(route.query as Record<string, string>) },
        }),
      )
      return
    }
    const urlSession = route.query.session as string | undefined
    const urlView = route.query.view as string | undefined
    if (urlView === 'chat' && urlSession === oldId) {
      router.replace({ path: '/app', query: { view: 'chat', session: newId } })
    }
  } catch {
    // Router absent in unit tests — store + tabs already updated.
  }
}

const handleNavigate = (
  view: string,
  chatName?: string,
  taskId?: string,
  workspaceId?: string,
  itemId?: string,
  // NEW (design-pages-in-workspace-tree plan, 2026-08-06): the
  // 6th positional arg lets the caller pin a specific design page
  // when navigating to `view: 'workspace'`. Empty / undefined
  // means "no page pinned" (DesignView falls back to the first
  // page in the cache). Pre-fix, the workspace branch only wrote
  // workspaceId + itemId to the URL — a click on a design page
  // navigated correctly into DesignView (the store had the page
  // id) but the URL lost it on the next reload, so a refresh
  // restored the wrong page. Now the URL is the source of truth
  // for reload, matching the existing `activeDesignPageId` mirror
  // on line 188.
  pageId?: string,
  // NEW (kanban default-URL, 2026-08-06): when the caller navigates
  // to a kanban workspace item, the Sidebar commits a default
  // `?sorts=col_X:updated_at:desc,...` string here. We mirror it
  // into the URL so a refresh preserves the user's implicit sort
  // choice. Empty / undefined means "no sort param" (folder /
  // design / chat paths). KanbanView's mount-time URL restore
  // reads it back and applies each entry's sort to its column.
  sortsParam?: string,
) => {
  console.log('[handleNavigate]', view)
  if (view.startsWith('chat-')) {
    const chatSessionId = view.replace(/^chat-/, '')
    // Clear any workspace-item active state — navigating to a chat wins.
    workspacesStore.setActiveWorkspaceItem(null)
    navigationStore.setActiveChat(chatSessionId, chatName)
    // The new chat URL carries no overlay query, so drop the previous
    // chat's file synchronously (reconcileRoute also clears on the
    // next pump — this avoids a one-frame flash of the old file).
    clearAllOverlays()
    // Fetch cwd for folder explorer and git
    fetchChatSessionCwd(chatSessionId)
    router.push(chatTarget(chatSessionId))
  } else if (view === 'chat') {
    // Clear any workspace-item active state — the URL is asserting
    // "no chat selected, no workspace item selected". Path-based:
    // land on the workspace path (chat list scoped to it) when a
    // workspace is active, else the landing.
    workspacesStore.setActiveWorkspaceItem(null)
    navigationStore.clearActiveChat()
    chatSessionCwd.value = ''
    if (workspacesStore.activeWorkspaceId) {
      router.push(buildAppUrl({ workspaceId: workspacesStore.activeWorkspaceId }))
    } else {
      router.push({ path: '/app', query: {} })
    }
  } else if (view === 'workspace') {
    navigationStore.clearAll()
    // Navigating to the board wins over any open task chat — clear the
    // workspaces task so the kanban/design/folder view renders instead of
    // the chat. (navigationStore.clearAll only clears the navigation
    // store's task; the visible chat is gated on workspacesStore.activeTask.
    // Without this, a board URL can render chat content when the caller
    // forgot to clear the task first.)
    workspacesStore.setActiveTask(null)
    chatSessionCwd.value = ''
    // When the caller passes (workspaceId, itemId), mirror them into the
    // URL so the kanban/folder/design item survives a page reload.
    // Without this, the workspace path alone loses the active item on
    // refresh because `activeWorkspaceItemId` is in-memory only.
    // Path-based (plan: 2026-09-22-revamp-ui-chats): projects live at
    // /app/{ws}/projects/{item}; pageId/sorts ride in the query.
    const sub: Record<string, string> = {}
    if (pageId) sub.pageId = pageId
    if (sortsParam) sub.sorts = sortsParam
    if (workspaceId && itemId) {
      router.push(buildAppUrl({ workspaceId, projectId: itemId, query: sub }))
    } else if (workspaceId) {
      router.push(buildAppUrl({ workspaceId, query: sub }))
    } else {
      router.push({ path: '/app', query: sub })
    }
  } else if (view === 'settings') {
    // Settings opens on the workspace the user is IN, with that workspace in
    // the PATH - the same URL contract every other view uses. Pushing the
    // workspace-less `/app/settings` (user scope, General only) threw the
    // workspace away, and the Workspace tab then had to guess one; it guessed
    // `workspaces[0]`, which is whichever workspace sits at the top of the
    // list, not the one the user came from.
    //
    // Land directly on the last-open section so the URL already carries
    // `?section=` (the shell's mount normalization would repair a clean push
    // via replace, but pushing the stored section avoids the clean-URL flash).
    let stored: string | null = null
    try {
      stored = localStorage.getItem('pabrik-settings-active-tab')
    } catch (e) {
      // Storage unreadable (private mode): fall back to the clean URL, which
      // renders the default section. The fallback cannot render a WRONG
      // section, only the default.
      console.warn('[settings] stored tab unreadable, using default', e)
      stored = null
    }
    // The stored key predates Migration 105: the sections it can name are
    // workspace-scoped now, so it selects a section on the workspace page.
    // Anything else (`general`, an unknown value) is dropped rather than sent
    // as `?section=` to the workspace page.
    const settingsWorkspaceId = resolveWorkspaceId(
      route.params.workspaceId,
      workspacesStore.activeWorkspace?.id,
    )
    router.push(
      buildSettingsUrl(
        settingsWorkspaceId,
        stored && isWorkspaceAgentSection(stored) ? stored : null,
      ),
    )
  }
}

// Header dropdown workspace switch (plan:
// docs/plans/2026-09-22-revamp-workspace-ui-dropdown-projects.md).
// A switch is a context change: clear the open item/task, then PUSH
// a fresh `/app/{workspaceId}` entry — user decision-log
// requirement: Back/Forward must cross workspace switches (this is
// deliberately NOT the tab-switch `replace` precedent). Re-selecting
// the workspace already shown is a no-op.
const handleSelectWorkspace = (workspaceId: string) => {
  const parsed = parseAppPath(route.path)
  const alreadyThere =
    (parsed.kind === 'workspace' && parsed.workspaceId === workspaceId) ||
    (route.query.view === 'workspace' &&
      (route.query.workspaceId as string | undefined) === workspaceId)
  if (alreadyThere) return
  navigationStore.clearAll()
  workspacesStore.setActiveTask(null)
  workspacesStore.setActiveWorkspaceItem(null)
  chatSessionCwd.value = ''
  workspacesStore.setActiveWorkspace(workspaceId)
  router.push(buildAppUrl({ workspaceId }))
}

// Shared "return to the underlying view" navigation for overlay
// closes (git viewer, skill viewer, code editor). Path-based (plan:
// 2026-09-22-revamp-ui-chats): active item → its project path (with
// pageId for designs); active task → the project-chat path; active
// chat → its chat path; otherwise the landing.
function replaceWithCurrentContext(): void {
  if (workspacesStore.activeWorkspaceItemId) {
    // Returning to the board wins over any open task chat — clear the
    // task so the kanban/design/folder renders instead of the chat.
    // Without this, the URL is bare (no /chat/ suffix) while the chat
    // is still active: board URL + chat content.
    workspacesStore.setActiveTask(null)
    const sub: Record<string, string> = {}
    if (workspacesStore.activeDesignPageId) {
      const item = workspacesStore.workspaces
        .flatMap((ws) => ws.items)
        .find((it) => it.id === workspacesStore.activeWorkspaceItemId)
      if (item?.item_type === 'design') sub.pageId = workspacesStore.activeDesignPageId
    }
    router.replace(
      buildAppUrl({
        workspaceId: activeWorkspaceId.value,
        projectId: workspacesStore.activeWorkspaceItemId,
        query: sub,
      }),
    )
  } else if (activeTask.value) {
    // NEW (add-workspace-id-params, 2026-08-06): include workspaceId +
    // itemId + pageId when the task is attached to a workspace item.
    // Pre-fix this branch wrote only `?view=task&task=X`, dropping
    // the kanban / design breadcrumb — the user reported this
    // (task_1785774094183).
    router.replace(
      buildTaskAppUrl({
        taskId: activeTask.value.id,
        activeWorkspaceId: activeWorkspaceId.value,
        activeWorkspaceItemId: workspacesStore.activeWorkspaceItemId,
        activeDesignPageId: workspacesStore.activeDesignPageId,
        activeItemType: workspacesStore.activeWorkspaceItem?.item_type ?? null,
        currentQuery: route.query,
      }),
    )
  } else if (activeChatId.value.startsWith('chat-')) {
    const sessionId = activeChatId.value.replace(/^chat-/, '')
    router.replace(chatTarget(sessionId))
  } else {
    router.replace({ path: '/app', query: {} })
  }
}

const closeGitViewer = () => {
  gitViewerFile.value = null
  gitViewerStaged.value = false
  // Navigate back to previous view based on state. If the user
  // opened the file viewer while on a workspace item (folder /
  // kanban / design), preserve the active item IDs in the URL so
  // a page reload restores the design/kanban/folder — otherwise the
  // URL was being stripped to ?view=task or ?view=chat, losing the
  // workspace context. For design items, also preserve pageId so
  // the active design page survives a reload.
  replaceWithCurrentContext()
}

// Skill viewer state
const skillViewerSkill = ref<{ name: string } | null>(null)

const closeSkillViewer = () => {
  skillViewerSkill.value = null
  // Navigate back to previous view based on state. Preserve the
  // workspace item (folder / kanban / design) IDs when the user
  // opened the skill view while on a workspace item — see
  // closeGitViewer for the same pattern. For design items, also
  // preserve pageId so the active design page survives a reload.
  replaceWithCurrentContext()
}

// Code editor session — single source of truth for the open-file
// flow (file / content / loading / error / requested line / cwd).
// All openers (sidebar explorer, diff views, tool-output cards)
// call openInCodeEditor below, which delegates to the session; URL
// restores go through session.restoreFromUrl. The session stores
// the cwd explicitly and syncs the URL as a readable `?file=` path
// appended to the current workspace route, so reloads and shared
// links resolve without silent blanks.
const codeEditorSession = useCodeEditorSession({
  readFile: (cwd, path) => api.readFileContent(cwd, path),
  syncUrl: ({ path, line }) => {
    // Keep-append: the editor keys merge into the current URL so the
    // workspace/project/chat context in the path survives a reload.
    // The file travels as a plain relative path (readable,
    // hand-editable); the cwd stays out of the URL and resolves from
    // the active workspace item / chat session on restore, so links
    // never leak absolute server paths and stay valid across machines.
    const next: Record<string, string> = {}
    for (const [k, v] of Object.entries(route.query)) {
      if (typeof v !== 'string' || v.length === 0) continue
      if (k === 'view' || k === 'file' || k === 'line' || k === 'cwd') continue
      next[k] = v
    }
    next.view = 'code-editor'
    next.file = path
    if (line !== null) {
      next.line = String(line)
    }
    router.replace({
      path: route.path,
      query: next,
    })
  },
})
// Template and view bindings keep their names — they alias the
// session refs (same objects, no duplicated state).
const codeEditorFile = codeEditorSession.file
const codeEditorContent = codeEditorSession.content
const codeEditorLoading = codeEditorSession.loading
const codeEditorError = codeEditorSession.error
const codeEditorRequestedLine = codeEditorSession.requestedLine

const openInCodeEditor: OpenInCodeEditorFn = async (opts: OpenInCodeEditorOptions) => {
  // Clear other overlays to prevent priority conflicts
  gitViewerFile.value = null
  gitViewerStaged.value = false
  skillViewerSkill.value = null
  await codeEditorSession.openFile(opts)
}

// Expose openInCodeEditor to all descendants (tool output components) via inject
provide<OpenInCodeEditorFn>(OPEN_IN_CODE_EDITOR_KEY, openInCodeEditor)

const closeCodeEditor = () => {
  codeEditorSession.clear()
  // Strip only the editor keys so the underlying board/chat URL
  // (path plus pageId/sorts/tab/…) survives the close. A bare /app
  // editor link (legacy bookmark, fresh reload with no path context)
  // has nothing to keep — rebuild from the store there.
  if (parseAppPath(route.path).kind !== 'landing') {
    const next: Record<string, string> = {}
    for (const [k, v] of Object.entries(route.query)) {
      if (typeof v !== 'string' || v.length === 0) continue
      if (k === 'file' || k === 'line' || k === 'cwd') continue
      if (k === 'view' && v === 'code-editor') continue
      next[k] = v
    }
    router.replace({ path: route.path, query: next })
    return
  }
  // Navigate back to previous view. Preserve the workspace item
  // (folder / kanban / design) IDs when the user opened the code
  // editor while on a workspace item — see closeGitViewer for the
  // same pattern. For design items, also preserve pageId so the
  // active design page survives a reload.
  replaceWithCurrentContext()
}

// The open file itself, so a SURFACE can render it: ChatView paints it in
// its center column next to the chat-owned right sidebar (the user opened
// the file FROM that sidebar — it must stay put), and the overlay in the
// template is the fallback for every context with no chat on screen (kanban
// board, design canvas, settings, chats list). Same session refs, no copies:
// the template bindings above alias these exact objects.
const codeViewerState: CodeViewerState = {
  file: codeEditorSession.file,
  content: codeEditorSession.content,
  loading: codeEditorSession.loading,
  error: codeEditorSession.error,
  requestedLine: codeEditorSession.requestedLine,
  cwd: codeEditorSession.cwd,
  close: closeCodeEditor,
}
provide<CodeViewerState>(CODE_VIEWER_STATE_KEY, codeViewerState)

const handleSubmitReview = async (message: string) => {
  console.log('[AppLayout] Code review submitted:', message)
  // Navigate to chat view with the review message
  if (activeChatId.value.startsWith('chat-')) {
    const sessionId = activeChatId.value.replace(/^chat-/, '')
    // Send the review message to the active chat session
    try {
      await api.sendChatMessage(sessionId, message, rightSidebarCwd.value)
      console.log('[AppLayout] Review message sent successfully')
    } catch (err) {
      console.error('[AppLayout] Failed to send review message:', err)
    }
  }
  // Close the git viewer after submitting
  closeGitViewer()
}

const handleCommentSaved = () => {
  closeGitViewer()
}

// Git file viewer state
const gitViewerFile = ref<api.GitFileChange | null>(null)
const gitViewerStaged = ref(false)

// The editor session is global to AppLayout, not per-chat: switching the
// main context (chat session, task, workspace item, document) must drop
// any open overlay, otherwise the old file keeps rendering inside the new
// chat's center column (ChatView reads the same injected refs). URL-only
// restores re-open via restoreFromUrl below, so clearing here is safe.
const clearAllOverlays = () => {
  gitViewerFile.value = null
  gitViewerStaged.value = false
  skillViewerSkill.value = null
  codeEditorSession.clear()
}

// Chat session cwd for folder explorer and git (fetched from API)
const chatSessionCwd = ref<string>('')

const fetchChatSessionCwd = async (sessionId: string) => {
  chatSessionCwd.value = ''
  try {
    // Single lightweight detail read (GET /api/llm/session/:id, no message
    // payload). The old messages?limit=1 fallback is gone: the detail
    // endpoint reads the sessions row directly, so cwd is present even for
    // zero-message sessions where the messages JOIN yields no rows.
    const session = await api.getSession(sessionId)
    if (session && session.cwd) {
      chatSessionCwd.value = session.cwd
      writeSessionCwdCache(session.cwd)
    }
  } catch (err) {
    console.error('Failed to fetch chat session cwd:', err)
  }
}

// The open document's id, read from the PATH rather than
// `route.params.documentId`. AppLayout derives everything else through
// `parseAppPath`, and going through `route.params` would make the view
// depend on the router having populated params, which is exactly what a
// hand-rolled route object (tests, some deep-link entry points) does not
// do.
const activeDocumentId = computed(() => {
  const parsed = parseAppPath(route.path)
  return parsed.kind === 'doc' ? parsed.documentId : ''
})

const currentView = computed(() => {
  const path = route.path
  if (path === '/app/settings') return 'settings'
  // NEW (plan: 2026-09-02-kanban-settings-as-page). Path-based
  // kanban-settings route (/app/kanban/:itemId/settings). Must come
  // BEFORE the route.query.view fallthrough because the URL has no
  // `view=` query param — the path IS the discriminator.
  //
  // The regex matches /app/kanban/<itemId>/settings with optional
  // trailing slash. It deliberately does NOT match /app/kanban/X
  // (no /settings) — the kanban board itself stays at the existing
  // ?view=workspace URL, so a future migration to /app/kanban/:itemId
  // would be a separate plan.
  if (/^\/app\/kanban\/[^/]+\/settings\/?$/.test(path)) {
    return 'kanban-settings'
  }
  // Workspace settings page, `/app/:workspaceId/settings`. Same shape as
  // the kanban-settings branch above and for the same reason: the path IS
  // the discriminator, there is no `view=` query param to read, and it must
  // be resolved before anything below claims a `/app/{id}` path. Checked
  // here rather than in `parseAppPath` because `helpers/appUrl.ts` is not
  // on this feature's edit surface — the regex keeps the new shape local.
  if (/^\/app\/[^/]+\/settings\/?$/.test(path)) {
    return 'workspace-settings'
  }
  // gitfile view - check only the ref (set synchronously before navigation)
  if (gitViewerFile.value) {
    console.log('[currentView] returning gitfile, gitViewerFile:', gitViewerFile.value.path)
    return 'gitfile'
  }
  // skill view - check only the ref
  if (skillViewerSkill.value) {
    console.log('[currentView] returning skill, skillViewerSkill:', skillViewerSkill.value.name)
    return 'skill'
  }
  console.log('[currentView] skillViewerSkill is null, checking route')
  // code-editor view - the open file wins UNLESS a chat surface can
  // display it itself. ChatView renders the file in its center column
  // (next to the chat-owned right sidebar, like the stacked center
  // diff), so claiming the whole <main> here would unmount ChatView
  // and take the sidebar with it. Everywhere else (kanban board,
  // design canvas, settings, chats list) there is no ChatView and this
  // overlay is the only surface. See `chatSurfaceActive`.
  if (codeEditorFile.value && !chatSurfaceActive.value) return 'code-editor'

  // Path-based contract (plan: 2026-09-22-revamp-ui-chats). Projects
  // are workspace items, so every project path is the 'workspace'
  // view. The landing renders <Chats> (which now hosts workspace
  // creation), so it reports 'chat' — same as a bare /app with no
  // query. Legacy /app/chat/:sid + /app/task/:tid fall through to
  // the query default below ('chat'); the boot rewrite converts them
  // to paths on the next tick.
  const parsedPath = parseAppPath(path)
  // Document page (Migration 095). It is a PAGE, not an overlay: it sits
  // in the same `v-else-if` chain as every other main view, so the chat
  // behind it is unmounted rather than stacked under. Checked before the
  // workspace/chat branches so nothing else can claim a doc path.
  if (parsedPath.kind === 'doc') return 'documents'
  if (
    parsedPath.kind === 'workspace' ||
    parsedPath.kind === 'project' ||
    parsedPath.kind === 'projectChat'
  ) {
    return 'workspace'
  }
  if (parsedPath.kind === 'chat' || parsedPath.kind === 'landing') {
    return 'chat'
  }

  // SIMPLIFY-URL-BROWSER (2026-08-15): the URL never says
  // `view=task` anymore (legacy URLs are auto-rewritten on mount).
  // The chat-open state is encoded as /chat/<taskId> on itemId
  // when view=workspace, so `currentView` returns 'workspace' for
  // both no-chat and chat-open states.
  const view = (route.query.view as string) || 'chat'
  console.log('[currentView] returning route view:', view)
  return view
})

const activeTask = computed(() => workspacesStore.activeTask)

// Workspace-item id of the currently-active task. Used by the
// 3-column kanban|chatview template branch to make sure the
// chatview and the kanban belong to the same parent — otherwise
// we'd render a chatview of a non-kanban task alongside an
// unrelated kanban (visual mess). The lookup walks every
// workspace's tasks looking for `activeTaskId`; returns the
// containing item's id or null. Cheap O(W) where W = number of
// tasks across all workspaces.
const activeTaskWorkspaceItemId = computed(() => workspacesStore.activeTaskWorkspaceItemId)

/**
 * True when the <main> chain is showing a ChatView surface — i.e. when
 * ChatView owns the center column AND the chat-owned right sidebar
 * (Explorer / Files changed / Terminal).
 *
 * Single source of truth for the three call sites that must agree:
 *   1. `currentView` — only claim the whole <main> for the code viewer
 *      when this is false (otherwise ChatView would be unmounted and the
 *      sidebar would vanish with it).
 *   2. ChatView, via the injected `CODE_VIEWER_STATE_KEY`, renders the
 *      file in its center column when a file is open.
 *
 * The three chat branches of the chain, faithfully:
 *   - inline task chats: kanban → `<ChatView>`, agent →
 *     `<AgentChatView>` (wraps ChatView), folder/memory/chat →
 *     `<StandardTaskChatView>` (wraps ChatView). All three gate on
 *     "the active task belongs to the active workspace item".
 *   - standalone chat: `<ChatView v-else-if="activeChatId.startsWith('chat-')">`.
 *
 * NOT chat surfaces (they keep AppLayout's full-surface viewer):
 *   - design items — their chat is the `DesignChatDialog` modal;
 *   - the chats list (`<Chats>`) — no active chat session at all.
 */
const chatSurfaceActive = computed(() => {
  const item = activeWorkspaceItem.value
  if (item?.item_type === 'design') return false
  if (activeTask.value && activeTaskWorkspaceItemId.value === item?.id) return true
  return activeChatId.value.startsWith('chat-')
})

// ─── Kanban task chat ────────────────────────────────────────────────────────
//
// The kanban task chat is a normal view in the <main> chain (see the
// `activeWorkspaceItem.item_type === 'kanban'` branch, which sits BEFORE
// the KanbanView branch), not a modal. There is therefore no open-state
// ref or watcher here: the chain's `activeTask` gate IS the state, and the
// board tab and the chat tab are two different tab keys pointing at the
// same item. Closing is handled by handleCloseTaskView, which closes the
// owning tab when tab mode gives the chat one.

// Captured from DesignView's `openChat` payload — the design page's
// own name (NOT the workspace item name). The dialog's header uses
// it as "Design Chat: <pageName>". Mirrors the FK-plan naming
// convention (2026-07-28-design-page-workspace-item-task-fk.md).
// Cleared when activeTask is cleared so a stale pageName from a prior
// chat doesn't leak into the next opened chat's header.
const activeDesignChatPageName = ref<string>('')

// ─── Design chat task FK handle (plan: 2026-08-06-design-chat-as-dialog,
//     bug fix from user report "the chat button keep not popup, chatview") ────
//
// Root cause: the design chat dialog's v-if gate was `activeTask && ...
// item_type === 'design'`. The `activeTask` computed walks
// `workspaces.value[].items[].tasks` looking for the task — but in
// PRODUCTION design items have empty `tasks` arrays after `init()`:
//   - `getWorkspacesItems` returns items WITHOUT tasks
//     (WorkspaceItemInfo struct in llm_history.zig:3208 has no `tasks` field)
//   - `init()` SKIPS `api.getTasks` for `item_type === 'design'`
//     (workspaces.ts:639 — only folders + other types fetch per-item tasks)
//   - The pre-fix 3-column [DesignView | resize-handle | ChatView]
//     layout used the same gate — it was BROKEN in production too.
//     The fix: capture the FK's `workspaceItemTaskId` directly via a
//     separate ref (this one), build a synthetic Task for the dialog,
//     and gate the dialog on THIS ref's truthiness — NOT on the
//     store's `activeTask` computed. `setActiveTask(...)` is still
//     called in `handleDesignOpenChat` (drives URL sync + handleCloseTaskView),
//     but the dialog no longer depends on its computed.
const activeDesignChatTaskId = ref<string>('')
// The store's `activeTaskId` going falsy clears the design-chat refs so
// the dialog unmounts — handled by the store subscription pump below,
// which reads `activeTaskId` directly (NOT the computed `activeTask`)
// so it fires even when activeTask stays null the whole time (the case
// for design items — see the bug comment above).

// Synthetic Task for DesignChatDialog. ChatView's API expects a
// Task object with at minimum `id` (chat-id) and `name` (for the
// title fallback). Real design-chat tasks live in
// `workspace_item_tasks` rows accessible via the per-page FK in
// `design_pages.workspace_item_task_id` — but the store's
// `workspaces.value[].items[].tasks` array is empty for design
// items after init() (see the bug comment above), so the store's
// `activeTask` computed returns null and we can't pass it
// directly. Build a minimal Task from the captured FK info.
//
// `name` reads "Design Chat: <pageName>" when pageName is set,
// otherwise falls back to "Design Chat" (matches the dialog's
// header fallback). `taskType: 'standard'` matches the row created
// at page-create time per the FK plan.
const activeDesignChatTask = computed<TaskType | null>(() => {
  if (!activeDesignChatTaskId.value) return null
  return {
    id: activeDesignChatTaskId.value,
    name: activeDesignChatPageName.value
      ? `Design Chat: ${activeDesignChatPageName.value}`
      : 'Design Chat',
    description: '',
    taskType: 'standard',
  } as TaskType
})

// ─── DesignChatDialog open state (plan: 2026-08-06-design-chat-as-dialog) ────
//
// Same v-model:show pattern the kanban chat modal used to have. The
// design dialog opens whenever activeDesignChatTaskId is set AND the
// active item is a design — the gating happens in the template
// (v-if), not here. We drive `show` from `activeDesignChatTaskId`
// (NOT from `activeTask` like the kanban version) because the
// store's `activeTask` is null for design items (their tasks
// array is empty post-init; see the bug comment below).
//
// 2026-08-06: prior to this plan, the design chat was rendered as a
// RIGHT-side column of a 3-column DesignView | resize-handle |
// ChatView layout, with a floating collapse button to hide it. The
// 3-column took ~40% of the canvas even when "minimised". Switching
// to a centred modal dialog reclaims the
// full canvas width — the dialog opens on top of the canvas with a
// dimmed backdrop. The collapse-state + design resize handle +
// DESIGN_WIDTH_STORAGE_KEY localStorage are removed below.
// Open state IS "there is an active design chat task id" — so express that as
// a writable computed instead of a ref plus a watcher that keeps the two in
// sync. The ref version needed `{ immediate: true }` and still left a window
// where the dialog's own `v-model:show` write and the watcher could disagree.
const designChatDialogOpen = computed({
  get: () => !!activeDesignChatTaskId.value,
  // The dialog can only ask to close (it never opens itself). Closing clears
  // the id, which is what "closed" actually means everywhere else.
  set: (open: boolean) => {
    if (!open) activeDesignChatTaskId.value = ''
  },
})

// Agent Mode (plan 2026-08-15-agent-mode, task_1786962724740_0):
// agent chat inline view. Driven by `activeTask` — when the
// user clicks a chat task under an agent, `activeTaskWorkspaceItemId`
// equals the agent's item id and `activeTaskWorkspaceItem.item_type`
// is `'agent'`. The AgentChatView's v-if gates on this exact case.
const agentKnowledge = ref<api.AgentKnowledgeRow[]>([])
const agentTools = ref<string[]>([])
// Agent system prompts (Migration 080) — same plain-ref pattern as
// knowledge above; the GET /agent bundle carries them in one round-trip.
const agentSystemPrompts = ref<api.AgentSystemPromptRow[]>([])

// True while `loadAgentData` is in flight. AgentView's knowledge and
// system-prompt panels gate their skeletons on this — without it they
// render "No knowledge files yet." / "No system prompts yet." during
// the fetch, which is a false statement about the agent's data.
const agentDataLoading = ref(false)

// FIX (agent-tools-fetch-on-view): the previous code only fetched
// `agentTools` inside the `activeTask` watcher. When the user landed
// directly on the agent view (?view=workspace&itemId=AGENT_ID,
// no chat task), activeTask was null and the watcher never fired —
// the Tools panel rendered with an empty `tools` array, every
// checkbox showed as unchecked, and clicking one POSTed against an
// existing row → 409 "tool already enabled for this agent".
//
// Now: a dedicated watcher on `activeWorkspaceItemId` fetches the
// agent data whenever the user lands on (or navigates between)
// agent items, regardless of whether a chat task is active. The
// `activeTask` watcher is reduced to only controlling the chat
// dialog visibility (no fetch).
async function loadAgentData(agentItemId: string) {
  agentDataLoading.value = true
  try {
    const wsId = activeWorkspace?.value?.id
    if (!wsId) return
    const data = await api.getAgent(wsId, agentItemId)
    agentKnowledge.value = data.knowledge
    agentTools.value = data.tools
    // Migration 080: the bundle now carries system_prompts too. Guard
    // for older binaries that don't include the field yet.
    agentSystemPrompts.value = data.system_prompts ?? []
  } catch (e) {
    console.error('[AppLayout] failed to load agent:', e)
  } finally {
    // Cleared on BOTH paths — a failed fetch must not park the
    // skeleton forever (the panels fall back to their empty states,
    // which is the honest answer when the request failed).
    agentDataLoading.value = false
  }
}

// Load agent bundle for agent items (replaces the old item-id watcher).
// AppLayout.agentToolsFetchOnView green) + the store subscription pump
// (covers in-app navigation to an agent item).
let lastAgentLoadItemId: string | null = null
const maybeLoadAgentData = () => {
  const id = activeWorkspaceItem.value?.id
  if (!id || activeWorkspaceItem.value?.item_type !== 'agent') return
  // Fire once per item id (replicates the old watcher, which only fired
  // on change): setup + onMounted + pump must not triple-fetch.
  if (id === lastAgentLoadItemId) return
  lastAgentLoadItemId = id
  // Fire-and-forget; loadAgentData assigns the refs itself.
  void loadAgentData(id)
}
// Setup-time call (replicates the old immediate watcher): the setup-time
// restore above already set the item for direct landings.
maybeLoadAgentData()

// Agent knowledge dialog open state + last-targeted agent id.
// `activeWorkspaceItem` still being set when the user submits (the
// user could navigate away mid-dialog).
const agentKnowledgeDialogOpen = ref(false)
const agentKnowledgeError = ref<string | null>(null)
const agentKnowledgeBusy = ref(false)

function openAgentKnowledgeDialog() {
  if (!activeWorkspaceItem.value || activeWorkspaceItem.value.item_type !== 'agent') return
  agentKnowledgeError.value = null
  agentKnowledgeDialogOpen.value = true
}

async function handleAgentAddKnowledge() {
  // v1.1 wiring: open the AgentKnowledgeDialog. Submission is
  // handled by `handleAgentKnowledgeCreate` (the dialog's `create`
  // emit). Keep this as a thin open-dialog shim so AgentView's emit
  // contract stays stable.
  openAgentKnowledgeDialog()
}

function closeAgentKnowledgeDialog() {
  agentKnowledgeDialogOpen.value = false
  agentKnowledgeError.value = null
}

async function handleAgentKnowledgeCreate(filePath: string, label: string, content: string) {
  const wsId = activeWorkspace?.value?.id
  const itemId = activeWorkspaceItem.value?.id
  if (!wsId || !itemId || activeWorkspaceItem.value?.item_type !== 'agent') return

  agentKnowledgeBusy.value = true
  agentKnowledgeError.value = null
  try {
    // The backend expects `agentId` (== workspace_item_id for agents)
    // on `POST /api/agents/:agentId/knowledge`. AddAgentItem's
    // convention (Migration 076) is that agents.id == workspace_items.id.
    // `content` is non-empty for text-mode adds; the backend
    // XOR-validates file_path vs content.
    const newRow = await api.addAgentKnowledge(itemId, filePath, label, content)
    // Optimistic append — the GET /agent response won't be re-fetched
    // until the user navigates away and back. Without this, the new
    // row is invisible in the UI until a full reload.
    agentKnowledge.value = [...agentKnowledge.value, newRow]
    closeAgentKnowledgeDialog()
  } catch (e) {
    agentKnowledgeError.value = e instanceof Error ? e.message : 'Failed to add knowledge'
    // Keep the dialog open so the user can see + retry.
  } finally {
    agentKnowledgeBusy.value = false
  }
}

async function handleAgentRemoveKnowledge(knowledgeId: string) {
  const wsId = activeWorkspace?.value?.id
  const itemId = activeWorkspaceItem.value?.id
  if (!wsId || !itemId || activeWorkspaceItem.value?.item_type !== 'agent') return

  // Optimistic remove + restore on failure.
  const previous = agentKnowledge.value
  agentKnowledge.value = previous.filter((k) => k.id !== knowledgeId)
  try {
    await api.deleteAgentKnowledge(itemId, knowledgeId)
  } catch (e) {
    // Restore the row so the user can retry.
    agentKnowledge.value = previous
    console.error('[AppLayout] failed to remove knowledge:', e)
  }
}

// Agent knowledge EDIT dialog (plan 2026-08-22-agent-mode-ui-ux, A2).
// Same open/busy/error pattern as the add dialog above. `row` is
// captured at open-time so navigation mid-dialog can't break the save.
const agentKnowledgeDetailOpen = ref(false)
const agentKnowledgeDetailRow = ref<api.AgentKnowledgeRow | null>(null)
const agentKnowledgeDetailBusy = ref(false)
const agentKnowledgeDetailError = ref<string | null>(null)

function handleAgentEditKnowledge(row: AgnosticKnowledgeRow) {
  if (!activeWorkspaceItem.value || activeWorkspaceItem.value.item_type !== 'agent') return
  agentKnowledgeDetailRow.value = row as api.AgentKnowledgeRow
  agentKnowledgeDetailError.value = null
  agentKnowledgeDetailOpen.value = true
}

function closeAgentKnowledgeDetailDialog() {
  agentKnowledgeDetailOpen.value = false
  agentKnowledgeDetailError.value = null
}

async function handleAgentKnowledgeSave(
  knowledgeId: string,
  updates: { label: string; file_path?: string; content?: string },
) {
  const itemId = activeWorkspaceItem.value?.id
  if (!itemId || activeWorkspaceItem.value?.item_type !== 'agent') return

  agentKnowledgeDetailBusy.value = true
  agentKnowledgeDetailError.value = null
  try {
    // The dialog always sends both source fields (file_path + content,
    // one of them '') so a File↔Text mode switch flips the row cleanly.
    const updated = await api.updateAgentKnowledge(itemId, knowledgeId, updates)
    // Replace in place so list order is preserved.
    agentKnowledge.value = agentKnowledge.value.map((k) => (k.id === knowledgeId ? updated : k))
    closeAgentKnowledgeDetailDialog()
  } catch (e) {
    // ApiError carries the backend's JSON body (e.g. {"error":"..."}).
    // Surface the specific message, not the generic "HTTP 400 Bad
    // Request" — the user needs to know WHAT was rejected.
    agentKnowledgeDetailError.value =
      e instanceof api.ApiError && e.body
        ? (tryParseErrorBody(e.body) ?? e.message)
        : e instanceof Error
          ? e.message
          : 'Failed to update knowledge'
    // Keep the dialog open so the user can see + retry.
  } finally {
    agentKnowledgeDetailBusy.value = false
  }
}

/** Extract the `error` field from a JSON error body, if present. */
function tryParseErrorBody(body: string): string | null {
  try {
    const obj = JSON.parse(body)
    if (obj && typeof obj === 'object' && typeof obj.error === 'string') {
      return obj.error
    }
    return null
  } catch {
    return null
  }
}

// ─── Agent System Prompt dialog (Migration 080, plan 2026-08-21-agent-system-prompt) ──
// Same open/busy/error pattern as the knowledge dialogs above. One
// dialog serves add (row=null) and edit (row set).
const agentSystemPromptDialogOpen = ref(false)
const agentSystemPromptRow = ref<api.AgentSystemPromptRow | null>(null)
const agentSystemPromptBusy = ref(false)
const agentSystemPromptError = ref<string | null>(null)

function handleAgentAddSystemPrompt() {
  if (!activeWorkspaceItem.value || activeWorkspaceItem.value.item_type !== 'agent') return
  agentSystemPromptRow.value = null
  agentSystemPromptError.value = null
  agentSystemPromptDialogOpen.value = true
}

function handleAgentEditSystemPrompt(row: AgnosticSystemPromptRow) {
  if (!activeWorkspaceItem.value || activeWorkspaceItem.value.item_type !== 'agent') return
  agentSystemPromptRow.value = row as api.AgentSystemPromptRow
  agentSystemPromptError.value = null
  agentSystemPromptDialogOpen.value = true
}

function closeAgentSystemPromptDialog() {
  agentSystemPromptDialogOpen.value = false
  agentSystemPromptError.value = null
}

async function handleAgentSystemPromptCreate(title: string, content: string) {
  const itemId = activeWorkspaceItem.value?.id
  if (!itemId || activeWorkspaceItem.value?.item_type !== 'agent') return

  agentSystemPromptBusy.value = true
  agentSystemPromptError.value = null
  try {
    // agents.id == workspace_item_id (Migration 076 spec D3).
    const newRow = await api.addAgentSystemPrompt(itemId, title, content)
    // Optimistic append — same rationale as knowledge create.
    agentSystemPrompts.value = [...agentSystemPrompts.value, newRow]
    closeAgentSystemPromptDialog()
  } catch (e) {
    // Surface the backend's specific error message when available.
    agentSystemPromptError.value =
      e instanceof api.ApiError && e.body
        ? (tryParseErrorBody(e.body) ?? e.message)
        : e instanceof Error
          ? e.message
          : 'Failed to add system prompt'
    // Keep the dialog open so the user can see + retry.
  } finally {
    agentSystemPromptBusy.value = false
  }
}

async function handleAgentSystemPromptSave(
  promptId: string,
  updates: { title: string; content: string },
) {
  const itemId = activeWorkspaceItem.value?.id
  if (!itemId || activeWorkspaceItem.value?.item_type !== 'agent') return

  agentSystemPromptBusy.value = true
  agentSystemPromptError.value = null
  try {
    const updated = await api.updateAgentSystemPrompt(itemId, promptId, updates)
    // Replace in place so list order is preserved.
    agentSystemPrompts.value = agentSystemPrompts.value.map((p) =>
      p.id === promptId ? updated : p,
    )
    closeAgentSystemPromptDialog()
  } catch (e) {
    agentSystemPromptError.value =
      e instanceof api.ApiError && e.body
        ? (tryParseErrorBody(e.body) ?? e.message)
        : e instanceof Error
          ? e.message
          : 'Failed to update system prompt'
  } finally {
    agentSystemPromptBusy.value = false
  }
}

async function handleAgentRemoveSystemPrompt(promptId: string) {
  const itemId = activeWorkspaceItem.value?.id
  if (!itemId || activeWorkspaceItem.value?.item_type !== 'agent') return

  // Optimistic remove + restore on failure.
  const previous = agentSystemPrompts.value
  agentSystemPrompts.value = previous.filter((p) => p.id !== promptId)
  try {
    await api.deleteAgentSystemPrompt(itemId, promptId)
  } catch (e) {
    // Restore the row so the user can retry.
    agentSystemPrompts.value = previous
    console.error('[AppLayout] failed to remove system prompt:', e)
  }
}

async function handleAgentToggleTool(toolName: string, enabled: boolean) {
  if (!activeWorkspaceItem.value) return
  const agentId = activeWorkspaceItem.value.id
  const { nextLocal, serverPromise } = buildToggle(agentTools.value, toolName, enabled, agentId, {
    enableAgentTool: api.enableAgentTool,
    disableAgentTool: api.disableAgentTool,
    refetchAgentTools: async (id) => {
      const data = await api.getAgentTools(id)
      return data.tools
    },
  })
  // Optimistic update.
  agentTools.value = nextLocal
  const out = await serverPromise
  if ('error' in out) {
    // Revert + log.
    agentTools.value = enabled
      ? agentTools.value.filter((n) => n !== toolName)
      : [...agentTools.value, toolName]
    console.error('[AppLayout] toggle tool failed:', out.error)
    return
  }
  // Canonical state from server.
  agentTools.value = out.canonical
}

/**
 * Bulk-toggle multiple tools at once (fired by AgentView's
 * "Select all" / "Clear" buttons in the Tools panel). Runs every
 * tool through the same optimistic-then-server-confirm path as a
 * single toggle so failures are observable per-tool and the UI
 * stays in sync with the server canonical list.
 *
 * Concurrency: requests are fired in parallel (Promise.all) — the
 * backend handler is per-tool INSERT/DELETE so there is no
 * cross-row contention. On any failure we re-fetch the canonical
 * list from the server, which collapses partial successes into a
 * single coherent view.
 *
 * On the wire, individual enable/disable failures are logged but
 * don't abort the rest of the batch — the user gets the best-
 * effort outcome (everything they could enable was enabled) and
 * a re-fetch corrects any drift.
 */
async function handleAgentToggleToolsBulk(toolNames: string[], enabled: boolean) {
  if (!activeWorkspaceItem.value) return
  const agentId = activeWorkspaceItem.value.id
  if (toolNames.length === 0) return

  // Optimistic apply.
  const set = new Set(agentTools.value)
  for (const n of toolNames) {
    if (enabled) set.add(n)
    else set.delete(n)
  }
  agentTools.value = Array.from(set)

  try {
    const ops = toolNames.map(async (n) => {
      try {
        if (enabled) await api.enableAgentTool(agentId, n)
        else await api.disableAgentTool(agentId, n)
        return { name: n, ok: true as const }
      } catch (e) {
        return { name: n, ok: false as const, error: e }
      }
    })
    const results = await Promise.all(ops)
    const failures = results.filter((r) => !r.ok)
    if (failures.length > 0) {
      console.error('[AppLayout] bulk toggle: some tools failed:', failures)
    }
    // Re-fetch the canonical list so partial successes + races collapse
    // into one coherent view. Cheap (one GET).
    const data = await api.getAgentTools(agentId)
    agentTools.value = data.tools
  } catch (e) {
    console.error('[AppLayout] bulk toggle failed:', e)
  }
}

// ─── Browser Back/forward ↔ task chat sync (non-tab mode) ─────
//
// Opening a task chat PUSHes `/app?...&itemId=<id>/chat/<taskId>`
// (Sidebar.handleSelectTask), so browser Back pops the URL back to
// the board URL — but nothing synced the STORE from the URL on
// popstate (the chat restore only ran onMounted), leaving the chat
// open on a board URL. This watcher closes that gap in both
// directions:
//   - Back (suffix gone, chat open) → clear activeTask +
//     activeChat so the board re-renders. No router call — the URL
//     is already the board URL.
//   - Forward (suffix back, chat closed) → re-open that task.
// Tab mode owns its own URL contract (tabs drive the URL via
// applyActiveTabToUrl), so this watcher stays out of its way there.
// Browser Back/forward task-chat sync (replaces the old itemId watcher;
// runs from the render pump below — see the block comment there for the
// Back/Forward contract). Kept as a named function for the pump.
const syncTaskFromItemId = () => {
  let rawItemId: string | undefined
  try {
    rawItemId = route.query.itemId as string | undefined
  } catch {
    return
  }
  try {
    if (tabsStore.enabled) return
    if (workspacesStore.isNavigatingToTask) return
    const parsed = parseItemIdWithChat(rawItemId ?? '')
    const urlTaskId = parsed.chatTaskId ?? null
    const activeTaskId = workspacesStore.activeTaskId ?? null
    if (urlTaskId === activeTaskId) return
    if (urlTaskId) {
      workspacesStore.setActiveTask(urlTaskId)
    } else if (activeTaskId) {
      workspacesStore.setActiveTask(null)
      navigationStore.clearActiveChat()
    }
  } catch {
    // Router/store absent in unit tests — nothing to sync.
  }
}

// Close the chatview column (the 3-column layout's right pane).
// Triggered by the ChatView's ✕ header button. Clears the active
// task and navigates to `view=workspace` so the URL remains the
// source of truth — a refresh of `/app?view=workspace` re-renders
// the kanban alone, with no leftover activeTask. Without the
// `router.replace`, the URL would still say `view=task&task=…`
// after the close, which would force a re-mount of the standalone
// task branch and the kanban would vanish.
//
// The chat list (ChatsList) is intentionally NOT touched here:
// closing the kanban task's chatview is independent of the chat
// list's active row (a kanban task has its own session, not a
// chat-row session). Clearing activeTask is sufficient.
const handleCloseTaskView = () => {
  // Tab mode: a kanban task chat owns its own tab, so "close the chat" means
  // "close that tab". Falling through to the router.replace below would rewrite
  // the CHAT tab's target to the bare board key instead — the funnel would then
  // focus the existing board tab and leave the chat tab behind as an orphaned
  // stale pointer.
  //
  // Scoped to kanban on purpose: design opens its chat as a dialog INSIDE the
  // canvas tab (closing it must keep that tab), and agent items are out of
  // scope for this change.
  const closingTab = tabsStore.activeTab
  const closingChatTaskId = closingTab
    ? parseItemIdWithChat(closingTab.query.itemId ?? '').chatTaskId
    : null
  if (
    tabsStore.enabled &&
    activeWorkspaceItem.value?.item_type === 'kanban' &&
    closingTab?.kind === 'workspace' &&
    closingChatTaskId
  ) {
    workspacesStore.setActiveTask(null)
    navigationStore.clearActiveChat()
    // close() activates the right neighbour, else the left. The chat tab was
    // inserted directly after the board tab, so this lands back on the board.
    // When the chat tab is the ONLY tab, close() opens a fresh home tab — the
    // browser-like fallback, deliberately not special-cased.
    tabsStore.close(closingTab.id)
    applyActiveTabToUrl()
    return
  }
  // CHATVIEW-BUG (fix): setActiveTask(null) does NOT clear the
  // navigation store's active chat anymore (the unconditional clear
  // broke the chat-nav paths in Sidebar.vue:316-322 and
  // ChatsList.vue:220-232). Since this is the ONLY path that needs
  // both the task AND the chat cleared (the user is closing the
  // chatview column of the 3-column kanban+chat layout and dropping
  // back to the workspace view), we now clear the chat explicitly
  // here. Without this explicit clear, the next page reload would
  // restore activeChatId from localStorage and pop the user back
  // into a chat they thought they had closed.
  workspacesStore.setActiveTask(null)
  navigationStore.clearActiveChat()
  // 2026-08-06 (design-chat-as-dialog bug fix): clearing
  // activeTaskId above triggers the watcher at the top of this
  // block which clears `activeDesignChatTaskId` and
  // `activeDesignChatPageName` — that's how the dialog unmounts.
  // (The watcher watches activeTaskId directly, NOT the computed
  // activeTask, because activeTask is null for design items the
  // whole time — see the comment at activeDesignChatTaskId.)
  // Preserve (workspaceId, itemId, pageId) when navigating back to
  // the workspace view — the active kanban/design item (and, for
  // design items, the active page) should survive a page reload.
  // Without this, the URL would be stripped to ?view=workspace and
  // a refresh would land on the empty state. The 3-column layout
  // already implies the user is on a workspace item (design or
  // kanban), so activeWorkspaceItemId is guaranteed truthy here —
  // but we guard anyway in case the chatview branch wins for an
  // unrelated chat session. pageId is design-item-scoped (empty
  // for kanban/folder items); only include it when set so the URL
  // stays clean for non-design items.
  const wsId = activeWorkspaceId.value
  const itemId = workspacesStore.activeWorkspaceItemId
  const pageId = workspacesStore.activeDesignPageId
  const sub: Record<string, string> = {}
  if (pageId) sub.pageId = pageId
  // Restore the kanban per-column sort state (kanban-sort-by plan,
  // 2026-08-06 — `?sorts=col_x:name:asc,...`). Sidebar's
  // handleSelectTask snapshots the user's sort choice before
  // navigating into the task view; we read it back here and put it
  // back into the URL. Without this, the round-trip drops the sort
  // (the user reported this 2026-08-06: "when click chatview, my
  // sort url is gone"). One round-trip's worth of state — the
  // store value is consumed once and cleared so a subsequent
  // close-without-a-task-open doesn't accidentally restore a stale
  // sort.
  if (workspacesStore.savedSortsParam) {
    sub.sorts = workspacesStore.savedSortsParam
    workspacesStore.savedSortsParam = ''
  }
  // Restore the kanban layout (columns | rows). Like `sorts`, this is
  // URL-only state, so it is read back off the current route rather than
  // the store. Without it, opening a task chat and closing it snapped the
  // board back to column mode.
  const urlLayout = route.query.layout
  if (typeof urlLayout === 'string' && urlLayout.length > 0) sub.layout = urlLayout
  if (wsId && itemId) {
    router.replace(buildAppUrl({ workspaceId: wsId, projectId: itemId, query: sub }))
  } else if (wsId) {
    router.replace(buildAppUrl({ workspaceId: wsId, query: sub }))
  } else {
    router.replace({ path: '/app', query: sub })
  }
}

// ─── Design 3-column resize (separate from kanban) ─────────────────────
//
// Design canvases need significantly more horizontal room than
// kanbans — a typical Figma-style page is 1440px wide, and
// DesignView itself contains its own 320px Layers+Properties
// sidebar at full width. The chat panel was eating the canvas
// because the old KANBAN constants (default 40%, max 720px) were
// reused for design (commit d0a05eb0, 2026-07-14) — 40% of the
// main area minus 320px internal sidebar left the canvas viewport
// visibly cramped (the user reported this 2026-07-25).
//
// Design uses its own constants + a SEPARATE localStorage key
// (kanban-column-width is also used by kanban view, so reusing it
// would bleed prefs across modes). State and handlers mirror the
// kanban block above but reference DESIGN_*.
//
// Bounds rationale + the entire RESIZE state machine
// (DESIGN_MIN_WIDTH / DESIGN_MAX_WIDTH / DESIGN_DEFAULT_WIDTH /
// DESIGN_WIDTH_STORAGE_KEY / loadDesignColumnWidth /
// designColumnWidth / isDesignResizing / designResizeStartX /
// designResizeStartWidth / startDesignResize / handleDesignResize /
// stopDesignResize / designColumnStyle) + the COLLAPSE state
// machine (DESIGN_CHAT_COLLAPSED_KEY / loadDesignChatCollapsed /
// designChatCollapsed / toggleDesignChat) have been REMOVED as part
// of the design-chat-as-dialog plan (2026-08-06). The design chat
// no longer sits in a 3-column split — it's a centred modal dialog
// (DesignChatDialog) that opens on top of the full-width canvas.
// The resize handle and collapse toggle are gone with the 3-column
// branch.

// ─── Kanban main-content view (was inline in WorkspaceItem.vue;
// now mounted here so the board lives in the main content area, not
// in the sidebar). KanbanView consumes every event locally — the
// "+ Add" flow opens the KanbanTaskDetailDialog in create mode
// inside KanbanView (it owns the columns list, so resolving the
// target column is trivial), and the other events (move-task,
// add-column, etc.) are forwarded to the workspaces store here
// or to Sidebar for modal-opening handlers. AppLayout never wires
// any kanban events through sidebarRef — that path was removed in
// the kanban-add-task-via-detail-dialog feature. ──────────────

// KanbanColumnEditor modal state. Three modes (add / rename / delete)
// share the same component; we track the mode + the target column
// id + the initial name. Lives at the AppLayout scope so the editor
// is mounted exactly once (any kanban view emits request-rename-
// column / request-delete-column; we point them at this state).
type KanbanEditorMode = 'add' | 'rename' | 'delete'
const showKanbanColumnEditor = ref(false)
const kanbanColumnEditorMode = ref<KanbanEditorMode>('add')
const kanbanColumnEditorTargetId = ref<string | null>(null)
const kanbanColumnEditorInitialName = ref<string>('')
const kanbanColumnEditorInitialDescription = ref<string>('')

// Look up the column by id in the active kanban item. Returns
// undefined if the active item is missing or has no columns — the
// caller treats that as a no-op.
const findKanbanColumn = (columnId: string) => {
  return activeWorkspaceItem.value?.kanban_columns?.find((c) => c.id === columnId)
}

// + Column on the kanban header: open the editor in 'add' mode.
const handleKanbanAddColumn = () => {
  kanbanColumnEditorMode.value = 'add'
  kanbanColumnEditorTargetId.value = null
  kanbanColumnEditorInitialName.value = ''
  showKanbanColumnEditor.value = true
}

// ⋮ menu "Rename" on a column: open the editor in 'rename' mode,
// pre-filled with the column's current name and description.
const handleKanbanRequestRenameColumn = (columnId: string) => {
  const col = findKanbanColumn(columnId)
  if (!col) return
  kanbanColumnEditorMode.value = 'rename'
  kanbanColumnEditorTargetId.value = columnId
  kanbanColumnEditorInitialName.value = col.name
  kanbanColumnEditorInitialDescription.value = col.description ?? ''
  showKanbanColumnEditor.value = true
}

/** Forward a kanban rename (from either the Settings dialog header
 * pencil or the KanbanView header pencil) to the store. Both
 * children emit `rename-item` with the trimmed new name; the
 * store action optimistic-updates + rolls back on error.
 * Plan: docs/superpowers/plans/2026-06-30-edit-workspace-item-name.md */
const handleKanbanRenameItem = (newName: string) => {
  if (!activeWorkspaceItem.value) return
  const ws = activeWorkspace.value
  if (!ws) return
  void workspacesStore.updateKanbanItemName(ws.id, activeWorkspaceItem.value.id, newName)
}

// ⋮ menu "Delete" on a column: open the editor in 'delete' mode
// (the editor renders the confirmation copy itself).
const handleKanbanRequestDeleteColumn = (columnId: string) => {
  const col = findKanbanColumn(columnId)
  if (!col) return
  kanbanColumnEditorMode.value = 'delete'
  kanbanColumnEditorTargetId.value = columnId
  kanbanColumnEditorInitialName.value = col.name
  kanbanColumnEditorInitialDescription.value = col.description ?? ''
  showKanbanColumnEditor.value = true
}

const handleKanbanColumnEditorClose = () => {
  showKanbanColumnEditor.value = false
}

const handleKanbanColumnEditorAdd = (name: string, description: string) => {
  if (!activeWorkspaceItem.value) return
  const ws = activeWorkspace.value
  if (!ws) return
  void workspacesStore.addKanbanColumn(ws.id, activeWorkspaceItem.value.id, name, description)
  showKanbanColumnEditor.value = false
}

const handleKanbanColumnEditorRename = (name: string, description: string) => {
  if (!activeWorkspaceItem.value || !kanbanColumnEditorTargetId.value) return
  const ws = activeWorkspace.value
  if (!ws) return
  void workspacesStore.updateKanbanColumn(
    ws.id,
    activeWorkspaceItem.value.id,
    kanbanColumnEditorTargetId.value,
    { name, description },
  )
  showKanbanColumnEditor.value = false
}

const handleKanbanColumnEditorDelete = () => {
  if (!activeWorkspaceItem.value || !kanbanColumnEditorTargetId.value) return
  const ws = activeWorkspace.value
  if (!ws) return
  void workspacesStore.deleteKanbanColumn(
    ws.id,
    activeWorkspaceItem.value.id,
    kanbanColumnEditorTargetId.value,
  )
  showKanbanColumnEditor.value = false
}

// ─── Kanban settings page (plan: 2026-09-02-kanban-settings-as-page) ────
//
// The settings UI moved from a centered modal dialog (the deleted
// KanbanSettingsDialog) to a dedicated full-page route
// (/app/kanban/:itemId/settings). Clicking ⚙ on a kanban board
// header now pushes a vue-router path route instead of opening a
// dialog. The new <KanbanSettingsView> component (mounted below)
// is gated on currentView === 'kanban-settings'.
//
// The handlers below route the page's emits (addColumn, editColumn,
// deleteColumn, renameItem, copySpec) to the existing
// workspacesStore actions — same contract as the old dialog, no
// backend changes.
const handleOpenKanbanSettings = () => {
  const itemId = activeWorkspaceItem.value?.id ?? ''
  if (!itemId) return
  // Path-based route: /app/kanban/:itemId/settings (registered in
  // router/index.ts). workspaceId is derived from the store by the
  // page itself — no need to encode it in the URL (itemId is
  // globally unique across all workspaces).
  router.push({ path: `/app/kanban/${itemId}/settings` })
}

const handleKanbanSettingsAddColumn = (name: string, description: string) => {
  if (!activeWorkspaceItem.value) return
  const ws = activeWorkspace.value
  if (!ws) return
  void workspacesStore.addKanbanColumn(ws.id, activeWorkspaceItem.value.id, name, description)
  // Dialog stays open so the user can add more columns in succession.
}

const handleKanbanSettingsEditColumn = (payload: {
  columnId: string
  name: string
  description: string
}) => {
  if (!activeWorkspaceItem.value) return
  const ws = activeWorkspace.value
  if (!ws) return
  void workspacesStore.updateKanbanColumn(ws.id, activeWorkspaceItem.value.id, payload.columnId, {
    name: payload.name,
    description: payload.description,
  })
}

const handleKanbanSettingsDeleteColumn = (columnId: string) => {
  if (!activeWorkspaceItem.value) return
  const ws = activeWorkspace.value
  if (!ws) return
  void workspacesStore.deleteKanbanColumn(ws.id, activeWorkspaceItem.value.id, columnId)
}

// ─── CopyKanbanSpecDialog ────────────────────────────────────────────────
//
// Per-board "copy columns from another kanban" flow. Triggered by
// the "Copy spec…" footer button in KanbanSettingsDialog. The
// dialog itself is a modal with a source picker + Replace/Append
// radio; this handler delegates to workspacesStore.copyKanbanSpecFrom
// which calls POST /kanban/copy_spec_from and refreshes the target's
// local kanban_columns from the backend's response.
const showCopyKanbanSpecDialog = ref(false)

const handleOpenCopyKanbanSpec = () => {
  showCopyKanbanSpecDialog.value = true
}

const handleCloseCopyKanbanSpec = () => {
  showCopyKanbanSpecDialog.value = false
}

const handleCopyKanbanSpec = (sourceItemId: string, mode: 'replace' | 'append') => {
  if (!activeWorkspaceItem.value || !activeWorkspace.value) return
  void workspacesStore
    .copyKanbanSpecFrom(activeWorkspace.value.id, activeWorkspaceItem.value.id, sourceItemId, mode)
    .then(() => {
      showCopyKanbanSpecDialog.value = false
    })
}

// + Add on a column: handled LOCALLY by KanbanView (no longer
// bubbles up here). KanbanView opens the KanbanTaskDetailDialog
// in create mode, then calls workspacesStore.addTask +
// moveTaskToColumn on submit. AppLayout doesn't wire this event
// anymore — see the comment at the top of the kanban section.

// Drag-and-drop task move between columns. Direct store call.
const handleKanbanMoveTask = (payload: { taskId: string; columnId: string; position: number }) => {
  if (!activeWorkspaceItem.value) return
  const ws = activeWorkspace.value
  if (!ws) return
  void workspacesStore.moveTaskToColumn(
    ws.id,
    activeWorkspaceItem.value.id,
    payload.taskId,
    payload.columnId,
    payload.position,
  )
}

// "Rename column" emitted from the inline rename input inside
// <KanbanColumn>. The column lets the user type a new name
// directly (no modal) and emits this on blur / Enter. Direct store
// call.
const handleKanbanRenameColumn = (payload: { columnId: string; name: string }) => {
  if (!activeWorkspaceItem.value) return
  const ws = activeWorkspace.value
  if (!ws) return
  void workspacesStore.updateKanbanColumn(ws.id, activeWorkspaceItem.value.id, payload.columnId, {
    name: payload.name,
  })
}

// "Delete column" emitted from the column's quick-delete path (the
// ⋮ menu's "Delete" goes through the editor flow above, but the
// column may also expose a faster path in a future iteration).
// Direct store call.
const handleKanbanDeleteColumn = (columnId: string) => {
  if (!activeWorkspaceItem.value) return
  const ws = activeWorkspace.value
  if (!ws) return
  void workspacesStore.deleteKanbanColumn(ws.id, activeWorkspaceItem.value.id, columnId)
}

// Column header drag-and-drop reorder (Trello/Jira UX). Direct store
// call — the store action resolves the target column's current
// position, PATCHes the moved column, and re-fetches the full
// column list (because the backend's PATCH response only includes
// the moved column, but siblings were renumbered too).
const handleKanbanReorderColumn = (payload: { columnId: string; targetColumnId: string }) => {
  if (!activeWorkspaceItem.value) return
  const ws = activeWorkspace.value
  if (!ws) return
  void workspacesStore.reorderKanbanColumn(
    ws.id,
    activeWorkspaceItem.value.id,
    payload.columnId,
    payload.targetColumnId,
  )
}

// Task-level events (select-task, delete-task, rename-task,
// pin-task) re-emitted by <KanbanColumn>.
// These all live in Sidebar (because they need access to
// chatsListRef and the modal state for rename), so
// we forward them via the exposed methods. The sidebar ref is
// non-null at runtime (AppLayout always renders a Sidebar); the
// optional-chaining + noop-on-miss is defensive for the
// initial-render / unmount edge case.

// select-task: click a card → open the task's chat view.
const handleKanbanSelectTask = (taskId: string) => {
  sidebarRef.value?.selectTask(taskId)
}

// Right-click "Open in new tab" on a kanban card. Builds the task
// chat URL from the card's explicit ids and opens a real browser
// tab — no store mutation, the board stays put.
const handleKanbanOpenTaskInBackground = (payload: {
  workspaceId: string
  itemId: string
  taskId: string
}) => {
  openInNewTab(
    router,
    buildTaskAppUrl({
      taskId: payload.taskId,
      activeWorkspaceId: payload.workspaceId || activeWorkspace?.value?.id || null,
      activeWorkspaceItemId: payload.itemId || null,
      activeDesignPageId: null,
      activeItemType: 'kanban',
      currentQuery: route.query,
    }),
  )
}

// Right-click "Open details in new tab" on a kanban card. Builds
// the BOARD url (no /chat/ suffix) + ?detail=<taskId> so the new
// tab loads the kanban with the inline detail panel pre-opened.
// Preserves sorts/pageId breadcrumb via currentQuery.
const handleKanbanOpenTaskDetailInBackground = (payload: {
  workspaceId: string
  itemId: string
  taskId: string
}) => {
  const pathParsed = parseAppPath(route.path)
  const wsId =
    payload.workspaceId ||
    activeWorkspace?.value?.id ||
    (pathParsed.kind === 'project' || pathParsed.kind === 'projectChat'
      ? pathParsed.workspaceId
      : '') ||
    (route.query.workspaceId as string) ||
    ''
  const pathProject =
    pathParsed.kind === 'project' || pathParsed.kind === 'projectChat' ? pathParsed.projectId : ''
  const bareItemId =
    payload.itemId ||
    pathProject ||
    parseItemIdWithChat((route.query.itemId as string) ?? '').itemId ||
    activeWorkspaceItem?.value?.id ||
    ''
  // Strip any existing /chat/ suffix — the detail tab is the
  // board, not the chat.
  const bare = bareItemId.split('/chat/')[0] ?? bareItemId
  const sub: Record<string, string> = { detail: payload.taskId }
  const sorts = route.query.sorts
  if (typeof sorts === 'string' && sorts !== '') sub.sorts = sorts
  openInNewTab(router, buildAppUrl({ workspaceId: wsId, projectId: bare, query: sub }))
}

const handleKanbanDeleteTask = (workspaceId: string, itemId: string, taskId: string) => {
  sidebarRef.value?.deleteTask(workspaceId, itemId, taskId)
}

const handleKanbanRenameTask = (
  workspaceId: string,
  itemId: string,
  taskId: string,
  currentName: string,
) => {
  sidebarRef.value?.renameTask(workspaceId, itemId, taskId, currentName)
}

const handleKanbanPinTask = (
  workspaceId: string,
  itemId: string,
  taskId: string,
  isPinned: boolean,
) => {
  sidebarRef.value?.pinTask(workspaceId, itemId, taskId, isPinned)
}

// ─── Design mode event handlers (Chunk 8 of design-mode-redesign) ────
//
// <DesignView> emits these when the user interacts with the canvas:
// tabs, layers, properties panel, Monaco editor. We forward them to
// the workspaces store + useDesignHandlers composable.
//
// pageId note: DesignView keeps the active page id in a LOCAL ref
// (its `activePageId`); the workspaces store does not yet track the
// active page. The selectPage/selectElement emits are currently
// noops — the parent doesn't need the info, the child already
// owns the state. Element mutations need pageId, which the store's
// `activeDesignPageId` (mirrored by DesignView's activePageId sync,
// ...)`) provides.
//
// Page CRUD (add / delete) used to live here too — we would bounce
// the click event up from DesignView, call the API, and trust that
// DesignView would re-fetch its pages list. It didn't, leaving the
// user staring at stale tabs until they reloaded the page. The
// fix moved the page CRUD into DesignView itself (which owns the
// `pages` state), so AppLayout no longer needs addPage /
// deletePage handlers.
const handleDesignSelectPage = (_pageId: string) => {
  // TODO (v2): workspacesStore.setActiveDesignPage(_pageId) once the
  // store tracks the active page. For now DesignView owns the page
  // state internally; the parent doesn't need to mirror it.
  void _pageId
}

const handleDesignSelectElement = (_elementId: string) => {
  // TODO (v2): workspacesStore.setActiveDesignElement(_elementId) so
  // other tabs / the right sidebar can show the element's properties.
  // For now selection state lives inside DesignView.
  void _elementId
}

// NEW: design-mode chat toggle (top-right 💬 button in DesignView).
// Finds or creates a per-page "Design Chat: <pageName>" standard
// task on the active design item and sets it as the active task,
// which triggers the 3-column "DesignView | resize-handle |
// ChatView" template below. Reuses the same per-page chat task
// across reopens (so history persists) — the look-up is by
// workspace_item_id + name = "Design Chat: <pageName>". Each
// design page gets a DISJOINT chat task; switching pages while a
// chat is open does NOT swap the active chat (the chat stays
// bound to the page that opened it; closing + reopening binds
// to the current page).
//
// Plan: docs/superpowers/plans/2026-07-28-design-per-page-chat-sessions.md
//
// Migration of legacy data: users created before this fix have a
// single "Design Chat" canonical task (the pre-fix behavior). On
// the first 💬 click on any page, that legacy task is RENAMED in
// place to "Design Chat: <activePageName>" via `api.updateTask`.
// The task id is preserved, so all existing `llm_history` rows
// stay attached. New pages the user visits later get fresh tasks
// via the existing `addTask` path.
//
// We could mark the task with a dedicated task_type (e.g.
// 'design_chat') and filter on that, but the existing standard
// task_type already gives us everything we need (no kanban auto-
// assign fires because the parent is not a kanban — see the
// parent_is_kanban check in createStandardTask at task_create.zig
// ~line 294) and adding a new task_type is a migration.
//
// 2026-07-28 FK rewrite (plan:
// docs/superpowers/plans/2026-07-28-design-page-workspace-item-task-fk.md):
// DESIGN_CHAT_TASK_NAME and PER_PAGE_CHAT_PREFIX are no longer used
// for chat lookup — the FK is the source of truth. `taskHasMessages`
// is gone too (no need to probe whether a task has messages — the
// FK is always populated at page-create time). The legacy
// pre-FK code that lived here (name matching, N+1 message probe,
// one-shot legacy migration) is removed; see the plan for the
// historical context.

const handleDesignOpenChat = async (payload: {
  pageId: string
  pageName: string
  workspaceItemTaskId: string
}): Promise<void> => {
  const ws = activeWorkspace.value
  const item = activeWorkspaceItem.value
  if (!ws || !item || item.item_type !== 'design') return
  if (!payload.pageId || !payload.pageName) return
  if (!payload.workspaceItemTaskId) return

  // 2026-07-28 FK rewrite (plan:
  // docs/superpowers/plans/2026-07-28-design-page-workspace-item-task-fk.md):
  // resolve the chat task via the FK directly. Each design page is
  // paired 1:1 with a workspace_item_tasks row at create time (see
  // design_model.setDesignPage) — the page row carries the task id
  // on the wire. No name matching, no legacy migration, no
  // `taskHasMessages` probe. The previous 2026-07-28 per-page
  // naming-convention implementation has been replaced.
  workspacesStore.setActiveTask(payload.workspaceItemTaskId)
  // 2026-08-06 (plan: design-chat-as-dialog): capture the design
  // page's own name so DesignChatDialog's header reads
  // "Design Chat: <pageName>". Distinct from the workspace item's
  // name (which would be the parent design's name like "Design").
  activeDesignChatPageName.value = payload.pageName
  // Bug fix (2026-08-06, user report "chat button keep not popup,
  // chatview"): the dialog's v-if was previously gated on the
  // store's `activeTask` computed, which is null for design items
  // (their tasks array is empty post-init). Capture the FK's
  // task id into a separate ref that the dialog actually reads;
  // see `activeDesignChatTaskId` declaration above.
  activeDesignChatTaskId.value = payload.workspaceItemTaskId
}

const handleDesignUpdateElement = async (
  elementId: string,
  patch: Partial<{
    x: number
    y: number
    width: number
    height: number
    rotation: number
    [k: string]: unknown
  }>,
): Promise<void> => {
  const ws = activeWorkspace.value
  const item = activeWorkspaceItem.value
  if (!ws || !item) return
  // Deprecated back-compat path (PATCH /geometry). New typed events
  // emit translateElement / resizeElement instead — see below.
  await designHandlers.updateElement(ws.id, item.id, elementId, patch)
}

/** NEW (2026-08-06, split-move-resize plan) — handler for the
 * `translateElement` event fired by DesignView during a single-element
 * drag (move mode). Routes to useDesignHandlers.translateElement →
 * POST /translate. Backend handles cascade-to-descendants for groups. */
const handleDesignTranslateElement = async (
  elementId: string,
  dx: number,
  dy: number,
): Promise<void> => {
  const ws = activeWorkspace.value
  const item = activeWorkspaceItem.value
  if (!ws || !item) return
  await designHandlers.translateElement(ws.id, item.id, elementId, dx, dy)
}

/** NEW (2026-08-06, split-move-resize plan) — handler for the
 * `resizeElement` event fired by DesignView during a resize gesture.
 * Routes to useDesignHandlers.resizeElement → POST /resize. Resize
 * never cascades (Figma convention). */
const handleDesignResizeElement = async (
  elementId: string,
  patch: Partial<{
    x: number
    y: number
    width: number
    height: number
    rotation: number
    [k: string]: unknown
  }>,
): Promise<void> => {
  const ws = activeWorkspace.value
  const item = activeWorkspaceItem.value
  if (!ws || !item) return
  await designHandlers.resizeElement(ws.id, item.id, elementId, patch)
}

const handleDesignDeleteElement = async (elementId: string): Promise<void> => {
  const ws = activeWorkspace.value
  const item = activeWorkspaceItem.value
  if (!ws || !item) return
  await designHandlers.deleteElement(ws.id, item.id, elementId)
}

/**
 * NEW (regression fix, 2026-08-14, "design mode, add element manual
 * not working"). `<DesignView>` fires this with the body returned by
 * the AddDesignElementDialog's `create` emit:
 *   { name: string; type: DesignElementApi['type']; html: string }
 *
 * Pre-fix: AppLayout's <DesignView> did NOT subscribe to
 * `@create-element`, so the emit went nowhere. The dialog closed
 * (the `@close` handler was wired) but no element was added — the
 * canvas appeared unchanged. The user reported this as "Add element
 * manual not working".
 *
 * Post-fix: routes through `useDesignHandlers.createElement` which
 * reads the active page id from `workspacesStore.activeDesignPageId`
 * (mirrored from DesignView's local `activePageId` ref), POSTs to
 * `/design/pages/:pageId/elements`, and mirrors the created element
 * into `item.design_elements[]` so the canvas re-renders without a
 * manual refresh. Errors surface as a notification toast.
 */
const handleDesignCreateElement = async (body: {
  name: string
  type: DesignElementApi['type']
  html: string
}): Promise<void> => {
  const ws = activeWorkspace.value
  const item = activeWorkspaceItem.value
  if (!ws || !item) return
  await designHandlers.createElement(ws.id, item.id, body)
}

// Right sidebar cwd - show when chat is open OR task is active
const rightSidebarCwd = computed(() => {
  if (activeTask.value && activeWorkspaceItem.value?.path) {
    return activeWorkspaceItem.value.path
  }
  if (navigationStore.activeChatId && navigationStore.activeChatId.startsWith('chat-')) {
    return chatSessionCwd.value || activeWorkspaceItem.value?.path || ''
  }
  return ''
})

// Effective cwd for the <ChatView> mount. The ChatView child seeds
// its `sessionCwd` ref from this prop in onMounted (`if (props.cwd)
// sessionCwd.value = props.cwd`), then sends it as `cwd_session` on
// every api.sendChatMessage call. Without this prop, ChatView falls
// back to `loadChatHistory`'s `data.cwd`, which is empty for any
// session whose `sessions.cwd` column is NULL — and `sessions.cwd`
// is only set on the FIRST saveMessage call, so a freshly-created
// session that the user opens and types into IMMEDIATELY sends
// `cwd_session: ""` to the backend.
//
// Sources (priority order, mirrors rightSidebarCwd above):
//   1. chatSessionCwd — populated by AppLayout.onMounted →
//      fetchChatSessionCwd for the `?view=chat&session=X` URL
//      path. Reads the session's persisted cwd from the DB.
//   2. activeWorkspaceItem.path — used for the workspace-item +
//      chat-task paths (the kanban chat branch, DesignChatDialog,
//      and the standard-task-chat branch added for task
//      task_1787027750097). The chat runs in the workspace item's
//      directory.
//   3. '' — empty fallback. Should not happen in practice because
//      either source above should be populated.
//
// FIX (task_1787027750097): previously the standalone ChatView
// branch (line 2099+) did NOT pass `:cwd` and ChatView relied
// entirely on loadChatHistory's data.cwd — which is empty when
// `sessions.cwd` is NULL (freshly-created sessions, or sessions
// created via non-Vue callers that bypass the cwd fallback chain).
// The user's bug report showed the network panel with
// `cwd_session: ""` because their session was opened from a
// `?view=workspace&itemId=X` URL where activeChatId was restored
// from localStorage; AppLayout's fetchChatSessionCwd was never
// called for that path (the route watcher at line 1720-1737 only
// fires for `view=chat&session=X`), so chatSessionCwd stayed
// empty and ChatView's loadChatHistory was the only source —
// which returned empty too. Adding this prop closes the gap.
const effectiveChatCwd = computed(() => {
  return chatSessionCwd.value || activeWorkspaceItem.value?.path || ''
})

// Route-change reconcile (Back/Forward/deep-link drift) — replaces the old
// path+query watcher; runs from the render pump below. Covers both
// path-only navigations (no query change) and query-only mutations
// (tests, legacy query URLs): query alone would miss /app/ws →
// /app/ws/chat/s hops, fullPath alone would miss direct query mutations.
const reconcileRoute = async () => {
  const query = route.query as Record<string, string | undefined>
  const sessionId = query.session as string
  const taskId = query.task as string
  const view = query.view as string
  const parsed = parseAppPath(route.path)

  // Path chat URL: adopt the chat when drifting (Back/Forward into
  // a chat from a board, or across chats). Mirrors the legacy
  // `?view=chat` branch below.
  const isOverlayView = view === 'gitfile' || view === 'skill' || view === 'code-editor'
  // Documents (Migration 095) are a PATH shape, so this watcher reads
  // them like any other branch below. It used to need an explicit
  // `?doc=` overlay guard here; that guard existed only because a
  // query-only change re-ran the path branch underneath it, and the
  // class of bug is gone with the query param.
  if (parsed.kind === 'chat') {
    // The path names the workspace too — adopt it, exactly as the
    // project branch below does. Without this, Back/Forward into a
    // chat left the previous workspace selected in the sidebar while
    // the URL named another one (task_1791556124905_10).
    if (workspacesStore.activeWorkspaceId !== parsed.workspaceId) {
      await workspacesStore.setActiveWorkspace(parsed.workspaceId)
    }
    if (activeChatId.value !== `chat-${parsed.sessionId}`) {
      workspacesStore.setActiveWorkspaceItem(null)
      navigationStore.setActiveChat(parsed.sessionId, navigationStore.activeChatName)
    }
    await fetchChatSessionCwd(parsed.sessionId)
    // An overlay on a chat path (readable editor link) still needs
    // its restore below — the path adoption above only rebuilds the
    // cwd context the restore reads from. Without an overlay in the
    // URL the previous chat's file must go, otherwise the global
    // session keeps rendering inside the new chat's center column.
    if (!isOverlayView) {
      clearAllOverlays()
      return
    }
  } else if (parsed.kind === 'project' || parsed.kind === 'projectChat') {
    // Path project URLs: adopt workspace + item, sync the task chat
    // suffix, drop any standalone chat. All writes are
    // equality-guarded: in-app navigations set the same values
    // before pushing, so this only ever acts on Back/Forward drift
    // (same contract as the legacy board branch below). Overlays
    // fall through to their restore below for the same reason as
    // the chat branch above.
    if (workspacesStore.activeWorkspaceId !== parsed.workspaceId) {
      await workspacesStore.setActiveWorkspace(parsed.workspaceId)
    }
    if (workspacesStore.activeWorkspaceItemId !== parsed.projectId) {
      workspacesStore.setActiveWorkspaceItem(parsed.projectId)
    }
    const wantTaskId = parsed.kind === 'projectChat' ? parsed.chatTaskId : null
    if ((workspacesStore.activeTaskId ?? null) !== wantTaskId) {
      workspacesStore.setActiveTask(wantTaskId)
    }
    if (navigationStore.activeChatId !== '') {
      navigationStore.clearActiveChat()
    }
    chatSessionCwd.value = ''
    if (!isOverlayView) {
      clearAllOverlays()
      return
    }
  } else if (parsed.kind === 'landing' && !view) {
    if (workspacesStore.activeWorkspaceItemId !== null) {
      workspacesStore.setActiveWorkspaceItem(null)
    }
    if (workspacesStore.activeTaskId !== null) {
      workspacesStore.setActiveTask(null)
    }
    if (navigationStore.activeChatId !== '') {
      navigationStore.clearActiveChat()
    }
    chatSessionCwd.value = ''
    clearAllOverlays()
    return
  } else if (parsed.kind === 'doc') {
    // A document is its own main view, so the chat / item / task
    // selections must clear — exactly as `landing` does above.
    //
    // This is NOT optional. <main> does NOT have a single v-if chain:
    // the standalone `v-if` on <DesignChatDialog> SPLITS it into two, so
    // <DocumentsView> (early, first chain) and the standalone
    // <ChatView v-else-if="activeChatId…"> (late, second chain) sit in
    // DIFFERENT chains — and independent chains are not mutually
    // exclusive. With `activeChatId` still set, clicking a document row
    // rendered the chat UNDERNEATH the document: composer dock and
    // transcript visible below it. A hard reload hid the bug only
    // because a fresh boot carries no chat state, so it reproduced from
    // a live chat session (the reported repro) and nowhere else.
    if (workspacesStore.activeWorkspaceItemId !== null) {
      workspacesStore.setActiveWorkspaceItem(null)
    }
    if (workspacesStore.activeTaskId !== null) {
      workspacesStore.setActiveTask(null)
    }
    if (navigationStore.activeChatId !== '') {
      navigationStore.clearActiveChat()
    }
    chatSessionCwd.value = ''
    clearAllOverlays()
    return
  }

  if (view === 'gitfile') {
    // Restore git file viewer state from URL
    const filePath = query.file as string
    const staged = query.staged === '1'

    if (filePath) {
      // Decode the file path
      try {
        const decodedPath = atob(filePath)
        gitViewerFile.value = {
          path: decodedPath,
          index_status: staged ? 'M' : ' ',
          worktree_status: staged ? ' ' : 'M',
        }
        gitViewerStaged.value = staged
      } catch {
        // Fallback if decoding fails
        gitViewerFile.value = {
          path: filePath,
          index_status: staged ? 'M' : ' ',
          worktree_status: staged ? ' ' : 'M',
        }
        gitViewerStaged.value = staged
      }
    }
  } else if (view === 'skill') {
    // Restore skill viewer state from URL
    const skillName = query.skill as string
    if (skillName) {
      skillViewerSkill.value = {
        name: skillName,
      }
    }
  } else if (view === 'code-editor') {
    // Restore code editor state from URL (reload, Back/Forward,
    // shared link). The session takes the plain `?file=` path as-is
    // and still decodes legacy base64 links, prefers the explicit
    // query cwd (legacy links) over the sidebar cwd, and skips the
    // fetch when the URL already matches the open session (open →
    // syncUrl → watcher echo costs one fetch). Every failure lands
    // in an explicit error state — never a silent blank.
    const fileParam = query.file as string | undefined
    const queryCwd = typeof query.cwd === 'string' ? query.cwd : ''
    if (fileParam) {
      void codeEditorSession.restoreFromUrl({
        fileParam,
        queryCwd,
        fallbackCwd: rightSidebarCwd.value,
        lineParam: query.line as string | undefined,
      })
    }
  } else {
    // No overlay in the URL: drop any open viewer. The full session
    // clear also resets loadedKey/cwd/loading, so a later deep link
    // with the same file still refetches instead of hitting the
    // restore echo guard.
    clearAllOverlays()

    if (view === 'chat' && sessionId) {
      if (activeChatId.value !== `chat-${sessionId}`) {
        // URL changed to a different chat — clear any leftover workspace
        // item active state from a previous view.
        workspacesStore.setActiveWorkspaceItem(null)
        navigationStore.setActiveChat(sessionId, navigationStore.activeChatName)
      }
      // Fetch cwd for folder explorer and git
      // Use localStorage cached value if available for immediate use
      const cachedCwd = localStorage.getItem(`session_cwd_${sessionId}`)
      if (cachedCwd) {
        chatSessionCwd.value = cachedCwd
      }
      await fetchChatSessionCwd(sessionId)
      // Cache the cwd for future use
      if (chatSessionCwd.value) {
        localStorage.setItem(`session_cwd_${sessionId}`, chatSessionCwd.value)
      }
    } else if (view === 'task' && taskId) {
      // Task is handled by workspacesStore.setActiveTask already called in onMounted
    } else if (!view || view === 'workspace') {
      // Clear chat session cwd when not in chat view. We
      // intentionally do NOT blindly clear activeWorkspaceItemId here:
      // Sidebar's handleSelectItem navigates to this exact URL
      // after setting the active workspace item (folder or
      // kanban).
      //
      // Back/Forward reconciliation (task_1789421136160_2): a bare
      // board URL must render the board. Browser Back from a
      // standalone chat changes ONLY the URL — no sidebar handler
      // runs — so activeWorkspaceItemId stayed null and activeChatId
      // stayed set, and ChatView kept winning on a board URL (board
      // URL + chat content, the reported anomaly). Adopt the URL's
      // item and drop any stale chat/task so the board renders.
      // Scoped to path '/app' (path routes like /app/settings own
      // their contracts) and to bare itemIds (a /chat/<taskId>
      // suffix means a task chat is open — the suffix watcher owns
      // that sync). All writes are equality-guarded and in-app
      // navigations set the same values before pushing, so this only
      // ever acts on Back/Forward/deep-link drift.
      if (route.path === '/app') {
        const parsed = parseItemIdWithChat((query.itemId as string | undefined) ?? '')
        if (!parsed.chatTaskId) {
          const wantItemId = parsed.itemId || null
          if (workspacesStore.activeWorkspaceItemId !== wantItemId) {
            workspacesStore.setActiveWorkspaceItem(wantItemId)
          }
          if (workspacesStore.activeTaskId !== null) {
            workspacesStore.setActiveTask(null)
          }
          if (navigationStore.activeChatId !== '') {
            navigationStore.clearActiveChat()
          }
        }
      }
      chatSessionCwd.value = ''
    }
  }
}

// Session-cwd localStorage cache (replaces the old chatSessionCwd watcher).
// Called from fetchChatSessionCwd after every assignment; clearing to ''
// needs no cache write (the old watcher only wrote truthy cwds).
const writeSessionCwdCache = (newCwd: string) => {
  if (newCwd && activeChatId.value) {
    const sessionId = activeChatId.value.replace(/^chat-/, '')
    localStorage.setItem(`session_cwd_${sessionId}`, newCwd)
  }
}

// Retry the editor restore when the cwd context arrives late. A cold
// boot of a project editor link restores before the workspace tree
// loads (no cwd yet, so an explicit 'No working directory' state);
// when the item adoption then flips rightSidebarCwd, this replays the
// same URL params instead of stranding the error. Only fires for that
// exact error — successful loads and read failures are left alone.
const retryEditorRestore = () => {
  const cwd = rightSidebarCwd.value
  if (!cwd) return
  const q = route.query as Record<string, string | undefined>
  if (q.view !== 'code-editor' || !q.file) return
  if (codeEditorSession.error.value !== 'No working directory') return
  void codeEditorSession.restoreFromUrl({
    fileParam: q.file,
    queryCwd: typeof q.cwd === 'string' ? q.cwd : '',
    fallbackCwd: cwd,
    lineParam: q.line,
  })
}

// Expose the design chat open handler so tests can simulate the
// user clicking the 💬 button in DesignView (which emits `openChat`).
// In production, this is reached via the DesignView emit chain —
// tests don't render DesignView because they stub it. Cheap seam.
//
// 2026-08-14: also expose `handleDesignCreateElement` for the same
// reason — the integration test for the "+ Element" dialog →
// addDesignElement wire invokes the handler directly because tests
// stub the DesignView child. Keeping the seam tiny: just one more
// named export.
// ─── Tab mode ─────────────────────────────────────────────────────────────────
//
// Tabs are a view over the URL: the `currentView` chain above still decides
// what renders, and activating a tab is just a navigation. Only two pieces
// are needed here — push the active tab's target into the URL, and turn
// every URL change into tab state (create / focus / normalise).
//
// `replace`, never `push`: Back must keep meaning "go back inside the active
// tab" rather than becoming a tab switcher. A normal navigation still uses
// `push`, so history stays about navigation, not about tab switches.

/**
 * The store side of a navigation.
 *
 * The render chain reads the STORES (`workspacesStore.activeWorkspaceItem`,
 * `navigationStore.activeChatId`) — not the URL — so a navigation that only
 * rewrote the URL left the previous view on screen. A sidebar click set both
 * (WorkspaceItem → Sidebar.handleSelectItem → emit), which is why this only
 * showed up once tabs could be activated directly: switching between two
 * workspace tabs kept rendering the same item.
 */
function mirrorTargetIntoStores(path: string, query: Record<string, string>, chatName?: string) {
  if (path !== '/app') return
  const view = query.view ?? 'chat'

  if (view === 'workspace') {
    const parsed = parseItemIdWithChat(query.itemId ?? '')
    navigationStore.clearAll()
    workspacesStore.setActiveTask(parsed.chatTaskId)
    workspacesStore.setActiveWorkspaceItem(parsed.itemId || null)
    if (query.pageId) workspacesStore.setActiveDesignPage(query.pageId)
    return
  }

  // A chat (with or without a session) wins over any workspace item — the same
  // sequence the sidebar's chat path performs.
  workspacesStore.setActiveTask(null)
  workspacesStore.setActiveWorkspaceItem(null)
  if (query.session) navigationStore.setActiveChat(query.session, chatName ?? '')
  else navigationStore.clearAll()
}

/** Navigate to the active tab's target. Called by the strip after it acts. */
function applyActiveTabToUrl() {
  const tab = tabsStore.activeTab
  if (!tab) return
  mirrorTargetIntoStores(tab.path, tab.query, tab.title)
  const query = withTabParam(tab.query, tab.id)
  if (route.path === tab.path && sameRouteQuery(route.query, query)) return
  router.replace({ path: tab.path, query })
}

/**
 * The funnel. Every navigation in the app lands here — sidebar clicks, the
 * chats list, kanban/design chat dialogs, deep links, the Back button — so
 * no call site has to know the tab strip exists, and a view type added
 * later becomes tabbable for free.
 *
 * Gated on mount so it runs AFTER the restore block above: the deep link is
 * resolved by the existing code first, then normalised with its `tab=` name.
 */
function syncFromRoute() {
  // The item's type decides whether a task chat belongs to the item's tab
  // (kanban/design open it as a dialog inside that view) or gets its own.
  // Only trust it when it describes the item this URL points at — on a cold
  // boot the tree may not be loaded yet, and the store adopts the tab later.
  const active = workspacesStore.activeWorkspaceItem
  const urlItemId = parseItemIdWithChat((route.query.itemId as string) ?? '').itemId
  const itemType = active && active.id === urlItemId ? (active.item_type ?? null) : null
  const result = tabsStore.syncFromTarget(route.path, { ...route.query }, itemType)
  if (result.changed) router.replace({ path: result.path, query: result.query })
}

let tabsFunnelReady = false

// Registered AFTER the restore block above, and Vue fires `onMounted` hooks
// in registration order — so a cold boot is already resolved by the time
// this runs, and it stays synchronous so it cannot shift mount timing.
onMounted(() => {
  tabsFunnelReady = true
  syncFromRoute()
})

/** Shortcuts and the live title feed are window-scoped wiring, so they live
 * here and are torn down with the layout. Every handler re-applies the URL
 * through `applyActiveTabToUrl`, so the shortcut map can never leave the
 * URL pointing at a tab the user is no longer on. */
const stopTabShortcuts = useTabShortcuts({
  isEnabled: () => tabsStore.enabled,
  tabCount: () => tabsStore.tabCount,
  handlers: {
    newTab: () => {
      tabsStore.openHomeTab()
      applyActiveTabToUrl()
    },
    closeTab: () => {
      tabsStore.close(tabsStore.activeTabId)
      applyActiveTabToUrl()
    },
    reopenTab: () => {
      tabsStore.reopenLastClosed()
      applyActiveTabToUrl()
    },
    nextTab: () => {
      tabsStore.next()
      applyActiveTabToUrl()
    },
    previousTab: () => {
      tabsStore.prev()
      applyActiveTabToUrl()
    },
    selectTab: (index: number) => {
      tabsStore.activateIndex(index - 1)
      applyActiveTabToUrl()
    },
  },
})

// The tab title feed is owned by App.vue (it installs the SSE bus), so nothing
// to unregister here — only the shortcuts, which live in this component.
onUnmounted(() => {
  stopTabShortcuts()
})

// ─── Subscription pumps (replace every watcher removed above) ────────────
// Two explicit mechanisms, no reactive watchers:
//
// 1. Store pump — `workspacesStore.$subscribe` fires synchronously on
//    every store mutation (same trigger set as the old watchers, with no
//    render dependency, so Sidebar/DesignView-initiated changes are seen):
//      - first truthy workspace id → initSseStores (one-shot guard inside)
//      - item/page id change → syncItemToUrl mirror (with previous id)
//      - item change → maybeLoadAgentData (agent branch)
//      - activeTaskId falsy → clear the design-chat refs (dialog unmount)
//      - workspaces populated while a URL restore is pending → restoreUrlState
//      - rightSidebarCwd change → retryEditorRestore
// 2. Render pump — `onUpdated` with prev-value refs replays the old route
//    watchers. Any route mutation re-renders (route is read by computeds
//    and the template), so Back/Forward/deep-link drift reconciles with
//    the same equality guards the watchers had (no mirror loops).
let prevPumpItemId: string | null = workspacesStore.activeWorkspaceItemId
let prevPumpPageId: string | null | undefined = workspacesStore.activeDesignPageId
let prevPumpCwd = rightSidebarCwd.value ?? ''
let prevPumpChatId = navigationStore.activeChatId
navigationStore.$subscribe(() => {
  const nextChatId = navigationStore.activeChatId
  if (nextChatId !== prevPumpChatId) {
    prevPumpChatId = nextChatId
    // Chat session switched (Sidebar, ChatsList, or handleNavigate all
    // funnel through setActiveChat). The new chat URL carries no overlay
    // query, so drop the previous chat's file synchronously — otherwise
    // the remounted ChatView (keyed on activeChatId) flashes the old file
    // for a frame before reconcileRoute clears on the next pump. When the
    // destination URL does carry an overlay (deep link, Back/Forward),
    // reconcileRoute's restore below re-opens it right after.
    clearAllOverlays()
  }
})
workspacesStore.$subscribe(() => {
  const wsId = activeWorkspaceId.value
  if (wsId) void initSseStores(wsId)
  const itemId = workspacesStore.activeWorkspaceItemId
  const pageId = workspacesStore.activeDesignPageId
  if (itemId !== prevPumpItemId || pageId !== prevPumpPageId) {
    const oldId = prevPumpItemId
    prevPumpItemId = itemId
    prevPumpPageId = pageId
    syncItemToUrl(oldId)
    maybeLoadAgentData()
  }
  if (!workspacesStore.activeTaskId) {
    if (activeDesignChatTaskId.value !== '' || activeDesignChatPageName.value !== '') {
      activeDesignChatTaskId.value = ''
      activeDesignChatPageName.value = ''
    }
  }
  if (pendingUrlRestore.value) void restoreUrlState()
  const cwd = rightSidebarCwd.value ?? ''
  if (cwd !== prevPumpCwd) {
    prevPumpCwd = cwd
    retryEditorRestore()
  }
})

let prevRoutePath: string | null = null
let prevRouteQuery: unknown = null
let prevFunnelFullPath: string | null = null
// Router-absent unit mounts: `route` may be undefined — optional chaining
// keeps the pump idle instead of throwing (same guard the old watchers
// carried via their try/catch sources).
if (route) {
  prevRoutePath = route.path
  prevRouteQuery = route.query
  prevFunnelFullPath = route.fullPath
}
onUpdated(() => {
  if (!route) return
  const path = route.path
  const query = route.query
  const full = route.fullPath
  if (path !== prevRoutePath || query !== prevRouteQuery) {
    prevRoutePath = path
    prevRouteQuery = query
    prevFunnelFullPath = full
    syncTaskFromItemId()
    void reconcileRoute()
  }
  if (full !== prevFunnelFullPath) {
    prevFunnelFullPath = full
    if (tabsFunnelReady) syncFromRoute()
  }
})

// Mount arms (replace the old `{ immediate: true }` watchers):
//   - initSseStores: no-op until the workspace id is truthy; the store
//     pump retries on every later mutation.
//   - restoreUrlState: covers fixtures seeded before mount; the store pump
//     covers the async initializeFromSystemFolder path.
//   - maybeLoadAgentData: covers landing directly on an agent item.
onMounted(() => {
  void initSseStores(activeWorkspaceId.value)
  void restoreUrlState()
  maybeLoadAgentData()
})

defineExpose({
  handleDesignOpenChat,
  handleDesignCreateElement,
  applyActiveTabToUrl,
  mirrorTargetIntoStores,
  syncFromRoute,
  handleUpdateChatId,
})
</script>

<template>
  <div class="flex h-screen" style="background-color: var(--semantic-content-bg)">
    <Sidebar
      ref="sidebarRef"
      @navigate="handleNavigate"
      @select-workspace="handleSelectWorkspace"
      :collapsed="sidebarCollapsed"
      :width="sidebarWidth"
      @toggle-collapse="toggleSidebar"
      @resize="handleSidebarResize"
    />
    <main class="flex-1 flex flex-col overflow-hidden relative">
      <!-- Git File Viewer (shown when view is gitfile) -->
      <GitFileViewer
        v-if="currentView === 'gitfile' && gitViewerFile && rightSidebarCwd"
        class="absolute inset-0"
        style="z-index: 10"
        :cwd="rightSidebarCwd"
        :file-path="gitViewerFile.path"
        :file-name="gitViewerFile.path.split('/').pop() || gitViewerFile.path"
        :staged="gitViewerStaged"
        @close="closeGitViewer"
        @submit-review="handleSubmitReview"
        @comment-saved="handleCommentSaved"
      />

      <!-- Skill Detail Viewer (shown when view is skill) -->
      <div
        v-if="currentView === 'skill' && skillViewerSkill"
        class="flex-1 flex flex-col overflow-hidden absolute inset-0"
        style="background-color: var(--semantic-content-bg); z-index: 10"
      >
        <!-- Header -->
        <div
          class="h-14 flex items-center justify-between px-4 shrink-0"
          style="border-bottom: 1px solid var(--color-border)"
        >
          <div class="flex items-center gap-3">
            <button
              @click="closeSkillViewer"
              class="p-2 rounded-lg hover:opacity-70 transition-opacity"
              title="Back"
            >
              <svg
                class="w-5 h-5"
                style="color: var(--semantic-text)"
                fill="none"
                viewBox="0 0 24 24"
                stroke="currentColor"
              >
                <path
                  stroke-linecap="round"
                  stroke-linejoin="round"
                  stroke-width="2"
                  d="M15 19l-7-7 7-7"
                />
              </svg>
            </button>
            <h2 class="text-lead font-semibold" style="color: var(--semantic-text)">
              <UiIcon name="brain" class="w-4 h-4" /> {{ skillViewerSkill?.name }}
            </h2>
          </div>
        </div>
        <!-- Skill Detail Content -->
        <div class="flex-1 overflow-hidden">
          <SkillDetail
            :skill-name="skillViewerSkill?.name"
            @skill-deleted="closeSkillViewer"
            @error="(msg) => console.error('Skill error:', msg)"
          />
        </div>
      </div>

      <!-- Code viewer — full-surface FALLBACK. `currentView` only resolves
           to 'code-editor' when no ChatView is on screen (see
           `chatSurfaceActive`), because inside a chat the viewer renders
           in ChatView's center column so the chat-owned right sidebar
           (Explorer / Files changed / Terminal) stays visible. Same
           `CodeViewerStage` component, so both surfaces are identical. -->
      <div
        v-if="currentView === 'code-editor' && codeEditorFile"
        class="flex-1 flex flex-col overflow-hidden absolute inset-0"
        style="background-color: var(--semantic-content-bg); z-index: 10"
        data-testid="code-viewer-overlay"
      >
        <CodeViewerStage
          :file="codeEditorFile"
          :content="codeEditorContent"
          :loading="codeEditorLoading"
          :error="codeEditorError"
          :cwd="rightSidebarCwd"
          :line="codeEditorRequestedLine"
          @close="closeCodeEditor"
        />
      </div>

      <!-- Document page (Migration 095). FIRST branch of the main view
           chain, so it REPLACES whatever was open — the chat is unmounted
           rather than left mounted underneath.

           This is why it is a `v-else-if` here and not a standalone
           `v-if` overlay: as an overlay it inherited the path it was
           opened from, and the chat's floating chrome (z-20/30/31)
           out-painted its z-index: 10, so the composer dock and scroll
           slider floated over the document. Being a page removes the
           overlap by construction instead of relying on a z-index
           ordering. The GitFileViewer / SkillViewer / code-editor
           overlays above are still overlays and still need the chat's
           own stacking containment (`isolation: isolate` on
           `.chat-column`).

           `:key` forces a fresh mount when the user moves between two
           documents (Back/Forward keeps the same component mounted, and
           DocumentsView loads on id change anyway — the key just makes
           the switch unambiguous). The id comes from the PATH, so a
           refresh or a shared link restores the same document. -->
      <DocumentsView
        v-else-if="currentView === 'documents' && activeDocumentId"
        :key="'doc-' + activeDocumentId"
        :document-id="activeDocumentId"
      />
      <!-- Kanban settings page (plan: 2026-09-02-kanban-settings-as-page).
           Mounted INSIDE the <main> v-else-if chain (BEFORE KanbanView)
           so the settings page REPLACES the kanban board — no overlay.
           The :key forces a fresh mount when the user navigates from
           one kanban's settings to another's (the page re-reads
           route.params.itemId on mount). -->
      <KanbanSettingsView
        v-else-if="currentView === 'kanban-settings'"
        :key="'kanban-settings-' + (route.params.itemId as string)"
        @add-column="handleKanbanSettingsAddColumn"
        @edit-column="handleKanbanSettingsEditColumn"
        @delete-column="handleKanbanSettingsDeleteColumn"
        @rename-item="handleKanbanRenameItem"
        @copy-spec="handleOpenCopyKanbanSpec"
      />
      <!-- Kanban task chat (inline view, own tab). When a chat task that
           belongs to THIS kanban item is active, the chat is the main
           surface. It MUST be a v-else-if in this chain and placed BEFORE
           the KanbanView branch below — the KanbanView branch only tests
           `item_type === 'kanban'`, so it would otherwise win the chain and
           the chat would never render; and a standalone v-if here would
           start a NEW chain and stack board + chat.

           The chat tab (URL `itemId=I/chat/<taskId>`) and the board tab
           (bare `itemId=I`) carry different tab keys, so this one branch
           gives each tab its own body with no extra state. `:key` forces a
           fresh mount per task, preserving useChatScrollRestore's
           per-session scroll contract when the user switches cards.
           `:show-header` renders the shared ChatAppBar (title + ◫ + ✕) so
           the chat stays closable with tab mode off; the ✕ routes through
           handleCloseTaskView, which closes the tab when one owns the chat.
           The other two task-chat modes (AgentChatView below,
           StandardTaskChatView further down) set the same flag, so all
           three render the identical bar. -->
      <ChatView
        v-else-if="
          activeWorkspaceItem &&
          activeWorkspaceItem.item_type === 'kanban' &&
          activeTask &&
          activeTaskWorkspaceItemId === activeWorkspaceItem.id
        "
        :key="'kanban-chat-' + activeTask.id"
        :chat-id="activeTask.id"
        :chat-name="activeTask.name ?? ''"
        :type="'task'"
        :cwd="effectiveChatCwd"
        :show-header="true"
        @update-chat-id="handleUpdateChatId"
        @close="handleCloseTaskView"
      />
      <!-- Kanban view (kanban-embed-chatview plan, Task 5). The kanban
           now owns the chat pane + resize handle internally — the old
           3-column sibling-of-KanbanView branch (was at lines
           1716-1814) is GONE. KanbanView renders the full-width board
           when no task is active (the kanban chat branch above claims the
           task-active case). The :key on
           KanbanView forces a fresh mount when the user navigates
           from one kanban to another (KanbanView fetches columns on
           mount). `@close-chat` fires when ChatView's close button is
           clicked — AppLayout handles URL routing + state cleanup. -->
      <KanbanView
        v-else-if="activeWorkspaceItem && activeWorkspaceItem.item_type === 'kanban'"
        :key="'kanban-' + activeWorkspaceItem.id"
        :item="activeWorkspaceItem"
        :workspace-id="activeWorkspace?.id ?? ''"
        :item-id="activeWorkspaceItem.id"
        @move-task="handleKanbanMoveTask"
        @add-column="handleKanbanAddColumn"
        @rename-column="handleKanbanRenameColumn"
        @delete-column="handleKanbanDeleteColumn"
        @reorder-column="handleKanbanReorderColumn"
        @request-rename-column="handleKanbanRequestRenameColumn"
        @request-delete-column="handleKanbanRequestDeleteColumn"
        @select-task="handleKanbanSelectTask"
        @open-task-in-background="handleKanbanOpenTaskInBackground"
        @open-task-detail-in-background="handleKanbanOpenTaskDetailInBackground"
        @delete-task="handleKanbanDeleteTask"
        @rename-task="handleKanbanRenameTask"
        @pin-task="handleKanbanPinTask"
        @open-settings="handleOpenKanbanSettings"
        @rename-item="handleKanbanRenameItem"
        @close-chat="handleCloseTaskView"
      />
      <!--
        Design chat dialog (plan: 2026-08-06-design-chat-as-dialog).
        Same Teleport pattern as the kanban task chat used to have, and
        the same v-model:show binding driven by `activeDesignChatTaskId`.
        This `v-if` (not `v-else-if`) starts its own chain — that is
        deliberate and pre-existing: DesignView's `v-else-if` below
        attaches to THIS element, not to the kanban chain above.
        Mounted at the AppLayout level (NOT inside DesignView) so the
        chat opens as a centred modal overlay rather than a side-by-
        side column. Gated on `item_type === 'design'` so the dialog
        only opens for design items — kanban / folder / standalone
        chat use their own mounts. The pre-fix design+chat 3-column
        branch (data-design-three-column) was removed; the dialog
        reclaims the full canvas width. URL routing is handled by
        AppLayout's existing handleCloseTaskView (re-used via @close).
      -->
      <DesignChatDialog
        v-if="
          activeWorkspaceItem &&
          activeWorkspaceItem.item_type === 'design' &&
          activeDesignChatTaskId
        "
        v-model:show="designChatDialogOpen"
        :task="activeDesignChatTask"
        :workspace-id="activeWorkspace?.id ?? ''"
        :item-id="activeWorkspaceItem.id"
        :page-name="activeDesignChatPageName"
        :project-name="activeWorkspace?.name ?? ''"
        :cwd="activeWorkspaceItem.path ?? ''"
        @close="handleCloseTaskView"
      />
      <!--
        SIMPLIFY-URL-BROWSER (2026-08-15): the legacy
        `<ChatView v-else-if="currentView === 'task' && activeTask">`
        branch has been removed. Under the new URL scheme the URL
        never says `view=task` — the chat is always a
        sub-state of the workspace view. Kanban tasks open via the
        inline <ChatView> branch (gated on
        `activeTaskWorkspaceItemId === activeWorkspaceItem.id`),
        design tasks via DesignChatDialog (gated on
        `activeDesignChatTaskId`), and standard task chats
        (folder / memory / chat items) via the inline <ChatView>
        branch below. The pre-fix "out-of-scope" gap for non-
        kanban / non-design items is closed by that branch.
        (2026-09-14: the kanban branch is no longer a modal — see the
        comment on the kanban chat branch itself.)
      -->
      <!--
        STALE MOUNT removed (kanban-chat-as-dialog plan, 2026-08-06).
        This <KanbanView> mount was a v-else-if continuation of the
        chain that started with the kanban chat dialog's v-if.
        Vue evaluates v-if / v-else-if / v-else within one chain,
        but that dialog's `v-if` (not `v-else-if`) started a
        NEW chain — so this mount and the correct mount at line 1655
        (also a v-else-if but in a different outer chain) both fired
        when activeWorkspaceItem.item_type === 'kanban' and no chat
        task was active. Result: the kanban board rendered TWICE,
        stacked vertically (visible in the user's screenshot 2026-08-06).
        The correct mount is the one at line 1655 above; this stale
        copy was a leftover from before the kanban-embed-chatview plan
        unified AppLayout's main-content chain.
      -->
      <!-- Design view (Chunk 8 of design-mode-redesign). Mirrors the
           single-column kanban branch above: full-bleed render when
           a design workspace item is active and no chat is open.
           The :key forces a fresh mount on item switch so the page
           list re-fetches. DesignView emits page/element mutations
           which we forward to the workspaces store (or api layer
           directly for page create — no store action yet).

           2026-08-06 (plan: design-chat-as-dialog): the design chat
           no longer shares this branch with a side-by-side chat
           column. The previous 3-column [DesignView | resize-handle |
           ChatView] layout (added in commit d0a05eb0, 2026-07-14)
           took ~40-65% of the canvas for ChatView even when
           "minimised". The chat is now a centred modal dialog
           (DesignChatDialog) mounted at the AppLayout level above —
           the canvas stays full-width behind a dimmed+blurred
           backdrop. The pre-fix data-design-three-column branch,
           data-design-resize-handle, design-chat-collapse-button,
           and design-chat-expand-button are GONE with the resize /
           collapse state machine. -->
      <DesignView
        v-else-if="activeWorkspaceItem && activeWorkspaceItem.item_type === 'design'"
        :key="'design-' + activeWorkspaceItem.id"
        :item="activeWorkspaceItem"
        :workspace-id="activeWorkspace?.id ?? ''"
        :item-id="activeWorkspaceItem.id"
        @select-page="handleDesignSelectPage"
        @select-element="handleDesignSelectElement"
        @create-element="handleDesignCreateElement"
        @update-element="handleDesignUpdateElement"
        @translate-element="handleDesignTranslateElement"
        @resize-element="handleDesignResizeElement"
        @delete-element="handleDesignDeleteElement"
        @open-chat="handleDesignOpenChat"
      />
      <!-- Agent chat (inline, non-dialog): when a chat task is open
           under an agent item, the chat REPLACES the AgentView config
           below (same swap semantics as StandardTaskChatView for
           folder tasks). MUST be v-else-if in this chain and placed
           BEFORE AgentView — a standalone v-if would start a new
           chain and render BOTH stacked (config on top, chat
           squeezed at the bottom). Closing the chat (@close →
           handleCloseTaskView clears activeTask) falls back to
           AgentView. AgentChatView no longer hand-rolls a header — it
           forwards `:show-header` + `@close` to its inner ChatView, so
           agent mode renders the same shared ChatAppBar as the kanban
           and standard branches. -->
      <AgentChatView
        v-else-if="
          activeWorkspaceItem &&
          activeWorkspaceItem.item_type === 'agent' &&
          activeTask &&
          activeTaskWorkspaceItemId === activeWorkspaceItem.id
        "
        :key="'agent-chat-' + activeTask.id"
        :task="activeTask"
        :workspace-id="activeWorkspace?.id ?? ''"
        :item-id="activeWorkspaceItem.id"
        :cwd="activeWorkspaceItem.path ?? ''"
        @close="handleCloseTaskView"
      />
      <!-- Agent Mode (plan 2026-08-15-agent-mode, task_1786962724740_0):
           4th workspace-item type. Mounted when item_type='agent'
           and NO chat task is open (the AgentChatView branch above
           wins when a task is active). The view is responsible for
           fetching its own agent data (knowledge + tools) via
           /api/workspaces/:wsId/items/:itemId/agent.
           IMPORTANT: this v-else-if must come BEFORE the new
           standard-task ChatView below (origin/main's blank-chatview
           fix) so 'agent' items render AgentView, not a plain
           ChatView. The new ChatView's v-else-if condition
           (`item_type !== 'kanban' && !== 'design'`) WOULD match
           'agent' items, so order matters. -->
      <AgentView
        v-else-if="activeWorkspaceItem && activeWorkspaceItem.item_type === 'agent'"
        :key="'agent-' + activeWorkspaceItem.id"
        :item="activeWorkspaceItem"
        :workspace-id="activeWorkspace?.id ?? ''"
        :item-id="activeWorkspaceItem.id"
        :knowledge="agentKnowledge"
        :tools="agentTools"
        :system-prompts="agentSystemPrompts"
        :parent-loading="agentDataLoading"
        @add-knowledge="handleAgentAddKnowledge"
        @remove-knowledge="handleAgentRemoveKnowledge"
        @edit-knowledge="handleAgentEditKnowledge"
        @toggle-tool="handleAgentToggleTool"
        @toggle-tools-bulk="(names, enabled) => handleAgentToggleToolsBulk(names, enabled)"
        @add-system-prompt="handleAgentAddSystemPrompt"
        @edit-system-prompt="handleAgentEditSystemPrompt"
        @remove-system-prompt="handleAgentRemoveSystemPrompt"
      />
      <!-- Workspace routines (Migration 084, plan
           2026-09-10-workspace-items-routines): mounted when
           item_type='routine'. The view fetches its own data via
           GET /api/workspaces/:ws/items/:item/routine. Placed after
           AgentView — same v-else-if chain position semantics (only
           one branch renders). -->
      <RoutineView
        v-else-if="activeWorkspaceItem && activeWorkspaceItem.item_type === 'routine'"
        :key="'routine-' + activeWorkspaceItem.id"
        :item="activeWorkspaceItem"
        :workspace-id="activeWorkspace?.id ?? ''"
        :item-id="activeWorkspaceItem.id"
      />
      <!--
        AgentKnowledgeDialog — mounted at the AppLayout level so the
        AgentView's `+ Add` button emits up to open this dialog. Uses
        the same v-model:show pattern as the knowledge dialogs below.
        Gated on `item_type === 'agent'` so the dialog only opens
        while an agent item is active. The agent id == workspace item
        id per Migration 076 (agents.id is the workspace_item_id).
      -->
      <AgentKnowledgeDialog
        v-if="activeWorkspaceItem && activeWorkspaceItem.item_type === 'agent'"
        v-model:show="agentKnowledgeDialogOpen"
        :busy="agentKnowledgeBusy"
        :error="agentKnowledgeError"
        @close="closeAgentKnowledgeDialog"
        @create="handleAgentKnowledgeCreate"
      />
      <!--
        AgentKnowledgeDetailDialog — edit mode for an existing knowledge
        row (plan 2026-08-22-agent-mode-ui-ux, A2). Opened by AgentView's
        per-row ✎ button via the `edit-knowledge` emit. Same v-model:show
        + busy/error pattern as the add dialog above.
      -->
      <AgentKnowledgeDetailDialog
        v-if="activeWorkspaceItem && activeWorkspaceItem.item_type === 'agent'"
        :show="agentKnowledgeDetailOpen"
        :row="agentKnowledgeDetailRow"
        :busy="agentKnowledgeDetailBusy"
        :error="agentKnowledgeDetailError"
        @close="closeAgentKnowledgeDetailDialog"
        @save="handleAgentKnowledgeSave"
      />
      <!--
        Agent System Prompt dialog (Migration 080) — one dialog serves
        add (row=null) and edit (row set). Same show/busy/error pattern
        as the knowledge dialogs above.
      -->
      <AgentSystemPromptDialog
        v-if="activeWorkspaceItem && activeWorkspaceItem.item_type === 'agent'"
        :show="agentSystemPromptDialogOpen"
        :row="agentSystemPromptRow"
        :busy="agentSystemPromptBusy"
        :error="agentSystemPromptError"
        @close="closeAgentSystemPromptDialog"
        @create="handleAgentSystemPromptCreate"
        @save="handleAgentSystemPromptSave"
      />
      <!--
        Standard task chat (folder / memory / chat items — anything
        that isn't a kanban, design, OR agent). FIX for blank
        chatview (task_1787027750097, 2026-08-14): the
        simplify-url-browser plan (#246) wired the kanban chat
        and design (DesignChatDialog) chat-open
        paths but listed "folder tasks … out-of-scope edge case".
        A user with a chat task on a folder / memory / chat
        workspace item hit a dead zone: setActiveTask fires,
        clears activeChatId, and NONE of the v-else-if branches
        above matched — right pane was blank.

        Render <StandardTaskChatView> with the active task —
        encapsulates the chat-id / chat-name / :key wiring (see
        StandardTaskChatView.vue). The wrapper passes the task id
        as the chat session id (migration 052 invariant: task.id
        == session.id) and forwards :cwd so sendChatMessage writes
        the right cwd_session. We pass props explicitly rather
        than going through navigationStore so this branch doesn't
        fight the activeTask state the kanban + design branches
        depend on.

        `@close` routes ChatView's app-bar ✕ through
        handleCloseTaskView, the same handler the kanban and agent
        branches use. With `:show-header` set on the wrapper, this mode
        renders the same shared ChatAppBar as the other two, so the
        title / ◫ / ✕ sit in the same place in all three.

        Mount order matters: this v-else-if is AFTER AgentView
        (above), so 'agent' items render AgentView not ChatView.
        It precedes the standalone `<ChatView v-else-if=
        "activeChatId.startsWith('chat-')">` branch below, so a
        folder task lands here even when activeChatId is empty
        (cleared by setActiveTask).
      -->
      <StandardTaskChatView
        v-else-if="
          activeWorkspaceItem &&
          activeWorkspaceItem.item_type !== 'kanban' &&
          activeWorkspaceItem.item_type !== 'design' &&
          activeWorkspaceItem.item_type !== 'agent' &&
          activeTask
        "
        :task="activeTask"
        :cwd="effectiveChatCwd"
        @update-chat-id="handleUpdateChatId"
        @close="handleCloseTaskView"
      />
      <!-- Standalone chat (sidebar-opened `chat-<id>` sessions, no task).
           Renders the same shared ChatAppBar as the kanban / agent /
           standard branches above, so the title / ◫ / ✕ sit in the
           same place in every mode. `@close` reuses handleCloseTaskView,
           which clears both the task and the chat. -->
      <ChatView
        v-else-if="activeChatId.startsWith('chat-')"
        :key="activeChatId"
        :chat-id="activeChatId"
        :chat-name="activeChatName"
        :cwd="effectiveChatCwd"
        :show-header="true"
        @update-chat-id="handleUpdateChatId"
        @close="handleCloseTaskView"
      />
      <Chats v-else-if="currentView === 'chat'" />
      <!--
        Workspace folder preview — the "no item selected, pick one"
        empty-state. Only renders when the user has navigated to
        `?view=workspace` AND has no active workspace item. If an
        item is active (kanban / design / folder with memories /
        etc.), the dedicated branch above handles rendering; we
        MUST NOT also render the preview or the user sees the
        workspace name duplicated below the dedicated view
        (regression confirmed by the user's screenshot on
        2026-08-06 after the kanban-chat-as-dialog plan removed a
        stale secondary <KanbanView> mount that was previously
        acting as an implicit guard).

        The `!activeWorkspaceItem` guard ensures mutual exclusivity
        with the dedicated branches above. Without it, the chain
        would still resolve to this branch when currentView is
        'workspace' even if a kanban/design is active, because
        the kanban + dialog + chat-view mounts live in different
        v-if chains (they were refactored to mount in their own
        chains during the kanban-embed-chatview plan).
      -->
      <div
        v-if="currentView === 'workspace' && !activeWorkspaceItem"
        class="flex-1 flex flex-col"
        data-testid="workspace-folder-preview"
      >
        <!--
          The three inner branches (memories view / no-path
          centered card / workspaces picker) only ever need to
          render when there IS no active workspace item — the
          outer v-if already guarantees that. The inner branches
          previously referenced `activeWorkspaceItem` defensively
          for type narrowing; we keep them as-is but rely on the
          outer guard so the inner conditions don't need to
          re-check. Vue's template type-checker can't infer the
          type from `v-if` short-circuit across nested v-if/v-else
          chains, so the inner conditions stay as they were. This
          is a no-op at runtime since `activeWorkspaceItem` is
          always null here.
        -->
      </div>
    </main>

    <!-- Settings page -->
    <SettingsView v-if="currentView === 'settings'" />

    <!-- Workspace settings page (/app/:workspaceId/settings). Mounted as a
         sibling of <main> like <SettingsView>, not inside the view chain:
         which settings SECTION is open is `?section=`, owned by the view. -->
    <WorkspaceSettingsView v-else-if="currentView === 'workspace-settings'" />

    <!-- Global error notification stack -->
    <NotificationContainer />

    <!-- Global SSE connection status pill. Renders nothing while the
         connection is healthy (state === 'open'); surfaces a small
         "Connecting…" / "Reconnecting…" / "Connection lost" pill in
         the top-right corner when the bus is in a degraded state.
         Fixed-positioned so it stays visible regardless of which
         view (chat / kanban / settings / workspace) is active.
         `pointer-events-none` keeps the pill visible WITHOUT
         capturing clicks — the pill overlaps the top-right of every
         view's chrome (in the kanban 3-column layout it sits on top
         of ChatView's ✕ close button; in design mode it sits on top
         of any future top-right toolbar). The pill is purely
         informational (no controls inside), so passing the click
         through is the right behavior. -->
    <div
      class="fixed top-3 right-3 z-50 pointer-events-none"
      data-testid="sse-status-badge-container"
    >
      <SseStatusBadge />
    </div>

    <!-- Kanban column editor: add / rename / delete a column on the
         currently-active kanban item. Mounted at the AppLayout root
         (not inside the KanbanView's scoped tree) so the modal's
         internal Teleport/animation lifecycle works cleanly even if
         the KanbanView branch unmounts mid-edit (e.g. the user
         clicks a task card and the view switches to ChatView while
         the modal is open). The modal's `show` prop is bound to
         showKanbanColumnEditor; mode/targetId/initialName are set
         by the request-add-column / request-rename-column /
         request-delete-column handlers. -->
    <KanbanColumnEditor
      :show="showKanbanColumnEditor"
      :mode="kanbanColumnEditorMode"
      :initial-name="kanbanColumnEditorInitialName"
      :initial-description="kanbanColumnEditorInitialDescription"
      @close="handleKanbanColumnEditorClose"
      @add="handleKanbanColumnEditorAdd"
      @rename="handleKanbanColumnEditorRename"
      @delete="handleKanbanColumnEditorDelete"
    />

    <!--
      CopyKanbanSpecDialog — source picker + Replace/Append radio for
      bulk-copying column spec from another kanban. Mounted as a SIBLING
      of <KanbanSettingsView> (not nested) so a user can stack them:
      Settings page under, picker over, both visible at once. The picker
      filters out the active kanban as a source (CopyKanbanSpecDialog's
      `availableSources` computed).
      Plan: docs/superpowers/plans/2026-07-04-copy-kanban-spec.md
        (Chunk 4, Task 4.3)
    -->
    <CopyKanbanSpecDialog
      :show="showCopyKanbanSpecDialog"
      :workspace-id="activeWorkspace?.id ?? ''"
      :target-item-id="activeWorkspaceItem?.id ?? ''"
      @close="handleCloseCopyKanbanSpec"
      @copy="handleCopyKanbanSpec"
    />
  </div>
</template>
