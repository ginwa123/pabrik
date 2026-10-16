/** Unit tests for the bus-backed designSse Pinia store (Chunk 6 of
 * docs/superpowers/plans/2026-07-08-design-mode-redesign.md). Mirrors kanbanSse.spec.ts
 * byte-for-byte in structure. */
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest'
import { setActivePinia, createPinia } from 'pinia'
import { createApp, type App as VueApp } from 'vue'

import {
  installSseBus,
  __resetSseBus,
  __dispatchSseBus,
  __setSseBusGlobalClient,
} from '../helpers/sseBus'
import type { SseClient, SseState, SseStateInfo } from '../helpers/sseClient'
import type { DesignElementEvent } from '../api'
import { useDesignSseStore } from '../stores/designSse'
import { useWorkspacesStore } from '../stores/workspaces'
import { makeLocalStorageStub } from './helpers'

/**  * Test-only stub SseClient. Tracks state-listener callbacks so tests can drive the bus's `state`
 * ShallowRef transitions to exercise the `onConnected → fetchInitialDesign` watcher. Same shape as
 * the kanban test's stub — the bus's SseClient vtable is shared across all channel subscribers. */
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

describe('useDesignSseStore (bus-backed)', () => {
  let app: VueApp
  let stubClient: SseClient

  beforeEach(() => {
    setActivePinia(createPinia())
    Object.defineProperty(globalThis, 'localStorage', {
      value: makeLocalStorageStub(),
      writable: true,
      configurable: true,
    })

    // Install the bus BEFORE initDesignSse runs — designSseStore calls `useSseBus()` inside
    // initDesignSse, which throws if the bus hasn't been installed. Replace the underlying
    // SseClient with a stub so we never open a network EventSource in tests.
    __resetSseBus()
    app = createApp({})
    installSseBus(app)
    stubClient = makeStubClient('connecting')
    __setSseBusGlobalClient(stubClient)
  })

  afterEach(() => {
    // Detach the bus listener so events don't fire into a store whose Pinia is gone —
    // `__resetSseBus` closes the global client which also tears down internal state, but explicit
    // closeDesignSse covers the case where a test crashed before reaching close.
    try {
      useDesignSseStore().closeDesignSse()
    } catch {
      // store not activated in this test → no-op
    }
    __resetSseBus()
    vi.restoreAllMocks()
  })

  function dispatch(event: DesignElementEvent): void {
    __dispatchSseBus('design', event)
  }

  // ─── Contract: idempotency + state cleanup ────────────────────────────
  //
  // The Chunk 6 task spec lists exactly two test contracts:
  //   1. initDesignSse is idempotent (second call doesn't add a
  //      second listener — confirmed by counting fetches per
  //      dispatched event).
  //   2. closeDesignSse clears activeWorkspaceId (so a later
  //      initDesignSse can re-bind cleanly).
  it('initDesignSse is idempotent — second call does NOT add a second listener', async () => {
    // Spy on workspacesStore.fetchDesignElements and count how many
    // times it fires per dispatched event. If initDesignSse added a
    // second listener, the count would double.
    const ws = useWorkspacesStore()
    const fetchSpy = vi.spyOn(ws, 'fetchDesignElements').mockResolvedValue()

    const store = useDesignSseStore()
    await store.initDesignSse('ws_1')
    await store.initDesignSse('ws_1') // 2nd call — should NOT re-subscribe

    dispatch({
      action: 'updated',
      workspace_id: 'ws_1',
      item_id: 'item_1',
      page_id: 'page_1',
      element_id: 'elem_1',
    } as DesignElementEvent)

    expect(fetchSpy).toHaveBeenCalledTimes(1)
  })

  it('closeDesignSse clears activeWorkspaceId so a later re-init re-binds cleanly', async () => {
    // The spec asserts that closeDesignSse nulls out the active workspace filter — this lets
    // `initDesignSse(newId)` after close re-register with the new id (verified by dispatching an
    // event for the new id post-close+reinit and observing the fetch fire).
    const ws = useWorkspacesStore()
    const fetchSpy = vi.spyOn(ws, 'fetchDesignElements').mockResolvedValue()

    const store = useDesignSseStore()
    await store.initDesignSse('ws_1')
    expect(store.activeWorkspaceId).toBe('ws_1')

    store.closeDesignSse()
    // After close, the filter must be cleared.
    expect(store.activeWorkspaceId).toBe('')

    // Re-init with a different workspace. The listener must be
    // re-installed (since closeDesignSse detached it) and the
    // activeWorkspaceId must reflect the new id.
    await store.initDesignSse('ws_2')
    expect(store.activeWorkspaceId).toBe('ws_2')

    // ws_1 event after re-init must be dropped (filter is now ws_2).
    dispatch({
      action: 'updated',
      workspace_id: 'ws_1',
      item_id: 'item_1',
      page_id: 'page_1',
      element_id: 'elem_1',
    } as DesignElementEvent)
    expect(fetchSpy).not.toHaveBeenCalled()

    // ws_2 event after re-init must trigger the fetch.
    dispatch({
      action: 'updated',
      workspace_id: 'ws_2',
      item_id: 'item_1',
      page_id: 'page_1',
      element_id: 'elem_1',
    } as DesignElementEvent)
    expect(fetchSpy).toHaveBeenCalledWith('ws_2', 'item_1', 'page_1')
  })
})
// ─── Chunk 3 — local-mutation SSE dedupe (design-drag-debounce-batch) ───
//
// Plan: docs/superpowers/plans/2026-07-30-design-drag-debounce-batch.md
//   (Chunk 3, Task 3.4)
//
// Every locally-issued geometry PATCH registers the affected
// element_id(s) in the `recentLocalMutations` Map (workspaces.ts). The
// SSE handler reads this Map on every incoming event and SKIPS the
// `fetchDesignElements` GET fan-out when the event is for a locally- mutated element. Combined with
// the batch endpoint (1 PATCH instead of N per-element PATCHes per pointermove), this is the
// dominant backend-load reduction.
describe('designSse — local-mutation dedupe', () => {
  let localStubClient: SseClient

  beforeEach(() => {
    setActivePinia(createPinia())
    __resetSseBus()
    installSseBus(createApp({}))
    localStubClient = makeStubClient('connecting')
    __setSseBusGlobalClient(localStubClient)
    // Mock fetch — the store actions would otherwise hit the
    // network (which doesn't exist in jsdom). The mock returns a
    // shape compatible with apiFetch's expectations.
    globalThis.fetch = vi.fn().mockResolvedValue({
      ok: true,
      status: 200,
      json: () => Promise.resolve({ updated: [] }),
      text: () => Promise.resolve('{}'),
    } as Response)
  })

  afterEach(() => {
    __resetSseBus()
    vi.restoreAllMocks()
  })

  function dispatchEvent(event: DesignElementEvent): void {
    __dispatchSseBus('design', event)
  }

  it('skips fetchDesignElements when the SSE event is for a locally-mutated element (single)', async () => {
    const ws = useWorkspacesStore()
    const fetchSpy = vi.spyOn(ws, 'fetchDesignElements').mockResolvedValue()
    // Pre-register the element as recently-mutated locally (the store
    // action does this automatically — we call the test-only helper).
    const { _clearRecentLocalMutationsForTests, isRecentLocalMutation } = await import('../stores/workspaces')
    _clearRecentLocalMutationsForTests()
    // Trigger a local mutation via the store action — it should
    // register the id in the dedupe Map.
    ws.workspaces.push(makeWorkspaceWithItem('ws_1', 'item_1'))
    await ws.updateDesignElementGeometry('ws_1', 'item_1', 'page_1', 'elem_local', { x: 10 })
    expect(isRecentLocalMutation('elem_local')).toBe(true)

    const store = useDesignSseStore()
    await store.initDesignSse('ws_1')

    // Dispatch an SSE event for the same element id — must be skipped.
    dispatchEvent({
      action: 'updated',
      workspace_id: 'ws_1',
      item_id: 'item_1',
      page_id: 'page_1',
      element_id: 'elem_local',
    } as DesignElementEvent)

    expect(fetchSpy).not.toHaveBeenCalled()
  })

  it('FIRES fetchDesignElements when the SSE event is for an element NOT in the dedupe Map', async () => {
    const ws = useWorkspacesStore()
    const fetchSpy = vi.spyOn(ws, 'fetchDesignElements').mockResolvedValue()
    const { _clearRecentLocalMutationsForTests } = await import('../stores/workspaces')
    _clearRecentLocalMutationsForTests()

    const store = useDesignSseStore()
    await store.initDesignSse('ws_1')

    dispatchEvent({
      action: 'updated',
      workspace_id: 'ws_1',
      item_id: 'item_1',
      page_id: 'page_1',
      element_id: 'elem_remote',
    } as DesignElementEvent)

    expect(fetchSpy).toHaveBeenCalledTimes(1)
  })

  it('FIRES fetchDesignElements when the dedupe Map entry has expired (TTL elapsed)', async () => {
    const ws = useWorkspacesStore()
    const fetchSpy = vi.spyOn(ws, 'fetchDesignElements').mockResolvedValue()
    const { _clearRecentLocalMutationsForTests, registerRecentLocalMutations } = await import('../stores/workspaces')
    _clearRecentLocalMutationsForTests()
    // Register an id with an EXPIRED timestamp (1 ms in the past).
    registerRecentLocalMutations(['elem_stale'], Date.now() - 1)

    const store = useDesignSseStore()
    await store.initDesignSse('ws_1')

    dispatchEvent({
      action: 'updated',
      workspace_id: 'ws_1',
      item_id: 'item_1',
      page_id: 'page_1',
      element_id: 'elem_stale',
    } as DesignElementEvent)

    expect(fetchSpy).toHaveBeenCalledTimes(1)
  })

  it('skips fetchDesignElements for BATCH events when EVERY element_id is in the Map', async () => {
    const ws = useWorkspacesStore()
    const fetchSpy = vi.spyOn(ws, 'fetchDesignElements').mockResolvedValue()
    const { _clearRecentLocalMutationsForTests } = await import('../stores/workspaces')
    _clearRecentLocalMutationsForTests()
    // Register 3 ids in the dedupe Map (simulating a local batch
    // PATCH that registered all 3).
    ws.workspaces.push(makeWorkspaceWithItem('ws_1', 'item_1'))
    await ws.updateDesignElementsGeometryBatch('ws_1', 'item_1', 'page_1', [
      { element_id: 'b1' },
      { element_id: 'b2' },
      { element_id: 'b3' },
    ])

    const store = useDesignSseStore()
    await store.initDesignSse('ws_1')

    dispatchEvent({
      action: 'updated',
      workspace_id: 'ws_1',
      item_id: 'item_1',
      page_id: 'page_1',
      element_ids: ['b1', 'b2', 'b3'],
    } as DesignElementEvent)

    expect(fetchSpy).not.toHaveBeenCalled()
  })

  it('FIRES fetchDesignElements for BATCH events when ANY element_id is missing (strict-superset dedupe)', async () => {
    const ws = useWorkspacesStore()
    const fetchSpy = vi.spyOn(ws, 'fetchDesignElements').mockResolvedValue()
    const { _clearRecentLocalMutationsForTests } = await import('../stores/workspaces')
    _clearRecentLocalMutationsForTests()
    // Register only 2 of 3 ids (partial dedupe is unsafe).
    ws.workspaces.push(makeWorkspaceWithItem('ws_1', 'item_1'))
    await ws.updateDesignElementsGeometryBatch('ws_1', 'item_1', 'page_1', [
      { element_id: 'b1' },
      { element_id: 'b2' },
    ])

    const store = useDesignSseStore()
    await store.initDesignSse('ws_1')

    dispatchEvent({
      action: 'updated',
      workspace_id: 'ws_1',
      item_id: 'item_1',
      page_id: 'page_1',
      element_ids: ['b1', 'b2', 'b3'],
    } as DesignElementEvent)

    expect(fetchSpy).toHaveBeenCalledTimes(1)
  })
})

 

// eslint-disable-next-line @typescript-eslint/no-explicit-any
function makeWorkspaceWithItem(workspaceId: string, itemId: string): any {
  return {
    id: workspaceId,
    name: 'Test',
    icon: '',
    items: [
      {
        id: itemId,
        workspace_id: workspaceId,
        item_type: 'design',
        name: 'Item',
        path: '/tmp',
        position: 0,
        design_elements: [],
      },
    ],
    expanded: false,
  }
}
