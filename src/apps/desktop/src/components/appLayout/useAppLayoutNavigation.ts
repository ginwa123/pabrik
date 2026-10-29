import type { ComputedRef, Ref } from 'vue'
import type { RouteLocationNormalizedLoaded, Router } from 'vue-router'
import { buildAppUrl, buildSettingsUrl, parseAppPath, type AppUrlLocation } from '../../helpers/appUrl'
import { parseItemIdWithChat } from '../../helpers/buildItemIdWithChat'
import { isWorkspaceAgentSection } from '../../helpers/configSource'
import { resolveWorkspaceId } from '../../helpers/workspaceScope'
import type { useNavigationStore } from '../../stores/navigation'
import type { useTabsStore } from '../../stores/tabs'
import type { useWorkspacesStore, WorkspaceItem } from '../../stores/workspaces'
import type { SidebarHandle } from './types'

type NavigationDeps = {
  router: Router
  route: RouteLocationNormalizedLoaded
  workspacesStore: ReturnType<typeof useWorkspacesStore>
  navigationStore: ReturnType<typeof useNavigationStore>
  tabsStore: ReturnType<typeof useTabsStore>
  sidebarRef: Ref<SidebarHandle | null>
  chatSessionCwd: Ref<string>
  activeChatId: ComputedRef<string>
  activeWorkspaceItem: ComputedRef<WorkspaceItem | undefined>
  activeWorkspaceId: ComputedRef<string>
  chatTarget: (sessionId: string) => AppUrlLocation
  clearAllOverlays: () => void
  fetchChatSessionCwd: (sessionId: string) => Promise<void>
  applyActiveTabToUrl: () => void
}

export interface UseAppLayoutNavigationReturn {
  handleNavigate: (
    view: string,
    chatName?: string,
    taskId?: string,
    workspaceId?: string,
    itemId?: string,
    pageId?: string,
    sortsParam?: string,
  ) => void
  handleSelectWorkspace: (workspaceId: string) => void
  handleUpdateChatId: (oldId: string, newId: string) => void
  handleCloseTaskView: () => void
}

/** Sidebar-driven and chat-header-driven navigation: the URL is the single sink for all of it. */
export function useAppLayoutNavigation(deps: NavigationDeps): UseAppLayoutNavigationReturn {
  const { router, route, workspacesStore, navigationStore, tabsStore } = deps

  const handleUpdateChatId = (oldId: string, newId: string) => {
    if (deps.activeChatId.value === `chat-${oldId}`) {
      navigationStore.setActiveChat(newId)
    }
    // Keep the strip's pointer in step: a brand-new chat starts life with the synthetic
    // `session-<timestamp>` id and gets its real one on the first message, so a tab left keyed on the
    // old id would be dead — and the route funnel would add a second tab for the same chat.
    tabsStore.renameChatTab(oldId, newId)
    deps.sidebarRef.value?.updateChatId(oldId, newId)
    // Keep the browser URL truthful: a brand-new chat mounts at /app/{ws}/chat/<synthetic-id> and
    // gets its real id on the first message.
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
    // NEW (design-pages-in-workspace-tree plan, 2026-08-06): the 6th positional arg lets the caller
    // pin a specific design page when navigating to `view: 'workspace'`. Empty / undefined means "no
    // page pinned" (DesignView falls back to the first page in the cache).
    pageId?: string,
    // NEW (kanban default-URL, 2026-08-06): when the caller navigates to a kanban workspace item, the
    // Sidebar commits a default `?sorts=col_X:updated_at:desc,...` string here. We mirror it into the
    // URL so a refresh preserves the user's implicit sort choice.
    sortsParam?: string,
  ) => {
    if (view.startsWith('chat-')) {
      const chatSessionId = view.replace(/^chat-/, '')
      // Clear any workspace-item active state — navigating to a chat wins.
      workspacesStore.setActiveWorkspaceItem(null)
      navigationStore.setActiveChat(chatSessionId, chatName)
      // The new chat URL carries no overlay query, so drop the previous
      // chat's file synchronously (reconcileRoute also clears on the
      // next pump — this avoids a one-frame flash of the old file).
      deps.clearAllOverlays()
      // Fetch cwd for folder explorer and git
      deps.fetchChatSessionCwd(chatSessionId)
      router.push(deps.chatTarget(chatSessionId))
    } else if (view === 'chat') {
      // Clear any workspace-item active state — the URL is asserting "no chat selected, no workspace
      // item selected". Path-based: land on the workspace path (chat list scoped to it) when a
      // workspace is active, else the landing.
      workspacesStore.setActiveWorkspaceItem(null)
      navigationStore.clearActiveChat()
      deps.chatSessionCwd.value = ''
      if (workspacesStore.activeWorkspaceId) {
        router.push(buildAppUrl({ workspaceId: workspacesStore.activeWorkspaceId }))
      } else {
        router.push({ path: '/app', query: {} })
      }
    } else if (view === 'workspace') {
      navigationStore.clearAll()
      // Navigating to the board wins over any open task chat — clear the workspaces task so the
      // kanban/design/folder view renders instead of the chat. (navigationStore.clearAll only clears
      // the navigation store's task; the visible chat is gated on workspacesStore.activeTask.
      workspacesStore.setActiveTask(null)
      deps.chatSessionCwd.value = ''
      // When the caller passes (workspaceId, itemId), mirror them into the URL so the
      // kanban/folder/design item survives a page reload. Without this, the workspace path alone
      // loses the active item on refresh because `activeWorkspaceItemId` is in-memory only.
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
      // Settings opens on the workspace the user is IN, with that workspace in the PATH - the same
      // URL contract every other view uses.
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
      // The stored key predates Migration 105: the sections it can name are workspace-scoped now, so
      // it selects a section on the workspace page. Anything else (`general`, an unknown value) is
      // dropped rather than sent as `?section=` to the workspace page.
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

  // Header dropdown workspace switch.
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
    deps.chatSessionCwd.value = ''
    workspacesStore.setActiveWorkspace(workspaceId)
    router.push(buildAppUrl({ workspaceId }))
  }

  // Close the chatview column (the 3-column layout's right pane). Triggered by the ChatView's ✕
  // header button.
  const handleCloseTaskView = () => {
    // Tab mode: a kanban task chat owns its own tab, so "close the chat" means "close that tab".
    const closingTab = tabsStore.activeTab
    const closingChatTaskId = closingTab
      ? parseItemIdWithChat(closingTab.query.itemId ?? '').chatTaskId
      : null
    if (
      tabsStore.enabled &&
      deps.activeWorkspaceItem.value?.item_type === 'kanban' &&
      closingTab?.kind === 'workspace' &&
      closingChatTaskId
    ) {
      workspacesStore.setActiveTask(null)
      navigationStore.clearActiveChat()
      // close() activates the right neighbour, else the left. The chat tab was inserted directly
      // after the board tab, so this lands back on the board. When the chat tab is the ONLY tab,
      // close() opens a fresh home tab — the browser-like fallback, deliberately not special-cased.
      tabsStore.close(closingTab.id)
      deps.applyActiveTabToUrl()
      return
    }
    // CHATVIEW-BUG (fix): setActiveTask(null) does NOT clear the navigation store's active chat
    // anymore (the unconditional clear broke the chat-nav paths in Sidebar.vue:316-322 and
    // ChatsList.vue:220-232).
    workspacesStore.setActiveTask(null)
    navigationStore.clearActiveChat()
    // 2026-08-06 (design-chat-as-dialog bug fix): clearing activeTaskId above triggers the watcher at
    // the top of this block which clears `activeDesignChatTaskId` and `activeDesignChatPageName` —
    // that's how the dialog unmounts.
    const wsId = deps.activeWorkspaceId.value
    const itemId = workspacesStore.activeWorkspaceItemId
    const pageId = workspacesStore.activeDesignPageId
    const sub: Record<string, string> = {}
    if (pageId) sub.pageId = pageId
    // Restore the kanban per-column sort state (kanban-sort-by plan, 2026-08-06 —
    // `?sorts=col_x:name:asc,...`). Sidebar's handleSelectTask snapshots the user's sort choice
    // before navigating into the task view; we read it back here and put it back into the URL.
    if (workspacesStore.savedSortsParam) {
      sub.sorts = workspacesStore.savedSortsParam
      workspacesStore.savedSortsParam = ''
    }
    // Restore the kanban layout (columns | rows). Like `sorts`, this is URL-only state, so it is read
    // back off the current route rather than the store. Without it, opening a task chat and closing
    // it snapped the board back to column mode.
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

  return { handleNavigate, handleSelectWorkspace, handleUpdateChatId, handleCloseTaskView }
}
