/** Wire-body regression tests for the terminal API fns. apiFetch() stringifies `body` itself —
 * these fns must pass plain objects. Passing JSON.stringify(...) double-encodes the payload (the
 * server sees a JSON *string* and answers 400 "Invalid JSON body"). */
import { afterEach, describe, expect, it, vi } from 'vitest'

import {
  createTerminalSession,
  deleteTerminalSession,
  getTerminalOutput,
  resizeTerminal,
  sendTerminalInput,
} from '../index'

function jsonResponse(body: unknown, status = 200): Response {
  return new Response(JSON.stringify(body), {
    status,
    headers: { 'Content-Type': 'application/json' },
  })
}

function stubFetchOnce(body: unknown, status = 200) {
  const fetchMock = vi.fn(async () => jsonResponse(body, status))
  vi.stubGlobal('fetch', fetchMock)
  return fetchMock
}

/** Raw fetch body, parsed exactly once — double-encoding fails here. */
function sentBody(fetchMock: ReturnType<typeof vi.fn>): unknown {
  const [, init] = fetchMock.mock.calls[0] as unknown as [string, RequestInit]
  expect(typeof init.body).toBe('string')
  return JSON.parse(init.body as string)
}

afterEach(() => {
  vi.unstubAllGlobals()
})

describe('createTerminalSession', () => {
  it('sends a singly-encoded object body', async () => {
    const fetchMock = stubFetchOnce({ id: 'term-1', pid: 111 })
    const data = await createTerminalSession('ws_1', '/tmp/work', { cols: 80, rows: 24 })
    expect(data).toEqual({ id: 'term-1', pid: 111 })
    expect(fetchMock).toHaveBeenCalledTimes(1)
    const [url] = fetchMock.mock.calls[0] as unknown as [string]
    expect(url).toBe('/api/terminal/sessions')
    // Parses to an OBJECT (not a string) with the exact fields. `workspace_id` is
    // what makes a --saas server run the shell inside that workspace's VM.
    expect(sentBody(fetchMock)).toEqual({
      workspace_id: 'ws_1',
      cwd: '/tmp/work',
      cols: 80,
      rows: 24,
    })
  })
})

describe('sendTerminalInput', () => {
  it('sends { data } singly-encoded to the session input endpoint', async () => {
    const fetchMock = stubFetchOnce({ ok: true, bytes: 3 })
    const data = await sendTerminalInput('term-1', 'ls\n')
    expect(data).toEqual({ ok: true, bytes: 3 })
    const [url] = fetchMock.mock.calls[0] as unknown as [string]
    expect(url).toBe('/api/terminal/sessions/term-1/input')
    expect(sentBody(fetchMock)).toEqual({ data: 'ls\n' })
  })
})

describe('resizeTerminal', () => {
  it('sends { cols, rows } singly-encoded to the resize endpoint', async () => {
    const fetchMock = stubFetchOnce({ ok: true, cols: 100, rows: 40 })
    const data = await resizeTerminal('term-1', 100, 40)
    expect(data).toEqual({ ok: true, cols: 100, rows: 40 })
    const [url] = fetchMock.mock.calls[0] as unknown as [string]
    expect(url).toBe('/api/terminal/sessions/term-1/resize')
    expect(sentBody(fetchMock)).toEqual({ cols: 100, rows: 40 })
  })
})

describe('getTerminalOutput / deleteTerminalSession', () => {
  it('polls with the cursor query param', async () => {
    const fetchMock = stubFetchOnce({ data: 'hi', cursor: 2, exited: false, exit_code: null })
    const data = await getTerminalOutput('term-1', 0)
    expect(data.cursor).toBe(2)
    const [url] = fetchMock.mock.calls[0] as unknown as [string]
    expect(url).toBe('/api/terminal/sessions/term-1/output?cursor=0')
  })

  it('deletes via DELETE with no body', async () => {
    const fetchMock = stubFetchOnce({ ok: true })
    const data = await deleteTerminalSession('term-1')
    expect(data).toEqual({ ok: true })
    const [url, init] = fetchMock.mock.calls[0] as unknown as [string, RequestInit]
    expect(url).toBe('/api/terminal/sessions/term-1')
    expect(init.method).toBe('DELETE')
    expect(init.body).toBeUndefined()
  })
})
