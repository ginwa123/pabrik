/**
 * virtualScrollerScrollAnchor.ts
 *
 * Pure math for VirtualScroller's measurement-shift compensation.
 *
 * Why this exists: `measureItems()` rewrites REAL heights over ESTIMATES
 * for every rendered child — including up to `buffer` items ABOVE the
 * viewport. Each write mutates `accumulatedHeights`, and since CSS scroll
 * anchoring is disabled (`overflow-anchor: none`, needed for the older
 * ratcheting fix), nothing adjusts scrollTop unless WE do. Content under
 * the viewport teleports by the total model delta above the anchor —
 * the "long chats jump while scrolling" bug
 * (task_1787496087806_6).
 *
 * ── v2: anchor prefix-sum delta (2026-09-23, scroll-jump fix) ──────────────
 *
 * v1 summed PER-MEUREMENT deltas with `baseline = oldHeight ??
 * defaultItemHeight`. That baseline was wrong twice over, and both
 * failure modes showed up as jumps on "many messages with many
 * different heights":
 *
 *   1. Wrong baseline for first measurements. The model does NOT
 *      estimate unmeasured items with the static `defaultItemHeight`
 *      prop (64px in ChatView) — it uses the adaptive running MEDIAN
 *      (`estimateHeight`, typically 200-600px in a real chat). Every
 *      first measurement above the viewport therefore over-compensated
 *      by (median − 64) px. With buffer=30, scrolling up through
 *      unmeasured history stacked tens of those errors into one
 *      scrollTop write — the scroll gesture visibly "fought back".
 *
 *   2. Estimate drift carried NO measurement entry. `observe()` feeds
 *      the estimator INSIDE a measure pass, so the median can move
 *      between rebuilds; every UNMEASURED item's contribution to the
 *      prefix changes with it — including items above the viewport.
 *      v1 only compensated entries in its `measurements` list, so a
 *      median shift (e.g. the first SSE-driven remeasure after mount)
 *      moved topSpacer with zero scrollTop correction: a pure
 *      teleport of the whole rendered window.
 *
 * v2 compares the ANCHOR's prefix sum before/after the model rebuild.
 * `prefix(anchor)` IS the summed height-model contribution of every
 * item strictly above the anchor — measured or not, any estimate
 * source. Its delta is exactly the signed shift of the content under
 * the viewport top edge:
 *
 *   screenPos(item) = prefix(anchor) + realOffset - scrollTop
 *
 * Keeping `scrollTop + prefix(anchor)` constant keeps every rendered
 * pixel stationary, and items AT/AFTER the anchor are excluded by
 * construction (their heights never appear in `prefix(anchor)`) —
 * visible-window growth still flows through uncompensated, as
 * intended.
 *
 * Pure function (no DOM, no Vue) so every branch is unit-testable,
 * mirroring `virtualScrollerThreshold.ts`.
 */

// Keep the wire shape honest without importing DOM types into a pure
// module: heights are plain numbers in px.
type geometry_px = number

/**
 * One pending height write from a measure pass. Carried on the debug
 * log only — compensation itself no longer consumes per-item entries
 * (see the v2 note above).
 */
export interface AnchorMeasurement {
  /** Item index in the full items array. */
  index: number
  /** Newly measured height in px (>0). */
  newHeight: number
  /**
   * Previously stored height in px, or undefined when this item has
   * never been measured before.
   */
  oldHeight: number | undefined
}

export interface AnchorCompensationInput {
  /**
   * Index of the first item at/under the viewport top edge BEFORE the
   * height model changed (the anchor). Negative = empty list → no-op.
   */
  anchorIndex: number
  /** scrollTop captured before the height model changed. */
  prevScrollTop: geometry_px
  /**
   * `accumulatedHeights[anchorIndex]` captured BEFORE the pass
   * mutates the model — the model-space top edge of the anchor item.
   */
  oldAnchorTop: geometry_px
  /**
   * `accumulatedHeights[anchorIndex]` after the pass rebuilt the
   * model (measured heights written, estimator re-seeded, estimates
   * refreshed).
   */
  newAnchorTop: geometry_px
  /**
   * The bottom edge AFTER the pass (`bottomScrollTop()`), passed only when
   * the reader was AT THE BOTTOM before the pass mutated the model. Omit it
   * and the anchor math runs.
   *
   * The anchor exists to hold still whatever the reader is looking at. A
   * reader sitting at the bottom is not anchored to anything — they are
   * reading the newest content, and the newest content is exactly what this
   * pass just resized. Anchoring them instead preserves a position they never
   * asked for, and that is what breaks the auto-stick: a long chat whose
   * window expands on the first long chunk measures a batch of rows above the
   * anchor, the prefix delta runs to thousands of pixels, and the write drags
   * the reader that far UP from the bottom. ChatView then reads a huge upward
   * move as "the user left the bottom" (the write is flagged programmatic, so
   * it does not even count as a gesture — `retainedThroughGrowth` cannot
   * recover it either, its cap is a strict `< 100` against a gap of ~15,900),
   * the stick disarms, and every later chunk of the long response lands
   * off-screen. The reader is left watching a gap grow.
   *
   * Targeting the bottom instead of the anchor keeps the reader where they
   * were, absorbs the same model change, and leaves the resulting scroll
   * event with `deltaTop ≈ 0` — so `isAtBottom` survives the pass.
   */
  atBottomTarget?: geometry_px
}

export interface AnchorCompensationResult {
  /**
   * Signed delta of the anchor's prefix sum. Positive = content above
   * grew in the model → scrollTop must increase to stay stationary.
   */
  shiftPx: geometry_px
  /** scrollTop after compensation, clamped at ≥ 0. */
  newScrollTop: geometry_px
  /** True when the clamp at 0 bit (residual jump is unavoidable). */
  clamped: boolean
  /**
   * Which rule produced `newScrollTop`. `'bottom'` means the reader was at the
   * bottom and the pass targeted the bottom edge instead of the anchor; the
   * `shiftPx` reported alongside it is the model delta that was absorbed, not
   * a move the reader can observe.
   */
  target: 'anchor' | 'bottom'
}

/**
 * Compute the scrollTop adjustment that keeps rendered content
 * stationary when the height model's prefix sum at the anchor changes.
 *
 * Rules:
 *   - `prefix(anchor)` covers items STRICTLY ABOVE the anchor only.
 *     A height change AT/AFTER the anchor moves that item's bottom
 *     edge (and everything below), never its top edge — content under
 *     the viewport top is unchanged, so those writes must not
 *     contribute. The prefix definition gives this for free.
 *   - The delta covers BOTH kinds of model churn in one subtraction:
 *     real-height writes for measured items AND estimate refreshes
 *     (estimator median movement) for unmeasured ones.
 *   - Result clamps at ≥ 0 (scrollTop can't go negative); `clamped`
 *     flags the residual-jump case.
 *   - Negative / non-finite anchorIndex (empty or unmounted list) is
 *     a no-op.
 *   - A reader who was at the bottom is NOT anchored: they get the bottom
 *     edge instead (see `atBottomTarget`). The anchor's contract is to hold
 *     the reader's view still, and at the bottom there is no view to hold —
 *     the content they are reading is what this pass just resized.
 */
export function computeAnchorCompensation(
  input: AnchorCompensationInput,
): AnchorCompensationResult {
  const { anchorIndex, prevScrollTop, oldAnchorTop, newAnchorTop, atBottomTarget } = input

  if (
    !Number.isFinite(anchorIndex) ||
    anchorIndex < 0 ||
    !Number.isFinite(oldAnchorTop) ||
    !Number.isFinite(newAnchorTop)
  ) {
    return { shiftPx: 0, newScrollTop: prevScrollTop, clamped: false, target: 'anchor' }
  }

  const shiftPx = newAnchorTop - oldAnchorTop

  // A reader at the bottom is re-targeted to the bottom edge rather than
  // compensated around the anchor — see `atBottomTarget` on the input type for
  // the failure this prevents.
  //
  // Ordered BEFORE the `shiftPx === 0` early return, and that ordering is the
  // fix (2026-10-10). It used to sit after it, on the reasoning that "a pass
  // that changed nothing above the anchor still writes nothing". That is true
  // for a scrolled-up reader and FALSE for a bottom one: the anchor path exists
  // to hold a reader still, and a bottom reader has no anchor to hold — they
  // need re-pinning whenever the bottom MOVED, which happens on every streaming
  // chunk (content grows AT/AFTER the anchor, so the prefix is unchanged and
  // `shiftPx` is 0) and whenever the rendered window shifts (the anchor index
  // moves with it, so the prefix at the anchor is unchanged too).
  //
  // Measured: every pass in a real streaming turn had `shiftPx === 0`, so
  // `atBottomTarget` was computed and then discarded, and the ONLY thing
  // re-pinning a bottom reader was ChatView's separate `scrollToBottom()` call.
  // When that call lost the race with the measure pass — which is timing
  // dependent, and therefore why this only ever failed on the slower macOS
  // runner — the reader was left where the last successful pin put them while
  // the bottom had already moved on. That is the "the stick died mid-stream"
  // flake.
  //
  // ── The guard is DIRECTION, not "did the target differ" ─────────────────
  //
  // The first attempt re-pinned whenever `atBottomTarget !== prevScrollTop`, and
  // it regressed `chatview_send_scrolls_to_bottom_ui_test.py` hard. Measured
  // pass, a send from history:
  //
  //     prevScrollTop=22987  oldAnchorTop=21321  newAnchorTop=22987  (shift +1666)
  //     atBottomTarget=22800
  //
  // The re-pin wrote 22800 — 187px ABOVE the reader — and stranded them 1833px
  // short of the bottom with no recovery. `atBottomTarget` comes from
  // `bottomScrollTop()` read AFTER the model rebuild but BEFORE the DOM
  // re-renders, so `content.offsetHeight` still describes the OLD window while
  // `topSpacer` comes from the NEW one; when the prefix moved, that pair never
  // existed together and the target is simply wrong.
  //
  // What distinguishes the bad pass from the good ones is not the prefix delta —
  // it is which way the target sits relative to the reader. A re-pin exists to
  // carry a bottom reader DOWN to content that grew below them. A target ABOVE
  // where they already sit is never something to write: it is either a stale
  // read or a reader already past the bottom, and writing it drags them UP,
  // which is the one move the stick must never make.
  //
  // So the guard is `atBottomTarget > prevScrollTop`. That admits every pass
  // whose target is genuinely further down (including the moved-prefix cases
  // this helper was originally written for) and rejects the stale upward read.
  // Scrolled-up readers are unaffected either way — the caller only passes
  // `atBottomTarget` when it has judged the reader to be at the bottom.
  if (
    typeof atBottomTarget === 'number' &&
    Number.isFinite(atBottomTarget) &&
    atBottomTarget > prevScrollTop
  ) {
    return {
      shiftPx,
      newScrollTop: Math.max(0, atBottomTarget),
      clamped: false,
      target: 'bottom',
    }
  }

  if (shiftPx === 0) {
    return { shiftPx: 0, newScrollTop: prevScrollTop, clamped: false, target: 'anchor' }
  }

  const raw = prevScrollTop + shiftPx
  const clamped = raw < 0
  return {
    shiftPx,
    newScrollTop: Math.max(0, raw),
    clamped,
    target: 'anchor',
  }
}
