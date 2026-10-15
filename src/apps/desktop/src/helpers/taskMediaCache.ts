/**
 * Persistent local cache for kanban task media (`GET .../tasks/:id/media`).
 *
 * Stale-while-revalidate: after the flag-only task list lands, cards paint
 * the last-known thumbnails synchronously (no network wait), then the
 * store revalidates in the background via the media endpoint and
 * write-throughs the fresh payload here. There is deliberately NO TTL —
 * a stale thumb beats the `has media` badge for the second the fetch is
 * in flight, and every list load is followed by a real revalidate anyway.
 *
 * localStorage (not module memory alone): the point is surviving a full
 * page reload — the cold-boot case where every card would otherwise show
 * the badge until N media round-trips land. Unlike the tiny workspace
 * rows, entries are base64 `data:` URLs that can reach MBs, so this
 * helper carries two guards `workspacesCache` doesn't need:
 *   - per-entry size cap (`MAX_ENTRY_CHARS`) — oversized payloads are
 *     never persisted (the live fetch still works, only the next
 *     cold boot's instant paint for that task is lost);
 *   - entry cap with oldest-eviction (`MAX_ENTRIES`) + quota failure
 *     recovery (drop the namespace, retry once, then give up silent).
 *
 * A module-memory memo sits in front of storage: parsing a multi-MB
 * JSON blob once per page load instead of once per card keeps mount
 * cheap. Writes go to both layers (write-through).
 *
 * Fail-silent: every storage access is wrapped, so private mode,
 * quota errors, or a missing `localStorage` (vitest/jsdom setups that
 * don't provide one) degrade to a plain cache miss.
 */
export interface CachedTaskMedia {
  imageUrls: string[]
  videoUrls: string[]
}

import { userScopedKey } from './userScope'

const TASK_MEDIA_CACHE_KEY = 'pabrik-task-media:v1'
// Largest single-task payload we'll persist (~1.5MB serialized — a
// phone-photo base64 can exceed this; skipping it only loses the
// instant paint, never correctness).
const MAX_ENTRY_CHARS = 1_500_000
// Oldest-evicted bound so one media-heavy board can't grow the blob
// without limit (insertion-ordered Map = oldest first).
const MAX_ENTRIES = 100

let memCache: Map<string, CachedTaskMedia> | null = null

/**
 * Normalizes one stored entry into paintable media. Requires arrays of
 * non-empty strings; filters out anything else. Returns null when
 * nothing paintable remains, so corrupt entries can never produce a
 * broken `<img>` where the badge should be.
 */
function normalizeEntry(raw: unknown): CachedTaskMedia | null {
  if (!raw || typeof raw !== 'object') return null
  const e = raw as Record<string, unknown>
  const clean = (v: unknown): string[] =>
    Array.isArray(v) ? v.filter((s): s is string => typeof s === 'string' && s.length > 0) : []
  const imageUrls = clean(e.imageUrls)
  const videoUrls = clean(e.videoUrls)
  if (imageUrls.length === 0 && videoUrls.length === 0) return null
  return { imageUrls, videoUrls }
}

/** Parses the stored blob into the memo (once per page load). Never throws. */
function loadAll(): Map<string, CachedTaskMedia> {
  if (memCache) return memCache
  const out = new Map<string, CachedTaskMedia>()
  try {
    const raw = localStorage.getItem(userScopedKey(TASK_MEDIA_CACHE_KEY))
    if (raw !== null) {
      const parsed: unknown = JSON.parse(raw)
      if (parsed && typeof parsed === 'object') {
        for (const [id, entry] of Object.entries(parsed as Record<string, unknown>)) {
          const clean = normalizeEntry(entry)
          if (clean) out.set(id, clean)
        }
      }
    }
  } catch {
    // corrupt blob / no storage — plain miss, memo stays empty.
  }
  memCache = out
  return out
}

/** Serializes the memo to storage with quota recovery. Never throws. */
function persist(): void {
  if (!memCache) return
  try {
    localStorage.setItem(userScopedKey(TASK_MEDIA_CACHE_KEY), JSON.stringify(Object.fromEntries(memCache)))
  } catch {
    try {
      // Quota hit: drop the whole media namespace and retry once with just the current memo (which
      // the cap below already trimmed). If that still fails (private mode), the session memo still
      // serves instant paints until reload.
      localStorage.removeItem(userScopedKey(TASK_MEDIA_CACHE_KEY))
      localStorage.setItem(userScopedKey(TASK_MEDIA_CACHE_KEY), JSON.stringify(Object.fromEntries(memCache)))
    } catch {
      /* live fetch still works — only the next cold boot loses paint */
    }
  }
}

/** Last-known media for a task, or null on miss / corrupt entry / no storage. */
export function readTaskMediaCache(taskId: string): CachedTaskMedia | null {
  try {
    return loadAll().get(taskId) ?? null
  } catch {
    return null
  }
}

/**
 * Persists a successful media fetch (write-through: memo + storage).
 * Oversized payloads are skipped silently. Never throws.
 */
export function writeTaskMediaCache(taskId: string, media: CachedTaskMedia): void {
  try {
    const clean = normalizeEntry(media)
    if (!clean) return
    if (JSON.stringify(clean).length > MAX_ENTRY_CHARS) return
    const all = loadAll()
    // Refresh recency on rewrite (delete + set moves it to newest).
    all.delete(taskId)
    all.set(taskId, clean)
    while (all.size > MAX_ENTRIES) {
      const oldest = all.keys().next()
      if (oldest.done) break
      all.delete(oldest.value)
    }
    persist()
  } catch {
    /* see persist */
  }
}

/** Test-only escape hatch — drops the cached media (memo + storage). */
export function clearTaskMediaCache(): void {
  memCache = null
  try {
    localStorage.removeItem(userScopedKey(TASK_MEDIA_CACHE_KEY))
  } catch {
    /* see persist */
  }
}

/**
 * Test-only escape hatch — drops the in-memory memo WITHOUT touching
 * storage, so tests can stage raw blobs and exercise the parse path
 * step by step (the memo would otherwise pin the first parse).
 */
export function resetTaskMediaCacheMemo(): void {
  memCache = null
}

/** Test-only escape hatch — exposes the storage key for corrupt-blob tests. */
export function taskMediaCacheKey(): string {
  return TASK_MEDIA_CACHE_KEY
}
