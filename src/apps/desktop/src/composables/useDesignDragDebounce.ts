import { onBeforeUnmount } from 'vue'

/** Trailing-edge debounce composable for the design-canvas drag handlers. The previous
 * implementation used a 50 ms leading-edge throttle in `DesignElement.vue`. */
export interface UseDesignDragDebounceArgs<P> {
  onFlush: (patch: P) => void
  /** Idle window in ms. Default 250. */
  idleMs?: number
}

export interface DesignDragDebounceHandle<P> {
  /** Update the pending snapshot and reset the idle timer. */
  recordDelta: (patch: P) => void
  /** Fire onFlush synchronously with the current snapshot and clear the timer. */
  flush: () => void
  /** Clear the timer and snapshot without firing. */
  cancel: () => void
  /** Remove the onBeforeUnmount hook (for tests that don't mount a component). */
  dispose: () => void
}

export function useDesignDragDebounce<P>(
  args: UseDesignDragDebounceArgs<P>,
): DesignDragDebounceHandle<P> {
  const idleMs = args.idleMs ?? 250
  let pending: P | null = null
  let timerId: ReturnType<typeof setTimeout> | null = null

  const fire = (): void => {
    if (pending !== null) {
      const patch = pending
      pending = null
      if (timerId !== null) {
        clearTimeout(timerId)
        timerId = null
      }
      args.onFlush(patch)
    }
  }

  const recordDelta = (patch: P): void => {
    pending = patch
    if (timerId !== null) clearTimeout(timerId)
    timerId = setTimeout(fire, idleMs)
  }

  const flush = (): void => {
    fire()
  }

  const cancel = (): void => {
    pending = null
    if (timerId !== null) {
      clearTimeout(timerId)
      timerId = null
    }
  }

  // Auto-cleanup on component unmount — mirrors the useKanbanScrollRestore pattern.
  // `onBeforeUnmount` returns the noop (a `() => void`) when called outside a component setup (e.g.
  // in unit tests). Guard so `dispose()` is safe to call without a component context.
  const removeOnUnmount = onBeforeUnmount(() => {
    cancel()
  }) as (() => void) | undefined

  const dispose = (): void => {
    cancel()
    if (removeOnUnmount) removeOnUnmount()
  }

  return { recordDelta, flush, cancel, dispose }
}