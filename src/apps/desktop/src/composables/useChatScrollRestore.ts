import { onBeforeUnmount, onMounted, onUpdated, ref, type Ref } from 'vue'

/**
 * Persists a vertically-scrolling container's `scrollTop` to
 * `localStorage` across component mounts, with a chat-specific
 * "near bottom" detection: if the saved position is within
 * `BOTTOM_THRESHOLD_PX` of the current `scrollHeight - clientHeight`,
 * `restore()` returns `null` so the caller falls through to
 * `scrollToBottom` instead of restoring a stale bottom edge (which
 * could be missing a few messages that arrived during the close
 * window).
 *
 * Why this exists:
 *   ChatView uses `:key="task-<id>"` in the surrounding
 *   `v-if/v-else-if` chain in AppLayout.vue. Vue 3 does NOT reuse
 *   component instances across keys at different DOM parents, so
 *   closing + reopening a chat (even the same chat) tears down and
 *   recreates ChatView. Without this composable, the new instance's
 *   scrollTop resets to 0 and the user loses their reading position.
 *
 *   The horizontal sibling `useKanbanScrollRestore` already solves
 *   this for the kanban board's columns row. This composable
 *   mirrors that pattern but for the chat's vertical scroll + the
 *   "near bottom" branch that the kanban does not need.
 *
 * Behavior:
 *   - **On mount**: reads the saved `scrollTop` from `localStorage`,
 *     waits for `scrollHeight > clientHeight` (the VirtualScroller's
 *     item measurement) or a 500 ms safety net, then attaches
 *     scroll + scrollend listeners. Exposes `restore()` (returns
 *     the saved value, or `null` if at-bottom / not set / not
 *     scrollable), `hasSavedPosition()` (whether a restoreable
 *     value exists at all, WITHOUT reading the container's
 *     geometry) and `restorePosition(value)` (clamps + applies).
 *
 * `hasSavedPosition()` exists so the caller can tell "there is
 * nothing to restore" apart from "the geometry is not ready yet".
 * The two need opposite handling: the first should fall through to
 * `scrollToBottom` immediately, the second should WAIT. Reading
 * `restore()` for that distinction conflates them, because
 * `restore()` returns `null` for both — and a caller that waits on
 * it parks a first-time visitor at the top of an empty scroll for
 * the whole timeout.
 *   - **On `scrollend`** (fast path): writes the current `scrollTop`
 *     synchronously and cancels any pending debounced write.
 *   - **On `scroll`** (fallback path): schedules a debounced 250 ms
 *     write via `setTimeout`. Each new scroll event resets the
 *     timer so a 60-Hz scroll stream produces one write per
 *     scroll-stop.
 *   - **On unmount**: flushes any pending debounced write so a fast
 *     scroll → click → remount cycle doesn't lose the latest
 *     position, then removes the scroll + scrollend listeners.
 *
 * Storage key convention: caller composes the full key (e.g.
 * `chat-scroll-<taskId>`). The key is accepted as either a plain
 * `string` or a `Ref<string>` so it can be computed from props
 * reactively.
 *
 * Edge cases:
 *   - `localStorage` access is wrapped in `try/catch` so
 *     private-mode / quota-exceeded failures don't throw. The
 *     in-memory restore still works for the current session; only
 *     reload persistence is lost.
 *   - The composable swallows `localStorage.setItem` throws so
 *     private-mode browsers don't surface errors.
 *   - The composable does NOT save on programmatic scrolls
 *     differently from user scrolls (no flag). The `scrollTop`
 *     value is what the user sees regardless of who moved it; the
 *     "near bottom" branch in `restore()` covers the case where
 *     the user was at the bottom when they closed.
 *
 * NOT for vertical scrolling inside a `VirtualScroller`'s
 * `beginPreserve`/`endPreserve` window — that flow has its own
 * anchor-tracking mechanism. This composable is for the persistent
 * across-mount case.
 */

const BOTTOM_THRESHOLD_PX = 40

export function useChatScrollRestore(
  containerRef: Ref<HTMLElement | null>,
  storageKey: Ref<string> | string,
  /**
   * Resolves the scrollTop that counts as "the bottom" for this container.
   *
   * The DOM's `scrollHeight - clientHeight` is only the bottom when the sizer
   * agrees with the real content. A VirtualScroller deliberately targets the
   * REAL content bottom instead when its height model overshoots (and its
   * tail-gap cap makes that overshoot routine at the end of a long chat), so a
   * position saved while the reader sat on the last message can sit up to
   * `maxTailGap` below the DOM edge. Comparing that save against the DOM edge
   * would (a) fail to recognise it as "still at the bottom" and restore a
   * stale position, and (b) clamp the restore to the DOM edge, parking the
   * reader in the blank region below the transcript. ChatView passes the
   * scroller's `bottomScrollTop`; the default keeps the pre-VirtualScroller
   * behaviour for plain containers.
   */
  resolveBottomEdge?: (container: HTMLElement) => number,
): {
  restore: () => number | null
  /** Whether a restoreable value is stored, judged WITHOUT the container. */

  /** `restore()` cannot answer this: it returns `null` both for "nothing saved" and for "the
   * container is not scrollable yet", and the caller must treat those two differently — fall
   * through to the bottom immediately versus wait for the scroller to measure. */

  /** See the header note. */
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

  // The watcher needed the `immediate` flag precisely because the snapshot could not see the
  // current value on its own, and it still could not cover a key that changed between setup and the
  // first flush.

  // Aliasing reads the live value every time, so a dynamic key is correct from the first access and
  // no watcher is needed at all.
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

  // Reads the raw saved value (no "near bottom" gating here — that's restore()'s job, computed
  // against the CURRENT container geometry which is only known after the VirtualScroller has
  // measured items).
  const savedScrollTop: number | null = readSaved()

  let attachedEl: HTMLElement | null = null

  // Wire the container when it becomes available. The chat's VirtualScroller is conditionally
  // rendered (v-if), so on first mount containerRef may still be null — the scroller only appears
  // once `isLoading` flips to true inside loadChatHistory's initial-load branch.

  // That arrival re-renders the host, which lands in the update hook (post-flush, like the old
  // watcher) with the element present. Idempotent per element.
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

  /** Answering it from `restore()` instead would make a not-yet-measured scroller look like
   * "nothing to restore". */
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
