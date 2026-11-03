/** The workspace a route-scoped surface is ABOUT. Order: the PATH's workspace id, then the one the
 * app is actually in. */
export function resolveWorkspaceId(
  fromPath: string | string[] | null | undefined,
  activeWorkspaceId: string | null | undefined,
): string {
  if (typeof fromPath === 'string' && fromPath.length > 0) return fromPath
  return activeWorkspaceId ?? ''
}

/** The workspace the app is on: the one every workspace-scoped request
 *  names. Under `--saas` the server lists a workspace's VM, so a request that
 *  does not say which workspace it means is refused. */
let currentWorkspaceId: string | null = null

/** Set the workspace the app is on. An empty id means "no workspace". */
export function setCurrentWorkspaceId(id: string | null | undefined): void {
  currentWorkspaceId = id && id.length > 0 ? id : null
}

/** The workspace the app is on, or null when there is none. */
export function getCurrentWorkspaceId(): string | null {
  return currentWorkspaceId
}

/** `url` with the workspace the app is on appended, for the endpoints whose
 *  `path` alone cannot name it: under `--saas` every `/api/git/*` tree lives
 *  in a workspace's VM, so the request has to say which one. */
export function withWorkspaceId(url: string): string {
  if (!url.startsWith('/git/')) return url
  const id = getCurrentWorkspaceId()
  if (!id) return url
  const separator = url.includes('?') ? '&' : '?'
  return `${url}${separator}workspace_id=${encodeURIComponent(id)}`
}

/** Test-only: reset the module state between specs. */
export function resetWorkspaceScopeForTest(): void {
  currentWorkspaceId = null
}
