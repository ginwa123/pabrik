/** Trailing-edge debounce around ONE repeatable task — the settings autosave. Every edit calls
 * `schedule()`; the task runs once the edit burst goes quiet, and `task` must resolve (report your
 * own failures) so a pending run can never surface as an unhandled rejection. */
export interface DebouncedRunner {
  /** (Re)start the idle window. A non-positive `delayMs` runs the task on the next microtask. */
  schedule: () => void
  /** Run a pending task now instead of waiting out the window; resolves when idle again. */
  flush: () => Promise<void>
  /** Drop the pending window without running the task. */
  cancel: () => void
}

export function useDebouncedRunner(delayMs: number, task: () => Promise<unknown>): DebouncedRunner {
  let timer: ReturnType<typeof setTimeout> | null = null
  let inFlight: Promise<void> | null = null
  let again = false

  function clearWindow(): void {
    if (timer === null) return
    clearTimeout(timer)
    timer = null
  }

  function run(): Promise<void> {
    const current = inFlight
    if (current !== null) {
      again = true
      return current
    }
    clearWindow()
    const started = task().then(() => {
      inFlight = null
      if (!again) return
      again = false
      void run()
    })
    inFlight = started
    return started
  }

  function schedule(): void {
    clearWindow()
    if (delayMs <= 0) {
      void run()
      return
    }
    timer = setTimeout(() => {
      timer = null
      void run()
    }, delayMs)
  }

  function flush(): Promise<void> {
    if (timer === null) return inFlight ?? Promise.resolve()
    return run()
  }

  function cancel(): void {
    clearWindow()
    again = false
  }

  return { schedule, flush, cancel }
}
