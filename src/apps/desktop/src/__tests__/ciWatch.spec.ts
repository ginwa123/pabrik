import { describe, expect, it } from 'vitest'
import {
  CI_WATCH_DEADLINE_MS,
  CI_WATCH_INTERVAL_MS,
  ciProgressLine,
  ciVerdict,
  ciWatchResultLine,
  watchCiChecks,
  type CiFetchResult,
  type CiWatchResult,
} from '../helpers/ciWatch'
import type { GitPrChecks, GitPrChecksSummary } from '../api'

function summary(over: Partial<GitPrChecksSummary> = {}): GitPrChecksSummary {
  const s: GitPrChecksSummary = {
    total: 0,
    passed: 0,
    failed: 0,
    pending: 0,
    skipped: 0,
    cancelled: 0,
    ...over,
  }
  s.total = over.total ?? s.passed + s.failed + s.pending + s.skipped + s.cancelled
  return s
}

const payload = (s: GitPrChecksSummary): GitPrChecks => ({
  provider: 'github',
  pr_url: 'https://github.com/ginwa123/pabrik/pull/891',
  checks: [],
  summary: s,
  steps_truncated: false,
})

function scripted(steps: Array<GitPrChecksSummary | Error>) {
  const calls: number[] = []
  const fetchChecks = async (): Promise<CiFetchResult> => {
    const next = steps[calls.length]
    calls.push(calls.length)
    if (next === undefined) return { ok: false, error: 'script exhausted' }
    if (next instanceof Error) return { ok: false, error: next.message }
    return { ok: true, checks: payload(next) }
  }
  return { fetchChecks, calls }
}

function fakeSleep() {
  const waits: number[] = []
  return { sleep: async (ms: number) => void waits.push(ms), waits }
}

describe('ciVerdict', () => {
  it('is empty when the forge reported no checks at all', () => {
    expect(ciVerdict(null)).toBe('empty')
    expect(ciVerdict(summary())).toBe('empty')
  })

  it('is pass when every check passed or was skipped', () => {
    expect(ciVerdict(summary({ passed: 4, skipped: 1 }))).toBe('pass')
  })

  it('is pending while any check is still running', () => {
    expect(ciVerdict(summary({ passed: 2, pending: 1 }))).toBe('pending')
  })

  it('is fail when a check failed', () => {
    expect(ciVerdict(summary({ passed: 2, failed: 1 }))).toBe('fail')
  })

  it('is fail when a check was cancelled, because that is not a green run', () => {
    expect(ciVerdict(summary({ passed: 2, cancelled: 1 }))).toBe('fail')
  })
})

describe('ciProgressLine', () => {
  it('says nothing has been reported yet when the list is empty', () => {
    expect(ciProgressLine(null)).toBe('no checks reported yet')
    expect(ciProgressLine(summary())).toBe('no checks reported yet')
  })

  it('counts the finished checks against the total while others run', () => {
    expect(ciProgressLine(summary({ passed: 3, pending: 2 }))).toBe('3 of 5 checks passed · 2 running')
  })

  it('counts skipped checks as finished, so the numbers add up', () => {
    expect(ciProgressLine(summary({ passed: 2, skipped: 1, pending: 1 }))).toBe(
      '3 of 4 checks passed · 1 running',
    )
  })

  it('names the failures instead of the progress when something is red', () => {
    expect(ciProgressLine(summary({ passed: 3, failed: 2 }))).toBe('2 of 5 checks failed')
  })

  it('names cancellations when nothing failed but a run was cancelled', () => {
    expect(ciProgressLine(summary({ passed: 3, cancelled: 1 }))).toBe('1 of 4 checks cancelled')
  })

  it('says all passed when the run is green', () => {
    expect(ciProgressLine(summary({ passed: 5 }))).toBe('all 5 checks passed')
  })

  it('keeps a single check singular', () => {
    expect(ciProgressLine(summary({ passed: 1 }))).toBe('all 1 check passed')
  })
})

describe('watchCiChecks', () => {
  it('returns pass on the first poll when the checks are already green', async () => {
    const { fetchChecks, calls } = scripted([summary({ passed: 3 })])
    const { sleep, waits } = fakeSleep()

    const result = await watchCiChecks({ fetchChecks, sleep })

    expect(result.outcome).toBe('pass')
    expect(result.polls).toBe(1)
    expect(calls).toHaveLength(1)
    expect(waits).toEqual([])
  })

  it('keeps polling while checks are running and stops the moment they all pass', async () => {
    const { fetchChecks, calls } = scripted([
      summary({ passed: 1, pending: 2 }),
      summary({ passed: 2, pending: 1 }),
      summary({ passed: 3 }),
    ])
    const { sleep, waits } = fakeSleep()

    const result = await watchCiChecks({ fetchChecks, sleep, intervalMs: 1000 })

    expect(result.outcome).toBe('pass')
    expect(result.polls).toBe(3)
    expect(calls).toHaveLength(3)
    expect(waits).toEqual([1000, 1000])
  })

  it('stops on the first failure instead of waiting for the rest of the run', async () => {
    const { fetchChecks, calls } = scripted([
      summary({ passed: 1, pending: 1 }),
      summary({ passed: 1, failed: 1, pending: 1 }),
      summary({ passed: 3 }),
    ])
    const { sleep, waits } = fakeSleep()

    const result = await watchCiChecks({ fetchChecks, sleep, intervalMs: 1000 })

    expect(result.outcome).toBe('fail')
    expect(result.polls).toBe(2)
    expect(calls).toHaveLength(2)
    expect(waits).toEqual([1000])
  })

  it('keeps waiting when the forge has not registered any check yet', async () => {
    const { fetchChecks } = scripted([summary(), summary(), summary({ passed: 1 })])
    const { sleep } = fakeSleep()

    const result = await watchCiChecks({ fetchChecks, sleep, intervalMs: 1000 })

    expect(result.outcome).toBe('pass')
    expect(result.polls).toBe(3)
  })

  it('gives up at the deadline and reports the last summary it saw', async () => {
    const pending = summary({ passed: 1, pending: 1 })
    const { fetchChecks, calls } = scripted([pending, pending, pending, pending, pending])
    const { sleep, waits } = fakeSleep()

    const result = await watchCiChecks({ fetchChecks, sleep, intervalMs: 1000, deadlineMs: 2000 })

    expect(result.outcome).toBe('timeout')
    expect(result.summary).toEqual(pending)
    expect(result.polls).toBe(3)
    expect(calls).toHaveLength(3)
    expect(waits).toEqual([1000, 1000])
  })

  it('polls once even with a zero deadline, so a green run is never reported as a timeout', async () => {
    const { fetchChecks } = scripted([summary({ passed: 1 })])
    const { sleep } = fakeSleep()

    const result = await watchCiChecks({ fetchChecks, sleep, deadlineMs: 0 })

    expect(result.outcome).toBe('pass')
    expect(result.polls).toBe(1)
  })

  it('stops when the caller asks it to, and keeps the last summary', async () => {
    const { fetchChecks, calls } = scripted([summary({ passed: 1, pending: 1 }), summary({ passed: 2 })])
    const { sleep } = fakeSleep()
    let stop = false

    const result = await watchCiChecks({
      fetchChecks,
      sleep,
      intervalMs: 1000,
      shouldStop: () => stop,
      onTick: () => {
        stop = true
      },
    })

    expect(result.outcome).toBe('cancelled')
    expect(result.polls).toBe(1)
    expect(result.summary).toEqual(summary({ passed: 1, pending: 1 }))
    expect(calls).toHaveLength(1)
  })

  it('reports a fetch failure as an error carrying the server sentence', async () => {
    const { fetchChecks } = scripted([new Error('gh CLI not found on PATH')])
    const { sleep } = fakeSleep()

    const result = await watchCiChecks({ fetchChecks, sleep })

    expect(result.outcome).toBe('error')
    expect(result.error).toBe('gh CLI not found on PATH')
    expect(result.polls).toBe(0)
  })

  it('reports every poll to the caller so the UI can show live progress', async () => {
    const { fetchChecks } = scripted([
      summary({ passed: 1, pending: 1 }),
      summary({ passed: 2 }),
    ])
    const { sleep } = fakeSleep()
    const ticks: Array<{ polls: number; verdict: string }> = []

    await watchCiChecks({
      fetchChecks,
      sleep,
      intervalMs: 1000,
      onTick: (t) => ticks.push({ polls: t.polls, verdict: t.verdict }),
    })

    expect(ticks).toEqual([
      { polls: 1, verdict: 'pending' },
      { polls: 2, verdict: 'pass' },
    ])
  })

  it('defaults to a 10 s interval and a 15 min deadline', () => {
    expect(CI_WATCH_INTERVAL_MS).toBe(10_000)
    expect(CI_WATCH_DEADLINE_MS).toBe(900_000)
  })
})

describe('ciWatchResultLine', () => {
  const result = (over: Partial<CiWatchResult>): CiWatchResult => ({
    outcome: 'pass',
    summary: null,
    polls: 1,
    error: null,
    ...over,
  })

  it('says the merge is ready when the watch passed', () => {
    expect(ciWatchResultLine(result({ outcome: 'pass' }))).toBe('All checks passed — ready to merge')
  })

  it('names the failure count when CI went red', () => {
    expect(
      ciWatchResultLine(result({ outcome: 'fail', summary: summary({ passed: 2, failed: 1 }) })),
    ).toBe('CI failed — 1 of 3 checks failed')
  })

  it('says how long it waited when it timed out', () => {
    expect(
      ciWatchResultLine(result({ outcome: 'timeout', summary: summary({ passed: 1, pending: 1 }) })),
    ).toBe('Still not green after 15 min — 1 of 2 checks passed · 1 running')
  })

  it('says it stopped when the user cancelled', () => {
    expect(ciWatchResultLine(result({ outcome: 'cancelled' }))).toBe('Stopped watching CI')
  })

  it('carries the server sentence when the checks could not be read', () => {
    expect(ciWatchResultLine(result({ outcome: 'error', error: 'boom' }))).toBe(
      'Could not read CI checks — boom',
    )
  })
})
