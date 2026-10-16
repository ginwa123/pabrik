/** Persistent cache for `GET /api/git/status`, keyed by cwd. Stale-while-revalidate: ChatView
 * paints the last-known status for a cwd synchronously on init / cwd switch so the bottom chip
 * shows a branch immediately, then the network fetch revalidates it in the background. */
import type { GitStatus } from '../api'
import { userScopedKey } from './userScope'

const KEY_PREFIX = 'pabrik-git-status:v1:'

function storageKey(cwd: string): string {
  return userScopedKey(`${KEY_PREFIX}${cwd}`)
}

/** Normalizes whatever JSON was stored (or what an older/newer backend emitted) into the
 * `GitStatus` shape ChatView renders. */
function normalizeStatus(raw: unknown): GitStatus | null {
  if (!raw || typeof raw !== 'object') return null
  const s = raw as Record<string, unknown>
  if (typeof s.is_git_repo !== 'boolean') return null
  return {
    is_git_repo: s.is_git_repo,
    branch: typeof s.branch === 'string' ? s.branch : '',
    has_changes: s.has_changes === true,
    is_clean: s.is_clean !== false,
    current: typeof s.current === 'string' ? s.current : '',
    status: typeof s.status === 'string' ? s.status : '',
  }
}

/** Last-known status for `cwd`, or null on miss / corrupt entry / no storage. */
export function readGitStatusCache(cwd: string): GitStatus | null {
  if (!cwd) return null
  try {
    const raw = localStorage.getItem(storageKey(cwd))
    if (raw === null) return null
    return normalizeStatus(JSON.parse(raw) as unknown)
  } catch {
    return null
  }
}

/** Persists a successful `/git/status` response. Never throws. */
export function writeGitStatusCache(cwd: string, status: GitStatus): void {
  if (!cwd) return
  try {
    localStorage.setItem(storageKey(cwd), JSON.stringify(status))
  } catch {
    // quota / private mode / no storage — the live fetch still works,
    // only the next init's instant paint is lost.
  }
}

/** Test-only escape hatch — drops the entry for one cwd. */
export function clearGitStatusCache(cwd: string): void {
  if (!cwd) return
  try {
    localStorage.removeItem(storageKey(cwd))
  } catch {
    /* see writeGitStatusCache */
  }
}
