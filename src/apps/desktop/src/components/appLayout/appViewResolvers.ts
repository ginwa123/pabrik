import { parseAppPath } from '../../helpers/appUrl'

/** The `<main>` views that win over the path-derived view: they are page routes or open overlays. */
export type OverlayView =
  | 'settings'
  | 'kanban-settings'
  | 'workspace-settings'
  | 'gitfile'
  | 'skill'

/** Path-only + overlay-ref half of `currentView`, resolved before the code-editor branch. */
export function resolveOverlayView(
  path: string,
  hasGitFile: boolean,
  hasSkill: boolean,
): OverlayView | null {
  if (path === '/app/settings') return 'settings'
  // LEGACY kanban-settings route (/app/kanban/:itemId/settings); the canonical shape is the
  // workspace-scoped project path, matched below via parseAppPath. Must come BEFORE the
  // route.query.view fallthrough: the URL has no `view=` param, the path IS the discriminator.
  if (/^\/app\/kanban\/[^/]+\/settings\/?$/.test(path)) {
    return 'kanban-settings'
  }
  // Workspace settings page, `/app/:workspaceId/settings`. Same shape as the kanban-settings branch
  // above and for the same reason: the path IS the discriminator, there is no `view=` query param
  // to read, and it must be resolved before anything below claims a `/app/{id}` path.
  if (/^\/app\/[^/]+\/settings\/?$/.test(path)) {
    return 'workspace-settings'
  }
  // gitfile view - check only the ref (set synchronously before navigation)
  if (hasGitFile) {
    return 'gitfile'
  }
  // skill view - check only the ref
  if (hasSkill) {
    return 'skill'
  }
  return null
}

/** Path-based half: projects are workspace items, the landing and a bare /app are 'chat'. */
export function resolvePathView(path: string, queryView: string | undefined): string {
  const parsedPath = parseAppPath(path)
  // Document page (Migration 095). It is a PAGE, not an overlay: it sits in the same `v-else-if`
  // chain as every other main view, so the chat behind it is unmounted rather than stacked under.
  // Checked before the workspace/chat branches so nothing else can claim a doc path.
  if (parsedPath.kind === 'doc') return 'documents'
  // Kanban settings page, workspace-scoped: /app/{ws}/projects/{pid}/settings.
  if (parsedPath.kind === 'projectSettings') return 'kanban-settings'
  if (
    parsedPath.kind === 'workspace' ||
    parsedPath.kind === 'project' ||
    parsedPath.kind === 'projectChat' ||
    parsedPath.kind === 'projectAdd'
  ) {
    return 'workspace'
  }
  if (parsedPath.kind === 'chat' || parsedPath.kind === 'landing') {
    return 'chat'
  }
  // SIMPLIFY-URL-BROWSER (2026-08-15): the URL never says `view=task` anymore (legacy URLs are
  // auto-rewritten on mount). The chat-open state is encoded as /chat/<taskId> on itemId when
  // view=workspace, so `currentView` returns 'workspace' for both no-chat and chat-open states.
  return queryView || 'chat'
}
