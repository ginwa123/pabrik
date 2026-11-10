import type { GitPrChecks, GitPrChecksSummary } from '../api'

export type CiVerdict = 'pass' | 'fail' | 'pending' | 'empty'

export type CiWatchOutcome = 'pass' | 'fail' | 'timeout' | 'cancelled' | 'error'

export interface CiWatchTick {
  polls: number
  summary: GitPrChecksSummary
  verdict: CiVerdict
}

export interface CiWatchResult {
  outcome: CiWatchOutcome
  summary: GitPrChecksSummary | null
  polls: number
  error: string | null
}

/** The failure is in the type, not in a `try`: a watch that could not read the
 *  forge must be distinguishable from one that read a green run. */
export type CiFetchResult =
  | { ok: true; checks: GitPrChecks }
  | { ok: false; error: string }

export interface CiWatchOptions {
  fetchChecks: () => Promise<CiFetchResult>
  sleep: (ms: number) => Promise<void>
  intervalMs?: number
  deadlineMs?: number
  onTick?: (tick: CiWatchTick) => void
  shouldStop?: () => boolean
}

export const CI_WATCH_INTERVAL_MS = 10_000
export const CI_WATCH_DEADLINE_MS = 15 * 60_000

const plural = (n: number, word: string) => `${n} ${word}${n === 1 ? '' : 's'}`

export function ciVerdict(summary: GitPrChecksSummary | null | undefined): CiVerdict {
  if (!summary || summary.total <= 0) return 'empty'
  if (summary.failed > 0 || summary.cancelled > 0) return 'fail'
  if (summary.pending > 0) return 'pending'
  return 'pass'
}

export function ciProgressLine(summary: GitPrChecksSummary | null | undefined): string {
  if (!summary || summary.total <= 0) return 'no checks reported yet'
  const total = plural(summary.total, 'check')
  if (summary.failed > 0) return `${summary.failed} of ${total} failed`
  if (summary.cancelled > 0) return `${summary.cancelled} of ${total} cancelled`
  if (summary.pending > 0) {
    const done = summary.passed + summary.skipped
    return `${done} of ${total} passed · ${summary.pending} running`
  }
  return `all ${total} passed`
}

export function ciWatchResultLine(result: CiWatchResult): string {
  switch (result.outcome) {
    case 'pass':
      return 'All checks passed — ready to merge'
    case 'fail':
      return `CI failed — ${ciProgressLine(result.summary)}`
    case 'timeout':
      return `Still not green after ${Math.round(CI_WATCH_DEADLINE_MS / 60_000)} min — ${ciProgressLine(result.summary)}`
    case 'cancelled':
      return 'Stopped watching CI'
    case 'error':
      return `Could not read CI checks — ${result.error ?? 'unknown error'}`
  }
}

export async function watchCiChecks(opts: CiWatchOptions): Promise<CiWatchResult> {
  const intervalMs = opts.intervalMs ?? CI_WATCH_INTERVAL_MS
  const deadlineMs = opts.deadlineMs ?? CI_WATCH_DEADLINE_MS
  let polls = 0
  let elapsed = 0
  let last: GitPrChecksSummary | null = null

  for (;;) {
    if (opts.shouldStop?.()) {
      return { outcome: 'cancelled', summary: last, polls, error: null }
    }
    const fetched = await opts.fetchChecks()
    if (!fetched.ok) {
      return { outcome: 'error', summary: last, polls, error: fetched.error }
    }
    polls += 1
    last = fetched.checks.summary
    const verdict = ciVerdict(fetched.checks.summary)
    opts.onTick?.({ polls, summary: fetched.checks.summary, verdict })
    if (verdict === 'pass') return { outcome: 'pass', summary: last, polls, error: null }
    if (verdict === 'fail') return { outcome: 'fail', summary: last, polls, error: null }
    if (elapsed + intervalMs > deadlineMs) {
      return { outcome: 'timeout', summary: last, polls, error: null }
    }
    await opts.sleep(intervalMs)
    elapsed += intervalMs
  }
}
