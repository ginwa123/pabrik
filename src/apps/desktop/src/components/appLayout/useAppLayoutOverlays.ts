import { ref, type ComputedRef, type Ref } from 'vue'
import type { RouteLocationNormalizedLoaded, Router } from 'vue-router'
import * as api from '../../api'
import type { OpenInCodeEditorFn, OpenInCodeEditorOptions } from '../../composables/useCodeEditor'
import type { useCodeEditorSession } from '../../composables/useCodeEditorSession'
import type { useCurrentMainView } from '../../composables/useCurrentMainView'
import { buildAppUrl, buildTaskAppUrl, parseAppPath, type AppUrlLocation } from '../../helpers/appUrl'
import type { useWorkspacesStore, Task } from '../../stores/workspaces'

type OverlaysDeps = {
  router: Router
  route: RouteLocationNormalizedLoaded
  workspacesStore: ReturnType<typeof useWorkspacesStore>
  currentMainView: ReturnType<typeof useCurrentMainView>
  codeEditorSession: ReturnType<typeof useCodeEditorSession>
  activeChatId: ComputedRef<string>
  activeTask: ComputedRef<Task | null | undefined>
  activeWorkspaceId: ComputedRef<string>
  chatSessionCwd: Ref<string>
  rightSidebarCwd: ComputedRef<string>
}

export interface UseAppLayoutOverlaysReturn {
  chatTarget: (sessionId: string) => AppUrlLocation
  gitViewerFile: Ref<api.GitFileChange | null>
  gitViewerStaged: Ref<boolean>
  skillViewerSkill: Ref<{ name: string } | null>
  clearAllOverlays: () => void
  closeGitViewer: () => void
  closeSkillViewer: () => void
  closeCodeEditor: () => void
  openInCodeEditor: OpenInCodeEditorFn
  handleSubmitReview: (message: string) => Promise<void>
  handleCommentSaved: () => void
  retryEditorRestore: () => void
}

/** The URL-driven overlays AppLayout mounts over the main view: git file, skill, code editor. */
export function useAppLayoutOverlays(deps: OverlaysDeps): UseAppLayoutOverlaysReturn {
  const { router, route, workspacesStore, codeEditorSession } = deps

  // Standalone-chat URL target (plan: 2026-09-22-revamp-ui-chats). Chats live under their workspace
  // path.
  function chatTarget(sessionId: string): AppUrlLocation {
    const wsForChat =
      (deps.currentMainView.value.kind === 'chat' && deps.currentMainView.value.workspaceId) ||
      (deps.currentMainView.value.kind === 'workspace' && deps.currentMainView.value.workspaceId) ||
      workspacesStore.activeWorkspaceId ||
      ''
    if (wsForChat) return buildAppUrl({ workspaceId: wsForChat, chatSessionId: sessionId })
    return { path: '/app', query: { view: 'chat', session: sessionId } }
  }

  // Shared "return to the underlying view" navigation for overlay closes (git viewer, skill viewer,
  // code editor).
  function replaceWithCurrentContext(): void {
    if (workspacesStore.activeWorkspaceItemId) {
      // Returning to the board wins over any open task chat — clear the task so the
      // kanban/design/folder renders instead of the chat. Without this, the URL is bare (no /chat/
      // suffix) while the chat is still active: board URL + chat content.
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
          workspaceId: deps.activeWorkspaceId.value,
          projectId: workspacesStore.activeWorkspaceItemId,
          query: sub,
        }),
      )
    } else if (deps.activeTask.value) {
      // NEW (add-workspace-id-params, 2026-08-06): include workspaceId + itemId + pageId when the
      // task is attached to a workspace item. Pre-fix this branch wrote only `?view=task&task=X`,
      // dropping the kanban / design breadcrumb — the user reported this (task_1785774094183).
      router.replace(
        buildTaskAppUrl({
          taskId: deps.activeTask.value.id,
          activeWorkspaceId: deps.activeWorkspaceId.value,
          activeWorkspaceItemId: workspacesStore.activeWorkspaceItemId,
          activeDesignPageId: workspacesStore.activeDesignPageId,
          activeItemType: workspacesStore.activeWorkspaceItem?.item_type ?? null,
          currentQuery: route.query,
        }),
      )
    } else if (deps.activeChatId.value.startsWith('chat-')) {
      const sessionId = deps.activeChatId.value.replace(/^chat-/, '')
      router.replace(chatTarget(sessionId))
    } else {
      router.replace({ path: '/app', query: {} })
    }
  }

  const closeGitViewer = () => {
    gitViewerFile.value = null
    gitViewerStaged.value = false
    // Navigate back to previous view based on state.
    replaceWithCurrentContext()
  }

  // Skill viewer state
  const skillViewerSkill = ref<{ name: string } | null>(null)

  const closeSkillViewer = () => {
    skillViewerSkill.value = null
    // Navigate back to previous view based on state. Preserve the workspace item (folder / kanban /
    // design) IDs when the user opened the skill view while on a workspace item — see closeGitViewer
    // for the same pattern.
    replaceWithCurrentContext()
  }

  const openInCodeEditor: OpenInCodeEditorFn = async (opts: OpenInCodeEditorOptions) => {
    // Clear other overlays to prevent priority conflicts
    gitViewerFile.value = null
    gitViewerStaged.value = false
    skillViewerSkill.value = null
    await codeEditorSession.openFile(opts)
  }

  const closeCodeEditor = () => {
    codeEditorSession.clear()
    // Strip only the editor keys so the underlying board/chat URL (path plus pageId/sorts/tab/…)
    // survives the close. A bare /app editor link (legacy bookmark, fresh reload with no path
    // context) has nothing to keep — rebuild from the store there.
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
    // Navigate back to previous view. Preserve the workspace item (folder / kanban / design) IDs when
    // the user opened the code editor while on a workspace item — see closeGitViewer for the same
    // pattern. For design items, also preserve pageId so the active design page survives a reload.
    replaceWithCurrentContext()
  }

  const handleSubmitReview = async (message: string) => {
    console.log('[AppLayout] Code review submitted:', message)
    // Navigate to chat view with the review message
    if (deps.activeChatId.value.startsWith('chat-')) {
      const sessionId = deps.activeChatId.value.replace(/^chat-/, '')
      // Send the review message to the active chat session
      try {
        await api.sendChatMessage(sessionId, message, deps.rightSidebarCwd.value)
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

  // The editor session is global to AppLayout, not per-chat: switching the main context (chat
  // session, task, workspace item, document) must drop any open overlay, otherwise the old file keeps
  // rendering inside the new chat's center column (ChatView reads the same injected refs).
  const clearAllOverlays = () => {
    gitViewerFile.value = null
    gitViewerStaged.value = false
    skillViewerSkill.value = null
    codeEditorSession.clear()
  }

  // Retry the editor restore when the cwd context arrives late.
  const retryEditorRestore = () => {
    const cwd = deps.rightSidebarCwd.value
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

  return {
    chatTarget,
    gitViewerFile,
    gitViewerStaged,
    skillViewerSkill,
    clearAllOverlays,
    closeGitViewer,
    closeSkillViewer,
    closeCodeEditor,
    openInCodeEditor,
    handleSubmitReview,
    handleCommentSaved,
    retryEditorRestore,
  }
}
