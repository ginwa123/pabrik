<script setup lang="ts" generic="T">
import { ref, computed, onMounted, onUnmounted, onUpdated, nextTick } from 'vue'

import { computeLoadMoreThreshold } from './virtualScrollerThreshold'
import { computeAnchorCompensation, type AnchorMeasurement } from './virtualScrollerScrollAnchor'
import { quantizePx, AdaptiveItemHeightEstimator } from './virtualScrollerPerf'
import { createScrollLogger } from './scrollLogger'

const props = withDefaults(
  defineProps<{
    /** The full list of items to virtualize. */
    items: T[]
    /** Total number of items that exist on the server / in the source of truth, if known. */
    totalCount?: number
    /** Number of extra items to render **on each side** (above AND below) the visible viewport. */
    buffer?: number
    /** Estimated height in pixels for an item whose real height hasn't been measured yet. */
    defaultItemHeight?: number
    /** Distance in pixels from the load edge at which the scroller emits `loadMore`. */
    loadMoreThreshold?: number
    /** Proportion of the container's visible height (`clientHeight`) that the effective threshold should track. */
    loadMoreThresholdRatio?: number
    /** If `true`, the scroller emits `loadMore` when the user scrolls within `loadMoreThreshold` of the **top** — use this when you're prepending older items (chat … */
    loadMoreAtTop?: boolean
    /** Stable identity function for items (2026-08-26 stable-keys fix). */
    itemKey?: (item: T, index: number) => string
    /** Hard cap, in pixels, on the blank region the user can scroll into BELOW the last rendered row. */
    maxTailGap?: number
    /** Debug chat id for VirtualScroller internal logging (2026-09-02). */
    debugChatId?: string
  }>(),
  {
    totalCount: 0,
    buffer: 5,
    defaultItemHeight: 100,
    loadMoreThreshold: 200,
    loadMoreThresholdRatio: 0.5,
    loadMoreAtTop: false,
    itemKey: undefined,
    maxTailGap: 100,
    debugChatId: undefined,
  },
)

const emit = defineEmits<{
  loadMore: []
  /** Fired when one of the scroller's internal guards prevented `loadMore` from being emitted — i.e. the user WAS within the load edge but the scroller still chose … */
  loadMoreSuppressed: [guard: string]
  /** Fired on every scroll event. */
  scroll: [
    scrollTop: number,
    direction: 'up' | 'down',
    target: HTMLElement,
    isProgrammatic: boolean,
  ]
  /** Fired whenever the scroller's `isScrollable` computed value CHANGES (not on every re-evaluation — only when the boolean flips from one value to the other). */
  scrollabilityChange: [scrollable: boolean]
  /** Fired whenever the scroller's content positioning values change — i.e. when `topSpacer`, `bottomSpacer`, or the total content height changes as a result of … */
  contentShift: [shift: { topSpacer: number; bottomSpacer: number; total: number }]
}>()

// ── Deep-dive logger (2026-09-02) ──────────────────────────────────────────
const vsLogger = computed(() => (props.debugChatId ? createScrollLogger(props.debugChatId) : null))

const containerRef = ref<HTMLElement | null>(null)
// The content div needs no template ref: the sizer is a pure function of the height model (see sizerHeight), and per-child heights come from measureItems.
const scrollTop = ref(0)
const lastScrollTop = ref(0)
const containerHeight = ref(0)
// Heights keyed by STABLE ID (itemKey(item)), not array index — see the itemKey prop JSDoc for the index-shift corruption this prevents.
const itemHeights = ref<Map<string, number>>(new Map())
const accumulatedHeights = ref<number[]>([0])
const isPreservingScroll = ref(false)
const forceRenderUpTo = ref(-1)

/** Stable identity for the item at `index`. */
const keyOf = (index: number): string => {
  const item = props.items[index]
  if (item === undefined) return `#${index}`
  return props.itemKey ? props.itemKey(item, index) : `#${index}`
}

// ── Programmatic-scroll tracking (2026-08-25 append-gap fix) ────────────────
let pendingProgrammaticScrolls = 0
let programmaticResetTimer: ReturnType<typeof setTimeout> | null = null
const markProgrammaticScroll = (): void => {
  pendingProgrammaticScrolls += 1
  if (programmaticResetTimer) clearTimeout(programmaticResetTimer)
  programmaticResetTimer = setTimeout(() => {
    pendingProgrammaticScrolls = 0
  }, 100)
}
const consumeProgrammaticScroll = (): boolean => {
  if (pendingProgrammaticScrolls > 0) {
    pendingProgrammaticScrolls -= 1
    return true
  }
  return false
}

// ── P1 perf: adaptive item-height estimation (task_1787551495337_9) ─────────
const heightEstimator = new AdaptiveItemHeightEstimator({
  seed: props.defaultItemHeight,
  maxSamples: 64,
})

// Highest index that has a real measured height (vestigial frontier, 2026-09-06: estimateHeight now trusts the running median for ALL unmeasured items — the old …
let maxMeasuredIndex = -1

/** Estimated height for an item with no stored measurement. 2026-09-06 (task_1788648119245_5): uses the adaptive running MEDIAN of measured heights instead of the … */
const ESTIMATE_MIN_PX = 32
const ESTIMATE_MAX_PX = 1600
const clampEstimate = (px: number): number =>
  Math.min(ESTIMATE_MAX_PX, Math.max(ESTIMATE_MIN_PX, px))

/** How many observations the estimator must hold before its estimate is frozen (see `estimateHeight`). */
const ESTIMATOR_FREEZE_SAMPLES = 64

/** Height for an item with no stored measurement — a PLACEHOLDER, and one that is deliberately not allowed to move once the estimator has learned a realistic … */
const estimateHeight = (index: number): number => {
  const stored = itemHeights.value.get(keyOf(index))
  if (stored !== undefined) return stored
  return clampEstimate(heightEstimator.estimate())
}

/** Whether the container's content currently overflows its visible area (i.e. */
const isScrollable = computed(() => {
  const totalContentHeight = accumulatedHeights.value[props.items.length] ?? 0
  return totalContentHeight > containerHeight.value
})

/** Effective distance (in px) from the load edge at which the scroller emits `loadMore`. */
const effectiveLoadMoreThreshold = computed(() =>
  computeLoadMoreThreshold(
    props.loadMoreThreshold,
    props.loadMoreThresholdRatio,
    containerHeight.value,
  ),
)

// Scrollability is pushed to the parent via the `scrollabilityChange` event (see its emit doc for why an event beats a template-ref read).
let prevScrollable: boolean | null = null
const emitScrollableIfChanged = () => {
  const scrollable = isScrollable.value
  if (scrollable === prevScrollable) return
  prevScrollable = scrollable
  emit('scrollabilityChange', scrollable)
}

let _anchorOffsetTopBefore = 0
let _pendingNewItemsCount = 0

const updateAccumulatedHeights = () => {
  const h: number[] = [0]
  let sum = 0
  for (let i = 0; i < props.items.length; i++) {
    sum += estimateHeight(i)
    h.push(sum)
  }
  accumulatedHeights.value = h
}

// ── Sizer height.
const modelTotal = computed(() => accumulatedHeights.value[props.items.length] ?? 0)

// ── Tail-gap cap (task_1790236655228_2) ─────────────────────────────────────
const tailContentBottom = ref(0)
// Latched "the rendered window covers the tail" flag.
const tailCapLatched = ref(false)
let cachedSizerHeight = -1
const sizerHeight = computed(() => {
  const total = modelTotal.value
  const gap = props.maxTailGap
  const capped =
    gap > 0 && tailCapLatched.value && tailContentBottom.value > 0
      ? Math.min(total, tailContentBottom.value + gap)
      : total
  if (cachedSizerHeight < 0 || Math.abs(capped - cachedSizerHeight) > HYSTERESIS_PX) {
    cachedSizerHeight = capped
    if (import.meta.env.DEV && vsLogger.value) {
      try {
        vsLogger.value.info({
          scrollTop: containerRef.value?.scrollTop ?? scrollTop.value,
          scrollHeight: containerRef.value?.scrollHeight ?? total,
          clientHeight: containerRef.value?.clientHeight ?? containerHeight.value,
          messages: props.items.length,
          isAtBottom: false,
          containerInfo: {
            null: !containerRef.value,
            offsetHeight: containerRef.value?.offsetHeight ?? 0,
            offsetParent: null,
          },
          reason: 'sizer-recomputed',
          caller: 'VirtualScroller.sizerHeight',
          extra: {
            modelTotal: total,
            sizerHeight: capped,
            tailCapPx: capped === total ? null : total - capped,
            tailContentBottom: tailContentBottom.value,
            maxTailGap: gap,
            tailCapLatched: tailCapLatched.value,
            hysteresis: HYSTERESIS_PX,
          },
          // eslint-disable-next-line @typescript-eslint/no-explicit-any
        } as any)
      } catch {}
    }
  }
  return cachedSizerHeight
})
// Rebuild the height model on mount AND whenever `items.length` changes.
let prevItemsLen = -1
const syncItemsLength = () => {
  const newLen = props.items.length
  if (newLen === prevItemsLen) return
  const oldLen = prevItemsLen
  prevItemsLen = newLen
  // A collapse to 0 means the list was swapped (chat switch) — forget the previous chat's height profile so its median doesn't pollute the new chat's estimates.
  if (newLen === 0 && oldLen > 0) {
    heightEstimator.reset()
    maxMeasuredIndex = -1
    // The measured tail bottom belongs to the OLD list: keeping it would cap the new chat's sizer at a position that means nothing here.
    tailContentBottom.value = 0
    tailCapLatched.value = false
  }
  updateAccumulatedHeights()
}

const findStartIndex = (): number => {
  const h = accumulatedHeights.value
  if (h.length <= 1) return 0
  let lo = 0,
    hi = h.length - 1
  while (lo < hi) {
    const mid = (lo + hi) >> 1
    if ((h[mid] ?? 0) <= scrollTop.value) lo = mid + 1
    else hi = mid
  }
  return Math.max(0, lo - 1)
}

const visibleRange = computed(() => {
  const len = props.items.length
  if (len === 0) return { start: 0, end: 0, topSpacer: 0, bottomSpacer: 0 }

  const startIndex = findStartIndex()
  const viewBottom = scrollTop.value + containerHeight.value
  let acc = accumulatedHeights.value[startIndex] ?? 0
  let endIndex = startIndex
  while (endIndex < len && acc < viewBottom) {
    acc += estimateHeight(endIndex)
    endIndex++
  }

  let start = Math.max(0, startIndex - props.buffer)
  let end = Math.min(len, endIndex + props.buffer)

  if (forceRenderUpTo.value >= 0) {
    start = 0
    end = Math.max(end, forceRenderUpTo.value + 1)
  }

  const topSpacer = accumulatedHeights.value[start] ?? 0
  const bottomSpacer = (accumulatedHeights.value[len] ?? 0) - (accumulatedHeights.value[end] ?? 0)
  return { start, end, topSpacer, bottomSpacer }
})

// Tail-cap latch (see the sizerHeight comment).
const applyTailCapLatch = (end: number) => {
  if (end >= props.items.length) tailCapLatched.value = true
  else if (end < props.items.length - props.buffer) tailCapLatched.value = false
}

/** Record the MEASURED bottom of the rendered window, in model space. */
const syncSizerHeightToDom = (): void => {
  const el = containerRef.value
  if (!el) return
  const sizer = el.querySelector('.virtual-scroller-sizer') as HTMLElement | null
  if (!sizer) return
  const px = `${sizerHeight.value}px`
  if (sizer.style.height === px) return
  sizer.style.height = px
}

/** Highest `scrollTop` the container can reach as its geometry stands NOW. */
const reachableScrollTop = (): number => {
  const el = containerRef.value
  if (!el) return 0
  return Math.max(0, el.scrollHeight - el.clientHeight)
}

const recordTailContentBottom = (
  childrenSum: number,
  firstIndex: number,
  lastIndex: number,
): void => {
  if (props.maxTailGap <= 0) return
  if (firstIndex < 0 || lastIndex < props.items.length - 1) {
    // This pass did not see the tail, so whatever bottom we recorded earlier describes a DIFFERENT window — and, if the list has grown since, a different list.
    tailContentBottom.value = 0
    return
  }
  // NOTE: `childrenSum <= 0` deliberately keeps the previous value rather than clearing it.
  if (childrenSum <= 0) return
  const bottom = (accumulatedHeights.value[firstIndex] ?? 0) + childrenSum
  if (bottom <= 0) return
  if (Math.abs(bottom - tailContentBottom.value) >= 1) tailContentBottom.value = bottom
}

const visibleItems = computed(() => {
  const { start, end } = visibleRange.value
  const result: { item: T; index: number }[] = []
  for (let i = start; i < end; i++) {
    const item = props.items[i]
    if (item !== undefined) result.push({ item, index: i })
  }
  return result
})

/** Live count of items currently rendered in the DOM (i.e. the length of `visibleItems`). */
const renderedCount = computed(() => {
  const { start, end } = visibleRange.value
  return Math.max(0, end - start)
})

/** The {start, end} range of items currently rendered. */
const effectiveRange = computed(() => {
  const { start, end } = visibleRange.value
  return { start, end }
})

const scrollInfo = computed(() => ({
  scrollTop: scrollTop.value,
  visibleStart: visibleRange.value.start,
  visibleEnd: visibleRange.value.end,
  totalItems: props.items.length,
  direction: scrollTop.value > lastScrollTop.value ? ('down' as const) : ('up' as const),
}))

// ── P2: contentShift emit (task_1787551495337_9) ─────────────────────────────
let prevShiftTop = -1
let prevShiftBottom = -1
let prevShiftTotal = -1
const emitContentShiftIfChanged = () => {
  const topSpacer = visibleRange.value.topSpacer
  const bottomSpacer = visibleRange.value.bottomSpacer
  const total = accumulatedHeights.value[props.items.length] ?? 0
  if (topSpacer === prevShiftTop && bottomSpacer === prevShiftBottom && total === prevShiftTotal)
    return
  prevShiftTop = topSpacer
  prevShiftBottom = bottomSpacer
  prevShiftTotal = total
  emit('contentShift', { topSpacer, bottomSpacer, total })
}

// Hysteresis dead-band for `measureItems()` ABOVE the viewport.
const HYSTERESIS_PX = 50

// How close to the bottom counts as "at the bottom" when `measureItems` decides which target the anchor compensation writes to (see `wasAtBottom` in that …
const AT_BOTTOM_SLACK_PX = 10

// Where the bottom sat as of the END of the previous pass (or the last `scrollToBottom`), or null before anything has positioned the list.
let settledBottom: number | null = null

// True once a measure pass has admitted at least one REAL height over an estimate.
let hasMeasuredItems = false

/** Whether this DOM reports geometry at all. jsdom answers 0 for EVERY element, so there a 0px item cannot be told apart from an item that draws nothing — and … */
let layoutReportsGeometry: boolean | null = null
const hasRealLayout = (): boolean => {
  if (typeof document === 'undefined') return false
  if (layoutReportsGeometry !== null) return layoutReportsGeometry
  const probe = document.createElement('div')
  probe.style.cssText = 'position:absolute;left:-9999px;top:0;width:1px;height:1px'
  document.body.appendChild(probe)
  layoutReportsGeometry = probe.offsetHeight > 0
  probe.remove()
  return layoutReportsGeometry
}

const measureItems = () => {
  if (!containerRef.value) return
  const content = containerRef.value.querySelector('.virtual-scroller-content')
  if (!content) return
  let changed = false
  // A 0px row is a MEASUREMENT only where the DOM really reports geometry (see `hasRealLayout`).
  const zeroIsMeasured = hasRealLayout()
  // ── Scroll-anchor compensation (2026-08-23; v2 prefix-delta 2026-09-23) ──
  const anchorIndex = findStartIndex()
  const prevScrollTop = containerRef.value.scrollTop
  // ── Was the reader at the bottom BEFORE this pass touched the model? ──────
  const wasAtBottom = prevScrollTop >= bottomScrollTop() - AT_BOTTOM_SLACK_PX
  const oldAnchorTop = accumulatedHeights.value[anchorIndex] ?? 0
  const pendingMeasurements: AnchorMeasurement[] = []
  const children = content.children
  // ── P1 perf: batched height writes (task_1787551495337_9) ──────────────
  const pendingWrites: Array<[string, number, number]> = []
  // Tail-gap cap inputs (see recordTailContentBottom): the summed real height of the rows currently in the DOM, plus the first/last indices they were stamped with.
  let renderedChildrenSum = 0
  let firstRenderedIndex = -1
  let lastRenderedIndex = -1
  for (let i = 0; i < children.length; i++) {
    const el = children[i] as HTMLElement
    // Read the index stamped by the renderer — the live computed range can already point at the next window while the DOM still shows the previous one (render is …
    const stamped = el.getAttribute?.('data-vs-index')
    const parsed =
      stamped !== null && stamped !== undefined && stamped !== '' ? Number(stamped) : NaN
    const stampedOk = Number.isInteger(parsed) && parsed >= 0 && parsed < props.items.length
    const realIndex = stampedOk ? parsed : visibleRange.value.start + i
    if (stampedOk) {
      if (firstRenderedIndex < 0) firstRenderedIndex = parsed
      lastRenderedIndex = parsed
    }
    const h = el.offsetHeight
    renderedChildrenSum += h > 0 ? quantizePx(h) : 0
    // An item that draws NOTHING is measured 0px: the compact fold turns a turn's other groups into empty wrappers, and a placeholder for each inflated the model …
    if (h > 0 || zeroIsMeasured) {
      // P1 perf: quantize to integer px.
      const heightPx = quantizePx(h)
      // Stable-key lookup: the height belongs to the ITEM (via its itemKey), not the array slot — immune to index shifts from messageGroups regrouping (the …
      const key = keyOf(realIndex)
      const prev = itemHeights.value.get(key)
      // First measurement (prev === undefined) always writes.
      const aboveAnchor = realIndex < anchorIndex
      const admitted =
        prev === undefined ||
        (aboveAnchor ? Math.abs(heightPx - prev) > HYSTERESIS_PX : heightPx !== prev)
      if (admitted) {
        pendingMeasurements.push({ index: realIndex, newHeight: heightPx, oldHeight: prev })
        pendingWrites.push([key, heightPx, realIndex])
        changed = true
      }
    }
  }
  // Record the measured tail bottom on BOTH paths — a no-op pass still carries a fresh window geometry (e.g. the user scrolled: same stored heights, different rows …
  recordTailContentBottom(renderedChildrenSum, firstRenderedIndex, lastRenderedIndex)
  if (!changed) {
    // Even a pass that wrote nothing establishes where the bottom is, and the NEXT pass has to judge against it (see `settledBottom`).
    settledBottom = bottomScrollTop()
    return
  }
  for (const [key, heightPx, realIndex] of pendingWrites) {
    itemHeights.value.set(key, heightPx)
    // A real height is now in the model, so every published number describes the content rather than the estimate (see `hasMeasuredItems`).
    hasMeasuredItems = true
    // Feed the adaptive estimator so future unmeasured items inherit a realistic median instead of the static prop guess.
    if (heightPx > 0) heightEstimator.observe(heightPx)
    // Track the measurement frontier: the learned median is only trusted for items at or before this index (see estimateHeight).
    if (realIndex > maxMeasuredIndex) maxMeasuredIndex = realIndex
  }
  // Freeze the placeholder once the estimator's window is full — from here on `estimateHeight` may only change for a MEASURED row, so no scroll gesture can rescale …
  if (!heightEstimator.isFrozen && heightEstimator.sampleCount >= ESTIMATOR_FREEZE_SAMPLES) {
    heightEstimator.freeze()
  }
  updateAccumulatedHeights()
  // Prefixes moved: recompute the measured tail bottom against the fresh model so the cap describes where the content actually sits now.
  recordTailContentBottom(renderedChildrenSum, firstRenderedIndex, lastRenderedIndex)
  // Post-pass prefix at the same anchor index: the delta vs `oldAnchorTop` is the compensation (v2 prefix-delta — covers measured writes AND estimator drift for …
  const newAnchorTop = accumulatedHeights.value[anchorIndex] ?? 0

  // NOTE (2026-08-25): a "tail-exact clamp" (force-write rendered tail heights + shrink the sizer to the real content bottom when the window shows the last item) …
  syncSizerHeightToDom()
  const result = computeAnchorCompensation({
    anchorIndex,
    prevScrollTop,
    oldAnchorTop,
    newAnchorTop,
    // Read the bottom edge AFTER the rebuild, so the target is the bottom as it is now.
    atBottomTarget: wasAtBottom ? bottomScrollTop() : undefined,
    maxScrollTop: reachableScrollTop(),
  })
  // ── The write gate is `shiftPx !==
  if (result.shiftPx !== 0 && !isPreservingScroll.value) {
    // Mark BEFORE the write: assigning .scrollTop fires a native scroll event that onScroll must label as programmatic (see the counter comment above — without this …
    if (import.meta.env.DEV && vsLogger.value) {
      try {
        vsLogger.value.info({
          scrollTop: prevScrollTop,
          scrollHeight: containerRef.value.scrollHeight,
          clientHeight: containerRef.value.clientHeight,
          messages: props.items.length,
          isAtBottom: false,
          containerInfo: {
            null: false,
            offsetHeight: containerRef.value.offsetHeight,
            offsetParent: containerRef.value.offsetParent
              ? (containerRef.value.offsetParent as HTMLElement).tagName
              : null,
          },
          reason: 'measure-compensation',
          caller: 'VirtualScroller.measureItems',
          extra: {
            anchorIndex,
            prevScrollTop,
            newScrollTop: result.newScrollTop,
            shiftPx: result.shiftPx,
            target: result.target,
            wasAtBottom,
            // True when the target exceeded the reachable range even after the sizer was brought up to date — the view could not be held exactly, and the NEXT pass will …
            clampedToMax: result.clampedToMax,
            reachableScrollTop: reachableScrollTop(),
            pendingMeasurements,
            pendingWritesLen: pendingWrites.length,
          },
          // eslint-disable-next-line @typescript-eslint/no-explicit-any
        } as any)
      } catch {}
    }
    markProgrammaticScroll()
    containerRef.value.scrollTop = result.newScrollTop
    scrollTop.value = result.newScrollTop
    lastScrollTop.value = result.newScrollTop
  }
  // Re-read rather than reusing the target: the branch above may not have run (shiftPx 0, or a preserve window), and the tail cap can move the bottom independently …
  settledBottom = bottomScrollTop()
}

// ── Pre-paint measurement on rendered-range change ───────────────────────────
let _inPrePaintMeasure = false
let _prePaintTrailing: ReturnType<typeof setTimeout> | null = null
let _prePaintScheduled = false
const schedulePrePaintMeasure = () => {
  if (_inPrePaintMeasure || isPreservingScroll.value || _prePaintScheduled) return
  _prePaintScheduled = true
  nextTick(() => {
    _prePaintScheduled = false
    if (_inPrePaintMeasure || isPreservingScroll.value) return
    _inPrePaintMeasure = true
    try {
      measureItems()
    } finally {
      _inPrePaintMeasure = false
    }
    // Trailing sweep: if the compensation shifted the window again, one more pass settles it (debounced, off the critical path).
    if (_prePaintTrailing) clearTimeout(_prePaintTrailing)
    _prePaintTrailing = setTimeout(() => {
      if (!_inPrePaintMeasure && !isPreservingScroll.value) measureItems()
    }, 50)
  })
}

let loadMoreDebounce: ReturnType<typeof setTimeout> | null = null
let measureDebounce: ReturnType<typeof setTimeout> | null = null

const onScroll = (e: Event) => {
  const target = e.target as HTMLElement
  // Timestamp for the idle content-size observer below: it stays quiet shortly after a scroll because the scroll path already measures.
  lastScrollEventAt = Date.now()
  // Keep `containerHeight.value` in sync with the live DOM reading.
  containerHeight.value = target.clientHeight
  const st = target.scrollTop
  const dir = st > lastScrollTop.value ? 'down' : 'up'
  // NOTE (P1 perf review, task_1787551495337_9): this write stays SYNCHRONOUS.
  scrollTop.value = st
  lastScrollTop.value = st
  // Consume the programmatic flag BEFORE the emit: a markProgrammatic bump (from measureItems' compensation write or endPreserve's restoration) belongs to exactly …
  const isProgrammatic = consumeProgrammaticScroll()
  emit('scroll', st, dir as 'up' | 'down', target, isProgrammatic)

  if (loadMoreDebounce) clearTimeout(loadMoreDebounce)
  loadMoreDebounce = setTimeout(() => {
    if (isPreservingScroll.value) {
      // Don't log here — the parent is mid-preserve, suppression is expected.
      return
    }
    const hasMore = props.totalCount === 0 || props.items.length < props.totalCount
    if (!hasMore) {
      emit('loadMoreSuppressed', 'no-more-items')
      return
    }
    // Defensive guard: if the container isn't actually scrollable (scrollHeight ≤ clientHeight, i.e. content fits in viewport), `st < loadMoreThreshold` is trivially …
    const isScrollable = target.scrollHeight > target.clientHeight
    if (!isScrollable) {
      emit('loadMoreSuppressed', 'not-scrollable')
      return
    }
    const threshold = effectiveLoadMoreThreshold.value
    if (props.loadMoreAtTop) {
      if (st < threshold && props.items.length > 0) {
        emit('loadMore')
      } else if (st < threshold && props.items.length === 0) {
        // User is near the top but there are no items yet — nothing to "load more of".
        emit('loadMoreSuppressed', 'no-items')
      }
      // else: user is just not near the top yet — normal scrolling, not a suppression.
    } else {
      const bottom = target.scrollHeight - st - target.clientHeight
      if (bottom < threshold && props.items.length > 0) {
        emit('loadMore')
      } else if (bottom < threshold && props.items.length === 0) {
        emit('loadMoreSuppressed', 'no-items')
      }
      // else: user is just not near the bottom yet
    }
  }, 200)

  // Max-wait, NOT reset-per-event: the previous clearTimeout+reschedule pushed the deadline out another 50ms on EVERY scroll event, so the trailing measure never …
  if (!measureDebounce) {
    measureDebounce = setTimeout(() => {
      measureDebounce = null
      measureItems()
    }, 50)
  }
  // Re-measure pre-paint when the scroll moved the rendered window (same contract the old `effectiveRange` watcher provided; deduped against the onUpdated sync …
  schedulePrePaintMeasure()
}

/** PHASE 1 — call BEFORE mutating items array. */
const beginPreserve = (newItemsCount: number) => {
  if (!containerRef.value || newItemsCount <= 0) return
  isPreservingScroll.value = true
  _pendingNewItemsCount = newItemsCount

  // NOTE (2026-08-26 stable-keys fix): the old index-shift remap (rebuilding the Map with every key +N) is GONE.
  if (newItemsCount > 0) {
    maxMeasuredIndex += newItemsCount
    updateAccumulatedHeights()
  }

  const content = containerRef.value.querySelector('.virtual-scroller-content')
  const anchorEl = content
    ? (content.querySelector('[data-vs-index="0"]') as HTMLElement | null)
    : null

  _anchorOffsetTopBefore = anchorEl ? anchorEl.offsetTop : 0
  console.log('[beginPreserve] anchorEl found:', !!anchorEl, 'offsetTop:', _anchorOffsetTopBefore)
}

/** PHASE 2 — call AFTER items array has been mutated. */
const endPreserve = async () => {
  if (!containerRef.value || _pendingNewItemsCount <= 0) {
    isPreservingScroll.value = false
    return
  }

  const n = _pendingNewItemsCount
  forceRenderUpTo.value = n - 1

  await nextTick()
  await new Promise<void>((r) => requestAnimationFrame(() => r()))
  await new Promise<void>((r) => requestAnimationFrame(() => r()))

  measureItems()
  updateAccumulatedHeights()

  // Try to find anchor at its new index
  const content = containerRef.value!.querySelector('.virtual-scroller-content')
  const anchorEl = content
    ? (content.querySelector(`[data-vs-index="${n}"]`) as HTMLElement | null)
    : null

  if (anchorEl) {
    const newST = anchorEl.offsetTop
    console.log('[endPreserve] strategy A — anchorEl.offsetTop:', newST)
    // Programmatic write — see markProgrammaticScroll's comment.
    markProgrammaticScroll()
    containerRef.value!.scrollTop = newST
    scrollTop.value = newST
    lastScrollTop.value = newST
  } else {
    // Fallback: sum measured heights of new items (key-based lookup)
    let sum = 0
    for (let i = 0; i < n; i++) sum += itemHeights.value.get(keyOf(i)) ?? props.defaultItemHeight
    console.log('[endPreserve] strategy B — sum:', sum)
    markProgrammaticScroll()
    containerRef.value!.scrollTop = sum
    scrollTop.value = sum
    lastScrollTop.value = sum
  }

  forceRenderUpTo.value = -1
  isPreservingScroll.value = false
  _pendingNewItemsCount = 0
  console.log('[endPreserve] END scrollTop:', containerRef.value!.scrollTop)
}

const writeScrollTop = (target: number, behavior: ScrollBehavior): void => {
  const el = containerRef.value
  if (!el) return
  const clamped = Math.max(0, Math.min(target, reachableScrollTop()))
  el.scrollTo({ top: clamped, behavior })
  if (behavior !== 'auto') return
  scrollTop.value = clamped
  lastScrollTop.value = clamped
}

const scrollToIndex = (index: number, behavior: ScrollBehavior = 'auto') => {
  writeScrollTop(accumulatedHeights.value[index] ?? index * props.defaultItemHeight, behavior)
}
const scrollToTop = (behavior: ScrollBehavior = 'auto') => writeScrollTop(0, behavior)
/** THE bottom, as a scrollTop — the single ruler for "is the reader at the end". */
const bottomScrollTop = (): number => {
  const el = containerRef.value
  if (!el) return 0
  const clientHeight = el.clientHeight
  const domEdge = Math.max(0, el.scrollHeight - clientHeight)
  // Real-bottom override (blank-viewport fix) — kept, but now safe because sizerHeight is stable (modelTotal only, no visibleRange dependency).
  const range = visibleRange.value
  const content = el.querySelector('.virtual-scroller-content')
  const contentH = content ? (content as HTMLElement).offsetHeight : 0
  if (range.end >= props.items.length && contentH > 0) {
    const realBottom = range.topSpacer + contentH
    const target = Math.max(0, realBottom - clientHeight)
    if (domEdge - target > HYSTERESIS_PX) return target
  }
  return domEdge
}

const scrollToBottom = (behavior: ScrollBehavior = 'auto') => {
  if (!containerRef.value) return
  const target = bottomScrollTop()
  containerRef.value.scrollTo({ top: target, behavior })
  // An explicit jump to the bottom is the strongest possible statement that the reader is following the tail, and the next measure pass has to honour it (see …
  settledBottom = target
}
/** Put the container at an arbitrary scrollTop, clamped to the DOM max. ── Why this clears `settledBottom` ───────────────────────────────────────── … */
const scrollToPosition = (position: number, behavior: ScrollBehavior = 'auto') => {
  if (!containerRef.value) return
  const max = containerRef.value.scrollHeight - containerRef.value.clientHeight
  if (max <= 0) return
  settledBottom = null
  writeScrollTop(position, behavior)
}
const scrollToItem = (index: number, behavior: ScrollBehavior = 'auto') =>
  scrollToIndex(index, behavior)

// Full recompute of the height model from the live DOM (2026-08-25 append-gap fix).
const rekeyHeight = (oldKey: string, newKey: string): boolean => {
  if (!oldKey || !newKey || oldKey === newKey) return false
  const h = itemHeights.value.get(oldKey)
  if (h === undefined) return false
  if (!itemHeights.value.has(newKey)) itemHeights.value.set(newKey, h)
  itemHeights.value.delete(oldKey)
  updateAccumulatedHeights()
  return true
}
const remeasure = () => {
  measureItems()
}

let ro: ResizeObserver | null = null
// ── Idle content-size observer ─────────────────────────────────────────────
let contentRO: ResizeObserver | null = null
let contentROTimer: ReturnType<typeof setTimeout> | null = null
const measureTimers = new Set<ReturnType<typeof setTimeout>>()
const scheduleMeasure = (delayMs: number): void => {
  const timer = setTimeout(() => {
    measureTimers.delete(timer)
    measureItems()
  }, delayMs)
  measureTimers.add(timer)
}
let lastContentH = -1
let lastScrollEventAt = 0
const CONTENT_RO_DEBOUNCE_MS = 150
const CONTENT_RO_MIN_DELTA_PX = 2
// ── Watch-free sync block ──────────────────────────────────────────────────
let prevRangeStart = -1
let prevRangeEnd = -1
onMounted(() => {
  emitScrollableIfChanged()
  syncItemsLength()
  const { start, end } = effectiveRange.value
  prevRangeStart = start
  prevRangeEnd = end
  applyTailCapLatch(end)
  emitContentShiftIfChanged()
})
onUpdated(() => {
  emitScrollableIfChanged()
  syncItemsLength()
  emitContentShiftIfChanged()
  const { start, end } = effectiveRange.value
  const rangeMoved = start !== prevRangeStart || end !== prevRangeEnd
  prevRangeStart = start
  prevRangeEnd = end
  applyTailCapLatch(end)
  if (rangeMoved) schedulePrePaintMeasure()
})
onMounted(() => {
  if (containerRef.value) {
    containerHeight.value = containerRef.value.clientHeight
    ro = new ResizeObserver(() => {
      if (containerRef.value) containerHeight.value = containerRef.value.clientHeight
      nextTick(() => scheduleMeasure(50))
    })
    ro.observe(containerRef.value)
    const contentEl = containerRef.value.querySelector(
      '.virtual-scroller-content',
    ) as HTMLElement | null
    if (contentEl && typeof ResizeObserver !== 'undefined') {
      lastContentH = contentEl.offsetHeight
      contentRO = new ResizeObserver(() => {
        const content = containerRef.value?.querySelector(
          '.virtual-scroller-content',
        ) as HTMLElement | null
        if (!content) return
        const h = content.offsetHeight
        if (Math.abs(h - lastContentH) < CONTENT_RO_MIN_DELTA_PX) {
          lastContentH = h
          return
        }
        lastContentH = h
        if (isPreservingScroll.value || _inPrePaintMeasure) return
        if (Date.now() - lastScrollEventAt < CONTENT_RO_DEBOUNCE_MS) return
        if (contentROTimer) clearTimeout(contentROTimer)
        contentROTimer = setTimeout(() => {
          if (!isPreservingScroll.value && !_inPrePaintMeasure) measureItems()
        }, CONTENT_RO_DEBOUNCE_MS)
      })
      contentRO.observe(contentEl)
    }
  }
  nextTick(() => scheduleMeasure(100))
})
onUnmounted(() => {
  ro?.disconnect()
  contentRO?.disconnect()
  if (contentROTimer) clearTimeout(contentROTimer)
  if (loadMoreDebounce) clearTimeout(loadMoreDebounce)
  if (measureDebounce) clearTimeout(measureDebounce)
  if (_prePaintTrailing) clearTimeout(_prePaintTrailing)
  if (programmaticResetTimer) clearTimeout(programmaticResetTimer)
  for (const timer of measureTimers) clearTimeout(timer)
  measureTimers.clear()
})

defineExpose({
  scrollToIndex,
  scrollToTop,
  scrollToBottom,
  bottomScrollTop,
  /** Where the bottom sat as of the END of the last pass (or the last `scrollToBottom`), or null before anything has positioned the list. */
  get settledBottom() {
    return settledBottom
  },
  /** Whether any real height has replaced an estimate yet. */
  get hasMeasuredItems() {
    return hasMeasuredItems
  },
  scrollToPosition,
  scrollToItem,
  remeasure,
  rekeyHeight,
  beginPreserve,
  endPreserve,
  preserveScrollPosition: endPreserve, // legacy alias
  scrollInfo,
  containerRef,
  isPreservingScroll,
  isScrollable,
  effectiveLoadMoreThreshold,
  renderedCount,
  effectiveRange,
  sizerHeight,
  modelTotal,
  tailContentBottom,
})
</script>

<template>
  <div ref="containerRef" class="virtual-scroller" @scroll="onScroll">
    <!--
      P2 (task_1787551495337_9): the two spacer DIVs are replaced by ONE
      sizer sized to the total content height, with the rendered window
      absolutely positioned inside it and moved via `translate3d`.

      Why: mutating a spacer's `height` style invalidates layout for the
      whole scroller on every window shift. A transform is a composited
      change — no layout, no paint of the shifted content — so window
      moves cost a GPU composite instead of a full relayout.

      The sizer keeps `scrollHeight` correct (the browser needs the total
      height to draw a scrollbar and clamp scrollTop); the transform puts
      the visible window at its exact offset within that height.
    -->
    <div class="virtual-scroller-sizer" :style="{ height: sizerHeight + 'px' }">
      <!--
        minHeight keeps the content window at least one viewport tall.
        The rendered window always covers the viewport in MODEL space
        (estimates), but the real DOM can be much shorter when estimates
        overshoot reality — e.g. a tail of short tool-card groups measured
        against a ~400px running median, plus up to HYSTERESIS_PX of
        residue per item that never corrects. Without this the content
        div collapses to half the chat height at the bottom with blank
        sizer below it. The content is absolutely positioned (out of
        flow) and measureItems reads child heights, so this never feeds
        back into the sizer model or the compensation loop.
      -->
      <div
        class="virtual-scroller-content"
        :style="{
          transform: `translate3d(0px, ${visibleRange.topSpacer}px, 0px)`,
          minHeight: containerHeight > 0 ? `${containerHeight}px` : undefined,
        }"
      >
        <!-- :key is the STABLE itemKey (not the index): Vue reuses the
             correct DOM node per item across index shifts (regrouping,
             prepends) — less re-render flicker, and offsetHeight mocks
             / real heights travel with their item. -->
        <div v-for="{ item, index } in visibleItems" :key="keyOf(index)" :data-vs-index="index">
          <slot :item="item" :index="index" />
        </div>
      </div>
    </div>
  </div>
</template>

<style scoped>
.virtual-scroller {
  overflow-y: auto;
  /** Disable CSS scroll anchoring. The default `overflow-anchor: auto` makes the browser adjust
   * scrollTop by the spacer delta when the topSpacer mutates — which happens every time
   * `measureItems` re-measures buffer items. */
  overflow-anchor: none;
  /** Use `flex: 1 1 0` instead of `height: 100%` so the scroller participates in the parent's flex
   * layout properly. */
  flex: 1 1 0;
  min-height: 0;
  /** No explicit min-height: the Tailwind `min-h-0` class on the parent (set by every consumer:
   * ChatsList's chat list div, ChatView's messages wrapper) provides the "shrink below content
   * size" behavior needed for the scroller to participate correctly in a flex column. */
}
.virtual-scroller-content {
  display: flex;
  flex-direction: column;
  /** P2: the content window is absolutely positioned inside the sizer and moved with translate3d
   * (see template comment). `will-change: transform` promotes it to its own compositor layer so
   * window shifts are a GPU composite instead of a layout+paint. */
  position: absolute;
  left: 0;
  right: 0;
  top: 0;
  will-change: transform;
}
.virtual-scroller-sizer {
  position: relative;
}
/** P1 perf: CSS containment on item wrappers (task_1787551495337_9). `contain: layout style` tells
 * the browser each item's internals cannot affect layout outside its wrapper box (and vice versa). */
.virtual-scroller-content > [data-vs-index] {
  contain: layout style;
}
</style>
