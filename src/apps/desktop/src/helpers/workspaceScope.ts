/**
 * The workspace a route-scoped surface is ABOUT.
 *
 * Order: the PATH's workspace id, then the one the app is actually in. The path
 * wins because it is the only source that is already right on a cold deep-link
 * load (`/app/:workspaceId/...`), where the store has not resolved an active
 * workspace yet; the store is the fallback for the legacy workspace-less routes
 * (`/app`, `/app/chat/:sessionId`).
 *
 * Never fall back to `workspaces[0]`. The list API sorts by
 * `position DESC, created_at DESC` (`workspaces_list.zig`), so "first" is
 * whichever workspace the user last moved to the top — not the one they are
 * working in. That guess is what put one workspace's Profiles on screen while
 * the user was in another.
 *
 * `fromPath` is typed loosely on purpose: `route.params.workspaceId` is
 * `string | string[]` on a Vue router route, and `undefined` in the
 * router-less mounts ~30 specs use.
 */
export function resolveWorkspaceId(
  fromPath: string | string[] | null | undefined,
  activeWorkspaceId: string | null | undefined,
): string {
  if (typeof fromPath === 'string' && fromPath.length > 0) return fromPath
  return activeWorkspaceId ?? ''
}
