<script setup lang="ts">
import {
  ref,
  reactive,
  onMounted,
  onUnmounted,
  onUpdated,
  nextTick,
  computed,
  inject,
  type Ref,
} from 'vue'
import { marked } from 'marked'
import * as api from '../../api'
import { chatEngineDb, newestCursor, toChatMessage } from '../../sync/ChatEngineDb'
import { runSyncEffect, runSyncEffectOr, runSyncVoid } from '../../sync/runtime'
import { useChatScrollRestore } from '../../composables/useChatScrollRestore'
import {
  stripThinkingTags,
  isHtmlTags,
  VirtualScroller,
  renderResponse,
  CHAT_HTML_FRAME_RESIZE_SOURCE,
  autoResizeScript,
  growFrameToContent,
  FRAME_NO_SCROLLBAR_STYLE,
  findSenderFrame,
  readAutoResizeHeight,
  formatCompactTokens,
} from '@/helpers'
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
import { installSseBus, useSseBus } from '../../helpers/sseBus'
import { readGitStatusCache } from '../../helpers/gitStatusCache'
import { splitMediaUrlsWire } from '../../helpers/mediaUrls'
import { Effect } from 'effect'
import { runEffectExit } from '../../helpers/effectRuntime'
import {
  fetchInitialHistoryWithRetry,
  INITIAL_HISTORY_TIMEOUT_MS,
} from '../../helpers/chatHistoryRetry'
import { ChatHistoryError } from '../../api'
import { tryUnwrapToolOutput, type UnwrappedToolOutput } from '@/helpers/unwrapToolOutput'
import {
  isBackgroundCommandOutput,
  parseBackgroundCommandOutput,
  backgroundToShellXml,
} from '@/helpers/isBackgroundCommandOutput'
import {
  applyProgressEvent,
  applySnapshotRows,
  clearProgressFor,
  isPlaceholderSpawnRow,
  type SubAgentProgressEvent,
  type SubAgentProgressMap,
} from '../../helpers/subagentProgress'
import AskUser from '../tool_outputs/AskUser.vue'
import DiffView from '../tool_outputs/_shared/DiffView.vue'
import ReadFile from '../tool_outputs/ReadFile.vue'
import WriteFile from '../tool_outputs/WriteFile.vue'
import UpdateActivity from '../preview/UpdateActivity.vue'
import Search from '../tool_outputs/Search.vue'
import Glob from '../preview/Glob.vue'
import TextReplace from '../tool_outputs/TextReplace.vue'
// eslint-disable-next-line @typescript-eslint/no-unused-vars -- used in <template> as <Bash> (~line 2507); typescript-eslint doesn't always see template usages via the Vue parser
import Bash from '../preview/Bash.vue'
import ShellTool from '../preview/ShellTool.vue'
import UseSkill from '../preview/UseSkill.vue'
import SearchSkills from '../tool_outputs/SearchSkills.vue'
import AddSkill from '../tool_outputs/AddSkill.vue'
import EditSkill from '../tool_outputs/EditSkill.vue'
import RemoveSkill from '../tool_outputs/RemoveSkill.vue'
import RemoveFile from '../tool_outputs/RemoveFile.vue'
import SpawnSubAgent from '../tool_outputs/SpawnSubAgent.vue'
import GenerateImage from '../tool_outputs/GenerateImage.vue'
import WebSearch from '../tool_outputs/WebSearch.vue'
import ListSearchProviders from '../tool_outputs/ListSearchProviders.vue'
import SetGitWorktree from '../tool_outputs/SetGitWorktree.vue'
import ReadCompactedMessages from '../tool_outputs/ReadCompactedMessages.vue'
import KanbanMove from '../tool_outputs/KanbanMove.vue'
import KanbanList from '../tool_outputs/KanbanList.vue'
import ListDirectory from '../tool_outputs/ListDirectory.vue'
import SaveMemory from '../tool_outputs/SaveMemory.vue'
import LoadMemory from '../tool_outputs/LoadMemory.vue'
import UpdatePlan from '../tool_outputs/UpdatePlan.vue'
import GetPlan from '../tool_outputs/GetPlan.vue'
import ListSubAgent from '../tool_outputs/ListSubAgent.vue'
import UsedTools from '../tool_outputs/UsedTools.vue'
import PresentFiles from '../tool_outputs/PresentFiles.vue'
import ReadWorkspaceSession from '../tool_outputs/ReadWorkspaceSession.vue'
import McpTool from '../tool_outputs/McpTool.vue'
import ProgressiveTool from '../tool_outputs/ProgressiveTool.vue'
import SubAgentPeekHost from '../pabrik/SubAgentPeekHost.vue'
import ChatRightSidebar from './chat_right_sidebar/ChatRightSidebar.vue'
import ChatAppBar from './ChatAppBar.vue'
import WorkerElapsedChip from '../WorkerElapsedChip.vue'
import CenterDiffSection from './chat_right_sidebar/CenterDiffSection.vue'
import { copyTextToClipboard } from './chat_right_sidebar/DiffCommentBox.vue'
import {
  centerDiffSectionId,
  encodePathParam,
  scrollToSectionElement,
} from './chat_right_sidebar/parseUnifiedDiff'
import type { DiffSelection } from './chat_right_sidebar/parseUnifiedDiff'
import { useChatRightSidebar } from './chat_right_sidebar/useChatRightSidebar'
import { useNavigationStore } from '../../stores/navigation'
import { useAgentErrorStore } from '../../stores/agentError'
import type { AgentErrorEntry } from '../../stores/agentError'
import { useInjectCodeViewer, useInjectOpenInCodeEditor } from '@/composables/useCodeEditor'
import type { CodeViewerView } from '@/composables/useCodeEditor'
import CodeViewerStage from './CodeViewerStage.vue'
import { useRouter, useRoute } from 'vue-router'
import type { LocationQueryRaw } from 'vue-router'
import { useWorkspacesStore } from '../../stores/workspaces'
import { buildAppUrl } from '../../helpers/appUrl'
import CompactionCard from '../preview/CompactionCard.vue'
// 2026-08-25 agent-error-card (task_1787663566535_2): dedicated renderer
// for agentic-loop error/retry diagnostics (is_error=true SSE events).
import AgentErrorCard from '../chat/AgentErrorCard.vue'
import ChatAttachments from '../chat/ChatAttachments.vue'
import UserPillRail, { type UserPill } from '../chat/UserPillRail.vue'
import ChatScrollSlider from '../chat/ChatScrollSlider.vue'
import { pickActivePillIndex, isPillGroup, estimateViewportEnd } from '../chat/activePill'
import SkillsPopup from '../preview/SkillsPopup.vue'
import BackgroundCommandsPopup from '../preview/BackgroundCommandsPopup.vue'
import ImagePreview from '../preview/ImagePreview.vue'
import WorktreeMenu from '../workspace/WorktreeMenu.vue'
import CreatePrDialog from '../dialogs/CreatePrDialog.vue'
import CreateWorktreeDialog from '../dialogs/CreateWorktreeDialog.vue'
import { parseSpawnSubAgentArgs } from '../../helpers/parseSpawnSubAgentArgs'
import type { SubAgentArgs } from '../../helpers/parseSpawnSubAgentArgs'
import { ICON_PATHS } from '../ui/icons'
import UiIcon from '../ui/UiIcon.vue'

const props = defineProps<{
  chatId: string
  chatName: string
  type?: 'chat' | 'task'
  cwd?: string
  /**
   * When true, render the shared chat app bar (ChatAppBar.vue —
   * chat name + `◫` sidebar toggle + `✕` close) above the
   * messages. Every task-chat host sets this so all three
   * workspace-item modes (kanban / agent / standard folder-chat)
   * get the identical bar; the standalone `chat-<id>` branch
   * leaves it false so a bare chat still fills the viewport
   * edge-to-edge.
   *
   * Defaults to `false` so older call sites that don't supply it
   * still compile — see the pabrik-frontend-task-literal-typing-rule
   * memory for the broader pattern.
   */
  showHeader?: boolean
  /**
   * Embedded mode for SubAgentPeekPanel: hides ChatView's own header
   * (the peek panel renders its own agent-name/status header above).
   * ChatView still owns fetch + SSE for `chatId` — the panel only
   * provides the slide-over chrome around it.
   *
   * Defaults to `false` so all existing call sites are unaffected.
   */
  embedded?: boolean
  /**
   * Hide the composer footer (FileInput + Compact/profile/tokens
   * status bar). The peek panel passes this so the sub-agent view is
   * read-only — sending messages into a sub-agent session from the
   * peek would fork its tool loop mid-run.
   *
   * Defaults to `false` so all existing call sites are unaffected.
   */
  hideInput?: boolean
}>()

const emit = defineEmits<{
  'update-chat-id': [oldId: string, newId: string]
  /**
   * Emitted when the user clicks the ✕ close button in the chat
   * header. The host (AppLayout) handles this by clearing the
   * active task and (optionally) navigating back to the kanban /
   * workspace view. The ChatView itself does NOT call router
   * directly — it just announces "user wants me gone" — so the
   * layout composition (e.g. sidebar | kanban | chatview) stays
   * the host's concern.
   */
  close: []
}>()

// Check if session is pending (needs creation on first message)
const isPendingSession = computed(() => props.chatId.startsWith('pending-'))

interface Message {
  id: string
  role: 'user' | 'assistant' | 'system' | 'tool'
  content: string
  timestamp: Date
  tool_name?: string
  diffview_before?: string
  diffview_after?: string
  image_urls?: string[]
  video_urls?: string[]
  tool_calls_json?: string
  finish_reason?: string
  tool_call_id?: string
  /**
   * JSON-stringified tool input arguments. Populated
   * by the same `tryUnwrapToolOutput` pipeline that fills
   * `unwrappedByMessageId`. Used by cards like `PresentFiles`
   * (`parameters` passthrough) without re-fetching.
   */
  parameters?: string
  is_input?: boolean
  is_output?: boolean
  /**
   * 2026-08-23 hidden-messages fix — thinking models' chain-of-thought
   * returned by the LLM and stored in `llm_history.reasoning_content`.
   * Populated by loadChatHistory (REST) and the SSE `full` handler.
   * Rendered as a collapsible section in the assistant bubble; also
   * keeps reasoning-only turns alive in filteredMessages.
   */
  reasoning_content?: string
}

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

// NOTE (2026-08-27, task_1787761084050_0): renderResponse is no
// longer defined here — it was extracted to
// `src/apps/desktop/src/helpers/renderResponse.ts` and exported via
// `@/helpers` (imported at the top of this file). The extraction
// added module-scoped memoization (Map<string,string> keyed on
// `${role}|${tool_name}|${trimmed}`) so a long chat's many messages
// don't re-parse the same markdown on every Vue re-render. The
// previous in-Vue implementation ran `marked.parse` synchronously
// inside v-html — O(visible_messages × renders_per_second) parse
// calls per second during SSE streaming. Memoization collapses that
// to O(unique_messages) per content mutation.

// ─── <html> wrapper-tag rendering (2026-08-23 html-tag-support) ────────────
// When the LLM wraps raw HTML in <html>...</html>, the chat UI renders
// each block as a live sandboxed iframe (null origin — the security
// boundary; inner scripts can't touch parent DOM/cookies). Mirrors the
// proven PreviewContentRenderer.vue pattern (sandbox="allow-scripts").

interface HtmlSegment {
  /** Text before this html block (markdown-rendered inline). */
  before: string
  /** Inner payload of the <html>...</html> block (goes into srcdoc). */
  html: string
}

/** True when the message contains at least one closed <html> block. */
const msgHasHtml = (content: string | undefined): boolean => {
  if (!content) return false
  return isHtmlTags(content) || /<html>[\s\S]*?<\/html>/i.test(content)
}

/**
 * Split a message into segments: for each closed <html>...</html> block,
 * one segment carrying (a) the markdown text preceding it and (b) the
 * block's inner HTML. Trailing text after the last block is attached to
 * a final segment with html=''. Unclosed tags mid-stream match nothing
 * and fall through to the legacy v-html path (raw text until close).
 */
const extractHtmlBlocks = (content: string): HtmlSegment[] => {
  const segments: HtmlSegment[] = []
  const regex = /<html>([\s\S]*?)<\/html>/gi
  let lastIndex = 0
  let match: RegExpExecArray | null
  while ((match = regex.exec(content)) !== null) {
    const before = content.slice(lastIndex, match.index)
    const inner = match[1] ?? ''
    if (before.trim() || segments.length === 0) {
      segments.push({ before: before.trim(), html: inner })
    } else {
      // Consecutive blocks: attach empty `before` to keep pairing.
      segments.push({ before: '', html: inner })
    }
    lastIndex = regex.lastIndex
  }
  const tail = content.slice(lastIndex).trim()
  if (tail || segments.length === 0) {
    segments.push({ before: tail, html: '' })
  }
  return segments
}

/**
 * The `<html>` frame is a separate document with a NULL origin, so the
 * app's CSS custom properties do NOT cascade into it — the theme values
 * have to be inlined into the srcdoc. Read them from the app's own tokens
 * (`src/style.css`) so the block always matches the surrounding transcript;
 * the literals below are the Kanagawa Dragon fallbacks for when there is no
 * DOM (vitest/jsdom, SSR) or a token is unavailable.
 */
interface HtmlFramePalette {
  bg: string
  fg: string
  muted: string
  border: string
  link: string
  /** Chip behind `code`/`pre`/table cells — matches the app's
   *  `.markdown-content pre` (`--color-bg-p1`). */
  chip: string
  /** Inline `code` ink — matches the app's `.markdown-content code`
   *  (`--color-aqua`). */
  codeInk: string
}

const HTML_FRAME_PALETTE_FALLBACK: HtmlFramePalette = {
  bg: '#1D1C19', // --semantic-card-bg
  fg: '#c5c9c5', // --semantic-text
  muted: '#a6a69c', // --semantic-text-muted
  border: '#282727', // --color-border
  link: '#8ba4b0', // --semantic-link
  chip: '#282727', // --color-bg-p1
  codeInk: '#8ea4a2', // --color-aqua
}

let htmlFramePalette: HtmlFramePalette | null = null

const readCssVar = (name: string, fallback: string): string => {
  if (typeof window === 'undefined' || typeof getComputedStyle !== 'function') return fallback
  const value = getComputedStyle(document.documentElement).getPropertyValue(name).trim()
  return value || fallback
}

/** Memoized — the theme is fixed for the app's lifetime and this runs for
 *  every `<html>` block on every assistant render. */
const resolveHtmlFramePalette = (): HtmlFramePalette => {
  if (htmlFramePalette) return htmlFramePalette
  const fallback = HTML_FRAME_PALETTE_FALLBACK
  htmlFramePalette = {
    bg: readCssVar('--semantic-card-bg', fallback.bg),
    fg: readCssVar('--semantic-text', fallback.fg),
    muted: readCssVar('--semantic-text-muted', fallback.muted),
    border: readCssVar('--color-border', fallback.border),
    link: readCssVar('--semantic-link', fallback.link),
    chip: readCssVar('--color-bg-p1', fallback.chip),
    codeInk: readCssVar('--color-aqua', fallback.codeInk),
  }
  return htmlFramePalette
}

/**
 * Build the srcdoc document for an html block.
 *
 * Full documents (`<!doctype html>` / `<html ...>`) pass through verbatim.
 * Fragments get a minimal shell carrying three things the fragment itself
 * cannot know:
 *   1. The app's THEME (see resolveHtmlFramePalette) — a hardcoded white
 *      body turned an LLM's HTML report into a bright slab in the dark
 *      transcript.
 *   2. `color-scheme: dark` — otherwise native scrollbars and form
 *      controls inside the frame render light.
 *   3. The auto-resize reporter (helpers/iframeAutoResize.ts) — the parent
 *      grows the frame to its content instead of clipping it behind an
 *      inner scrollbar at the browser's 150 px default height.
 *
 * Text SURFACES are forced with `!important`. The model authors this HTML
 * blind — it has no idea the transcript is dark, so it writes for a light
 * page (real payload: `style="background:#f6f8fa"` on every `<pre>`, GitHub's
 * light code chip). An inline style beats this stylesheet, which left the
 * frame's light ink on the payload's own light chip: measured 1.57:1
 * contrast, i.e. washed out. Forcing the chip + ink keeps every block
 * readable while leaving the rest of the payload's styling (layout, spans,
 * callout colours) alone.
 */
const buildHtmlSrcdoc = (block: string): string => {
  const trimmed = block.trim()
  if (/<!doctype html|<html[\s>]/i.test(trimmed)) {
    // Full documents pass through, but still get the no-scrollbar shell
    // + reporter so they grow to full height instead of clipping behind
    // the browser's 150px default with an inner scrollbar.
    const noScrollbar = `<style>${FRAME_NO_SCROLLBAR_STYLE}</style>`
    const reporter = autoResizeScript(CHAT_HTML_FRAME_RESIZE_SOURCE)
    if (/<\/body\s*>/i.test(trimmed)) {
      return trimmed.replace(/<\/body\s*>/i, `${noScrollbar}${reporter}</body>`)
    }
    return `${trimmed}${noScrollbar}${reporter}`
  }
  const p = resolveHtmlFramePalette()
  return (
    '<!DOCTYPE html><html><head><meta charset="utf-8">' +
    '<style>' +
    ':root{color-scheme:dark}' +
    'html,body{margin:0;padding:0}' +
    `body{font-family:system-ui,sans-serif;background:${p.bg};color:${p.fg};margin:8px}` +
    `a{color:${p.link}}` +
    'img{max-width:100%}' +
    `pre,code,th,td{background:${p.chip}!important;color:${p.fg}!important}` +
    'code{font-family:ui-monospace,"SF Mono",Menlo,monospace;padding:.1em .3em;border-radius:3px}' +
    `code{color:${p.codeInk}!important}` +
    'pre{font-family:ui-monospace,"SF Mono",Menlo,monospace;padding:.6em .8em;' +
    'border-radius:4px;overflow-x:auto}' +
    'pre code{background:transparent!important;padding:0}' +
    `pre code{color:${p.fg}!important}` +
    'table{border-collapse:collapse}' +
    `th,td{border:1px solid ${p.border};padding:4px 8px}` +
    `hr{border:none;border-top:1px solid ${p.border}}` +
    `blockquote{margin:.6em 0;padding-left:.8em;border-left:3px solid ${p.border};color:${p.muted}}` +
    FRAME_NO_SCROLLBAR_STYLE +
    '</style>' +
    '</head><body>' +
    trimmed +
    '</body>' +
    autoResizeScript(CHAT_HTML_FRAME_RESIZE_SOURCE) +
    '</html>'
  )
}

/**
 * The reporter script inside each frame posts its content height; grow the
 * frame that sent it to its FULL content height (no upper cap) so no inner
 * scrollbar ever appears — the outer chat scroller owns scrolling.
 * Identity-matching on `contentWindow` is the only handle a null-origin
 * sandbox leaves the parent (see helpers/iframeAutoResize.ts). Without
 * this a long `<html>` block renders at the browser's 150 px default
 * inside its own scrollbar.
 */
const onHtmlFrameResize = (event: MessageEvent): void => {
  const reported = readAutoResizeHeight(event, CHAT_HTML_FRAME_RESIZE_SOURCE)
  if (reported === null) return
  const frame = findSenderFrame(document, event, 'iframe.chat-html-frame')
  if (!frame) return
  frame.style.height = `${growFrameToContent(reported)}px`
}

// Detect a compaction summary message — a user-role message whose
// content is the `<compact_messages>` envelope written by
// `compactMessageInMemoryNew` (workflow.zig). Used by the user bubble
// to render the envelope as a structured `CompactionCard` instead of
// a wall of escaped XML.
//
// Detection is content-prefix based (rather than a dedicated DB field)
// because the existing API doesn't carry a `is_compaction` flag. A user
// who literally types "<compact_messages>" into chat would also match,
// but that's vanishingly unlikely; the compactor writes this exact
// prefix and no other message does.
const isCompactionMessage = (msg: { role: string; content: string } | undefined): boolean => {
  if (!msg) return false
  if (msg.role !== 'user') return false
  return msg.content.trimStart().startsWith('<compact_messages>')
}

// Session ID extracted from props on mount
const sessionId = ref('')

// Inject processingState from App.vue (driven by SSE - always up-to-date)
const processingState = inject<Ref<Record<string, boolean>>>('processingState', ref({}))

// LLM processing state - derived reactively from App.vue's processingState
const isLLMProcessing = computed(() => !!processingState.value[sessionId.value])

// Pagination state
const messageCursor = ref<string | null>(null)
// 2026-09-09 user-pill pagination fix: 1000 rows per page defeated
// pagination (slow TTFB with base64 image_urls + tool JSON, memory
// spike, VirtualScroller height-estimate blowup) — cut to 100 in #434,
// raised to 500, then back to 1000 per user request. Large pages risk
// the original TTFB/memory tradeoff; the load-more threshold still
// drives the rest for histories beyond one page.
const PAGE_SIZE = 1000

// ── Sub-agent peek ────────────────────────────────────────────────
// Owns the slide-over panel for watching a single sub-agent's
// progress. The composable is only mounted when `peekPanel` is
// non-null (lazy) so we don't open SSE channels speculatively.
//
// Two flows reach the panel:
//   1. 👁 click on a <SpawnSubAgent> row  →  SpawnSubAgent emits
//      `peek`  →  ChatView calls `nav.openPeek(payload)`. The
//      composable mounts on the next render.
//   2. "Open full" in the panel  →  panel emits `openFull(sid)`
//      →  ChatView closes the peek + navigates the URL to switch
//      the main chat view to the sub-agent's session.
const nav = useNavigationStore()
const router = useRouter()
const route = useRoute()

// Chat-owned git-diff sidebar (git-diff-only scope). ChatView passes
// its already-owned effectiveCwd + sessionId down, so each chat shows
// its own working tree without AppLayout-level cwd plumbing. Hidden in
// embedded/peek mode — the peek panel owns the right edge there.
const chatSidebar = useChatRightSidebar(props.type ?? 'chat')
const chatSidebarRef = ref<InstanceType<typeof ChatRightSidebar> | null>(null)
// Attached PR URL for the sidebar's PR-changes mode (set_pull_request
// tool). Empty = worktree-changes mode. Re-synced with the worktree
// binding so a mid-chat attach/clear flips the panel without reload.
const chatPrUrl = ref('')
const chatPrProvider = ref('')

// Persisted review comments (agnostic comment-box path). Saved to
// localStorage instead of sent to the LLM — the diff comment box owns
// per-line draft persistence; ChatView keeps the appended list (capped
// at 200 entries).
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

// Sidebar file-row click (or header Open button): open the file in the
// in-app code browser, which also updates the app URL (view=code-editor).
//
// Captured at setup: inject() only resolves against an active component
// instance, and a DOM event handler has none — calling it inside the
// handler returned undefined and made this a silent no-op. Null-guarded
// for mounts outside an AppLayout subtree (unit tests), where the click
// is legitimately a no-op.
const openInEditor = useInjectOpenInCodeEditor()
function onChatSidebarOpenFile(payload: { path: string; line?: number }) {
  if (!openInEditor || !effectiveCwd.value) return
  void openInEditor({ filePath: payload.path, cwd: effectiveCwd.value, line: payload.line })
}

// Stacked center diff: every changed file renders as its own
// lazily-mounted section so long lists scroll fast. centerDiff stays as
// the compat "current selection" (back-button + single-file wiring);
// centerFiles is the ordered render list, currentPath the most-visible
// section (scroll-spy + ?diff= deep link).
const centerDiff = ref<DiffSelection | null>(null)
const centerFiles = ref<DiffSelection[]>([])
const currentPath = ref<string | null>(null)
const centerDiffScrollRef = ref<HTMLElement | null>(null)

const showCenterDiff = computed(() => centerDiff.value !== null)

// ── Centre-diff view state: two axes, one owner ───────────────────────────
//   mode          — LAYOUT (unified | split). Global, so it lives in the URL
//                   (?diffmode=) with a localStorage fallback for "I always
//                   read split". A view switch must be linkable + survive
//                   refresh (house rule), hence the param and not a bare ref.
//   collapsedPaths / wholeFilePaths — SCOPE, per file. Session state like a
//                   scroll position: 40 stale per-file rows in the URL would
//                   be worse than a reset. Only the BULK collapse is mirrored
//                   into ?diffcollapse=1, so "show me just the file list" is
//                   still deep-linkable in one param.
const DIFF_MODE_STORAGE_KEY = 'pabrik.centerdiff.mode'

const readStoredDiffMode = (): 'unified' | 'split' => {
  try {
    const stored = localStorage.getItem(DIFF_MODE_STORAGE_KEY)
    if (stored === 'unified' || stored === 'split') return stored
  } catch {
    // No storage (private mode / jsdom) — the documented default stands.
  }
  return 'unified'
}

/**
 * Read `?diffmode=` at SETUP time, unlike `syncDiffParam` (a click handler).
 * That makes the read optional-router-safe: ~30 ChatView specs mount the
 * component with no router installed, where `useRoute()` is undefined and a
 * bare `route.query` throws inside setup, failing the whole mount. With no
 * router there is no URL to read, and no URL to keep in sync either — so the
 * default is the correct answer, not a swallowed error.
 */
const readDiffModeParam = (): 'unified' | 'split' | null => {
  const v = route?.query?.diffmode
  return v === 'unified' || v === 'split' ? v : null
}

const diffMode = ref<'unified' | 'split'>(readDiffModeParam() ?? readStoredDiffMode())
const collapsedPaths = reactive(new Set<string>())
const wholeFilePaths = reactive(new Set<string>())

const collapsedCount = computed(
  () => centerFiles.value.filter((f) => collapsedPaths.has(f.path)).length,
)
/** True when every listed file is collapsed — the state ?diffcollapse=1 names. */
const allCollapsed = computed(
  () => centerFiles.value.length > 0 && collapsedCount.value === centerFiles.value.length,
)

/**
 * Write one of the diff view's params, skipping stale writes during a chat
 * switch (the same guard `syncDiffParam` needs: ChatsList replaces the URL at
 * the same time, and a second replace from the dying view corrupts the patch).
 */
function syncDiffQuery(mutate: (query: LocationQueryRaw) => void) {
  // Same optional-router guard as `syncDiffParam`: a ChatView mounted outside
  // the router tree has no URL to write to.
  if (!route) return
  if (route.query.view !== undefined && route.query.view !== 'chat') return
  const routeSession = route.query.session
  if (typeof routeSession === 'string' && routeSession !== sessionId.value) return
  const query: LocationQueryRaw = { ...route.query }
  mutate(query)
  router.replace({ path: route.path, query }).catch(() => {})
}

const syncCollapseParam = () => {
  syncDiffQuery((query) => {
    if (allCollapsed.value) query.diffcollapse = '1'
    else delete query.diffcollapse
  })
}

/** Replace-all rather than per-file: the bulk button is one user gesture, and
 * `?diffcollapse=1` can only mean "all of them". */
function setAllCollapsed(collapsed: boolean, paths: DiffSelection[] = centerFiles.value) {
  collapsedPaths.clear()
  if (collapsed) for (const f of paths) collapsedPaths.add(f.path)
  syncCollapseParam()
}

function toggleCollapse(path: string) {
  if (collapsedPaths.has(path)) collapsedPaths.delete(path)
  else collapsedPaths.add(path)
  syncCollapseParam()
}

/**
 * Whole file is per section — 40 whole-file requests and a wall of text is
 * not what "show me this file" means. The untracked case is refused UP FRONT:
 * a new file's diff already IS the whole file, so the control stays locked at
 * "Whole file" and no request is ever made.
 */
function toggleWholeFile(path: string) {
  if (wholeFilePaths.has(path)) wholeFilePaths.delete(path)
  else wholeFilePaths.add(path)
}

function setDiffMode(next: 'unified' | 'split') {
  diffMode.value = next
  try {
    localStorage.setItem(DIFF_MODE_STORAGE_KEY, next)
  } catch {
    // Storage unavailable — the URL still carries the choice.
  }
  syncDiffQuery((query) => {
    query.diffmode = next
  })
}

/**
 * The code viewer's open file, shared by `AppLayout` (which owns the
 * session). Non-null ⇒ this chat renders the file in its center column,
 * exactly where the stacked center diff goes, so the chat-owned right
 * sidebar — the Explorer the user just clicked a file in — stays on
 * screen. `null` outside an AppLayout subtree (unit tests), which is the
 * pre-existing "no file open" state.
 *
 * The viewer wins over the diff stage: the diff's ⤴ button opens the
 * file, so both can be true for one click.
 */
const codeViewer = useInjectCodeViewer()
/**
 * Plain (never-null) view model for the template: the injected session
 * unwrapped, or an empty model when there is no provider (unit tests) /
 * no open file. One object, so the template needs no null-narrowing.
 */
const codeViewerModel = computed<CodeViewerView>(() => ({
  file: codeViewer?.file.value ?? null,
  content: codeViewer?.content.value ?? '',
  loading: codeViewer?.loading.value ?? false,
  error: codeViewer?.error.value ?? null,
  line: codeViewer?.requestedLine.value ?? null,
  cwd: codeViewer?.cwd.value ?? '',
  close: () => codeViewer?.close(),
}))
const showCodeViewer = computed(() => codeViewerModel.value.file !== null)
/** Messages + composer are hidden while either center stage is up. */
const showCenterStage = computed(() => showCenterDiff.value || showCodeViewer.value)

function scrollToCenterFile(path: string) {
  // Click on an already-loaded file scrolls instead of refetching.
  currentPath.value = path
  if (showCenterDiff.value) syncDiffParam(path)
  // Expand before scrolling: landing on a collapsed section would scroll to a
  // one-line stub and look like the click did nothing.
  if (collapsedPaths.has(path)) {
    collapsedPaths.delete(path)
    syncCollapseParam()
  }
  scrollToSectionElement(path)
}

function onChatSidebarShowDiff(selection: DiffSelection) {
  centerDiff.value = selection
  const idx = centerFiles.value.findIndex((f) => f.path === selection.path)
  if (idx >= 0) centerFiles.value[idx] = selection
  else {
    centerFiles.value.push(selection)
    syncCenterSpy()
  }
  void nextTick(() => scrollToCenterFile(selection.path))
}

function onChatSidebarShowDiffList(files: DiffSelection[]) {
  // Union by path, incoming list order wins — the panel just fetched
  // everything, so its entries are the freshest.
  const incoming = new Map(files.map((f) => [f.path, f]))
  const merged = [...files]
  for (const existing of centerFiles.value) {
    if (!incoming.has(existing.path)) merged.push(existing)
  }
  centerFiles.value = merged
  syncCenterSpy()
  // A file that arrived WHILE the bulk state was "all collapsed" must arrive
  // collapsed too, or the next poll would silently expand one row.
  if (allCollapsed.value) {
    for (const f of merged) collapsedPaths.add(f.path)
  }
  // Refresh an open selection in place when the list reloads, but never
  // auto-open from a background list load — refresh must land on chat.
  if (centerDiff.value) {
    const refresh = incoming.get(centerDiff.value.path)
    if (refresh) centerDiff.value = refresh
  }
}

function onCenterDiffBack() {
  centerDiff.value = null
  centerFiles.value = []
  syncCenterSpy()
  currentPath.value = null
  // Per-file view state dies with the stage, and the bulk param with it.
  collapsedPaths.clear()
  wholeFilePaths.clear()
  syncDiffQuery((query) => {
    delete query.diffcollapse
  })
  stopCenterSpy()
  // Back exits the diff view: drop the param so reload lands on chat,
  // not a stale file. The currentPath watcher skips while hidden, so
  // clear it explicitly here (replace, not push).
  syncDiffParam(null)
}

// Scroll-spy: the most-visible section (middle band of the center
// scroll container) owns currentPath, which syncs to ?diff= below.
let centerSpy: IntersectionObserver | null = null

function startCenterSpy() {
  stopCenterSpy()
  const root = centerDiffScrollRef.value
  if (!root || typeof IntersectionObserver === 'undefined') return
  centerSpy = new IntersectionObserver(
    (entries) => {
      // Ignore late callbacks after stop (chat switch unmounts the
      // scroll container mid-navigation; writing currentPath then
      // would fire a stale router.replace racing ChatsList).
      if (!centerSpy) return
      let best: string | null = null
      let bestRatio = 0
      for (const entry of entries) {
        const path = (entry.target as HTMLElement).dataset.path
        if (!entry.isIntersecting || !path) continue
        if (entry.intersectionRatio > bestRatio) {
          bestRatio = entry.intersectionRatio
          best = path
        }
      }
      if (best) {
        currentPath.value = best
        if (showCenterDiff.value) syncDiffParam(best)
      }
    },
    { root, rootMargin: '-40% 0px -55%', threshold: [0, 0.25, 0.5, 0.75, 1] },
  )
  for (const el of root.querySelectorAll('[data-testid="center-diff-section"]'))
    centerSpy.observe(el)
}

function stopCenterSpy() {
  centerSpy?.disconnect()
  centerSpy = null
}

function syncDiffParam(path: string | null) {
  // No router = nothing to keep in sync. Unit mounts (and any host that
  // renders ChatView outside the router tree) have `useRoute() === undefined`,
  // where a bare `route.query` throws from the currentPath watcher and fails
  // the mount. There is no URL to be stale in that case.
  if (!route) return
  // Skip stale writes during chat switch: ChatsList replaces the URL
  // with the new session at the same time; a second replace from the
  // dying view races it and corrupts Vue's patch (null vnode).
  if (route.query.view !== undefined && route.query.view !== 'chat') return
  const routeSession = route.query.session
  if (typeof routeSession === 'string' && routeSession !== sessionId.value) return
  const query = { ...route.query }
  if (path) query.diff = encodePathParam(path)
  else delete query.diff
  router.replace({ path: route.path, query }).catch(() => {})
}

// (The old currentPath watcher lived here — every assignment site below
// now calls syncDiffParam explicitly. Replace, not push — scrolling must
// not spam history entries.)

// Start/stop the scroll-spy to match the file list (replaces the old
// centerFiles.length watcher). Called explicitly after every assignment.
const syncCenterSpy = () => {
  if (centerFiles.value.length === 0) stopCenterSpy()
  else void nextTick(() => startCenterSpy())
}

function onCenterDiffRetry() {
  chatSidebarRef.value?.reloadDiff()
}

// Re-read the session's worktree binding from the backend. The binding
// is created/removed mid-chat by the LLM's set_git_worktree tool, so
// the mount-time value from loadChatHistory() goes stale — the sidebar
// (and git chip) would keep showing the session's original cwd (e.g.
// main) instead of the bound worktree. Uses the lightweight session
// detail endpoint (no message payload), not messages?limit=1.
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
  // Sidebar ↻ clicked: re-sync the binding FIRST (it may have changed
  // since mount), then reload the panel. The panel's cwd watcher
  // reloads automatically when the binding actually changed; the
  // explicit refresh covers the unchanged-cwd case.
  await refreshWorktreeBinding()
  chatSidebarRef.value?.refresh()
}

// 2026-09-04 subagent-peek P1 fix: the peek lifecycle lives in
// SubAgentPeekHost (setup scope, keyed by sessionId). Never call
// useSubAgentPeek inside a computed — lifecycle hooks registered during
// render are unreliable (fetch fired 0/N times → permanent empty panel).

/**
 * Handler for the panel's `openFull` event — closes the peek and
 * navigates to the sub-agent's own chat view in the main panel.
 */
function onPeekOpenFull(sessionId: string) {
  nav.closePeek()
  router.replace({ path: '/app', query: { view: 'chat', session: sessionId } })
}

/**
 * A `read_workspace_session` search hit pointed at a different conversation.
 * The card is presentation-only, so the navigation decision lives here.
 * Mirrors `ChatsList.setActive`: canonical path URL when a workspace is in
 * scope, legacy query form only as a fallback.
 */
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

// SSE connection. Both the `llm` and `queue` channels now flow
// through the global `sseBus` (opened once by App.vue). The bus's
// single global SseClient carries ALL 5 channels (including bare
// 'llm' and bare 'queue'). Listeners here filter by
// `event.session_id === sid` on the JS side — defense-in-depth
// against backend routing regressions. The same listener filter
// would also be needed in a future multi-tab scenario where
// multiple ChatViews share one EventSource.
const isStreaming = ref(false)
const streamingContent = ref('')
let streamContentVersion = 0

// Queue state
const queuedMessages = ref<api.QueuedMessage[]>([])

// Scroll refs
// We declare an explicit interface for the VirtualScroller instance because
// `InstanceType<typeof VirtualScroller>` doesn't resolve cleanly for a generic
// Vue SFC component (the compiler infers a function signature that doesn't
// satisfy Vue's component-ref constructor constraint).
//
// Note: `containerRef` and the `isX`/`effectiveX` refs are AUTO-UNWRAPPED
// by `defineExpose` — the exposed property is the ref's `.value`, not
// the ref object. The existing `handleVirtualScroll` reads
// `.containerRef.value` (double-unwrapped, which returns undefined);
// it falls back to the event `target` so the bug is invisible. The
// scroll-restore composable reads `.containerRef` directly.
interface VirtualScrollerExposed {
  scrollToIndex: (index: number, behavior?: ScrollBehavior) => void
  scrollToTop: (behavior?: ScrollBehavior) => void
  scrollToBottom: (behavior?: ScrollBehavior) => void
  /**
   * The scrollTop that counts as "the bottom" — the same number
   * `scrollToBottom` is about to use. `handleVirtualScroll` MUST measure
   * at-bottom against this rather than `scrollHeight - clientHeight`: when
   * the height model overshoots the real content, the DOM's max sits up to
   * `maxTailGap` (100px) BELOW the last message, so the DOM measure reports
   * a perfectly good auto-stick as "the user left the bottom" and disarms
   * every later stick for the rest of the mount.
   */
  bottomScrollTop: () => number
  /**
   * Where the bottom sat when the stick LAST acted (end of the last measure
   * pass, or the last `scrollToBottom`), or null before anything positioned
   * the list. A getter on the child, so it always reads live.
   *
   * `handleVirtualScroll` prefers this over a live `bottomScrollTop()` — see
   * `atBottomEdge` below for why the live read is a moving target.
   */
  readonly settledBottom?: number | null
  scrollToPosition: (scrollTop: number, behavior?: ScrollBehavior) => void
  scrollToItem: (index: number, behavior?: ScrollBehavior) => void
  /** Full height-model recompute from the live DOM (append-gap fix). */
  remeasure: () => void
  /** Transfer a stored height across an identity swap (shrink fix). */
  rekeyHeight: (oldKey: string, newKey: string) => boolean
  beginPreserve: (newItemsCount: number) => void
  endPreserve: () => Promise<void>
  preserveScrollPosition: () => Promise<void>
  containerRef: HTMLElement | null
  isPreservingScroll: boolean
  effectiveLoadMoreThreshold: number
  /** Topmost/bottommost rendered item indices (auto-unwrapped computed). */
  effectiveRange: { start: number; end: number }
  sizerHeight?: number
  modelTotal?: number
}
const virtualScrollerRef = ref<VirtualScrollerExposed | null>(null)

// Composer input ref — re-focus after the async mount chain (history +
// stream snapshot + queued messages) so the cursor lands in the box on
// every session switch, even if the child's own mount-focus raced the
// history render.
const fileInputRef = ref<{ focusInput?: () => void } | null>(null)

// Persist chat scroll position per-task across mount/unmount. The
// composable attaches its own scroll/scrollend listeners to the
// VirtualScroller's container ref (via the computed `scrollerContainerRef`
// below) and flushes pending writes on unmount. The storage key is
// `chat-scroll-<taskId>` — same identity as the session id per the
// project's task.id == session.id convention (migration 052).
//
// Note: `virtualScrollerRef.value.containerRef` is the HTMLElement
// directly (NOT a ref object), because `defineExpose` in
// VirtualScroller.vue auto-unwraps refs. The existing code in
// `handleVirtualScroll` reads `.containerRef.value` (double-unwrapped),
// which silently returns undefined — the code falls back to the
// event `target` so the bug is invisible. Don't copy that pattern.
const scrollerContainerRef = computed<HTMLElement | null>(
  () => virtualScrollerRef.value?.containerRef ?? null,
)
// Stable accessor for ChatScrollSlider: the scroller's containerRef
// resolves after mount and swaps on chat switch, so the slider takes
// a function (re-resolved on its interval) instead of a raw element.
const getChatScrollContainer = (): HTMLElement | null => scrollerContainerRef.value
const chatScrollStorageKey = computed(() => `chat-scroll-${sessionId.value || props.chatId}`)
// The restore composable's "is the saved position still at the bottom?" test
// has to use the SAME bottom edge the auto-stick uses, or a position saved
// while the reader sat on the last message (which lives at the real content
// bottom, up to `maxTailGap` above the DOM edge) reads as "scrolled up" and
// gets restored verbatim.
const chatScrollRestore = useChatScrollRestore(
  scrollerContainerRef,
  chatScrollStorageKey,
  (el) => virtualScrollerRef.value?.bottomScrollTop?.() ?? el.scrollHeight - el.clientHeight,
)

// Guard flag for the messages-length watcher's auto-stick. During
// the initial load, the loadChatHistory branch handles the scroll
// explicitly (either restore a saved position via scrollToPosition
// or land at the bottom via scrollToBottom). Without this guard,
// the watcher would yank the user back to the bottom immediately
// after the restore — defeating the feature.
let isInitialLoad = false

// Ref to the outer flex wrapper around the VirtualScroller. The logger
// reads this so it can report "did the layout chain reach the
// scroller's parent?" — without it, a 0×0 VirtualScroller could mean
// either "the wrapper isn't sized" (layout bug higher up) or "the
// wrapper is sized but the scroller isn't" (the `flex flex-col` bug
// the recent fix addressed). The two cases need different fixes; the
// logger needs the wrapper's dimensions to tell them apart.
const messagesWrapperRef = ref<HTMLElement | null>(null)

// ─── Floating composer: the `--chat-composer-inset` contract ────────────────
//
// The composer dock is `position: absolute` on the chat column, so the
// transcript scrolls *under* it. Four things need to know how tall that dock
// is, and none of them can be a reactive ref: the textarea autogrows on every
// input event, and a reactive dep read in the render function would re-run
// ChatView's whole (very large) render on every keystroke.
//
// So the height is written straight to the DOM as a CSS custom property on
// the chat column, and everything reads it in CSS:
//   - `.composer-scrim`         — the fade's own extent
//   - `.last-transcript-row`    — bottom padding on the newest message, so it
//                                 can always be scrolled clear of the dock
//   - `.chat-scroll-to-bottom`  — keeps the arrow above the dock
//   - `.chat-scroll-slider`     — (in ChatScrollSlider) keeps the track
//                                 reachable when the viewport is narrow
// Because it is plain CSS padding, VirtualScroller's `measureItems()` picks
// the clearance up through `el.offsetHeight` for free — the sizer grows, and
// its `scrollToBottom` (`realBottom = topSpacer + contentH`) lands on the
// padded bottom, so auto-stick keeps the last message visible with no change
// to the scroller's height model.

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

// True for the newest transcript group only. Pads that ONE row so the final
// message scrolls clear of the floating composer. Index-based on purpose:
// `:last-child` would pad whichever row the virtual window happens to end
// on, which is a mid-transcript row whenever the window does not cover the
// tail (leaving a ~150px hole in the middle of the conversation).
const isLastGroup = (index: number) => index === messageGroups.value.length - 1

// Timestamp (ms since epoch) of the most recent auto-stick assignment.
// Set at every site that programmatically writes `container.scrollTop`
// to keep the chat pinned to the bottom — the SSE chunk handler, the
// messages-length watcher, the SSE `full` event handler, and
// `onSpacersResized`. `handleLoadMore` consults this (via
// `isAutoStickActive`) to decide whether a prepend right now would
// fight an active stick. See `helpers/autoStickGate.ts` for the
// gating math.
//
// Starts at 0, which the gate treats as "never fired" — so the very
// first `loadMore` after mount isn't blocked.
const lastAutoStickAt = ref(0)

// contentShift handler (P2, task_1787551495337_9) — replaces the old
// spacer MutationObserver. VirtualScroller now positions its window with
// `translate3d` inside a sizer div (no spacer `style.height` mutations
// left to observe), so it emits an explicit `contentShift` event whenever
// the virtual layout's geometry changes. Whenever that happens — which is
// asynchronously after VirtualScroller measures real item heights
// (~50-100ms after mount, and again whenever new items scroll into view)
// — we re-stick to the bottom IF the user was at bottom. This is
// "stick-to-bottom" behavior and naturally handles both the initial-load
// measurement drift and the chain-reaction where measuring one batch of
// items reveals more items that get measured too. Once the user scrolls
// up, isAtBottom flips to false and we stop fighting them.
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
    // ── Fix: only stick on GROWTH, not shrink (2026-09-02) ──────────
    // Shrinking is the sizer clamp itself (modelTotal -> realTotal),
    // not new content. Sticking on shrink causes the down-clamp loop:
    // sizer 22163 -> stick to 21007 -> sizer 21788 -> stick to 20632
    // -> sizer 20433 -> stick to 19277 -> sizer jumps back to 22163
    // (because at 19277 range no longer includes last item) -> gap.
    // Also ignore tiny deltas (<50px) which are sub-pixel noise.
    if (delta <= 0 || Math.abs(delta) < 50) {
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
    // We are going to assign scrollTop. Mark the next scroll event as
    // programmatic BEFORE the assignment so the browser-fired scroll
    // reads origin='programmatic' in handleVirtualScroll. This is the
    // critical bit: without it, a stick-to-bottom action looks identical
    // to a user scroll in the logs.
    scrollLogger.markProgrammatic()
    // Record the auto-stick timestamp so the loadMore gate knows the
    // stick is actively engaged right now (not just that the LLM is
    // busy — those are different things, see autoStickGate.ts).
    lastAutoStickAt.value = Date.now()
    // Explicit bottom computation — DELEGATED to the scroller's
    // scrollToBottom (2026-08-26 blank-viewport fix): the scroller
    // targets the REAL rendered content bottom when the window shows
    // the last item, so a residual sizer overshoot can no longer land
    // the stick in the phantom region (the user's fully-blank
    // viewport screenshots: sizer 29389px, window at 27971px, nothing
    // visible). The old inline `scrollHeight - clientHeight` trusted
    // the model total; the scroller's version falls back to it only
    // when the model agrees with reality.
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
// Ready-gate: true while the initial mount fetch is outstanding (or the
// session id hasn't been assigned yet). Drives the initializing skeleton
// + composer disable. Deliberately NOT gated on SSE, git status, stream
// snapshot, or queued messages — all best-effort/late by design, and
// waiting on them would wedge the composer disabled after the chat is
// already usable. Pending drafts (`pending-*`) skip history fetch by
// design, so they count as ready immediately.
const isInitializing = computed(
  () =>
    !isPendingSession.value &&
    (!sessionId.value || (isLoading.value && messages.value.length === 0)),
)
const hasMoreMessages = ref(true)
const isAtBottom = ref(true)
// "The server has answered, and the answer was: zero messages."
//
// The empty state must be gated on this, not on `messageGroups.length === 0`
// alone. Before it existed, ANY state that wasn't actively loading — a failed
// fetch, a mid-retry window, a not-yet-assigned session — rendered
// "How can I help you?" for sessions with hundreds of messages. The
// distinction that matters to the reader is "empty" vs "not known yet", and
// only a completed load can tell us which one we are looking at.
//
// Reset to false at the start of every load and set true only when an attempt
// completes without throwing.
const historyConfirmed = ref(false)

// File previews render inline inside the chat bubble
// (see PresentFiles.vue + PreviewContentRenderer.vue). There is no
// side panel — wide HTML content offers an "Open in new tab"
// action instead.
// Whether the VirtualScroller's container is currently scrollable
// (`scrollHeight > clientHeight`). When the container IS scrollable,
// the user can scroll to the top to trigger loadMore via the
// VirtualScroller's `@load-more` event — so the "Load more messages"
// button hides and avoids UI clutter. When the container is NOT
// scrollable (the common short-chat case in the screenshot in
// docs/plans/2026-06-04-chat-lazy-load-button.md), the user has no
// scroll-driven path, so the button is the only way to reach older
// messages.
//
// Updated by the VirtualScroller via the `@scrollability-change`
// event (not read through the template ref). The event pattern is
// used because component-instance proxies do not establish reactive
// dependencies on inner ref values when accessed through
// `childRef.value.someRef.value` — a parent `computed` reading
// that chain would not re-evaluate when the child's value changes.
// With the event, this is a plain `ref<boolean>` that the template
// can react to via standard Vue reactivity. Defaults to `false` so
// the initial-render 0×0 flicker shows the affordance; the
// VirtualScroller's watch with `immediate: true` fires the event
// synchronously during setup, overwriting this default with the
// real value before the first render.
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
// Branch for the right sidebar. The bottom status bar's `gitStatus` is
// the single source of truth — the sidebar used to fetch its own branch
// via getGitChanges, and the two concurrent fetches raced on worktree
// switches (sidebar showing stale 'main' while the bottom chip already
// followed the worktree). `undefined` while loading so the sidebar
// falls back to its own fetched branch instead of flashing 'detached'.
const sidebarBranch = computed(() =>
  gitStatus.value ? gitStatus.value.branch || 'detached' : undefined,
)
const maxTotalTokens = ref(0)
const maxCapacityTotalTokens = ref(200000)

// ─── Profile selection ────────────────────────────────────────────────────────
// Per-session model selection. The chip in the status bar shows the EFFECTIVE
// profile (per-session `selected_profile_model` → `config.active_profile` →
// top-level default) and lets the user pick a profile from the list in
// PabrikConfig. Per-session selection is persisted via PUT
// /api/llm/session/:id and forwarded to the next LLM call via POST
// /api/llm/session. The chip mirrors the backend cascade in
// `workflow.zig::resolveProfileField` so the user sees the same name that's
// actually applied.
const availableProfiles = ref<Array<{ name: string; model: string; base_url: string }>>([])
const selectedProfile = ref<string | null>(null)
/// User-chosen default profile from PabrikSettings → Profiles → "Set active".
/// `null` when no profile is marked active (or no profiles configured). The
/// chatview shows this as the chip's effective selection when no per-session
/// override is set. See plan docs/superpowers/plans/2026-08-06-chatview-profile-cascade-display.md.
const activeProfile = ref<string | null>(null)
const showProfilePicker = ref(false)
const isUpdatingProfile = ref(false)
const profilePickerRef = ref<HTMLElement | null>(null)

const loadProfiles = async () => {
  try {
    const config = await api.getPabrikConfig()
    const profiles = (config.profiles ?? {}) as Record<
      string,
      { model?: string; base_url?: string }
    >
    availableProfiles.value = Object.entries(profiles).map(([name, p]) => ({
      name,
      model: p.model ?? '',
      base_url: p.base_url ?? '',
    }))
    // `active_profile` is the user-chosen default from PabrikSettings. Empty
    // string → null (matches the backend's PUT coercion in
    // `pabrik_config_put.zig`).
    const raw = (config as { active_profile?: string | null }).active_profile
    activeProfile.value = raw && raw.length > 0 ? raw : null
  } catch (err) {
    console.error('Failed to load profiles:', err)
    availableProfiles.value = []
    activeProfile.value = null
  }
}

/// Effective profile the chip / picker reflect — mirrors the backend cascade
/// in `workflow.zig::resolveProfileField`. `selectedProfile` wins; if the
/// user has not picked one for this session, `activeProfile` (the
/// PabrikSettings "Set active" default) applies; otherwise the chip shows
/// "Default" and the backend uses the top-level config.
///
/// NOTE: we use `||` (not `??`) so an empty string from the session's
/// `selected_profile_model` falls through to the active profile. `??` only
/// catches `null` / `undefined`, but the per-session value arrives as `""`
/// (empty string) when the user never picked one — see
/// `api.getSession.selectedProfile` which returns the raw string. Falling
/// through `||` makes the empty-string case match the cascade.
const effectiveProfile = computed<string | null>(() => {
  const sel = selectedProfile.value
  if (sel && sel.length > 0) return sel
  return activeProfile.value
})

/// Tooltip text reflecting what the backend will actually use. Distinguishes
/// "explicit per-session choice" from "defaulted to active profile" so the
/// user understands the cascade.
const profileChipTooltip = computed(() => {
  const sel = selectedProfile.value
  if (sel && sel.length > 0) return `Using profile: ${sel}`
  if (activeProfile.value) return `Using active profile: ${activeProfile.value}`
  return 'Using default (top-level config)'
})

const selectProfile = async (name: string | null) => {
  if (isUpdatingProfile.value) return
  isUpdatingProfile.value = true
  try {
    const sid = sessionId.value
    if (sid) {
      await api.updateSession(sid, { selectedProfile: name })
    }
    selectedProfile.value = name
  } catch (err) {
    console.error('Failed to update profile:', err)
  } finally {
    isUpdatingProfile.value = false
    showProfilePicker.value = false
  }
}

const closeOnOutsideClick = (e: MouseEvent) => {
  if (profilePickerRef.value && !profilePickerRef.value.contains(e.target as Node)) {
    showProfilePicker.value = false
  }
}

// ─── Worktree dropdown + PR dialog ────────────────────────────────────────────
// The chat status bar's git branch indicator becomes a clickable button
// when a worktree is bound (`gitWorktreeCwd` is non-empty). Clicking
// opens a small dropdown (WorktreeMenu) with three actions: Create a
// PR, View in folder, Clear worktree. Create a PR opens the
// CreatePrDialog modal; Clear worktree asks the LLM to call
// `set_git_worktree(clear=true)` (LLM-mediated so the cleanup
// re-uses the existing tool path — see plan design decision #5).
const showWorktreeMenu = ref(false)
const worktreeMenuRef = ref<HTMLElement | null>(null)
const showCreatePrDialog = ref(false)
const showCreateWorktreeDialog = ref(false)

const onWorktreeMenuCreatePr = () => {
  showCreatePrDialog.value = true
}

const onWorktreeMenuCreateWorktree = () => {
  showCreateWorktreeDialog.value = true
}

const onWorktreeMenuViewFolder = () => {
  // Open the worktree path (or session cwd if no worktree) in the
  // system file manager. Implementation: use the existing
  // /api/system/folder?path=<worktree> to confirm the directory is
  // accessible, then emit a window event that the right-sidebar file
  // explorer subscribes to. For v1, the simplest implementation is
  // to copy the path to the clipboard and show a toast — see
  // ChatsList.vue for the clipboard pattern.
  const path = gitWorktreeCwd.value || sessionCwd.value
  navigator.clipboard.writeText(path)
  // TODO: open a folder-explorer modal in a follow-up
}

const onWorktreeMenuRefresh = () => {
  // Re-fetch git status from the backend so the chip shows the latest
  // state immediately (instead of waiting for the next poll tick).
  checkGitStatus()
}

const onWorktreeMenuClear = async () => {
  // Send a system message to the LLM asking it to clear the worktree.
  // The LLM calls set_git_worktree(clear=true), which removes the
  // directory and clears the binding. The SSE event updates the UI.
  // Uses sessionCwd.value (the session's ORIGINAL cwd) so the LLM's context
  // matches the session it was started from.
  if (!sessionId.value) return
  try {
    await api.sendChatMessage(
      sessionId.value,
      'Please call set_git_worktree with clear=true to remove the current worktree binding.',
      sessionCwd.value,
      [],
      selectedProfile.value ?? undefined,
    )
  } catch (err) {
    console.error('Failed to send clear-worktree message:', err)
  }
}

const onPrCreated = (url: string) => {
  showCreatePrDialog.value = false
  // Show a brief toast (use the existing notification pattern)
  // For v1, just open the PR URL in a new tab
  window.open(url, '_blank')
}

const onPrError = (message: string) => {
  console.error('PR creation failed:', message)
  // Show a toast with the error
  // For v1, just log — the dialog stays open with the form intact
}

const onCreateWorktree = async (path: string) => {
  if (!sessionId.value) return
  if (!sessionCwd.value) {
    console.error('Create worktree: no session cwd available')
    showCreateWorktreeDialog.value = false
    return
  }
  // The dialog passes the user's absolute path verbatim. The LLM calls
  // set_git_worktree(path=<path>) which validates (must be absolute, no
  // .., basename matches [A-Za-z0-9._-]{1,100}) and runs git worktree
  // add. The branch is auto-derived as worktree/<basename(path)>.
  const message = `Please call set_git_worktree with path=${path} to create a new worktree for me.`
  try {
    await api.sendChatMessage(
      sessionId.value,
      message,
      sessionCwd.value,
      [],
      selectedProfile.value ?? undefined,
    )
  } catch (err) {
    console.error('Failed to send create-worktree message:', err)
  }
  showCreateWorktreeDialog.value = false
}

// ─── Scroll logger ────────────────────────────────────────────────────────────
//
// A dedicated logger for the scroll subsystem. Bound to the active chat
// so every line is tagged with chatId. Recreated when sessionId changes
// so the log context is never stale. See helpers/scrollLogger.ts for
// what fields every line carries and why.
let scrollLogger: ScrollLogger = createScrollLogger(props.chatId)
const refreshScrollLogger = () => {
  scrollLogger = createScrollLogger(sessionId.value || props.chatId)
}

// Session skills state
const sessionSkills = ref<api.SkillInfo[]>([])
const showSkillsPopup = ref(false)

// Track which tool items are expanded.
//
// 2026-08-23 auto-collapse fix — keys are STABLE per-message ids, NOT
// positional `${groupIndex}-${idx}` pairs. Positional keys broke the
// moment any SSE event mutated `messages`: messageGroups recomputes,
// group/message indices shift (a new assistant row inserts a group
// before the tool rows; dedupe/hidden-row filtering changes counts),
// and every stored key silently started pointing at a DIFFERENT card.
// The user's manually-expanded card lost its key → collapsed itself;
// worse, an unrelated card could render pre-expanded. Message ids are
// stable across re-computation (DB nanos from REST history, or the
// synthetic-but-consistent ids minted by the SSE handler), so
// expansion survives any number of live updates.
const expandedToolIds = ref<Set<string>>(new Set())

// 2026-08-23 spawn-subagent-live-progress: per-tool_call_id map of
// sub-agent progress rows. Fed by role="subagent_progress" SSE events
// on the existing `llm` bus channel (no new event_type). The map
// entry is cleared once the parent's final <results> tool result
// arrives so the parsed-envelope view takes over rendering.
const subAgentProgressMap = ref<SubAgentProgressMap>({})

// 2026-08-25 agent-error-card (task_1787663566535_2): live-only list of
// agentic-loop error/retry diagnostics. Fed by `full` SSE events with
// is_error=true (workflow.zig's 3 diagnostic sites — never persisted,
// is_skip_db=true). Rendered OUTSIDE the VirtualScroller (below it) so
// the scroller's height-estimate model never sees these rows; state
// lives in the agentError store (keyed by session_id) so the card
// survives ChatView remounts on session switches.
//
// 2026-08-25 task_1787668954023_2: SINGLE-LATEST semantics — only the most
// recent error is rendered. New error events overwrite the previous entry
// (status of a retry chain progressing: 1/10 → 2/10 → ... → final 10/10
// bail, all on the same card). This avoids the pile-up you see in the
// screenshot. The card is also cleared as soon as ANY non-error `full`
// SSE event arrives for this session (handled in the SSE listener below)
/// — meaning the moment the agent recovers, the error card disappears.
//
// 2026-08-29 agent-error-persistent: state moved into the
// `useAgentErrorStore` Pinia store so the card survives
// AppLayout's `:key="activeChatId"` remounts on sidebar
// navigation. The interface now lives in the store module;
// here we read the per-session entry via a computed.
const agentErrorStore = useAgentErrorStore()
// Per-session derived read. Reads from the store (keyed by
// sessionId) so the card survives ChatView remounts caused by
// AppLayout's :key="activeChatId" or StandardTaskChatView's
// :key="chat-${task.id}" on session/task switches. A user
// visiting session A, switching to session B, then returning to
// session A still sees the most recent error diagnostic for A.
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

// Stable expand-state key for a tool message. Falls back through:
//   1. msg.id (DB nanos id or SSE-minted synthetic id — always present)
//   2. tool_call_id (stable across the whole turn)
//   3. positional `${groupIndex}-${idx}` — last resort for legacy rows
//      with no id at all; better than nothing, same behaviour as before.
const toolExpandKey = (msg: Message, groupIndex: number, idx: number): string => {
  return msg.id || msg.tool_call_id || `pos-${groupIndex}-${idx}`
}

// Code-editor wiring for the fallback `<DiffView>` rendered for tools that
// don't have a dedicated component (e.g. legacy tools). When the user clicks
// a line number in the fallback diff we forward to the in-app editor — but
// only when we know the target file path. We don't have a stable path here
// (the fallback is rendered for any tool with diffview_*), so we silently
// no-op when the path is missing. Most tools with diff content now route
// through the dedicated `<TextReplace>` component (which knows the path);
// this fallback is for legacy/edge cases.
const fallbackOpenInEditor = useInjectOpenInCodeEditor()
const handleFallbackJumpToLine = (line: number) => {
  // No-op: we don't have a target file path in the fallback context.
  // The click affordance still works (hover/cursor change), but won't
  // open the editor. Hook retained for future enhancement when we add a
  // generic tool→path lookup.
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
  // Stale-response guard: the worktree binding can flip twice in quick
  // succession (session cwd → worktree A → worktree B). Without the seq
  // check, the slower fetch for A resolves last and the bottom chip
  // shows A's branch while the sidebar already follows B.
  const seq = ++gitStatusSeq
  const cwd = effectiveCwd.value
  // Cache-first paint: on init or a cwd switch, synchronously show the
  // last-known status from localStorage so the chip has a branch to
  // render while the remote fetch below revalidates it in the
  // background (stale-while-revalidate). Poll ticks for the same cwd
  // skip this — their in-memory value is newer than the cache.
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

// Filter out empty messages for display (check stripped content).
//
// 2026-08-23 hidden-messages fix — three exemptions ADDED to the
// original "drop if stripThinkingTags(content) is empty" rule:
//
//   1. `image_urls` populated → KEEP. A user message with attached
//      images but no text (content='') was permanently invisible:
//      it was dropped HERE, before hasBubbleContent's image check
//      (line ~1289) could ever see it. The images exist; show them.
//
//   2. `role === 'tool'` → KEEP. Tool result rows are rendered by
//      structured components (ReadFile, Bash, ...) that parse their
//      own envelope from content — several tools legitimately carry
//      whitespace-only or empty raw content while still rendering a
//      meaningful card. Dropping them here broke the tool sequence.
//
//   3. `reasoning_content` present → KEEP. Thinking models can emit
//      reasoning with an empty final text body; the message is not
//      empty, and the assistant bubble now renders a collapsible
//      reasoning section for it (see template, assistant branch).
const filteredMessages = computed(() =>
  messages.value.filter((m) => {
    // Always keep tool_calls messages even if content is only thinking tags
    if (m.finish_reason === 'tool_calls') return true
    // 2026-08-23: image-only user messages must survive the filter —
    // hasBubbleContent renders their images downstream.
    if ((m.image_urls?.length ?? 0) > 0) return true
    // 2026-08-23: tool results render via dedicated components; never
    // drop them on empty stripped content.
    if (m.role === 'tool') return true
    // 2026-08-23: thinking-only assistant turns (reasoning_content set,
    // final text empty) still have visible content once the reasoning
    // section renders.
    if (m.role === 'assistant' && m.reasoning_content && m.reasoning_content.trim() !== '') {
      return true
    }
    const stripped = stripThinkingTags(m.content)
    return stripped && stripped.trim() !== ''
  }),
)

// Group consecutive messages of the same role together for cleaner display
interface MessageGroup {
  role: 'user' | 'assistant' | 'tool'
  messages: Message[]
  timestamp: Date
}

/**
 * Stable identity for a message group (2026-08-26 stable-keys fix).
 * The VirtualScroller keys its height cache by this — a group keeps
 * its measured height wherever it moves in the array. messageGroups
 * re-merges/re-filters on every SSE event, shifting indices; with
 * index-keyed heights those shifts corrupted the sizer (heights
 * describing the wrong rows → phantom gaps → blank stick-to-bottom).
 * The first message's DB id is stable across regrouping.
 */
const groupKey = (group: MessageGroup): string =>
  group.messages[0]?.id ?? `empty-${group.timestamp.getTime()}`

const messageGroups = computed((): MessageGroup[] => {
  const groups: MessageGroup[] = []

  for (const msg of filteredMessages.value) {
    const lastGroup = groups[groups.length - 1]

    if (lastGroup && lastGroup.role === msg.role) {
      lastGroup.messages.push(msg)
      if (msg.timestamp > lastGroup.timestamp) {
        lastGroup.timestamp = msg.timestamp
      }
    } else {
      groups.push({
        role: msg.role as 'user' | 'assistant' | 'tool',
        messages: [msg],
        timestamp: msg.timestamp,
      })
    }
  }

  // 2026-08-23 blank-block fix — drop groups with nothing renderable
  // BEFORE the VirtualScroller ever sees them. The previous approach
  // (v-if inside the slot) left empty groups in the items array, where
  // their height stayed at the scroller's 200px ESTIMATE forever
  // (measureItems only measures rendered children). The estimated total
  // then far exceeded the real content height, and scrollToBottom —
  // which trusts the estimate — landed the visible window PAST all real
  // items: a fully blank chat. Filtering here keeps the scroller's item
  // list in sync with what actually renders; hasBubbleContent in the
  // template remains as defense-in-depth.
  return groups.filter((g, i) => hasBubbleContent(g, i))
})

/**
 * Group key of the group containing a message id (2026-09-06
 * virtual-scroller shrink fix). Used at the streaming->DB swap site to
 * transfer the measured height to the new key. Null when the message
 * is not in any group (already filtered, empty chat).
 */
const groupKeyForMessageId = (messageId: string): string | null => {
  if (!messageId) return null
  const g = messageGroups.value.find((grp) => grp.messages.some((m) => m.id === messageId))
  return g ? groupKey(g) : null
}

// ── User-pill rail (2026-09-09 chatview user pill) ──────────────────────
// One pill per user group; click jumps the scroller to that group.
// Per-group (not per-message) because VirtualScroller items ARE groups —
// scrollToItem(groupIndex) is exact. Compaction envelopes are skipped
// (system artifacts, not user turns). Uniform stack order (not
// proportional to height) so the rail stays predictable under
// virtualization estimates.
const userPills = computed((): UserPill[] => {
  const pills: UserPill[] = []
  messageGroups.value.forEach((g, i) => {
    // Real user turns only: bg-output groups are role=user on the wire
    // but render as tool cards, compaction envelopes are system
    // artifacts — neither gets a pill (see isPillGroup).
    const first = g.messages[0]
    if (!isPillGroup(g.role, isBgOnlyGroup(g), !!first && isCompactionMessage(first))) return
    const text = g.messages
      .map((m) => m.content || '')
      .join('\n')
      .trim()
    const preview = text.slice(0, 60) || 'Image'
    pills.push({ groupIndex: i, key: groupKey(g), preview, title: `${preview}` })
  })
  return pills
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

// Per-message envelope unwrap lookup. Keyed by message id; value is the
// parsed envelope or null if the content is not a <tool> envelope (legacy
// or non-tool content). Computed once when messages change so the
// template can do a cheap O(1) lookup per tool component.
const unwrappedByMessageId = computed((): Map<string, UnwrappedToolOutput | null> => {
  const map = new Map<string, UnwrappedToolOutput | null>()
  for (const m of messages.value) {
    if (m.role !== 'tool') {
      map.set(m.id, null)
      continue
    }
    map.set(m.id, tryUnwrapToolOutput(m.content))
  }
  return map
})

// Helper used in the template: get the inner data to pass to a
// tool-specific component. Returns the original content if the
// envelope didn't parse (legacy fallback) or if there was an error
// (the error message is shown via the envelope, not via the inner
// component's own error path).
const innerToolData = (m: Message): unknown => {
  const unwrapped = unwrappedByMessageId.value.get(m.id)
  if (unwrapped === null || unwrapped === undefined) return m.content // legacy
  return unwrapped.data ?? m.content // error case: fall back to full content
}

// Helper used in the template: get the JSON-string tool-call arguments
// for a tool message. Falls back to '{}' for legacy messages that
// don't carry the envelope.
const getParametersForMessage = (m: Message): string => {
  return unwrappedByMessageId.value.get(m.id)?.parameters ?? '{}'
}

const isBgUserMsg = (m: { content?: string }): boolean =>
  !!m.content && isBackgroundCommandOutput(m.content)
const bgShellContent = (m: { content?: string }): string => {
  const pr = m.content ? parseBackgroundCommandOutput(m.content) : null
  return pr ? backgroundToShellXml(pr) : (m.content ?? '')
}
// A user group made ONLY of background completions renders as a
// transparent left-aligned tool card, not the blue right bubble
// (background completions are role=user on the wire, tool-styled
// in pixels — see helpers/isBackgroundCommandOutput).
const isBgOnlyGroup = (group: { role: string; messages: { content?: string }[] }): boolean =>
  group.role === 'user' && group.messages.length > 0 && group.messages.every(isBgUserMsg)

// ─── FIX: Compute tool call names per assistant group ─────────────────────────
// For each group index, returns the tool names string if the group is an
// assistant turn that triggered tool calls BUT the tool outputs are NOT shown
// anywhere in the transcript. When tool outputs ARE shown (same group is tool,
// next group is tool, OR a later non-adjacent tool row carries a matching
// tool_call_id) we return null — the structured tool card already conveys
// what was called.
//
// 2026-08-23 stray-TOOLS-pill fix — the previous adjacency check
// (`messageGroups[i+1]?.role === 'tool'`) flashed a pill during the
// live-SSE window between the assistant tool_calls row arriving and
// the tool result row arriving. Worse, it could persist wrongly if
// the tool group was later collapsed / dropped / merged by
// filteredMessages or hasBubbleContent. Now we walk the WHOLE
// transcript for matching tool_call_ids — robust against ordering,
// merging, and live SSE interleaving.
const groupToolNames = computed((): (string | null)[] => {
  // Pre-collect every tool_call_id that has a matching tool row in the
  // transcript. The id set is the single source of truth for "is this
  // tool call already represented by a structured card?".
  const renderedToolCallIds = new Set<string>()
  for (const g of messageGroups.value) {
    if (g.role !== 'tool') continue
    for (const m of g.messages) {
      if (m.tool_call_id) renderedToolCallIds.add(m.tool_call_id)
    }
  }

  return messageGroups.value.map((group, i) => {
    if (group.role !== 'assistant') return null

    // Same-group tool rows (rare but possible when an assistant message
    // carries tool_calls_json AND a tool result) → no pill needed.
    const nextGroup = messageGroups.value[i + 1]
    if (nextGroup?.role === 'tool') {
      return null
    }

    // Look for any message in this assistant group whose tool_calls_json
    // either already has a matching tool row OR yields parseable names.
    for (const msg of group.messages) {
      // 2026-08-24 wire-shape fix (task_1787590621966_10): the backend
      // now always serializes tool_calls_json as a JSON STRING, but
      // older events (or any future array-shaped regression) must not
      // crash the render — `.trim` doesn't exist on arrays and `?.`
      // only guards null/undefined. Non-string values fall through to
      // the finish_reason heuristic below instead of throwing.
      if (typeof msg.tool_calls_json === 'string' && msg.tool_calls_json.trim()) {
        try {
          const parsed = JSON.parse(msg.tool_calls_json)
          // tool_calls_json IS the array directly: [{id, type, function: {name}}]
          if (Array.isArray(parsed) && parsed.length > 0) {
            // eslint-disable-next-line @typescript-eslint/no-explicit-any -- intentional escape hatch; the surrounding type is intentionally opaque.
            const names = parsed.map((tc: any) => tc.function?.name || tc.name || 'unknown')

            // If EVERY tool call in this group already has a rendered
            // tool row somewhere in the transcript, the structured cards
            // are the source of truth — suppress the pill entirely.
            // eslint-disable-next-line @typescript-eslint/no-explicit-any -- intentional escape hatch; tool_calls_json shape is intentionally opaque.
            const allRendered = parsed.every((tc: any) => {
              const id = tc?.id
              return typeof id === 'string' && renderedToolCallIds.has(id)
            })
            if (allRendered) return null

            return names.join(', ')
          }
        } catch {}
      }

      // finish_reason set but tool_calls_json missing/unparseable.
      // Only show the "..." pill when the tool call is NOT yet
      // represented by a rendered tool row (otherwise the live SSE
      // window between tool_calls and tool_result would flash a stray
      // pill that immediately gets replaced by a structured card).
      if (msg.finish_reason === 'tool_calls') {
        // We can't match by id here (tool_calls_json is missing), so
        // fall back to the adjacency heuristic: if a tool group
        // appears ANYWHERE in the transcript after this group, the
        // tool call was rendered → no pill.
        let hasLaterTool = false
        for (let j = i + 1; j < messageGroups.value.length; j++) {
          if (messageGroups.value[j]?.role === 'tool') {
            hasLaterTool = true
            break
          }
        }
        if (hasLaterTool) return null
        return '...'
      }
    }

    return null
  })
})

// ─── Inherited Context: thread sub_agents args from assistant message to tool
// result. The tool result message carries a tool_call_id; we walk backwards
// through messageGroups to find the assistant message whose tool_calls_json
// contains a call with that id, then extract the sub_agents array via
// parseSpawnSubAgentArgs. Returns null when no match is found, which the
// SpawnSubAgent component treats as "no inherited_context badge".
function findSubAgentArgsForToolGroup(
  toolCallId: string | undefined,
  groups: MessageGroup[],
  currentGroupIndex: number,
): SubAgentArgs[] | null {
  if (!toolCallId) return null
  // Walk backwards from the current group
  for (let i = currentGroupIndex - 1; i >= 0; i--) {
    const g = groups[i]
    if (!g) continue
    if (g.role !== 'assistant') continue
    for (const msg of g.messages) {
      // 2026-08-24 wire-shape fix: typeof guard — parseSpawnSubAgentArgs
      // JSON.parses this value; a non-string (legacy array shape) would
      // throw inside the computed. Non-strings simply yield no badge.
      if (typeof msg.tool_calls_json !== 'string') continue
      const args = parseSpawnSubAgentArgs(msg.tool_calls_json, toolCallId)
      if (args) return args
    }
  }
  return null
}

// ─── Bubble Visibility ────────────────────────────────────────────────────────
// Check if a message has visible text content (i.e. content that survives
// stripThinkingTags and is non-empty after trim). An assistant message saved
// with finish_reason='tool_calls' often has raw content that is *only*
// `<thinking>...</thinking>` tags — the raw string is non-empty, but
// renderResponse() strips those tags and renders an empty string, producing
// a visible-but-empty bubble. The bubble check must match what the renderer
// actually shows, not the raw column.
const hasVisibleContent = (m: Message): boolean => {
  const stripped = stripThinkingTags(m.content || '')
  return stripped.trim().length > 0
}

// Check if a message group has any visible content for its bubble.
// Hides empty bubbles (e.g., a user message with no text and no images,
// or an assistant message with no content and no tool-call header).
//
// 2026-08-23 hidden-messages fix — the user branch previously checked
// ONLY group.messages[0]; with consecutive user messages (queue-drain
// bursts) the 2nd+ messages were invisible even when non-empty. Now
// ANY message in the group having images, visible text, or reasoning
// keeps the bubble alive.
const hasBubbleContent = (group: MessageGroup, groupIndex: number): boolean => {
  if (group.role === 'user') {
    return group.messages.some(
      (m) =>
        (m.image_urls?.length ?? 0) > 0 ||
        hasVisibleContent(m) ||
        !!(m.reasoning_content && m.reasoning_content.trim() !== ''),
    )
  }
  if (group.role === 'tool') {
    return group.messages.length > 0
  }
  if (group.role === 'assistant') {
    const hasToolHeader = groupToolNames.value[groupIndex] !== null
    const hasReasoning = group.messages.some(
      (m) => m.reasoning_content && m.reasoning_content.trim() !== '',
    )
    return hasToolHeader || hasReasoning || group.messages.some(hasVisibleContent)
  }
  return false
}

// ─── Chat History ────────────────────────────────────────────────────────────

// 2026-09-04 spawn-subagent-refresh-persist (task_1788505292766_1) —
// rehydrate live sub-agent rows after a (re)load. Progress events are
// SSE-ephemeral; a refresh/re-mount wipes subAgentProgressMap with no
// replay. For every spawn_sub_agent tool row still in placeholder
// state (no `<summary>` → the tool hasn't completed), fetch the
// backend's authoritative snapshot and fold it into the map.
// Best-effort: any failure (server restarted → progress=[]; network
// error) leaves Task 0's "starting…" fallback in place. Skipped on
// loadMore (scroll-back fetches older, already-completed history).
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
//
// Task_1789505423062_0 — "the auto fetch is loaded after the user hit the
// max; what if the auto fetch is done before the scroll reaches the top?"
//
// Why the old path felt slow: VirtualScroller's `loadMore` check is positional
// AND debounced (200 ms, trailing edge, timer reset on every scroll event — see
// its `onScroll`). During a fling the timer keeps being pushed out, so the
// request is only issued ~200 ms after the LAST scroll event. On a fling that
// ends at the top, "last event" IS "user already at the top" — the half-screen
// head start from `loadMoreThresholdRatio` is consumed before the request even
// starts, and the round trip + preserve dance then play out in front of a user
// who has nothing left to scroll.
//
// The fix, in three beats:
//   ARM     — while the user is still far from the top (armRadiusPx), fetch the
//             next older page speculatively and keep it in memory. Invisible:
//             no `messages` mutation, no scrollTop write, no stick-flag bump.
//   COMMIT  — when the user actually enters the scroller's load-more band (or
//             the 200 ms backstop fires, or the manual button is clicked), the
//             buffered page is prepended through the SAME preserve path as
//             before. Zero network wait on the critical path.
//   REFILL  — after a commit, arm the next page from the advanced cursor, so
//             page-after-page scroll-back is instant (one page of lookahead).
//
// Deliberate non-behaviour: prepending mid-fling is NOT done. `beginPreserve` /
// `endPreserve` write `scrollTop` to keep the reading position stable; doing
// that while a momentum scroll is in flight fights the gesture (the
// jump/teleport class already fixed in #308/#337/#349). Fetch early, commit at
// the band.
//
// Invariants (asserted by ChatView.lazyPrefetch.spec.ts):
//   1. ARM mutates no DOM/scroll state — `messages` is untouched until COMMIT.
//   2. `messageCursor` advances ONLY at COMMIT.
//   3. The buffer is claimed SYNCHRONOUSLY, before the first `await`, so the
//      positional commit and the 200 ms `@load-more` backstop cannot both
//      prepend the same page.
//   4. A buffer is dropped when its cursor or generation no longer matches
//      (session switch, refresh, or another path advancing the cursor).

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

/**
 * How many consecutive gesture-less commits may chain before REFILL stops.
 * A commit normally restores the anchor far below the band (so no chain), but a
 * tall viewport / short page can leave the viewport inside the band and pull
 * pages back-to-back. Bound it; a fresh user scroll resets the budget.
 */
const MAX_PREFETCH_AUTO_CHAIN = 3

/**
 * Shared log context for the prefetch path — the same scroller/wrapper geometry
 * every other scroll log carries. One helper, so the five prefetch log lines
 * (`armed` / `committed` / `skipped` / `dropped` / `failed`) can never disagree
 * about the geometry they report.
 */
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

/**
 * Map REST rows into the view's `Message` shape.
 *
 * Shared by the initial load AND the scroll-back prefetch so a pull of older
 * history can never drift from the initial page's wire shape (the #291 lesson:
 * two mappers for one endpoint = two shapes).
 */
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
    finish_reason: msg.finish_reason,
    tool_calls_json: msg.tool_calls_json,
    tool_call_id: msg.tool_call_id,
    is_input: msg.is_input,
    is_output: msg.is_output,
    // 2026-08-23 hidden-messages fix — carry the thinking model's
    // reasoning through to the renderer. The backend REST endpoint
    // already returns it (http_response.zig SessionMessage).
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

const rememberLiveMessage = (sid: string, id: string, role: Message['role']): void => {
  if (liveMessageSessionId !== sid) {
    liveMessageSessionId = sid
    liveMessageIds.clear()
  }
  if (role === 'tool') liveMessageIds.add(id)
}

const currentLiveMessages = (): Message[] =>
  messages.value.filter(
    (message) => liveMessageIds.has(message.id) || message.id.startsWith('streaming-'),
  )

/**
 * Fetch ONE older page and measure the round trip.
 *
 * Network + mapping only: mutates no component state except the fetch-duration
 * estimate. Used by the speculative ARM (buffered, never rendered directly) and
 * by the foreground path when no buffer is armed.
 */
const fetchOlderPage = async (cursor: string | null): Promise<BufferedOlderPage> => {
  const startedAt = performance.now()
  // Cache-first older page: serve from IndexedDB when it holds rows older
  // than the current oldest, so scroll-back avoids the network. The cursor
  // is left unchanged on a hit so the next cache MISS resumes the network
  // exactly where it left off; the commit's id-dedupe covers any overlap.
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

/**
 * Drop any armed / in-flight older page and invalidate late responses.
 *
 * Called on session switch (the two `sessionId` watchers), on an initial
 * `loadChatHistory()` refresh, and on unmount. The `commitGeneration` bump is
 * what makes a response that is already in flight inert — it is checked both
 * when an ARM resolves and again when a commit claims the buffer.
 *
 * Deliberately NOT called from the SSE `full` echo: that handler patches
 * `messages` in place without touching `messageCursor`, so a cursor-stamped
 * buffer stays valid and the commit's id-dedupe covers any overlap.
 */
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

/**
 * ARM — fetch the next older page speculatively, into the buffer.
 *
 * Invisible by contract: no `messages` mutation, no scrollTop write, no
 * `lastAutoStickAt` bump, no `isLoadingMore`. That is also why it is NOT gated
 * by the auto-stick gate: the gate requires `isAtBottom === true`, and the arm
 * requires the user to be within `armRadiusPx` of the top — mutually exclusive
 * in a scrollable chat, so a gate check here could never fire.
 */
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

/**
 * Claim the armed page for a commit — SYNCHRONOUSLY, before any `await`.
 *
 * This is the contract that makes the positional commit and the 200 ms
 * `@load-more` backstop safe: the first caller clears the slot in the same tick,
 * so the second caller sees `null` and cannot prepend the same page twice.
 * Returns `null` (and logs a drop) when the buffer no longer matches the live
 * cursor/generation.
 */
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

/**
 * COMMIT — prepend a fetched older page through the preserve path.
 *
 * Moved verbatim from the old `loadChatHistory(true)` branch: suppress the
 * contentShift re-stick, snapshot `wasAtBottom`, `beginPreserve`, dedupe by id,
 * prepend, advance the cursor, `nextTick`, mark the restore programmatic,
 * `endPreserve`, re-seed `lastObservedScrollHeight`, and re-stick when the user
 * was at the bottom. The only additions are the `trigger`/`bufferedAgeMs`
 * fields in the logs and the REFILL arm at the end.
 *
 * The caller (`maybeLoadOlder`) owns `isLoadingMore` / `isCommittingOlder`.
 */
const commitOlderPage = async (
  page: BufferedOlderPage,
  trigger: 'buffered' | 'foreground' | 'manual',
) => {
  const newMessages = page.messages
  // Suppress the contentShift re-stick for the duration of the
  // preserve. The user is scrolling *up* to load older history
  // (not at the bottom), so the stick-to-bottom behavior is
  // useless here — and its re-stick callback firing on every
  // layout shift during the forceRender/measure/anchor dance is
  // what was causing the visible flicker. Detaching the rAF
  // handler eliminates that work entirely for this window.
  suppressContentShiftStick = true

  // Snapshot the at-bottom state BEFORE the preserve begins. The
  // preserve dance (beginPreserve → messages mutation → endPreserve)
  // fires scroll events that pass through handleVirtualScroll and
  // would corrupt the live `isAtBottom` flag — the snapshot is the
  // only trustworthy signal for the post-preserve re-validation
  // below (task_1787638309623_3).
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
  // 2026-09-09 user-pill pagination fix — dedupe: drop pages already
  // present (retry after a failed endPreserve, overlapping cursor
  // pages, or an SSE `full` echo that landed mid-preserve). Without
  // this the same id prepended twice renders double bubbles and
  // corrupts group indices the pill rail jumps to.
  const seenIds = new Set(messages.value.map((m) => m.id))
  const freshMessages = newMessages.filter((m) => !seenIds.has(m.id))
  messages.value = [...freshMessages.slice().reverse(), ...messages.value]
  // 2026-09-09 user-pill pagination fix — cursor advance: the NEXT
  // loadMore must continue from THIS page's cursor, not the initial
  // one. These assignments previously lived only in the initial-load
  // branch, so every 2nd+ loadMore re-sent the same cursor and
  // re-prepended the same page forever.
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

  // Re-arm the re-stick. Re-seed `lastObservedScrollHeight` from the
  // current `scrollHeight`, so the next contentShift is compared
  // against the post-preserve state — not the stale pre-preserve
  // value, which would have made the very first post-preserve shift
  // look like a "measurement update" and re-trigger the stick path.
  lastObservedScrollHeight = virtualScrollerRef.value?.containerRef?.scrollHeight ?? 0
  suppressContentShiftStick = false

  // ── Post-preserve bottom re-validation (task_1787638309623_3) ────────
  //
  // The suppress window above SWALLOWED every contentShift event, so
  // if the user was at bottom before the prepend, nothing re-validated
  // the bottom after `endPreserve` restored the anchor. If the
  // prepended items' heights were still estimates when endPreserve
  // measured them (images/code blocks settle later), the sizer grows
  // AFTER the preserve window closes and nothing scrolls to absorb
  // it — a persistent gap below the last message (the "new items on
  // demand create big gaps" symptom).
  //
  // `wasAtBottom` was snapshotted BEFORE `beginPreserve` (the preserve
  // dance fires scroll events that would corrupt the live flag).
  // Explicit Math.max compute — same contract as the contentShift
  // re-stick, no browser-clamp delegate.
  if (wasAtBottom) {
    const c = virtualScrollerRef.value?.containerRef
    if (c) {
      scrollLogger.markProgrammatic()
      lastAutoStickAt.value = Date.now()
      // Delegated to the scroller's scrollToBottom (real-bottom
      // target — same rationale as the onContentShift stick).
      virtualScrollerRef.value?.scrollToBottom('auto')
      // Re-engage the stick explicitly: the user WAS at bottom before
      // the prepend, and we just moved them to the new bottom on their
      // behalf. The preserve dance's programmatic scroll events may
      // have flipped isAtBottom=false mid-prepend (the round-2 guard
      // only retains the stick for users who were already engaged) —
      // without this re-arm, the next SSE chunk's contentShift would
      // skip and leave a gap below the last message.
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

/**
 * Evaluate the prefetch decision for the CURRENT scroll geometry and arm if it
 * says so. Called from `handleVirtualScroll` (per user gesture) and once after
 * the initial load settles (so a chat opened near the top pre-arms without
 * waiting for a scroll event — at the bottom it is a no-op, out of radius).
 */
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

/**
 * The single entry point for "load older messages".
 *
 * Replaces the old `handleLoadMore` guard chain and is the only path that
 * commits a page, so the guards run exactly once per attempt:
 *   - the auto-stick gate applies ONLY to `trigger === 'edge'` (the scroll
 *     trigger). The manual button deliberately bypasses it, matching the
 *     previous behaviour where the button called `loadChatHistory(true)`
 *     directly — an explicit user click must never be swallowed by a stream.
 *   - `isLoadingMore` / `isCommittingOlder` are set SYNCHRONOUSLY with the
 *     buffer claim, before the first `await` (double-commit contract).
 */
const maybeLoadOlder = async (trigger: 'edge' | 'manual') => {
  const container = virtualScrollerRef.value?.containerRef
  const ctx = buildScrollContext(container, {
    chatId: sessionId.value || props.chatId,
    messages: messages.value.length,
    isAtBottom: isAtBottom.value,
    virtualScrollerRef,
    wrapperRef: messagesWrapperRef,
  })

  // Each guard is its own `if` (not chained with `||`) so we can
  // log exactly which one blocked. Order matters: the auto-stick
  // gate is first because it's the most common cause of "I
  // scrolled to the top during streaming and nothing loaded".
  //
  // Gate suppression (not blanket suppression): the previous
  // guard `isLLMProcessing && isAtBottom` blocked loadMore for
  // the ENTIRE duration of the stream, which made pagination
  // impossible while a long response was streaming. The new
  // guard is timestamp-based: only suppress if the auto-stick
  // actually fired recently (within AUTO_STICK_GATE_MS). That
  // way:
  //   - Active stream (chunks every <100ms)
  //     → gate is fresh → suppress (no jitter from prepend
  //       fighting the next chunk's stick).
  //   - Slow model, paused stream, or user scrolled up
  //     → gate goes stale → allow loadMore.
  // See `helpers/autoStickGate.ts` for the gating math.
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

/**
 * Apply the session metadata piggybacked on the messages endpoint (cwd,
 * worktree, PR binding, profile, token budgets, skills). Shared by the
 * cached-mount delta path and the full-load path so the two can never drift.
 */
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
    selectedProfile.value =
      typeof extra.selected_profile_model === 'string' ? extra.selected_profile_model || null : null
  if (extra.max_total_tokens !== undefined) maxTotalTokens.value = extra.max_total_tokens
  if (extra.max_capacity_total_tokens !== undefined)
    maxCapacityTotalTokens.value = extra.max_capacity_total_tokens
  sessionSkills.value = extra.skills || []
}

/**
 * One attempt at the initial load: cache-first paint, then the network page.
 *
 * Split out of `loadChatHistory` so the retry loop can re-run the WHOLE
 * attempt (cache-prime included) after a failed network fetch. It fails —
 * the caller's error channel is the only place that decides what a failed
 * transcript means, and it must never be "this session is empty".
 *
 * The body is still promise-shaped (it awaits IndexedDB reads and the
 * network page); `runHistoryLoadAttemptEffect` is the one place that bridges
 * it onto the Effect seam.
 */
const runHistoryLoadAttempt = async () => {
  // Cached mount: paint stored full-fidelity raws instantly (same mapper as
  // the network path, so no shape drift), restore the cursor from sync_state,
  // then refresh just the tail with cursor+asc. Miss/IDB failure falls
  // through to the full-load path below unchanged.
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
      // Painted rows exist either way, so "this session is empty" is now
      // ruled out — the empty state may be shown again if the session is
      // later reloaded.
      historyConfirmed.value = true
      setupCodeBlockCopyButtons()
      void rehydrateSubAgentProgress()
      return
    }
  } catch {
    // Ignore — network path below is authoritative.
  }

  // `fetchChatHistoryEffect`, not `getChatHistory`: the latter answers a
  // failed fetch with an empty transcript, which is exactly the "this session
  // has no messages" lie the empty state would then render. Here the failure
  // is a `ChatHistoryError` on the error channel; `runPromise` re-raises it
  // and `runHistoryLoadAttemptEffect` re-types it for the retry loop.
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

  // 2026-08-07-profile-persist-read — load the persisted profile
  // selection from the messages endpoint response. onSessionChanged
  // (below) ALSO reads it from getSession() (lightweight session detail
  // endpoint, same sessions row), but it runs on mount/switch
  // and races with loadChatHistory on initial mount. Reading it here
  // is the authoritative source: whichever finishes first, the value
  // is the same. The handler's later update will agree and not clobber.
  if (data.selected_profile_model !== undefined) {
    selectedProfile.value =
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

  // Initial load path. Set isInitialLoad BEFORE the messages
  // assignment so the messages-length watcher's sync callback
  // sees the flag and skips its own scrollToBottom (which would
  // yank the user back to the bottom right after we restore a
  // saved position).
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
      // Sync cursor must be the newest row, not the pagination cursor:
      // the backend omits next_cursor when has_more is false (wiping the
      // cursor to null), and on a full page it points at the oldest row
      // (re-fetching the same page next mount). Either way the next mount
      // degrades to a full desc limit=1000 load.
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
    // Wait one paint frame so the browser has actually laid out the
    // VirtualScroller items (nextTick alone only waits for Vue's DOM
    // update, not for layout/paint). After this, the MutationObserver
    // set up in onMounted takes over: whenever spacers resize (from
    // measurement updates) it'll re-stick to the bottom as long as the
    // user hasn't scrolled up.
    await new Promise<void>((r) => requestAnimationFrame(() => r()))

    // Try to restore the user's previous scroll position (set by
    // useChatScrollRestore when they last closed this task). If
    // no saved position exists OR the saved position is "near
    // bottom" (within BOTTOM_THRESHOLD_PX of max), restore()
    // returns null and we fall through to the existing
    // scrollToBottom behavior. This is the chat-specific
    // counterpart of the kanban composable's restore-on-mount
    // path.
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
    // 2026-09-04 spawn-subagent-refresh-persist
    // (task_1788505292766_1) — rehydrate live sub-agent rows after
    // a (re)load. Fire-and-forget: the map update re-renders cards
    // when snapshots land; failures keep Task 0's "starting…".
    void rehydrateSubAgentProgress()
  } finally {
    isInitialLoad = false
  }
  // The server answered. Whether the answer was "0 messages" or "500", the
  // empty state is now allowed to consider rendering.
  historyConfirmed.value = true

  // NOTE — deliberately NO prefetch evaluation here.
  //
  // An eager one-shot evaluation at this point reads unsettled geometry: the
  // initial-load scroll (`chatScrollRestore.restore()` / `scrollToBottom`) is
  // applied a tick AFTER this function returns, so `container.scrollTop` is
  // still 0 and the arm radius check passes — burning a scroll-back request on
  // every chat open, which then gets dropped when the real position lands.
  // Verified in the browser (chatview_lazy_prefetch_ui_test.py): the eager
  // request was issued at `scrollTop = 0` and dropped ~1 frame later.
  //
  // The arm therefore waits for the first real user scroll event, which is also
  // when the prefetch is actually useful. A chat restored to a position near
  // the top arms on its first upward scroll — still ~1.5 viewports early.
}

/**
 * The promise-shaped attempt above, as an `Effect`.
 *
 * `Effect.tryPromise` is the sanctioned bridge (see `sync/SessionEngineDb.ts`
 * for the same shape): it is where a rejection becomes a typed
 * `ChatHistoryError` instead of an unhandled throw, so the retry loop and the
 * error state can both see it.
 */
const runHistoryLoadAttemptEffect = (): Effect.Effect<void, ChatHistoryError> =>
  Effect.tryPromise({
    try: runHistoryLoadAttempt,
    catch: (cause) =>
      new ChatHistoryError({
        sessionId: sessionId.value,
        reason: cause instanceof Error ? cause.message : String(cause),
      }),
  })

/**
 * Initial load / refresh (the old `loadChatHistory(false)`).
 *
 * Wraps `runHistoryLoadAttempt` in the retry schedule, then decides what a
 * fully-failed load means. Two invariants this owns:
 *
 *   1. `isLoading` stays true across every attempt, so `isInitializing` keeps
 *      the skeleton up and the composer disabled for the whole wait. The user
 *      sees "still loading" — never a transcript that claims to be empty.
 *   2. `historyConfirmed` is only set by a SUCCESSFUL attempt, so the empty
 *      state cannot render off a failed fetch. A fully-failed load lands in
 *      the error state with its Retry button.
 *
 * The `loadMore` branch that used to live here moved to `maybeLoadOlder` /
 * `commitOlderPage`; this function no longer has a `loadMore` parameter, so the
 * two scroll-back call sites can no longer accidentally take the slow path.
 */
const loadChatHistory = async () => {
  if (!sessionId.value || isPendingSession.value) return

  isLoading.value = true
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
      }),
    ),
    'history.load',
  )
}

// ─── Scroll ──────────────────────────────────────────────────────────────────

const scrollToBottom = async (force = false, trigger: string = 'unspecified') => {
  await nextTick()
  // Defense: during `beginPreserve`/`endPreserve`, the VirtualScroller
  // is adjusting `scrollTop` itself to keep the user's view stable
  // while older messages are prepended. An external `scrollToBottom`
  // here fights that adjustment and produces visible jitter. The
  // preserve window is short (<100ms typically) so suppressing is
  // safe — the next SSE chunk will trigger a fresh scrollToBottom.
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

// ─── Follow the newest turn ──────────────────────────────────────────────────
//
// "Take me to the newest turn", as an explicit act by the reader rather than an
// inference from where they happen to be sitting. Sending and queueing are
// that act: the reader is looking at history, they ask for a turn, and the turn
// they asked for is what they should be looking at.
//
// It has to re-arm `isAtBottom` and not merely pass `force = true`, because
// `isAtBottom` is what three separate gates read afterwards — the
// `messages.length` watcher returns early without it, `onContentShift` skips,
// and a non-forced `scrollToBottom` does nothing. A reader scrolled up into
// history is `isAtBottom === false` by definition, and there is no optimistic
// push (see `handleFileInputSubmit`), so the turn that answers the send arrives
// over SSE a frame or two later and is exactly the content those gates are
// there to follow.
//
// A forced scroll alone cannot do this. It writes `container.scrollTop` and
// leaves the flag to the native `scroll` event that follows — and the browser
// fires none when the write is a no-op, which is the common case here: the
// scroller's sizer already reports a max scrollTop that the container is
// sitting at. The flag then stays false and the turn lands below the fold with
// nothing left to bring it up. Setting the flag first is what makes the
// follow deterministic instead of a race with an event that may not come.
const followNewestTurn = (trigger: string) => {
  isAtBottom.value = true
  lastAutoStickAt.value = Date.now()
  scrollLogger.markProgrammatic()
  scrollToBottom(true, trigger)
}

// Triggered by VirtualScroller when the user scrolls within `loadMoreThreshold`
// of the top (because `loadMoreAtTop` is true). Auto-paginates older messages.
//
// Thin wrapper: the guard chain + buffered-page commit live in
// `maybeLoadOlder` (which the positional commit in `handleVirtualScroll` and
// the manual button also call), so every trigger shares one implementation.
const handleLoadMore = () => {
  void maybeLoadOlder('edge')
}

// Triggered by VirtualScroller when one of ITS internal guards
// prevented `loadMore` from being emitted — i.e. the user WAS
// within the load edge but the scroller still chose not to emit
// (because `isPreservingScroll`, `!hasMore`, `!isScrollable`, or
// `items.length === 0`). This is the "scroller-side" companion to
// `handleLoadMore`'s guard logging — together they cover every
// reason lazy load might not have fired.
//
// The `source: 'VirtualScroller'` field in `extra` distinguishes
// these from ChatView-side suppressions when you're grepping.
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

// Track isAtBottom from the VirtualScroller's scroll event so we can decide
// whether to auto-scroll on new messages and when to show the "scroll to
// bottom" button.
//
// `previousIsAtTop` is a module-scope (not ref) because it only feeds
// the logger — nothing else needs to react to it. Storing the
// "did we just reach the top" transition is what powers the
// `reached-top` / `left-top` log lines, which are the answer to
// "user scrolled to the top of the chat — why didn't lazy load
// fire?" If the `reached-top` line is followed by silence (no
// `load-more-threshold-reached` and no `load-more-suppressed`),
// the loadMore event was never fired in the first place.
let previousIsAtTop = false
// Module-scope state for the additional handleVirtualScroll logs
// below. Like `previousIsAtTop`, these are pure diagnostics —
// nothing else reads them. Using plain `let` (not ref) avoids any
// reactive work; the values exist only to feed the logger.
//
// Sentinel `-1` for the numeric "previous" values signals "no
// prior event yet" so the delta-based logs (`direction-change`,
// `content-resized`) can skip their first call. The
// `first-scroll` info log captures that initial state explicitly,
// so the missing deltas on call #1 don't look like a bug.
let previousScrollTop = -1
let previousScrollHeight = -1
let previousDirection: 'up' | 'down' | null = null

const handleVirtualScroll = (
  scrollTop: number,
  direction: 'up' | 'down',
  target: HTMLElement,
  isProgrammatic = false,
) => {
  // Prefer the event target — it's the actual DOM element that
  // dispatched the scroll event, so the browser guarantees it
  // exists for the lifetime of this handler. The ref chain
  // (`virtualScrollerRef.value?.containerRef`) is null during
  // mount/remount races (chat switch, initial mount before Vue
  // binds the template ref, v-if toggle), but the target is
  // always live. See the `scroll` emit JSDoc in
  // VirtualScroller.vue for the full rationale.
  //
  // The ref chain is kept as a defensive fallback for any future
  // caller that doesn't supply a target (none today).
  const container = target ?? virtualScrollerRef.value?.containerRef
  if (!container) {
    // Tripwire — with the target in hand this branch should be
    // unreachable. If it ever fires, the VirtualScroller stopped
    // passing the target through the emit (regression on the
    // fix in VirtualScroller.vue `onScroll`).
    console.warn('[scroll] handleVirtualScroll: no container (target and ref chain both null)', {
      reportedScrollTop: scrollTop,
      reportedDirection: direction,
    })
    return
  }

  // The container is the source of truth for geometry — the
  // `scrollTop` parameter is the VirtualScroller's reported value
  // and may lag by a frame. We log the param for cross-validation
  // but use the container's value everywhere else.
  const { scrollHeight, clientHeight } = container
  const actualScrollTop = container.scrollTop
  const scrollTopMatches = Math.abs(scrollTop - actualScrollTop) < 1
  // ── "The bottom" is whatever scrollToBottom is about to target ──────────
  // NOT `scrollHeight - clientHeight`. The sizer is a height MODEL; when it
  // overshoots the real content, the DOM's max is up to `maxTailGap` (100px
  // by default) below the last message — and `VirtualScroller.scrollToBottom`
  // deliberately parks the reader at the real content bottom instead, so the
  // DOM's max is a position the reader is never AT. Measuring against it
  // meant every successful auto-stick immediately reported itself as "the user
  // left the bottom", which disarmed all four auto-stick gates for the rest of
  // the mount (scrollToBottom(force=false), the onContentShift re-stick, the
  // SSE-chunk remeasure, the messages-length watcher). That is the
  // "sometimes it does not autoscroll to bottom" report: the reader sat at the
  // bottom, the FAB said otherwise, and the stream stopped following.
  //
  // The scroller owns this number because it owns the blank-viewport override
  // that makes the two disagree. Fall back to the DOM measure when the ref is
  // not populated (mount races, a caller without a scroller) — that path
  // existed before the override did, so it is the safe default.
  //
  // ── Stable anchor, not a live read (2026-10-10) ─────────────────────────
  //
  // `bottomScrollTop()` is a MOVING TARGET, and that is the "the stick dies
  // mid-stream" flake. Its two inputs move independently:
  //
  //     domEdge    = scrollHeight - clientHeight       (the height MODEL)
  //     realBottom = topSpacer + content.offsetHeight  (the RENDERED rows)
  //     if (domEdge - realBottom + clientHeight > HYSTERESIS_PX) use realBottom
  //
  // The override engages only while the model overshoots by more than
  // `HYSTERESIS_PX` (50px). So when the model converges — or the rendered
  // window shifts and `topSpacer` jumps — the SAME stationary reader is
  // suddenly measured against a different number. Instrumented trace, one
  // chunk apart, reader never having moved:
  //
  //     frame A: bottomEdge=30114  scrollTop=30071  -> 43px short -> atBottom=false
  //     frame B: bottomEdge=30093  scrollTop=30093  ->  0px short -> atBottom=true
  //
  // The reader did not move 43px; the RULER moved. `isAtBottom` therefore
  // oscillates, the jump-to-bottom arrow blinks, and every follow gate that
  // reads the flag disarms on the "short" frames. `retainedThroughGrowth`
  // below papers over most of them, but it is capped at <100px and does not
  // fire when `contentGrew` is false — so on a slow runner the last settle
  // lands on a short frame and the arrow is up when anything samples it.
  //
  // The fix is to judge against the bottom AS IT WAS when the stick last
  // acted — `settledBottom`, which `measureItems` and `scrollToBottom`
  // already maintain for exactly this reason (see its own comment about
  // judging `wasAtBottom` against a stale rather than a live read). That
  // number only changes when the scroller deliberately repositions, so a
  // stationary reader stays at-bottom across the model's own convergence.
  //
  // The tolerance widens to absorb the model's convergence between the last
  // pass and this event: `BOTTOM_THRESHOLD` (10px) plus the overshoot hysteresis
  // (50px) — the largest step the ruler can take between two frames. It is
  // deliberately NOT `maxTailGap` (100px): that would swallow a reader sitting
  // 101px up, which `retainedThroughGrowth`'s own `< 100` cap exists to keep
  // disengaged. A genuine scroll-up is still caught immediately.
  const settled = virtualScrollerRef.value?.settledBottom
  const liveEdge = virtualScrollerRef.value?.bottomScrollTop?.() ?? scrollHeight - clientHeight
  const bottomEdge =
    typeof settled === 'number' && Number.isFinite(settled) ? Math.max(settled, liveEdge) : liveEdge
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
  // Deltas: how much scrollTop moved since the last event, and how
  // much scrollHeight grew (or shrank — e.g. an image unmounted).
  // Both are 0 on the first event. The `>= 0` guard on the
  // previous-sentinel -1 is what makes the first call a no-op
  // for delta-based logs.
  const deltaTop = previousScrollTop >= 0 ? actualScrollTop - previousScrollTop : 0
  const deltaHeight = previousScrollHeight >= 0 ? scrollHeight - previousScrollHeight : 0
  const directionChanged = previousDirection !== null && previousDirection !== direction
  const contentGrew = deltaHeight > 0
  // "Lazy-load zone" is the VirtualScroller's `loadMoreThreshold`
  // (200px) — wider than the 10px `reached-top` log. A user
  // entering the zone hasn't reached the top yet, but lazy load
  // is about to consider firing. This is the WARN-equivalent
  // info: "user is heading toward the top — expect a
  // `load-more-*` line soon".
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
  // ── First-scroll info ───────────────────────────────────────────────
  //
  // Captures the chat's initial state on the very first scroll
  // event. Without this, "delta=0" lines for the first few events
  // look like a bug in the delta math. Also surfaces whether the
  // VirtualScroller's reported `scrollTop` matches the container's
  // (they should agree to within 1px; a >1px mismatch is a stale
  // param bug, not a cosmetic issue).
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
  // ── Direction-change info ───────────────────────────────────────────
  //
  // The user reversed scroll direction (e.g. was scrolling up to
  // read history, then back down). This is the "why did the chat
  // jump to the bottom when I was scrolling up?" signal — if a
  // `reached-bottom` log follows a `direction-change` with
  // `direction: 'up'`, the auto-stick fired in the middle of an
  // upward gesture. If you see this in the logs and the next state
  // transition is `left-bottom` (not `reached-bottom`), the user's
  // direction reversal was respected correctly.
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
  // ── Content-resized info ────────────────────────────────────────────
  //
  // `scrollHeight` changed between two scroll events. Causes:
  //   - New message appended (SSE chunk, messages-length watcher)
  //   - Image finished loading / unmounted
  //   - VirtualScroller measured or relayouted items
  //   - User toggled message-grouping, attachments, or code fold
  // Combined with the next state-transition log, this answers
  // "did content grow while I was scrolled up reading?" — if so,
  // the user's reading position may no longer reference the same
  // message it did a moment ago. Negative `deltaHeight` (content
  // shrank) is logged too — that's a code-fold collapse or
  // optimistic message rollback.
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
  // ── Lazy-load-zone info ─────────────────────────────────────────────
  //
  // The user is within `loadMoreThreshold` (200px) of the top
  // but hasn't reached the 10px `reached-top` threshold yet.
  // The VirtualScroller's onScroll debounce is probably about to
  // fire `loadMore`. If you see this line followed by silence
  // (no `load-more-threshold-reached` and no
  // `load-more-suppressed`), the debounce was reset by another
  // scroll event before it could fire.
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
  // ── Older-history prefetch (task_1789505423062_0) ────────────────────
  //
  // Runs on USER scroll events only: a programmatic write (anchor
  // compensation, `endPreserve` restore) is not a gesture and must not feed
  // the decision — but it must not skip the delta bookkeeping below either,
  // so this is a scoped `if`, never an early return.
  if (!isProgrammatic) {
    // A real upward gesture is fresh intent to read history — reset the
    // refill auto-chain budget so the next commits may chain again.
    if (deltaTop < 0) prefetchAutoChain = 0
    // ARM as early as the geometry allows (fetch into the buffer, invisibly)…
    evaluateOlderPrefetch()
    // …and COMMIT the moment the user is inside the scroller's own
    // load-more band, instead of waiting out the 200 ms `@load-more`
    // backstop. `maybeLoadOlder` re-runs every guard and claims the buffer
    // synchronously, so this cannot double-commit with the backstop.
    const band = virtualScrollerRef.value?.effectiveLoadMoreThreshold ?? 200
    if (bufferedOlderPage && distanceFromTop < band) void maybeLoadOlder('edge')
  }

  // ── State transitions are loud ─────────────────────────────────────
  //
  // This is the most useful line in the whole logger. "User was
  // at bottom, scrolled up 200px" vs "Auto-stick fired,
  // isAtBottom is true again" are the two events that answer
  // every "why did the chat jump?" question.
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
  // ── Top edge transitions ─────────────────────────────────────────────
  //
  // Mirrors the bottom-edge logging above. The two edges behave
  // symmetrically: the user can be 200px from the top and have
  // `loadMore` fire (the lazy-load threshold), but the
  // `reached-top` state-transition log only fires at <10px — the
  // same `BOTTOM_THRESHOLD` analog (`TOP_THRESHOLD`). A user who's
  // at the top of the chat is by definition within lazy-load range,
  // so the `reached-top` line should ALWAYS be followed by either:
  //   - `load-more-threshold-reached` (the loadMore fired)
  //   - `load-more-suppressed`  (a guard blocked it)
  // If you see `reached-top` with neither of those, the loadMore
  // event was lost (e.g. the VirtualScroller's onScroll debounce
  // was reset by a new scroll event, or the handler returned
  // before debounce fired).
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
  // Tight 10px threshold: a chat message is typically 50-100px tall, so
  // reading the last message puts you well outside this window. This
  // prevents SSE chunks, the messages-length watcher, and the spacer
  // MutationObserver from yanking the user back to the bottom while
  // they're reading history.
  //
  // The initial chat load is unaffected — it uses `scrollToBottom(true)`
  // (force=true), which always scrolls regardless of this flag. So
  // opening a session still lands at the bottom, but once the user
  // scrolls up even a few pixels, the auto-scroll disengages.
  //
  // ── Content-grew-under-a-stationary-viewport guard (task_1787595375531_0) ──
  //
  // When scrollHeight grows (SSE chunk / measurement pass) while the
  // user's scrollTop is UNCHANGED (deltaTop === 0), the user did NOT
  // scroll — the bottom simply moved away from them. Flipping
  // isAtBottom=false here permanently disengages the auto-stick: every
  // later contentShift sees isAtBottom=false and skips (the
  // `spacer-resize-skip` log), so the gap never closes and grows with
  // every chunk — the "huge blank space below" symptom.
  //
  // Log evidence (scroll#228→#231): top=10638 constant, scrollHeight
  // 11641→11732 (+91), bottom 0→91px, `left-bottom` fired with
  // deltaTop=0, then every re-stick skipped forever after.
  //
  // Fix: only DIS-engage when the user actually moved (deltaTop < 0 —
  // a real upward scroll). A stationary viewport with growing content
  // keeps the stick engaged so the next contentShift re-stick closes
  // the gap.
  //
  // ── Round-2 refinement (task_1787638309623_3): previousIsAtBottom gate ──
  //
  // The round-1 guard (`newIsAtBottom || (contentGrew && !userScrolledUp)`)
  // couldn't distinguish "user AT bottom, content grows away" from "user
  // ALREADY scrolled up reading, content grows below, viewport
  // stationary". In the second case it RE-ENGAGED the stick
  // (previousIsAtBottom=false → true), and the next contentShift yanked
  // the user to the bottom mid-read — the "bouncing text" symptom.
  //
  // Log evidence (scroll#234-#247): user scrolling up (top 33249→30533,
  // bottom 4436px), SSE chunk grew scrollHeight +172 with deltaTop≈0,
  // `spacer-resize-stick` fired and teleported the user to top=35039
  // (bottom=4px).
  //
  // Fix: only RETAIN the stick if it WAS engaged. A user who already
  // scrolled up must never be re-engaged by content growth — only by
  // actually scrolling back down to the bottom (newIsAtBottom).
  // ── Programmatic-write guard (2026-08-25 append-gap fix) ──────────────
  //
  // `userScrolledUp` must mean "the USER scrolled up", not "scrollTop
  // decreased". VirtualScroller's anchor compensation (measureItems)
  // and endPreserve restoration write scrollTop directly; those writes
  // fire native scroll events that arrive here with
  // `isProgrammatic=true` (4th emit arg). A downward compensation
  // (measured height < estimate — streamed markdown settling shorter)
  // previously read as a real upward gesture: isAtBottom flipped
  // false, the auto-stick disengaged, and every later SSE chunk's
  // contentShift hit the spacer-resize-skip guard — the gap below the
  // last message accumulated with each chunk and never self-healed.
  const userScrolledUp = !isProgrammatic && deltaTop < 0
  // ── Fix: cap retention (2026-09-02) ───────────────────────────────
  // Previously retained even with bottom=1730px gap, keeping
  // isAtBottom=true forever and causing every contentShift to stick
  // even when user is far from bottom. Only retain when gap is small.
  const retainedThroughGrowth =
    previousIsAtBottom && contentGrew && !userScrolledUp && distanceFromBottom < 100
  const nextIsAtBottom = newIsAtBottom || retainedThroughGrowth
  // ── Deep-dive: isAtBottom decision (2026-09-02) ────────────────────
  // Log every time the retained path changes the outcome, or when
  // contentGrew is true (the blinking-loop trigger). This is the
  // single line that answers "why did isAtBottom stay true with
  // bottom=1633px?" — without it you have to infer from
  // spacer-resize-stick vs skip.
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
  // ── Realtime pill highlight ───────────────────────────────────────
  // Light the rail pill for the latest user turn at/above the viewport
  // BOTTOM as the user scrolls (previously the pill only lit on
  // click-jump, so scrolling never activated any pill; and anchoring to
  // the rendered window top lit index 0 whenever the window rendered
  // from 0 — the overscan buffer above the viewport. See
  // estimateViewportEnd). Pure display-ref write — no scroll writes,
  // so it can't fight the auto-stick logic above.
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

// ─── SSE ─────────────────────────────────────────────────────────────────────

// Bus listener unsubscribes. Declared at script-setup scope so they
// persist across `connectSse`/`disconnectSse` calls (re-declaring them
// inside the function would reset them to null on every mount, losing
// the unsubscribe). Initialized to null; set by `connectSse`, cleared
// by `disconnectSse`. Same pattern as the existing `sseScrollPending`
// flag below.
let offLlm: (() => void) | null = null
let offQueue: (() => void) | null = null
// Stale-on-wake (cross-tab sharing): fires when this window takes over the
// shared SSE connection, or returns from a long hidden period, so the visible
// chat never shows a stale history. See `helpers/sseTabChannel.ts`.
let offResync: (() => void) | null = null

const persistSseFullRowLocally = (
  sid: string,
  event: api.SseEvent,
  role: Message['role'],
  messageId: string,
  timestamp: Date,
): void => {
  try {
    const evtSec = (event as unknown as { created_at?: number }).created_at
    const createdAt = Number.isFinite(Number(evtSec))
      ? Number(evtSec)
      : Math.floor(timestamp.getTime() / 1000)
    void runSyncVoid(
      chatEngineDb.putLocal(sid, [
        toChatMessage(sid, {
          id: messageId,
          role,
          content: event.content || '',
          created_at: createdAt,
          tool_name: event.tool_name,
          diffview_before: event.diffview_before,
          diffview_after: event.diffview_after,
          image_url: event.image_url,
          video_url: event.video_url,
          finish_reason: event.finish_reason,
          tool_calls_json: event.tool_calls_json,
          tool_call_id: event.tool_call_id,
          is_input: event.is_input,
          is_output: event.is_output,
          reasoning_content: event.reasoning_content || undefined,
        }),
      ]),
      'messages.putLocal',
    )
  } catch {
    // Cache writes are advisory; the live message is already updated.
  }
}

const connectSse = () => {
  console.log('[connectSse] Connecting SSE via sseBus for session:', sessionId.value)
  const sid = sessionId.value
  if (!sid) return
  if (liveMessageSessionId !== sid) {
    liveMessageSessionId = sid
    liveMessageIds.clear()
  }

  // Defensive: if a previous connectSse didn't clean up (e.g. mid-mount
  // session change), tear down before re-registering. The bus's single
  // global EventSource is already open (App.vue opens it once), so we
  // only need to manage our listener subscriptions here.
  disconnectSse()

  streamingContent.value = ''

  // App.vue normally installs the bus in its own onMounted, which runs
  // after a child ChatView mounts. Install lazily here as well so an
  // early subscription is never silently lost.
  installSseBus()
  const bus = useSseBus()
  // Subscribe FIRST so we don't miss any bus events that arrive between
  // registration and the next tick. The `event.session_id !== sid` filter
  // is defense-in-depth — the bus's single global EventSource carries
  // ALL sessions' llm/queue events (no per-session routing), and the
  // listener-side filter scopes each ChatView to its own sid.
  offLlm = bus.on('llm', (event: api.SseEvent) => {
    if (event.session_id !== sid) return

    console.log('[SSE ChatView] Received event:', event)

    // 2026-08-23 spawn-subagent-live-progress: route sub-agent
    // progress events into the per-tool_call_id map and STOP here.
    // Touching `messages.value` would pollute the chat transcript
    // (these rows are ephemeral, NOT persisted) and would also
    // toggle the dedupe gate above. The progress map is the
    // SINGLE consumer for role="subagent_progress".
    if ((event as SubAgentProgressEvent).role === 'subagent_progress') {
      subAgentProgressMap.value = applyProgressEvent(
        subAgentProgressMap.value,
        event as SubAgentProgressEvent,
      )
      return
    }

    if (event.type === 'connected' && event.session_id) {
      console.log('SSE connected, session:', event.session_id)
      return
    }

    // 2026-08-23 llm-chunk-streaming: gate on the three event types
    // ChatView actually handles — `chunk` (append delta), `chunk_final`
    // (token-stream-end marker that updates maxTotalTokens), and `full`
    // (replace streaming-* row with canonical DB row). Other types
    // (`reasoning_chunk`, `tool_call_delta`, `connected`) are handled
    // by their own dedicated branches above.
    if (event.type !== 'chunk' && event.type !== 'chunk_final' && event.type !== 'full') {
      return
    }

    // 2026-08-25 agent-error-card (task_1787663566535_2) +
    // 2026-08-25 dedupe (task_1787668954023_2): agentic-loop diagnostics
    // (retry attempts + TooManyRetries bails) arrive as `full` events
    // with is_error=true. Route them into the dedicated agentError slot
    // (single-card, latest-wins) and STOP — they must never enter
    // messages.value (they'd render as a plain user bubble and pollute
    // the transcript). Each new error overwrites the previous one
    // (so 1/10 → 2/10 → ... → 10/10 all show on the same card).
    // The card also auto-clears as soon as ANY non-error `full` event
    // arrives below in this handler, or on a non-error `chunk_final`
    // run-end marker — i.e. the moment the agent recovers from the
    // retry chain, the error disappears.
    if (event.type === 'full' && event.is_error) {
      agentErrorStore.setError(sid, event.content || '', event.id || undefined)
      nextTick(() => scrollToBottom(false, 'agent-error-card'))
      return
    }

    if (event.type === 'chunk' && event.content) {
      // 2026-08-23 llm-chunk-streaming: the backend sends RAW DELTAS
      // (choices[0].delta.content per provider SSE), so APPEND here —
      // the old `=` replace left only the last fragment visible.
      streamingContent.value += event.content
      streamContentVersion += 1
      updateStreamingMessage()
      return
    }

    // 2026-08-23 llm-chunk-streaming: in-stream final marker emitted by
    // workflow.zig right before the canonical llm_full row. Carries
    // usage + signals "token stream over" so the typing indicator can
    // stop early. Do NOT push a message here — the full event that
    // follows replaces the streaming-* row with the canonical DB row.
    // 2026-09-10 agent-error-chunk_final-clear: a non-error chunk_final
    // means the token stream completed, i.e. the agent recovered from
    // any prior retry chain — clear the error card here too, so a
    // terminal `full` that lacks finish_reason / renderable payload
    // can't leave a stale card behind.
    if (event.type === 'chunk_final') {
      if (event.total_tokens) {
        maxTotalTokens.value = event.total_tokens
      }
      if (!event.is_error && agentErrorStore.bySession[sid]) {
        console.log('[SSE ChatView] clearing agent error card on chunk_final (run-end)')
        agentErrorStore.clearForSession(sid)
      }
      return
    }

    // 2026-08-23 hidden-messages fix — the gate previously required
    // `event.content` to be truthy, which silently DROPPED every `full`
    // event whose content was empty: tool-result rows (role='tool',
    // empty raw content — the card renders from tool_name + envelope),
    // image-only user echoes, and thinking-only assistant turns. All
    // of those are renderable now (filteredMessages exemptions +
    // reasoning section), so accept any event that has a finish_reason
    // and at least ONE renderable field.
    const hasRenderableFullPayload = !!(
      event.content ||
      event.reasoning_content ||
      event.tool_call_id ||
      event.tool_name ||
      (event.image_url && event.image_url.length > 0) ||
      (event.video_url && event.video_url.length > 0)
    )
    if (event.type === 'full' && event.finish_reason && hasRenderableFullPayload) {
      // 2026-08-25 task_1787668954023_2: any non-error `full` event that
      // passes the renderable gate means the agent is alive and
      // producing output — clear the error card so it disappears the
      // moment the agent recovers from the retry chain.
      if (agentErrorStore.bySession[sid]) {
        console.log('[SSE ChatView] clearing agent error card on non-error full event')
        agentErrorStore.clearForSession(sid)
      }
      // 2026-09-06 virtual-scroller shrink fix: capture the streaming
      // group's height key BEFORE the filter drops the placeholder —
      // the canonical row pushed below has a new DB id (new group key,
      // no stored height → sizer dip). Transferred after the push.
      const streamingGroupKey = groupKeyForMessageId(
        messages.value.find((m) => m.id.startsWith('streaming-'))?.id ?? '',
      )
      messages.value = messages.value.filter((m) => !m.id.startsWith('streaming-'))

      const role =
        (event.role as 'user' | 'assistant' | 'system' | 'tool') ||
        (event.tool_call_id ? 'tool' : 'assistant')

      // 2026-09-01 fix: placeholder → final update for the same tool
      // call shares the same `id` (row id). The placeholder SSE (empty
      // `<data>`) arrives first, then the final SSE (`<results>`) for
      // the same row. Without this, the frontend would push a DUPLICATE
      // message (same id, same tool_call_id, different content) and
      // render two cards. Update in place instead.
      if (event.id) {
        const existingById = messages.value.find((m) => m.id === event.id)
        if (existingById) {
          // In-place update — preserve timestamp, refresh all wire fields
          existingById.content = event.content || ''
          existingById.role = role
          existingById.tool_name = event.tool_name
          existingById.tool_call_id = event.tool_call_id
          existingById.finish_reason = event.finish_reason
          existingById.tool_calls_json = event.tool_calls_json
          existingById.reasoning_content = event.reasoning_content || undefined
          existingById.diffview_before = event.diffview_before
          existingById.diffview_after = event.diffview_after
          existingById.image_urls = splitMediaUrlsWire(event.image_url)
          existingById.video_urls = splitMediaUrlsWire(event.video_url)
          existingById.is_input = event.is_input
          existingById.is_output = event.is_output
          rememberLiveMessage(sid, event.id, role)
          persistSseFullRowLocally(sid, event, role, event.id, existingById.timestamp)
          streamingContent.value = ''
          isStreaming.value = false
          scrollLogger.markProgrammatic()
          lastAutoStickAt.value = Date.now()
          nextTick(() => {
            if (isAtBottom.value) virtualScrollerRef.value?.remeasure()
            scrollToBottom(false, 'sse-message-update')
          })
          setupCodeBlockCopyButtons()
          if (
            role === 'tool' &&
            event.tool_name === 'spawn_sub_agent' &&
            event.tool_call_id &&
            subAgentProgressMap.value[event.tool_call_id]
          ) {
            subAgentProgressMap.value = clearProgressFor(
              subAgentProgressMap.value,
              event.tool_call_id,
            )
          }
          if (event.total_tokens) {
            maxTotalTokens.value = event.total_tokens
          }
          // Live skills: backend piggybacks session_skills on every llm_full
          // (fresh on tool-result emit, stale on assistant emit — see
          // handle_tool.zig:459 vs :745). REST remains initial source.
          // Scoped by the event.session_id !== sid filter at handler entry.
          if (Array.isArray(event.session_skills))
            sessionSkills.value = event.session_skills as api.SkillInfo[]
          maybeRefreshWorktreeBinding(role, event.tool_name)
          return
        }
      }

      // 2026-08-23 TOOLS-pill-spam fix — the backend re-emits an SSE for
      // EVERY tool completion via getLatestMessage(), which (backend bug
      // B1, see handle_tool.zig) often returns the ASSISTANT tool_calls
      // row instead of the completed tool placeholder. The frontend then
      // receives several role=assistant events with tool_calls_json per
      // turn; each became a new assistant group and groupToolNames
      // rendered a "TOOLS" pill for each — pill spam between tool rows.
      // Dedupe: skip any event that duplicates an existing message on
      // role + content + tool_call_id. Genuine repeats from the server
      // (same DB row re-emitted) collapse to one; distinct rows differ
      // in tool_call_id and still render.
      const dup = messages.value.find((m) => {
        if (m.role !== role) return false
        if ((m.tool_call_id ?? '') !== (event.tool_call_id ?? '')) return false
        return m.content === (event.content || '')
      })
      if (
        dup &&
        // 2026-08-23: the optimistic-user dedupe that lived here is
        // gone — handleFileInputSubmit no longer pushes a local
        // placeholder. User echoes arrive fresh with a stable DB id;
        // a same-content repeat (server re-emit) collapses to one
        // message via the dedupe above.
        role !== 'user'
      ) {
        console.log('[SSE ChatView] duplicate full event skipped', {
          role,
          tool_call_id: event.tool_call_id,
          content_len: (event.content || '').length,
        })
        return
      }

      const messageId = event.id || `assistant-${Date.now()}`
      const messageTimestamp = new Date()
      rememberLiveMessage(sid, messageId, role)
      messages.value.push({
        id: messageId,
        role: role,
        content: event.content || '',
        timestamp: messageTimestamp,
        tool_name: event.tool_name,
        diffview_before: event.diffview_before,
        diffview_after: event.diffview_after,
        // Decode the `||`-joined wire string the backend sends. A plain
        // `split('|')` would turn `A||B` into `["A", "", "B"]`, and the
        // empty entry renders as `<img src="">` — a broken-image icon in
        // the transcript. `splitMediaUrlsWire` drops empty segments, so
        // `A|B`, `A||B` and `A||B||C` all decode to N real URLs.
        image_urls: splitMediaUrlsWire(event.image_url),
        video_urls: splitMediaUrlsWire(event.video_url),
        finish_reason: event.finish_reason,
        tool_call_id: event.tool_call_id,
        // 2026-08-24 (task_1787545088500_6, bug A) — carry the wire
        // field through the SSE full-event push. Without this, the
        // SSE path arrived at groupToolNames with tool_calls_json
        // undefined → JSON.parse never ran → suppression was bypassed
        // → "tools" pill flashed between every card. The REST path
        // (loadChatHistory ~line 1579) already had this — keep both
        // sites in sync.
        tool_calls_json: event.tool_calls_json,
        is_input: event.is_input,
        is_output: event.is_output,
        // 2026-08-23 hidden-messages fix — carry reasoning through so
        // thinking-only turns render their collapsible section.
        reasoning_content: event.reasoning_content || undefined,
      })
      // Write-through: persist the SSE `full` row with its full wire shape
      // so cached mounts render it identically. Best-effort.
      persistSseFullRowLocally(sid, event, role, messageId, messageTimestamp)
      // 2026-09-06 virtual-scroller shrink fix: move the streaming
      // group's measured height onto the canonical row's key so the
      // sizer never dips through the 64px estimate for a frame.
      // Best-effort — missing keys are a no-op (rekeyHeight guards).
      if (streamingGroupKey && event.id) {
        const newGroupKey = groupKeyForMessageId(event.id)
        if (newGroupKey && newGroupKey !== streamingGroupKey) {
          virtualScrollerRef.value?.rekeyHeight(streamingGroupKey, newGroupKey)
        }
      }
      streamingContent.value = ''
      isStreaming.value = false
      scrollLogger.markProgrammatic()
      // One more auto-stick fires (scrollToBottom below) for the
      // final, post-stream assistant message. Mark the timestamp so
      // the loadMore gate sees the stick as still active during the
      // tail of the message-complete render frame. After ~500ms
      // (AUTO_STICK_GATE_MS) the gate lifts and the user can
      // scroll-up-and-prepend as normal.
      lastAutoStickAt.value = Date.now()
      nextTick(() => {
        // Recompute the height model BEFORE the auto-stick (append-gap
        // fix): the streaming-* row was just replaced by the canonical
        // DB row, which re-renders at a DIFFERENT height (markdown
        // settles, reasoning collapses). nextTick first — the DOM must
        // reflect the swap before offsetHeight reads mean anything.
        // Gated on isAtBottom: a scrolled-up reader must not be
        // disturbed by sizer mutations (the bouncing bug); the at-
        // bottom case gets an exact sizer so the stick lands on the
        // real last message, not in a phantom region.
        if (isAtBottom.value) virtualScrollerRef.value?.remeasure()
        scrollToBottom(false, 'sse-message-complete')
      })
      setupCodeBlockCopyButtons()

      // 2026-08-23 spawn-subagent-live-progress: when the FINAL
      // spawn_sub_agent tool result row lands, drop the
      // corresponding live-progress entry so the parsed-envelope
      // view (which lives in `content`) takes over rendering
      // immediately. Without this, the map's running rows would
      // sit invisibly under the now-populated <results> envelope
      // (the component precedence logic hides them, but the map
      // memory leaks across renders).
      if (
        role === 'tool' &&
        event.tool_name === 'spawn_sub_agent' &&
        event.tool_call_id &&
        subAgentProgressMap.value[event.tool_call_id]
      ) {
        subAgentProgressMap.value = clearProgressFor(subAgentProgressMap.value, event.tool_call_id)
      }

      if (event.total_tokens) {
        maxTotalTokens.value = event.total_tokens
      }
      // Live skills: backend piggybacks session_skills on every llm_full
      // (fresh on tool-result emit, stale on assistant emit — see
      // handle_tool.zig:459 vs :745). REST remains initial source.
      // Scoped by the event.session_id !== sid filter at handler entry.
      if (Array.isArray(event.session_skills))
        sessionSkills.value = event.session_skills as api.SkillInfo[]
      maybeRefreshWorktreeBinding(role, event.tool_name)

      return
    }

    // 2026-08-23 hidden-messages fix — reasoning chunks used to be
    // console.log-only. Accumulate them onto the streaming assistant
    // message so the collapsible reasoning section renders live while
    // a thinking model works (before any final content arrives).
    if (event.reasoning_content && !event.content) {
      console.log('Reasoning:', event.reasoning_content)
      const existingMsg = messages.value.find(
        (m) => m.role === 'assistant' && m.id.startsWith('streaming-'),
      )
      if (existingMsg) {
        existingMsg.reasoning_content =
          (existingMsg.reasoning_content || '') + event.reasoning_content
      } else {
        messages.value.push({
          id: `streaming-${Date.now()}`,
          role: 'assistant',
          content: '',
          timestamp: new Date(),
          reasoning_content: event.reasoning_content,
        })
      }
    }
  })
  offQueue = bus.on('queue', (event: api.QueueMessageEvent) => {
    if (event.session_id !== sid) return
    console.log('[QueueMessages SSE] Received event:', event)
    if (event.action === 'queued') {
      queuedMessages.value.push({
        id: event.id ?? `q-${Date.now()}`,
        message: event.message,
      })
      // A queued turn renders no transcript row — it is only ever a row in the
      // composer's queue panel — so nothing in `messages` grows and none of
      // the auto-stick triggers fire. The row that finally reaches the
      // transcript is the live worker draining this turn, which can be minutes
      // away, and by then the reader may well have scrolled off the end. Arm
      // the follow now, at the moment they asked for the turn.
      followNewestTurn('queue-queued')
    } else if (event.action === 'deleted') {
      queuedMessages.value = queuedMessages.value.filter((m) => m.id !== event.id)
    }
  })
  // Stale-on-wake (cross-tab sharing): if this window just took over the shared
  // connection, or slept through a long hidden period, llm/queue events may have
  // been missed entirely — fetch just the tail (cursor+asc) and merge it. A
  // full loadChatHistory here repainted the whole list, yanked the scroll
  // position, and (before the newestCursor fix) re-fetched up to PAGE_SIZE
  // rows on every tab return. Empty view (nothing painted yet) still takes
  // the full path so the first paint, cursor, and scroll state initialize.
  offResync =
    bus.onResync?.(() => {
      if (sessionId.value !== sid) return
      void (async () => {
        try {
          if (messages.value.length === 0) {
            await loadChatHistory()
            return
          }
          const delta = await runSyncEffect(
            chatEngineDb.loadDelta(sid, PAGE_SIZE, liveMessageIds),
            'messages.loadDelta',
          )
          if (!delta || sessionId.value !== sid) return
          applyDeltaExtra(delta.extra)
          if (delta.items.length > 0) {
            const fresh = toChatMessages(delta.items.map((i) => i.raw))
            if (fresh.length > 0) {
              const liveMessagesAtMerge = currentLiveMessages()
              messages.value = mergeMessagesById(
                mergeMessagesById(messages.value, fresh),
                liveMessagesAtMerge,
              )
              if (isAtBottom.value) scrollToBottom(false, 'sse-resync-delta')
            }
          }
        } catch {
          // Painted messages stand; the next mount retries the tail.
        }
      })()
    }) ?? null
  // Set isStreaming LAST so external observers (tests, UI) can poll
  // it as a "listeners are wired up" signal — flipping it before
  // would race with test assertions that fire events into the bus
  // expecting the listener to be registered.
  isStreaming.value = true
}

const disconnectSse = () => {
  if (offLlm) {
    offLlm()
    offLlm = null
  }
  if (offResync) {
    offResync()
    offResync = null
  }
  if (offQueue) {
    offQueue()
    offQueue = null
  }
  isStreaming.value = false
  streamingContent.value = ''
  messages.value = messages.value.filter((m) => !m.id.startsWith('streaming-'))
}

// Coalesce flag for SSE-driven `scrollToBottom` calls. SSE chunks
// can fire 20+ times/sec, but we only need one scrollToBottom per
// animation frame. Without this, the console floods with
// `scroll-to-bottom-conditional` lines and we do redundant geometry
// reads. The user reads content, not scroll position — one frame
// (16ms) of lag is imperceptible.
//
// Declared at script-setup scope so the flag persists across calls
// to `updateStreamingMessage` (re-declaring it inside the function
// would reset it every time, defeating the coalesce).
let sseScrollPending = false

const updateStreamingMessage = () => {
  console.log('[updateStreamingMessage] streamingContent:', streamingContent.value)
  // Every SSE chunk drives an auto-stick via scrollToBottom below
  // (coalesced to one-per-frame). Mark the timestamp NOW, before the
  // rAF coalesce, so the gate reflects the chunk that just arrived
  // — not the rAF callback that runs up to 16ms later. With chunks
  // firing 20+/sec this keeps the gate always-fresh during active
  // streaming; with a slow model the timestamp goes stale between
  // chunks and the user can loadMore.
  lastAutoStickAt.value = Date.now()
  const existingMsg = messages.value.find(
    (m) => m.role === 'assistant' && m.id.startsWith('streaming-'),
  )
  if (existingMsg) {
    existingMsg.content = streamingContent.value
  } else {
    messages.value.push({
      id: `streaming-${Date.now()}`,
      role: 'assistant',
      content: streamingContent.value,
      timestamp: new Date(),
    })
  }
  const stripped = stripThinkingTags(streamingContent.value)
  if (stripped && stripped.trim() !== '') {
    // Coalesce: SSE chunks can fire 20+ times/sec, but we only need
    // one scrollToBottom per animation frame. Without this, the
    // console floods with `scroll-to-bottom-conditional` lines and
    // we do redundant geometry reads. The user reads content, not
    // scroll position — one frame (16ms) of lag is imperceptible.
    if (!sseScrollPending) {
      sseScrollPending = true
      requestAnimationFrame(() => {
        sseScrollPending = false
        scrollLogger.markProgrammatic()
        // Recompute the height model BEFORE scrolling (append-gap fix),
        // but ONLY when the stick is engaged. A scrolled-up user must
        // not be disturbed: remeasure mutates the sizer, and sizer
        // mutations during active reading = the bouncing-text bug.
        // Gaps below are acceptable while reading; the moment the user
        // returns to the bottom, this branch re-runs and tightens.
        if (isAtBottom.value) virtualScrollerRef.value?.remeasure()
        scrollToBottom(false, 'sse-chunk')
      })
    }
  }
  nextTick(() => setupCodeBlockCopyButtons())
}

// ─── Init ──────────────────────────────────────────────────────────────────────

onMounted(async () => {
  sessionId.value = props.chatId.replace(/^chat-/, '')
  // Replaces the old sessionId watchers (profile load + scroll-logger
  // refresh): the id is fixed for the component lifetime.
  void onSessionChanged(sessionId.value)

  if (props.cwd) {
    sessionCwd.value = props.cwd
  }

  // Refresh lands on chat, never auto-opens the diff: a reload keeps the
  // ?diff= the scroll-spy wrote while the viewer was open, and the panel
  // no longer restores from it — strip it here so the URL stays truthful
  // (Back does the same on explicit exit).
  // NOTE: left exactly as-is on purpose. Optional-chaining this read (the
  // obvious fix for a router-less mount) makes onMounted run FURTHER in unit
  // mounts where `useRoute()` is undefined, and two unrelated ChatView specs
  // (profile picker, autofocus) were written against the early-abort
  // behaviour — they fail. Turning it into a behaviour change belongs with
  // those specs, not with the diff view.
  if (typeof route.query.diff === 'string' && !showCenterDiff.value) syncDiffParam(null)

  if (sessionId.value) {
    // Seed the re-stick baseline BEFORE loadChatHistory so we catch the
    // very first measurement-driven contentShift. The VirtualScroller's
    // child component mounts before us (child before parent in Vue 3),
    // so its containerRef is already populated.
    lastObservedScrollHeight = virtualScrollerRef.value?.containerRef?.scrollHeight ?? 0

    // Subscribe before the history request. A tool can finish while the
    // initial REST load is in flight; waiting until afterward misses that
    // event permanently because the placeholder's creation-time cursor does
    // not change when its result is updated in place.
    try {
      connectSse()
      startGitStatusPoll()
    } catch (err) {
      console.warn('[ChatView] SSE init failed (likely torn down by test cleanup):', err)
    }

    await loadChatHistory()
    // 2026-09-02 stream-resume-on-reselect (task_1787673548905_0) —
    // seed the streaming-* placeholder with the backend's partial text so
    // subsequent chunk events APPEND to the recovered content instead of
    // starting from an empty buffer. The SSE listener is already active.
    // Best-effort: a failed snapshot fetch must never block chat loading.
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
    // Session switch remounts this view — land the cursor in the
    // message box so the user types immediately (no second click).
    // Best-effort: focus must never reject the mount (e.g. peek-embed
    // hides the input, so fileInputRef stays null).
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

// Load available profiles (called once on mount)
loadProfiles()
document.addEventListener('click', closeOnOutsideClick)
// `<html>` blocks auto-size themselves via postMessage (see
// onHtmlFrameResize above). Registered here — paired with the
// removeEventListener in onUnmounted — for the same lifetime as the
// other window-level listener this view owns.
window.addEventListener('message', onHtmlFrameResize)

// Session-change entry point (replaces the two old sessionId watchers).
// The component is keyed per chat, so the id is fixed for the component
// lifetime — this runs once from onMounted below. It loads the session's
// profile selection AND refreshes the scroll logger so the chatId tag in
// every line stays accurate.
const onSessionChanged = async (newId: string) => {
  refreshScrollLogger()
  // Any page armed for the previous session is invalid — drop it before
  // the new session's history loads.
  resetOlderPrefetch('session-change')
  if (!newId) {
    selectedProfile.value = null
    return
  }
  try {
    const session = await api.getSession(newId)
    const raw = session?.selectedProfile ?? null
    selectedProfile.value = typeof raw === 'string' ? raw : null
  } catch (err) {
    console.error('Failed to load session profile:', err)
    selectedProfile.value = null
  }
}

// Auto-stick on new messages (replaces the old messages.length watcher).
// `onUpdated` with a prev-length guard fires for every append path (user
// sends, SSE chunks, tool results) exactly like the watcher did, and the
// isAtBottom gates keep scrolled-up readers undisturbed.
let prevMessagesLength = messages.value.length
onUpdated(() => {
  if (messages.value.length === prevMessagesLength) return
  prevMessagesLength = messages.value.length
  {
    if (isInitialLoad) return // initial-load branch handled scroll explicitly
    if (!isAtBottom.value) return // don't disturb scrolled-up readers
    scrollLogger.markProgrammatic()
    // Any push to `messages` triggers an auto-stick (scrollToBottom
    // below). Mark the timestamp synchronously so the loadMore gate
    // sees the stick as active during the same render frame the
    // message landed in. Catches user-message sends, tool results,
    // pagination prepends (handled separately by endPreserve, but
    // the watcher also fires), and the streaming message's first
    // push before updateStreamingMessage's own mark takes over.
    lastAutoStickAt.value = Date.now()
    nextTick(() => {
      // Recompute the height model BEFORE the auto-stick (append-gap
      // fix): a new item's real height is unknown until it renders;
      // the sizer's estimate may overshoot (phantom gap) or undershoot
      // (stick lands short). Gated on isAtBottom — scrolled-up readers
      // are never disturbed; at-bottom users get an exact sizer so the
      // stick shows the real last message. (The gate MUST be re-checked
      // here, not just at fire time above: the user can scroll up in
      // between, and sizer mutations during active reading are the
      // bouncing-text bug — same contract as updateStreamingMessage's
      // rAF branch.)
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

  // Converting attachments (especially video, up to 25 MB) to base64
  // blocks the send for seconds with no feedback. Flip the Send
  // button into its loading state for the whole convert + POST
  // window so the user waits instead of double-clicking Send.
  isSendingAttachments.value = true
  let imageUrls: string[] = []
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
      imageUrls = await Promise.all(files.map((f) => fileToBase64(f)))
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

  // 2026-08-23 auto-collapse fix — NO optimistic local push.
  // Previously the user's own message was pushed to `messages` with a
  // synthetic `optimistic-user-*` id, then replaced when the backend's
  // queue-drain re-emitted it via SSE `full`. Two problems:
  //   (a) the local push sat at the END of the array, while the
  //       server's canonical row carried the correct DB id and
  //       chronological position — the optimistic was visible only
  //       briefly before the dedupe swapped them;
  //   (b) every push shifted `messageGroups`, which — combined with
  //       positional expand keys — silently re-keyed tool cards the
  //       user had just expanded (see expandedToolIds comment).
  // Now we let the SSE echo deliver the canonical row. The user sees
  // a brief gap (server round-trip) but the rendered card carries the
  // real DB id from the start, with stable expansion semantics.

  try {
    await api.sendChatMessage(
      currentSessionId,
      userMessage,
      sessionCwd.value,
      imageUrls,
      selectedProfile.value ?? undefined,
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
    // The first pin aimed at the bottom of the transcript as it stood BEFORE
    // this turn — there is no optimistic push, so the turn is still in flight
    // at this point and the bottom moves when it renders. Pin again against
    // the settled position so the turn the server accepted is the one on
    // screen, whether it arrived over SSE or was pushed here as an error card.
    followNewestTurn('send-message-settled')
  }
}

// ─── Stop session ──────────────────────────────────────────────────────────
//
// The FileInput component renders a Stop button (visible only when
// `isLLMProcessing === true`) that emits `stop-session`. We translate
// that into a `POST /api/llm/session/<sid>/stop` which flips the
// worker's `cancelled` flag. The workflow breaks at the next iteration
// boundary, deletes the worker, and the SSE `worker deleted` event
// removes the session from `processingState`. The button's
// `v-if="isLLMProcessing"` auto-hides when that event lands.
//
// We deliberately do NOT optimistically flip `isLLMProcessing`
// locally — the SSE event races with the API response and could
// cause a flicker (button hides → re-shows → hides). FileInput owns
// its own `isStopping` flag for the spinner; `processingState` is the
// source of truth.
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
    <div :ref="setChatColumnEl" class="relative flex flex-col h-full flex-1 min-w-0 chat-column">
      <!--
        Chat app bar. Rendered only when the parent passed the
        `showHeader` prop. Every task-chat host sets it (kanban
        branch, AgentChatView, StandardTaskChatView) so all three
        workspace-item modes get the identical bar; the standalone
        `chat-<id>` branch leaves it false so a bare chat still
        fills the viewport edge-to-edge. The markup itself lives in
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
          <!-- How long this session's worker has been running. Sits in the
               same extras slot the hosts project their SessionSlider into,
               so the number is visible while typing without touching the
               Stop button. -->
          <WorkerElapsedChip
            v-if="sessionId"
            :session-id="sessionId"
            test-id="chat-app-bar-elapsed"
          />
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
        <!-- Loading More indicator (floats above the scroller during pagination).

             Restored: while `maybeLoadOlder` / `commitOlderPage` run, the
             "Load more messages" button below is hidden (`!isLoadingMore`
             in its v-if), so with this block commented out the user got
             NO affordance at all — the button vanished and nothing
             replaced it until the page committed. -->
        <div
          v-if="isLoadingMore"
          class="absolute top-0 left-0 right-0 flex justify-center py-2 z-10 pointer-events-none"
          data-testid="chat-loading-more"
          role="status"
          aria-label="Loading older messages"
        >
          <div
            class="flex items-center gap-2 px-4 py-2 rounded-full shadow-sm"
            style="background-color: var(--semantic-card-bg)"
          >
            <div
              class="w-4 h-4 border-2 rounded-full animate-spin"
              style="border-color: var(--color-violet); border-top-color: transparent"
            ></div>
            <span class="text-body" style="color: var(--semantic-text-dim)">Loading more...</span>
          </div>
        </div>

        <!-- Initializing skeleton — shown while the first history fetch
             is outstanding (isInitializing): covers the mount gap where
             sessionId is still empty plus the getChatHistory round-trip.
             Shimmer rows keep layout stable so the transcript doesn't
             flash empty-state before content arrives. -->
        <div
          v-if="isInitializing"
          data-testid="chat-initializing-skeleton"
          class="flex flex-col gap-3 px-4 max-w-4xl mx-auto pt-6 w-full"
          role="status"
          aria-label="Loading conversation"
        >
          <div
            v-for="w in ['42%', '88%', '67%']"
            :key="w"
            class="h-4 rounded animate-pulse"
            :style="{ width: w, backgroundColor: 'var(--semantic-card-bg)' }"
          ></div>
        </div>

        <!-- Load error — `error` was previously write-only (set on fetch
             failure but never rendered). Shown only once initializing is
             over and no messages arrived. -->
        <div
          v-if="error && !isInitializing && messageGroups.length === 0"
          data-testid="chat-load-error"
          class="flex flex-col items-center justify-center h-full px-4"
        >
          <p class="text-body mb-3" style="color: var(--semantic-text-dim)">{{ error }}</p>
          <button
            @click="loadChatHistory()"
            class="px-4 py-1.5 rounded-full text-dense"
            style="
              background-color: var(--semantic-card-bg);
              border: 1px solid var(--color-border);
              color: var(--semantic-text);
            "
          >
            Retry
          </button>
        </div>

        <!-- Empty State --
             Gated on `historyConfirmed`, NOT on "there are no messages".
             "Zero messages" and "we have not been told yet" are different
             states and only a completed load can tell them apart: before
             this gate, a slow or erroring backend — whose failure used to
             be swallowed into an empty transcript — rendered "How can I
             help you?" for sessions full of messages. -->
        <div
          v-if="
            historyConfirmed &&
            !isInitializing &&
            !isLoading &&
            !error &&
            messageGroups.length === 0
          "
          class="flex flex-col items-center justify-center h-full px-4"
        >
          <div
            class="w-16 h-16 rounded-2xl mb-4 flex items-center justify-center text-display"
            style="background: linear-gradient(135deg, var(--color-violet), var(--color-blue))"
          >
            <UiIcon name="chat" size-class="w-7 h-7" />
          </div>
          <h3 class="text-title-sm font-medium mb-2" style="color: var(--semantic-text)">
            How can I help you?
          </h3>
          <p class="text-body text-center" style="color: var(--semantic-text-dim)">
            Start a conversation by typing a message below
          </p>
        </div>

        <!--
          Load more messages button.

          Why this exists: the <VirtualScroller> below only emits @load-more
          when the user scrolls within `loadMoreThreshold` of the top of a
          *scrollable* container. When the loaded messages fit in the
          viewport (a common case for short tool/result chats, see the
          screenshot in docs/plans/2026-06-04-chat-lazy-load-button.md),
          the container is not scrollable, the scroll event never fires,
          and the user has no way to reach older messages.

          This button bypasses the scroll trigger and calls
          `maybeLoadOlder('manual')` — the same guard chain the scroll path
          uses, minus the auto-stick gate (an explicit click must not be
          swallowed by a stream). A page the prefetch already armed is
          committed from memory. It is hidden while a
          pagination is already in flight (`isLoadingMore`) so we don't
          show two spinners, hidden when the initial empty state is
          rendered (`messageGroups.length === 0`), and hidden when the
          container IS scrollable (`!scrollerIsScrollable` is false) —
          in that case the user can scroll to the top to load more, and
          showing the button would be UI clutter.

          Position: sibling of <VirtualScroller> inside the
          `messagesWrapperRef` flex container. The wrapper is
          `position: relative` (see line 1395) and a `flex flex-col`
          layout; this button is the first child so it sits above the
          scroller and is not subject to virtualization or the
          `beginPreserve`/`endPreserve` scroll-restoration dance.
        -->
        <div
          v-if="
            hasMoreMessages && !isLoadingMore && messageGroups.length > 0 && !scrollerIsScrollable
          "
          class="flex justify-center pt-2 pb-1"
          data-testid="load-more-messages"
        >
          <button
            @click="maybeLoadOlder('manual')"
            class="flex items-center gap-2 px-4 py-1.5 rounded-full text-dense transition-all duration-200 hover:scale-105"
            style="
              background-color: var(--semantic-card-bg);
              border: 1px solid var(--color-border);
              color: var(--semantic-text);
            "
            :title="`Load ${PAGE_SIZE} older messages`"
          >
            <span>↑</span>
            <span>Load more messages</span>
          </button>
        </div>

        <!-- Virtualized Message List.
             2026-08-23 fast-scroll responsiveness tuning:
             - default-item-height 200 -> 64: real rows are ~40-80px
               (one-line tool cards, short paragraphs). The old 200px
               estimate made top/bottom spacers 2.5-5x too tall, so a
               fast fling landed the estimated visible window deep inside
               spacer territory; content only appeared after measureItems
               caught up (~3s of blank). A closer estimate keeps the
               window near the real content from the first frame.
             - buffer 20 -> 30: cheap insurance for fast scrolls — more
               pre-rendered rows above/below means the viewport is
               already populated when the fling stops. -->
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
            <div
              class="px-4 max-w-4xl mx-auto"
              :class="[
                groupIndex === 0 ? 'pt-6' : '',
                isLastGroup(groupIndex) ? 'last-transcript-row' : '',
              ]"
              :data-group-key="groupKey(group)"
            >
              <div
                class="flex"
                :class="
                  group.role === 'user' && !isBgOnlyGroup(group) ? 'flex-row-reverse' : 'flex-row'
                "
              >
                <!-- Bubble / paragraph container.
                     2026-08-23 paragraph-mode: the AI (assistant) side no
                     longer renders as a chat bubble. The container keeps
                     the bubble chrome (padding, rounded corners, card bg,
                     border) ONLY for user groups; assistant + tool groups
                     render as transparent, borderless paragraphs that flow
                     with the page background — like a document, not a
                     messenger.
                     NOTE: empty groups are already filtered out of
                     messageGroups (see the computed) — this v-if is only
                     defense-in-depth. Do NOT move it to the slot root:
                     an unrendered group keeps its 200px height ESTIMATE
                     in the VirtualScroller forever, which desyncs the
                     estimated scroll model from the real DOM and blanks
                     the whole chat on scrollToBottom. -->
                <div
                  class="min-w-0"
                  :class="
                    group.role === 'user' && !isBgOnlyGroup(group)
                      ? 'max-w-[90%] w-fit ml-auto'
                      : 'flex-1 w-full max-w-full'
                  "
                >
                  <div
                    v-if="hasBubbleContent(group, groupIndex)"
                    class="text-body leading-relaxed"
                    role="button"
                    tabindex="0"
                    :class="
                      group.role === 'user' && !isBgOnlyGroup(group)
                        ? 'px-4 py-2.5 rounded-2xl whitespace-pre-wrap break-words'
                        : 'markdown-content'
                    "
                    :style="
                      group.role === 'user' && !isBgOnlyGroup(group)
                        ? 'background-color: var(--color-blue-1); color: var(--semantic-text); border-bottom-right-radius: 6px;'
                        : 'color: var(--semantic-text);'
                    "
                  >
                    <!-- ── User ── -->
                    <template v-if="group.role === 'user'">
                      <!-- Compaction envelope: render as a structured card
                           instead of a wall of escaped XML. -->
                      <CompactionCard
                        v-if="isCompactionMessage(group.messages[0])"
                        :content="group.messages[0]!.content"
                      />
                      <!-- Background completions: role=user on the wire,
                           tool card in pixels — transparent left-aligned
                           tool-sequence, never the blue bubble. -->
                      <template v-else-if="isBgOnlyGroup(group)">
                        <div class="tool-sequence">
                          <div
                            v-for="(bgMsg, bgIdx) in group.messages"
                            :key="bgMsg.id || `bg-${bgIdx}`"
                            class="tool-item"
                            :class="bgIdx < group.messages.length - 1 ? 'tool-item-border' : ''"
                          >
                            <ShellTool
                              tool-name="command"
                              :content="bgShellContent(bgMsg)"
                              :parameters="'{}'"
                            />
                          </div>
                        </div>
                      </template>
                      <!-- 2026-08-23 hidden-messages fix — v-for over ALL
                           messages in the group. The old template rendered
                           only group.messages[0], so consecutive user
                           messages (queue-drain bursts, rapid sends) beyond
                           the first were invisible: their text AND attached
                           images never appeared. Each message renders its
                           own images + text; empty-text messages with
                           images render images only. -->
                      <template v-else>
                        <template
                          v-for="(userMsg, userMsgIdx) in group.messages"
                          :key="userMsg.id || `u-${userMsgIdx}`"
                        >
                          <ChatAttachments
                            v-if="
                              (userMsg.image_urls && userMsg.image_urls.length > 0) ||
                              (userMsg.video_urls && userMsg.video_urls.length > 0)
                            "
                            :image-urls="userMsg.image_urls"
                            :video-urls="userMsg.video_urls"
                            @open-image="openImagePreview"
                          />
                          <template v-if="isBgUserMsg(userMsg)"
                            ><ShellTool
                              tool-name="command"
                              :content="bgShellContent(userMsg)"
                              :parameters="'{}'" /></template
                          ><template v-else
                            ><span v-if="userMsg.content">{{ userMsg.content }}</span></template
                          >
                        </template>
                      </template>
                    </template>

                    <!-- ── Tool ── -->
                    <template v-else-if="group.role === 'tool'">
                      <div class="tool-sequence">
                        <div
                          v-for="(msg, idx) in group.messages"
                          :key="msg.id || msg.tool_call_id || `t-${groupIndex}-${idx}`"
                          class="tool-item"
                          :class="idx < group.messages.length - 1 ? 'tool-item-border' : ''"
                        >
                          <ReadFile
                            v-if="msg.tool_name === 'read_file'"
                            :content="innerToolData(msg)"
                            :expanded="expandedToolIds.has(toolExpandKey(msg, groupIndex, idx))"
                            :cwd="sessionCwd"
                            :parameters="getParametersForMessage(msg)"
                          />
                          <WriteFile
                            v-else-if="msg.tool_name === 'write_file'"
                            :content="innerToolData(msg)"
                            :expanded="expandedToolIds.has(toolExpandKey(msg, groupIndex, idx))"
                            :cwd="sessionCwd"
                            :parameters="getParametersForMessage(msg)"
                          />
                          <UpdateActivity
                            v-else-if="msg.tool_name === 'update_activity'"
                            :content="innerToolData(msg)"
                            :expanded="expandedToolIds.has(toolExpandKey(msg, groupIndex, idx))"
                            :parameters="getParametersForMessage(msg)"
                          />
                          <Search
                            v-else-if="msg.tool_name === 'search'"
                            :content="innerToolData(msg)"
                            :expanded="expandedToolIds.has(toolExpandKey(msg, groupIndex, idx))"
                            :cwd="sessionCwd"
                            :parameters="getParametersForMessage(msg)"
                          />
                          <ReadWorkspaceSession
                            v-else-if="msg.tool_name === 'read_workspace_session'"
                            :content="innerToolData(msg)"
                            :expanded="expandedToolIds.has(toolExpandKey(msg, groupIndex, idx))"
                            :parameters="getParametersForMessage(msg)"
                            @open-session="onOpenWorkspaceSession"
                          />
                          <Glob
                            v-else-if="msg.tool_name === 'glob'"
                            :content="innerToolData(msg)"
                            :expanded="expandedToolIds.has(toolExpandKey(msg, groupIndex, idx))"
                            :cwd="sessionCwd"
                            :parameters="getParametersForMessage(msg)"
                          />
                          <TextReplace
                            v-else-if="msg.tool_name === 'text_replace'"
                            :content="innerToolData(msg)"
                            :expanded="expandedToolIds.has(toolExpandKey(msg, groupIndex, idx))"
                            :diffview-before="msg.diffview_before"
                            :diffview-after="msg.diffview_after"
                            :cwd="sessionCwd"
                            :parameters="getParametersForMessage(msg)"
                          />
                          <ShellTool
                            v-else-if="
                              msg.tool_name === 'bash' ||
                              msg.tool_name === 'pwsh' ||
                              msg.tool_name === 'run_command' ||
                              msg.tool_name === 'command'
                            "
                            :tool-name="
                              msg.tool_name === 'pwsh'
                                ? 'pwsh'
                                : msg.tool_name === 'command'
                                  ? 'command'
                                  : 'bash'
                            "
                            :content="innerToolData(msg)"
                            :expanded="expandedToolIds.has(toolExpandKey(msg, groupIndex, idx))"
                            :parameters="getParametersForMessage(msg)"
                          />
                          <UseSkill
                            v-else-if="msg.tool_name === 'use_skill'"
                            :content="innerToolData(msg)"
                            :expanded="expandedToolIds.has(toolExpandKey(msg, groupIndex, idx))"
                            :parameters="getParametersForMessage(msg)"
                          />
                          <SearchSkills
                            v-else-if="msg.tool_name === 'search_skills'"
                            :content="innerToolData(msg)"
                            :expanded="expandedToolIds.has(toolExpandKey(msg, groupIndex, idx))"
                            :parameters="getParametersForMessage(msg)"
                          />
                          <AddSkill
                            v-else-if="msg.tool_name === 'add_skill'"
                            :content="innerToolData(msg)"
                            :expanded="expandedToolIds.has(toolExpandKey(msg, groupIndex, idx))"
                            :parameters="getParametersForMessage(msg)"
                          />
                          <EditSkill
                            v-else-if="msg.tool_name === 'edit_skill'"
                            :content="innerToolData(msg)"
                            :expanded="expandedToolIds.has(toolExpandKey(msg, groupIndex, idx))"
                            :parameters="getParametersForMessage(msg)"
                          />
                          <RemoveSkill
                            v-else-if="msg.tool_name === 'remove_skill'"
                            :content="innerToolData(msg)"
                            :expanded="expandedToolIds.has(toolExpandKey(msg, groupIndex, idx))"
                            :parameters="getParametersForMessage(msg)"
                          />
                          <RemoveFile
                            v-else-if="msg.tool_name === 'remove_file'"
                            :content="innerToolData(msg)"
                            :expanded="expandedToolIds.has(toolExpandKey(msg, groupIndex, idx))"
                            :cwd="sessionCwd"
                            :parameters="getParametersForMessage(msg)"
                          />
                          <SpawnSubAgent
                            v-else-if="msg.tool_name === 'spawn_sub_agent'"
                            :content="innerToolData(msg)"
                            :expanded="expandedToolIds.has(toolExpandKey(msg, groupIndex, idx))"
                            :sub-agent-args="
                              findSubAgentArgsForToolGroup(
                                msg.tool_call_id,
                                messageGroups,
                                groupIndex,
                              )
                            "
                            :progress="
                              msg.tool_call_id ? subAgentProgressMap[msg.tool_call_id] : null
                            "
                            :parameters="getParametersForMessage(msg)"
                            @peek="nav.openPeek($event)"
                          />
                          <SetGitWorktree
                            v-else-if="msg.tool_name === 'set_git_worktree'"
                            :content="innerToolData(msg)"
                            :parameters="getParametersForMessage(msg)"
                            :expanded="expandedToolIds.has(toolExpandKey(msg, groupIndex, idx))"
                          />
                          <ReadCompactedMessages
                            v-else-if="msg.tool_name === 'read_compacted_messages'"
                            :content="innerToolData(msg)"
                            :expanded="expandedToolIds.has(toolExpandKey(msg, groupIndex, idx))"
                            :parameters="getParametersForMessage(msg)"
                          />
                          <KanbanMove
                            v-else-if="msg.tool_name === 'kanban_move_task'"
                            :content="innerToolData(msg)"
                            :parameters="getParametersForMessage(msg)"
                            :expanded="expandedToolIds.has(toolExpandKey(msg, groupIndex, idx))"
                          />
                          <KanbanList
                            v-else-if="msg.tool_name === 'kanban_list'"
                            :content="innerToolData(msg)"
                            :parameters="getParametersForMessage(msg)"
                            :expanded="expandedToolIds.has(toolExpandKey(msg, groupIndex, idx))"
                          />
                          <ListDirectory
                            v-else-if="msg.tool_name === 'list_directory'"
                            :content="innerToolData(msg)"
                            :expanded="expandedToolIds.has(toolExpandKey(msg, groupIndex, idx))"
                            :cwd="sessionCwd"
                            :parameters="getParametersForMessage(msg)"
                          />
                          <SaveMemory
                            v-else-if="msg.tool_name === 'save_memory'"
                            :content="innerToolData(msg)"
                            :parameters="getParametersForMessage(msg)"
                            :expanded="expandedToolIds.has(toolExpandKey(msg, groupIndex, idx))"
                          />
                          <LoadMemory
                            v-else-if="msg.tool_name === 'load_memory'"
                            :content="innerToolData(msg)"
                            :parameters="getParametersForMessage(msg)"
                            :expanded="expandedToolIds.has(toolExpandKey(msg, groupIndex, idx))"
                          />
                          <!--
                            `update_plan` + `get_plan` (Task 8 — optional UI).
                            These render the agent's per-session task plan as
                            a checklist card. Both components parse the
                            inner envelope themselves and extract the plan
                            body from the canonical `<plan><![CDATA[...]]></plan>`
                            block — no `parameters` prop threading needed.
                            Self-contained (no `expanded` from the dispatcher
                            — local toggle is enough for an optional UI).
                          -->
                          <UpdatePlan v-else-if="msg.tool_name === 'update_plan'" :message="msg" />
                          <GetPlan v-else-if="msg.tool_name === 'get_plan'" :message="msg" />
                          <ListSubAgent
                            v-else-if="msg.tool_name === 'list_sub_agent'"
                            :message="msg"
                          />
                          <!--
                            `used_tools` is the "what do I already have"
                            counterpart to `search_tool` ("what else exists").
                            Its payload is a flat name/description list, so it
                            renders as a dedicated card instead of dumping
                            `{"count":10,"tools":[…]}` into the generic
                            fallback.
                          -->
                          <UsedTools v-else-if="msg.tool_name === 'used_tools'" :message="msg" />
                          <!--
                            `present_files` renders one inline-preview
                            section per file (images full-width, html in
                            a sandboxed iframe, text via the shared
                            renderer, pdf/video/audio native) plus a
                            download action. Cookie-based auth, so plain
                            `<a href>` / `<img src>` / `<iframe src>`
                            carry credentials. Expanded by default: the
                            files ARE the answer, so the set tracks
                            user-collapsed rows (inverted vs the other
                            cards that track user-expanded rows).
                          -->
                          <PresentFiles
                            v-else-if="msg.tool_name === 'present_files'"
                            :content="innerToolData(msg)"
                            :session-id="sessionId || chatId"
                            :cwd="sessionCwd"
                            :parameters="getParametersForMessage(msg)"
                            :expanded="!expandedToolIds.has(toolExpandKey(msg, groupIndex, idx))"
                          />
                          <!--
                            `generate_image` is expandable. The card shows
                            the prompt + model + size + saved file paths;
                            the agent's NEXT tool call is `present_files`
                            with `files=[{path=<image.path>}]` which renders
                            the image inline. This component is informational
                            metadata only.
                          -->
                          <GenerateImage
                            v-else-if="msg.tool_name === 'generate_image'"
                            :content="innerToolData(msg)"
                            :parameters="getParametersForMessage(msg)"
                            :expanded="expandedToolIds.has(toolExpandKey(msg, groupIndex, idx))"
                          />
                          <!--
                            `web_search` + `list_web_search_providers`.
                            The provider's answer is UNTYPED passthrough
                            (D13), so the search card renders one
                            convention — a top-level `results` array — and
                            pretty-prints anything else. The listing card
                            shows each provider's curl TEMPLATE, which
                            carries `{key}` and never the key itself.
                          -->
                          <WebSearch
                            v-else-if="msg.tool_name === 'web_search'"
                            :content="innerToolData(msg)"
                            :parameters="getParametersForMessage(msg)"
                            :expanded="expandedToolIds.has(toolExpandKey(msg, groupIndex, idx))"
                          />
                          <ListSearchProviders
                            v-else-if="msg.tool_name === 'list_web_search_providers'"
                            :content="innerToolData(msg)"
                            :parameters="getParametersForMessage(msg)"
                            :expanded="expandedToolIds.has(toolExpandKey(msg, groupIndex, idx))"
                          />
                          <!--
                            Universal MCP card: ANY `mcp_*` tool (graphify, db,
                            context7, future servers) renders here — never in
                            the DiffView fallback below. The name check uses
                            startsWith so new servers work with zero template
                            changes.
                          -->
                          <AskUser
                            v-else-if="msg.tool_name === 'ask_user'"
                            :content="innerToolData(msg)"
                            :parameters="getParametersForMessage(msg)"
                            :expanded="expandedToolIds.has(toolExpandKey(msg, groupIndex, idx))"
                            :session-id="sessionId || chatId"
                          />
                          <McpTool
                            v-else-if="msg.tool_name?.startsWith('mcp_')"
                            :content="innerToolData(msg)"
                            :tool-name="msg.tool_name ?? 'mcp_tool'"
                            :parameters="getParametersForMessage(msg)"
                            :expanded="expandedToolIds.has(toolExpandKey(msg, groupIndex, idx))"
                          />
                          <!--
                            Progressive discovery card: `search_tool` /
                            `view_tool` / `use_tool` render here — never in
                            the generic fallback below. Same expandable
                            ToolCardHeader pattern as McpTool/ListDirectory.
                          -->
                          <ProgressiveTool
                            v-else-if="
                              msg.tool_name === 'search_tool' ||
                              msg.tool_name === 'view_tool' ||
                              msg.tool_name === 'use_tool'
                            "
                            :content="innerToolData(msg)"
                            :tool-name="msg.tool_name ?? 'search_tool'"
                            :parameters="getParametersForMessage(msg)"
                            :expanded="expandedToolIds.has(toolExpandKey(msg, groupIndex, idx))"
                          />
                          <div v-else class="tool-expandable">
                            <button
                              class="tool-summary"
                              @click="toggleToolExpanded(toolExpandKey(msg, groupIndex, idx))"
                              :style="[
                                'cursor: pointer; padding: 2px 4px; border-radius: 4px; transition: background-color 0.15s; text-align: left; width: 100%; border: none; background: transparent; font: inherit; color: inherit;',
                                expandedToolIds.has(toolExpandKey(msg, groupIndex, idx))
                                  ? 'border-bottom: 1px dashed var(--color-border);'
                                  : '',
                              ]"
                            >
                              <span
                                v-html="
                                  renderResponse(
                                    msg.content,
                                    msg.role,
                                    msg.tool_name,
                                    msg.diffview_before,
                                    msg.diffview_after,
                                    msg.finish_reason,
                                    msg.tool_calls_json,
                                  )
                                "
                              ></span>
                            </button>
                            <div
                              v-if="expandedToolIds.has(toolExpandKey(msg, groupIndex, idx))"
                              class="tool-full-content"
                            >
                              <!--
                                Render the diff only when at least one side
                                has content. Both-empty (e.g. legacy MCP rows
                                whose COALESCE'd "" diffview fields reach the
                                wire) renders nothing — the previous
                                `!== undefined` check treated "" as present
                                and showed a "(no content)" / "(no content)"
                                frame (see mcp_graphify_graph_stats bug).
                                Empty-before or empty-after alone still
                                renders so "new file" / "all deleted" stays
                                visible.
                              -->
                              <DiffView
                                v-if="msg.diffview_before || msg.diffview_after"
                                :before="msg.diffview_before ?? ''"
                                :after="msg.diffview_after ?? ''"
                                :file-path="msg.tool_name"
                                @jump-to-line="handleFallbackJumpToLine"
                              />
                            </div>
                          </div>
                        </div>
                      </div>
                    </template>

                    <!-- ── Assistant ── -->
                    <template v-else-if="group.role === 'assistant'">
                      <!-- 2026-08-23 hidden-messages fix — collapsible
                           reasoning section for thinking models. Previously
                           reasoning_content was console.log-only, so a
                           thinking-only turn (empty final text) looked like
                           the agent said nothing. Default-collapsed so long
                           chains-of-thought don't push content off-screen;
                           click to expand. Rendered ABOVE the answer: the
                           reasoning is the context the reply follows from,
                           so it reads first, not as a footnote. -->
                      <div
                        v-for="(msg, rIdx) in group.messages.filter(
                          (m) => m.reasoning_content && m.reasoning_content.trim() !== '',
                        )"
                        :key="`reasoning-${rIdx}`"
                        class="mt-3 mb-3"
                      >
                        <details class="assistant-reasoning">
                          <summary
                            class="cursor-pointer select-none text-dense font-medium opacity-70 hover:opacity-100"
                            :style="{ color: 'var(--semantic-text-dim)' }"
                          >
                            Thought
                          </summary>
                          <div
                            class="mt-1 whitespace-pre-wrap text-dense leading-relaxed opacity-80 border-l-2 pl-3"
                            :style="{
                              color: 'var(--semantic-text-dim)',
                              'border-color': 'var(--color-border)',
                            }"
                          >
                            {{ msg.reasoning_content }}
                          </div>
                        </details>
                      </div>
                      <!-- Hide the messages block when every message in the group
                           is empty after stripping thinking tags — this happens
                           on tool_calls-only assistant turns. The tool header
                           (if any) is shown above; we don't want an empty
                           padded area below it. -->
                      <div v-if="group.messages.some(hasVisibleContent)" class="assistant-messages">
                        <div v-for="(msg, idx) in group.messages" :key="idx" class="assistant-item">
                          <!-- <html> blocks render as live sandboxed iframes
                               (null origin = security boundary); any text
                               outside the tags still renders as markdown.
                               Legacy messages take the v-else path unchanged. -->
                          <template v-if="msg.role === 'assistant' && msgHasHtml(msg.content)">
                            <template
                              v-for="(seg, sIdx) in extractHtmlBlocks(msg.content || '')"
                              :key="sIdx"
                            >
                              <!-- eslint-disable-next-line vue/no-v-html -->
                              <span
                                v-if="seg.before"
                                v-html="marked.parse(seg.before, { async: false })"
                              ></span>
                              <iframe
                                v-if="seg.html"
                                class="chat-html-frame"
                                sandbox="allow-scripts"
                                scrolling="no"
                                style="overflow: hidden"
                                :srcdoc="buildHtmlSrcdoc(seg.html)"
                              ></iframe>
                            </template>
                          </template>
                          <span
                            v-else
                            v-html="
                              renderResponse(
                                msg.content,
                                msg.role,
                                msg.tool_name,
                                msg.diffview_before,
                                msg.diffview_after,
                                msg.finish_reason,
                                msg.tool_calls_json,
                              )
                            "
                          ></span>
                        </div>
                      </div>
                    </template>
                  </div>
                  <!-- Timestamp is hidden along with the bubble. The bubble
                       uses v-if="hasBubbleContent(...)" above; if the
                       bubble is hidden, the timestamp would otherwise
                       appear orphaned (this was the "timestamps with no
                       bubble" visual artifact between tool calls). -->
                  <!-- <div -->
                  <!--   v-if="hasBubbleContent(group, groupIndex)" -->
                  <!--   class="text-dense mt-1 px-1" -->
                  <!--   :class="group.role === 'user' ? 'text-right' : 'text-left'" -->
                  <!--   style="color: var(--semantic-text-dim)" -->
                  <!-- > -->
                  <!--   {{ formatTime(group.timestamp) }} -->
                  <!-- </div> -->
                </div>
              </div>
            </div>
          </template>
        </VirtualScroller>

        <!-- User-pill rail (2026-09-09 chatview user pill): one pill per
             user group on the right edge; click jumps to that message.
             Sibling of VirtualScroller inside the relative
             messagesWrapperRef so it never virtualizes. Hidden when
             fewer than 2 user groups (nothing to navigate). -->
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

        <!-- 2026-08-25 agent-error-card (task_1787663566535_2):
             Agentic-loop error/retry diagnostics. Rendered OUTSIDE the
             VirtualScroller on purpose — the scroller's height-estimate
             model only knows about messageGroups rows, and injecting
             foreign rows desyncs the estimated scroll window (same class
             of bug as the empty-group note above). These are transient,
             live-only diagnostics (backend is_skip_db=true), so pinning
             them at the bottom of the transcript area is correct UX too:
             the newest error is always visible without scrolling. -->
        <div
          v-if="agentError"
          class="px-4 max-w-4xl mx-auto agent-error-list"
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
        <div class="max-w-4xl mx-auto">
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

                  <!-- Model/Profile selector -->
                  <div ref="profilePickerRef" class="relative">
                    <button
                      @click.stop="showProfilePicker = !showProfilePicker"
                      :disabled="isUpdatingProfile || isInitializing || !sessionId"
                      class="composer-tool-btn"
                      data-testid="profile-picker-button"
                      :title="profileChipTooltip"
                    >
                      <span>{{ effectiveProfile ?? 'Default' }}</span>
                      <span class="text-micro">▾</span>
                    </button>
                    <div
                      v-if="showProfilePicker"
                      class="absolute bottom-full mb-2 left-0 min-w-[240px] rounded-lg shadow-lg z-20 overflow-hidden"
                      style="
                        background-color: var(--semantic-card-bg);
                        border: 1px solid var(--color-border);
                      "
                    >
                      <button
                        @click="selectProfile(null)"
                        class="w-full text-left px-3 py-2 text-dense hover:opacity-80 flex items-center justify-between"
                        style="color: var(--semantic-text)"
                        data-testid="profile-picker-default"
                      >
                        <span>Default (top-level config)</span>
                        <span v-if="!selectedProfile && !activeProfile">✓</span>
                      </button>
                      <button
                        v-for="p in availableProfiles"
                        :key="p.name"
                        @click="selectProfile(p.name)"
                        class="w-full text-left px-3 py-2 text-dense hover:opacity-80"
                        style="
                          color: var(--semantic-text);
                          border-top: 1px solid var(--color-border);
                        "
                        :data-testid="`profile-picker-${p.name}`"
                      >
                        <div class="flex items-center justify-between">
                          <span class="font-medium">
                            {{ p.name }}
                            <span
                              v-if="activeProfile === p.name"
                              class="text-micro ml-1 px-1 py-0.5 rounded"
                              :style="{ backgroundColor: 'var(--color-violet)', color: '#181616' }"
                              data-testid="profile-picker-active-badge"
                              >(active)</span
                            >
                          </span>
                          <span v-if="effectiveProfile === p.name">✓</span>
                        </div>
                        <div class="text-micro mt-0.5" style="color: var(--semantic-text-muted)">
                          {{ p.model }} · {{ p.base_url }}
                        </div>
                      </button>
                      <div
                        v-if="availableProfiles.length === 0"
                        class="px-3 py-2 text-dense"
                        style="color: var(--semantic-text-muted)"
                      >
                        No profiles configured. Add one in Settings.
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
          console.log('Skill clicked:', skill)
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

    <!-- Sub-agent peek panel — slide-over from the right.
         Renders only when navigationStore.peekPanel is set;
         teardown happens when ChatView unmounts (route change
         away from this chat).

         The `!embedded` guard is load-bearing (task_1788604407681_2):
         the peek panel itself embeds a read-only ChatView for the
         sub-agent session, and `peekPanel` is GLOBAL store state. An
         embedded instance that also rendered the host would recurse
         Host → Panel → ChatView → Host → … forever and the panel
         would never appear. Exactly one host exists — the one in the
         outermost non-embedded ChatView. Eye-clicks inside the peek
         still drill down: they call `nav.openPeek` (kept below on
         SpawnSubAgent), which swaps the payload the outer host
         renders (it is `:key`d by sessionId). -->
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

<style scoped>
.fade-enter-active,
.fade-leave-active {
  transition: opacity 0.2s ease;
}

.fade-enter-from,
.fade-leave-to {
  opacity: 0;
}

:deep(.tool-output) {
  padding: 0.5rem 0.75rem;
  border-radius: 0.375rem;
  margin: 0.25rem 0;
  font-family: 'Monaco', 'Menlo', 'Ubuntu Mono', monospace;
  font-size: var(--text-dense);
  line-height: 1.5;
}

:deep(.tool-stdout) {
  background-color: rgba(59, 130, 246, 0.1);
  border-left: 3px solid #3b82f6;
  color: var(--semantic-text);
}

:deep(.tool-stderr) {
  background-color: rgba(245, 158, 11, 0.1);
  border-left: 3px solid #f59e0b;
  color: var(--semantic-text);
}

:deep(.tool-success) {
  background-color: rgba(34, 197, 94, 0.1);
  border-left: 3px solid #22c55e;
  color: var(--semantic-text);
}

:deep(.tool-error) {
  background-color: rgba(239, 68, 68, 0.1);
  border-left: 3px solid #ef4444;
  color: var(--semantic-text);
}

:deep(.tool-tag) {
  font-weight: 600;
  margin-right: 0.5rem;
}

:deep(.file-path) {
  font-family: 'Monaco', 'Menlo', 'Ubuntu Mono', monospace;
  font-size: var(--text-dense);
  padding: 0.25rem 0.5rem;
  background-color: rgba(139, 92, 246, 0.1);
  border-radius: 0.25rem;
  margin: 0.125rem 0;
  color: var(--semantic-text);
}

:deep(.search-file) {
  font-weight: 600;
  font-size: var(--text-body);
  color: var(--color-violet);
  margin-top: 0.5rem;
}

:deep(.search-line) {
  font-family: 'Monaco', 'Menlo', 'Ubuntu Mono', monospace;
  font-size: var(--text-dense);
  padding: 0.125rem 0.5rem;
}

:deep(.line-num) {
  color: var(--semantic-text-dim);
  user-select: none;
  margin-right: 1rem;
  min-width: 3rem;
  display: inline-block;
}

:deep(.line-content) {
  white-space: pre-wrap;
  word-break: break-all;
}

:deep(.file-content) {
  margin-top: 0.25rem;
  font-family: 'Monaco', 'Menlo', 'Ubuntu Mono', monospace;
  font-size: var(--text-dense);
  line-height: 1.5;
  background-color: rgba(0, 0, 0, 0.04);
  border-radius: 0.375rem;
  padding: 0.5rem 0;
  overflow-x: hidden;
}

:deep(.tool-sequence) {
  display: flex;
  flex-direction: column;
  width: 100%;
  min-width: 0;
  /* 2026-08-23 paragraph-mode margin pass — the old 0.25rem gap was
     sized for boxed cards that carried their own visual separation.
     De-bubbled rows are flat, so they need explicit rhythm to read as
     distinct steps instead of one dense wall. */
  gap: 0.625rem;
}

:deep(.tool-item) {
  padding: 0.125rem 0;
  width: 100%;
  min-width: 0;
}

:deep(.tool-item-border) {
  border-bottom: none;
  padding-bottom: 0;
}

:deep(.tool-item-border:last-child) {
  border-bottom: none;
  padding-bottom: 0;
}

/* 2026-08-23 paragraph-mode margin pass — spacing AROUND the tool
   sequence so it breathes against surrounding prose:
   - gap above the first tool row (was flush against the assistant text)
   - gap below the last tool row (was flush against the next group) */
:deep(.tool-sequence) {
  margin-top: 0.375rem;
  margin-bottom: 0.375rem;
}

/* Tool calls summary - shown only when tool outputs are NOT displayed */
:deep(.tool-calls-summary) {
  display: flex;
  align-items: center;
  flex-wrap: wrap;
  gap: 0.5rem;
  padding: 0.5rem 0.75rem;
  margin-bottom: 0.5rem;
  background-color: var(--color-bg-p1);
  border: 1px solid var(--color-border);
  border-radius: 0.5rem;
  border-left: 3px solid var(--color-violet);
}

:deep(.tool-calls-badge) {
  display: flex;
  align-items: center;
  gap: 0.35rem;
  color: var(--color-violet);
  font-size: var(--text-dense);
  text-transform: uppercase;
  letter-spacing: 0.05em;
  font-family: var(--font-mono);
}

:deep(.tool-names-list) {
  display: flex;
  flex-wrap: wrap;
  gap: 0.375rem;
}

:deep(.tool-name-chip) {
  display: inline-flex;
  align-items: center;
  padding: 0.125rem 0.5rem;
  background-color: var(--color-bg-p2);
  border: 1px solid var(--color-border-light);
  border-radius: 9999px;
  font-size: var(--text-dense);
  font-family: var(--font-mono);
  color: var(--color-aqua);
}

:deep(.tool-inline) {
  font-size: var(--text-dense);
  color: var(--color-violet);
  font-family: monospace;
}

:deep(.tool-inline-result) {
  font-size: var(--text-dense);
  color: var(--semantic-text-dim);
  font-family: monospace;
}

:deep(.tool-inline-success) {
  color: var(--color-green);
  font-weight: 600;
}

:deep(.tool-inline-error) {
  color: var(--color-red);
  font-weight: 600;
}

:deep(.markdown-content pre) {
  overflow-x: auto;
}

/* 2026-08-24 (task_1787545088500_6, bug C) — long unbroken URLs in
   assistant prose overflow the chat bubble. The pre block above
   already scrolls horizontally, but inline links + prose do not.
   `overflow-wrap: anywhere` lets the browser break inside a long
   word/URL at any character so the bubble stays within its parent;
   `word-break: break-word` is the older alias kept for browsers
   that don't recognise the new property name. Surgical, scoped
   to .markdown-content only. */
.markdown-content {
  overflow-wrap: anywhere;
  word-break: break-word;
}

:deep(.markdown-content pre:hover .code-copy-btn) {
  opacity: 1;
}

/* ─── Assistant paragraph mode (2026-08-23) ──────────────────────────────
   The AI side no longer renders as a chat bubble — assistant groups are
   transparent, borderless paragraphs that flow with the page background.
   These rules give the un-bubbled content document-like rhythm:
   - .assistant-messages: vertical spacing between consecutive assistant
     groups (the old bubble's py-2.5 padding provided this separation).
   - .assistant-item + .assistant-item + .assistant-item: a small gap
     between adjacent messages inside one group.
   2026-08-23 margin pass: bumped both up — flat paragraphs need more
   explicit rhythm than boxed bubbles did. */
.assistant-messages {
  margin-bottom: 0.375rem;
}

.assistant-item + .assistant-item {
  margin-top: 0.625rem;
}

/* ─── <html> wrapper-tag sandboxed iframe (2026-08-23 html-tag-support) ──
   Live HTML blocks from the LLM render inside a null-origin iframe
   (sandbox="allow-scripts", no allow-same-origin). The frame paints the
   app's CARD surface, NOT white: an LLM that answers in HTML mode (the
   response-formatting prompt explicitly offers it) is still part of the
   transcript, and a hardcoded #fff read as a bright slab in the dark
   theme. `color-scheme: dark` keeps the frame's native scrollbars dark
   too. Height is set inline by the frame's own auto-resize report
   (helpers/iframeAutoResize.ts) to its FULL content height — no inner
   scrollbar, the outer chat scroller owns scrolling. */
.chat-html-frame {
  display: block;
  width: 100%;
  min-height: 120px;
  border: 1px solid var(--color-border, #ddd);
  border-radius: 8px;
  background: var(--semantic-card-bg, #1d1c19);
  color-scheme: dark;
  overflow: hidden;
  scrollbar-width: none;
}

.chat-html-frame::-webkit-scrollbar {
  display: none;
}

/* ─── Tool-output cards, de-bubbled (2026-08-23) ────────────────────────
   All 24 tool_output components used to carry an identical Tailwind card
   frame (`rounded-md border border-[--color-border] bg-[--semantic-card-bg]`)
   — a boxed bubble per tool row. In paragraph mode that reads as heavy
   chrome stacked under un-bubbled prose. The frame is now ONE shared
   class, `.chat-tool-card`, defined here once:
     - transparent background (page shows through)
     - no full box border; a subtle 2px left rule marks the row instead
     - gentle hover tint so rows stay discoverable as expandable
   Error/warning variants still work: components bind
   `border-red-500/50` / `border-orange-500/50` via :class, which now
   recolors the left rule (border-left-color) instead of drawing a box.
   Scoped deep selector: the components are children of ChatView's tree. */
:deep(.chat-tool-card) {
  background-color: transparent;
  border: none;
  border-left: 2px solid var(--color-border);
  border-radius: 0;
  overflow: visible;
  width: 100%;
  min-width: 0;
  box-sizing: border-box;
  transition:
    background-color 0.15s ease,
    border-left-color 0.15s ease;
}

:deep(.chat-tool-card pre) {
  max-width: 100%;
  min-width: 0;
  overflow-x: auto;
}

:deep(.chat-tool-card:hover) {
  background-color: color-mix(in srgb, var(--color-violet) 4%, transparent);
  border-left-color: var(--color-violet);
}

/* Attached image thumbnail — small fixed-size preview matching
   FileInput.vue's FilePreview (80×80px, rounded, object-fit:cover).
   Click opens the full-screen ImagePreview via openImagePreview(). */
.chat-attached-image-thumb {
  width: 80px;
  height: 80px;
  border-radius: 8px;
  overflow: hidden;
  border: 1px solid var(--color-border);
  background-color: var(--semantic-sidebar-bg);
  cursor: pointer;
}

.chat-attached-image-img {
  width: 100%;
  height: 100%;
  object-fit: cover;
  display: block;
}

.chat-attached-image-thumb:hover .chat-attached-image-img {
  opacity: 0.9;
}

/* Pill-jump flash (2026-09-09 chatview user pill): brief outline pulse
   on the user bubble after a rail-pill jump so the eye finds it. */
.pill-jump-flash {
  animation: pill-jump-flash 1.2s ease-out;
  border-radius: 12px;
}

@keyframes pill-jump-flash {
  0%,
  100% {
    outline: 2px solid transparent;
    outline-offset: 2px;
  }
  25%,
  60% {
    outline: 2px solid var(--color-violet, #8b5cf6);
    outline-offset: 2px;
  }
}

@media (prefers-reduced-motion: reduce) {
  .pill-jump-flash {
    animation: none;
    outline: 2px solid var(--color-violet, #8b5cf6);
    outline-offset: 2px;
  }
}

/* Realtime chat slider: this scroller's native scrollbar is replaced by
   the ChatScrollSlider thumb (draggable, scroll-synced). Scrolling
   itself is untouched (wheel/touch/keyboard still work) — only the
   native visual is hidden, and only inside this wrapper. */
.messages-scroll-hide-native :deep(.virtual-scroller) {
  scrollbar-width: none;
}
.messages-scroll-hide-native :deep(.virtual-scroller::-webkit-scrollbar) {
  display: none;
}
/* Make room for the slider track at the extreme right edge. */
.messages-scroll-hide-native :deep(.user-pill-rail) {
  right: 18px;
}

/* ─── Floating composer ──────────────────────────────────────────────────
   The composer is an overlay, not the last flex child. The dock's
   ResizeObserver writes its height into `--chat-composer-inset` on the
   `.chat-column` (see the script block); everything below reads that one
   number, so there is a single source of truth for "how much room does
   the floating composer take". It is unset (0) while the dock is not
   rendered — e.g. the read-only peek panel — which degrades the last row
   to a plain 1rem of bottom padding, matching the old flow layout. */
.chat-column {
  --chat-composer-inset: 0px;

  /* Contain this surface's whole z-ladder.
     `position: relative` with `z-index: auto` does NOT open a stacking
     context, so the tiers below (scroll slider / pill rail 20, composer
     dock 30, scroll-to-bottom 31) were competing in the ROOT stacking
     context against AppLayout's full-surface overlays — and every one of
     them outranked the document viewer's `z-index: 10`. Opening a chat
     session and then clicking a document therefore painted the composer
     dock, the scroll arrow and the scroll slider ON TOP of the document.

     Isolating here fixes the class of bug rather than one instance: no
     z-index added to the chat in future can escape past an app-level
     overlay, so DocumentsView does not have to be raised above a number
     that would have to be raised again. */
  isolation: isolate;
}

.composer-dock {
  position: absolute;
  left: 0;
  right: 0;
  bottom: 0;
  /* Above the transcript (z-0/auto) and the pill rail + scroll slider
     (z-20), below the scroll-to-bottom arrow (z-31). */
  z-index: 30;
}

/* The fade that replaces the old `border-top` + opaque sidebar fill.
   `--semantic-content-bg` is the colour the transcript is actually
   painted on, so the gradient dissolves into the page instead of
   stopping at a 1px rule — or showing the 1-shade seam that fading to
   `--semantic-sidebar-bg` (the old bar fill) would have produced. */
.composer-scrim {
  position: absolute;
  left: 0;
  right: 0;
  bottom: 0;
  /* Opaque across the dock itself (so nothing shows through the padding
     around the card), then 3rem of fade ABOVE it — that extra band is
     what softens the cut where the transcript runs under the composer. */
  height: calc(100% + 3rem);
  pointer-events: none;
  background: linear-gradient(
    to top,
    var(--semantic-content-bg) 0,
    var(--semantic-content-bg) calc(100% - 3rem),
    transparent 100%
  );
}

/* Lift the composer card off the page. Without this it reads as another
   flat surface rather than something floating over the transcript.

   `position: relative` + `z-index: 1` is load-bearing, not decoration: the
   scrim is a POSITIONED descendant of the dock (`position: absolute`,
   `z-index: auto`), and CSS paints positioned descendants AFTER in-flow,
   non-positioned content. A static card therefore loses to the scrim, whose
   opaque band covers the dock's full height — the input row, paperclip and
   Send button all vanish, leaving only whatever the card happens to position
   itself (the profile picker's `relative` wrapper) on top. `pointer-events:
   none` on the scrim hides the damage from hit-testing, so `elementFromPoint`
   still reports the textarea and every geometry test passes. Giving the card
   its own stacking context above the scrim is what keeps it visible. */
.composer-dock :deep(.composer-card) {
  position: relative;
  z-index: 1;
  box-shadow:
    0 10px 30px -10px rgba(0, 0, 0, 0.7),
    0 2px 8px -2px rgba(0, 0, 0, 0.45);
}

/* Bottom clearance for the newest message. Plain CSS padding on the last
   row, so VirtualScroller's `measureItems()` (which reads
   `el.offsetHeight`) folds it into the height model for free: the sizer
   grows, and `scrollToBottom` lands on the padded bottom, so the newest
   message is always fully visible above the composer. Keyed by group
   index in the template, never `:last-child` — the last child of the
   rendered window is a mid-transcript row whenever the window does not
   cover the tail. */
.last-transcript-row {
  padding-bottom: calc(var(--chat-composer-inset) + 1rem);
}

/* Same clearance for the live agent-error band: it sits after the
   VirtualScroller (outside the height model, so it can't borrow
   `.last-transcript-row`'s padding) and would otherwise sit under the
   dock. */
.agent-error-list {
  padding-bottom: calc(var(--chat-composer-inset) + 0.5rem);
}

/* Scroll-to-bottom arrow: sits clear of the dock instead of at a fixed
   `bottom-24`, which was tuned for the old in-flow composer height. */
.chat-scroll-to-bottom {
  position: absolute;
  right: 2rem;
  bottom: calc(var(--chat-composer-inset) + 0.75rem);
  z-index: 31;
}

/* V1 composer toolbar (single-card): quiet ghost actions + muted status.
   The strip itself lives in FileInput's toolbar slot; these classes style
   the projected content. Display-only status (tokens) deliberately has no
   button affordance — no border, no hover — so actions read as actions. */
.composer-tool-btn {
  display: flex;
  align-items: center;
  gap: 6px;
  padding: 6px 8px;
  border-radius: 8px;
  font-size: var(--text-dense);
  font-weight: 500;
  color: var(--semantic-text-dim);
  background: transparent;
  border: 1px solid transparent;
  white-space: nowrap;
  cursor: pointer;
  transition:
    background-color 0.15s ease,
    color 0.15s ease;
}

.composer-tool-btn:hover {
  background-color: var(--hover-bg, rgba(255, 255, 255, 0.04));
  color: var(--semantic-text);
}

.composer-tool-btn:disabled {
  opacity: 0.45;
  cursor: not-allowed;
}

.composer-tool-btn:disabled:hover {
  background: transparent;
  color: var(--semantic-text-dim);
}

.composer-toolbar-divider {
  width: 1px;
  height: 16px;
  background: var(--color-border);
  margin: 0 4px;
  flex-shrink: 0;
}

.composer-tokens-status {
  display: flex;
  align-items: center;
  gap: 6px;
  padding: 6px 4px;
  font-size: var(--text-dense);
  color: var(--semantic-text-dim);
  white-space: nowrap;
}

.composer-branch-label {
  overflow: hidden;
  text-overflow: ellipsis;
  white-space: nowrap;
  max-width: 220px;
}

@media (max-width: 720px) {
  .composer-branch-label {
    max-width: 120px;
  }
}

@media (max-width: 560px) {
  .composer-tokens-status {
    display: none;
  }
}
</style>
