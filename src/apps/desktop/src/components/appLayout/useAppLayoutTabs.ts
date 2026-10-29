import { onMounted, onUnmounted } from 'vue'
import type { RouteLocationNormalizedLoaded, Router } from 'vue-router'
import { useTabShortcuts } from '../../composables/useTabShortcuts'
import { sameRouteQuery, withTabParam } from '../../helpers/tabTarget'
import { parseItemIdWithChat } from '../../helpers/buildItemIdWithChat'
import type { useNavigationStore } from '../../stores/navigation'
import type { useTabsStore } from '../../stores/tabs'
import type { useWorkspacesStore } from '../../stores/workspaces'

type TabsDeps = {
  router: Router
  route: RouteLocationNormalizedLoaded
  workspacesStore: ReturnType<typeof useWorkspacesStore>
  navigationStore: ReturnType<typeof useNavigationStore>
  tabsStore: ReturnType<typeof useTabsStore>
}

export interface UseAppLayoutTabsReturn {
  mirrorTargetIntoStores: (path: string, query: Record<string, string>, chatName?: string) => void
  applyActiveTabToUrl: () => void
  syncFromRoute: () => void
  isTabsFunnelReady: () => boolean
}

/** The tab funnel: every navigation lands here, so the strip can key a tab on the target it reached. */
export function useAppLayoutTabs(deps: TabsDeps): UseAppLayoutTabsReturn {
  const { router, route, workspacesStore, navigationStore, tabsStore } = deps

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

  /** The funnel. Every navigation in the app lands here — sidebar clicks, the chats list,
   * kanban/design chat dialogs, deep links, the Back button — so no call site has to know the tab
   * strip exists, and a view type added later becomes tabbable for free. */
  function syncFromRoute() {
    // The item's type decides whether a task chat belongs to the item's tab (kanban/design open it as
    // a dialog inside that view) or gets its own. Only trust it when it describes the item this URL
    // points at — on a cold boot the tree may not be loaded yet, and the store adopts the tab later.
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

  /**  * Shortcuts and the live title feed are window-scoped wiring, so they live here and are torn down
   * with the layout. Every handler re-applies the URL through `applyActiveTabToUrl`, so the shortcut
   * map can never leave the URL pointing at a tab the user is no longer on. */
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

  return {
    mirrorTargetIntoStores,
    applyActiveTabToUrl,
    syncFromRoute,
    isTabsFunnelReady: () => tabsFunnelReady,
  }
}
