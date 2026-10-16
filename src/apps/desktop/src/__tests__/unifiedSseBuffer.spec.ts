/** unifiedSseBuffer.spec.ts Regression test for Plan Reviewer finding #1 (in
 * docs/superpowers/plans/2026-06-30-unify-sse-endpoints.md): The unified factory's default-message
 * handler MUST use a SINGLE shared buffer for the 3 default-`message` event families (workers. */
import { assert, beforeEach, describe, expect, it, vi } from 'vitest'

import { createUnifiedSseConnection } from '../api'
import * as sseClient from '../helpers/sseClient'

describe('createUnifiedSseConnection: single-buffer design (regression for Plan Reviewer #1)', () => {
  // Mock the SseClient so we capture the onEvent callback without needing a real EventSource.
  // Returns a stub SseClient (we never call .close() etc. in these tests). Spy lifecycle note:
  // vi.spyOn() returns a live spy.
  const spy = vi.spyOn(sseClient, 'createSseClient')
  let capturedOnEvent: ((raw: string, eventType: string) => void) | null = null

  beforeEach(() => {
    capturedOnEvent = null
    spy.mockImplementation(((opts: sseClient.SseClientOptions) => {
      capturedOnEvent = opts.onEvent
      return {
        close: vi.fn(),
        reconnect: vi.fn(),
        getState: () => 'open' as const,
        onStateChange: () => () => {},
      }
    }) as unknown as typeof sseClient.createSseClient)
  })

  it('does not corrupt the buffer when 100 worker events are followed by 1 session event', () => {
    const workersCb = vi.fn()
    const sessionsCb = vi.fn()

    createUnifiedSseConnection({
      channels: {
        workers: workersCb,
        sessions: sessionsCb,
      },
    })

    // Sanity: the spy captured onEvent.
    expect(capturedOnEvent).not.toBeNull()

    // Fire 100 worker-shape events. Each MUST dispatch to workersCb.
    for (let i = 0; i < 100; i++) {
      const ev = JSON.stringify({
        action: 'updated',
        id: `worker-${i}`,
        session_id: `session-${i}`,
        working_directory: `/tmp/worker-${i}`,
        last_activity: 1700000000 + i,
        last_activity_description: `tick ${i}`,
        created_at: '2026-06-30T00:00:00Z',
      })
      capturedOnEvent!(ev, 'message')
    }

    // All 100 worker events dispatched.
    expect(workersCb).toHaveBeenCalledTimes(100)

    // Now fire 1 session-shape event. If the buffer were leaked (per- channel buffers), this event
    // would be appended to a "session buffer" that already contains 100 worker events, and the
    // parser would produce malformed JSON → session cb fires 0 times.
    const sessionEvent = JSON.stringify({
      action: 'updated',
      id: 'session-final',
      name: 'Final Session',
      status: 'active',
      cwd: '/home/ginwa/project',
      created_at: '2026-06-30T00:00:00Z',
      updated_at: '2026-06-30T00:00:01Z',
    })
    capturedOnEvent!(sessionEvent, 'message')

    // With the correct (1-buffer) design: session cb fires exactly 1
    // time, and the dispatched object is the session event — not
    // garbage, not a worker event.
    expect(sessionsCb).toHaveBeenCalledTimes(1)
    const dispatchedSession = sessionsCb.mock.calls[0]![0] as { id: string; action: string; status: string }
    expect(dispatchedSession.id).toBe('session-final')
    expect(dispatchedSession.action).toBe('updated')
    expect(dispatchedSession.status).toBe('active')
  })

  it('does not corrupt the buffer when 100 worker events are followed by 1 llm event', () => {
    const workersCb = vi.fn()
    const llmCb = vi.fn()

    createUnifiedSseConnection({
      channels: {
        workers: workersCb,
        llm: { sessionId: 'sid-abc', onEvent: llmCb },
      },
    })

    expect(capturedOnEvent).not.toBeNull()

    for (let i = 0; i < 100; i++) {
      const ev = JSON.stringify({
        action: 'updated',
        id: `worker-${i}`,
        session_id: `session-${i}`,
        working_directory: `/tmp/worker-${i}`,
        last_activity: 1700000000 + i,
        last_activity_description: `tick ${i}`,
        created_at: '2026-06-30T00:00:00Z',
      })
      capturedOnEvent!(ev, 'message')
    }
    expect(workersCb).toHaveBeenCalledTimes(100)

    // Fire an llm chunk event. The llm discriminator requires `type === 'chunk' | 'full'`. If the
    // buffer were leaked, this would never dispatch (parse throws on malformed multi-object
    // string).
    const llmChunk = JSON.stringify({
      type: 'chunk',
      content: 'hello world',
      session_id: 'sid-abc',
    })
    capturedOnEvent!(llmChunk, 'message')

    expect(llmCb).toHaveBeenCalledTimes(1)
    const dispatchedLlm = llmCb.mock.calls[0]![0] as { type: string; content: string; session_id: string }
    expect(dispatchedLlm.type).toBe('chunk')
    expect(dispatchedLlm.content).toBe('hello world')
    expect(dispatchedLlm.session_id).toBe('sid-abc')
  })

  it('dispatches interleaved workers + sessions events independently (single buffer is sliced per dispatch)', () => {
    const workersCb = vi.fn()
    const sessionsCb = vi.fn()
    const llmCb = vi.fn()

    createUnifiedSseConnection({
      channels: {
        workers: workersCb,
        sessions: sessionsCb,
        llm: { sessionId: 'sid-xyz', onEvent: llmCb },
      },
    })

    expect(capturedOnEvent).not.toBeNull()

    // 100 interleaved events — workers, sessions, llm, workers, sessions, llm, …
    for (let i = 0; i < 100; i++) {
      // 1/3 of events are worker-shape
      capturedOnEvent!(
        JSON.stringify({
          action: 'updated',
          id: `w-${i}`,
          session_id: `s-${i}`,
          working_directory: `/tmp/w-${i}`,
          last_activity: 1700000000 + i,
          last_activity_description: `tick ${i}`,
          created_at: '2026-06-30T00:00:00Z',
        }),
        'message',
      )
      // 1/3 are session-shape
      capturedOnEvent!(
        JSON.stringify({
          action: 'updated',
          id: `sess-${i}`,
          name: `S ${i}`,
          status: 'active',
          cwd: `/tmp/sess-${i}`,
          created_at: '2026-06-30T00:00:00Z',
          updated_at: '2026-06-30T00:00:01Z',
        }),
        'message',
      )
      // 1/3 are llm-shape
      capturedOnEvent!(
        JSON.stringify({ type: 'chunk', content: `chunk ${i}`, session_id: 'sid-xyz' }),
        'message',
      )
    }

    // Each channel cb fires exactly the expected number of times —
    // and only for events matching its shape.
    expect(workersCb).toHaveBeenCalledTimes(100)
    expect(sessionsCb).toHaveBeenCalledTimes(100)
    expect(llmCb).toHaveBeenCalledTimes(100)

    // Spot-check that each callback received the right kind of event.
    const firstWorker = workersCb.mock.calls[0]![0] as { id: string }
    expect(firstWorker.id).toBe('w-0')
    const firstSession = sessionsCb.mock.calls[0]![0] as { id: string }
    expect(firstSession.id).toBe('sess-0')
    const firstLlm = llmCb.mock.calls[0]![0] as { content: string }
    expect(firstLlm.content).toBe('chunk 0')
  })

  it('resets the buffer on a connected event (no leakage across reconnects)', () => {
    const workersCb = vi.fn()

    createUnifiedSseConnection({ channels: { workers: workersCb } })

    expect(capturedOnEvent).not.toBeNull()

    // Simulate the server sending a 'connected' event mid-stream
    // (e.g. reconnect). This MUST reset the buffer — leftover bytes
    // from a previous connection would corrupt the next parse.
    capturedOnEvent!('{"connected":true}', 'connected')

    // After connected, fire a worker event. Should dispatch.
    capturedOnEvent!(
      JSON.stringify({
        action: 'updated',
        id: 'w-after-reconnect',
        session_id: 's-1',
        working_directory: '/tmp/w-1',
        last_activity: 1700000000,
        last_activity_description: 'after reconnect',
        created_at: '2026-06-30T00:00:00Z',
      }),
      'message',
    )

    expect(workersCb).toHaveBeenCalledTimes(1)
    const dispatched = workersCb.mock.calls[0]![0] as { id: string }
    expect(dispatched.id).toBe('w-after-reconnect')
  })

  it('does not dispatch a worker event to the sessions channel (shape discrimination is correct)', () => {
    // Defense against the obvious footgun: an event with `action`
    // should NEVER be dispatched to sessions if it doesn't have
    // `status + cwd`. The discriminator checks all 3 fields.
    const sessionsCb = vi.fn()
    const workersCb = vi.fn()

    createUnifiedSseConnection({
      channels: { sessions: sessionsCb, workers: workersCb },
    })

    // Worker-shape event (has action + working_directory, no status/cwd).
    capturedOnEvent!(
      JSON.stringify({
        action: 'updated',
        id: 'w-1',
        session_id: 's-1',
        working_directory: '/tmp/w-1',
        last_activity: 1700000000,
        last_activity_description: 'tick',
        created_at: '2026-06-30T00:00:00Z',
      }),
      'message',
    )

    expect(workersCb).toHaveBeenCalledTimes(1)
    expect(sessionsCb).toHaveBeenCalledTimes(0)

    // Session-shape event (has action + status + cwd).
    capturedOnEvent!(
      JSON.stringify({
        action: 'updated',
        id: 'sess-1',
        name: 'S',
        status: 'active',
        cwd: '/tmp/sess-1',
        created_at: '2026-06-30T00:00:00Z',
        updated_at: '2026-06-30T00:00:01Z',
      }),
      'message',
    )

    expect(sessionsCb).toHaveBeenCalledTimes(1)
    // Worker cb was NOT called for the session event.
    expect(workersCb).toHaveBeenCalledTimes(1)
  })

  /** Regression for Code Reviewer Critical Fix (2026-06-30): when the caller's `channels` set does
   * NOT include a consumer for a default-message event shape the backend emits, the buffer MUST
   * still advance past the event. Otherwise the buffer grows unboundedly on every dropped event. */
  it('advances the buffer past default-message events with no matching consumer', () => {
    // Re-spy with a fresh mockImplementation (the describe-level
    // spy already exists; just update its impl to capture the new
    // onEvent arg from this test's createUnifiedSseConnection call).
    spy.mockImplementation(((opts: sseClient.SseClientOptions) => {
      capturedOnEvent = opts.onEvent
      return {
        close: vi.fn(),
        reconnect: vi.fn(),
        getState: () => 'open' as const,
        onStateChange: () => () => {},
      }
    }) as unknown as typeof sseClient.createSseClient)

    const kanbanCb = vi.fn()
    // Note: NO workers/sessions/llm consumer — only kanban.
    createUnifiedSseConnection({
      channels: { kanban: kanbanCb },
    })

    // Fire 50 worker-shaped default-message events. None should
    // dispatch (no workers consumer), but the buffer MUST advance.
    for (let i = 0; i < 50; i++) {
      capturedOnEvent!(
        JSON.stringify({
          action: 'updated',
          id: `w-${i}`,
          session_id: `task_${i}`,
          working_directory: '/tmp/w',
          last_activity: 0,
          last_activity_description: 'tick',
          created_at: '2026-06-30T00:00:00Z',
        }),
        'message',
      )
    }

    // Now fire a kanban named event — it MUST reach the consumer.
    capturedOnEvent!(
      JSON.stringify({
        action: 'created',
        workspace_id: 'ws-1',
        item_id: 'item-1',
        column_id: 'col-1',
      }),
      'kanban_column',
    )

    expect(kanbanCb).toHaveBeenCalledTimes(1)
    // The bug doesn't fire the kanban cb with the right payload if
    // the buffer had been corrupted. Verify the payload is intact.
    expect(kanbanCb).toHaveBeenCalledWith(
      expect.objectContaining({ column_id: 'col-1', action: 'created' }),
    )

    // Follow up: fire a VALID default-message event AFTER the dropped ones.
    const afterCb = vi.fn()
    const client2 = createUnifiedSseConnection({
      channels: {
        kanban: () => {},
        sessions: afterCb,
      },
    })
    void client2

    // Drop a worker event (no workers consumer — sessions-cb
    // shouldn't fire either since neither discriminator matches).
    capturedOnEvent!(
      JSON.stringify({
        action: 'updated',
        id: 'w-x',
        session_id: 'task_x',
        working_directory: '/tmp/w',
        last_activity: 0,
        last_activity_description: 'tick',
        created_at: '2026-06-30T00:00:00Z',
      }),
      'message',
    )

    // Now fire a session event — MUST dispatch cleanly.
    capturedOnEvent!(
      JSON.stringify({
        action: 'updated',
        id: 's-1',
        name: 'S',
        status: 'active',
        cwd: '/tmp/s',
        created_at: '2026-06-30T00:00:00Z',
        updated_at: '2026-06-30T00:00:01Z',
      }),
      'message',
    )

    expect(afterCb).toHaveBeenCalledTimes(1)
  })
})

/** Regression tests for Chunk 4 of docs/superpowers/plans/2026-06-30-single-sse-all-sessions.md:
 * The `UnifiedChannels.llm` / `.queue` shapes now accept an OPTIONAL `sessionId`. */
describe('createUnifiedSseConnection: bare vs per-session tokens (Chunk 4)', () => {
  const spy = vi.spyOn(sseClient, 'createSseClient')
  let capturedUrl: string | null = null

  beforeEach(() => {
    capturedUrl = null
    spy.mockImplementation(((opts: sseClient.SseClientOptions) => {
      capturedUrl = opts.url
      return {
        close: vi.fn(),
        reconnect: vi.fn(),
        getState: () => 'open' as const,
        onStateChange: () => () => {},
      }
    }) as unknown as typeof sseClient.createSseClient)
  })

  it('sends bare "llm" token (not "llm:") when sessionId is omitted', () => {
    const llmCb = vi.fn()

    createUnifiedSseConnection({
      channels: { llm: { onEvent: llmCb } },
    })

    expect(capturedUrl).not.toBeNull()
    // Must contain the bare token
    expect(capturedUrl).toMatch(/[?&]channels=[^&]*\bllm\b/)
    // Must NOT contain the per-session form (`llm:` followed by anything)
    expect(capturedUrl).not.toMatch(/[?&]channels=[^&]*\bllm:/)
  })

  it('sends bare "queue" token (not "queue:") when sessionId is omitted', () => {
    const queueCb = vi.fn()

    createUnifiedSseConnection({
      channels: { queue: { onEvent: queueCb } },
    })

    expect(capturedUrl).not.toBeNull()
    expect(capturedUrl).toMatch(/[?&]channels=[^&]*\bqueue\b/)
    expect(capturedUrl).not.toMatch(/[?&]channels=[^&]*\bqueue:/)
  })

  it('sends per-session "llm:<sid>" token when sessionId is provided', () => {
    const llmCb = vi.fn()

    createUnifiedSseConnection({
      channels: { llm: { sessionId: 'sid-back-compat', onEvent: llmCb } },
    })

    expect(capturedUrl).not.toBeNull()
    expect(capturedUrl).toMatch(/[?&]channels=[^&]*\bllm:sid-back-compat\b/)
  })

  it('sends per-session "queue:<sid>" token when sessionId is provided', () => {
    const queueCb = vi.fn()

    createUnifiedSseConnection({
      channels: { queue: { sessionId: 'qid-back-compat', onEvent: queueCb } },
    })

    expect(capturedUrl).not.toBeNull()
    expect(capturedUrl).toMatch(/[?&]channels=[^&]*\bqueue:qid-back-compat\b/)
  })

  it('sends BOTH bare "llm" + bare "queue" when both channels omit sessionId (the bus shape)', () => {
    const llmCb = vi.fn()
    const queueCb = vi.fn()

    createUnifiedSseConnection({
      channels: {
        llm: { onEvent: llmCb },
        queue: { onEvent: queueCb },
      },
    })

    expect(capturedUrl).not.toBeNull()
    // Both bare tokens present
    expect(capturedUrl).toMatch(/[?&]channels=[^&]*\bllm\b/)
    expect(capturedUrl).toMatch(/[?&]channels=[^&]*\bqueue\b/)
    // Neither per-session form present
    expect(capturedUrl).not.toMatch(/[?&]channels=[^&]*\bllm:/)
    expect(capturedUrl).not.toMatch(/[?&]channels=[^&]*\bqueue:/)
  })
})

/** Regression tests for the granular `event:` names commit. See SseClient JSDoc + the project
 * memory browser-eventsource-named-events.md. */
describe('createUnifiedSseConnection: pre-registers all granular event names', () => {
  const REQUIRED_EVENT_TYPES = [
    'kanban_column',
    'kanban_task',
    'queue_queued',
    'queue_deleted',
    'llm_chunk',
    'llm_full',
    'worker_created',
    'worker_updated',
    'worker_deleted',
    'session_created',
    'session_deleted',
    'session_updated', // task_1786507100896 — auto-rename on first user message + unattended toggle
    // Design-mode events (src/ai_workflow/tui/on_event_sent_design.zig): - design_element_created /
    // _updated / _deleted — single - design_elements_geometry_batch_updated — batch (emitted by
    // `updateElementsBatch` AND `moveElementsWithDescendantsBatch`).
    'design_element_created',
    'design_element_updated',
    'design_element_deleted',
    'design_elements_geometry_batch_updated',
  ]

  const spy = vi.spyOn(sseClient, 'createSseClient')
  let capturedAdditionalEventTypes: string[] | null = null

  beforeEach(() => {
    capturedAdditionalEventTypes = null
    spy.mockImplementation(((opts: sseClient.SseClientOptions) => {
      capturedAdditionalEventTypes = opts.additionalEventTypes ?? null
      return {
        close: vi.fn(),
        reconnect: vi.fn(),
        getState: () => 'open' as const,
        onStateChange: () => () => {},
      }
    }) as unknown as typeof sseClient.createSseClient)
  })

  it('registers every required event type as an additionalEventType', () => {
    // Any single-channel subscription triggers factory construction.
    createUnifiedSseConnection({
      channels: { workers: () => {} },
    })

    expect(capturedAdditionalEventTypes).not.toBeNull()
    const registered = new Set(capturedAdditionalEventTypes!)
    for (const name of REQUIRED_EVENT_TYPES) {
      assert(
        registered.has(name),
        `expected additionalEventTypes to include "${name}" but the list was: [${capturedAdditionalEventTypes!.join(', ')}]`,
      )
    }
  })

  it('does NOT register the obsolete "queue_message" event name', () => {
    // Belt-and-braces: the queue event name was renamed from
    // `queue_message` to `queue_queued` for parity with `queue_deleted`.
    // The old name must NOT appear in additionalEventTypes anymore.
    createUnifiedSseConnection({
      channels: { queue: { onEvent: () => {} } },
    })

    expect(capturedAdditionalEventTypes).not.toBeNull()
    expect(capturedAdditionalEventTypes).not.toContain('queue_message')
  })

  it('dispatches design_elements_geometry_batch_updated to opts.channels.design', () => {
    // Bug history (2026-08-06): the move-batch endpoint emitted
    // `design_elements_geometry_batch_updated` SSE events, but the dispatcher's if-chain only
    // handled the three singular event names.
    let capturedOnEvent: ((raw: string, type: string) => void) | null = null
    spy.mockImplementation(((opts: sseClient.SseClientOptions) => {
      capturedOnEvent = opts.onEvent
      return {
        close: vi.fn(),
        reconnect: vi.fn(),
        getState: () => 'open' as const,
        onStateChange: () => {},
      }
    }) as unknown as typeof sseClient.createSseClient)

    const designCb = vi.fn()
    createUnifiedSseConnection({
      channels: { design: designCb },
    })

    expect(capturedOnEvent).not.toBeNull()
    capturedOnEvent!(
      JSON.stringify({
        workspace_id: 'ws-1',
        item_id: 'item-1',
        page_id: 'page-1',
        element_ids: ['elem-root', 'elem-child1'],
        updated_at: 0,
      }),
      'design_elements_geometry_batch_updated',
    )

    expect(designCb).toHaveBeenCalledTimes(1)
    expect(designCb).toHaveBeenCalledWith(
      expect.objectContaining({
        workspace_id: 'ws-1',
        element_ids: ['elem-root', 'elem-child1'],
      }),
    )
  })

  /** Regression test for task_1786507100896: when the backend emits a session rename on first user
   * message (LLM auto-name), the downstream consumer's `sessions` callback MUST fire. */
  it('routes session_updated wire events to the sessions channel callback', () => {
    const sessionsCb = vi.fn()
    let capturedOnEvent: ((raw: string, eventType: string) => void) | null = null
    const localSpy = vi.spyOn(sseClient, 'createSseClient')
    localSpy.mockImplementation(((opts: sseClient.SseClientOptions) => {
      capturedOnEvent = opts.onEvent
      return {
        close: vi.fn(),
        reconnect: vi.fn(),
        getState: () => 'open' as const,
        onStateChange: () => () => {},
      }
    }) as unknown as typeof sseClient.createSseClient)

    createUnifiedSseConnection({
      channels: { sessions: sessionsCb },
    })

    expect(capturedOnEvent).not.toBeNull()

    // Simulate the wire-format payload the backend emits on updateSessionName cascade (see
    // agentic_loop/update_session_name.zig:24-34 + the OnEventInputSessions struct in
    // sse_on_event_send_session.zig:7-17).
    const payload = JSON.stringify({
      action: 'updated',
      id: 'session_abc',
      name: 'Auto-generated name',
      status: 'idle',
      cwd: '/tmp',
      created_at: '2026-08-12T10:00:00Z',
      updated_at: '2026-08-12T10:00:05Z',
      selected_profile_model: '',
      git_worktree_cwd: '',
    })
    capturedOnEvent!(payload, 'session_updated')

    expect(sessionsCb).toHaveBeenCalledTimes(1)
    expect(sessionsCb).toHaveBeenCalledWith(
      expect.objectContaining({
        action: 'updated',
        id: 'session_abc',
        name: 'Auto-generated name',
      }),
    )

    localSpy.mockRestore()
  })
})