<script setup lang="ts" generic="T">
import { ref, computed, onMounted, onUnmounted, onUpdated, nextTick } from 'vue'

import { computeLoadMoreThreshold } from './virtualScrollerThreshold'
import { computeAnchorCompensation, type AnchorMeasurement } from './virtualScrollerScrollAnchor'
import { quantizePx, AdaptiveItemHeightEstimator } from './virtualScrollerPerf'
import { createScrollLogger } from './scrollLogger'

const props = withDefaults(
  defineProps<{
    /**
     * The full list of items to virtualize. The scroller only mounts the
     * items currently visible in the viewport (plus a small buffer above
     * and below), so passing thousands of items is fine — the DOM stays
     * small. Each item is rendered via the default scoped slot, receiving
     * `{ item, index }` so you can render whatever you need.
     *
     * Indexing is significant: the scroller uses the item's index in this
     * array as its key and as the height-measurement key. **Avoid splicing
     * items into the middle of the array at runtime** unless you also call
     * `beginPreserve`/`endPreserve` to keep the visible range stable.
     * Appending to the end (e.g. chat messages, log lines) and prepending
     * to the start (e.g. paginated history, with `beginPreserve`/
     * `endPreserve`) are both well-supported.
     */
    items: T[]
    /**
     * Total number of items that exist on the server / in the source of
     * truth, if known. Used to decide whether `loadMore` should still
     * fire when the user nears the edge.
     *
     * - Default `0` means "unknown / unbounded" — `loadMore` is allowed
     *   to fire whenever the user is within `loadMoreThreshold` of the
     *   load edge. The parent is responsible for stopping it (e.g. by
     *   checking a `hasMore` flag in its handler).
     * - Set this to the real total when you know it (e.g. `data.total`
     *   from your API) to let the scroller stop firing `loadMore` on
     *   its own once `items.length >= totalCount`.
     */
    totalCount?: number
    /**
     * Number of extra items to render **on each side** (above AND below)
     * the visible viewport. So `buffer=20` means 20 items above + 20
     * items below + the visible items themselves.
     *
     * Worked example with `defaultItemHeight=200`, `containerHeight=800`:
     *   - buffer=0  → 4 items in the DOM  (4 visible, no overscan)
     *   - buffer=5  → 14 items in the DOM (4 visible + 5 above + 5 below)
     *   - buffer=20 → 44 items in the DOM (4 visible + 20 above + 20 below)
     *
     * A larger buffer means smoother scrolling (fewer "pop in" moments
     * as the user scrolls) at the cost of more DOM nodes. The default
     * of 5 is a good balance for most text/list UIs. For tall items
     * (chat bubbles, cards with images) you may want to lower this;
     * for short uniform items (log lines, search results) you can
     * raise it.
     *
     * To read the live rendered count from the parent, use the
     * `renderedCount` exposed on the component instance (see
     * `defineExpose` below) or the `scrollInfo` object.
     */
    buffer?: number
    /**
     * Estimated height in pixels for an item whose real height hasn't
     * been measured yet. The scroller uses this to size the top/bottom
     * spacers before measurement completes, which affects the initial
     * `scrollHeight` and therefore the initial scroll position.
     *
     * Pick a value close to your **median** real item height:
     * - Too small → the initial render undershoots `scrollHeight`, so
     *   after measurement the user appears scrolled up by the difference
     *   (the spacers grew). Usually fine if you "stick to bottom" — see
     *   the chat viewer for an example using a MutationObserver on the
     *   spacers to re-stick after measurement.
     * - Too large → the initial render overshoots `scrollHeight`; the
     *   browser clamps `scrollTop` to the real bottom, so the user
     *   lands correctly but the spacers briefly show extra blank space
     *   that snaps away.
     *
     * Default 100px suits most text rows. Chat bubbles with avatars and
     * markdown often want 150-250px.
     */
    defaultItemHeight?: number
    /**
     * Distance in pixels from the load edge at which the scroller emits
     * `loadMore`. If `loadMoreAtTop` is `true` (paginating older items
     * by prepending), this is measured from the top of the scrollable
     * area; otherwise from the bottom.
     *
     * Acts as the **absolute floor** for the effective threshold. The
     * actual threshold used in the `loadMore` check is
     * `max(loadMoreThreshold, containerHeight * loadMoreThresholdRatio)`,
     * so the scroller fires `loadMore` when the user is within EITHER
     * the floor OR the proportional distance of the load edge —
     * whichever is larger.
     *
     * Default 200px keeps the trigger safe on small viewports and during
     * the 0×0 initial-mount flicker. Raise it (e.g. 400-600px) for very
     * slow APIs that need a longer fetch head-start.
     *
     * The emit is debounced (~200ms) and is suppressed while
     * `beginPreserve`/`endPreserve` is in flight, so a single
     * scroll-to-edge gesture won't fire `loadMore` multiple times.
     */
    loadMoreThreshold?: number
    /**
     * Proportion of the container's visible height (`clientHeight`) that
     * the effective threshold should track. Combined with
     * `loadMoreThreshold` as `effective = max(loadMoreThreshold,
     * containerHeight * loadMoreThresholdRatio)`.
     *
     * Default `0.5` means "fire `loadMore` when the user is within half
     * a screen of the load edge" — the same heuristic used by Slack,
     * Discord, and iMessage. On a 1000 px viewport this gives a 500 px
     * effective threshold; on a 600 px viewport, 300 px. The absolute
     * `loadMoreThreshold` floor (200 px) protects tiny viewports where
     * the proportional value would be smaller.
     *
     * Set to `0` to opt out of the proportional mode entirely
     * (floor only). The threshold is computed in
     * `computeLoadMoreThreshold` (a pure helper, unit-tested).
     */
    loadMoreThresholdRatio?: number
    /**
     * If `true`, the scroller emits `loadMore` when the user scrolls
     * within `loadMoreThreshold` of the **top** — use this when you're
     * prepending older items (chat history, activity feeds, logs).
     * `loadMoreAtTop` should be paired with `beginPreserve`/`endPreserve`
     * in the parent so the user's scroll position doesn't jump when the
     * new items are inserted at index 0.
     *
     * If `false` (the default), the scroller emits `loadMore` when the
     * user scrolls within `loadMoreThreshold` of the **bottom** — use
     * this for "load more on demand" patterns where new content is
     * appended past the visible area.
     */
    loadMoreAtTop?: boolean
    /**
     * Stable identity function for items (2026-08-26 stable-keys fix).
     * Returns a string that uniquely identifies the item's CONTENT —
     * e.g. a DB id — and survives position changes in the array.
     *
     * WHY: the height cache was keyed by ARRAY INDEX. ChatView renders
     * `messageGroups`, a computed that re-merges/re-filters on every
     * SSE event — so a group count change (thinking-only row dropped,
     * tool row arriving, streaming row swapped) SHIFTS every later
     * index. The stored height for index k then described a different
     * row: a 40px tool-card height landed on a 2000px markdown message
     * and vice versa. The sizer became the sum of mismatched heights →
     * wildly too tall → stick-to-bottom landed in blank space (the
     * "sizer 16034px vs real content 13720px" DevTools evidence).
     *
     * With `itemKey`, heights are keyed by identity: a row keeps its
     * own measured height wherever it moves. Index shifts become
     * harmless. Also used as the v-for key so Vue reuses the correct
     * DOM node per item (less re-render flicker during streaming).
     *
     * Default: `String(index)` — index-keyed, the historical behavior.
     * Consumers with stable ids (ChatView: `group.messages[0].id`)
     * SHOULD pass this prop.
     */
    itemKey?: (item: T, index: number) => string
    /**
     * Hard cap, in pixels, on the blank region the user can scroll into
     * BELOW the last rendered row.
     *
     * WHY: the sizer height is the height MODEL (Σ measured/estimated row
     * heights). Unmeasured rows are estimated from the running median of
     * the measured ones, so a tail of short rows (one-line tool cards)
     * inherits a tall median and the model overshoots the real content by
     * thousands of px. `scrollToBottom` still lands on the real bottom,
     * but the browser lets the user scroll on into the overshoot — a
     * blank viewport below the last message (user report + DevTools:
     * `sizer 26796px`, `content translate3d(0, 23406px)`, `min-height
     * 708px` → ~2682px of empty sizer below the content box).
     *
     * So while the rendered window covers the LAST item (i.e. the real
     * bottom is directly measurable), the sizer is clamped to
     * `realBottom + maxTailGap`. The model is never written — the cap is
     * a render-time `min()` on the style binding, so it cannot feed back
     * into the measure/scroll loop (PR #355's clamp was removed because
     * its input went stale and inflated the sizer; a cap can only ever
     * SHRINK the reserved void, never grow it).
     *
     * `0` disables the cap (sizer is always the full model total).
     */
    maxTailGap?: number
    /**
     * Debug chat id for VirtualScroller internal logging (2026-09-02).
     * When provided, the scroller creates its own scrollLogger and emits
     * sizer-recomputed / measure-compensation / scroll-to-bottom-target
     * lines with the same chatId tag as ChatView, so you can correlate
     * sizerHeight flips with spacer-resize-stick in one grep.
     * When omitted, internal logging is silent (no perf cost).
     */
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
  /**
   * Fired when one of the scroller's internal guards prevented
   * `loadMore` from being emitted — i.e. the user WAS within the
   * load edge but the scroller still chose not to emit (because
   * `isPreservingScroll`, `!hasMore`, `!isScrollable`, or
   * `items.length === 0`). Lets the parent log "user reached top,
   * but lazy load was blocked by X" so the "why didn't it load?"
   * question is answerable from the logs.
   *
   * The `guard` payload is a short identifier — see the emit sites
   * in `onScroll` below for the full list. NOT emitted when the
   * user simply isn't near the edge (that's normal scrolling, not
   * a suppression).
   */
  loadMoreSuppressed: [guard: string]
  /**
   * Fired on every scroll event. `target` is the actual DOM element
   * that dispatched the event — guaranteed non-null by the browser
   * for the lifetime of the event handler. Parents should prefer
   * `target` over walking the component's `containerRef` ref chain:
   * the ref chain is null during mount/remount races (chat switch,
   * initial mount before Vue binds the template ref, v-if toggle),
   * but `target` is always live for the duration of the handler.
   *
   * The component-level `containerRef` is still exposed for the
   * initial-load, scroll-to-bottom, and other controlled paths that
   * don't have an event to extract the element from.
   *
   * `isProgrammatic` (4th arg, 2026-08-25 append-gap fix): true when
   * this scroll event was caused by the scroller's OWN scrollTop
   * write — the anchor-compensation inside `measureItems()` (and the
   * `endPreserve` restoration). Assigning `.scrollTop` fires a real
   * native `scroll` event that is otherwise indistinguishable from a
   * user gesture. ChatView's `handleVirtualScroll` uses this to keep
   * `userScrolledUp` honest: a compensation write that happens to
   * move scrollTop DOWN (measured height < estimate — common when
   * streamed markdown settles shorter) must NOT flip `isAtBottom`
   * to false, or the auto-stick disengages and every later SSE
   * chunk's contentShift hits the `spacer-resize-skip` guard — the
   * "gap below the last message grows forever" symptom.
   */
  scroll: [
    scrollTop: number,
    direction: 'up' | 'down',
    target: HTMLElement,
    isProgrammatic: boolean,
  ]
  /**
   * Fired whenever the scroller's `isScrollable` computed value
   * CHANGES (not on every re-evaluation — only when the boolean
   * flips from one value to the other). The parent uses this to
   * show/hide UI affordances (e.g. a "Load more messages" button)
   * that only make sense when the user has no other way to reach
   * older content. The event-based pattern is used instead of
   * exposing `isScrollable` via the template ref because
   * component-instance proxies do not establish reactive
   * dependencies on inner ref values when accessed through
   * `childRef.value.someRef.value` — the parent would not
   * re-render on changes. With this event, the parent maintains
   * a plain `ref<boolean>` that the template can react to.
   */
  scrollabilityChange: [scrollable: boolean]
  /**
   * Fired whenever the scroller's content positioning values change —
   * i.e. when `topSpacer`, `bottomSpacer`, or the total content height
   * changes as a result of scrolling, measurement, or item-list updates.
   *
   * P2 (task_1787551495337_9): with transform-based positioning there
   * are no spacer DIVs whose `style.height` mutations a parent
   * MutationObserver could watch (ChatView's previous stick-to-bottom
   * signal). This event is the explicit replacement: parents that need
   * to react to "the virtual layout moved" (re-stick to bottom after
   * measurement drift, etc.) listen here instead.
   *
   * Payload: `{ topSpacer, bottomSpacer, total }` in px.
   */
  contentShift: [shift: { topSpacer: number; bottomSpacer: number; total: number }]
}>()

// ── Deep-dive logger (2026-09-02) ──────────────────────────────────────────
// When debugChatId is provided, internal sizer/measure/scrollToBottom
// decisions are logged via the same scrollLogger infra as ChatView,
// so a single `grep chat=task_...` shows both sides of the loop.
const vsLogger = computed(() => (props.debugChatId ? createScrollLogger(props.debugChatId) : null))

const containerRef = ref<HTMLElement | null>(null)
// The content div needs no template ref: the sizer is a pure function of the
// height model (see sizerHeight), and per-child heights come from measureItems.
const scrollTop = ref(0)
const lastScrollTop = ref(0)
const containerHeight = ref(0)
// Heights keyed by STABLE ID (itemKey(item)), not array index — see the
// itemKey prop JSDoc for the index-shift corruption this prevents.
const itemHeights = ref<Map<string, number>>(new Map())
const accumulatedHeights = ref<number[]>([0])
const isPreservingScroll = ref(false)
const forceRenderUpTo = ref(-1)

/**
 * Stable identity for the item at `index`. Falls back to the index
 * string when no `itemKey` prop is supplied (historical behavior).
 */
const keyOf = (index: number): string => {
  const item = props.items[index]
  if (item === undefined) return `#${index}`
  return props.itemKey ? props.itemKey(item, index) : `#${index}`
}

// ── Programmatic-scroll tracking (2026-08-25 append-gap fix) ────────────────
//
// The scroller writes `containerRef.scrollTop` itself in two places:
// the anchor-compensation inside `measureItems()` and the restoration
// in `endPreserve()`. Assigning `.scrollTop` fires a REAL native
// `scroll` event — indistinguishable from a user gesture by the time
// it reaches `onScroll`. Without a flag, ChatView's
// `handleVirtualScroll` reads a downward compensation write (measured
// height < estimate) as `userScrolledUp = true`, flips `isAtBottom`
// to false, and the auto-stick disengages for the rest of the stream
// — every later contentShift hits the `spacer-resize-skip` guard and
// the gap below the last message grows with each chunk.
//
// Same counter pattern as scrollLogger.markProgrammatic (which only
// labels LOG lines — it has no influence on the stick decision).
// `pendingProgrammaticScrolls` is bumped BEFORE the write and consumed
// by the very next `onScroll`, which forwards the flag on the `scroll`
// emit. The 100ms reset timer is the same leak-guard scrollLogger
// uses (scroll event never fires because scrollTop didn't change).
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
//
// `props.defaultItemHeight` is a static guess; real chat bubbles are almost
// always taller, so unmeasured items were systematically under-estimated and
// every measurement pass triggered anchor compensation. The estimator learns
// the running MEDIAN of measured heights (robust against one giant code-block
// message) and supplies far better estimates for never-measured items → fewer
// wrong spacers → fewer compensation shifts → smoother scroll.
//
// Reset when the items array is swapped for a different list (length → 0 or
// identity change via the onUpdated prev-length guard below) so one chat's height
// profile doesn't bleed into another's.
const heightEstimator = new AdaptiveItemHeightEstimator({
  seed: props.defaultItemHeight,
  maxSamples: 64,
})

// Highest index that has a real measured height (vestigial frontier,
// 2026-09-06: estimateHeight now trusts the running median for ALL
// unmeasured items — the old index-gated fallback to the static prop
// collapsed the tail to 64px/item and shrank the list. Kept updated by
// measureItems/beginPreserve for diagnostics; not read by the model.)
//
// WHY the median is safe for the tail now (gap-below-last-message bug,
// reported after P1+P2): the median CAN be taller than a fresh streaming
// bubble, extending the sizer past real content — but stick-to-bottom
// targets the real DOM bottom (scrollToBottom real-bottom override), not
// scrollHeight, so the viewport never parks in the over-estimated
// region. And the sizer itself is scroll-independent (see sizerHeight),
// so an overshoot cannot feed back into a bounce.
let maxMeasuredIndex = -1

/**
 * Estimated height for an item with no stored measurement.
 *
 * 2026-09-06 (task_1788648119245_5): uses the adaptive running MEDIAN
 * of measured heights instead of the static `defaultItemHeight` (64).
 * Real chat bubbles are ~400px; estimating the unmeasured tail at 64
 * collapsed the model total (and sizer + scrollHeight) to less than
 * half the real height with 100+ messages — the "list becomes small"
 * symptom. The median is robust against single giant code-block rows;
 * clampEstimate bounds it to a sane bubble range.
 */
// Bounds for the adaptive estimate (2026-09-06): the running median can
// overshoot fresh/short rows (e.g. a 3000px code-block median applied to
// one-line tool cards) or undershoot after a short-history chat. Clamping
// keeps any single estimate within a sane chat-bubble range; measured
// heights (stored above) are always exact and unaffected.
const ESTIMATE_MIN_PX = 32
const ESTIMATE_MAX_PX = 1600
const clampEstimate = (px: number): number =>
  Math.min(ESTIMATE_MAX_PX, Math.max(ESTIMATE_MIN_PX, px))
const estimateHeight = (index: number): number => {
  const stored = itemHeights.value.get(keyOf(index))
  if (stored !== undefined) return stored
  return clampEstimate(heightEstimator.estimate())
}

/**
 * Whether the container's content currently overflows its visible area
 * (i.e. `scrollHeight > clientHeight`). Exposed to the parent so it
 * can decide whether to show UI affordances (e.g. a "Load more"
 * button) that only make sense when the user can't trigger the
 * scroll-driven `loadMore` event because the container has no
 * scrollbar.
 *
 * Implemented as a `computed` (not a `ref` populated by a DOM read)
 * so it stays in sync with the underlying reactive data. The previous
 * ref-based version read `containerRef.value.scrollHeight` from a
 * `ResizeObserver` / `measureItems` / mount-time trigger, but those
 * triggers do NOT fire when the content inside the container grows
 * (e.g. during streaming, after pagination, or on first item
 * measurement) — only when the *observed element itself* resizes.
 * Result: `isScrollable` would get stuck at its initial-mount value
 * (typically `false` from the 0×0 flicker), and the parent's "Load
 * more" button would never hide even when the chat became scrollable.
 * See docs/plans/2026-06-04-chat-lazy-load-button.md §4.3.
 *
 * The estimate uses `defaultItemHeight` for unmeasured items, so it
 * can be slightly off in the milliseconds before `measureItems` runs
 * — that's a soft UX hint, not a precise measurement, and an
 * over-estimate is harmless (button hides for a frame, then re-shows
 * once measurement catches up). An under-estimate could hide the
 * button when the user needs it; in practice the default of 200px
 * matches most chat bubbles closely.
 */
const isScrollable = computed(() => {
  const totalContentHeight = accumulatedHeights.value[props.items.length] ?? 0
  return totalContentHeight > containerHeight.value
})

/**
 * Effective distance (in px) from the load edge at which the scroller
 * emits `loadMore`. Recomputed whenever the container's height changes
 * (via the `containerHeight` ref, which is updated in `onScroll`).
 *
 * Combines the absolute `loadMoreThreshold` floor (default 200 px) with
 * the proportional `loadMoreThresholdRatio` (default 0.5, i.e. half a
 * screen). Exposed on the instance so the parent can read it for
 * logging ("effective threshold was 500 px when loadMore fired") and
 * so the integration tests can assert against a single value rather
 * than duplicating the max() logic.
 */
const effectiveLoadMoreThreshold = computed(() =>
  computeLoadMoreThreshold(
    props.loadMoreThreshold,
    props.loadMoreThresholdRatio,
    containerHeight.value,
  ),
)

// Scrollability is pushed to the parent via the `scrollabilityChange` event
// (see its emit doc for why an event beats a template-ref read).
// `emitScrollableIfChanged` below (driven by onMounted + onUpdated) sends
// the initial value on mount — otherwise the parent's local ref would
// start at its default (`false`) until the FIRST actual value change.
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

// ── Sizer height — pure function of the height model (2026-09-06) ──────────
//
// Bounce root cause (task_1788648119245_5 audit): the previous version read
// `visibleRange` (a function of scrollTop) in its at-bottom branch and
// expanded to `topSpacer + realContentHeight`, where realContentHeight was
// STALE — the template ref callback only fires on mount/replace, never on
// child updates, so it described an OLD window. Scrolling to the bottom
// with a stale tall window blew the sizer up ~3x; scrolling up collapsed
// it back to the model total. sizer → scrollHeight → contentShift →
// scrollToBottom → scrollTop → visibleRange → sizer: a loop.
//
// Fixed invariant: the RENDERED sizer is the model total (plus the
// hysteresis dead-band), minus the tail-gap cap below. It changes only
// when the height MODEL changes (measurement, items mutation) — never
// from scrolling. Undershoot is safe: scrollToBottom targets the real DOM
// bottom at the tail, and the model converges as items measure. Overshoot
// from stale reads is gone by construction — there is no scroll-derived
// input left (see the tail-gap cap for the one deliberate exception).
const modelTotal = computed(() => accumulatedHeights.value[props.items.length] ?? 0)

// ── Tail-gap cap (task_1790236655228_2) ─────────────────────────────────────
//
// "the gap is too long" — the model can reserve thousands of px of empty
// sizer BELOW the real content (DevTools: sizer 26796px vs a content box
// ending at ~24114px), and the browser lets the user scroll into it.
// `scrollToBottom` already lands on the real bottom, so the void shows up
// as a blank region below the last message once the user keeps scrolling
// DOWN (wheel momentum, keyboard End, dragging the scrollbar).
//
// `tailContentBottom` is the MEASURED bottom of the rendered window in
// model space (model prefix of the first rendered row + the real heights
// of the rows in the DOM). It is recorded by `measureItems()` — the one
// place that reads live child geometry — and NOT from a template-ref
// callback. That distinction is why the PR #355 clamp had to be reverted:
// its `onContentRef` value only refreshed when the content DIV was
// mounted/replaced, so after a window shift it described the PREVIOUS
// window (a tall one), inflating the sizer ~3x and bouncing. `measureItems`
// runs on every window change, scroll, and content resize, so the number
// always describes the rows that are actually on screen.
//
// The cap is `min(modelTotal, tailContentBottom + maxTailGap)`: it can only
// ever SHRINK the reserved void, never grow the sizer past the model — so
// the "sizer blew up / bounce" failure mode is impossible. The model itself
// is never written; only the style binding changes.
const tailContentBottom = ref(0)
// Latched "the rendered window covers the tail" flag. The clamp is applied
// only while this is true, so a user reading history can always scroll back
// down to newly appended rows (no cap → upstream model space is intact).
// ON at the tail; OFF only once the window is clearly away from it
// (`buffer` rows), which keeps a scrollTop clamp at the capped bottom from
// flipping the cap off and on in the same frame (the bounce/dither the
// user rejected in the earlier tail-clamp experiment).
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
    if (vsLogger.value) {
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
// The mount run is load-bearing: on initial mount the items are already
// present (the parent populates them before rendering this child), so a
// change-only trigger would leave `accumulatedHeights` at `[0]`,
// `isScrollable` would read `undefined ?? 0 = 0`, and the parent's
// "Load more messages" button would show in scrollable chats. Driven by
// onMounted + onUpdated with a prev-length guard (see the sync block
// near the bottom of <script setup>).
let prevItemsLen = -1
const syncItemsLength = () => {
  const newLen = props.items.length
  if (newLen === prevItemsLen) return
  const oldLen = prevItemsLen
  prevItemsLen = newLen
  // A collapse to 0 means the list was swapped (chat switch) — forget
  // the previous chat's height profile so its median doesn't pollute
  // the new chat's estimates.
  if (newLen === 0 && oldLen > 0) {
    heightEstimator.reset()
    maxMeasuredIndex = -1
    // The measured tail bottom belongs to the OLD list: keeping it
    // would cap the new chat's sizer at a position that means nothing
    // here.
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

// Tail-cap latch (see the sizerHeight comment). ON as soon as the rendered
// window reaches the last item — that is exactly when `measureItems` can
// see the real content bottom and record it. OFF only once the window is a
// full `buffer` away from the tail, so a clamp-driven scrollTop write at
// the capped bottom cannot flip the cap off (the window would then re-grow,
// get clamped again, and dither). Applied by the onMounted + onUpdated
// sync block below (same hysteresis, prev-end guard).
const applyTailCapLatch = (end: number) => {
  if (end >= props.items.length) tailCapLatched.value = true
  else if (end < props.items.length - props.buffer) tailCapLatched.value = false
}

/**
 * Record the MEASURED bottom of the rendered window, in model space.
 *
 * Only called from `measureItems()` with values read from the live DOM in
 * that same pass, which is what keeps it fresh (PR #355's clamp stored this
 * from a template-ref callback that never re-fired for the new window).
 *
 * FAIL-OPEN everywhere: if the last item is not in the DOM, or nothing in
 * the window has laid out yet (`childrenSum <= 0`), the previous value is
 * left untouched rather than guessed — a wrong real bottom would either
 * re-open the phantom (too large) or hide real content (too small).
 */
const recordTailContentBottom = (
  childrenSum: number,
  firstIndex: number,
  lastIndex: number,
): void => {
  if (props.maxTailGap <= 0) return
  if (firstIndex < 0 || lastIndex < props.items.length - 1) {
    // This pass did not see the tail, so whatever bottom we recorded earlier
    // describes a DIFFERENT window — and, if the list has grown since, a
    // different list. The tail cap is `min(modelTotal, recorded + maxTailGap)`,
    // so a stale record silently clamps the sizer far below the real content:
    // with 43 items, a buffer of 30, and a record from when the list was 20
    // items long, the cap held the sizer at 4196px against a correct 8542px
    // model. The reader then sees phantom scroll range that no content backs.
    //
    // Clearing it is also what makes the cap dither-free. The latch's
    // hysteresis exists because a clamp-driven scrollTop write can move the
    // window off the tail and back, re-clamping each time. With the record
    // cleared, the cap switches OFF the moment the window leaves the tail, so
    // there is no clamp to fight — and when the window returns, the value
    // written is one this pass actually measured, never one the clamp itself
    // produced. The cap can then only ever clamp to a real bottom.
    tailContentBottom.value = 0
    return
  }
  // NOTE: `childrenSum <= 0` deliberately keeps the previous value rather than
  // clearing it. A pass with no layout (container not yet painted, `v-if`
  // hidden) is not evidence that the tail moved, and fail-open here keeps the
  // cap protecting the reader from a phantom void while there is no
  // measurement to replace it with. A pass that DOES see rows and does not
  // reach the tail is different evidence — that is the case cleared above.
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

/**
 * Live count of items currently rendered in the DOM (i.e. the
 * length of `visibleItems`). Exposed so the parent can verify the
 * buffer contract and log "rendered N items" diagnostics without
 * opening dev-tools.
 *
 * Equals `end - start` from `visibleRange`, which is:
 *   - In the middle of the list: `2 * buffer + visibleCount`
 *   - At the top/bottom edges: clamped to whatever the list allows
 *
 * Recomputed automatically on every scroll, every measurement, and
 * every `items` length change.
 */
const renderedCount = computed(() => {
  const { start, end } = visibleRange.value
  return Math.max(0, end - start)
})

/**
 * The {start, end} range of items currently rendered. Exposed as
 * a single object so the parent can read both fields in one
 * reactive read (avoiding the start-vs-end skew that would happen
 * if they were two separate computeds and a scroll fired between
 * reads).
 */
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
//
// Transform-based positioning has no spacer DIVs whose style mutations a
// parent MutationObserver could watch. This emit is the explicit
// replacement signal: it fires whenever the virtual layout's geometry
// changes (scroll-driven window shift, measurement update, item-list
// change). ChatView listens to re-stick to bottom after measurement drift.
// `emitContentShiftIfChanged` below (driven by onMounted + onUpdated with
// a prev-geometry guard) sends the initial geometry on mount — without it
// a never-scrolled list would never emit, and ChatView's re-stick logic
// would miss the initial measurement drift.
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
//
// Only update a stored height for an item strictly above the visible
// window when the new measurement differs by more than this many
// pixels. Smaller deltas are sub-pixel rounding noise from the
// browser's layout (Chromium rounds sub-pixel offsets). Writing
// them anyway was the trigger for the scroll-ratcheting bug
// (docs/plans/2026-06-10-scroll-ratcheting-fix.md): a 1-2 px
// fluctuation cycled through updateAccumulatedHeights → topSpacer
// mutation → browser scroll-anchoring → scrollTop ratchet, with
// scrollTop and scrollHeight oscillating in lockstep while
// distanceFromBottom stayed constant. 50 px absorbs that noise floor
// with margin; any real layout change above the viewport (image load,
// content expansion) exceeds it.
//
// Items AT or BELOW the viewport start use NO dead-band (exact
// writes) — see the measure loop. Those writes only move the sizer's
// bottom edge; topSpacer is untouched, so they cannot shift visible
// content or ratchet scrollTop, and computeAnchorCompensation ignores
// them by construction. Exact tail writes let the sizer converge to
// the real content bottom instead of parking up to 50 px per item too
// tall — the persistent blank gap below the last message at max
// scroll (sizer 40383 px vs content bottom ~37095 px in the report).
const HYSTERESIS_PX = 50

// How close to the bottom counts as "at the bottom" when `measureItems`
// decides which target the anchor compensation writes to (see `wasAtBottom`
// in that function). It is deliberately the SAME number as ChatView's
// `BOTTOM_THRESHOLD`, and it is measured with the SAME ruler
// (`bottomScrollTop`), because the two must never disagree: if the scroller
// anchored a reader that ChatView believes is at the bottom, the resulting
// write disarms the stick that was supposed to follow the stream.
//
// 10px is tight on purpose. A chat message is 50-100px tall, so a reader
// reading the last one is far outside this window — the tolerance covers
// scroll-position rounding, not a deliberate scroll-up.
const AT_BOTTOM_SLACK_PX = 10

// Where the bottom sat as of the END of the previous pass (or the last
// `scrollToBottom`), or null before anything has positioned the list.
//
// `measureItems` must judge "was the reader at the bottom?" against THIS, not
// against a live read of `bottomScrollTop()`. A live read answers with the
// geometry as it is NOW — and when the previous pass grew the model, that is
// already further down than where it left the reader. Judged live, a reader
// who has not moved at all reads as "left the bottom", the anchor branch takes
// over, and the pass strands them. That is the reported bug arriving one pass
// late, and it is why a single-pass fix looks correct and a multi-pass turn
// still breaks: a turn is many passes.
//
// The distinction the model moving vs the reader moving is the whole point. A
// reader scrolled UP is below this number, so the test still fails for them.
let settledBottom: number | null = null

const measureItems = () => {
  if (!containerRef.value) return
  const content = containerRef.value.querySelector('.virtual-scroller-content')
  if (!content) return
  let changed = false
  // ── Scroll-anchor compensation (2026-08-23; v2 prefix-delta 2026-09-23) ──
  //
  // Writing heights/estimates for items ABOVE the viewport mutates the
  // transform origin (topSpacer) without moving scrollTop — content
  // under the viewport teleports. That is the "long chats jump while
  // scrolling" bug (task_1787496087806_6).
  //
  // v2 (2026-09-23): compensation is the ANCHOR's prefix-sum delta,
  // not a sum of per-measurement deltas against `defaultItemHeight`.
  // The old per-item baseline was wrong twice: (a) first measurements
  // were compared against the static prop (64px) while the model
  // actually used the adaptive MEDIAN (200-600px) — every first
  // measurement above the viewport over-compensated by (median − 64)
  // px, stacking into huge wrong scrollTop writes while scrolling up
  // through history; (b) the estimator median moving INSIDE this pass
  // changes every UNMEASURED item's contribution above the viewport
  // with no measurement entry at all — uncompensated, a pure teleport
  // (the "jump when the first SSE remeasure lands" case).
  // `prefix(anchor)` is exactly the model contribution of items
  // strictly above the viewport top, so its before/after delta covers
  // both. Capture the pre-pass values now; the post-rebuild values are
  // read after `updateAccumulatedHeights()`.
  //
  // The anchor is the first VISIBLE index (not a DOM node): stable even
  // if the anchor item unmounts between frames, and jsdom-testable.
  const anchorIndex = findStartIndex()
  const prevScrollTop = containerRef.value.scrollTop
  // ── Was the reader at the bottom BEFORE this pass touched the model? ──────
  // Read here, not at the compensation site: by then `updateAccumulatedHeights`
  // has already resized the sizer, so `bottomScrollTop()` would answer with
  // the POST-pass edge and the question would be circular.
  //
  // The answer decides which target the compensation below uses — the anchor
  // (hold the reader's view still) or the bottom (hold the reader AT the
  // newest content). Anchoring a bottom reader is what breaks long streams:
  // their window expands, a batch of rows above the anchor gets measured for
  // the first time, the prefix delta runs to thousands of px, and the write
  // drags them that far UP — which ChatView then reads as leaving the bottom,
  // disarming the stick for every remaining chunk of the response.
  //
  // Same ruler ChatView's `isAtBottom` uses, same tolerance as its
  // `BOTTOM_THRESHOLD` (10px), so the two can never disagree about whether
  // the reader is at the bottom.
  // Judge against the LIVE bottom, not `settledBottom`.
  //
  // `settledBottom` is where the bottom sat when the stick LAST acted, which is
  // the right anchor for "has this reader moved?" but the WRONG one for "is this
  // reader at the bottom right now?". Using it here meant a reader who scrolled
  // up into history was still compared against the bottom as it had been, so
  // `wasAtBottom` stayed true and the re-pin below yanked them straight back to
  // the tail — the "bouncing text" failure, and a hard regression in
  // `test_sending_from_history_still_lands_on_the_newest_turn`.
  //
  // The live read is correct here precisely because this runs BEFORE the model
  // rebuild: `bottomScrollTop()` still describes the geometry the reader is
  // actually sitting in. (It is re-read after the rebuild for `atBottomTarget`,
  // which is the other half of the pair and wants the post-pass edge.)
  const wasAtBottom = prevScrollTop >= bottomScrollTop() - AT_BOTTOM_SLACK_PX
  const oldAnchorTop = accumulatedHeights.value[anchorIndex] ?? 0
  const pendingMeasurements: AnchorMeasurement[] = []
  const children = content.children
  // ── P1 perf: batched height writes (task_1787551495337_9) ──────────────
  //
  // All measurements are collected into `pendingWrites` and applied to the
  // reactive Map in ONE synchronous block. The deep watcher on itemHeights
  // debounces its rebuild (50ms), so N writes inside one batch collapse to
  // ONE timer + ONE prefix-sum rebuild instead of N timer resets that each
  // would have re-scanned the full list. The Map itself is only made
  // reactive-mutable once per batch.
  //
  // NOTE: the child→index mapping reads each child's `data-vs-index`
  // attribute, NOT `visibleRange.value.start + i`. The computed range can
  // update synchronously while the DOM still shows the previous window
  // (render is scheduled to a later microtask); mapping via the live
  // computed would attribute old children's heights to the wrong indices.
  // The attribute is stamped by the renderer at mount time and always
  // matches the node it decorates.
  const pendingWrites: Array<[string, number, number]> = []
  // Tail-gap cap inputs (see recordTailContentBottom): the summed real
  // height of the rows currently in the DOM, plus the first/last indices
  // they were stamped with. Read in this same pass so the recorded real
  // bottom can never describe a previous window.
  let renderedChildrenSum = 0
  let firstRenderedIndex = -1
  let lastRenderedIndex = -1
  for (let i = 0; i < children.length; i++) {
    const el = children[i] as HTMLElement
    // Read the index stamped by the renderer — the live computed range
    // can already point at the next window while the DOM still shows
    // the previous one (render is async). Falling back to start+i here
    // misattributes a tall measured height to the wrong item, which
    // corrupts the spacers and shows as a scroll jump on fast flings
    // through variable-height chat messages.
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
    if (h > 0) {
      // P1 perf: quantize to integer px. Fractional offsetHeights under
      // sub-pixel layout re-quantize differently between our prefix sums
      // and the browser's layout → ±1px spacer drift → micro-jitter.
      const heightPx = quantizePx(h)
      // Stable-key lookup: the height belongs to the ITEM (via its
      // itemKey), not the array slot — immune to index shifts from
      // messageGroups regrouping (the sizer-corruption bug).
      const key = keyOf(realIndex)
      const prev = itemHeights.value.get(key)
      // First measurement (prev === undefined) always writes. On
      // subsequent measurements the dead-band is two-tier:
      // - Strictly ABOVE the viewport start (realIndex < anchorIndex):
      //   keep the HYSTERESIS_PX dead-band. Those writes mutate
      //   topSpacer and shift content under the viewport — small
      //   deltas there are the scroll-ratcheting trigger.
      // - AT or BELOW the viewport start: write exact. Those writes
      //   only move the sizer's bottom edge (topSpacer untouched), so
      //   they cannot shift visible content, and the anchor
      //   compensation below skips them (index >= anchorIndex). This
      //   lets the sizer converge to the real content bottom instead
      //   of parking up to 50 px per item too tall.
      //

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
  // Record the measured tail bottom on BOTH paths — a no-op pass still
  // carries a fresh window geometry (e.g. the user scrolled: same stored
  // heights, different rows on screen), and the cap must follow the
  // window, not only the height writes.
  recordTailContentBottom(renderedChildrenSum, firstRenderedIndex, lastRenderedIndex)
  if (!changed) {
    // Even a pass that wrote nothing establishes where the bottom is, and the
    // NEXT pass has to judge against it (see `settledBottom`).
    settledBottom = bottomScrollTop()
    return
  }
  for (const [key, heightPx, realIndex] of pendingWrites) {
    itemHeights.value.set(key, heightPx)
    // Feed the adaptive estimator so future unmeasured items inherit a
    // realistic median instead of the static prop guess.
    heightEstimator.observe(heightPx)
    // Track the measurement frontier: the learned median is only
    // trusted for items at or before this index (see estimateHeight).
    if (realIndex > maxMeasuredIndex) maxMeasuredIndex = realIndex
  }
  updateAccumulatedHeights()
  // Prefixes moved: recompute the measured tail bottom against the fresh
  // model so the cap describes where the content actually sits now.
  recordTailContentBottom(renderedChildrenSum, firstRenderedIndex, lastRenderedIndex)
  // Post-pass prefix at the same anchor index: the delta vs
  // `oldAnchorTop` is the compensation (v2 prefix-delta — covers
  // measured writes AND estimator drift for unmeasured items above).
  const newAnchorTop = accumulatedHeights.value[anchorIndex] ?? 0

  // NOTE (2026-08-25): a "tail-exact clamp" (force-write rendered tail
  // heights + shrink the sizer to the real content bottom when the
  // window shows the last item) was tried here and REMOVED. It caused
  // an oscillation loop — clamp shrinks sizer → window shifts → next
  // pass reads different heights → sizer grows → shifts again — which
  // the user experienced as app freezes and bouncing text during SSE
  // streams. Product decision (user): gaps below the last message are
  // ACCEPTABLE; bouncing is NOT. The anchor compensation above already
  // keeps scrolled-up reading stable; the remeasure() calls in ChatView
  // keep the at-bottom case tight without any clamping.

  // ── Apply the anchor compensation ────────────────────────────────────
  //
  // v2 prefix-delta: the anchor's prefix sum moved by
  // `newAnchorTop − oldAnchorTop`, i.e. everything strictly above the
  // viewport top shifted by that amount in the model. Add the same
  // signed total to scrollTop so the rendered window stays put on
  // screen. Writes AT/AFTER the anchor never appear in the prefix —
  // visible-window growth (streaming text, image load) flows through
  // uncompensated by construction.
  //
  // Skipped while `isPreservingScroll`: `endPreserve` owns scroll
  // restoration during prepends and sets scrollTop from its own anchor
  // element; compensating here would double-adjust.
  //
  // A bottom reader is re-targeted rather than compensated (see
  // `wasAtBottom` above and `atBottomTarget` on the helper): the write still
  // happens — it absorbs the model change and keeps them on the newest
  // content — but it leaves them at the bottom instead of stranding them
  // `shiftPx` px above it with the auto-stick already disarmed.
  const result = computeAnchorCompensation({
    anchorIndex,
    prevScrollTop,
    oldAnchorTop,
    newAnchorTop,
    // Read the bottom edge AFTER the rebuild, so the target is the bottom as
    // it is now. Passing it is the whole point: a bottom reader is re-targeted
    // instead of compensated around an anchor they never chose.
    atBottomTarget: wasAtBottom ? bottomScrollTop() : undefined,
  })
  if (result.shiftPx !== 0 && !isPreservingScroll.value) {
    // Mark BEFORE the write: assigning .scrollTop fires a native scroll
    // event that onScroll must label as programmatic (see the counter
    // comment above — without this, a downward compensation is misread
    // as "user scrolled up" and disengages ChatView's auto-stick).
    if (vsLogger.value) {
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
  // Re-read rather than reusing the target: the branch above may not have run
  // (shiftPx 0, or a preserve window), and the tail cap can move the bottom
  // independently of anything measured here.
  settledBottom = bottomScrollTop()
}

// ── Pre-paint measurement on rendered-range change ───────────────────────────
//
// The debounced measureItems (50ms) compensates at MEASUREMENT time, but
// the jump for a tall item happens at RENDER time: when a new item enters
// the top buffer, Vue renders it in one commit — the topSpacer shrinks by
// its 64px estimate while its real height (e.g. a 3000px long message)
// takes its place — shifting content under the viewport IMMEDIATELY. The
// debounced correction arrives ≤50ms later: a visible down-up bounce.
//
// Fix: re-measure inside `nextTick` whenever the rendered window changes.
// nextTick callbacks drain BEFORE the browser paints, so render +
// measure + compensation collapse into ONE frame — no intermediate paint
// with wrong spacers, nothing to see.
//
// `schedulePrePaintMeasure` (driven by onScroll + the onUpdated sync block
// below) re-measures inside `nextTick` whenever the rendered window
// changes. nextTick callbacks drain BEFORE the browser paints, so render +
// measure + compensation collapse into ONE frame — no intermediate paint
// with wrong spacers, nothing to see.
//
// `_inPrePaintMeasure` guards re-entrancy: measureItems mutates
// scrollTop, which fires another scroll event → visibleRange recomputes
// → the sync block would re-run. The guard breaks that cycle; the trailing
// debounce below still catches any range change caused by the correction
// itself (rare — compensation preserves the anchor's screen position).
// `_prePaintScheduled` dedupes the onScroll call against the onUpdated
// call for the same scroll gesture (the scroll handler runs first, the
// update follows for the same range — one measure, not two).
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
    // Trailing sweep: if the compensation shifted the window again,
    // one more pass settles it (debounced, off the critical path).
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
  // Timestamp for the idle content-size observer below: it stays quiet
  // shortly after a scroll because the scroll path already measures.
  lastScrollEventAt = Date.now()
  // Keep `containerHeight.value` in sync with the live DOM reading.
  // The `ResizeObserver` only fires when the container's *size* changes —
  // it does NOT fire for scroll-only events. Between the first `loadMore`
  // and the next one, `endPreserve` does `containerRef.value.scrollTop =
  // newST` to restore the user's view, which fires a scroll event but not
  // a resize, and a layout reflow during the prepend can briefly shrink
  // the container below its settled height. Either path leaves the cached
  // `containerHeight.value` stale, and the `effectiveLoadMoreThreshold`
  // computed then silently falls back to its 200 px absolute floor —
  // which is the "ratio only works on the first load" symptom. Reading
  // `target.clientHeight` here on every scroll event keeps the ref in
  // sync. Vue's `ref` does an internal equality check, so this is a no-op
  // when the value didn't change.
  containerHeight.value = target.clientHeight
  const st = target.scrollTop
  const dir = st > lastScrollTop.value ? 'down' : 'up'
  // NOTE (P1 perf review, task_1787551495337_9): this write stays
  // SYNCHRONOUS. An rAF-deferred variant was tried and reverted: the
  // pre-paint compensation contract (onScroll + onUpdated → nextTick →
  // measureItems, PR #310) requires the range recompute to begin within
  // the SAME tick as the scroll event; deferring it to the next frame
  // broke that guarantee. Coalescing is already provided by Vue's async
  // render queue — N scroll events between two flushes produce exactly
  // ONE component re-render and ONE visibleRange evaluation.
  scrollTop.value = st
  lastScrollTop.value = st
  // Consume the programmatic flag BEFORE the emit: a markProgrammatic
  // bump (from measureItems' compensation write or endPreserve's
  // restoration) belongs to exactly THIS event — the next one is a
  // fresh gesture (or another marked write).
  const isProgrammatic = consumeProgrammaticScroll()
  emit('scroll', st, dir as 'up' | 'down', target, isProgrammatic)

  if (loadMoreDebounce) clearTimeout(loadMoreDebounce)
  loadMoreDebounce = setTimeout(() => {
    if (isPreservingScroll.value) {
      // Don't log here — the parent is mid-preserve, suppression is
      // expected. The parent will log its own preserve-start/end
      // events that bracket this window.
      return
    }
    const hasMore = props.totalCount === 0 || props.items.length < props.totalCount
    if (!hasMore) {
      emit('loadMoreSuppressed', 'no-more-items')
      return
    }
    // Defensive guard: if the container isn't actually scrollable
    // (scrollHeight ≤ clientHeight, i.e. content fits in viewport),
    // `st < loadMoreThreshold` is trivially true because `st` is 0
    // and there's nothing to scroll. Emitting `loadMore` here would
    // cause the parent to fetch a page and prepend it, which is the
    // exact "flicker" users see when a chat's container reads as
    // 0×0 during an SSE stream. The check uses the container's
    // own dimensions — no parent layout assumptions.
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
        // User is near the top but there are no items yet — nothing
        // to "load more of". This is the "empty list, scrolled to
        // top" case (rare; usually we wouldn't be at the top of
        // an empty list, but guard it).
        emit('loadMoreSuppressed', 'no-items')
      }
      // else: user is just not near the top yet — normal scrolling,
      // not a suppression. Don't emit.
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

  // Max-wait, NOT reset-per-event: the previous clearTimeout+reschedule
  // pushed the deadline out another 50ms on EVERY scroll event, so the
  // trailing measure never fired while the user kept scrolling — all
  // pending height corrections then landed in one lump the moment the
  // gesture stopped (the "scroll, then it jumps" feel). Arm once; the
  // fired timer clears itself, and the next scroll event arms the
  // following pass — guaranteeing a measure at most ~50ms after the
  // first un-flushed scroll during sustained scrolling.
  if (!measureDebounce) {
    measureDebounce = setTimeout(() => {
      measureDebounce = null
      measureItems()
    }, 50)
  }
  // Re-measure pre-paint when the scroll moved the rendered window (same
  // contract the old `effectiveRange` watcher provided; deduped against
  // the onUpdated sync block below via `_prePaintScheduled`).
  schedulePrePaintMeasure()
}

/**
 * PHASE 1 — call BEFORE mutating items array.
 * Reads anchor (old item[0]) offsetTop while it is still in the DOM.
 */
const beginPreserve = (newItemsCount: number) => {
  if (!containerRef.value || newItemsCount <= 0) return
  isPreservingScroll.value = true
  _pendingNewItemsCount = newItemsCount

  // NOTE (2026-08-26 stable-keys fix): the old index-shift remap
  // (rebuilding the Map with every key +N) is GONE. Heights are keyed
  // by stable itemKey, so a prepend needs no remap — each item keeps
  // its own height wherever it moves. maxMeasuredIndex still advances
  // (the frontier is index-based: the prepended items are new tail
  // relative to the estimator's trust boundary... actually they are
  // NEW items at the FRONT, so the frontier advances by N to keep
  // pointing at the same physical item).
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

/**
 * PHASE 2 — call AFTER items array has been mutated.
 * Expands render window, waits for layout, sets scrollTop once accurately.
 */
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

const scrollToIndex = (index: number, behavior: ScrollBehavior = 'auto') => {
  if (!containerRef.value) return
  containerRef.value.scrollTo({
    top: accumulatedHeights.value[index] ?? index * props.defaultItemHeight,
    behavior,
  })
}
const scrollToTop = (behavior: ScrollBehavior = 'auto') =>
  containerRef.value?.scrollTo({ top: 0, behavior })
/**
 * THE bottom, as a scrollTop — the single ruler for "is the reader at the end".
 *
 * Two different notions of "the bottom" used to live in two files, and they
 * disagreed by more than either one's tolerance:
 *
 *   - the DOM's notion: `scrollHeight - clientHeight`, which trusts the sizer.
 *     When the height model overshoots the real content, that lands the
 *     reader in a fully blank region (the blank-viewport bug).
 *   - the content's notion: `topSpacer + content.offsetHeight`, the actual
 *     bottom of the last rendered row. This is the one that LOOKS right.
 *
 * `scrollToBottom` has always chosen between them, preferring the real bottom
 * when the model overshoots by more than `HYSTERESIS_PX`. The parent, however,
 * decided at-bottom with the DOM's number — so a *successful* auto-stick
 * reported a gap of exactly `maxTailGap` (100 by default) and ChatView read
 * that as "the user left the bottom", disarming every later auto-stick for the
 * rest of the session. That is the "sometimes it does not autoscroll to
 * bottom" report.
 *
 * Exposing the choice as a pure function closes the loop: the parent asks
 * `bottomScrollTop()` for the same number `scrollToBottom` is about to use, so
 * the two can no longer disagree. Reading `content.offsetHeight` costs a
 * layout flush, but every caller has already read `scrollHeight` /
 * `clientHeight` in the same tick, so the layout is warm.
 *
 * Two invariants, both load-bearing for a value the parent now TRUSTS:
 *
 *   1. Live geometry, not `containerHeight.value`. That ref is a cache fed by
 *      scroll events and the container ResizeObserver, so it is 0 before the
 *      first scroll and stale whenever a reflow shrinks the container between
 *      them. Publishing an anchor derived from it hands the parent a position
 *      the container is not at — the same "measured 800px off" symptom this
 *      whole fix is about, reintroduced through a different variable.
 *   2. Never above the DOM max. The browser clamps `scrollTop` to
 *      `scrollHeight - clientHeight`, so an anchor past that is a position the
 *      reader can never occupy, and every at-bottom comparison against it is
 *      permanently false.
 */
const bottomScrollTop = (): number => {
  const el = containerRef.value
  if (!el) return 0
  const clientHeight = el.clientHeight
  const domEdge = Math.max(0, el.scrollHeight - clientHeight)
  // Real-bottom override (blank-viewport fix) — kept, but now safe because
  // sizerHeight is stable (modelTotal only, no visibleRange dependency).
  // Previously the sizer clamp + this override together caused the loop;
  // with sizer stable, this is a one-time read that doesn't feedback.
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
  // An explicit jump to the bottom is the strongest possible statement that the
  // reader is following the tail, and the next measure pass has to honour it
  // (see `settledBottom`). This is the gesture behind the jump-to-bottom
  // arrow, and it is the exact moment the reported bug used to be armed.
  settledBottom = target
}
const scrollToPosition = (scrollTop: number, behavior: ScrollBehavior = 'auto') => {
  if (!containerRef.value) return
  const clientHeight = containerRef.value.clientHeight
  const max = containerRef.value.scrollHeight - clientHeight
  if (max <= 0) return
  const clamped = Math.max(0, Math.min(scrollTop, max))
  containerRef.value.scrollTo({ top: clamped, behavior })
}
const scrollToItem = (index: number, behavior: ScrollBehavior = 'auto') =>
  scrollToIndex(index, behavior)

/**
 * Full recompute of the height model from the live DOM (2026-08-25
 * append-gap fix). The parent calls this whenever it KNOWS content
 * changed — new message appended, streaming text mutated in place,
 * streaming row swapped for the canonical row. measureItems() reads
 * every rendered child's real offsetHeight, writes the model, rebuilds
 * the sizer, and anchor-compensates — the same pass a scroll event
 * triggers, invoked explicitly at data-mutation time instead of being
 * inferred from DOM observation (the ResizeObserver attempt froze the
 * browser: observe → measure → sizer write → re-observe loop).
 *
 * Call inside nextTick (or later) so the DOM already reflects the
 * mutation — offsetHeight reads need the patched layout.
 */
/**
 * Transfer a stored height across an identity swap (2026-09-06).
 * ChatView's groupKey is group.messages[0].id; on message-complete the
 * `streaming-*` placeholder row is replaced by the canonical DB row, so
 * the group's key changes and its measured height would be lost (sizer
 * shrinks by real−estimate for a frame, then remeasure() heals it — a
 * visible flicker on long streams). ChatView calls this at the swap
 * site BEFORE mutating the array. Returns true when a height moved.
 * Never overwrites an existing target height (the DB row may already
 * have been measured under its own key).
 */
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
// measureItems runs on scroll, remeasure(), and rendered-range change —
// but NOT when an already-rendered item grows on its own: async image
// decode, a PresentFiles source fetch resolving, sub-agent progress
// filling in, copy-button injection. The model then lags reality until
// the user's NEXT scroll, which applies all pending corrections at
// once: the "small scroll suddenly shows content / jumps" symptom.
// A ResizeObserver on the CONTENT box closes that gap: real growth
// schedules a debounced measure within ~150ms, so corrections land
// promptly instead of accumulating.
//
// Loop safety (a naive observer on the container once froze the
// browser: observe → measure → sizer write → re-observe): this observes
// ONLY the content div's own box. Nothing in the measure path alters
// that box — measureItems reads children; its writes move
// topSpacer/transform (position, not size) and the sizer (a SIBLING
// element). The callback additionally ignores sub-2px noise, skips
// while preserving or pre-paint measuring, and stays quiet shortly
// after a scroll event (the scroll path already measures — measuring
// twice would just force extra layouts).
let contentRO: ResizeObserver | null = null
let contentROTimer: ReturnType<typeof setTimeout> | null = null
let lastContentH = -1
let lastScrollEventAt = 0
const CONTENT_RO_DEBOUNCE_MS = 150
const CONTENT_RO_MIN_DELTA_PX = 2
// ── Watch-free sync block ──────────────────────────────────────────────────
// The six reactive edges above (scrollability emit, items-length rebuild,
// tail-cap latch, contentShift emit, rendered-range measure) run here:
// onMounted for the initial pass, onUpdated with prev-value guards after
// that. `itemHeights` needs no entry: `measureItems()` and `rekeyHeight()`
// already call `updateAccumulatedHeights()` synchronously after writing,
// so the deleted debounced deep watcher only ever re-ran the same update.
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
      nextTick(() => setTimeout(measureItems, 50))
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
  nextTick(() => setTimeout(measureItems, 100))
})
onUnmounted(() => {
  ro?.disconnect()
  contentRO?.disconnect()
  if (contentROTimer) clearTimeout(contentROTimer)
  if (loadMoreDebounce) clearTimeout(loadMoreDebounce)
  if (measureDebounce) clearTimeout(measureDebounce)
  if (_prePaintTrailing) clearTimeout(_prePaintTrailing)
  if (programmaticResetTimer) clearTimeout(programmaticResetTimer)
})

defineExpose({
  scrollToIndex,
  scrollToTop,
  scrollToBottom,
  bottomScrollTop,
  /**
   * Where the bottom sat as of the END of the last pass (or the last
   * `scrollToBottom`), or null before anything has positioned the list.
   *
   * Exposed so the parent can judge "is the reader at the bottom" against the
   * bottom AS IT WAS when the stick last acted, rather than against a freshly
   * recomputed `bottomScrollTop()`. The live read is a MOVING TARGET: its two
   * inputs (`scrollHeight - clientHeight`, the height model, and
   * `topSpacer + content.offsetHeight`, the rendered rows) move independently,
   * and the real-bottom override engages only while the model overshoots by
   * more than `HYSTERESIS_PX`. So between two frames the same stationary reader
   * can be measured 0px from the bottom and then 43px from it, with no gesture
   * in between — which flips `isAtBottom` false, shows the jump-to-bottom arrow,
   * and disarms every follow gate. That is the "the stick dies mid-stream"
   * flake, and it is timing-dependent by construction.
   *
   * A getter, not a value: `settledBottom` is a plain `let` (deliberately not
   * reactive — it is written inside measure passes and must not schedule a
   * render), so a snapshot in `defineExpose` would be frozen at setup time.
   */
  get settledBottom() {
    return settledBottom
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
  /*
   * Disable CSS scroll anchoring. The default `overflow-anchor: auto`
   * makes the browser adjust scrollTop by the spacer delta when the
   * topSpacer mutates — which happens every time `measureItems()`
   * re-measures buffer items. That adjustment is the "ratchet" the
   * user sees in the scrollLogger: scrollTop and scrollHeight
   * oscillate in lockstep, distanceFromBottom stays constant.
   * Disabling it preserves the user's scrollTop on spacer changes;
   * any visible re-anchoring is the user's choice (they can scroll
   * a hair to compensate). See
   * docs/plans/2026-06-10-scroll-ratcheting-fix.md.
   */
  overflow-anchor: none;
  /*
   * Use `flex: 1 1 0` instead of `height: 100%` so the scroller
   * participates in the parent's flex layout properly. `height: 100%`
   * requires every ancestor to have a *resolved* height, which isn't
   * guaranteed through a chain of `flex-1` items during the first
   * paint — the scroller then reads as 0×0, which (1) breaks auto-
   * scroll, (2) makes the scroller's own loadMore check fire
   * inappropriately, causing the "flicker" users see during SSE
   * streaming. `flex: 1 1 0` makes the scroller a proper flex item
   * that takes all available space without depending on percentage
   * resolution. `min-height: 0` allows it to shrink below its
   * content size (the default `min-height: auto` would prevent
   * shrinking and break the scroll).
   *
   * `min-height: 100px` is a safety net: if the scroller is ever
   * dropped into a non-flex parent, it still has a visible size.
   */
  flex: 1 1 0;
  min-height: 0;
  /*
   * No explicit min-height: the Tailwind `min-h-0` class on the parent
   * (set by every consumer: ChatsList's chat list div, ChatView's
   * messages wrapper) provides the "shrink below content size" behavior
   * needed for the scroller to participate correctly in a flex column.
   * The previous `min-height: 100px` was a misnamed safety net that
   * caused the scroller to overflow its parent when the parent's
   * available height was less than 100px (e.g. ChatsList with a small
   * `chatsHeight` percentage), making the last visible chat row render
   * ON TOP of the WORKSPACES section header below. The "non-flex
   * parent" case the old comment worried about would already be broken
   * (no height to scroll in) — the 100 px floor just hid the bug
   * behind an even bigger layout collision.
   */
}
.virtual-scroller-content {
  display: flex;
  flex-direction: column;
  /*
   * P2: the content window is absolutely positioned inside the sizer and
   * moved with translate3d (see template comment). `will-change: transform`
   * promotes it to its own compositor layer so window shifts are a GPU
   * composite instead of a layout+paint. The absolute positioning takes
   * the content out of flow — the SIZER is what holds scrollHeight up.
   */
  position: absolute;
  left: 0;
  right: 0;
  top: 0;
  will-change: transform;
}
.virtual-scroller-sizer {
  position: relative;
}
/*
 * P1 perf: CSS containment on item wrappers (task_1787551495337_9).
 *
 * `contain: layout style` tells the browser each item's internals cannot
 * affect layout outside its wrapper box (and vice versa). During a fast
 * scroll the window shift mounts/unmounts whole items; with containment
 * the browser can skip re-laying-out every OTHER item's subtree and only
 * process the changed wrappers. `contain: paint` is deliberately NOT set:
 * chat bubbles legitimately overflow their wrapper (dropdown menus,
 * hover cards, code-block scrollbars) and paint-clipping would cut them
 * off. `content-visibility` is also skipped for now — it defers rendering
 * of offscreen items, but combined with the virtualizer's own windowing
 * it caused blank-flash artifacts in earlier experiments.
 */
.virtual-scroller-content > [data-vs-index] {
  contain: layout style;
}
</style>
