import { onBeforeUnmount, onMounted, ref, type Ref } from 'vue'

/** Persists a scrolling container's scroll offset to `localStorage` across component mounts. */
export function useKanbanScrollRestore(
  containerRef: Ref<HTMLElement | null>,
  storageKey: Ref<string> | string,
  axis: 'x' | 'y' = 'x',
): void {
  // Alias the key rather than mirroring it into a local ref — a dynamic storage key (computed from
  // props) then stays live with no watcher. This used to initialise to '' whenever `storageKey` was
  // a Ref and rely on an `{ immediate: true }` watcher to fill it in.
  const keyRef: Ref<string> = typeof storageKey === 'string' ? ref(storageKey) : storageKey

  let debounceTimer: ReturnType<typeof setTimeout> | null = null

  // Axis accessors — the only place the two axes differ. Reading and
  // writing through these keeps the rest of the composable shared.
  const readOffset = (el: HTMLElement): number => (axis === 'y' ? el.scrollTop : el.scrollLeft)
  const writeOffset = (el: HTMLElement, value: number): void => {
    if (axis === 'y') el.scrollTop = value
    else el.scrollLeft = value
  }
  const scrollSize = (el: HTMLElement): number => (axis === 'y' ? el.scrollHeight : el.scrollWidth)
  const clientSize = (el: HTMLElement): number => (axis === 'y' ? el.clientHeight : el.clientWidth)

  const readSavedOffset = (): number => {
    try {
      const raw = localStorage.getItem(keyRef.value)
      if (raw === null) return 0
      const parsed = parseInt(raw, 10)
      return Number.isNaN(parsed) || parsed < 0 ? 0 : parsed
    } catch {
      // localStorage may throw in disabled / private-mode.
      return 0
    }
  }

  const writeSavedOffset = (value: number): void => {
    try {
      localStorage.setItem(keyRef.value, String(value))
    } catch {
      // localStorage may throw in disabled / private-mode / quota-exceeded scenarios. The in-memory
      // restore on the next mount still works; only cross-reload persistence is lost. Silently
      // ignore.
    }
  }

  const flushPending = (): void => {
    if (debounceTimer !== null) {
      clearTimeout(debounceTimer)
      debounceTimer = null
    }
    const el = containerRef.value
    if (el) writeSavedOffset(readOffset(el))
  }

  const scheduleWrite = (): void => {
    const el = containerRef.value
    if (!el) return
    if (debounceTimer !== null) clearTimeout(debounceTimer)
    debounceTimer = setTimeout(() => {
      debounceTimer = null
      const e = containerRef.value
      if (e) writeSavedOffset(readOffset(e))
    }, 250)
  }

  const handleScroll = (): void => scheduleWrite()
  const handleScrollEnd = (): void => {
    // scrollend is the fast path — cancel the debounced write and
    // commit immediately.
    flushPending()
    const el = containerRef.value
    if (el) writeSavedOffset(readOffset(el))
  }

  onMounted(async () => {
    // Wait two animation frames so the content has geometry. A single rAF isn't enough: Vue mounts
    // the DOM, then React-style effects (useLayoutEffect-like) may still settle, and the browser
    // may need a second frame to fully compute scrollWidth / scrollHeight.
    await new Promise<void>((r) => requestAnimationFrame(() => r()))
    await new Promise<void>((r) => requestAnimationFrame(() => r()))

    const el = containerRef.value
    if (!el) return

    // Attach listeners FIRST (regardless of whether there's a saved value to restore). The user
    // might scroll from scratch — without an attached listener we'd never establish the first saved
    // value. Passive scroll listener for the debounced fallback write.
    el.addEventListener('scroll', handleScroll, { passive: true })

    // scrollend is the fast path. Feature-detect by trying to set `onscrollend` (returns
    // `undefined` if the property doesn't exist; assigning to a missing property silently creates
    // it in jsdom, so we additionally check `'onscrollend' in el` to be safe in test environments).
    const supportsScrollEnd =
      'onscrollend' in el ||
      typeof (el as unknown as { onscrollend?: unknown }).onscrollend !== 'undefined'
    if (supportsScrollEnd) {
      el.addEventListener('scrollend', handleScrollEnd, { passive: true })
    }
    // else: the debounced `scroll` handler covers this case. Each scroll event schedules a 250 ms
    // write, so even without scrollend the position is saved ~250 ms after the user stops
    // scrolling. Now restore from the previous session's saved offset.
    const saved = readSavedOffset()
    if (saved <= 0) return // nothing to restore (initial state)

    const max = scrollSize(el) - clientSize(el)
    if (max <= 0) return // content fits in viewport — nothing to scroll
    writeOffset(el, Math.min(saved, max))
  })

  onBeforeUnmount(() => {
    flushPending()
    const el = containerRef.value
    if (!el) return
    el.removeEventListener('scroll', handleScroll)
    el.removeEventListener('scrollend', handleScrollEnd)
  })
}
