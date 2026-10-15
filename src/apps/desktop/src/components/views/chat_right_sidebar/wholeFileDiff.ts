import * as api from '../../../api'
import { parseUnifiedDiff, type ParsedDiffLine } from './parseUnifiedDiff'

/**
 * Whole-file diff reader — the ONE way the frontend asks for a file's full
 * context, and the reason "Whole file" costs one request instead of one per
 * click.
 *
 * Deliberately SEPARATE from `helpers/folderDiffCache.ts`: that snapshot is
 * the 3-line-context diff the sidebar re-primes on every 30 s poll, and it
 * holds EVERY changed file. Writing a full-context body into it would either
 * bloat every poll or silently swap the diff view's own content. Different
 * question, different cache.
 *
 * `refused` is a real answer, not an error: the server declines to serve a
 * file whose full-context diff is over its budget, because a truncated
 * "whole file" reads as a complete one. The caller offers the code viewer.
 */
export interface WholeFileDiff {
  lines: ParsedDiffLine[]
  added: number
  removed: number
  refused: boolean
}

const TTL_MS = 30_000
const MAX_ENTRIES = 32

interface CacheEntry {
  value: WholeFileDiff
  at: number
}

const cache = new Map<string, CacheEntry>()
const inFlight = new Map<string, Promise<WholeFileDiff>>()

/** Cache key for one file's whole-file diff. Staged and unstaged are
 * independent diffs of the same path, so `staged` is part of the key. */
export function wholeFileKey(path: string, staged: boolean): string {
  return `${staged ? 1 : 0}:${path}`
}

function cacheKey(cwd: string, path: string, staged: boolean): string {
  return `${cwd}|${wholeFileKey(path, staged)}`
}

function remember(key: string, value: WholeFileDiff): void {
  cache.set(key, { value, at: Date.now() })
  // Insert-order eviction. The map is small (a handful of files the user
  // actually opened) so a plain oldest-first trim is enough.
  while (cache.size > MAX_ENTRIES) {
    const oldest = cache.keys().next()
    if (oldest.done) break
    cache.delete(oldest.value)
  }
}

/** Read the whole-file diff for one path, fetching at most once per path.
 * A backend failure REJECTS. It must never resolve to an empty diff: an empty
 * diff renders as "this file is unchanged", which is the worst direction to be
 * wrong in — and the one thing the whole-file view exists to avoid. */
export async function fetchWholeFileDiff(
  cwd: string,
  path: string,
  staged: boolean,
): Promise<WholeFileDiff> {
  const key = cacheKey(cwd, path, staged)
  const hit = cache.get(key)
  if (hit && Date.now() - hit.at < TTL_MS) return hit.value

  const pending = inFlight.get(key)
  if (pending) return pending

  const request = (async (): Promise<WholeFileDiff> => {
    const res = await api.getGitWholeFileDiff(cwd, path, staged)
    const entry = res.diffs.find((d) => d.path === path)
    // A missing entry is a REFUSAL, not a clean file. The server answers a whole-file request for a
    // path it could not diff with an empty list, and "empty list" rendered as "no changes" would be
    // the exact lie this view exists to prevent.
    const refused = res.whole_file_refused === true || !entry
    const parsed = refused ? null : parseUnifiedDiff(entry.diff_content)
    const value: WholeFileDiff = {
      lines: parsed?.lines ?? [],
      added: parsed?.added ?? 0,
      removed: parsed?.removed ?? 0,
      refused,
    }
    remember(key, value)
    return value
  })()

  inFlight.set(key, request)
  try {
    return await request
  } finally {
    // Cleared on both paths, so a failed fetch does not poison the next
    // attempt (and does not wedge a stale rejected promise in the map).
    inFlight.delete(key)
  }
}

/** Synchronous cache read — `null` when this path was never fetched. */
export function readWholeFileDiff(
  cwd: string,
  path: string,
  staged: boolean,
): WholeFileDiff | null {
  const hit = cache.get(cacheKey(cwd, path, staged))
  if (!hit) return null
  if (Date.now() - hit.at >= TTL_MS) return null
  return hit.value
}

/** Test-only escape hatch: the cache is module-level on purpose. */
export function clearWholeFileDiffCache(): void {
  cache.clear()
  inFlight.clear()
}
