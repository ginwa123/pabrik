<script setup lang="ts">
import { ref, onUnmounted, nextTick, computed, inject, type Ref } from 'vue'
import * as api from '../../api'
import { useChatContentWidth } from '../../composables/useChatContentWidth'
import { useChatScrollRestore } from '../../composables/useChatScrollRestore'
import { VirtualScroller, formatCompactTokens } from '@/helpers'
import { useChatComposerAgents } from './chat_view/useChatComposerAgents'
import { useChatDiffView } from './chat_view/useChatDiffView'
import { useChatWorktree } from './chat_view/useChatWorktree'
import { useChatPagination } from './chat_view/useChatPagination'
import { useChatTranscriptView } from './chat_view/useChatTranscriptView'
import { useChatSessionRuntime } from './chat_view/useChatSessionRuntime'
import type { VirtualScrollerExposed } from './chat_view/chatViewTypes'
import ChatMessageRow from './chat_view/ChatMessageRow.vue'
import ChatTranscriptStates from './chat_view/ChatTranscriptStates.vue'
import type { Message } from './chat_view/useChatMessagePresentation'
import { buildScrollContext, createScrollLogger, type ScrollLogger } from '@/helpers'
import FileInput from '../file/FileInput.vue'
import { resolveWorkspaceId } from '../../helpers/workspaceScope'
// eslint-disable-next-line @typescript-eslint/no-unused-vars -- used in <template> as <Bash> (~line 2507); typescript-eslint doesn't always see template usages via the Vue parser
import Bash from '../preview/Bash.vue'
import SubAgentPeekHost from '../pabrik/SubAgentPeekHost.vue'
import ChatRightSidebar from './chat_right_sidebar/ChatRightSidebar.vue'
import ChatAppBar from './ChatAppBar.vue'
import CenterDiffSection from './chat_right_sidebar/CenterDiffSection.vue'
import { copyTextToClipboard } from './chat_right_sidebar/DiffCommentBox.vue'
import { centerDiffSectionId } from './chat_right_sidebar/parseUnifiedDiff'
import type { DiffSelection } from './chat_right_sidebar/parseUnifiedDiff'
import { useChatRightSidebar } from './chat_right_sidebar/useChatRightSidebar'
import { useNavigationStore } from '../../stores/navigation'
import { chatViewModeFrom } from '../../stores/chatView'
import { useInjectOpenInCodeEditor } from '@/composables/useCodeEditor'
import CodeViewerStage from './CodeViewerStage.vue'
import { useRouter, useRoute } from 'vue-router'
import { useWorkspacesStore } from '../../stores/workspaces'
import { buildAppUrl } from '../../helpers/appUrl'
import AgentErrorCard from '../chat/AgentErrorCard.vue'
import UserPillRail from '../chat/UserPillRail.vue'
import ChatScrollSlider from '../chat/ChatScrollSlider.vue'
import SkillsPopup from '../preview/SkillsPopup.vue'
import BackgroundCommandsPopup from '../preview/BackgroundCommandsPopup.vue'
import ImagePreview from '../preview/ImagePreview.vue'
import WorktreeMenu from '../workspace/WorktreeMenu.vue'
import CreatePrDialog from '../dialogs/CreatePrDialog.vue'
import CreateWorktreeDialog from '../dialogs/CreateWorktreeDialog.vue'
import { ICON_PATHS } from '../ui/icons'

const props = defineProps<{
  chatId: string
  chatName: string
  type?: 'chat' | 'task'
  cwd?: string
  /**    * When true, render the shared chat app bar (ChatAppBar.vue — chat name + `◫` sidebar toggle +
   * `✕` close) above the messages. Every chat host sets this so all modes get the identical bar.
   * Defaults to `false`. */
  showHeader?: boolean
  /**    * Embedded mode for SubAgentPeekPanel: hides ChatView's own header (the peek panel renders its
   * own). ChatView still owns fetch + SSE for `chatId`. Defaults to `false`. */
  embedded?: boolean
  /**    * Hide the composer footer (FileInput + status bar). The peek panel passes this so the sub-agent
   * view is read-only — sending into a sub-agent session from the peek would fork its tool loop
   * mid-run. */
  hideInput?: boolean
}>()

const emit = defineEmits<{
  'update-chat-id': [oldId: string, newId: string]
  /**    * Emitted when the user clicks the ✕ close button. The host (AppLayout) clears the active task
   * and optionally navigates back. ChatView does NOT call router directly — layout composition
   * stays the host's concern. */
  close: []
}>()

// Check if session is pending (needs creation on first message)
const isPendingSession = computed(() => props.chatId.startsWith('pending-'))
const { presetClass: chatWidthClass } = useChatContentWidth()

// Copy code content to clipboard
const copyCodeContent = async (codeContent: string) => {
  try {
    await navigator.clipboard.writeText(codeContent)
  } catch (err) {
    console.error('Failed to copy code:', err)
  }
}

// Setup copy buttons on code blocks after render
const setupCodeBlockCopyButtons = () => {
  nextTick(() => {
    const container = virtualScrollerRef.value?.containerRef
    if (!container) return
    const codeBlocks = container.querySelectorAll('.markdown-content pre')
    codeBlocks.forEach((block) => {
      if (block.querySelector('.code-copy-btn')) return
      const code = block.querySelector('code')
      if (!code) return
      const content = code.textContent || ''
      const btn = document.createElement('button')
      btn.className = 'code-copy-btn'
      // Built imperatively (post-render decoration), so it cannot mount a
      // <UiIcon>; it renders the registry's own `clipboard` paths instead of
      // a hand-copied <path>, so the copy button stays on the one geometry.
      btn.innerHTML = `<svg viewBox="0 0 24 24" width="12" height="12" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round" aria-hidden="true">${ICON_PATHS.clipboard.map((d) => `<path d="${d}"/>`).join('')}</svg>`
      btn.title = 'Copy code'
      btn.style.cssText =
        'position: absolute; top: 8px; right: 8px; padding: 4px 8px; font-size: 12px; cursor: pointer; border: none; background: var(--semantic-active-bg); border-radius: 4px; opacity: 0.7; transition: opacity 0.2s;'
      btn.onmouseover = () => (btn.style.opacity = '1')
      btn.onmouseout = () => (btn.style.opacity = '0.7')
      btn.onclick = (e) => {
        e.stopPropagation()
        copyCodeContent(content)
      }
      ;(block as HTMLElement).style.position = 'relative'
      block.appendChild(btn)
    })
  })
}

// Session ID extracted from props on mount
const sessionId = ref('')

// Inject processingState from App.vue (driven by SSE - always up-to-date)
const processingState = inject<Ref<Record<string, boolean>>>('processingState', ref({}))

// LLM processing state - derived reactively from App.vue's processingState
const isLLMProcessing = computed(() => !!processingState.value[sessionId.value])

// Pagination state
const messageCursor = ref<string | null>(null)
const PAGE_SIZE = 1000

// ── Sub-agent peek ──────────────────────────────────────────────── Owns the slide-over panel for
// watching a single sub-agent's progress. The composable is only mounted when `peekPanel` is
// non-null (lazy) so we don't open SSE channels speculatively.
const nav = useNavigationStore()
const router = useRouter()
const route = useRoute()

// Chat-owned git-diff sidebar (git-diff-only scope). ChatView passes its already-owned effectiveCwd
// + sessionId down, so each chat shows its own working tree without AppLayout-level cwd plumbing.
// Hidden in embedded/peek mode — the peek panel owns the right edge there.
const chatSidebar = useChatRightSidebar(props.type ?? 'chat')
const chatSidebarRef = ref<InstanceType<typeof ChatRightSidebar> | null>(null)
// Attached PR URL for the sidebar's PR-changes mode (set_pull_request
// tool). Empty = worktree-changes mode. Re-synced with the worktree
// binding so a mid-chat attach/clear flips the panel without reload.
const chatPrUrl = ref('')
const chatPrProvider = ref('')

// Persisted review comments (agnostic comment-box path). Saved to localStorage instead of sent to
// the LLM — the diff comment box owns per-line draft persistence; ChatView keeps the appended list
// (capped at 200 entries).
interface SavedReviewComment {
  filePath: string
  message: string
  formatted: string
  savedAt: number
}

const REVIEW_COMMENTS_KEY = 'diff-review-comments'

function loadSavedReviewComments(): SavedReviewComment[] {
  try {
    if (typeof localStorage === 'undefined') return []
    const raw = localStorage.getItem(REVIEW_COMMENTS_KEY)
    if (!raw) return []
    const parsed = JSON.parse(raw) as SavedReviewComment[]
    return Array.isArray(parsed) ? parsed : []
  } catch {
    return []
  }
}

const savedReviewComments = ref<SavedReviewComment[]>(loadSavedReviewComments())

function persistSavedReviewComments(): void {
  try {
    if (typeof localStorage === 'undefined') return
    localStorage.setItem(REVIEW_COMMENTS_KEY, JSON.stringify(savedReviewComments.value.slice(-200)))
  } catch {
    // Best effort — comments stay in memory for the session.
  }
}

function appendSavedReviewComment(entry: SavedReviewComment): void {
  savedReviewComments.value = [...savedReviewComments.value, entry].slice(-200)
  persistSavedReviewComments()
}

// Legacy compat: the old mini-chat emitted raw markdown for the LLM.
// Now it only persists — never calls api.sendChatMessage.
function onChatSidebarSubmitReview(message: string) {
  appendSavedReviewComment({ filePath: '', message, formatted: message, savedAt: Date.now() })
}

function onChatSidebarCommentSaved(payload: {
  filePath: string
  startLine: number
  endLine: number
  message: string
  formatted: string
}) {
  appendSavedReviewComment({
    filePath: payload.filePath,
    message: payload.message,
    formatted: payload.formatted,
    savedAt: Date.now(),
  })
}

const reviewCommentsForDiff = computed(() => {
  const order = new Map(centerFiles.value.map((f, i) => [f.path, i]))
  return savedReviewComments.value
    .filter((e) => order.has(e.filePath))
    .sort((a, b) => (order.get(a.filePath) ?? 0) - (order.get(b.filePath) ?? 0))
})

const copiedAllReviews = ref(false)
let copiedAllTimer: ReturnType<typeof setTimeout> | null = null

async function copyAllReviewComments() {
  const body = reviewCommentsForDiff.value.map((e) => e.formatted).join('\n\n---\n\n')
  if (!body) return
  await copyTextToClipboard(body)
  copiedAllReviews.value = true
  if (copiedAllTimer) clearTimeout(copiedAllTimer)
  copiedAllTimer = setTimeout(() => {
    copiedAllReviews.value = false
  }, 2000)
}

// Sidebar file-row click (or header Open button): open the file in the in-app code browser, which
// also updates the app URL (view=code-editor).
const openInEditor = useInjectOpenInCodeEditor()
function onChatSidebarOpenFile(payload: { path: string; line?: number }) {
  if (!openInEditor || !effectiveCwd.value) return
  void openInEditor({ filePath: payload.path, cwd: effectiveCwd.value, line: payload.line })
}

// Stacked center diff: every changed file renders as its own lazily-mounted section so long lists
// scroll fast. centerDiff stays as the compat "current selection" (back-button + single-file
// wiring).
const centerDiff = ref<DiffSelection | null>(null)
const centerFiles = ref<DiffSelection[]>([])
const currentPath = ref<string | null>(null)
const centerDiffScrollRef = ref<HTMLElement | null>(null)

const showCenterDiff = computed(() => centerDiff.value !== null)

const {
  codeViewerModel,
  collapsedCount,
  collapsedPaths,
  diffMode,
  onCenterDiffBack,
  onCenterDiffRetry,
  onChatSidebarShowDiff,
  onChatSidebarShowDiffList,
  setAllCollapsed,
  setDiffMode,
  showCenterStage,
  showCodeViewer,
  stopCenterSpy,
  syncCenterSpy,
  syncDiffParam,
  toggleCollapse,
  toggleWholeFile,
  wholeFilePaths,
} = useChatDiffView({
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

// Re-read the session's worktree binding from the backend.
async function refreshWorktreeBinding() {
  if (!sessionId.value || isPendingSession.value) return
  try {
    const prevCwd = effectiveCwd.value
    const data = await api.getSession(sessionId.value)
    if (!data) return
    if (data.git_worktree_cwd !== undefined) gitWorktreeCwd.value = data.git_worktree_cwd
    if (data.cwd) sessionCwd.value = data.cwd
    // Replaces the old effectiveCwd watcher arm for the SSE-append path.
    noteCwdMutation(prevCwd)
    if (data.prUrl !== undefined) chatPrUrl.value = data.prUrl ?? ''
    if (data.prProvider !== undefined) chatPrProvider.value = data.prProvider ?? ''
  } catch (err) {
    console.warn('[ChatView] worktree binding refresh failed:', err)
  }
}

// SSE hook: a completed set_git_worktree tool call means the binding
// just changed (bound or cleared) — re-sync so effectiveCwd (and the
// sidebar's cwd prop) follows the worktree immediately.
function maybeRefreshWorktreeBinding(role: string, toolName?: string) {
  if (role === 'tool' && (toolName === 'set_git_worktree' || toolName === 'set_pull_request'))
    void refreshWorktreeBinding()
}

async function onChatSidebarRefresh() {
  // Sidebar ↻ clicked: re-sync the binding FIRST (it may have changed since mount), then reload the
  // panel. The panel's cwd watcher reloads automatically when the binding actually changed; the
  // explicit refresh covers the unchanged-cwd case.
  await refreshWorktreeBinding()
  chatSidebarRef.value?.refresh()
}

function onPeekOpenFull(sessionId: string) {
  nav.closePeek()
  router.replace({ path: '/app', query: { view: 'chat', session: sessionId } })
}

/**  * A `read_workspace_session` search hit pointed at a different conversation. The card is
 * presentation-only, so the navigation decision lives here. Mirrors `ChatsList.setActive`:
 * canonical path URL when a workspace is in scope, legacy query form only as a fallback. */
const workspacesStore = useWorkspacesStore()

function onOpenWorkspaceSession(sessionId: string): void {
  if (!sessionId) return
  const wsId = workspacesStore.activeWorkspace?.id
  if (wsId) {
    router.replace(buildAppUrl({ workspaceId: wsId, chatSessionId: sessionId }))
    return
  }
  router.replace({ path: '/app', query: { view: 'chat', session: sessionId } })
}

// SSE connection. Both the `llm` and `queue` channels now flow through the global `sseBus` (opened
// once by App.vue). The bus's single global SseClient carries ALL 5 channels (including bare 'llm'
// and bare 'queue').
const isStreaming = ref(false)
const streamingContent = ref('')
let streamContentVersion = 0
const getStreamContentVersion = (): number => streamContentVersion

function bumpStreamContentVersion(): void {
  streamContentVersion += 1
}

// Queue state
const queuedMessages = ref<api.QueuedMessage[]>([])

const virtualScrollerRef = ref<VirtualScrollerExposed | null>(null)

// Composer input ref — re-focus after the async mount chain (history + stream snapshot + queued
// messages) so the cursor lands in the box on every session switch, even if the child's own
// mount-focus raced the history render.
const fileInputRef = ref<{ focusInput?: () => void } | null>(null)

// Persist chat scroll position per-task across mount/unmount. The composable attaches its own
// scroll/scrollend listeners to the VirtualScroller's container ref (via the computed
// `scrollerContainerRef` below) and flushes pending writes on unmount.
const scrollerContainerRef = computed<HTMLElement | null>(
  () => virtualScrollerRef.value?.containerRef ?? null,
)
// Stable accessor for ChatScrollSlider: the scroller's containerRef
// resolves after mount and swaps on chat switch, so the slider takes
// a function (re-resolved on its interval) instead of a raw element.
const getChatScrollContainer = (): HTMLElement | null => scrollerContainerRef.value
const chatScrollStorageKey = computed(() => `chat-scroll-${sessionId.value || props.chatId}`)
// The restore composable's "is the saved position still at the bottom?" test has to use the SAME
// bottom edge the auto-stick uses, or a position saved while the reader sat on the last message
// (which lives at the real content bottom, up to `maxTailGap` above the DOM edge) reads as.
const chatScrollRestore = useChatScrollRestore(
  scrollerContainerRef,
  chatScrollStorageKey,
  (el) => virtualScrollerRef.value?.bottomScrollTop?.() ?? el.scrollHeight - el.clientHeight,
)

// Ref to the outer flex wrapper around the VirtualScroller.
const messagesWrapperRef = ref<HTMLElement | null>(null)

// ─── Floating composer: the `--chat-composer-inset` contract ──────────────── The composer dock is
// `position: absolute` on the chat column, so the transcript scrolls *under* it.
let chatColumnEl: HTMLElement | null = null
const setChatColumnEl = (el: unknown) => {
  chatColumnEl = (el as HTMLElement | null) ?? null
}

let composerDockObserver: ResizeObserver | null = null
const syncComposerInset = (height: number) => {
  // Ignore the 0×0 report a display:none dock emits (v-show hides it when
  // the centre diff opens) — zeroing the inset there would make the last
  // row lose its clearance for the whole time the diff is open.
  if (height <= 0 || !chatColumnEl) return
  const px = `${Math.ceil(height)}px`
  if (chatColumnEl.style.getPropertyValue('--chat-composer-inset') === px) return
  chatColumnEl.style.setProperty('--chat-composer-inset', px)
}
const setComposerDockEl = (el: unknown) => {
  composerDockObserver?.disconnect()
  composerDockObserver = null
  const dockEl = (el as HTMLElement | null) ?? null
  if (!dockEl) return
  composerDockObserver = new ResizeObserver((entries) => {
    for (const entry of entries) {
      syncComposerInset(entry.borderBoxSize?.[0]?.blockSize ?? entry.contentRect.height)
    }
  })
  composerDockObserver.observe(dockEl)
}
onUnmounted(() => {
  composerDockObserver?.disconnect()
  composerDockObserver = null
  chatColumnEl = null
})

// True for the newest transcript group only. Pads that ONE row so the final message scrolls clear
// of the floating composer.
const isLastGroup = (index: number) => index === messageGroups.value.length - 1

// Timestamp (ms since epoch) of the most recent auto-stick assignment. See
// `helpers/autoStickGate.ts` for the gating math.
const lastAutoStickAt = ref(0)

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
      chatId: sessionId.value || props.chatId,
      messages: messages.value.length,
      isAtBottom: isAtBottom.value,
      virtualScrollerRef,
      wrapperRef: messagesWrapperRef,
    })
    if (!isAtBottom.value) {
      scrollLogger.debug({
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
      scrollLogger.info({
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
    scrollLogger.markProgrammatic()
    // Record the auto-stick timestamp so the loadMore gate knows the
    // stick is actively engaged right now (not just that the LLM is
    // busy — those are different things, see autoStickGate.ts).
    lastAutoStickAt.value = Date.now()
    // Explicit bottom computation.
    virtualScrollerRef.value?.scrollToBottom('auto')
    scrollLogger.info({
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

// State
const messages = ref<Message[]>([])
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
// "The server has answered, and the answer was: zero messages." The empty state must be gated on
// this, not on `messageGroups.length === 0` alone.
const historyConfirmed = ref(false)

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

const {
  availableAgents,
  selectedAgent,
  activeAgent,
  showAgentPicker,
  isUpdatingAgent,
  agentPickerRef,
  chatWorkspaceId,
  loadAgents,
  effectiveAgent,
  effectiveProfileUrlStyle,
  agentChipTooltip,
  selectAgent,
  closeOnOutsideClick,
} = useChatComposerAgents({
  sessionId,
  workspaceId: () =>
    resolveWorkspaceId(route?.params?.workspaceId, workspacesStore.activeWorkspace?.id),
  applyChatViewMode: (config) => chatView.setMode(chatViewModeFrom(config)),
})

const {
  onCreateWorktree,
  onPrCreated,
  onPrError,
  onWorktreeMenuClear,
  onWorktreeMenuCreatePr,
  onWorktreeMenuCreateWorktree,
  onWorktreeMenuRefresh,
  onWorktreeMenuViewFolder,
  showCreatePrDialog,
  showCreateWorktreeDialog,
  showWorktreeMenu,
  worktreeMenuRef,
} = useChatWorktree({
  sessionId,
  sessionCwd,
  gitWorktreeCwd,
  selectedAgent,
  workspacesStore,
  checkGitStatus: () => checkGitStatus(),
})

// ─── Scroll logger ──────────────────────────────────────────────────────────── A dedicated logger
// for the scroll subsystem. Bound to the active chat so every line is tagged with chatId. See
// helpers/scrollLogger.ts for what fields every line carries and why.
let scrollLogger: ScrollLogger = createScrollLogger(props.chatId)
const refreshScrollLogger = () => {
  scrollLogger = createScrollLogger(sessionId.value || props.chatId)
}

const {
  activePillGroupIndex,
  agentError,
  agentErrorStore,
  CHAT_SCROLL_BUFFER,
  chatView,
  checkGitStatus,
  closeImagePreview,
  gitStatus,
  setGitStatusCwd,
  groupKey,
  groupKeyForMessageId,
  isInitializing,
  jumpToUserGroup,
  messageGroups,
  previewImageUrl,
  rehydrateSubAgentProgress,
  rowProps,
  sessionSkills,
  showSkillsPopup,
  startGitStatusPoll,
  statesProps,
  stopGitStatusPoll,
  subAgentProgressMap,
  userPills,
} = useChatTranscriptView({
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
  logger: () => scrollLogger,
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
} = useChatPagination({
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
  logger: () => scrollLogger,
  noteCwdMutation: (prevCwd: string) => noteCwdMutation(prevCwd),
  rehydrateSubAgentProgress,
  setupCodeBlockCopyButtons,
  PAGE_SIZE,
})

const {
  handleFileInputSubmit,
  handleLoadMore,
  handleLoadMoreSuppressed,
  handleStopSession,
  handleVirtualScroll,
  noteCwdMutation,
} = useChatSessionRuntime({
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
  logger: () => scrollLogger,
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

// ─── Compact ──────────────────────────────────────────────────────────────────
const isCompacting = ref(false)
const compactError = ref<string | null>(null)

const compactSession = async () => {
  if (!sessionId.value || isCompacting.value) return

  isCompacting.value = true
  compactError.value = null

  try {
    const result = await api.compactSession(sessionId.value)
    if (result.success) {
      await loadChatHistory()
    } else {
      compactError.value = result.message || 'Failed to compact'
    }
  } catch (err) {
    console.error('Failed to compact session:', err)
    compactError.value = 'Failed to compact session'
  } finally {
    isCompacting.value = false
  }
}
</script>

<template>
  <div class="flex h-full w-full">
    <!-- Main Chat Content -->
    <!--
      `relative` + `chat-column`: the composer FLOATS over the transcript
      (see the `composer-dock` block at the bottom), so this column is the
      containing block it anchors to, and the host of the
      `--chat-composer-inset` custom property every consumer of that inset
      reads (the scrim, the last transcript row, the scroll-to-bottom
      button, ChatScrollSlider's track). The inset is written here by the
      dock's ResizeObserver via `setChatColumnEl` — deliberately a plain
      DOM write, not a reactive ref, so that growing the textarea (which
      fires the observer on every input event) never re-runs ChatView's
      (very large) render.
    -->
    <div
      :ref="setChatColumnEl"
      class="relative flex flex-col h-full flex-1 min-w-0 chat-column"
      :class="chatWidthClass"
    >
      <!--
        Chat app bar. Rendered only when the parent passed the
        `showHeader` prop. Every chat host sets it (kanban
        branch, AgentChatView, StandardTaskChatView, standalone
        `chat-<id>` branch) so all modes get the identical bar.
        The markup itself lives in
        ChatAppBar.vue — the one app bar shared by every mode, so the
        title, the sidebar toggle and the ✕ cannot drift apart again.
        The `app-bar-extras` slot lets a host pin mode-specific bits
        (AgentChatView's SessionSlider) into the same bar.
        The host (AppLayout) handles the actual navigation / state
        cleanup so the ChatView stays decoupled from router + store
        concerns.
      -->
      <ChatAppBar
        v-if="showHeader && !embedded"
        :title="chatName"
        :show-sidebar-toggle="!embedded"
        :data-chat-header="chatId"
        @toggle-sidebar="chatSidebar.toggle()"
        @close="emit('close')"
      >
        <template #extras>
          <slot name="app-bar-extras" />
        </template>
      </ChatAppBar>
      <!-- Messages (Virtual Scroll) -->
      <!--
        The wrapper MUST be a flex container (`flex flex-col`) so the
        VirtualScroller's own `flex: 1 1 0` (defined in helpers/
        VirtualScroller.vue) can resolve to a real height. Without
        `flex` here, the wrapper is a regular block element — the
        VirtualScroller's `flex: 1 1 0` does nothing, the scroller
        collapses to 0×0, the messages overflow out of the wrapper,
        and the last bubbles overlap the composer below. This is the
        "no scroll, bubbles overlap input" bug.

        The composer is a floating overlay now (an `absolute` sibling
        anchored to the column), so this wrapper takes the column's FULL
        height and content scrolls under the dock. It is also the element
        that clears the dock: the last row is padded by
        `--chat-composer-inset`, which the dock's ResizeObserver measures
        and writes onto the parent `.chat-column` (see the script block
        and `.last-transcript-row` in the style block).
      -->
      <div
        v-show="!showCenterStage"
        ref="messagesWrapperRef"
        class="relative flex-1 min-h-0 flex flex-col messages-scroll-hide-native"
        :class="{ 'has-pill-rail': userPills.length >= 2 }"
      >
        <!-- Changes-sidebar toggle for the headerless standalone layout
             (the kanban layout has its toggle button in the header above). -->
        <button
          v-if="!showHeader && !embedded && !chatSidebar.isOpen.value"
          type="button"
          class="absolute top-2 right-2 z-10 w-7 h-7 rounded flex items-center justify-center text-body hover:opacity-70 transition-opacity"
          style="
            color: var(--semantic-text-dim);
            background-color: var(--semantic-card-bg);
            border: 1px solid var(--color-border);
          "
          title="Show changes sidebar (Cmd/Ctrl+B)"
          aria-label="Show changes sidebar"
          data-testid="chat-sidebar-open"
          @click="chatSidebar.open()"
        >
          ◫
        </button>
        <ChatTranscriptStates v-bind="statesProps" />

        <VirtualScroller
          v-if="!isInitializing && (isLoading || messageGroups.length > 0)"
          ref="virtualScrollerRef"
          :items="messageGroups"
          :item-key="groupKey"
          :total-count="0"
          :buffer="30"
          :default-item-height="64"
          :load-more-threshold="200"
          :load-more-threshold-ratio="0.5"
          :load-more-at-top="true"
          :debug-chat-id="sessionId || props.chatId"
          @load-more="handleLoadMore"
          @load-more-suppressed="handleLoadMoreSuppressed"
          @scroll="handleVirtualScroll"
          @scrollability-change="scrollerIsScrollable = $event"
          @content-shift="onContentShift"
        >
          <template #default="{ item: group, index: groupIndex }">
            <ChatMessageRow v-bind="rowProps(group, groupIndex)" />
          </template>
        </VirtualScroller>

        <UserPillRail
          v-if="userPills.length >= 2"
          :pills="userPills"
          :active-group-index="activePillGroupIndex"
          @jump="jumpToUserGroup"
        />

        <!-- Realtime chat slider: continuous draggable scrollbar thumb
             synced to the VirtualScroller's scroll position (scroll-up
             moves the thumb in realtime; dragging the thumb scrubs the
             chat). Sibling of VirtualScroller inside the relative
             messagesWrapperRef so it never virtualizes. The native
             scrollbar is hidden for this scroller (see scoped style
             below) — this thumb IS the scrollbar visual. -->
        <ChatScrollSlider :get-container="getChatScrollContainer" />

        <div
          v-if="agentError"
          class="px-4 max-w-[var(--chat-content-max)] mx-auto agent-error-list"
          data-testid="agent-error-list"
        >
          <AgentErrorCard :key="agentError.id" :content="agentError.content" />
        </div>
      </div>

      <!-- Scroll to bottom button.
           Anchored to the chat column (now `relative`) and lifted clear of
           the floating composer by `--chat-composer-inset`, so it never ends
           up half-hidden behind the dock on narrow viewports. z-31 puts it
           above the dock's z-30. -->
      <Transition name="fade">
        <button
          v-if="!isAtBottom && messageGroups.length > 0"
          v-show="!showCenterStage"
          @click="scrollToBottom(true, 'user-button-click')"
          class="chat-scroll-to-bottom p-3 rounded-full shadow-lg transition-all duration-200 hover:scale-105"
          style="background-color: var(--color-violet); color: var(--color-bg)"
        >
          <svg
            xmlns="http://www.w3.org/2000/svg"
            class="w-5 h-5"
            fill="none"
            viewBox="0 0 24 24"
            stroke="currentColor"
          >
            <path
              stroke-linecap="round"
              stroke-linejoin="round"
              stroke-width="2"
              d="M19 14l-7 7m0 0l-7-7m7 7V3"
            />
          </svg>
        </button>
      </Transition>

      <!--
        Floating composer dock (hidden in peek-embed read-only mode).

        Was the last flex child in normal flow, with a `border-top` and an
        opaque `--semantic-sidebar-bg` fill. That cost the transcript a
        slice of its height AND read as a hard-edged bar: the message
        column ended in a 1px rule with content hard-clipped above it.

        Now the dock is `position: absolute; bottom: 0` on the (relative)
        chat column, so the transcript owns the full column height and the
        transcript scrolls *under* the composer. The hard rule is replaced
        by `composer-scrim` — a solid-to-transparent gradient that fades to
        `--semantic-content-bg`, the same colour the transcript is painted
        on, so messages dissolve into the composer instead of being cut off
        (fading to `--semantic-sidebar-bg` instead would show a 1-shade seam).

        The card reads as floating because of the shadow applied in
        `.composer-dock :deep(.composer-card)` below.

        Clearance is the other half of "floating": the LAST transcript row
        is padded by `--chat-composer-inset` (see `last-transcript-row`), so
        the newest message can always be scrolled fully clear of the dock.
        The dock's ResizeObserver keeps that inset in sync as the composer
        grows (textarea autogrow, attachment previews, queued messages).
      -->
      <div
        v-if="!hideInput"
        v-show="!showCenterStage"
        :ref="setComposerDockEl"
        class="composer-dock p-4"
        data-testid="composer-dock"
      >
        <div class="composer-scrim" aria-hidden="true" data-testid="composer-scrim"></div>
        <div class="max-w-[var(--chat-content-max)] mx-auto">
          <FileInput
            ref="fileInputRef"
            :cwd="sessionCwd"
            :queuedMessages="queuedMessages"
            :isLoading="isLoading || isSendingAttachments"
            :isInitializing="isInitializing"
            :isLLMProcessing="isLLMProcessing"
            @submit="handleFileInputSubmit"
            @files-selected="handleFileInputSubmit"
            @stop-session="handleStopSession"
            :draft-key="sessionId ? `chat:${sessionId}` : undefined"
          >
            <!-- Composer toolbar (V1 single-card): projected into FileInput's
                 toolbar strip so input + status read as one card. Three zones:
                 left actions · middle muted status · right context. -->
            <template #toolbar>
              <div class="flex items-center gap-1 min-w-0 flex-1 flex-wrap">
                <!-- Left zone: session actions -->
                <div class="flex items-center gap-1 shrink-0">
                  <!-- Compact button -->
                  <button
                    @click="compactSession"
                    :disabled="
                      isCompacting || isLoading || isInitializing || isLLMProcessing || !sessionId
                    "
                    class="composer-tool-btn"
                    :title="isCompacting ? 'Compacting...' : 'Compact conversation history'"
                  >
                    <span
                      v-if="isCompacting"
                      class="w-3.5 h-3.5 border-2 rounded-full animate-spin"
                      style="border-color: var(--color-violet); border-top-color: transparent"
                    ></span>
                    <svg
                      v-else
                      class="w-3.5 h-3.5"
                      fill="none"
                      viewBox="0 0 24 24"
                      stroke="currentColor"
                      stroke-width="2"
                      stroke-linecap="round"
                      stroke-linejoin="round"
                    >
                      <polyline points="4 14 10 14 10 20" />
                      <polyline points="20 10 14 10 14 4" />
                      <line x1="10" y1="14" x2="21" y2="3" />
                      <line x1="21" y1="21" x2="14" y2="14" />
                    </svg>
                    <span>{{ isCompacting ? 'Compacting...' : 'Compact' }}</span>
                  </button>

                  <!-- Model/Agent selector -->
                  <div ref="agentPickerRef" class="relative">
                    <button
                      @click.stop="showAgentPicker = !showAgentPicker"
                      :disabled="isUpdatingAgent || isInitializing || !sessionId"
                      class="composer-tool-btn"
                      data-testid="agent-picker-button"
                      :title="agentChipTooltip"
                    >
                      <span>{{ effectiveAgent ?? 'Default' }}</span>
                      <span class="text-micro">▾</span>
                    </button>
                    <div
                      v-if="showAgentPicker"
                      class="agent-picker-menu absolute bottom-full mb-2 left-0 min-w-[240px] rounded-lg shadow-lg z-20"
                      data-testid="agent-picker-menu"
                      style="
                        background-color: var(--semantic-card-bg);
                        border: 1px solid var(--color-border);
                      "
                    >
                      <button
                        @click="selectAgent(null)"
                        class="w-full text-left px-3 py-2 text-dense hover:opacity-80 flex items-center justify-between"
                        style="color: var(--semantic-text)"
                        data-testid="agent-picker-default"
                      >
                        <span>Default (top-level config)</span>
                        <span v-if="!selectedAgent && !activeAgent">✓</span>
                      </button>
                      <button
                        v-for="p in availableAgents"
                        :key="p.name"
                        @click="selectAgent(p.name)"
                        class="w-full text-left px-3 py-2 text-dense hover:opacity-80"
                        style="
                          color: var(--semantic-text);
                          border-top: 1px solid var(--color-border);
                        "
                        :data-testid="`agent-picker-${p.name}`"
                      >
                        <div class="flex items-center justify-between">
                          <span class="font-medium">
                            {{ p.name }}
                            <span
                              v-if="activeAgent === p.name"
                              class="text-micro ml-1 px-1 py-0.5 rounded"
                              :style="{ backgroundColor: 'var(--color-violet)', color: 'var(--semantic-on-accent)' }"
                              data-testid="agent-picker-active-badge"
                              >(active)</span
                            >
                          </span>
                          <span v-if="effectiveAgent === p.name">✓</span>
                        </div>
                        <div class="text-micro mt-0.5" style="color: var(--semantic-text-muted)">
                          {{ p.model }} · {{ p.base_url }}
                        </div>
                      </button>
                      <div
                        v-if="availableAgents.length === 0"
                        class="px-3 py-2 text-dense"
                        style="color: var(--semantic-text-muted)"
                      >
                        No agents configured. Add one in Settings.
                      </div>
                    </div>
                  </div>
                </div>
                <span class="composer-toolbar-divider" aria-hidden="true" />
                <!-- Middle zone: token status (display-only, muted) -->
                <div
                  v-if="maxTotalTokens > 0 || maxCapacityTotalTokens > 0"
                  class="composer-tokens-status"
                  data-testid="tokens-status"
                  :title="`Tokens: ${maxTotalTokens.toLocaleString()} / ${maxCapacityTotalTokens.toLocaleString()}`"
                >
                  <span>{{ formatCompactTokens(maxTotalTokens) }}</span>
                  <span v-if="maxCapacityTotalTokens > 0"
                    >/ {{ formatCompactTokens(maxCapacityTotalTokens) }}</span
                  >
                  <div
                    v-if="maxCapacityTotalTokens > 0"
                    class="w-12 h-1 rounded-full overflow-hidden"
                    style="background-color: var(--color-border)"
                  >
                    <div
                      class="h-full rounded-full transition-all duration-300"
                      :style="{
                        width: Math.min(100, (maxTotalTokens / maxCapacityTotalTokens) * 100) + '%',
                        backgroundColor:
                          maxTotalTokens / maxCapacityTotalTokens > 0.8
                            ? 'var(--color-red)'
                            : maxTotalTokens / maxCapacityTotalTokens > 0.6
                              ? 'var(--color-orange)'
                              : 'var(--color-violet)',
                      }"
                    ></div>
                  </div>
                </div>
                <!-- Right zone: context (pushed right, truncates first) -->
                <div class="flex items-center gap-1 ml-auto pl-1 shrink-0">
                  <!-- Git status indicator — always clickable; opens a dropdown
                       menu with context-appropriate actions (worktree-bound vs.
                       no-worktree). -->
                  <div ref="worktreeMenuRef" class="relative min-w-0">
                    <button
                      v-if="gitStatus && gitStatus.is_git_repo"
                      @click.stop="showWorktreeMenu = !showWorktreeMenu"
                      data-testid="worktree-status-button"
                      class="composer-tool-btn"
                      :title="
                        gitWorktreeCwd
                          ? `Worktree: ${gitWorktreeCwd}\n${gitStatus.status === 'clean' ? 'Working tree clean' : 'Working tree has changes'}`
                          : gitStatus.status === 'clean'
                            ? 'Working tree clean'
                            : 'Working tree has changes'
                      "
                    >
                      <span class="composer-branch-label">{{
                        gitStatus.branch || 'detached'
                      }}</span>
                      <span v-if="!gitStatus.is_clean" style="color: var(--color-orange)">●</span>
                      <span v-else style="color: var(--color-green)">✓</span>
                      <span class="text-micro">▾</span>
                    </button>
                    <WorktreeMenu
                      v-if="showWorktreeMenu"
                      :has-worktree="!!gitWorktreeCwd"
                      :branch="gitStatus?.branch || 'detached'"
                      :status="gitStatus?.status"
                      @create-pr="onWorktreeMenuCreatePr"
                      @create-worktree="onWorktreeMenuCreateWorktree"
                      @view-folder="onWorktreeMenuViewFolder"
                      @clear="onWorktreeMenuClear"
                      @refresh="onWorktreeMenuRefresh"
                      @close="showWorktreeMenu = false"
                    />
                  </div>
                  <!-- Session skills display -->
                  <button
                    v-if="sessionSkills && sessionSkills.length > 0"
                    @click="showSkillsPopup = true"
                    class="composer-tool-btn"
                    :title="'Loaded skills: ' + sessionSkills.map((s) => s.skill_name).join(', ')"
                  >
                    <span>{{ sessionSkills.length }}</span>
                    <span>skill{{ sessionSkills.length !== 1 ? 's' : '' }}</span>
                  </button>
                  <!-- Background commands pill — self-contained: SSE push via
                       `background_process_created/completed` + queue fallback +
                       resync refetch; hidden when nothing is running. -->
                  <BackgroundCommandsPopup v-if="sessionId" :session-id="sessionId" />
                </div>
              </div>
            </template>
          </FileInput>
        </div>
      </div>
      <!-- Stacked center diff: every changed file renders as its own
           lazily-mounted section (content-visibility + IntersectionObserver
           in CenterDiffSection) so long lists scroll fast. Messages state
           is preserved (v-show) underneath. -->
      <div
        v-if="showCenterDiff && !showCodeViewer"
        class="flex-1 min-h-0 flex flex-col"
        data-testid="chat-center-diff"
      >
        <div
          class="flex items-center gap-2 px-3 h-10 shrink-0"
          style="border-bottom: 1px solid var(--color-border)"
        >
          <button
            type="button"
            class="text-dense px-2 py-1 rounded hover:opacity-70"
            style="color: var(--semantic-text-dim)"
            data-testid="chat-center-diff-back"
            @click="onCenterDiffBack"
          >
            ← Back to chat
          </button>
          <span
            class="text-dense truncate flex-1"
            style="color: var(--semantic-text-dim)"
            data-testid="chat-center-diff-count"
          >
            {{ centerFiles.length }} file{{ centerFiles.length !== 1 ? 's' : ''
            }}<template v-if="collapsedCount > 0"> · {{ collapsedCount }} collapsed</template>
          </span>
          <!-- LAYOUT axis (global): how the lines are laid out. -->
          <span
            class="inline-flex rounded overflow-hidden shrink-0"
            style="border: 1px solid var(--color-border)"
            data-testid="chat-center-diff-mode"
          >
            <button
              type="button"
              class="px-2 py-0.5 text-dense"
              :style="
                diffMode === 'unified'
                  ? { background: 'var(--color-violet)', color: 'var(--color-bg-m2)' }
                  : { color: 'var(--semantic-text-dim)' }
              "
              title="Unified — one column, git-style hunks"
              data-testid="chat-center-diff-mode-unified"
              @click="setDiffMode('unified')"
            >
              Unified
            </button>
            <button
              type="button"
              class="px-2 py-0.5 text-dense"
              :style="
                diffMode === 'split'
                  ? { background: 'var(--color-violet)', color: 'var(--color-bg-m2)' }
                  : { color: 'var(--semantic-text-dim)' }
              "
              title="Split — side by side, before | after"
              data-testid="chat-center-diff-mode-split"
              @click="setDiffMode('split')"
            >
              Split
            </button>
          </span>
          <!-- One state-aware button: the label IS the current state. -->
          <button
            type="button"
            class="text-dense px-2 py-1 rounded hover:opacity-70 shrink-0"
            style="color: var(--semantic-text-dim)"
            :title="
              collapsedCount > 0
                ? 'Expand every file section'
                : 'Collapse every file section to its header'
            "
            data-testid="chat-center-diff-toggle-all"
            @click="setAllCollapsed(collapsedCount === 0)"
          >
            {{ collapsedCount > 0 ? '⌄ Expand all' : '⌃ Collapse all' }}
          </button>
          <button
            v-if="reviewCommentsForDiff.length > 0"
            type="button"
            class="text-dense px-2 py-1 rounded hover:opacity-70"
            style="color: var(--color-blue)"
            data-testid="chat-center-diff-copy-all"
            @click="copyAllReviewComments"
          >
            Copy all ({{ reviewCommentsForDiff.length }})
          </button>
          <span
            v-if="copiedAllReviews"
            class="text-dense"
            style="color: var(--color-green)"
            data-testid="chat-center-diff-copied-all"
          >
            Copied
          </span>
        </div>
        <div
          ref="centerDiffScrollRef"
          class="flex-1 min-h-0 overflow-y-auto"
          data-testid="chat-center-diff-scroll"
        >
          <CenterDiffSection
            v-for="file in centerFiles"
            :key="file.path"
            :section-id="centerDiffSectionId(file.path)"
            :path="file.path"
            :lines="file.lines"
            :added="file.added"
            :removed="file.removed"
            :staged="file.staged"
            :error="file.error ?? null"
            :cwd="effectiveCwd"
            :collapsed="collapsedPaths.has(file.path)"
            :mode="diffMode"
            :whole-file="wholeFilePaths.has(file.path) || file.untracked === true"
            :untracked="file.untracked === true"
            @open="onChatSidebarOpenFile"
            @retry="onCenterDiffRetry"
            @toggle-collapse="toggleCollapse(file.path)"
            @toggle-whole-file="toggleWholeFile(file.path)"
            @submit-review="onChatSidebarSubmitReview"
            @comment-saved="onChatSidebarCommentSaved"
          />
        </div>
      </div>

      <!-- Code viewer stage: the open file, in the same center slot as the
           stacked diff above, so the chat-owned right sidebar (Explorer /
           Files changed / Terminal) stays visible next to it. This is the
           path the user's own Explorer click takes. The session state is
           injected by AppLayout (see `useInjectCodeViewer`). -->
      <div
        v-if="codeViewerModel.file"
        class="flex-1 min-h-0 flex flex-col"
        data-testid="chat-center-code"
      >
        <CodeViewerStage
          :file="codeViewerModel.file"
          :content="codeViewerModel.content"
          :loading="codeViewerModel.loading"
          :error="codeViewerModel.error"
          :cwd="codeViewerModel.cwd"
          :line="codeViewerModel.line"
          @close="codeViewerModel.close()"
        />
      </div>
    </div>

    <!-- Chat-owned git-diff sidebar. Mounted beside (not inside) the
         main chat column so messages keep their flex-1 min-w-0 layout.
         Hidden in embedded/peek mode — the peek panel owns the right
         edge there. -->
    <ChatRightSidebar
      v-if="!embedded"
      ref="chatSidebarRef"
      :cwd="effectiveCwd"
      :session-key="chatId"
      :workspace-id="chatWorkspaceId"
      :branch="sidebarBranch"
      :pr-url="chatPrUrl"
      :pr-provider="chatPrProvider"
      :open="chatSidebar.isOpen.value"
      :width="chatSidebar.width.value"
      :min-width="chatSidebar.MIN_WIDTH"
      :max-width="chatSidebar.MAX_WIDTH"
      @update:open="(v) => (v ? chatSidebar.open() : chatSidebar.close())"
      @update:width="(w) => chatSidebar.setWidth(w)"
      @refresh="onChatSidebarRefresh"
      @show-diff="onChatSidebarShowDiff"
      @show-diff-list="onChatSidebarShowDiffList"
    />

    <!-- Skills Popup Modal -->
    <SkillsPopup
      :show="showSkillsPopup"
      :skills="sessionSkills"
      :session-cwd="sessionCwd"
      @close="showSkillsPopup = false"
      @skill-click="
        (skill) => {
          showSkillsPopup = false
        }
      "
    />

    <!-- Image Preview Popup -->
    <ImagePreview :src="previewImageUrl ?? ''" @close="closeImagePreview" />

    <!--
      Create-PR modal. Mounted when the user picks "Create a PR" from
      the WorktreeMenu. The dialog pre-fills from getGitWorktreeInfo,
      submits to /api/git/pr, and emits pr-created (URL) or error.
    -->
    <CreatePrDialog
      v-if="showCreatePrDialog"
      :worktree-path="gitWorktreeCwd"
      @pr-created="onPrCreated"
      @error="onPrError"
      @close="showCreatePrDialog = false"
    />
    <CreateWorktreeDialog
      v-if="showCreateWorktreeDialog"
      :initial-cwd="cwd"
      @create="onCreateWorktree"
      @close="showCreateWorktreeDialog = false"
    />

    <SubAgentPeekHost
      v-if="nav.peekPanel && !embedded"
      :key="nav.peekPanel.sessionId"
      :session-id="nav.peekPanel.sessionId"
      :agent-name="nav.peekPanel.agentName"
      :instruction="nav.peekPanel.instruction"
      @close="nav.closePeek()"
      @open-full="onPeekOpenFull"
    />
  </div>
</template>

<style scoped src="./chat_view/chatView.css"></style>
