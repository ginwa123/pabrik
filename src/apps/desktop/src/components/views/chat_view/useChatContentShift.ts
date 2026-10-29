import { type Ref } from 'vue'
import { buildScrollContext, type ScrollLogger } from '@/helpers'
import type { Message } from './useChatMessagePresentation'
import type { VirtualScrollerExposed } from './chatViewTypes'

export interface ChatContentShiftDeps {
  virtualScrollerRef: Ref<VirtualScrollerExposed | null>
  messagesWrapperRef: Ref<HTMLElement | null>
  messages: Ref<Message[]>
  isAtBottom: Ref<boolean>
  lastAutoStickAt: Ref<number>
  sessionId: Ref<string>
  chatId: () => string
  getSuppressContentShiftStick: () => boolean
  getLastObservedScrollHeight: () => number
  setLastObservedScrollHeight: (value: number) => void
  logger: () => ScrollLogger
}

export function useChatContentShift(deps: ChatContentShiftDeps) {
  const {
    virtualScrollerRef,
    messagesWrapperRef,
    messages,
    isAtBottom,
    lastAutoStickAt,
    sessionId,
    chatId,
    getSuppressContentShiftStick,
    getLastObservedScrollHeight,
    setLastObservedScrollHeight,
    logger,
  } = deps
  const scrollLogger = logger

  let spacerRafId: number | null = null
  const onContentShift = (shift: { topSpacer: number; bottomSpacer: number; total: number }) => {
    if (getSuppressContentShiftStick()) return
    if (spacerRafId !== null) cancelAnimationFrame(spacerRafId)
    spacerRafId = requestAnimationFrame(() => {
      spacerRafId = null
      const container = virtualScrollerRef.value?.containerRef
      if (!container) return
      const newScrollHeight = container.scrollHeight
      // Only re-stick if the scrollHeight actually changed (a measurement
      // update). Positioning-only shifts (pure window moves at constant
      // total height) won't trigger a re-scroll.
      if (newScrollHeight === getLastObservedScrollHeight()) return
      const delta = newScrollHeight - getLastObservedScrollHeight()
      if (delta <= 0 || delta < 10) {
        setLastObservedScrollHeight(newScrollHeight)
        return
      }
      setLastObservedScrollHeight(newScrollHeight)
      void shift
      // Build a context with the *pre-stick* geometry (scrollTop before
      // we touch it), so the log answers "what was the world like when
      // this re-stick fired?".
      const ctx = buildScrollContext(container, {
        chatId: sessionId.value || chatId(),
        messages: messages.value.length,
        isAtBottom: isAtBottom.value,
        virtualScrollerRef,
        wrapperRef: messagesWrapperRef,
      })
      if (!isAtBottom.value) {
        scrollLogger().debug({
          ...ctx,
          caller: 'onContentShift',
          origin: 'programmatic',
          extra: {
            delta,
            lastObservedScrollHeight: newScrollHeight,
            skipped: 'user-scrolled-up',
            isAtBottom: isAtBottom.value,
            distanceFromBottom: ctx.distanceFromBottom,
            scrollTop: ctx.scrollTop,
          },
        })
        scrollLogger().info({
          ...ctx,
          caller: 'onContentShift',
          reason: 'spacer-resize-skip',
          extra: {
            delta,
            lastObservedScrollHeight: newScrollHeight,
            isAtBottom: isAtBottom.value,
            distanceFromBottom: ctx.distanceFromBottom,
            scrollTop: ctx.scrollTop,
            shift,
          },
        })
        return
      }
      // We are going to assign scrollTop. Mark the next scroll event as programmatic BEFORE the
      // assignment so the browser-fired scroll reads origin='programmatic' in handleVirtualScroll.
      scrollLogger().markProgrammatic()
      // Record the auto-stick timestamp so the loadMore gate knows the
      // stick is actively engaged right now (not just that the LLM is
      // busy — those are different things, see autoStickGate.ts).
      lastAutoStickAt.value = Date.now()
      // Explicit bottom computation.
      virtualScrollerRef.value?.scrollToBottom('auto')
      scrollLogger().info({
        ...ctx,
        caller: 'onContentShift',
        reason: 'spacer-resize-stick',
        extra: {
          delta,
          lastObservedScrollHeight: newScrollHeight,
          isAtBottom: isAtBottom.value,
          distanceFromBottom: ctx.distanceFromBottom,
          scrollTop: ctx.scrollTop,
          shift,
          willStick: true,
        },
      })
    })
  }

  const teardownContentShiftRaf = () => {
    if (spacerRafId !== null) {
      cancelAnimationFrame(spacerRafId)
      spacerRafId = null
    }
  }

  return { onContentShift, teardownContentShiftRaf }
}
