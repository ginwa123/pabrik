import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest'

import { useDebouncedRunner } from '../composables/useDebouncedRunner'

describe('useDebouncedRunner', () => {
  beforeEach(() => {
    vi.useFakeTimers()
  })

  afterEach(() => {
    vi.useRealTimers()
  })

  it('runs the task once for a burst of edits, after the idle window', async () => {
    const task = vi.fn(async () => {})
    const runner = useDebouncedRunner(600, task)

    runner.schedule()
    runner.schedule()
    runner.schedule()

    await vi.advanceTimersByTimeAsync(599)
    expect(task).not.toHaveBeenCalled()

    await vi.advanceTimersByTimeAsync(1)
    expect(task).toHaveBeenCalledTimes(1)
  })

  it('restarts the idle window on every edit', async () => {
    const task = vi.fn(async () => {})
    const runner = useDebouncedRunner(600, task)

    runner.schedule()
    await vi.advanceTimersByTimeAsync(500)
    runner.schedule()
    await vi.advanceTimersByTimeAsync(500)

    expect(task).not.toHaveBeenCalled()
  })

  it('runs again when an edit lands while the previous run is still in flight', async () => {
    const releases: Array<() => void> = []
    const task = vi.fn(
      () =>
        new Promise<void>((resolve) => {
          releases.push(resolve)
        }),
    )
    const runner = useDebouncedRunner(600, task)

    runner.schedule()
    await vi.advanceTimersByTimeAsync(600)
    expect(task).toHaveBeenCalledTimes(1)

    runner.schedule()
    await vi.advanceTimersByTimeAsync(600)
    expect(task).toHaveBeenCalledTimes(1)

    releases[0]!()
    await vi.advanceTimersByTimeAsync(0)
    expect(task).toHaveBeenCalledTimes(2)

    releases[1]!()
    await vi.advanceTimersByTimeAsync(0)
    expect(task).toHaveBeenCalledTimes(2)
  })

  it('flush runs a pending task without waiting out the window', async () => {
    const task = vi.fn(async () => {})
    const runner = useDebouncedRunner(600, task)

    runner.schedule()
    await runner.flush()

    expect(task).toHaveBeenCalledTimes(1)
  })

  it('flush leaves nothing behind when no task is pending', async () => {
    const task = vi.fn(async () => {})
    const runner = useDebouncedRunner(600, task)

    await runner.flush()
    await vi.advanceTimersByTimeAsync(600)

    expect(task).not.toHaveBeenCalled()
  })

  it('cancel drops the pending run', async () => {
    const task = vi.fn(async () => {})
    const runner = useDebouncedRunner(600, task)

    runner.schedule()
    runner.cancel()
    await vi.advanceTimersByTimeAsync(600)

    expect(task).not.toHaveBeenCalled()
  })

  it('runs without a timer when the delay is zero', async () => {
    const task = vi.fn(async () => {})
    const runner = useDebouncedRunner(0, task)

    runner.schedule()
    await vi.advanceTimersByTimeAsync(0)

    expect(task).toHaveBeenCalledTimes(1)
  })
})
