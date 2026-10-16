import { onBeforeUnmount, onMounted, onUpdated, ref, type Ref } from 'vue'

/** Persists a kanban column body's `scrollTop` to `localStorage` across component mounts. Why this
 * exists: A kanban column's card list is a `<VirtualScroller>` that owns a `overflow-y-auto`
 * container. */
export function useKanbanColumnScrollRestore(
  containerRef: Ref<HTMLElement | null>,
  storageKey: Ref<string> | string,
): void {
  // Alias the key rather than mirroring it into a local ref — see the note in useChatScrollRestore.
  const keyRef: Ref<string> = typeof storageKey === 'string' ? ref(storageKey) : storageKey

  let debounceTimer: ReturnType<typeof setTimeout> | null = null
  let attachedEl: HTMLElement | null = null
  // Last value observed while the element was still attached. The unmount
  // flush writes THIS, never a fresh DOM read (see the doc comment).
  let lastKnownScrollTop: number | null = null

  const readSaved = (): number => {
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

  const write = (value: number): void => {
    try {
      localStorage.setItem(keyRef.value, String(value))
    } catch {
      // private-mode / quota-exceeded — cross-reload persistence is lost,
      // the in-session restore still works. Silently ignore.
    }
  }

  const flushPending = (): void => {
    if (debounceTimer !== null) {
      clearTimeout(debounceTimer)
      debounceTimer = null
    }
    if (lastKnownScrollTop !== null) write(lastKnownScrollTop)
  }

  const handleScroll = (): void => {
    const el = containerRef.value
    if (!el) return
    lastKnownScrollTop = el.scrollTop
    if (debounceTimer !== null) clearTimeout(debounceTimer)
    debounceTimer = setTimeout(() => {
      debounceTimer = null
      if (lastKnownScrollTop !== null) write(lastKnownScrollTop)
    }, 250)
  }

  const handleScrollEnd = (): void => {
    const el = containerRef.value
    if (el) lastKnownScrollTop = el.scrollTop
    flushPending()
  }

  const detach = (): void => {
    if (!attachedEl) return
    attachedEl.removeEventListener('scroll', handleScroll)
    attachedEl.removeEventListener('scrollend', handleScrollEnd)
    attachedEl = null
  }

  const restoreInto = async (el: HTMLElement): Promise<void> => {
    // Two frames so the VirtualScroller has sized its spacers — a single rAF
    // isn't enough for `scrollHeight` to reflect the measured items.
    await new Promise<void>((r) => requestAnimationFrame(() => r()))
    await new Promise<void>((r) => requestAnimationFrame(() => r()))

    // Then wait for the column to actually become scrollable (up to 500 ms). Bailing out on `max <=
    // 0` alone would silently DROP the restore for any column whose cards have not been laid out by
    // the second frame: the user would come back to a column sitting at the top, which is the bug.
    const start = Date.now()
    while (Date.now() - start < 500) {
      if (containerRef.value !== el) return // swapped out while waiting
      if (el.scrollHeight > el.clientHeight) break
      await new Promise<void>((r) => setTimeout(r, 16))
    }
    if (containerRef.value !== el) return

    const saved = readSaved()
    if (saved <= 0) return // nothing saved (first visit)
    const max = el.scrollHeight - el.clientHeight
    if (max <= 0) return // genuinely not scrollable — nothing to restore
    const clamped = Math.min(saved, max)
    el.scrollTop = clamped
    lastKnownScrollTop = clamped
  }

  // Attach on mount when the element is already there, and on update when
  // it shows up late (the scroller sits behind `v-if="cardsInColumn.length
  // > 0"`, so on a cold load the container is still null at mount and only
  // appears once cards arrive — which re-renders the host and lands here).
  // `wireContainer` is idempotent per element; a null pass detaches.
  const wireContainer = (el: HTMLElement | null) => {
    if (!el) {
      detach()
      return
    }
    if (attachedEl === el) return
    detach()
    attachedEl = el

    el.addEventListener('scroll', handleScroll, { passive: true })
    // `scrollend` is the fast path (~100 ms after the user stops). Feature
    // detect with `in` — jsdom silently creates missing properties on
    // assignment, so a bare `if (el.onscrollend)` would lie.
    if ('onscrollend' in el) {
      el.addEventListener('scrollend', handleScrollEnd, { passive: true })
    }
    // else: the debounced `scroll` handler covers it.
    void restoreInto(el)
  }

  onMounted(() => {
    wireContainer(containerRef.value)
  })
  onUpdated(() => {
    wireContainer(containerRef.value)
  })

  onBeforeUnmount(() => {
    flushPending()
    detach()
  })
}
