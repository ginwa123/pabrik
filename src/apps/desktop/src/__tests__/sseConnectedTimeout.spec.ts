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
      simulateOpen(payload = '{"connected":true}') {
        this.emit('connected', payload)
      },
    }
    instances.push(inst)
    return inst
  } as unknown as typeof EventSource
  return { ctor, instances }
}

function baseOpts(ctor: typeof EventSource, onStateChange?: (s: string) => void) {
  return {
    url: '/test',
    EventSourceCtor: ctor,
    visibilityTarget: { hidden: false, addEventListener() {}, removeEventListener() {} } as any,
    onlineTarget: { addEventListener() {}, removeEventListener() {} } as any,
    pauseWhenHidden: false,
    random: () => 0.5,
    baseDelayMs: 1000,
    maxDelayMs: 30000,
    connectedTimeoutMs: 1000,
    onEvent: () => {},
    ...(onStateChange ? { onStateChange: onStateChange as any } : {}),
  }
}

describe('SSE connected timeout (handshake deadline)', () => {
  beforeEach(() => {
    vi.useFakeTimers()
  })
  afterEach(() => {
    vi.useRealTimers()
  })

  it('first attempt with no handshake lands in failed, never infinite connecting', () => {
    const { ctor, instances } = createMockCtor()
    const states: string[] = []
    const client = createSseClient(baseOpts(ctor, (s) => states.push(s)))
    vi.advanceTimersByTime(0)
    expect(instances.length).toBe(1)
    expect(client.getState()).toBe('connecting')
    // Heartbeats/pings must NOT satisfy the deadline — only `connected` does.
    vi.advanceTimersByTime(1000)
    expect(client.getState()).toBe('failed')
    expect(states).toContain('failed')
    client.close()
  })

  it('handshake before the deadline keeps the stream open past it', () => {
    const { ctor, instances } = createMockCtor()
    const client = createSseClient(baseOpts(ctor))
    vi.advanceTimersByTime(0)
    instances[0].simulateOpen()
    expect(client.getState()).toBe('open')
    vi.advanceTimersByTime(5000)
    expect(client.getState()).toBe('open')
    expect(instances.length).toBe(1)
    client.close()
  })
})
