import type { ComputedRef } from 'vue'
import type { RouteLocationNormalizedLoaded, Router } from 'vue-router'
import * as api from '../../api'
import type { useCodeEditorSession } from '../../composables/useCodeEditorSession'
import {
  buildAppUrl,
  isAppPath,
  normalizeAppPath,
  parseAppPath,
  type AppUrlLocation,
} from '../../helpers/appUrl'
import { parseItemIdWithChat } from '../../helpers/buildItemIdWithChat'
import type { useNavigationStore } from '../../stores/navigation'
import type { useWorkspacesStore } from '../../stores/workspaces'

type BootUrlDeps = {
  router: Router
  route: RouteLocationNormalizedLoaded
  workspacesStore: ReturnType<typeof useWorkspacesStore>
  navigationStore: ReturnType<typeof useNavigationStore>
  codeEditorSession: ReturnType<typeof useCodeEditorSession>
  fetchChatSessionCwd: (sessionId: string) => Promise<void>
  rightSidebarCwd: ComputedRef<string>
}

export type UseAppLayoutBootUrlReturn = { handleBootUrl: () => Promise<void> }

/** Boot URL handling (plan: 2026-09-22-revamp-ui-chats). */
export function useAppLayoutBootUrl(deps: BootUrlDeps): UseAppLayoutBootUrlReturn {
  const { router, route, workspacesStore, navigationStore, codeEditorSession } = deps

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

    // 3.
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
      // Unknown ?view= values (gitfile/skill/code-editor overlays)
    }

    // 4. Canonical boot from the (possibly rewritten) path.
    const parsed = parseAppPath(path)
    if (parsed.kind === 'chat') {
      workspacesStore.setActiveWorkspaceItem(null)
      navigationStore.setActiveChat(parsed.sessionId, navigationStore.activeChatName)
      deps.fetchChatSessionCwd(parsed.sessionId)
    } else if (parsed.kind === 'projectChat') {
      workspacesStore.setActiveTask(parsed.chatTaskId)
    } else if (parsed.kind === 'doc') {
      // A document is its own page: drop any chat/project selection so the sidebar's single-active-row contract holds and the document does not look like it is …
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

    // Prefer the workspace encoded by a workspace/project deep link.
    const preferredWorkspaceId =
      parsed.kind === 'workspace' ||
      parsed.kind === 'project' ||
      parsed.kind === 'projectChat' ||
      parsed.kind === 'projectAdd' ||
      parsed.kind === 'projectSettings' ||
      parsed.kind === 'chat'
        ? parsed.workspaceId
        : undefined
    workspacesStore.initializeFromSystemFolder(preferredWorkspaceId)

    // 5.
    if (query.view === 'code-editor' && query.file) {
      if (parsed.kind === 'chat') {
        await deps.fetchChatSessionCwd(parsed.sessionId)
      }
      await codeEditorSession.restoreFromUrl({
        fileParam: query.file,
        queryCwd: query.cwd ?? '',
        fallbackCwd: deps.rightSidebarCwd.value,
        lineParam: query.line,
        modeParam: query.mode,
      })
    }
  }

  // The `tab` param is client-only (names the browser tab) — carry it across boot rewrites so a background tab doesn't lose its name.
  function keepTabParam(query: Record<string, string>): Record<string, string> {
    return query.tab ? { tab: query.tab } : {}
  }

  // Legacy standalone chat (path or ?view=chat): resolve the owning workspace via the session-detail endpoint, then boot the chat under its path.
  async function bootLegacyChat(sessionId: string, keep: Record<string, string>): Promise<void> {
    const wsId = await api.getSessionWorkspaceId(sessionId)
    // The URL points to a chat: clear any workspace-item active state in BOTH branches (unresolvable sessions fail closed to `/app`, but the stale item must still go …
    workspacesStore.setActiveWorkspaceItem(null)
    navigationStore.setActiveChat(sessionId, navigationStore.activeChatName)
    deps.fetchChatSessionCwd(sessionId)
    if (!wsId) {
      router.replace({ path: '/app', query: keep })
      workspacesStore.initializeFromSystemFolder()
      return
    }
    router.replace(buildAppUrl({ workspaceId: wsId, chatSessionId: sessionId, query: keep }))
    await workspacesStore.initializeFromSystemFolder()
  }

  // Legacy task link (/app/task/:tid): resolve the workspace via the session detail (task id == session id), then locate the parent item in the loaded tree.
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
        buildAppUrl({
          workspaceId: wsId,
          projectId: parentItemId,
          chatTaskId: taskId,
          query: keep,
        }),
      )
    } else {
      router.replace(buildAppUrl({ workspaceId: wsId, query: keep }))
    }
  }

  // Sync rewrite for legacy query URLs whose target is fully described by the query itself (no server lookup needed).
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
      // Kanban layout (columns | rows).
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

  return { handleBootUrl }
}
