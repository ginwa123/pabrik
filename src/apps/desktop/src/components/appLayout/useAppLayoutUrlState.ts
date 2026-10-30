import { ref, type Ref } from 'vue'
import type { RouteLocationNormalizedLoaded, Router } from 'vue-router'
import { buildAppUrl, parseAppPath, type AppUrlLocation } from '../../helpers/appUrl'
import { parseItemIdWithChat } from '../../helpers/buildItemIdWithChat'
import type { useWorkspacesStore, Workspace } from '../../stores/workspaces'

type UrlStateDeps = {
  router: Router
  route: RouteLocationNormalizedLoaded
  workspacesStore: ReturnType<typeof useWorkspacesStore>
}

type PendingUrlRestore = { workspaceId: string; itemId: string; pageId: string }

export interface UseAppLayoutUrlStateReturn {
  pendingUrlRestore: Ref<PendingUrlRestore | null>
  restoreUrlState: (wsList?: Workspace[]) => Promise<void>
  syncItemToUrl: (oldItemId: string | null) => void
}

/** URL ⇄ store mirroring: the one-shot deep-link restore and the item→URL sync. */
export function useAppLayoutUrlState(deps: UrlStateDeps): UseAppLayoutUrlStateReturn {
  const { router, route, workspacesStore } = deps

  // Subscribe to /api/kanban/events on the FIRST truthy activeWorkspaceId and update the client-side
  // filter on every subsequent change.
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
      // `/add` extends the project path, so it restores the same item/pageId —
      // without this a deep link to the add page renders a blank main view.
      if (
        parsedPath.kind === 'project' ||
        parsedPath.kind === 'projectChat' ||
        parsedPath.kind === 'projectAdd'
      ) {
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
        // SIMPLIFY-URL-BROWSER (2026-08-15): parse the wire-shape itemId (may carry /chat/<taskId>
        // suffix). pendingUrlRestore only needs the bare id; the chat task id is restored separately
        // in onMounted above.
        const parsed = rawItemId ? parseItemIdWithChat(rawItemId) : { itemId: '' }
        return { workspaceId: wsId, itemId: parsed.itemId, pageId: pageId ?? '' }
      }
      return null
    })(),
  )
  // Keep one restore in flight while the target workspace lazily loads. A seeded workspace can appear
  // in the list before its items arrive; checking that first snapshot would incorrectly clear the
  // pending URL restore and leave a project deep link on the blank Chats view.
  let urlRestoreInFlight = false
  // URL restore (replaces the old workspaces watcher). Runs once from onMounted (covers fixtures
  // seeded before mount) and from the store subscription pump (covers the async
  // initializeFromSystemFolder path). Reads the live list by default so pump callers pass nothing.
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

  // Run once at setup (replicates the old `{ immediate: true }` watcher): with fixtures seeded before
  // mount this restores synchronously, BEFORE initializeFromSystemFolder's seedList replaces the rows
  // (a later call would see the seeded items as "loaded" and skip the fetch, stranding an empty tree.
  void restoreUrlState()

  // IMPORTANT (2026-07-28 per-page chat scoping): When the user switches design pages
  // (activeDesignPageId changes in the store, mirrored from DesignView's activePageId sync), we DO
  // NOT swap the active chat task.
  const syncItemToUrl = (oldItemId: string | null) => {
    const itemId = workspacesStore.activeWorkspaceItemId
    const pageId = workspacesStore.activeDesignPageId
    const wsId = workspacesStore.activeWorkspace?.id ?? ''
    const currentView = route.query.view as string | undefined
    // FIX (task-url-overwrite, task_1785959660154, 2026-08-06): The URL sync watcher must NOT fire
    // while Sidebar is in the middle of a task navigation.
    if (workspacesStore.isNavigatingToTask) return
    // FIX (chat-click-url-overwrite, task_1787844892180_2, 2026-08-27): Inverse of the
    // task_1785959660154 race.
    if (!itemId && oldItemId) return
    // Only sync when we're on the workspace view — all other views
    // (chat, settings, gitfile, skill, code-editor) have their
    // own URL contract and should be preserved.
    if (currentView !== 'workspace' && currentView !== undefined) return

    // Path-based mirror (plan: 2026-09-22-revamp-ui-chats). Store state maps onto buildAppUrl
    // targets; the task-chat suffix is preserved from the current URL when the suffixed task is still
    // the store's live task.
    const safeItemId = itemId ?? ''
    // The live task id is read from `activeTaskId` (the raw id), NOT the `activeTask` computed: the
    // computed resolves the parent item from the loaded tree, which is null when the parent's
    // workspace hasn't loaded its items yet (lazy loading) or in tests that seed the task id without.
    const liveTaskId = workspacesStore.activeTaskId ?? workspacesStore.activeTask?.id ?? null
    const pathParsed = parseAppPath(route.path)
    const urlChatTask =
      pathParsed.kind === 'projectChat'
        ? pathParsed.chatTaskId
        : parseItemIdWithChat((route.query.itemId as string) ?? '').chatTaskId
    const chatTaskId = urlChatTask && urlChatTask === liveTaskId ? urlChatTask : undefined

    const sub: Record<string, string> = {}
    // pageId is design-item-scoped — only include it when the active item is a design. Empty pageId
    // means "default to first page" and is omitted from the URL to keep the URL clean.
    if (pageId) {
      const activeItem = workspacesStore.workspaces
        .flatMap((ws) => ws.items)
        .find((it) => it.id === itemId)
      if (activeItem?.item_type === 'design') {
        sub.pageId = pageId
      }
    }
    // FIX (kanban-sort-independence, task_1785730557641, 2026-08-06): preserve the per-column `sorts`
    // query param so the URL survives navigation. Without this, this watcher (which fires on every
    // workspaceItemId change) would clobber the URL and drop the `sorts=col_X:...` KanbanView wrote.
    const urlSorts = route.query.sorts as string | undefined
    if (urlSorts) {
      sub.sorts = urlSorts
    }
    // Preserve the kanban task-detail deep-link (?detail=<taskId>) when staying on the SAME project,
    // so reactive store updates (e.g. setActiveTask parent-discovery, design page switches) don't
    // drop the open panel. Dropped when navigating to a different item.
    const urlDetail = route.query.detail as string | undefined
    if (urlDetail) {
      const urlProject =
        pathParsed.kind === 'project' ||
        pathParsed.kind === 'projectChat' ||
        pathParsed.kind === 'projectAdd'
          ? pathParsed.projectId
          : parseItemIdWithChat((route.query.itemId as string) ?? '').itemId
      if (urlProject === safeItemId) {
        sub.detail = urlDetail
      }
    }
    // The add-task page is the project path + `/add`, its target column in `?column=`. Keep both only
    // while the URL names the store's own item — otherwise this mirror would replace a `/add` deep
    // link back to the plain board the moment its item lands (dropping the page the user asked for).
    const keepAdd = pathParsed.kind === 'projectAdd' && pathParsed.projectId === safeItemId
    const urlAddColumn = keepAdd ? (route.query.column as string | undefined) : undefined
    if (urlAddColumn) sub.column = urlAddColumn
    // A document is its own path, so this mirror never targets one — there
    // is no `doc` query for a store write to strip.
    let target: AppUrlLocation | null = null
    if (wsId && safeItemId) {
      target = buildAppUrl({
        workspaceId: wsId,
        projectId: safeItemId,
        chatTaskId,
        addTask: keepAdd && !chatTaskId,
        query: sub,
      })
    } else if (workspacesStore.activeWorkspaceId) {
      // Standalone workspace selection (no active item): keep the
      // dropdown's workspaceId in the URL (revamp plan, 2026-09-22).
      target = buildAppUrl({ workspaceId: workspacesStore.activeWorkspaceId, query: sub })
    }
    if (!target) return
    // No-op when the URL already matches the store state (path + sorts/detail/pageId) — avoids
    // redundant replaces that would churn history and re-trigger the route watcher. `tab` is
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

  return { pendingUrlRestore, restoreUrlState, syncItemToUrl }
}
