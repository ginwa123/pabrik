import { nextTick, onMounted, onUnmounted, onUpdated, type ComputedRef, type Ref } from 'vue'
import * as api from '../../../api'
import {
  AT_BOTTOM_STABLE_TOLERANCE_PX,
  BOTTOM_THRESHOLD,
  TOP_THRESHOLD,
  buildScrollContext,
} from '@/helpers'
import { onHtmlFrameResize } from '../../../helpers/chatHtmlFrame'
import {
  fileToAttachment,
  isDocumentFile,
  styleCarriesFile,
  type FileAttachment,
} from '../../../helpers/fileAttachments'
import type { useWorkspacesStore } from '../../../stores/workspaces'
import { estimateViewportEnd, pickActivePillIndex } from '../../chat/activePill'
import type { UserPill } from '../../chat/UserPillRail.vue'
import type { DiffSelection } from '../chat_right_sidebar/parseUnifiedDiff'
import { useChatSse, type ChatSseDeps } from './useChatSse'
import type { VirtualScrollerExposed } from './chatViewTypes'
import type { Message, MessageGroup } from './useChatMessagePresentation'

export interface ChatSessionRuntimeDeps {
  CHAT_SCROLL_BUFFER: number
  PAGE_SIZE: number
  activePillGroupIndex: Ref<number | null>
  agentErrorStore: ChatSseDeps['agentErrorStore']
  applyDeltaExtra: ChatSseDeps['applyDeltaExtra']
  bumpStreamContentVersion: ChatSseDeps['bumpStreamContentVersion']
  centerDiff: Ref<DiffSelection | null>
  centerFiles: Ref<DiffSelection[]>
  checkGitStatus: () => void
  claimLiveMessageSession: ChatSseDeps['claimLiveMessageSession']
  closeOnOutsideClick: (event: MouseEvent) => void
  currentLiveMessages: ChatSseDeps['currentLiveMessages']
  currentPath: Ref<string | null>
  effectiveCwd: ComputedRef<string>
  effectiveProfileUrlStyle: ComputedRef<string | undefined>
  evaluateOlderPrefetch: () => void
  fileInputRef: Ref<{ focusInput?: () => void } | null>
  getIsInitialLoad: () => boolean
  getStreamContentVersion: () => number
  gitStatus: Ref<api.GitStatus | null>
  groupKeyForMessageId: ChatSseDeps['groupKeyForMessageId']
  hasBufferedOlderPage: () => boolean
  isAtBottom: Ref<boolean>
  isSendingAttachments: Ref<boolean>
  isStreaming: ChatSseDeps['isStreaming']
  lastAutoStickAt: Ref<number>
  liveMessageIds: ChatSseDeps['liveMessageIds']
  loadAgents: () => void
  loadChatHistory: ChatSseDeps['loadChatHistory']
  logger: ChatSseDeps['logger']
  maxTotalTokens: ChatSseDeps['maxTotalTokens']
  maybeLoadOlder: (trigger: 'edge' | 'manual') => Promise<void>
  maybeRefreshWorktreeBinding: ChatSseDeps['maybeRefreshWorktreeBinding']
  mergeMessagesById: ChatSseDeps['mergeMessagesById']
  messageGroups: ComputedRef<MessageGroup[]>
  messages: Ref<Message[]>
  messagesWrapperRef: Ref<HTMLElement | null>
  props: { chatId: string; cwd?: string }
  queuedMessages: ChatSseDeps['queuedMessages']
  refreshScrollLogger: () => void
  rememberLiveMessage: ChatSseDeps['rememberLiveMessage']
  resetOlderPrefetch: (cause: string) => void
  resetPrefetchAutoChain: () => void
  route: { query: { diff?: unknown } }
  scrollToBottom: ChatSseDeps['scrollToBottom']
  selectedAgent: Ref<string | null>
  sessionCwd: Ref<string>
  sessionId: Ref<string>
  sessionSkills: ChatSseDeps['sessionSkills']
  setGitStatusCwd: (value: string) => void
  setLastObservedScrollHeight: (value: number) => void
  setupCodeBlockCopyButtons: ChatSseDeps['setupCodeBlockCopyButtons']
  showCenterDiff: ComputedRef<boolean>
  startGitStatusPoll: () => void
  stopCenterSpy: () => void
  stopGitStatusPoll: () => void
  streamingContent: ChatSseDeps['streamingContent']
  subAgentProgressMap: ChatSseDeps['subAgentProgressMap']
  syncCenterSpy: () => void
  syncDiffParam: (path: string | null) => void
  teardownContentShiftRaf: () => void
  toChatMessages: ChatSseDeps['toChatMessages']
  userPills: ComputedRef<UserPill[]>
  virtualScrollerRef: Ref<VirtualScrollerExposed | null>
  workspacesStore: ReturnType<typeof useWorkspacesStore>
}

/** Owns the transcript runtime: scroll gestures, mount/unmount wiring, session change, auto-stick,
 * cwd side effects, send/stop. The `─── Send Message` header must stay BELOW `handleVirtualScroll`
 * in this file — `ChatView.lazyPrefetch.spec.ts` slices the scroll handler between the two. */
export function useChatSessionRuntime(deps: ChatSessionRuntimeDeps) {
  const {
    CHAT_SCROLL_BUFFER,
    PAGE_SIZE,
    activePillGroupIndex,
    agentErrorStore,
    applyDeltaExtra,
    bumpStreamContentVersion,
    centerDiff,
    centerFiles,
    checkGitStatus,
    claimLiveMessageSession,
    closeOnOutsideClick,
    currentLiveMessages,
    currentPath,
    effectiveCwd,
    effectiveProfileUrlStyle,
    evaluateOlderPrefetch,
    fileInputRef,
    getIsInitialLoad,
    getStreamContentVersion,
    gitStatus,
    groupKeyForMessageId,
    hasBufferedOlderPage,
    isAtBottom,
    isSendingAttachments,
    isStreaming,
    lastAutoStickAt,
    liveMessageIds,
    loadAgents,
    loadChatHistory,
    logger,
    maxTotalTokens,
    maybeLoadOlder,
    maybeRefreshWorktreeBinding,
    mergeMessagesById,
    messageGroups,
    messages,
    messagesWrapperRef,
    props,
    queuedMessages,
    refreshScrollLogger,
    rememberLiveMessage,
    resetOlderPrefetch,
    resetPrefetchAutoChain,
    route,
    scrollToBottom,
    selectedAgent,
    sessionCwd,
    sessionId,
    sessionSkills,
    setGitStatusCwd,
    setLastObservedScrollHeight,
    setupCodeBlockCopyButtons,
    showCenterDiff,
    startGitStatusPoll,
    stopCenterSpy,
    stopGitStatusPoll,
    streamingContent,
    subAgentProgressMap,
    syncCenterSpy,
    syncDiffParam,
    teardownContentShiftRaf,
    toChatMessages,
    userPills,
    virtualScrollerRef,
    workspacesStore,
  } = deps

  // ─── Follow the newest turn ────────────────────────────────────────────────── "Take me to the
  // newest turn", as an explicit act by the reader rather than an inference from where they happen to
  // be sitting.
  const followNewestTurn = (trigger: string) => {
    isAtBottom.value = true
    lastAutoStickAt.value = Date.now()
    logger().markProgrammatic()
    scrollToBottom(true, trigger)
  }

  // Triggered by VirtualScroller when the user scrolls within `loadMoreThreshold` of the top (because
  // `loadMoreAtTop` is true). Auto-paginates older messages.
  const handleLoadMore = () => {
    void maybeLoadOlder('edge')
  }

  // Triggered by VirtualScroller when one of ITS internal guards prevented `loadMore` from being
  // emitted — i.e. the user WAS within the load edge but the scroller still chose not to emit
  // (because `isPreservingScroll`, `!hasMore`, `!isScrollable`, or `items.length === 0`).
  const handleLoadMoreSuppressed = (guard: string) => {
    const container = virtualScrollerRef.value?.containerRef
    const ctx = buildScrollContext(container, {
      chatId: sessionId.value || props.chatId,
      messages: messages.value.length,
      isAtBottom: isAtBottom.value,
      virtualScrollerRef,
      wrapperRef: messagesWrapperRef,
    })
    logger().info({
      ...ctx,
      caller: 'handleLoadMoreSuppressed',
      reason: 'load-more-suppressed',
      extra: { guard, source: 'VirtualScroller' },
    })
  }

  // Track isAtBottom from the VirtualScroller's scroll event so we can decide whether to auto-scroll
  // on new messages and when to show the "scroll to bottom" button. `previousIsAtTop` is a plain
  // `let` (not a ref) because it only feeds the logger — nothing else needs to react to it.
  let previousIsAtTop = false
  // State for the additional handleVirtualScroll logs below. Like `previousIsAtTop`, these are pure
  // diagnostics — nothing else reads them. Using plain `let` (not ref) avoids any reactive work;
  // the values exist only to feed the logger.
  let previousScrollTop = -1
  let previousScrollHeight = -1
  let previousDirection: 'up' | 'down' | null = null

  const handleVirtualScroll = (
    scrollTop: number,
    direction: 'up' | 'down',
    target: HTMLElement,
    isProgrammatic = false,
  ) => {
    // Prefer the event target — it's the actual DOM element that dispatched the scroll event, so the
    // browser guarantees it exists for the lifetime of this handler. See the `scroll` emit JSDoc in
    // VirtualScroller.vue for the full rationale.
    const container = target ?? virtualScrollerRef.value?.containerRef
    if (!container) {
      // Tripwire — with the target in hand this branch should be unreachable. If it ever fires, the
      // VirtualScroller stopped passing the target through the emit (regression on the fix in
      // VirtualScroller.vue `onScroll`).
      console.warn('[scroll] handleVirtualScroll: no container (target and ref chain both null)', {
        reportedScrollTop: scrollTop,
        reportedDirection: direction,
      })
      return
    }

    // The container is the source of truth for geometry — the `scrollTop` parameter is the
    // VirtualScroller's reported value and may lag by a frame. We log the param for cross-validation
    // but use the container's value everywhere else.
    const { scrollHeight, clientHeight } = container
    const actualScrollTop = container.scrollTop
    const scrollTopMatches = Math.abs(scrollTop - actualScrollTop) < 1
    // ── "The bottom" is whatever scrollToBottom is about to target ────────── NOT `scrollHeight -
    // clientHeight`.
    const settled = virtualScrollerRef.value?.settledBottom
    const liveEdge = virtualScrollerRef.value?.bottomScrollTop?.() ?? scrollHeight - clientHeight
    // The anchor is the bottom the reader was LAST parked at, so it is the number the reader's
    // position is actually referenced to.
    const bottomEdge = typeof settled === 'number' && Number.isFinite(settled) ? settled : liveEdge
    const distanceFromBottom = Math.max(0, bottomEdge - actualScrollTop)
    const distanceFromTop = Math.max(0, actualScrollTop)
    // Widened only for the stable-anchor read; a live read keeps the tight
    // threshold so a genuine scroll-up is still caught immediately.
    const atBottomTolerance =
      typeof settled === 'number' && Number.isFinite(settled)
        ? AT_BOTTOM_STABLE_TOLERANCE_PX
        : BOTTOM_THRESHOLD
    const newIsAtBottom = distanceFromBottom < atBottomTolerance
    const newIsAtTop = distanceFromTop < TOP_THRESHOLD
    const previousIsAtBottom = isAtBottom.value
    // Deltas: how much scrollTop moved since the last event, and how much scrollHeight grew (or
    // shrank — e.g. an image unmounted). Both are 0 on the first event. The `>= 0` guard on the
    // previous-sentinel -1 is what makes the first call a no-op for delta-based logs.
    const deltaTop = previousScrollTop >= 0 ? actualScrollTop - previousScrollTop : 0
    const deltaHeight = previousScrollHeight >= 0 ? scrollHeight - previousScrollHeight : 0
    const directionChanged = previousDirection !== null && previousDirection !== direction
    const contentGrew = deltaHeight > 0
    // "Lazy-load zone" is the VirtualScroller's `loadMoreThreshold` (200px) — wider than the 10px
    // `reached-top` log. A user entering the zone hasn't reached the top yet, but lazy load is about
    // to consider firing.
    const isInLazyLoadZone = distanceFromTop < 200 && !newIsAtTop
    const isFirstScroll = previousScrollTop === -1
    const ctx = buildScrollContext(container, {
      chatId: sessionId.value || props.chatId,
      messages: messages.value.length,
      isAtBottom: newIsAtBottom,
      virtualScrollerRef,
      wrapperRef: messagesWrapperRef,
    })
    // Per-frame sample: throttled to ~5 Hz in the logger, with a
    // trailing-edge flush so the final position is never lost. In dev
    // you'll see ~5 lines/sec while scrolling. In production it's silent.
    logger().debug({ ...ctx, caller: 'handleVirtualScroll' })
    // ── First-scroll info ─────────────────────────────────────────────── Captures the chat's
    // initial state on the very first scroll event. Without this, "delta=0" lines for the first few
    // events look like a bug in the delta math.
    if (isFirstScroll) {
      logger().info({
        ...ctx,
        caller: 'handleVirtualScroll',
        reason: 'first-scroll',
        extra: {
          reportedScrollTop: scrollTop,
          reportedDirection: direction,
          actualScrollTop,
          scrollTopMatches,
          distanceFromTop,
          distanceFromBottom,
        },
      })
    }
    // ── Direction-change info ─────────────────────────────────────────── The user reversed scroll
    // direction (e.g. was scrolling up to read history, then back down).
    if (directionChanged) {
      logger().info({
        ...ctx,
        caller: 'handleVirtualScroll',
        reason: 'direction-change',
        extra: {
          previousDirection,
          direction,
          deltaTop,
          distanceFromTop,
          distanceFromBottom,
        },
      })
    }
    // ── Content-resized info ──────────────────────────────────────────── `scrollHeight` changed
    // between two scroll events.
    if (contentGrew) {
      logger().info({
        ...ctx,
        caller: 'handleVirtualScroll',
        reason: 'content-resized',
        extra: {
          deltaHeight,
          previousScrollHeight,
          scrollHeight,
          direction,
          distanceFromTop,
          distanceFromBottom,
        },
      })
    }
    // ── Lazy-load-zone info ───────────────────────────────────────────── The user is within
    // `loadMoreThreshold` (200px) of the top but hasn't reached the 10px `reached-top` threshold yet.
    // The VirtualScroller's onScroll debounce is probably about to fire `loadMore`.
    if (isInLazyLoadZone) {
      logger().info({
        ...ctx,
        caller: 'handleVirtualScroll',
        reason: 'lazy-load-zone',
        extra: {
          distanceFromTop,
          threshold: 200,
          direction,
          deltaTop,
        },
      })
    }
    // ── Older-history prefetch ─────────────────────────────────────────── USER scroll events only: a
    // programmatic write (anchor compensation, `endPreserve` restore) is not a gesture, and neither is
    // the initial load — a late unmarked scroll event there would arm while the transcript is placed.
    if (!isProgrammatic && !getIsInitialLoad()) {
      // A real upward gesture is fresh intent to read history — reset the
      // refill auto-chain budget so the next commits may chain again.
      if (deltaTop < 0) resetPrefetchAutoChain()
      // ARM as early as the geometry allows (fetch into the buffer, invisibly)…
      evaluateOlderPrefetch()
      // …and COMMIT the moment the user is inside the scroller's own load-more band, instead of
      // waiting out the 200 ms `@load-more` backstop. `maybeLoadOlder` re-runs every guard and claims
      // the buffer synchronously, so this cannot double-commit with the backstop.
      const band = virtualScrollerRef.value?.effectiveLoadMoreThreshold ?? 200
      if (hasBufferedOlderPage() && distanceFromTop < band) void maybeLoadOlder('edge')
    }

    // ── State transitions are loud ───────────────────────────────────── This is the most useful
    // line in the whole logger.
    if (newIsAtBottom !== previousIsAtBottom) {
      logger().info({
        ...ctx,
        caller: 'handleVirtualScroll',
        reason: newIsAtBottom ? 'reached-bottom' : 'left-bottom',
        extra: {
          previousIsAtBottom,
          distanceFromBottom,
          threshold: BOTTOM_THRESHOLD,
          direction,
          deltaTop,
        },
      })
    }
    // ── Top edge transitions ───────────────────────────────────────────── Mirrors the bottom-edge
    // logging above.
    if (newIsAtTop !== previousIsAtTop) {
      logger().info({
        ...ctx,
        caller: 'handleVirtualScroll',
        reason: newIsAtTop ? 'reached-top' : 'left-top',
        extra: {
          previousIsAtTop,
          distanceFromTop,
          threshold: TOP_THRESHOLD,
          direction,
          deltaTop,
        },
      })
      previousIsAtTop = newIsAtTop
    }
    // Tight 10px threshold: a chat message is typically 50-100px tall, so reading the last message
    // puts you well outside this window.
    const userScrolledUp = !isProgrammatic && deltaTop < 0
    const retainedThroughGrowth =
      previousIsAtBottom && contentGrew && !userScrolledUp && distanceFromBottom < 100
    const nextIsAtBottom = newIsAtBottom || retainedThroughGrowth
    if (contentGrew || retainedThroughGrowth || newIsAtBottom !== nextIsAtBottom) {
      logger().info({
        ...ctx,
        caller: 'handleVirtualScroll',
        reason: 'isAtBottom-decision',
        extra: {
          newIsAtBottom,
          previousIsAtBottom,
          contentGrew,
          deltaHeight,
          deltaTop,
          isProgrammatic,
          userScrolledUp,
          retainedThroughGrowth,
          nextIsAtBottom,
          distanceFromBottom,
          distanceFromTop,
          scrollHeight,
          actualScrollTop,
        },
      })
    }
    isAtBottom.value = nextIsAtBottom
    // ── Realtime pill highlight ─────────────────────────────────────── Light the rail pill for the
    // latest user turn at/above the viewport BOTTOM as the user scrolls (previously the pill only lit
    // on click-jump, so scrolling never activated any pill.
    const range = virtualScrollerRef.value?.effectiveRange
    if (range) {
      const visEnd = estimateViewportEnd(
        range.start,
        range.end,
        messageGroups.value.length,
        CHAT_SCROLL_BUFFER,
      )
      activePillGroupIndex.value = pickActivePillIndex(userPills.value, visEnd)
    }
    // Persist the current state for the next call's deltas. Done
    // AFTER the logs so the `first-scroll` log captures the raw
    // initial state (with -1 sentinels making the deltas explicit).
    previousScrollTop = actualScrollTop
    previousScrollHeight = scrollHeight
    previousDirection = direction
  }

  const { connectSse, disconnectSse, updateStreamingMessage } = useChatSse({
    sessionId,
    messages,
    queuedMessages,
    isStreaming,
    isAtBottom,
    lastAutoStickAt,
    maxTotalTokens,
    sessionSkills,
    subAgentProgressMap,
    virtualScrollerRef,
    agentErrorStore,
    toChatMessages,
    mergeMessagesById,
    rememberLiveMessage,
    currentLiveMessages,
    applyDeltaExtra,
    loadChatHistory,
    scrollToBottom,
    followNewestTurn,
    maybeRefreshWorktreeBinding,
    setupCodeBlockCopyButtons,
    claimLiveMessageSession,
    bumpStreamContentVersion,
    logger,
    PAGE_SIZE,
    streamingContent,
    groupKeyForMessageId,
    liveMessageIds,
  })

  // ─── Init ──────────────────────────────────────────────────────────────────────
  onMounted(async () => {
    sessionId.value = props.chatId.replace(/^chat-/, '')
    // Replaces the old sessionId watchers (agent load + scroll-logger
    // refresh): the id is fixed for the component lifetime.
    void onSessionChanged(sessionId.value)

    if (props.cwd) {
      sessionCwd.value = props.cwd
    }

    // Refresh lands on chat, never auto-opens the diff: a reload keeps the ?diff= the scroll-spy
    // wrote while the viewer was open, and the panel no longer restores from it — strip it here so
    // the URL stays truthful (Back does the same on explicit exit).
    if (typeof route.query.diff === 'string' && !showCenterDiff.value) syncDiffParam(null)

    if (sessionId.value) {
      // Seed the re-stick baseline BEFORE loadChatHistory so we catch the very first
      // measurement-driven contentShift. The VirtualScroller's child component mounts before us
      // (child before parent in Vue 3), so its containerRef is already populated.
      setLastObservedScrollHeight(virtualScrollerRef.value?.containerRef?.scrollHeight ?? 0)

      // Subscribe before the history request. A tool can finish while the initial REST load is in
      // flight; waiting until afterward misses that event permanently because the placeholder's
      // creation-time cursor does not change when its result is updated in place.
      try {
        connectSse()
        startGitStatusPoll()
      } catch (err) {
        console.warn('[ChatView] SSE init failed (likely torn down by test cleanup):', err)
      }

      await loadChatHistory()
      const snapshotStartVersion = getStreamContentVersion()
      try {
        const snap = await api.getStreamSnapshot(sessionId.value)
        if (
          snap.active &&
          snap.content &&
          getStreamContentVersion() === snapshotStartVersion &&
          streamingContent.value.length === 0
        ) {
          streamingContent.value = snap.content
          updateStreamingMessage()
        }
      } catch (err) {
        console.warn('[ChatView] stream snapshot fetch failed (resume skipped):', err)
      }

      try {
        const result = await api.getQueuedMessages(sessionId.value)
        queuedMessages.value = result.messages
      } catch (err) {
        console.error('Failed to get queued messages:', err)
      }
      // Session switch remounts this view — land the cursor in the message box so the user types
      // immediately (no second click). Best-effort: focus must never reject the mount (e.g.
      // peek-embed hides the input, so fileInputRef stays null).
      try {
        await nextTick()
        fileInputRef.value?.focusInput?.()
      } catch {
        // ignore — input focus is a convenience, not load-critical
      }
    }
  })

  onUnmounted(() => {
    teardownContentShiftRaf()
    disconnectSse()
    stopGitStatusPoll()
    document.removeEventListener('click', closeOnOutsideClick)
    window.removeEventListener('message', onHtmlFrameResize)
    stopCenterSpy()
    // Drop any armed older page and invalidate in-flight arms — the
    // commitGeneration bump makes a late response inert.
    resetOlderPrefetch('unmount')
  })

  // Load available agents (called once on mount)
  loadAgents()
  document.addEventListener('click', closeOnOutsideClick)
  // `<html>` blocks auto-size themselves via postMessage (see onHtmlFrameResize above). Registered
  // here — paired with the removeEventListener in onUnmounted — for the same lifetime as the other
  // window-level listener the component owns.
  window.addEventListener('message', onHtmlFrameResize)

  // Session-change entry point (replaces the two old sessionId watchers). The component is keyed per
  // chat, so the id is fixed for the component lifetime — this runs once from the onMounted callback above.
  const onSessionChanged = async (newId: string) => {
    refreshScrollLogger()
    // Any page armed for the previous session is invalid — drop it before
    // the new session's history loads.
    resetOlderPrefetch('session-change')
    if (!newId) {
      selectedAgent.value = null
      return
    }
    try {
      const session = await api.getSession(newId)
      const raw = session?.selectedAgent ?? null
      selectedAgent.value = typeof raw === 'string' ? raw : null
    } catch (err) {
      console.error('Failed to load session agent:', err)
      selectedAgent.value = null
    }
  }

  // Auto-stick on new messages (replaces the old messages.length watcher). `onUpdated` with a
  // prev-length guard fires for every append path (user sends, SSE chunks, tool results) exactly like
  // the watcher did, and the isAtBottom gates keep scrolled-up readers undisturbed.
  let prevMessagesLength = messages.value.length
  onUpdated(() => {
    if (messages.value.length === prevMessagesLength) return
    prevMessagesLength = messages.value.length
    {
      if (getIsInitialLoad()) return // initial-load branch handled scroll explicitly
      if (!isAtBottom.value) return // don't disturb scrolled-up readers
      logger().markProgrammatic()
      // Any push to `messages` triggers an auto-stick (scrollToBottom below). Mark the timestamp
      // synchronously so the loadMore gate sees the stick as active during the same render frame the
      // message landed in.
      lastAutoStickAt.value = Date.now()
      nextTick(() => {
        // Recompute the height model BEFORE the auto-stick (append-gap fix): a new item's real height
        // is unknown until it renders; the sizer's estimate may overshoot (phantom gap) or undershoot
        // (stick lands short).
        if (isAtBottom.value) virtualScrollerRef.value?.remeasure()
        scrollToBottom(false, 'messages-length')
      })
    }
  })

  // React to an effective-cwd change (replaces the old effectiveCwd
  // watcher). A changed cwd invalidates the shown diff (e.g. worktree
  // bound or cleared mid-review).
  const onEffectiveCwdChanged = (newCwd: string) => {
    // Stop the spy synchronously before clearing so the observer can't
    // fire during teardown and write a stale ?diff= racing the
    // chat-switch navigation.
    stopCenterSpy()
    centerDiff.value = null
    centerFiles.value = []
    syncCenterSpy()
    currentPath.value = null
    if (newCwd) {
      checkGitStatus()
    } else {
      gitStatus.value = null
      // Reset the paint gate too — returning to the same cwd later
      // must re-read the cache instead of waiting out the fetch.
      setGitStatusCwd('')
    }
  }

  // Call after any assignment to sessionCwd / gitWorktreeCwd; runs the
  // side effects only when the effective cwd actually changed (the old
  // watcher only fired on change too).
  const noteCwdMutation = (prevCwd: string) => {
    if (effectiveCwd.value !== prevCwd) onEffectiveCwdChanged(effectiveCwd.value)
  }

  // ─── Send Message ─────────────────────────────────────────────────────────────
  const handleFileInputSubmit = async (userMessage: string, files?: File[]) => {
    await nextTick()
    followNewestTurn('send-message')

    const currentSessionId = sessionId.value

    // Converting attachments (especially video, up to 25 MB) to base64 blocks the send for seconds
    // with no feedback. Flip the Send button into its loading state for the whole convert + POST
    // window so the user waits instead of double-clicking Send.
    isSendingAttachments.value = true
    let imageUrls: string[] = []
    let fileAttachments: FileAttachment[] = []
    try {
      if (files && files.length > 0) {
        const fileToBase64 = (file: File): Promise<string> => {
          return new Promise((resolve, reject) => {
            const reader = new FileReader()
            reader.onload = () => resolve(reader.result as string)
            reader.onerror = reject
            reader.readAsDataURL(file)
          })
        }
        const mediaFiles = files.filter((f) => !isDocumentFile(f))
        const documentFiles = files.filter((f) => isDocumentFile(f))
        // Only the Responses API reads a rich binary document; the other wire
        // styles take a PDF. Refuse the turn rather than drop the file silently.
        const style = effectiveProfileUrlStyle.value
        const unreadable = documentFiles.filter((f) => !styleCarriesFile(style, f))
        if (unreadable.length > 0) {
          messages.value.push({
            id: `error-${Date.now()}`,
            role: 'assistant',
            content: `This model cannot read ${unreadable.map((f) => f.name).join(', ')}. Only the OpenAI Responses API reads a Word or Excel document.`,
            timestamp: new Date(),
          })
          isSendingAttachments.value = false
          return
        }
        imageUrls = await Promise.all(mediaFiles.map((f) => fileToBase64(f)))
        fileAttachments = await Promise.all(documentFiles.map((f) => fileToAttachment(f)))
      }
    } catch (err) {
      console.error('Failed to convert attachments:', err)
      isSendingAttachments.value = false
      messages.value.push({
        id: `error-${Date.now()}`,
        role: 'assistant',
        content: 'Sorry, I could not read the attached files. Please try again.',
        timestamp: new Date(),
      })
      return
    }

    // 2026-08-23 auto-collapse fix — NO optimistic local push. Previously the user's own message was
    // pushed to `messages` with a synthetic `optimistic-user-*` id, then replaced when the backend's
    // queue-drain re-emitted it via SSE `full`.
    try {
      await api.sendChatMessage(
        currentSessionId,
        userMessage,
        sessionCwd.value,
        imageUrls,
        selectedAgent.value ?? undefined,
        '',
        [],
        workspacesStore.activeWorkspace?.id,
        fileAttachments,
      )
    } catch (err) {
      console.error('Failed to send message:', err)
      // No local bubble to roll back — just surface an inline error so
      // the user knows the send failed. The server log has the truth.
      messages.value.push({
        id: `error-${Date.now()}`,
        role: 'assistant',
        content: 'Sorry, I encountered an error sending your message. Please try again.',
        timestamp: new Date(),
      })
    } finally {
      isSendingAttachments.value = false
      // The first pin aimed at the bottom of the transcript as it stood BEFORE this turn — there is
      // no optimistic push, so the turn is still in flight at this point and the bottom moves when it
      // renders.
      followNewestTurn('send-message-settled')
    }
  }

  // ─── Stop session ────────────────────────────────────────────────────────── The FileInput
  // component renders a Stop button (visible only when `isLLMProcessing === true`) that emits
  // `stop-session`.
  const handleStopSession = async () => {
    if (!sessionId.value) return
    try {
      await api.stopSession(sessionId.value)
    } catch (err) {
      console.error('Failed to stop session:', err)
    }
  }

  return {
    handleFileInputSubmit,
    handleLoadMore,
    handleLoadMoreSuppressed,
    handleStopSession,
    handleVirtualScroll,
    noteCwdMutation,
  }
}
