import type { ComputedRef, Ref } from 'vue'
import type { RouteLocationNormalizedLoaded } from 'vue-router'
import type { useCodeEditorSession } from '../../composables/useCodeEditorSession'
import { parseAppPath } from '../../helpers/appUrl'
import { parseItemIdWithChat } from '../../helpers/buildItemIdWithChat'
import type { useNavigationStore } from '../../stores/navigation'
import type { useTabsStore } from '../../stores/tabs'
import type { useWorkspacesStore } from '../../stores/workspaces'
import type * as api from '../../api'

type RouteSyncDeps = {
  route: RouteLocationNormalizedLoaded
  workspacesStore: ReturnType<typeof useWorkspacesStore>
  navigationStore: ReturnType<typeof useNavigationStore>
  tabsStore: ReturnType<typeof useTabsStore>
  codeEditorSession: ReturnType<typeof useCodeEditorSession>
  activeChatId: ComputedRef<string>
  chatSessionCwd: Ref<string>
  rightSidebarCwd: ComputedRef<string>
  gitViewerFile: Ref<api.GitFileChange | null>
  gitViewerStaged: Ref<boolean>
  skillViewerSkill: Ref<{ name: string } | null>
  clearAllOverlays: () => void
  fetchChatSessionCwd: (sessionId: string) => Promise<void>
}

export interface UseAppLayoutRouteSyncReturn {
  syncTaskFromItemId: () => void
  reconcileRoute: () => Promise<void>
}

export function useAppLayoutRouteSync(deps: RouteSyncDeps): UseAppLayoutRouteSyncReturn {
  const {
    route,
    workspacesStore,
    navigationStore,
    tabsStore,
    codeEditorSession,
    activeChatId,
    chatSessionCwd,
    rightSidebarCwd,
    gitViewerFile,
    gitViewerStaged,
    skillViewerSkill,
    clearAllOverlays,
    fetchChatSessionCwd,
  } = deps

// ─── Browser Back/forward ↔ task chat sync (non-tab mode) ───── Opening a task chat PUSHes
// `/app?...&itemId=<id>/chat/<taskId>` (Sidebar.handleSelectTask), so browser Back pops the URL
// back to the board URL.
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

// Route-change reconcile (Back/Forward/deep-link drift) — replaces the old path+query watcher; runs
// from the render pump below.
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
  // Documents (Migration 095) are a PATH shape, so this watcher reads them like any other branch
  // below.
  if (parsed.kind === 'chat') {
    // The path names the workspace too — adopt it, exactly as the project branch below does.
    // Without this, Back/Forward into a chat left the previous workspace selected in the sidebar
    // while the URL named another one (task_1791556124905_10).
    if (workspacesStore.activeWorkspaceId !== parsed.workspaceId) {
      await workspacesStore.setActiveWorkspace(parsed.workspaceId)
    }
    if (activeChatId.value !== `chat-${parsed.sessionId}`) {
      workspacesStore.setActiveWorkspaceItem(null)
      navigationStore.setActiveChat(parsed.sessionId, navigationStore.activeChatName)
    }
    await fetchChatSessionCwd(parsed.sessionId)
    // An overlay on a chat path (readable editor link) still needs its restore below — the path
    // adoption above only rebuilds the cwd context the restore reads from.
    if (!isOverlayView) {
      clearAllOverlays()
      return
    }
  } else if (
    parsed.kind === 'project' ||
    parsed.kind === 'projectChat' ||
    parsed.kind === 'projectAdd' ||
    parsed.kind === 'projectSettings'
  ) {
    // Path project URLs: adopt workspace + item, sync the task chat suffix, drop any standalone
    // chat. `/add` and `/settings` ride the project path, so they adopt the same context — no task
    // is active on them (wantTaskId stays null), exactly as on the plain board.
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
    // A document is its own main view, so the chat / item / task selections must clear — exactly as
    // `landing` does above.
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
    // Restore code editor state from URL (reload, Back/Forward, shared link).
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
    // No overlay in the URL: drop any open viewer. The full session clear also resets
    // loadedKey/cwd/loading, so a later deep link with the same file still refetches instead of
    // hitting the restore echo guard.
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
      // Clear chat session cwd when not in chat view. We intentionally do NOT blindly clear
      // activeWorkspaceItemId here: Sidebar's handleSelectItem navigates to this exact URL after
      // setting the active workspace item (folder or kanban).
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

  return { syncTaskFromItemId, reconcileRoute }
}
