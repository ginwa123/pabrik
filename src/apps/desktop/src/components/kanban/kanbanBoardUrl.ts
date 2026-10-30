/** URL + `sorts` param helpers for the board. Pure functions only — every router call stays in the
 * component or in the composable that owns the state being persisted. */
import { buildAppUrl } from '../../helpers/appUrl'
import type { SortEntry } from './kanbanViewTypes'

export const flattenQuery = (src: Record<string, unknown> | undefined): Record<string, string> => {
  const out: Record<string, string> = {}
  for (const [k, v] of Object.entries(src ?? {})) {
    if (typeof v === 'string') out[k] = v
    else if (Array.isArray(v)) {
      const first = v.find((x): x is string => typeof x === 'string')
      if (first !== undefined) out[k] = first
    }
  }
  return out
}

export const buildBoardAppUrl = (
  wsId: string,
  itemId: string,
  query: Record<string, string>,
) => {
  if (!wsId || !itemId) return { path: '/app', query }
  return buildAppUrl({ workspaceId: wsId, projectId: itemId, query })
}

export const buildAddAppUrl = (wsId: string, itemId: string, query: Record<string, string>) => {
  if (!wsId || !itemId) return { path: '/app', query }
  return buildAppUrl({ workspaceId: wsId, projectId: itemId, addTask: true, query })
}

// Parse the URL's `sorts` query param. Returns an empty array if
// missing / malformed.
export const parseSortsParam = (raw: string | string[] | undefined): SortEntry[] => {
  if (!raw) return []
  const s = Array.isArray(raw) ? raw.join(',') : raw
  const entries: SortEntry[] = []
  for (const part of s.split(',')) {
    const trimmed = part.trim()
    if (!trimmed) continue
    const [columnId, sortBy, direction] = trimmed.split(':')
    if (!columnId || !sortBy || !direction) continue
    if (
      sortBy !== 'position' &&
      sortBy !== 'created_at' &&
      sortBy !== 'updated_at' &&
      sortBy !== 'name'
    )
      continue
    if (direction !== 'asc' && direction !== 'desc') continue
    entries.push({ columnId, sortBy, direction })
  }
  return entries
}

// Encode the per-column sorts into a URL-safe `sorts` string. Default sorts (position + asc) are
// OMITTED so the URL stays clean. Returns null when no non-default sorts exist (caller writes no
// `sorts` param).
export const encodeSortsParam = (entries: SortEntry[]): string | null => {
  const filtered = entries.filter((e) => !(e.sortBy === 'position' && e.direction === 'asc'))
  if (filtered.length === 0) return null
  return filtered.map((e) => `${e.columnId}:${e.sortBy}:${e.direction}`).join(',')
}
