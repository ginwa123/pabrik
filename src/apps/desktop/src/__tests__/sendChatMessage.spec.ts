import { describe, it, expect, beforeEach, vi } from 'vitest'
import { setActivePinia, createPinia } from 'pinia'
import { sendChatMessage } from '../api'

describe('sendChatMessage', () => {
  beforeEach(() => {
    setActivePinia(createPinia())
    vi.restoreAllMocks()
  })

  it('returns { status: "bad_request" } on 400', async () => {
    vi.spyOn(globalThis, 'fetch').mockResolvedValue(
      new Response('{"error":"bad"}', {
        status: 400,
        headers: { 'Content-Type': 'application/json' },
      }),
    )
    expect(await sendChatMessage('s1', 'msg', '/cwd')).toEqual({ status: 'bad_request' })
  })

  it('returns { status: "unprocessable_entity" } on 422', async () => {
    vi.spyOn(globalThis, 'fetch').mockResolvedValue(
      new Response('{"error":"bad"}', {
        status: 422,
        headers: { 'Content-Type': 'application/json' },
      }),
    )
    expect(await sendChatMessage('s1', 'msg', '/cwd')).toEqual({ status: 'unprocessable_entity' })
  })

  it('returns { status: "offline" } on network failure', async () => {
    vi.spyOn(globalThis, 'fetch').mockRejectedValue(new TypeError('NetworkError'))
    expect(await sendChatMessage('s1', 'msg', '/cwd')).toEqual({ status: 'offline' })
  })

  it('returns parsed body on 2xx', async () => {
    vi.spyOn(globalThis, 'fetch').mockResolvedValue(
      new Response('{"status":"queued"}', {
        status: 200,
        headers: { 'Content-Type': 'application/json' },
      }),
    )
    expect(await sendChatMessage('s1', 'msg', '/cwd')).toEqual({ status: 'queued' })
  })

  it('does not fire a notification on 400 (silent: true)', async () => {
    const { useNotificationStore } = await import('../stores/notifications')
    vi.spyOn(globalThis, 'fetch').mockResolvedValue(
      new Response('{"error":"bad"}', {
        status: 400,
        headers: { 'Content-Type': 'application/json' },
      }),
    )
    await sendChatMessage('s1', 'msg', '/cwd')
    const store = useNotificationStore()
    expect(store.notifications).toHaveLength(0)
  })
})

/** The attachment wire format. `image_urls` / `video_urls` ride as ONE string joined with `||` — the
 * same separator the three kanban task endpoints in this module already sent. */
describe('sendChatMessage — attachment wire format', () => {
  beforeEach(() => {
    setActivePinia(createPinia())
    vi.restoreAllMocks()
  })

  const PNG_A = 'data:image/png;base64,AAA'
  const PNG_B = 'data:image/png;base64,BBB'

  const postedBody = async (
    ...args: Parameters<typeof sendChatMessage>
  ): Promise<Record<string, unknown>> => {
    vi.spyOn(globalThis, 'fetch').mockResolvedValue(
      new Response('{"status":"queued"}', {
        status: 200,
        headers: { 'Content-Type': 'application/json' },
      }),
    )
    await sendChatMessage(...args)
    const [, init] = vi.mocked(globalThis.fetch).mock.calls[0] as unknown as [string, RequestInit]
    return JSON.parse(String(init.body)) as Record<string, unknown>
  }

  it('joins multiple images with || so the queued row matches every other endpoint', async () => {
    const body = await postedBody('s1', 'hi', '/cwd', [PNG_A, PNG_B])
    expect(body.image_urls).toBe(`${PNG_A}||${PNG_B}`)
  })

  it('sends a lone image unchanged (no delimiter to add)', async () => {
    const body = await postedBody('s1', 'hi', '/cwd', [PNG_A])
    expect(body.image_urls).toBe(PNG_A)
  })

  it('sends the empty string sentinel when there are no attachments', async () => {
    const body = await postedBody('s1', 'hi', '/cwd')
    expect(body.image_urls).toBe('')
    expect(body.video_urls).toBe('')
  })

  it('sends the attached documents as ONE JSON array field', async () => {
    const body = await postedBody('s1', 'hi', '/cwd', [], undefined, undefined, [], undefined, [
      { name: 'doc.pdf', mime: 'application/pdf', b64: 'aGk=' },
    ])
    expect(JSON.parse(String(body.file_attachments))).toEqual([
      { name: 'doc.pdf', mime: 'application/pdf', b64: 'aGk=' },
    ])
  })

  it('omits the file field when the message carries no document', async () => {
    const body = await postedBody('s1', 'hi', '/cwd')
    expect(body.file_attachments).toBeUndefined()
  })

  it('routes data:video entries to video_urls, joined with ||', async () => {
    const body = await postedBody(
      's1',
      'hi',
      '/cwd',
      [PNG_A, 'data:video/mp4;base64,AAA'],
      undefined,
      undefined,
      ['data:video/webm;base64,BBB'],
    )
    expect(body.image_urls).toBe(PNG_A)
    // Order is `splitMediaUrls`'s, not this test's: the explicit `videoUrls`
    // argument seeds the list before the inline `data:video/` entries are
    // appended. Pre-existing, and irrelevant to the delimiter.
    expect(body.video_urls).toBe('data:video/webm;base64,BBB||data:video/mp4;base64,AAA')
  })
})
