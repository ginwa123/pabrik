/** Shared PR-status fetch for kanban card git-branch badges. Problem: a board mounts ~140 cards at
 * once and every card fired its own `GET /api/git/pr/status` (one `gh pr view` subprocess each). */
import { Cause, Data, Effect } from 'effect'
import { ApiError, getPrStatus } from '../api'
import { describeCause } from './effectRuntime'
// Type-only: the bus is passed in by the owner (App.vue), so this module never
// reaches into the SSE singleton itself.
import type { SseBus } from './sseBus'

const TTL_MS = 60_000
const SETTLED_TTL_MS = 10 * 60_000
const MAX_RETRIES = 2
const RETRY_DELAYS_MS = [300, 900]

export interface PrInfo {
  status: string
  prUrl: string
  mergeable: string
  merge_state: string
  /** `true` = the forge has a change request for this branch, `false` = it answered that there is
   * none, `null` = the question is still open (failed fetch, or no answer yet). */
  hasPr: boolean | null
}

interface CacheEntry {
  info: PrInfo
  at: number
  ttl: number
}

/** CONFLICTING (or DIRTY) means the PR cannot merge until conflicts resolve. */
export function isPrConflictValue(mergeable: string, merge_state: string): boolean {
  if ((mergeable || '').toUpperCase() === 'CONFLICTING') return true
  if ((merge_state || '').toUpperCase() === 'DIRTY') return true
  // GitLab's `detailed_merge_status` uses its own vocabulary rather than
  // GitHub's; without these two rows a conflicted MR renders as
  // mergeable, which is the worst possible direction to be wrong in.
  if ((mergeable || '').toUpperCase() === 'CONFLICTED') return true
  if ((mergeable || '').toUpperCase() === 'NOT_MERGEABLE') return true
  return false
}

const cache = new Map<string, CacheEntry>()
const inflight = new Map<string, Promise<PrInfo>>()
/** Per-key generation, bumped by `invalidatePrStatus`. */
const epoch = new Map<string, number>()

function bumpEpoch(k: string): void {
  epoch.set(k, (epoch.get(k) ?? 0) + 1)
}

/** Test-only escape hatch — clears the TTL cache, in-flight map and epochs. */
export function clearPrStatusCache(): void {
  cache.clear()
  inflight.clear()
  epoch.clear()
}

/** The (cwd, branch) pair an invalidation dropped — exactly the pair a badge
 * holds, so a consumer can skip work that is not about it. */
export interface PrStatusInvalidation {
  cwd: string
  branch: string
}

const invalidationSubscribers = new Set<(change: PrStatusInvalidation) => void>()

/** A registered badge threw while re-reading. Reported, never propagated: the
 * invalidation may be running inside a merge that already succeeded. */
class PrStatusSubscriberError extends Data.TaggedError('PrStatusSubscriberError')<{
  readonly reason: string
}> {}

/** Register `cb` to run whenever a cached answer is invalidated, with the (cwd, branch) it was for.
 * Returns the unsubscribe handle — call it from `onUnmounted`. */
export function onPrStatusInvalidated(cb: (change: PrStatusInvalidation) => void): () => void {
  invalidationSubscribers.add(cb)
  return () => {
    invalidationSubscribers.delete(cb)
  }
}

/** Drop every cached answer for one repo + branch so the next fetch re-asks the forge, and tell the
 * registered badges to re-read. */
export function invalidatePrStatus(cwd: string, branch: string): void {
  if (!cwd || !branch) return
  const prefix = `${cwd}::${branch}::`
  const keys = new Set<string>()
  for (const k of cache.keys()) if (k.startsWith(prefix)) keys.add(k)
  for (const k of inflight.keys()) if (k.startsWith(prefix)) keys.add(k)
  for (const k of epoch.keys()) if (k.startsWith(prefix)) keys.add(k)
  for (const k of keys) {
    cache.delete(k)
    inflight.delete(k)
    bumpEpoch(k)
  }
  for (const cb of invalidationSubscribers) {
    // A buggy badge must not stop the other badges from re-reading, nor fail the merge that
    // triggered the invalidation. Each notification is its own Effect whose failure is REPORTED
    // rather than propagated — no `catch`, whose binding would be `unknown` (local/no-try-catch).
    Effect.runSync(
      Effect.try({
        try: () => cb({ cwd, branch }),
        catch: (cause) => new PrStatusSubscriberError({ reason: describeCause(Cause.fail(cause)) }),
      }).pipe(
        Effect.catchTag('PrStatusSubscriberError', (e) =>
          Effect.sync(() => {
            console.error('[pr-status] invalidation subscriber threw:', e.reason)
          }),
        ),
      ),
    )
  }
}

/**  * Provider is part of the key because one repo directory can hold branches pointing at different
 * forges, and a GitLab answer must never be served to a caller that asked for GitHub (the status
 * vocabulary differs too — GitHub reports CONFLICTING, GitLab `conflicted`). */
function cacheKey(cwd: string, branch: string, provider: string): string {
  return `${cwd}::${branch}::${provider}`
}

/** 404 means "no PR for this branch" — retrying can never help. */
function isRetryable(err: unknown): boolean {
  if (err instanceof ApiError) return err.status !== 404
  // Network abort / timeout / TypeError — transient by definition.
  return true
}

function sleep(ms: number): Promise<void> {
  return new Promise<void>((resolve) => setTimeout(resolve, ms))
}

const EMPTY_INFO: PrInfo = { status: '', prUrl: '', mergeable: '', merge_state: '', hasPr: null }

/** How long an answer may be reused. A branch the forge has no change request for, and a change
 * request that is already merged or closed, cannot answer differently in the next minute — so they
 * are kept for `SETTLED_TTL_MS` and the board stops asking the forge about them. */
function ttlFor(info: PrInfo): number {
  if (info.hasPr === false) return SETTLED_TTL_MS
  if (info.status === 'merged' || info.status === 'closed') return SETTLED_TTL_MS
  return TTL_MS
}

async function fetchWithRetry(cwd: string, branch: string, provider: string): Promise<PrInfo> {
  let lastErr: unknown = null
  for (let attempt = 0; attempt <= MAX_RETRIES; attempt++) {
    if (attempt > 0) await sleep(RETRY_DELAYS_MS[attempt - 1] ?? 1000)
    try {
      // Passing the provider lets the backend pick `glab` for a GitLab repo. Omitted when empty so
      // the backend can auto-detect from the repo's `origin` remote, which is the accurate answer
      // when the board badge has no stored provider to hand.
      const data = await getPrStatus(cwd, branch, { provider: provider || undefined })
      return {
        status: (data.status || data.state || '').toLowerCase(),
        prUrl: data.pr_url || '',
        mergeable: (data.mergeable || '').toUpperCase(),
        merge_state: (data.merge_state || '').toUpperCase(),
        hasPr: data.has_pr !== false,
      }
    } catch (err) {
      lastErr = err
      // A 404 is the pre-`has_pr` spelling of "this branch has no change request", so it is an
      // answer rather than a failure: no retry, no warning, and it is remembered as an answer.
      if (!isRetryable(err)) return { ...EMPTY_INFO, hasPr: false }
    }
  }
  console.warn(`[pr-status] giving up on branch "${branch}":`, lastErr)
  return { ...EMPTY_INFO }
}

/**  * PR status + URL for a repo + branch. Never rejects — unknown (no cwd/branch, no PR, `gh` missing,
 * fetch failing) resolves to `{ status: '', prUrl: '' }`. */
export function fetchPrInfoCached(cwd: string, branch: string, provider = ''): Promise<PrInfo> {
  if (!cwd || !branch) return Promise.resolve({ ...EMPTY_INFO })
  const k = cacheKey(cwd, branch, provider)
  const hit = cache.get(k)
  if (hit && Date.now() - hit.at < hit.ttl) return Promise.resolve({ ...hit.info })
  const ongoing = inflight.get(k)
  if (ongoing) return ongoing
  // Captured before the request goes out: an `invalidatePrStatus` that lands
  // while it is in flight moves the epoch, and the answer we are about to
  // receive predates the mutation the caller made.
  const myEpoch = epoch.get(k) ?? 0
  const p = fetchWithRetry(cwd, branch, provider).then(
    (info) => {
      if ((epoch.get(k) ?? 0) === myEpoch) {
        cache.set(k, { info, at: Date.now(), ttl: ttlFor(info) })
      }
      inflight.delete(k)
      return info
    },
    () => {
      // Defensive: fetchWithRetry never rejects, but never leak the
      // in-flight slot if that invariant ever breaks.
      inflight.delete(k)
      return { ...EMPTY_INFO }
    },
  )
  inflight.set(k, p)
  return p
}

/**  * Lowercase PR status (`open` | `merged` | `closed`) for a repo + branch, or `''` when unknown (no
 * cwd/branch, no PR, `gh` missing, or the fetch kept failing). Never rejects. */
export function fetchPrStatusCached(cwd: string, branch: string, provider = ''): Promise<string> {
  return fetchPrInfoCached(cwd, branch, provider).then((info) => info.status)
}

/** Full cached PR status including the mergeable flag, so card/row badges
 * can surface a conflict hint without an extra `gh` call. Never rejects. */
export function fetchPrStatusFullCached(
  cwd: string,
  branch: string,
  provider = '',
): Promise<PrInfo> {
  return fetchPrInfoCached(cwd, branch, provider)
}

/**  * Cached conflict flag for a repo + branch. True only when the PR reports CONFLICTING (or DIRTY) —
 * quiet (false) for mergeable, unknown, or failed fetches. Never rejects. */
export function fetchPrConflictCached(
  cwd: string,
  branch: string,
  provider = '',
): Promise<boolean> {
  return fetchPrInfoCached(cwd, branch, provider).then((info) =>
    isPrConflictValue(info.mergeable, info.merge_state),
  )
}

/** The two URL shapes that identify a change-request, longest first so a
 * GitLab `/-/merge_requests/` URL is not mistaken for something else. */
const PR_URL_MARKERS = ['/-/merge_requests/', '/pull/'] as const

/** Wire the `git_pr_state` SSE channel (see src/agentic_loop/git_pr_state_events.zig) into this
 * cache. Call ONCE, from `App.vue`, next to `installSseBus()`. */
export function subscribePrStatusEvents(bus: SseBus): () => void {
  return bus.on('gitPrState', (event) => {
    invalidatePrStatus(event.cwd, event.branch)
  })
}

/** The path segment GitLab uses between the repo and the branch (GitHub has none). */
const GITLAB_TREE_SEGMENT = '/-/tree/'

/** Which forge a PR/MR URL belongs to: `github`, `gitlab`, or `''` when unrecognised. */
export function providerFromPrUrl(prUrl: string): string {
  if (!prUrl) return ''
  const idx = earliestMarkerIndex(prUrl)
  if (idx < 0) return ''
  return prUrl.slice(idx).startsWith('/-/merge_requests/') ? 'gitlab' : 'github'
}

/** Index of the earliest PR marker in `prUrl`, or -1 when there is none. */
function earliestMarkerIndex(prUrl: string): number {
  let best = -1
  for (const m of PR_URL_MARKERS) {
    const at = prUrl.indexOf(m)
    if (at >= 0 && (best < 0 || at < best)) best = at
  }
  return best
}

/** Repo base derived from a PR/MR URL — the part before the change-request segment:
 * `https://github.com/owner/repo` from `…/owner/repo/pull/123`, and
 * `https://gitlab.com/group/sub/repo` from `…/group/sub/repo/-/merge_requests/7`. */
export function repoBaseFromPrUrl(prUrl: string): string {
  if (!prUrl) return ''
  const idx = earliestMarkerIndex(prUrl)
  if (idx < 0) return ''
  return prUrl.slice(0, idx)
}

/** Branch page URL derived from the PR URL's repo base. The `/tree/` vs `/-/tree/` split is not
 * cosmetic: GitLab puts a `/-/` discriminator before sub-paths, so a GitHub-shaped link on a GitLab
 * repo is a 404. */
export function branchUrlFromPrUrl(prUrl: string, branch: string): string {
  const base = repoBaseFromPrUrl(prUrl)
  if (!base || !branch) return ''
  const tree = providerFromPrUrl(prUrl) === 'gitlab' ? GITLAB_TREE_SEGMENT : '/tree/'
  return `${base}${tree}${encodeURIComponent(branch)}`
}
