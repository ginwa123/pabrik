/* eslint-disable @typescript-eslint/no-explicit-any, @typescript-eslint/no-unsafe-function-type -- test mocks legitimately use loose types */
import { describe, it, expect, beforeEach, afterEach, vi } from 'vitest'
import { createSseClient } from '../helpers/sseClient'

function createMockCtor() {
  const instances: any[] = []
  const ctor = function (this: unknown, url: string) {
    const inst: any = {
      url,
      readyState: 1,
      onerror: null,
      _listeners: new Map<string, Set<Function>>(),
      _closed: false,
      close() {
        this._closed = true
        this.readyState = 2
      },
      addEventListener(type: string, l: Function) {
        let s = this._listeners.get(type)
        if (!s) {
          s = new Set()
          this._listeners.set(type, s)
        }
        s.add(l)
      },
      removeEventListener() {},
      emit(type: string, data?: string) {
        const ev = data !== undefined ? new MessageEvent(type, { data }) : new Event(type)
        const set = this._listeners.get(type)
        if (set) for (const l of set) (l as Function)(ev)
        if (type === 'error' && this.onerror) this.onerror(ev)
      },
      simulateOpen(payload = '{"ok":true}') {
        this.emit('connected', payload)
      },
    }
    instances.push(inst)
    return inst
  } as unknown as typeof EventSource
  return { ctor, instances }
}

describe('SSE stall recovery (idle-freeze)', () => {
  beforeEach(() => {
    vi.useFakeTimers()
  })
  afterEach(() => {
    vi.useRealTimers()
  })

  it('reconnects after stall threshold with no events', () => {
    const { ctor, instances } = createMockCtor()
    const vis = { hidden: false, addEventListener() {}, removeEventListener() {} } as any
    const online = { addEventListener() {}, removeEventListener() {} } as any
    const states: string[] = []
    const client = createSseClient({
      url: '/test',
      EventSourceCtor: ctor,
      visibilityTarget: vis,
      onlineTarget: online,
      pauseWhenHidden: false,
      random: () => 0.5,
      baseDelayMs: 1000,
      maxDelayMs: 30000,
      stallThresholdMs: 7_000,
      onEvent: () => {},
      onStateChange: (s) => states.push(s),
    })
    vi.advanceTimersByTime(0)
    expect(instances.length).toBe(1)
    instances[0].simulateOpen()
    expect(client.getState()).toBe('open')
    // No further events for 7s stall threshold -> must leave open
    vi.advanceTimersByTime(7000)
    // RED: currently stays open (log-only). Fixed: reconnecting + new instance after backoff
    expect(client.getState()).toBe('reconnecting')
    vi.advanceTimersByTime(750)
    expect(instances.length).toBe(2)
    client.close()
  })

  it('default threshold tolerates the ~15s backend heartbeat without reconnecting', () => {
    const { ctor, instances } = createMockCtor()
    const vis = { hidden: false, addEventListener() {}, removeEventListener() {} } as any
    const online = { addEventListener() {}, removeEventListener() {} } as any
    const client = createSseClient({
      url: '/test',
      EventSourceCtor: ctor,
      visibilityTarget: vis,
      onlineTarget: online,
      pauseWhenHidden: false,
      random: () => 0.5,
      baseDelayMs: 1000,
      maxDelayMs: 30000,
      onEvent: () => {},
    })
    vi.advanceTimersByTime(0)
    expect(instances.length).toBe(1)
    instances[0].simulateOpen()
    expect(client.getState()).toBe('open')
    // Backend heartbeat every ~15s must NOT look like a stall.
    for (let i = 0; i < 2; i++) {
      vi.advanceTimersByTime(15_000)
      instances[0].emit('message', 'ping')
      expect(client.getState()).toBe('open')
    }
    expect(instances.length).toBe(1)
    // But 30s of true silence (past the 30s default) must recover.
    vi.advanceTimersByTime(30_000)
    expect(client.getState()).toBe('reconnecting')
    vi.advanceTimersByTime(1_000)
    expect(instances.length).toBe(2)
    client.close()
  })
})
