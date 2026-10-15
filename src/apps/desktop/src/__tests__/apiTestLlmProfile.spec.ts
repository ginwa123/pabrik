/** Unit tests for the `api.testLlmProfile` function. Mocks `global.fetch`
 * to assert URL, method, body, and response parsing without hitting the
 * network. Mirrors `apiDeleteProfile.spec.ts`. */
import { afterEach, assert, describe, expect, it, vi } from 'vitest'

import { testLlmProfile } from '../api'

describe('api.testLlmProfile', () => {
  const originalFetch = global.fetch
  const fetchMock = vi.fn()

  afterEach(() => {
    fetchMock.mockReset()
    global.fetch = originalFetch
  })

  function mockFetchOnce(status: number, body: unknown) {
    fetchMock.mockResolvedValueOnce({
      ok: status >= 200 && status < 300,
      status,
      text: () =>
        Promise.resolve(
          typeof body === 'string' ? body : JSON.stringify(body),
        ),
    } as Response)
    global.fetch = fetchMock as unknown as typeof fetch
  }

  const req = {
    model: 'MiniMax-M2.7',
    base_url: 'https://api.minimax.io/v1/chat/completions',
    api_key: 'sk-test',
    url_style: 'openai',
  }

  it('POSTs the profile to /api/llm/test as JSON', async () => {
    mockFetchOnce(200, { ok: true, model: req.model, reply: 'ok', latency_ms: 123 })

    await testLlmProfile(req)

    expect(fetchMock).toHaveBeenCalledTimes(1)
    const [url, init] = fetchMock.mock.calls[0] as [string, RequestInit]
    expect(url).toContain('/api/llm/test')
    expect(init.method).toBe('POST')
    expect(init.headers).toMatchObject({ 'Content-Type': 'application/json' })
    expect(JSON.parse(init.body as string)).toEqual(req)
  })

  it('returns the ok:true payload verbatim', async () => {
    mockFetchOnce(200, { ok: true, model: 'm', reply: 'ok', latency_ms: 42 })

    const result = await testLlmProfile(req)

    expect(result).toEqual({ ok: true, model: 'm', reply: 'ok', latency_ms: 42 })
  })

  it('returns the ok:false payload verbatim (no throw — the modal renders it inline)', async () => {
    mockFetchOnce(200, { ok: false, error: 'model is required', details: 'MissingModel' })

    const result = await testLlmProfile(req)

    expect(result).toEqual({ ok: false, error: 'model is required', details: 'MissingModel' })
  })

  it('maps a non-JSON response to a generic ok:false shape', async () => {
    mockFetchOnce(502, '<html>bad gateway</html>')

    const result = await testLlmProfile(req)

    assert(!result.ok, 'expected ok:false for non-JSON 502 response')
    expect(result.error).toContain('HTTP 502')
  })
})
