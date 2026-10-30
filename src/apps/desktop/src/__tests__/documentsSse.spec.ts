/** Unit tests for the bus-backed documentsSse Pinia store. The backend emits `documents` events
 * from the AGENT TOOLS only (src/agentic_loop/document_events.zig), so the sidebar's Documents list
 * refreshes when an agent writes or removes one. */
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
import type { Document as ApiDocument, DocumentEvent } from '../api'
import { useDocumentsSseStore } from '../stores/documentsSse'
import { useDocumentsStore } from '../stores/documents'
import { makeLocalStorageStub } from './helpers'

const listDocuments = vi.hoisted(() => vi.fn())

// ONLY `listDocuments` is replaced — everything else in `../api` stays real because
// `installSseBus` builds its client through `createUnifiedSseConnection`.
vi.mock('../api', async () => {
  const actual = await vi.importActual<typeof import('../api')>('../api')
  return { ...actual, listDocuments }
})

const doc = (over: Partial<ApiDocument> = {}): ApiDocument => ({
  id: 'doc_1',
  workspace_id: 'ws_1',
  title: 'Notes',
  content: '# heading',
  format: 'markdown',
  created_at: '2026-09-01 10:00:00',
  updated_at: '2026-09-01 10:00:00',
  position: 0,
  ...over,
})

/** Test-only stub SseClient: never opens a network EventSource. */
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

describe('useDocumentsSseStore (bus-backed)', () => {
  let app: VueApp
  let stubClient: SseClient

  beforeEach(() => {
    setActivePinia(createPinia())
    listDocuments.mockReset()
    Object.defineProperty(globalThis, 'localStorage', {
      value: makeLocalStorageStub(),
      writable: true,
      configurable: true,
    })

    // Install the bus BEFORE initDocumentsSse runs — the store calls `useSseBus()` inside it,
    // which throws if the bus is not installed.
    __resetSseBus()
    app = createApp({})
    installSseBus(app)
    stubClient = makeStubClient('connecting')
    __setSseBusGlobalClient(stubClient)
  })

  afterEach(() => {
    useDocumentsSseStore().closeDocumentsSse()
    __resetSseBus()
    vi.restoreAllMocks()
  })

  function dispatch(event: DocumentEvent): void {
    __dispatchSseBus('documents', event)
  }

  function spyOnFetch() {
    return vi.spyOn(useDocumentsStore(), 'fetchDocuments').mockResolvedValue()
  }

  it('re-reads the list when an agent creates a document in the active workspace', async () => {
    const fetchSpy = spyOnFetch()
    await useDocumentsSseStore().initDocumentsSse('ws_1')

    dispatch({ action: 'created', workspace_id: 'ws_1', document_id: 'doc_1', title: 'Notes' })

    expect(fetchSpy).toHaveBeenCalledWith('ws_1')
  })

  it('an agent create lands in the store, not just as a fetch call', async () => {
    // The test above proves the wiring; this proves the OUTCOME an agent write has for the
    // sidebar. The list is cache-first over a module singleton, so clear it first or a previous
    // test's rows paint through and the assertion becomes order-dependent.
    const { documentEngineDb } = await import('../sync/DocumentEngineDb')
    const { runSyncVoid } = await import('../sync/runtime')
    await runSyncVoid(documentEngineDb.clear('ws_1'), 'spec.clearDocuments')

    listDocuments.mockResolvedValue({
      documents: [doc({ id: 'doc_agent', title: 'Written by the agent' })],
      count: 1,
    })

    await useDocumentsSseStore().initDocumentsSse('ws_1')
    // Positive control: init alone must NOT read the list (the bus is still 'connecting'), so the
    // population below can only have come from the dispatched event.
    expect(listDocuments).not.toHaveBeenCalled()

    dispatch({
      action: 'created',
      workspace_id: 'ws_1',
      document_id: 'doc_agent',
      title: 'Written by the agent',
    })

    await vi.waitFor(() => {
      expect(useDocumentsStore().documents.map((d) => d.id)).toEqual(['doc_agent'])
    })
  })

  it('re-reads the list for an updated document as well', async () => {
    const fetchSpy = spyOnFetch()
    await useDocumentsSseStore().initDocumentsSse('ws_1')

    dispatch({ action: 'updated', workspace_id: 'ws_1', document_id: 'doc_1', title: 'Renamed' })

    expect(fetchSpy).toHaveBeenCalledWith('ws_1')
  })

  it('re-reads the list for a deleted document, so the row disappears', async () => {
    const fetchSpy = spyOnFetch()
    await useDocumentsSseStore().initDocumentsSse('ws_1')

    dispatch({ action: 'deleted', workspace_id: 'ws_1', document_id: 'doc_1', title: 'Gone' })

    expect(fetchSpy).toHaveBeenCalledWith('ws_1')
  })

  it('ignores documents events for another workspace', async () => {
    const fetchSpy = spyOnFetch()
    await useDocumentsSseStore().initDocumentsSse('ws_1')

    dispatch({ action: 'created', workspace_id: 'ws_OTHER', document_id: 'doc_1', title: 'X' })

    expect(fetchSpy).not.toHaveBeenCalled()
  })

  it('registers exactly one listener — a second init does not double the refresh', async () => {
    const fetchSpy = spyOnFetch()
    const store = useDocumentsSseStore()
    await store.initDocumentsSse('ws_1')
    await store.initDocumentsSse('ws_1')

    dispatch({ action: 'created', workspace_id: 'ws_1', document_id: 'doc_1', title: 'Notes' })

    expect(fetchSpy).toHaveBeenCalledTimes(1)
  })

  it('closing detaches the listener — later events are dropped', async () => {
    const fetchSpy = spyOnFetch()
    const store = useDocumentsSseStore()
    await store.initDocumentsSse('ws_1')

    dispatch({ action: 'created', workspace_id: 'ws_1', document_id: 'doc_1', title: 'Notes' })
    expect(fetchSpy).toHaveBeenCalledTimes(1)

    store.closeDocumentsSse()

    dispatch({ action: 'created', workspace_id: 'ws_1', document_id: 'doc_2', title: 'Later' })
    expect(fetchSpy).toHaveBeenCalledTimes(1)
  })

  it('closing is a no-op when no subscription is active', () => {
    expect(() => useDocumentsSseStore().closeDocumentsSse()).not.toThrow()
  })

  it('setActiveWorkspaceId moves the filter without re-subscribing', async () => {
    const fetchSpy = spyOnFetch()
    const store = useDocumentsSseStore()
    await store.initDocumentsSse('ws_1')
    await store.setActiveWorkspaceId('ws_2')

    dispatch({ action: 'created', workspace_id: 'ws_1', document_id: 'doc_1', title: 'Old' })
    expect(fetchSpy).not.toHaveBeenCalled()

    dispatch({ action: 'created', workspace_id: 'ws_2', document_id: 'doc_2', title: 'New' })
    expect(fetchSpy).toHaveBeenCalledWith('ws_2')
  })
})
