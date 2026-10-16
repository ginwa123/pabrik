import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest'
import { createApp } from 'vue'

import { installSseBus, __resetSseBus, __setSseBusGlobalClient } from '../helpers/sseBus'
import type { SseClient, SseState, SseStateInfo } from '../helpers/sseClient'

/** Regression cover for the bug behind
 * `chat_row_context_menu_ui_test.py::test_stop_agent_cancels_the_running_worker`: `App.vue` used to
 * subscribe via `__getSseBusGlobalClient()?.onStateChange(...)`. */
describe('sseBus onStateChange — subscribers survive a late-created client', () => {
  beforeEach(() => {
    vi.resetModules()
  })

  afterEach(() => {
    __resetSseBus()
    vi.restoreAllMocks()
  })

  function makeStubClient(initial: SseState = 'connecting'): SseClient {
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

  function listenersOf(client: SseClient): Array<(s: SseState, i: SseStateInfo) => void> {
    return (client as unknown as { __stateListeners: typeof listeners }).__stateListeners
  }

  const listeners: Array<(s: SseState, i: SseStateInfo) => void> = []

  function fire(client: SseClient, s: SseState): void {
    const info: SseStateInfo = { attempt: 1, reason: 'manual' }
    for (const cb of listenersOf(client)) cb(s, info)
  }

  it('delivers to a subscriber registered before the client exists', () => {
    const bus = installSseBus(createApp({}), { tabSharing: 'off' })

    // Subscribe FIRST — this is the App.vue onMounted ordering, and the
    // exact moment the old client-reaching form silently dropped the
    // callback because `_globalClient` was still null.
    const seen: SseState[] = []
    const off = bus.onStateChange?.((s) => seen.push(s))
    expect(typeof off).toBe('function')

    // The client arrives afterwards (leader election, reconnect).
    const client = makeStubClient()
    __setSseBusGlobalClient(client)
    expect(listenersOf(client).length).toBeGreaterThan(0)

    fire(client, 'open')
    expect(seen).toEqual(['open'])
    expect(bus.state.value).toBe('open')

    off?.()
    fire(client, 'reconnecting')
    // toEqual takes one argument; the message belongs in its own assert.
    expect(seen).toEqual(['open'])
  })

  it('keeps delivering across a client swap (leader handover)', () => {
    const bus = installSseBus(createApp({}), { tabSharing: 'off' })
    const seen: SseState[] = []
    bus.onStateChange?.((s) => seen.push(s))

    const first = makeStubClient()
    __setSseBusGlobalClient(first)
    fire(first, 'open')
    expect(seen).toEqual(['open'])

    // A brand-new client taking over must also reach the subscriber.
    const second = makeStubClient()
    __setSseBusGlobalClient(second)
    fire(second, 'open')
    expect(seen).toEqual(['open', 'open'])
  })

  it('a throwing subscriber cannot break the others', () => {
    const bus = installSseBus(createApp({}), { tabSharing: 'off' })
    const good: SseState[] = []
    bus.onStateChange?.(() => {
      throw new Error('boom')
    })
    bus.onStateChange?.((s) => good.push(s))

    const client = makeStubClient()
    __setSseBusGlobalClient(client)

    const errorSpy = vi.spyOn(console, 'error').mockImplementation(() => {})
    fire(client, 'open')

    expect(good).toEqual(['open'])
    expect(errorSpy).toHaveBeenCalled()
  })
})
