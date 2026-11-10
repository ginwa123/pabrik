import { describe, expect, it } from 'vitest'
import {
  CI_WATCH_DEADLINE_MS,
  CI_WATCH_TICK_MS,
  ciProgressLine,
  ciVerdict,
  ciWatchResultLine,
  watchCiChecks,
  type CiWatchResult,
} from '../helpers/ciWatch'
import type { GitPrChecksSummary } from '../api'

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

/** A getter that hands out one rollup per tick, repeating the last one. */
function scripted(steps: Array<GitPrChecksSummary | null>) {
  let reads = 0
  const readSummary = () => {
    const next = steps[Math.min(reads, steps.length - 1)]
    reads += 1
    return next
  }
  return { readSummary, reads: () => reads }
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
  it('returns pass on the first read when the checks are already green', async () => {
    const { readSummary } = scripted([summary({ passed: 3 })])
    const { sleep, waits } = fakeSleep()

    const result = await watchCiChecks({ readSummary, sleep })

    expect(result.outcome).toBe('pass')
    expect(result.updates).toBe(1)
    expect(waits).toEqual([])
  })

  it('keeps waiting while checks are running and stops the moment they all pass', async () => {
    const { readSummary } = scripted([
      summary({ passed: 1, pending: 2 }),
      summary({ passed: 2, pending: 1 }),
      summary({ passed: 3 }),
    ])
    const { sleep, waits } = fakeSleep()

    const result = await watchCiChecks({ readSummary, sleep, tickMs: 1000 })

    expect(result.outcome).toBe('pass')
    expect(result.updates).toBe(3)
    expect(waits).toEqual([1000, 1000])
  })

  it('stops on the first failure instead of waiting for the rest of the run', async () => {
    const { readSummary } = scripted([
      summary({ passed: 1, pending: 1 }),
      summary({ passed: 1, failed: 1, pending: 1 }),
      summary({ passed: 3 }),
    ])
    const { sleep, waits } = fakeSleep()

    const result = await watchCiChecks({ readSummary, sleep, tickMs: 1000 })

    expect(result.outcome).toBe('fail')
    expect(result.updates).toBe(2)
    expect(waits).toEqual([1000])
  })

  it('keeps waiting when the forge has not registered any check yet', async () => {
    const { readSummary } = scripted([summary(), summary(), summary({ passed: 1 })])
    const { sleep } = fakeSleep()

    const result = await watchCiChecks({ readSummary, sleep, tickMs: 1000 })

    expect(result.outcome).toBe('pass')
    expect(result.updates).toBe(2)
  })

  it('counts a rollup once, however many ticks read the same one', async () => {
    // The panel polls the status endpoint every 30 s; the watch ticks far more
    // often than that. Re-reporting an unchanged rollup would make the progress
    // line flicker and the update count meaningless.
    const pending = summary({ passed: 1, pending: 1 })
    const { readSummary, reads } = scripted([pending, pending, pending, pending, summary({ passed: 2 })])
    const { sleep } = fakeSleep()

    const result = await watchCiChecks({ readSummary, sleep, tickMs: 1000 })

    expect(result.outcome).toBe('pass')
    expect(result.updates).toBe(2)
    expect(reads()).toBe(5)
  })

  it('gives up at the deadline and reports the last summary it saw', async () => {
    const pending = summary({ passed: 1, pending: 1 })
    const { readSummary } = scripted([pending])
    const { sleep, waits } = fakeSleep()

    const result = await watchCiChecks({ readSummary, sleep, tickMs: 1000, deadlineMs: 2000 })

    expect(result.outcome).toBe('timeout')
    expect(result.summary).toEqual(pending)
    expect(result.updates).toBe(1)
    expect(waits).toEqual([1000, 1000])
  })

  it('reads once even with a zero deadline, so a green run is never reported as a timeout', async () => {
    const { readSummary } = scripted([summary({ passed: 1 })])
    const { sleep } = fakeSleep()

    const result = await watchCiChecks({ readSummary, sleep, deadlineMs: 0 })

    expect(result.outcome).toBe('pass')
    expect(result.updates).toBe(1)
  })

  it('stops when the caller asks it to, and keeps the last summary', async () => {
    const { readSummary } = scripted([summary({ passed: 1, pending: 1 }), summary({ passed: 2 })])
    const { sleep } = fakeSleep()
    let stop = false

    const result = await watchCiChecks({
      readSummary,
      sleep,
      tickMs: 1000,
      shouldStop: () => stop,
      onTick: () => {
        stop = true
      },
    })

    expect(result.outcome).toBe('cancelled')
    expect(result.updates).toBe(1)
    expect(result.summary).toEqual(summary({ passed: 1, pending: 1 }))
  })

  it('reports every change to the caller so the UI can show live progress', async () => {
    const { readSummary } = scripted([
      summary({ passed: 1, pending: 1 }),
      summary({ passed: 1, pending: 1 }),
      summary({ passed: 2 }),
    ])
    const { sleep } = fakeSleep()
    const ticks: Array<{ updates: number; verdict: string }> = []

    await watchCiChecks({
      readSummary,
      sleep,
      tickMs: 1000,
      onTick: (t) => ticks.push({ updates: t.updates, verdict: t.verdict }),
    })

    expect(ticks).toEqual([
      { updates: 1, verdict: 'pending' },
      { updates: 2, verdict: 'pass' },
    ])
  })

  it('tolerates a status payload that has not arrived yet', async () => {
    const { readSummary } = scripted([null, null, summary({ passed: 1 })])
    const { sleep } = fakeSleep()

    const result = await watchCiChecks({ readSummary, sleep, tickMs: 1000 })

    expect(result.outcome).toBe('pass')
    expect(result.updates).toBe(1)
  })

  it('defaults to a 2 s tick and a 15 min deadline', () => {
    expect(CI_WATCH_TICK_MS).toBe(2_000)
    expect(CI_WATCH_DEADLINE_MS).toBe(900_000)
  })
})

describe('ciWatchResultLine', () => {
  const result = (over: Partial<CiWatchResult>): CiWatchResult => ({
    outcome: 'pass',
    summary: null,
    updates: 1,
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
})
