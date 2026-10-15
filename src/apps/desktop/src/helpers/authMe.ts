/**
 * Cached client for `GET /api/auth/me`.
 *
 * Why this exists: the router guard `await`s `/api/auth/me` on EVERY
 * navigation (plus `LoginView` on mount, plus `Sidebar` on mount and
 * every window focus) with a bare `fetch` — no cache, no timeout. The
 * handler itself is trivial (one indexed SELECT, ~7ms even against a
 * 3GB DB), but all SQLite access serializes on a single global
 * `SqliteBackend` mutex, so on a busy boot (~20 concurrent git-status /
 * diff / messages requests) `/me` queues behind seconds of heavy
 * queries and the navigation stalls for ~20s. A slow `/me` must never
 * block a view switch.
 *
 * Contract (stale-while-revalidate, fail-silent):
 * - Fresh cache (< TTL) returns synchronously without network.
 * - Stale cache returns immediately AND revalidates in the background.
 * - No cache awaits one live fetch (concurrent callers share it via
 *   `inflight` dedup) with a 4s timeout; on failure the guard's
 *   existing fail-open path runs (let the view render).
 * - localStorage (not just module memory) so a full page reload — the
 *   cold-cache case that hurt most — still paints from the last-known
 *   state and revalidates behind it.
 * - `invalidateAuthMe()` on login/logout so the next guard sees the
 *   new session instead of the pre-login 401 (or post-logout user).
 *
 * Stale-auth risk is bounded: TTL is 30s, logout invalidates, and a
 * wrongly-admitted view still 401s on its own data fetches (apiFetch
 * bounces those to /login). The guard already fails open on network
 * errors, so serving a seconds-old decision matches existing behavior.
 */
export interface AuthMeUser {
  id: string
  email: string
  name: string
  role: string
}

export interface AuthMeData {
  authenticated: boolean
  auth_enabled: boolean
  user?: AuthMeUser
}

export interface AuthMeResult {
  /** HTTP status of the live response; 0 = network/abort (no response). */
  status: number
  /** Parsed body, or null on !ok / parse failure / network error. */
  data: AuthMeData | null
  /** True when served from cache without a network round-trip. */
  fromCache: boolean
}

const AUTH_ME_KEY = 'pabrik-auth-me:v1'
const AUTH_ME_TTL_MS = 30_000
const AUTH_ME_TIMEOUT_MS = 4_000

interface CacheEntry {
  status: number
  data: AuthMeData | null
  at: number
}

function normalizeAuthMe(raw: unknown): AuthMeData | null {
  if (!raw || typeof raw !== 'object') return null
  const d = raw as Record<string, unknown>
  if (typeof d.authenticated !== 'boolean') return null
  if (typeof d.auth_enabled !== 'boolean') return null
  const out: AuthMeData = { authenticated: d.authenticated, auth_enabled: d.auth_enabled }
  if (d.user && typeof d.user === 'object') {
    const u = d.user as Record<string, unknown>
    out.user = {
      id: typeof u.id === 'string' ? u.id : '',
      email: typeof u.email === 'string' ? u.email : '',
      name: typeof u.name === 'string' ? u.name : '',
      role: typeof u.role === 'string' ? u.role : '',
    }
  }
  return out
}

function readEntry(): CacheEntry | null {
  try {
    const raw = localStorage.getItem(AUTH_ME_KEY)
    if (raw === null) return null
    const parsed = JSON.parse(raw) as Partial<CacheEntry> & { data?: unknown }
    if (typeof parsed.at !== 'number' || typeof parsed.status !== 'number') return null
    const data = parsed.data === null ? null : normalizeAuthMe(parsed.data)
    // normalizeAuthMe rejects garbage; a non-null data that fails to
    // normalize means a corrupt entry (fail-silent miss), except an
    // explicit null body which is a legitimate cached !ok response.
    if (parsed.data !== null && parsed.data !== undefined && data === null) return null
    return { status: parsed.status, data, at: parsed.at }
  } catch {
    return null
  }
}

function writeEntry(status: number, data: AuthMeData | null): void {
  try {
    const entry: CacheEntry = { status, data, at: Date.now() }
    localStorage.setItem(AUTH_ME_KEY, JSON.stringify(entry))
  } catch {
    // quota / private mode / no storage — the live fetch still works,
    // only the next init's instant paint is lost.
  }
}

/** Drops the cached `/me` response (memory + storage). Call on login/logout. */
export function invalidateAuthMe(): void {
  inflight = null
  try {
    localStorage.removeItem(AUTH_ME_KEY)
  } catch {
    /* no storage — nothing to clear */
  }
}

/** Test-only escape hatch — same as invalidate without touching inflight. */
export function clearAuthMeCache(): void {
  try {
    localStorage.removeItem(AUTH_ME_KEY)
  } catch {
    /* no storage (vitest without jsdom localStorage) */
  }
}

function timeoutSignal(ms: number): { signal: AbortSignal | undefined; done: () => void } {
  const g = globalThis as { AbortSignal?: typeof AbortSignal }
  if (g.AbortSignal && typeof g.AbortSignal.timeout === 'function') {
    return { signal: g.AbortSignal.timeout(ms), done: () => {} }
  }
  if (typeof AbortController !== 'undefined') {
    const c = new AbortController()
    const id = setTimeout(() => c.abort(), ms)
    return { signal: c.signal, done: () => clearTimeout(id) }
  }
  return { signal: undefined, done: () => {} }
}

/** One live `GET /api/auth/me` round-trip. Never throws — network/abort yields status 0. */
export async function fetchAuthMeLive(
  timeoutMs: number = AUTH_ME_TIMEOUT_MS,
): Promise<AuthMeResult> {
  const { signal, done } = timeoutSignal(timeoutMs)
  try {
    const res = await fetch('/api/auth/me', { credentials: 'same-origin', signal })
    if (!res.ok) return { status: res.status, data: null, fromCache: false }
    const data = normalizeAuthMe(await res.json().catch(() => null))
    return { status: res.status, data, fromCache: false }
  } catch {
    return { status: 0, data: null, fromCache: false }
  } finally {
    done()
  }
}

let inflight: Promise<AuthMeResult> | null = null

function fetchShared(): Promise<AuthMeResult> {
  if (!inflight) {
    inflight = fetchAuthMeLive().finally(() => {
      inflight = null
    })
  }
  return inflight
}

/**  * Cached `/me` for navigation guards and chrome (sidebar/login). Fresh cache hits never touch the
 * network; stale entries are served instantly with a background revalidate; cold starts share one
 * live fetch across concurrent callers. */
export async function getAuthMeCached(): Promise<AuthMeResult> {
  const cached = readEntry()
  if (cached) {
    if (Date.now() - cached.at < AUTH_ME_TTL_MS) {
      return { status: cached.status, data: cached.data, fromCache: true }
    }
    // Stale: serve now, revalidate behind. Fail-silent by design.
    fetchShared().then(
      (r) => {
        if (r.status !== 0) writeEntry(r.status, r.data)
      },
      () => {},
    )
    return { status: cached.status, data: cached.data, fromCache: true }
  }
  const live = await fetchShared()
  if (live.status !== 0) writeEntry(live.status, live.data)
  return live
}
