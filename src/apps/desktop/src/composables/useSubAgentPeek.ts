/** useSubAgentPeek — composable for the sub-agent peek panel. Owns the lifecycle of a "peek" into a
 * sub-agent session: 1. Fetch the sub-agent's initial message history via `GET
 * /llm/session/{sid}/messages`. 2. */
import { onMounted, onUnmounted, ref, type Ref } from 'vue'
import { apiFetch, type SseEvent, type Message } from '../api'
import { useSseBus } from '../helpers/sseBus'

/** Inputs the composable needs to open a peek. */
export interface UseSubAgentPeekOptions {
  sessionId: string
  agentName: string
  instruction: string
}

/** Current lifecycle state of the peek. */
export type PeekStatus = 'idle' | 'loading' | 'streaming' | 'complete' | 'error'

/** Public surface of the composable (the panel reads these). */
export interface UseSubAgentPeekReturn {
  messages: Ref<Message[]>
  status: Ref<PeekStatus>
  errorMessage: Ref<string | null>
  totalTokens: Ref<number>
  /** Force a manual reload (wired to the "Retry" button in the error banner). */
  reload: () => Promise<void>
}

/** Internal — wraps a single SSE chunk and applies it to the messages ref. */
function applyChunkToMessages(
  messages: Ref<Message[]>,
  ev: SseEvent,
  totalTokens: Ref<number>,
  status: Ref<PeekStatus>,
): void {
  // Token-usage accounting — applied regardless of role.
  if (typeof ev.total_tokens === 'number' && !Number.isNaN(ev.total_tokens)) {
    totalTokens.value = ev.total_tokens
  }

  // Tool-result chunks — always create a NEW message keyed by
  // tool_call_id (the panel groups them with the assistant call).
  if (ev.role === 'tool' && ev.tool_call_id) {
    // Cast role='tool' through unknown — the public Message interface
    // doesn't list 'tool' as a role (only user/assistant/system), but
    // tool-result messages do arrive on the wire in practice.
    const newMsg = {
      id: ev.id ?? `tool-${ev.tool_call_id}`,
      role: 'tool',
      content: ev.content ?? '',
      created_at: ev.created_at ?? Math.floor(Date.now() / 1000),
      tool_call_id: ev.tool_call_id,
      tool_name: ev.tool_name,
      finish_reason: ev.finish_reason ?? undefined,
    } as unknown as Message
    messages.value = [...messages.value, newMsg]
  } else {
    // Assistant / user chunks — find-or-create by ev.id.
    const chunkId = ev.id
    const existingIdx = chunkId ? messages.value.findIndex((m) => m.id === chunkId) : -1

    if (existingIdx >= 0) {
      // Append / update the existing message in place (immutable splice).
      const existing = messages.value[existingIdx]!
      const updated: Message = {
        ...existing,
        content: (existing.content ?? '') + (ev.content ?? ''),
        finish_reason: ev.finish_reason ?? existing.finish_reason,
        // tool_calls_json / tool_name arrive on the assistant turn that emits a tool call; preserve
        // them across subsequent content chunks. 2026-08-24 wire-shape fix: only copy STRING values
        // into tool_calls_json.
        tool_calls_json:
          typeof (ev as { tool_calls?: unknown }).tool_calls === 'string'
            ? (ev as { tool_calls: string }).tool_calls
            : existing.tool_calls_json,
        tool_name: ev.tool_name ?? existing.tool_name,
      }
      const arr = messages.value.slice()
      arr[existingIdx] = updated
      messages.value = arr
    } else {
      // No matching id — append a new message.
      if (ev.content || (ev as { tool_calls?: unknown }).tool_calls || ev.role) {
        const newMsg = {
          id:
            ev.id ??
            `sse-${Math.floor(Date.now() / 1000)}-${Math.random().toString(36).slice(2, 8)}`,
          role: (ev.role as Message['role']) ?? 'assistant',
          content: ev.content ?? '',
          created_at: ev.created_at ?? Math.floor(Date.now() / 1000),
          tool_name: ev.tool_name,
          // 2026-08-24 wire-shape fix: only accept STRING tool_calls —
          // legacy array-shaped values are dropped (see applyChunkToMessages).
          tool_calls_json:
            typeof (ev as { tool_calls?: unknown }).tool_calls === 'string'
              ? (ev as { tool_calls: string }).tool_calls
              : undefined,
          finish_reason: ev.finish_reason ?? undefined,
        } as Message
        messages.value = [...messages.value, newMsg]
      }
    }
  }

  // Completion detection — applied to any chunk that carries a finish_reason. 2026-09-04
  // subagent-peek fix: `tool_calls` means "assistant stopped to await a tool result".
  if (
    ev.finish_reason === 'stop' ||
    ev.finish_reason === 'length' ||
    ev.finish_reason === 'content_filter'
  ) {
    status.value = 'complete'
  }
}

export function useSubAgentPeek(opts: UseSubAgentPeekOptions): UseSubAgentPeekReturn {
  const messages = ref<Message[]>([]) as Ref<Message[]>
  const status = ref<PeekStatus>('idle') as Ref<PeekStatus>
  const errorMessage = ref<string | null>(null) as Ref<string | null>
  const totalTokens = ref(0) as Ref<number>

  let offLlm: (() => void) | null = null

  async function fetchInitial(): Promise<void> {
    status.value = 'loading'
    errorMessage.value = null
    try {
      // We fetch in ASC order so messages render in chronological order.
      const data = await apiFetch<{
        messages: Message[]
        has_more: boolean
        next_cursor: string | null
      }>(
        `/llm/session/${encodeURIComponent(opts.sessionId)}/messages?sort_by=created_at&direction=asc&limit=100`,
        {
          silent: true,
        },
      )
      messages.value = Array.isArray(data.messages) ? data.messages : []

      // If the most recent message has a finish_reason, the
      // sub-agent already finished before we opened the panel.
      // Otherwise we need the SSE for live updates.
      const last = messages.value[messages.value.length - 1]
      if (last && last.finish_reason) {
        status.value = 'complete'
        closeSse()
      } else {
        status.value = 'streaming'
        openSse()
      }
    } catch (err) {
      errorMessage.value = err instanceof Error ? err.message : String(err)
      status.value = 'error'
    }
  }

  function openSse(): void {
    const bus = useSseBus()
    const sid = opts.sessionId
    offLlm = bus.on('llm', (event: SseEvent) => {
      // 2026-09-04 subagent-peek P2: completion signals are parent-scoped (progress events carry
      // session_id=parent + subagent_session_id=child). When OUR child completes, refetch — the
      // panel may have opened mid-run with 0 rows committed and missed the live chunks.
      if (event.role === 'subagent_progress') {
        if (
          event.subagent_session_id === sid &&
          (event.status === 'completed' || event.status === 'failed')
        ) {
          void fetchInitial()
        }
        return
      }
      // Listener-side filter — the bus's single global EventSource carries all sessions' llm
      // events, so we drop events for other sessions here.
      if (event.session_id !== sid) return
      applyChunkToMessages(messages, event, totalTokens, status)
    })
  }

  function closeSse(): void {
    if (offLlm) {
      offLlm()
      offLlm = null
    }
  }

  onMounted(() => {
    void fetchInitial()
  })

  // 2026-09-04 subagent-peek P1: eye-click from agent A -> agent B remounts the host (keyed by
  // sessionId), and `opts` is a plain snapshot object — so observing `opts.sessionId` never fires
  // (the source never changes).
  onUnmounted(() => {
    closeSse()
  })

  return {
    messages,
    status,
    errorMessage,
    totalTokens,
    reload: fetchInitial,
  }
}
