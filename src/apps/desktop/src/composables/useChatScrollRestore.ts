import { onBeforeUnmount, onMounted, onUpdated, ref, type Ref } from 'vue'

/** Persists a vertically-scrolling container's `scrollTop` to `localStorage` across component
 * mounts, with a chat-specific "near bottom" detection: if the saved position is within
 * `BOTTOM_THRESHOLD_PX` of the current `scrollHeight. */
const BOTTOM_THRESHOLD_PX = 40

export function useChatScrollRestore(
  containerRef: Ref<HTMLElement | null>,
  storageKey: Ref<string> | string,
  /** Resolves the scrollTop that counts as "the bottom" for this container. The DOM's `scrollHeight
   * - clientHeight` is only the bottom when the sizer agrees with the real content. */
  resolveBottomEdge?: (container: HTMLElement) => number,
): {
  restore: () => number | null
  /** Whether a restoreable value is stored, judged WITHOUT the container. */
  hasSavedPosition: () => boolean
  restorePosition: (value: number) => void
} {
  const bottomEdgeOf = (el: HTMLElement): number => {
    if (resolveBottomEdge) {
      const edge = resolveBottomEdge(el)
      if (Number.isFinite(edge)) return edge
    }
    return el.scrollHeight - el.clientHeight
  }
  // Alias the key rather than mirroring it into a local ref. This used to be `const keyRef =
  // ref(initialKey)` plus a `{ immediate: true }` watcher copying `storageKey.value` into it.
  const keyRef: Ref<string> = typeof storageKey === 'string' ? ref(storageKey) : storageKey

  let debounceTimer: ReturnType<typeof setTimeout> | null = null

  const readSaved = (): number | null => {
    try {
      const raw = localStorage.getItem(keyRef.value)
      if (raw === null) return null
      const parsed = parseInt(raw, 10)
      return Number.isNaN(parsed) || parsed < 0 ? null : parsed
    } catch {
      return null
    }
  }

  const writeSaved = (value: number): void => {
    try {
      localStorage.setItem(keyRef.value, String(value))
    } catch {
      // private-mode / quota-exceeded — silent.
    }
  }

  const flushPending = (): void => {
    if (debounceTimer !== null) {
      clearTimeout(debounceTimer)
      debounceTimer = null
    }
    const el = containerRef.value
    if (el) writeSaved(el.scrollTop)
  }

  const scheduleWrite = (): void => {
    const el = containerRef.value
    if (!el) return
    if (debounceTimer !== null) clearTimeout(debounceTimer)
    debounceTimer = setTimeout(() => {
      debounceTimer = null
      const e = containerRef.value
      if (e) writeSaved(e.scrollTop)
    }, 250)
  }

  const handleScroll = (): void => scheduleWrite()
  const handleScrollEnd = (): void => {
    flushPending()
    const el = containerRef.value
    if (el) writeSaved(el.scrollTop)
  }

  // Captured synchronously during setup so restore() can return it immediately (matches the
  // existing kanban composable's contract).
  const savedScrollTop: number | null = readSaved()

  let attachedEl: HTMLElement | null = null

  // Wire the container when it becomes available. The chat's VirtualScroller is conditionally
  // rendered (v-if), so on first mount containerRef may still be null — the scroller only appears
  // once `isLoading` flips to true inside loadChatHistory's initial-load branch.
  const wireChatContainer = (el: HTMLElement | null) => {
    if (!el) return
    if (attachedEl === el) return
    attachedEl = el
    void attachListenersWhenScrollable(el)
  }

  onMounted(() => {
    wireChatContainer(containerRef.value)
  })
  onUpdated(() => {
    wireChatContainer(containerRef.value)
  })

  async function attachListenersWhenScrollable(el: HTMLElement): Promise<void> {
    // VirtualScroller takes ~100ms to measure items after mount. Wait for `scrollHeight >
    // clientHeight` so restore() can compute a meaningful max. If the chat is empty / not
    // scrollable, fall through and attach anyway — the listener still serves future scrolls.
    const start = Date.now()
    while (Date.now() - start < 500) {
      if (el.scrollHeight > el.clientHeight) break
      await new Promise<void>((r) => setTimeout(r, 16))
    }

    el.addEventListener('scroll', handleScroll, { passive: true })
    if ('onscrollend' in el) {
      el.addEventListener('scrollend', handleScrollEnd, { passive: true })
    }
  }

  onBeforeUnmount(() => {
    flushPending()
    if (attachedEl) {
      attachedEl.removeEventListener('scroll', handleScroll)
      attachedEl.removeEventListener('scrollend', handleScrollEnd)
      attachedEl = null
    }
  })

  const restore = (): number | null => {
    if (savedScrollTop === null) return null
    if (savedScrollTop <= 0) return null
    const el = containerRef.value
    if (!el) return null
    const max = el.scrollHeight - el.clientHeight
    if (max <= 0) return null
    // "Near bottom" branch: if the saved position is within BOTTOM_THRESHOLD_PX of the bottom edge,
    // treat as "still at bottom" → let the caller fall through to scrollToBottom. The edge is the
    // caller's, not the DOM's — see `resolveBottomEdge`.
    if (savedScrollTop >= bottomEdgeOf(el) - BOTTOM_THRESHOLD_PX) return null
    return savedScrollTop
  }

  /** True when localStorage holds a positive value for the current key. Deliberately reads NOTHING
   * from the container: the question is "did this reader ever leave a position behind?", which is a
   * fact about storage, not about layout. */
  const hasSavedPosition = (): boolean =>
    savedScrollTop !== null && savedScrollTop > 0

  const restorePosition = (value: number): void => {
    const el = containerRef.value
    if (!el) return
    const max = el.scrollHeight - el.clientHeight
    if (max <= 0) return
    // Clamp to the DOM edge: the browser clamps there anyway, and the DOM edge
    // is the furthest the reader can physically go.
    const clamped = Math.max(0, Math.min(value, max))
    el.scrollTop = clamped
  }

  return { restore, hasSavedPosition, restorePosition }
}
