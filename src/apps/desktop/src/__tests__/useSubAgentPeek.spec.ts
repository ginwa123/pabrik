/** Tests for the useSubAgentPeek composable (skeleton — Chunk 1). Mocks global.fetch to assert the
 * initial history call shape and the messages ref updates. The SSE/chunk-accumulation behavior is
 * covered by Chunk 2 tests. */
/** After the single-global-EventSource migration (Chunks 1-3 of the `single-sse-all-sessions`
 * plan), the composable no longer creates its own SseClient and the bus no longer exposes a
 * per-session subscribe/unsubscribe API. */
/** The composable registers a listener on the bus's `llm` channel and filters by `event.session_id
 * === sid` on the JS side. Tests install the bus in `beforeEach` and drive `llm` events via
 * `__dispatchSseBus`. */
/** The bus's single global SseClient is replaced with a stub so no real EventSource is opened in
 * jsdom. */
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest'
import { defineComponent, h, nextTick } from 'vue'
import { mount, flushPromises } from '@vue/test-utils'
import { useSubAgentPeek } from '../composables/useSubAgentPeek'
import type { Message } from '../api'
import {
  installSseBus,
  __resetSseBus,
  __setSseBusGlobalClient,
  __dispatchSseBus,
} from '../helpers/sseBus'
import type { SseClient, SseState, SseStateInfo } from '../helpers/sseClient'

// ─── shared SSE stub ──────────────────────────────────────────────────────── Mirrors the helper
// in chatViewWorktree.spec.ts / sseBus.spec.ts.

// The stub satisfies the SseClient interface (close / reconnect / getState / onStateChange) so the
// bus's global client slot can be filled without opening a real EventSource in jsdom.
function makeStubClient(initial: SseState): SseClient {
  const stub: {
    close: ReturnType<typeof vi.fn>
    reconnect: ReturnType<typeof vi.fn>
    getState: () => SseState
    onStateChange: (cb: (s: SseState, info: SseStateInfo) => void) => () => void
    _state: SseState
  } = {
    close: vi.fn(),
    reconnect: vi.fn(),
    getState: () => stub._state,
    onStateChange: (_cb) => () => {},
    _state: initial,
  }
  return stub as unknown as SseClient
}

describe('useSubAgentPeek', () => {
  const originalFetch = global.fetch
  const fetchMock = vi.fn()

  beforeEach(() => {
    fetchMock.mockReset()
    global.fetch = fetchMock as unknown as typeof fetch

    // Install the bus BEFORE mounting so useSubAgentPeek's `useSseBus()` call in openSse finds an
    // installed bus (the bus throws "useSseBus called before installSseBus" if not installed).

    // The global client is stubbed so no real EventSource is opened in jsdom — the stub satisfies
    // the SseClient interface. The bus owns a single global SseClient carrying all 5 channels;
    // tests drive the `llm` channel via `__dispatchSseBus`.
    __resetSseBus()
    installSseBus({} as unknown as Parameters<typeof installSseBus>[0])
    __setSseBusGlobalClient(makeStubClient('connecting'))
  })

  afterEach(() => {
    global.fetch = originalFetch
    __resetSseBus()
    vi.clearAllMocks()
  })

  function mockFetchOnce(status: number, body: unknown) {
    fetchMock.mockResolvedValueOnce({
      ok: status >= 200 && status < 300,
      status,
      json: () => Promise.resolve(body),
      text: () => Promise.resolve(JSON.stringify(body)),
    } as Response)
  }

  // Build a Message[] with permissive typing — the backend sends `finish_reason: null` for
  // in-progress messages even though the TypeScript interface declares it as `string | undefined`.
  // We build the realistic shape here and cast at the boundary.
  function msgs(rows: Array<Partial<Message> & { id: string; role: Message['role']; content: string; created_at: number }>): Message[] {
    return rows as unknown as Message[]
  }

  function mountWith(options: Parameters<typeof useSubAgentPeek>[0]) {
    let peek: ReturnType<typeof useSubAgentPeek> | null = null
    const Comp = defineComponent({
      setup() {
        peek = useSubAgentPeek(options)
        return () => h('div')
      },
    })
    const wrapper = mount(Comp)
    return { wrapper, get peek() { return peek! } }
  }

  it('fetches the initial history from /llm/session/{sid}/messages', async () => {
    const messages = msgs([
      { id: 'm1', role: 'user', content: 'do X', created_at: 1000 },
      {
        id: 'm2',
        role: 'assistant',
        content: 'OK, starting…',
        created_at: 1001,
        finish_reason: null as unknown as string, // backend sends null for in-progress
      },
    ])
    mockFetchOnce(200, { messages, has_more: false, next_cursor: null })

    const { peek } = mountWith({
      sessionId: 'subagent_1_foo',
      agentName: 'foo',
      instruction: 'do X',
    })

    expect(peek.status.value).toBe('loading')
    await flushPromises()
    expect(fetchMock).toHaveBeenCalledTimes(1)
    const [url] = fetchMock.mock.calls[0] as [string]
    expect(url).toContain('/llm/session/subagent_1_foo/messages')
    expect(url).toContain('sort_by=created_at')
    expect(url).toContain('direction=asc')
    expect(peek.messages.value).toHaveLength(2)
    expect(peek.messages.value[0]?.id).toBe('m1')
    // Last message has no finish_reason → SSE should open. After the global EventSource migration,
    // opening SSE no longer touches any per-session client; status=streaming is the observable
    // signal that the listener was registered on the bus.
    expect(peek.status.value).toBe('streaming')
  })

  it('marks status=complete when the latest message already has finish_reason', async () => {
    const messages = msgs([
      { id: 'm1', role: 'user', content: 'do X', created_at: 1000 },
      {
        id: 'm2',
        role: 'assistant',
        content: 'all done',
        created_at: 1001,
        finish_reason: 'stop',
      },
    ])
    mockFetchOnce(200, { messages, has_more: false, next_cursor: null })

    const { peek } = mountWith({
      sessionId: 'subagent_2_bar',
      agentName: 'bar',
      instruction: 'do X',
    })
    await flushPromises()

    expect(peek.status.value).toBe('complete')
    // No SSE listener registered for an already-completed sub-agent.
  })

  it('marks status=error when the initial fetch throws', async () => {
    fetchMock.mockRejectedValueOnce(new Error('network down'))
    // The apiFetch wrapper turns a rejected fetch into an ApiError
    // via the !response.ok branch — emulate that with a non-ok
    // response.
    fetchMock.mockReset()
    fetchMock.mockResolvedValueOnce({
      ok: false,
      status: 500,
      statusText: 'Internal Server Error',
      text: () => Promise.resolve('boom'),
      json: () => Promise.reject(new Error('not json')),
    } as Response)

    const { peek } = mountWith({
      sessionId: 'subagent_3_baz',
      agentName: 'baz',
      instruction: 'do X',
    })
    await flushPromises()

    expect(peek.status.value).toBe('error')
    expect(peek.errorMessage.value).toContain('500')
  })

  it('reloads via the public reload() action', async () => {
    mockFetchOnce(200, { messages: [], has_more: false, next_cursor: null })
    mockFetchOnce(200, { messages: [], has_more: false, next_cursor: null })

    const { peek } = mountWith({
      sessionId: 'subagent_4_qux',
      agentName: 'qux',
      instruction: 'do X',
    })
    await flushPromises()
    expect(fetchMock).toHaveBeenCalledTimes(1)

    await peek.reload()
    expect(fetchMock).toHaveBeenCalledTimes(2)
  })

  it('after unmount, bus events for the peek sid no longer mutate messages (listener unsubscribed)', async () => {
    const messages = msgs([
      { id: 'm1', role: 'user', content: 'do X', created_at: 1000 },
    ])
    mockFetchOnce(200, { messages, has_more: false, next_cursor: null })

    const peekSessionId = 'subagent_5b_listener_off'
    const { wrapper, peek } = mountWith({
      sessionId: peekSessionId,
      agentName: 'listener-off',
      instruction: 'do X',
    })
    await flushPromises()
    expect(peek.status.value).toBe('streaming')

    // Sanity: events for the peek sid DO update messages while the
    // composable is mounted.
    __dispatchSseBus('llm', {
      session_id: peekSessionId,
      id: 'a1',
      role: 'assistant',
      content: 'before-unmount',
     
    // eslint-disable-next-line @typescript-eslint/no-explicit-any
    } as any)
    await nextTick()
    expect(peek.messages.value.some((m) => m.content === 'before-unmount')).toBe(true)

    wrapper.unmount()

    // After unmount, dispatching more events for the peek sid must
    // NOT mutate messages — the listener unsubscribe in closeSse()
    // removed the callback from the bus's llm Set.
    __dispatchSseBus('llm', {
      session_id: peekSessionId,
      id: 'a2',
      role: 'assistant',
       
      content: 'after-unmount',
    // eslint-disable-next-line @typescript-eslint/no-explicit-any
    } as any)
    await nextTick()
    expect(peek.messages.value.some((m) => m.content === 'after-unmount')).toBe(false)
  })

  it('exposes a reactive totalTokens ref that defaults to 0', () => {
    const { peek } = mountWith({
      sessionId: 'subagent_6_corge',
      agentName: 'corge',
      instruction: 'do X',
    })
    expect(peek.totalTokens.value).toBe(0)
  })

  // ── Chunk 2 — chunk accumulation tests ────────────────────────────────── After the bus
  // migration, chunks arrive via `__dispatchSseBus('llm', ...)` rather than the old per-channel
  // onEvent callback.

  // The listener-side filter (`event.session_id !== sid` returns early) scopes the events to the
  // peek's own sid. Stable sid for the chunk scenario tests so the dispatched events match the
  // peek's filter.

  // Pulled out as a constant so the `creates a new message` test (which doesn't use
  // runChunkScenario) can also reuse it.
  const CHUNK_PEEK_SID = 'subagent_chunk_test'

  /**    * Drive streaming chunks through the bus's llm channel. Returns the composable's peek so callers
   * can assert on the final state. Each chunk is dispatched as `{ session_id: CHUNK_PEEK_SID,
   * ...chunk }` so the listener-side filter passes through. */
  async function runChunkScenario(
    initialMessages: Message[],
    chunks: Array<{
      id?: string
      role?: 'user' | 'assistant' | 'system' | 'tool'
      content?: string
      tool_calls_json?: unknown
      tool_call_id?: string
      tool_name?: string
      finish_reason?: string
      total_tokens?: number
    }>,
  ) {
    mockFetchOnce(200, { messages: initialMessages, has_more: false, next_cursor: null })
    const { peek } = mountWith({
      sessionId: CHUNK_PEEK_SID,
      agentName: 'chunk-test',
      instruction: 'do X',
    })
    await flushPromises()

    for (const chunk of chunks) {
      __dispatchSseBus('llm', {
         
        session_id: CHUNK_PEEK_SID,
        ...chunk,
      // eslint-disable-next-line @typescript-eslint/no-explicit-any
      } as any)
      await nextTick()
    }
    return peek
  }

  it('appends a content chunk to an in-progress assistant message (find-or-create by id)', async () => {
    const initial = msgs([
      { id: 'm1', role: 'user', content: 'do X', created_at: 1000 },
    ])
    const peek = await runChunkScenario(initial, [
      // First SSE chunk for assistant message id=a1 — creates it
      { id: 'a1', role: 'assistant', content: 'Hello' },
      // Second chunk — appends to the existing a1
      { id: 'a1', role: 'assistant', content: ' world' },
      // Third chunk with finish_reason — closes the bubble
      { id: 'a1', role: 'assistant', content: '!', finish_reason: 'stop' },
    ])

    expect(peek.messages.value).toHaveLength(2)
    const last = peek.messages.value[peek.messages.value.length - 1]!
    expect(last.id).toBe('a1')
    expect(last.content).toBe('Hello world!')
    expect(last.finish_reason).toBe('stop')
    expect(peek.status.value).toBe('complete')
  })

  it('creates a new message when SSE chunk has no matching id', async () => {
    // No initial fetch — patch fetchMock to return empty
    fetchMock.mockReset()
    fetchMock.mockResolvedValueOnce({
      ok: true,
      status: 200,
      json: () => Promise.resolve({ messages: [], has_more: false, next_cursor: null }),
      text: () => Promise.resolve('{"messages":[]}'),
    } as Response)

    const NEW_MSG_PEEK_SID = 'subagent_new_msg'
    const { peek } = mountWith({
      sessionId: NEW_MSG_PEEK_SID,
      agentName: 'new-msg',
      instruction: 'do X',
    })
    await flushPromises()

    // Drive the chunk through the bus with the peek's sid so the listener-side filter lets it
    // through. The chunk has no matching message in `messages` (empty initial fetch) so
    // `applyChunkToMessages` must create a NEW tool message.
    __dispatchSseBus('llm', {
      session_id: NEW_MSG_PEEK_SID,
      id: 'x1',
       
      role: 'tool',
      content: 'r',
      tool_call_id: 'call_1',
    // eslint-disable-next-line @typescript-eslint/no-explicit-any
    } as any)
    await nextTick()

    expect(peek.messages.value).toHaveLength(1)
    expect(peek.messages.value[0]?.role).toBe('tool')
    expect(peek.messages.value[0]?.tool_call_id).toBe('call_1')
  })

  it('listener-side filter drops bus events for OTHER session_ids (cross-peek isolation)', async () => {
    // Two peeks on different sids — bus events for sid A must not
    // mutate peek B's messages, and vice versa. Mirrors the
    // cross-session isolation test in chatViewWorktree.spec.ts.
    mockFetchOnce(200, { messages: [], has_more: false, next_cursor: null })
    mockFetchOnce(200, { messages: [], has_more: false, next_cursor: null })

    const SID_A = 'subagent_iso_A'
    const SID_B = 'subagent_iso_B'

    const { peek: peekA } = mountWith({
      sessionId: SID_A,
      agentName: 'iso-A',
      instruction: 'do X',
    })
    const { peek: peekB } = mountWith({
      sessionId: SID_B,
      agentName: 'iso-B',
      instruction: 'do X',
    })
    await flushPromises()

    // Event for SID_A must mutate peekA only.
    __dispatchSseBus('llm', {
       
      session_id: SID_A,
      id: 'a1',
      role: 'assistant',
      content: 'for-A',
    // eslint-disable-next-line @typescript-eslint/no-explicit-any
    } as any)
    await nextTick()

    expect(peekA.messages.value.some((m) => m.content === 'for-A')).toBe(true)
    expect(peekB.messages.value.some((m) => m.content === 'for-A')).toBe(false)

    // Event for SID_B must mutate peekB only.
     
    __dispatchSseBus('llm', {
      session_id: SID_B,
      id: 'b1',
      role: 'assistant',
      content: 'for-B',
    // eslint-disable-next-line @typescript-eslint/no-explicit-any
    } as any)
    await nextTick()

    expect(peekA.messages.value.some((m) => m.content === 'for-B')).toBe(false)
    expect(peekB.messages.value.some((m) => m.content === 'for-B')).toBe(true)
  })

  it('tracks total_tokens from SSE chunks', async () => {
    const initial = msgs([
      { id: 'a1', role: 'assistant', content: '', created_at: 1000 },
    ])
    const peek = await runChunkScenario(initial, [
      { id: 'a1', role: 'assistant', content: 'partial', total_tokens: 4217 },
      { id: 'a1', role: 'assistant', content: 'more', total_tokens: 5102, finish_reason: 'stop' },
    ])

    expect(peek.totalTokens.value).toBe(5102)
  })

  it('keeps status=streaming while chunks arrive without finish_reason', async () => {
    const initial = msgs([{ id: 'a1', role: 'assistant', content: '', created_at: 1000 }])
    const peek = await runChunkScenario(initial, [
      { id: 'a1', role: 'assistant', content: 'chunk 1' },
      { id: 'a1', role: 'assistant', content: 'chunk 2' },
    ])
    expect(peek.status.value).toBe('streaming')
  })

  it('keeps status=streaming on tool_calls finish_reason (tool result still pending)', async () => {
    // 2026-09-04 subagent-peek fix: tool_calls is NOT terminal — the old
    // assertion (complete) stranded the panel on the first tool call.
    const initial = msgs([
      { id: 'a1', role: 'assistant', content: '', created_at: 1000 },
    ])
    const peek = await runChunkScenario(initial, [
      {
        id: 'a1',
        role: 'assistant',
        content: 'calling tool',
        finish_reason: 'tool_calls',
      },
    ])
    expect(peek.status.value).toBe('streaming')
  })

  it('encodes the sessionId in the fetch URL (spaces/slashes)', async () => {
    // 2026-09-04 subagent-peek P0: raw spaces break the HTTP request line.
    mockFetchOnce(200, { messages: [], has_more: false, next_cursor: null })
    mountWith({
      sessionId: 'subagent_1_backend implementer',
      agentName: 'backend implementer',
      instruction: 'do X',
    })
    await flushPromises()
    expect(fetchMock).toHaveBeenCalledTimes(1)
    const [url] = fetchMock.mock.calls[0] as [string]
    expect(url).toContain('/llm/session/subagent_1_backend%20implementer/messages')
    expect(url).not.toContain('backend implementer/messages')
  })

  it('refetches when a parent subagent_progress completed event arrives for our sid', async () => {
    // 2026-09-04 subagent-peek P2: panel opened mid-run with 0 rows must
    // populate after done via the parent-scoped completed event.
    const sid = 'subagent_9_refetch_me'
    mockFetchOnce(200, { messages: [], has_more: false, next_cursor: null })
    const { peek } = mountWith({ sessionId: sid, agentName: 'x', instruction: 'do X' })
    await flushPromises()
    expect(fetchMock).toHaveBeenCalledTimes(1)
    expect(peek.messages.value).toHaveLength(0)

    const doneMsgs = msgs([
      { id: 'm1', role: 'user', content: 'do X', created_at: 1000 },
      { id: 'm2', role: 'assistant', content: 'all done', created_at: 1001, finish_reason: 'stop' },
    ])
    mockFetchOnce(200, { messages: doneMsgs, has_more: false, next_cursor: null })
    __dispatchSseBus('llm', {
      session_id: 'parent_1',
      role: 'subagent_progress',
      status: 'completed',
      subagent_session_id: sid,
    // eslint-disable-next-line @typescript-eslint/no-explicit-any
    } as any)
    await flushPromises()
    expect(fetchMock).toHaveBeenCalledTimes(2)
    expect(peek.messages.value).toHaveLength(2)
    expect(peek.status.value).toBe('complete')
  })

  it('ignores subagent_progress events for other sids', async () => {
    mockFetchOnce(200, { messages: [], has_more: false, next_cursor: null })
    mountWith({ sessionId: 'subagent_10_mine', agentName: 'x', instruction: 'do X' })
    await flushPromises()
    expect(fetchMock).toHaveBeenCalledTimes(1)
    __dispatchSseBus('llm', {
      session_id: 'parent_1',
      role: 'subagent_progress',
      status: 'completed',
      subagent_session_id: 'subagent_10_other',
    // eslint-disable-next-line @typescript-eslint/no-explicit-any
    } as any)
    await flushPromises()
    expect(fetchMock).toHaveBeenCalledTimes(1)
  })
})