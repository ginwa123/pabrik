/** Behavioural tests for the D2 URL builder. Kroki's GET form is base64url(zlib-deflate(source)) —
 * the assertions decode the encoded string back, so a changed alphabet or a switch to raw deflate
 * fails here instead of as a 400 in the transcript. */
import { describe, expect, it } from 'vitest'
import { D2_DEFAULT_SERVER, d2SvgUrl, encodeD2, resolveD2Server } from '../d2'

const SOURCE = 'a: Alpha -> b: Beta'

const fromBase64Url = (encoded: string): Uint8Array<ArrayBuffer> => {
  const padded = encoded.replace(/-/g, '+').replace(/_/g, '/')
  const binary = atob(padded + '='.repeat((4 - (padded.length % 4)) % 4))
  const bytes = new Uint8Array(new ArrayBuffer(binary.length))
  for (let i = 0; i < binary.length; i += 1) bytes[i] = binary.charCodeAt(i)
  return bytes
}

/** Decompress through a one-chunk stream — jsdom's Blob has no `.stream()`. */
const inflate = async (bytes: Uint8Array<ArrayBuffer>): Promise<string> => {
  const stream = new ReadableStream<Uint8Array<ArrayBuffer>>({
    start(controller) {
      controller.enqueue(bytes)
      controller.close()
    },
  }).pipeThrough(new DecompressionStream('deflate'))
  return new Response(stream).text()
}

describe('encodeD2', () => {
  it('produces base64url that inflates back to the source', async () => {
    const encoded = await encodeD2(SOURCE)
    expect(encoded).not.toMatch(/[+/=]/)
    expect(await inflate(fromBase64Url(encoded))).toBe(SOURCE)
  })

  it('survives multi-byte characters and newlines', async () => {
    const source = 'a: "naïve → b"\n\nc -> a: step ✅'
    expect(await inflate(fromBase64Url(await encodeD2(source)))).toBe(source)
  })

  it('is deterministic — the same source is the same URL, so a re-render is cacheable', async () => {
    expect(await encodeD2(SOURCE)).toBe(await encodeD2(SOURCE))
  })
})

describe('d2SvgUrl', () => {
  it('appends /d2/svg/<encoded> to the server', async () => {
    const url = await d2SvgUrl(SOURCE, 'https://example.test')
    expect(url.startsWith('https://example.test/d2/svg/')).toBe(true)
    expect(await inflate(fromBase64Url(url.split('/').pop() ?? ''))).toBe(SOURCE)
  })

  it('does not double the slash when the server has a trailing one', async () => {
    expect(await d2SvgUrl(SOURCE, 'https://example.test/')).toBe(
      await d2SvgUrl(SOURCE, 'https://example.test'),
    )
  })
})

describe('resolveD2Server', () => {
  it('defaults to the public Kroki so the feature needs no setup', () => {
    expect(D2_DEFAULT_SERVER).toBe('https://kroki.io')
    expect(resolveD2Server()).toBe(D2_DEFAULT_SERVER)
  })
})
