/**
 * The `git_file_stage` channel at the API layer.
 *
 * `SidebarDiffPanel.stage.spec.ts` drives the panel and dispatches synthetic
 * events through `__dispatchSseBus` — which deliberately bypasses
 * `api/index.ts`. That leaves the OTHER half of the four-place registration
 * untested: a named SSE event that is not in `additionalEventTypes` is dropped
 * by the browser's `EventSource` before `onEvent` ever fires (the PR #215 /
 * `session_unknown` class), and a name with no `onEvent` dispatch branch
 * falls through to the default-message JSON buffer.
 *
 * This spec captures the real `onEvent` callback `createUnifiedSseConnection`
 * hands to the SseClient and calls it exactly as the browser would. That is
 * the only honest witness for "the event reaches the channel callback".
 *
 * The spy-on-`createSseClient` harness is the one `unifiedSseBuffer.spec.ts`
 * established — no mock EventSource, no fake timers.
 */

import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest'

import { createUnifiedSseConnection } from '../api'
import * as sseClient from '../helpers/sseClient'

describe('createUnifiedSseConnection: git_file_stage channel', () => {
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

  it('adds the git_file_stage channel token to the EventSource URL', () => {
    createUnifiedSseConnection({ channels: { gitFileStage: vi.fn() } })

    expect(capturedOpts?.url).toContain('channels=git_file_stage')
  })

  it('pre-registers both granular wire names so the browser dispatches them', () => {
    createUnifiedSseConnection({ channels: { gitFileStage: vi.fn() } })

    // A name missing here is dropped by EventSource before onEvent — the
    // failure mode that looks exactly like a dead stream.
    expect(capturedOpts?.additionalEventTypes).toContain('git_file_staged')
    expect(capturedOpts?.additionalEventTypes).toContain('git_file_unstaged')
  })

  it('routes git_file_staged to the channel callback with the parsed payload', () => {
    const cb = vi.fn()
    createUnifiedSseConnection({ channels: { gitFileStage: cb } })

    const payload = { action: 'staged', path: 'src/a.ts', cwd: '/repo', failed: false }
    capturedOnEvent!(JSON.stringify(payload), 'git_file_staged')

    expect(cb).toHaveBeenCalledTimes(1)
    expect(cb).toHaveBeenCalledWith(payload)
  })

  it('routes git_file_unstaged to the same channel callback', () => {
    const cb = vi.fn()
    createUnifiedSseConnection({ channels: { gitFileStage: cb } })

    const payload = { action: 'unstaged', path: 'src/b.ts', cwd: '/repo', failed: false }
    capturedOnEvent!(JSON.stringify(payload), 'git_file_unstaged')

    expect(cb).toHaveBeenCalledTimes(1)
    expect(cb).toHaveBeenCalledWith(payload)
  })

  it('ignores the event when the channel is not subscribed', () => {
    // No `gitFileStage` channel → the branch must return early rather than
    // fall through to the default-message buffer (which would corrupt the
    // next unnamed event's parse).
    const workersCb = vi.fn()
    createUnifiedSseConnection({ channels: { workers: workersCb } })

    expect(() =>
      capturedOnEvent!(JSON.stringify({ action: 'staged', path: 'a', cwd: '/r', failed: false }), 'git_file_staged'),
    ).not.toThrow()
    expect(workersCb).not.toHaveBeenCalled()
  })

  it('an unparseable body is logged, not thrown', () => {
    const errSpy = vi.spyOn(console, 'error').mockImplementation(() => {})
    const cb = vi.fn()
    createUnifiedSseConnection({ channels: { gitFileStage: cb } })

    expect(() => capturedOnEvent!('not json', 'git_file_staged')).not.toThrow()
    expect(cb).not.toHaveBeenCalled()
    expect(errSpy).toHaveBeenCalled()
    errSpy.mockRestore()
  })
})
