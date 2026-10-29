<script setup lang="ts">
import { ref, onMounted, onUnmounted, onUpdated, nextTick, computed, inject, type Ref } from 'vue'
import * as api from '../../api'
import { chatEngineDb, newestCursor, toChatMessage } from '../../sync/ChatEngineDb'
import { runSyncEffect, runSyncEffectOr, runSyncVoid } from '../../sync/runtime'
import { useChatContentWidth } from '../../composables/useChatContentWidth'
import { useChatScrollRestore } from '../../composables/useChatScrollRestore'
import { VirtualScroller, formatCompactTokens } from '@/helpers'
import { onHtmlFrameResize } from '../../helpers/chatHtmlFrame'
import { useChatComposerAgents } from './chat_view/useChatComposerAgents'
import { useChatDiffView } from './chat_view/useChatDiffView'
import { useChatSse } from './chat_view/useChatSse'
import { useChatWorktree } from './chat_view/useChatWorktree'
import type { VirtualScrollerExposed } from './chat_view/chatViewTypes'
import ChatMessageRow from './chat_view/ChatMessageRow.vue'
import ChatTranscriptStates from './chat_view/ChatTranscriptStates.vue'
import {
  isCompactionMessage,
  useChatMessagePresentation,
  type Message,
  type MessageGroup,
} from './chat_view/useChatMessagePresentation'
import {
  buildScrollContext,
  createScrollLogger,
  isAutoStickActive,
  AUTO_STICK_GATE_MS,
  BOTTOM_THRESHOLD,
  AT_BOTTOM_STABLE_TOLERANCE_PX,
  TOP_THRESHOLD,
  decidePrefetchOlder,
  armRadiusPx,
  nextFetchEstimate,
  PREFETCH_SAMPLE_INIT_MS,
  type ScrollLogger,
  type ScrollReason,
} from '@/helpers'
import FileInput from '../file/FileInput.vue'
import { readGitStatusCache } from '../../helpers/gitStatusCache'
import { splitMediaUrlsWire } from '../../helpers/mediaUrls'
import {
  fileToAttachment,
  isDocumentFile,
  styleCarriesFile,
  type FileAttachment,
} from '../../helpers/fileAttachments'
import { Effect } from 'effect'
import { runEffectExit } from '../../helpers/effectRuntime'
import {
  fetchInitialHistoryWithRetry,
  INITIAL_HISTORY_TIMEOUT_MS,
} from '../../helpers/chatHistoryRetry'
import { ChatHistoryError } from '../../api'
import { resolveWorkspaceId } from '../../helpers/workspaceScope'
import {
  applySnapshotRows,
  isPlaceholderSpawnRow,
  type SubAgentProgressMap,
} from '../../helpers/subagentProgress'
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
import { useAgentErrorStore } from '../../stores/agentError'
import { useChatViewStore, chatViewModeFrom } from '../../stores/chatView'
import type { AgentErrorEntry } from '../../stores/agentError'
import { useInjectOpenInCodeEditor } from '@/composables/useCodeEditor'
import CodeViewerStage from './CodeViewerStage.vue'
import { useRouter, useRoute } from 'vue-router'
import { useWorkspacesStore } from '../../stores/workspaces'
import { buildAppUrl } from '../../helpers/appUrl'
import AgentErrorCard from '../chat/AgentErrorCard.vue'
import UserPillRail from '../chat/UserPillRail.vue'
import ChatScrollSlider from '../chat/ChatScrollSlider.vue'
import { pickActivePillIndex, estimateViewportEnd } from '../chat/activePill'
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
        'position: absolute; top: 8px; right: 8px; padding: 4px 8px; font-size: 12px; cursor: pointer; border: none; background: rgba(255,255,255,0.1); border-radius: 4px; opacity: 0.7; transition: opacity 0.2s;'
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

// Guard flag for the messages-length watcher's auto-stick. During the initial load, the
// loadChatHistory branch handles the scroll explicitly (either restore a saved position via
// scrollToPosition or land at the bottom via scrollToBottom).
let isInitialLoad = false

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
let lastObservedScrollHeight = 0
// True while a loadMore preserve window is in flight — contentShift
// events are ignored entirely (same effect as the old observer teardown,
// without detaching anything).
let suppressContentShiftStick = false

const onContentShift = (shift: { topSpacer: number; bottomSpacer: number; total: number }) => {
  if (suppressContentShiftStick) return
  if (spacerRafId !== null) cancelAnimationFrame(spacerRafId)
  spacerRafId = requestAnimationFrame(() => {
    spacerRafId = null
    const container = virtualScrollerRef.value?.containerRef
    if (!container) return
    const newScrollHeight = container.scrollHeight
    // Only re-stick if the scrollHeight actually changed (a measurement
    // update). Positioning-only shifts (pure window moves at constant
    // total height) won't trigger a re-scroll.
    if (newScrollHeight === lastObservedScrollHeight) return
    const delta = newScrollHeight - lastObservedScrollHeight
    if (delta <= 0 || delta < 10) {
      lastObservedScrollHeight = newScrollHeight
      return
    }
    lastObservedScrollHeight = newScrollHeight
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
  scrollLogger.markProgrammatic()
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
    scrollLogger.info({
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
        scrollLogger.info({
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
      scrollLogger.info({
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
      scrollLogger.warn({
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
    scrollLogger.info({
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
  scrollLogger.info({
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
  scrollLogger.markProgrammatic()
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
  scrollLogger.info({
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
      scrollLogger.markProgrammatic()
      lastAutoStickAt.value = Date.now()
      // Delegated to the scroller's scrollToBottom (real-bottom
      // target — same rationale as the onContentShift stick).
      virtualScrollerRef.value?.scrollToBottom('auto')
      // Re-engage the stick explicitly: the user WAS at bottom before the prepend, and we just
      // moved them to the new bottom on their behalf.
      isAtBottom.value = true
      scrollLogger.info({
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
      scrollLogger.info({
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
    scrollLogger.info({
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
    scrollLogger.info({
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
    scrollLogger.info({
      ...ctx,
      caller: 'maybeLoadOlder',
      reason: 'load-more-suppressed',
      extra: { guard: 'no-more-messages', source: 'ChatView', trigger },
    })
    return
  }
  if (isLoadingMore.value) {
    scrollLogger.info({
      ...ctx,
      caller: 'maybeLoadOlder',
      reason: 'load-more-suppressed',
      extra: { guard: 'already-loading', source: 'ChatView', trigger },
    })
    return
  }
  if (isCommittingOlder) {
    scrollLogger.info({
      ...ctx,
      caller: 'maybeLoadOlder',
      reason: 'load-more-suppressed',
      extra: { guard: 'already-committing', source: 'ChatView', trigger },
    })
    return
  }
  if (messages.value.length === 0) {
    scrollLogger.info({
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
  scrollLogger.info({
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
    scrollLogger.info({
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
      scrollLogger.markProgrammatic()
      virtualScrollerRef.value?.scrollToPosition(savedScrollTop, 'auto')
      scrollLogger.info({
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
      scrollLogger.markProgrammatic()
      if (force) {
        scrollLogger.info({
          ...ctx,
          caller: 'scrollToBottom',
          reason: 'scroll-to-bottom-forced',
          extra: { trigger },
        })
      } else {
        scrollLogger.info({
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

// ─── Follow the newest turn ────────────────────────────────────────────────── "Take me to the
// newest turn", as an explicit act by the reader rather than an inference from where they happen to
// be sitting.
const followNewestTurn = (trigger: string) => {
  isAtBottom.value = true
  lastAutoStickAt.value = Date.now()
  scrollLogger.markProgrammatic()
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
  scrollLogger.info({
    ...ctx,
    caller: 'handleLoadMoreSuppressed',
    reason: 'load-more-suppressed',
    extra: { guard, source: 'VirtualScroller' },
  })
}

// Track isAtBottom from the VirtualScroller's scroll event so we can decide whether to auto-scroll
// on new messages and when to show the "scroll to bottom" button. `previousIsAtTop` is a
// module-scope (not ref) because it only feeds the logger — nothing else needs to react to it.
let previousIsAtTop = false
// Module-scope state for the additional handleVirtualScroll logs below. Like `previousIsAtTop`,
// these are pure diagnostics — nothing else reads them. Using plain `let` (not ref) avoids any
// reactive work; the values exist only to feed the logger.
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
  scrollLogger.debug({ ...ctx, caller: 'handleVirtualScroll' })
  // ── First-scroll info ─────────────────────────────────────────────── Captures the chat's
  // initial state on the very first scroll event. Without this, "delta=0" lines for the first few
  // events look like a bug in the delta math.
  if (isFirstScroll) {
    scrollLogger.info({
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
    scrollLogger.info({
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
    scrollLogger.info({
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
    scrollLogger.info({
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
  if (!isProgrammatic && !isInitialLoad) {
    // A real upward gesture is fresh intent to read history — reset the
    // refill auto-chain budget so the next commits may chain again.
    if (deltaTop < 0) prefetchAutoChain = 0
    // ARM as early as the geometry allows (fetch into the buffer, invisibly)…
    evaluateOlderPrefetch()
    // …and COMMIT the moment the user is inside the scroller's own load-more band, instead of
    // waiting out the 200 ms `@load-more` backstop. `maybeLoadOlder` re-runs every guard and claims
    // the buffer synchronously, so this cannot double-commit with the backstop.
    const band = virtualScrollerRef.value?.effectiveLoadMoreThreshold ?? 200
    if (bufferedOlderPage && distanceFromTop < band) void maybeLoadOlder('edge')
  }

  // ── State transitions are loud ───────────────────────────────────── This is the most useful
  // line in the whole logger.
  if (newIsAtBottom !== previousIsAtBottom) {
    scrollLogger.info({
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
    scrollLogger.info({
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
    scrollLogger.info({
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
  logger: () => scrollLogger,
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
    lastObservedScrollHeight = virtualScrollerRef.value?.containerRef?.scrollHeight ?? 0

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
    const snapshotStartVersion = streamContentVersion
    try {
      const snap = await api.getStreamSnapshot(sessionId.value)
      if (
        snap.active &&
        snap.content &&
        streamContentVersion === snapshotStartVersion &&
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
// window-level listener this view owns.
window.addEventListener('message', onHtmlFrameResize)

// Session-change entry point (replaces the two old sessionId watchers). The component is keyed per
// chat, so the id is fixed for the component lifetime — this runs once from onMounted below.
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
    if (isInitialLoad) return // initial-load branch handled scroll explicitly
    if (!isAtBottom.value) return // don't disturb scrolled-up readers
    scrollLogger.markProgrammatic()
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
    gitStatusCwd = ''
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

// eslint-disable-next-line @typescript-eslint/no-unused-vars -- kept for diff readability.
const formatTime = (date: Date) => {
  if (!date || isNaN(date.getTime())) return ''
  return date.toLocaleTimeString([], { hour: '2-digit', minute: '2-digit' })
}

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
                              :style="{ backgroundColor: 'var(--color-violet)', color: '#181616' }"
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
