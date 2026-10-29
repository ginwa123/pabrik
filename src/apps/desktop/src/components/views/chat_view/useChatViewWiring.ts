import { computed, ref, type ComputedRef, type Ref } from 'vue'
import { resolveWorkspaceId } from '../../../helpers/workspaceScope'
import { chatViewModeFrom } from '../../../stores/chatView'
import { useChatComposerAgents } from './useChatComposerAgents'
import { useChatContentShift } from './useChatContentShift'
import { useChatDiffView } from './useChatDiffView'
import { useChatPagination } from './useChatPagination'
import { useChatSessionRuntime } from './useChatSessionRuntime'
import { useChatTranscriptView } from './useChatTranscriptView'
import { useChatViewSession } from './useChatViewSession'
import { useChatWorktree } from './useChatWorktree'
import type { useChatScrollRestore } from '../../../composables/useChatScrollRestore'
import type { DiffSelection } from '../chat_right_sidebar/parseUnifiedDiff'
import type { Message } from './useChatMessagePresentation'
import type { VirtualScrollerExposed } from './chatViewTypes'

export interface ChatViewWiringProps {
  chatId: string
  chatName: string
  type?: 'chat' | 'task'
  cwd?: string
  showHeader?: boolean
  embedded?: boolean
  hideInput?: boolean
}

export interface ChatViewWiringDeps {
  props: ChatViewWiringProps
  sessionId: Ref<string>
  messages: Ref<Message[]>
  centerDiff: Ref<DiffSelection | null>
  centerFiles: Ref<DiffSelection[]>
  currentPath: Ref<string | null>
  centerDiffScrollRef: Ref<HTMLElement | null>
  showCenterDiff: ComputedRef<boolean>
  historyConfirmed: Ref<boolean>
  virtualScrollerRef: Ref<VirtualScrollerExposed | null>
  scrollerContainerRef: ComputedRef<HTMLElement | null>
  messagesWrapperRef: Ref<HTMLElement | null>
  fileInputRef: Ref<{ focusInput?: () => void } | null>
  chatScrollRestore: ReturnType<typeof useChatScrollRestore>
  setupCodeBlockCopyButtons: () => void
  maybeRefreshWorktreeBinding: (role: string, toolName?: string) => void
  chatSidebarRef: Ref<{ reloadDiff: () => void } | null>
}

export function useChatViewWiring(deps: ChatViewWiringDeps) {
  const {
    props,
    sessionId,
    messages,
    centerDiff,
    centerFiles,
    currentPath,
    centerDiffScrollRef,
    showCenterDiff,
    historyConfirmed,
    virtualScrollerRef,
    scrollerContainerRef,
    messagesWrapperRef,
    fileInputRef,
    chatScrollRestore,
    setupCodeBlockCopyButtons,
    maybeRefreshWorktreeBinding,
    chatSidebarRef,
  } = deps

  const session = useChatViewSession({ chatId: props.chatId, sessionId })
  const {
    PAGE_SIZE,
    bumpStreamContentVersion,
    chatPrProvider,
    chatPrUrl,
    getStreamContentVersion,
    isLLMProcessing,
    isStreaming,
    logger,
    messageCursor,
    nav,
    onOpenWorkspaceSession,
    queuedMessages,
    refreshScrollLogger,
    route,
    router,
    streamingContent,
    workspacesStore,
  } = session

  // True for the newest transcript group only. Pads that ONE row so the final message scrolls clear
  // of the floating composer.
  const isLastGroup = (index: number) => index === messageGroups.value.length - 1

  // Timestamp (ms since epoch) of the most recent auto-stick assignment. See
  // `helpers/autoStickGate.ts` for the gating math.
  const lastAutoStickAt = ref(0)

  // State
  const isLoading = ref(false)
  const isSendingAttachments = ref(false)
  const isLoadingMore = ref(false)
  const error = ref<string | null>(null)
  // True while the REMOTE half of the transcript load is still outstanding. The load has two halves:
  // the cache prime (IndexedDB, fast) and the network page/delta (slow — bound by
  // `INITIAL_HISTORY_TIMEOUT_MS`, currently 45 s, plus the retry schedule).
  const isRemoteLoadPending = ref(false)
  const hasMoreMessages = ref(true)
  const isAtBottom = ref(true)

  // File previews render inline inside the chat bubble (see PresentFiles.vue +
  // PreviewContentRenderer.vue). There is no side panel — wide HTML content offers an "Open in new
  // tab" action instead.
  const scrollerIsScrollable = ref(false)
  const sessionCwd = ref('')
  // Bound git worktree path (empty string when no worktree is bound).
  // Updated by loadChatHistory() from the API response and by the
  // sessions SSE stream when the LLM calls set_git_worktree.
  const gitWorktreeCwd = ref('')
  // The cwd we run git status against. Prefers the worktree when set
  // (so the branch display reflects the worktree's branch, not the
  // session's original cwd). Falls back to the session's original cwd.
  const effectiveCwd = computed(() => gitWorktreeCwd.value || sessionCwd.value)
  // Branch for the right sidebar.
  const sidebarBranch = computed(() =>
    gitStatus.value ? gitStatus.value.branch || 'detached' : undefined,
  )
  const maxTotalTokens = ref(0)
  const maxCapacityTotalTokens = ref(200000)

  // Check if session is pending (needs creation on first message)
  const isPendingSession = computed(() => props.chatId.startsWith('pending-'))

  const diffView = useChatDiffView({
    router,
    route,
    sessionId,
    chatSidebarRef,
    centerDiff,
    centerFiles,
    currentPath,
    centerDiffScrollRef,
    showCenterDiff,
  })
  const { stopCenterSpy, syncCenterSpy, syncDiffParam } = diffView

  const agents = useChatComposerAgents({
    sessionId,
    workspaceId: () =>
      resolveWorkspaceId(route?.params?.workspaceId, workspacesStore.activeWorkspace?.id),
    applyChatViewMode: (config) => chatView.setMode(chatViewModeFrom(config)),
  })
  const { selectedAgent, loadAgents, effectiveProfileUrlStyle, closeOnOutsideClick } = agents

  const worktree = useChatWorktree({
    sessionId,
    sessionCwd,
    gitWorktreeCwd,
    selectedAgent,
    workspacesStore,
    checkGitStatus: () => checkGitStatus(),
  })

  const transcript = useChatTranscriptView({
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
    loadChatHistory: () => loadChatHistory(),
    maybeLoadOlder: (trigger) => maybeLoadOlder(trigger),
    logger,
  })
  const {
    activePillGroupIndex,
    agentErrorStore,
    CHAT_SCROLL_BUFFER,
    chatView,
    checkGitStatus,
    gitStatus,
    groupKeyForMessageId,
    messageGroups,
    rehydrateSubAgentProgress,
    sessionSkills,
    setGitStatusCwd,
    startGitStatusPoll,
    stopGitStatusPoll,
    subAgentProgressMap,
    userPills,
  } = transcript

  const pagination = useChatPagination({
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
    noteCwdMutation: (prevCwd: string) => noteCwdMutation(prevCwd),
    rehydrateSubAgentProgress,
    setupCodeBlockCopyButtons,
    PAGE_SIZE,
  })
  const {
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
  } = pagination

  const { onContentShift, teardownContentShiftRaf } = useChatContentShift({
    virtualScrollerRef,
    messagesWrapperRef,
    messages,
    isAtBottom,
    lastAutoStickAt,
    sessionId,
    chatId: () => props.chatId,
    getSuppressContentShiftStick,
    getLastObservedScrollHeight,
    setLastObservedScrollHeight,
    logger,
  })

  const runtime = useChatSessionRuntime({
    activePillGroupIndex,
    agentErrorStore,
    applyDeltaExtra,
    bumpStreamContentVersion,
    centerDiff,
    centerFiles,
    CHAT_SCROLL_BUFFER,
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
    PAGE_SIZE,
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
  })

  const { noteCwdMutation } = runtime

  return {
    ...session,
    ...diffView,
    ...agents,
    ...worktree,
    ...transcript,
    ...pagination,
    ...runtime,
    centerDiffScrollRef,
    effectiveCwd,
    gitWorktreeCwd,
    isAtBottom,
    isLoading,
    isPendingSession,
    isSendingAttachments,
    maxCapacityTotalTokens,
    maxTotalTokens,
    onContentShift,
    scrollerIsScrollable,
    sessionCwd,
    sessionId,
    sidebarBranch,
  }
}
