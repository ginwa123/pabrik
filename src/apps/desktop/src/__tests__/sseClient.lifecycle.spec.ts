import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest'

import { createSseClient, type SseState } from '../helpers/sseClient'
import {
  createMockCtor,
  createMockTarget,
  createMockOnlineTarget,
  createMockUnloadTarget,
} from './_helpers/sseClientHarness'

describe('createSseClient', () => {
  beforeEach(() => {
    vi.useFakeTimers()
  })
  afterEach(() => {
    vi.useRealTimers()
  })

  // Listener cleanup
  it('removes DOM listeners on close()', () => {
    const { ctor, instances } = createMockCtor()
    const { target: visTarget } = createMockTarget(false)
    const { target: onlineTarget } = createMockOnlineTarget()
    const { target: unloadTarget } = createMockUnloadTarget()

    const client = createSseClient({
      url: '/test',
      EventSourceCtor: ctor,
      visibilityTarget: visTarget,
      onlineTarget: onlineTarget,
      unloadTarget: unloadTarget,
      pauseWhenHidden: false,
      onEvent: () => {},
    })

    // Flush the deferred start() — createSseClient schedules start() on the next
    // macrotask so the SSE setup is fully async (see helpers/sseClient.ts).
    vi.advanceTimersByTime(0)
    // Before close: 1 visibility listener, 1 online listener,
    // 1 pagehide listener, 1 beforeunload listener.
    expect(visTarget._listeners.get('visibilitychange')?.size ?? 0).toBe(1)
    expect(onlineTarget._listeners.get('online')?.size ?? 0).toBe(1)
    expect(unloadTarget._listeners.get('pagehide')?.size ?? 0).toBe(1)
    expect(unloadTarget._listeners.get('beforeunload')?.size ?? 0).toBe(1)

    client.close()

    // After close: 0 listeners of each kind. This is the
    // defense against the App.vue-style timer-leak bug — a
    // closed client must not retain DOM references.
    expect(visTarget._listeners.get('visibilitychange')?.size ?? 0).toBe(0)
    expect(onlineTarget._listeners.get('online')?.size ?? 0).toBe(0)
    expect(unloadTarget._listeners.get('pagehide')?.size ?? 0).toBe(0)
    expect(unloadTarget._listeners.get('beforeunload')?.size ?? 0).toBe(0)

    // The underlying EventSource was also closed.
    expect(instances[0]!._closed).toBe(true)
  })

  // 10. pagehide / beforeunload cleanly tear down the connection (the 2026-01-15 fix for "SSE still
  // open after refresh").
  it('closes the connection on pagehide so it is not still "open" after refresh', () => {
    const { ctor, instances } = createMockCtor()
    const { target: visTarget } = createMockTarget(false)
    const { target: onlineTarget } = createMockOnlineTarget()
    const { target: unloadTarget } = createMockUnloadTarget()

    const states: SseState[] = []
    const client = createSseClient({
      url: '/test',
      EventSourceCtor: ctor,
      visibilityTarget: visTarget,
      onlineTarget: onlineTarget,
      unloadTarget: unloadTarget,
      pauseWhenHidden: false,
      onStateChange: (s) => states.push(s),
      onEvent: () => {},
    })

    // Flush the deferred start() — createSseClient schedules start() on the next
    // macrotask so the SSE setup is fully async (see helpers/sseClient.ts).
    vi.advanceTimersByTime(0)
    // Simulate a normal open: server sent the `connected` event.
    instances[0]!.simulateOpen()
    expect(client.getState()).toBe('open')

    // User hits refresh — the browser fires `pagehide` on window.
    unloadTarget.fire('pagehide')

    // The client must be in 'closed' state, the EventSource must
    // be closed, and all DOM listeners (pagehide, beforeunload,
    // visibility, online) must be removed.
    expect(client.getState()).toBe('closed')
    expect(instances[0]!._closed).toBe(true)
    expect(unloadTarget._listeners.get('pagehide')?.size ?? 0).toBe(0)
    expect(unloadTarget._listeners.get('beforeunload')?.size ?? 0).toBe(0)
    expect(visTarget._listeners.get('visibilitychange')?.size ?? 0).toBe(0)
    expect(onlineTarget._listeners.get('online')?.size ?? 0).toBe(0)
    // The state emission sequence includes 'closed' as the final
    // entry, same shape as the manual close() path.
    expect(states).toEqual(['connecting', 'open', 'closed'])
  })

  // 10b. beforeunload does the same thing (legacy fallback for
  // browsers without pagehide support).
  it('closes the connection on beforeunload (legacy fallback)', () => {
    const { ctor, instances } = createMockCtor()
    const { target: visTarget } = createMockTarget(false)
    const { target: onlineTarget } = createMockOnlineTarget()
    const { target: unloadTarget } = createMockUnloadTarget()

    const client = createSseClient({
      url: '/test',
      EventSourceCtor: ctor,
      visibilityTarget: visTarget,
      onlineTarget: onlineTarget,
      unloadTarget: unloadTarget,
      pauseWhenHidden: false,
      onEvent: () => {},
    })

    // Flush the deferred start() — createSseClient schedules start() on the next
    // macrotask so the SSE setup is fully async (see helpers/sseClient.ts).
    vi.advanceTimersByTime(0)
    instances[0]!.simulateOpen()
    expect(client.getState()).toBe('open')

    unloadTarget.fire('beforeunload')
    expect(client.getState()).toBe('closed')
    expect(instances[0]!._closed).toBe(true)
  })

  // 10c. Stale pagehide handler after explicit close() is a no-op
  // (teardown is idempotent via the `closed` guard).
  it('a stale pagehide handler after close() is a no-op', () => {
    const { ctor, instances } = createMockCtor()
    const { target: visTarget } = createMockTarget(false)
    const { target: onlineTarget } = createMockOnlineTarget()
    const { target: unloadTarget } = createMockUnloadTarget()

    const client = createSseClient({
      url: '/test',
      EventSourceCtor: ctor,
      visibilityTarget: visTarget,
      onlineTarget: onlineTarget,
      unloadTarget: unloadTarget,
      pauseWhenHidden: false,
      onEvent: () => {},
    })

    // Flush the deferred start() — createSseClient schedules start() on the next
    // macrotask so the SSE setup is fully async (see helpers/sseClient.ts).
    vi.advanceTimersByTime(0)
    client.close()
    expect(client.getState()).toBe('closed')

    // Stale pagehide (e.g. browser fires it after Vue's onUnmounted called .close() and the page
    // finally unloads). Must not throw, must not create a new instance, must not change state.
    unloadTarget.fire('pagehide')
    expect(client.getState()).toBe('closed')
    expect(instances.length).toBe(1)
  })

  // 10d. closeOnUnload: false skips the unload listeners. Useful
  // for SSR / tests / contexts without a real `window`.
  it('does not attach unload listeners when closeOnUnload is false', () => {
    const { ctor } = createMockCtor()
    const { target: visTarget } = createMockTarget(false)
    const { target: onlineTarget } = createMockOnlineTarget()
    const { target: unloadTarget } = createMockUnloadTarget()

    const client = createSseClient({
      url: '/test',
      EventSourceCtor: ctor,
      visibilityTarget: visTarget,
      onlineTarget: onlineTarget,
      unloadTarget: unloadTarget,
      pauseWhenHidden: false,
      closeOnUnload: false,
      onEvent: () => {},
    })

    // Flush the deferred start() — createSseClient schedules start() on the next
    // macrotask so the SSE setup is fully async (see helpers/sseClient.ts).
    vi.advanceTimersByTime(0)
    expect(unloadTarget._listeners.get('pagehide')?.size ?? 0).toBe(0)
    expect(unloadTarget._listeners.get('beforeunload')?.size ?? 0).toBe(0)

    client.close()
  })

  // getState is synchronous
  it('getState() returns the current state synchronously', () => {
    const { ctor, instances } = createMockCtor()
    const { target: visTarget } = createMockTarget(false)
    const { target: onlineTarget } = createMockOnlineTarget()

    const client = createSseClient({
      url: '/test',
      EventSourceCtor: ctor,
      visibilityTarget: visTarget,
      onlineTarget: onlineTarget,
      pauseWhenHidden: false,
      onEvent: () => {},
    })

    // Flush the deferred start() — createSseClient schedules start() on the next
    // macrotask so the SSE setup is fully async (see helpers/sseClient.ts).
    vi.advanceTimersByTime(0)
    expect(client.getState()).toBe('connecting')
    instances[0]!.simulateOpen()
    expect(client.getState()).toBe('open')
    instances[0]!.emit('error')
    expect(client.getState()).toBe('reconnecting')

    client.close()
  })

  // reconnect() resets the attempt counter
  it('reconnect() resets the attempt counter and opens a new connection', () => {
    const { ctor, instances } = createMockCtor()
    const { target: visTarget } = createMockTarget(false)
    const { target: onlineTarget } = createMockOnlineTarget()

    const states: SseState[] = []
    const client = createSseClient({
      url: '/test',
      EventSourceCtor: ctor,
      visibilityTarget: visTarget,
      onlineTarget: onlineTarget,
      pauseWhenHidden: false,
      onStateChange: (s) => states.push(s),
      onEvent: () => {},
      stallThresholdMs: 120_000,
      connectedTimeoutMs: 120_000,
    })

    // Flush the deferred start() — createSseClient schedules start() on the next
    // macrotask so the SSE setup is fully async (see helpers/sseClient.ts).
    vi.advanceTimersByTime(0)
    // Burn through 2 retries so attempt=3.
    instances[0]!.simulateOpen()
    instances[0]!.emit('error')
    vi.advanceTimersByTime(2_000)
    instances[1]!.simulateOpen()
    instances[1]!.emit('error')
    vi.advanceTimersByTime(2_000)
    expect(instances.length).toBe(3)

    // Manual reconnect — should close the current instance and
    // create a fresh one. Attempt counter resets to 0, then
    // start() bumps to 1.
    client.reconnect()
    expect(instances.length).toBe(4)
    // The previous instance was closed.
    expect(instances[2]!._closed).toBe(true)
    // State is now 'connecting' for the fresh attempt.
    expect(client.getState()).toBe('connecting')

    client.close()
  })

  // Subscriber errors do not break the connection
  it('a throwing onStateChange subscriber does not break the connection', () => {
    const { ctor, instances } = createMockCtor()
    const { target: visTarget } = createMockTarget(false)
    const { target: onlineTarget } = createMockOnlineTarget()

    const errorSpy = vi.spyOn(console, 'error').mockImplementation(() => {})

    const client = createSseClient({
      url: '/test',
      EventSourceCtor: ctor,
      visibilityTarget: visTarget,
      onlineTarget: onlineTarget,
      pauseWhenHidden: false,
      onEvent: () => {},
      onStateChange: () => {
        throw new Error('subscriber bug')
      },
    })

    // Flush the deferred start() — createSseClient schedules start() on the next
    // macrotask so the SSE setup is fully async (see helpers/sseClient.ts).
    vi.advanceTimersByTime(0)
    // Despite the throw, the connection should reach 'open'.
    instances[0]!.simulateOpen()
    expect(client.getState()).toBe('open')
    expect(errorSpy).toHaveBeenCalled()

    errorSpy.mockRestore()
    client.close()
  })

  // onStateChange returns an unsubscribe function
  it('onStateChange returns an unsubscribe function', () => {
    const { ctor, instances } = createMockCtor()
    const { target: visTarget } = createMockTarget(false)
    const { target: onlineTarget } = createMockOnlineTarget()

    const client = createSseClient({
      url: '/test',
      EventSourceCtor: ctor,
      visibilityTarget: visTarget,
      onlineTarget: onlineTarget,
      pauseWhenHidden: false,
      onEvent: () => {},
    })

    // Flush the deferred start() — createSseClient schedules start() on the next
    // macrotask so the SSE setup is fully async (see helpers/sseClient.ts).
    vi.advanceTimersByTime(0)
    const cb = vi.fn()
    const unsub = client.onStateChange(cb)
    instances[0]!.simulateOpen()
    expect(cb).toHaveBeenCalledWith('open', expect.any(Object))

    cb.mockClear()
    unsub()
    client.reconnect()
    // After unsub, the new attempt's 'connecting' should not be
    // observed.
    expect(cb).not.toHaveBeenCalled()

    client.close()
  })

  // message handler is robust to non-string data
  it('handles message events whose `data` is not a string', () => {
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

    // Flush the deferred start() — createSseClient schedules start() on the next
    // macrotask so the SSE setup is fully async (see helpers/sseClient.ts).
    vi.advanceTimersByTime(0)
    instances[0]!.emit('connected', 'ok')
    onEvent.mockClear()
    // Manually fire a message event with non-string data via the
    // mock's addEventListener path. We use a custom shape.
    const set = instances[0]!._listeners.get('message')!
    for (const listener of set) {
      const ev = { data: 42 } as unknown as MessageEvent
      if (typeof listener === 'function') listener(ev)
      else listener.handleEvent(ev)
    }
    expect(onEvent).toHaveBeenCalledWith('42', 'message')

    client.close()
  })

  // Throw-isolation: a throwing onConnected must not break the handshake —
  // onEvent still fires for `connected` and later data events dispatch.
  it('a throwing onConnected still passes connected to onEvent and keeps the stream open', () => {
    const { ctor, instances } = createMockCtor()
    const { target: visTarget } = createMockTarget(false)
    const { target: onlineTarget } = createMockOnlineTarget()

    const errorSpy = vi.spyOn(console, 'error').mockImplementation(() => {})
    const onEvent = vi.fn()
    const client = createSseClient({
      url: '/test',
      EventSourceCtor: ctor,
      visibilityTarget: visTarget,
      onlineTarget: onlineTarget,
      pauseWhenHidden: false,
      additionalEventTypes: ['llm_chunk'],
      onConnected: () => {
        throw new Error('onConnected bug')
      },
      onEvent,
    })

    vi.advanceTimersByTime(0)
    // Must not throw out of the listener — handshake completes.
    expect(() => instances[0]!.emit('connected', '{"connected":true}')).not.toThrow()
    expect(client.getState()).toBe('open')
    expect(onEvent).toHaveBeenCalledWith('{"connected":true}', 'connected')
    expect(errorSpy).toHaveBeenCalledWith(
      '[SseClient] onConnected subscriber threw:',
      expect.any(Error),
    )

    // Stream stays alive: a later named event still dispatches.
    onEvent.mockClear()
    instances[0]!.emit('llm_chunk', '{"type":"chunk"}')
    expect(onEvent).toHaveBeenCalledWith('{"type":"chunk"}', 'llm_chunk')

    errorSpy.mockRestore()
    client.close()
  })

  // Throw-isolation: a throwing onEvent on one event must not silence the next.
  it('a throwing onEvent on message does not silence the next event', () => {
    const { ctor, instances } = createMockCtor()
    const { target: visTarget } = createMockTarget(false)
    const { target: onlineTarget } = createMockOnlineTarget()

    const errorSpy = vi.spyOn(console, 'error').mockImplementation(() => {})
    let calls = 0
    const throwOnCall = 2 // simulateOpen (connected) = call 1 (ok), message = call 2 (throws)
    const client = createSseClient({
      url: '/test',
      EventSourceCtor: ctor,
      visibilityTarget: visTarget,
      onlineTarget: onlineTarget,
      pauseWhenHidden: false,
      additionalEventTypes: ['llm_chunk'],
      onEvent: () => {
        calls += 1
        if (calls === throwOnCall) throw new Error('consumer bug')
      },
    })

    vi.advanceTimersByTime(0)
    instances[0]!.simulateOpen()
    expect(calls).toBe(1)
    expect(() => instances[0]!.emit('message', '{"a":1}')).not.toThrow()
    expect(calls).toBe(2)
    // Second event still dispatches despite the first throw.
    expect(() => instances[0]!.emit('llm_chunk', '{"type":"chunk"}')).not.toThrow()
    expect(calls).toBe(3)
    expect(client.getState()).toBe('open')

    errorSpy.mockRestore()
    client.close()
  })
})
