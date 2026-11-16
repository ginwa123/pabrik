// Scroll refs We declare an explicit interface for the VirtualScroller instance because `InstanceType<typeof VirtualScroller>` doesn't resolve cleanly for a …
export interface VirtualScrollerExposed {
  scrollToIndex: (index: number, behavior?: ScrollBehavior) => void
  scrollToTop: (behavior?: ScrollBehavior) => void
  scrollToBottom: (behavior?: ScrollBehavior) => void
  /** The scrollTop that counts as "the bottom" — the same number `scrollToBottom` is about to use. */
  bottomScrollTop: () => number
  /** Where the bottom sat when the stick LAST acted (end of the last measure pass, or the last `scrollToBottom`), or null before anything positioned the list. */
  readonly settledBottom?: number | null
  /** Whether a real height has replaced an estimate yet. */
  readonly hasMeasuredItems?: boolean
  scrollToPosition: (scrollTop: number, behavior?: ScrollBehavior) => void
  scrollToItem: (index: number, behavior?: ScrollBehavior) => void
  /** Full height-model recompute from the live DOM (append-gap fix). */
  remeasure: () => void
  /** Transfer a stored height across an identity swap (shrink fix). */
  rekeyHeight: (oldKey: string, newKey: string) => boolean
  beginPreserve: (newItemsCount: number) => void
  endPreserve: () => Promise<void>
  preserveScrollPosition: () => Promise<void>
  containerRef: HTMLElement | null
  isPreservingScroll: boolean
  effectiveLoadMoreThreshold: number
  /** Topmost/bottommost rendered item indices (auto-unwrapped computed). */
  effectiveRange: { start: number; end: number }
  sizerHeight?: number
  modelTotal?: number
}
