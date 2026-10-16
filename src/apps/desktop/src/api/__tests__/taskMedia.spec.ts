/** Tests for the lazy task-media endpoint client (media-flags change). List/get return only
 * `is_have_image` / `is_have_video` flags so board fetches stay small; `getTaskMedia` fetches the
 * full `||`-delimited base64 TEXT columns on demand (called only when a flag is true). */
import { afterEach, describe, expect, it, vi } from 'vitest'

import { getTaskMedia, getTasksMedia } from '@/api/index'

function jsonResponse(body: unknown, status = 200): Response {
  return new Response(JSON.stringify(body), {
    status,
    headers: { 'Content-Type': 'application/json' },
  })
}

afterEach(() => {
  vi.unstubAllGlobals()
})

describe('getTaskMedia', () => {
  it('hits the media endpoint with encoded ids', async () => {
    const fetchMock = vi.fn(async () => jsonResponse({ image_urls: '', video_urls: '' }))
    vi.stubGlobal('fetch', fetchMock)

    const data = await getTaskMedia('ws 1/2', 'item 3', 'task 4')
    expect(data).toEqual({ imageUrls: [], videoUrls: [] })
    expect(fetchMock).toHaveBeenCalledTimes(1)
    const [url] = fetchMock.mock.calls[0] as unknown as [string]
    expect(url).toBe('/api/workspaces/ws%201%2F2/items/item%203/tasks/task%204/media')
  })

  it('splits ||-delimited wire strings and drops empty segments', async () => {
    vi.stubGlobal(
      'fetch',
      vi.fn(async () =>
        jsonResponse({
          image_urls: 'data:image/png;base64,AAA||data:image/png;base64,BBB',
          video_urls: 'data:video/mp4;base64,CCC',
        }),
      ),
    )

    const data = await getTaskMedia('ws', 'item', 'task')
    expect(data?.imageUrls).toEqual(['data:image/png;base64,AAA', 'data:image/png;base64,BBB'])
    expect(data?.videoUrls).toEqual(['data:video/mp4;base64,CCC'])
  })

  it('resolves null on 404', async () => {
    vi.stubGlobal(
      'fetch',
      vi.fn(async () => jsonResponse({ error: 'task not found' }, 404)),
    )

    const data = await getTaskMedia('ws', 'item', 'no_such_task')
    expect(data).toBeNull()
  })
})

describe('getTasksMedia', () => {
  it('fires one request per id concurrently and maps results by id', async () => {
    const fetchMock = vi.fn(async (url: string) => {
      if (url.includes('/tasks/t1/media'))
        return jsonResponse({ image_urls: 'data:image/png;base64,AAA', video_urls: '' })
      return jsonResponse({ image_urls: '', video_urls: 'data:video/mp4;base64,BBB' })
    })
    vi.stubGlobal('fetch', fetchMock)

    const out = await getTasksMedia('ws', 'item', ['t1', 't2'])
    expect(fetchMock).toHaveBeenCalledTimes(2)
    expect(out.get('t1')).toEqual({
      imageUrls: ['data:image/png;base64,AAA'],
      videoUrls: [],
    })
    expect(out.get('t2')).toEqual({
      imageUrls: [],
      videoUrls: ['data:video/mp4;base64,BBB'],
    })
  })

  it('resolves a 404 leg to null without failing the batch', async () => {
    const fetchMock = vi.fn(async (url: string) => {
      if (url.includes('/tasks/gone/media'))
        return jsonResponse({ error: 'task not found' }, 404)
      return jsonResponse({ image_urls: 'data:image/png;base64,AAA', video_urls: '' })
    })
    vi.stubGlobal('fetch', fetchMock)

    const out = await getTasksMedia('ws', 'item', ['ok', 'gone'])
    expect(out.get('gone')).toBeNull()
    expect(out.get('ok')).toEqual({
      imageUrls: ['data:image/png;base64,AAA'],
      videoUrls: [],
    })
  })
})
