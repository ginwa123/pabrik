/** Tests for ChatView's stream-resume-on-reselect behavior. 2026-09-02 stream-resume-on-reselect
 * (task_1787673548905_0) — when the user closes/re-selects a chat session mid-stream, ChatView
 * drops its `streaming-*` placeholder and resets `streamingContent`. */
import { afterEach, describe, expect, it, vi } from 'vitest'
import { ref } from 'vue'

type StreamMsg = {
  id: string
  role: 'assistant'
  content: string
}

type SseEventLike = {
  type: 'chunk' | 'chunk_final' | 'full' | 'connected'
  session_id?: string
  content?: string
  finish_reason?: string
  role?: string
  id?: string
}

type StreamSnapshot = {
  active: boolean
  content: string
}

const SID = 'sess_resume'

function makeHandler(_snapshot: StreamSnapshot) {
  const streamingContent = ref('')
  const isStreaming = ref(false)
  const messages = ref<StreamMsg[]>([])
  let snapshotFetched = false

  // Mirrors the planned ChatView resumeStreamFromSnapshot() — called
  // after loadChatHistory() and BEFORE connectSse() on mount.
  const resumeStreamFromSnapshot = async (
    fetchSnapshot: (sid: string) => Promise<StreamSnapshot>,
  ) => {
    const snap = await fetchSnapshot(SID)
    snapshotFetched = true
    if (!snap.active || !snap.content) return
    // Seed the buffer + recreate the streaming-* placeholder so the
    // next chunk event APPENDS to the recovered text instead of
    // starting from an empty string.
    streamingContent.value = snap.content
    updateStreamingMessage()
  }

  // Mirrors ChatView.vue connectSse() bus.on('llm') handler — the
  // relevant branches only.
  const onEvent = (event: SseEventLike) => {
    if (event.session_id !== SID) return

    if (event.type === 'connected') return
    if (event.type !== 'chunk' && event.type !== 'full' && event.type !== 'chunk_final') return

    if (event.type === 'chunk' && event.content) {
      streamingContent.value += event.content
      updateStreamingMessage()
      return
    }

    if (event.type === 'full' && event.finish_reason && !!event.content) {
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

  return {
    streamingContent,
    isStreaming,
    messages,
    onEvent,
    resumeStreamFromSnapshot,
    getSnapshotFetched: () => snapshotFetched,
  }
}

afterEach(() => {
  vi.restoreAllMocks()
})

describe('ChatView stream resume on reselect', () => {
  it('seeds the streaming row from an ACTIVE snapshot before chunks arrive', async () => {
    const h = makeHandler({ active: true, content: 'partial text from backend' })
    await h.resumeStreamFromSnapshot(async () => ({ active: true, content: 'partial text from backend' }))

    expect(h.getSnapshotFetched()).toBe(true)
    const streamingRow = h.messages.value.find((m) => m.id.startsWith('streaming-'))
    expect(streamingRow?.content).toBe('partial text from backend')
    expect(h.streamingContent.value).toBe('partial text from backend')
  })

  it('subsequent chunk events APPEND to the restored text', async () => {
    const h = makeHandler({ active: true, content: 'partial' })
    await h.resumeStreamFromSnapshot(async () => ({ active: true, content: 'partial' }))

    h.onEvent({ type: 'chunk', session_id: SID, content: ' continued' })

    expect(h.streamingContent.value).toBe('partial continued')
    const streamingRow = h.messages.value.find((m) => m.id.startsWith('streaming-'))
    expect(streamingRow?.content).toBe('partial continued')
  })

  it('does NOT seed anything for an INACTIVE snapshot', async () => {
    const h = makeHandler({ active: false, content: '' })
    await h.resumeStreamFromSnapshot(async () => ({ active: false, content: '' }))

    expect(h.messages.value.find((m) => m.id.startsWith('streaming-'))).toBeUndefined()
    expect(h.streamingContent.value).toBe('')
  })

  it('does NOT seed anything for an active snapshot with EMPTY content', async () => {
    const h = makeHandler({ active: true, content: '' })
    await h.resumeStreamFromSnapshot(async () => ({ active: true, content: '' }))

    expect(h.messages.value.find((m) => m.id.startsWith('streaming-'))).toBeUndefined()
  })

  it('full event after resume replaces the restored streaming row with the canonical one', async () => {
    const h = makeHandler({ active: true, content: 'partial' })
    await h.resumeStreamFromSnapshot(async () => ({ active: true, content: 'partial' }))
    h.onEvent({ type: 'chunk', session_id: SID, content: '+more' })

    h.onEvent({
      type: 'full',
      session_id: SID,
      role: 'assistant',
      content: 'final complete text',
      finish_reason: 'stop',
      id: 'db-row-9',
    })

    expect(h.messages.value).toHaveLength(1)
    expect(h.messages.value[0]).toMatchObject({ id: 'db-row-9', content: 'final complete text' })
    expect(h.streamingContent.value).toBe('')
  })
})
