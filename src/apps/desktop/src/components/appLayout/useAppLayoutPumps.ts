import { onMounted, onUpdated, type ComputedRef, type Ref } from 'vue'
import type { RouteLocationNormalizedLoaded } from 'vue-router'
import type { useNavigationStore } from '../../stores/navigation'
import type { useWorkspacesStore } from '../../stores/workspaces'

type PumpsDeps = {
  route: RouteLocationNormalizedLoaded
  workspacesStore: ReturnType<typeof useWorkspacesStore>
  navigationStore: ReturnType<typeof useNavigationStore>
  activeWorkspaceId: ComputedRef<string>
  rightSidebarCwd: ComputedRef<string>
  activeDesignChatTaskId: Ref<string>
  activeDesignChatPageName: Ref<string>
  pendingUrlRestore: Ref<{ workspaceId: string; itemId: string; pageId: string } | null>
  clearAllOverlays: () => void
  initSseStores: (newId: string) => Promise<void>
  syncItemToUrl: (oldItemId: string | null) => void
  maybeLoadAgentData: () => void
  restoreUrlState: () => Promise<void>
  retryEditorRestore: () => void
  syncTaskFromItemId: () => void
  reconcileRoute: () => Promise<void>
  syncFromRoute: () => void
  isTabsFunnelReady: () => boolean
}

/** The setup-time side of the layout: store subscription pumps, the route-change pump and the mount
 * arms — all explicit, no reactive watchers. */
export function useAppLayoutPumps(deps: PumpsDeps): void {
  const {
    route,
    workspacesStore,
    navigationStore,
    activeWorkspaceId,
    rightSidebarCwd,
    activeDesignChatTaskId,
    activeDesignChatPageName,
    pendingUrlRestore,
    clearAllOverlays,
    initSseStores,
    syncItemToUrl,
    maybeLoadAgentData,
    restoreUrlState,
    retryEditorRestore,
    syncTaskFromItemId,
    reconcileRoute,
    syncFromRoute,
    isTabsFunnelReady,
  } = deps

// ─── Subscription pumps (replace every watcher removed above) ──────────── Two explicit
// mechanisms, no reactive watchers: 1.
let prevPumpItemId: string | null = workspacesStore.activeWorkspaceItemId
let prevPumpPageId: string | null | undefined = workspacesStore.activeDesignPageId
let prevPumpCwd = rightSidebarCwd.value ?? ''
let prevPumpChatId = navigationStore.activeChatId
navigationStore.$subscribe(() => {
  const nextChatId = navigationStore.activeChatId
  if (nextChatId !== prevPumpChatId) {
    prevPumpChatId = nextChatId
    // Chat session switched (Sidebar, ChatsList, or handleNavigate all funnel through
    // setActiveChat).
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
    if (isTabsFunnelReady()) syncFromRoute()
  }
})

// Mount arms (replace the old `{ immediate: true }` watchers): - initSseStores: no-op until the
// workspace id is truthy; the store pump retries on every later mutation. - restoreUrlState: covers
// fixtures seeded before mount; the store pump covers the async initializeFromSystemFolder path.
onMounted(() => {
  void initSseStores(activeWorkspaceId.value)
  void restoreUrlState()
  maybeLoadAgentData()
})
}
