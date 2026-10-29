import { nextTick, type Ref } from 'vue'
import * as api from '../../../api'
import { chatEngineDb, toChatMessage } from '../../../sync/ChatEngineDb'
import { runSyncEffect, runSyncVoid } from '../../../sync/runtime'
import { stripThinkingTags, type ScrollLogger } from '@/helpers'
import { splitMediaUrlsWire } from '../../../helpers/mediaUrls'
import { installSseBus, useSseBus } from '../../../helpers/sseBus'
import {
  applyProgressEvent,
  clearProgressFor,
  type SubAgentProgressEvent,
  type SubAgentProgressMap,
} from '../../../helpers/subagentProgress'
import { useAgentErrorStore } from '../../../stores/agentError'
import type { Message } from './useChatMessagePresentation'
import type { VirtualScrollerExposed } from './chatViewTypes'

export interface ChatSseDeps {
  sessionId: Ref<string>
  messages: Ref<Message[]>
  queuedMessages: Ref<api.QueuedMessage[]>
  isStreaming: Ref<boolean>
  isAtBottom: Ref<boolean>
  lastAutoStickAt: Ref<number>
  maxTotalTokens: Ref<number>
  sessionSkills: Ref<api.SkillInfo[]>
  subAgentProgressMap: Ref<SubAgentProgressMap>
  virtualScrollerRef: Ref<VirtualScrollerExposed | null>
  agentErrorStore: ReturnType<typeof useAgentErrorStore>
  toChatMessages: (
    rows: Awaited<ReturnType<typeof api.getChatHistory>>['messages'] | undefined,
  ) => Message[]
  mergeMessagesById: (current: Message[], incoming: Message[]) => Message[]
  rememberLiveMessage: (sid: string, id: string, role: Message['role']) => void
  currentLiveMessages: () => Message[]
  applyDeltaExtra: (extra: {
    cwd?: string
    git_worktree_cwd?: string
    pr_url?: string
    pr_provider?: string
    selected_profile_model?: string
    max_total_tokens?: number
    max_capacity_total_tokens?: number
    skills?: api.SkillInfo[]
  }) => void
  loadChatHistory: () => Promise<void>
  scrollToBottom: (force?: boolean, trigger?: string) => Promise<void>
  followNewestTurn: (trigger: string) => void
  maybeRefreshWorktreeBinding: (role: string, toolName?: string) => void
  setupCodeBlockCopyButtons: () => void
  claimLiveMessageSession: (sid: string) => void
  bumpStreamContentVersion: () => void
  logger: () => ScrollLogger
  PAGE_SIZE: number
  streamingContent: Ref<string>
  groupKeyForMessageId: (messageId: string) => string | null
  liveMessageIds: Set<string>
}

export function useChatSse(deps: ChatSseDeps) {
  const {
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
  } = deps

  // ─── SSE ───────────────────────────────────────────────────────────────────── Bus listener
  // unsubscribes.
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
    const sid = sessionId.value
    if (!sid) return
    claimLiveMessageSession(sid)

    // Defensive: if a previous connectSse didn't clean up (e.g. mid-mount session change), tear down
    // before re-registering. The bus's single global EventSource is already open (App.vue opens it
    // once), so we only need to manage our listener subscriptions here.
    disconnectSse()

    streamingContent.value = ''

    // App.vue normally installs the bus in its own onMounted, which runs
    // after a child ChatView mounts. Install lazily here as well so an
    // early subscription is never silently lost.
    installSseBus()
    const bus = useSseBus()
    // Subscribe FIRST so we don't miss any bus events that arrive between registration and the next
    // tick.
    offLlm = bus.on('llm', (event: api.SseEvent) => {
      if (event.session_id !== sid) return

      if ((event as SubAgentProgressEvent).role === 'subagent_progress') {
        subAgentProgressMap.value = applyProgressEvent(
          subAgentProgressMap.value,
          event as SubAgentProgressEvent,
        )
        return
      }

      if (event.type === 'connected' && event.session_id) {
        return
      }

      if (event.type !== 'chunk' && event.type !== 'chunk_final' && event.type !== 'full') {
        return
      }

      if (event.type === 'full' && event.is_error) {
        agentErrorStore.setError(sid, event.content || '', event.id || undefined)
        nextTick(() => scrollToBottom(false, 'agent-error-card'))
        return
      }

      if (event.type === 'chunk' && event.content) {
        streamingContent.value += event.content
        bumpStreamContentVersion()
        updateStreamingMessage()
        return
      }

      if (event.type === 'chunk_final') {
        if (event.total_tokens) {
          maxTotalTokens.value = event.total_tokens
        }
        if (!event.is_error && agentErrorStore.bySession[sid]) {
          agentErrorStore.clearForSession(sid)
        }
        return
      }

      const hasRenderableFullPayload = !!(
        event.content ||
        event.reasoning_content ||
        event.tool_call_id ||
        event.tool_name ||
        (event.image_url && event.image_url.length > 0) ||
        (event.video_url && event.video_url.length > 0)
      )
      if (event.type === 'full' && event.finish_reason && hasRenderableFullPayload) {
        if (agentErrorStore.bySession[sid]) {
          agentErrorStore.clearForSession(sid)
        }
        const streamingGroupKey = groupKeyForMessageId(
          messages.value.find((m) => m.id.startsWith('streaming-'))?.id ?? '',
        )
        messages.value = messages.value.filter((m) => !m.id.startsWith('streaming-'))

        const role =
          (event.role as 'user' | 'assistant' | 'system' | 'tool') ||
          (event.tool_call_id ? 'tool' : 'assistant')

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
            existingById.file_attachments = event.file_attachments
            existingById.is_input = event.is_input
            existingById.is_output = event.is_output
            rememberLiveMessage(sid, event.id, role)
            persistSseFullRowLocally(sid, event, role, event.id, existingById.timestamp)
            streamingContent.value = ''
            isStreaming.value = false
            logger().markProgrammatic()
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
            // Live skills: backend piggybacks session_skills on every llm_full (fresh on tool-result
            // emit, stale on assistant emit — see handle_tool.zig:459 vs :745). REST remains initial
            // source. Scoped by the event.session_id !== sid filter at handler entry.
            if (Array.isArray(event.session_skills))
              sessionSkills.value = event.session_skills as api.SkillInfo[]
            maybeRefreshWorktreeBinding(role, event.tool_name)
            return
          }
        }

        const dup = messages.value.find((m) => {
          if (m.role !== role) return false
          if ((m.tool_call_id ?? '') !== (event.tool_call_id ?? '')) return false
          return m.content === (event.content || '')
        })
        if (dup && role !== 'user') {
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
          // Decode the `||`-joined wire string the backend sends. A plain `split('|')` would turn
          // `A||B` into `["A", "", "B"]`, and the empty entry renders as `<img src="">` — a
          // broken-image icon in the transcript.
          image_urls: splitMediaUrlsWire(event.image_url),
          video_urls: splitMediaUrlsWire(event.video_url),
          file_attachments: event.file_attachments,
          finish_reason: event.finish_reason,
          tool_call_id: event.tool_call_id,
          tool_calls_json: event.tool_calls_json,
          is_input: event.is_input,
          is_output: event.is_output,
          reasoning_content: event.reasoning_content || undefined,
        })
        // Write-through: persist the SSE `full` row with its full wire shape
        // so cached mounts render it identically. Best-effort.
        persistSseFullRowLocally(sid, event, role, messageId, messageTimestamp)
        if (streamingGroupKey && event.id) {
          const newGroupKey = groupKeyForMessageId(event.id)
          if (newGroupKey && newGroupKey !== streamingGroupKey) {
            virtualScrollerRef.value?.rekeyHeight(streamingGroupKey, newGroupKey)
          }
        }
        streamingContent.value = ''
        isStreaming.value = false
        logger().markProgrammatic()
        // One more auto-stick fires (scrollToBottom below) for the final, post-stream assistant
        // message. Mark the timestamp so the loadMore gate sees the stick as still active during the
        // tail of the message-complete render frame.
        lastAutoStickAt.value = Date.now()
        nextTick(() => {
          // Recompute the height model BEFORE the auto-stick (append-gap fix): the streaming-* row
          // was just replaced by the canonical DB row, which re-renders at a DIFFERENT height
          // (markdown settles, reasoning collapses). nextTick first.
          if (isAtBottom.value) virtualScrollerRef.value?.remeasure()
          scrollToBottom(false, 'sse-message-complete')
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
        // Live skills: backend piggybacks session_skills on every llm_full (fresh on tool-result
        // emit, stale on assistant emit — see handle_tool.zig:459 vs :745). REST remains initial
        // source. Scoped by the event.session_id !== sid filter at handler entry.
        if (Array.isArray(event.session_skills))
          sessionSkills.value = event.session_skills as api.SkillInfo[]
        maybeRefreshWorktreeBinding(role, event.tool_name)

        return
      }

      if (event.reasoning_content && !event.content) {
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
      if (event.action === 'queued') {
        queuedMessages.value.push({
          id: event.id ?? `q-${Date.now()}`,
          message: event.message,
        })
        // A queued turn renders no transcript row — it is only ever a row in the composer's queue
        // panel — so nothing in `messages` grows and none of the auto-stick triggers fire.
        followNewestTurn('queue-queued')
      } else if (event.action === 'deleted') {
        queuedMessages.value = queuedMessages.value.filter((m) => m.id !== event.id)
      }
    })
    // Stale-on-wake (cross-tab sharing): if this window just took over the shared connection, or
    // slept through a long hidden period, llm/queue events may have been missed entirely — fetch just
    // the tail (cursor+asc) and merge it.
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
    // Set isStreaming LAST so external observers (tests, UI) can poll it as a "listeners are wired
    // up" signal — flipping it before would race with test assertions that fire events into the bus
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

  // Coalesce flag for SSE-driven `scrollToBottom` calls. SSE chunks can fire 20+ times/sec, but we
  // only need one scrollToBottom per animation frame. Without this, the console floods with
  // `scroll-to-bottom-conditional` lines and we do redundant geometry reads.
  let sseScrollPending = false

  const updateStreamingMessage = () => {
    // Every SSE chunk drives an auto-stick via scrollToBottom below (coalesced to one-per-frame).
    // Mark the timestamp NOW, before the rAF coalesce, so the gate reflects the chunk that just
    // arrived — not the rAF callback that runs up to 16ms later.
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
      // Coalesce: SSE chunks can fire 20+ times/sec, but we only need one scrollToBottom per
      // animation frame. Without this, the console floods with `scroll-to-bottom-conditional` lines
      // and we do redundant geometry reads.
      if (!sseScrollPending) {
        sseScrollPending = true
        requestAnimationFrame(() => {
          sseScrollPending = false
          logger().markProgrammatic()
          // Recompute the height model BEFORE scrolling (append-gap fix), but ONLY when the stick is
          // engaged. A scrolled-up user must not be disturbed: remeasure mutates the sizer, and sizer
          // mutations during active reading = the bouncing-text bug.
          if (isAtBottom.value) virtualScrollerRef.value?.remeasure()
          scrollToBottom(false, 'sse-chunk')
        })
      }
    }
    nextTick(() => setupCodeBlockCopyButtons())
  }

  return {
    connectSse,
    disconnectSse,
    updateStreamingMessage,
  }
}
