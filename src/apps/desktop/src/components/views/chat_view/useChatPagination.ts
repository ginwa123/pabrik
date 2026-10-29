import { nextTick, type ComputedRef, type Ref } from 'vue'
import { Effect } from 'effect'
import * as api from '../../../api'
import { ChatHistoryError } from '../../../api'
import { chatEngineDb, newestCursor, toChatMessage } from '../../../sync/ChatEngineDb'
import { runSyncEffect, runSyncEffectOr, runSyncVoid } from '../../../sync/runtime'
import { useChatScrollRestore } from '../../../composables/useChatScrollRestore'
import {
  buildScrollContext,
  isAutoStickActive,
  AUTO_STICK_GATE_MS,
  decidePrefetchOlder,
  armRadiusPx,
  nextFetchEstimate,
  PREFETCH_SAMPLE_INIT_MS,
  type ScrollLogger,
  type ScrollReason,
} from '@/helpers'
import { splitMediaUrlsWire } from '../../../helpers/mediaUrls'
import { runEffectExit } from '../../../helpers/effectRuntime'
import {
  fetchInitialHistoryWithRetry,
  INITIAL_HISTORY_TIMEOUT_MS,
} from '../../../helpers/chatHistoryRetry'
import type { Message, MessageGroup } from './useChatMessagePresentation'
import type { VirtualScrollerExposed } from './chatViewTypes'

export interface ChatPaginationDeps {
  props: { chatId: string }
  sessionId: Ref<string>
  messages: Ref<Message[]>
  messagesWrapperRef: Ref<HTMLElement | null>
  virtualScrollerRef: Ref<VirtualScrollerExposed | null>
  sessionCwd: Ref<string>
  gitWorktreeCwd: Ref<string>
  effectiveCwd: ComputedRef<string>
  error: Ref<string | null>
  isLoading: Ref<boolean>
  isLoadingMore: Ref<boolean>
  isRemoteLoadPending: Ref<boolean>
  historyConfirmed: Ref<boolean>
  hasMoreMessages: Ref<boolean>
  messageCursor: Ref<string | null>
  isAtBottom: Ref<boolean>
  isPendingSession: ComputedRef<boolean>
  isLLMProcessing: ComputedRef<boolean>
  maxTotalTokens: Ref<number>
  maxCapacityTotalTokens: Ref<number>
  lastAutoStickAt: Ref<number>
  sessionSkills: Ref<api.SkillInfo[]>
  selectedAgent: Ref<string | null>
  messageGroups: ComputedRef<MessageGroup[]>
  chatPrUrl: Ref<string>
  chatPrProvider: Ref<string>
  chatScrollRestore: ReturnType<typeof useChatScrollRestore>
  logger: () => ScrollLogger
  noteCwdMutation: (prevCwd: string) => void
  rehydrateSubAgentProgress: () => Promise<void>
  setupCodeBlockCopyButtons: () => void
  PAGE_SIZE: number
}

/** Owns the older-history arm → commit → refill cycle, `loadChatHistory`, and the two scroll
 * primitives that cycle drives. The `─── Scroll` header travels with it so the bundle order that
 * `ChatView.lazyPrefetch.spec.ts` pins (… loadChatHistory < ─── Scroll) still holds. */
export function useChatPagination(deps: ChatPaginationDeps) {
  const {
    props,
    sessionId,
    messages,
    messagesWrapperRef,
    virtualScrollerRef,
    sessionCwd,
    gitWorktreeCwd,
    effectiveCwd,
    error,
    isLoading,
    isLoadingMore,
    isRemoteLoadPending,
    historyConfirmed,
    hasMoreMessages,
    messageCursor,
    isAtBottom,
    isPendingSession,
    isLLMProcessing,
    maxTotalTokens,
    maxCapacityTotalTokens,
    lastAutoStickAt,
    sessionSkills,
    selectedAgent,
    messageGroups,
    chatPrUrl,
    chatPrProvider,
    chatScrollRestore,
    logger,
    noteCwdMutation,
    rehydrateSubAgentProgress,
    setupCodeBlockCopyButtons,
    PAGE_SIZE,
  } = deps

  // Guard flag for the messages-length watcher's auto-stick. During the initial load, the
  // loadChatHistory branch handles the scroll explicitly (either restore a saved position via
  // scrollToPosition or land at the bottom via scrollToBottom).
  let isInitialLoad = false
  let lastObservedScrollHeight = 0
  // True while a loadMore preserve window is in flight — contentShift
  // events are ignored entirely (same effect as the old observer teardown,
  // without detaching anything).
  let suppressContentShiftStick = false

  // ─── Older-history pagination: arm → commit → refill ─────────────────────────
  // Task_1789505423062_0 — "the auto fetch is loaded after the user hit the max.
  interface BufferedOlderPage {
    /** Cursor this page was requested with — must still equal `messageCursor` to commit. */
    fetchedWithCursor: string | null
    /** Generation stamp; a session switch / refresh invalidates it. */
    generation: number
    messages: Message[]
    hasMore: boolean
    nextCursor: string | null
    /** Measured round trip, folded into `fetchEstimateMs`. */
    measuredMs: number
    /** `performance.now()` when the page landed (for the bufferedAgeMs log). */
    armedAt: number
  }

  /** Page armed in memory, not yet in `messages`. `null` = nothing armed. */
  let bufferedOlderPage: BufferedOlderPage | null = null
  /** In-flight ARM request. Doubles as the single source of truth for "arm in flight". */
  let prefetchPromise: Promise<void> | null = null
  /** A commit (prepend/preserve) is in flight — guards the double-commit race. */
  let isCommittingOlder = false
  /** Bumped on session switch / refresh / unmount; invalidates buffers and late responses. */
  let commitGeneration = 0
  /** EMA of observed `getChatHistory` durations (logged; drives the Phase-2 velocity term). */
  let fetchEstimateMs = PREFETCH_SAMPLE_INIT_MS
  /** `performance.now()` deadline before another ARM may be attempted after a failure. */
  let prefetchBackoffUntil = 0
  let prefetchFailures = 0
  /** Consecutive commits with no intervening user gesture — bounds refill chaining. */
  let prefetchAutoChain = 0
  /** Last skip reason logged, so a fling inside the radius doesn't spam one line per frame. */
  let lastPrefetchSkip: string | null = null

  /** How many consecutive gesture-less commits may chain before REFILL stops. A commit normally
   * restores the anchor far below the band (so no chain), but a tall viewport / short page can leave
   * the viewport inside the band and pull pages back-to-back. */
  const MAX_PREFETCH_AUTO_CHAIN = 3

  /**  * Shared log context for the prefetch path — the same scroller/wrapper geometry every other scroll
   * log carries. One helper, so the five prefetch log lines (`armed` / `committed` / `skipped` /
   * `dropped` / `failed`) can never disagree about the geometry they report. */
  const prefetchLogCtx = (
    reason: ScrollReason,
    caller: string,
    extra: Record<string, unknown>,
  ): Parameters<ScrollLogger['info']>[0] => ({
    ...buildScrollContext(virtualScrollerRef.value?.containerRef, {
      chatId: sessionId.value || props.chatId,
      messages: messages.value.length,
      isAtBottom: isAtBottom.value,
      virtualScrollerRef,
      wrapperRef: messagesWrapperRef,
    }),
    reason,
    caller,
    extra,
  })

  /**  * Map REST rows into the view's `Message` shape. Shared by the initial load AND the scroll-back
   * prefetch so a pull of older history can never drift from the initial page's wire shape (the #291
   * lesson: two mappers for one endpoint = two shapes). */
  const toChatMessages = (
    rows: Awaited<ReturnType<typeof api.getChatHistory>>['messages'] | undefined,
  ): Message[] =>
    (rows || []).map((msg) => ({
      id: msg.id || `msg-${msg.created_at}`,
      role: msg.role as 'user' | 'assistant' | 'system' | 'tool',
      content: msg.content,
      timestamp: new Date((msg.created_at || 0) * 1000),
      tool_name: msg.tool_name,
      diffview_before: msg.diffview_before,
      diffview_after: msg.diffview_after,
      image_urls: splitMediaUrlsWire(msg.image_url),
      video_urls: splitMediaUrlsWire(msg.video_url),
      file_attachments: msg.file_attachments,
      finish_reason: msg.finish_reason,
      tool_calls_json: msg.tool_calls_json,
      tool_call_id: msg.tool_call_id,
      is_input: msg.is_input,
      is_output: msg.is_output,
      reasoning_content: msg.reasoning_content || undefined,
    }))

  const mergeMessagesById = (current: Message[], incoming: Message[]): Message[] => {
    const byId = new Map(current.map((message) => [message.id, message]))
    for (const message of incoming) byId.set(message.id, message)
    return [...byId.values()]
  }

  // SSE is the freshest source for tool rows it has delivered in this view.
  // Retain their ids for the component lifetime so a late REST response
  // cannot roll a completed tool result back to its placeholder.
  let liveMessageSessionId: string | null = null
  const liveMessageIds = new Set<string>()

  function claimLiveMessageSession(sid: string): void {
    if (liveMessageSessionId === sid) return
    liveMessageSessionId = sid
    liveMessageIds.clear()
  }

  const rememberLiveMessage = (sid: string, id: string, role: Message['role']): void => {
    claimLiveMessageSession(sid)
    if (role === 'tool') liveMessageIds.add(id)
  }

  const currentLiveMessages = (): Message[] =>
    messages.value.filter(
      (message) => liveMessageIds.has(message.id) || message.id.startsWith('streaming-'),
    )

  /**  * Fetch ONE older page and measure the round trip. Network + mapping only: mutates no component
   * state except the fetch-duration estimate. Used by the speculative ARM (buffered, never rendered
   * directly) and by the foreground path when no buffer is armed. */
  const fetchOlderPage = async (cursor: string | null): Promise<BufferedOlderPage> => {
    const startedAt = performance.now()
    // Cache-first older page: serve from IndexedDB when it holds rows older than the current oldest,
    // so scroll-back avoids the network. The cursor is left unchanged on a hit so the next cache MISS
    // resumes the network exactly where it left off; the commit's id-dedupe covers any overlap.
    try {
      const oldest = messages.value[0]
      if (oldest) {
        const beforeKey = oldest.timestamp ? oldest.timestamp.getTime() * 1e6 : 0
        const cached = await runSyncEffectOr(
          chatEngineDb.loadOlderFromCache(sessionId.value, beforeKey, PAGE_SIZE),
          [],
          'messages.loadOlderFromCache',
        )
        if (cached.length > 0) {
          return {
            fetchedWithCursor: cursor,
            generation: commitGeneration,
            messages: toChatMessages(cached.map((c) => c.raw)),
            hasMore: hasMoreMessages.value,
            nextCursor: cursor,
            measuredMs: performance.now() - startedAt,
            armedAt: performance.now(),
          }
        }
      }
    } catch {
      // Cache failure must not break the network path.
    }
    const data = await api.getChatHistory(sessionId.value, PAGE_SIZE, cursor ?? undefined)
    const measuredMs = performance.now() - startedAt
    fetchEstimateMs = nextFetchEstimate(fetchEstimateMs, measuredMs)
    return {
      fetchedWithCursor: cursor,
      generation: commitGeneration,
      messages: toChatMessages(data.messages),
      hasMore: data.has_more,
      nextCursor: data.next_cursor,
      measuredMs,
      armedAt: performance.now(),
    }
  }

  /** Drop any armed / in-flight older page and invalidate late responses. Called on session switch
   * (the two `sessionId` watchers), on an initial `loadChatHistory()` refresh, and on unmount. */
  const resetOlderPrefetch = (cause: string) => {
    const hadWork = bufferedOlderPage !== null || prefetchPromise !== null
    commitGeneration++
    bufferedOlderPage = null
    prefetchPromise = null
    isCommittingOlder = false
    prefetchFailures = 0
    prefetchBackoffUntil = 0
    prefetchAutoChain = 0
    lastPrefetchSkip = null
    if (hadWork) {
      logger().info({
        ...prefetchLogCtx('load-more-prefetch-dropped', 'resetOlderPrefetch', { cause }),
      })
    }
  }

  /** ARM — fetch the next older page speculatively, into the buffer. Invisible by contract: no
   * `messages` mutation, no scrollTop write, no `lastAutoStickAt` bump, no `isLoadingMore`. */
  const armPrefetchOlder = (trigger: 'margin' | 'velocity' | 'refill') => {
    if (prefetchPromise) return
    if (!sessionId.value || isPendingSession.value) return
    const cursor = messageCursor.value
    const generation = commitGeneration
    prefetchPromise = (async () => {
      try {
        const page = await fetchOlderPage(cursor)
        if (generation !== commitGeneration || page.fetchedWithCursor !== messageCursor.value) {
          // The world moved while we were in flight (session switch, refresh,
          // or another path advanced the cursor). Committing this page would
          // prepend the wrong slice — drop it.
          logger().info({
            ...prefetchLogCtx('load-more-prefetch-dropped', 'armPrefetchOlder', {
              cause: generation !== commitGeneration ? 'generation-changed' : 'cursor-changed',
              trigger,
              cursor: cursor ?? 'null',
            }),
          })
          return
        }
        bufferedOlderPage = page
        prefetchFailures = 0
        prefetchBackoffUntil = 0
        logger().info({
          ...prefetchLogCtx('load-more-prefetch-armed', 'armPrefetchOlder', {
            trigger,
            cursor: cursor ?? 'null',
            buffered: page.messages.length,
            hasMore: page.hasMore,
            measuredMs: Math.round(page.measuredMs),
            estimatedFetchMs: Math.round(fetchEstimateMs),
          }),
        })
      } catch (err) {
        // A failed speculative fetch must never block the foreground path — the
        // user's own trigger will simply fetch normally. Back off so a dead
        // backend is not hammered once per scroll event.
        prefetchFailures++
        const backoffMs = Math.min(5000, 250 * 2 ** (prefetchFailures - 1))
        prefetchBackoffUntil = performance.now() + backoffMs
        logger().warn({
          ...prefetchLogCtx('load-more-prefetch-failed', 'armPrefetchOlder', {
            trigger,
            backoffMs,
            prefetchFailures,
            error: String(err),
          }),
        })
      } finally {
        prefetchPromise = null
      }
    })()
  }

  /** Claim the armed page for a commit — SYNCHRONOUSLY, before any `await`. */
  const claimBufferedOlderPage = (): BufferedOlderPage | null => {
    const page = bufferedOlderPage
    bufferedOlderPage = null
    if (!page) return null
    if (page.generation !== commitGeneration || page.fetchedWithCursor !== messageCursor.value) {
      logger().info({
        ...prefetchLogCtx('load-more-prefetch-dropped', 'claimBufferedOlderPage', {
          cause: page.generation !== commitGeneration ? 'generation-changed' : 'cursor-changed',
          bufferedAgeMs: Math.round(performance.now() - page.armedAt),
        }),
      })
      return null
    }
    return page
  }

  /** COMMIT — prepend a fetched older page through the preserve path. */
  const commitOlderPage = async (
    page: BufferedOlderPage,
    trigger: 'buffered' | 'foreground' | 'manual',
  ) => {
    const newMessages = page.messages
    // Suppress the contentShift re-stick for the duration of the preserve.
    suppressContentShiftStick = true

    // Snapshot the at-bottom state BEFORE the preserve begins.
    const wasAtBottom = isAtBottom.value

    // Preserve scroll position when prepending new (older) messages at the top.
    // beginPreserve must be called BEFORE mutating the array so the anchor
    // element's offsetTop is captured while it's still in the DOM.
    const newCount = newMessages.length
    const containerBefore = virtualScrollerRef.value?.containerRef
    const beforeCtx = buildScrollContext(containerBefore, {
      chatId: sessionId.value || props.chatId,
      messages: messages.value.length,
      isAtBottom: isAtBottom.value,
      virtualScrollerRef,
      wrapperRef: messagesWrapperRef,
    })
    logger().info({
      ...beforeCtx,
      caller: 'commitOlderPage',
      reason: 'load-more-preserve-start',
      extra: {
        prepending: newCount,
        trigger,
        bufferedAgeMs: Math.round(performance.now() - page.armedAt),
      },
    })
    virtualScrollerRef.value?.beginPreserve(newCount)
    const seenIds = new Set(messages.value.map((m) => m.id))
    const freshMessages = newMessages.filter((m) => !seenIds.has(m.id))
    messages.value = [...freshMessages.slice().reverse(), ...messages.value]
    messageCursor.value = page.nextCursor
    hasMoreMessages.value = page.hasMore
    await nextTick()
    // The VirtualScroller's internal scrollTop restoration may fire
    // a scroll event. Mark it programmatic so the next
    // handleVirtualScroll knows.
    logger().markProgrammatic()
    await virtualScrollerRef.value?.endPreserve()
    const containerAfter = virtualScrollerRef.value?.containerRef
    const afterCtx = buildScrollContext(containerAfter, {
      chatId: sessionId.value || props.chatId,
      messages: messages.value.length,
      isAtBottom: isAtBottom.value,
      virtualScrollerRef,
      wrapperRef: messagesWrapperRef,
    })
    // The interesting deltas: did scrollTop actually return to its
    // pre-preserve position? did scrollHeight grow by ~the new
    // messages? did the user-visible position jump (deltaAnchor ≠ 0)?
    const scrollTopDelta = afterCtx.scrollTop - beforeCtx.scrollTop
    const scrollHeightDelta = afterCtx.scrollHeight - beforeCtx.scrollHeight
    logger().info({
      ...afterCtx,
      caller: 'commitOlderPage',
      reason: 'load-more-preserve-end',
      extra: {
        prepending: newCount,
        trigger,
        scrollTopDelta,
        scrollHeightDelta,
        restoredOk: Math.abs(scrollTopDelta) < 2,
      },
    })

    // Re-arm the re-stick.
    lastObservedScrollHeight = virtualScrollerRef.value?.containerRef?.scrollHeight ?? 0
    suppressContentShiftStick = false

    if (wasAtBottom) {
      const c = virtualScrollerRef.value?.containerRef
      if (c) {
        logger().markProgrammatic()
        lastAutoStickAt.value = Date.now()
        // Delegated to the scroller's scrollToBottom (real-bottom
        // target — same rationale as the onContentShift stick).
        virtualScrollerRef.value?.scrollToBottom('auto')
        // Re-engage the stick explicitly: the user WAS at bottom before the prepend, and we just
        // moved them to the new bottom on their behalf.
        isAtBottom.value = true
        logger().info({
          ...afterCtx,
          caller: 'commitOlderPage',
          reason: 'post-preserve-stick',
          extra: { prepending: newCount, wasAtBottom },
        })
      }
    }

    // REFILL — keep exactly one page of lookahead so the NEXT scroll-back is
    // instant too. Bounded: a commit that leaves the viewport inside the band
    // (tall viewport / short page) would otherwise chain pages with no gesture.
    if (page.hasMore && !isLoading.value && !isPendingSession.value) {
      if (prefetchAutoChain < MAX_PREFETCH_AUTO_CHAIN) {
        prefetchAutoChain++
        armPrefetchOlder('refill')
      } else {
        logger().info({
          ...afterCtx,
          caller: 'commitOlderPage',
          reason: 'load-more-prefetch-skipped',
          extra: {
            skip: 'auto-chain-budget',
            prefetchAutoChain,
            maxAutoChain: MAX_PREFETCH_AUTO_CHAIN,
          },
        })
      }
    }
  }

  /** Evaluate the prefetch decision for the CURRENT scroll geometry and arm if it says so. */
  const evaluateOlderPrefetch = () => {
    if (!sessionId.value || isPendingSession.value) return
    const container = virtualScrollerRef.value?.containerRef
    if (!container) return
    const distanceFromTop = Math.max(0, container.scrollTop)
    const radius = armRadiusPx(container.clientHeight)
    const decision = decidePrefetchOlder({
      distanceFromTop,
      armRadiusPx: radius,
      hasMore: hasMoreMessages.value,
      isLoading: isLoading.value,
      isCommitting: isCommittingOlder,
      isPrefetching: prefetchPromise !== null,
      hasBufferedPage: bufferedOlderPage !== null,
      isPreservingScroll: virtualScrollerRef.value?.isPreservingScroll === true,
      sessionId: sessionId.value || null,
      backoffActive: performance.now() < prefetchBackoffUntil,
    })
    if (decision.arm) {
      lastPrefetchSkip = null
      armPrefetchOlder(decision.trigger === 'velocity' ? 'velocity' : 'margin')
      return
    }
    // Log a skip once per DISTINCT reason (a fling inside the radius fires many
    // scroll events; one line each would drown the log), and never log the
    // ordinary "still far from the top" case.
    const skip = decision.skip && decision.skip !== 'not-close-enough' ? decision.skip : null
    if (skip && skip !== lastPrefetchSkip) {
      logger().info({
        ...prefetchLogCtx('load-more-prefetch-skipped', 'evaluateOlderPrefetch', {
          skip,
          distanceFromTop,
          armRadiusPx: radius,
        }),
      })
    }
    lastPrefetchSkip = skip
  }

  /** The single entry point for "load older messages". Replaces the old `handleLoadMore` guard chain
   * and is the only path that commits a page, so the guards run exactly once per attempt: - the
   * auto-stick gate applies ONLY to `trigger === 'edge'` (the scroll trigger). */
  const maybeLoadOlder = async (trigger: 'edge' | 'manual') => {
    // The open must not spend a scroll-back request: while the initial load is
    // still placing the transcript the scroller can transiently report its edge,
    // before the bottom/restore scroll of the first page has landed.
    if (isInitialLoad && trigger === 'edge') return
    const container = virtualScrollerRef.value?.containerRef
    const ctx = buildScrollContext(container, {
      chatId: sessionId.value || props.chatId,
      messages: messages.value.length,
      isAtBottom: isAtBottom.value,
      virtualScrollerRef,
      wrapperRef: messagesWrapperRef,
    })

    // Each guard is its own `if` (not chained with `||`) so we can log exactly which one blocked. See
    // `helpers/autoStickGate.ts` for the gating math.
    const now = Date.now()
    const sinceLastAutoStickMs = lastAutoStickAt.value === 0 ? -1 : now - lastAutoStickAt.value
    if (trigger === 'edge' && isAutoStickActive(lastAutoStickAt.value, now, isAtBottom.value)) {
      logger().info({
        ...ctx,
        caller: 'maybeLoadOlder',
        reason: 'load-more-suppressed',
        extra: {
          guard: 'auto-stick-active',
          source: 'ChatView',
          sinceLastAutoStickMs,
          gateMs: AUTO_STICK_GATE_MS,
          isLLMProcessing: isLLMProcessing.value,
          isAtBottom: isAtBottom.value,
        },
      })
      return
    }
    if (!hasMoreMessages.value) {
      logger().info({
        ...ctx,
        caller: 'maybeLoadOlder',
        reason: 'load-more-suppressed',
        extra: { guard: 'no-more-messages', source: 'ChatView', trigger },
      })
      return
    }
    if (isLoadingMore.value) {
      logger().info({
        ...ctx,
        caller: 'maybeLoadOlder',
        reason: 'load-more-suppressed',
        extra: { guard: 'already-loading', source: 'ChatView', trigger },
      })
      return
    }
    if (isCommittingOlder) {
      logger().info({
        ...ctx,
        caller: 'maybeLoadOlder',
        reason: 'load-more-suppressed',
        extra: { guard: 'already-committing', source: 'ChatView', trigger },
      })
      return
    }
    if (messages.value.length === 0) {
      logger().info({
        ...ctx,
        caller: 'maybeLoadOlder',
        reason: 'load-more-suppressed',
        extra: { guard: 'no-messages', source: 'ChatView', trigger },
      })
      return
    }

    // Synchronous claim — the buffer slot is cleared and both in-flight flags are
    // set BEFORE any `await`, so a second caller (the positional commit racing the
    // scroller's 200 ms backstop) hits `already-loading`/`already-committing`.
    const buffered = claimBufferedOlderPage()
    const pending = prefetchPromise
    isLoadingMore.value = true
    isCommittingOlder = true

    // All guards passed — log the threshold reached and fetch.
    // The extra includes the LLM/scroll state so the log line
    // answers "was this a streaming-time loadMore?" in one glance.
    const effectiveThreshold = virtualScrollerRef.value?.effectiveLoadMoreThreshold ?? 200
    logger().info({
      ...ctx,
      caller: 'maybeLoadOlder',
      reason: 'load-more-threshold-reached',
      extra: {
        trigger,
        hasMore: hasMoreMessages.value,
        loadMoreThreshold: 200, // absolute floor, mirrors the prop on <VirtualScroller>
        loadMoreThresholdRatio: 0.5, // mirrors the prop on <VirtualScroller>
        effectiveLoadMoreThreshold: effectiveThreshold, // max(floor, containerHeight * ratio)
        isLLMProcessing: isLLMProcessing.value,
        isAtBottom: isAtBottom.value,
        fromBuffer: buffered !== null,
        estimatedFetchMs: Math.round(fetchEstimateMs),
      },
    })

    try {
      if (buffered) {
        await commitOlderPage(buffered, 'buffered')
        return
      }
      // No buffer: if an ARM is already in flight, reuse it instead of firing a
      // duplicate request (single-flight), then commit whatever it produced.
      if (pending) {
        await pending
        const claimed = claimBufferedOlderPage()
        if (claimed) {
          await commitOlderPage(claimed, 'buffered')
          return
        }
      }
      const page = await fetchOlderPage(messageCursor.value)
      if (page.generation !== commitGeneration) return
      await commitOlderPage(page, trigger === 'manual' ? 'manual' : 'foreground')
    } catch (err) {
      console.error('[ChatView] failed to load older messages:', err)
    } finally {
      isLoadingMore.value = false
      isCommittingOlder = false
    }
  }

  /**  * Apply the session metadata piggybacked on the messages endpoint (cwd, worktree, PR binding,
   * profile, token budgets, skills). Shared by the cached-mount delta path and the full-load path so
   * the two can never drift. */
  const applyDeltaExtra = (extra: {
    cwd?: string
    git_worktree_cwd?: string
    pr_url?: string
    pr_provider?: string
    selected_profile_model?: string
    max_total_tokens?: number
    max_capacity_total_tokens?: number
    skills?: typeof sessionSkills.value
  }) => {
    if (extra.cwd || extra.git_worktree_cwd !== undefined) {
      const prevCwd = effectiveCwd.value
      if (extra.cwd) sessionCwd.value = extra.cwd
      if (extra.git_worktree_cwd !== undefined) gitWorktreeCwd.value = extra.git_worktree_cwd
      noteCwdMutation(prevCwd)
    }
    if (extra.pr_url !== undefined) chatPrUrl.value = extra.pr_url ?? ''
    if (extra.pr_provider !== undefined) chatPrProvider.value = extra.pr_provider ?? ''
    if (extra.selected_profile_model !== undefined)
      selectedAgent.value =
        typeof extra.selected_profile_model === 'string' ? extra.selected_profile_model || null : null
    if (extra.max_total_tokens !== undefined) maxTotalTokens.value = extra.max_total_tokens
    if (extra.max_capacity_total_tokens !== undefined)
      maxCapacityTotalTokens.value = extra.max_capacity_total_tokens
    sessionSkills.value = extra.skills || []
  }

  /** One attempt at the initial load: cache-first paint, then the network page. Split out of
   * `loadChatHistory` so the retry loop can re-run the WHOLE attempt (cache-prime included) after a
   * failed network fetch. */
  const runHistoryLoadAttempt = async () => {
    // Cached mount: paint stored full-fidelity raws instantly (same mapper as the network path, so no
    // shape drift), restore the cursor from sync_state, then refresh just the tail with cursor+asc.
    // Miss/IDB failure falls through to the full-load path below unchanged.
    try {
      const sid = sessionId.value
      const cached = await runSyncEffectOr(
        chatEngineDb.primeFromCache(sid, PAGE_SIZE),
        [],
        'messages.primeFromCache',
      )
      if (cached.length > 0 && sessionId.value === sid) {
        const storedCursor = await runSyncEffectOr(
          chatEngineDb.getCursor(sid),
          null,
          'messages.getCursor',
        )
        isInitialLoad = true
        try {
          const liveMessagesAtPaint = currentLiveMessages()
          messages.value = mergeMessagesById(
            toChatMessages(cached.map((c) => c.raw))
              .slice()
              .reverse(),
            liveMessagesAtPaint,
          )
          messageCursor.value = storedCursor
          hasMoreMessages.value = true
        } finally {
          isInitialLoad = false
        }
        // The cache painted rows, so the empty state is already ruled out — but
        // the tail delta below has not answered yet, so `historyConfirmed`
        // waits for it. A cached mount is still a "not known yet" state.
        isLoading.value = false
        await nextTick()
        scrollToBottom(true, 'cached-mount')
        try {
          const delta = await runSyncEffect(
            chatEngineDb.loadDelta(sid, PAGE_SIZE, liveMessageIds),
            'messages.loadDelta',
          )
          if (delta && sessionId.value === sid) {
            applyDeltaExtra(delta.extra)
            if (delta.items.length > 0) {
              const fresh = toChatMessages(delta.items.map((i) => i.raw))
              const liveMessagesAtMerge = currentLiveMessages()
              messages.value = mergeMessagesById(
                mergeMessagesById(messages.value, fresh),
                liveMessagesAtMerge,
              )
            }
            messageCursor.value = delta.nextCursor
            hasMoreMessages.value = delta.hasMore
          }
        } catch {
          // Painted cache stands; the next mount retries the tail.
        }
        // Painted rows exist either way, so "this session is empty" is now ruled out — the empty
        // state may be shown again if the session is later reloaded. "Painted rows" has to mean rows
        // the transcript can actually DRAW.
        if (messageGroups.value.length > 0) {
          historyConfirmed.value = true
          setupCodeBlockCopyButtons()
          void rehydrateSubAgentProgress()
          return
        }
      }
    } catch {
      // Ignore — network path below is authoritative.
    }

    // `fetchChatHistoryEffect`, not `getChatHistory`: the latter answers a failed fetch with an empty
    // transcript, which is exactly the "this session has no messages" lie the empty state would then
    // render.
    const data = await Effect.runPromise(
      api.fetchChatHistoryEffect(
        sessionId.value,
        PAGE_SIZE,
        undefined,
        'desc',
        INITIAL_HISTORY_TIMEOUT_MS,
      ),
    )

    if (data.cwd || data.git_worktree_cwd !== undefined) {
      const prevCwd = effectiveCwd.value
      if (data.cwd) {
        sessionCwd.value = data.cwd
      }

      if (data.git_worktree_cwd !== undefined) {
        gitWorktreeCwd.value = data.git_worktree_cwd
      }
      noteCwdMutation(prevCwd)
    }

    // Attached-PR binding for the sidebar's PR-changes mode. Loaded
    // here (mount) and re-synced by refreshWorktreeBinding() so a
    // mid-chat attach/clear flips the panel without a reload.
    if (data.pr_url !== undefined) {
      chatPrUrl.value = data.pr_url ?? ''
    }
    if (data.pr_provider !== undefined) {
      chatPrProvider.value = data.pr_provider ?? ''
    }

    if (data.selected_profile_model !== undefined) {
      selectedAgent.value =
        typeof data.selected_profile_model === 'string' ? data.selected_profile_model || null : null
    }

    if (data.max_total_tokens !== undefined) {
      maxTotalTokens.value = data.max_total_tokens
    }
    if (data.max_capacity_total_tokens !== undefined) {
      maxCapacityTotalTokens.value = data.max_capacity_total_tokens
    }
    sessionSkills.value = data.skills || []

    const newMessages = toChatMessages(data.messages)

    // Initial load path. Set isInitialLoad BEFORE the messages assignment so the messages-length
    // watcher's sync callback sees the flag and skips its own scrollToBottom (which would yank the
    // user back to the bottom right after we restore a saved position).
    isInitialLoad = true
    try {
      const liveMessagesAtCommit = currentLiveMessages()
      messages.value = mergeMessagesById(newMessages.slice().reverse(), liveMessagesAtCommit)
      messageCursor.value = data.next_cursor
      hasMoreMessages.value = data.has_more
      // Write-through: persist full server rows so the next mount paints
      // from cache. Best-effort — IDB failure keeps in-memory behavior.
      try {
        const sid = sessionId.value
        const allRows = (data.messages ?? []).map((m) => toChatMessage(sid, m))
        const rows = allRows.filter((row) => !liveMessageIds.has(row.id))
        await runSyncVoid(chatEngineDb.putLocal(sid, rows), 'messages.putLocal')
        // Sync cursor must be the newest row, not the pagination cursor: the backend omits
        // next_cursor when has_more is false (wiping the cursor to null), and on a full page it
        // points at the oldest row (re-fetching the same page next mount).
        if (rows.length === allRows.length) {
          await runSyncVoid(
            chatEngineDb.setCursor(sid, newestCursor(allRows, data.next_cursor ?? null, null)),
            'messages.setCursor',
          )
        }
      } catch {
        // Ignore — cache is advisory on write.
      }

      const initialContainer = virtualScrollerRef.value?.containerRef
      const initialCtx = buildScrollContext(initialContainer, {
        chatId: sessionId.value || props.chatId,
        messages: messages.value.length,
        isAtBottom: isAtBottom.value,
        virtualScrollerRef,
        wrapperRef: messagesWrapperRef,
      })
      logger().info({
        ...initialCtx,
        caller: 'loadChatHistory',
        reason: 'scroll-to-bottom-forced',
        extra: { trigger: 'initial-load' },
      })
      await nextTick()
      // Wait one paint frame so the browser has actually laid out the VirtualScroller items (nextTick
      // alone only waits for Vue's DOM update, not for layout/paint).
      await new Promise<void>((r) => requestAnimationFrame(() => r()))

      // Try to restore the user's previous scroll position (set by useChatScrollRestore when they
      // last closed this task).
      if (chatScrollRestore.hasSavedPosition()) {
        await waitForScrollerMeasured()
      }
      const savedScrollTop = chatScrollRestore.restore()
      if (savedScrollTop !== null) {
        logger().markProgrammatic()
        virtualScrollerRef.value?.scrollToPosition(savedScrollTop, 'auto')
        logger().info({
          ...initialCtx,
          caller: 'loadChatHistory',
          reason: 'scroll-position-restored',
          extra: { savedScrollTop, trigger: 'initial-load' },
        })
      } else {
        scrollToBottom(true, 'initial-load')
      }

      setupCodeBlockCopyButtons()
      void rehydrateSubAgentProgress()
    } finally {
      isInitialLoad = false
    }
    // The server answered. Whether the answer was "0 messages" or "500", the
    // empty state is now allowed to consider rendering.
    historyConfirmed.value = true

    // NOTE — deliberately NO prefetch evaluation here.
  }

  /** The promise-shaped attempt above, as an `Effect`. */
  const runHistoryLoadAttemptEffect = (): Effect.Effect<void, ChatHistoryError> =>
    Effect.tryPromise({
      try: runHistoryLoadAttempt,
      catch: (cause) =>
        new ChatHistoryError({
          sessionId: sessionId.value,
          reason: cause instanceof Error ? cause.message : String(cause),
        }),
    })

  /** Initial load / refresh (the old `loadChatHistory(false)`). Wraps `runHistoryLoadAttempt` in the
   * retry schedule, then decides what a fully-failed load means. Two invariants this owns: 1. */
  const loadChatHistory = async () => {
    if (!sessionId.value || isPendingSession.value) return

    isLoading.value = true
    isRemoteLoadPending.value = true
    messageCursor.value = null
    // Invalidate anything armed for the previous view of this session.
    resetOlderPrefetch('refresh')
    error.value = null
    // "Not known yet" until an attempt completes.
    historyConfirmed.value = false

    // No try/catch: `ensuring` is the finally, `tapError` is the catch, and both
    // are typed against the error channel. See AGENTS.md, "Frontend — No
    // `try`/`catch` in the desktop app; use Effect-TS".
    await runEffectExit(
      Effect.ensuring(
        Effect.tapError(fetchInitialHistoryWithRetry(runHistoryLoadAttemptEffect), (err) =>
          Effect.sync(() => {
            console.error('Failed to load chat history:', err)
            error.value = 'Failed to load messages'
            messages.value = []
          }),
        ),
        Effect.sync(() => {
          isLoading.value = false
          // The network half is over — success, or every retry exhausted — so
          // the readgate may fall through to the empty / error state.
          isRemoteLoadPending.value = false
        }),
      ),
      'history.load',
    )
  }

  // ─── Scroll ──────────────────────────────────────────────────────────────────
  /** Resolve once the VirtualScroller's height model describes the CONTENT rather than the estimate,
   * or after `MEASURE_WAIT_TIMEOUT_MS` — whichever comes first. */
  const MEASURE_WAIT_TIMEOUT_MS = 500
  const MEASURE_POLL_MS = 16

  const waitForScrollerMeasured = async (): Promise<void> => {
    const start = Date.now()
    while (Date.now() - start < MEASURE_WAIT_TIMEOUT_MS) {
      if (virtualScrollerRef.value?.hasMeasuredItems) return
      await new Promise<void>((r) => setTimeout(r, MEASURE_POLL_MS))
    }
  }

  const scrollToBottom = async (force = false, trigger: string = 'unspecified') => {
    await nextTick()
    // Defense: during `beginPreserve`/`endPreserve`, the VirtualScroller is adjusting `scrollTop`
    // itself to keep the user's view stable while older messages are prepended. An external
    // `scrollToBottom` here fights that adjustment and produces visible jitter.
    if (virtualScrollerRef.value?.isPreservingScroll) return
    if (virtualScrollerRef.value) {
      if (force || isAtBottom.value) {
        const container = virtualScrollerRef.value.containerRef
        const ctx = buildScrollContext(container, {
          chatId: sessionId.value || props.chatId,
          messages: messages.value.length,
          isAtBottom: isAtBottom.value,
          virtualScrollerRef,
          wrapperRef: messagesWrapperRef,
        })
        // Mark before the assignment so the resulting scroll event reads
        // origin='programmatic' in handleVirtualScroll.
        logger().markProgrammatic()
        if (force) {
          logger().info({
            ...ctx,
            caller: 'scrollToBottom',
            reason: 'scroll-to-bottom-forced',
            extra: { trigger },
          })
        } else {
          logger().info({
            ...ctx,
            caller: 'scrollToBottom',
            reason: 'scroll-to-bottom-conditional',
            extra: { trigger, isAtBottom: isAtBottom.value },
          })
        }
        virtualScrollerRef.value.scrollToBottom('auto')
      }
    }
  }

  const getIsInitialLoad = () => isInitialLoad
  const getSuppressContentShiftStick = () => suppressContentShiftStick
  const getLastObservedScrollHeight = () => lastObservedScrollHeight
  const setLastObservedScrollHeight = (value: number) => {
    lastObservedScrollHeight = value
  }
  const hasBufferedOlderPage = () => bufferedOlderPage !== null
  const resetPrefetchAutoChain = () => {
    prefetchAutoChain = 0
  }

  return {
    applyDeltaExtra,
    claimLiveMessageSession,
    currentLiveMessages,
    evaluateOlderPrefetch,
    getIsInitialLoad,
    getLastObservedScrollHeight,
    getSuppressContentShiftStick,
    hasBufferedOlderPage,
    liveMessageIds,
    loadChatHistory,
    maybeLoadOlder,
    mergeMessagesById,
    rememberLiveMessage,
    resetOlderPrefetch,
    resetPrefetchAutoChain,
    scrollToBottom,
    setLastObservedScrollHeight,
    toChatMessages,
  }
}
