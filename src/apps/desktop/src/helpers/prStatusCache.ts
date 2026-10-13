/**
 * Shared PR-status fetch for kanban card git-branch badges.
 *
 * Problem: a board mounts ~140 cards at once and every card fired its
 * own `GET /api/git/pr/status` (one `gh pr view` subprocess each).
 * Under that burst, transient failures (timeouts, 429/5xx from the
 * API) were common — and with no retry the badge stayed grey forever.
 *
 * This module collapses the burst:
 *   - in-flight dedupe: simultaneous callers for the same
 *     `cwd::branch` share one request (141 cards → ~30 unique
 *     branches → ~30 requests).
 *   - 60s TTL cache: remounts / "Load more" pages reuse the result
 *     instead of re-hammering `gh`. A merged PR shows its color on
 *     the next fetch after the TTL expires.
 *   - retry with backoff (2 retries): transient failures get a second
 *     chance. 404 (no PR for the branch — e.g. `main`) is
 *     deterministic and is NOT retried.
 *
 * Fail-silent contract is preserved: total failure resolves to `''`
 * and the card keeps its current dim look. Final failures go to
 * `console.warn` (devtools only) so the next grey-icon report comes
 * with evidence instead of silence.
 */
import { ApiError, getPrStatus } from '../api'

const TTL_MS = 60_000
const MAX_RETRIES = 2
const RETRY_DELAYS_MS = [300, 900]

export interface PrInfo {
  status: string
  prUrl: string
  mergeable: string
  merge_state: string
}

interface CacheEntry {
  status: string
  prUrl: string
  mergeable: string
  merge_state: string
  at: number
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

/** Test-only escape hatch — clears both the TTL cache and in-flight map. */
export function clearPrStatusCache(): void {
  cache.clear()
  inflight.clear()
}

/**
 * Drop one repo + branch entry so the next fetch re-asks the forge.
 * Called after a close from the board-level PR list: the badge would
 * otherwise keep its stale `open` color until the 60s TTL expires.
 * The in-flight slot is dropped too — a close that lands mid-fetch
 * must not let the stale answer populate the cache afterwards.
 */
export function invalidatePrStatus(cwd: string, branch: string, provider = ''): void {
  const k = cacheKey(cwd, branch, provider)
  cache.delete(k)
  inflight.delete(k)
}

/**
 * Provider is part of the key because one repo directory can hold
 * branches pointing at different forges, and a GitLab answer must never
 * be served to a caller that asked for GitHub (the status vocabulary
 * differs too — GitHub reports CONFLICTING, GitLab `conflicted`).
 */
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

const EMPTY_INFO: PrInfo = { status: '', prUrl: '', mergeable: '', merge_state: '' }

async function fetchWithRetry(cwd: string, branch: string, provider: string): Promise<PrInfo> {
  let lastErr: unknown = null
  for (let attempt = 0; attempt <= MAX_RETRIES; attempt++) {
    if (attempt > 0) await sleep(RETRY_DELAYS_MS[attempt - 1] ?? 1000)
    try {
      // Passing the provider lets the backend pick `glab` for a GitLab
      // repo. Omitted when empty so the backend can auto-detect from the
      // repo's `origin` remote, which is the accurate answer when the
      // board badge has no stored provider to hand.
      const data = await getPrStatus(cwd, branch, { provider: provider || undefined })
      return {
        status: (data.status || data.state || '').toLowerCase(),
        prUrl: data.pr_url || '',
        mergeable: (data.mergeable || '').toUpperCase(),
        merge_state: (data.merge_state || '').toUpperCase(),
      }
    } catch (err) {
      lastErr = err
      if (!isRetryable(err)) break
    }
  }
  console.warn(`[pr-status] giving up on branch "${branch}":`, lastErr)
  return { ...EMPTY_INFO }
}

/**
 * PR status + URL for a repo + branch. Never rejects — unknown
 * (no cwd/branch, no PR, `gh` missing, fetch failing) resolves to
 * `{ status: '', prUrl: '' }`.
 */
export function fetchPrInfoCached(cwd: string, branch: string, provider = ''): Promise<PrInfo> {
  if (!cwd || !branch) return Promise.resolve({ ...EMPTY_INFO })
  const k = cacheKey(cwd, branch, provider)
  const hit = cache.get(k)
  if (hit && Date.now() - hit.at < TTL_MS)
    return Promise.resolve({
      status: hit.status,
      prUrl: hit.prUrl,
      mergeable: hit.mergeable,
      merge_state: hit.merge_state,
    })
  const ongoing = inflight.get(k)
  if (ongoing) return ongoing
  const p = fetchWithRetry(cwd, branch, provider).then(
    (info) => {
      cache.set(k, {
        status: info.status,
        prUrl: info.prUrl,
        mergeable: info.mergeable,
        merge_state: info.merge_state,
        at: Date.now(),
      })
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

/**
 * Lowercase PR status (`open` | `merged` | `closed`) for a repo + branch,
 * or `''` when unknown (no cwd/branch, no PR, `gh` missing, or the fetch
 * kept failing). Never rejects.
 */
export function fetchPrStatusCached(cwd: string, branch: string, provider = ''): Promise<string> {
  return fetchPrInfoCached(cwd, branch, provider).then((info) => info.status)
}

/**
 * Full cached PR status including the mergeable flag, so card/row badges
 * can surface a conflict hint without an extra `gh` call. Never rejects.
 */
export function fetchPrStatusFullCached(
  cwd: string,
  branch: string,
  provider = '',
): Promise<PrInfo> {
  return fetchPrInfoCached(cwd, branch, provider)
}

/**
 * Cached conflict flag for a repo + branch. True only when the PR reports
 * CONFLICTING (or DIRTY) — quiet (false) for mergeable, unknown, or failed
 * fetches. Never rejects.
 */
export function fetchPrConflictCached(
  cwd: string,
  branch: string,
  provider = '',
): Promise<boolean> {
  return fetchPrInfoCached(cwd, branch, provider).then((info) =>
    isPrConflictValue(info.mergeable, info.merge_state),
  )
}

/**
 * The two URL shapes that identify a change-request, longest first so a
 * GitLab `/-/merge_requests/` URL is not mistaken for something else.
 */
const PR_URL_MARKERS = ['/-/merge_requests/', '/pull/'] as const

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

/**
 * Repo base derived from a PR/MR URL — the part before the change-request
 * segment: `https://github.com/owner/repo` from
 * `…/owner/repo/pull/123`, and `https://gitlab.com/group/sub/repo` from
 * `…/group/sub/repo/-/merge_requests/7`.
 *
 * Previously this only understood `/pull/`, so it returned `''` for every
 * GitLab MR URL — which silently disabled the "open branch in new tab"
 * menu item for the entire GitLab user base rather than showing an error.
 */
export function repoBaseFromPrUrl(prUrl: string): string {
  if (!prUrl) return ''
  const idx = earliestMarkerIndex(prUrl)
  if (idx < 0) return ''
  return prUrl.slice(0, idx)
}

/**
 * Branch page URL derived from the PR URL's repo base.
 *
 * The `/tree/` vs `/-/tree/` split is not cosmetic: GitLab puts a `/-/`
 * discriminator before sub-paths, so a GitHub-shaped link on a GitLab repo
 * is a 404. Deriving the shape from the URL (rather than the provider
 * string) keeps this correct even when the caller never learned the
 * provider, e.g. a bare MR URL off the board badge.
 */
export function branchUrlFromPrUrl(prUrl: string, branch: string): string {
  const base = repoBaseFromPrUrl(prUrl)
  if (!base || !branch) return ''
  const tree = providerFromPrUrl(prUrl) === 'gitlab' ? GITLAB_TREE_SEGMENT : '/tree/'
  return `${base}${tree}${encodeURIComponent(branch)}`
}
