import { computed, inject, ref, type Ref } from 'vue'
import { useRouter, useRoute } from 'vue-router'
import * as api from '../../../api'
import { createScrollLogger, type ScrollLogger } from '@/helpers'
import { buildAppUrl } from '../../../helpers/appUrl'
import { useNavigationStore } from '../../../stores/navigation'
import { useWorkspacesStore } from '../../../stores/workspaces'

export interface ChatViewSessionDeps {
  chatId: string
  sessionId: Ref<string>
}

export function useChatViewSession({ chatId, sessionId }: ChatViewSessionDeps) {

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

  // Attached PR URL for the sidebar's PR-changes mode (set_pull_request
  // tool). Empty = worktree-changes mode. Re-synced with the worktree
  // binding so a mid-chat attach/clear flips the panel without reload.
  const chatPrUrl = ref('')
  const chatPrProvider = ref('')

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

  // ─── Scroll logger ──────────────────────────────────────────────────────────── A dedicated logger
  // for the scroll subsystem. Bound to the active chat so every line is tagged with chatId. See
  // helpers/scrollLogger.ts for what fields every line carries and why.
  let scrollLogger: ScrollLogger = createScrollLogger(chatId)
  const refreshScrollLogger = () => {
    scrollLogger = createScrollLogger(sessionId.value || chatId)
  }
  const logger = () => scrollLogger

  return {
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
    onPeekOpenFull,
    queuedMessages,
    refreshScrollLogger,
    route,
    router,
    streamingContent,
    workspacesStore,
  }
}
