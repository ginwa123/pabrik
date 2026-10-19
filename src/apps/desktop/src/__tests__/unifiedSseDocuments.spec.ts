/** The `documents` channel at the API layer: the wire token, the three pre-registered granular
 * event names, and the dispatch into the channel callback. */
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest'

import { createUnifiedSseConnection } from '../api'
import * as sseClient from '../helpers/sseClient'

describe('createUnifiedSseConnection: documents channel', () => {
  const spy = vi.spyOn(sseClient, 'createSseClient')
  let capturedOnEvent: ((raw: string, eventType: string) => void) | null = null
  let capturedOpts: sseClient.SseClientOptions | null = null

  beforeEach(() => {
    capturedOnEvent = null
    capturedOpts = null
    spy.mockImplementation(((opts: sseClient.SseClientOptions) => {
      capturedOnEvent = opts.onEvent
      capturedOpts = opts
      return {
        close: vi.fn(),
        reconnect: vi.fn(),
        getState: () => 'open' as const,
        onStateChange: () => () => {},
      }
    }) as unknown as typeof sseClient.createSseClient)
  })

  afterEach(() => {
    spy.mockClear()
  })

  it('adds the documents channel token to the EventSource URL', () => {
    createUnifiedSseConnection({ channels: { documents: vi.fn() } })

    expect(capturedOpts?.url).toContain('channels=documents')
  })

  it('pre-registers all three granular wire names so the browser dispatches them', () => {
    createUnifiedSseConnection({ channels: { documents: vi.fn() } })

    // A name missing here is dropped by EventSource before onEvent — the
    // failure mode that looks exactly like a dead stream.
    expect(capturedOpts?.additionalEventTypes).toContain('document_created')
    expect(capturedOpts?.additionalEventTypes).toContain('document_updated')
    expect(capturedOpts?.additionalEventTypes).toContain('document_deleted')
  })

  it('routes document_created to the channel callback with the parsed payload', () => {
    const cb = vi.fn()
    createUnifiedSseConnection({ channels: { documents: cb } })

    const payload = {
      action: 'created',
      workspace_id: 'ws_1',
      document_id: 'doc_1',
      title: 'Notes',
    }
    capturedOnEvent!(JSON.stringify(payload), 'document_created')

    expect(cb).toHaveBeenCalledTimes(1)
    expect(cb).toHaveBeenCalledWith(payload)
  })

  it('routes document_updated and document_deleted to the same callback', () => {
    const cb = vi.fn()
    createUnifiedSseConnection({ channels: { documents: cb } })

    const updated = {
      action: 'updated',
      workspace_id: 'ws_1',
      document_id: 'doc_1',
      title: 'Renamed',
    }
    const deleted = {
      action: 'deleted',
      workspace_id: 'ws_1',
      document_id: 'doc_1',
      title: 'Gone',
    }
    capturedOnEvent!(JSON.stringify(updated), 'document_updated')
    capturedOnEvent!(JSON.stringify(deleted), 'document_deleted')

    expect(cb).toHaveBeenNthCalledWith(1, updated)
    expect(cb).toHaveBeenNthCalledWith(2, deleted)
  })

  it('ignores the event when the channel is not subscribed', () => {
    const workersCb = vi.fn()
    createUnifiedSseConnection({ channels: { workers: workersCb } })

    expect(() =>
      capturedOnEvent!(
        JSON.stringify({ action: 'created', workspace_id: 'ws_1', document_id: 'd', title: 't' }),
        'document_created',
      ),
    ).not.toThrow()
    expect(workersCb).not.toHaveBeenCalled()
  })

  it('an unparseable body is logged, not thrown', () => {
    const errSpy = vi.spyOn(console, 'error').mockImplementation(() => {})
    const cb = vi.fn()
    createUnifiedSseConnection({ channels: { documents: cb } })

    expect(() => capturedOnEvent!('not json', 'document_created')).not.toThrow()
    expect(cb).not.toHaveBeenCalled()
    expect(errSpy).toHaveBeenCalled()
    errSpy.mockRestore()
  })
})
