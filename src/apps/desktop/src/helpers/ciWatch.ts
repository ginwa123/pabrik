import type { GitPrChecksSummary } from '../api'

export type CiVerdict = 'pass' | 'fail' | 'pending' | 'empty'

export type CiWatchOutcome = 'pass' | 'fail' | 'timeout' | 'cancelled'

export interface CiWatchTick {
  updates: number
  summary: GitPrChecksSummary
  verdict: CiVerdict
}

export interface CiWatchResult {
  outcome: CiWatchOutcome
  summary: GitPrChecksSummary | null
  updates: number
}

export interface CiWatchOptions {
  readSummary: () => GitPrChecksSummary | null | undefined
  sleep: (ms: number) => Promise<void>
  tickMs?: number
  deadlineMs?: number
  onTick?: (tick: CiWatchTick) => void
  shouldStop?: () => boolean
}

export const CI_WATCH_TICK_MS = 2_000
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
  }
}

function sameRollup(a: GitPrChecksSummary | null, b: GitPrChecksSummary): boolean {
  return (
    a !== null &&
    a.total === b.total &&
    a.passed === b.passed &&
    a.failed === b.failed &&
    a.pending === b.pending &&
    a.skipped === b.skipped &&
    a.cancelled === b.cancelled
  )
}

export async function watchCiChecks(opts: CiWatchOptions): Promise<CiWatchResult> {
  const tickMs = opts.tickMs ?? CI_WATCH_TICK_MS
  const deadlineMs = opts.deadlineMs ?? CI_WATCH_DEADLINE_MS
  let updates = 0
  let elapsed = 0
  let last: GitPrChecksSummary | null = null

  for (;;) {
    if (opts.shouldStop?.()) return { outcome: 'cancelled', summary: last, updates }

    const summary = opts.readSummary() ?? null
    if (summary && !sameRollup(last, summary)) {
      updates += 1
      last = summary
      const verdict = ciVerdict(summary)
      opts.onTick?.({ updates, summary, verdict })
      if (verdict === 'pass') return { outcome: 'pass', summary, updates }
      if (verdict === 'fail') return { outcome: 'fail', summary, updates }
    }

    if (elapsed + tickMs > deadlineMs) return { outcome: 'timeout', summary: last, updates }
    await opts.sleep(tickMs)
    elapsed += tickMs
  }
}
