/** scrollLogger.ts A focused logger for the ChatView's scroll subsystem. */
export type ScrollOrigin = 'user' | 'programmatic'

/** Diagnostic snapshot of the scroll container element. */
export interface ContainerInfo {
  null: boolean
  tag?: string
  className?: string
  display?: string
  visibility?: string
  offsetHeight: number
  offsetParent: string | null
}

/** Diagnostic snapshot of the VirtualScroller **component** (not the inner container). */
export interface ScrollerState {
  refNull: boolean
  containerRefNull: boolean
  hasScrollToBottom: boolean
  hasContainerRef: boolean
  containerClientHeight: number
  containerOffsetHeight: number
  exposedKeys: string[]
}

/** Diagnostic snapshot of the **outer flex wrapper** that contains the VirtualScroller. */
export interface WrapperState {
  refNull: boolean
  offsetHeight: number
  clientHeight: number
  offsetParent: string | null
  display?: string
  flexDirection?: string
}

export type ScrollReason =
  // Info-level reasons (state transitions / lifecycle events)
  | 'reached-bottom'
  | 'left-bottom'
  | 'reached-top'
  | 'left-top'
  | 'load-more-threshold-reached'
  | 'load-more-suppressed'
  | 'scroll-to-bottom-forced'
  | 'scroll-to-bottom-conditional'
  | 'scroll-position-restored'
  | 'spacer-resize-stick'
  | 'spacer-resize-skip'
  | 'load-more-preserve-start'
  | 'load-more-preserve-end'
  | 'post-preserve-stick' // loadMore prepend finished, user was at bottom → explicit re-stick (task_1787638309623_3)
  // Older-history PREFETCH (task_1789505423062_0) — one page armed ahead of the scroll reaching the load-more band, so crossing the band commits from memory …
  | 'load-more-prefetch-armed' // the speculative page landed and is buffered (not yet in `messages`)
  | 'load-more-prefetch-committed' // the buffered page was prepended (trigger: buffered/foreground/manual)
  | 'load-more-prefetch-skipped' // the arm trigger ran but a state blocked it (extra.skip: PrefetchSkip)
  | 'load-more-prefetch-dropped' // a buffered/in-flight page was discarded (extra.cause)
  | 'load-more-prefetch-failed' // the speculative request threw (warn level)
  | 'sse-chunk-arrived'
  | 'messages-length-changed'
  // Per-call handleVirtualScroll diagnostics.
  | 'first-scroll' // first scroll event for this chat (no prior deltas)
  | 'direction-change' // user reversed scroll direction (up↔down)
  | 'content-resized' // scrollHeight changed between two scroll events
  | 'lazy-load-zone' // within VirtualScroller's loadMoreThreshold but not at the 10px edge
  // VirtualScroller internal diagnostics (2026-09-02 blinking-loop deep dive)
  | 'sizer-recomputed' // sizerHeight flipped between modelTotal and realTotal
  | 'sizer-clamp' // sizerHeight is currently clamped (overshoot > hysteresis)
  | 'measure-compensation' // measureItems anchor compensation wrote scrollTop
  | 'scroll-to-bottom-target' // scrollToBottom chose realBottom vs modelBottom
  | 'isAtBottom-decision' // handleVirtualScroll isAtBottom retained vs flipped
  // Warn-level reason: handleVirtualScroll fired but the container ref chain was null (component unmounted, inner ref not yet bound, or layout chain broke).
  | 'no-container'
  // Debug-level reason (per-frame sample)
  | 'scroll-sample'
  | 'error'

export interface ScrollContext {
  /** Stable id for the chat (props.chatId, may be 'pending-…'). */
  chatId: string
  /** Number of messages currently rendered. */
  messages: number
  /** VirtualScroller container geometry. */
  scrollTop: number
  scrollHeight: number
  clientHeight: number
  /** Derived — saves you from doing the math in your head. */
  distanceFromTop: number
  distanceFromBottom: number
  /** 0 = at top, 1 = at bottom. -1 if content is shorter than viewport. */
  scrollPercent: number
  /** True when within `BOTTOM_THRESHOLD` px of the bottom. */
  isAtBottom: boolean
  /** Was this scroll caused by the user's wheel/touch, or by code? */
  origin: ScrollOrigin
  /** What triggered this log line. */
  reason: ScrollReason
  /** Diagnostic snapshot of the scroll container element. */
  containerInfo: ContainerInfo
  /** Which function in ChatView produced this log line, e.g. `'loadChatHistory'`. */
  caller?: string
  /** Diagnostic snapshot of the VirtualScroller **component** (see `ScrollerState` doc). */
  scrollerState?: ScrollerState
  /** Diagnostic snapshot of the outer flex wrapper (see `WrapperState` doc). */
  wrapperState?: WrapperState
  /** Short stack trace captured ONLY when the container is null or on warn/error. */
  stack?: string
  /** Free-form extras (caller, delta, etc.). */
  extra?: Record<string, unknown>
}

// ─── Configuration ────────────────────────────────────────────────────────────
export const BOTTOM_THRESHOLD = 10

/** How far the height MODEL may sit above the real content bottom before `VirtualScroller.bottomScrollTop` switches to the real bottom. */
export const MODEL_OVERSHOOT_HYSTERESIS_PX = 50

/** Tolerance for the at-bottom judgement once it is measured against the STABLE anchor (`settledBottom`) rather than a live `bottomScrollTop()`. */
export const AT_BOTTOM_STABLE_TOLERANCE_PX = BOTTOM_THRESHOLD + MODEL_OVERSHOOT_HYSTERESIS_PX

/** Within this many px of the top counts as "at the top". */
export const TOP_THRESHOLD = 10

/** Debug-level scroll samples are throttled to this interval. */
const DEBUG_THROTTLE_MS = 200

// ─── Programmatic-scroll tracking ─────────────────────────────────────────────
let programmaticScrollsRemaining = 0
let programmaticScrollsResetTimer: ReturnType<typeof setTimeout> | null = null

/** Call this BEFORE a programmatic `scrollTop` assignment. */
export const markProgrammatic = (): void => {
  programmaticScrollsRemaining += 1
  // Safety net: if the scroll event never fires (e.g., scrollTop didn't actually change because we were already there), don't leak the mark.
  if (programmaticScrollsResetTimer) clearTimeout(programmaticScrollsResetTimer)
  programmaticScrollsResetTimer = setTimeout(() => {
    programmaticScrollsRemaining = 0
  }, 100)
}

/** Returns true once per pending programmatic mark, then decrements. */
export const consumeProgrammatic = (): boolean => {
  if (programmaticScrollsRemaining > 0) {
    programmaticScrollsRemaining -= 1
    return true
  }
  return false
}

// ─── Throttled debug queue ────────────────────────────────────────────────────
let pendingDebugContext: ScrollContext | null = null
let pendingDebugTimer: ReturnType<typeof setTimeout> | null = null

const flushPendingDebug = (): void => {
  pendingDebugTimer = null
  if (!pendingDebugContext) return
  const ctx = pendingDebugContext
  pendingDebugContext = null
  // debug() would re-throttle; emit directly via emit().
  emit(ctx, 'debug')
}

// ─── Logger factory ───────────────────────────────────────────────────────────
export interface ScrollLogger {
  /** Throttled per-frame sample. */
  debug: (
    ctx: Omit<ScrollContext, 'chatId' | 'reason' | 'origin'> & {
      origin?: ScrollOrigin
      caller?: string
    },
  ) => void
  /** State change / lifecycle event. Always logged. */
  info: (
    ctx: Omit<ScrollContext, 'chatId' | 'reason' | 'origin'> & {
      reason: ScrollReason
      origin?: ScrollOrigin
      caller?: string
    },
  ) => void
  /** Warning — something unexpected but recoverable. */
  warn: (
    ctx: Omit<ScrollContext, 'chatId' | 'reason' | 'origin'> & {
      reason: ScrollReason
      origin?: ScrollOrigin
      caller?: string
    },
  ) => void
  /** Error — scroll subsystem failed. */
  error: (
    ctx: Omit<ScrollContext, 'chatId' | 'reason' | 'origin'> & {
      reason: ScrollReason
      origin?: ScrollOrigin
      caller?: string
    },
  ) => void
  /** Mark the next scroll event(s) as programmatic. */
  markProgrammatic: (count?: number) => void
}

/** Create a scroll logger bound to a chat id. @param chatId The chat session id (used to correlate logs across components and to label every line). */
export const createScrollLogger = (chatId: string): ScrollLogger => {
  // Auto-derive the context fields the caller usually can't be bothered to pass.
  const resolveOrigin = (explicit?: ScrollOrigin): ScrollOrigin => {
    if (explicit) return explicit
    if (consumeProgrammatic()) return 'programmatic'
    return 'user'
  }

  const buildContext = (
    partial: Omit<ScrollContext, 'chatId' | 'reason' | 'origin'> & { origin?: ScrollOrigin },
    reason: ScrollReason,
  ): ScrollContext => {
    const { scrollTop, scrollHeight, clientHeight, messages, isAtBottom, extra, containerInfo } =
      partial
    const distanceFromTop = Math.max(0, scrollTop)
    // Prefer the caller's own number.
    const distanceFromBottom =
      typeof partial.distanceFromBottom === 'number'
        ? Math.max(0, partial.distanceFromBottom)
        : Math.max(0, scrollHeight - scrollTop - clientHeight)
    const scrollable = scrollHeight - clientHeight
    const scrollPercent = scrollable > 0 ? Math.min(1, Math.max(0, scrollTop / scrollable)) : -1
    return {
      chatId,
      messages,
      scrollTop,
      scrollHeight,
      clientHeight,
      distanceFromTop,
      distanceFromBottom,
      scrollPercent,
      isAtBottom,
      origin: resolveOrigin(partial.origin),
      reason,
      containerInfo,
      extra,
    }
  }

  return {
    debug(partial) {
      const ctx = buildContext(partial, 'scroll-sample')
      pendingDebugContext = ctx
      if (pendingDebugTimer) return // already scheduled
      pendingDebugTimer = setTimeout(flushPendingDebug, DEBUG_THROTTLE_MS)
    },
    info(partial) {
      const ctx = buildContext(partial, partial.reason)
      emit(ctx, 'info')
    },
    warn(partial) {
      const ctx = buildContext(partial, partial.reason)
      emit(ctx, 'warn')
    },
    error(partial) {
      const ctx = buildContext(partial, partial.reason)
      emit(ctx, 'error')
    },
    markProgrammatic(count = 1) {
      programmaticScrollsRemaining += count
    },
  }
}

// ─── Emit ─────────────────────────────────────────────────────────────────────
let eventCounter = 0

const emit = (ctx: ScrollContext, level: 'debug' | 'info' | 'warn' | 'error'): void => {
  // Production gate: silence per-frame debug spam AND the ~60Hz info stream that fires during SSE streaming scrolls (scroll-perf Task 6).
  if ((level === 'debug' || level === 'info') && !import.meta.env.DEV) return

  eventCounter += 1
  let tag = `[scroll#${eventCounter} chat=${ctx.chatId} ${level.toUpperCase()}]`

  // ── Caller / scroller / wrapper metadata in the tag ───────────────────
  if (ctx.caller) {
    tag += ` caller=${ctx.caller}`
  }
  if (ctx.scrollerState) {
    if (ctx.scrollerState.refNull) {
      tag += ' scroller=ref-null'
    } else if (ctx.scrollerState.containerRefNull) {
      tag += ' scroller=container-null'
    } else {
      tag += ` scroller=ok(h=${ctx.scrollerState.containerClientHeight})`
    }
  }
  if (ctx.wrapperState) {
    if (ctx.wrapperState.refNull) {
      tag += ' wrapper=ref-null'
    } else if (ctx.wrapperState.offsetHeight === 0) {
      tag += ` wrapper=h=0(d=${ctx.wrapperState.display ?? '?'},flex=${ctx.wrapperState.flexDirection ?? '?'})`
    } else {
      tag += ` wrapper=h=${ctx.wrapperState.offsetHeight}`
    }
  }

  // Diagnostic markers for suspicious container states.
  if (ctx.scrollHeight === 0 && ctx.clientHeight === 0) {
    tag += ` ⚠ZERO-SIZE(${ctx.containerInfo.tag ?? '?'} d=${ctx.containerInfo.display ?? '?'} oH=${ctx.containerInfo.offsetHeight})`
  } else if (ctx.scrollHeight === 0) {
    tag += ` ⚠ZERO-SCROLL-HEIGHT(${ctx.containerInfo.tag ?? '?'} ch=${ctx.clientHeight} d=${ctx.containerInfo.display ?? '?'})`
  } else if (ctx.clientHeight === 0) {
    tag += ` ⚠ZERO-CLIENT-HEIGHT(${ctx.containerInfo.tag ?? '?'} sh=${ctx.scrollHeight})`
  }
  const originMark = ctx.origin === 'programmatic' ? '⚙️' : '👆'
  const isAtBottomMark = ctx.isAtBottom ? '⤵' : '↑'
  // The "short" label is misleading when the container is 0×0 (which is the whole point of the markers above).
  const positionLabel =
    ctx.scrollHeight === 0
      ? 'zero-sh'
      : ctx.scrollPercent === -1
        ? 'short'
        : (ctx.scrollPercent * 100).toFixed(1) + '%'
  const line1 =
    `${tag} ${originMark} ${isAtBottomMark} ${ctx.reason} ` +
    `top=${ctx.scrollTop.toFixed(0)} ` +
    `bottom=${ctx.distanceFromBottom.toFixed(0)}px ` +
    `(${positionLabel}) ` +
    `msgs=${ctx.messages}`

  // ── Lazy stack capture for hard-to-debug cases ─────────────────────────
  if (!ctx.stack && (ctx.containerInfo.null || level === 'warn' || level === 'error')) {
    try {
      const err = new Error()
      const raw = err.stack ?? ''
      // Drop frames that are inside this file (the logger itself) — the caller is what we want.
      const frames = raw
        .split('\n')
        .filter((line) => !line.includes('scrollLogger.ts'))
        .slice(0, 5)
        .join('\n')
      if (frames) ctx.stack = frames
    } catch {
      // stack capture is best-effort; never let it break logging
    }
  }

  // Two-line format: first line is the headline (scannable in DevTools' log group), second line is the full context object (collapsible).
  if (level === 'error') {
    console.error(line1, ctx)
  } else if (level === 'warn') {
    console.warn(line1, ctx)
  } else {
    // info and debug both use console.log with the object so the user can click to expand.
    console.log(line1, ctx)
  }
}

// ─── Helpers exported for callers ─────────────────────────────────────────────
const buildContainerInfo = (container: HTMLElement | null | undefined): ContainerInfo => {
  if (!container) return { null: true, offsetHeight: 0, offsetParent: null }
  const scrollHeight = container.scrollHeight
  const clientHeight = container.clientHeight
  const info: ContainerInfo = {
    null: false,
    tag: container.tagName,
    className: container.className,
    offsetHeight: container.offsetHeight,
    offsetParent: container.offsetParent ? container.offsetParent.tagName : null,
  }
  // Only pay the getComputedStyle cost when dimensions are weird.
  if (scrollHeight === 0 || clientHeight === 0) {
    const style = getComputedStyle(container)
    info.display = style.display
    info.visibility = style.visibility
  }
  return info
}

/** Build the diagnostic `ScrollerState` block for a VirtualScroller component ref. */
const buildScrollerState = (scrollerRef: { value: unknown } | null | undefined): ScrollerState => {
  if (!scrollerRef) {
    return {
      refNull: true,
      containerRefNull: true,
      hasScrollToBottom: false,
      hasContainerRef: false,
      containerClientHeight: 0,
      containerOffsetHeight: 0,
      exposedKeys: [],
    }
  }
  const scroller = scrollerRef.value as Record<string, unknown> | null
  if (!scroller) {
    return {
      refNull: true,
      containerRefNull: true,
      hasScrollToBottom: false,
      hasContainerRef: false,
      containerClientHeight: 0,
      containerOffsetHeight: 0,
      exposedKeys: [],
    }
  }
  const containerRef = scroller.containerRef as { value: unknown } | undefined
  const hasContainerRef = !!containerRef
  const container = (containerRef?.value ?? null) as HTMLElement | null
  return {
    refNull: false,
    containerRefNull: !container,
    hasScrollToBottom: typeof scroller.scrollToBottom === 'function',
    hasContainerRef,
    containerClientHeight: container?.clientHeight ?? 0,
    containerOffsetHeight: container?.offsetHeight ?? 0,
    exposedKeys: Object.keys(scroller).sort(),
  }
}

/** THE bottom edge, in scrollTop coordinates — the same number the VirtualScroller's `scrollToBottom` is about to target. */
const resolveBottomEdge = (
  scrollerRef: { value: unknown } | null | undefined,
  container: HTMLElement | null | undefined,
): number => {
  const domEdge = Math.max(0, (container?.scrollHeight ?? 0) - (container?.clientHeight ?? 0))
  const scroller = scrollerRef?.value as { bottomScrollTop?: () => number } | null | undefined
  if (!scroller || typeof scroller.bottomScrollTop !== 'function') return domEdge
  const edge = scroller.bottomScrollTop()
  return Number.isFinite(edge) ? edge : domEdge
}

/** Build the diagnostic `WrapperState` block for the outer flex wrapper. */
const buildWrapperState = (wrapperRef: { value: unknown } | null | undefined): WrapperState => {
  if (!wrapperRef) {
    return { refNull: true, offsetHeight: 0, clientHeight: 0, offsetParent: null }
  }
  const wrapper = wrapperRef.value as HTMLElement | null
  if (!wrapper) {
    return { refNull: true, offsetHeight: 0, clientHeight: 0, offsetParent: null }
  }
  const info: WrapperState = {
    refNull: false,
    offsetHeight: wrapper.offsetHeight,
    clientHeight: wrapper.clientHeight,
    offsetParent: wrapper.offsetParent ? wrapper.offsetParent.tagName : null,
  }
  // getComputedStyle forces a style recalc — only do it when dimensions are suspicious, same logic as buildContainerInfo.
  if (wrapper.offsetHeight === 0 || wrapper.clientHeight === 0) {
    const style = getComputedStyle(wrapper)
    info.display = style.display
    info.flexDirection = style.flexDirection
  }
  return info
}

/** Build a context object from a container element + the caller's snapshot of state. */
export const buildScrollContext = (
  container: HTMLElement | null | undefined,
  fallback: Pick<ScrollContext, 'chatId' | 'messages' | 'isAtBottom'> & {
    /** The VirtualScroller ref from ChatView. */
    virtualScrollerRef?: { value: unknown } | null
    /** The outer flex wrapper ref from ChatView. */
    wrapperRef?: { value: unknown } | null
  },
  partial: Partial<Pick<ScrollContext, 'origin' | 'reason' | 'extra' | 'caller'>> = {},
): Omit<ScrollContext, 'reason' | 'origin'> & { reason?: ScrollReason; origin?: ScrollOrigin } => {
  const scrollTop = container?.scrollTop ?? 0
  const scrollHeight = container?.scrollHeight ?? 0
  const clientHeight = container?.clientHeight ?? 0
  // `distanceFromBottom` must be the number the CALLER decided with.
  const bottomEdge = resolveBottomEdge(fallback.virtualScrollerRef, container)
  return {
    chatId: fallback.chatId,
    messages: fallback.messages,
    isAtBottom: fallback.isAtBottom,
    scrollTop,
    scrollHeight,
    clientHeight,
    distanceFromTop: Math.max(0, scrollTop),
    distanceFromBottom: Math.max(0, bottomEdge - scrollTop),
    scrollPercent:
      scrollHeight - clientHeight > 0
        ? Math.min(1, Math.max(0, scrollTop / (scrollHeight - clientHeight)))
        : -1,
    // `origin` is intentionally omitted — see the doc comment above.
    reason: partial.reason,
    extra: partial.extra,
    caller: partial.caller,
    containerInfo: buildContainerInfo(container),
    scrollerState: buildScrollerState(fallback.virtualScrollerRef),
    wrapperState: buildWrapperState(fallback.wrapperRef),
  }
}
