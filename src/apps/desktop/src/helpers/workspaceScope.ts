/** The workspace a route-scoped surface is ABOUT. Order: the PATH's workspace id, then the one the
 * app is actually in. */
export function resolveWorkspaceId(
  fromPath: string | string[] | null | undefined,
  activeWorkspaceId: string | null | undefined,
): string {
  if (typeof fromPath === 'string' && fromPath.length > 0) return fromPath
  return activeWorkspaceId ?? ''
}
