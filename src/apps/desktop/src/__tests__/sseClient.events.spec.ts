import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest'

import { createSseClient } from '../helpers/sseClient'
import {
  createMockCtor,
  createMockTarget,
  createMockOnlineTarget,
} from './_helpers/sseClientHarness'

describe('createSseClient', () => {
  beforeEach(() => {
    vi.useFakeTimers()
  })
  afterEach(() => {
    vi.useRealTimers()
  })

  // 9b. 'connected' server event fires onConnected
  it('fires onConnected and passes the payload to onEvent on the `connected` event', () => {
    const { ctor, instances } = createMockCtor()
    const { target: visTarget } = createMockTarget(false)
    const { target: onlineTarget } = createMockOnlineTarget()

    const onConnected = vi.fn()
    const onEvent = vi.fn()

    const client = createSseClient({
      url: '/test',
      EventSourceCtor: ctor,
      visibilityTarget: visTarget,
      onlineTarget: onlineTarget,
      pauseWhenHidden: false,
      onConnected,
      onEvent,
    })

    // Flush the deferred start() — createSseClient schedules start() on the next macrotask so the SSE setup is fully async (see helpers/sseClient.ts).
    vi.advanceTimersByTime(0)
    // Emit the 'connected' named event with a JSON payload.
    instances[0]!.emit('connected', JSON.stringify({ session_id: 'abc' }))
    expect(onConnected).toHaveBeenCalledTimes(1)
    expect(onEvent).toHaveBeenCalledWith(JSON.stringify({ session_id: 'abc' }), 'connected')
    expect(client.getState()).toBe('open')

    client.close()
  })

  // 9c. 'message' events go to onEvent
  it('routes `message` events to onEvent with the raw payload and type "message"', () => {
    const { ctor, instances } = createMockCtor()
    const { target: visTarget } = createMockTarget(false)
    const { target: onlineTarget } = createMockOnlineTarget()

    const onEvent = vi.fn()
    const client = createSseClient({
      url: '/test',
      EventSourceCtor: ctor,
      visibilityTarget: visTarget,
      onlineTarget: onlineTarget,
      pauseWhenHidden: false,
      onEvent,
    })

    // Flush the deferred start() — createSseClient schedules start() on the next macrotask so the SSE setup is fully async (see helpers/sseClient.ts).
    vi.advanceTimersByTime(0)
    instances[0]!.emit('connected', '{"ok":true}')
    onEvent.mockClear() // drop the 'connected' call
    instances[0]!.emit('message', '{"chunk":"hello"}')
    expect(onEvent).toHaveBeenCalledWith('{"chunk":"hello"}', 'message')

    client.close()
  })

  // 9d. additionalEventTypes registers listeners for custom named events (e.g.
  it('routes `additionalEventTypes` named events to onEvent with the event name as the type', () => {
    const { ctor, instances } = createMockCtor()
    const { target: visTarget } = createMockTarget(false)
    const { target: onlineTarget } = createMockOnlineTarget()

    const onEvent = vi.fn()
    const client = createSseClient({
      url: '/test',
      EventSourceCtor: ctor,
      visibilityTarget: visTarget,
      onlineTarget: onlineTarget,
      pauseWhenHidden: false,
      additionalEventTypes: ['queue_message', 'worker_event'],
      onEvent,
    })

    // Flush the deferred start() — createSseClient schedules start() on the next macrotask so the SSE setup is fully async (see helpers/sseClient.ts).
    vi.advanceTimersByTime(0)
    // Confirm the SseClient actually registered the listeners on the EventSource instance.
    expect(instances[0]!._listeners.get('queue_message')?.size ?? 0).toBe(1)
    expect(instances[0]!._listeners.get('worker_event')?.size ?? 0).toBe(1)

    instances[0]!.emit('connected', '{"ok":true}')
    onEvent.mockClear()
    instances[0]!.emit('queue_message', '{"action":"queued","message":"hi"}')
    expect(onEvent).toHaveBeenCalledWith('{"action":"queued","message":"hi"}', 'queue_message')

    // A second declared type also routes through.
    onEvent.mockClear()
    instances[0]!.emit('worker_event', '{"id":"w1"}')
    expect(onEvent).toHaveBeenCalledWith('{"id":"w1"}', 'worker_event')

    client.close()
  })

  // 9e. additionalEventTypes dedupes reserved names.
  it('silently de-duplicates reserved names (`connected`, `message`) in additionalEventTypes', () => {
    const { ctor, instances } = createMockCtor()
    const { target: visTarget } = createMockTarget(false)
    const { target: onlineTarget } = createMockOnlineTarget()

    const onEvent = vi.fn()
    const client = createSseClient({
      url: '/test',
      EventSourceCtor: ctor,
      visibilityTarget: visTarget,
      onlineTarget: onlineTarget,
      pauseWhenHidden: false,
      additionalEventTypes: ['connected', 'message', 'queue_message'],
      onEvent,
    })

    // Flush the deferred start() — createSseClient schedules start() on the next macrotask so the SSE setup is fully async (see helpers/sseClient.ts).
    vi.advanceTimersByTime(0)
    // 'connected' is registered by the SseClient itself (1 listener); the dedupe must NOT add a second.
    expect(instances[0]!._listeners.get('connected')?.size ?? 0).toBe(1)
    // 'message' is also registered by the SseClient itself.
    expect(instances[0]!._listeners.get('message')?.size ?? 0).toBe(1)
    // 'queue_message' is a custom name and gets one listener.
    expect(instances[0]!._listeners.get('queue_message')?.size ?? 0).toBe(1)

    // Confirm a 'message' event fires onEvent exactly once (not twice from the dedup-bug).
    instances[0]!.emit('connected', '{"ok":true}')
    onEvent.mockClear()
    instances[0]!.emit('message', 'real-data')
    expect(onEvent).toHaveBeenCalledTimes(1)
    expect(onEvent).toHaveBeenCalledWith('real-data', 'message')

    client.close()
  })

  // 9f. additionalEventTypes listeners are re-registered on reconnect.
  it('re-registers additionalEventTypes listeners after a reconnect', () => {
    const { ctor, instances } = createMockCtor()
    const { target: visTarget } = createMockTarget(false)
    const { target: onlineTarget } = createMockOnlineTarget()

    const onEvent = vi.fn()
    const client = createSseClient({
      url: '/test',
      EventSourceCtor: ctor,
      visibilityTarget: visTarget,
      onlineTarget: onlineTarget,
      // Deterministic random: returns the midpoint (0.5) so jitter is always 0.75 of the exponential value.
      random: () => 0.5,
      pauseWhenHidden: false,
      baseDelayMs: 1_000,
      maxDelayMs: 30_000,
      additionalEventTypes: ['queue_message'],
      onEvent,
    })

    // Flush the deferred start() — createSseClient schedules start() on the next macrotask so the SSE setup is fully async (see helpers/sseClient.ts).
    vi.advanceTimersByTime(0)
    // First instance: listener registered.
    expect(instances[0]!._listeners.get('queue_message')?.size ?? 0).toBe(1)

    // Simulate a connect → error → reconnect cycle.
    instances[0]!.emit('connected', '{"ok":true}')
    instances[0]!.emit('error')

    // Advance past the 750ms backoff to trigger the retry.
    vi.advanceTimersByTime(750)
    expect(instances.length).toBeGreaterThanOrEqual(2)

    // The new instance has the `queue_message` listener re-attached.
    expect(instances[1]!._listeners.get('queue_message')?.size ?? 0).toBe(1)

    // And the listener actually fires when the server sends the named event on the new connection.
    instances[1]!.emit('queue_message', '{"action":"deleted"}')
    expect(onEvent).toHaveBeenCalledWith('{"action":"deleted"}', 'queue_message')

    client.close()
  })

  // 9g.
  it('silently drops `ping` heartbeat messages from the default `message` event', () => {
    const { ctor, instances } = createMockCtor()
    const { target: visTarget } = createMockTarget(false)
    const { target: onlineTarget } = createMockOnlineTarget()

    const onEvent = vi.fn()
    const client = createSseClient({
      url: '/test',
      EventSourceCtor: ctor,
      visibilityTarget: visTarget,
      onlineTarget: onlineTarget,
      pauseWhenHidden: false,
      onEvent,
    })

    // Flush the deferred start() — createSseClient schedules start() on the next macrotask so the SSE setup is fully async (see helpers/sseClient.ts).
    vi.advanceTimersByTime(0)
    instances[0]!.emit('connected', '{"ok":true}')
    onEvent.mockClear()

    // 100 heartbeats in a row should result in ZERO onEvent calls.
    for (let i = 0; i < 100; i++) {
      instances[0]!.emit('message', 'ping')
    }
    expect(onEvent).not.toHaveBeenCalled()

    // A real message still passes through.
    instances[0]!.emit('message', '{"real":"data"}')
    expect(onEvent).toHaveBeenCalledWith('{"real":"data"}', 'message')
    expect(onEvent).toHaveBeenCalledTimes(1)

    client.close()
  })

  // 9h.
  it('disables the heartbeat filter when heartbeatData is null', () => {
    const { ctor, instances } = createMockCtor()
    const { target: visTarget } = createMockTarget(false)
    const { target: onlineTarget } = createMockOnlineTarget()

    const onEvent = vi.fn()
    const client = createSseClient({
      url: '/test',
      EventSourceCtor: ctor,
      visibilityTarget: visTarget,
      onlineTarget: onlineTarget,
      pauseWhenHidden: false,
      heartbeatData: null,
      onEvent,
    })

    // Flush the deferred start() — createSseClient schedules start() on the next macrotask so the SSE setup is fully async (see helpers/sseClient.ts).
    vi.advanceTimersByTime(0)
    instances[0]!.emit('connected', '{"ok":true}')
    onEvent.mockClear()

    instances[0]!.emit('message', 'ping')
    expect(onEvent).toHaveBeenCalledWith('ping', 'message')
    expect(onEvent).toHaveBeenCalledTimes(1)

    client.close()
  })

  // 9i.
  it('uses a custom heartbeatData string when provided', () => {
    const { ctor, instances } = createMockCtor()
    const { target: visTarget } = createMockTarget(false)
    const { target: onlineTarget } = createMockOnlineTarget()

    const onEvent = vi.fn()
    const client = createSseClient({
      url: '/test',
      EventSourceCtor: ctor,
      visibilityTarget: visTarget,
      onlineTarget: onlineTarget,
      pauseWhenHidden: false,
      heartbeatData: ':keepalive',
      onEvent,
    })

    // Flush the deferred start() — createSseClient schedules start() on the next macrotask so the SSE setup is fully async (see helpers/sseClient.ts).
    vi.advanceTimersByTime(0)
    instances[0]!.emit('connected', '{"ok":true}')
    onEvent.mockClear()

    // The custom keepalive is filtered.
    instances[0]!.emit('message', ':keepalive')
    expect(onEvent).not.toHaveBeenCalled()

    // The default 'ping' is NOT filtered anymore — the consumer now sees it as a regular event.
    instances[0]!.emit('message', 'ping')
    expect(onEvent).toHaveBeenCalledWith('ping', 'message')
    expect(onEvent).toHaveBeenCalledTimes(1)

    client.close()
  })
})
