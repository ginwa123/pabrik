/** Tests for ChatView's llm_chunk streaming-append behavior. 2026-08-23 llm-chunk-streaming — the
 * backend sends RAW DELTAS (choices[0].delta.content per provider SSE), so the chunk handler must
 * APPEND to streamingContent (the old `=` replace left only the last fragment visible). */
import { afterEach, describe, expect, it, vi } from 'vitest'
import { ref } from 'vue'

type StreamMsg = {
  id: string
  role: 'assistant'
  content: string
  reasoning_content?: string
}

type SseEventLike = {
  type: 'chunk' | 'chunk_final' | 'full' | 'connected'
  session_id?: string
  content?: string
  reasoning_content?: string
  finish_reason?: string
  role?: string
  id?: string
  total_tokens?: number
  tool_call_id?: string
  tool_name?: string
}

const SID = 'sess_target'

function makeHandler() {
  const streamingContent = ref('')
  const isStreaming = ref(false)
  const messages = ref<StreamMsg[]>([])
  const maxTotalTokens = ref(0)
  let finalEventsSeen = 0

  // Mirrors ChatView.vue connectSse() bus.on('llm') handler — the
  // relevant branches only, in the same order as the real component.
  const onEvent = (event: SseEventLike) => {
    if (event.session_id !== SID) return

    if (event.type === 'connected') return
    if (event.type !== 'chunk' && event.type !== 'full' && event.type !== 'chunk_final') return

    if (event.type === 'chunk' && event.content) {
      streamingContent.value += event.content
      updateStreamingMessage()
      return
    }

    if (event.type === 'chunk_final') {
      if (event.total_tokens) maxTotalTokens.value = event.total_tokens
      finalEventsSeen++
      return
    }

    if (
      event.type === 'full' &&
      event.finish_reason &&
      !!(
        event.content ||
        event.reasoning_content ||
        event.tool_call_id ||
        event.tool_name
      )
    ) {
      messages.value = messages.value.filter((m) => !m.id.startsWith('streaming-'))
      messages.value.push({
        id: event.id || `assistant-${Date.now()}`,
        role: (event.role as 'assistant') || 'assistant',
        content: event.content || '',
      })
      streamingContent.value = ''
      isStreaming.value = false
    }
  }

  // Mirrors ChatView.vue updateStreamingMessage() — find-and-mutate
  // keeps ONE streaming row (pushing a new row per chunk would thrash
  // VirtualScroller height estimates).
  function updateStreamingMessage() {
    const existing = messages.value.find(
      (m) => m.role === 'assistant' && m.id.startsWith('streaming-'),
    )
    if (existing) {
      existing.content = streamingContent.value
    } else {
      messages.value.push({
        id: `streaming-${Date.now()}`,
        role: 'assistant',
        content: streamingContent.value,
      })
    }
  }

  return { streamingContent, isStreaming, messages, maxTotalTokens, onEvent, getFinalSeen: () => finalEventsSeen }
}

afterEach(() => {
  vi.restoreAllMocks()
})

describe('ChatView llm_chunk streaming append', () => {
  it('APPENDS deltas so the streaming message shows the full text', () => {
    const h = makeHandler()
    h.onEvent({ type: 'chunk', session_id: SID, content: 'Hel' })
    h.onEvent({ type: 'chunk', session_id: SID, content: 'lo ' })
    h.onEvent({ type: 'chunk', session_id: SID, content: 'world' })

    expect(h.streamingContent.value).toBe('Hello world')
    const streamingRow = h.messages.value.find((m) => m.id.startsWith('streaming-'))
    expect(streamingRow?.content).toBe('Hello world')
  })

  it('keeps exactly ONE streaming row across many chunks', () => {
    const h = makeHandler()
    for (const piece of ['a', 'b', 'c', 'd', 'e']) {
      h.onEvent({ type: 'chunk', session_id: SID, content: piece })
    }
    const streamingRows = h.messages.value.filter((m) => m.id.startsWith('streaming-'))
    expect(streamingRows).toHaveLength(1)
    expect(streamingRows[0]?.content).toBe('abcde')
  })

  it('drops chunks for a different session (payload must carry session_id)', () => {
    const h = makeHandler()
    h.onEvent({ type: 'chunk', session_id: 'OTHER_SESSION', content: 'nope' })
    expect(h.streamingContent.value).toBe('')
    expect(h.messages.value).toHaveLength(0)
  })

  it('full event replaces the streaming row with the canonical one and clears the buffer', () => {
    const h = makeHandler()
    h.onEvent({ type: 'chunk', session_id: SID, content: 'partial' })
    h.onEvent({
      type: 'full',
      session_id: SID,
      role: 'assistant',
      content: 'final complete text',
      finish_reason: 'stop',
      id: 'db-row-1',
    })

    expect(h.streamingContent.value).toBe('')
    expect(h.messages.value).toHaveLength(1)
    expect(h.messages.value[0]).toMatchObject({
      id: 'db-row-1',
      content: 'final complete text',
    })
    expect(h.messages.value.some((m) => m.id.startsWith('streaming-'))).toBe(false)
  })

  it('chunk_final updates maxTotalTokens WITHOUT pushing a message or clearing the buffer', () => {
    const h = makeHandler()
    h.onEvent({ type: 'chunk', session_id: SID, content: 'streaming text' })
    h.onEvent({ type: 'chunk_final', session_id: SID, total_tokens: 4321 })

    expect(h.maxTotalTokens.value).toBe(4321)
    expect(h.getFinalSeen()).toBe(1)
    // No message pushed by chunk_final itself; streaming buffer intact
    // until the canonical full event arrives.
    expect(h.streamingContent.value).toBe('streaming text')
    expect(
      h.messages.value.filter((m) => !m.id.startsWith('streaming-')),
    ).toHaveLength(0)
  })
})
