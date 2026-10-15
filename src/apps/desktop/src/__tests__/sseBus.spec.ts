import { describe, it, expect, beforeEach, vi } from 'vitest'
import { createApp, type App } from 'vue'
import {
  installSseBus,
  useSseBus,
  __resetSseBus,
  __dispatchSseBus,
  __setSseBusGlobalClient,
  __getSseBusGlobalClient,
} from '../helpers/sseBus'
import type { SseClient, SseState, SseStateInfo } from '../helpers/sseClient'
import * as api from '../api'

/** Test-only stub SseClient. Tracks state-listener callbacks on a
 * non-public `__stateListeners` array so `emitStubState` can fan out
 * a transition to all subscribers (the production `SseClient` keeps
 * the listener list in a closure; tests reach it via `as any`). */
function makeStubClient(initial: SseState): SseClient {
  // eslint-disable-next-line @typescript-eslint/no-explicit-any
  const stub: any = {
    close: vi.fn(),
    reconnect: vi.fn(),
    getState: () => stub._state,
    onStateChange: (cb: (s: SseState, info: SseStateInfo) => void) => {
      stub.__stateListeners.push(cb)
      return () => {
        const i = stub.__stateListeners.indexOf(cb)
        if (i >= 0) stub.__stateListeners.splice(i, 1)
      }
    },
  }
  stub._state = initial
  stub.__stateListeners = [] as Array<(s: SseState, info: SseStateInfo) => void>
  return stub as SseClient
}

function emitStubState(c: SseClient, s: SseState): void {
  // Walk the internal listener list. The stub stores it as a non-public

  // property — we use `as any` to reach it from the test.
  // eslint-disable-next-line @typescript-eslint/no-explicit-any
  const listeners = (c as any).__stateListeners as
    Array<(s: SseState, info: SseStateInfo) => void> | undefined
  if (listeners) {
    for (const cb of listeners) cb(s, {} as SseStateInfo)
  }
}

describe('sseBus', () => {
  let app: App
  beforeEach(() => {
    __resetSseBus()
    app = createApp({})
  })

  it('installSseBus is idempotent — second call returns the same instance', () => {
    const a = installSseBus(app)
    const b = installSseBus(app)
    expect(a).toBe(b)
  })

  it('useSseBus throws if not installed', () => {
    expect(() => useSseBus()).toThrow(/installSseBus/)
  })

  it('useSseBus returns the installed bus after installSseBus', () => {
    const bus = installSseBus(app)
    expect(useSseBus()).toBe(bus)
  })

  it('on(type, cb) — dispatch fires the listener', () => {
    const bus = installSseBus(app)
    const cb = vi.fn()
    bus.on('session', cb)
    __dispatchSseBus('session', {
      id: 's_1',

      action: 'updated',
      name: 'Renamed',
      // eslint-disable-next-line @typescript-eslint/no-explicit-any
    } as any)
    expect(cb).toHaveBeenCalledTimes(1)
    expect(cb).toHaveBeenCalledWith({
      id: 's_1',
      action: 'updated',
      name: 'Renamed',
    })
  })

  it('on(type, cb) — multiple subscribers all fire', () => {
    const bus = installSseBus(app)
    const a = vi.fn(),
      b = vi.fn()
    bus.on('worker', a)
    bus.on('worker', b)
    // eslint-disable-next-line @typescript-eslint/no-explicit-any
    __dispatchSseBus('worker', { id: 'w_1', action: 'created' } as any)
    expect(a).toHaveBeenCalledTimes(1)
    expect(b).toHaveBeenCalledTimes(1)
  })

  it('on(type, cb) — unsubscribe stops delivery', () => {
    const bus = installSseBus(app)
    const cb = vi.fn()
    const off = bus.on('session', cb)
    off()
    // eslint-disable-next-line @typescript-eslint/no-explicit-any
    __dispatchSseBus('session', { id: 's_1', action: 'updated' } as any)
    expect(cb).not.toHaveBeenCalled()
  })

  it('off(type, cb) — removes a specific listener', () => {
    const bus = installSseBus(app)
    const cb = vi.fn()
    bus.on('session', cb)
    bus.off('session', cb)
    // eslint-disable-next-line @typescript-eslint/no-explicit-any
    __dispatchSseBus('session', { id: 's_1', action: 'updated' } as any)
    expect(cb).not.toHaveBeenCalled()
  })

  it('__setSseBusGlobalClient replaces the global SseClient and re-wires state', () => {
    const bus = installSseBus(app)

    const stub = makeStubClient('connecting')
    __setSseBusGlobalClient(stub)
    expect(bus.state.value).toBe('connecting')

    // Subscribe directly to the stub's state fan-out (explicit push,
    // not a reactive watcher) and drive a transition.
    const stateChanges: SseState[] = []
    const unsub = stub.onStateChange((s) => stateChanges.push(s))

    // Drive a state change on the stub
    emitStubState(stub, 'open')
    expect(bus.state.value).toBe('open')

    // The stub fans out synchronously, so no tick-drain is needed.
    expect(stateChanges).toContain('open')

    unsub()
  })

  it('__setSseBusGlobalClient closes the old client when replacing', () => {
    installSseBus(app)
    const old = __getSseBusGlobalClient()
    expect(old).not.toBeNull()
    const closeSpy = vi.spyOn(old!, 'close')
    const stub = makeStubClient('closed')
    __setSseBusGlobalClient(stub)
    expect(closeSpy).toHaveBeenCalled()
  })

  it('bus.close() closes the SWAPPED-IN global client, not the original', () => {
    installSseBus(app)
    const original = __getSseBusGlobalClient()!
    const originalCloseSpy = vi.spyOn(original, 'close')

    const stub = makeStubClient('connecting')
    const stubCloseSpy = vi.spyOn(stub, 'close')
    __setSseBusGlobalClient(stub)

    // The swap itself already called `original.close()` exactly once
    // (the `_globalClient && _globalClient !== client` branch in
    // __setSseBusGlobalClient). The test asserts bus.close() does NOT
    // call it again — which would happen if bus.close() reads the
    // closure-scoped `globalClient` (the pre-fix bug).
    expect(originalCloseSpy).toHaveBeenCalledTimes(1)

    const bus = useSseBus()
    bus.close()

    // After bus.close(): still exactly 1 close on the original
    // (only the swap called it). If the fix regresses, this jumps
    // to 2 because bus.close() would call original.close() again.
    expect(originalCloseSpy).toHaveBeenCalledTimes(1)
    // bus.close() must close the SWAPPED-IN stub.
    expect(stubCloseSpy).toHaveBeenCalledTimes(1)
  })

  it('installSseBus opens a single global SseClient with all 5 channels including bare llm+queue', () => {
    // Spy on createUnifiedSseConnection (used by the bus) by spying on the api module.
    const spy = vi.spyOn(api, 'createUnifiedSseConnection')
    spy.mockReturnValueOnce(makeStubClient('connecting'))

    installSseBus(createApp({}))

    expect(spy).toHaveBeenCalledTimes(1)
    const callArg = spy.mock.calls[0]![0]
    // The bus must wire up workers, sessions, kanban, llm, queue.

    expect(callArg.channels.workers).toBeDefined()

    expect(callArg.channels.sessions).toBeDefined()
    expect(callArg.channels.kanban).toBeDefined()
    expect(callArg.channels.llm).toBeDefined()
    expect(callArg.channels.queue).toBeDefined()
    // llm and queue must use bare tokens (no sessionId).
    // eslint-disable-next-line @typescript-eslint/no-explicit-any
    expect((callArg.channels.llm as any).sessionId).toBeUndefined()
    // eslint-disable-next-line @typescript-eslint/no-explicit-any
    expect((callArg.channels.queue as any).sessionId).toBeUndefined()
    spy.mockRestore()
  })
})
