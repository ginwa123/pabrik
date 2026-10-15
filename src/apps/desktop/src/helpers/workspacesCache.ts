/**
 * Persistent cache for `GET /api/workspaces?is_include_items=false`.
 *
 * Stale-while-revalidate: the workspaces store paints the last-known
 * list synchronously on init so the dropdown/sidebar shows rows
 * immediately, then the network fetch revalidates in the background.
 * There is deliberately NO TTL — a stale list is better than an empty
 * sidebar for the seconds the fetch is in flight, and every init is
 * followed by a real fetch anyway.
 *
 * localStorage (not module memory): the point is surviving a full page
 * reload — the cold-boot case where `/api/workspaces` queues behind
 * heavy SQLite queries and takes seconds. Entries are one small array
 * (~100 bytes per workspace), comfortably inside the storage quota.
 *
 * Fail-silent: every storage access is wrapped, so private mode,
 * quota errors, or a missing `localStorage` (vitest/jsdom setups that
 * don't provide one) degrade to a plain cache miss.
 */
import type { Workspace } from '../api'
import { userScopedKey } from './userScope'

const WORKSPACES_CACHE_KEY = 'pabrik-workspaces:v1'

interface CachedWorkspace {
  id: string
  name: string
  icon: string
  items_count?: number
}

/** Normalizes whatever JSON was stored into the minimal `Workspace` shape the store seeds from. */

/** Rows carry `items: []` + `expanded` defaults here — the store restores `expanded` from its own
 * `pabrik-workspace-expanded` key and lazily fills `items` per visit, so the cache never owns UI
 * state or item trees. */

/** Returns null when the payload isn't recognizable at all, so corrupt or foreign data under our
 * key can never render a broken list. */
function normalizeWorkspaces(raw: unknown): Workspace[] | null {
  if (!Array.isArray(raw)) return null
  const out: Workspace[] = []
  for (const entry of raw) {
    if (!entry || typeof entry !== 'object') return null
    const w = entry as Record<string, unknown>
    if (typeof w.id !== 'string' || w.id.length === 0) return null
    if (typeof w.name !== 'string') return null
    out.push({
      id: w.id,
      name: w.name,
      icon: typeof w.icon === 'string' ? w.icon : '📁',
      items: Array.isArray(w.items) && w.items.length === 0 ? [] : [],
      items_count: typeof w.items_count === 'number' ? w.items_count : undefined,
      expanded: false,
    } as Workspace)
  }
  return out
}

/** Last-known workspace list, or null on miss / corrupt entry / no storage. */
export function readWorkspacesCache(): Workspace[] | null {
  try {
    const raw = localStorage.getItem(userScopedKey(WORKSPACES_CACHE_KEY))
    if (raw === null) return null
    return normalizeWorkspaces(JSON.parse(raw) as unknown)
  } catch {
    return null
  }
}

/** Persists a successful `/workspaces?is_include_items=false` response. Never throws. */
export function writeWorkspacesCache(workspaces: Workspace[]): void {
  try {
    const slim: CachedWorkspace[] = (workspaces || []).map((w) => ({
      id: w.id,
      name: w.name,
      icon: typeof w.icon === 'string' ? w.icon : '📁',
      ...(typeof w.items_count === 'number' ? { items_count: w.items_count } : {}),
    }))
    localStorage.setItem(userScopedKey(WORKSPACES_CACHE_KEY), JSON.stringify(slim))
  } catch {
    // quota / private mode / no storage — the live fetch still works,
    // only the next init's instant paint is lost.
  }
}

/** Test-only escape hatch — drops the cached workspace list. */
export function clearWorkspacesCache(): void {
  try {
    localStorage.removeItem(userScopedKey(WORKSPACES_CACHE_KEY))
  } catch {
    /* see writeWorkspacesCache */
  }
}

/** Test-only escape hatch — exposes the storage key for TTL-style tests. */
export function workspacesCacheKey(): string {
  return WORKSPACES_CACHE_KEY
}
