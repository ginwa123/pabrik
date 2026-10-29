import { ref, nextTick, computed, type ComputedRef, type Ref } from 'vue'
import * as api from '../../../api'
import {
  isCompactionMessage,
  useChatMessagePresentation,
  type Message,
  type MessageGroup,
} from './useChatMessagePresentation'
import { readGitStatusCache } from '../../../helpers/gitStatusCache'
import {
  applySnapshotRows,
  isPlaceholderSpawnRow,
  type SubAgentProgressMap,
} from '../../../helpers/subagentProgress'
import { useAgentErrorStore, type AgentErrorEntry } from '../../../stores/agentError'
import { useChatViewStore } from '../../../stores/chatView'
import { useNavigationStore } from '../../../stores/navigation'
import { useInjectOpenInCodeEditor } from '@/composables/useCodeEditor'
import type { VirtualScrollerExposed } from './chatViewTypes'
import type { ScrollLogger } from '@/helpers'

export interface ChatTranscriptViewDeps {
  props: { chatId: string }
  sessionId: Ref<string>
  messages: Ref<Message[]>
  isPendingSession: ComputedRef<boolean>
  isRemoteLoadPending: Ref<boolean>
  isLoading: Ref<boolean>
  isLoadingMore: Ref<boolean>
  error: Ref<string | null>
  hasMoreMessages: Ref<boolean>
  historyConfirmed: Ref<boolean>
  scrollerIsScrollable: Ref<boolean>
  scrollerContainerRef: ComputedRef<HTMLElement | null>
  virtualScrollerRef: Ref<VirtualScrollerExposed | null>
  sessionCwd: Ref<string>
  effectiveCwd: ComputedRef<string>
  isLastGroup: (index: number) => boolean
  nav: ReturnType<typeof useNavigationStore>
  onOpenWorkspaceSession: (sessionId: string) => void
  PAGE_SIZE: number
  logger: () => ScrollLogger
  loadChatHistory: () => void
  maybeLoadOlder: (trigger: 'edge' | 'manual') => void
}

/** The transcript's own view state: skills popup, tool expansion, sub-agent progress, agent
 * error, image preview, the git-status poller, and the presentation helpers plus the
 * `statesProps`/`rowProps` bags the template renders from. */
export function useChatTranscriptView(deps: ChatTranscriptViewDeps) {
  const {
    props,
    sessionId,
    messages,
    isPendingSession,
    isRemoteLoadPending,
    isLoading,
    isLoadingMore,
    error,
    hasMoreMessages,
    historyConfirmed,
    scrollerIsScrollable,
    scrollerContainerRef,
    virtualScrollerRef,
    sessionCwd,
    effectiveCwd,
    isLastGroup,
    nav,
    onOpenWorkspaceSession,
    PAGE_SIZE,
    loadChatHistory,
    maybeLoadOlder,
    logger,
  } = deps

  // Session skills state
  const sessionSkills = ref<api.SkillInfo[]>([])
  const showSkillsPopup = ref(false)

  // Track which tool items are expanded. 2026-08-23 auto-collapse fix — keys are STABLE per-message
  // ids, NOT positional `${groupIndex}-${idx}` pairs.
  const expandedToolIds = ref<Set<string>>(new Set())

  const subAgentProgressMap = ref<SubAgentProgressMap>({})

  const agentErrorStore = useAgentErrorStore()
  const chatView = useChatViewStore()
  // Per-session derived read. Reads from the store (keyed by sessionId) so the card survives ChatView
  // remounts caused by AppLayout's :key="activeChatId" or StandardTaskChatView's
  // :key="chat-${task.id}" on session/task switches.
  const agentError = computed<AgentErrorEntry | null>(() => agentErrorStore.errorFor(sessionId.value))

  // Image preview state
  const previewImageUrl = ref<string | null>(null)

  const openImagePreview = (url: string) => {
    // A blank URL must never open the lightbox — the overlay would then render
    // its own broken `<img>` on top of a full-screen backdrop.
    if (!url || url.trim().length === 0) return
    previewImageUrl.value = url
  }

  const closeImagePreview = () => {
    previewImageUrl.value = null
  }

  // Toggle expanded state for a tool item. Keyed by the message's stable
  // id (see expandedToolIds above) — never by position, which shifts on
  // every SSE-driven recompute of messageGroups.
  const toggleToolExpanded = (msgId: string) => {
    const newSet = new Set(expandedToolIds.value)
    if (newSet.has(msgId)) {
      newSet.delete(msgId)
    } else {
      newSet.add(msgId)
    }
    expandedToolIds.value = newSet
  }

  // Code-editor wiring for the fallback `<DiffView>` rendered for tools that don't have a dedicated
  // component (e.g. legacy tools). When the user clicks a line number in the fallback diff we forward
  // to the in-app editor — but only when we know the target file path.
  const fallbackOpenInEditor = useInjectOpenInCodeEditor()
  const handleFallbackJumpToLine = (line: number) => {
    // No-op: we don't have a target file path in the fallback context. The click affordance still
    // works (hover/cursor change), but won't open the editor. Hook retained for future enhancement
    // when we add a generic tool→path lookup.
    void fallbackOpenInEditor
    void line
  }

  // Git status state
  const gitStatus = ref<api.GitStatus | null>(null)
  let gitStatusSeq = 0
  let gitStatusPollInterval: ReturnType<typeof setInterval> | null = null
  // cwd the current `gitStatus` was fetched/painted for — gates the
  // cache-first paint so a 30s poll tick never repaints the localStorage
  // copy over a fresher in-memory value (only init / cwd switches do).
  let gitStatusCwd = ''

  const checkGitStatus = async () => {
    if (!effectiveCwd.value) {
      gitStatus.value = null
      gitStatusCwd = ''
      return
    }
    // Stale-response guard: the worktree binding can flip twice in quick succession (session cwd →
    // worktree A → worktree B). Without the seq check, the slower fetch for A resolves last and the
    // bottom chip shows A's branch while the sidebar already follows B.
    const seq = ++gitStatusSeq
    const cwd = effectiveCwd.value
    // Cache-first paint: on init or a cwd switch, synchronously show the last-known status from
    // localStorage so the chip has a branch to render while the remote fetch below revalidates it in
    // the background (stale-while-revalidate).
    if (gitStatusCwd !== cwd) {
      gitStatusCwd = cwd
      const cached = readGitStatusCache(cwd)
      if (cached) gitStatus.value = cached
    }
    try {
      const status = await api.getGitStatus(cwd)
      if (seq !== gitStatusSeq) return
      gitStatus.value = status
    } catch (err) {
      if (seq !== gitStatusSeq) return
      console.error('Failed to check git status:', err)
      gitStatus.value = null
    }
  }

  const startGitStatusPoll = () => {
    checkGitStatus()
    if (gitStatusPollInterval) clearInterval(gitStatusPollInterval)
    gitStatusPollInterval = setInterval(checkGitStatus, 30000)
  }

  const stopGitStatusPoll = () => {
    if (gitStatusPollInterval) {
      clearInterval(gitStatusPollInterval)
      gitStatusPollInterval = null
    }
  }

  const {
    groupKey,
    messageGroups,
    isInitializing,
    groupKeyForMessageId,
    userPills,
    compactChains,
    visibleReasoning,
    answeredMessages,
    toolCardsFor,
    standaloneCardsFor,
    renderMessageHtml,
    isBgUserMsg,
    bgShellData,
    isBgOnlyGroup,
    hasVisibleContent,
    hasBubbleContent,
  } = useChatMessagePresentation({
    messages,
    expandedToolIds,
    subAgentProgressMap,
    isPendingSession,
    sessionId,
    isRemoteLoadPending,
    mode: () => chatView.mode,
  })

  const statesProps = computed(() => ({
    isLoadingMore: isLoadingMore.value,
    isInitializing: isInitializing.value,
    isLoading: isLoading.value,
    error: error.value,
    historyConfirmed: historyConfirmed.value,
    messageGroups: messageGroups.value,
    hasMoreMessages: hasMoreMessages.value,
    scrollerIsScrollable: scrollerIsScrollable.value,
    pageSize: PAGE_SIZE,
    loadChatHistory,
    maybeLoadOlder,
  }))

  /** One prop bag per rendered row: the presentation helpers are stable functions, the mode and the
   * chain map are read here so the child re-renders with them. */
  const rowProps = (group: MessageGroup, groupIndex: number) => ({
    group,
    groupIndex,
    mode: chatView.mode,
    sessionId: sessionId.value,
    chatId: props.chatId,
    cwd: sessionCwd.value,
    groupKey,
    isLastGroup,
    isBgOnlyGroup,
    hasBubbleContent,
    isCompactionMessage,
    bgShellData,
    isBgUserMsg,
    openImagePreview,
    compactChains: compactChains.value,
    standaloneCardsFor,
    toolCardsFor,
    toggleToolExpanded,
    openPeek: nav.openPeek,
    handleFallbackJumpToLine,
    onOpenWorkspaceSession,
    visibleReasoning,
    answeredMessages,
    hasVisibleContent,
    renderMessageHtml,
  })

  // Last pill the user jumped to (highlight). Also driven by scroll (see
  // the realtime update at the end of handleVirtualScroll) so the rail
  // lights up while reading, not just after a click-jump.
  const activePillGroupIndex = ref<number | null>(null)

  // Must mirror the `:buffer` prop on the <VirtualScroller> below: the
  // scroller renders this many extra items on EACH side of the viewport,
  // so the active-pill anchor compensates by it (see estimateViewportEnd).
  const CHAT_SCROLL_BUFFER = 30

  const jumpToUserGroup = (groupIndex: number, key: string) => {
    // Resolve the index by stable groupKey at click time: SSE appends
    // between render and click can shift positional indices.
    const current = messageGroups.value.findIndex((g) => groupKey(g) === key)
    const target = current !== -1 ? current : groupIndex
    activePillGroupIndex.value = target
    // Mark programmatic BEFORE the write so handleVirtualScroll doesn't
    // misread the jump as a user scroll-up (same pattern as scrollToBottom).
    logger().markProgrammatic()
    virtualScrollerRef.value?.scrollToItem(target, 'smooth')
    // Flash-highlight the bubble so the eye finds it after the scroll.
    nextTick(() => {
      requestAnimationFrame(() => {
        const container = scrollerContainerRef.value
        if (!container) return
        const nodes = container.querySelectorAll('[data-group-key]')
        for (const node of nodes) {
          if (node.getAttribute('data-group-key') === key) {
            node.classList.remove('pill-jump-flash')
            // Force reflow so repeated jumps to the same pill re-trigger.
            void (node as HTMLElement).offsetWidth
            node.classList.add('pill-jump-flash')
            window.setTimeout(() => node.classList.remove('pill-jump-flash'), 1300)
            break
          }
        }
      })
    })
  }

  const rehydrateSubAgentProgress = async () => {
    const placeholders = messages.value.filter(isPlaceholderSpawnRow)
    if (placeholders.length === 0) return
    const seen = new Set<string>()
    for (const m of placeholders) {
      const toolCallId = m.tool_call_id as string
      if (seen.has(toolCallId)) continue
      seen.add(toolCallId)
      try {
        const snap = await api.getSubAgentProgress(toolCallId)
        if (snap.progress.length > 0) {
          subAgentProgressMap.value = applySnapshotRows(
            subAgentProgressMap.value,
            toolCallId,
            snap.progress,
          )
        }
      } catch (err) {
        console.warn(
          '[ChatView] subagent progress snapshot fetch failed (starting fallback kept):',
          err,
        )
      }
    }
  }

  const setGitStatusCwd = (value: string) => {
    gitStatusCwd = value
  }

  return {
    activePillGroupIndex,
    agentError,
    agentErrorStore,
    CHAT_SCROLL_BUFFER,
    chatView,
    checkGitStatus,
    closeImagePreview,
    gitStatus,
    groupKey,
    groupKeyForMessageId,
    isInitializing,
    jumpToUserGroup,
    messageGroups,
    previewImageUrl,
    rehydrateSubAgentProgress,
    rowProps,
    sessionSkills,
    setGitStatusCwd,
    showSkillsPopup,
    startGitStatusPoll,
    statesProps,
    stopGitStatusPoll,
    subAgentProgressMap,
    userPills,
  }
}
